param([string]$Dart = 'dart')

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$runner = Join-Path $root 'launcher/build/windows/x64/runner/Release'
if (!(Test-Path -LiteralPath (Join-Path $runner 'lulu_remote.exe') -PathType Leaf)) {
    throw 'Build the Windows launcher before staging the pairing worker.'
}

Push-Location (Join-Path $root 'pairing_worker')
try {
    & $Dart pub get
    if ($LASTEXITCODE -ne 0) { throw 'Pairing worker dependencies could not be resolved.' }
    & $Dart compile exe bin/pairing_worker.dart -o (Join-Path $runner 'lulu_pairing_worker.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Pairing worker compilation failed.' }
} finally {
    Pop-Location
}

$licenses = Join-Path $runner 'licenses'
New-Item -ItemType Directory -Force -Path $licenses | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'pairing_worker/lib/COPYING') -Destination (Join-Path $licenses 'PAIRING-WORKER-GPL-3.0.txt')
Copy-Item -LiteralPath (Join-Path $root 'pairing_worker/README.md') -Destination (Join-Path $licenses 'PAIRING-WORKER-NOTICE.md')
# CI compiles from a clean checkout. Embed its exact corresponding source
# in the Windows packages. Local builds may include uncommitted changes.
if ($env:GITHUB_ACTIONS -eq 'true') {
    $source = Join-Path $licenses 'PAIRING-WORKER-SOURCE.zip'
    git -C $root archive --format=zip --output=$source HEAD pairing_worker launcher/pubspec.yaml installer/scripts/build-pairing-worker.ps1 .github/workflows/build.yml
    if ($LASTEXITCODE -ne 0) { throw 'Pairing worker source archive failed.' }
}
