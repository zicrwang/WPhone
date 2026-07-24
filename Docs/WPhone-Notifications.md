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
       wechat 来源打开 -> WPhone 全屏微信过渡页 -> 打开 weixin://
       其他来源打开 -> 唤醒 WPhone
       30 秒内无关闭信号 -> 自动清理通知
```

`message.received` 与 `notification.show` 是普通通知；每条在成功提交后会独立倒计时 5 秒并自动清理。`call.incoming` 是带铃声的时效横幅；它继续使用独立的 30 秒清理计时。`call.ended` 必须以与来电相同的 `source` 和对应来电事件的 `id` 作为 `targetId`。`notification.dismiss` 可提前移除对应的通用通知。`POST /api/debug/stop` 与 `POST /STOP_RING` 会清理调试通知。两类倒计时都由 Packet Tunnel 进程执行，停止 VPN 后系统可能终止扩展，因此不保证已经显示的通知仍按时清理。

## 来源图标与打开目标

Packet Tunnel 内置微信、短信、电话和邮箱 PNG。通知事件按 `source` 的首分段选用图片：`wechat`、`sms`、`phone`、`email`，每个分段后可继续使用 `.`, `_` 或 `-` 区分设备实例。图片作为 iOS 通信通知的来源头像提交，最终位置由 iOS 决定，不会替换 WPhone 的 App 图标。

只有 `source` 为 `wechat` 的事件具有固定允许的 `weixin://` 打开目标。点按微信通知时，WPhone 先显示不含设置选项的全屏微信过渡页约 0.9 秒，再调用该固定地址；不会短暂显示 WPhone 的设置表单。`sms`、`phone`、`email` 和任何未映射来源点按后只进入 WPhone，当前不会启动短信、电话或邮件 App。发送端不能通过 `payload`、`extensions` 或调试参数指定任意图片或 Deep Link。

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
| `regularNotificationAutoClearSeconds` | `message.received` 和 `notification.show` 的自动清理时间，当前为 `5` |
| `incomingCallAutoClearSeconds` | 自动清理时间，当前为 `30` |

真机验收：

1. 安装重签后的完整 IPA，并确认 `PacketTunnel.appex` 一同安装。
2. 启动 WPhone，在系统通知页允许横幅、声音和时效通知；需要时将横幅风格设为持续。
3. 设置中继站 `192.168.2.99:18081` 并连接 VPN。
4. 在中继站请求 `http://192.168.2.99:18080/health`，确认 `providers` 为 `1`。
5. 打开 `http://<手机IP>:8080/` 的“弹出调试”页面，分别选择微信、短信、电话、邮箱并提交信息通知，确认显示相应来源图片；微信点按后先显示全屏过渡页再进入微信，其余点按后只进入 WPhone。
6. 不操作这条信息通知，确认提交成功 5 秒后自动清理，日志出现 `Regular notification auto-cleared after 5 seconds`。
7. 发送 `call.incoming`，确认立即出现时效通知及所选声音，没有系统闹铃界面。
8. 点击“关闭”或发送对应的 `call.ended`，确认来电通知立即移除。
9. 再次以 `source: "wechat"` 触发后点击“打开”，确认指定截图的全屏过渡页显示约 0.9 秒后进入微信，期间不出现 WPhone 设置表单；再以 `source: "phone"` 触发，确认只进入 WPhone。
10. 再触发一次来电且不操作、不发送 `call.ended`，确认提交 30 秒后通知被自动清理，日志出现 `Time-sensitive incoming-call notification auto-cleared after 30 seconds`。
