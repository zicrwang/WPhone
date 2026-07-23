# WPhone

这是一个可由 GitHub Actions 编译的 SwiftUI iOS App，安装后的名称为“手机信息通知”，包含一个 Packet Tunnel Provider Extension。VPN 只作为后台运行载体：启动后不读取 `packetFlow`，不设置包含路由，并显式排除默认路由，不承担代理、转发或流量处理。扩展只在 Wi-Fi 接口监听 TCP 8080 端口。

项目不使用任何第三方 Web 或网络框架。日志同时写入 Unified Logging 和 App Group 目录中的 `debug.log`，文件达到 512 KB 时自动轮转，主 App 内可直接查看。

## 当前标识

- 主 App：`app.wephone.vpn`
- Packet Tunnel Extension：`app.wephone.vpn.PacketTunnel`
- 工程/产品名：`WPhone`
- App 显示名：`手机信息通知`
- App Group：`group.3970029fa0cfcf6d.1`

## 固定构建方式

只有手动运行 GitHub Actions 工作流时，才会执行无需签名的真机 Release 编译，确认主 App 已嵌入 `PacketTunnel.appex`，并上传 `WPhone-unsigned-ipa` artifact。普通代码推送和 Pull Request 不构建 IPA。下载其中的 `WPhone-unsigned.ipa` 后，可以交给支持 App Extension 和相应 entitlement 的手机端签名工具处理；这条流程不需要 GitHub Secrets。

这是本项目的固定云端构建方式：GitHub Actions 不导入 P12、不安装 provisioning profile、不读取 Apple 签名 Secrets，也不执行 Ad Hoc 签名。`WPhone-unsigned.ipa` 内保持标准嵌套结构：`Payload/WPhone.app/PlugIns/PacketTunnel.appex`。

未签名 IPA 不会绕过 iOS 的签名校验。安装前仍需由手机端工具完成签名，并确保主 App 和嵌入的 `PacketTunnel.appex` 都被正确处理。通知授权和 VPN 连接流程此前已在实际设备上验证；更换为当前固定 Bundle ID 后，需要在下次手动构建并签名时重新确认。

仅在明确需要新 IPA 时，进入 GitHub 仓库的 **Actions > Build iOS app > Run workflow** 手动构建。最终下载 `WPhone-unsigned-ipa` artifact 即可。

## 使用

主 App 首次启动时会申请通知、本地网络和 VPN 配置权限。点击 **Start** 启动 Packet Tunnel，点击 **Stop** 停止。调试后台只接受经 Wi-Fi 到达的私网来源：`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`、IPv4 链路本地、IPv6 ULA/链路本地和回环地址。公网来源会在读取请求前被拒绝。

VPN 连接成功后，在同一局域网的电脑访问：

```text
http://<手机的局域网IP>:8080/
```

网页包含实时隧道/监听/通知/CallKit 状态、信息弹出调试、CallKit 来电调试和增量 `debug.log` 输出。日志按游标读取，每次最多 64 KB，不会在每次刷新时加载完整日志。服务还通过 Bonjour 发布 `_wphone-debug._tcp`。

## 局域网 API

正式事件协议由 WPhone 定义，字段和响应规范见 [WPhone Event API v1](Docs/WPhone-API-v1.md)，第三方软件的发送队列、重试和事件映射建议见 [外部软件接入指南](Docs/WPhone-Integration-Guide.md)。生产发送端使用：

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

让同一内网电脑上的 Codex 先读取下面的发现接口，即可按 OpenAPI 路由调用：

```bash
curl http://<手机的局域网IP>:8080/.well-known/wphone
curl http://<手机的局域网IP>:8080/openapi.json
```

旧的 `/.well-known/wphone-debug` 发现地址继续保留兼容。

接口没有账号或令牌认证，同一私网内的其他设备也能读取日志和触发通知；只应在可信局域网中开启 VPN。Codex 无法仅凭项目代码自动知道手机当前 IP，需要提供 IP，或先通过 `_wphone-debug._tcp` 的 mDNS/Bonjour 记录发现服务。

“CallKit 来电”由 Packet Tunnel Extension 的 `CXProvider` 报告系统来电页，但不会建立真实语音通道。拒绝会立即取消来电；接听会结束这个合成来电并提交一条带“打开微信/关闭”操作的本地通知。点击普通微信文字通知正文或“打开微信”后，系统先唤醒 WPhone，再由主 App 打开 `weixin://`。

CallKit 的系统“接听/拒绝”按钮由 iOS 管理，应用不能改名或接管系统“信息”按钮。Network Extension 也不能调用 `UIApplication` 打开其他 App，因此 CallKit 的接听键无法一步直达微信，接听后还需要点击一次“打开微信”通知。这是公开 API 的平台边界，不是接口配置问题。

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

`START_RING` 提交一条 time-sensitive 本地通知，`STOP_RING` 移除对应的待处理和已送达通知。

## 平台限制

`NEPacketTunnelProvider` 不是永久后台运行保证。即使使用 Ad Hoc 或企业签名，iOS 仍可因系统策略、资源压力、网络切换或配置变化停止扩展。空包含路由和排除默认路由可避免主动接管普通流量，但不能承诺所有未来 iOS 版本行为完全相同。

普通本地通知只能播放一次系统声音，删除已送达通知不能中断已经开始的声音。CallKit 来电由系统控制响铃和结束；Critical Alert 仍需要 Apple 单独授权。
