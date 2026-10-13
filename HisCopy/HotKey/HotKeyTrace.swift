import AppKit
import Foundation
import os.log

/// Unavoidable hotkey diagnostics: Console + stdout + a file the user can `cat`.
enum HotKeyTrace {
    static let logFileName = "hotkey.log"
    private static let logger = Logger(subsystem: "com.bianyanhui.HisCopy", category: "HotKey")
    private static let queue = DispatchQueue(label: "com.bianyanhui.HisCopy.hotkey-log")

    static var logFileURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/HisCopy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(logFileName)
    }

    static func line(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let full = "\(stamp) \(message)"
        // Three channels — Console filters often hide Logger-only output.
        NSLog("%@", "[HisCopy HotKey] \(message)")
        print("[HisCopy HotKey] \(message)")
        logger.log("\(message, privacy: .public)")
        queue.async {
            let url = logFileURL
            let data = (full + "\n").data(using: .utf8) ?? Data()
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
