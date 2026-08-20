import SwiftUI

// MARK: - Pro Tools control kit
//
// WHY THIS FILE EXISTS
// ---------------------
// Before this file, every row in the Pro Tools drawer (Timer, Level meter,
// Exposure, White balance, ...) was its own hand-written VStack/HStack block
// living directly inside `proToolsDrawer` in CameraScreen.swift. Adding a
// new control meant copy-pasting one of those blocks and hoping you matched
// the spacing/fonts/haptics of its neighbours.
//
// Now a Pro Tools control is just one `ProToolControl` value describing
// *what* it is (a toggle, a slider, a set of chips, ...) and *where its
// data comes from* (a closure into `AppSettings`/`CameraRecorder`). The
// drawer just lays out a list of these. All the shared chrome (section
// label styling, haptics-on-tap, spacing, chip look) lives in one renderer
// here instead of being re-typed per control.
//
// HOW TO ADD A NEW PRO TOOLS CONTROL
// -----------------------------------
// 1. If it needs a new setting, add it to `AppSettings` in Settings.swift
//    (see the "HOW TO ADD A NEW SETTING" comment there).
// 2. Add ONE case to the `proToolsControls` array below (in CameraScreen.swift,
//    see `proToolsDrawerControls`), using whichever `ProToolControl` case
//    fits: `.toggle`, `.chips`, `.slider`, or `.custom` for anything bespoke.
// 3. That's it — the drawer renders it automatically with the right
//    spacing, label styling, and haptic feedback.

/// One control inside the Pro Tools drawer. Each case carries just the data
/// needed to render + wire up that kind of control; the drawer never needs
/// to know about specific settings by name.
enum ProToolControl: Identifiable {

    /// A simple on/off row with a title and a trailing switch.
    case toggle(ToggleSpec)

    /// A horizontal row of selectable chips (e.g. Timer: Off / 3s / 10s).
    case chips(ChipsSpec)

    /// A labeled slider with a live value readout and optional reset button.
    case slider(SliderSpec)

    /// Escape hatch for anything that doesn't fit the three shapes above.
    /// Prefer the typed cases where possible so new controls stay
    /// consistent; reach for `.custom` only for one-off layouts.
    case custom(id: String, AnyView)

    var id: String {
        switch self {
        case .toggle(let spec): return spec.id
        case .chips(let spec): return spec.id
        case .slider(let spec): return spec.id
        case .custom(let id, _): return id
        }
    }

    struct ToggleSpec {
        let id: String
        let title: String
        let isOn: Binding<Bool>
        /// Called after the toggle changes, for side effects like
        /// `recorder.refreshMotionUpdateRate()`. Optional.
        var onChange: ((Bool) -> Void)? = nil

        init(id: String, title: String, isOn: Binding<Bool>, onChange: ((Bool) -> Void)? = nil) {
            self.id = id
            self.title = title
            self.isOn = isOn
            self.onChange = onChange
        }
    }

    struct ChipsSpec {
        let id: String
        let title: String
        let items: [Item]
        /// Chips wider than this many items scroll horizontally instead of wrapping.
        var scrollsHorizontally: Bool = false

        struct Item: Identifiable {
            let id: String
            let label: String
            let selected: Bool
            let action: () -> Void
        }
    }

    struct SliderSpec {
        let id: String
        let title: String
        let value: Binding<Float>
        let range: ClosedRange<Float>
        let step: Float
        /// Formats the current value for the trailing readout (e.g. "+0.3 EV").
        let valueLabel: (Float) -> String
        /// Called continuously as the slider moves, for side effects like
        /// `recorder.setExposureBias(val)`. Optional.
        var onChange: ((Float) -> Void)? = nil
        /// Value considered "default" — when the slider differs from it,
        /// a Reset button appears.
        var defaultValue: Float = 0
    }
}

/// Renders a list of `ProToolControl`s with the drawer's shared chrome.
/// This is the one place that knows how each control kind should look —
/// individual controls never re-implement fonts/spacing/haptics themselves.
struct ProToolsControlList: View {
    let controls: [ProToolControl]
    let accentColor: Color
    let hapticsEnabled: Bool

    @State private var chipHaptic = UISelectionFeedbackGenerator()

    var body: some View {
        ForEach(controls) { control in
            switch control {
            case .toggle(let spec):
                ProToolsToggleRow(spec: spec, accentColor: accentColor)
            case .chips(let spec):
                ProToolsChipsRow(spec: spec, accentColor: accentColor, hapticsEnabled: hapticsEnabled, haptic: chipHaptic)
            case .slider(let spec):
                ProToolsSliderRow(spec: spec, accentColor: accentColor)
            case .custom(_, let view):
                view
            }
        }
    }
}

private struct ProToolsToggleRow: View {
    let spec: ProToolControl.ToggleSpec
    let accentColor: Color

    var body: some View {
        HStack {
            Text(spec.title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.9))
            Spacer()
            Toggle("", isOn: Binding(
                get: { spec.isOn.wrappedValue },
                set: { newValue in
                    spec.isOn.wrappedValue = newValue
                    spec.onChange?(newValue)
                }
            ))
            .labelsHidden()
            .toggleStyle(SwitchToggleStyle(tint: accentColor))
        }
    }
}

private struct ProToolsChipsRow: View {
    let spec: ProToolControl.ChipsSpec
    let accentColor: Color
    let hapticsEnabled: Bool
    let haptic: UISelectionFeedbackGenerator

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(spec.title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.55))

            let chips = HStack(spacing: 8) {
                ForEach(spec.items) { item in
                    chip(item)
                }
                if !spec.scrollsHorizontally { Spacer(minLength: 0) }
            }

            if spec.scrollsHorizontally {
                ScrollView(.horizontal, showsIndicators: false) { chips }
            } else {
                chips
            }
        }
    }

    private func chip(_ item: ProToolControl.ChipsSpec.Item) -> some View {
        Button(action: {
            if hapticsEnabled { haptic.selectionChanged() }
            item.action()
        }) {
            Text(item.label)
                .font(.system(size: 12, weight: item.selected ? .semibold : .medium, design: .rounded))
                .foregroundColor(item.selected ? Palette.slateDeep : .white.opacity(0.85))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(item.selected ? accentColor : Palette.slateMid.opacity(0.6))
                )
        }
        .buttonStyle(.plain)
    }
}

private struct ProToolsSliderRow: View {
    let spec: ProToolControl.SliderSpec
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(spec.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
                Spacer()
                Text(spec.valueLabel(spec.value.wrappedValue))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
            }
            HStack(spacing: 8) {
                Slider(value: spec.value, in: spec.range, step: spec.step)
                    .tint(accentColor)
                    .onChange(of: spec.value.wrappedValue) { val in
                        spec.onChange?(val)
                    }
                if abs(spec.value.wrappedValue - spec.defaultValue) > 0.01 {
                    Button("Reset") {
                        spec.value.wrappedValue = spec.defaultValue
                        spec.onChange?(spec.defaultValue)
                    }
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Palette.slateMid)
                    .clipShape(Capsule())
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
