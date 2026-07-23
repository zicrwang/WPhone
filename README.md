# Empty Tunnel

这是一个可由 GitHub Actions 编译的 SwiftUI iOS App，包含一个 Packet Tunnel Provider Extension。VPN 启动后不读取 `packetFlow`，不设置包含路由，并显式排除默认路由；扩展只在 Wi-Fi 接口监听 TCP 8080 端口。

项目不使用任何第三方 Web 或网络框架。日志同时写入 Unified Logging 和 App Group 目录中的 `debug.log`，文件达到 512 KB 时自动轮转，主 App 内可直接查看。

## 当前签名标识

- 主 App：`app.star6979.lettuce4401`
- Packet Tunnel Extension：`app.star6979.lettuce4401.PacketTunnel`
- App Group：`group.3970029fa0cfcf6d.1`
- Apple Team ID：`84V4S488EQ`

提供的证书 ZIP 中，主 App profile 与上述主 App ID 匹配，包含 Packet Tunnel entitlement、选定的 App Group，以及用户提供的设备 UDID。证书和 profile 没有复制到本仓库。

嵌入式 Extension 必须使用独立 profile。请在 Apple Developer 网站注册 `app.star6979.lettuce4401.PacketTunnel`，启用 **Network Extensions > Packet Tunnel Provider** 和 `group.3970029fa0cfcf6d.1`，然后生成一份包含同一台设备的 Ad Hoc profile。创建 profile 不需要苹果电脑。

## GitHub Actions

每次推送都会执行无需签名的 Simulator 编译，用于校验主 App 和 Extension。进入 GitHub 仓库的 **Actions > Build iOS app > Run workflow** 后，会使用以下 Secrets 执行真机 Ad Hoc 签名并上传 IPA：

- `APPLE_TEAM_ID`：`84V4S488EQ`
- `IOS_P12_BASE64`：P12 文件的 Base64 内容
- `IOS_P12_PASSWORD`：证书 ZIP 中文本文件提供的 P12 密码
- `IOS_APP_MOBILEPROVISION_BASE64`：现有主 App profile 的 Base64 内容
- `IOS_EXTENSION_MOBILEPROVISION_BASE64`：新生成 Extension profile 的 Base64 内容
- `APPLE_SIGNING_CERTIFICATE`：可选；默认使用 `Apple Distribution`

Linux 环境可使用 `base64 -w 0 文件名` 生成单行 Secret。不要把 ZIP、P12、密码、profile 或 Base64 内容提交到 Git。

工作流会检查两个 profile 的 application identifier，并在不匹配时停止归档。最终 IPA 位于该次 workflow run 的 `EmptyTunnel-ipa` artifact 中。

## 使用

主 App 首次启动时会申请通知、本地网络和 VPN 配置权限。点击 **Start** 启动 Packet Tunnel，点击 **Stop** 停止。默认只接受来自 `192.168.1.10` 的 Wi-Fi TCP 连接；如需修改，请调整 `TunnelController.allowedClientIPv4` 后重新编译。

监听器接受以下精确命令：

```text
START_RING
STOP_RING
```

也可以发送 HTTP 请求：

```http
POST /START_RING HTTP/1.1
Host: iphone.local:8080

```

`START_RING` 提交一条 time-sensitive 本地通知，`STOP_RING` 移除对应的待处理和已送达通知。

## 平台限制

`NEPacketTunnelProvider` 不是永久后台运行保证。即使使用 Ad Hoc 或企业签名，iOS 仍可因系统策略、资源压力、网络切换或配置变化停止扩展。空包含路由和排除默认路由可避免主动接管普通流量，但不能承诺所有未来 iOS 版本行为完全相同。

普通本地通知只能播放一次系统声音，删除已送达通知不能中断已经开始的声音。持续响铃或 Critical Alert 需要不同的产品实现和 Apple 授权。
