# 已拍板（2026-11-26 用户确认）

1. **引擎**：Moonlight，首选定版。
2. **组网**：Tailscale 首选，ZeroTier 备选。
3. **安卓配对**：用户接受第一次手动配对，但随后追加要求（见下）。
4. **仓库**：先私有。

## 追加要求（2026-11-26 16:20，用户原话要点）

不要手动打开 Moonlight 配对。像 LL-Remote 那样，LULU 在后台直接操作本机 Moonlight，把 4 位 PIN 直接发到 LULU 前端，所有交互都在 LULU 内完成。

## 诚实说明：这条要求改变了实现方式

原调研的启动器方案是“先在 Moonlight 里配对一次，再把 UUID 填进 LULU”，因为官方 Moonlight 的配对证书存在它自己的数据里，外部启动器读不到。

要做到 PIN 全在 LULU 内，LULU 自己必须做一次 GameStream 配对，而不是只调 Moonlight 的界面：

- Windows：官方 moonlight-qt 的 `pair` 命令行没有可靠的无头取 PIN 方式（`--headless` 是个别 fork 才有的参数，官方版不支持）。可行路是 LULU 自己实现 4 阶段 `/pair` 握手，生成客户端证书和 4 位 PIN，在 LULU 里显示 PIN，再把 PIN 提交给 Sunshine（Sunshine 有 `/api/pin`，需一次输入 Sunshine 管理员密码），配对成功后用 `moonlight-qt stream` 拉起画面。配对模块借鉴 moonlight-common-c / moonlight-chrome 的 pairing 逻辑，该模块按 GPL-3.0 处理，与 LULU 壳子其余代码分开。
- Android：同理，LULU 自己配对后，它的证书和 Moonlight 的证书不是同一张，所以不能再靠 ShortcutTrampoline 借用 Moonlight 的配对。v1 需先验证直接用 Game Intent 带 LULU 自己的证书拉起 Moonlight 是否可行；不行的话，就得 fork Moonlight Android（整个 fork GPL-3.0），工作量大得多。这是 Android 端最大的不确定点，先做原型验证再定。

## 已确认（2026-11-26 17:08，用户原话“可以，两个都接受”）

- 配对模块按 GPL-3.0 单独处理，接受。
- 在 LULU 里一次输入 Sunshine 管理员密码、由 LULU 自动向 Sunshine 提交 PIN，接受。密码只存系统安全存储，不存明文。

## 首次提交

- 2026-11-26：首次提交完成，commit 7c67d86，40 个文件，3672 行，本地 main 分支，无远端，未推送。仓库仍私有，本地保存。

## 一键安装要求（2026-11-26 17:16，用户原话要点）

用户觉得之前的要求太高，要分别下载好几个程序。改为：直接打包成正常 APP，所用的 exe 相关依赖都放进安装包里，用户一键安装。

- 客户端（控制端 Windows）：一个安装包，带齐 LULU 启动器 + Moonlight Qt + Tailscale，装完即用，不用用户再去各家官网下载。
- 被控端（两台远端电脑）：一个安装包，带齐 Sunshine + Tailscale，装完按提示建好管理员账号即可。
- 安卓：一个 APK，首次打开时用一步引导装好 Moonlight 和 Tailscale（安卓不允许静默装别的应用，最多做到一键跳转安装，用户点一下确认）。
- 关键纠正：Flutter、Visual Studio、Android SDK 只是“做” LULU 需要的工具，不是“用” LULU 需要的。用户用的时候不该装这些。打包改用 GitHub Actions 在云端自动编译 Windows 安装包和 APK，用户只下载成品。

## 一键安装实施（2026-11-26）

用户要求改一键安装后做的事，文件都在 `installer/` 和 `.github/workflows/`：

- 客户端安装包 `installer/client/LULU-Remote-Setup.iss`：LULU 启动器 + Moonlight Qt v6.2.0（随包，GPL-3.0，附 LICENSE 和源码说明）+ Tailscale 1.104.7（安装时从官网下载并校验 SHA-256）。
- 被控端安装包 `installer/host/LULU-Host-Setup.iss`：Sunshine v2026.914.233613（随包，GPL-3.0）+ Tailscale（同上），装完放行防火墙、启动 Sunshine、打开 `https://localhost:47990` 建管理员账号。
- Tailscale 不随包分发的原因写在 `installer/VERSIONS.md`：开源客户端是 BSD-3-Clause，但官方 Windows 图形客户端是独立产品，直接打包再分发没有明确许可，所以走安装时官网下载。
- CI `.github/workflows/build.yml`：跑测试、编 Windows 版、编 APK、取包并校验、编译两个安装包；打 `v*` 标签时自动发 Release。用户用 LULU 不需要 Flutter / Visual Studio / Android SDK / Inno Setup，这些只在 CI 里用。
- Flutter 里加了 `lib/services/component_installer.dart` 和设置检查清单顶部的“一键安装缺失组件”按钮：Windows 上重跑安装包里自带的组件安装器；安卓上只能一键跳转 Play 商店，界面文字如实说了这一点。
- 钉住的版本见 `installer/VERSIONS.md`；第三方清单见 `release/THIRD-PARTY.md`。
- 没验证过的：`.iss` 没编译过，CI 工作流没跑过，静默安装参数和取包脚本的 asset 名字规律是按常见情况写的，第一次 CI 才是真正的测试。安装包目前无代码签名，首次打开会有 SmartScreen 警告。

## 骨架实现（2026-11-26，v1 scaffold）

- `launcher/` 已搭好：Flutter 一套代码出 Windows exe + Android APK，深绿主题、2 台设备列表、画质预设、在线状态、Tailscale 状态栏。
- 配对按上面“诚实说明”的方式实现：`launcher/lib/pairing/` 自己做 GameStream 4 阶段 `/pair` 握手（RSA-2048 自签证书 `CN=NVIDIA GameStream Client`、4 位 PIN 在 LULU 里显示、经 `POST /api/pin` 提交），配对模块单独按 GPL-3.0 处理，与 MIT 壳子分开。没有抄 LL-Remote 的代码。
- 上面两个待确认问题，骨架是按“接受”来写的：如果用户不接受，配对模块和密码存储要改，改动点见 `launcher/lib/pairing/README.md` 和 `launcher/BUILD.md`。
- 没验证过的都在 `launcher/BUILD.md`“What is NOT verified”里列着，最关键的三件：配对握手对真 Sunshine、安卓 Game Intent 带 LULU 自己的证书、`moonlight-qt pair` 无头方式（LULU 没用它，特意避开了）。
