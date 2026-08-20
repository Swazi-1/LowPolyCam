import Foundation

/// Writes to a plain text file inside the app's Documents folder so it
/// can be pulled off-device via the Files app (On My iPhone > LowPolyCam)
/// without needing Xcode/a Mac. Call `DebugLog.write(...)` anywhere.
enum DebugLog {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("recording_debug_log.txt")
    }()

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    static func write(_ message: String) {
        let stamp = dateFormatter.string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        print(line, terminator: "")
        guard let data = line.data(using: .utf8) else { return }
        DispatchQueue.global(qos: .utility).async {
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }

    static func reset() {
        try? FileManager.default.removeItem(at: url)
    }
}
