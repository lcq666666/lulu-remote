$ErrorActionPreference = 'Stop'
$service = Get-Service -Name 'SunshineService' -ErrorAction SilentlyContinue
if (-not $service) {
    $installer = Join-Path $PSScriptRoot 'Sunshine-Windows-AMD64-installer.msi'
    $result = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" `
        -ArgumentList @('/i', ('"{0}"' -f $installer), '/qn', '/norestart', 'REBOOT=ReallySuppress') `
        -WindowStyle Hidden -Wait -PassThru
    if ($result.ExitCode -ne 0) { exit $result.ExitCode }
    $service = Get-Service -Name 'SunshineService'
}
Set-Service -InputObject $service -StartupType Automatic
if ($service.Status -ne 'Running') {
    Start-Service -InputObject $service
    $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
}

$service.Refresh()
if ($service.Status -ne 'Running') { throw 'Sunshine service did not enter the Running state.' }