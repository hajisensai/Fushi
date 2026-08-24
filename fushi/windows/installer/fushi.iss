; fushi/windows/installer/fushi.iss
; 由 CI 用 ISCC 编译；AppVersion / SourceDir / OutputDir 由命令行 /D 传入。
; Fushi 改名（Phase 3）：AppId GUID 不变 => 对旧 Hibiki 安装做覆盖升级；
; 升级路径上的旧名残留（hibiki.exe / 快捷方式 / 注册表 ProgID）在本脚本内清理。
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\build\installer"
#endif

[Setup]
AppId={{8F2C1A3E-7B4D-4E9A-9C21-0A1B2C3D4E5F}}
AppName=Fushi
AppVersion={#AppVersion}
AppPublisher=Fushi
DefaultDirName={localappdata}\Fushi
DefaultGroupName=Fushi
DisableProgramGroupPage=yes
; Fushi 改名：Inno 默认 UsePreviousGroup=yes，升级时从卸载键里读回上一次的
; 「Inno Setup: Icon Group」（旧安装写的是 Hibiki），于是 {group} 解析成
; ...\Programs\Hibiki，新建的 Fushi 快捷方式会落进一个叫 Hibiki 的文件夹里
; （实测用户机器上 Programs\Hibiki 现在是空目录，正是这条路径的产物）。
; 关掉它，强制用 DefaultGroupName=Fushi；遗留的 Programs\Hibiki 在
; CurStepChanged/ssPostInstall 里清理（先删旧 lnk，目录空了才 RemoveDir）。
; DisableProgramGroupPage=yes 意味着用户从来无法自定义组名，所以这里不存在
; 「覆盖用户选择」的风险。
UsePreviousGroup=no
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename=fushi-{#AppVersion}-windows-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=no
CloseApplicationsFilter=*.exe,*.dll
RestartApplications=no
; 过渡期双 mutex：老 Hibiki 实例还持有旧名互斥量时，升级安装同样要等它退出。
AppMutex=FushiSingleInstanceMutex,HibikiSingleInstanceMutex

[Tasks]
; 桌面快捷方式：默认勾选（保持旧行为——首装桌面即有图标），允许用户取消。
; 配合 [Icons] 的 Check: ShouldCreateDesktopIcon，仅在快捷方式尚不存在时创建，
; 应用内静默更新（/VERYSILENT，用户看不到向导、无法取消）不会重写已存在的 .lnk，
; 桌面图标位置得以保留（BUG-1014）。
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加快捷方式："

; 可选：把 Fushi 注册为视频文件的「打开方式」候选（不抢占系统默认播放器，
; 只在资源管理器右键「打开方式」里出现 Fushi，并支持拖视频到 fushi.exe）。
Name: "videoassoc"; Description: "将 Fushi 加入视频文件的「打开方式」（mkv / mp4 等）"; GroupDescription: "文件关联："

[InstallDelete]
; BUG-1449：galgame helper 现在以**普通文件**随包发在 {app}\voice_hook\<arch>\，
; 由 install_into_bundle.ps1 在构建期解压，与本体同一次构建产出。随包 zip 归档
; （旧模型的产物）必须在升级时清掉——否则它会以「随包真相源」的身份留在磁盘上：
; 一旦用户手工删过 voice_hook\<arch>\installed.sha256（排障时的常见动作），
; GalgameHelperInstaller 就会拿这份**旧** zip 回填，把安装器刚放好的新组件覆盖成旧的，
; 直接复发 BUG-1448 的「组件比本体旧」。删的是上一版留下的归档，不碰用户数据。
Type: filesandordirs; Name: "{app}\galgame_helper"
; 归属判据：本段只放「必须在复制前删、且删了不影响可运行性」的条目。
; 上面 {app}\galgame_helper 两点都满足——新包同样往 {app} 下写 helper 组件，
; 不先删就会被旧归档回填；而它本身不是可执行入口，删早了不会让 app 打不开。
;
; 旧名二进制（hibiki.exe / hibiki_update_launcher.exe / hibiki_torrent_ffi.dll /
; hoshidicts_ffi.dll）和旧名快捷方式**不在这里**：[InstallDelete] 在复制任何新文件
; 之前执行，且 Inno 明确不会在安装失败/取消时回滚这些删除。它们又都不与新文件同名，
; 所以「复制前删」没有任何必要性，却把一次中途失败的升级从「还剩个能跑的旧版」
; 变成「一个可执行文件都没有」（实测现场：{app} 下 hibiki.exe 与 fushi.exe 双双消失，
; 只剩 unins000.exe，快捷方式全成死链接）。这些条目已下沉到 [Code] 的
; CurStepChanged / ssPostInstall，即新文件全部落地之后才执行。

[Files]
; 包含 fushi_update_launcher.exe：应用内更新用它等待当前 fushi.exe 退出后再启动 Inno。
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Fushi"; Filename: "{app}\fushi.exe"
; BUG-1014：只在桌面快捷方式尚不存在时创建（详见旧注释；改名后判 Fushi.lnk）。
Name: "{userdesktop}\Fushi"; Filename: "{app}\fushi.exe"; Tasks: desktopicon; Check: ShouldCreateDesktopIcon

[Registry]
; Fushi 应用 ProgId：双击/「打开方式」时以 fushi.exe "<文件>" 启动。
; "%1" 即视频绝对路径，被 runner 经 set_dart_entrypoint_arguments 传给 Dart
; main(args)（见 lib/main.dart + windows/runner/utils.cpp::GetCommandLineArguments）。
; BUG-1666：fushi:// URL 协议（Anki 卡片上的词典交叉引用 fushi://lookup?word=<词>）。
; 点击后系统以 fushi.exe "<完整URL>" 启动：冷启动走 Dart main(args)，app 已开则由
; 单实例守卫经 WM_COPYDATA 转交首实例（与外部视频同一条链路），Dart 侧
; lookupWordFromDeepLink 解析后排队显式查词。无条件注册（不挂 videoassoc 任务）。
Root: HKCU; Subkey: "Software\Classes\fushi"; ValueType: string; ValueData: "URL:Fushi Lookup"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\fushi"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\fushi\DefaultIcon"; ValueType: string; ValueData: "{app}\fushi.exe,0"
Root: HKCU; Subkey: "Software\Classes\fushi\shell\open\command"; ValueType: string; ValueData: """{app}\fushi.exe"" ""%1"""

Root: HKCU; Subkey: "Software\Classes\Fushi.Video"; ValueType: string; ValueData: "Fushi 视频"; Flags: uninsdeletekey; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Fushi.Video\DefaultIcon"; ValueType: string; ValueData: "{app}\fushi.exe,0"; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Fushi.Video\shell\open\command"; ValueType: string; ValueData: """{app}\fushi.exe"" ""%1"""; Tasks: videoassoc

; 让 fushi.exe 出现在「打开方式」应用列表，并声明它支持的视频扩展名。
Root: HKCU; Subkey: "Software\Classes\Applications\fushi.exe\shell\open\command"; ValueType: string; ValueData: """{app}\fushi.exe"" ""%1"""; Flags: uninsdeletekey; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Applications\fushi.exe\SupportedTypes"; ValueType: string; ValueName: ".mkv"; ValueData: ""; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Applications\fushi.exe\SupportedTypes"; ValueType: string; ValueName: ".mp4"; ValueData: ""; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Applications\fushi.exe\SupportedTypes"; ValueType: string; ValueName: ".m4v"; ValueData: ""; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Applications\fushi.exe\SupportedTypes"; ValueType: string; ValueName: ".avi"; ValueData: ""; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Applications\fushi.exe\SupportedTypes"; ValueType: string; ValueName: ".webm"; ValueData: ""; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Applications\fushi.exe\SupportedTypes"; ValueType: string; ValueName: ".mov"; ValueData: ""; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Applications\fushi.exe\SupportedTypes"; ValueType: string; ValueName: ".ts"; ValueData: ""; Tasks: videoassoc

; 把 Fushi.Video 挂到各扩展名的 OpenWithProgids（追加候选，不改默认关联）。
Root: HKCU; Subkey: "Software\Classes\.mkv\OpenWithProgids"; ValueType: string; ValueName: "Fushi.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\.mp4\OpenWithProgids"; ValueType: string; ValueName: "Fushi.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\.m4v\OpenWithProgids"; ValueType: string; ValueName: "Fushi.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\.avi\OpenWithProgids"; ValueType: string; ValueName: "Fushi.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\.webm\OpenWithProgids"; ValueType: string; ValueName: "Fushi.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\.mov\OpenWithProgids"; ValueType: string; ValueName: "Fushi.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\.ts\OpenWithProgids"; ValueType: string; ValueName: "Fushi.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc

; ── 旧 Hibiki 注册表迁移清理（无条件执行，不挂 videoassoc：用户这次没勾关联
;    也要把指向已删除 hibiki.exe 的死键清掉，否则「打开方式」里留一个坏条目）──
Root: HKCU; Subkey: "Software\Classes\Hibiki.Video"; ValueType: none; Flags: deletekey
Root: HKCU; Subkey: "Software\Classes\Applications\hibiki.exe"; ValueType: none; Flags: deletekey
Root: HKCU; Subkey: "Software\Classes\.mkv\OpenWithProgids"; ValueType: none; ValueName: "Hibiki.Video"; Flags: deletevalue
Root: HKCU; Subkey: "Software\Classes\.mp4\OpenWithProgids"; ValueType: none; ValueName: "Hibiki.Video"; Flags: deletevalue
Root: HKCU; Subkey: "Software\Classes\.m4v\OpenWithProgids"; ValueType: none; ValueName: "Hibiki.Video"; Flags: deletevalue
Root: HKCU; Subkey: "Software\Classes\.avi\OpenWithProgids"; ValueType: none; ValueName: "Hibiki.Video"; Flags: deletevalue
Root: HKCU; Subkey: "Software\Classes\.webm\OpenWithProgids"; ValueType: none; ValueName: "Hibiki.Video"; Flags: deletevalue
Root: HKCU; Subkey: "Software\Classes\.mov\OpenWithProgids"; ValueType: none; ValueName: "Hibiki.Video"; Flags: deletevalue
Root: HKCU; Subkey: "Software\Classes\.ts\OpenWithProgids"; ValueType: none; ValueName: "Hibiki.Video"; Flags: deletevalue

[UninstallDelete]
; 数据存储位置引导文件（见 [Code] WriteDataRootBootstrap）。app 首启即消费并删除；
; 装完从没启动过就卸载时由这里收尾，别在安装目录留一个孤儿文件。
Type: files; Name: "{app}\data_root.bootstrap"

[Run]
Filename: "{app}\fushi.exe"; Description: "启动 Fushi"; Flags: nowait postinstall

[Code]
// -- TODO-549: app-internal self-update "AppMutex deadlock" root-cause layer --
// Regression source: TODO-431.
//
// The old app launches the new installer; Inno does its AppMutex check early
// (CheckForMutexes; per Inno source Setup.MainFunc.pas the InitializeSetup call
// runs BEFORE the CheckForMutexes loop) and finds some running instance still
// holding the single-instance mutex, so it pops "Setup has detected that the
// app is currently running". Under /VERYSILENT + /SUPPRESSMSGBOXES that
// OK/Cancel box defaults to Cancel -> Got EAbort -> immediate exit with no
// files replaced.
//
// Inno's CloseApplications / /CLOSEAPPLICATIONS go through RestartManager (by
// file usage) and are completely independent from the AppMutex check
// (CheckForMutexes), so they cannot suppress the mutex abort. The only layer
// that runs BEFORE the AppMutex check and can own the timing is this
// InitializeSetup: it actively terminates the running app (Fushi 改名过渡期
// 新旧两个 exe 名与两个 mutex 名都要照顾) and its WebView2 child processes,
// then bounded-polls until the mutex is truly released, then returns True; by
// the time Inno runs CheckForMutexes the mutex is gone, so it passes quietly.
// The [Setup] AppMutex= (both names) is kept as a fallback.

const
  FushiAppMutexName = 'FushiSingleInstanceMutex';
  LegacyAppMutexName = 'HibikiSingleInstanceMutex';
  SyncMutexAccess = $00100000; { SYNCHRONIZE }
  MutexReleasePollAttempts = 40; { 40 * 250ms = up to ~10s waiting for the kernel to reclaim the mutex }
  MutexReleasePollIntervalMs = 250;
  GracefulCloseAttempts = 8;
  { Inno 的 Pascal Script 不预定义 INVALID_HANDLE_VALUE；THandle 是无符号 32 位，
    Win32 的 (HANDLE)-1 在这里就是 $FFFFFFFF。 }
  InvalidHandleValue = $FFFFFFFF;

{ OpenMutexW: third arg is a String; Inno (Unicode) marshals it into a
  PWideChar for the W variant. Returns THandle; non-zero = the named mutex is
  still present (the app has not actually exited yet). }
function OpenMutexW(dwDesiredAccess: Cardinal; bInheritHandle: Boolean;
  lpName: String): THandle;
  external 'OpenMutexW@kernel32.dll stdcall';

function CloseHandle(hObject: THandle): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';

{ Probe whether a named mutex exists; close the handle immediately to avoid
  leaking (and to avoid the probe itself keeping a reference alive). }
function NamedMutexExists(const MutexName: String): Boolean;
var
  Handle: THandle;
begin
  Handle := OpenMutexW(SyncMutexAccess, False, MutexName);
  Result := Handle <> 0;
  if Result then
    CloseHandle(Handle);
end;

{ 过渡期：新旧两个单实例互斥量任一存在都算「应用仍在运行」。 }
function AppMutexExists(): Boolean;
begin
  Result := NamedMutexExists(FushiAppMutexName) or
            NamedMutexExists(LegacyAppMutexName);
end;

{ Gentle close: taskkill WITHOUT /F sends WM_CLOSE so the app can save state
  and release its mutex on its own. /T also targets child processes (the
  WebView2 msedgewebview2.exe runs as a child). }
procedure KillGracefully(const ExeName: String);
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'),
       '/IM ' + ExeName + ' /T',
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

{ Force kill: /F forces, /IM by image name, /T takes the whole child-process
  tree (WebView2 included). ResultCode=128 means no matching process; that is
  not an error -- the mutex poll is the source of truth. }
procedure KillImage(const ExeName: String);
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'),
       '/F /IM ' + ExeName + ' /T',
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

{ BUG-1459: the mutex layer only proves the main exe exited. Helper processes
  launched from the install dir (ffmpeg.exe audio jobs, galgame helper) can
  outlive it and keep their image files locked, so the file-copy phase dies
  with "could not replace ...\ffmpeg.exe (DeleteFile code 5)". Sweep by image
  PATH under the target dir (not by name) so unrelated same-named processes
  elsewhere on the machine are untouched. }
procedure KillProcessesUnderDir(const Dir: String);
var
  ResultCode: Integer;
  EscapedDir: String;
  Cmd: String;
begin
  EscapedDir := Dir;
  StringChangeEx(EscapedDir, '''', '''''', True);
  Cmd := '-NoProfile -NonInteractive -Command "$d = ''' + EscapedDir + '''; ' +
    'if (-not $d.EndsWith(''\'')) { $d += ''\'' }; ' +
    'Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($d, [System.StringComparison]::OrdinalIgnoreCase) ' +
    '-and $_.ProcessName -ne ''fushi_update_launcher'' } | ' +
    'Stop-Process -Force -ErrorAction SilentlyContinue"';
  // BUG-1786：必须走 {sysnative} 而不是 {sys}。本安装器是 **32 位**进程
  // （日志里的「64-bit install mode: No」），{sys} 会被 WOW64 重定向到 SysWOW64 的
  // **32 位** PowerShell，而 32 位 PowerShell 读不到 64 位进程的 .Path（底层 MainModule
  // 跨位宽访问失败，属性取到空串）。于是过滤条件 `$_.Path -and ...` 对**每一个** 64 位
  // 进程都恒假——fushi.exe / injector / ffmpeg 一个都杀不掉，这个过程长期是发哑弹。
  // 实测（同一份命令、同一个 x64 目标进程）：
  // 64 位 PowerShell → alive=False，文件随即可写；
  // 32 位 PowerShell → alive=True，文件仍被占用，且 Path 取到空串。
  // {sysnative} 在 64 位 Windows 上绕过 WOW64 重定向指向真正的 System32；32 位 Windows
  // 上它等同 {sys}，故无平台回归。
  //
  // launcher 被显式排除（上面的 ProcessName 判断）：它是拉起本安装器的进程，且要活到
  // 安装结束才能在失败时把 app 拉回来（BUG-1708）。杀了它等于用那条 bug 的复发换这次
  // 复制成功。它自己占住的文件由 MakeWayForRunningLauncher 改名让路解决。
  Exec(ExpandConstant('{sysnative}\WindowsPowerShell\v1.0\powershell.exe'), Cmd,
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

{ BUG-1675: 能不能真的换掉这个文件——用「独占写方式打开」实测，而不是猜。
  被别的进程映射的 DLL 在 Windows 下**可以改名但不能覆盖**，所以 RenameFile
  探测会给出假的「没被占用」；只有以 GENERIC_WRITE + dwShareMode=0 打开才复现
  安装器复制阶段的真实约束（占用时返回 INVALID_HANDLE_VALUE / 共享冲突）。 }
function CreateFileW(lpFileName: String; dwDesiredAccess: Cardinal;
  dwShareMode: Cardinal; lpSecurityAttributes: Cardinal;
  dwCreationDisposition: Cardinal; dwFlagsAndAttributes: Cardinal;
  hTemplateFile: THandle): THandle;
  external 'CreateFileW@kernel32.dll stdcall';

function FileLockedForWrite(const FileName: String): Boolean;
var
  Handle: THandle;
begin
  Result := False;
  if not FileExists(FileName) then
    Exit;
  { GENERIC_WRITE=$40000000, 不共享(0), OPEN_EXISTING=3, FILE_ATTRIBUTE_NORMAL=$80 }
  Handle := CreateFileW(FileName, $40000000, 0, 0, 3, $80, 0);
  if Handle = InvalidHandleValue then
    Result := True
  else
    CloseHandle(Handle);
end;

{ 扫一个 arch 目录下所有 exe/dll，返回第一个被占用的完整路径（没有则空串）。 }
function FirstLockedFileInDir(const Dir: String): String;
var
  FindRec: TFindRec;
  Lower: String;
  Full: String;
begin
  Result := '';
  if not DirExists(Dir) then
    Exit;
  if not FindFirst(AddBackslash(Dir) + '*', FindRec) then
    Exit;
  try
    repeat
      if FindRec.Attributes and FILE_ATTRIBUTE_DIRECTORY = 0 then
      begin
        Lower := Lowercase(FindRec.Name);
        { 按**后缀**判，不用 Pos 子串：`classdata.tpk` 之类不该进来，而
          `foo.dll.stale`（换入残骸）也不是安装器要覆盖的目标。 }
        Lower := Copy(Lower, Length(Lower) - 3, 4);
        if (Lower = '.dll') or (Lower = '.exe') then
        begin
          Full := AddBackslash(Dir) + FindRec.Name;
          if FileLockedForWrite(Full) then
          begin
            Result := Full;
            Exit;
          end;
        end;
      end;
    until not FindNext(FindRec);
  finally
    FindClose(FindRec);
  end;
end;

{ 被占用的 galgame helper 组件（两个架构都查），没有则空串。 }
function LockedGalHookComponent(const AppDir: String): String;
var
  Base: String;
begin
  Base := AddBackslash(AppDir) + 'voice_hook\';
  Result := FirstLockedFileInDir(Base + 'x86');
  if Result = '' then
    Result := FirstLockedFileInDir(Base + 'x64');
end;

// BUG-1786：给正在运行的 update launcher 让路。
//
// 应用内更新时 {app}\fushi_update_launcher.exe **必然**处于运行中——它就是拉起本安装器
// 的那个进程，而且必须一直活到安装结束：BUG-1708 把「安装失败后谁把 app 拉回来」这一环
// 交给了它（app 为让出文件锁已经 exit 了，Inno 走不到 [Run] 就没人负责）。于是复制阶段
// 撞上「文件正被使用」→ DeleteFile code 5 → /SUPPRESSMSGBOXES 对 Abort/Retry/Ignore
// 默认取 **Abort** → 整包回滚。排在它后面的 data\app.so（全部 Dart 代码）和 flutter_assets
// 一个都装不上，而字母序在它之前的 fushi.exe 已经落地并被保留——半更新态：新 exe + 旧
// Dart 代码，版本号（读自 exe 资源）却显示为新版，用户完全无从察觉（现场：用户连报
// 「修好的 bug 怎么没生效」）。
//
// 这里**故意不杀 launcher**：杀了它就没人在安装失败时把 app 拉回来，等于用 BUG-1708 的
// 复发换这次复制成功。Windows 允许给正在运行的 exe **改名**（同卷，只是不能删除/覆盖），
// 改名后目标路径空出来让 Inno 正常写入新文件，而那个进程的映像仍然有效、照样兜底。
//
// 新版 app 起已改为从安装目录**外**的副本运行 launcher（platform_updater.dart 的
// stageWindowsUpdateLauncher），届时这里探测不到占用、直接返回；本过程是给**存量旧版**
// 用户的救援——他们跑的仍是安装目录里的 launcher，只有靠这一步才能把这一版装完整。
procedure MakeWayForRunningLauncher(const AppDir: String);
var
  Launcher: String;
  Stale: String;
  Attempt: Integer;
begin
  Launcher := AddBackslash(AppDir) + 'fushi_update_launcher.exe';
  Stale := AddBackslash(AppDir) + 'fushi_update_launcher.old.exe';
  { BUG-1831：launcher 不在位、只剩残留 —— 上一轮让路之后那次安装**仍然回滚了**。
    改名之后 Launcher 这个路径是空的，Inno 往里写的是一个**新建**文件，而回滚会删除
    本次新建的文件（只有被覆盖的文件才原样保留）⇒ 原件已改名、新件被删，安装目录里
    再没有 launcher。此时必须把残留**改回去**：它是同一份映像，旧版 app 又只认
    fushi_update_launcher.exe 这一个路径。先删掉它等于把「还能自愈」变成「这台机器
    永远发不出更新」（安装器一次都起不来，连 Inno 日志都不会产生）。
    改回去之后本次安装照常覆盖它，一次装完即回到正常态。 }
  if not FileExists(Launcher) then
  begin
    if FileExists(Stale) then
      RenameFile(Stale, Launcher);
    Exit;
  end;
  { 没被占用就什么都不做——不给正常路径平添一次改名和一个残留文件。
    顺手清掉上一轮的残留：原件在位说明它早已完成使命，不让它无限堆积。 }
  if not FileLockedForWrite(Launcher) then
  begin
    if FileExists(Stale) then
      DeleteFile(Stale);
    Exit;
  end;
  { 让路目标必须先空出来，否则 RenameFile 直接失败、等于没让路。残留可能正是
    **拉起本安装器的那个进程**（BUG-1831 的自愈路径上 app 就是从 .old 起的 launcher），
    删不掉就换个序号名——绝不因为一个删不掉的残留放弃整次安装。 }
  Attempt := 0;
  while FileExists(Stale) do
  begin
    if DeleteFile(Stale) then
      Break;
    Attempt := Attempt + 1;
    if Attempt > 8 then
      Exit;
    Stale := AddBackslash(AppDir) + 'fushi_update_launcher.old' +
      IntToStr(Attempt) + '.exe';
  end;
  RenameFile(Launcher, Stale);
end;

{ Runs after the user confirms install, before file copy — the last hook where
  we can still release file locks. Empty result string = proceed. }
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Locked: String;
  NL: String;
begin
  Result := '';
  KillProcessesUnderDir(ExpandConstant('{app}'));
  Sleep(500);
  { KillProcessesUnderDir 杀不到 launcher，也**不该**杀它（见上）。改名让路。 }
  MakeWayForRunningLauncher(ExpandConstant('{app}'));

  { BUG-1675：KillProcessesUnderDir 按**主模块路径**杀进程，杀得掉安装目录里的
    fushi_voice_injector.exe，却杀不掉真正的占用大头——**用户正在玩的游戏**：它的
    exe 在 D:\Games\ 之类的地方，只是把安装目录下 voice_hook\<arch>\fushi_voice_hook.dll
    映射了进去。放着不管，复制阶段就换不掉这些文件，而应用内更新用的
    /VERYSILENT /SUPPRESSMSGBOXES 会把这次失败静默吞掉，落地成「新本体 + 旧 helper」，
    用户下次开游戏才看到 `voice_hook open protocol_mismatch shm=13/want 15`，
    且那条提示给的处置（关掉游戏重开）对已经写坏的磁盘状态毫无作用。

    这里**故意不强杀游戏**：ffmpeg/injector 是我们自己的无状态子进程，杀了没有代价；
    而玩家的游戏里可能有没存档的进度，为了装个更新把它杀掉是不可接受的破坏。
    所以查出占用就在**复制任何文件之前**中止，让用户自己存档退出——这一步返回非空
    字符串，Inno 会显示它并干净地放弃本次安装，磁盘保持完整旧版本。 }
  Locked := LockedGalHookComponent(ExpandConstant('{app}'));
  if Locked <> '' then
  begin
    { NL 走变量而不是把 #13#10 直接写进串联式：ISPP 会把**行首**的 `#` 当成
      预处理指令，跨行拼接时以 #13#10 开头的续行会直接编译失败。 }
    NL := Chr(13) + Chr(10);
    { 文案不再断言占用者是「游戏」：Fushi 的捕获组件可以附着到任何被用户选中的窗口，
      实测现场里锁住 fushi_voice_hook.dll 的是**微信**（连开三天，于是每次自动更新都在
      这里中止，版本卡了五天，BUG-1708）。把占用者写死成游戏会让用户对着一个根本没开的
      东西找问题。只陈述事实：哪个文件被占用、它为什么会被别的进程持有、怎么放开。 }
    Result := '检测到 Fushi 的捕获组件正被其它程序占用，无法更新：' + NL + Locked + NL + NL +
      'Fushi 的语音捕获组件会注入到你选定的程序里（游戏，或任何你附着过的窗口），' + NL +
      '并由该程序持有到它退出为止。请关闭最近附着过的程序（游戏请先存档），' + NL +
      '然后重新运行本安装程序。' + NL + NL +
      '（本次未改动任何文件，现有版本可继续使用。）';
  end;
end;

// BUG-1014: preserve the user's desktop icon position across updates.
// Return False (skip creating the desktop shortcut) when {userdesktop}\Fushi.lnk
// already exists, so an update never rewrites it -- Explorer keeps the remembered
// grid position. On a first install the file is absent -> True -> the shortcut is
// created as before (gated by the default-checked "desktopicon" task).
function ShouldCreateDesktopIcon(): Boolean;
begin
  Result := not FileExists(ExpandConstant('{userdesktop}\Fushi.lnk'));
end;

// ── 数据存储位置（全新安装向导页）──────────────────────────────────────────
// 安装目录 ({app}) 与数据目录是两回事：书库/漫画/视频封面字幕/词典/数据库全落数据根，
// 体积可能远大于程序本身。旧行为是 app 首启无条件用默认根（<Documents>\Fushi\data +
// %APPDATA%\Fushi\Fushi），用户只能装完再去「设置 → 数据存储位置」整树迁移 + 重启。
// 这里在全新安装时多问一页；用户的选择经 {app}\data_root.bootstrap 一次性交给 app
// （lib/src/storage/installer_data_root_bootstrap.dart 首启消费后删除、之后唯一真相源
// 仍是 app 自己的 data_root 偏好）。安装器只是一次性写者，不是第二个配置来源。
//
// 只对全新安装显示：升级/重装时 app 已经有自己的数据根（默认或自定义），从安装器再
// 塞一个进去只会让既有书库「消失」；要搬走走设置里的迁移（连 DB 内绝对路径一起 rebase）。
const
  DataRootBootstrapFileName = 'data_root.bootstrap';

var
  DataRootPage: TInputDirWizardPage;
  { ShouldSkipPage 里判定并记住「本次真的向用户展示了数据目录页」。ssPostInstall 时卸载键
    已经写好，届时再调 IsFreshInstall 恒为 False，所以必须在页面阶段落下这个标记。 }
  DataRootPageOffered: Boolean;

{ Inno 卸载键：HKCU（PrivilegesRequired=lowest）\...\Uninstall\<AppId>_is1。AppId 直接
  经 ISPP 从 Setup 段取，再让 ExpandConstant 做双左括号 → 单左括号的转义——Setup 段里
  写的是双括号包着的 GUID，真值是「单左括号 + GUID + 双右括号」（尾部两个右括号是 Inno
  的既定行为，不是笔误）。手抄 GUID 会漏掉这一层，键永远匹配不上。
  注意：本注释任何一行都不能以「[」开头——Inno 段解析先于 Code 段，会当成段标签。 }
function FushiUninstallKey(): String;
begin
  Result := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\'
    + ExpandConstant('{#SetupSetting("AppId")}') + '_is1';
end;

{ 全新安装 = 卸载键不存在（没装过 / 已卸载）且 app 的平台固定落点不存在——
  %APPDATA%\Fushi\Fushi（path_provider 取 exe 版本资源 CompanyName\ProductName），
  兼看改名前的 %APPDATA%\Hibiki\Hibiki（app 首启 migrateLegacySupportDir 会把它搬成新名，
  随后认出旧库、丢弃安装器的选择）。这两条兜住「卸载但保留了数据」的重装：那种机器上
  app 首启会认出旧库，安装器不该再问。 }
function IsFreshInstall(): Boolean;
begin
  Result := (not RegKeyExists(HKCU, FushiUninstallKey()))
    and (not DirExists(ExpandConstant('{userappdata}\Fushi\Fushi')))
    and (not DirExists(ExpandConstant('{userappdata}\Hibiki\Hibiki')));
end;

{ A 等于 B、或是 B 的祖先目录（大小写不敏感、按整段路径前缀比较：尾部补反斜杠后
  'C:\Fushi\' 不会误配 'C:\FushiData\'）。 }
function IsSameOrAncestorDir(const A, B: String): Boolean;
begin
  Result := Pos(Lowercase(AddBackslash(A)), Lowercase(AddBackslash(B))) = 1;
end;

procedure InitializeWizard();
begin
  DataRootPageOffered := False;
  DataRootPage := CreateInputDirPage(wpSelectDir,
    '选择数据存储位置',
    '导入的书籍、漫画、视频封面与字幕、词典和数据库存放在哪里？',
    '这些数据可能远大于程序本身，建议选一个空间充足的位置。' + #13#10 +
    '之后可以在「设置 → 数据存储位置」里迁移。' + #13#10#13#10 +
    '点击「下一步」继续。',
    False, 'Fushi');
  DataRootPage.Add('');
  DataRootPage.Values[0] := ExpandConstant('{userdocs}\Fushi');
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if (DataRootPage <> nil) and (PageID = DataRootPage.ID) then
  begin
    { 静默安装（/SILENT、/VERYSILENT：无人值守部署、app 内自更新）没人回答这页，
      Inno 仍会逐页 ClickThrough——NextButtonClick 返回 False 会整个安装中止。
      静默 = 不问、不写引导文件，app 按默认根走，与改动前逐字节一致。 }
    DataRootPageOffered := (not WizardSilent()) and IsFreshInstall();
    Result := not DataRootPageOffered;
  end;
end;

{ ssPostInstall：把用户选的数据目录交给 app。默认值也照写——「选的是不是默认位置」由
  app 按它自己的默认根定义归一化，安装器不复制这条规则。 }
procedure WriteDataRootBootstrap();
var
  Lines: TArrayOfString;
  Target: String;
begin
  if not DataRootPageOffered then
    Exit;
  { DataRootPageOffered 只可能在 ShouldSkipPage 里被置真，那时 DataRootPage 必非 nil；
    显式再判一次，别让这条隐式不变式成为一次改动就能踩穿的解引用。 }
  if DataRootPage = nil then
    Exit;
  Target := RemoveBackslashUnlessRoot(Trim(DataRootPage.Values[0]));
  if Target = '' then
    Exit;
  SetArrayLength(Lines, 1);
  Lines[0] := Target;
  if not SaveStringsToUTF8File(ExpandConstant('{app}\' + DataRootBootstrapFileName), Lines, False) then
    Log('WriteDataRootBootstrap: 写入失败，app 将使用默认数据位置');
end;

// Fushi 改名的旧名残留清理，全部放在 ssPostInstall（新文件已全部落地之后），
// 不放 [InstallDelete]：后者在复制前执行，且 Inno 不会在安装失败/取消时回滚删除，
// 于是任何一次中途失败的升级都会把「还剩个能跑的旧版」变成「一个可执行文件都没有」。
// ssPostInstall 只有在文件复制成功后才会到达，删旧名二进制不再有这个窗口。
//
// 平台限制（如实记录）：Windows 不提供程序化「固定到任务栏」的公开接口，
// 所以任务栏固定项这里只能删掉指向已消失的 hibiki.exe 的死链接，
// 无法自动改指 fushi.exe、也无法重新固定；用户需要的话得手动再固定一次。
procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep <> ssPostInstall then
    Exit;

  WriteDataRootBootstrap();

  // 旧名可执行文件：Inno 只覆盖同名文件，改了名的旧 exe 不清就会与 fushi.exe
  // 并存，旧快捷方式还能把上一版拉起来。
  DeleteFile(ExpandConstant('{app}\hibiki.exe'));
  DeleteFile(ExpandConstant('{app}\hibiki_update_launcher.exe'));

  // 旧名 native 产物（改名前 windows/CMakeLists.txt 装的是 hoshidicts_ffi.dll
  // 与 hibiki_torrent_ffi.dll）。留着一是纯垃圾，二是 torrent 引擎按名加载
  // 「exe 同目录」，等于给「新 DLL 缺失时静默加载上一版旧 ABI」留口子。
  DeleteFile(ExpandConstant('{app}\hibiki_torrent_ffi.dll'));
  DeleteFile(ExpandConstant('{app}\hoshidicts_ffi.dll'));

  // 三处旧名快捷方式全部指向已删除的 hibiki.exe，都是死链接。
  // 1) 桌面
  DeleteFile(ExpandConstant('{userdesktop}\Hibiki.lnk'));
  // 2) 开始菜单程序组（UsePreviousGroup=no 之后 {group} 已是 Fushi 组；
  //    这条覆盖「旧 lnk 与新组同目录」的情形，遗留的 Hibiki 组另行处理）。
  DeleteFile(ExpandConstant('{group}\Hibiki.lnk'));
  // 3) 任务栏固定项——[InstallDelete] 从来没清过它，正是用户实测那个
  //    「任务栏图标点了没反应」的死链接来源。
  DeleteFile(ExpandConstant('{userappdata}\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Hibiki.lnk'));

  // 遗留的 Programs\Hibiki 程序组：旧安装留下的 Hibiki.lnk，以及
  // UsePreviousGroup=yes 时期误建在该组里的 Fushi.lnk。两个都删掉后目录空了才移除
  // （RemoveDir 只删空目录，用户自己往里放的东西不会被波及）。
  DeleteFile(ExpandConstant('{userprograms}\Hibiki\Hibiki.lnk'));
  DeleteFile(ExpandConstant('{userprograms}\Hibiki\Fushi.lnk'));
  RemoveDir(ExpandConstant('{userprograms}\Hibiki'));
end;

function InitializeSetup(): Boolean;
var
  Attempt: Integer;
begin
  Result := True;
  { No mutex = no running instance, pass straight through (first install / the
    app has already exited cleanly). }
  if not AppMutexExists() then
    Exit;

  { Gentle first: WM_CLOSE gives the app a chance to save state and release the
    mutex on its own. 过渡期新旧 exe 名都发。 }
  KillGracefully('fushi.exe');
  KillGracefully('hibiki.exe');
  for Attempt := 1 to GracefulCloseAttempts do
  begin
    if not AppMutexExists() then
      Exit;
    Sleep(MutexReleasePollIntervalMs);
  end;

  { Still alive: force-kill both exe trees (WebView2 with them), then sweep
    any orphaned msedgewebview2.exe. }
  KillImage('fushi.exe');
  KillImage('hibiki.exe');
  KillImage('msedgewebview2.exe');

  { Bounded poll until the mutex is truly released; on timeout still return True
    (do not hang forever) and let the [Setup] AppMutex fallback handle it. }
  for Attempt := 1 to MutexReleasePollAttempts do
  begin
    if not AppMutexExists() then
      Exit;
    Sleep(MutexReleasePollIntervalMs);
  end;
end;

{ BUG-1483: 选目录页写入预检。本安装器 PrivilegesRequired=lowest（不提权），
  用户手选 Program Files 这类需要管理员权限的目录时，老行为是复制阶段才蹦
  "Error 5: 拒绝访问" 中断安装；就算用户再手动提权装进去，运行期还有第二排雷：
  应用以普通权限跑，WebView2 数据目录与应用内自动更新都写不进安装目录
  （更新每次都得提权）。所以在用户点「下一步」时就实测一把可写性，拦下并给出
  明确指引，而不是让错误在安装中途/运行期反复浮现。
  探测方式：目录已存在→写探针文件再删掉；不存在→建目录链（建成后目录留给
  正式安装直接用，不回滚——马上就要装进去，且 RemoveDir 误删既有空目录的
  风险比留一个空目录大）。}
function InstallDirWritable(const Dir: String): Boolean;
var
  Probe: String;
begin
  Result := False;
  if not DirExists(Dir) then
  begin
    if not ForceDirectories(Dir) then
      Exit;
  end;
  Probe := AddBackslash(Dir) + '.fushi-setup-write-test';
  if SaveStringToFile(Probe, 'fushi setup preflight', False) then
  begin
    DeleteFile(Probe);
    Result := True;
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  DataRoot: String;
begin
  Result := True;
  if CurPageID = wpSelectDir then
  begin
    if not InstallDirWritable(WizardDirValue) then
    begin
      MsgBox('当前权限无法写入所选目录：' + #13#10 + WizardDirValue + #13#10#13#10
        + '请改选用户可写的目录（推荐默认目录 '
        + ExpandConstant('{localappdata}\Fushi') + '）。' + #13#10#13#10
        + '不建议装进需要管理员权限的目录：即使以管理员身份重装到该目录，'
        + '应用日常以普通权限运行，之后每次自动更新都需要再次提权。',
        mbError, MB_OK);
      Result := False;
    end;
  end
  else if (DataRootPage <> nil) and (CurPageID = DataRootPage.ID) then
  begin
    DataRoot := RemoveBackslashUnlessRoot(Trim(DataRootPage.Values[0]));
    { 绝对路径预检，必须排在其余三条业务校验之前。TInputDirWizardPage 的编辑框允许清空、
      也照收相对路径，Inno 对自定义页的取值不做任何自动校验，而下面三条业务校验对这两种
      输入**全部放行**（Inno 6.7.3 实测，不是推断）：
        AddBackslash('') = ''           → 子目录探测变成相对路径 'documents'，DirExists 假
        IsSameOrAncestorDir 两向         → 都假
        DirExists('') = False，但 ForceDirectories('') = True，SaveStringToFile 也成功
                                        → InstallDirWritable('') 返回 True
      后果：空串一路走到 WriteDataRootBootstrap，被那里的空串兜底 Exit 掉——不写坏数据，
      但用户的选择被**静默丢弃**；相对路径更糟，安装器会在 setup 自己的工作目录（用户的
      下载目录）里真建出一个目录、写探针、再把相对路径原样写进引导文件，直到 app 侧
      installer_data_root_bootstrap.dart 的绝对路径判定才被丢掉，而那条拒绝路径是无声的。
      路径合法性不能整层下放给 app：这里就得判死并告诉用户。
      判据：盘符路径 X:\...（含盘符根 X:\，长度 3）或 UNC \\server\share。正斜杠写法
      C:/Fushi 也判非法——Inno 的目录选择框只产出反斜杠，手打正斜杠给明确报错，
      好过一路放行到 app 再无声丢弃。 }
    if (Length(DataRoot) < 3)
      or ((Copy(DataRoot, 2, 2) <> ':\') and (Copy(DataRoot, 1, 2) <> '\\')) then
    begin
      MsgBox('数据存储位置必须是完整的绝对路径（例如 D:\FushiData）。' + #13#10#13#10
        + '当前填写的是：' + #13#10 + DataRoot,
        mbError, MB_OK);
      Result := False;
      Exit;
    end;
    { 数据目录与安装目录不得相同或互相包含：自动更新 / 安装回滚会整体处理安装目录，
      数据压在下面会被一起清；反过来安装目录落在数据根里则迁移会拒绝（含运行中 exe）。
      app 侧 installer_data_root_bootstrap.dart 首启再做一次同样的双向判定。 }
    if IsSameOrAncestorDir(DataRoot, WizardDirValue)
      or IsSameOrAncestorDir(WizardDirValue, DataRoot) then
    begin
      MsgBox('数据存储位置不能与安装目录相同或互相包含：' + #13#10
        + '安装目录：' + WizardDirValue + #13#10
        + '数据目录：' + DataRoot + #13#10#13#10
        + '请另选一个独立的目录（推荐默认 '
        + ExpandConstant('{userdocs}\Fushi') + '）。',
        mbError, MB_OK);
      Result := False;
      Exit;
    end;
    { app 会在所选目录下派生 documents\ 与 support\ 两棵私有子树并整树接管（子目录名的
      真相源是 Dart 侧 AppPaths.dataRootDocumentsChild / dataRootSupportChild，源码守卫
      把两侧绑在一起，改了 Dart 常量这里会当场变红而不是静默放行）；用户自己的
      目录里已经有同名子目录（典型：把 D:\Downloads 选成数据根）就不能选——否则之后的
      数据根迁移会把用户文件当 Fushi 数据整树搬走 / 删掉。app 首启同样拒绝（targetNotEmpty），
      这里提前拦，别让用户装完才发现选择被丢弃。 }
    if DirExists(AddBackslash(DataRoot) + 'documents')
      or DirExists(AddBackslash(DataRoot) + 'support') then
    begin
      MsgBox('所选目录下已经存在 documents 或 support 子目录：' + #13#10 + DataRoot + #13#10#13#10
        + 'Fushi 会在数据目录下创建并接管这两个子目录，请选一个空目录或新建一个目录。',
        mbError, MB_OK);
      Result := False;
      Exit;
    end;
    if not InstallDirWritable(DataRoot) then
    begin
      MsgBox('当前权限无法写入所选数据目录：' + #13#10 + DataRoot + #13#10#13#10
        + '请改选用户可写的目录（推荐默认 '
        + ExpandConstant('{userdocs}\Fushi') + '）。',
        mbError, MB_OK);
      Result := False;
    end;
  end;
end;
