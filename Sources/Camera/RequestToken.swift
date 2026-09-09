import Foundation

final class RequestToken {
    private let lock = NSLock()
    private var latest: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        latest &+= 1
        return latest
    }

    func isLatest(_ id: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return id == latest
    }

    func current() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func isCurrent(_ id: UInt64?) -> Bool {
        guard let id else { return true }
        return isLatest(id)
    }
}
