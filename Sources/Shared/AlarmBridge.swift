import AlarmKit
import AppIntents
import Foundation

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

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }
}

struct WPhoneStopAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "关闭"
    static var description = IntentDescription("关闭 WPhone 来电提醒")

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
    static var title: LocalizedStringResource = "打开"
    static var description = IntentDescription("关闭提醒并打开微信")
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
