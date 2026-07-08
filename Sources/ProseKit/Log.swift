import Foundation

/// Lightweight file logger. Because this app runs as a menu-bar accessory with
/// no console attached, a log file at `~/Library/Logs/Prose.log` is the only way
/// to see what happens on a real (AX-trusted) run — indispensable for debugging
/// force-click delivery, which can't be reproduced from an untrusted CLI.
public enum Log {
    public static let fileURL: URL = {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        return logs.appendingPathComponent("Prose.log")
    }()

    private static let queue = DispatchQueue(label: "prose.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            FileHandle.standardError.write(Data("prose \(message)\n".utf8))
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    /// Truncate and start a fresh session marker.
    public static func startSession(_ header: String) {
        try? "".write(to: fileURL, atomically: true, encoding: .utf8)
        write("──────── \(header) ────────")
    }
}
