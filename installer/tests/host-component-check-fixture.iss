[Setup]
AppName=QG host component test
AppVersion=1.0
DefaultDirName={tmp}\QGHostComponentTest
PrivilegesRequired=lowest
Uninstallable=no
CreateUninstallRegKey=no
OutputBaseFilename=host-component-check
OutputDir=.
RestartIfNeededByRun=no

[Files]
Source: "install-tailscale.ps1"; DestDir: "{app}\vendor"
Source: "finalize-host.ps1"; DestDir: "{app}\vendor"
Source: "launcher-marker.txt"; DestDir: "{app}"

[Code]
#include "host-component-checks.iss"

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := PrepareHostComponents(False, NeedsRestart);
end;
