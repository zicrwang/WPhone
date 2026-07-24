# WPhone AlarmKit 说明

WPhone 从 iOS 26 起使用 AlarmKit 显示局域网来电提醒。它不创建真实通话，也不传输音频。

## 系统与工程要求

- 设备必须运行 iOS 26.0 或更高版本；当前目标设备为 iOS 26.1。
- 工程必须使用 Xcode 26 和 iOS 26 SDK 构建。
- 主 App 的 `Info.plist` 必须包含 `NSAlarmKitUsageDescription`。本项目也在 Packet Tunnel 的 `Info.plist` 中提供同一用途说明，以便真机验证扩展调度路径。
- 用户必须至少打开主 App 一次并允许 AlarmKit 权限。
- AlarmKit 不需要额外 entitlement。工程原有的 Network Extension 和 App Groups capability 保持不变。
- time-sensitive 本地通知需要 `com.apple.developer.usernotifications.time-sensitive` entitlement；主 App 和 Packet Tunnel target 均已声明，重签名配置必须保留该 capability。它不要求 APNs。
- 主 App 与 Packet Tunnel Extension 必须使用同一 App Group，供活动闹钟状态和“接听”动作交接使用。

## 行为流程

```text
Tasker/局域网软件
  -> POST 中继站 192.168.2.99:18080/api/v1/events
  -> 中继站通过 iPhone 主动建立的 TCP 长连接转发
  -> Packet Tunnel Extension 接收 call.incoming
       -> 调度 AlarmKit，约 1 秒后显示系统提醒
       -> 同时提交 time-sensitive 本地通知顶部横幅
       关闭 -> 停止并取消提醒
       打开 -> 停止提醒 -> 唤醒 WPhone -> 打开 weixin://
       50 秒内无关闭信号 -> 自动停止提醒并清理横幅
```

WPhone 当前只保留一条活动 AlarmKit 来电。新来电会停止上一条；`call.ended` 只有在 `source + targetId` 与活动来电匹配时才停止它。`POST /api/debug/stop` 和 `POST /STOP_RING` 会停止活动提醒。没有收到这些关闭信号且用户也没有操作时，Packet Tunnel 会在提醒触发 50 秒后调用 AlarmKit `stop/cancel` 并移除横幅。停止 VPN 会断开中继长连接，但不会立即取消已经调度给系统的提醒；由于 50 秒清理由 Packet Tunnel 进程执行，超时期间应保持 VPN 运行。

“接听”必须经过主 App，因为 Packet Tunnel Extension 受 App Extension API 限制，不能调用 `UIApplication`。AlarmKit 的 `LiveActivityIntent` 负责在用户点击后唤醒 WPhone，WPhone 再打开微信。该过程需要一次明确的用户点击，不能无人值守启动微信。

## 系统呈现策略

WPhone 只创建 `AlarmPresentation.Alert`，不设置 `Alarm.CountdownDuration`，也不包含 Widget/自定义 Live Activity 或应用自己的全屏来电页。每次来电还会并行提交 `interruptionLevel = .timeSensitive` 的本地通知，因为公开 API 不能可靠读取锁屏状态，也不能确认 AlarmKit UI 是否实际展开：

- 手机仍处于锁定状态时，由 iOS 显示锁屏闹铃界面并响铃。仅点亮屏幕但没有解锁，仍属于这种情况。
- 手机已经解锁且正在使用时，由 iOS 在 Dynamic Island 或顶部系统区域显示闹铃并响铃，不主动打开 WPhone 的全屏界面。
- 没有公开 API 可以读取可靠的锁屏状态，或指定 Alert 的宽高、位置以及强制 compact/full-screen 样式。系统可能在响铃瞬间临时展开顶部提醒，最终样式仍由设备型号和 iOS 决定。
- 应用只能请求 `.banner` 呈现，不能把横幅风格强制改为“持续”。请在主 App 点击“通知设置”，由用户打开横幅、声音、时效通知，并把横幅风格选为“持续”。

Apple 的 [AlarmKit 示例](https://developer.apple.com/documentation/AlarmKit/scheduling-an-alarm-with-alarmkit)说明：仅需 Alert 的闹铃应只提供 Alert presentation；Widget Extension 用于自定义非响铃的 countdown presentation。WWDC25 的 [Wake up to the AlarmKit API](https://developer.apple.com/videos/play/wwdc2025/230/)说明 Alert 支持 Dynamic Island，且 AlarmKit 使用 ActivityKit 呈现。对于没有 Dynamic Island 的设备，ActivityKit 的[系统呈现说明](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)会在解锁状态下将提醒显示为屏幕顶部 banner；据此可预期 AlarmKit 采用相应的顶部系统区域，但 AlarmKit 没有承诺固定几何形态。以上资料都没有提供由 App 强制指定 Alert 尺寸的接口。

## 自定义声音

AlarmKit 的 `sound` 使用 `AlertConfiguration.AlertSound.named(...)`，本地通知使用同名 `UNNotificationSound`。工程把 [WPhoneIncomingCall.wav](../Resources/WPhoneIncomingCall.wav) 同时加入主 App 和 Packet Tunnel Extension 的 Resources build phase；内置文件为精确 10 秒、单声道 22.05 kHz Linear PCM WAV。

主 App 的“来电铃声”区域可以从“文件”选择 WAV、CAF 或 AIFF，限制为 10 秒和 20 MB，并校验 Linear PCM、IMA4、µLaw 或 aLaw 编码。文件存入 App Group 的 `Library/Sounds`，普通通知可直接读取；AlarmKit 调度前还会复制到当前主 App 或 Packet Tunnel 数据容器的 `Library/Sounds`。点击“恢复内置”会删除运行时选择。自定义资源丢失或复制失败时回退到内置声音，内置资源也缺失时再回退到系统默认声音。

## 接口

正式来电事件继续使用稳定的 v1 协议，并发送到中继站 HTTP 端口：

```http
POST /api/v1/events HTTP/1.1
Host: 192.168.2.99:18080
Content-Type: application/json
```

```json
{
  "specVersion": 1,
  "id": "wechat-call-550e8400-e29b-41d4-a716-446655440000",
  "source": "wechat.tasker",
  "type": "call.incoming",
  "occurredAt": 1784800000123,
  "payload": {
    "caller": "联系人",
    "callKind": "voice"
  }
}
```

人工调试接口：

```http
POST /api/debug/call?caller=微信来电
POST /api/debug/stop
```

`/api/debug/call` 返回 HTTP `202` 只表示异步调度已提交。最终结果应通过 `GET /api/status` 和增量日志确认。

## 状态与日志

`GET /api/status` 的 `alarmKit` 对象包含：

| 字段 | 含义 |
| --- | --- |
| `supported` | 当前构建是否包含 AlarmKit |
| `authorization` | 兼容字段，当前等同于 `extensionAuthorization` |
| `hostAuthorization` | 主 App 最近写入 App Group 的授权状态 |
| `hostAuthorizationUpdatedAt` | 主 App 最近更新授权状态的时间 |
| `extensionAuthorization` | Packet Tunnel 进程读取到的授权状态；它可能与主 App 不同 |
| `active` | App Group 中是否记录活动提醒 |
| `activeAlarmId` | AlarmKit UUID，没有活动提醒时为 `null` |
| `activeCallKey` | `source:id`，调试或旧接口使用固定键 |
| `caller` | 当前来电名称 |
| `scheduledAt` | ISO 8601 调度时间 |
| `expiresAt` | 没有关闭信号时自动停止的 ISO 8601 时间 |
| `triggerDelaySeconds` | 当前固定为 1 |
| `maximumAlertDurationSeconds` | 当前固定为 50 |
| `sound` | AlarmKit 自定义声音文件名 |
| `soundAvailable` | 当前进程或 App Group 是否能找到来电声音 |
| `soundCustom` | 当前是否使用页面导入的铃声 |
| `soundDurationSeconds` | 当前铃声时长，最大为 10 |
| `openBehavior` | 当前为 `open-wphone-then-wechat` |

`notifications` 对象的 `timeSensitiveSetting` 应为 `enabled`；`alertStyle` 为 `persistent` 表示用户选择了持续横幅，为 `temporary` 表示临时横幅。应用只能读取这两个系统设置，不能修改。

`GET /api/status` 的 `relay` 对象包含中继连接状态、主机、端口、连接时间和已接收事件数。Armbian 上的 `GET /health` 返回 `providers: 1` 才表示 iPhone 通道已经注册。

所有调度、停止和失败信息都追加写入 App Group 的 `debug.log`，可通过 `GET /api/logs?cursor=<cursor>` 增量读取。Packet Tunnel 不再因自身读到 `not-determined` 而提前退出，而是直接调用 `schedule`；失败日志包含 NSError 的 domain、code、description、可用的 userInfo、调用前后的扩展授权状态和主 App 授权状态。带“打开”操作的 time-sensitive 本地通知与 AlarmKit 并行提交，不以 AlarmKit 返回失败为前提。

## 真机验收

1. 安装重签后的完整 IPA，确认 `PacketTunnel.appex` 一同安装。
2. 启动 WPhone，允许通知、时效通知、AlarmKit 和 VPN 权限；从“通知设置”进入系统页，打开横幅和声音，需要时把横幅风格改为“持续”。可在“来电铃声”选择一份不超过 10 秒的受支持音频。
3. 暂不连接 VPN，先点击主 App 的 **Test Alarm**。若约 1 秒后响铃，说明主 App 权限、用途说明和 AlarmKit 配置有效。
4. 点击 **Stop Alarm**，设置中继站 `192.168.2.99:18081`，再连接 VPN。
5. 在 Armbian 请求 `http://192.168.2.99:18080/health`，确认 `providers` 为 `1`。
6. 向中继站发送 `call.incoming`，确认约 1 秒内出现系统提醒并播放自定义声音；锁定状态验收系统锁屏闹铃界面，已解锁且正在使用时验收 Dynamic Island 或 time-sensitive 顶部横幅，并确认 WPhone 没有自行显示全屏页面。
7. 点击“拒绝”，确认提醒立即停止。
8. 再次触发并点击“接听”，确认提醒停止、WPhone 被唤醒并进入微信。
9. 再触发一次且不操作、不发送 `call.ended`，确认触发 50 秒后 AlarmKit 和横幅被自动清理，日志出现 `AlarmKit alarm auto-stopped after 50 seconds`。
10. 查看实时日志。成功应出现 `PacketTunnel AlarmKit schedule attempt` 和 `AlarmKit alarm scheduled`；失败应提供真实的系统 domain/code，而不是旧版的授权预检查错误。

AlarmKit 的视觉样式、顶部提醒的展开程度、声音、持续时间和系统调度由 iOS 控制。它会越过静音和专注模式，但不能保证 VPN Extension 永久存活。Apple 的公开示例从主 App 调度 AlarmKit，并没有明确支持任意 App Extension 调度。主 App 测试成功只证明 AlarmKit 基础配置正确；Packet Tunnel 路径仍必须以上述 iOS 26.x 真机结果作为最终验收依据。

VPN 在 WPhone 中只作为 Packet Tunnel Extension 的后台运行载体。AlarmKit 提醒一旦成功提交给系统，其显示和声音由系统负责，即使随后停止 VPN 也应继续有效。新的局域网请求则不同：`NWListener` 位于 Packet Tunnel 进程内，停止 VPN 后 iOS 会结束扩展进程和监听器，因此必须重新连接 VPN 才能继续接收。主 App 前台调度的 **Test Alarm** 不依赖 VPN。
