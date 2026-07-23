# WPhone

这是一个可由 GitHub Actions 编译的 SwiftUI iOS App，安装后的名称为“手机信息通知”，包含一个 Packet Tunnel Provider Extension。VPN 启动后不读取 `packetFlow`，不设置包含路由，并显式排除默认路由；扩展只在 Wi-Fi 接口监听 TCP 8080 端口。

项目不使用任何第三方 Web 或网络框架。日志同时写入 Unified Logging 和 App Group 目录中的 `debug.log`，文件达到 512 KB 时自动轮转，主 App 内可直接查看。

## 当前标识

- 主 App：`app.star6979.lettuce4401`
- Packet Tunnel Extension：`app.star6979.lettuce4401.PacketTunnel`
- 工程/产品名：`WPhone`
- App 显示名：`手机信息通知`
- App Group：`group.3970029fa0cfcf6d.1`
- Apple Team ID：`84V4S488EQ`

## 固定构建方式

每次推送都会执行无需签名的真机 Release 编译，确认主 App 已嵌入 `PacketTunnel.appex`，并上传 `WPhone-unsigned-ipa` artifact。下载其中的 `WPhone-unsigned.ipa` 后，可以交给支持 App Extension 和相应 entitlement 的手机端签名工具处理；这条流程不需要 GitHub Secrets。

这是本项目的固定云端构建方式：GitHub Actions 不导入 P12、不安装 provisioning profile、不读取 Apple 签名 Secrets，也不执行 Ad Hoc 签名。`WPhone-unsigned.ipa` 内保持标准嵌套结构：`Payload/WPhone.app/PlugIns/PacketTunnel.appex`。

未签名 IPA 不会绕过 iOS 的签名校验。安装前仍需由手机端工具完成签名，并确保主 App 和嵌入的 `PacketTunnel.appex` 都被正确处理。已经在实际设备上验证：手机端签名后可以申请通知权限并连接 VPN。

进入 GitHub 仓库的 **Actions > Build iOS app > Run workflow** 可手动重新构建；也可以直接推送到 `main` 自动触发。最终下载 `WPhone-unsigned-ipa` artifact 即可。

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
