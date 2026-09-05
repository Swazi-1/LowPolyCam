//
//  DebugLog.swift
//  LowPolyCam
//
//  Updated for iOS 27 / Xcode 27 / Swift 6.4.
//  Swift 6 complete concurrency · Observation · Liquid Glass · RotationCoordinator
//

import Foundation

/// Writes to a plain text file inside the app's Documents folder so it
/// can be pulled off-device via the Files app (On My iPhone > LowPolyCam)
/// without needing Xcode/a Mac. Call `DebugLog.write(...)` anywhere.
enum DebugLog {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("recording_debug_log.txt")
    }()

    private static let dateFormatter = ISO8601DateFormatter()

    private static let ioQueue = DispatchQueue(label: "lowpolycam.debuglog", qos: .utility)
    private static var handle: FileHandle?

    static func write(_ message: String) {
        ioQueue.async {
            let stamp = dateFormatter.string(from: Date())
            let line = "[\(stamp)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if handle == nil {
                let path = url.path
                if !FileManager.default.fileExists(atPath: path) {
                    FileManager.default.createFile(atPath: path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: url)
            }
            guard let h = handle else { return }
            do {
                let size = try h.seekToEnd()
                if size > 2_000_000 { try h.truncate(atOffset: 0); try h.seek(toOffset: 0) }
                try h.write(contentsOf: data)
            } catch {
                // Keep logging best-effort — a failed write must never crash capture.
            }
        }
    }

    static func reset() {
        ioQueue.async {
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: url)
        }
    }
}
