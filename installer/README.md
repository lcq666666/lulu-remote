# 一键安装包（installer/）

用户只下载成品安装包，双击后一路“下一步”装完即用。
Flutter、Visual Studio、Android SDK、Inno Setup 只是**做** LULU 需要的工具，
只在 GitHub Actions 里用；**用** LULU 的人一个都不用装。

## 用户拿到什么

Windows 文件名中的 `<版本>` 取自 `launcher/pubspec.yaml`，不含 `+` 后的构建号。Android 包名保留 `LULU` 以兼容现有交付方式，应用显示为「强哥远程」。

| 文件 | 用途 | 安装后 |
|---|---|---|
| `LULU-Remote-Setup-<版本>.exe` | Windows 通用版，可控制其他电脑，也可开启被控 | 首次连接从设备卡开始。随包携带 Moonlight；缺少被控组件时在「让别人连接我」按提示准备。 |
| `LULU-Host-Setup-<版本>.exe` | Windows 专用被控机 | 安装过程准备 Sunshine 和 Tailscale、检查服务是否就绪；失败时停止并指出出错步骤。 |
| `LULU-Remote-release.apk` 和 `LULU-Pairing-Worker-release.apk` | Android 启动器与配对伴侣 | 两份装同一次构建。Moonlight 独立安装。旧版调试 APK 如果签名不同，需要先记录配置再卸载重装。 |

正式发布从 GitHub Releases 取包，验收版从指定 GitHub Actions 运行的 Artifacts 取包。不要混用不同构建的两份 Android APK。

## 目录

```
installer/
  VERSIONS.md              第三方组件固定版本、下载地址、SHA-256、许可说明
  README.md                本文件
  .gitignore               vendor/ 里下载来的安装包不进仓库
  licenses/                随包的许可与源码说明（纯文本，进仓库）
    LULU-LICENSE.txt           LULU 启动器 MIT 许可（安装向导里显示的那个）
    MOONLIGHT-SOURCE-OFFER.txt Moonlight Qt GPL-3.0 源码获取方式
    SUNSHINE-SOURCE-OFFER.txt  Sunshine GPL-3.0 源码获取方式
    TAILSCALE-NOTICE.txt       Tailscale 说明（下载安装、BSD-3-Clause）
  scripts/
    fetch-components.ps1   CI 用：按 VERSIONS.md 下载 Moonlight / Sunshine，
                           算 SHA-256 写进 vendor/MANIFEST.md，下载它们的 LICENSE
    install-tailscale.ps1  安装时用：从官网下载 Tailscale MSI，校验 SHA-256 再静默安装
  client/
    LULU-Remote-Setup.iss  控制端安装包（Inno Setup 脚本）
  host/
    LULU-Host-Setup.iss    被控端安装包（Inno Setup 脚本）
    finalize-host.ps1      被控端装完收尾：放行防火墙、启动 Sunshine
  vendor/                  CI 下载来的文件（不在仓库里，构建时生成）
    MoonlightSetup-6.2.0.exe
    Sunshine-Windows-AMD64-installer.msi
    licenses/              Moonlight / Sunshine 的 LICENSE 全文
    MANIFEST.md            实际下载的文件名、版本、SHA-256
```

## 构建流程（CI，见 `.github/workflows/build.yml`）

1. CI 执行 Flutter 分析、启动器和配对伴侣测试，以及激活服务测试。
2. Windows 构建启动器和配对伴侣，下载并校验 Moonlight、Sunshine、Tailscale，生成 `vendor/MANIFEST.md`。Tailscale 不随包分发；详见 `VERSIONS.md`。
3. `installer/scripts/build-installers.ps1` 从启动器 `pubspec.yaml` 读取版本，编译两个 `.iss`，输出到 `installer/dist/`。CI 检查组件安装失败、通用版安装与卸载，以及安装后的完整版本。
4. Android 两包使用同一签名身份，CI 核对包名、版本号和证书。非发布构建没有发布密钥时可以生成调试包；标签发布没有发布密钥时会失败。
5. 通过验收后，符合版本要求的 `v*` 标签构建才生成 GitHub Release。附件含 Windows 安装器及便携包、两份 APK、配对伴侣源码包、激活服务和密钥工具。

本地开发构建见 `launcher/BUILD.md`。涉及物理双屏、真实组件就绪或 Android 串流的检查，使用 `docs/unified-device-acceptance.md` 的步骤另行完成。Windows 安装器未做代码签名，可能触发 SmartScreen；请先核对下载来源与校验值。
