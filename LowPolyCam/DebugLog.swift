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

    // All file I/O funnels through this single serial queue. Previously
    // write() dispatched onto the shared concurrent .utility queue with no
    // ordering guarantee and no synchronization with reset() — a reset()
    // firing at the start of the *next* recording could delete the file
    // out from under a write() from the *previous* recording's stop-drain
    // that was still in flight, silently truncating exactly the tail of
    // the log needed to diagnose a stop-path hang (log would just stop
    // mid-sequence with no error, matching what looked like a dead app
    // when it was actually a dead log). A serial queue also prevents
    // concurrent FileHandle opens from clobbering each other's writes.
    private static let ioQueue = DispatchQueue(label: "lowpolycam.debuglog", qos: .utility)
    private static var handle: FileHandle?

    static func write(_ message: String) {
        let stamp = dateFormatter.string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        print(line, terminator: "")
        guard let data = line.data(using: .utf8) else { return }
        ioQueue.async {
            if handle == nil {
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: url)
            }
            guard let h = handle else { return }
            h.seekToEndOfFile()
            h.write(data)
        }
    }

    static func reset() {
        ioQueue.sync {
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: url)
        }
    }
}
