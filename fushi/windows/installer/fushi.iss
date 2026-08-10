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
  end;
end;
