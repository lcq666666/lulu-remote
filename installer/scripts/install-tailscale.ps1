# install-tailscale.ps1 — run DURING the LULU installers (bundled in
# the installer, executed by Inno Setup as administrator).
#
# Downloads the official Tailscale Windows MSI from Tailscale's own
# servers, verifies its SHA-256, then installs it silently.
# Tailscale is NOT bundled in the installer (see installer/VERSIONS.md
# for why) — this script is the download-at-install path.
#
# Behaviour:
#   - If Tailscale is already installed, prints a message and exits 0.
#   - If the download fails or the SHA-256 does not match, exits 1
#     with an error. The installer must NOT silently continue without
#     Tailscale — the user needs it for the mesh network.
#   - Needs internet. On an offline machine this step fails; the
#     installer shows the error and the user retries after going online.

param(
    [string]$Version = "1.104.7",
    # Keep in sync with installer/VERSIONS.md. Secondary source: the
    # Windows Package Manager manifest. Both this script and the CI
    # fetch script re-verify the hash; a mismatch aborts the install.
    [string]$ExpectedSha256 = "676b5b32fdd1aeaee90d8e8f38e222635b216fbdfbf877bf01cb1d7cda330ec5"
)

$ErrorActionPreference = 'Stop'

function Test-TailscaleInstalled {
    $exe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (Test-Path $exe) { return $true }
    return [bool](Get-Command tailscale -ErrorAction SilentlyContinue)
}

if (Test-TailscaleInstalled) {
    Write-Host 'Tailscale is already installed — skipping download.'
    exit 0
}

$url = "https://pkgs.tailscale.com/stable/tailscale-setup-$Version-amd64.msi"
$msi = Join-Path $env:TEMP "tailscale-setup-$Version-amd64.msi"

Write-Host "Downloading Tailscale $Version from $url ..."
try {
    Invoke-WebRequest -Uri $url -OutFile $msi
} catch {
    Write-Error "Tailscale download failed (check internet): $($_.Exception.Message)"
    exit 1
}

$actual = (Get-FileHash -Path $msi -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $ExpectedSha256.ToLower()) {
    Remove-Item $msi -Force -ErrorAction SilentlyContinue
    Write-Error ("Tailscale SHA-256 mismatch! Expected $ExpectedSha256, got $actual. " +
        "Refusing to install an unverified file. Please update LULU Remote and retry.")
    exit 1
}

Write-Host 'Checksum OK. Installing Tailscale (silent, no restart) ...'
$proc = Start-Process -FilePath 'msiexec.exe' `
    -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart') `
    -Wait -PassThru
Remove-Item $msi -Force -ErrorAction SilentlyContinue
if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
    Write-Error "Tailscale MSI install failed with exit code $($proc.ExitCode)."
    exit 1
}

if (-not (Test-TailscaleInstalled)) {
    Write-Error 'Tailscale MSI reported success but tailscale.exe was not found.'
    exit 1
}

Write-Host 'Tailscale installed. Sign in from the Tailscale tray icon after setup finishes.'
exit 0
