param([string]$Compiler = 'iscc.exe')

$ErrorActionPreference = 'Stop'
$version = & (Join-Path $PSScriptRoot 'read-app-version.ps1')
$installer = Split-Path -Parent $PSScriptRoot
foreach ($file in @('client/LULU-Remote-Setup.iss', 'host/LULU-Host-Setup.iss')) {
    & $Compiler "/DAppVersion=$version" (Join-Path $installer $file)
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed compiling $file ($LASTEXITCODE)." }
}
