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
;   2. iscc installer\host\LULU-Host-Setup.iss
;

#define AppVersion "0.1.0"

[Setup]
AppId={{8D4E3B2C-5F6A-4E7B-8C9D-2F3E4A5B6C7D}
AppName=LULU Remote Host
AppVersion={#AppVersion}
AppPublisher=LULU Remote
DefaultDirName={autopf}\LULU Remote Host
DefaultGroupName=LULU Remote Host
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=LULU-Host-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=LULU Remote Host
LicenseFile=..\licenses\LULU-LICENSE.txt
; The installer is unsigned in v1 — Windows SmartScreen will warn on
; first run. A code-signing certificate is the only fix for that.

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "chs"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Files]
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

[Icons]
Name: "{group}\Sunshine"; Filename: "{autopf}\Sunshine\sunshine.exe"
Name: "{group}\{cm:UninstallProgram,LULU Remote Host}"; Filename: "{uninstallexe}"

[Code]
function SunshineInstalled: Boolean;
begin
  Result := FileExists('C:\Program Files\Sunshine\sunshine.exe');
end;

function TailscaleInstalled: Boolean;
begin
  Result := FileExists('C:\Program Files\Tailscale\tailscale.exe');
end;

[Run]
; Sunshine, silent. Skipped if already installed.
Filename: "{sys}\msiexec.exe"; Parameters: "/i ""{app}\vendor\Sunshine-Windows-AMD64-installer.msi"" /qn /norestart"; StatusMsg: "正在安装 Sunshine…"; Check: not SunshineInstalled; Flags: waituntilterminated
; Tailscale, downloaded + SHA-256 verified + silently installed by script.
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -NoProfile -File ""{app}\vendor\install-tailscale.ps1"""; StatusMsg: "正在安装 Tailscale（从官网下载并校验）…"; Check: not TailscaleInstalled; Flags: waituntilterminated
; Firewall rules + start Sunshine.
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -NoProfile -File ""{app}\vendor\finalize-host.ps1"""; StatusMsg: "正在配置 Sunshine…"; Flags: waituntilterminated
; Open the Sunshine web UI so the user creates the admin account once.
; LULU needs that username + password once for in-app pairing.
Filename: "https://localhost:47990"; Description: "打开 Sunshine 网页，创建管理员账号"; Flags: postinstall shellexec skipifsilent

[UninstallRun]
; Uninstall removes LULU Host files only. Sunshine and Tailscale are
; left installed on purpose — silently removing someone's VPN or
; streaming host is not something an uninstaller should do.
