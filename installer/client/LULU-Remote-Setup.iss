; LULU-Remote-Setup.iss — LULU Remote client installer (control-side PC).
;
; One installer, Next-Next-Finish. Installs, in order:
;   1. LULU Remote launcher itself (Flutter build output).
;   2. Moonlight Qt v6.2.0 (bundled, GPL-3.0 — see licenses\ in the app folder).
;   3. Tailscale 1.104.7 (downloaded at install time from Tailscale's own
;      servers, SHA-256 verified — see installer/VERSIONS.md for why it
;      is not bundled).
;
; Build: CI only (see .github/workflows/build.yml):
;   1. flutter build windows --release
;   2. installer\scripts\fetch-components.ps1   (fills installer\vendor\)
;   3. iscc installer\client\LULU-Remote-Setup.iss
;
; The component installers are kept under {app}\vendor\ (not deleted
; after install) so LULU's first-run wizard can re-run them later if
; a component failed or was removed.
;
; NOT compiled yet: no Inno Setup on the Linux VM this was written on.
; Silent switches (/VERYSILENT) assume Moonlight's and Sunshine's
; installers are Inno Setup based — if CI's iscc run fails on them,
; check the vendor installers' actual silent switches first.

#define AppVersion "0.1.0"
#define MoonlightSetup "MoonlightSetup-6.2.0.exe"

[Setup]
AppId={{7C3F2A1B-4D5E-4F6A-9B8C-1E2D3F4A5B6C}
AppName=LULU Remote
AppVersion={#AppVersion}
AppPublisher=LULU Remote
DefaultDirName={autopf}\LULU Remote
DefaultGroupName=LULU Remote
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=LULU-Remote-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=LULU Remote
LicenseFile=..\licenses\LULU-LICENSE.txt
; The installer is unsigned in v1 — Windows SmartScreen will warn on
; first run. A code-signing certificate is the only fix for that.

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "chs"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; LULU launcher (Flutter Windows release output).
Source: "..\..\launcher\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Moonlight Qt installer, bundled (downloaded by fetch-components.ps1).
; Kept under {app}\vendor\ so the first-run wizard can re-run it.
Source: "..\vendor\MoonlightSetup-6.2.0.exe"; DestDir: "{app}\vendor"; Flags: ignoreversion
; Tailscale download script (runs at install time, downloads from Tailscale).
Source: "..\scripts\install-tailscale.ps1"; DestDir: "{app}\vendor"; Flags: ignoreversion
; Third-party licences + source offers (GPL compliance).
Source: "..\vendor\licenses\*"; DestDir: "{app}\licenses"; Flags: ignoreversion recursesubdirs
Source: "..\licenses\MOONLIGHT-SOURCE-OFFER.txt"; DestDir: "{app}\licenses"; Flags: ignoreversion
Source: "..\licenses\TAILSCALE-NOTICE.txt"; DestDir: "{app}\licenses"; Flags: ignoreversion
Source: "..\vendor\MANIFEST.md"; DestDir: "{app}\licenses"; Flags: ignoreversion

[Icons]
Name: "{group}\LULU Remote"; Filename: "{app}\lulu_remote.exe"
Name: "{group}\{cm:UninstallProgram,LULU Remote}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\LULU Remote"; Filename: "{app}\lulu_remote.exe"; Tasks: desktopicon

[Code]
function MoonlightInstalled: Boolean;
begin
  Result := FileExists('C:\Program Files\Moonlight\moonlight-qt.exe')
    or FileExists('C:\Program Files (x86)\Moonlight\moonlight-qt.exe')
    or FileExists(ExpandConstant('{localappdata}\Programs\Moonlight\moonlight-qt.exe'));
end;

function TailscaleInstalled: Boolean;
begin
  Result := FileExists('C:\Program Files\Tailscale\tailscale.exe');
end;

[Run]
; Moonlight Qt, silent. Skipped if already installed.
Filename: "{app}\vendor\MoonlightSetup-6.2.0.exe"; Parameters: "/VERYSILENT /NORESTART /SUPPRESSMSGBOXES"; StatusMsg: "正在安装 Moonlight Qt…"; Check: not MoonlightInstalled; Flags: waituntilterminated
; Tailscale, downloaded + SHA-256 verified + silently installed by script.
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -NoProfile -File ""{app}\vendor\install-tailscale.ps1"""; StatusMsg: "正在安装 Tailscale（从官网下载并校验）…"; Check: not TailscaleInstalled; Flags: waituntilterminated
; Offer to launch LULU at the end. Tailscale sign-in happens from the
; Tailscale tray icon; LULU's setup checklist shows whether it is up.
Filename: "{app}\lulu_remote.exe"; Description: "运行 LULU 远程"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Uninstall removes LULU itself only. Moonlight and Tailscale are left
; installed on purpose — other software may use them, and silently
; removing someone's VPN is not something an uninstaller should do.
