# LULU Remote

自己的免费远程助手：一个薄启动器壳子，底层串流、组网、加密全部借用现成开源引擎，壳子只做设备列表、在线状态和一键连接。

## 定版方案（调研结论，待最终拍板）

- 串流引擎：Sunshine（装在两台被控 Windows 电脑上）+ 官方 Moonlight 客户端（Windows 用 Moonlight Qt，安卓用 Moonlight Android），均为 GPL-3.0，只调用、不改、不内嵌。
- 组网：Tailscale 免费版优先（组网地址按设备单独存，组网层可替换：ZeroTier / Headscale / frp / 皎月连都是备选）。
- 壳子：Flutter 一套 Dart 代码，同时出 Windows exe 和 Android APK；壳子自身代码用 MIT 许可，与 GPL 引擎之间只有进程 / Intent 调用边界。
- 备选引擎：RustDesk（AGPL-3.0）——如果文件传输和无人值守比画面流畅更重要，就换它，壳子只负责预配服务器参数。

## 目录

- `launcher/` — Flutter 启动器（Windows + Android 同一份代码）
- `scripts/host-setup/` — 被控端一键配置：装 Sunshine、开服务、打开配对页
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
