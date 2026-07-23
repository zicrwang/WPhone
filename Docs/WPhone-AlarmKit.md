# WPhone AlarmKit 说明

WPhone 从 iOS 26 起使用 AlarmKit 显示局域网来电提醒。它不创建真实通话、不使用 CallKit，也不传输音频。

## 系统与工程要求

- 设备必须运行 iOS 26.0 或更高版本；当前目标设备为 iOS 26.1。
- 工程必须使用 Xcode 26 和 iOS 26 SDK 构建。
- 主 App 的 `Info.plist` 必须包含 `NSAlarmKitUsageDescription`。本项目也在 Packet Tunnel 的 `Info.plist` 中提供同一用途说明，以便真机验证扩展调度路径。
- 用户必须至少打开主 App 一次并允许 AlarmKit 权限。
- AlarmKit 不需要额外 entitlement。工程原有的 Network Extension 和 App Groups capability 保持不变。
- 主 App 与 Packet Tunnel Extension 必须使用同一 App Group，供活动闹钟状态和“打开”动作交接使用。

## 行为流程

```text
Tasker/局域网软件
  -> POST /api/v1/events (call.incoming)
  -> Packet Tunnel Extension 调度 AlarmKit
  -> 约 2 秒后显示系统提醒
       关闭 -> 停止并取消提醒
       打开 -> 停止提醒 -> 唤醒 WPhone -> 打开 weixin://
```

WPhone 当前只保留一条活动 AlarmKit 来电。新来电会停止上一条；`call.ended` 只有在 `source + targetId` 与活动来电匹配时才停止它。`POST /api/debug/stop`、`POST /STOP_RING` 和停止 VPN 也会停止活动提醒。

“打开”必须经过主 App，因为 Packet Tunnel Extension 受 App Extension API 限制，不能调用 `UIApplication`。AlarmKit 的 `LiveActivityIntent` 负责在用户点击后唤醒 WPhone，WPhone 再打开微信。该过程需要一次明确的用户点击，不能无人值守启动微信。

## 接口

正式来电事件继续使用稳定的 v1 协议：

```http
POST /api/v1/events HTTP/1.1
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
| `triggerDelaySeconds` | 当前固定为 2 |
| `openBehavior` | 当前为 `open-wphone-then-wechat` |

所有调度、停止和失败信息都追加写入 App Group 的 `debug.log`，可通过 `GET /api/logs?cursor=<cursor>` 增量读取。Packet Tunnel 不再因自身读到 `not-determined` 而提前退出，而是直接调用 `schedule`；失败日志包含 NSError 的 domain、code、description、可用的 userInfo、调用前后的扩展授权状态和主 App 授权状态。AlarmKit 调度失败时，WPhone 会尝试显示带“打开”操作的 time-sensitive 本地通知。

## 真机验收

1. 安装重签后的完整 IPA，确认 `PacketTunnel.appex` 一同安装。
2. 启动 WPhone，允许通知、AlarmKit 和 VPN 权限。
3. 暂不连接 VPN，先点击主 App 的 **Test Alarm**。若约 3 秒后响铃，说明主 App 权限、用途说明和 AlarmKit 配置有效。
4. 点击 **Stop Alarm**，再连接 VPN 并访问 `http://<iPhone-IP>:8080/`。
5. 确认网页 AlarmKit 状态显示 `App authorized`；扩展可能仍显示 `not-determined`。
6. 在调试后台点击“AlarmKit 来电”，确认约 2 秒后出现系统提醒并响铃。
7. 点击“关闭”，确认提醒立即停止。
8. 再次触发并点击“打开”，确认提醒停止、WPhone 被唤醒并进入微信。
9. 查看实时日志。成功应出现 `PacketTunnel AlarmKit schedule attempt` 和 `AlarmKit alarm scheduled`；失败应提供真实的系统 domain/code，而不是旧版的授权预检查错误。

AlarmKit 的视觉样式、声音、持续时间和系统调度由 iOS 控制。该能力不是 Critical Alert，也不能保证 VPN Extension 永久存活。Apple 的公开示例从主 App 调度 AlarmKit，并没有明确支持任意 App Extension 调度。主 App 测试成功只证明 AlarmKit 基础配置正确；Packet Tunnel 路径仍必须以上述 iOS 26.x 真机结果作为最终验收依据。
