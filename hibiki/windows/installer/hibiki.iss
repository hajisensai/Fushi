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
CloseApplications=yes
CloseApplicationsFilter=*.exe,*.dll
RestartApplications=yes
AppMutex=HibikiSingleInstanceMutex

[Tasks]
; 可选：把 Hibiki 注册为视频文件的「打开方式」候选（不抢占系统默认播放器，
; 只在资源管理器右键「打开方式」里出现 Hibiki，并支持拖视频到 hibiki.exe）。
Name: "videoassoc"; Description: "将 Hibiki 加入视频文件的「打开方式」（mkv / mp4 等）"; GroupDescription: "文件关联："

[Files]
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
