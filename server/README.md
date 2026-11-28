# 在线激活服务

Windows 发布包提供同一个 Go 程序的两个文件名。`lulu-auth-<版本>-windows-x64.exe` 用于服务端。`lulu-keygen-<版本>-windows-x64.exe` 提供相同的管理命令。运行程序无需安装 Go 或 SQLite。

## 初始化和开机自启

把程序放在常开的 Windows 电脑上，以运行服务的 Windows 帐号打开 PowerShell。把下例的本地程序路径和组网地址替换成这台机器的实际值。

```powershell
$auth = 'C:\LuluAuth\lulu-auth-<版本>-windows-x64.exe'
$data = Join-Path $env:LOCALAPPDATA 'LuluActivation'
$listen = '100.64.10.20:8765'
& $auth --data-dir $data init
& $auth --data-dir $data serve --listen $listen
```

`init` 输出公钥，重复运行使用原来的公钥。把输出写入 GitHub 仓库的 `LULU_ACTIVATION_PUBLIC_KEY` Actions 变量。把完整的组网 URL 写入 `LULU_ACTIVATION_SERVER`，例如 `http://100.64.10.20:8765`。正式版标签使用这两个值构建 Windows 与 Android 启动器，配置缺失会停止发布。`-rc.` 标签使用 `LULU_ACTIVATION_PREVIEW_PUBLIC_KEY`，由验收人员在激活页填写预览服务的组网地址。日常 PR 构建保留调试入口。为同仓库 PR 或手动运行工作流（勾选 `activation_preview`）制作真机验收包时，可分别配置 `LULU_ACTIVATION_PREVIEW_PUBLIC_KEY` 和 `LULU_ACTIVATION_PREVIEW_SERVER`，用独立的数据目录、签名私钥和服务器运行验收服务。需要本地测试激活门时，用 `flutter build windows --release` 或 `flutter build apk` 并传入三个参数：`--dart-define=LULU_ACTIVATION_REQUIRED=true`、`--dart-define=LULU_ACTIVATION_PUBLIC_KEY=<公钥>`、`--dart-define=LULU_ACTIVATION_SERVER=<组网 URL>`。

在 Windows 任务计划程序里创建任务，程序填 `$auth` 对应的完整路径，参数填 `--data-dir "<数据目录>" serve --listen <组网IP>:8765`。选择初始化时用的同一 Windows 帐号，任务触发器设为「启动时」，延迟 1 分钟，失败后每 1 分钟重试。需要防火墙规则时，只允许组网客户端访问指定 IPv4 地址与 TCP 端口。可用 `GET /v1/status` 从组网内检查服务是否启动。HTTP 部署依赖受信任的加密组网以及组网成员访问限制。

## 生成和吊销

```powershell
& $auth --data-dir $data keys generate --count 20 --note 实验室
& $auth --data-dir $data keys list
& $auth --data-dir $data devices list
& $auth --data-dir $data devices revoke '<devices list 中完整的 64 位指纹哈希>'
```

生成的密钥只在生成时显示。服务端签发令牌时即标记密钥为已用。如果此时网络中断或客户端无法保存令牌，可在 `keys list` 中确认是否已签发，再给设备发一枚新密钥。被吊销的设备无法用新密钥激活，也不会占用该密钥。`keys revoke <未使用密钥>` 可以作废未发出的密钥。PowerShell 可先用 `Read-Host` 读入密钥参数，避免把实际密钥打进命令历史。

Windows 绑主板序列号、系统盘序列号、MachineGuid 三项的分项哈希，至少两项匹配时继续使用。Android 使用系统提供的 `ANDROID_ID`，签名密钥、系统用户或设备重置后可能要重新激活。服务端只接收分项哈希和机器码。激活后的令牌由应用写入系统安全存储，客户端启动时离线验签。先确认激活服务在线并能提供有效签名，再发送每周最多一次的吊销复核。网络或服务不可用时继续使用，不占用本周复核机会。程序保持运行时，失败的在线探测间隔至少五分钟。管理员吊销时应从列表选择目标设备对应的完整指纹哈希。如果同一设备因硬件变化重新领码并产生了另一个指纹，需分别吊销两个记录。

## 备份和恢复

上例的数据目录在当前 Windows 帐号的 `%LOCALAPPDATA%\LuluActivation`。`activation.db` 存储密钥摘要、已用状态及吊销记录。停止服务、确认没有发码操作后复制该数据库即可备份业务记录。`signing.seed` 是服务器签名私钥。把它单独保存在服务器的受保护备份中，限制为运行服务的账号可访问。更换服务器时恢复数据库和原来的签名私钥，保持客户端公钥一致。

本地开发命令为 `go test ./...` 和 `go build .`。使用 `127.0.0.1:<端口>` 可在同一台电脑上做测试。客户端与 Go 服务器的联调测试通过 `LULU_AUTH_TEST_EXE` 指定本地测试程序。
