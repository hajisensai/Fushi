# --------------------------------------------------------------------------
# package_windows.ps1 - Build shadow JAR -> custom JRE (jlink) -> Windows bundle
#
# Creates a portable .zip bundle with embedded JRE.
# Optionally creates an .exe installer using Inno Setup (if installed).
#
# Usage (PowerShell):
#   .\package_windows.ps1
#   .\package_windows.ps1 -BuildInstaller
# --------------------------------------------------------------------------

param(
    [switch]$BuildInstaller = $true
)

$ErrorActionPreference = "Stop"

$APP_NAME = "MExtensionServer"
$BUNDLE_NAME = "MExtensionServer-Windows-x64"
$DEST = "dist"
$ICON_SRC = "server/src/main/resources/icon-black.png"

# Check tools
Write-Host "[*] Checking prerequisites..."

$tools = @("java", "jlink", "magick")  # magick = ImageMagick (for ICO conversion)
foreach ($tool in $tools) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        if ($tool -eq "magick") {
            Write-Host "  [!] Warning: ImageMagick not found. Icon conversion skipped."
            Write-Host "      Download from https://imagemagick.org/script/download.php"
        } else {
            Write-Host "[ERROR] Error: '$tool' not found."
            exit 1
        }
    }
}

# Build shadow JAR
Write-Host ""
Write-Host "[*] Building shadow JAR..."
& .\gradlew.bat shadowJar

$jarFile = Get-ChildItem "server/build/${APP_NAME}-*.jar" | Select-Object -Last 1
if (-not $jarFile) {
    Write-Host "[ERROR] Error: JAR not found in server/build/"
    exit 1
}
$jarName = $jarFile.Name
Write-Host "  JAR: $($jarFile.FullName)"

# Convert PNG -> ICO
$icoFile = ""
if (Test-Path $ICON_SRC) {
    Write-Host ""
    Write-Host "[*] Converting icon to .ico..."
    $icoDir = [System.IO.Path]::GetTempPath() + [System.IO.Path]::GetRandomFileName()
    New-Item -ItemType Directory -Path $icoDir -Force | Out-Null
    
    $icoOutput = "$icoDir\AppIcon.ico"
    try {
        # ImageMagick to convert PNG -> ICO
        & magick convert "$ICON_SRC" -define icon:auto-resize=256,128,96,64,48,32,16 "$icoOutput"
        if (Test-Path $icoOutput) {
            $icoFile = $icoOutput
            Write-Host "  Icon: $icoFile"
        } else {
            Write-Host "  [!] Icon conversion failed, skipping"
        }
    } catch {
        Write-Host "  [!] Icon conversion failed: $_"
    }
} else {
    Write-Host "  Warning: Icon not found at $ICON_SRC"
}

# Build custom JRE with jlink
$jreTmpDir = ".jre_build_tmp"
if (Test-Path $jreTmpDir) { Remove-Item -Recurse -Force $jreTmpDir }

Write-Host ""
Write-Host "[*] Building custom JRE with jlink..."
$modules = @(
    "java.base","java.compiler","java.datatransfer","java.desktop","java.instrument",
    "java.logging","java.management","java.naming","java.prefs","java.scripting","java.se",
    "java.security.jgss","java.security.sasl","java.sql","java.transaction.xa","java.xml",
    "jdk.attach","jdk.crypto.ec","jdk.jdi","jdk.management","jdk.net","jdk.unsupported",
    "jdk.unsupported.desktop","jdk.zipfs","jdk.accessibility"
) -join ","

& jlink `
    --add-modules "$modules" `
    --output "$jreTmpDir" `
    --strip-debug `
    --no-man-pages `
    --no-header-files `
    --compress=2

$jreSizeMB = [math]::Round((Get-ChildItem -Recurse $jreTmpDir | Measure-Object -Property Length -Sum).Sum / 1MB, 2)
Write-Host "  JRE size: ${jreSizeMB} MB"

# Assemble bundle
Write-Host ""
Write-Host "[*] Assembling Windows bundle..."

$bundleDir = "$DEST\$BUNDLE_NAME"
if (Test-Path $bundleDir) { Remove-Item -Recurse -Force $bundleDir }
New-Item -ItemType Directory -Path "$bundleDir/jre", "$bundleDir/bin" -Force | Out-Null

# 4a. Copy JRE
Copy-Item -Recurse -Path "$jreTmpDir\*" -Destination "$bundleDir/jre"
Remove-Item -Recurse -Force $jreTmpDir

# 4b. Copy JAR
Copy-Item -Path $jarFile.FullName -Destination "$bundleDir/$jarName"

# 4c. Create launcher.bat (with console)
$batContent = @"
@echo off
setlocal enabledelayedexpansion

REM Get the directory where this batch file is located
set SCRIPT_DIR=%~dp0
set JAVA=%SCRIPT_DIR%jre\bin\java.exe
set JAR=
for /f %%f in ('dir /b "%SCRIPT_DIR%*.jar"') do set JAR=%%f

"%JAVA%" ^
  -Xmx512m ^
  --add-opens=java.base/java.lang=ALL-UNNAMED ^
  --add-opens=java.base/java.util=ALL-UNNAMED ^
  --add-opens=java.base/java.lang.reflect=ALL-UNNAMED ^
  -Dapple.awt.application.name="MExtension Server" ^
  -jar "%SCRIPT_DIR%!JAR!" ^
  --ui ^
  %*

endlocal
"@
Set-Content -Path "$bundleDir\launcher.bat" -Value $batContent -Encoding ASCII

# 4d. Create launcher.vbs (no console window, GUI only)
$vbsContent = @"
Set objShell = CreateObject("WScript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")

scriptDir = objFSO.GetParentFolderName(WScript.ScriptFullName)
javaExe = scriptDir & "\jre\bin\javaw.exe"
jarFile = ""

Set folder = objFSO.GetFolder(scriptDir)
For Each file In folder.Files
    If LCase(objFSO.GetExtensionName(file.Name)) = "jar" Then
        jarFile = file.Path
        Exit For
    End If
Next

If jarFile = "" Then
    objShell.Popup "JAR file not found!", 0, "Error", 48
    WScript.Quit 1
End If

cmdLine = javaExe & " -Xmx512m" & _
    " --add-opens=java.base/java.lang=ALL-UNNAMED" & _
    " --add-opens=java.base/java.util=ALL-UNNAMED" & _
    " --add-opens=java.base/java.lang.reflect=ALL-UNNAMED" & _
    " -jar """ & jarFile & """ --ui"

objShell.Run cmdLine, 0, False
"@
Set-Content -Path "$bundleDir\launcher.vbs" -Value $vbsContent -Encoding ASCII

# 4e. Copy icon
if ($icoFile -and (Test-Path $icoFile)) {
    Copy-Item -Path $icoFile -Destination "$bundleDir\AppIcon.ico"
    Remove-Item -Recurse -Force (Split-Path $icoFile)
}

# 4f. Create README.txt
$readmeContent = @"
MExtension Server for Windows
==============================

QUICK START:
  1. Double-click launcher.vbs to run the app (recommended)
     OR launcher.bat to run with console output

REQUIREMENTS:
  None! Everything is bundled (JRE is included).

UNINSTALL:
  Delete this entire folder. No registry entries are created.

COMMAND-LINE:
  launcher.bat [port] [appdir]
  Example: launcher.bat 8080 ./data

MORE INFO:
  https://github.com/kodjodevf/m-extension-server

"@
Set-Content -Path "$bundleDir\README.txt" -Value $readmeContent -Encoding ASCII

Write-Host ""
Write-Host "[OK] Bundle created: $bundleDir"
Write-Host "   Run: .\launcher.vbs   (recommended, no console)"
Write-Host "   Or:  .\launcher.bat   (with console)"

# Create portable .zip
Write-Host ""
Write-Host "[*] Creating .zip archive..."
$zipPath = "$DEST\$BUNDLE_NAME.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath }

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($bundleDir, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)

Write-Host "[OK] Portable ZIP: $zipPath"

# Optional: Build Inno Setup installer
if ($BuildInstaller) {
    if (Get-Command "iscc" -ErrorAction SilentlyContinue) {
        Write-Host ""
        Write-Host "[*] Building Inno Setup installer..."
        
        $bundleAbsPath = (Get-Item $bundleDir).FullName
        $distAbsPath = (Get-Item $DEST).FullName
        
        # Create .iss script
        $issLines = @(
            '#define MyAppName "MExtension Server"',
            '#define MyAppVersion "1.0.0"',
            '#define MyAppPublisher "kodjodevf"',
            "#define SourceDir `"$bundleAbsPath`"",
            '',
            '[Setup]',
            'AppId={{3E8F8E42-5A8C-4B1A-9E2B-8F8E8E8E8E8E}}',
            'AppName={#MyAppName}',
            'AppVersion={#MyAppVersion}',
            'AppPublisher={#MyAppPublisher}',
            'DefaultDirName={autopf}\{#MyAppName}',
            'DefaultGroupName={#MyAppName}',
            'AllowNoIcons=yes',
            'WizardStyle=modern',
            'Compression=lzma',
            'SolidCompression=yes',
            "OutputDir=$distAbsPath",
            'OutputBaseFilename=MExtensionServer-{#MyAppVersion}-setup-x64',
            'ArchitecturesAllowed=x64',
            'ArchitecturesInstallIn64BitMode=x64',
            '',
            '[Languages]',
            'Name: "en"; MessagesFile: "compiler:Default.isl"',
            '',
            '[Files]',
            'Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs; Excludes: "Setup.iss"',
            '',
            '[Icons]',
            'Name: "{group}\{#MyAppName}"; Filename: "{app}\launcher.vbs"; IconFilename: "{app}\AppIcon.ico"',
            'Name: "{commondesktop}\{#MyAppName}"; Filename: "{app}\launcher.vbs"; IconFilename: "{app}\AppIcon.ico"',
            '',
            '[Run]',
            'Filename: "{app}\launcher.vbs"; Description: "Launch {#MyAppName}"; Flags: shellexec nowait postinstall skipifsilent'
        )
        $issContent = $issLines -join "`n"
        $issFile = "$DEST\Setup.iss"
        Set-Content -Path $issFile -Value $issContent -Encoding ASCII
        
        # Run Inno Setup compiler
        & iscc "$issFile"
        Remove-Item $issFile -ErrorAction SilentlyContinue
        
        $setupExe = Get-ChildItem "$DEST\MExtensionServer-*-setup.exe" -ErrorAction SilentlyContinue | Select-Object -Last 1
        if ($setupExe) {
            Write-Host "[OK] Installer created: $($setupExe.FullName)"
        } else {
            Write-Host "[OK] Installer compilation completed"
        }
    } else {
        Write-Host ""
        Write-Host "[!] Inno Setup not installed. Skipping installer build."
        Write-Host "    Download from https://jrsoftware.org/isdl.php"
    }
}

Write-Host ""
Write-Host "Done!"
