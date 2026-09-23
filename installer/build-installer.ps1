# 卡提聊天助手 · 安装包构建（最终版：iexpress 自解压 exe + 备用安装方式）
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$src      = 'F:\aiworking\whale-translator'
$build    = 'F:\aiworking\installer-build'
$payload  = Join-Path $build 'payload2'
$outDir   = 'F:\aiworking\卡提聊天助手_安装包'
$exeName  = '卡提聊天助手_安装程序.exe'
$llamaSrc = 'C:\aiuse\llama-b11100-bin-win-vulkan-x64'

Write-Host '=== 构建 卡提聊天助手 安装包 ===' -ForegroundColor Cyan

# ---------- 1. 暂存 ----------
Write-Host '[1/5] 暂存程序文件…'
Remove-Item $payload -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $payload 'app'), (Join-Path $payload 'runtime\llama') | Out-Null
foreach ($f in @('server.mjs', 'launch.ps1', 'tray.ps1', 'README.md', '停止服务.bat')) {
  Copy-Item (Join-Path $src $f) (Join-Path $payload "app\$f") -Force
}
foreach ($d in @('public', 'assets', 'tools')) {
  Copy-Item (Join-Path $src $d) (Join-Path $payload "app\$d") -Recurse -Force
}
Remove-Item (Join-Path $payload 'app\assets\test-en.png') -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $build 'install.ps1') (Join-Path $payload 'install.ps1') -Force

# 确保所有 .ps1 都带 UTF-8 BOM（PowerShell 5.1 解析中文脚本必需）
$bom = [byte[]](0xEF, 0xBB, 0xBF)
Get-ChildItem $payload -Recurse -Filter '*.ps1' | ForEach-Object {
  $bytes = [IO.File]::ReadAllBytes($_.FullName)
  if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
    $text = [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($_.FullName, $text, (New-Object Text.UTF8Encoding($true)))
    Write-Host "      已补齐 BOM: $($_.Name)"
  } else {
    Write-Host "      BOM 正常: $($_.Name)"
  }
}

Write-Host '[2/5] 复制运行时（内置 Node + llama.cpp Vulkan）…'
Copy-Item 'C:\Program Files\nodejs\node.exe' (Join-Path $payload 'runtime\node.exe') -Force
Copy-Item (Join-Path $llamaSrc '*') (Join-Path $payload 'runtime\llama\') -Recurse -Force
$totalPayload = (Get-ChildItem $payload -Recurse -File | Measure-Object Length -Sum).Sum
Write-Host ("      负载合计: {0:N1} MB" -f ($totalPayload / 1MB))

# ---------- 2. 打包 ----------
Write-Host '[3/5] 打包 payload.zip …'
$zip = Join-Path $build 'payload.zip'
Remove-Item $zip -Force -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($payload, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
Write-Host ("      payload.zip: {0:N1} MB" -f ((Get-Item $zip).Length / 1MB))

# ---------- 3. iexpress 生成自解压安装程序 ----------
$exePath = Join-Path $outDir $exeName
Write-Host '[4/5] 生成单文件安装程序（iexpress，需等 makecab 压缩完成）…'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Remove-Item $exePath -Force -ErrorAction SilentlyContinue
$sedContent = @"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=1
HideExtractAnimation=0
UseLongFileName=1
InsideCompressed=0
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=
DisplayPrompt=
RebootPrompt=
TargetName=$exePath
FriendlyName=KatiChat Setup
AppLaunched=install.cmd
PostInstallCmd=<None>
AdminQuietInstCmd=powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Src . -PkgDir .
UserQuietInstCmd=powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Src . -PkgDir .
SourceFiles=SourceFiles
[SourceFiles]
SourceFiles0=$build\
[SourceFiles0]
%FILE0%=
%FILE1%=
%FILE2%=
[Strings]
FILE0=payload.zip
FILE1=install.cmd
FILE2=install.ps1
"@
[IO.File]::WriteAllText((Join-Path $build 'kati3.sed'), $sedContent, [Text.Encoding]::GetEncoding(936))
$proc = Start-Process -FilePath "$env:WINDIR\System32\iexpress.exe" -ArgumentList '/N', '/Q', (Join-Path $build 'kati3.sed') -PassThru
$built = $false
for ($i = 1; $i -le 120; $i++) {
  Start-Sleep -Seconds 5
  if (Test-Path $exePath) {
    $a = (Get-Item $exePath).Length
    Start-Sleep -Seconds 5
    if ((Get-Item $exePath).Length -eq $a -and $a -gt 10MB) { $built = $true; break }
  }
  if ($proc.HasExited -and -not (Test-Path $exePath)) { break }
  if ($i % 12 -eq 0) { Write-Host "      已等待 $($i * 5)s …" }
}
if (-not $built) { throw '安装程序生成失败' }
Write-Host ("      {0}: {1:N1} MB" -f $exeName, ((Get-Item $exePath).Length / 1MB)) -ForegroundColor Green

# ---------- 4. 备用安装方式 + 模型 + 说明 ----------
Write-Host '[5/5] 备用安装文件、离线模型与说明…'
Copy-Item $zip (Join-Path $outDir 'payload.zip') -Force
Copy-Item (Join-Path $build 'install.ps1') (Join-Path $outDir 'install.ps1') -Force
Copy-Item (Join-Path $build 'install.cmd') (Join-Path $outDir '安装.cmd') -Force

$modelOut = Join-Path $outDir 'models'
New-Item -ItemType Directory -Force -Path $modelOut | Out-Null
foreach ($f in @('Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf', 'mmproj-Qwen2.5-VL-7B-Instruct-f16.gguf')) {
  $s = Join-Path $src "models\$f"
  $d = Join-Path $modelOut $f
  if ((Test-Path $d) -and ((Get-Item $d).Length -eq (Get-Item $s).Length)) { Write-Host "      $f 已存在，跳过"; continue }
  Write-Host "      复制 $f …"
  Copy-Item $s $d -Force
}

$readme = @"
卡提聊天助手 · 安装说明
=========================================

【一键安装】
  双击「$exeName」→ 出现解压进度窗口 → 自动完成安装并启动。
  安装程序会自动：
    1. 解压程序到 %LOCALAPPDATA%\KatiChat
       （内含 Node 运行时 + llama.cpp Vulkan 加速库，无需另装任何环境）
    2. 复制本文件夹 models 里的 AI 模型（约 5.6GB）
    3. 生成桌面快捷方式 + 开始菜单项
    4. 在「设置 → 应用和功能」登记（可一键卸载）
    5. 启动软件
  无需管理员权限；无需预装 Node.js / Python / Ollama。

【如果 exe 被安全软件拦截】
  改用备用方式：双击本文件夹里的「安装.cmd」（效果完全相同）。

【安装完成后怎么用】
  · 双击桌面「卡提聊天助手」→ 打开聊天窗口
      图片翻译：粘贴截图 / 拖入图片 → 自动识别英文 + 逐句翻译 + 单词词组详解
      文字翻译：直接输入英文
      回答长度：右上角切换「简洁 / 标准 / 详细」
      聊天记录自动保存在本机，右上角 🗑️ 可清空
  · 右 Alt + 回车 → 任何界面下呼出「悬浮快速输入窗」
  · 右下角托盘图标：双击打开窗口；右键菜单含 快速输入 / 停止后台服务 / 退出后台
  · 联网搜索：右上角「联网」下拉框（自动 / 始终 / 关闭）；问新闻类问题会自动抓实时热榜
  · 语音输入：点 🎤（需要 Edge / Chrome）

【卸载】
  设置 → 应用 → 应用和功能 → 卡提聊天助手 → 卸载
  或双击 %LOCALAPPDATA%\KatiChat\卸载.cmd

【配置要求】
  · Windows 10 / 11 64 位
  · 支持 Vulkan 的独立显卡（已在 AMD RX 6750 XT 12GB 实测：
      生成速度 46 tok/s，文字翻译约 4～5 秒，图片翻译约 4～10 秒）
  · 显存 8GB 以上体验最佳；无独显时可用 CPU 兜底（较慢）

【说明】
  · 若未随包携带 models 文件夹，安装程序会自动从 ModelScope 联网下载
  · 全部数据在本机运行、不上传；除主动使用「联网搜索」外不访问网络
"@
[IO.File]::WriteAllText((Join-Path $outDir '安装说明.txt'), $readme, (New-Object Text.UTF8Encoding($true)))

Write-Host ''
Write-Host '=== 构建完成 ===' -ForegroundColor Green
Get-ChildItem $outDir | Select-Object Name, @{n = 'MB'; e = { if ($_.PSIsContainer) { '<文件夹>' } else { [math]::Round($_.Length / 1MB, 1) } } } | Format-Table -AutoSize | Out-String | Write-Host
