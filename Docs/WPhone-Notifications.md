# WPhone 来电通知说明

WPhone 使用 iOS `.timeSensitive` 本地通知显示局域网来电。它不创建系统闹铃、锁屏闹铃界面、Dynamic Island 活动或 Live Activity，也不创建真实通话或传输音频。

## 系统与工程要求

- 设备必须允许本应用的通知、声音和时效通知。
- 主 App 与 Packet Tunnel Extension 都保留 `com.apple.developer.usernotifications.time-sensitive` capability。
- Network Extension 和 App Groups capability 保持不变；不需要 APNs、远程推送或 Critical Alert entitlement。

## 行为流程

```text
Tasker/局域网软件
  -> POST 中继站 192.168.2.99:18080/api/v1/events
  -> 中继站通过 iPhone 主动建立的 TCP 长连接转发
  -> Packet Tunnel Extension 接收 call.incoming
       -> 立即提交 timeSensitive 本地通知
       关闭 / call.ended -> 移除通知
       打开 -> 唤醒 WPhone -> 打开 weixin://
       30 秒内无关闭信号 -> 自动清理通知
```

`call.ended` 必须以与来电相同的 `source` 和对应来电事件的 `id` 作为 `targetId`。`POST /api/debug/stop` 与 `POST /STOP_RING` 会清理调试通知。30 秒清理由 Packet Tunnel 进程执行，停止 VPN 后系统可能终止扩展，因此不保证已经显示的通知仍按时清理。

## 自定义声音

来电通知默认使用 [WPhoneIncomingCall.wav](../Resources/WPhoneIncomingCall.wav)。主 App 可导入一项 WAV、CAF 或 AIFF 来电声音，最长 29 秒、最大 20 MB，且必须使用 Linear PCM、IMA4、uLaw 或 aLaw 编码。选择器以复制模式导入文件并保存到 App Group 的 `Library/Sounds`；资源缺失时会回退到内置声音或系统默认声音。

## 状态与验收

`GET /api/status` 的 `notifications` 对象包含：

| 字段 | 含义 |
| --- | --- |
| `timeSensitiveSetting` | 系统时效通知设置 |
| `incomingCallInterruptionLevel` | 固定为 `timeSensitive` |
| `incomingCallSound` | 当前来电声音文件名 |
| `incomingCallSoundAvailable` | 当前进程或 App Group 是否能找到来电声音 |
| `incomingCallSoundCustom` | 当前是否使用导入声音 |
| `incomingCallSoundDurationSeconds` | 当前来电声音时长 |
| `incomingCallSoundMaximumDurationSeconds` | 文件上限，当前为 `29` |
| `incomingCallAutoClearSeconds` | 自动清理时间，当前为 `30` |

真机验收：

1. 安装重签后的完整 IPA，并确认 `PacketTunnel.appex` 一同安装。
2. 启动 WPhone，在系统通知页允许横幅、声音和时效通知；需要时将横幅风格设为持续。
3. 设置中继站 `192.168.2.99:18081` 并连接 VPN。
4. 在中继站请求 `http://192.168.2.99:18080/health`，确认 `providers` 为 `1`。
5. 发送 `call.incoming`，确认立即出现时效通知及所选声音，没有系统闹铃界面。
6. 点击“关闭”或发送对应的 `call.ended`，确认通知立即移除。
7. 再次触发后点击“打开”，确认 WPhone 被唤醒并进入微信。
8. 再触发一次且不操作、不发送 `call.ended`，确认提交 30 秒后通知被自动清理，日志出现 `Time-sensitive incoming-call notification auto-cleared after 30 seconds`。
