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

Write-Host '[2/2] Starting Sunshine...'
$sunshine = Join-Path $env:ProgramFiles 'Sunshine\sunshine.exe'
if (Test-Path $sunshine) {
    Start-Process $sunshine
} else {
    Write-Warning "Sunshine exe not found at $sunshine — open Sunshine from the Start menu."
}

Write-Host 'Done. The installer will now open the Sunshine web UI:'
Write-Host '  1. Create the Sunshine admin username + password (LULU needs these once for pairing).'
Write-Host '  2. In Tailscale, sign in and note this PC''s Tailscale address (100.x.y.z).'
Write-Host '  3. In LULU, add this PC with that address, then tap "开始配对".'
