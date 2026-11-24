; The Windows installer: fweek-<version>-windows-x64-setup.exe.
;
;   flutter build windows --release
;   iscc /DAppVersion=1.2.3 windows\installer\fweek.iss
;
; Installs for the current user, without administrator rights, into
; %LOCALAPPDATA%\Programs\fweek. An update installs over the earlier version
; (closing fweek if it is open). The planner itself is in
; %APPDATA%\yourj4m\fweek and its passwords are encrypted with the user's
; Windows login; neither an update nor removing the app touches them.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
; Identifies the app to Windows' list of installed programs: fixed, or an
; update would be a second program.
AppId={{8CF6C11F-6A3E-4B87-A995-11EDA38C196F}
AppName=fweek
AppVersion={#AppVersion}
AppVerName=fweek {#AppVersion}
AppPublisher=yourj4m
AppPublisherURL=https://github.com/yourj4m/fweek
AppSupportURL=https://github.com/yourj4m/fweek/issues
DefaultDirName={autopf}\fweek
DefaultGroupName=fweek
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\dist
OutputBaseFilename=fweek-{#AppVersion}-windows-x64-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\fweek.exe
UninstallDisplayName=fweek
LicenseFile=..\..\LICENSE
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; The shortcut carries the app id the program gives itself (see
; windows\runner\main.cpp): Windows shows an app's notifications only when
; a Start-menu shortcut names it.
Name: "{autoprograms}\fweek"; Filename: "{app}\fweek.exe"; AppUserModelID: "yourj4m.fweek"
Name: "{autodesktop}\fweek"; Filename: "{app}\fweek.exe"; AppUserModelID: "yourj4m.fweek"; Tasks: desktopicon

[Run]
Filename: "{app}\fweek.exe"; Description: "{cm:LaunchProgram,fweek}"; Flags: nowait postinstall skipifsilent
