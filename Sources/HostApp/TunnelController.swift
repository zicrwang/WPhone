import Combine
import Foundation
import NetworkExtension
import UserNotifications

@MainActor
final class TunnelController: NSObject, ObservableObject {
    // Change these values to the identifiers registered in the Apple Developer portal.
    static let providerBundleIdentifier = "app.star6979.lettuce4401.PacketTunnel"
    static let appGroupIdentifier = "group.3970029fa0cfcf6d.1"
    static let allowedClientIPv4 = "192.168.1.10"

    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var lastError: String?

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    override init() {
        super.init()
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.status = self.manager?.connection.status ?? .invalid
        }
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    func requestNotificationAuthorization() async {
        do {
            // Critical alerts require a separate Apple entitlement and approval.
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            )
            SharedLogger.shared.info("Notification authorization granted: \(granted)")
        } catch {
            lastError = error.localizedDescription
            SharedLogger.shared.error("Notification authorization failed: \(error.localizedDescription)")
        }
    }

    func load() async {
        do {
            let managers = try await loadManagers()
            manager = managers.first { current in
                (current.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == Self.providerBundleIdentifier
            }
            status = manager?.connection.status ?? .invalid
            SharedLogger.shared.debug("Loaded packet tunnel status: \(status.rawValue)")
        } catch {
            lastError = error.localizedDescription
            SharedLogger.shared.error("Packet tunnel configuration load failed: \(error.localizedDescription)")
        }
    }

    func start() async {
        do {
            let manager = try await configuredManager()
            self.manager = manager
            try await save(manager)
            try await reload(manager)
            try manager.connection.startVPNTunnel()
            status = manager.connection.status
            lastError = nil
            SharedLogger.shared.info("Packet tunnel start requested")
        } catch {
            lastError = error.localizedDescription
            SharedLogger.shared.error("Packet tunnel start failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
        status = manager?.connection.status ?? .invalid
        SharedLogger.shared.info("Packet tunnel stop requested")
    }

    var statusText: String {
        switch status {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .disconnecting: return "Disconnecting"
        case .disconnected: return "Disconnected"
        case .reasserting: return "Reasserting"
        case .invalid: return "Not configured"
        @unknown default: return "Unknown"
        }
    }

    private func configuredManager() async throws -> NETunnelProviderManager {
        let managers = try await loadManagers()
        let manager = managers.first { current in
            guard let configuration = current.protocolConfiguration as? NETunnelProviderProtocol else {
                return false
            }
            return configuration.providerBundleIdentifier == Self.providerBundleIdentifier
        } ?? NETunnelProviderManager()

        let configuration = NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = Self.providerBundleIdentifier
        configuration.serverAddress = "Empty tunnel"
        configuration.providerConfiguration = [
            "allowedClientIPv4": Self.allowedClientIPv4,
            "listenerPort": 8080
        ]

        manager.protocolConfiguration = configuration
        manager.localizedDescription = "Empty Tunnel LAN Notifier"
        manager.isEnabled = true
        return manager
    }

    private func loadManagers() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[NETunnelProviderManager], Error>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: managers ?? [])
                }
            }
        }
    }

    private func save(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func reload(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
