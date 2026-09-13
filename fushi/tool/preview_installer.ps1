<#
.SYNOPSIS
    编译 Windows 安装器并逐页抓真实像素，用来验证外观改动。全程离屏后台。

.DESCRIPTION
    改 fushi.iss 的外观时，唯一靠得住的验收方式就是把安装器编出来、真跑一遍、看像素。
    本脚本把这条闭环压到几秒：编译 ~0.6s + 每页约 1.5s。

    **全程不打扰**：窗口一出现就被挪到屏幕外，翻页走 BM_CLICK 消息注入，截图走
    PrintWindow。不抢前台、不动鼠标、不在屏幕上露面，跑的时候可以照常用电脑。

    编译的是仓库里的 fushi.iss 本体，只额外打几个**仅预览用**的补丁（换 AppId、换
    目标目录等，见下面各开关）。未指定 -Install 时，staged copy 还会跳过关闭真实
    Fushi 的初始化流程、清空 AppMutex，并在准备安装页阻止继续，避免占位文件被安装。
    每个补丁都当场核对是否命中，不会出现「开关没生效却一路编译成功」的静默失败。

.PARAMETER Pages
    抓几页。翻页按「下一步 / Next」；-Install 时才会按「安装 / 完成」真的执行安装。

.PARAMETER CompileOnly
    仅编译，返回 SetupExe / StageDir / InstallDir，不启动安装器、不自动操作 UI 或截图，
    也不清理预览安装目录。便于交给独立的可见 UI 验证工具检查。

.PARAMETER Install
    显式保留安装器原有的应用关闭和安装流程，允许安装占位 payload；不受外观预览保护。

.PARAMETER ForceFreshInstall
    让 IsFreshInstall 恒真，好让「选择数据存储位置」页出现 —— 那页只在全新安装时
    显示，本机 %APPDATA%\Fushi 存在就会被 ShouldSkipPage 跳过。

.PARAMETER SkipDirPage
    禁掉「选择目标位置」页，让它后面的自定义页成为第一页。用于单独盯某一页。

.PARAMETER StyleOverride
    覆盖 [Setup] 的 WizardStyle 整行，用来对比 Inno 内置样式
    （polar / slate / zircon / windows11），或强制明暗：
        -StyleOverride 'modern light windows11 hidebevels'

.PARAMETER RealScreen
    改用「置顶 + CopyFromScreen」抓真实屏幕，而不是离屏 PrintWindow。
    只在验**标题栏**时需要：标题栏由 DWM 画、属于非客户区，PrintWindow 抓不准。
    这个模式会短暂置顶窗口。客户区的验证一律用默认的离屏模式。

.EXAMPLE
    pwsh -File fushi/tool/preview_installer.ps1 -CompileOnly -Tag 0.0.0 -ForceFreshInstall
    pwsh -File fushi/tool/preview_installer.ps1 -Pages 4 -ForceFreshInstall
    pwsh -File fushi/tool/preview_installer.ps1 -StyleOverride 'modern light windows11 hidebevels'
    pwsh -File fushi/tool/preview_installer.ps1 -RealScreen -Pages 1   # 验标题栏配色
#>
[CmdletBinding()]
param(
  [int]$Pages = 4,
  [string]$Tag = 'preview',
  [string]$OutDir = "$env:TEMP\fushi-installer-preview",
  [string]$Iss,
  [string]$StyleOverride = '',
  [switch]$ForceFreshInstall,
  [switch]$SkipDirPage,
  [switch]$Install,
  [switch]$CompileOnly,
  [switch]$RealScreen
)
$ErrorActionPreference = 'Stop'

if (-not $Iss) {
  $Iss = Join-Path (Split-Path $PSScriptRoot -Parent) 'windows\installer\fushi.iss'
}
if (-not (Test-Path -LiteralPath $Iss)) { throw "找不到 iss：$Iss" }

$iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
if (-not (Test-Path -LiteralPath $iscc)) {
  throw @"
找不到 ISCC：$iscc
安装器外观要 Inno Setup 6.6+（StyleElements / IsDarkInstallMode 是 6.6 加的）。
CI 钉的是 6.7.3，本地装同一版即可：
  https://github.com/jrsoftware/issrc/releases/download/is-6_7_3/innosetup-6.7.3.exe
  SHA-256 9C73C3BAE7ED48D44112A0F48E66742C00090BDB5BEF71D9D3C056C66E97B732
"@
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
# 必须绝对化：ISCC 把 /DSourceDir 里的相对路径按 **iss 文件所在目录**解析，而 iss 被
# stage 到了 $OutDir 下面，于是相对的 -OutDir 会被拼成
# <stage>\installer\<相对OutDir>\payload 这种不存在的路径，报 "No files found matching"。
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$Iss = (Resolve-Path -LiteralPath $Iss).Path

# 删除前既检查绝对路径归属，也拒绝目录联接/符号链接，避免递归清理越出预览目录。
function Assert-PreviewChildPath([string]$Path, [string]$Root) {
  $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
  $childPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
  if (-not $childPath.StartsWith($rootPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "预览清理路径必须位于 $rootPath 内：$childPath"
  }
  $currentPath = $childPath
  while ($true) {
    if (Test-Path -LiteralPath $currentPath) {
      $item = Get-Item -LiteralPath $currentPath -Force
      if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "预览清理路径不允许目录联接或符号链接：$currentPath"
      }
    }
    if ($currentPath.TrimEnd('\', '/').Equals($rootPath, [StringComparison]::OrdinalIgnoreCase)) { break }
    $currentPath = Split-Path -Path $currentPath -Parent
  }
  return $childPath
}

# 一个输出目录对应一个稳定的安装身份；深浅色等并行预览不会复用彼此的安装记录。
$sha256 = [System.Security.Cryptography.SHA256]::Create()
try {
  $pathBytes = [System.Text.Encoding]::UTF8.GetBytes($OutDir.ToUpperInvariant())
  $identityHash = [BitConverter]::ToString($sha256.ComputeHash($pathBytes)).Replace('-', '')
} finally {
  $sha256.Dispose()
}
$previewKey = $identityHash.Substring(0, 16).ToLowerInvariant()
$previewAppId = '{0}-{1}-{2}-{3}-{4}' -f $identityHash.Substring(0, 8),
  $identityHash.Substring(8, 4), $identityHash.Substring(12, 4),
  $identityHash.Substring(16, 4), $identityHash.Substring(20, 12)
$previewRoot = Join-Path $env:LOCALAPPDATA 'FushiInstallerPreviews'
$previewDir = Assert-PreviewChildPath (Join-Path $previewRoot $previewKey) $previewRoot

# ── 1. 占位 payload ────────────────────────────────────────────────────────────
# 外观验证不需要真的 500MB 产物，给 [Files] 几个占位文件就够。
$src = Join-Path $OutDir 'payload'
if (-not (Test-Path "$src\fushi.exe")) {
  New-Item -ItemType Directory -Force -Path "$src\data" | Out-Null
  'placeholder' | Set-Content "$src\fushi.exe"
  'placeholder' | Set-Content "$src\fushi_update_launcher.exe"
  'placeholder' | Set-Content "$src\data\app.so"
}

# ── 2. stage：照搬仓库的目录层级 ───────────────────────────────────────────────
# iss 里既引用 assets\...（同级），也引用 ..\runner\resources\app_icon.ico（上跳一级），
# 把 iss 平铺到临时目录根下会让 SetupIconFile 那条编译失败「系统找不到指定的路径」。
$stageRoot = Assert-PreviewChildPath (Join-Path $OutDir 'stage') $OutDir
$stage = Join-Path $stageRoot 'installer'
if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Copy-Item -Recurse -Force (Join-Path (Split-Path $Iss) '*') $stage
$runnerSrc = Join-Path (Split-Path (Split-Path $Iss)) 'runner\resources'
if (Test-Path $runnerSrc) {
  $runnerDst = Join-Path $stageRoot 'runner\resources'
  New-Item -ItemType Directory -Force -Path $runnerDst | Out-Null
  Copy-Item -Recurse -Force (Join-Path $runnerSrc '*') $runnerDst
}

$stagedIss = Join-Path $stage (Split-Path $Iss -Leaf)
$text = Get-Content -LiteralPath $stagedIss -Raw -Encoding UTF8

# ── 3. 仅预览用的补丁 ──────────────────────────────────────────────────────────
# AppId：本机装着真 Fushi，同 AppId 下 Inno 认出已有安装、UsePreviousAppDir 生效，
# 会直接跳过「选择目标位置」页；换个测试 GUID 才能看到全部页，也不碰真实卸载键。
$appIdSetting = "AppId={{$previewAppId}}"
$text = $text -replace '(?m)^AppId=\{\{[^}]+\}\}', $appIdSetting

# 目标目录：默认的 {localappdata}\Fushi 在开发机上已经装着真 Fushi，点「下一步」会弹
# 「文件夹已存在」的模态框把翻页拦住 —— 而 PrintWindow 只画主窗口、看不见那个框，
# 现象就是「点了但页面不动」，极难判断。
$defaultDirSetting = "DefaultDirName={localappdata}\FushiInstallerPreviews\$previewKey"
$text = $text -replace '(?m)^DefaultDirName=.*$', $defaultDirSetting

if (-not $Install) {
  # 这些保护只注入 staged copy；production iss 的更新/安装行为保持原样。
  $mutexPattern = [regex]'(?m)^AppMutex=[^\r\n]*(?=\r?$)'
  if ($mutexPattern.Matches($text).Count -ne 1) { throw 'AppMutex 预览补丁必须命中一处' }
  $text = $mutexPattern.Replace($text, 'AppMutex=')

  # 只接受精确的函数签名、可选的本地 var 声明以及该函数自己的 begin。
  # 保留 var 块，且不使用跨函数的 .*?，避免误把保护插进后续嵌套 begin。
  $previewGuards = @(
    @{
      Signature = 'function InitializeSetup(): Boolean;'
      Body = "  { Appearance preview: do not close a running Fushi. }`r`n  Result := True;`r`n  Exit;"
    },
    @{
      Signature = 'function NextButtonClick(CurPageID: Integer): Boolean;'
      Body = "  { Appearance preview: the payload contains placeholders only. }`r`n  if CurPageID = wpReady then`r`n  begin`r`n    Result := False;`r`n    MsgBox('这是外观预览，不包含安装文件。', mbInformation, MB_OK);`r`n    Exit;`r`n  end;"
    }
  )
  foreach ($guard in $previewGuards) {
    $functionPattern = [regex]('(?m)^(' + [regex]::Escape($guard.Signature) +
      '\r?\n(?:var\r?\n(?:[ \t]+[A-Za-z_][A-Za-z0-9_, ]*:[^\r\n]+;\r?\n)+)?begin)(?=\r?$)')
    if ($functionPattern.Matches($text).Count -ne 1) {
      throw "预览保护必须精确定位一处函数 begin：$($guard.Signature)"
    }
    $text = $functionPattern.Replace($text, ('$1' + "`r`n" + $guard.Body), 1)
  }
}

if ($SkipDirPage) {
  $text = $text -replace '(?m)^PrivilegesRequired=lowest\r?$', "PrivilegesRequired=lowest`r`nDisableDirPage=yes"
}
if ($ForceFreshInstall) {
  # 文件是 CRLF，pattern 里必须 \r?\n；写字面换行会匹配不到（踩过：补丁静默不生效，
  # 但编译照样成功，白截了好几轮图）。
  $text = $text -replace '(?s)function IsFreshInstall\(\): Boolean;\r?\n\s*begin.*?\r?\nend;',
    "function IsFreshInstall(): Boolean;`r`nbegin`r`n  Result := True;`r`nend;"
}
if ($StyleOverride) {
  $text = $text -replace '(?m)^WizardStyle=.*$', "WizardStyle=$StyleOverride"
}
Set-Content -LiteralPath $stagedIss -Value $text -Encoding UTF8 -NoNewline

# 每个补丁都当场核对，杜绝「开关没生效但一路编译成功」。
if ($text -notmatch [regex]::Escape($appIdSetting)) { throw 'AppId 隔离补丁未命中' }
if ($text -notmatch [regex]::Escape($defaultDirSetting)) { throw 'DefaultDirName 隔离补丁未命中' }
if ($SkipDirPage -and ($text -notmatch 'DisableDirPage=yes')) { throw 'SkipDirPage 补丁未命中' }
if ($ForceFreshInstall -and ($text -notmatch 'Result := True;')) { throw 'ForceFreshInstall 补丁未命中' }
if ($StyleOverride -and ($text -notmatch [regex]::Escape($StyleOverride))) { throw 'StyleOverride 补丁未命中' }

# ── 4. 编译 ───────────────────────────────────────────────────────────────────
& $iscc "/DAppVersion=$Tag" "/DSourceDir=$src" "/DOutputDir=$OutDir" $stagedIss 2>&1 |
  Where-Object { $_ -match 'Error|Warning|Successful compile' }
if ($LASTEXITCODE -ne 0) { throw "ISCC 失败，退出码 $LASTEXITCODE" }
$setupExe = Join-Path $OutDir "fushi-$Tag-windows-setup.exe"
if (-not (Test-Path -LiteralPath $setupExe)) { throw "编译后未找到预览安装器：$setupExe" }
if ($CompileOnly) {
  [pscustomobject]@{
    SetupExe = $setupExe
    StageDir = $stage
    InstallDir = $previewDir
    AppId = $previewAppId
  }
  return
}

# 只有即将运行预览时才清理目标目录，纯编译不会影响已安装的预览。
$previewDir = Assert-PreviewChildPath $previewDir $previewRoot
if (Test-Path -LiteralPath $previewDir) { Remove-Item -LiteralPath $previewDir -Recurse -Force }

# ── 5. 跑起来逐页抓图 ─────────────────────────────────────────────────────────
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class FushiPreviewNative {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, Cb c, IntPtr l);
  // CharSet.Unicode 一个都不能漏：这两个 API 写的是宽字符，按默认 ANSI marshal 会把
  // "TNewButton" 读成 "T"、"&Next" 读成 "&"，于是**一个按钮都找不到**。当初正是栽在
  // 这里，误判成「VCL 不吃消息注入」，绕道去做抢鼠标的真实点击。
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr h);
  public struct R { public int L, T, Rt, B; }
  delegate bool Cb(IntPtr h, IntPtr l);

  // 枚举整个留在 C# 里：PowerShell 的 scriptblock 转委托在这里静默失效，
  // 回调根本不触发，一个子窗口都拿不到。
  public static IntPtr FindButton(IntPtr parent, string pattern) {
    IntPtr found = IntPtr.Zero;
    EnumChildWindows(parent, delegate(IntPtr h, IntPtr l) {
      var cls = new StringBuilder(256); GetClassNameW(h, cls, 256);
      if (cls.ToString().IndexOf("Button", StringComparison.OrdinalIgnoreCase) < 0) return true;
      if (!IsWindowVisible(h) || !IsWindowEnabled(h)) return true;
      var txt = new StringBuilder(256); GetWindowTextW(h, txt, 256);
      if (txt.ToString().Replace("&", "").IndexOf(pattern, StringComparison.OrdinalIgnoreCase) >= 0) {
        found = h; return false;
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
"@
# PER_MONITOR_AWARE_V2 = -4。必须赶在读任何窗口坐标之前：进程不是 DPI aware 时
# GetWindowRect 给逻辑像素、PrintWindow 却画物理像素，图会被裁掉右下角。
try { [FushiPreviewNative]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null } catch { }

$stem = [System.IO.Path]::GetFileNameWithoutExtension($setupExe)
function Stop-SetupProc {
  Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -like "$stem*" } | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Save-WindowShot([IntPtr]$hwnd, [string]$png, [bool]$useRealScreen) {
  $r = New-Object FushiPreviewNative+R
  [FushiPreviewNative]::GetWindowRect($hwnd, [ref]$r) | Out-Null
  $w = $r.Rt - $r.L; $h = $r.B - $r.T
  $bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  if ($useRealScreen) {
    $g.CopyFromScreen($r.L, $r.T, 0, 0, (New-Object System.Drawing.Size $w, $h))
  } else {
    $hdc = $g.GetHdc()
    [FushiPreviewNative]::PrintWindow($hwnd, $hdc, 2) | Out-Null   # PW_RENDERFULLCONTENT
    $g.ReleaseHdc($hdc)
  }
  $g.Dispose()
  $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}

Stop-SetupProc
Start-Process -FilePath $setupExe | Out-Null

# Inno 的 setup.exe 只是 loader，真正的向导被解压成 <name>.tmp 再启动，
# 窗口属于那个 .tmp 进程，不是 Start-Process 拿到的那个 → 按进程名前缀轮询。
$deadline = (Get-Date).AddSeconds(20)
$proc = $null
while ((Get-Date) -lt $deadline) {
  $proc = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -like "$stem*" -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if ($proc) { break }
  Start-Sleep -Milliseconds 300
}
if (-not $proc) { Stop-SetupProc; throw '向导窗口没出现' }
$hwnd = $proc.MainWindowHandle
Write-Host "窗口：'$($proc.MainWindowTitle)'"

if ($RealScreen) {
  # 真实屏幕模式要能看见窗口：置顶（HWND_TOPMOST=-1，NOMOVE|NOSIZE|SHOWWINDOW=0x43）。
  [FushiPreviewNative]::SetWindowPos($hwnd, [IntPtr](-1), 0, 0, 0, 0, 0x43) | Out-Null
} else {
  # 默认离屏：挪出可视区域，跑测试时它完全不出现在用户眼前。
  # PrintWindow 是让窗口自己画到我们给的 DC，与它在不在屏幕上无关。
  # SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE = 0x0015
  [FushiPreviewNative]::SetWindowPos($hwnd, [IntPtr]::Zero, -4000, -4000, 0, 0, 0x0015) | Out-Null
}
Start-Sleep -Milliseconds 1800

$advance = if ($Install) { @('下一步', 'Next', '安装', 'Install', '完成', 'Finish') }
           else { @('下一步', 'Next') }

$shots = @()
for ($i = 1; $i -le $Pages; $i++) {
  $png = Join-Path $OutDir "$Tag-$i.png"
  Save-WindowShot $hwnd $png $RealScreen.IsPresent
  $shots += $png
  Write-Host "  第 $i 页 -> $png"
  if ($i -eq $Pages) { break }

  $btn = [IntPtr]::Zero
  foreach ($n in $advance) {
    $btn = [FushiPreviewNative]::FindButton($hwnd, $n)
    if ($btn -ne [IntPtr]::Zero) { break }
  }
  if ($btn -eq [IntPtr]::Zero) { Write-Host '  没有可用的前进按钮，停在这页'; break }
  [FushiPreviewNative]::PostMessageW($btn, 0x00F5, [IntPtr]0, [IntPtr]0) | Out-Null   # BM_CLICK
  Start-Sleep -Milliseconds 1500
  $proc.Refresh()
  if ($proc.HasExited) { Write-Host '  向导已退出'; break }
}

Stop-SetupProc
$previewDir = Assert-PreviewChildPath $previewDir $previewRoot
if (Test-Path -LiteralPath $previewDir) { Remove-Item -LiteralPath $previewDir -Recurse -Force }

Write-Host ''
Write-Host "共 $($shots.Count) 张：$OutDir"
