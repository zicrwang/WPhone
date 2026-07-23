import Foundation
import Network
import NetworkExtension
import UserNotifications

final class LocalPushProvider: NEAppPushProvider {
    private static let maximumFrameBytes = 24 * 1024
    private static let reconnectDelay: TimeInterval = 5

    private let queue = DispatchQueue(label: "app.wephone.vpn.local-push-provider")
    private let log = SharedLogger.shared
    private lazy var idempotencyStore = WPhoneEventIdempotencyStore(log: log)
    private var connection: Network.NWConnection?
    private var receiveBuffer = Data()
    private var reconnectWorkItem: DispatchWorkItem?
    private var isRunning = false
    private var isReady = false
    private var host = ""
    private var port: Network.NWEndpoint.Port = 8081
    private var deviceID = ""

    override func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard let configuration = self.providerConfiguration,
                  let host = configuration["host"] as? String,
                  !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let rawPort = configuration["port"] as? NSNumber,
                  let port = Network.NWEndpoint.Port(rawValue: rawPort.uint16Value) else {
                self.log.error("Local Push provider configuration is invalid")
                return
            }

            self.host = host
            self.port = port
            self.deviceID = configuration["deviceID"] as? String ?? UUID().uuidString
            self.isRunning = true
            self.log.info("Local Push provider started host=\(host) port=\(port.rawValue)")
            self.connect()
        }
    }

    override func stop(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        queue.async { [weak self] in
            guard let self else {
                completionHandler()
                return
            }
            self.isRunning = false
            self.isReady = false
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.connection?.cancel()
            self.connection = nil
            self.receiveBuffer.removeAll(keepingCapacity: false)
            self.log.info("Local Push provider stopped reason=\(reason.rawValue)")
            completionHandler()
        }
    }

    override func handleTimerEvent() {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            if self.isReady {
                self.sendObject([
                    "kind": "ping",
                    "timestamp": Int64(Date().timeIntervalSince1970 * 1_000)
                ])
            } else if self.connection == nil {
                self.connect()
            }
        }
    }

    private func connect() {
        guard isRunning, connection == nil else { return }
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil

        let parameters = Network.NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        let newConnection = Network.NWConnection(
            host: Network.NWEndpoint.Host(host),
            port: port,
            using: parameters
        )
        connection = newConnection
        isReady = false
        receiveBuffer.removeAll(keepingCapacity: true)

        newConnection.stateUpdateHandler = {
            [weak self, weak newConnection] (state: Network.NWConnection.State) in
            guard let self, let newConnection, self.connection === newConnection else { return }
            self.handleConnectionState(state, connection: newConnection)
        }
        newConnection.start(queue: queue)
    }

    private func handleConnectionState(
        _ state: Network.NWConnection.State,
        connection: Network.NWConnection
    ) {
        switch state {
        case .ready:
            isReady = true
            log.info("Local Push relay connected host=\(host) port=\(port.rawValue)")
            sendObject([
                "kind": "register",
                "protocolVersion": 1,
                "deviceID": deviceID
            ])
            receive(on: connection)
        case .waiting(let error):
            isReady = false
            log.error("Local Push relay waiting: \(error.localizedDescription)")
        case .failed(let error):
            log.error("Local Push relay failed: \(error.localizedDescription)")
            finishConnection(connection)
        case .cancelled:
            finishConnection(connection)
        default:
            break
        }
    }

    private func finishConnection(_ finishedConnection: Network.NWConnection) {
        guard connection === finishedConnection else { return }
        connection = nil
        isReady = false
        receiveBuffer.removeAll(keepingCapacity: false)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard isRunning, reconnectWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            self.connect()
        }
        reconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + Self.reconnectDelay, execute: workItem)
    }

    private func receive(on activeConnection: Network.NWConnection) {
        activeConnection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 4096
        ) { [weak self, weak activeConnection] data, _, isComplete, error in
            guard let self, let activeConnection, self.connection === activeConnection else { return }

            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                guard self.receiveBuffer.count <= Self.maximumFrameBytes else {
                    self.log.error("Local Push relay frame exceeds \(Self.maximumFrameBytes) bytes")
                    activeConnection.cancel()
                    return
                }
                self.processFrames()
            }

            if let error {
                self.log.error("Local Push relay receive failed: \(error.localizedDescription)")
                activeConnection.cancel()
                return
            }
            if isComplete {
                activeConnection.cancel()
                return
            }
            self.receive(on: activeConnection)
        }
    }

    private func processFrames() {
        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            let frame = Data(receiveBuffer[..<newline])
            receiveBuffer.removeSubrange(...newline)
            guard !frame.isEmpty else { continue }
            processFrame(frame)
        }
    }

    private func processFrame(_ frame: Data) {
        do {
            guard let object = try JSONSerialization.jsonObject(with: frame) as? [String: Any],
                  let kind = object["kind"] as? String else {
                throw WPhoneEventAPIError(
                    httpStatus: 400,
                    code: "invalid_relay_frame",
                    message: "The relay frame must be a JSON object with a kind."
                )
            }

            switch kind {
            case "event":
                processEventFrame(object)
            case "ping":
                sendObject([
                    "kind": "pong",
                    "timestamp": object["timestamp"] ?? Int64(Date().timeIntervalSince1970 * 1_000)
                ])
            case "pong":
                break
            default:
                log.debug("Ignored Local Push relay frame kind=\(kind)")
            }
        } catch {
            log.error("Local Push relay frame rejected: \(error.localizedDescription)")
        }
    }

    private func processEventFrame(_ object: [String: Any]) {
        let deliveryID = object["deliveryID"] as? String ?? UUID().uuidString
        guard let encodedEvent = object["eventBase64"] as? String,
              let eventData = Data(base64Encoded: encodedEvent) else {
            sendAck(
                deliveryID: deliveryID,
                status: "rejected",
                errorCode: "invalid_event_encoding"
            )
            return
        }

        do {
            let event = try WPhoneEventContract.decode(eventData)
            let effect = WPhoneEventContract.effect(for: event.type)
            let decision = idempotencyStore.evaluate(
                key: event.idempotencyKey,
                requestDigest: WPhoneEventContract.requestDigest(eventData),
                effect: effect
            )

            switch decision {
            case .accepted(let record):
                do {
                    try apply(event)
                } catch {
                    idempotencyStore.discard(
                        key: event.idempotencyKey,
                        requestDigest: WPhoneEventContract.requestDigest(eventData)
                    )
                    throw error
                }
                log.info(
                    "Local Push event accepted source=\(event.source) type=\(event.type) id=\(event.id)"
                )
                sendAck(
                    deliveryID: deliveryID,
                    status: "accepted",
                    event: event,
                    effect: effect,
                    firstAcceptedAt: record.firstAcceptedAtMilliseconds
                )
            case .duplicate(let record):
                log.info("Local Push event duplicate source=\(event.source) id=\(event.id)")
                sendAck(
                    deliveryID: deliveryID,
                    status: "duplicate",
                    event: event,
                    effect: record.effect,
                    firstAcceptedAt: record.firstAcceptedAtMilliseconds
                )
            case .conflict:
                log.error("Local Push idempotency conflict source=\(event.source) id=\(event.id)")
                sendAck(
                    deliveryID: deliveryID,
                    status: "conflict",
                    event: event,
                    errorCode: "idempotency_conflict"
                )
            }
        } catch let error as WPhoneEventAPIError {
            log.error("Local Push event rejected code=\(error.code) field=\(error.field ?? "none")")
            sendAck(
                deliveryID: deliveryID,
                status: "rejected",
                errorCode: error.code
            )
        } catch {
            log.error("Local Push event failed: \(error.localizedDescription)")
            sendAck(
                deliveryID: deliveryID,
                status: "rejected",
                errorCode: "internal_error"
            )
        }
    }

    private func apply(_ event: WPhoneEvent) throws {
        let notificationIdentifier = WPhoneEventContract.notificationIdentifier(
            source: event.source,
            eventID: event.id
        )

        switch event.type {
        case "call.incoming":
            let caller = event.payloadString("caller") ?? "未知来电"
            reportIncomingCall(userInfo: [
                "eventID": event.id,
                "source": event.source,
                "caller": caller,
                "hasVideo": event.payloadString("callKind") == "video",
                "notificationIdentifier": notificationIdentifier
            ])
            log.info("Local Push incoming call reported to manager key=\(event.idempotencyKey)")
        case "call.ended":
            guard let targetID = event.payloadString("targetId") else { return }
            removeNotification(source: event.source, eventID: targetID)
            try CallKitBridge.enqueue(
                .end(
                    key: "\(event.source):\(targetID)",
                    action: "LOCAL_PUSH_CALLKIT_ENDED"
                )
            )
        case "message.received":
            let title = event.payloadString("title")
                ?? event.payloadString("sender")
                ?? "新消息"
            submitNotification(
                identifier: notificationIdentifier,
                title: title,
                body: event.payloadString("body") ?? "",
                event: event,
                opensWeChat: true
            )
        case "notification.show":
            submitNotification(
                identifier: notificationIdentifier,
                title: event.payloadString("title") ?? "WPhone 通知",
                body: event.payloadString("body") ?? "",
                event: event,
                opensWeChat: false
            )
        case "notification.dismiss":
            guard let targetID = event.payloadString("targetId") else { return }
            removeNotification(source: event.source, eventID: targetID)
        default:
            log.info("Local Push custom event logged source=\(event.source) type=\(event.type)")
        }
    }

    private func submitNotification(
        identifier: String,
        title: String,
        body: String,
        event: WPhoneEvent,
        opensWeChat: Bool
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = event.sound == "none" ? nil : .default
        content.threadIdentifier = "app.wephone.vpn.events.\(event.source)"
        if event.priority == "timeSensitive" {
            content.interruptionLevel = .timeSensitive
        }
        if opensWeChat {
            NotificationRouting.routeToWeChat(content)
        }

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) {
            [weak self] error in
            if let error {
                self?.log.error("Local Push notification failed: \(error.localizedDescription)")
            } else {
                self?.log.info("Local Push notification submitted id=\(event.id)")
            }
        }
    }

    private func removeNotification(source: String, eventID: String) {
        let identifier = WPhoneEventContract.notificationIdentifier(source: source, eventID: eventID)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        log.info("Local Push notification removed source=\(source) targetId=\(eventID)")
    }

    private func sendAck(
        deliveryID: String,
        status: String,
        event: WPhoneEvent? = nil,
        effect: String? = nil,
        firstAcceptedAt: Int64? = nil,
        errorCode: String? = nil
    ) {
        var object: [String: Any] = [
            "kind": "ack",
            "deliveryID": deliveryID,
            "status": status
        ]
        if let event {
            object["source"] = event.source
            object["id"] = event.id
            object["eventType"] = event.type
        }
        if let effect { object["effect"] = effect }
        if let firstAcceptedAt { object["firstAcceptedAt"] = firstAcceptedAt }
        if let errorCode { object["errorCode"] = errorCode }
        sendObject(object)
    }

    private func sendObject(_ object: [String: Any]) {
        guard isReady, let connection else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.log.error("Local Push relay send failed: \(error.localizedDescription)")
                }
            })
        } catch {
            log.error("Local Push relay encoding failed: \(error.localizedDescription)")
        }
    }
}
