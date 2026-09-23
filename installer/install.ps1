# 卡提聊天助手 · 安装脚本（由安装程序调用）
param(
  [string]$Src = $PSScriptRoot,
  [string]$PkgDir = '',
  [switch]$NoStart
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# 容错：%~dp0 以反斜杠结尾会转义掉引号，这里清掉多余引号与结尾反斜杠
if ($Src) { $Src = $Src.Trim().Trim('"').TrimEnd('\') }
if ($PkgDir) { $PkgDir = $PkgDir.Trim().Trim('"').TrimEnd('\') }
if (-not $Src) { $Src = $PSScriptRoot }

$target   = Join-Path $env:LOCALAPPDATA 'KatiChat'
$appDir   = Join-Path $target 'app'
$runDir   = Join-Path $target 'runtime'
$modelDir = Join-Path $target 'models'
$logDir   = Join-Path $target 'logs'
New-Item -ItemType Directory -Force -Path $target, $logDir | Out-Null
$logFile = Join-Path $logDir 'install.log'

function Log([string]$m, [string]$color = 'Gray') {
  $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  Add-Content -Path $logFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
  Write-Host "  $m" -ForegroundColor $color
}

Write-Host ''
Write-Host '  ==================================================' -ForegroundColor Cyan
Write-Host '            卡提聊天助手 · 安装程序' -ForegroundColor Cyan
Write-Host '  ==================================================' -ForegroundColor Cyan
Write-Host ''
Log "安装目录: $target"

# ---------- 1. 停止正在运行的旧实例 ----------
try { Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:7890/api/shutdown' -TimeoutSec 3 | Out-Null; Log '已停止旧的网页服务' } catch { }
Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
# 结束旧的托盘后台：只按它自己写的 PID 文件精确清理（绝不扫描命令行，避免误杀其它进程）
$oldPidFile = Join-Path $logDir 'tray.pid'
if (Test-Path $oldPidFile) {
  $oldPid = (Get-Content $oldPidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
  if ($oldPid) { Stop-Process -Id ([int]$oldPid) -Force -ErrorAction SilentlyContinue; Log "已停止旧托盘 (PID $oldPid)" }
}
Start-Sleep -Milliseconds 900

# ---------- 2. 解包程序文件 ----------
$zip = Join-Path $Src 'payload.zip'
if (-not (Test-Path $zip)) { $zip = Join-Path $Src 'payload2.zip' }
if (-not (Test-Path $zip)) { Log "找不到负载文件 payload.zip: $zip" 'Red'; exit 1 }
Log '正在解压程序文件…'
Remove-Item $appDir, $runDir -Recurse -Force -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem
try {
  [IO.Compression.ZipFile]::ExtractToDirectory($zip, $target)
} catch {
  Log "解压失败: $($_.Exception.Message)" 'Red'; exit 1
}
Log '程序文件就绪（含内置 Node 运行时与 llama.cpp）' 'Green'

# ---------- 3. 模型文件 ----------
$modelFiles = @('Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf', 'mmproj-Qwen2.5-VL-7B-Instruct-f16.gguf')
New-Item -ItemType Directory -Force -Path $modelDir | Out-Null

function Test-ModelDir([string]$dir) {
  if (-not $dir -or -not (Test-Path $dir)) { return $false }
  foreach ($f in $modelFiles) { if (-not (Test-Path (Join-Path $dir $f))) { return $false } }
  return $true
}
function Test-ModelsInstalled {
  foreach ($f in $modelFiles) {
    $p = Join-Path $modelDir $f
    if (-not (Test-Path $p)) { return $false }
    if ((Get-Item $p).Length -lt 100MB) { return $false }
  }
  return $true
}

if (Test-ModelsInstalled) {
  Log '模型文件已存在，跳过复制' 'Green'
} else {
  $cands = @(
    (Join-Path $PkgDir 'models'),
    (Join-Path $Src 'models'),
    $env:KATI_MODELS,
    'F:\aiworking\卡提聊天助手_安装包\models',
    'F:\aiworking\whale-translator\models',
    (Join-Path $env:USERPROFILE 'Downloads\KatiChat-models')
  ) | Where-Object { $_ }
  $found = $null
  foreach ($c in $cands) { if (Test-ModelDir $c) { $found = $c; break } }

  if (-not $found) {
    Add-Type -AssemblyName System.Windows.Forms
    Log '未自动找到模型文件，请在弹出的窗口中选择模型文件夹（取消则改为联网下载）' 'Yellow'
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '请选择包含两个 .gguf 模型的文件夹（可取消 → 联网下载）'
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK -and (Test-ModelDir $dlg.SelectedPath)) {
      $found = $dlg.SelectedPath
    }
  }

  if ($found) {
    Log "从本地复制模型（约 5.6GB，请稍候）: $found"
    foreach ($f in $modelFiles) {
      $dst = Join-Path $modelDir $f
      $s = Join-Path $found $f
      if ((Test-Path $dst) -and ((Get-Item $dst).Length -eq (Get-Item $s).Length)) { Log "  $f 已存在，跳过"; continue }
      Log "  复制 $f …"
      Copy-Item $s $dst -Force
    }
    Log '模型就绪' 'Green'
  } else {
    Log '开始从 ModelScope 联网下载模型（约 5.6GB，25MB/s 时约 4 分钟）…' 'Yellow'
    $base = 'https://modelscope.cn/models/ggml-org/Qwen2.5-VL-7B-Instruct-GGUF/resolve/master'
    foreach ($f in $modelFiles) {
      $dst = Join-Path $modelDir $f
      Log "  下载 $f …"
      & curl.exe -sS -L --retry 3 --retry-delay 2 -o $dst "$base/$f"
      if ((Test-Path $dst) -and (Get-Item $dst).Length -gt 100MB) { Log "  $f 完成" 'Green' }
      else { Log "  $f 下载失败，请检查网络后重新运行安装程序" 'Red' }
    }
  }
}

# ---------- 4. 快捷方式 ----------
$launcher = Join-Path $appDir 'launch.ps1'
$icon = Join-Path $appDir 'assets\whale-v2.ico'
$args = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcher`""
$ws = New-Object -ComObject WScript.Shell
$desktop = [Environment]::GetFolderPath('Desktop')
$lnkPath = Join-Path $desktop '卡提聊天助手.lnk'
$lnk = $ws.CreateShortcut($lnkPath)
$lnk.TargetPath = 'powershell.exe'
$lnk.Arguments = $args
$lnk.WorkingDirectory = $appDir
$lnk.IconLocation = "$icon,0"
$lnk.Description = '卡提聊天助手 · 本地 AI 翻译与聊天（GPU 加速）'
$lnk.Save()
Log "桌面快捷方式已创建" 'Green'

$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\卡提聊天助手.lnk'
$lnk2 = $ws.CreateShortcut($startMenu)
$lnk2.TargetPath = 'powershell.exe'
$lnk2.Arguments = $args
$lnk2.WorkingDirectory = $appDir
$lnk2.IconLocation = "$icon,0"
$lnk2.Description = $lnk.Description
$lnk2.Save()
Log '开始菜单快捷方式已创建' 'Green'

# ---------- 5. 卸载程序 + 注册表登记 ----------
$unPs1 = Join-Path $target '卸载.ps1'
$unCmd = Join-Path $target '卸载.cmd'
$uninstallBody = @'
# 卸载 卡提聊天助手
$t = $PSScriptRoot
Write-Host ''
Write-Host '  正在卸载 卡提聊天助手…' -ForegroundColor Yellow
try { Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:7890/api/shutdown' -TimeoutSec 3 | Out-Null } catch {}
Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Content (Join-Path $t 'logs\tray.pid') -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id ([int]$_) -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 600
Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop')) '卡提聊天助手.lnk') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\卡提聊天助手.lnk') -Force -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\KatiChat' -Recurse -Force -ErrorAction SilentlyContinue
Start-Process cmd.exe -ArgumentList '/c', ('timeout /t 2 >nul & rmdir /s /q "' + $t + '"') -WindowStyle Hidden
Write-Host '  已卸载完成（窗口几秒后自动关闭）' -ForegroundColor Green
'@
[IO.File]::WriteAllText($unPs1, $uninstallBody, (New-Object Text.UTF8Encoding($true)))
$cmdBody = "@echo off`r`nchcp 65001 >nul`r`ntitle 卸载 卡提聊天助手`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0卸载.ps1`"`r`ntimeout /t 4 >nul`r`n"
[IO.File]::WriteAllText($unCmd, $cmdBody, [Text.Encoding]::GetEncoding(936))

$reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\KatiChat'
New-Item -Path $reg -Force | Out-Null
Set-ItemProperty $reg DisplayName '卡提聊天助手'
Set-ItemProperty $reg DisplayVersion '1.0.0'
Set-ItemProperty $reg Publisher 'KatiChat'
Set-ItemProperty $reg DisplayIcon "$icon,0"
Set-ItemProperty $reg UninstallString "`"$unCmd`""
Set-ItemProperty $reg InstallLocation $target
Set-ItemProperty $reg NoModify 1 -Type DWord
Set-ItemProperty $reg NoRepair 1 -Type DWord
Log '已在「应用和功能」中登记（可一键卸载）' 'Green'

# ---------- 6. 启动 ----------
if (-not $NoStart) {
  Log '正在启动卡提聊天助手…'
  Start-Process powershell -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $launcher
}

Log ''
Log '安装完成！桌面已生成「卡提聊天助手」快捷方式，双击即可使用。' 'Cyan'
Log "程序目录: $target"
Log "安装日志: $logFile"
exit 0
