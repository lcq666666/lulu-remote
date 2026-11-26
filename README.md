# LULU Remote

自己的免费远程助手：一个薄启动器壳子，底层串流、组网、加密全部借用现成开源引擎，壳子只做设备列表、在线状态和一键连接。

## 定版方案（调研结论，待最终拍板）

- 串流引擎：Sunshine（装在两台被控 Windows 电脑上）+ 官方 Moonlight 客户端（Windows 用 Moonlight Qt，安卓用 Moonlight Android），均为 GPL-3.0，只调用、不改、不内嵌。
- 组网：Tailscale 免费版优先（组网地址按设备单独存，组网层可替换：ZeroTier / Headscale / frp / 皎月连都是备选）。
- 壳子：Flutter 一套 Dart 代码，同时出 Windows exe 和 Android APK；壳子自身代码用 MIT 许可，与 GPL 引擎之间只有进程 / Intent 调用边界。
- 备选引擎：RustDesk（AGPL-3.0）——如果文件传输和无人值守比画面流畅更重要，就换它，壳子只负责预配服务器参数。

## 用户安装（一键安装，不用装开发工具）

每台 Windows 电脑安装同一个 LULU 安装包。要让别人控制这台电脑，在「这台电脑」中点「允许远程控制」，设置本机管理账号，再复制电脑地址。要控制对方的电脑，在「我的电脑」里添加对方的地址。同一 Wi-Fi 下用局域网地址。跨网连接可在连接设置里准备所需组件。
**Flutter、Visual Studio、Android SDK、Inno Setup 只是做 LULU 需要的工具，
只在 GitHub Actions 里用；用 LULU 的人一个都不用装。**

| 文件 | 给谁用 | 里面有什么 |
|---|---|---|
| `LULU-Remote-Setup-0.1.0.exe` | 所有 Windows 电脑 | LULU 界面及控制、被控组件，首次使用对应功能时准备组件 |
| `LULU-Remote-0.1.0.apk` | 安卓手机 | 只有 LULU 启动器；首次打开一键跳转 Play 商店装 Moonlight 和 Tailscale（安卓不允许静默装别的应用，跳转后由你点一下确认） |

安装包可以从 GitHub Actions 的构建产物下载（打 `v*` 标签时自动发布到 GitHub Releases）。
钉住的版本号、下载地址、SHA-256 见 `installer/VERSIONS.md`。

## 目录

- `launcher/` — Flutter 启动器（Windows + Android 同一份代码）
- `installer/` — Windows 安装包、取包脚本、钉住的版本清单
- `.github/workflows/build.yml` — CI：编译 Flutter、做安装包、发 Release（唯一出正式安装包的地方）
- `scripts/host-setup/` — 被控端手动一键配置脚本（安装包的等价手动版）
- `docs/` — 调研结论、许可清单、待拍板事项
- `release/` — 发布清单：每个引擎的版本、SHA-256、源码链接

## 红线

- 不抄 LL-Remote 的代码：它没有 LICENSE 文件，`package.json` 是 `"private": true`，默认保留全部权利，只能当架构参考。
- 打包分发 Moonlight / Sunshine 二进制时，必须附它们的 LICENSE 和对应版本源码链接，见 `release/THIRD-PARTY.md`。
- 皎月连是专有组件，分发前必须先向供应商确认再分发条款。

## 状态

- 2026-11-26：项目建立，git init 完成；深度调研完成；启动器交互原型已出（Windows 版 + 安卓版）。
- 2026-11-26：已拍板——引擎 Moonlight、组网 Tailscale 首选 / ZeroTier 备选、仓库先私有、配对全在 LULU 内完成（见 `docs/decisions.md`）。
- 2026-11-26：Flutter 启动器 v1 骨架已搭好（`launcher/`，见 `launcher/BUILD.md`）。本机没有 Flutter/Dart，所以 `flutter pub get` / `flutter build` 还没跑过；配对握手、安卓 Game Intent 都还没对真机验证过。
- 2026-11-26：一键安装打包已做（`installer/` + `.github/workflows/build.yml`）：客户端和被控端两个 Inno Setup 安装包，CI 自动编译 Flutter、出安装包、发 Release；用户只下载成品。本机没有 Flutter、没有 Inno Setup、没有 Windows，所以安装包脚本和 CI 工作流都还没跑过，第一次 CI 是真正的测试。
