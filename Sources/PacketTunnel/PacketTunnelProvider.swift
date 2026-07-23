import AlarmKit
import AppIntents
import Foundation
import Network
import NetworkExtension
import SwiftUI
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
        var acceptedEventCount = 0
        var duplicateEventCount = 0
        var lastEventID: String?
        var lastEventSource: String?
        var lastEventType: String?
        var lastEventEffect: String?
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let queryItems: [URLQueryItem]
        let headers: [String: String]
        let body: Data

        func queryValue(named name: String, maximumCharacters: Int) -> String? {
            guard let value = queryItems.first(where: { $0.name == name })?.value else {
                return nil
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return String(trimmed.prefix(maximumCharacters))
        }
    }

    private enum RequestFraming {
        case incomplete
        case complete(Int)
        case tooLarge
    }

    private let log = SharedLogger.shared
    private let listenerQueue = DispatchQueue(label: "app.wephone.vpn.listener")
    private let connectionLock = NSLock()
    private let stateLock = NSLock()
    private let dateFormatter = ISO8601DateFormatter()
    private lazy var eventIdempotencyStore = WPhoneEventIdempotencyStore(log: log)
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var requestBuffers: [ObjectIdentifier: Data] = [:]
    private var connectionTimeouts: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var listenerPort: Network.NWEndpoint.Port = 8080
    private var listenerStartCompletion: ((Error?) -> Void)?
    private var listenerReachedReady = false
    private var runtimeState = RuntimeState()
    private lazy var alarmKit = AlarmKitCoordinator { [weak self] event in
        self?.handleAlarmKitEvent(event)
    }

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        log.info("Starting keepalive-only packet tunnel")
        loadProviderConfiguration()
        NotificationRouting.registerCategories()
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
        alarmKit.stopAll()
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
                    self.sendAPIError(
                        status: 413,
                        code: "request_too_large",
                        message: "The complete HTTP request exceeds 16384 bytes.",
                        on: connection
                    )
                    return
                }

                if let request {
                    switch self.requestFraming(for: request) {
                    case .complete(let length):
                        self.process(Data(request.prefix(length)), on: connection)
                        return
                    case .tooLarge:
                        self.sendAPIError(
                            status: 413,
                            code: "request_too_large",
                            message: "The complete HTTP request exceeds 16384 bytes.",
                            on: connection
                        )
                        return
                    case .incomplete:
                        if isComplete {
                            self.process(request, on: connection)
                            return
                        }
                    }
                }
            }

            if isComplete {
                self.remove(connection)
            } else {
                self.receive(on: connection)
            }
        }
    }

    private func requestFraming(for data: Data) -> RequestFraming {
        if let text = String(data: data, encoding: .utf8) {
            let command = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if command == "START_RING" || command == "STOP_RING" {
                return .complete(data.count)
            }
        }

        let separator = Data([13, 10, 13, 10])
        guard let separatorRange = data.range(of: separator) else { return .incomplete }
        let bodyStart = separatorRange.upperBound
        guard let headerText = String(
            data: Data(data[..<separatorRange.lowerBound]),
            encoding: .utf8
        ) else {
            return .complete(bodyStart)
        }

        var contentLength = 0
        var foundContentLength = false
        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .complete(bodyStart) }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "content-length" else { continue }
            guard !foundContentLength,
                  let parsed = Int(
                    String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                  ),
                  parsed >= 0 else {
                return .complete(bodyStart)
            }
            foundContentLength = true
            contentLength = parsed
        }

        guard contentLength <= Self.maximumRequestBytes - bodyStart else { return .tooLarge }
        let totalLength = bodyStart + contentLength
        return data.count >= totalLength ? .complete(totalLength) : .incomplete
    }

    private func process(_ data: Data, on connection: NWConnection) {
        if let text = String(data: data, encoding: .utf8) {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if normalized == "START_RING" || normalized == "STOP_RING" {
                handleLegacyCommand(normalized)
                sendText(
                    status: 200,
                    body: normalized == "START_RING" ? "STARTED\n" : "STOPPED\n",
                    on: connection
                )
                return
            }
        }

        guard let request = parseHTTPRequest(data) else {
            sendAPIError(
                status: 400,
                code: "invalid_http_request",
                message: "The HTTP request framing or headers are invalid.",
                on: connection
            )
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
                object: [
                    "ok": true,
                    "service": "wphone",
                    "apiVersion": WPhoneEventContract.specVersion,
                    "events": WPhoneEventContract.endpoint
                ],
                on: connection
            )
        case ("GET", "/api"), ("GET", "/.well-known/wphone"), ("GET", "/.well-known/wphone-debug"):
            sendJSON(status: 200, object: apiDiscoveryPayload(), on: connection)
        case ("GET", "/openapi.json"):
            send(
                status: 200,
                contentType: "application/json; charset=utf-8",
                body: Data(WPhoneEventContract.openAPIJSON.utf8),
                on: connection
            )
        case ("GET", "/api/status"):
            sendJSON(status: 200, object: statusPayload(), on: connection)
        case ("GET", "/api/logs"):
            sendLogSnapshot(for: request, on: connection)
        case ("POST", let path) where path == WPhoneEventContract.endpoint:
            handleEventRequest(request, on: connection)
        case ("POST", "/api/debug/message"):
            let title = request.queryValue(named: "title", maximumCharacters: 80) ?? "信息弹出调试"
            let body = request.queryValue(named: "body", maximumCharacters: 240) ?? "WPhone 局域网调试消息"
            submitNotification(
                identifier: Self.messageNotificationIdentifier,
                title: title,
                body: body,
                action: "DEBUG_MESSAGE",
                opensWeChat: true
            )
            sendAccepted(action: "DEBUG_MESSAGE", on: connection)
        case ("POST", "/api/debug/call"):
            let caller = request.queryValue(named: "caller", maximumCharacters: 80) ?? "WPhone 调试来电"
            scheduleIncomingAlarm(
                key: "debug-call",
                caller: caller,
                action: "DEBUG_ALARMKIT_INCOMING"
            )
            sendAccepted(
                action: "DEBUG_ALARMKIT_INCOMING",
                extra: [
                    "mode": "alarmkit",
                    "alarmKit": true,
                    "openBehavior": "open-wphone-then-wechat"
                ],
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
            sendAPIError(
                status: 404,
                code: "route_not_found",
                message: "No route matches this method and path.",
                on: connection
            )
        }
    }

    private func parseHTTPRequest(_ data: Data) -> HTTPRequest? {
        let separator = Data([13, 10, 13, 10])
        guard let separatorRange = data.range(of: separator),
              let headerText = String(data: Data(data[..<separatorRange.lowerBound]), encoding: .utf8) else {
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let components = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard components.count == 3 else { return nil }

        let method = components[0].uppercased()
        let target = String(components[1])
        guard components[2].uppercased().hasPrefix("HTTP/"),
              let urlComponents = URLComponents(string: target) else {
            return nil
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty, let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, headers[name] == nil else { return nil }
            headers[name] = value
        }
        guard headers["transfer-encoding"] == nil else { return nil }

        let contentLength: Int
        if let rawContentLength = headers["content-length"] {
            guard let parsed = Int(rawContentLength), parsed >= 0 else { return nil }
            contentLength = parsed
        } else {
            contentLength = 0
        }
        let bodyStart = separatorRange.upperBound
        guard bodyStart + contentLength <= data.count else {
            return nil
        }

        let path = urlComponents.path.isEmpty ? "/" : urlComponents.path
        let body = Data(data[bodyStart..<(bodyStart + contentLength)])
        return HTTPRequest(
            method: method,
            path: path,
            queryItems: urlComponents.queryItems ?? [],
            headers: headers,
            body: body
        )
    }

    private func handleEventRequest(_ request: HTTPRequest, on connection: NWConnection) {
        let rawContentType = request.headers["content-type"] ?? ""
        let firstMediaType = rawContentType
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        let mediaType = firstMediaType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard mediaType == "application/json" else {
            sendAPIError(
                status: 415,
                code: "unsupported_media_type",
                message: "Content-Type must be application/json.",
                field: "Content-Type",
                on: connection
            )
            return
        }

        do {
            let event = try WPhoneEventContract.decode(request.body)
            let digest = WPhoneEventContract.requestDigest(request.body)
            let effect = WPhoneEventContract.effect(for: event.type)
            let decision = eventIdempotencyStore.evaluate(
                key: event.idempotencyKey,
                requestDigest: digest,
                effect: effect
            )

            switch decision {
            case .accepted(let record):
                apply(event)
                recordEvent(event, effect: effect, duplicate: false)
                sendJSON(
                    status: 202,
                    object: eventResponse(
                        event: event,
                        status: "accepted",
                        duplicate: false,
                        effect: effect,
                        firstAcceptedAt: record.firstAcceptedAtMilliseconds
                    ),
                    on: connection
                )
            case .duplicate(let record):
                recordEvent(event, effect: record.effect, duplicate: true)
                sendJSON(
                    status: 200,
                    object: eventResponse(
                        event: event,
                        status: "duplicate",
                        duplicate: true,
                        effect: record.effect,
                        firstAcceptedAt: record.firstAcceptedAtMilliseconds
                    ),
                    on: connection
                )
            case .conflict:
                log.error("Idempotency conflict source=\(event.source) id=\(event.id)")
                sendAPIError(
                    status: 409,
                    code: "idempotency_conflict",
                    message: "This source and id were already used with a different request body.",
                    field: "id",
                    on: connection
                )
            }
        } catch let error as WPhoneEventAPIError {
            log.debug("Event rejected code=\(error.code) field=\(error.field ?? "none")")
            sendAPIError(
                status: error.httpStatus,
                code: error.code,
                message: error.message,
                field: error.field,
                on: connection
            )
        } catch {
            recordError("Event processing failed: \(error.localizedDescription)")
            sendAPIError(
                status: 500,
                code: "internal_error",
                message: "The event could not be processed.",
                on: connection
            )
        }
    }

    private func apply(_ event: WPhoneEvent) {
        let identifier = WPhoneEventContract.notificationIdentifier(
            source: event.source,
            eventID: event.id
        )

        switch event.type {
        case "message.received":
            let title = event.payloadString("title")
                ?? event.payloadString("sender")
                ?? "新消息"
            submitNotification(
                identifier: identifier,
                title: title,
                body: event.payloadString("body") ?? "",
                action: "EVENT_MESSAGE_RECEIVED",
                priority: event.priority,
                sound: event.sound,
                threadIdentifier: "app.wephone.vpn.events.\(event.source)",
                opensWeChat: true
            )
        case "call.incoming":
            scheduleIncomingAlarm(
                key: callKey(source: event.source, eventID: event.id),
                caller: event.payloadString("caller") ?? "未知来电",
                action: "EVENT_ALARMKIT_INCOMING"
            )
        case "call.ended":
            guard let targetID = event.payloadString("targetId") else { return }
            let targetIdentifier = WPhoneEventContract.notificationIdentifier(
                source: event.source,
                eventID: targetID
            )
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [targetIdentifier])
            center.removeDeliveredNotifications(withIdentifiers: [targetIdentifier])
            _ = alarmKit.stop(key: callKey(source: event.source, eventID: targetID))
            recordAction("EVENT_ALARMKIT_ENDED")
            log.info("Event AlarmKit alarm ended source=\(event.source) targetId=\(targetID)")
        case "notification.dismiss":
            guard let targetID = event.payloadString("targetId") else { return }
            let targetIdentifier = WPhoneEventContract.notificationIdentifier(
                source: event.source,
                eventID: targetID
            )
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [targetIdentifier])
            center.removeDeliveredNotifications(withIdentifiers: [targetIdentifier])
            recordAction("EVENT_NOTIFICATION_REMOVED")
            log.info("Event notification removed source=\(event.source) targetId=\(targetID)")
        case "notification.show":
            submitNotification(
                identifier: identifier,
                title: event.payloadString("title") ?? "WPhone 通知",
                body: event.payloadString("body") ?? "",
                action: "EVENT_NOTIFICATION_SHOW",
                priority: event.priority,
                sound: event.sound,
                threadIdentifier: "app.wephone.vpn.events.\(event.source)"
            )
        default:
            recordAction("EVENT_LOGGED_ONLY")
            log.info("Custom event logged source=\(event.source) type=\(event.type) id=\(event.id)")
        }
    }

    private func eventResponse(
        event: WPhoneEvent,
        status: String,
        duplicate: Bool,
        effect: String,
        firstAcceptedAt: Int64
    ) -> [String: Any] {
        [
            "ok": true,
            "apiVersion": WPhoneEventContract.specVersion,
            "status": status,
            "duplicate": duplicate,
            "effect": effect,
            "firstAcceptedAt": firstAcceptedAt,
            "event": [
                "id": event.id,
                "source": event.source,
                "type": event.type
            ]
        ]
    }

    private func recordEvent(_ event: WPhoneEvent, effect: String, duplicate: Bool) {
        mutateState {
            if duplicate {
                $0.duplicateEventCount += 1
            } else {
                $0.acceptedEventCount += 1
            }
            $0.lastEventID = event.id
            $0.lastEventSource = event.source
            $0.lastEventType = event.type
            $0.lastEventEffect = effect
        }
        log.info(
            "Event \(duplicate ? "duplicate" : "accepted") source=\(event.source) type=\(event.type) id=\(event.id) effect=\(effect)"
        )
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
        scheduleIncomingAlarm(
            key: "legacy-ring",
            caller: "局域网提醒",
            action: "START_RING_ALARMKIT"
        )
    }

    private func callKey(source: String, eventID: String) -> String {
        "\(source):\(eventID)"
    }

    private func scheduleIncomingAlarm(
        key: String,
        caller: String,
        action: String
    ) {
        alarmKit.schedule(
            key: key,
            caller: caller,
            action: action
        )
    }

    private func handleAlarmKitEvent(_ event: AlarmKitCoordinator.Event) {
        switch event {
        case .scheduled(let action, let key, let alarmID):
            recordAction(action)
            log.info("\(action) AlarmKit alarm scheduled key=\(key) id=\(alarmID.uuidString)")
        case .scheduleFailed(let key, let message):
            recordError("AlarmKit schedule failed key=\(key): \(message)")
            submitNotification(
                identifier: Self.callNotificationIdentifier,
                title: "微信来电",
                body: "AlarmKit 不可用，点击“打开”进入微信",
                action: "ALARMKIT_FALLBACK_NOTIFICATION",
                opensWeChat: true
            )
        case .stopped(let key):
            recordAction("ALARMKIT_STOPPED")
            log.info("AlarmKit alarm stopped key=\(key)")
        }
    }

    private func submitNotification(
        identifier: String,
        title: String,
        body: String,
        action: String,
        priority: String = "timeSensitive",
        sound: String = "default",
        threadIdentifier: String = "app.wephone.vpn.debug",
        opensWeChat: Bool = false
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound == "none" ? nil : .default
        content.threadIdentifier = threadIdentifier
        if opensWeChat {
            NotificationRouting.routeToWeChat(content)
        }
        if #available(iOS 15.0, *), priority == "timeSensitive" {
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
        alarmKit.stopAll()
        recordAction("STOP_DEBUG")
        log.info("Debug alarms and notifications removed")
    }

    private func sendLogSnapshot(for request: HTTPRequest, on connection: NWConnection) {
        let cursorText = request.queryItems.first(where: { $0.name == "cursor" })?.value
        let cursor: UInt64?
        if let cursorText {
            guard let parsed = UInt64(cursorText) else {
                sendAPIError(
                    status: 400,
                    code: "invalid_cursor",
                    message: "cursor must be an unsigned integer.",
                    field: "cursor",
                    on: connection
                )
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
            "name": "WPhone LAN API",
            "version": 1,
            "openapi": "/openapi.json",
            "health": "/health",
            "status": "/api/status",
            "logs": "/api/logs",
            "events": WPhoneEventContract.endpoint,
            "accessPolicy": "private-lan-over-wifi",
            "authentication": "none",
            "supportedEventTypes": WPhoneEventContract.supportedEventTypes,
            "customEventTypePattern": "custom.<vendor>.<name>",
            "extensionKeyPattern": "reverse-domain-name",
            "idempotency": [
                "scope": "source+id",
                "retentionHours": 24,
                "maximumRecords": 512,
                "comparison": "sha256-of-exact-json-body"
            ],
            "capabilities": [
                "versioned_events",
                "persistent_idempotency",
                "status",
                "incremental_logs",
                "message_notification",
                "alarmkit_alert",
                "alarm_open_action",
                "wechat_notification_action"
            ]
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

        let activeAlarm = WPhoneAlarmStore.activeAlarm()
        return [
            "ok": true,
            "service": "wphone",
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
                "lastActionAt": jsonValue(state.lastActionAt.map { dateFormatter.string(from: $0) })
            ],
            "alarmKit": [
                "supported": true,
                "authorization": alarmKit.extensionAuthorizationState,
                "hostAuthorization": WPhoneAlarmStore.hostAuthorization() ?? "unknown",
                "hostAuthorizationUpdatedAt": jsonValue(
                    WPhoneAlarmStore.hostAuthorizationUpdatedAt().map { dateFormatter.string(from: $0) }
                ),
                "extensionAuthorization": alarmKit.extensionAuthorizationState,
                "active": activeAlarm != nil,
                "activeAlarmId": jsonValue(activeAlarm?.id.uuidString),
                "activeCallKey": jsonValue(activeAlarm?.callKey),
                "caller": jsonValue(activeAlarm?.caller),
                "scheduledAt": jsonValue(activeAlarm.map { dateFormatter.string(from: $0.scheduledAt) }),
                "triggerDelaySeconds": AlarmKitCoordinator.triggerDelaySeconds,
                "openBehavior": "open-wphone-then-wechat"
            ],
            "events": [
                "endpoint": WPhoneEventContract.endpoint,
                "specVersion": WPhoneEventContract.specVersion,
                "supportedTypes": WPhoneEventContract.supportedEventTypes,
                "idempotencyRecords": eventIdempotencyStore.count,
                "acceptedCount": state.acceptedEventCount,
                "duplicateCount": state.duplicateEventCount,
                "lastEventId": jsonValue(state.lastEventID),
                "lastEventSource": jsonValue(state.lastEventSource),
                "lastEventType": jsonValue(state.lastEventType),
                "lastEventEffect": jsonValue(state.lastEventEffect)
            ],
            "lastError": jsonValue(state.lastError)
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

    private func sendAPIError(
        status: Int,
        code: String,
        message: String,
        field: String? = nil,
        on connection: NWConnection
    ) {
        var error: [String: Any] = ["code": code, "message": message]
        if let field {
            error["field"] = field
        }
        sendJSON(status: status, object: ["ok": false, "error": error], on: connection)
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
        case 409: reason = "Conflict"
        case 404: reason = "Not Found"
        case 413: reason = "Payload Too Large"
        case 415: reason = "Unsupported Media Type"
        case 422: reason = "Unprocessable Content"
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
        .stats { display: grid; grid-template-columns: repeat(7, minmax(0, 1fr)); gap: 10px; }
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
          <div class="stat"><span>AlarmKit</span><strong id="alarmKit">-</strong></div>
          <div class="stat"><span>请求总数</span><strong id="requests">-</strong></div>
          <div class="stat"><span>本次事件</span><strong id="eventsAccepted">-</strong></div>
          <div class="stat"><span>重复事件</span><strong id="eventsDuplicate">-</strong></div>
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
              <label>来电名称<input id="caller" value="微信来电" maxlength="80"></label>
              <button type="submit">AlarmKit 来电</button>
              <button id="stopButton" class="secondary" type="button">停止并清除</button>
            </form>
          </div>
          <p id="result" class="result" role="status"></p>
        </section>
        <section>
          <div class="toolbar"><h2>实时日志</h2><button id="clearView" class="secondary" type="button">清空视图</button></div>
          <pre id="logs">正在读取 debug.log...</pre>
        </section>
        <footer><span id="lastAction">最近操作：-</span><span><a href="/openapi.json">OpenAPI</a> · <a href="/.well-known/wphone">Discovery</a></span></footer>
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
            byId('alarmKit').textContent = `App ${data.alarmKit.hostAuthorization} / 扩展 ${data.alarmKit.extensionAuthorization} · ${data.alarmKit.active ? '响铃中' : '空闲'}`;
            byId('requests').textContent = String(data.listener.totalRequests);
            byId('eventsAccepted').textContent = String(data.events.acceptedCount);
            byId('eventsDuplicate').textContent = String(data.events.duplicateCount);
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
          runAction(`/api/debug/call?${query}`, 'AlarmKit 来电已提交');
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

private final class AlarmKitCoordinator {
    static let triggerDelaySeconds = 2

    enum Event {
        case scheduled(action: String, key: String, alarmID: UUID)
        case scheduleFailed(key: String, message: String)
        case stopped(key: String)
    }

    private let manager = AlarmManager.shared
    private let eventHandler: (Event) -> Void
    private let generationLock = NSLock()
    private var generation = 0

    init(eventHandler: @escaping (Event) -> Void) {
        self.eventHandler = eventHandler
    }

    var extensionAuthorizationState: String {
        switch manager.authorizationState {
        case .notDetermined: return "not-determined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }

    func schedule(key: String, caller: String, action: String) {
        let operation = beginOperation()
        cancelPersistedAlarm()
        let id = UUID()
        let configuration = WPhoneAlarmConfiguration.make(
            id: id,
            caller: caller,
            callKey: key,
            triggerDate: Date.now.addingTimeInterval(TimeInterval(Self.triggerDelaySeconds))
        )
        let hostAuthorization = WPhoneAlarmStore.hostAuthorization() ?? "unknown"
        let extensionAuthorization = extensionAuthorizationState
        SharedLogger.shared.debug(
            "PacketTunnel AlarmKit schedule attempt key=\(key) id=\(id.uuidString) " +
            "hostAuthorization=\(hostAuthorization) extensionAuthorization=\(extensionAuthorization)"
        )

        Task { [weak self, manager, eventHandler] in
            do {
                _ = try await manager.schedule(id: id, configuration: configuration)
                guard self?.isCurrent(operation) == true else {
                    try? manager.stop(id: id)
                    try? manager.cancel(id: id)
                    return
                }
                WPhoneAlarmStore.save(WPhoneAlarmRecord(
                    id: id,
                    callKey: key,
                    caller: caller,
                    scheduledAt: Date()
                ))
                eventHandler(.scheduled(action: action, key: key, alarmID: id))
            } catch {
                if self?.isCurrent(operation) == true {
                    let currentExtensionState = self?.extensionAuthorizationState ?? "unavailable"
                    let details = WPhoneAlarmDiagnostics.describe(error)
                    eventHandler(.scheduleFailed(
                        key: key,
                        message: "\(details); hostAuthorization=\(hostAuthorization); " +
                            "extensionAuthorizationBefore=\(extensionAuthorization); " +
                            "extensionAuthorizationAfter=\(currentExtensionState)"
                    ))
                }
            }
        }
    }

    @discardableResult
    func stop(key: String) -> Bool {
        guard let record = WPhoneAlarmStore.activeAlarm(), record.callKey == key else {
            return false
        }
        _ = beginOperation()
        stop(record)
        eventHandler(.stopped(key: key))
        return true
    }

    func stopAll() {
        _ = beginOperation()
        cancelPersistedAlarm()
    }

    private func stop(_ record: WPhoneAlarmRecord) {
        try? manager.stop(id: record.id)
        try? manager.cancel(id: record.id)
        WPhoneAlarmStore.clear(alarmID: record.id)
    }

    private func cancelPersistedAlarm() {
        guard let record = WPhoneAlarmStore.activeAlarm() else { return }
        stop(record)
    }

    private func beginOperation() -> Int {
        generationLock.lock()
        generation += 1
        let value = generation
        generationLock.unlock()
        return value
    }

    private func isCurrent(_ operation: Int) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation == operation
    }
}
