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
    @Published private(set) var notificationTimeSensitiveStatus = "unknown"
    @Published private(set) var notificationBannerStyle = "unknown"
    @Published private(set) var incomingCallSoundStatus = "内置铃声 · 10秒"
    @Published private(set) var incomingCallSoundError: String?
    @Published var relayHost = TunnelController.defaultRelayHost
    @Published var relayPort = String(TunnelController.defaultRelayPort)

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

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
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    func requestNotificationAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge, .timeSensitive]
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
        let duration = NotificationRouting.incomingCallSoundDurationSeconds
        let formattedDuration = duration.rounded() == duration
            ? String(Int(duration))
            : String(format: "%.1f", duration)
        if let originalName = NotificationRouting.incomingCallSoundOriginalName {
            incomingCallSoundStatus = "\(originalName) · \(formattedDuration)秒"
        } else {
            incomingCallSoundStatus = "内置铃声 · \(formattedDuration)秒"
        }
    }

    func installIncomingCallSound(from url: URL) async {
        incomingCallSoundError = nil
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
            let maximumDuration = NotificationRouting.maximumIncomingCallSoundDurationSeconds
            guard durationSeconds <= maximumDuration else {
                throw IncomingCallSoundImportError.tooLong(
                    maximumSeconds: Int(maximumDuration)
                )
            }

            _ = try NotificationRouting.installCustomIncomingCallSound(
                from: url,
                originalName: url.lastPathComponent,
                duration: durationSeconds
            )
            refreshIncomingCallSoundStatus()
            SharedLogger.shared.info(
                "Custom incoming-call sound installed name=\(url.lastPathComponent) " +
                    "duration=\(String(format: "%.3f", durationSeconds))"
            )
        } catch {
            incomingCallSoundError = error.localizedDescription
            SharedLogger.shared.error(
                "Custom incoming-call sound import failed: \(error.localizedDescription)"
            )
        }
    }

    func restoreBundledIncomingCallSound() {
        do {
            try NotificationRouting.restoreBundledIncomingCallSound()
            incomingCallSoundError = nil
            refreshIncomingCallSoundStatus()
            SharedLogger.shared.info("Bundled incoming-call sound restored")
        } catch {
            incomingCallSoundError = error.localizedDescription
            SharedLogger.shared.error(
                "Unable to restore bundled incoming-call sound: \(error.localizedDescription)"
            )
        }
    }

    func recordIncomingCallSoundImportError(_ error: Error) {
        incomingCallSoundError = error.localizedDescription
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
