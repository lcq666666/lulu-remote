# Windows 隐私屏原生冒烟测试

在有桌面会话的 Windows 10 2004 或更新版本中，用 Visual Studio 的 **Developer PowerShell** 打开仓库根目录。测试会短暂创建覆盖整个桌面的窗口，请勿在使用远程串流时运行。编译输出只写入系统临时目录。

```powershell
$runner = (Resolve-Path 'launcher/windows/runner').Path
$source = (Resolve-Path 'launcher/test/native/privacy_recovery_smoke.cpp').Path
$out = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ('qg-privacy-smoke-' + [Guid]::NewGuid()))
Push-Location $out.FullName
try {
    cl /nologo /std:c++17 /EHsc /DNOMINMAX "/I$runner" $source `
        "$runner/privacy_screen.cpp" /link /MANIFEST:EMBED `
        "/MANIFESTINPUT:$runner/runner.exe.manifest" /out:privacy_recovery_smoke.exe `
        user32.lib gdi32.lib ole32.lib windowscodecs.lib
    if ($LASTEXITCODE -ne 0) { throw '编译失败' }
    .\privacy_recovery_smoke.exe
    if ($LASTEXITCODE -ne 0) { throw "测试失败：$LASTEXITCODE" }
} finally {
    Pop-Location
}
```

测试用 Win32 消息验证预览回退、窗口缩小后通过续期恢复全虚拟桌面范围、超时后同一会话恢复、热键退出后拒绝同一会话重试，以及下一会话可重新显示。它不验证物理热键、Moonlight 画面与操作，不能替代双机双屏验收。

## Moonlight 自定义安装目录

在 Windows 仓库根目录运行 `pwsh -File launcher/test/native/test-moonlight-shortcut.ps1`。Windows CI 也运行该测试。测试用临时快捷方式验证带空格和中文的目标路径、目标丢失和错误文件名；既不启动快捷方式，也不安装或卸载本机 Moonlight。如当前电脑已有官方开始菜单快捷方式，仅报告找到的个数。
