import CoreFoundation
import Foundation

struct CallKitBridgeCommand: Codable {
    enum Kind: String, Codable {
        case incoming
        case end
        case endAll
    }

    let id: String
    let kind: Kind
    let key: String?
    let caller: String?
    let hasVideo: Bool
    let action: String?
    let notificationIdentifier: String?
    let createdAt: Date

    static func incoming(
        key: String,
        caller: String,
        hasVideo: Bool,
        action: String,
        notificationIdentifier: String
    ) -> CallKitBridgeCommand {
        CallKitBridgeCommand(
            id: UUID().uuidString,
            kind: .incoming,
            key: key,
            caller: caller,
            hasVideo: hasVideo,
            action: action,
            notificationIdentifier: notificationIdentifier,
            createdAt: Date()
        )
    }

    static func end(key: String, action: String) -> CallKitBridgeCommand {
        CallKitBridgeCommand(
            id: UUID().uuidString,
            kind: .end,
            key: key,
            caller: nil,
            hasVideo: false,
            action: action,
            notificationIdentifier: nil,
            createdAt: Date()
        )
    }

    static func endAll(action: String) -> CallKitBridgeCommand {
        CallKitBridgeCommand(
            id: UUID().uuidString,
            kind: .endAll,
            key: nil,
            caller: nil,
            hasVideo: false,
            action: action,
            notificationIdentifier: nil,
            createdAt: Date()
        )
    }
}

struct CallKitBridgeState: Codable {
    var providerReady: Bool
    var lifecycle: String
    var hostApplicationState: String
    var hostUpdatedAt: Date
    var activeCallCount: Int
    var activeCallKey: String?
    var caller: String?
    var customRingtone: String?
    var lastAction: String?
    var lastActionAt: Date?
    var lastError: String?
    var processedCommandIDs: [String]

    static var initial: CallKitBridgeState {
        CallKitBridgeState(
            providerReady: false,
            lifecycle: "not-started",
            hostApplicationState: "not-running",
            hostUpdatedAt: Date(),
            activeCallCount: 0,
            activeCallKey: nil,
            caller: nil,
            customRingtone: nil,
            lastAction: nil,
            lastActionAt: nil,
            lastError: nil,
            processedCommandIDs: []
        )
    }

    func hasProcessed(_ commandID: String) -> Bool {
        processedCommandIDs.contains(commandID)
    }

    mutating func recordProcessedCommand(_ commandID: String) {
        processedCommandIDs.removeAll { $0 == commandID }
        processedCommandIDs.append(commandID)
        if processedCommandIDs.count > 32 {
            processedCommandIDs.removeFirst(processedCommandIDs.count - 32)
        }
        hostUpdatedAt = Date()
    }
}

enum CallKitBridge {
    static let notificationName = "app.wephone.vpn.callkit-command"
    static let maximumPendingCommands = 64
    static let commandLifetime: TimeInterval = 10 * 60

    private static let appGroupIdentifier = "group.3970029fa0cfcf6d.1"
    private static let commandDirectoryName = "callkit-commands"
    private static let stateFileName = "callkit-state.json"

    enum BridgeError: LocalizedError {
        case appGroupUnavailable
        case commandDirectoryUnavailable

        var errorDescription: String? {
            switch self {
            case .appGroupUnavailable:
                return "CallKit App Group container is unavailable"
            case .commandDirectoryUnavailable:
                return "CallKit command directory is unavailable"
            }
        }
    }

    static func enqueue(_ command: CallKitBridgeCommand) throws {
        let directory = try commandDirectoryURL(createIfNeeded: true)
        removeExpiredCommands(in: directory)

        let fileURL = directory
            .appendingPathComponent(command.id, isDirectory: false)
            .appendingPathExtension("json")
        try encoder().encode(command).write(to: fileURL, options: .atomic)
        trimPendingCommands(in: directory)
        postCommandNotification()
    }

    static func drainPendingCommands(now: Date = Date()) -> [CallKitBridgeCommand] {
        guard let directory = try? commandDirectoryURL(createIfNeeded: true),
              let fileURLs = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var commands: [(URL, CallKitBridgeCommand)] = []
        for fileURL in fileURLs where fileURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: fileURL),
                  let command = try? decoder().decode(CallKitBridgeCommand.self, from: data),
                  now.timeIntervalSince(command.createdAt) <= commandLifetime else {
                try? FileManager.default.removeItem(at: fileURL)
                continue
            }
            commands.append((fileURL, command))
        }

        commands.sort {
            if $0.1.createdAt == $1.1.createdAt {
                return $0.1.id < $1.1.id
            }
            return $0.1.createdAt < $1.1.createdAt
        }
        commands.forEach { try? FileManager.default.removeItem(at: $0.0) }
        return commands.map { $0.1 }
    }

    static func loadState() -> CallKitBridgeState? {
        guard let fileURL = try? stateFileURL(),
              let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return try? decoder().decode(CallKitBridgeState.self, from: data)
    }

    static var pendingCommandCount: Int {
        guard let directory = try? commandDirectoryURL(createIfNeeded: false),
              let fileURLs = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return 0
        }
        return fileURLs.filter { $0.pathExtension == "json" }.count
    }

    static func removePendingCommand(id: String) {
        guard let directory = try? commandDirectoryURL(createIfNeeded: false) else { return }
        let fileURL = directory
            .appendingPathComponent(id, isDirectory: false)
            .appendingPathExtension("json")
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func saveState(_ state: CallKitBridgeState) throws {
        let fileURL = try stateFileURL()
        try encoder().encode(state).write(to: fileURL, options: .atomic)
    }

    private static func containerURL() throws -> URL {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw BridgeError.appGroupUnavailable
        }
        return url
    }

    private static func commandDirectoryURL(createIfNeeded: Bool) throws -> URL {
        let directory = try containerURL()
            .appendingPathComponent(commandDirectoryName, isDirectory: true)
        if createIfNeeded {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                throw BridgeError.commandDirectoryUnavailable
            }
        }
        return directory
    }

    private static func stateFileURL() throws -> URL {
        try containerURL().appendingPathComponent(stateFileName, isDirectory: false)
    }

    private static func removeExpiredCommands(in directory: URL, now: Date = Date()) {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for fileURL in fileURLs where fileURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: fileURL),
                  let command = try? decoder().decode(CallKitBridgeCommand.self, from: data),
                  now.timeIntervalSince(command.createdAt) <= commandLifetime else {
                try? FileManager.default.removeItem(at: fileURL)
                continue
            }
        }
    }

    private static func trimPendingCommands(in directory: URL) {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), fileURLs.count > maximumPendingCommands else { return }

        let sorted = fileURLs.sorted { lhs, rhs in
            let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return leftDate < rightDate
        }
        sorted.prefix(fileURLs.count - maximumPendingCommands).forEach {
            try? FileManager.default.removeItem(at: $0)
        }
    }

    private static func postCommandNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: notificationName as CFString),
            nil,
            nil,
            true
        )
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
