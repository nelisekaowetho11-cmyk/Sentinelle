; Inno Setup script for the Sentinelle desktop client.
;
; Build the app and bundle the core first:
;     cd clients/sentinelle
;     flutter build windows --release
;     python tool/bundle_core.py
;
; Then compile this script:
;     "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" windows\packaging\sentinelle.iss
;
; The output lands in dist\SentinelleSetup-<version>.exe.
;
; .github/workflows/windows.yml runs exactly these three steps, so a change
; here is a change to what CI publishes.

#define AppName        "Sentinelle"
#define AppPublisher   "Sentinelle"
#define AppExeName     "Sentinelle.exe"
#define SourceDir      "..\..\build\windows\x64\runner\Release"

; Read the version straight out of the built exe so the installer can never
; disagree with what it is installing.
#define AppVersion GetVersionNumbersString(SourceDir + "\" + AppExeName)
#if AppVersion == ""
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{8F3C1B92-4A7E-4E2E-9C41-6E1B2D5A7C33}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=..\..\dist
OutputBaseFilename=SentinelleSetup-{#AppVersion}
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible
; Per-machine install: VPN mode needs administrator rights anyway, and a
; machine-wide install keeps the elevated and normal runs pointing at the
; same folder.
PrivilegesRequired=admin
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "startupicon"; Description: "Start {#AppName} when Windows starts"; GroupDescription: "Startup"; Flags: unchecked

[Files]
; The whole Flutter release folder, including the bundled sing-box core and
; its libcronet.dll. recursesubdirs picks up data\ and the plugin DLLs.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon
Name: "{userstartup}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: startupicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Stop a running core before removing files, so nothing is left holding the
; tunnel open or the system proxy pointed at a dead listener.
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM sing-box.exe /T"; Flags: runhidden; RunOnceId: "KillCore"
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM {#AppExeName} /T"; Flags: runhidden; RunOnceId: "KillApp"

[UninstallDelete]
; Config and the managed core copy live in the user's app-data folder.
Type: filesandordirs; Name: "{localappdata}\{#AppPublisher}\{#AppName}"

[Code]
{ Close a running copy before any file is written.

  A running Sentinelle holds Sentinelle.exe and data\app.so open, and Windows
  refuses to overwrite either. CloseApplications does not always catch it —
  the window can be hidden in the tray, where the Restart Manager cannot see
  it — and the install then reports success having replaced everything except
  the two files that carry the code. The result is the new version's assets
  wrapped around the old version's binary, which reports the old version and
  is very hard to explain afterwards. }
procedure KillProcess(const ExeName, Flags: String);
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), Flags + ' /IM ' + ExeName, '',
       SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  { Asked politely first: this sends a close request, which lets the app run
    its own shutdown and put the system proxy back the way it found it. }
  KillProcess('Sentinelle.exe', '');
  Sleep(2500);
  { Then not politely. A window hidden in the tray ignores the request above,
    and an update that silently does nothing is worse than a lost session. }
  KillProcess('Sentinelle.exe', '/F /T');
  KillProcess('sing-box.exe', '/F /T');
  Result := '';
end;

{ Put the Windows proxy back if an uninstall happens while the app had it set.
  The app does this itself on exit, but an uninstall after a crash should not
  leave the machine pointing at a proxy that no longer exists. }
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ProxyServer: String;
begin
  if CurUninstallStep = usUninstall then
  begin
    if RegQueryStringValue(HKCU,
         'Software\Microsoft\Windows\CurrentVersion\Internet Settings',
         'ProxyServer', ProxyServer) then
    begin
      { Only touch it if it is ours — never clobber a proxy the user set. }
      if Pos('127.0.0.1:', ProxyServer) = 1 then
      begin
        RegWriteDWordValue(HKCU,
          'Software\Microsoft\Windows\CurrentVersion\Internet Settings',
          'ProxyEnable', 0);
        RegDeleteValue(HKCU,
          'Software\Microsoft\Windows\CurrentVersion\Internet Settings',
          'ProxyServer');
      end;
    end;
  end;
end;
