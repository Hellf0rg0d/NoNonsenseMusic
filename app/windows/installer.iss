; The Windows installer, NoNonsenseMusic-Setup.exe: built by .github/workflows/windows.yml with Inno Setup, from the
; release build. Installs for the current user (no administrator prompt) into %LOCALAPPDATA%\Programs, with a Start menu
; entry, an optional desktop icon and an uninstaller in Settings > Apps. A newer setup replaces the version installed,
; closing the app first, and an update the app downloads itself runs it silently. The workflow passes the version and the
; build's folder:
;   iscc /DAppVersion=0.3.0 /DSourceDir=<build folder> installer.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\build\windows\x64\runner\Release"
#endif

[Setup]
; the same id for every version: a newer setup is an update of this app, not a second one
AppId={{6E0B9C1A-4D7F-4C2B-9E3A-5B8D2F1C7A64}
AppName=NoNonsenseMusic
AppVersion={#AppVersion}
AppVerName=NoNonsenseMusic {#AppVersion}
AppPublisher=NoNonsenseMusic
AppPublisherURL=https://github.com/ego004/NoNonsenseMusic
AppSupportURL=https://github.com/ego004/NoNonsenseMusic/issues
AppUpdatesURL=https://github.com/ego004/NoNonsenseMusic/releases
VersionInfoVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\NoNonsenseMusic
DefaultGroupName=NoNonsenseMusic
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\NoNonsenseMusic.exe
UninstallDisplayName=NoNonsenseMusic
WizardStyle=modern
Compression=lzma2/ultra
SolidCompression=yes
CloseApplications=yes
OutputDir=..\build\installer
OutputBaseFilename=NoNonsenseMusic-Setup

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\NoNonsenseMusic"; Filename: "{app}\NoNonsenseMusic.exe"
Name: "{autodesktop}\NoNonsenseMusic"; Filename: "{app}\NoNonsenseMusic.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\NoNonsenseMusic.exe"; Description: "{cm:LaunchProgram,NoNonsenseMusic}"; Flags: nowait postinstall skipifsilent
; an in-place update (lib/core/update_check.dart) runs this setup silently after the app quits: the new version opens
Filename: "{app}\NoNonsenseMusic.exe"; Flags: nowait; Check: WizardSilent
