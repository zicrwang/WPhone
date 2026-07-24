import Foundation
import UserNotifications

enum NotificationRouting {
    enum IncomingCallSoundKind: String, Identifiable {
        case alarm
        case notification

        var id: String { rawValue }
    }

    static let categoryIdentifier = "app.wephone.vpn.wechat"
    static let openWeChatActionIdentifier = "app.wephone.vpn.action.open-wechat"
    static let dismissActionIdentifier = "app.wephone.vpn.action.dismiss"
    static let destinationKey = "app.wephone.vpn.destination"
    static let incomingCallKey = "app.wephone.vpn.incoming-call-key"
    static let weChatDestination = "weixin://"
    static let bundledIncomingCallSoundName = "WPhoneIncomingCall.wav"
    static let bundledIncomingCallSoundDurationSeconds = 10.0
    static let maximumAlarmSoundDurationSeconds = 60.0
    static let maximumNotificationSoundDurationSeconds = 10.0

    private static let appGroupIdentifier = "group.3970029fa0cfcf6d.1"
    private static let alarmCustomSoundNameKey = "app.wephone.vpn.sound.alarm.custom-name"
    private static let alarmCustomSoundOriginalNameKey = "app.wephone.vpn.sound.alarm.original-name"
    private static let alarmCustomSoundDurationKey = "app.wephone.vpn.sound.alarm.duration"
    private static let alarmCustomSoundBaseName = "WPhoneCustomAlarm"
    private static let notificationCustomSoundNameKey = "app.wephone.vpn.sound.notification.custom-name"
    private static let notificationCustomSoundOriginalNameKey = "app.wephone.vpn.sound.notification.original-name"
    private static let notificationCustomSoundDurationKey = "app.wephone.vpn.sound.notification.duration"
    private static let notificationCustomSoundBaseName = "WPhoneCustomNotification"
    private static let legacyCustomSoundNameKey = "app.wephone.vpn.sound.custom-name"
    private static let legacyCustomSoundOriginalNameKey = "app.wephone.vpn.sound.original-name"
    private static let legacyCustomSoundDurationKey = "app.wephone.vpn.sound.duration"
    private static let legacyCustomSoundBaseName = "WPhoneCustomIncomingCall"
    private static let splitSoundMigrationKey = "app.wephone.vpn.sound.split-migration-version"
    private static let supportedSoundExtensions = ["wav", "caf", "aiff"]
    private static let migrationLock = NSLock()

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

    static var incomingCallAlarmSoundName: String {
        incomingCallSoundName(for: .alarm)
    }

    static var incomingCallNotificationSoundName: String {
        incomingCallSoundName(for: .notification)
    }

    static func incomingCallSoundName(for kind: IncomingCallSoundKind) -> String {
        selectedCustomSoundName(for: kind) ?? bundledIncomingCallSoundName
    }

    static func isUsingCustomIncomingCallSound(_ kind: IncomingCallSoundKind) -> Bool {
        selectedCustomSoundName(for: kind) != nil
    }

    static func incomingCallSoundOriginalName(
        for kind: IncomingCallSoundKind
    ) -> String? {
        guard isUsingCustomIncomingCallSound(kind) else { return nil }
        return sharedDefaults?.string(forKey: originalNameKey(for: kind))
    }

    static func incomingCallSoundDurationSeconds(
        for kind: IncomingCallSoundKind
    ) -> Double {
        guard isUsingCustomIncomingCallSound(kind) else {
            return bundledIncomingCallSoundDurationSeconds
        }
        let duration = sharedDefaults?.double(forKey: durationKey(for: kind)) ?? 0
        return duration > 0 ? duration : bundledIncomingCallSoundDurationSeconds
    }

    static func maximumIncomingCallSoundDurationSeconds(
        for kind: IncomingCallSoundKind
    ) -> Double {
        switch kind {
        case .alarm: maximumAlarmSoundDurationSeconds
        case .notification: maximumNotificationSoundDurationSeconds
        }
    }

    static func hasIncomingCallSound(
        _ kind: IncomingCallSoundKind,
        in bundle: Bundle = .main
    ) -> Bool {
        soundURL(named: incomingCallSoundName(for: kind), in: bundle) != nil
            || soundURL(named: bundledIncomingCallSoundName, in: bundle) != nil
    }

    static func incomingCallAlarmSoundNameForScheduling(
        in bundle: Bundle = .main
    ) -> String? {
        if currentExecutableSoundURL(named: incomingCallAlarmSoundName, in: bundle) != nil {
            return incomingCallAlarmSoundName
        }
        if currentExecutableSoundURL(named: bundledIncomingCallSoundName, in: bundle) != nil {
            return bundledIncomingCallSoundName
        }
        return nil
    }

    static func incomingCallNotificationSound(
        in bundle: Bundle = .main
    ) -> UNNotificationSound {
        if soundURL(named: incomingCallNotificationSoundName, in: bundle) != nil {
            return UNNotificationSound(
                named: UNNotificationSoundName(rawValue: incomingCallNotificationSoundName)
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
        duration: Double,
        for kind: IncomingCallSoundKind
    ) throws -> String {
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard supportedSoundExtensions.contains(fileExtension) else {
            throw SoundStorageError.unsupportedFileType
        }
        let directory = try sharedSoundsDirectory()
        let destinationName = "\(customSoundBaseName(for: kind)).\(fileExtension)"
        let destinationURL = directory.appendingPathComponent(destinationName)
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        try data.write(to: destinationURL, options: .atomic)

        removeCustomSoundFiles(for: kind, except: destinationName, from: directory)
        sharedDefaults?.set(destinationName, forKey: nameKey(for: kind))
        sharedDefaults?.set(originalName, forKey: originalNameKey(for: kind))
        sharedDefaults?.set(duration, forKey: durationKey(for: kind))
        sharedDefaults?.synchronize()
        if kind == .alarm {
            try prepareIncomingCallAlarmSoundForCurrentContainer()
        }
        return destinationName
    }

    static func restoreBundledIncomingCallSound(
        for kind: IncomingCallSoundKind
    ) throws {
        if let directory = try? sharedSoundsDirectory() {
            removeCustomSoundFiles(for: kind, except: nil, from: directory)
        }
        if let directory = try? currentSoundsDirectory() {
            removeCustomSoundFiles(for: kind, except: nil, from: directory)
        }
        sharedDefaults?.removeObject(forKey: nameKey(for: kind))
        sharedDefaults?.removeObject(forKey: originalNameKey(for: kind))
        sharedDefaults?.removeObject(forKey: durationKey(for: kind))
        sharedDefaults?.synchronize()
    }

    @discardableResult
    static func prepareIncomingCallAlarmSoundForCurrentContainer() throws -> String {
        guard let customName = selectedCustomSoundName(for: .alarm),
              let sourceURL = sharedSoundURL(named: customName) else {
            if let directory = try? currentSoundsDirectory() {
                removeCustomSoundFiles(for: .alarm, except: nil, from: directory)
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
            for: .alarm,
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

    private static func selectedCustomSoundName(
        for kind: IncomingCallSoundKind
    ) -> String? {
        migrateLegacySoundPreferenceIfNeeded()
        guard let name = sharedDefaults?.string(forKey: nameKey(for: kind)),
              name == URL(fileURLWithPath: name).lastPathComponent,
              name.hasPrefix("\(customSoundBaseName(for: kind))."),
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
        for kind: IncomingCallSoundKind,
        except preservedName: String?,
        from directory: URL
    ) {
        for fileExtension in supportedSoundExtensions {
            let name = "\(customSoundBaseName(for: kind)).\(fileExtension)"
            guard name != preservedName else { continue }
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(name)
            )
        }
    }

    private static func migrateLegacySoundPreferenceIfNeeded() {
        migrationLock.lock()
        defer { migrationLock.unlock() }
        guard let defaults = sharedDefaults,
              defaults.integer(forKey: splitSoundMigrationKey) < 1 else {
            return
        }
        guard let legacyName = defaults.string(forKey: legacyCustomSoundNameKey) else {
            defaults.set(1, forKey: splitSoundMigrationKey)
            defaults.synchronize()
            return
        }
        guard
              legacyName == URL(fileURLWithPath: legacyName).lastPathComponent,
              legacyName.hasPrefix("\(legacyCustomSoundBaseName)."),
              supportedSoundExtensions.contains(
                URL(fileURLWithPath: legacyName).pathExtension.lowercased()
              ) else {
            defaults.set(1, forKey: splitSoundMigrationKey)
            defaults.synchronize()
            return
        }
        guard
              let legacyURL = sharedSoundURL(named: legacyName),
              let data = try? Data(contentsOf: legacyURL, options: .mappedIfSafe),
              let directory = try? sharedSoundsDirectory() else {
            return
        }

        let fileExtension = legacyURL.pathExtension.lowercased()
        let originalName = defaults.string(forKey: legacyCustomSoundOriginalNameKey)
            ?? legacyName
        let duration = defaults.double(forKey: legacyCustomSoundDurationKey)
        for kind in [IncomingCallSoundKind.alarm, .notification] {
            let destinationName = "\(customSoundBaseName(for: kind)).\(fileExtension)"
            let destinationURL = directory.appendingPathComponent(destinationName)
            guard (try? data.write(to: destinationURL, options: .atomic)) != nil else {
                return
            }
            defaults.set(destinationName, forKey: nameKey(for: kind))
            defaults.set(originalName, forKey: originalNameKey(for: kind))
            defaults.set(duration, forKey: durationKey(for: kind))
        }
        defaults.set(1, forKey: splitSoundMigrationKey)
        defaults.synchronize()
    }

    private static func nameKey(for kind: IncomingCallSoundKind) -> String {
        switch kind {
        case .alarm: alarmCustomSoundNameKey
        case .notification: notificationCustomSoundNameKey
        }
    }

    private static func originalNameKey(for kind: IncomingCallSoundKind) -> String {
        switch kind {
        case .alarm: alarmCustomSoundOriginalNameKey
        case .notification: notificationCustomSoundOriginalNameKey
        }
    }

    private static func durationKey(for kind: IncomingCallSoundKind) -> String {
        switch kind {
        case .alarm: alarmCustomSoundDurationKey
        case .notification: notificationCustomSoundDurationKey
        }
    }

    private static func customSoundBaseName(for kind: IncomingCallSoundKind) -> String {
        switch kind {
        case .alarm: alarmCustomSoundBaseName
        case .notification: notificationCustomSoundBaseName
        }
    }
}
