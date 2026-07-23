# WPhone Event API v1

本文档是 WPhone 局域网事件接口的规范性定义。运行中的 App 通过 `GET /openapi.json` 提供机器可读版本；Tasker、Codex 和其他发送端是该协议的客户端，不应自行改变字段含义。

第三方软件的发现、队列、重试、事件映射和诊断建议见 [WPhone 外部软件接入指南](WPhone-Integration-Guide.md)。

## 1. 版本规则

- HTTP 端点：`POST /api/v1/events`
- 请求字段：`specVersion: 1`
- v1 可以增加可选字段、响应字段和新事件类型，但不会删除字段或改变现有字段含义。
- 客户端必须忽略响应中不认识的字段。
- 破坏兼容性的变更必须使用 `/api/v2/events` 和新的 `specVersion`。
- JSON 正文最大 12,288 字节，完整 HTTP 请求最大 16,384 字节。
- 不支持 `Transfer-Encoding: chunked`；客户端必须发送正确的 `Content-Length`。

## 2. 事件信封

```json
{
  "specVersion": 1,
  "id": "wechat-1784800000123",
  "source": "wechat",
  "type": "message.received",
  "occurredAt": 1784800000123,
  "payload": {
    "title": "联系人",
    "body": "消息内容",
    "sender": "联系人",
    "conversationId": "optional-conversation-id",
    "mediaKind": "text"
  },
  "delivery": {
    "priority": "timeSensitive",
    "sound": "default"
  },
  "extensions": {
    "com.example.trace": {
      "traceId": "optional-vendor-value"
    }
  }
}
```

### 2.1 顶层字段

| 字段 | 必填 | 类型 | 规则 |
| --- | --- | --- | --- |
| `specVersion` | 是 | integer | v1 固定为 `1` |
| `id` | 是 | string | 1 至 128 字符，只允许 `A-Z a-z 0-9 . _ : -` |
| `source` | 是 | string | 1 至 64 字符，格式为 `[a-z][a-z0-9._-]*` |
| `type` | 是 | string | 受支持类型或 `custom.<vendor>.<name>` |
| `occurredAt` | 是 | integer | 事件源产生事件时的 Unix 毫秒时间戳，必须大于 0 |
| `payload` | 是 | object | 类型相关字段；允许增加未知字段 |
| `delivery` | 否 | object | 本地通知投递选项；允许增加未知字段 |
| `extensions` | 否 | object | 发送端自有的、不影响 WPhone v1 行为的扩展元数据 |

未知顶层字段和未知 `payload`/`delivery` 字段会被忽略。发送端可以提前附带将来需要的数据，但不能依赖旧版 WPhone 执行未知字段。

### 2.2 delivery

| 字段 | 值 | 默认值 |
| --- | --- | --- |
| `priority` | `normal`、`timeSensitive` | `call.incoming` 为 `timeSensitive`，其他为 `normal` |
| `sound` | `default`、`none` | `default` |

`timeSensitive` 仍受 iOS 通知权限、专注模式和系统策略控制，不代表 Critical Alert。

### 2.3 extensions

`extensions` 最多包含 16 项。每个键最长 128 字符，并使用至少三级的反向域名式名称，例如 `com.example.trace`；每一级必须以小写字母开头，之后只允许小写字母、数字和连字符。值可以是任意 JSON 值。

WPhone v1 会校验扩展键并将整个对象纳入幂等指纹，但不会解释或执行扩展值。不同发送端不得使用自己不控制的命名空间。将来 WPhone 即使识别某个扩展，也不得改变未携带该扩展的现有事件语义。

## 3. 事件类型

| type | 必需 payload | 可选 payload | 当前效果 |
| --- | --- | --- | --- |
| `message.received` | `body` | `title`、`sender`、`conversationId`、`mediaKind` | 显示可进入微信的独立本地通知 |
| `call.incoming` | `caller` | `title`、`callKind` | 报告 CallKit 系统来电 |
| `call.ended` | `targetId` | 其他字段被忽略 | 结束同一 `source` 下、ID 为 `targetId` 的 CallKit 来电 |
| `notification.show` | `body` | `title` | 显示通用本地通知 |
| `notification.dismiss` | `targetId` | 其他字段被忽略 | 移除同一 `source` 下、ID 为 `targetId` 的通知 |
| `custom.<vendor>.<name>` | 无 | 任意 JSON 字段 | 只记录日志，响应 `logged_only` |

字符串限制：`title`、`sender`、`caller` 最多 120 字符，`body` 最多 1,000 字符，`conversationId` 和 `targetId` 最多 128 字符，`mediaKind` 和 `callKind` 最多 32 字符。

`call.incoming` 会把来电命令写入 App Group，由主 App 的 CallKit provider 报告系统来电；WPhone 不建立媒体通道。主 App 未运行或已完全挂起时，Extension 会在一秒后改用有声本地通知。拒绝会结束合成来电；接听会立即结束合成来电并提交一条无声、time-sensitive、带 `.foreground` 操作的本地通知。点击通知正文或“打开微信”后，WPhone 前台启动并自动尝试进入微信；失败时显示全屏按钮。`callKind: video` 会设置 CallKit 的视频标记，其他值按音频来电展示。当前只保留一个活动来电，新的 `call.incoming` 会以未接听结束前一个。`call.ended` 必须引用对应来电事件的 `id`：

```json
{
  "specVersion": 1,
  "id": "wechat-call-end-1784800060000",
  "source": "wechat",
  "type": "call.ended",
  "occurredAt": 1784800060000,
  "payload": {
    "targetId": "wechat-call-start-1784800000000"
  }
}
```

## 4. 幂等规则

幂等键为 `source + id`。发送端重试时必须原样重发同一个 JSON 正文字节序列。

WPhone 对完整 JSON 正文计算 SHA-256，并在 App Group 中保存最近 24 小时、最多 512 条记录：

1. 新的 `source + id`：保存记录、执行效果，返回 HTTP `202`。
2. 相同 `source + id` 且 JSON 正文字节完全相同：不再次执行，返回 HTTP `200` 和 `duplicate: true`。
3. 相同 `source + id` 但 JSON 正文不同：不执行，返回 HTTP `409 idempotency_conflict`。
4. 记录超过 24 小时或因 512 条容量限制被淘汰后，同一事件可能再次被当作新事件处理。

JSON 属性顺序、空白或转义方式变化都会改变请求指纹。重试队列应保存原始请求体，而不是重新序列化对象。

### 4.1 顺序与投递语义

- WPhone 不提供跨连接或跨 `source` 的全局事件顺序，也不会按 `occurredAt` 重新排序；该字段只表示来源侧时间。
- 存在依赖关系的事件必须由客户端串行发送。例如发送 `call.ended` 前，应先收到对应 `call.incoming` 的 HTTP `200` 或 `202`。
- 移除事件引用的 `targetId` 不存在时仍返回成功，因为“目标通知不存在”与“已被移除”具有相同最终状态。
- 幂等记录防止窗口期内重复执行，但不构成端到端 exactly-once 保证。HTTP 成功只表示处理已提交，不能证明 iOS 已向用户展示通知。

## 5. 成功响应

新事件：

```http
HTTP/1.1 202 Accepted
Content-Type: application/json
```

```json
{
  "ok": true,
  "apiVersion": 1,
  "status": "accepted",
  "duplicate": false,
  "effect": "notification_submitted",
  "firstAcceptedAt": 1784800000456,
  "event": {
    "id": "wechat-1784800000123",
    "source": "wechat",
    "type": "message.received"
  }
}
```

完全相同的重试返回 HTTP `200`，其中 `status` 为 `duplicate`、`duplicate` 为 `true`，`firstAcceptedAt` 保持首次接收时间。

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `ok` | boolean | 成功响应固定为 `true` |
| `apiVersion` | integer | 当前固定为 `1` |
| `status` | string | `accepted` 或 `duplicate` |
| `duplicate` | boolean | 本次请求是否命中完全相同的幂等记录 |
| `effect` | string | WPhone 对该事件采用的处理效果 |
| `firstAcceptedAt` | integer | WPhone 首次接受该幂等键时的 Unix 毫秒时间戳 |
| `event` | object | 回显已验证事件的 `id`、`source` 和 `type` |

`effect` 的稳定值：

- `notification_submitted`
- `call_notification_submitted`（已向 CallKit 报告流程提交；字段名为保持 v1 响应兼容继续使用）
- `notification_removed`
- `logged_only`

`202` 表示 WPhone 已校验、记录并提交事件。Local Push 路径的响应在 App Push Extension 确认处理后返回，但仍不表示 iOS 最终展示了 CallKit 或通知；Packet Tunnel 兼容路径的未确认来电命令会回退为通知。接听后的微信交接还依赖本地通知权限。异步状态和错误写入 `debug.log`。

## 6. 错误响应

```json
{
  "ok": false,
  "error": {
    "code": "validation_failed",
    "message": "payload.body must be a non-empty string.",
    "field": "payload.body"
  }
}
```

错误对象中的 `code` 是稳定的机器判断值，`message` 是供人阅读的英文说明，`field` 只在错误能定位到字段时出现。客户端必须允许错误对象将来增加可选字段。

| HTTP | code | 含义 | 是否适合原样重试 |
| --- | --- | --- | --- |
| `400` | `invalid_http_request`、`invalid_json`、`empty_body` | HTTP 或 JSON 无效 | 否 |
| `409` | `idempotency_conflict` | 幂等键被不同正文复用 | 否，必须生成新 ID 或恢复原正文 |
| `413` | `request_too_large`、`body_too_large` | 请求超过上限 | 否 |
| `415` | `unsupported_media_type` | 不是 `application/json` | 否 |
| `422` | `validation_failed`、`unsupported_spec_version`、`unsupported_event_type` | 字段或版本不符合规范 | 否 |
| `500` | `internal_error` | WPhone 内部错误 | 可以按退避策略重试原始正文 |

## 7. 发现与状态

- `GET /.well-known/wphone`：规范发现入口，返回能力、版本、事件端点和幂等策略。
- `GET /.well-known/wphone-debug`：为旧调试客户端保留的发现入口别名。
- `GET /openapi.json`：完整 OpenAPI 3.0.3 定义。
- `GET /api/status`：事件计数、最近事件、幂等记录数、监听器和通知/CallKit 状态。`notifications.providerLocation` 固定为 `main-app`，`providerReady` 和 `providerLifecycle` 表示主 App 最近写入的 provider 状态，`hostProcessState` 表示主 App 是否活跃或状态已经陈旧，`bridgeReachable` 表示本地桥当前能否及时交付，`pendingCommandCount` 表示尚未取走的桥接命令。`activeCallCount`、`activeCallKey` 和 `caller` 描述当前来电，`customRingtone` 表示主 App 实际启用的铃声文件。旧的 `alarmKit` 对象为保持 v1 响应兼容暂时保留，但固定返回 `supported: false`、`active: false` 和 `authorization: "removed"`；客户端不得再以它判断来电状态。
- `GET /api/logs?cursor=<cursor>`：增量文本日志。

正式客户端应调用 `/api/v1/events`。`/api/debug/*`、`START_RING` 和 `STOP_RING` 只用于人工诊断，不属于事件协议。

## 8. 访问与安全边界

- 服务仅绑定当前设备的 Wi-Fi 局域网监听器，接受 RFC 1918 IPv4、IPv6 ULA/链路本地和回环来源；它不会主动连接事件发送端。
- v1 当前不提供 TLS、访问令牌或请求签名。任何能访问该端口的同一可信私网设备都可能提交事件、读取状态和调试日志。
- 不得通过端口映射、反向代理或公网隧道暴露该端口。调试日志可能含通知正文等敏感信息。
- 来源字段 `source` 只是幂等和归类标识，不是身份认证信息，接收端不能据此信任发送者身份。
- 将来增加鉴权时，应作为可选向后兼容能力发布；若改变未鉴权请求的处理语义，则发布新的 API 主版本。

## 9. 客户端要求

- 必须设置 `Content-Type: application/json`。
- 必须使用真正的 JSON 序列化器正确转义引号、反斜杠、换行和 Unicode；不要用 Shell 字符串拼接 JSON。
- 超时或连接中断时，使用相同 ID 和完全相同的原始正文重试。
- 只有 `200` 或 `202` 且 `ok: true` 才表示 WPhone 接受了事件。
- 生成 ID 时应使用来源前缀加毫秒时间或 UUID，避免同一 `source` 内重复。
- 发送端不应根据错误消息文字做逻辑判断，只使用 HTTP 状态和 `error.code`。
