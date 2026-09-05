import Foundation

/// Main-camera equivalents; pure policy shared by gestures and lens routing.
enum ZoomPolicy {
    static func clamp(_ value: Double, minimum: Double, maximum: Double) -> Double {
        let lower = max(0.01, minimum)
        let upper = max(lower, min(8, maximum))
        return min(upper, max(lower, value.isFinite ? value : 1))
    }

    static func useUltraWide(zoom: Double, currentlyUltraWide: Bool, reset: Bool = false) -> Bool {
        guard !reset else { return false }
        return currentlyUltraWide ? zoom < 1.08 : zoom < 1
    }

    static func ticks(minimum: Double, maximum: Double) -> [Double] {
        Array(Set([minimum, 0.5, 1, 2, maximum].filter {
            $0 >= minimum && $0 <= maximum
        })).sorted()
    }
}
