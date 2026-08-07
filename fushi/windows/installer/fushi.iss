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
; Fushi 改名：升级时清掉旧名二进制（Inno 不删除未被覆盖的旧文件，不清则
; hibiki.exe 与 fushi.exe 并存，旧快捷方式还能把旧版拉起来）。
Type: files; Name: "{app}\hibiki.exe"
Type: files; Name: "{app}\hibiki_update_launcher.exe"
; 旧名快捷方式指向已被删除的 hibiki.exe，一并清掉（桌面图标位置一次性丢失，
; 换来不留死链接；新名快捷方式按 BUG-1014 规则只建一次）。
Type: files; Name: "{userdesktop}\Hibiki.lnk"
Type: files; Name: "{group}\Hibiki.lnk"

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
  Cmd := '-NoProfile -ExecutionPolicy Bypass -Command "$d = ''' + EscapedDir + '''; ' +
    'if (-not $d.EndsWith(''\'')) { $d += ''\'' }; ' +
    'Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($d, [System.StringComparison]::OrdinalIgnoreCase) } | ' +
    'Stop-Process -Force -ErrorAction SilentlyContinue"';
  Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Cmd, '',
       SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

{ Runs after the user confirms install, before file copy — the last hook where
  we can still release file locks. Empty result string = proceed. }
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  KillProcessesUnderDir(ExpandConstant('{app}'));
  Sleep(500);
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
