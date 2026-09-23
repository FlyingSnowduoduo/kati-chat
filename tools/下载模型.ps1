# 卡提聊天助手 · 一键下载模型
# 从 ModelScope（国内快速）下载 Qwen2.5-VL-7B-Instruct 的 GGUF 模型到 models\ 目录
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$root = Split-Path -Parent $PSScriptRoot
$dir = Join-Path $root 'models'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$base = 'https://modelscope.cn/models/ggml-org/Qwen2.5-VL-7B-Instruct-GGUF/resolve/master'
$files = @(
  @{ name = 'Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf'; min = 100MB },
  @{ name = 'mmproj-Qwen2.5-VL-7B-Instruct-f16.gguf'; min = 100MB }
)

Write-Host ''
Write-Host '  卡提聊天助手 · 模型下载' -ForegroundColor Cyan
Write-Host "  目标目录: $dir"
Write-Host '  （主模型约 4.4GB + 视觉编码器约 1.3GB，共约 5.6GB；25MB/s 时约 4 分钟）'
Write-Host ''

foreach ($f in $files) {
  $dst = Join-Path $dir $f.name
  if ((Test-Path $dst) -and ((Get-Item $dst).Length -gt $f.min)) {
    Write-Host "  [跳过] $($f.name) 已存在（$([math]::Round((Get-Item $dst).Length / 1GB, 2)) GB）" -ForegroundColor Green
    continue
  }
  Write-Host "  [下载] $($f.name) …" -ForegroundColor Yellow
  $t0 = Get-Date
  & curl.exe -L --retry 3 --retry-delay 2 -o $dst "$base/$($f.name)"
  if ((Test-Path $dst) -and ((Get-Item $dst).Length -gt $f.min)) {
    Write-Host ("  [完成] {0}  {1:N2} GB  {2:N0}s" -f $f.name, ((Get-Item $dst).Length / 1GB), ((Get-Date) - $t0).TotalSeconds) -ForegroundColor Green
  } else {
    Write-Host "  [失败] $($f.name) —— 请检查网络后重试" -ForegroundColor Red
  }
}

Write-Host ''
$total = (Get-ChildItem $dir -File | Measure-Object Length -Sum).Sum
Write-Host ("  模型目录合计: {0:N2} GB" -f ($total / 1GB)) -ForegroundColor Cyan
Write-Host '  接下来：把 llama.cpp 的 Vulkan 版（llama-server.exe 等）放到 runtime\llama\，然后运行 .\launch.ps1'
