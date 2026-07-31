; Modbus TCP/IP Tester - Inno Setup Installer Script
; ====================================================
; To build: Open this file in Inno Setup Compiler and click Build > Compile
; Download Inno Setup from: https://jrsoftware.org/isdl.php

#define MyAppName "Modbus TCP/IP Tester"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Industrial Tools"
#define MyAppURL "https://github.com/your-repo/modbus-tester"
#define MyAppExeName "start.bat"

; IMPORTANT: Set this to the folder where your project files are located
#define MySourceDir "C:\Users\abrah\.gemini\antigravity\scratch\modbus-tester"

[Setup]
AppId={{B7E3F2A1-4D8C-4F5E-9A2B-6C1D3E8F0A4B}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
OutputDir={#MySourceDir}\installer_output
OutputBaseFilename=ModbusTester_Setup_v{#MyAppVersion}
SetupIconFile={#MySourceDir}\app.ico
UninstallDisplayIcon={app}\app.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile=
MinVersion=10.0
DisableProgramGroupPage=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "firewallrule"; Description: "Add Windows Firewall exception (required for Modbus TCP)"; GroupDescription: "Network Configuration:"; Flags: checkedonce

[Files]
; Core application files
Source: "{#MySourceDir}\server.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#MySourceDir}\start.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#MySourceDir}\app.ico"; DestDir: "{app}"; Flags: ignoreversion

; Web UI files
Source: "{#MySourceDir}\public\index.html"; DestDir: "{app}\public"; Flags: ignoreversion
Source: "{#MySourceDir}\public\app.js"; DestDir: "{app}\public"; Flags: ignoreversion
Source: "{#MySourceDir}\public\styles.css"; DestDir: "{app}\public"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\app.ico"; WorkingDir: "{app}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\app.ico"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
; Open the app after install
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent shellexec; WorkingDir: "{app}"

; Add firewall rule for Modbus TCP
Filename: "netsh"; Parameters: "advfirewall firewall add rule name=""Modbus TCP/IP Tester"" dir=in action=allow protocol=TCP localport=10502 program=any"; Flags: runhidden; Tasks: firewallrule
Filename: "netsh"; Parameters: "advfirewall firewall add rule name=""Modbus TCP/IP Tester HTTP"" dir=in action=allow protocol=TCP localport=8080 program=any"; Flags: runhidden; Tasks: firewallrule

[UninstallRun]
; Remove firewall rules on uninstall
Filename: "netsh"; Parameters: "advfirewall firewall delete rule name=""Modbus TCP/IP Tester"""; Flags: runhidden
Filename: "netsh"; Parameters: "advfirewall firewall delete rule name=""Modbus TCP/IP Tester HTTP"""; Flags: runhidden

[Code]
// Check if PowerShell 5.1+ is available (required)
function InitializeSetup(): Boolean;
var
  PSVersion: String;
begin
  Result := True;
  if not RegQueryStringValue(HKLM, 'SOFTWARE\Microsoft\PowerShell\3\PowerShellEngine', 'PowerShellVersion', PSVersion) then
  begin
    if MsgBox('PowerShell 5.1 or later is required but was not detected.' + #13#10 +
              'Windows 10/11 includes PowerShell by default.' + #13#10#13#10 +
              'Continue anyway?', mbConfirmation, MB_YESNO) = IDNO then
      Result := False;
  end;
end;
