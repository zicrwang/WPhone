import AlarmKit
import Combine
import Foundation
import NetworkExtension
import UserNotifications

@MainActor
final class TunnelController: NSObject, ObservableObject {
    static let providerBundleIdentifier = "app.wephone.vpn.PacketTunnel"
    static let appGroupIdentifier = "group.3970029fa0cfcf6d.1"

    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var lastError: String?
    @Published private(set) var alarmTestStatus = "Not tested"

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

    func requestAlarmAuthorization() async {
        do {
            let stateDescription: String
            let isAuthorized: Bool
            switch AlarmManager.shared.authorizationState {
            case .notDetermined:
                let requestedState = try await AlarmManager.shared.requestAuthorization()
                stateDescription = String(describing: requestedState)
                isAuthorized = requestedState == .authorized
            case .denied:
                stateDescription = "denied"
                isAuthorized = false
            case .authorized:
                stateDescription = "authorized"
                isAuthorized = true
            @unknown default:
                stateDescription = "unknown"
                isAuthorized = false
            }
            WPhoneAlarmStore.saveHostAuthorization(stateDescription)
            SharedLogger.shared.info("AlarmKit authorization: \(stateDescription)")
            if !isAuthorized {
                lastError = "AlarmKit permission is required for system alarm alerts."
            }
        } catch {
            WPhoneAlarmStore.saveHostAuthorization("error")
            lastError = error.localizedDescription
            SharedLogger.shared.error(
                "AlarmKit authorization failed: \(WPhoneAlarmDiagnostics.describe(error))"
            )
        }
    }

    func scheduleAlarmKitTest() async {
        let manager = AlarmManager.shared
        guard manager.authorizationState == .authorized else {
            alarmTestStatus = "Not authorized"
            SharedLogger.shared.error("Main app AlarmKit test skipped: authorization is not authorized")
            await requestAlarmAuthorization()
            return
        }

        stopAlarmKitTest(logResult: false)
        let id = UUID()
        let caller = "WPhone 主 App 测试"
        let callKey = "main-app-test"
        let configuration = WPhoneAlarmConfiguration.make(
            id: id,
            caller: caller,
            callKey: callKey,
            triggerDate: Date.now.addingTimeInterval(3)
        )
        alarmTestStatus = "Scheduling"
        SharedLogger.shared.debug(
            "Main app AlarmKit schedule attempt id=\(id.uuidString) authorization=authorized"
        )

        do {
            _ = try await manager.schedule(id: id, configuration: configuration)
            WPhoneAlarmStore.save(WPhoneAlarmRecord(
                id: id,
                callKey: callKey,
                caller: caller,
                scheduledAt: Date()
            ))
            alarmTestStatus = "Scheduled"
            lastError = nil
            SharedLogger.shared.info("Main app AlarmKit alarm scheduled id=\(id.uuidString)")
        } catch {
            let details = WPhoneAlarmDiagnostics.describe(error)
            alarmTestStatus = "Failed"
            lastError = error.localizedDescription
            SharedLogger.shared.error("Main app AlarmKit schedule failed: \(details)")
        }
    }

    func stopAlarmKitTest(logResult: Bool = true) {
        guard let record = WPhoneAlarmStore.activeAlarm() else {
            if logResult {
                alarmTestStatus = "No active alarm"
            }
            return
        }
        // AlarmKit uses stop for an alerting alarm and cancel for a scheduled one.
        // Calling both makes this control work on either side of the trigger date.
        try? AlarmManager.shared.stop(id: record.id)
        try? AlarmManager.shared.cancel(id: record.id)
        WPhoneAlarmStore.clear(alarmID: record.id)
        alarmTestStatus = "Stopped"
        if logResult {
            SharedLogger.shared.info("Main app AlarmKit alarm stop/cancel requested id=\(record.id.uuidString)")
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
        configuration.serverAddress = "Keepalive only"
        configuration.providerConfiguration = [
            "listenerPort": 8080,
            "accessPolicy": "privateLANOverWiFi"
        ]

        manager.protocolConfiguration = configuration
        manager.localizedDescription = "WPhone Background Keepalive"
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
