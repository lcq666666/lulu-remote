; LULU-Host-Setup.iss — LULU Remote host installer (remote PC side).
;
; Run this on EACH remote Windows PC. One installer, Next-Next-Finish.
; Installs, in order:
;   1. Sunshine v2026.914.233613 (bundled, GPL-3.0 — see licenses\ in
;      the app folder).
;   2. Tailscale 1.104.7 (downloaded at install time from Tailscale's own
;      servers, SHA-256 verified — see installer/VERSIONS.md for why it
;      is not bundled).
;   3. Firewall rules for Sunshine + start Sunshine (finalize-host.ps1).
;   4. Opens https://localhost:47990 so the user creates the Sunshine
;      admin account once (LULU needs it once for in-app pairing).
;
; Build: CI only (see .github/workflows/build.yml):
;   1. installer\scripts\fetch-components.ps1   (fills installer\vendor\)
;   2. installer\scripts\build-installers.ps1
;

#ifndef AppVersion
  #error Build using installer/scripts/build-installers.ps1
#endif

[Setup]
AppId={{8D4E3B2C-5F6A-4E7B-8C9D-2F3E4A5B6C7D}
AppName=强哥远程主机
AppVersion={#AppVersion}
AppPublisher=强哥远程
DefaultDirName={autopf}\LULU Remote Host
DefaultGroupName=强哥远程主机
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=LULU-Host-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=强哥远程主机
LicenseFile=..\licenses\LULU-LICENSE.txt
; The installer is unsigned in v1 — Windows SmartScreen will warn on
; first run. A code-signing certificate is the only fix for that.

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "chs"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Files]
Source: "..\..\launcher\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "lulu_pairing_worker.exe"
Source: "..\..\launcher\build\windows\x64\runner\Release\lulu_pairing_worker.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\scripts\prepare-host.ps1"; DestDir: "{app}\vendor"; Flags: ignoreversion
; Sunshine installer, bundled (downloaded by fetch-components.ps1).
; Kept under {app}\vendor\ so it can be re-run by hand if needed.
Source: "..\vendor\Sunshine-Windows-AMD64-installer.msi"; DestDir: "{app}\vendor"; Flags: ignoreversion
; Tailscale download script (runs at install time, downloads from Tailscale).
Source: "..\scripts\install-tailscale.ps1"; DestDir: "{app}\vendor"; Flags: ignoreversion
; Host finalize script (firewall + start Sunshine).
Source: "finalize-host.ps1"; DestDir: "{app}\vendor"; Flags: ignoreversion
; Third-party licences + source offers (GPL compliance).
Source: "..\vendor\licenses\*"; DestDir: "{app}\licenses"; Flags: ignoreversion recursesubdirs
Source: "..\licenses\SUNSHINE-SOURCE-OFFER.txt"; DestDir: "{app}\licenses"; Flags: ignoreversion
Source: "..\licenses\TAILSCALE-NOTICE.txt"; DestDir: "{app}\licenses"; Flags: ignoreversion
Source: "..\vendor\MANIFEST.md"; DestDir: "{app}\licenses"; Flags: ignoreversion

[Registry]
Root: HKLM; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "LULU Remote Host"; ValueData: """{app}\lulu_remote.exe"" --tray"; Flags: uninsdeletevalue

[Icons]
Name: "{group}\强哥远程"; Filename: "{app}\lulu_remote.exe"
Name: "{group}\Sunshine"; Filename: "{autopf}\Sunshine\sunshine.exe"
Name: "{group}\{cm:UninstallProgram,强哥远程主机}"; Filename: "{uninstallexe}"

[Code]
procedure RunHostStep(const FileName, Params, Step: String; AllowRestart: Boolean);
var
  ResultCode: Integer;
begin
  if not Exec(FileName, Params, ExpandConstant('{app}'), SW_HIDE,
      ewWaitUntilTerminated, ResultCode) then
    RaiseException(Step + ' could not start. Windows error ' + IntToStr(ResultCode) + '.');
  if (ResultCode <> 0) and not (AllowRestart and (ResultCode = 3010)) then
    RaiseException(Step + ' failed. Exit code ' + IntToStr(ResultCode) + '.');
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  PowerShell: String;
begin
  if CurStep <> ssPostInstall then Exit;
  PowerShell := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  if not FileExists(ExpandConstant('{autopf}\Sunshine\sunshine.exe')) then
    RunHostStep(ExpandConstant('{sys}\msiexec.exe'),
      '/i "' + ExpandConstant('{app}\vendor\Sunshine-Windows-AMD64-installer.msi') + '" /qn /norestart',
      'Sunshine installation', True);
  RunHostStep(PowerShell, '-NoProfile -ExecutionPolicy Bypass -File "' +
      ExpandConstant('{app}\vendor\install-tailscale.ps1') + '"', 'Tailscale installation', False);
  RunHostStep(PowerShell, '-NoProfile -ExecutionPolicy Bypass -File "' +
    ExpandConstant('{app}\vendor\finalize-host.ps1') + '"', 'Sunshine startup and readiness check', False);
end;

[Run]
Filename: "https://localhost:47990"; Description: "打开 Sunshine 网页，创建管理员账号"; Flags: postinstall shellexec skipifsilent
Filename: "{app}\lulu_remote.exe"; Parameters: "--tray"; Description: "启动 LULU 配对提醒"; Flags: postinstall nowait skipifsilent runasoriginaluser

[UninstallRun]
; Uninstall removes LULU Host files only. Sunshine and Tailscale are
; left installed on purpose — silently removing someone's VPN or
; streaming host is not something an uninstaller should do.
