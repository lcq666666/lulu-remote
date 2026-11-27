param([string]$Version = '0.2.1')

$ErrorActionPreference = 'Stop'
$installer = Split-Path -Parent $PSScriptRoot
$vendor = Join-Path $installer 'vendor'
$dist = Join-Path $installer 'dist'
$staging = Join-Path ([IO.Path]::GetTempPath()) ('lulu-portable-' + [guid]::NewGuid())
$app = Join-Path $staging 'LULU Remote'
New-Item -ItemType Directory -Path $app, $dist -Force | Out-Null

$runner = Join-Path (Split-Path -Parent $installer) 'launcher/build/windows/x64/runner/Release'
Copy-Item -Path "$runner\*" -Destination $app -Recurse
if (!(Test-Path -LiteralPath (Join-Path $app 'lulu_remote.exe'))) {
    throw 'Windows launcher executable is missing.'
}

$appVendor = Join-Path $app 'vendor'
$licenses = Join-Path $app 'licenses'
New-Item -ItemType Directory -Path $appVendor, $licenses | Out-Null
Copy-Item -LiteralPath (Join-Path $vendor 'moonlight') -Destination $appVendor -Recurse
foreach ($file in @('MoonlightSetup-6.2.0.exe', 'Sunshine-Windows-AMD64-installer.msi')) {
    Copy-Item -LiteralPath (Join-Path $vendor $file) -Destination $appVendor
}
foreach ($file in @('prepare-host.ps1', 'install-tailscale.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $appVendor
}
Copy-Item -Path "$vendor\licenses\*" -Destination $licenses
Copy-Item -Path "$installer\licenses\*" -Destination $licenses
Copy-Item -LiteralPath (Join-Path $vendor 'MANIFEST.md') -Destination $licenses

$archive = Join-Path $dist "LULU-Remote-Portable-$Version-x64.zip"
Compress-Archive -LiteralPath $app -DestinationPath $archive -Force
Write-Host $archive
