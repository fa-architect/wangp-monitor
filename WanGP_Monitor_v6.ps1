# WanGP Python Process Monitor (v6 - パフォーマンス改善版)
# CPU / GPU / RAM / VRAM / 出力状況を監視
#
# v5からの修正点:
#   1. 出力パスのハードコードを廃止し、スクリプト冒頭の設定変数に切り出し
#      （$HOME基準の相対パスをデフォルトに変更、環境が違っても動くように）
#   2. Start-Job（プロセス生成コストが高い）を廃止し、
#      System.Diagnostics.Process + WaitForExit()による軽量なタイムアウト処理に変更
#   3. Clear-Hostによる画面のちらつきを廃止し、
#      [Console]::SetCursorPosition(0,0)での上書き描画に変更
#   4. プロセス特定を、RAM使用量最大からの推定に加えて、
#      Get-CimInstanceで一度だけコマンドラインを確認し「wgp.py」等の
#      WanGP関連キーワードを含むプロセスを優先的に採用するよう変更
#
# 注意: 本ツールはWanGP内部の進捗APIを使わず、CPU/GPU/VRAM/出力ファイルの
# 変化から動作状況を推定する補助ツール。正確な進捗率・残り時間は分からない。

# ==================== 設定 ====================
# 出力フォルダのパス。既定では実行ユーザーのDocuments配下を想定するが、
# 環境に合わせて自由に書き換えてよい。
$outputPath = Join-Path $HOME "Documents\AI\Wan2GP\outputs"

$intervalSeconds = 10
$sampleCount = 5
$gpuTimeoutSec = 5
$stallThresholdChecks = 18   # 3分 / 10秒 = 18回
# ================================================

$Host.UI.RawUI.WindowTitle = "WanGP Monitor v6"

$previous = @{}
$lastOutputCount = 0
$monitorStartTime = Get-Date
$stallCount = 0
$isFirstDraw = $true

if (Test-Path $outputPath) {
    $lastOutputCount = @(
        Get-ChildItem $outputPath -Filter "*.mp4" -File -ErrorAction SilentlyContinue
    ).Count
}

# nvidia-smi を .NET Process + WaitForExit でタイムアウト付き実行する
# （Start-Jobより軽量。v4/v5で判明した「長い文字列引数を直接渡すとパースに
#   失敗する」問題を避けるため、引数は配列としてArgumentListに渡す）
function Invoke-NvidiaSmiSafe {
    param([int]$TimeoutSec = 5)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "nvidia-smi"
    $psi.ArgumentList.Add('--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw')
    $psi.ArgumentList.Add('--format=csv,noheader,nounits')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    try {
        [void]$proc.Start()
        $exited = $proc.WaitForExit($TimeoutSec * 1000)

        if (-not $exited) {
            try { $proc.Kill() } catch {}
            return $null
        }

        $out = $proc.StandardOutput.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($out)) { return $null }
        return $out.Trim()
    }
    catch {
        return $null
    }
    finally {
        $proc.Dispose()
    }
}

# WanGP候補プロセスのPIDを、一度だけコマンドラインで特定する試み。
# Get-CimInstanceは重いので毎ループ呼ばず、プロセス一覧が変わった時だけ照合する。
$knownWanGpPid = $null
function Resolve-WanGpPid {
    param([object[]]$PythonProcs)

    if (-not $PythonProcs) { return $null }

    try {
        $cimProcs = Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" -ErrorAction Stop
        foreach ($cp in $cimProcs) {
            if ($cp.CommandLine -and ($cp.CommandLine -match "wgp\.py|Wan2GP|WanGP")) {
                return $cp.ProcessId
            }
        }
    }
    catch {
        # CIM取得に失敗しても致命的ではない。RAM最大値へフォールバックする。
    }
    return $null
}

while ($true) {
    if ($isFirstDraw) {
        Clear-Host
        $isFirstDraw = $false
    }
    else {
        [Console]::SetCursorPosition(0, 0)
    }

    # 各行を固定幅でパディングし、前回より短い行が残らないようにする
    $lines = New-Object System.Collections.Generic.List[string]
    function Add-Line([string]$text = "") { $lines.Add($text) }

    Add-Line "=================================================="
    Add-Line "         WanGP動作状況モニター (v6)"
    Add-Line "=================================================="
    Add-Line "更新: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

    $elapsed = (Get-Date) - $monitorStartTime
    Add-Line ("監視時間: {0:00}:{1:00}:{2:00}" -f `
        [math]::Floor($elapsed.TotalHours), $elapsed.Minutes, $elapsed.Seconds)

    Add-Line ""
    Add-Line "本ツールはWanGP内部の進捗APIを使わず、CPU/GPU/VRAM/"
    Add-Line "出力ファイルの変化から動作状況を推定する補助ツールです。"
    Add-Line "正確な進捗率・残り時間は分かりません。"
    Add-Line ""

    # ---------------- CPU/プロセス ----------------
    $pythonProcs = Get-Process -Name "python", "pythonw" -ErrorAction SilentlyContinue
    $cpuActive = $false

    if (-not $pythonProcs) {
        Add-Line "Pythonプロセスが見つかりません。"
        Add-Line "WanGPが起動していないか、終了しています。"
        $knownWanGpPid = $null
    }
    else {
        # 既知のWanGP PIDがまだ生きているか確認。いなければ再特定を試みる。
        if ($knownWanGpPid -and -not ($pythonProcs.Id -contains $knownWanGpPid)) {
            $knownWanGpPid = $null
        }
        if (-not $knownWanGpPid) {
            $knownWanGpPid = Resolve-WanGpPid -PythonProcs $pythonProcs
        }

        $results = foreach ($proc in $pythonProcs) {
            $pidValue = $proc.Id
            $cpu = if ($null -ne $proc.CPU) { $proc.CPU } else { 0 }
            $ramGB = [math]::Round($proc.WorkingSet64 / 1GB, 2)

            $cpuDelta = 0
            if ($previous.ContainsKey($pidValue)) {
                $cpuDelta = [math]::Round($cpu - $previous[$pidValue], 2)
            }
            $previous[$pidValue] = $cpu

            [PSCustomObject]@{
                PID       = $pidValue
                CPU累積秒 = [math]::Round($cpu, 1)
                CPU増加   = $cpuDelta
                RAM_GB    = $ramGB
                WanGP候補 = if ($pidValue -eq $knownWanGpPid) { "はい" } else { "" }
            }
        }

        $tableLines = ($results | Sort-Object RAM_GB -Descending |
            Format-Table PID, WanGP候補, CPU累積秒, CPU増加, RAM_GB -AutoSize | Out-String) -split "`r?`n"
        foreach ($tl in $tableLines) { Add-Line $tl }

        # コマンドラインで特定できていればそれを、できていなければRAM最大値を採用
        $mainProc = if ($knownWanGpPid) {
            $results | Where-Object { $_.PID -eq $knownWanGpPid } | Select-Object -First 1
        } else {
            $results | Sort-Object RAM_GB -Descending | Select-Object -First 1
        }

        if ($mainProc -and $mainProc.CPU増加 -gt 0.1) {
            $cpuActive = $true
        }

        if ($mainProc) {
            $label = if ($knownWanGpPid) { "WanGP候補プロセス" } else { "最大メモリ使用プロセス（推定）" }
            Add-Line "$label : PID $($mainProc.PID) (RAM: $($mainProc.RAM_GB)GB)"
        }
    }

    # ---------------- GPU ----------------
    Add-Line ""
    Add-Line "---------------- GPU (最大${gpuTimeoutSec}秒×${sampleCount}回計測) -----------------"

    $gpuActive = $false
    $samples = @()
    $nvidiaSmiCmd = Get-Command nvidia-smi -ErrorAction SilentlyContinue

    if (-not $nvidiaSmiCmd) {
        Add-Line "nvidia-smiが見つかりません。"
    }
    else {
        for ($si = 0; $si -lt $sampleCount; $si++) {
            $gpuLine = Invoke-NvidiaSmiSafe -TimeoutSec $gpuTimeoutSec
            $status = if ($gpuLine) { "OK" } else { "タイムアウト/エラー" }
            Add-Line ("  計測中 {0}/{1} ... {2}" -f ($si + 1), $sampleCount, $status)

            if ($gpuLine) {
                $p = $gpuLine -split ",\s*"
                if ($p.Count -ge 6) {
                    $samples += [PSCustomObject]@{
                        Name     = $p[0].Trim()
                        Util     = [int]$p[1]
                        MemUsed  = [int]$p[2]
                        MemTotal = [int]$p[3]
                        Temp     = [double]$p[4]
                        Power    = [double]$p[5]
                    }
                }
            }

            if ($si -lt ($sampleCount - 1)) {
                Start-Sleep -Milliseconds ([int](($intervalSeconds * 1000) / $sampleCount))
            }
        }
    }

    if (-not $samples -or $samples.Count -eq 0) {
        Add-Line "GPU情報を取得できませんでした。"
    }
    else {
        $utilAvg = [math]::Round(($samples | Measure-Object -Property Util -Average).Average, 1)
        $utilMax = ($samples | Measure-Object -Property Util -Maximum).Maximum
        $utilMin = ($samples | Measure-Object -Property Util -Minimum).Minimum
        $memLatest = $samples[-1].MemUsed
        $memTotal = $samples[-1].MemTotal
        $tempLatest = $samples[-1].Temp
        $powerLatest = $samples[-1].Power

        Add-Line ""
        Add-Line "GPU:            $($samples[-1].Name)"
        Add-Line ("平均使用率:      {0} %" -f $utilAvg)
        Add-Line ("最大使用率:      {0} %  ／ 最小: {1} %" -f $utilMax, $utilMin)
        Add-Line ("VRAM(現在値):    {0} / {1} MB" -f $memLatest, $memTotal)
        Add-Line ("温度(現在値):    {0} ℃" -f $tempLatest)
        Add-Line ("消費電力(現在値): {0} W" -f $powerLatest)
        Add-Line ""

        if ($utilMax -ge 10) {
            $gpuActive = $true
            Add-Line "● GPU処理を確認（最大使用率: $utilMax %）"
        }
        else {
            Add-Line "△ 計測中、GPU使用率は10%を超えませんでした。"
        }
    }

    # ---------------- 出力フォルダ ----------------
    Add-Line ""
    Add-Line "--------------- 出力 -----------------------------"

    $outputChanged = $false

    if (Test-Path $outputPath) {
        $currentFiles = @(
            Get-ChildItem $outputPath -Filter "*.mp4" -File -ErrorAction SilentlyContinue
        )
        $currentCount = $currentFiles.Count

        if ($currentCount -gt $lastOutputCount) {
            Add-Line "★ 新しい動画ファイルが生成されました！"
            $lastOutputCount = $currentCount
            $outputChanged = $true
        }

        $latestFile = $currentFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latestFile) {
            $age = (Get-Date) - $latestFile.LastWriteTime
            Add-Line "最新出力: $($latestFile.Name)"
            Add-Line ("更新: {0:N1}分前 | サイズ: {1:N1} MB" -f $age.TotalMinutes, ($latestFile.Length / 1MB))
        }
        else {
            Add-Line "MP4ファイルはまだありません。"
        }
        Add-Line "出力ファイル総数: $currentCount 個"
    }
    else {
        Add-Line "出力フォルダが見つかりません:"
        Add-Line $outputPath
        Add-Line "（スクリプト冒頭の `$outputPath 変数で、実際のパスに書き換えてください）"
    }

    # ---------------- 総合判定 ----------------
    Add-Line ""
    Add-Line "---------------- 総合判定 -------------------------"

    if ($cpuActive -or $gpuActive -or $outputChanged) {
        $stallCount = 0
        Add-Line "● 処理は継続していると考えられます。"
        Add-Line "  (CPU増加:$cpuActive / GPU反応:$gpuActive / 出力更新:$outputChanged)"
    }
    else {
        $stallCount++
        Add-Line "△ 今回の計測ではCPU/GPU/出力すべてに変化が見られませんでした。"
        Add-Line "  連続 $stallCount 回目（3分＝18回で警告）"

        if ($stallCount -ge $stallThresholdChecks) {
            Add-Line ""
            Add-Line "▲ 約3分間、CPU・GPU・出力ファイルのいずれにも変化がありません。"
            Add-Line "  フリーズしている可能性があります。WanGP画面を確認してください。"
        }
    }

    Add-Line "--------------------------------------------------"
    Add-Line "終了: Ctrl+C"
    Add-Line ""

    # ウィンドウ幅に合わせてパディングし、上書き時に前回の残像が出ないようにする
    $consoleWidth = try { $Host.UI.RawUI.WindowSize.Width } catch { 80 }
    foreach ($line in $lines) {
        $padded = if ($line.Length -lt $consoleWidth) {
            $line.PadRight($consoleWidth - 1)
        } else {
            $line
        }
        Write-Host $padded
    }

    Start-Sleep -Seconds 2
}
