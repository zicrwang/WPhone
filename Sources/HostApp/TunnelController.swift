import AlarmKit
import AVFoundation
import Combine
import Foundation
import NetworkExtension
import UserNotifications

@MainActor
final class TunnelController: NSObject, ObservableObject {
    static let providerBundleIdentifier = "app.wephone.vpn.PacketTunnel"
    static let appGroupIdentifier = "group.3970029fa0cfcf6d.1"
    static let defaultRelayHost = "192.168.2.99"
    static let defaultRelayPort: UInt16 = 18081

    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var lastError: String?
    @Published private(set) var alarmTestStatus = "Not tested"
    @Published private(set) var alarmAuthorizationStatus = "unknown"
    @Published private(set) var notificationTimeSensitiveStatus = "unknown"
    @Published private(set) var notificationBannerStyle = "unknown"
    @Published private(set) var alarmSoundStatus = "内置铃声 · 10秒"
    @Published private(set) var notificationSoundStatus = "内置铃声 · 10秒"
    @Published private(set) var incomingCallSoundError: String?
    @Published private(set) var incomingCallSoundErrorKind: NotificationRouting.IncomingCallSoundKind?
    @Published var relayHost = TunnelController.defaultRelayHost
    @Published var relayPort = String(TunnelController.defaultRelayPort)

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var alarmTestTimeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.status = self.manager?.connection.status ?? .invalid
            }
        }
    }

    deinit {
        alarmTestTimeoutTask?.cancel()
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
            await refreshNotificationSettings()
        } catch {
            lastError = error.localizedDescription
            SharedLogger.shared.error("Notification authorization failed: \(error.localizedDescription)")
        }
    }

    func refreshNotificationSettings() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.timeSensitiveSetting {
        case .notSupported: notificationTimeSensitiveStatus = "不支持"
        case .disabled: notificationTimeSensitiveStatus = "已关闭"
        case .enabled: notificationTimeSensitiveStatus = "已开启"
        @unknown default: notificationTimeSensitiveStatus = "未知"
        }
        switch settings.alertStyle {
        case .none: notificationBannerStyle = "无"
        case .banner: notificationBannerStyle = "临时"
        case .alert: notificationBannerStyle = "持续"
        @unknown default: notificationBannerStyle = "未知"
        }
    }

    func refreshIncomingCallSoundStatus() {
        alarmSoundStatus = incomingCallSoundStatus(for: .alarm)
        notificationSoundStatus = incomingCallSoundStatus(for: .notification)
    }

    private func incomingCallSoundStatus(
        for kind: NotificationRouting.IncomingCallSoundKind
    ) -> String {
        let duration = NotificationRouting.incomingCallSoundDurationSeconds(for: kind)
        let formattedDuration = duration.rounded() == duration
            ? String(Int(duration))
            : String(format: "%.1f", duration)
        if let originalName = NotificationRouting.incomingCallSoundOriginalName(for: kind) {
            return "\(originalName) · \(formattedDuration)秒"
        } else {
            return "内置铃声 · \(formattedDuration)秒"
        }
    }

    func installIncomingCallSound(
        from url: URL,
        for kind: NotificationRouting.IncomingCallSoundKind
    ) async {
        incomingCallSoundError = nil
        incomingCallSoundErrorKind = kind
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let fileExtension = url.pathExtension.lowercased()
            guard ["wav", "caf", "aiff"].contains(fileExtension) else {
                throw IncomingCallSoundImportError.unsupportedFileType
            }
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if let fileSize = values.fileSize, fileSize > 20 * 1_024 * 1_024 {
                throw IncomingCallSoundImportError.fileTooLarge
            }

            let audioFile = try AVAudioFile(forReading: url)
            let settings = audioFile.fileFormat.settings
            let formatID = (settings[AVFormatIDKey] as? NSNumber)?.uint32Value
            let supportedFormatIDs: Set<UInt32> = [
                kAudioFormatLinearPCM,
                kAudioFormatAppleIMA4,
                kAudioFormatULaw,
                kAudioFormatALaw
            ]
            guard let formatID, supportedFormatIDs.contains(formatID) else {
                throw IncomingCallSoundImportError.unsupportedEncoding
            }
            let sampleRate = audioFile.processingFormat.sampleRate
            let durationSeconds = sampleRate > 0
                ? Double(audioFile.length) / sampleRate
                : 0
            guard durationSeconds.isFinite, durationSeconds > 0 else {
                throw IncomingCallSoundImportError.unreadableAudio
            }
            let maximumDuration = NotificationRouting.maximumIncomingCallSoundDurationSeconds(
                for: kind
            )
            guard durationSeconds <= maximumDuration + 0.02 else {
                throw IncomingCallSoundImportError.tooLong(
                    maximumSeconds: Int(maximumDuration)
                )
            }

            _ = try NotificationRouting.installCustomIncomingCallSound(
                from: url,
                originalName: url.lastPathComponent,
                duration: durationSeconds,
                for: kind
            )
            refreshIncomingCallSoundStatus()
            incomingCallSoundErrorKind = nil
            SharedLogger.shared.info(
                "Custom \(kind.rawValue) sound installed name=\(url.lastPathComponent) " +
                    "duration=\(String(format: "%.3f", durationSeconds))"
            )
        } catch {
            incomingCallSoundError = error.localizedDescription
            SharedLogger.shared.error(
                "Custom incoming-call sound import failed: \(error.localizedDescription)"
            )
        }
    }

    func restoreBundledIncomingCallSound(
        for kind: NotificationRouting.IncomingCallSoundKind
    ) {
        do {
            try NotificationRouting.restoreBundledIncomingCallSound(for: kind)
            incomingCallSoundError = nil
            incomingCallSoundErrorKind = nil
            refreshIncomingCallSoundStatus()
            SharedLogger.shared.info("Bundled \(kind.rawValue) sound restored")
        } catch {
            incomingCallSoundError = error.localizedDescription
            incomingCallSoundErrorKind = kind
            SharedLogger.shared.error(
                "Unable to restore bundled incoming-call sound: \(error.localizedDescription)"
            )
        }
    }

    func recordIncomingCallSoundImportError(
        _ error: Error,
        for kind: NotificationRouting.IncomingCallSoundKind
    ) {
        incomingCallSoundError = error.localizedDescription
        incomingCallSoundErrorKind = kind
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
            alarmAuthorizationStatus = stateDescription
            WPhoneAlarmStore.saveHostAuthorization(stateDescription)
            SharedLogger.shared.info("AlarmKit authorization: \(stateDescription)")
            if !isAuthorized {
                lastError = "AlarmKit permission is required for system alarm alerts."
            }
        } catch {
            alarmAuthorizationStatus = "error"
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
        let triggerDate = Date.now.addingTimeInterval(1)
        let expiresAt = triggerDate.addingTimeInterval(
            WPhoneAlarmConfiguration.maximumAlertDurationSeconds
        )
        let configuration = WPhoneAlarmConfiguration.make(
            id: id,
            caller: caller,
            callKey: callKey,
            triggerDate: triggerDate
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
                scheduledAt: Date(),
                expiresAt: expiresAt
            ))
            armAlarmKitTestTimeout(alarmID: id, expiresAt: expiresAt)
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
        alarmTestTimeoutTask?.cancel()
        alarmTestTimeoutTask = nil
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

    private func armAlarmKitTestTimeout(alarmID: UUID, expiresAt: Date) {
        alarmTestTimeoutTask?.cancel()
        let delay = max(0, expiresAt.timeIntervalSinceNow)
        alarmTestTimeoutTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(delay * 1_000_000_000)
            )
            guard !Task.isCancelled,
                  let self,
                  let record = WPhoneAlarmStore.activeAlarm(),
                  record.id == alarmID else {
                return
            }
            try? AlarmManager.shared.stop(id: alarmID)
            try? AlarmManager.shared.cancel(id: alarmID)
            WPhoneAlarmStore.removeNotification(for: record)
            WPhoneAlarmStore.clear(alarmID: alarmID)
            alarmTestStatus = "Timed out (50s)"
            alarmTestTimeoutTask = nil
            SharedLogger.shared.info(
                "Main app AlarmKit alarm auto-stopped after 50 seconds id=\(alarmID.uuidString)"
            )
        }
    }

    func load() async {
        refreshIncomingCallSoundStatus()
        do {
            let managers = try await loadManagers()
            manager = managers.first { current in
                (current.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == Self.providerBundleIdentifier
            }
            if let configuration = manager?.protocolConfiguration as? NETunnelProviderProtocol,
               let values = configuration.providerConfiguration {
                if let savedHost = values["relayHost"] as? String, !savedHost.isEmpty {
                    relayHost = savedHost
                }
                if let savedPort = values["relayPort"] as? NSNumber {
                    relayPort = String(savedPort.uint16Value)
                }
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
        let normalizedHost = relayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty, normalizedHost.count <= 255 else {
            throw RelayConfigurationError.invalidHost
        }
        guard let parsedPort = UInt16(relayPort), parsedPort > 0 else {
            throw RelayConfigurationError.invalidPort
        }

        let managers = try await loadManagers()
        let manager = managers.first { current in
            guard let configuration = current.protocolConfiguration as? NETunnelProviderProtocol else {
                return false
            }
            return configuration.providerBundleIdentifier == Self.providerBundleIdentifier
        } ?? NETunnelProviderManager()

        let configuration = NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = Self.providerBundleIdentifier
        configuration.serverAddress = "WPhone relay \(normalizedHost):\(parsedPort)"
        configuration.providerConfiguration = [
            "listenerPort": 8080,
            "accessPolicy": "privateLANOverWiFi",
            "relayHost": normalizedHost,
            "relayPort": NSNumber(value: parsedPort),
            "relayDeviceID": Self.relayDeviceID()
        ]

        manager.protocolConfiguration = configuration
        manager.localizedDescription = "WPhone Background Keepalive"
        manager.isEnabled = true
        return manager
    }

    private static func relayDeviceID() -> String {
        let key = "app.wephone.vpn.relay.device-id"
        let defaults = UserDefaults(suiteName: appGroupIdentifier)
        if let saved = defaults?.string(forKey: key), !saved.isEmpty {
            return saved
        }
        let created = UUID().uuidString
        defaults?.set(created, forKey: key)
        return created
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

private enum RelayConfigurationError: LocalizedError {
    case invalidHost
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            return "中继站地址不能为空。"
        case .invalidPort:
            return "中继站端口必须是 1 到 65535。"
        }
    }
}

private enum IncomingCallSoundImportError: LocalizedError {
    case unsupportedFileType
    case unsupportedEncoding
    case fileTooLarge
    case unreadableAudio
    case tooLong(maximumSeconds: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
            return "仅支持 WAV、CAF 或 AIFF 铃声。"
        case .unsupportedEncoding:
            return "铃声必须使用 Linear PCM、IMA4、µLaw 或 aLaw 编码。"
        case .fileTooLarge:
            return "铃声文件不能超过 20 MB。"
        case .unreadableAudio:
            return "无法读取该音频文件。"
        case .tooLong(let maximumSeconds):
            return "自定义铃声不能超过 \(maximumSeconds) 秒。"
        }
    }
}
