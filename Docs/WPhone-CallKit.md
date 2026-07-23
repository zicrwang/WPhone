# WPhone CallKit 说明

WPhone 使用 CallKit 显示局域网来电提醒。它不创建真实通话、不传输音频，也不使用 AlarmKit、PushKit 或 APNs。Packet Tunnel 只负责后台生命周期和局域网入口，不路由设备流量。

## 交互流程

```text
Tasker/局域网软件
  -> POST /api/v1/events (call.incoming)
  -> Packet Tunnel Extension 的 CXProvider 报告系统来电
       拒绝 -> 结束合成来电
       接听 -> 立即结束合成来电
            -> 提交无声的 time-sensitive 本地通知
            -> 点击通知正文或“打开微信”(.foreground)
            -> WPhone 前台激活
            -> 自动打开 weixin://
            -> 失败时显示全屏“打开微信”按钮
```

WPhone 当前只保留一个活动来电。新的 `call.incoming` 会以 `unanswered` 结束上一个；`call.ended` 通过同一 `source` 下的 `targetId` 结束匹配来电。`POST /api/debug/stop`、`POST /STOP_RING` 和停止 VPN 都会结束扩展中的活动来电。

接听后的通知不播放声音，避免 CallKit 铃声刚结束又响一次。自定义动作使用 `UNNotificationActionOptions.foreground`；直接点击通知正文也会启动 WPhone 并执行同一路由。主 App 等到前台激活后约 350ms 再尝试打开微信，以减少冷启动期间的跳转失败。待处理路由最多保留 60 秒，避免以后打开 WPhone 时误跳微信。

## 权限和 Target

- 主 App 需要通知权限，否则接听后的交接通知无法显示。
- CallKit 没有单独的用户授权弹窗。
- PacketTunnel Target 继续需要 Network Extension 和 App Groups capability。
- 主 App 继续需要 Personal VPN 和 App Groups capability。
- 两个 Target 必须使用同一个 App Group：`group.3970029fa0cfcf6d.1`。
- 不再需要 `NSAlarmKitUsageDescription`、AlarmKit 源码或 iOS 26 最低版本。

## 自定义铃声

`PacketTunnelProvider` 会检查 PacketTunnel 扩展 bundle 中是否存在：

```text
WPhoneRingtone.caf
```

若存在，代码将 `CXProviderConfiguration.ringtoneSound` 设置为该文件；若不存在，则保留 `nil` 并使用系统 CallKit 铃声。由于 `CXProvider` 位于扩展进程，文件必须加入 **PacketTunnel** Target Membership，仅加入主 App 无效。

在 Xcode 中添加铃声：

1. 将 `WPhoneRingtone.caf` 拖入工程。
2. 勾选 **Copy items if needed**。
3. Target Membership 只勾选 **PacketTunnel**。
4. 构建后确认文件位于 `WPhone.app/PlugIns/PacketTunnel.appex/WPhoneRingtone.caf`。
5. 连接 VPN，读取 `/api/status`；`notifications.customRingtone` 应为 `WPhoneRingtone.caf`。

铃声的循环、音量、静音模式响应和界面由 iOS 的 CallKit 管理。更换铃声后需要重新构建并安装。

## 调试接口

```text
POST /api/debug/call?caller=微信来电
POST /api/debug/stop
GET  /api/status
GET  /api/logs?cursor=0
```

`GET /api/status` 的 `notifications` 对象包含：

| 字段 | 含义 |
| --- | --- |
| `authorization` | 本地通知授权状态 |
| `callKit` | 当前构建是否启用 CallKit |
| `activeCallCount` | 当前活动的合成来电数，最大为 1 |
| `activeCallKey` | 当前来电的 `source:id`，空闲时为 `null` |
| `caller` | 当前来电名称，空闲时为 `null` |
| `customRingtone` | 实际启用的铃声文件名；系统铃声时为 `null` |
| `answerBehavior` | `end-call-then-foreground-notification` |
| `openBehavior` | `notification-opens-wphone-then-wechat` |

成功日志应依次出现：

```text
DEBUG_CALLKIT_INCOMING CallKit call reported key=...
CallKit answered and ended key=...
CALLKIT_HANDOFF_NOTIFICATION notification submitted
WeChat handoff requested from notification action
WeChat opened from WPhone handoff
```

若自动跳转失败，日志会出现 `Automatic WeChat handoff failed; showing fallback`，主 App 显示全屏按钮。

## 平台边界

Packet Tunnel Extension 不能调用 `UIApplication.open`。因此 CallKit 的“接听”只能结束合成来电并发出系统通知，不能直接打开微信。公开 API 下没有比 `.foreground` 通知动作更无感、同时又能合法把主 App 带到前台的通知类型；这一步仍需要用户点击通知正文或动作按钮。

停止 VPN 后，Packet Tunnel 进程、局域网监听器和其中的 `CXProvider` 都不会继续运行。已经送达的交接通知仍由系统管理，但停止后不能接收新的局域网来电事件。
