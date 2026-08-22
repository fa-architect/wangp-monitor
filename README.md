
WanGP (Wan2GP) の動作状況を監視するPowerShellスクリプト。CPU/GPU/VRAM/出力ファイルの変化からフリーズを検知します。
# WanGP Monitor v5

A PowerShell monitoring tool for WanGP (Wan2GP) — watches CPU / GPU / VRAM / output file changes to help detect freezes during video generation. (Japanese docs below / 日本語の説明は下にあります)

---


[WanGP (Wan2GP)](https://github.com/deepbeepmeep/Wan2GP) を使ったAI動画生成（SCAIL-2等）は、1回の生成に数分〜数十分かかることがあります。その間、処理が正常に進んでいるのか、それとも実際にフリーズしているのか、画面を見ているだけでは分かりにくいことがあります。

このツールは、WanGPの内部進捗APIを使わず、外部から

- CPU使用率の変化
- GPU使用率・VRAM・温度・消費電力
- 出力フォルダの新規ファイル

を監視し、「処理が続いている可能性が高いか」「しばらく変化がなくフリーズしている可能性があるか」を推定して表示します。

**注意：** これは正確な進捗率や残り時間を示すものではありません。あくまで「動いていそうか」を判断するための補助ツールです。

## 使い方

```powershell
powershell -ExecutionPolicy Bypass -File "WanGP_Monitor_v5.ps1"
```

WanGPを起動した状態で、別のPowerShellウィンドウでこのスクリプトを実行してください。10秒ごとに画面が更新されます。

終了するには `Ctrl + C` を押してください。

## 表示される内容

- 監視時間
- Pythonプロセスの検出、CPU使用状況
- GPU使用率（最大5回サンプリングし、平均・最大値を表示）、VRAM、温度、消費電力
- 出力フォルダの最新ファイル、総数
- 総合判定（CPU・GPU・出力のいずれかに動きがあれば「継続中」、約3分間すべてに変化がなければ警告）

## v3からv5での修正内容

v3では、GPU情報の取得部分（`nvidia-smi`の呼び出し）に長時間フリーズするバグがありました。

原因は、PowerShellの`Start-Job`内で`nvidia-smi`に長いオプション文字列を直接渡すと、引数が意図通りに解釈されずエラーになる、というものでした。配列（`@gpuArgs`）で引数を渡す形に変更することで解決しています。

あわせて、`Get-CimInstance Win32_Process`（重い場合がある）から`Get-Process`ベースの軽量な取得方法に変更し、`nvidia-smi`呼び出しにはタイムアウト機構も追加しています。

## 動作環境

- Windows PowerShell
- NVIDIA GPU（`nvidia-smi`コマンドが使える環境）

## ライセンス

MIT License
