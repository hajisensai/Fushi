; ─────────────────────────────────────────────────────────────────────────────
; setup.iss – Inno Setup template for MExtension Server installer
;
; Usage:
;   1. Download Inno Setup from https://jrsoftware.org/isdl.php
;   2. Edit the [Setup] section below with correct version
;   3. In PowerShell: .\package_windows.ps1 -BuildInstaller
;
; Or manually:
;   iscc setup.iss
; ─────────────────────────────────────────────────────────────────────────────

#define MyAppName "MExtension Server"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "kodjodevf"
#define MyAppURL "https://github.com/kodjodevf/m-extension-server"
#define SourceBundle "dist\MExtensionServer-Windows-x64"

[Setup]
; Unique ID for the app
AppId={{3E8F8E42-5A8C-4B1A-9E2B-8F8E8E8E8E8E}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}

DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes

; Compression settings
CompressionLevel=max
SolidCompression=yes

; UI
WizardStyle=modern
WizardImageFile=compiler:WizModernImage.bmp
WizardSmallImageFile=compiler:WizModernSmallImage.bmp

; Output
OutputDir=dist
OutputBaseFilename={#MyAppName}-{#MyAppVersion}-setup-x64
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64

; Disable confirmations for uninstall
UninstallDisplayIcon={app}\AppIcon.ico

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "fr"; MessagesFile: "compiler:French.isl"

[Files]
Source: "{#SourceBundle}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs; Excludes: "Setup.iss"
Source: "{#SourceBundle}\AppIcon.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\launcher.vbs"; \
    IconFilename: "{app}\AppIcon.ico"; Comment: "MExtension Server GUI"
Name: "{commondesktop}\{#MyAppName}"; Filename: "{app}\launcher.vbs"; \
    IconFilename: "{app}\AppIcon.ico"; Comment: "MExtension Server GUI"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\launcher.vbs"; Description: "Launch {#MyAppName} now"; \
    Flags: shellexec nowait postinstall skipifsilent

[Code]
{ Clean up temp icon conversion directory if it exists }
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    { Add any cleanup here if needed }
  end;
end;
