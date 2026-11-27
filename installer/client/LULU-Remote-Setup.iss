; LULU-Remote-Setup.iss — unified Windows installer.
;
; One installer for controlling other computers and enabling this host.
; The front end installs first. Components are prepared when requested.
;   1. LULU Remote launcher itself (Flutter build output).
;   2. Moonlight Qt v6.2.0 (bundled, GPL-3.0 — see licenses\ in the app folder).
;   3. Sunshine (bundled, GPL-3.0).
; Optional cross-network setup can download Tailscale after installation.
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
#define AppVersion "0.2.0"
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
RestartIfNeededByRun=no
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
Source: "..\vendor\moonlight\*"; DestDir: "{app}\vendor\moonlight"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\vendor\Sunshine-Windows-AMD64-installer.msi"; DestDir: "{app}\vendor"; Flags: ignoreversion
Source: "..\scripts\prepare-host.ps1"; DestDir: "{app}\vendor"; Flags: ignoreversion
; Tailscale download script (runs at install time, downloads from Tailscale).
Source: "..\scripts\install-tailscale.ps1"; DestDir: "{app}\vendor"; Flags: ignoreversion
; Third-party licences + source offers (GPL compliance).
Source: "..\vendor\licenses\*"; DestDir: "{app}\licenses"; Flags: ignoreversion recursesubdirs
Source: "..\licenses\MOONLIGHT-SOURCE-OFFER.txt"; DestDir: "{app}\licenses"; Flags: ignoreversion
Source: "..\licenses\SUNSHINE-SOURCE-OFFER.txt"; DestDir: "{app}\licenses"; Flags: ignoreversion
Source: "..\licenses\TAILSCALE-NOTICE.txt"; DestDir: "{app}\licenses"; Flags: ignoreversion
Source: "..\vendor\MANIFEST.md"; DestDir: "{app}\licenses"; Flags: ignoreversion

[Icons]
Name: "{group}\LULU Remote"; Filename: "{app}\lulu_remote.exe"
Name: "{group}\{cm:UninstallProgram,LULU Remote}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\LULU Remote"; Filename: "{app}\lulu_remote.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\lulu_remote.exe"; Description: "运行 LULU 远程"; Flags: nowait postinstall skipifsilent
