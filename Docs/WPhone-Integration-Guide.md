# WPhone 外部软件接入指南

本文档面向需要向 WPhone 发送局域网通知事件的软件，包括 Tasker、通知监听器、桌面脚本、家庭自动化服务和其他常驻程序。

规范性定义以 [WPhone Event API v1](WPhone-API-v1.md) 和设备运行时返回的 `GET /openapi.json` 为准。本文档提供适配方法和工程建议，不改变协议字段含义。

## 1. 接入范围

生产发送端连接 Armbian 中继站的 HTTP/1.1 JSON API：

```text
http://192.168.2.99:18080
```

正式发送端只使用：

```http
POST /api/v1/events HTTP/1.1
Content-Type: application/json
Content-Length: <bytes>
```

下列接口用于发现和诊断：

| 方法和路径 | 用途 |
| --- | --- |
| `GET /.well-known/wphone` | 获取 API 版本、能力、事件端点和幂等策略 |
| `GET /openapi.json` | 获取 OpenAPI 3.0.3 定义 |
| `GET /health` | 快速检查服务是否在线 |
| `GET /api/status` | 获取隧道、监听器、通知权限和最近事件状态 |
| `GET /api/logs?cursor=<cursor>` | 按游标增量读取 `debug.log` |

`/api/debug/*`、`START_RING` 和 `STOP_RING` 只用于人工调试或旧客户端兼容，不应作为新软件的正式接入方式。

## 2. 中继连接

发送端将中继站 `192.168.2.99:18080` 作为稳定配置。iPhone Packet Tunnel 主动连接中继 TCP `18081`、注册设备 ID 并保持心跳；Wi-Fi 重连或 iPhone DHCP 地址变化后会自动重新拨号，不需要发送端扫描手机地址。

发送前可调用 `GET /health`。`providers: 1` 表示已有 iPhone VPN 通道；为 `0` 时事件请求返回 `503 provider_unavailable`。中继响应中的未知字段必须忽略。

## 3. v1 请求模型

每次请求发送一个事件：

```json
{
  "specVersion": 1,
  "id": "wechat-550e8400-e29b-41d4-a716-446655440000",
  "source": "wechat.mi8",
  "type": "message.received",
  "occurredAt": 1784800000123,
  "payload": {
    "title": "联系人",
    "body": "消息内容",
    "sender": "联系人",
    "conversationId": "conversation-42",
    "mediaKind": "text"
  },
  "delivery": {
    "priority": "normal",
    "sound": "default"
  }
}
```

### 3.1 顶层字段

| 字段 | 必填 | 适配要求 |
| --- | --- | --- |
| `specVersion` | 是 | 固定发送整数 `1`，不要发送字符串 `"1"` |
| `id` | 是 | 同一事件的全部重试必须复用同一 ID；建议使用 UUID 或来源侧稳定事件 ID |
| `source` | 是 | 为适配器实例选择稳定名称，例如 `wechat.mi8`、`homeassistant.home` |
| `type` | 是 | 优先使用 WPhone 内置事件类型 |
| `occurredAt` | 是 | 来源侧 Unix 毫秒时间戳，不是秒时间戳 |
| `payload` | 是 | 始终发送 JSON object，即使自定义事件没有字段也发送 `{}` |
| `delivery` | 否 | 控制通知优先级和声音；不需要时可以省略 |
| `extensions` | 否 | 保存发送端自有元数据，不得用来改变内置事件语义 |

JSON 正文不得超过 12,288 字节，包含请求行和请求头的完整 HTTP 请求不得超过 16,384 字节。WPhone 不支持 `Transfer-Encoding: chunked`；发送端必须提供正确的 `Content-Length`。发送端必须使用 JSON 库进行序列化，不能用字符串拼接用户产生的标题或正文。

### 3.2 source 和 id

`source` 是幂等命名空间，不是身份认证。格式为 `[a-z][a-z0-9._-]*`，最多 64 字符。

同一种上游软件在不同设备上运行时，应使用不同且稳定的来源名，例如：

```text
wechat.mi8
wechat.tablet
homeassistant.home
```

`id` 最多 128 字符，只允许英文字母、数字、点、下划线、冒号和连字符。不要仅使用秒级时间，因为同一秒可能产生多个事件。推荐顺序：

1. 使用上游系统提供的稳定唯一事件 ID。
2. 没有上游 ID 时，在事件首次进入发送队列时生成 UUID。
3. 不要在每次 HTTP 重试时重新生成 ID。

### 3.3 delivery

| 字段 | 可选值 | 建议 |
| --- | --- | --- |
| `priority` | `normal`、`timeSensitive` | 默认使用 `normal`；来电兜底横幅固定为普通 `active` 级别 |
| `sound` | `default`、`none` | 普通事件中 `default` 使用系统声；来电横幅中 `default` 使用 App 当前选择的最长 29 秒铃声；`none` 关闭本地通知声音 |

`timeSensitive` 不是 Critical Alert。它仍受通知授权、专注模式和 iOS 系统策略控制。该值只影响 `message.received` 和 `notification.show`；`call.incoming` 为避免系统“时效通知”标签而固定使用普通 `active` 横幅，并由 AlarmKit 承担系统级来电提醒。

### 3.4 extensions

适配器需要携带 WPhone 不解释的元数据时，使用 `extensions`：

```json
{
  "extensions": {
    "com.example.trace": {
      "traceId": "01J0EXAMPLE",
      "adapterVersion": "2.1.0"
    }
  }
}
```

键必须使用至少三级反向域名式名称，例如 `com.example.trace`，最多 16 项。WPhone v1 会将扩展内容纳入幂等指纹，但不会执行它。不要把标题、正文或结束事件目标藏在 `extensions` 中。

## 4. 事件映射

| 上游语义 | WPhone type | 必需 payload | 适配建议 |
| --- | --- | --- | --- |
| 收到文本、图片或其他消息 | `message.received` | `body` | 将联系人放入 `sender`，会话 ID 放入 `conversationId` |
| 检测到来电开始 | `call.incoming` | `caller` | 保存本事件的 `id`，结束时作为 `targetId` |
| 检测到来电结束或取消 | `call.ended` | `targetId` | `source` 必须与对应 `call.incoming` 相同 |
| 显示不属于消息/来电的通用提醒 | `notification.show` | `body` | 监控告警、自动化提醒等使用该类型 |
| 移除一条通用提醒 | `notification.dismiss` | `targetId` | 引用对应 `notification.show` 的 `id` |
| 暂无内置语义的厂商事件 | `custom.<vendor>.<name>` | 无 | 当前只写日志，不能期待弹出通知 |

`conversationId`、`mediaKind` 和 `callKind` 当前只是保留的结构化元数据。AlarmKit 不区分音频和视频来电，也不会建立媒体通道。每个 `call.incoming` 会同时调度 AlarmKit 和普通 `active` 本地通知；这是亮屏时 AlarmKit 没有正确展开时的顶部横幅兜底，不需要 APNs，也不会显示系统“时效通知”标签。发送端没有发出 `call.ended` 时，WPhone 会在提醒触发 50 秒后自动停止并清理横幅。

### 4.1 消息事件

```json
{
  "specVersion": 1,
  "id": "wechat-msg-550e8400-e29b-41d4-a716-446655440000",
  "source": "wechat.mi8",
  "type": "message.received",
  "occurredAt": 1784800000123,
  "payload": {
    "title": "微信消息",
    "body": "今晚八点见",
    "sender": "联系人",
    "conversationId": "chat-42",
    "mediaKind": "text"
  },
  "delivery": {
    "priority": "normal",
    "sound": "default"
  }
}
```

### 4.2 来电开始与结束

开始事件：

```json
{
  "specVersion": 1,
  "id": "wechat-call-550e8400-e29b-41d4-a716-446655440000",
  "source": "wechat.mi8",
  "type": "call.incoming",
  "occurredAt": 1784800000123,
  "payload": {
    "title": "微信来电",
    "caller": "联系人",
    "callKind": "voice"
  },
  "delivery": {
    "priority": "normal",
    "sound": "default"
  }
}
```

结束事件必须引用开始事件的 `id`：

```json
{
  "specVersion": 1,
  "id": "wechat-call-end-c57f65e1-5206-4c23-a2ea-78105a2fba54",
  "source": "wechat.mi8",
  "type": "call.ended",
  "occurredAt": 1784800060000,
  "payload": {
    "targetId": "wechat-call-550e8400-e29b-41d4-a716-446655440000"
  }
}
```

普通局域网软件通常只能识别“疑似来电通知”，不一定能可靠获得通话生命周期。无法确认结束事件时，不要伪造 `call.ended`；WPhone 会在触发 50 秒后自动结束未关闭的提醒。WPhone 会为 `call.incoming` 调度 iOS 26 AlarmKit 系统提醒：“拒绝”停止提醒，“接听”启动 WPhone 后进入微信。它不是实际 VoIP 通话，也不传输音频；新的来电提醒会替换上一条活动提醒。

### 4.3 通用通知与移除

```json
{
  "specVersion": 1,
  "id": "monitor-disk-550e8400-e29b-41d4-a716-446655440000",
  "source": "homeassistant.home",
  "type": "notification.show",
  "occurredAt": 1784800000123,
  "payload": {
    "title": "服务器告警",
    "body": "磁盘空间低于 10%"
  },
  "delivery": {
    "priority": "timeSensitive",
    "sound": "default"
  }
}
```

清除时发送新的 `notification.dismiss` 事件，并让 `targetId` 指向上述显示事件的 `id`。

## 5. 幂等与发送队列

WPhone 使用 `source + id` 作为幂等键，并比较完整 JSON 正文的 SHA-256。记录写入 App Group，在 Packet Tunnel Extension 重启后仍然保留；保留窗口为 24 小时，容量最多 512 条。

发送端必须遵守“序列化一次，原样重试”：

1. 事件首次产生时确定 `id` 和 `occurredAt`。
2. 通过 JSON 序列化器生成 UTF-8 正文。
3. 将原始正文字节保存到待发送队列。
4. 每次重试发送完全相同的字节，不重新生成时间、不调整空白、不改变属性顺序。
5. 收到 HTTP `200` 或 `202` 且 `ok: true` 后才能删除队列记录。

推荐为每个 `source` 使用串行队列。有关联的事件必须等待前一个事件成功后再发送，尤其是 `call.incoming` 与 `call.ended`。

### 5.1 建议的重试策略

| 结果 | 行为 |
| --- | --- |
| HTTP `200` 或 `202` 且 `ok: true` | 成功，删除待发送记录 |
| 连接超时、断开、无响应 | 结果未知，按退避策略原样重试 |
| HTTP `500` | 原样重试 |
| HTTP `400`、`413`、`415`、`422` | 客户端数据错误，停止自动重试并记录错误 |
| HTTP `409 idempotency_conflict` | 适配器缺陷或队列损坏；恢复首次正文，不能为同一业务事件悄悄更换内容 |
| 其他 HTTP 状态 | 记录完整响应，等待人工检查或客户端升级 |

建议连接/响应超时为 5 秒，重试间隔可使用 1、2、4、8、15 秒并将上限保持在 15 秒。设备长时间离线时保留队列但降低重试频率，避免持续唤醒网络。超过 WPhone 的 24 小时去重窗口后，旧事件可能再次执行；业务方应决定过期消息是丢弃还是允许重新提醒。

WPhone 不按 `occurredAt` 排序，也不保证跨连接的全局顺序。HTTP 成功表示事件已提交到本地处理流程，不表示用户一定看到了通知。

## 6. 响应处理

新事件通常返回 HTTP `202`：

```json
{
  "ok": true,
  "apiVersion": 1,
  "status": "accepted",
  "duplicate": false,
  "effect": "notification_submitted",
  "firstAcceptedAt": 1784800000456,
  "event": {
    "id": "wechat-msg-550e8400-e29b-41d4-a716-446655440000",
    "source": "wechat.mi8",
    "type": "message.received"
  }
}
```

相同正文重试返回 HTTP `200`、`status: "duplicate"` 和 `duplicate: true`，仍然属于成功。客户端必须同时检查 HTTP 状态和 JSON `ok`，并忽略不认识的新增响应字段。

错误响应：

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

程序逻辑只依赖 HTTP 状态和 `error.code`，不要匹配可能调整的 `message` 文本。

## 7. 参考发送方式

### 7.1 curl

先用 JSON 序列化器或编辑器生成 `event.json`，重试时复用同一文件：

```bash
curl --fail-with-body \
  --connect-timeout 5 \
  --max-time 5 \
  -H 'Content-Type: application/json' \
  --data-binary '@event.json' \
  'http://192.168.2.99:18080/api/v1/events'
```

不要在重试命令中重新计算 `id` 或 `occurredAt`。

### 7.2 Python 标准库

下面的示例只演示一次序列化和有限重试；正式软件还应将 `body` 持久化到队列：

```python
import json
import time
import urllib.error
import urllib.request
import uuid

base_url = "http://192.168.2.99:18080"
event = {
    "specVersion": 1,
    "id": f"desktop-{uuid.uuid4()}",
    "source": "desktop.home",
    "type": "notification.show",
    "occurredAt": int(time.time() * 1000),
    "payload": {
        "title": "桌面提醒",
        "body": "任务已经完成",
    },
}

# body 只生成一次；所有重试复用完全相同的 bytes。
body = json.dumps(
    event,
    ensure_ascii=False,
    separators=(",", ":"),
).encode("utf-8")

for delay in (0, 1, 2, 4, 8):
    if delay:
        time.sleep(delay)
    request = urllib.request.Request(
        f"{base_url}/api/v1/events",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            result = json.load(response)
            if response.status in (200, 202) and result.get("ok") is True:
                break
            raise RuntimeError(f"unexpected response: {response.status} {result}")
    except urllib.error.HTTPError as error:
        response_body = error.read().decode("utf-8", errors="replace")
        if error.code < 500:
            raise RuntimeError(f"permanent WPhone error: {error.code} {response_body}")
    except (urllib.error.URLError, TimeoutError):
        pass
else:
    raise RuntimeError("WPhone remained unavailable after retries")
```

## 8. 各类软件的适配建议

### 8.1 Tasker 或手机自动化工具

- 将监听通知、识别事件和发送 HTTP 分成三个独立步骤，便于单独查看错误。
- 在事件首次出现时生成 `%event_id`、`%occurred_at` 和完整 `%event_body`，重试任务只复用 `%event_body`。
- 使用 Tasker 的 JSON 结构化能力或 JavaScriptlet 调用 `JSON.stringify`，不要直接拼接通知正文。
- 将微信普通通知映射为 `message.received`；只有能可靠区分开始和结束时才映射来电事件。
- 保存来电开始事件 ID，结束事件的 `payload.targetId` 必须引用它。
- HTTP `200` 和 `202` 都按成功处理；不要把重复响应当成错误再次生成新事件。
- 将中继站地址、HTTP 端口和 `source` 做成用户可修改配置，不要写死在事件规则中。

### 8.2 桌面脚本或常驻服务

- 使用磁盘队列保存原始 UTF-8 请求体和创建时间，进程重启后继续重试。
- 为每个 WPhone 设备维护独立目标配置和队列，避免不同手机共享确认状态。
- 使用单连接单请求即可；WPhone 会在每个响应后关闭连接，不依赖 HTTP keep-alive。
- 限制并发请求。通常每个目标一个正在发送的请求即可，尤其是存在事件依赖时。
- 周期性读取 `/health` 只用于状态展示，不要用高频健康检查代替发送失败判断。

### 8.3 Codex 或其他自动化代理

首次连接时先检查中继状态：

```text
GET http://192.168.2.99:18080/health
```

代理按本文档构造 `POST /api/v1/events`，并把中继站地址视为环境配置。事件发送不再使用 iPhone IP；需要读取 iPhone 调试状态时，才通过 App 内日志或 TCP 8080 兼容入口诊断。

代理执行重试时必须保留第一次生成的 JSON 字节。不要在每轮推理中重新组织 JSON 或更换事件 ID。

### 8.4 通知桥接器

- 在采集层先形成平台无关的内部事件，再由 WPhone adapter 映射字段，避免把 WPhone 字段侵入通知解析代码。
- 保留上游原始事件 ID；没有时由 adapter 创建并持久化 WPhone ID。
- 对标题和正文做长度控制。WPhone 按 Swift 字符计数验证；跨语言实现可保守限制标题为 100 个用户可见字符、正文为 900 个用户可见字符。
- 不要把同一通知的内容更新复用同一 WPhone ID。v1 没有更新语义；内容变化应生成新事件，旧通知需要时再显式 dismiss。
- 对敏感正文提供发送前过滤选项，因为 WPhone 的局域网 API 当前没有 TLS 或鉴权。

## 9. 诊断流程

出现“发送成功但手机无提示”时，按顺序检查：

1. 主 App 中 VPN 是否已连接。
2. 中继站 `GET /health` 是否返回 `ok: true` 且 `providers` 为 `1`。
3. WPhone 日志是否出现 `VPN relay registered`；直连调试页时确认 `relay.state` 为 `connected`。
4. 普通消息检查 `notifications.authorization` 是否为 `authorized` 或 `provisional`；来电先检查 `alarmKit.hostAuthorization` 是否为 `authorized`。`alarmKit.extensionAuthorization` 可能与主 App 不同，不能单独用它判断最终调度结果。
5. `events.acceptedCount`、`lastEventId` 和 `lastEventEffect` 是否更新。
6. 来电后检查 `alarmKit.active`、`activeAlarmId` 和 `activeCallKey`。
7. 使用 `/api/logs?cursor=0` 查看 `AlarmKit alarm scheduled`，或包含 NSError domain/code 的 AlarmKit 提交错误。
8. 检查 iOS 闹钟权限、通知设置和声音设置。

HTTP `202` 只表示 WPhone 接受并提交了本地处理请求。iOS 最终是否展示 AlarmKit/通知、播放声音或采用请求的中断级别仍由系统决定。

## 10. 安全边界

- 当前 v1 没有 TLS、访问令牌或请求签名，只能用于可信 Wi-Fi 私网。
- 不要使用路由器端口映射、反向代理或公网隧道暴露 `18080`、`18081` 或 iPhone 调试端口 `8080`。
- `source` 不能证明发送者身份。
- `/api/logs` 可能暴露运行信息，不应向不可信设备开放。
- 多租户、访客 Wi-Fi 或不可信局域网环境应停止使用，等待未来带鉴权的协议版本。

## 11. 最低兼容清单

发布一个 WPhone adapter 前，至少验证：

- 能读取 `/.well-known/wphone` 并确认 v1 事件端点。
- 使用 UTF-8 JSON 和正确 `Content-Type`、`Content-Length`。
- 秒时间戳会被转换为 Unix 毫秒。
- 标题、正文、来源和 ID 均满足长度与格式限制。
- HTTP `202` 新事件和 HTTP `200` 重复事件都被确认出队。
- 网络超时后重发的原始正文完全一致，手机不会重复弹出。
- 相同 `source + id` 的不同正文得到 HTTP `409` 并停止重试。
- `call.ended` 和 `notification.dismiss` 使用正确的 `targetId` 与相同 `source`。
- 未知响应字段会被忽略，错误逻辑只依赖状态码和 `error.code`。
- iPhone 更换 IP、VPN 停止、通知权限关闭和 WPhone 重启时有明确诊断信息；IP 变化后中继通道能自动恢复。
- 来电提醒设备运行 iOS 26.0 或更高版本，并已在主 App 中允许 AlarmKit 权限。
- 不依赖真实媒体通话、无人值守打开其他 App、Critical Alert 或永久后台运行等 v1 未承诺能力。

完成以上项目后，其他软件即可在不依赖 WPhone 内部实现的情况下稳定接入 `/api/v1/events`。
