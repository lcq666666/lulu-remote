# Read the shipping version from the launcher manifest for Windows packages.
param([switch]$IncludeBuild)

$manifest = Join-Path $PSScriptRoot '../../launcher/pubspec.yaml'
$source = Get-Content -Raw -LiteralPath $manifest
$version = [regex]::Match($source, '(?m)^version: ([0-9]+\.[0-9]+\.[0-9]+(?:-[a-z0-9.]+)?)\+(\d+)\r?$')
if (-not $version.Success) { throw 'Invalid launcher version in pubspec.yaml.' }
if ($IncludeBuild) {
    '{0}+{1}' -f $version.Groups[1].Value, $version.Groups[2].Value
} else {
    $version.Groups[1].Value
}
