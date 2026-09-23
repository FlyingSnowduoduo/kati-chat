# 卡提聊天助手 · 一键启动脚本
$ErrorActionPreference = 'Continue'

# 目录解析：安装版布局为 <KatiChat>\app\（程序）+ <KatiChat>\models、\runtime、\logs
# 开发版布局为 <项目目录>\（程序与 models 同级）
$appDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = $appDir
if ((Split-Path -Leaf $appDir) -eq 'app') { $root = Split-Path -Parent $appDir }

$logDir = Join-Path $root 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir 'launch.log'

function Log([string]$msg) {
  $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  Add-Content -Path $logFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}

# 运行时：优先使用安装目录自带的，否则退回系统已装的位置（兼容开发目录）
$llamaExe = Join-Path $root 'runtime\llama\llama-server.exe'
if (-not (Test-Path $llamaExe)) { $llamaExe = 'C:\aiuse\llama-b11100-bin-win-vulkan-x64\llama-server.exe' }
$nodeExe = Join-Path $root 'runtime\node.exe'
if (-not (Test-Path $nodeExe)) { $nodeExe = 'C:\Program Files\nodejs\node.exe' }
if (-not (Test-Path $nodeExe)) { $nodeExe = 'node' }

$llamaModel  = Join-Path $root 'models\Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf'
$llamaMmproj = Join-Path $root 'models\mmproj-Qwen2.5-VL-7B-Instruct-f16.gguf'

$llamaApi = 'http://127.0.0.1:8080'
$appUrl   = 'http://127.0.0.1:7890'
$openUrl  = 'http://127.0.0.1:7890/?v=6'

function Gpu-Up() {
  try { $r = Invoke-RestMethod "$llamaApi/health" -TimeoutSec 2; return ($r.status -eq 'ok') } catch { return $false }
}

# 优先用 Edge/Chrome 的 --app 模式打开：独立窗口、无标签页、每次双击都是全新窗口
function Open-App([string]$url) {
  $browsers = @(
    'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
    'C:\Program Files\Google\Chrome\Application\chrome.exe',
    'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe'
  )
  foreach ($exe in $browsers) {
    if (Test-Path $exe) {
      try {
        Start-Process -FilePath $exe -ArgumentList "--app=$url", '--window-size=1120,880', '--no-first-run', '--no-default-browser-check'
        Log "已用独立应用窗口打开: $exe"
        return $true
      } catch {
        Log "应用窗口打开失败: $exe - $($_.Exception.Message)"
      }
    }
  }
  try { Start-Process $url; Log '已用默认浏览器打开'; return $true } catch { }
  try { Start-Process 'cmd.exe' -ArgumentList '/c','start','',"$url" -WindowStyle Hidden; Log '已用 cmd start 打开'; return $true } catch { }
  return $false
}

Log '=== 启动请求 ==='

# ---------- 1) 本地网页服务 ----------
$webUp = $false
try { Invoke-RestMethod "$appUrl/api/health" -TimeoutSec 2 | Out-Null; $webUp = $true; Log '网页服务已在运行' } catch {}
if (-not $webUp) {
  Log '启动网页服务 (node server.mjs)'
  try {
    Start-Process -FilePath $nodeExe -ArgumentList 'server.mjs' -WorkingDirectory $appDir -WindowStyle Hidden `
      -RedirectStandardOutput (Join-Path $logDir 'server.out.log') `
      -RedirectStandardError (Join-Path $logDir 'server.err.log')
  } catch {
    Start-Process -FilePath $nodeExe -ArgumentList 'server.mjs' -WorkingDirectory $appDir -WindowStyle Hidden
  }
  for ($i = 0; $i -lt 40 -and -not $webUp; $i++) {
    Start-Sleep -Milliseconds 300
    try { Invoke-RestMethod "$appUrl/api/health" -TimeoutSec 2 | Out-Null; $webUp = $true } catch {}
  }
}
Log "网页服务可用: $webUp"

# ---------- 2) 打开界面窗口 ----------
$opened = Open-App $openUrl
Log "打开界面: $opened  URL: $openUrl"

# ---------- 3) GPU 推理后端（llama.cpp + Vulkan） ----------
$gpuReady = $false
if ((Test-Path $llamaExe) -and (Test-Path $llamaModel) -and (Test-Path $llamaMmproj)) {
  if (-not (Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue)) {
    Log '启动 GPU 推理服务 (llama.cpp + Vulkan)'
    $args = @(
      '-m', $llamaModel,
      '--mmproj', $llamaMmproj,
      '-ngl', '99',
      '-c', '4096',
      '-b', '1024', '-ub', '512',
      '--host', '127.0.0.1', '--port', '8080',
      '--no-webui', '--jinja'
    )
    try {
      Start-Process -FilePath $llamaExe -ArgumentList $args -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $logDir 'llama.out.log') `
        -RedirectStandardError (Join-Path $logDir 'llama.err.log')
    } catch {
      Log "llama-server 启动失败: $($_.Exception.Message)"
    }
  } else {
    Log 'GPU 推理服务已在运行'
  }
  for ($i = 0; $i -lt 60 -and -not $gpuReady; $i++) {
    Start-Sleep -Seconds 1
    $gpuReady = Gpu-Up
  }
  Log "GPU 后端就绪: $gpuReady"
} else {
  Log '缺少 llama.cpp 或模型文件，无法启动 GPU 后端'
}

# ---------- 4) 托盘后台 + 全局热键（右 Alt + 回车 呼出快速输入） ----------
$trayPidFile = Join-Path $logDir 'tray.pid'
$trayRunning = $false
if (Test-Path $trayPidFile) {
  $tp = (Get-Content $trayPidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
  if ($tp -and (Get-Process -Id ([int]$tp) -ErrorAction SilentlyContinue)) { $trayRunning = $true }
}
if (-not $trayRunning) {
  Log '启动托盘后台（含右Alt+回车热键）'
  Start-Process powershell -ArgumentList '-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File', (Join-Path $appDir 'tray.ps1') -WindowStyle Hidden
} else {
  Log '托盘后台已在运行'
}

# ---------- 5) 启动失败时给出明确提示（不再自动下载模型） ----------
if (-not $gpuReady) {
  Log 'GPU 后端未就绪，弹出提示窗口'
  $hint = "Write-Host ''; Write-Host '  GPU 推理服务未能启动' -ForegroundColor Yellow; Write-Host ''; Write-Host '  排查：'; Write-Host '   日志: $logDir\llama.err.log'; Write-Host '   模型: $llamaModel'; Write-Host '   程序: $llamaExe'; Write-Host ''; Read-Host '按回车退出'"
  Start-Process powershell -ArgumentList '-NoProfile','-Command',$hint
}

# ---------- 6) 兜底提示 ----------
if (-not $opened) {
  Start-Process powershell -ArgumentList '-NoProfile','-Command',"Write-Host '请手动在浏览器中打开：$openUrl'; Read-Host '按回车退出'"
}
Log '=== 启动流程结束 ==='
exit 0
