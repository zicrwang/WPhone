import Foundation
import os

/// A small logger shared by the app and its Network Extension targets.
/// All targets must have the same App Group entitlement.
public final class SharedLogger {
    public static let shared = SharedLogger()
    public static let appGroupIdentifier = "group.3970029fa0cfcf6d.1"

    public struct LogSnapshot {
        public let text: String
        public let nextOffset: UInt64
        public let reset: Bool
        public let truncated: Bool
    }

    private enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case error = "ERROR"
    }

    private let lock = NSLock()
    private let fileURL: URL?
    private let osLogger: Logger
    private let timestampFormatter: ISO8601DateFormatter
    private let maximumLogBytes = 512 * 1024

    private init() {
        let subsystem = Bundle.main.bundleIdentifier ?? "app.wephone.vpn"
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

    public func recentLog() -> String {
        guard let fileURL else { return "App Group container is unavailable." }

        lock.lock()
        defer { lock.unlock() }

        do {
            let data = try Data(contentsOf: fileURL)
            return String(decoding: data, as: UTF8.self)
        } catch {
            return "No debug.log has been written yet."
        }
    }

    /// Reads an incremental window without loading the complete log into memory.
    public func logSnapshot(
        after requestedOffset: UInt64?,
        maximumBytes: Int = 64 * 1024
    ) -> LogSnapshot {
        guard let fileURL else {
            return LogSnapshot(
                text: "App Group container is unavailable.\n",
                nextOffset: 0,
                reset: true,
                truncated: false
            )
        }

        let byteLimit = max(1, min(maximumBytes, 128 * 1024))
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: fileURL.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSizeNumber = attributes[.size] as? NSNumber else {
            return LogSnapshot(text: "", nextOffset: 0, reset: requestedOffset != nil, truncated: false)
        }

        let fileSize = fileSizeNumber.uint64Value
        var reset = false
        let startOffset: UInt64

        if let requestedOffset, requestedOffset <= fileSize {
            startOffset = requestedOffset
        } else {
            reset = requestedOffset != nil
            startOffset = fileSize > UInt64(byteLimit) ? fileSize - UInt64(byteLimit) : 0
        }

        let availableBytes = fileSize - startOffset
        let readLength = Int(min(UInt64(byteLimit), availableBytes))
        let truncated = (startOffset > 0 && requestedOffset == nil) || availableBytes > UInt64(byteLimit)

        guard readLength > 0 else {
            return LogSnapshot(
                text: "",
                nextOffset: startOffset,
                reset: reset,
                truncated: truncated
            )
        }

        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            try handle.seek(toOffset: startOffset)
            let data = try handle.read(upToCount: readLength) ?? Data()
            try handle.close()
            return LogSnapshot(
                text: String(decoding: data, as: UTF8.self),
                nextOffset: startOffset + UInt64(data.count),
                reset: reset,
                truncated: truncated
            )
        } catch {
            osLogger.error("Unable to read debug.log: \(error.localizedDescription, privacy: .public)")
            return LogSnapshot(
                text: "Unable to read debug.log.\n",
                nextOffset: startOffset,
                reset: true,
                truncated: false
            )
        }
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

        rotateLogIfNeeded(at: fileURL)
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

    private func rotateLogIfNeeded(at fileURL: URL) {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= maximumLogBytes else {
            return
        }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
