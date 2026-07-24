# WPhone

这是一个可由 GitHub Actions 编译的 SwiftUI iOS App，安装后的名称为“手机信息通知”，包含一个 Packet Tunnel Provider Extension。VPN 只作为后台运行载体：启动后不读取 `packetFlow`，不设置包含路由，并显式排除默认路由，不承担代理、转发或流量处理。扩展在 Wi-Fi 接口保留 TCP 8080 调试监听，同时主动连接中继站，默认地址为 `192.168.2.99:18081`。

项目不使用任何第三方 Web 或网络框架。日志同时写入 Unified Logging 和 App Group 目录中的 `debug.log`，文件达到 512 KB 时自动轮转，主 App 内可直接查看。

来电提醒使用 iOS `.timeSensitive` 本地通知，不创建系统闹铃、锁屏闹铃界面或 Live Activity。项目最低支持 iOS 26.0，并要求 GitHub Actions 使用 Xcode 26。首次运行必须允许通知和时效通知；不需要 APNs、远程推送或 Critical Alert entitlement。

## 当前标识

- 主 App：`app.wephone.vpn`
- Packet Tunnel Extension：`app.wephone.vpn.PacketTunnel`
- 工程/产品名：`WPhone`
- App 显示名：`手机信息通知`
- App Group：`group.3970029fa0cfcf6d.1`

## 固定构建方式

只有手动运行 GitHub Actions 工作流时，才会执行无需签名的真机 Release 编译，确认主 App 已嵌入 `PacketTunnel.appex`，并上传 `WPhone-unsigned-ipa` artifact。普通代码推送和 Pull Request 不构建 IPA。下载其中的 `WPhone-unsigned.ipa` 后，可以交给支持 App Extension 和相应 entitlement 的手机端签名工具处理；这条流程不需要 GitHub Secrets。

这是本项目的固定云端构建方式：GitHub Actions 不导入 P12、不安装 provisioning profile、不读取 Apple 签名 Secrets，也不执行 Ad Hoc 签名。`WPhone-unsigned.ipa` 内保持标准嵌套结构：`Payload/WPhone.app/PlugIns/PacketTunnel.appex`。

未签名 IPA 不会绕过 iOS 的签名校验。安装前仍需由手机端工具完成签名，并确保主 App 和嵌入的 `PacketTunnel.appex` 都被正确处理。签名配置必须为两个 Bundle ID 保留 App Groups、Network Extension 和 Time Sensitive Notifications capability；来电使用后者提交时效通知。通知授权和 VPN 连接流程此前已在实际设备上验证；更换为当前固定 Bundle ID 后，需要在下次手动构建并签名时重新确认。

仅在明确需要新 IPA 时，进入 GitHub 仓库的 **Actions > Build iOS app > Run workflow** 手动构建。最终下载 `WPhone-unsigned-ipa` artifact 即可。

## 使用

主 App 首次启动时会申请通知、时效通知、本地网络和 VPN 配置权限。在“中继站”中填写 Armbian 地址和通道端口，然后点击“启动”。“通知设置”按钮会进入本应用的系统通知页；请打开横幅、声音和时效通知。应用代码不能代替用户修改这些偏好。“来电横幅铃声”可从“文件”选择一份自定义声音或恢复内置声音。调试后台只接受经 Wi-Fi 到达的私网来源：`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`、IPv4 链路本地、IPv6 ULA/链路本地和回环地址。

中继服务默认监听 HTTP `18080` 和 iPhone 长连接 `18081`：

```bash
python3 Relay/wphone_relay.py
curl http://192.168.2.99:18080/health
```

Armbian 上可使用仓库内的 systemd 单元使中继随开机启动：

```bash
cp Relay/wphone-relay.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now wphone-relay.service
```

健康响应中的 `providers` 为 `1` 时，表示 Packet Tunnel 已连接中继。iPhone 通过出站长连接注册，iPhone 的 DHCP 地址发生变化后会自动重连，发送端不需要知道新的 iPhone IP。

VPN 连接成功后，在同一局域网的电脑访问：

```text
http://<手机的局域网IP>:8080/
```

网页包含实时隧道、监听、通知状态、信息弹出调试、时效来电通知调试和增量 `debug.log` 输出。日志按游标读取，每次最多 64 KB，不会在每次刷新时加载完整日志。服务还通过 Bonjour 发布 `_wphone-debug._tcp`。

## 局域网 API

正式事件协议由 WPhone 定义，字段和响应规范见 [WPhone Event API v1](Docs/WPhone-API-v1.md)，第三方软件的发送队列、重试和事件映射建议见 [外部软件接入指南](Docs/WPhone-Integration-Guide.md)，来电时效通知的权限、状态和真机验收见 [WPhone 来电通知说明](Docs/WPhone-Notifications.md)。生产发送端向中继站使用：

```text
POST http://192.168.2.99:18080/api/v1/events
Content-Type: application/json
```

该接口包含版本化事件信封、类型校验、跨扩展重启的 App Group 幂等记录和统一错误响应。`/api/debug/*` 继续只用于人工调试，不作为 Tasker 的正式通知入口。

Packet Tunnel 的 TCP 8080 入口继续保留作诊断和兼容，机器可读入口包括：

```text
GET  /.well-known/wphone
GET  /openapi.json
GET  /api/status
GET  /api/logs?cursor=<上次返回的cursor>
POST /api/debug/message?title=<标题>&body=<内容>
POST /api/debug/call?caller=<来电名称>
POST /api/debug/stop
```

如需直接调试 iPhone，可读取下面的发现接口：

```bash
curl http://<手机的局域网IP>:8080/.well-known/wphone
curl http://<手机的局域网IP>:8080/openapi.json
```

旧的 `/.well-known/wphone-debug` 发现地址继续保留兼容。

中继和 iPhone 调试接口都没有账号或令牌认证，只应部署在可信局域网。正式发送端固定调用中继站，不再依赖 iPhone 当前 IP；只有访问 iPhone 调试网页时才需要 IP 或 `_wphone-debug._tcp` Bonjour 发现。

“时效来电通知”会立即提交一条可点击微信的 iOS `.timeSensitive` 本地通知。WPhone 不再创建系统闹铃、锁屏闹铃界面、Dynamic Island 活动或 Live Activity。点“关闭”或收到匹配的 `call.ended` 会移除通知；无操作时，Packet Tunnel 在提交后 30 秒自动清理。点“打开”会唤醒 WPhone，再由主 App 打开 `weixin://`。时效通知仍受用户通知授权、专注模式、通知摘要与其他系统策略控制。

## 来电声音

来电时效通知默认使用 [WPhoneIncomingCall.wav](Resources/WPhoneIncomingCall.wav)。仓库内置的是 10 秒、单声道、22.05 kHz Linear PCM WAV，工程已把它复制到主 App 和 Packet Tunnel Extension 两个 bundle。文档选择器只显示 WAV、CAF 或 AIFF，采用“打开副本”模式，选择后直接导入；文件最长 29 秒、最大 20 MB，并校验 Linear PCM、IMA4、µLaw 或 aLaw 编码。文件保存到 App Group 的 `Library/Sounds`。资源缺失时 WPhone 回退到内置或系统默认声音。`/api/status` 会报告来电声音、时效通知级别、30 秒自动清理时间和 `alertStyle`；后者为 `persistent` 才表示用户已选择持续横幅。

VPN 只提供 Packet Tunnel Extension 的后台生命周期，不参与路由、代理或通知展示。局域网 HTTP 监听器和来电通知的 30 秒自动清理由 Packet Tunnel 进程执行；停止 VPN 后 iOS 会终止该进程，因此在重新连接 VPN 前无法接收新的局域网事件，已经显示的通知也不再保证按时自动移除。这是后台入口的生命周期限制，不是通知权限依赖 VPN。

VPN Extension 不能调用 `UIApplication`，所以“打开”操作由本地通知唤醒主 App，主 App 再打开微信。系统会短暂经过 WPhone；公开 API 不支持由后台扩展在完全无用户操作的情况下直接启动微信。

## 兼容指令

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

`START_RING` 提交一条时效来电通知，`STOP_RING` 移除对应的待处理和已送达通知。

## 平台限制

`NEPacketTunnelProvider` 不是永久后台运行保证。即使使用 Ad Hoc 或企业签名，iOS 仍可因系统策略、资源压力、网络切换或配置变化停止扩展。空包含路由和排除默认路由可避免主动接管普通流量，但不能承诺所有未来 iOS 版本行为完全相同。

本地通知只能播放一次声音，删除已送达通知不能中断已经开始的声音。时效通知不是 Critical Alert，仍可能受用户授权、专注模式、通知摘要、静音模式和系统策略影响；应用不能强制“持续”横幅。Packet Tunnel 保持运行时，未收到关闭信号的来电通知会在提交 30 秒后自动清理；停止 VPN 后扩展可能被系统终止，因此无法保证该进程内计时器继续运行。
