param([string]$Compiler = 'iscc.exe', [switch]$TestClientInstaller)

$ErrorActionPreference = 'Stop'
$installer = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path $env:TEMP ("qg-installer-check-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workspace | Out-Null
Copy-Item -LiteralPath (Join-Path $installer 'host/host-component-checks.iss') -Destination $workspace
Copy-Item -LiteralPath (Join-Path $installer 'tests/host-component-check-fixture.iss') -Destination $workspace
Set-Content -LiteralPath (Join-Path $workspace 'launcher-marker.txt') -Value 'launcher installed'

function Invoke-Setup([string]$Exe, [string[]]$Arguments) {
    $process = Start-Process -FilePath $Exe -ArgumentList $Arguments -WindowStyle Hidden -PassThru
    for ($wait = 0; $wait -lt 3; $wait++) {
        if ($process.WaitForExit(40000)) { return $process.ExitCode }
    }
    if (!$process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "Setup timed out. Logs: $workspace"
    }
    return $process.ExitCode
}

foreach ($scenario in @(
    @{ Name = 'success'; Tailscale = 0; Finalize = 0; ExpectedExit = 0 },
    @{ Name = 'tailscale-failure'; Tailscale = 3; Finalize = 0; ExpectedExit = 7 },
    @{ Name = 'readiness-failure'; Tailscale = 0; Finalize = 4; ExpectedExit = 7 }
)) {
    $target = Join-Path $workspace $scenario.Name
    $log = Join-Path $workspace ($scenario.Name + '.log')
    Set-Content -LiteralPath (Join-Path $workspace 'install-tailscale.ps1') -Value "exit $($scenario.Tailscale)"
    Set-Content -LiteralPath (Join-Path $workspace 'finalize-host.ps1') -Value "exit $($scenario.Finalize)"
    & $Compiler /Q (Join-Path $workspace 'host-component-check-fixture.iss')
    if ($LASTEXITCODE -ne 0) { throw "Could not compile component test. Logs: $workspace" }
    $code = Invoke-Setup (Join-Path $workspace 'host-component-check.exe') @(
        '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=`"$target`"", "/LOG=`"$log`""
    )
    $installed = Test-Path -LiteralPath (Join-Path $target 'launcher-marker.txt')
    if ($code -ne $scenario.ExpectedExit -or $installed -ne ($scenario.ExpectedExit -eq 0)) {
        throw "$($scenario.Name): unexpected setup result $code (launcher installed: $installed). See $log"
    }
    if ($scenario.Tailscale -ne 0 -and (Select-String -LiteralPath $log -SimpleMatch 'Starting Sunshine startup')) {
        throw "Readiness check ran after a Tailscale failure. See $log"
    }
    Write-Host "$($scenario.Name) returned $code (launcher installed: $installed)."
}

if ($TestClientInstaller) {
    $version = & (Join-Path $installer 'scripts/read-app-version.ps1')
    $client = Join-Path $installer "dist/LULU-Remote-Setup-$version.exe"
    $target = Join-Path $workspace 'client-installed'
    for ($iteration = 1; $iteration -le 2; $iteration++) {
        $log = Join-Path $workspace "client-$iteration.log"
        $code = Invoke-Setup $client @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
            "/DIR=`"$target`"", "/LOG=`"$log`"")
        if ($code -ne 0) { throw "Client installer returned $code. See $log" }
        foreach ($relativePath in @('lulu_remote.exe', 'lulu_pairing_worker.exe',
            'vendor/moonlight/Moonlight.exe', 'vendor/MoonlightSetup-6.2.0.exe')) {
            if (!(Test-Path -LiteralPath (Join-Path $target $relativePath) -PathType Leaf)) {
                throw "Missing $relativePath after client installation. See $log"
            }
        }
        $launcherVersion = (Get-Item -LiteralPath (Join-Path $target 'lulu_remote.exe')).VersionInfo.ProductVersion
        if (($launcherVersion -split '\+')[0] -ne $version) {
            throw "Installed launcher version $launcherVersion does not match $version. See $log"
        }
        Write-Host "Client installer pass $iteration verified version $launcherVersion and bundled Moonlight."
    }
    $uninstaller = @(Get-ChildItem -LiteralPath $target -Filter 'unins*.exe' -File)
    if ($uninstaller.Count -ne 1) { throw "Expected one client uninstaller in $target." }
    $code = Invoke-Setup $uninstaller[0].FullName @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
    if ($code -ne 0 -or (Test-Path -LiteralPath (Join-Path $target 'lulu_pairing_worker.exe'))) {
        throw 'Client uninstall did not remove the pairing worker.'
    }
}
