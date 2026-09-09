import Combine
import Foundation

final class LiveRecordingStatsState: ObservableObject {
    struct Snapshot: Equatable {
        var fps: Double?
        var mbps: Double?
        var drops: Int?
    }

    @Published private(set) var snapshot = Snapshot(fps: nil, mbps: nil, drops: nil)

    var fps: Double? { snapshot.fps }
    var mbps: Double? { snapshot.mbps }
    var drops: Int? { snapshot.drops }

    func reset() {
        let empty = Snapshot(fps: nil, mbps: nil, drops: nil)
        if snapshot != empty { snapshot = empty }
    }

    func update(fps: Double?, mbps: Double?, drops: Int?) {
        let next = Snapshot(fps: fps, mbps: mbps, drops: drops)
        if snapshot != next { snapshot = next }
    }
}
