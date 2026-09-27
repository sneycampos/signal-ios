import Foundation
import os

/// Diagnostics log: unified logging (Console.app) plus a small in-memory buffer for the diagnostics export.
public final class SignalDebugLogger: Sendable {
    public static let shared = SignalDebugLogger()

    private let buffer = OSAllocatedUnfairLock(initialState: [String]())
    private let maxEntries = 300

    private init() {}

    public func log(_ message: String, category: String = "App") {
        Logger(subsystem: "com.silviogodinho.signal", category: category).info("\(message, privacy: .public)")
        let line = "[\(Date().formatted(.iso8601))] [\(category)] \(message)"
        buffer.withLock { entries in
            entries.append(line)
            if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        }
    }

    public func recentLogs() -> String {
        let entries = buffer.withLock { $0 }
        return entries.isEmpty ? "No entries yet." : entries.joined(separator: "\n")
    }

    public func clear() {
        buffer.withLock { $0.removeAll() }
    }
}
