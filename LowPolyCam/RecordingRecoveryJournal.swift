import Foundation

/// A split recording can have several independently finalizing segments.
/// Never let an older completion clear a newer segment's recovery marker.
enum RecordingRecoveryJournal {
    private static let lock = NSLock()
    private static let key = "recordingRecoverySegments"

    static var entries: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }
    static func record(_ url: URL, destination: SaveLocation) {
        lock.lock(); defer { lock.unlock() }
        var items = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        items[url.lastPathComponent] = destination.rawValue
        UserDefaults.standard.set(items, forKey: key)
    }
    static func remove(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        var items = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        items.removeValue(forKey: url.lastPathComponent)
        UserDefaults.standard.set(items, forKey: key)
        if UserDefaults.standard.string(forKey: CameraRecorder.inProgressKey) == url.lastPathComponent {
            UserDefaults.standard.removeObject(forKey: CameraRecorder.inProgressKey)
            UserDefaults.standard.removeObject(forKey: CameraRecorder.inProgressDestinationKey)
        }
    }
}
