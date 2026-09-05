import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    precondition(condition(), name)
}
expect(ZoomPolicy.clamp(.nan, minimum: 0.5, maximum: 8) == 1, "Invalid zoom resets safely")
expect(ZoomPolicy.clamp(20, minimum: 0.5, maximum: 16) == 8, "Application zoom cap")
expect(ZoomPolicy.clamp(0.5, minimum: 1, maximum: 6) == 1, "Unavailable ultra-wide cannot be requested")
expect(ZoomPolicy.useUltraWide(zoom: 0.9, currentlyUltraWide: false), "Below one requires ultra-wide")
expect(ZoomPolicy.useUltraWide(zoom: 1.04, currentlyUltraWide: true), "Hysteresis retains ultra-wide")
expect(!ZoomPolicy.useUltraWide(zoom: 1.04, currentlyUltraWide: false), "Hysteresis retains wide")
expect(!ZoomPolicy.useUltraWide(zoom: 1.08, currentlyUltraWide: true), "Upper boundary switches wide")
expect(!ZoomPolicy.useUltraWide(zoom: 1, currentlyUltraWide: true, reset: true), "Reset selects main lens")
expect(ZoomPolicy.ticks(minimum: 1, maximum: 2) == [1, 2], "Ticks exclude unsupported and duplicate factors")
print("Zoom policy regression tests passed")
