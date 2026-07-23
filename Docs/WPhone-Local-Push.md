# WPhone Local Push 部署说明

WPhone 使用 iOS Local Push Connectivity 在指定局域网中维持后台接收能力。外部软件把 WPhone Event API v1 事件提交给局域网中继，中继通过长连接交给 `AppPushProvider.appex`。来电事件再通过系统的 `NEAppPushDelegate` 唤起主 App 并报告 CallKit。

```text
发送端 --HTTP :8080--> 局域网中继 --NDJSON TCP :8081--> AppPushProvider
                                                        |
                                                        +--> 本地通知
                                                        +--> NEAppPushDelegate --> CallKit
```

## 1. 签名要求

工程已经包含以下配置：

- 主 App：`app.wephone.vpn`
- Local Push Extension：`app.wephone.vpn.AppPushProvider`
- 两个 target 都声明 `app-push-provider`
- 两个 target 都使用 App Group `group.3970029fa0cfcf6d.1`

最终安装包的 provisioning profile 也必须实际授权 `com.apple.developer.networking.networkextension = app-push-provider`。主 App 和 Extension 各自需要与 bundle ID、App Group 和 entitlement 匹配的 profile。不上架 App Store 不会取消这项系统签名检查；缺失时通常会在保存配置、启动扩展或安装阶段失败。

## 2. 启动局域网中继

中继只依赖 Python 3 标准库。在一台与 iPhone 同网段、IP 稳定且不会休眠的电脑上运行：

```bash
cd /path/to/WPhone
python3 Relay/wphone_relay.py \
  --host 0.0.0.0 \
  --http-port 8080 \
  --provider-port 8081
```

中继本身拒绝非私网来源；主机防火墙仍应只对可信局域网开放 TCP 8080 和 8081。不要把这两个端口映射到公网；当前协议没有 TLS 和身份认证。

中继状态：

```bash
curl http://<中继IP>:8080/health
```

未连接 iPhone 时 `providers` 为 `0`；扩展连入后为 `1`。

## 3. 配置 iPhone

打开 WPhone，在 **Local Push** 区域填写：

- **Wi-Fi SSID**：iPhone 当前连接网络的精确名称，区分大小写。
- **Relay host or IP**：运行中继的局域网 IP，例如 `192.168.2.20`。
- **Relay port**：默认 `8081`。

点击 **Enable**。状态含义：

| 状态 | 含义 |
| --- | --- |
| `Active` | iOS 已为当前网络激活 Local Push Extension |
| `Waiting for Wi-Fi` | 配置已保存，但当前 SSID 不匹配或系统尚未激活 |
| `Disabled` | 配置已关闭 |
| `Save failed` / `Load failed` | 查看界面错误和 `debug.log`，重点检查 entitlement/profile |

配置保存后再次请求中继 `/health`，确认 `providers: 1`。

## 4. 发送测试事件

发送端访问中继 IP，不再访问 iPhone IP：

```bash
curl --fail-with-body \
  -H 'Content-Type: application/json' \
  --data-binary '{
    "specVersion":1,
    "id":"local-push-call-1",
    "source":"test.lan",
    "type":"call.incoming",
    "occurredAt":1784800000123,
    "payload":{"caller":"Local Push 测试","callKind":"voice"},
    "delivery":{"priority":"timeSensitive","sound":"default"}
  }' \
  http://<中继IP>:8080/api/v1/events
```

扩展确认后，中继返回 HTTP `202`。完全相同的正文重试返回 HTTP `200` 和 `duplicate: true`；相同 `source + id` 使用不同正文返回 HTTP `409`。

## 5. 诊断

按以下顺序检查：

1. WPhone Local Push 状态是否为 `Active`。
2. `/health` 的 `providers` 是否为 `1`。
3. 中继日志是否出现 `iPhone provider connected`。
4. WPhone `debug.log` 是否出现 `Local Push relay connected`。
5. 来电是否出现 `Local Push manager delivered incoming call` 和 `main-app CallKit call reported`。
6. 普通通知没有出现时检查 iOS 通知授权和专注模式。

HTTP `503 provider_unavailable` 表示没有 iPhone 通道；`504 provider_timeout` 表示事件已写入通道，但扩展未在五秒内确认。两者都应由发送端保留原始 JSON 字节后退避重试。

## 6. 网络边界

事件的运行时路径完全在局域网内，不使用 APNs，也不要求中继访问互联网。iOS 仍会验证安装包签名和 provisioning profile；这与事件传输是否走公网是两件不同的事。
