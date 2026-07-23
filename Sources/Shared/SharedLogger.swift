import Foundation
import os

/// A small logger shared by the app and the packet-tunnel extension.
/// Both targets must have the same App Group entitlement.
public final class SharedLogger {
    public static let shared = SharedLogger()
    public static let appGroupIdentifier = "group.com.example.emptytunnel"

    private enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case error = "ERROR"
    }

    private let lock = NSLock()
    private let fileURL: URL?
    private let osLogger: Logger
    private let timestampFormatter: ISO8601DateFormatter

    private init() {
        let subsystem = Bundle.main.bundleIdentifier ?? "com.example.emptytunnel"
        osLogger = Logger(subsystem: subsystem, category: "runtime")
        timestampFormatter = ISO8601DateFormatter()

        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) {
            try? FileManager.default.createDirectory(
                at: container,
                withIntermediateDirectories: true,
                attributes: nil
            )
            fileURL = container.appendingPathComponent("debug.log", isDirectory: false)
        } else {
            fileURL = nil
        }
    }

    public func debug(_ message: @autoclosure () -> String) {
        write(message(), level: .debug)
    }

    public func info(_ message: @autoclosure () -> String) {
        write(message(), level: .info)
    }

    public func error(_ message: @autoclosure () -> String) {
        write(message(), level: .error)
    }

    private func write(_ message: String, level: Level) {
        switch level {
        case .debug:
            osLogger.debug("\(message, privacy: .public)")
        case .info:
            osLogger.info("\(message, privacy: .public)")
        case .error:
            osLogger.error("\(message, privacy: .public)")
        }

        guard let fileURL else { return }
        lock.lock()
        defer { lock.unlock() }

        let timestamp = timestampFormatter.string(from: Date())
        let line = "\(timestamp) [\(level.rawValue)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            // Do not recurse into this logger when the shared file is unavailable.
            osLogger.error("Unable to append debug.log: \(error.localizedDescription, privacy: .public)")
        }
    }
}
