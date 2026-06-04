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
RestartApplications=no
AppMutex=HibikiSingleInstanceMutex

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Hibiki"; Filename: "{app}\hibiki.exe"
Name: "{userdesktop}\Hibiki"; Filename: "{app}\hibiki.exe"

[Run]
Filename: "{app}\hibiki.exe"; Description: "启动 Hibiki"; Flags: nowait postinstall
