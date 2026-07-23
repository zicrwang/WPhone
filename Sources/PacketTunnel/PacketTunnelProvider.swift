import Foundation
import Network
import NetworkExtension
import UserNotifications

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private static let ringNotificationIdentifier = "app.wephone.vpn.ring"
    private static let messageNotificationIdentifier = "app.wephone.vpn.debug.message"
    private static let callNotificationIdentifier = "app.wephone.vpn.debug.call"
    private static let maximumRequestBytes = 16 * 1024
    private static let maximumConnections = 8
    private static let requestTimeoutSeconds: TimeInterval = 10
    private static let bonjourServiceType = "_wphone-debug._tcp"

    private struct RuntimeState {
        var tunnelStartedAt: Date?
        var listenerState = "idle"
        var notificationAuthorization = "unknown"
        var totalRequests = 0
        var lastRequestPath: String?
        var lastAction: String?
        var lastActionAt: Date?
        var lastError: String?
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let queryItems: [URLQueryItem]

        func queryValue(named name: String, maximumCharacters: Int) -> String? {
            guard let value = queryItems.first(where: { $0.name == name })?.value else {
                return nil
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return String(trimmed.prefix(maximumCharacters))
        }
    }

    private let log = SharedLogger.shared
    private let listenerQueue = DispatchQueue(label: "app.wephone.vpn.listener")
    private let connectionLock = NSLock()
    private let stateLock = NSLock()
    private let dateFormatter = ISO8601DateFormatter()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var requestBuffers: [ObjectIdentifier: Data] = [:]
    private var connectionTimeouts: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var listenerPort: Network.NWEndpoint.Port = 8080
    private var listenerStartCompletion: ((Error?) -> Void)?
    private var listenerReachedReady = false
    private var runtimeState = RuntimeState()

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        log.info("Starting keepalive-only packet tunnel")
        loadProviderConfiguration()
        mutateState {
            $0.tunnelStartedAt = Date()
            $0.listenerState = "starting"
            $0.lastError = nil
        }
        refreshNotificationAuthorization()

        // This extension deliberately does not read packetFlow. With no included
        // routes and an excluded default route, normal traffic stays on Wi-Fi or
        // cellular instead of being intercepted by this keepalive-only tunnel.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "192.0.2.1")
        let ipv4 = NEIPv4Settings(
            addresses: ["192.0.2.2"],
            subnetMasks: ["255.255.255.255"]
        )
        ipv4.includedRoutes = []
        ipv4.excludedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else {
                completionHandler(NSError(domain: "WPhone", code: 1))
                return
            }
            if let error {
                self.recordError("Network settings failed: \(error.localizedDescription)")
                completionHandler(error)
                return
            }

            do {
                try self.startListener { [weak self] error in
                    if let error {
                        self?.recordError("LAN listener failed: \(error.localizedDescription)")
                    } else {
                        self?.log.info("LAN debug server started on Wi-Fi port \(self?.listenerPort.rawValue ?? 0)")
                    }
                    completionHandler(error)
                }
            } catch {
                self.recordError("LAN listener failed: \(error.localizedDescription)")
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        log.info("Stopping packet tunnel, reason=\(reason.rawValue)")
        listener?.cancel()
        listener = nil
        listenerStartCompletion = nil
        listenerReachedReady = false
        mutateState {
            $0.listenerState = "stopped"
            $0.lastAction = "STOP_TUNNEL"
            $0.lastActionAt = Date()
        }

        connectionLock.lock()
        let activeConnections = Array(connections.values)
        let activeTimeouts = Array(connectionTimeouts.values)
        connections.removeAll(keepingCapacity: false)
        requestBuffers.removeAll(keepingCapacity: false)
        connectionTimeouts.removeAll(keepingCapacity: false)
        connectionLock.unlock()

        activeTimeouts.forEach { $0.cancel() }
        activeConnections.forEach { $0.cancel() }
        completionHandler()
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)? = nil
    ) {
        let command = String(data: messageData, encoding: .utf8) ?? ""
        handleLegacyCommand(command)
        completionHandler?(Data("OK\n".utf8))
    }

    private func loadProviderConfiguration() {
        guard let configuration = protocolConfiguration as? NETunnelProviderProtocol,
              let values = configuration.providerConfiguration else { return }

        if let port = values["listenerPort"] as? NSNumber,
           let parsed = Network.NWEndpoint.Port(rawValue: port.uint16Value) {
            listenerPort = parsed
        }
    }

    private func startListener(completion: @escaping (Error?) -> Void) throws {
        var parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi

        let newListener = try NWListener(using: parameters, on: listenerPort)
        newListener.service = NWListener.Service(
            name: "WPhone Debug",
            type: Self.bonjourServiceType
        )
        newListener.serviceRegistrationUpdateHandler = { [weak self] change in
            self?.log.debug("Bonjour registration: \(String(describing: change))")
        }
        newListener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listenerStartCompletion = completion
        listenerReachedReady = false
        listener = newListener
        newListener.start(queue: listenerQueue)
    }

    private func handleListenerState(_ state: NWListener.State) {
        let stateText = String(describing: state)
        log.debug("NWListener state: \(stateText)")
        mutateState { $0.listenerState = stateText }

        switch state {
        case .ready:
            listenerReachedReady = true
            mutateState { $0.listenerState = "ready" }
            finishListenerStart(with: nil)
        case .failed(let error):
            let failedAfterStart = listenerReachedReady
            listener = nil
            recordError("LAN listener stopped: \(error.localizedDescription)")
            finishListenerStart(with: error)
            if failedAfterStart {
                cancelTunnelWithError(error)
            }
        case .cancelled:
            mutateState { $0.listenerState = "cancelled" }
            if !listenerReachedReady {
                finishListenerStart(with: NSError(domain: "WPhone", code: 2))
            }
        default:
            break
        }
    }

    private func finishListenerStart(with error: Error?) {
        guard let completion = listenerStartCompletion else { return }
        listenerStartCompletion = nil
        completion(error)
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard isPrivateLANClient(connection.endpoint) else {
            log.error("Rejected non-private LAN client: \(String(describing: connection.endpoint))")
            connection.cancel()
            return
        }

        connectionLock.lock()
        guard connections.count < Self.maximumConnections else {
            connectionLock.unlock()
            log.error("Rejected LAN client: connection limit reached")
            connection.cancel()
            return
        }
        connections[id] = connection
        requestBuffers[id] = Data()
        let timeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.log.error("LAN request timed out")
            self.remove(connection)
            connection.cancel()
        }
        connectionTimeouts[id] = timeout
        connectionLock.unlock()

        listenerQueue.asyncAfter(
            deadline: .now() + Self.requestTimeoutSeconds,
            execute: timeout
        )

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .failed(let error) = state {
                self.log.error("Connection failed: \(error.localizedDescription)")
                self.remove(connection)
            } else if case .cancelled = state {
                self.remove(connection)
            }
        }
        connection.start(queue: listenerQueue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 4096
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            if let error {
                self.log.error("Receive failed: \(error.localizedDescription)")
                self.remove(connection)
                return
            }
            if let data, !data.isEmpty {
                let id = ObjectIdentifier(connection)
                self.connectionLock.lock()
                self.requestBuffers[id, default: Data()].append(data)
                let size = self.requestBuffers[id]?.count ?? 0
                let request = self.requestBuffers[id]
                self.connectionLock.unlock()

                guard size <= Self.maximumRequestBytes else {
                    self.sendText(status: 413, body: "request too large\n", on: connection)
                    return
                }

                if let request, self.isCompleteRequest(request) || isComplete {
                    self.process(request, on: connection)
                    return
                }
            }

            if isComplete {
                self.remove(connection)
            } else {
                self.receive(on: connection)
            }
        }
    }

    private func isCompleteRequest(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        if text.contains("\r\n\r\n") { return true }
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return command == "START_RING" || command == "STOP_RING"
    }

    private func process(_ data: Data, on connection: NWConnection) {
        guard let text = String(data: data, encoding: .utf8) else {
            sendJSON(status: 400, object: ["ok": false, "error": "invalid_utf8"], on: connection)
            return
        }

        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if normalized == "START_RING" || normalized == "STOP_RING" {
            handleLegacyCommand(normalized)
            sendText(status: 200, body: normalized == "START_RING" ? "STARTED\n" : "STOPPED\n", on: connection)
            return
        }

        guard let request = parseHTTPRequest(text) else {
            sendJSON(status: 400, object: ["ok": false, "error": "invalid_http_request"], on: connection)
            return
        }
        recordRequest(request)

        switch (request.method, request.path) {
        case ("GET", "/"):
            send(
                status: 200,
                contentType: "text/html; charset=utf-8",
                body: Data(Self.dashboardHTML.utf8),
                on: connection
            )
        case ("GET", "/health"):
            sendJSON(
                status: 200,
                object: ["ok": true, "service": "wphone-debug", "version": 1],
                on: connection
            )
        case ("GET", "/api"), ("GET", "/.well-known/wphone-debug"):
            sendJSON(status: 200, object: apiDiscoveryPayload(), on: connection)
        case ("GET", "/openapi.json"):
            sendJSON(status: 200, object: openAPIPayload(), on: connection)
        case ("GET", "/api/status"):
            sendJSON(status: 200, object: statusPayload(), on: connection)
        case ("GET", "/api/logs"):
            sendLogSnapshot(for: request, on: connection)
        case ("POST", "/api/debug/message"):
            let title = request.queryValue(named: "title", maximumCharacters: 80) ?? "信息弹出调试"
            let body = request.queryValue(named: "body", maximumCharacters: 240) ?? "WPhone 局域网调试消息"
            submitNotification(
                identifier: Self.messageNotificationIdentifier,
                title: title,
                body: body,
                action: "DEBUG_MESSAGE"
            )
            sendAccepted(action: "DEBUG_MESSAGE", on: connection)
        case ("POST", "/api/debug/call"):
            let caller = request.queryValue(named: "caller", maximumCharacters: 80) ?? "WPhone 调试来电"
            submitNotification(
                identifier: Self.callNotificationIdentifier,
                title: "电话弹出调试",
                body: caller,
                action: "DEBUG_CALL_NOTIFICATION"
            )
            sendAccepted(
                action: "DEBUG_CALL_NOTIFICATION",
                extra: ["mode": "local_notification", "callKit": false],
                on: connection
            )
        case ("POST", "/api/debug/stop"):
            stopAllDebugNotifications()
            sendJSON(status: 200, object: ["ok": true, "action": "STOP_DEBUG"], on: connection)
        case ("POST", "/START_RING"):
            triggerRing()
            sendText(status: 200, body: "STARTED\n", on: connection)
        case ("POST", "/STOP_RING"):
            stopAllDebugNotifications()
            sendText(status: 200, body: "STOPPED\n", on: connection)
        case ("OPTIONS", _):
            send(status: 204, contentType: "text/plain", body: Data(), on: connection)
        default:
            sendJSON(status: 404, object: ["ok": false, "error": "route_not_found"], on: connection)
        }
    }

    private func parseHTTPRequest(_ text: String) -> HTTPRequest? {
        guard let requestLine = text.split(whereSeparator: { $0.isNewline }).first else {
            return nil
        }
        let components = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard components.count == 3 else { return nil }

        let method = components[0].uppercased()
        let target = String(components[1])
        guard components[2].uppercased().hasPrefix("HTTP/"),
              let urlComponents = URLComponents(string: target) else {
            return nil
        }
        let path = urlComponents.path.isEmpty ? "/" : urlComponents.path
        return HTTPRequest(method: method, path: path, queryItems: urlComponents.queryItems ?? [])
    }

    private func handleLegacyCommand(_ request: String) {
        switch request.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "START_RING":
            triggerRing()
        case "STOP_RING":
            stopAllDebugNotifications()
        default:
            log.error("Unsupported app message")
        }
    }

    private func triggerRing() {
        submitNotification(
            identifier: Self.ringNotificationIdentifier,
            title: "响铃请求",
            body: "局域网设备请求手机提醒",
            action: "START_RING"
        )
    }

    private func submitNotification(
        identifier: String,
        title: String,
        body: String,
        action: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "app.wephone.vpn.debug"
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }

        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request) { [weak self] error in
            guard let self else { return }
            if let error {
                self.recordError("Notification failed: \(error.localizedDescription)")
            } else {
                self.recordAction(action)
                self.log.info("\(action) notification submitted")
            }
            self.refreshNotificationAuthorization()
        }
    }

    private func stopAllDebugNotifications() {
        let identifiers = [
            Self.ringNotificationIdentifier,
            Self.messageNotificationIdentifier,
            Self.callNotificationIdentifier
        ]
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        recordAction("STOP_DEBUG")
        log.info("Debug notifications removed")
    }

    private func sendLogSnapshot(for request: HTTPRequest, on connection: NWConnection) {
        let cursorText = request.queryItems.first(where: { $0.name == "cursor" })?.value
        let cursor: UInt64?
        if let cursorText {
            guard let parsed = UInt64(cursorText) else {
                sendJSON(status: 400, object: ["ok": false, "error": "invalid_cursor"], on: connection)
                return
            }
            cursor = parsed
        } else {
            cursor = nil
        }

        let snapshot = log.logSnapshot(after: cursor)
        sendJSON(
            status: 200,
            object: [
                "ok": true,
                "text": snapshot.text,
                "cursor": snapshot.nextOffset,
                "reset": snapshot.reset,
                "truncated": snapshot.truncated
            ],
            on: connection
        )
    }

    private func sendAccepted(
        action: String,
        extra: [String: Any] = [:],
        on connection: NWConnection
    ) {
        var payload: [String: Any] = ["ok": true, "accepted": true, "action": action]
        extra.forEach { payload[$0.key] = $0.value }
        sendJSON(status: 202, object: payload, on: connection)
    }

    private func apiDiscoveryPayload() -> [String: Any] {
        [
            "name": "WPhone LAN Debug API",
            "version": 1,
            "openapi": "/openapi.json",
            "health": "/health",
            "status": "/api/status",
            "logs": "/api/logs",
            "accessPolicy": "private-lan-over-wifi",
            "capabilities": ["status", "incremental_logs", "message_notification", "call_style_notification"]
        ]
    }

    private func statusPayload() -> [String: Any] {
        let state = stateSnapshot()
        connectionLock.lock()
        let activeConnections = connections.count
        connectionLock.unlock()

        let uptimeSeconds: Int
        if let startedAt = state.tunnelStartedAt {
            uptimeSeconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        } else {
            uptimeSeconds = 0
        }

        return [
            "ok": true,
            "service": "wphone-debug",
            "version": 1,
            "tunnel": [
                "purpose": "keepalive-only",
                "packetForwarding": false,
                "includedRouteCount": 0,
                "defaultRouteExcluded": true,
                "startedAt": jsonValue(state.tunnelStartedAt.map { dateFormatter.string(from: $0) }),
                "uptimeSeconds": uptimeSeconds
            ],
            "listener": [
                "state": state.listenerState,
                "port": Int(listenerPort.rawValue),
                "interface": "wifi",
                "accessPolicy": "private-lan-only",
                "bonjourType": Self.bonjourServiceType,
                "activeConnections": activeConnections,
                "maximumConnections": Self.maximumConnections,
                "totalRequests": state.totalRequests,
                "lastRequestPath": jsonValue(state.lastRequestPath)
            ],
            "notifications": [
                "authorization": state.notificationAuthorization,
                "lastAction": jsonValue(state.lastAction),
                "lastActionAt": jsonValue(state.lastActionAt.map { dateFormatter.string(from: $0) }),
                "callDebugMode": "local-notification",
                "callKit": false
            ],
            "lastError": jsonValue(state.lastError)
        ]
    }

    private func openAPIPayload() -> [String: Any] {
        let successResponse: [String: Any] = [
            "description": "Successful JSON response",
            "content": ["application/json": ["schema": ["type": "object"]]]
        ]
        let acceptedResponse: [String: Any] = [
            "description": "Notification request accepted",
            "content": ["application/json": ["schema": ["type": "object"]]]
        ]

        return [
            "openapi": "3.0.3",
            "info": [
                "title": "WPhone LAN Debug API",
                "version": "1.0.0",
                "description": "Private-LAN debug controls for WPhone"
            ],
            "servers": [["url": "/"]],
            "paths": [
                "/health": [
                    "get": ["operationId": "getHealth", "responses": ["200": successResponse]]
                ],
                "/api/status": [
                    "get": ["operationId": "getStatus", "responses": ["200": successResponse]]
                ],
                "/api/logs": [
                    "get": [
                        "operationId": "getIncrementalLogs",
                        "parameters": [[
                            "name": "cursor",
                            "in": "query",
                            "required": false,
                            "schema": ["type": "integer", "format": "int64", "minimum": 0]
                        ]],
                        "responses": ["200": successResponse]
                    ]
                ],
                "/api/debug/message": [
                    "post": [
                        "operationId": "showDebugMessage",
                        "parameters": [
                            ["name": "title", "in": "query", "schema": ["type": "string", "maxLength": 80]],
                            ["name": "body", "in": "query", "schema": ["type": "string", "maxLength": 240]]
                        ],
                        "responses": ["202": acceptedResponse]
                    ]
                ],
                "/api/debug/call": [
                    "post": [
                        "operationId": "showDebugCallNotification",
                        "description": "Shows a call-style local notification; it is not a CallKit incoming call.",
                        "parameters": [[
                            "name": "caller",
                            "in": "query",
                            "schema": ["type": "string", "maxLength": 80]
                        ]],
                        "responses": ["202": acceptedResponse]
                    ]
                ],
                "/api/debug/stop": [
                    "post": ["operationId": "stopDebugNotifications", "responses": ["200": successResponse]]
                ]
            ]
        ]
    }

    private func recordRequest(_ request: HTTPRequest) {
        mutateState {
            $0.totalRequests += 1
            $0.lastRequestPath = request.path
        }
        if request.path != "/api/status" && request.path != "/api/logs" {
            log.debug("HTTP \(request.method) \(request.path)")
        }
    }

    private func recordAction(_ action: String) {
        mutateState {
            $0.lastAction = action
            $0.lastActionAt = Date()
            $0.lastError = nil
        }
    }

    private func recordError(_ message: String) {
        mutateState { $0.lastError = message }
        log.error(message)
    }

    private func refreshNotificationAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let value: String
            switch settings.authorizationStatus {
            case .notDetermined: value = "not-determined"
            case .denied: value = "denied"
            case .authorized: value = "authorized"
            case .provisional: value = "provisional"
            case .ephemeral: value = "ephemeral"
            @unknown default: value = "unknown"
            }
            self?.mutateState { $0.notificationAuthorization = value }
        }
    }

    private func mutateState(_ update: (inout RuntimeState) -> Void) {
        stateLock.lock()
        update(&runtimeState)
        stateLock.unlock()
    }

    private func stateSnapshot() -> RuntimeState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return runtimeState
    }

    private func jsonValue(_ value: String?) -> Any {
        guard let value else { return NSNull() }
        return value
    }

    private func sendJSON(status: Int, object: [String: Any], on connection: NWConnection) {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            send(status: status, contentType: "application/json; charset=utf-8", body: data, on: connection)
        } catch {
            recordError("JSON response failed: \(error.localizedDescription)")
            sendText(status: 500, body: "internal server error\n", on: connection)
        }
    }

    private func sendText(status: Int, body: String, on connection: NWConnection) {
        send(
            status: status,
            contentType: "text/plain; charset=utf-8",
            body: Data(body.utf8),
            on: connection
        )
    }

    private func send(
        status: Int,
        contentType: String,
        body: Data,
        on connection: NWConnection
    ) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 413: reason = "Payload Too Large"
        default: reason = "Internal Server Error"
        }

        let headers = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: GET, POST, OPTIONS\r
        Access-Control-Allow-Headers: Content-Type\r
        X-Content-Type-Options: nosniff\r
        Connection: close\r
        \r

        """
        var response = Data(headers.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self, weak connection] error in
            if let error {
                self?.log.error("Send failed: \(error.localizedDescription)")
            }
            if let connection {
                self?.remove(connection)
            }
            connection?.cancel()
        })
    }

    private func remove(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connectionLock.lock()
        connections.removeValue(forKey: id)
        requestBuffers.removeValue(forKey: id)
        let timeout = connectionTimeouts.removeValue(forKey: id)
        connectionLock.unlock()
        timeout?.cancel()
    }

    private func isPrivateLANClient(_ endpoint: Network.NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        let address = String(describing: host)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: "%", maxSplits: 1)
            .first
            .map(String.init) ?? ""

        if let ipv4 = IPv4Address(address) {
            let bytes = [UInt8](ipv4.rawValue)
            return isPrivateIPv4Octets(bytes)
        }

        if let ipv6 = IPv6Address(address) {
            let bytes = [UInt8](ipv6.rawValue)
            guard bytes.count == 16 else { return false }
            let isUniqueLocal = bytes[0] & 0xfe == 0xfc
            let isLinkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
            let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let isMappedPrivateIPv4 = bytes.prefix(10).allSatisfy { $0 == 0 }
                && bytes[10] == 0xff
                && bytes[11] == 0xff
                && isPrivateIPv4Octets(Array(bytes.suffix(4)))
            return isUniqueLocal || isLinkLocal || isLoopback || isMappedPrivateIPv4
        }

        return false
    }

    private func isPrivateIPv4Octets(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        return bytes[0] == 10
            || (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31)
            || (bytes[0] == 192 && bytes[1] == 168)
            || (bytes[0] == 169 && bytes[1] == 254)
            || bytes[0] == 127
    }

    private static let dashboardHTML = #"""
    <!doctype html>
    <html lang="zh-CN">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <title>WPhone 调试后台</title>
      <style>
        :root { color-scheme: light; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color: #182026; background: #f4f6f7; }
        * { box-sizing: border-box; }
        body { margin: 0; min-width: 320px; }
        header { background: #fff; border-bottom: 1px solid #d9dee2; }
        header > div, main { width: min(1040px, calc(100% - 32px)); margin: 0 auto; }
        header > div { min-height: 64px; display: flex; align-items: center; justify-content: space-between; gap: 16px; }
        h1 { margin: 0; font-size: 20px; font-weight: 650; }
        h2 { margin: 0 0 14px; font-size: 16px; }
        .status { display: inline-flex; align-items: center; gap: 8px; font-size: 13px; font-weight: 600; }
        .dot { width: 10px; height: 10px; border-radius: 50%; background: #9aa4aa; }
        .dot.ready { background: #18864b; }
        main { padding: 24px 0 36px; }
        section { padding: 20px 0; border-bottom: 1px solid #d9dee2; }
        .stats { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 10px; }
        .stat { background: #fff; border: 1px solid #d9dee2; border-radius: 6px; padding: 14px; min-height: 82px; }
        .stat span { display: block; color: #65727a; font-size: 12px; margin-bottom: 8px; }
        .stat strong { display: block; font-size: 16px; overflow-wrap: anywhere; }
        .actions { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
        form { display: grid; grid-template-columns: 1fr; gap: 10px; align-content: start; }
        label { display: grid; gap: 6px; color: #4e5a61; font-size: 12px; }
        input { width: 100%; min-height: 38px; padding: 8px 10px; border: 1px solid #b8c1c7; border-radius: 5px; background: #fff; color: #182026; font-size: 14px; }
        button { min-height: 38px; border: 1px solid #1769aa; border-radius: 5px; padding: 8px 14px; background: #1769aa; color: #fff; font-size: 14px; font-weight: 600; cursor: pointer; }
        button.secondary { background: #fff; color: #ad2f2f; border-color: #c65c5c; }
        button:disabled { opacity: .55; cursor: wait; }
        .toolbar { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 10px; }
        .result { min-height: 20px; color: #4e5a61; font-size: 13px; }
        pre { margin: 0; width: 100%; height: 360px; overflow: auto; padding: 14px; background: #111719; color: #dce4e7; border: 1px solid #263238; border-radius: 6px; font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre-wrap; overflow-wrap: anywhere; }
        a { color: #1769aa; }
        footer { display: flex; justify-content: space-between; gap: 12px; padding-top: 18px; color: #65727a; font-size: 12px; }
        @media (max-width: 720px) { .stats { grid-template-columns: 1fr 1fr; } .actions { grid-template-columns: 1fr; } header > div, main { width: min(100% - 20px, 1040px); } }
      </style>
    </head>
    <body>
      <header><div><h1>WPhone 调试后台</h1><div class="status"><i id="dot" class="dot"></i><span id="listenerState">连接中</span></div></div></header>
      <main>
        <section class="stats" aria-label="实时状态">
          <div class="stat"><span>隧道用途</span><strong id="purpose">-</strong></div>
          <div class="stat"><span>运行时间</span><strong id="uptime">-</strong></div>
          <div class="stat"><span>通知权限</span><strong id="notification">-</strong></div>
          <div class="stat"><span>请求总数</span><strong id="requests">-</strong></div>
        </section>
        <section>
          <h2>弹出调试</h2>
          <div class="actions">
            <form id="messageForm">
              <label>信息标题<input id="messageTitle" value="信息弹出调试" maxlength="80"></label>
              <label>信息内容<input id="messageBody" value="WPhone 局域网调试消息" maxlength="240"></label>
              <button type="submit">弹出信息</button>
            </form>
            <form id="callForm">
              <label>来电名称<input id="caller" value="WPhone 调试来电" maxlength="80"></label>
              <button type="submit">电话弹出</button>
              <button id="stopButton" class="secondary" type="button">停止并清除</button>
            </form>
          </div>
          <p id="result" class="result" role="status"></p>
        </section>
        <section>
          <div class="toolbar"><h2>实时日志</h2><button id="clearView" class="secondary" type="button">清空视图</button></div>
          <pre id="logs">正在读取 debug.log...</pre>
        </section>
        <footer><span id="lastAction">最近操作：-</span><span><a href="/openapi.json">OpenAPI</a> · <a href="/.well-known/wphone-debug">Discovery</a></span></footer>
      </main>
      <script>
        const byId = id => document.getElementById(id);
        let cursor = null;
        let actionBusy = false;

        async function getJSON(path, options = {}) {
          const response = await fetch(path, { cache: 'no-store', ...options });
          const data = await response.json();
          if (!response.ok) throw new Error(data.error || `HTTP ${response.status}`);
          return data;
        }

        function duration(seconds) {
          const hours = Math.floor(seconds / 3600);
          const minutes = Math.floor((seconds % 3600) / 60);
          const rest = seconds % 60;
          return `${hours}h ${minutes}m ${rest}s`;
        }

        async function refreshStatus() {
          try {
            const data = await getJSON('/api/status');
            const ready = data.listener.state === 'ready';
            byId('dot').className = ready ? 'dot ready' : 'dot';
            byId('listenerState').textContent = `${data.listener.state} · :${data.listener.port}`;
            byId('purpose').textContent = data.tunnel.purpose;
            byId('uptime').textContent = duration(data.tunnel.uptimeSeconds);
            byId('notification').textContent = data.notifications.authorization;
            byId('requests').textContent = String(data.listener.totalRequests);
            byId('lastAction').textContent = `最近操作：${data.notifications.lastAction || '-'}`;
          } catch (error) {
            byId('dot').className = 'dot';
            byId('listenerState').textContent = error.message;
          }
        }

        async function refreshLogs() {
          try {
            const suffix = cursor === null ? '' : `?cursor=${cursor}`;
            const data = await getJSON(`/api/logs${suffix}`);
            const output = byId('logs');
            if (cursor === null || data.reset) output.textContent = data.text;
            else if (data.text) output.textContent += data.text;
            cursor = data.cursor;
            if (output.textContent.length > 160000) output.textContent = output.textContent.slice(-120000);
            if (data.text) output.scrollTop = output.scrollHeight;
          } catch (error) {
            byId('result').textContent = `日志读取失败：${error.message}`;
          }
        }

        async function runAction(path, message) {
          if (actionBusy) return;
          actionBusy = true;
          document.querySelectorAll('button').forEach(button => button.disabled = true);
          try {
            await getJSON(path, { method: 'POST' });
            byId('result').textContent = message;
            await refreshStatus();
          } catch (error) {
            byId('result').textContent = `操作失败：${error.message}`;
          } finally {
            actionBusy = false;
            document.querySelectorAll('button').forEach(button => button.disabled = false);
          }
        }

        byId('messageForm').addEventListener('submit', event => {
          event.preventDefault();
          const query = new URLSearchParams({ title: byId('messageTitle').value, body: byId('messageBody').value });
          runAction(`/api/debug/message?${query}`, '信息通知已提交');
        });
        byId('callForm').addEventListener('submit', event => {
          event.preventDefault();
          const query = new URLSearchParams({ caller: byId('caller').value });
          runAction(`/api/debug/call?${query}`, '电话样式通知已提交');
        });
        byId('stopButton').addEventListener('click', () => runAction('/api/debug/stop', '调试通知已清除'));
        byId('clearView').addEventListener('click', () => { byId('logs').textContent = ''; });

        refreshStatus();
        refreshLogs();
        setInterval(refreshStatus, 1000);
        setInterval(refreshLogs, 1000);
      </script>
    </body>
    </html>
    """#
}
