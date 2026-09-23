# 卡提聊天助手 · 发布到 GitHub（使用 REST API，无需安装 git）
#
# 用法：
#   .\发布到GitHub.ps1 -Token ghp_xxxxxxxxxxxx
#   .\发布到GitHub.ps1 -Token ghp_xxx -RepoName kati-chat -Private
#   .\发布到GitHub.ps1 -Token ghp_xxx -SkipRelease        # 不发 Release / 不上传安装程序
#
# 令牌要求：GitHub Classic Token，勾选 repo 权限（用于创建仓库、提交文件、发 Release）
#   创建地址: https://github.com/settings/tokens
param(
  [string]$Token = '',
  [switch]$PromptToken,
  [string]$RepoName = 'kati-chat',
  [string]$Description = '卡提聊天助手 · 本地多模态 AI 助手（图片英文翻译 / 单词词组详解 / 联网搜索，GPU 加速）',
  [switch]$Private,
  [switch]$SkipRelease,
  [string]$AssetPath = 'F:\aiworking\卡提聊天助手_安装包\卡提聊天助手_安装程序.exe',
  [string]$Tag = 'v1.0.0'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# 掩码输入令牌（输入不显示在屏幕上）
if ($PromptToken -or -not $Token) {
  $sec = Read-Host '请粘贴 GitHub 令牌（输入不会显示）' -AsSecureString
  $Token = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}
$Token = "$Token".Trim()
if (-not $Token) { Write-Host '  未提供令牌，已取消。' -ForegroundColor Red; exit 1 }

$repoDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$api = 'https://api.github.com'
$headers = @{
  Authorization          = "Bearer $Token"
  Accept                 = 'application/vnd.github+json'
  'User-Agent'           = 'KatiChat-Publisher'
  'X-GitHub-Api-Version' = '2022-11-28'
}

function Api($method, $path, $body) {
  $params = @{ Method = $method; Uri = "$api$path"; Headers = $headers; TimeoutSec = 60 }
  if ($body) { $params.Body = ($body | ConvertTo-Json -Depth 5); $params.ContentType = 'application/json; charset=utf-8' }
  return Invoke-RestMethod @params
}

Write-Host ''
Write-Host '  ==========================================' -ForegroundColor Cyan
Write-Host '        卡提聊天助手 · 发布到 GitHub' -ForegroundColor Cyan
Write-Host '  ==========================================' -ForegroundColor Cyan
Write-Host ''

# ---------- 1. 校验令牌 ----------
Write-Host '  [1/5] 校验令牌…'
$me = Api 'GET' '/user' $null
$owner = $me.login
Write-Host "        已登录: $owner" -ForegroundColor Green

# ---------- 2. 创建（或复用）仓库 ----------
Write-Host "  [2/5] 创建仓库 $owner/$RepoName …"
$repoUrl = $null
try {
  $repo = Api 'POST' '/user/repos' @{
    name        = $RepoName
    description = $Description
    private     = [bool]$Private
    auto_init   = $false
    has_issues  = $true
    has_wiki    = $false
  }
  $repoUrl = $repo.html_url
  Write-Host "        已创建: $repoUrl" -ForegroundColor Green
} catch {
  $code = $_.Exception.Response.StatusCode.value__
  if ($code -eq 422) {
    $repo = Api 'GET' "/repos/$owner/$RepoName" $null
    $repoUrl = $repo.html_url
    Write-Host "        仓库已存在，将更新内容: $repoUrl" -ForegroundColor Yellow
  } else { throw }

}

# ---------- 3. 上传文件 ----------
Write-Host '  [3/5] 上传文件…'
$skipDirs = @('.git', 'models', 'runtime', 'logs', 'node_modules', '.vscode')
$skipExt = @('.gguf', '.exe', '.zip', '.7z', '.iso')
$skipNames = @('payload.zip', 'Thumbs.db', 'desktop.ini')
$files = Get-ChildItem $repoDir -Recurse -File | Where-Object {
  $rel = $_.FullName.Substring($repoDir.Length + 1)
  $parts = $rel -split '\\'
  $skip = $false
  foreach ($p in $parts) { if ($skipDirs -contains $p) { $skip = $true } }
  if ($skipNames -contains $_.Name) { $skip = $true }
  if ($skipExt -contains $_.Extension.ToLower()) { $skip = $true }
  -not $skip
}

$okCount = 0; $failCount = 0
foreach ($f in $files) {
  $rel = $f.FullName.Substring($repoDir.Length + 1)
  $apiPath = ($rel -split '\\' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
  $content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($f.FullName))
  $body = @{ message = "Add $rel"; content = $content }
  # 已存在则带上 sha 以覆盖
  try {
    $exist = Api 'GET' "/repos/$owner/$RepoName/contents/$apiPath" $null
    if ($exist.sha) { $body.sha = $exist.sha }
  } catch { }
  try {
    Api 'PUT' "/repos/$owner/$RepoName/contents/$apiPath" $body | Out-Null
    $okCount++
    Write-Host "        ✔ $rel"
  } catch {
    $failCount++
    Write-Host "        ✘ $rel —— $($_.Exception.Message)" -ForegroundColor Red
  }
}
Write-Host "        完成: 成功 $okCount 个，失败 $failCount 个" -ForegroundColor Green

# ---------- 4. 创建 Release 并上传安装程序 ----------
if (-not $SkipRelease -and (Test-Path $AssetPath)) {
  Write-Host '  [4/5] 创建 Release 并上传安装程序…'
  $body = @"
## 卡提聊天助手 $Tag

本地运行的多模态 AI 助手：图片英文识别翻译 · 单词词组详解 · 联网搜索 · 悬浮快速输入

### 安装
1. 下载下方 `卡提聊天助手_安装程序.exe`
2. 双击安装（自动配置运行时、复制/下载模型、创建桌面快捷方式）
3. 安装完成即可使用

### 亮点
- 独立显卡（Vulkan）加速：图片翻译约 4～10 秒、文字翻译约 4～5 秒
- 右 Alt + 回车呼出悬浮快速输入窗，托盘常驻后台
- 联网搜索：问"今天/昨天"的事不再答错
- 全部数据在本机运行

> 若未随附模型，安装程序会自动从 ModelScope 下载（约 5.6GB）。
"@
  $release = Api 'POST' "/repos/$owner/$RepoName/releases" @{
    tag_name   = $Tag
    name       = "卡提聊天助手 $Tag"
    body       = $body
    draft      = $false
    prerelease = $false
  }
  Write-Host "        Release: $($release.html_url)"
  $assetName = Split-Path -Leaf $AssetPath
  Write-Host "        上传 $assetName（约 $([math]::Round((Get-Item $AssetPath).Length/1MB,1)) MB，请稍候）…"
  $uploadUrl = "https://uploads.github.com/repos/$owner/$RepoName/releases/$($release.id)/assets?name=$([uri]::EscapeDataString($assetName))"
  $res = curl.exe -sS -X POST `
    -H "Authorization: Bearer $Token" `
    -H 'Content-Type: application/octet-stream' `
    -H 'User-Agent: KatiChat-Publisher' `
    --data-binary "@$AssetPath" $uploadUrl
  if ($res -match '"browser_download_url"') { Write-Host '        安装程序上传完成 ✔' -ForegroundColor Green }
  else { Write-Host "        上传结果: $($res.Substring(0, [Math]::Min(200, $res.Length)))" -ForegroundColor Yellow }
} else {
  Write-Host '  [4/5] 跳过 Release（未指定 -SkipRelease 之外的安装程序文件或已指定跳过）'
}

# ---------- 5. 完成 ----------
Write-Host '  [5/5] 完成！' -ForegroundColor Green
Write-Host ''
Write-Host "  仓库地址: $repoUrl"
Write-Host "  API 地址: $api/repos/$owner/$RepoName"
Write-Host ''
Write-Host '  提示：本机可能无法直接打开 github.com 网页（网络受限），可用手机或代理访问；' -ForegroundColor Yellow
Write-Host '        API 上传不受影响。' -ForegroundColor Yellow
Write-Host ''
