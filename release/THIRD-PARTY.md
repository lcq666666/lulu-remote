# 第三方组件清单（发布时随包附带）

打包分发时每个引擎都要填：版本、SHA-256、源码链接，并附其 LICENSE 全文。

| 组件 | 许可 | 版本 | SHA-256 | 源码 |
|---|---|---|---|---|
| Sunshine | GPL-3.0 | 待定版时填 | | https://github.com/LizardByte/Sunshine |
| Moonlight Qt | GPL-3.0 | 待定版时填 | | https://github.com/moonlight-stream/moonlight-qt |
| Moonlight Android | GPL-3.0 | 待定版时填 | | https://github.com/moonlight-stream/moonlight-android |
| Tailscale 客户端 | BSD-3-Clause（客户端） | 待定版时填 | | https://tailscale.com |

LULU 启动器自身代码不链接以上任何库：Windows 端以子进程方式调用 `moonlight-qt.exe`，安卓端以 Intent 方式调起 `com.limelight.ShortcutTrampoline`。
