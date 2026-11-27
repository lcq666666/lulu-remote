# finalize-host.ps1 — run at the END of the LULU Host installer
# (Inno Setup, as administrator, after Sunshine + Tailscale are in).
#
# This is the installer version of scripts/host-setup/install-sunshine.ps1
# minus the winget installs (the installer already did those):
#   1. Open the Windows Firewall ports Sunshine needs.
#   2. Start Sunshine.
# The installer itself opens https://localhost:47990 afterwards
# (post-install step), so the user creates the Sunshine admin account once.
#
# It does NOT create the admin account, pair anything, or change any
# password. Those happen in the Sunshine web UI / LULU.
#
# NOT run on a real Windows machine yet — watch the installer log the
# first time.

$ErrorActionPreference = 'Stop'

Write-Host '[1/2] Opening firewall ports for Sunshine...'
# Sunshine base port 47989: NVHTTP 47989, TLS 47984, web UI 47990,
# RTSP 48010; UDP 47998-48000 for video/control/audio.
New-NetFirewallRule -DisplayName 'LULU Sunshine TCP' -Direction Inbound `
    -Protocol TCP -LocalPort 47984,47989,47990,48010 -Action Allow `
    -ErrorAction SilentlyContinue | Out-Null
New-NetFirewallRule -DisplayName 'LULU Sunshine UDP' -Direction Inbound `
    -Protocol UDP -LocalPort 47998-48000 -Action Allow `
    -ErrorAction SilentlyContinue | Out-Null

Write-Host '[2/2] Starting and checking Sunshine...'
try {
    $service = Get-Service -Name 'SunshineService' -ErrorAction Stop
    Set-Service -InputObject $service -StartupType Automatic
    Start-Service -InputObject $service
    $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(20))

    $url = 'http://127.0.0.1:47989/serverinfo'
    $lastError = 'No response.'
    for ($attempt = 0; $attempt -lt 15; $attempt++) {
        try {
            $request = [Net.WebRequest]::CreateHttp($url)
            $request.Proxy = $null
            $request.Timeout = 2000
            $request.ReadWriteTimeout = 2000
            $request.AllowAutoRedirect = $false
            $response = $request.GetResponse()
            try {
                $reader = [IO.StreamReader]::new($response.GetResponseStream())
                try { [xml]$info = $reader.ReadToEnd() } finally { $reader.Dispose() }
                if ([int]$response.StatusCode -ne 200 -or -not $info.root.appversion) {
                    throw 'The endpoint did not return Sunshine server information.'
                }
            } finally {
                $response.Dispose()
            }
            Write-Host 'Sunshine is ready and configured for automatic startup.'
            exit 0
        } catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Milliseconds 500
        }
    }
    throw "Sunshine service did not respond at $url. $lastError"
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
