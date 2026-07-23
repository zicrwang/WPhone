import Combine
import Foundation
import NetworkExtension

final class LocalPushController: NSObject, ObservableObject, NEAppPushDelegate {
    static let shared = LocalPushController()
    static let providerBundleIdentifier = "app.wephone.vpn.AppPushProvider"

    @Published var ssid = ""
    @Published var host = ""
    @Published var portText = "8081"
    @Published private(set) var isEnabled = false
    @Published private(set) var isActive = false
    @Published private(set) var statusText = "Not configured"
    @Published private(set) var lastError: String?

    private let log = SharedLogger.shared
    private let deviceID: String
    private var manager: NEAppPushManager?
    private var activeObservation: NSKeyValueObservation?
    private var initialized = false

    private override init() {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: "localPushDeviceID") {
            deviceID = existing
        } else {
            let newID = UUID().uuidString
            defaults.set(newID, forKey: "localPushDeviceID")
            deviceID = newID
        }
        super.init()
    }

    func initialize() {
        guard !initialized else { return }
        initialized = true
        statusText = "Loading"
        NEAppPushManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async {
                    self.initialized = false
                    self.lastError = error.localizedDescription
                    self.statusText = "Load failed"
                }
                self.log.error("Local Push configuration load failed: \(error.localizedDescription)")
                return
            }

            let manager = managers?.first {
                $0.providerBundleIdentifier == Self.providerBundleIdentifier
            }
            manager?.delegate = self
            DispatchQueue.main.async {
                if let manager {
                    self.prepare(manager)
                } else {
                    self.statusText = "Not configured"
                }
            }
        }
    }

    func saveAndEnable() {
        let normalizedSSID = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSSID.isEmpty else {
            lastError = "Wi-Fi SSID is required"
            return
        }
        guard !normalizedHost.isEmpty else {
            lastError = "Relay host is required"
            return
        }
        guard let portValue = UInt16(portText), portValue > 0 else {
            lastError = "Relay port must be between 1 and 65535"
            return
        }

        let manager = manager ?? NEAppPushManager()
        self.manager = manager
        manager.localizedDescription = "WPhone Local Push"
        manager.providerBundleIdentifier = Self.providerBundleIdentifier
        manager.providerConfiguration = [
            "host": normalizedHost,
            "port": NSNumber(value: portValue),
            "deviceID": deviceID
        ]
        manager.matchSSIDs = [normalizedSSID]
        manager.isEnabled = true
        manager.delegate = self
        statusText = "Saving"
        lastError = nil

        manager.saveToPreferences { [weak self, weak manager] error in
            guard let self, let manager else { return }
            if let error {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    self.statusText = "Save failed"
                }
                self.log.error("Local Push configuration save failed: \(error.localizedDescription)")
                return
            }
            manager.loadFromPreferences { [weak self, weak manager] reloadError in
                guard let self, let manager else { return }
                DispatchQueue.main.async {
                    if let reloadError {
                        self.lastError = reloadError.localizedDescription
                        self.statusText = "Reload failed"
                        self.log.error(
                            "Local Push configuration reload failed: \(reloadError.localizedDescription)"
                        )
                    } else {
                        manager.delegate = self
                        self.prepare(manager)
                        self.log.info(
                            "Local Push enabled ssid=\(normalizedSSID) relay=\(normalizedHost):\(portValue)"
                        )
                    }
                }
            }
        }
    }

    func disable() {
        guard let manager else { return }
        manager.isEnabled = false
        statusText = "Saving"
        lastError = nil
        manager.saveToPreferences { [weak self, weak manager] error in
            guard let self, let manager else { return }
            DispatchQueue.main.async {
                if let error {
                    self.lastError = error.localizedDescription
                    self.statusText = "Save failed"
                    self.log.error("Local Push disable failed: \(error.localizedDescription)")
                } else {
                    self.prepare(manager)
                    self.log.info("Local Push disabled")
                }
            }
        }
    }

    func appPushManager(
        _ manager: NEAppPushManager,
        didReceiveIncomingCallWithUserInfo userInfo: [AnyHashable: Any] = [:]
    ) {
        guard let source = userInfo["source"] as? String,
              let eventID = userInfo["eventID"] as? String,
              let caller = userInfo["caller"] as? String,
              let notificationIdentifier = userInfo["notificationIdentifier"] as? String else {
            log.error("Local Push incoming call is missing required userInfo")
            return
        }
        let hasVideo = userInfo["hasVideo"] as? Bool ?? false
        log.info("Local Push manager delivered incoming call source=\(source) id=\(eventID)")
        HostCallKitCoordinator.shared.receiveLocalPushIncomingCall(
            key: "\(source):\(eventID)",
            caller: caller,
            hasVideo: hasVideo,
            notificationIdentifier: notificationIdentifier
        )
    }

    private func prepare(_ manager: NEAppPushManager) {
        self.manager = manager
        manager.delegate = self
        isEnabled = manager.isEnabled
        isActive = manager.isActive
        statusText = manager.isActive ? "Active" : (manager.isEnabled ? "Waiting for Wi-Fi" : "Disabled")
        ssid = manager.matchSSIDs.first ?? ssid
        let configuration = manager.providerConfiguration
        host = configuration["host"] as? String ?? host
        if let port = configuration["port"] as? NSNumber {
            portText = String(port.uint16Value)
        }
        activeObservation = manager.observe(\.isActive, options: [.initial, .new]) {
            [weak self] manager, _ in
            DispatchQueue.main.async {
                self?.isActive = manager.isActive
                self?.isEnabled = manager.isEnabled
                self?.statusText = manager.isActive
                    ? "Active"
                    : (manager.isEnabled ? "Waiting for Wi-Fi" : "Disabled")
            }
        }
    }
}
