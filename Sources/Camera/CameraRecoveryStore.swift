import Foundation

enum CameraRecoveryStore {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("LowPolyCam/Recovery", isDirectory: true)
    }

    private static func recordingURLs(sorted: Bool) -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let recordings = files.filter { $0.pathExtension.lowercased() == "mov" }
        return sorted ? recordings.sorted { $0.lastPathComponent < $1.lastPathComponent } : recordings
    }

    static func recordings() -> [URL] {
        recordingURLs(sorted: true)
    }

    static func containsRecording(named filename: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path)
    }

    static func recordingCount() -> Int {
        recordingURLs(sorted: false).count
    }

    @discardableResult
    static func preserve(_ source: URL) -> URL? {
        let fm = FileManager.default
        let sourceURL = source.standardizedFileURL
        let recoveryDirectory = directory.standardizedFileURL
        guard fm.fileExists(atPath: sourceURL.path) else { return nil }
        if sourceURL.deletingLastPathComponent() == recoveryDirectory {
            return sourceURL
        }

        do {
            try fm.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
            var destination = recoveryDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            if fm.fileExists(atPath: destination.path) {
                let stem = sourceURL.deletingPathExtension().lastPathComponent
                destination = recoveryDirectory.appendingPathComponent("\(stem)_\(UUID().uuidString).mov")
            }
            try fm.moveItem(at: sourceURL, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    static func removeAll() {
        for url in recordingURLs(sorted: false) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
