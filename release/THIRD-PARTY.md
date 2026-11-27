# 第三方组件清单（随安装包发布）

> 事实来源：`installer/VERSIONS.md`（钉住的版本）和构建时生成的
> `installer/vendor/MANIFEST.md`（实际下载的文件名和 SHA-256）。
> 发布前对照这两份文件核对下面这张表，版本号对不上就不要发。

## 随安装包分发或安装时下载的组件

| 组件 | 许可 | 钉住版本 | SHA-256 | 源码 / 发布页 | 怎么进用户电脑 |
|---|---|---|---|---|---|
| Moonlight Qt | GPL-3.0 | v6.2.0 | 待构建时填（见 `vendor/MANIFEST.md`） | https://github.com/moonlight-stream/moonlight-qt | CI 下载后**随客户端安装包分发**，安装时静默运行；LICENSE 全文 + 源码说明随包放在 `licenses\` |
| Sunshine | GPL-3.0 | v2026.914.233613 | 待构建时填（见 `vendor/MANIFEST.md`） | https://github.com/LizardByte/Sunshine | CI 下载后**随被控端安装包分发**，安装时静默运行；LICENSE 全文 + 源码说明随包放在 `licenses\` |
| Tailscale Windows 客户端 | BSD-3-Clause（开源客户端/守护进程） | 1.104.7 | `676b5b32fdd1aeaee90d8e8f38e222635b216fbdfbf877bf01cb1d7cda330ec5`（安装时重新校验，不一致就停） | https://github.com/tailscale/tailscale；下载页 https://tailscale.com/download/windows | **不随包分发**。安装时从 `pkgs.tailscale.com` 下载官方 MSI，校验通过才装（原因见 `installer/VERSIONS.md`） |
| Moonlight Android | GPL-3.0 | v12.2（`com.limelight`） | 不适用（Play 商店分发） | https://github.com/moonlight-stream/moonlight-android | 不进 APK；LULU 首次打开一键跳转 Play 商店安装 |
| Tailscale Android | BSD-3-Clause（客户端） | 最新稳定版（`com.tailscale.ipn`） | 不适用（Play 商店分发） | https://github.com/tailscale/tailscale | 不进 APK；LULU 首次打开一键跳转 Play 商店安装 |
| ZeroTier（备选组网） | 客户端 BSL-1.1（以随包文件为准） | 不钉版本 | — | https://www.zerotier.com/download/ | 备选，不进安装包；需要时用户手动装 |

## 只在构建时用的工具（不进安装包，不发给用户）

| 工具 | 许可 | 版本 |
|---|---|---|
| Flutter SDK | BSD-3-Clause | 3.22+ stable（CI 装） |
| Inno Setup | Inno Setup License（免费） | 6.x（CI 装） |
| Visual Studio 2022 C++ 工作负载 | Microsoft 许可 | CI 的 `windows-latest` 自带 |
| Android SDK / NDK、JDK 17 | 各自许可 | CI 装（Android 构建用） |

## 许可合规要点

- Moonlight / Sunshine 是 GPL-3.0：随包附 LICENSE 全文（CI 从官方仓库下载）
  和源码获取方式（`installer/licenses/*-SOURCE-OFFER.txt`），二进制原样分发、
  不改代码。改了代码才需要另外公开改动源码，LULU 没有改。
- LULU 启动器自身代码不链接以上任何库：Windows 端以子进程方式调用
  `moonlight-qt.exe`，安卓端以 Intent 方式调起 Moonlight；配对模块
  （`pairing_worker/`）是独立的 GPL-3.0-only 组件。构建产物附对应源码和完整许可，构建方法见该目录的 README。
- Tailscale 不随包分发，见 `installer/VERSIONS.md` 里“为什么 Tailscale
  不随包分发”。
- 没抄 LL-Remote 的任何代码（它没有 LICENSE 文件，`package.json` 是
  `private: true`，只能当架构参考）。
