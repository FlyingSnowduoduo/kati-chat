# 卡提聊天助手 · 托盘后台 + 全局热键（右 Alt + 回车 呼出快速输入）
$ErrorActionPreference = 'Continue'
# 安装版布局：程序在 <KatiChat>\app\，日志统一放 <KatiChat>\logs
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = $scriptDir
if ((Split-Path -Leaf $scriptDir) -eq 'app') { $root = Split-Path -Parent $scriptDir }
$logDir = Join-Path $root 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir 'tray.log'
$pidFile = Join-Path $logDir 'tray.pid'

function Log([string]$m) {
  Add-Content -Path $logFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 -ErrorAction SilentlyContinue
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$src = @"
using System;
using System.Runtime.InteropServices;

public class KatiHook {
  private const int WH_KEYBOARD_LL = 13;
  private const int WM_KEYDOWN = 0x0100, WM_SYSKEYDOWN = 0x0104;
  private const int VK_RMENU = 0xA5, VK_RETURN = 0x0D;
  private delegate IntPtr Proc(int nCode, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", SetLastError=true)] private static extern IntPtr SetWindowsHookEx(int idHook, Proc lpfn, IntPtr hMod, uint tid);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool UnhookWindowsHookEx(IntPtr hhk);
  [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
  [DllImport("kernel32.dll")] private static extern IntPtr GetModuleHandle(string name);
  [StructLayout(LayoutKind.Sequential)] private struct KB { public uint vk; public uint scan; public uint flags; public uint time; public IntPtr extra; }
  private static IntPtr hook = IntPtr.Zero;
  private static Proc proc = Callback;
  private static bool ralt = false;
  public static volatile bool Triggered = false;
  public static bool Install() { hook = SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(null), 0); return hook != IntPtr.Zero; }
  public static void Uninstall() { if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; } }
  private static IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam) {
    if (nCode >= 0) {
      KB k = (KB)Marshal.PtrToStructure(lParam, typeof(KB));
      int msg = wParam.ToInt32();
      if (k.vk == VK_RMENU) { ralt = (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN); }
      if (k.vk == VK_RETURN && ralt && (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN)) { Triggered = true; return (IntPtr)1; }
    }
    return CallNextHookEx(hook, nCode, wParam, lParam);
  }
}

public class KatiWin {
  private delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  public static readonly IntPtr TOPMOST = new IntPtr(-1);
  public static IntPtr Found = IntPtr.Zero;
  public static IntPtr FindByTitle(string needle) {
    Found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      System.Text.StringBuilder sb = new System.Text.StringBuilder(512);
      GetWindowTextW(h, sb, 512);
      string t = sb.ToString();
      if (t.Length > 0 && t.Contains(needle)) { Found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return Found;
  }
  public static void TopMost(IntPtr h) { SetWindowPos(h, TOPMOST, 0, 0, 0, 0, 0x0003); }
  public static void Focus(IntPtr h) { ShowWindow(h, 5); SetForegroundWindow(h); }
}
"@
Add-Type -TypeDefinition $src

$edge = @(
  'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
  'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
  'C:\Program Files\Google\Chrome\Application\chrome.exe',
  'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1

$mainUrl = 'http://127.0.0.1:7890/?v=6'
$quickUrl = 'http://127.0.0.1:7890/quick.html'
$quickTitle = '卡提 · 快速输入'
$iconPath = Join-Path $scriptDir 'assets\whale-v2.ico'

function Open-Main {
  Log '打开主界面'
  $h = [KatiWin]::FindByTitle('卡提聊天助手')
  if ($h -ne [IntPtr]::Zero -and [KatiWin]::IsWindow($h)) {
    [KatiWin]::Focus($h); Log '主窗口已存在 → 聚焦'; return
  }
  if ($edge) { Start-Process -FilePath $edge -ArgumentList "--app=$mainUrl", '--window-size=1120,880', '--no-first-run', '--no-default-browser-check' }
  else { Start-Process $mainUrl }
}

function Open-Quick {
  $h = [KatiWin]::FindByTitle($quickTitle)
  if ($h -ne [IntPtr]::Zero -and [KatiWin]::IsWindow($h)) {
    [KatiWin]::TopMost($h); [KatiWin]::Focus($h)
    Log '快速窗口已存在 → 置顶聚焦'
    return
  }
  $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $w = 800; $ht = 460
  $x = [int](($b.Width - $w) / 2)
  $y = [int]($b.Height * 0.24)
  if ($edge) {
    Start-Process -FilePath $edge -ArgumentList "--app=$quickUrl", "--window-size=$w,$ht", "--window-position=$x,$y", '--no-first-run', '--no-default-browser-check'
  } else {
    Start-Process $quickUrl
  }
  Log "呼出快速窗口 ($x,$y)"
  Start-Sleep -Milliseconds 1800
  $h2 = [KatiWin]::FindWindow($null, $quickTitle)
  if ($h2 -ne [IntPtr]::Zero) { [KatiWin]::TopMost($h2); [KatiWin]::Focus($h2) }
}

function Stop-App {
  Log '停止服务'
  try { Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:7890/api/shutdown' -TimeoutSec 5 | Out-Null } catch { }
  Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

# ---------- 托盘图标 ----------
$notify = New-Object System.Windows.Forms.NotifyIcon
try { $notify.Icon = New-Object System.Drawing.Icon($iconPath) } catch { $notify.Icon = [System.Drawing.SystemIcons]::Application }
$notify.Text = '卡提聊天助手（双击打开）'
$notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$null = $menu.Items.Add('打开聊天窗口').add_Click({ Open-Main })
$null = $menu.Items.Add('快速输入（右Alt+回车）').add_Click({ Open-Quick })
$null = $menu.Items.Add('-')
$null = $menu.Items.Add('停止后台服务').add_Click({ Stop-App })
$null = $menu.Items.Add('退出后台').add_Click({
  Log '退出后台'
  [KatiHook]::Uninstall()
  $notify.Visible = $false
  $notify.Dispose()
  Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
  [System.Windows.Forms.Application]::ExitThread()
})
$notify.ContextMenuStrip = $menu
$notify.add_MouseDoubleClick({ Open-Main })
$notify.add_MouseClick({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Open-Main } })

# ---------- 全局热键：右 Alt + 回车 ----------
$installed = [KatiHook]::Install()
Log "键盘钩子安装: $installed"

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 120
$timer.add_Tick({ if ([KatiHook]::Triggered) { [KatiHook]::Triggered = $false; Open-Quick } })
$timer.Start()

Set-Content -Path $pidFile -Value $PID -Encoding ASCII
Log "托盘已启动 PID=$PID"

[System.Windows.Forms.Application]::Run()

# 退出清理
[KatiHook]::Uninstall()
Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
Log '托盘已退出'
