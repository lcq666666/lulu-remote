$ErrorActionPreference = 'Stop'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or !$vs) { throw 'Visual Studio with C++ tools is required.' }
Import-Module (Join-Path $vs 'Common7/Tools/Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null
$runner = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../windows/runner')).Path
$source = Join-Path $PSScriptRoot 'moonlight_shortcut_smoke.cpp'
$out = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ('qg-moonlight-shortcut-' + [Guid]::NewGuid()))
Push-Location $out.FullName
try {
    cl.exe /nologo /std:c++17 /EHsc /W4 /WX /DNOMINMAX "/I$runner" $source `
        "$runner/moonlight_shortcut.cpp" /link /out:moonlight-shortcut-smoke.exe shell32.lib ole32.lib uuid.lib
    if ($LASTEXITCODE -ne 0) { throw 'Moonlight shortcut smoke test did not compile.' }
    .\moonlight-shortcut-smoke.exe
    if ($LASTEXITCODE -ne 0) { throw "Moonlight shortcut smoke test failed: $LASTEXITCODE" }
} finally {
    Pop-Location
}
