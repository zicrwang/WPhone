import AlarmKit
import AppIntents
import Foundation
import SwiftUI

struct WPhoneAlarmMetadata: AlarmMetadata {
    let caller: String
    let callKey: String
}

struct WPhoneAlarmRecord: Codable {
    let id: UUID
    let callKey: String
    let caller: String
    let scheduledAt: Date
}

enum WPhoneAlarmStore {
    static let appGroupIdentifier = "group.3970029fa0cfcf6d.1"

    private static let activeAlarmKey = "app.wephone.vpn.alarm.active"
    private static let pendingOpenKey = "app.wephone.vpn.alarm.pending-open"
    private static let hostAuthorizationKey = "app.wephone.vpn.alarm.host-authorization"
    private static let hostAuthorizationUpdatedAtKey = "app.wephone.vpn.alarm.host-authorization-updated-at"
    private static let lock = NSLock()

    static func activeAlarm() -> WPhoneAlarmRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults?.data(forKey: activeAlarmKey) else { return nil }
        return try? JSONDecoder().decode(WPhoneAlarmRecord.self, from: data)
    }

    static func save(_ record: WPhoneAlarmRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        lock.lock()
        defaults?.set(data, forKey: activeAlarmKey)
        lock.unlock()
    }

    static func clear(alarmID: UUID? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let alarmID,
           let data = defaults?.data(forKey: activeAlarmKey),
           let record = try? JSONDecoder().decode(WPhoneAlarmRecord.self, from: data),
           record.id != alarmID {
            return
        }
        defaults?.removeObject(forKey: activeAlarmKey)
    }

    static func markPendingOpen() {
        lock.lock()
        defaults?.set(true, forKey: pendingOpenKey)
        lock.unlock()
    }

    static func consumePendingOpen() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard defaults?.bool(forKey: pendingOpenKey) == true else { return false }
        defaults?.removeObject(forKey: pendingOpenKey)
        return true
    }

    static func saveHostAuthorization(_ value: String) {
        lock.lock()
        let sharedDefaults = defaults
        sharedDefaults?.set(value, forKey: hostAuthorizationKey)
        sharedDefaults?.set(Date(), forKey: hostAuthorizationUpdatedAtKey)
        sharedDefaults?.synchronize()
        lock.unlock()
    }

    static func hostAuthorization() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return defaults?.string(forKey: hostAuthorizationKey)
    }

    static func hostAuthorizationUpdatedAt() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return defaults?.object(forKey: hostAuthorizationUpdatedAtKey) as? Date
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }
}

enum WPhoneAlarmConfiguration {
    typealias Configuration = AlarmManager.AlarmConfiguration<WPhoneAlarmMetadata>

    static func make(
        id: UUID,
        caller: String,
        callKey: String,
        triggerDate: Date
    ) -> Configuration {
        let title = LocalizedStringResource(stringLiteral: caller.isEmpty ? "微信来电" : caller)
        let stopButton = AlarmButton(
            text: "拒绝",
            textColor: .white,
            systemImageName: "xmark.circle.fill"
        )
        let openButton = AlarmButton(
            text: "接听",
            textColor: .white,
            systemImageName: "arrow.up.forward.app.fill"
        )
        let alert = AlarmPresentation.Alert(
            title: title,
            stopButton: stopButton,
            secondaryButton: openButton,
            secondaryButtonBehavior: .custom
        )
        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: alert),
            metadata: WPhoneAlarmMetadata(caller: caller, callKey: callKey),
            tintColor: Color.green
        )
        return Configuration(
            schedule: .fixed(triggerDate),
            attributes: attributes,
            stopIntent: WPhoneStopAlarmIntent(alarmID: id.uuidString),
            secondaryIntent: WPhoneOpenAlarmIntent(alarmID: id.uuidString)
        )
    }
}

enum WPhoneAlarmDiagnostics {
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        var fields = [
            "domain=\(nsError.domain)",
            "code=\(nsError.code)",
            "description=\(nsError.localizedDescription)"
        ]
        if let reason = nsError.localizedFailureReason, !reason.isEmpty {
            fields.append("reason=\(reason)")
        }
        if let suggestion = nsError.localizedRecoverySuggestion, !suggestion.isEmpty {
            fields.append("recovery=\(suggestion)")
        }
        let userInfo = nsError.userInfo
            .filter { $0.key != NSLocalizedDescriptionKey }
            .map { "\($0.key)=\(String(describing: $0.value))" }
            .sorted()
        if !userInfo.isEmpty {
            fields.append("userInfo={\(userInfo.joined(separator: ", "))}")
        }
        return fields.joined(separator: "; ")
    }
}

struct WPhoneStopAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "拒绝"
    static var description = IntentDescription("拒绝 WPhone 来电提醒")

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    init() {
        alarmID = ""
    }

    func perform() throws -> some IntentResult {
        guard let id = UUID(uuidString: alarmID) else { return .result() }
        try? AlarmManager.shared.stop(id: id)
        try? AlarmManager.shared.cancel(id: id)
        WPhoneAlarmStore.clear(alarmID: id)
        return .result()
    }
}

struct WPhoneOpenAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "接听"
    static var description = IntentDescription("停止提醒并打开微信")
    static var openAppWhenRun = true

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    init() {
        alarmID = ""
    }

    func perform() throws -> some IntentResult {
        guard let id = UUID(uuidString: alarmID) else { return .result() }
        WPhoneAlarmStore.markPendingOpen()
        try? AlarmManager.shared.stop(id: id)
        try? AlarmManager.shared.cancel(id: id)
        WPhoneAlarmStore.clear(alarmID: id)
        return .result()
    }
}
