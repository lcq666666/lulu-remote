# 钉住的组件版本（LULU Remote 一键安装包）

> 规则：所有版本号只改这里。CI 的取包脚本
> `installer/scripts/fetch-components.ps1` 按这里的版本去下载，
> 下载完算出 SHA-256 写进 `installer/vendor/MANIFEST.md`。
> 用户永远只下载 LULU 的成品安装包，不用自己去各家官网找版本。

| 组件 | 钉住版本 | 发布日期 | 许可 | 源码 / 发布页 | 怎么进安装包 |
|---|---|---|---|---|---|
| LULU 启动器（Flutter） | 0.1.0（本仓库 `launcher/`，`pubspec.yaml`） | — | MIT（壳子）；`lib/pairing/` 单独 GPL-3.0 | 本仓库 | CI 编译 `flutter build windows`，exe + DLL + data 直接装进安装包 |
| Moonlight Qt（Windows 控制端） | **v6.2.0** | 2026-10-04 | GPL-3.0 | https://github.com/moonlight-stream/moonlight-qt/releases/tag/v6.2.0 | CI 下载后**随包分发**：`installer/vendor/MoonlightSetup-6.2.0.exe`，安装时静默运行 |
| Sunshine（Windows 被控端） | **v2026.914.233613** | 2026-09-14 | GPL-3.0 | https://github.com/LizardByte/Sunshine/releases/tag/v2026.914.233613（仓库已改名 SunshineStream/Sunshine，同一 release） | CI 下载后**随包分发**：`installer/vendor/Sunshine-Windows-Installer.exe`，安装时静默运行 |
| Tailscale（Windows 组网） | **1.104.7** | 2026-11-12 | BSD-3-Clause（开源客户端/守护进程）；官方 Windows 图形客户端是独立产品 | https://tailscale.com/download/windows；源码 https://github.com/tailscale/tailscale | **不随包分发，安装时从官网下载**：`https://pkgs.tailscale.com/stable/tailscale-setup-1.104.7-amd64.msi`，下载完校验 SHA-256 再装 |
| Moonlight Android（手机控制端） | v12.2（`com.limelight`） | 2026-09 | GPL-3.0 | https://github.com/moonlight-stream/moonlight-android | 不进 APK；LULU 首次打开一键跳转 Play 商店安装 |
| Tailscale Android（手机组网） | 最新稳定版（`com.tailscale.ipn`） | — | BSD-3-Clause（客户端） | https://tailscale.com/download/android | 不进 APK；LULU 首次打开一键跳转 Play 商店安装 |
| ZeroTier（备选组网，未钉版本） | 不钉版本，备选 | — | 客户端 BSL-1.1（以随包文件为准） | https://www.zerotier.com/download/ | 备选，不进安装包；需要时用户手动装 |
| Inno Setup（只用于做安装包） | 6.x（CI 装最新 6.x） | — | Inno Setup License（免费） | https://jrsoftware.org/isinfo.php | 只在 CI 里用，不进安装包 |
| Flutter（只用于编译） | 3.22+ stable | — | BSD-3-Clause | https://flutter.dev | 只在 CI 里用，不进安装包 |

## SHA-256（安装包里的文件以 `installer/vendor/MANIFEST.md` 为准）

| 文件 | SHA-256 | 来源 |
|---|---|---|
| `tailscale-setup-1.104.7-amd64.msi` | `676b5b32fdd1aeaee90d8e8f38e222635b216fbdfbf877bf01cb1d7cda330ec5` | winget 清单里的官方 MSI 校验值（二次来源）。**安装脚本和 CI 取包脚本都会重新算一遍，不一致就停下不装**，以官网文件为准 |
| `MoonlightSetup-6.2.0.exe` | 待构建时填 | CI 下载后算出，写进 `installer/vendor/MANIFEST.md` |
| `Sunshine-Windows-Installer.exe` | 待构建时填 | CI 下载后算出，写进 `installer/vendor/MANIFEST.md` |

## 为什么 Tailscale 不随包分发

查到的情况（2026-11-26）：

- Tailscale 主仓库（`tailscaled` 守护进程和命令行客户端）是 BSD-3-Clause，
  二进制再分发要附版权说明，这一点没问题。
- 但官方 Windows 安装包是带图形界面的完整产品，仓库说明里明确写了
  “非开源平台上的图形界面不在开源范围内”，托管的控制面也是另外的产品。
  也就是说，**直接把官方 MSI 塞进自己的安装包再分发，并没有明确的许可**。
- 所以 Tailscale 走最稳妥的路：安装包里只放一个下载脚本，安装时从
  `pkgs.tailscale.com`（Tailscale 自己的服务器）下载官方 MSI，校验
  SHA-256 通过才装。用户还是“一键安装”，只是 Tailscale 那一步要联网。
  离线安装时这一步会报错并提示用户联网后重试，不会悄悄跳过。

## 为什么 Moonlight / Sunshine 可以随包分发

两者都是 GPL-3.0，允许再分发二进制，条件是：

1. 随包附上它们的 LICENSE 全文（CI 取包脚本从官方仓库下载，
   放进安装包的 `licenses\` 目录）；
2. 附上源码获取方式（`installer/licenses/*-SOURCE-OFFER.txt`，
   写明版本和 GitHub 发布页地址）；
3. 不改它们的二进制，原样分发。

满足这三点就可以。改动了它们的代码才需要另外公开改动源码，
LULU 没有改，只调用，所以只做上面三点。
