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

## 骨架实现（2026-11-26，v1 scaffold）

- `launcher/` 已搭好：Flutter 一套代码出 Windows exe + Android APK，深绿主题、2 台设备列表、画质预设、在线状态、Tailscale 状态栏。
- 配对按上面“诚实说明”的方式实现：`launcher/lib/pairing/` 自己做 GameStream 4 阶段 `/pair` 握手（RSA-2048 自签证书 `CN=NVIDIA GameStream Client`、4 位 PIN 在 LULU 里显示、经 `POST /api/pin` 提交），配对模块单独按 GPL-3.0 处理，与 MIT 壳子分开。没有抄 LL-Remote 的代码。
- 上面两个待确认问题，骨架是按“接受”来写的：如果用户不接受，配对模块和密码存储要改，改动点见 `launcher/lib/pairing/README.md` 和 `launcher/BUILD.md`。
- 没验证过的都在 `launcher/BUILD.md`“What is NOT verified”里列着，最关键的三件：配对握手对真 Sunshine、安卓 Game Intent 带 LULU 自己的证书、`moonlight-qt pair` 无头方式（LULU 没用它，特意避开了）。
