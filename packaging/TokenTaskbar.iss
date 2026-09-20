#ifndef AppVersion
  #define AppVersion "1.1.0"
#endif

[Setup]
AppId={{2C120954-A503-488A-B755-21901FD0EA94}
AppName=TokenTaskbar
AppVersion={#AppVersion}
AppPublisher=A6721jpn
AppPublisherURL=https://github.com/A6721jpn/token-taskbar
AppSupportURL=https://github.com/A6721jpn/token-taskbar/issues
DefaultDirName={localappdata}\Programs\TokenTaskbar
DefaultGroupName=TokenTaskbar
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
OutputDir=..\dist
OutputBaseFilename=TokenTaskbar-{#AppVersion}-win-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=TokenTaskbar
AppMutex=Local\CodexTokenTaskbarTray
SetupMutex=TokenTaskbarSetup
CloseApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"

[Tasks]
Name: "startup"; Description: "Start TokenTaskbar when I sign in"; Flags: checkedonce

[Files]
Source: "..\app\TokenTaskbar.ps1"; DestDir: "{app}\app"; Flags: ignoreversion
Source: "..\app\read_codex_rate_limits.py"; DestDir: "{app}\app"; Flags: ignoreversion
Source: "..\launch-powershell-hidden.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\start-token-taskbar.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\.build\runtime\*"; DestDir: "{app}\runtime"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\TokenTaskbar"; Filename: "{sys}\wscript.exe"; Parameters: "//nologo ""{app}\launch-powershell-hidden.vbs"" ""{app}\app\TokenTaskbar.ps1"""; WorkingDir: "{app}"
Name: "{group}\Uninstall TokenTaskbar"; Filename: "{uninstallexe}"
Name: "{userstartup}\TokenTaskbar"; Filename: "{sys}\wscript.exe"; Parameters: "//nologo ""{app}\launch-powershell-hidden.vbs"" ""{app}\app\TokenTaskbar.ps1"""; WorkingDir: "{app}"; Tasks: startup

[Run]
Filename: "{sys}\wscript.exe"; Parameters: "//nologo ""{app}\launch-powershell-hidden.vbs"" ""{app}\app\TokenTaskbar.ps1"""; Description: "Launch TokenTaskbar"; Flags: nowait postinstall skipifsilent
