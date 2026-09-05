import SwiftUI

/// The expanded dial is an overlay: it never moves the shutter or mode row.
struct SingleZoomControl: View {
    let value: CGFloat
    let minimum: CGFloat
    let maximum: CGFloat
    let enabled: Bool
    let change: (CGFloat) -> Void
    let reset: () -> Void
    @GestureState private var touching = false
    @State private var base: CGFloat?
    @State private var moved = false
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var upper: CGFloat { max(minimum, min(8, maximum)) }
    private var label: String { String(format: abs(value.rounded() - value) < 0.05 ? "%.0fx" : "%.1fx", Double(value)) }

    var body: some View {
        Text(label)
            .font(.system(.subheadline, design: .rounded, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: 76, height: 44)
            .background(.black.opacity(0.72), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.2)))
            .contentShape(Capsule())
            .overlay(alignment: .bottom) {
                if expanded && enabled {
                    wheel.offset(y: -52).allowsHitTesting(false)
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { gesture in
                    guard enabled else { return }
                    if base == nil { base = value }
                    if abs(gesture.translation.width) >= 4 {
                        moved = true
                        expanded = true
                        let span = max(0.01, log2(upper / max(minimum, 0.01)))
                        let candidate = (base ?? value) * pow(2, -gesture.translation.width / 140 * span)
                        change(CGFloat(ZoomPolicy.clamp(Double(candidate), minimum: Double(minimum), maximum: Double(upper))))
                    }
                }
                .onEnded { _ in
                    if enabled && !moved && !expanded { reset() }
                    collapse()
                })
            .task(id: touching) {
                guard touching else { collapse(); return }
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                guard touching, enabled else { return }
                expanded = true
            }
            .onChange(of: enabled) { _, ready in if !ready { collapse() } }
            .onDisappear { collapse() }
            .accessibilityElement()
            .accessibilityLabel("Camera zoom")
            .accessibilityValue(label)
            .accessibilityHint("Double tap to reset to one times")
            .accessibilityAction { if enabled { reset() } }
            .accessibilityAdjustableAction { direction in
                guard enabled else { return }
                let factor = direction == .increment ? value * 1.15 : value / 1.15
                change(CGFloat(ZoomPolicy.clamp(Double(factor), minimum: Double(minimum), maximum: Double(upper))))
            }
            .opacity(enabled ? 1 : 0.45)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
    }

    private var wheel: some View {
        GeometryReader { geometry in
            let span = max(0.01, log2(upper / max(minimum, 0.01)))
            ZStack(alignment: .topLeading) {
                ForEach(0..<25, id: \.self) { tick in
                    Rectangle().fill(.white.opacity(0.4))
                        .frame(width: 1, height: 8)
                        .offset(x: CGFloat(tick) / 24 * (geometry.size.width - 32) + 16, y: 10)
                }
                ForEach(ZoomPolicy.ticks(minimum: Double(minimum), maximum: Double(upper)), id: \.self) { tick in
                    Text(String(format: tick == tick.rounded() ? "%.0fx" : "%.1fx", tick))
                        .font(.caption2.monospacedDigit())
                        .position(x: CGFloat(log2(tick / Double(max(minimum, 0.01)))) / span * (geometry.size.width - 32) + 16, y: 31)
                }
                Rectangle().fill(.yellow).frame(width: 2, height: 16)
                    .offset(x: CGFloat(log2(max(value, minimum) / max(minimum, 0.01))) / span * (geometry.size.width - 32) + 16, y: 7)
            }
        }
        .foregroundStyle(.white)
        .frame(width: 280, height: 48)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 14))
        .transition(reduceMotion ? .identity : .opacity)
    }

    private func collapse() { expanded = false; base = nil; moved = false }
}
