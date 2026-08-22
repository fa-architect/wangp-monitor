# WanGP Python Process Monitor (v5 - 修正確定版)
# CPU / GPU / RAM / VRAM / 出力状況を監視
#
# v3からの修正点:
#   1. Get-CimInstance Win32_Process を Get-Process ベースに変更（反復呼び出しの負荷軽減）
#   2. nvidia-smi 呼び出しにタイムアウト機構を追加（ハング対策）
#   3. メインループ末尾に Start-Sleep を追加（欠落していた）
#   4. 未使用だった Get-GpuSamples 関数を削除
#   5. サンプリング中の進捗表示を追加（「固まって見える」問題への対処）
#
# 注意: 本ツールはWanGP内部の進捗APIを使わず、CPU/GPU/VRAM/出力ファイルの
# 変化から動作状況を推定する補助ツール。正確な進捗率・残り時間は分からない。

$Host.UI.RawUI.WindowTitle = "WanGP Monitor v5"

$previous = @{}
$outputPath = "C:\Users\User\Documents\AI\Wan2GP\outputs"
$intervalSeconds = 10
$sampleCount = 5
$gpuTimeoutSec = 5
$stallThresholdChecks = 18   # 3分 / 10秒 = 18回

$lastOutputCount = 0
$monitorStartTime = Get-Date
$stallCount = 0

if (Test-Path $outputPath) {
    $lastOutputCount = @(
        Get-ChildItem $outputPath -Filter "*.mp4" -File -ErrorAction SilentlyContinue
    ).Count
}

# nvidia-smi をタイムアウト付きで呼び出す（ハング対策）
# 注意: Start-Job内で --query-gpu=... のような長い文字列引数を直接並べると
# パースに失敗することがある（v4で発見）。配列(@gpuArgs)で渡すことで解決する。
function Invoke-NvidiaSmiSafe {
    param([int]$TimeoutSec = 5)

    $job = Start-Job -ScriptBlock {
        $gpuArgs = @(
            '--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw',
            '--format=csv,noheader,nounits'
        )
        & nvidia-smi @gpuArgs 2>&1
    }

    $completed = Wait-Job $job -Timeout $TimeoutSec
    $result = $null

    if ($completed) {
        $raw = Receive-Job $job
        if ($raw) { $result = ($raw -join "").Trim() }
    }

    Remove-Job $job -Force -ErrorAction SilentlyContinue
    return $result
}

while ($true) {
    Clear-Host

    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "         WanGP動作状況モニター (v5)" -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "更新: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

    $elapsed = (Get-Date) - $monitorStartTime
    Write-Host ("監視時間: {0:00}:{1:00}:{2:00}" -f `
        [math]::Floor($elapsed.TotalHours), $elapsed.Minutes, $elapsed.Seconds)

    Write-Host ""
    Write-Host "本ツールはWanGP内部の進捗APIを使わず、CPU/GPU/VRAM/" -ForegroundColor DarkGray
    Write-Host "出力ファイルの変化から動作状況を推定する補助ツールです。" -ForegroundColor DarkGray
    Write-Host "正確な進捗率・残り時間は分かりません。" -ForegroundColor DarkGray
    Write-Host ""

    # ---------------- CPU/プロセス（軽量版） ----------------
    # Get-CimInstance Win32_Process の代わりに Get-Process を使用。
    # コマンドラインは取れないため、プロセス名とメモリ量からWanGP候補を推定する。
    $pythonProcs = Get-Process -Name "python", "pythonw" -ErrorAction SilentlyContinue

    $cpuActive = $false

    if (-not $pythonProcs) {
        Write-Host "Pythonプロセスが見つかりません。" -ForegroundColor Yellow
        Write-Host "WanGPが起動していないか、終了しています。" -ForegroundColor Yellow
    }
    else {
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
            }
        }

        $results | Sort-Object RAM_GB -Descending |
            Format-Table PID, CPU累積秒, CPU増加, RAM_GB -AutoSize

        # RAM使用量最大のプロセスをメイン候補とみなす（コマンドライン特定不可のため簡易推定）
        $mainProc = $results | Sort-Object RAM_GB -Descending | Select-Object -First 1

        if ($mainProc -and $mainProc.CPU増加 -gt 0.1) {
            $cpuActive = $true
        }

        if ($mainProc) {
            Write-Host "最大メモリ使用プロセス: PID $($mainProc.PID) (RAM: $($mainProc.RAM_GB)GB)" -ForegroundColor DarkGray
        }
    }

    # ---------------- GPU (タイムアウト付き複数回サンプリング) ----------------
    Write-Host ""
    Write-Host "---------------- GPU (最大${gpuTimeoutSec}秒×${sampleCount}回計測) -----------------" -ForegroundColor Cyan

    $gpuActive = $false
    $samples = @()
    $nvidiaSmiCmd = Get-Command nvidia-smi -ErrorAction SilentlyContinue

    if (-not $nvidiaSmiCmd) {
        Write-Host "nvidia-smiが見つかりません。" -ForegroundColor Yellow
    }
    else {
        for ($si = 0; $si -lt $sampleCount; $si++) {
            Write-Host ("  計測中 {0}/{1} ..." -f ($si + 1), $sampleCount) -ForegroundColor DarkGray -NoNewline

            $gpuLine = Invoke-NvidiaSmiSafe -TimeoutSec $gpuTimeoutSec

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
                    Write-Host " OK" -ForegroundColor DarkGray
                }
                else {
                    Write-Host " 解析失敗" -ForegroundColor Yellow
                }
            }
            else {
                Write-Host " タイムアウト/エラー" -ForegroundColor Red
            }

            if ($si -lt ($sampleCount - 1)) {
                Start-Sleep -Milliseconds ([int](($intervalSeconds * 1000) / $sampleCount))
            }
        }
    }

    if (-not $samples -or $samples.Count -eq 0) {
        Write-Host "GPU情報を取得できませんでした。" -ForegroundColor Yellow
    }
    else {
        $utilAvg = [math]::Round(($samples | Measure-Object -Property Util -Average).Average, 1)
        $utilMax = ($samples | Measure-Object -Property Util -Maximum).Maximum
        $utilMin = ($samples | Measure-Object -Property Util -Minimum).Minimum
        $memLatest = $samples[-1].MemUsed
        $memTotal = $samples[-1].MemTotal
        $tempLatest = $samples[-1].Temp
        $powerLatest = $samples[-1].Power

        Write-Host ""
        Write-Host "GPU:            $($samples[-1].Name)"
        Write-Host ("平均使用率:      {0} %" -f $utilAvg)
        Write-Host ("最大使用率:      {0} %  ／ 最小: {1} %" -f $utilMax, $utilMin)
        Write-Host ("VRAM(現在値):    {0} / {1} MB" -f $memLatest, $memTotal)
        Write-Host ("温度(現在値):    {0} ℃" -f $tempLatest)
        Write-Host ("消費電力(現在値): {0} W" -f $powerLatest)

        if ($utilMax -ge 10) {
            $gpuActive = $true
            Write-Host ""
            Write-Host "● GPU処理を確認（最大使用率: $utilMax %）" -ForegroundColor Green
        }
        else {
            Write-Host ""
            Write-Host "△ 計測中、GPU使用率は10%を超えませんでした。" -ForegroundColor Yellow
        }
    }

    # ---------------- 出力フォルダ ----------------
    Write-Host ""
    Write-Host "--------------- 出力 -----------------------------"

    $outputChanged = $false

    if (Test-Path $outputPath) {
        $currentFiles = @(
            Get-ChildItem $outputPath -Filter "*.mp4" -File -ErrorAction SilentlyContinue
        )
        $currentCount = $currentFiles.Count

        if ($currentCount -gt $lastOutputCount) {
            Write-Host "★ 新しい動画ファイルが生成されました！" -ForegroundColor Magenta
            $lastOutputCount = $currentCount
            $outputChanged = $true
        }

        $latestFile = $currentFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latestFile) {
            $age = (Get-Date) - $latestFile.LastWriteTime
            Write-Host "最新出力: $($latestFile.Name)"
            Write-Host ("更新: {0:N1}分前 | サイズ: {1:N1} MB" -f $age.TotalMinutes, ($latestFile.Length / 1MB))
        }
        else {
            Write-Host "MP4ファイルはまだありません。"
        }
        Write-Host "出力ファイル総数: $currentCount 個"
    }
    else {
        Write-Host "出力フォルダが見つかりません:" -ForegroundColor Yellow
        Write-Host $outputPath -ForegroundColor Yellow
    }

    # ---------------- 総合判定 ----------------
    Write-Host ""
    Write-Host "---------------- 総合判定 -------------------------" -ForegroundColor Cyan

    if ($cpuActive -or $gpuActive -or $outputChanged) {
        $stallCount = 0
        Write-Host "● 処理は継続していると考えられます。" -ForegroundColor Green
        Write-Host "  (CPU増加:$cpuActive / GPU反応:$gpuActive / 出力更新:$outputChanged)" -ForegroundColor DarkGray
    }
    else {
        $stallCount++
        Write-Host "△ 今回の計測ではCPU/GPU/出力すべてに変化が見られませんでした。" -ForegroundColor Yellow
        Write-Host "  連続 $stallCount 回目（3分＝18回で警告）" -ForegroundColor DarkGray

        if ($stallCount -ge $stallThresholdChecks) {
            Write-Host ""
            Write-Host "▲ 約3分間、CPU・GPU・出力ファイルのいずれにも変化がありません。" -ForegroundColor Red
            Write-Host "  フリーズしている可能性があります。WanGP画面を確認してください。" -ForegroundColor Red
        }
    }

    Write-Host "--------------------------------------------------"
    Write-Host "終了: Ctrl+C"
    Write-Host ""

    Start-Sleep -Seconds 2
}
