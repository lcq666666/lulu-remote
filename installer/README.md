# 一键安装包（installer/）

用户只下载成品安装包，双击后一路“下一步”装完即用。
Flutter、Visual Studio、Android SDK、Inno Setup 只是**做** LULU 需要的工具，
只在 GitHub Actions 里用；**用** LULU 的人一个都不用装。

## 用户拿到什么

| 文件 | 给谁用 | 里面有什么 | 装完要做什么 |
|---|---|---|---|
| `LULU-Remote-Setup-0.1.0.exe` | 控制端 Windows 电脑（你的电脑） | LULU 启动器 + Moonlight Qt（随包）+ Tailscale（安装时从官网下载并校验） | 打开 LULU，登录一次 Tailscale，加两台电脑，点“开始配对” |
| `LULU-Host-Setup-0.1.0.exe` | 被控端 Windows 电脑（两台远端电脑，每台跑一次） | Sunshine（随包）+ Tailscale（安装时从官网下载并校验） | 装完自动打开 `https://localhost:47990`，建一次 Sunshine 管理员账号；登录一次 Tailscale，记下这台电脑的组网地址 |
| `LULU-Remote-0.1.0.apk` | 安卓手机 | 只有 LULU 启动器本身 | 首次打开点“一键安装缺失组件”，跳转 Play 商店装 Moonlight 和 Tailscale（安卓不允许静默装别的应用，跳转后由你点一下确认安装） |

三个文件都在 GitHub Releases 里（打 `v*` 标签时自动发布），
平时也可以在 Actions 的 Artifacts 里下载。

## 目录

```
installer/
  VERSIONS.md              钉住的版本号、下载地址、SHA-256、许可说明（唯一事实来源）
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

1. `flutter test` → `flutter build windows --release` → `flutter build apk --release`
   （APK 发布签名用仓库 Secrets 里的 keystore，没有 Secrets 时改打 debug 包并在文件名里写明）。
2. `fetch-components.ps1` 下载 Moonlight / Sunshine，校验并写 `vendor/MANIFEST.md`，
   同时下载它们的 LICENSE；还会下载 Tailscale MSI 只做 SHA-256 校验，校验完就删掉，
   **不**把它放进安装包（原因见 `VERSIONS.md`）。
3. `installer/scripts/build-installers.ps1` 读取启动器 `pubspec.yaml` 里的版本，调用 Inno Setup 编译两个 `.iss`，安装包输出到 `installer/dist/`。
4. 推 `v*` 标签时，两个安装包 + APK 自动挂到 GitHub Release 上。

本地开发构建见 `launcher/BUILD.md`——本地只做开发调试，不出正式安装包。

## 没验证过的（先说清楚）

- 这台 Linux 机器上没有 Flutter、没有 Inno Setup、没有 Windows，
  所以 `.iss` 没有编译过，`build.yml` 没有跑过，静默安装参数
  （`/VERYSILENT`）是按“Moonlight / Sunshine 的安装包都是 Inno Setup 做的”
  这一常见情况写的，**CI 第一次跑如果报错，先查这个**。
- `fetch-components.ps1` 按 release asset 的名字规律去匹配 Sunshine 的
  Windows 安装包（`*Windows*Installer*.exe`），没有对着真实的 release API
  跑过，第一次 CI 如果找不到文件，先看 `vendor/MANIFEST.md` 的报错和
  release 页上的实际文件名。
- Tailscale MSI 的 SHA-256 来自 winget 清单的二次来源，安装脚本和 CI
  都会重新校验，官网文件对不上就停下，这是故意设计的安全检查，
  不是 bug。
- 两个安装包目前都没有代码签名，Windows 第一次打开会弹 SmartScreen
  警告，点“更多信息 → 仍要运行”即可。签名证书要花钱买，v1 先不做。
