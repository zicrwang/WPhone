import Foundation
import UserNotifications

enum NotificationRouting {
    static let categoryIdentifier = "app.wephone.vpn.wechat"
    static let openWeChatActionIdentifier = "app.wephone.vpn.action.open-wechat"
    static let dismissActionIdentifier = "app.wephone.vpn.action.dismiss"
    static let destinationKey = "app.wephone.vpn.destination"
    static let incomingCallKey = "app.wephone.vpn.incoming-call-key"
    static let weChatDestination = "weixin://"
    static let bundledIncomingCallSoundName = "WPhoneIncomingCall.wav"
    static let maximumIncomingCallSoundDurationSeconds = 10.0

    private static let appGroupIdentifier = "group.3970029fa0cfcf6d.1"
    private static let customSoundNameKey = "app.wephone.vpn.sound.custom-name"
    private static let customSoundOriginalNameKey = "app.wephone.vpn.sound.original-name"
    private static let customSoundDurationKey = "app.wephone.vpn.sound.duration"
    private static let customSoundBaseName = "WPhoneCustomIncomingCall"
    private static let supportedSoundExtensions = ["wav", "caf", "aiff"]

    enum SoundStorageError: LocalizedError {
        case sharedContainerUnavailable
        case unsupportedFileType

        var errorDescription: String? {
            switch self {
            case .sharedContainerUnavailable:
                return "无法访问 App Group 铃声目录"
            case .unsupportedFileType:
                return "仅支持 WAV、CAF 或 AIFF 铃声"
            }
        }
    }

    static var incomingCallSoundName: String {
        selectedCustomSoundName ?? bundledIncomingCallSoundName
    }

    static var isUsingCustomIncomingCallSound: Bool {
        selectedCustomSoundName != nil
    }

    static var incomingCallSoundOriginalName: String? {
        guard isUsingCustomIncomingCallSound else { return nil }
        return sharedDefaults?.string(forKey: customSoundOriginalNameKey)
    }

    static var incomingCallSoundDurationSeconds: Double {
        guard isUsingCustomIncomingCallSound else {
            return maximumIncomingCallSoundDurationSeconds
        }
        let duration = sharedDefaults?.double(forKey: customSoundDurationKey) ?? 0
        return duration > 0 ? duration : maximumIncomingCallSoundDurationSeconds
    }

    static func hasIncomingCallSound(in bundle: Bundle = .main) -> Bool {
        soundURL(named: incomingCallSoundName, in: bundle) != nil
            || soundURL(named: bundledIncomingCallSoundName, in: bundle) != nil
    }

    static func incomingCallAlarmSoundName(in bundle: Bundle = .main) -> String? {
        if currentExecutableSoundURL(named: incomingCallSoundName, in: bundle) != nil {
            return incomingCallSoundName
        }
        if currentExecutableSoundURL(named: bundledIncomingCallSoundName, in: bundle) != nil {
            return bundledIncomingCallSoundName
        }
        return nil
    }

    static func incomingCallNotificationSound(
        in bundle: Bundle = .main
    ) -> UNNotificationSound {
        if soundURL(named: incomingCallSoundName, in: bundle) != nil {
            return UNNotificationSound(
                named: UNNotificationSoundName(rawValue: incomingCallSoundName)
            )
        }
        if soundURL(named: bundledIncomingCallSoundName, in: bundle) != nil {
            return UNNotificationSound(
                named: UNNotificationSoundName(rawValue: bundledIncomingCallSoundName)
            )
        }
        return .default
    }

    @discardableResult
    static func installCustomIncomingCallSound(
        from sourceURL: URL,
        originalName: String,
        duration: Double
    ) throws -> String {
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard supportedSoundExtensions.contains(fileExtension) else {
            throw SoundStorageError.unsupportedFileType
        }
        let directory = try sharedSoundsDirectory()
        let destinationName = "\(customSoundBaseName).\(fileExtension)"
        let destinationURL = directory.appendingPathComponent(destinationName)
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        try data.write(to: destinationURL, options: .atomic)

        removeCustomSoundFiles(except: destinationName, from: directory)
        sharedDefaults?.set(destinationName, forKey: customSoundNameKey)
        sharedDefaults?.set(originalName, forKey: customSoundOriginalNameKey)
        sharedDefaults?.set(duration, forKey: customSoundDurationKey)
        sharedDefaults?.synchronize()
        try prepareIncomingCallSoundForCurrentContainer()
        return destinationName
    }

    static func restoreBundledIncomingCallSound() throws {
        if let directory = try? sharedSoundsDirectory() {
            removeCustomSoundFiles(except: nil, from: directory)
        }
        if let directory = try? currentSoundsDirectory() {
            removeCustomSoundFiles(except: nil, from: directory)
        }
        sharedDefaults?.removeObject(forKey: customSoundNameKey)
        sharedDefaults?.removeObject(forKey: customSoundOriginalNameKey)
        sharedDefaults?.removeObject(forKey: customSoundDurationKey)
        sharedDefaults?.synchronize()
    }

    @discardableResult
    static func prepareIncomingCallSoundForCurrentContainer() throws -> String {
        guard let customName = selectedCustomSoundName,
              let sourceURL = sharedSoundURL(named: customName) else {
            if let directory = try? currentSoundsDirectory() {
                removeCustomSoundFiles(except: nil, from: directory)
            }
            return bundledIncomingCallSoundName
        }

        let destinationURL = try currentSoundsDirectory()
            .appendingPathComponent(customName)
        let sourceData = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        if (try? Data(contentsOf: destinationURL, options: .mappedIfSafe)) != sourceData {
            try sourceData.write(to: destinationURL, options: .atomic)
        }
        removeCustomSoundFiles(
            except: customName,
            from: destinationURL.deletingLastPathComponent()
        )
        return customName
    }

    static func registerCategories(on center: UNUserNotificationCenter = .current()) {
        let openWeChat = UNNotificationAction(
            identifier: openWeChatActionIdentifier,
            title: "打开",
            options: [.foreground]
        )
        let dismiss = UNNotificationAction(
            identifier: dismissActionIdentifier,
            title: "关闭",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [openWeChat, dismiss],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "微信通知",
            options: [.customDismissAction]
        )
        center.setNotificationCategories([category])
    }

    static func routeToWeChat(_ content: UNMutableNotificationContent) {
        content.categoryIdentifier = categoryIdentifier
        content.userInfo[destinationKey] = weChatDestination
    }

    static func routeIncomingCallToWeChat(
        _ content: UNMutableNotificationContent,
        callKey: String
    ) {
        routeToWeChat(content)
        content.userInfo[incomingCallKey] = callKey
    }

    static func incomingCallKey(from content: UNNotificationContent) -> String? {
        content.userInfo[incomingCallKey] as? String
    }

    static func destination(from content: UNNotificationContent) -> URL? {
        guard let rawValue = content.userInfo[destinationKey] as? String,
              rawValue == weChatDestination else {
            return nil
        }
        return URL(string: rawValue)
    }

    private static var selectedCustomSoundName: String? {
        guard let name = sharedDefaults?.string(forKey: customSoundNameKey),
              name == URL(fileURLWithPath: name).lastPathComponent,
              name.hasPrefix("\(customSoundBaseName)."),
              supportedSoundExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased()),
              sharedSoundURL(named: name) != nil else {
            return nil
        }
        return name
    }

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    private static func soundURL(named name: String, in bundle: Bundle) -> URL? {
        currentExecutableSoundURL(named: name, in: bundle)
            ?? sharedSoundURL(named: name)
    }

    private static func currentExecutableSoundURL(
        named name: String,
        in bundle: Bundle
    ) -> URL? {
        let fileURL = URL(fileURLWithPath: name)
        if let bundledURL = bundle.url(
            forResource: fileURL.deletingPathExtension().lastPathComponent,
            withExtension: fileURL.pathExtension
        ) {
            return bundledURL
        }
        guard let directory = try? currentSoundsDirectory() else { return nil }
        let candidate = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private static func sharedSoundURL(named name: String) -> URL? {
        guard let directory = try? sharedSoundsDirectory() else { return nil }
        let candidate = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private static func sharedSoundsDirectory() throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw SoundStorageError.sharedContainerUnavailable
        }
        let directory = container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func currentSoundsDirectory() throws -> URL {
        guard let library = FileManager.default.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first else {
            throw SoundStorageError.sharedContainerUnavailable
        }
        let directory = library.appendingPathComponent("Sounds", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func removeCustomSoundFiles(
        except preservedName: String?,
        from directory: URL
    ) {
        for fileExtension in supportedSoundExtensions {
            let name = "\(customSoundBaseName).\(fileExtension)"
            guard name != preservedName else { continue }
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(name)
            )
        }
    }
}
