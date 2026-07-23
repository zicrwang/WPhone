# WPhone

这是一个可由 GitHub Actions 编译的 SwiftUI iOS App，安装后的名称为“手机信息通知”。项目现在以 Local Push Connectivity 为主要局域网后台通道，并保留 Packet Tunnel Provider 作为兼容和调试入口。Local Push Extension 与同网段中继保持 TCP 长连接，不依赖 APNs；中继继续向外提供 WPhone Event API v1。

项目不使用任何第三方 Web 或网络框架。日志同时写入 Unified Logging 和 App Group 目录中的 `debug.log`，文件达到 512 KB 时自动轮转，主 App 内可直接查看。

来电提醒使用主 App 中的 CallKit，项目最低支持 iOS 15.0。Local Push Extension 收到 `call.incoming` 后调用系统的 `reportIncomingCall(userInfo:)`，iOS 唤起主 App 的 `NEAppPushDelegate`，再由主 App 报告 CallKit。它不使用 AlarmKit、PushKit、APNs 或 Critical Alert entitlement。

## 当前标识

- 主 App：`app.wephone.vpn`
- Packet Tunnel Extension：`app.wephone.vpn.PacketTunnel`
- Local Push Extension：`app.wephone.vpn.AppPushProvider`
- 工程/产品名：`WPhone`
- App 显示名：`手机信息通知`
- App Group：`group.3970029fa0cfcf6d.1`

## 固定构建方式

只有手动运行 GitHub Actions 工作流时，才会执行无需签名的真机 Release 编译，确认主 App 已嵌入 `PacketTunnel.appex` 和 `AppPushProvider.appex`，并上传 `WPhone-unsigned-ipa` artifact。普通代码推送和 Pull Request 不构建 IPA。下载其中的 `WPhone-unsigned.ipa` 后，可以交给支持 App Extension 和相应 entitlement 的手机端签名工具处理；这条流程不需要 GitHub Secrets。

这是本项目的固定云端构建方式：GitHub Actions 不导入 P12、不安装 provisioning profile、不读取 Apple 签名 Secrets，也不执行 Ad Hoc 签名。两个 Extension 都位于 `Payload/WPhone.app/PlugIns/`。

未签名 IPA 不会绕过 iOS 的签名校验。安装前仍需确保主 App、`PacketTunnel.appex` 和 `AppPushProvider.appex` 都被正确签名。Local Push 还要求主 App 和 App Push Extension 的 provisioning profile 实际包含 `app-push-provider` entitlement；仅修改 entitlements 文件不能绕过这一要求。

仅在明确需要新 IPA 时，进入 GitHub 仓库的 **Actions > Build iOS app > Run workflow** 手动构建。最终下载 `WPhone-unsigned-ipa` artifact 即可。

## 使用

先在局域网内一台长期在线的电脑运行中继：

```bash
python3 Relay/wphone_relay.py --http-port 8080 --provider-port 8081
```

主 App 的 **Local Push** 区域填写 iPhone 当前连接的精确 Wi-Fi SSID、中继电脑的局域网 IP 和端口 `8081`，然后点击 **Enable**。`GET http://<中继IP>:8080/health` 返回 `providers: 1` 表示 iPhone 扩展已经连入。完整配置和验收步骤见 [Local Push 部署说明](Docs/WPhone-Local-Push.md)。

兼容模式仍可点击 **Start** 启动 Packet Tunnel，点击 **Stop** 停止。它只接受经 Wi-Fi 到达的私网来源，不承担 VPN 流量转发。

VPN 连接成功后，在同一局域网的电脑访问：

```text
http://<手机的局域网IP>:8080/
```

网页包含实时隧道、监听、通知、CallKit 活动来电与铃声状态、信息弹出调试、CallKit 来电调试和增量 `debug.log` 输出。日志按游标读取，每次最多 64 KB，不会在每次刷新时加载完整日志。服务还通过 Bonjour 发布 `_wphone-debug._tcp`。

## 局域网 API

正式事件协议由 WPhone 定义，字段和响应规范见 [WPhone Event API v1](Docs/WPhone-API-v1.md)，第三方软件的发送队列、重试和事件映射建议见 [外部软件接入指南](Docs/WPhone-Integration-Guide.md)，来电交互、铃声和真机验收见 [WPhone CallKit 说明](Docs/WPhone-CallKit.md)。Local Push 模式下，生产发送端向中继电脑使用：

```text
POST /api/v1/events
Content-Type: application/json
```

该接口包含版本化事件信封、类型校验、跨扩展重启的 App Group 幂等记录和统一错误响应。`/api/debug/*` 继续只用于人工调试，不作为 Tasker 的正式通知入口。

供 Codex、脚本或其他同网段工具使用的机器可读入口：

```text
GET  /.well-known/wphone
GET  /openapi.json
GET  /api/status
GET  /api/logs?cursor=<上次返回的cursor>
POST /api/debug/message?title=<标题>&body=<内容>
POST /api/debug/call?caller=<来电名称>
POST /api/debug/stop
```

下面的发现和调试接口由 Packet Tunnel 兼容入口提供；Local Push 中继只提供 `/health`、`/api/status` 和 `/api/v1/events`：

```bash
curl http://<手机的局域网IP>:8080/.well-known/wphone
curl http://<手机的局域网IP>:8080/openapi.json
```

旧的 `/.well-known/wphone-debug` 发现地址继续保留兼容。

接口没有账号或令牌认证，同一私网内的其他设备也能触发通知；中继和 Packet Tunnel 兼容入口都只应在可信局域网使用。Codex 无法仅凭项目代码自动知道中继或手机当前 IP，需要显式提供目标地址；兼容入口也可通过 `_wphone-debug._tcp` 的 mDNS/Bonjour 记录发现。

Local Push 的“CallKit 来电”通过系统 `NEAppPushProvider -> NEAppPushDelegate` 唤醒链路交给主 App 的 `CXProvider`，不会建立真实语音通道。拒绝会立即取消来电；接听会立即结束这个合成来电，并提交一条无声、time-sensitive、带 `.foreground` 操作的“打开微信”通知。点击通知正文或“打开微信”后，系统先将 WPhone 置于前台，WPhone 在激活后自动尝试 `weixin://`；自动跳转失败时显示全屏“打开微信”按钮。

VPN 只提供 Packet Tunnel 兼容入口的后台生命周期，不参与路由、代理或 CallKit。停止 VPN 会结束 iPhone 上的兼容 HTTP 监听器，但不会停止已经激活的 Local Push 通道，也不会主动结束主 App 已经报告的 CallKit 来电或通知。

`CXProvider` 和接听回调现在都位于主 App，但 iOS 仍不允许接听动作无用户确认地启动另一个 App。“打开微信”由 `.foreground` 通知动作完成，系统会短暂经过 WPhone；通知正文的默认点击执行相同路由。

CallKit 支持自定义铃声。主 App 会在自身 bundle 中查找 `WPhoneRingtone.caf`：把该文件加入 Xcode 工程并只勾选 **WPhone** Target Membership 后，`CXProviderConfiguration.ringtoneSound` 会自动启用它；文件缺失时使用系统 CallKit 铃声。`GET /api/status` 的 `notifications.customRingtone` 会显示实际启用的文件名或 `null`。

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

`START_RING` 报告一条 CallKit 来电，`STOP_RING` 结束当前调试来电并移除对应的待处理和已送达通知。

## 平台限制

`NEAppPushProvider` 由 iOS 根据 `matchSSIDs` 激活；SSID 不匹配、网络切换、entitlement 或 provisioning profile 不正确时不会保持通道。中继必须位于 iPhone 可访问的同一可信局域网。运行时事件链路不经过 APNs 或本项目之外的云服务。

兼容入口的 `NEPacketTunnelProvider` 也不是永久后台运行保证。即使使用 Ad Hoc 或企业签名，iOS 仍可因系统策略、资源压力、网络切换或配置变化停止扩展。

WPhone 当前一次只保留一条活动 CallKit 来电，新来电会以“未接听”结束上一条。铃声、接听/拒绝界面和最终呈现由 iOS 控制。Local Push 来电通过系统的 `reportIncomingCall` 唤起链路交付；Packet Tunnel 兼容入口在主 App 无法接收 Darwin 通知时仍会回退为有声通知。接听后的交接通知刻意不播放声音，避免系统来电结束后重复响铃。CallKit 应用于合成提醒不等于真实 VoIP 通话，WPhone 不传输或接管任何音频。
