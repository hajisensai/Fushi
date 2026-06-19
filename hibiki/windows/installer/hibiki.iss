; hibiki/windows/installer/hibiki.iss
; 由 CI 用 ISCC 编译；AppVersion / SourceDir / OutputDir 由命令行 /D 传入。
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
AppName=Hibiki
AppVersion={#AppVersion}
AppPublisher=Hibiki
DefaultDirName={localappdata}\Hibiki
DefaultGroupName=Hibiki
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename=hibiki-{#AppVersion}-windows-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=no
CloseApplicationsFilter=*.exe,*.dll
RestartApplications=no
AppMutex=HibikiSingleInstanceMutex

[Tasks]
; 可选：把 Hibiki 注册为视频文件的「打开方式」候选（不抢占系统默认播放器，
; 只在资源管理器右键「打开方式」里出现 Hibiki，并支持拖视频到 hibiki.exe）。
Name: "videoassoc"; Description: "将 Hibiki 加入视频文件的「打开方式」（mkv / mp4 等）"; GroupDescription: "文件关联："

[Files]
; 包含 hibiki_update_launcher.exe：应用内更新用它等待当前 hibiki.exe 退出后再启动 Inno。
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Hibiki"; Filename: "{app}\hibiki.exe"
Name: "{userdesktop}\Hibiki"; Filename: "{app}\hibiki.exe"

[Registry]
; 一个 Hibiki 应用 ProgId：双击/「打开方式」时以 hibiki.exe "<文件>" 启动。
; "%1" 即视频绝对路径，被 runner 经 set_dart_entrypoint_arguments 传给 Dart
; main(args)（见 lib/main.dart + windows/runner/utils.cpp::GetCommandLineArguments）。
Root: HKCU; Subkey: "Software\Classes\Hibiki.Video"; ValueType: string; ValueData: "Hibiki 视频"; Flags: uninsdeletekey; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Hibiki.Video\DefaultIcon"; ValueType: string; ValueData: "{app}\hibiki.exe,0"; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Hibiki.Video\shell\open\command"; ValueType: string; ValueData: """{app}\hibiki.exe"" ""%1"""; Tasks: videoassoc

; 让 hibiki.exe 出现在「打开方式」应用列表，并声明它支持的视频扩展名。
Root: HKCU; Subkey: "Software\Classes\Applications\hibiki.exe\shell\open\command"; ValueType: string; ValueData: """{app}\hibiki.exe"" ""%1"""; Flags: uninsdeletekey; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Applications\hibiki.exe\SupportedTypes"; ValueType: string; ValueName: ".mkv"; ValueData: ""; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Applications\hibiki.exe\SupportedTypes"; ValueType: string; ValueName: ".mp4"; ValueData: ""; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Applications\hibiki.exe\SupportedTypes"; ValueType: string; ValueName: ".m4v"; ValueData: ""; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Applications\hibiki.exe\SupportedTypes"; ValueType: string; ValueName: ".avi"; ValueData: ""; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Applications\hibiki.exe\SupportedTypes"; ValueType: string; ValueName: ".webm"; ValueData: ""; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Applications\hibiki.exe\SupportedTypes"; ValueType: string; ValueName: ".mov"; ValueData: ""; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Applications\hibiki.exe\SupportedTypes"; ValueType: string; ValueName: ".ts"; ValueData: ""; Tasks: videoassoc

; 把 Hibiki.Video 挂到各扩展名的 OpenWithProgids（追加候选，不改默认关联）。
Root: HKCU; Subkey: "Software\Classes\.mkv\OpenWithProgids"; ValueType: string; ValueName: "Hibiki.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\.mp4\OpenWithProgids"; ValueType: string; ValueName: "Hibiki.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\.m4v\OpenWithProgids"; ValueType: string; ValueName: "Hibiki.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\.avi\OpenWithProgids"; ValueType: string; ValueName: "Hibiki.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\.webm\OpenWithProgids"; ValueType: string; ValueName: "Hibiki.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\.mov\OpenWithProgids"; ValueType: string; ValueName: "Hibiki.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\.ts\OpenWithProgids"; ValueType: string; ValueName: "Hibiki.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc

[Run]
Filename: "{app}\hibiki.exe"; Description: "启动 Hibiki"; Flags: nowait postinstall

[Code]
; -- TODO-549: app-internal self-update "AppMutex deadlock" root-cause layer --
; Regression source: TODO-431.
;
; The old app launches the new installer; Inno does its AppMutex check early
; (CheckForMutexes; per Inno source Setup.MainFunc.pas the InitializeSetup call
; runs BEFORE the CheckForMutexes loop) and finds some hibiki.exe / leftover
; process still holding HibikiSingleInstanceMutex, so it pops "Setup has
; detected that Hibiki is currently running". Under /VERYSILENT +
; /SUPPRESSMSGBOXES that OK/Cancel box defaults to Cancel -> Got EAbort ->
; immediate exit with no files replaced (real log:
; hibiki-*-windows-setup.install.log).
;
; Inno's CloseApplications / /CLOSEAPPLICATIONS go through RestartManager (by
; file usage) and are completely independent from the AppMutex check
; (CheckForMutexes), so they cannot suppress the mutex abort. The only layer
; that runs BEFORE the AppMutex check and can own the timing is this
; InitializeSetup: it actively terminates the running hibiki.exe and its
; WebView2 child processes, then bounded-polls until the mutex is truly
; released, then returns True; by the time Inno runs CheckForMutexes the mutex
; is gone, so it passes quietly -- no box, no abort. The [Setup] AppMutex= is
; kept as a fallback (if the poll times out with the mutex still held it
; degrades to the original prompt behaviour).

const
  HibikiAppMutexName = 'HibikiSingleInstanceMutex';
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

{ Probe whether the named mutex exists; close the handle immediately to avoid
  leaking (and to avoid the probe itself keeping a reference alive). }
function HibikiMutexExists(): Boolean;
var
  Handle: THandle;
begin
  Handle := OpenMutexW(SyncMutexAccess, False, HibikiAppMutexName);
  Result := Handle <> 0;
  if Result then
    CloseHandle(Handle);
end;

{ Gentle close: taskkill WITHOUT /F sends WM_CLOSE so the app can save state
  and release its mutex on its own. /T also targets child processes (the
  WebView2 msedgewebview2.exe runs as a hibiki.exe child). }
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

function InitializeSetup(): Boolean;
var
  Attempt: Integer;
begin
  Result := True;
  { No mutex = no running Hibiki, pass straight through (first install / the
    app has already exited cleanly). }
  if not HibikiMutexExists() then
    Exit;

  { Gentle first: WM_CLOSE gives the app a chance to save state and release the
    mutex on its own. }
  KillGracefully('hibiki.exe');
  for Attempt := 1 to GracefulCloseAttempts do
  begin
    if not HibikiMutexExists() then
      Exit;
    Sleep(MutexReleasePollIntervalMs);
  end;

  { Still alive: force-kill the hibiki.exe tree (WebView2 with it), then sweep
    any orphaned msedgewebview2.exe. }
  KillImage('hibiki.exe');
  KillImage('msedgewebview2.exe');

  { Bounded poll until the mutex is truly released; on timeout still return True
    (do not hang forever) and let the [Setup] AppMutex fallback handle it. }
  for Attempt := 1 to MutexReleasePollAttempts do
  begin
    if not HibikiMutexExists() then
      Exit;
    Sleep(MutexReleasePollIntervalMs);
  end;
end;
