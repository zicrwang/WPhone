import Foundation
import Network

final class WPhoneRelayChannel {
    static let defaultHost = "192.168.2.99"
    static let defaultPort: UInt16 = 18081

    private static let maximumFrameBytes = 24 * 1024
    private static let reconnectDelay: TimeInterval = 5
    private static let heartbeatInterval: TimeInterval = 20

    typealias EventHandler = (Data) -> [String: Any]
    typealias StateHandler = (String) -> Void

    private let queue: DispatchQueue
    private let eventHandler: EventHandler
    private let stateHandler: StateHandler
    private let log = SharedLogger.shared

    private var connection: Network.NWConnection?
    private var receiveBuffer = Data()
    private var reconnectWorkItem: DispatchWorkItem?
    private var heartbeatTimer: DispatchSourceTimer?
    private var isRunning = false
    private var isReady = false
    private var hasStartedReceiveLoop = false
    private var host = Self.defaultHost
    private var port = Network.NWEndpoint.Port(rawValue: Self.defaultPort)!
    private var deviceID = ""

    init(
        queue: DispatchQueue,
        eventHandler: @escaping EventHandler,
        stateHandler: @escaping StateHandler
    ) {
        self.queue = queue
        self.eventHandler = eventHandler
        self.stateHandler = stateHandler
    }

    func start(host: String, port: UInt16, deviceID: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopInternal(reportState: false)
            self.host = host
            self.port = Network.NWEndpoint.Port(rawValue: port)
                ?? Network.NWEndpoint.Port(rawValue: Self.defaultPort)!
            self.deviceID = deviceID
            self.isRunning = true
            self.startHeartbeat()
            self.connect()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopInternal(reportState: true)
        }
    }

    private func stopInternal(reportState: Bool) {
        isRunning = false
        isReady = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        heartbeatTimer?.setEventHandler {}
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        hasStartedReceiveLoop = false
        receiveBuffer.removeAll(keepingCapacity: false)
        if reportState {
            stateHandler("stopped")
        }
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.heartbeatInterval,
            repeating: Self.heartbeatInterval
        )
        timer.setEventHandler { [weak self] in
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
        heartbeatTimer = timer
        timer.resume()
    }

    private func connect() {
        guard isRunning, connection == nil else { return }
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        stateHandler("connecting")

        let parameters = Network.NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        let newConnection = Network.NWConnection(
            host: Network.NWEndpoint.Host(host),
            port: port,
            using: parameters
        )
        connection = newConnection
        isReady = false
        hasStartedReceiveLoop = false
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
        connection activeConnection: Network.NWConnection
    ) {
        switch state {
        case .ready:
            isReady = true
            stateHandler("registering")
            log.info("VPN relay transport connected host=\(host) port=\(port.rawValue)")
            sendObject([
                "kind": "register",
                "protocolVersion": 1,
                "providerKind": "packet-tunnel",
                "deviceID": deviceID
            ])
            if !hasStartedReceiveLoop {
                hasStartedReceiveLoop = true
                receive(on: activeConnection)
            }
        case .waiting(let error):
            isReady = false
            stateHandler("waiting")
            log.error("VPN relay waiting: \(error.localizedDescription)")
        case .failed(let error):
            stateHandler("failed")
            log.error("VPN relay failed: \(error.localizedDescription)")
            finishConnection(activeConnection)
        case .cancelled:
            finishConnection(activeConnection)
        default:
            break
        }
    }

    private func finishConnection(_ finishedConnection: Network.NWConnection) {
        guard connection === finishedConnection else { return }
        finishedConnection.stateUpdateHandler = nil
        connection = nil
        isReady = false
        hasStartedReceiveLoop = false
        receiveBuffer.removeAll(keepingCapacity: false)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard isRunning, reconnectWorkItem == nil else { return }
        stateHandler("reconnecting")
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
            guard let self,
                  let activeConnection,
                  self.connection === activeConnection else {
                return
            }

            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.processFrames()
                guard self.receiveBuffer.count <= Self.maximumFrameBytes else {
                    self.log.error("VPN relay frame exceeds \(Self.maximumFrameBytes) bytes")
                    activeConnection.cancel()
                    return
                }
            }

            if let error {
                self.log.error("VPN relay receive failed: \(error.localizedDescription)")
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
            guard frame.count <= Self.maximumFrameBytes else {
                log.error("VPN relay frame exceeds \(Self.maximumFrameBytes) bytes")
                connection?.cancel()
                return
            }
            processFrame(frame)
        }
    }

    private func processFrame(_ frame: Data) {
        do {
            guard let object = try JSONSerialization.jsonObject(with: frame) as? [String: Any],
                  let kind = object["kind"] as? String else {
                throw RelayFrameError.invalidJSON
            }

            switch kind {
            case "registered":
                stateHandler("connected")
                log.info("VPN relay registered device=\(deviceID)")
            case "event":
                processEventFrame(object)
            case "ping":
                sendObject([
                    "kind": "pong",
                    "timestamp": object["timestamp"]
                        ?? Int64(Date().timeIntervalSince1970 * 1_000)
                ])
            case "pong":
                break
            default:
                log.debug("Ignored VPN relay frame kind=\(kind)")
            }
        } catch {
            log.error("VPN relay frame rejected: \(error.localizedDescription)")
        }
    }

    private func processEventFrame(_ object: [String: Any]) {
        let deliveryID = object["deliveryID"] as? String ?? UUID().uuidString
        guard let encodedEvent = object["eventBase64"] as? String,
              let eventData = Data(base64Encoded: encodedEvent) else {
            sendObject([
                "kind": "ack",
                "deliveryID": deliveryID,
                "status": "rejected",
                "errorCode": "invalid_event_encoding"
            ])
            return
        }

        var acknowledgement = eventHandler(eventData)
        acknowledgement["kind"] = "ack"
        acknowledgement["deliveryID"] = deliveryID
        sendObject(acknowledgement)
    }

    private func sendObject(_ object: [String: Any]) {
        guard isReady, let connection else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            connection.send(content: data, completion: .contentProcessed {
                [weak self, weak connection] error in
                if let error {
                    self?.log.error("VPN relay send failed: \(error.localizedDescription)")
                    if let connection, self?.connection === connection {
                        connection.cancel()
                    }
                }
            })
        } catch {
            log.error("VPN relay encoding failed: \(error.localizedDescription)")
        }
    }
}

private enum RelayFrameError: LocalizedError {
    case invalidJSON

    var errorDescription: String? {
        "The relay frame must be a JSON object with a kind."
    }
}
