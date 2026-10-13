import AppKit
import Foundation
import os.log

/// Hotkey diagnostics. Quiet by default; set UserDefaults `HisCopy.debugHotkeys` = true
/// (or build DEBUG) for verbose lines and `~/Library/Logs/HisCopy/hotkey.log`.
enum HotKeyTrace {
    private static let debugKey = "HisCopy.debugHotkeys"
    private static let logger = Logger(subsystem: "com.bianyanhui.HisCopy", category: "HotKey")
    private static let queue = DispatchQueue(label: "com.bianyanhui.HisCopy.hotkey-log")

    static var isVerbose: Bool {
        #if DEBUG
        true
        #else
        UserDefaults.standard.bool(forKey: debugKey)
        #endif
    }

    static var logFileURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/HisCopy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hotkey.log")
    }

    /// Always visible for rare important events (AX missing, tap failed).
    static func important(_ message: String) {
        NSLog("%@", "[HisCopy HotKey] \(message)")
        logger.warning("\(message, privacy: .public)")
        appendToFile(message)
    }

    /// FIRE / start / AX changes — verbose only unless important.
    static func line(_ message: String) {
        guard isVerbose else { return }
        NSLog("%@", "[HisCopy HotKey] \(message)")
        logger.log("\(message, privacy: .public)")
        appendToFile(message)
    }

    private static func appendToFile(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = ("\(stamp) \(message)\n").data(using: .utf8) ?? Data()
        queue.async {
            let url = logFileURL
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
