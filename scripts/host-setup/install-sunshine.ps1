# install-sunshine.ps1 — remote-PC one-click setup for LULU Remote.
# Run on the REMOTE Windows PC, in an Administrator PowerShell:
#   powershell -ExecutionPolicy Bypass -File scripts\host-setup\install-sunshine.ps1
#
# What it does:
#   1. Installs Sunshine (host) and Tailscale via winget.
#   2. Opens the Windows Firewall ports Sunshine needs.
#   3. Starts Sunshine and opens its web UI so you can create the
#      Sunshine admin account (needed once for LULU's in-app pairing).
#
# What it does NOT do: create the admin account for you, pair anything,
# or change any password. Those happen in the Sunshine web UI / LULU.
#
# NOT run on a real Windows machine yet (written on a Linux VM) — watch
# it run the first time and check each step's output.

#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'

function Test-Command($name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

if (-not (Test-Command winget)) {
    Write-Error 'winget not found. Install "App Installer" from the Microsoft Store first, then re-run this script.'
    exit 1
}

Write-Host '[1/4] Installing Sunshine...'
winget install --id LizardByte.Sunshine -e --accept-source-agreements --accept-package-agreements

Write-Host '[2/4] Installing Tailscale...'
winget install --id Tailscale.Tailscale -e --accept-source-agreements --accept-package-agreements

Write-Host '[3/4] Opening firewall ports for Sunshine...'
# Sunshine base port 47989: NVHTTP 47989, TLS 47984, web UI 47990,
# RTSP 48010; UDP 47998-48000 for video/control/audio.
New-NetFirewallRule -DisplayName 'LULU Sunshine TCP' -Direction Inbound `
    -Protocol TCP -LocalPort 47984,47989,47990,48010 -Action Allow `
    -ErrorAction SilentlyContinue | Out-Null
New-NetFirewallRule -DisplayName 'LULU Sunshine UDP' -Direction Inbound `
    -Protocol UDP -LocalPort 47998-48000 -Action Allow `
    -ErrorAction SilentlyContinue | Out-Null

Write-Host '[4/4] Starting Sunshine and opening the web UI...'
$sunshine = Join-Path $env:ProgramFiles 'Sunshine\sunshine.exe'
if (Test-Path $sunshine) {
    Start-Process $sunshine
} else {
    Write-Warning "Sunshine exe not found at $sunshine — open Sunshine from the Start menu."
}
Start-Sleep -Seconds 3
Start-Process 'https://localhost:47990'

Write-Host ''
Write-Host 'Done. In the web UI that just opened:'
Write-Host '  1. Create the Sunshine admin username + password (LULU needs these once for pairing).'
Write-Host '  2. In Tailscale, sign in and note this PC''s Tailscale address (100.x.y.z).'
Write-Host '  3. In LULU, add this PC with that address, then tap "开始配对".'
