import Foundation
import Network
import NetworkExtension
import UserNotifications

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private static let ringNotificationIdentifier = "app.star6979.lettuce4401.ring"
    private static let maximumRequestBytes = 16 * 1024
    private static let maximumConnections = 8

    private let log = SharedLogger.shared
    private let listenerQueue = DispatchQueue(label: "app.star6979.lettuce4401.listener")
    private let connectionLock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var requestBuffers: [ObjectIdentifier: Data] = [:]
    private var allowedClientIPv4 = "192.168.1.10"
    private var listenerPort: Network.NWEndpoint.Port = 8080
    private var listenerStartCompletion: ((Error?) -> Void)?
    private var listenerReachedReady = false

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        log.info("Starting empty packet tunnel")
        loadProviderConfiguration()

        // There is deliberately no packetFlow read loop. The empty included route list,
        // plus an explicit excluded default route, leaves normal device traffic on its
        // physical interface. This is not a guarantee against OS policy changes.
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
                completionHandler(NSError(domain: "EmptyTunnel", code: 1))
                return
            }
            if let error {
                self.log.error("Network settings failed: \(error.localizedDescription)")
                completionHandler(error)
                return
            }

            do {
                try self.startListener { [weak self] error in
                    if let error {
                        self?.log.error("LAN listener failed: \(error.localizedDescription)")
                    } else {
                        self?.log.info("LAN listener started on port \(self?.listenerPort.rawValue ?? 0)")
                    }
                    completionHandler(error)
                }
            } catch {
                self.log.error("LAN listener failed: \(error.localizedDescription)")
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

        connectionLock.lock()
        let activeConnections = Array(connections.values)
        connections.removeAll(keepingCapacity: false)
        requestBuffers.removeAll(keepingCapacity: false)
        connectionLock.unlock()

        activeConnections.forEach { $0.cancel() }
        completionHandler()
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)? = nil
    ) {
        // Keep the extension controllable without opening another IPC mechanism.
        let command = String(data: messageData, encoding: .utf8) ?? ""
        handleCommand(command)
        completionHandler?(Data("OK\n".utf8))
    }

    private func loadProviderConfiguration() {
        guard let configuration = protocolConfiguration as? NETunnelProviderProtocol,
              let values = configuration.providerConfiguration else { return }

        if let allowed = values["allowedClientIPv4"] as? String,
           IPv4Address(allowed) != nil {
            allowedClientIPv4 = allowed
        }
        if let port = values["listenerPort"] as? NSNumber,
           let parsed = Network.NWEndpoint.Port(rawValue: port.uint16Value) {
            listenerPort = parsed
        }
    }

    private func startListener(completion: @escaping (Error?) -> Void) throws {
        var parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi

        let newListener = try NWListener(using: parameters, on: listenerPort)
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
        log.debug("NWListener state: \(String(describing: state))")

        switch state {
        case .ready:
            listenerReachedReady = true
            finishListenerStart(with: nil)
        case .failed(let error):
            let failedAfterStart = listenerReachedReady
            listener = nil
            finishListenerStart(with: error)
            if failedAfterStart {
                log.error("LAN listener stopped after becoming ready: \(error.localizedDescription)")
                cancelTunnelWithError(error)
            }
        case .cancelled:
            if !listenerReachedReady {
                finishListenerStart(with: NSError(domain: "EmptyTunnel", code: 2))
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
        guard clientIPv4(for: connection.endpoint) == allowedClientIPv4 else {
            log.error("Rejected LAN client: \(String(describing: connection.endpoint))")
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
        connectionLock.unlock()

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            self.log.debug("Connection state: \(String(describing: state))")
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
                    self.send(status: 413, body: "request too large\n", on: connection)
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
            send(status: 400, body: "invalid utf8\n", on: connection)
            return
        }
        let command = commandFromRequest(text)
        switch command {
        case "START_RING":
            triggerRing()
            send(status: 200, body: "STARTED\n", on: connection)
        case "STOP_RING":
            stopRing()
            send(status: 200, body: "STOPPED\n", on: connection)
        default:
            send(status: 400, body: "use START_RING or STOP_RING\n", on: connection)
        }
    }

    private func handleCommand(_ request: String) {
        switch commandFromRequest(request) {
        case "START_RING": triggerRing()
        case "STOP_RING": stopRing()
        default: log.error("Unsupported app message")
        }
    }

    private func commandFromRequest(_ request: String) -> String {
        let normalized = request.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if normalized == "START_RING" || normalized == "STOP_RING" {
            return normalized
        }

        guard let requestLine = request.split(whereSeparator: { $0.isNewline }).first else {
            return ""
        }
        let components = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count >= 2, components[0].uppercased() == "POST" else {
            return ""
        }
        switch components[1].uppercased() {
        case "/START_RING": return "START_RING"
        case "/STOP_RING": return "STOP_RING"
        default: return ""
        }
    }

    private func send(status: Int, body: String, on connection: NWConnection) {
        let reason = status == 200 ? "OK" : (status == 413 ? "Payload Too Large" : "Bad Request")
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self, weak connection] error in
            if let error { self?.log.error("Send failed: \(error.localizedDescription)") }
            connection?.cancel()
        })
    }

    private func triggerRing() {
        let content = UNMutableNotificationContent()
        content.title = "Ring request"
        content.body = "A trusted LAN client requested attention."
        content.sound = .default
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }

        let request = UNNotificationRequest(
            identifier: Self.ringNotificationIdentifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.log.error("Notification failed: \(error.localizedDescription)")
            } else {
                self?.log.info("START_RING notification submitted")
            }
        }
    }

    private func stopRing() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.ringNotificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.ringNotificationIdentifier])
        log.info("STOP_RING notification removed")
    }

    private func remove(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connectionLock.lock()
        connections.removeValue(forKey: id)
        requestBuffers.removeValue(forKey: id)
        connectionLock.unlock()
    }

    private func clientIPv4(for endpoint: Network.NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        return String(describing: host).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }
}
