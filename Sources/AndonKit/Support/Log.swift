import Foundation
import os

/// Thin wrapper over `os.Logger` so the hook shim and the app agree on
/// subsystem/category naming, and so a debug file sink can be flipped on
/// without touching call sites.
public enum Log {
    public static let subsystem = "app.andoncord"

    public static let server = Logger(subsystem: subsystem, category: "server")
    public static let hook = Logger(subsystem: subsystem, category: "hook")
    public static let install = Logger(subsystem: subsystem, category: "install")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    public static let jump = Logger(subsystem: subsystem, category: "jump")
    public static let usage = Logger(subsystem: subsystem, category: "usage")

    /// `ANDON_DEBUG=1` mirrors everything to a file, because `log stream` is
    /// awkward to use when you are debugging a hook that runs inside someone
    /// else's terminal.
    public static var fileLoggingEnabled: Bool {
        ProcessInfo.processInfo.environment["ANDON_DEBUG"] == "1"
    }

    private static let fileQueue = DispatchQueue(label: "app.andoncord.filelog")

    public static func debugFile(_ message: @autoclosure () -> String) {
        guard fileLoggingEnabled else { return }
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message())\n"
        let url = Paths.root.appendingPathComponent("debug.log")
        fileQueue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
