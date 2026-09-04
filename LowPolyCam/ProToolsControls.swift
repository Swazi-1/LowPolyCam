//
//  ProToolsControls.swift
//  LowPolyCam
//
//  Updated for iOS 27 / Xcode 27 / Swift 6.4.
//  Swift 6 complete concurrency · Observation · Liquid Glass · RotationCoordinator
//

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
// *what* it is (a toggle, a slider, a set of chips, a tap-to-open picker...)
// and *where its data comes from* (a closure into `AppSettings`/
// `CameraRecorder`). The drawer just lays out a list of these. All the
// shared chrome — icon badge, row separators, haptics-on-tap, spacing —
// lives in one renderer here instead of being re-typed per control. The
// icon-badge look intentionally matches `SettingsLabelStyle` in
// SettingsScreen.swift so Pro Tools feels like the same app as Settings,
// not a bare floating menu.
//
// HOW TO ADD A NEW PRO TOOLS CONTROL
// -----------------------------------
// 1. If it needs a new setting, add it to `AppSettings` in Settings.swift
//    (see the "HOW TO ADD A NEW SETTING" comment there).
// 2. Add ONE case to the `proToolsDrawerControls` array below (in CameraScreen.swift,
//    see `proToolsDrawerControls`), using whichever `ProToolControl` case
//    fits: `.toggle`, `.chips`, `.slider`, `.navigation`, or `.custom` for
//    anything bespoke.
// 3. That's it — the drawer renders it automatically with the right
//    spacing, icon badge, label styling, and haptic feedback.

/// One control inside the Pro Tools drawer. Each case carries just the data
/// needed to render + wire up that kind of control; the drawer never needs
/// to know about specific settings by name.
enum ProToolControl: Identifiable {

    /// A simple on/off row with an icon, title, and a trailing switch.
    case toggle(ToggleSpec)

    /// A horizontal row of selectable chips (e.g. Timer: Off / 3s / 10s).
    case chips(ChipsSpec)

    /// A labeled slider with a live value readout and optional reset button.
    case slider(SliderSpec)

    /// A row that opens a separate full sheet to pick from (e.g. White
    /// balance). Shows an icon, title, the current value, and a chevron —
    /// tapping opens whatever sheet the drawer wires up via `action`.
    case navigation(NavigationSpec)

    /// Escape hatch for anything that doesn't fit the shapes above.
    /// Prefer the typed cases where possible so new controls stay
    /// consistent; reach for `.custom` only for one-off layouts.
    case custom(id: String, AnyView)

    var id: String {
        switch self {
        case .toggle(let spec): return spec.id
        case .chips(let spec): return spec.id
        case .slider(let spec): return spec.id
        case .navigation(let spec): return spec.id
        case .custom(let id, _): return id
        }
    }

    struct ToggleSpec {
        let id: String
        let icon: String
        let title: String
        let isOn: Binding<Bool>
        /// Called after the toggle changes, for side effects like
        /// `recorder.refreshMotionUpdateRate()`. Optional.
        var onChange: ((Bool) -> Void)? = nil

        init(id: String, icon: String, title: String, isOn: Binding<Bool>, onChange: ((Bool) -> Void)? = nil) {
            self.id = id
            self.icon = icon
            self.title = title
            self.isOn = isOn
            self.onChange = onChange
        }
    }

    struct ChipsSpec {
        let id: String
        let icon: String
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
        let icon: String
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
        /// a reset button appears next to the header instead of crowding the track.
        var defaultValue: Float = 0
    }

    struct NavigationSpec {
        let id: String
        let icon: String
        let title: String
        /// Current selection, shown trailing (e.g. "Auto").
        let valueLabel: String
        let action: () -> Void
    }
}

/// Renders a list of `ProToolControl`s with the drawer's shared chrome:
/// a leading icon badge (matches Settings), consistent row height, and a
/// hairline separator between rows so the drawer reads as structured rows
/// instead of loose floating text.
struct ProToolsControlList: View {
    let controls: [ProToolControl]
    let accentColor: Color
    let hapticsEnabled: Bool

    @State private var chipHaptic = UISelectionFeedbackGenerator()

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(controls.enumerated()), id: \.element.id) { index, control in
                Group {
                    switch control {
                    case .toggle(let spec):
                        ProToolsToggleRow(spec: spec, accentColor: accentColor)
                    case .chips(let spec):
                        ProToolsChipsRow(spec: spec, accentColor: accentColor, hapticsEnabled: hapticsEnabled, haptic: chipHaptic)
                    case .slider(let spec):
                        ProToolsSliderRow(spec: spec, accentColor: accentColor)
                    case .navigation(let spec):
                        ProToolsNavigationRow(spec: spec, accentColor: accentColor)
                    case .custom(_, let view):
                        view
                    }
                }
                .padding(.vertical, 6)

                if index < controls.count - 1 {
                    Divider().overlay(Color.white.opacity(0.08))
                }
            }
        }
    }
}

/// The shared icon badge used by every row — same 28pt rounded-square look
/// as `SettingsLabelStyle`, so Pro Tools rows read as the same visual
/// language as the Settings screen.
private struct ProToolsIconBadge: View {
    let icon: String
    let accentColor: Color

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(accentColor)
            )
    }
}

private struct ProToolsToggleRow: View {
    let spec: ProToolControl.ToggleSpec
    let accentColor: Color

    var body: some View {
        HStack(spacing: 10) {
            ProToolsIconBadge(icon: spec.icon, accentColor: accentColor)
            Text(spec.title)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
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
            // Slightly undersized + anchored to the trailing edge so the
            // switch's own intrinsic size (which `.fixedSize()` used to let
            // win over this frame) can never poke past the drawer's edge on
            // iPhone 7's narrower 375pt width.
            .scaleEffect(0.85, anchor: .trailing)
            .frame(width: 42, height: 24, alignment: .trailing)
        }
        .frame(minHeight: 34)
        .padding(.trailing, 2)
    }
}

private struct ProToolsChipsRow: View {
    let spec: ProToolControl.ChipsSpec
    let accentColor: Color
    let hapticsEnabled: Bool
    let haptic: UISelectionFeedbackGenerator

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ProToolsIconBadge(icon: spec.icon, accentColor: accentColor)
                Text(spec.title)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.92))
                Spacer()
            }

            let chips = HStack(spacing: 6) {
                ForEach(spec.items) { item in
                    chip(item)
                }
                if !spec.scrollsHorizontally { Spacer(minLength: 0) }
            }
            .padding(.leading, 34) // aligns under the title, past the icon badge

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
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(item.selected ? accentColor : Palette.slateMid.opacity(0.6))
                )
        }
        .buttonStyle(.plain)
    }
}

/// Settings-inspired layout: icon + title + live value on one header line,
/// with the slider indented underneath it (instead of a bare track sitting
/// in empty space, which read as "unfinished" before).
private struct ProToolsSliderRow: View {
    let spec: ProToolControl.SliderSpec
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ProToolsIconBadge(icon: spec.icon, accentColor: accentColor)
                Text(spec.title)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.92))
                Spacer()
                Text(spec.valueLabel(spec.value.wrappedValue))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(accentColor)
                    .monospacedDigit()
                if abs(spec.value.wrappedValue - spec.defaultValue) > 0.01 {
                    Button(action: {
                        spec.value.wrappedValue = spec.defaultValue
                        spec.onChange?(spec.defaultValue)
                    }) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white.opacity(0.75))
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Palette.slateMid))
                    }
                    .buttonStyle(.plain)
                }
            }
            Slider(value: spec.value, in: spec.range, step: spec.step)
                .tint(accentColor)
                .padding(.leading, 34) // aligns under the title, past the icon badge
                .onChange(of: spec.value.wrappedValue) { val in
                    spec.onChange?(val)
                }
        }
    }
}

/// A row that opens a separate sheet (e.g. White balance). Mirrors the
/// icon-badge + title + trailing-value + chevron pattern used by the
/// Quick Presets entry row in SettingsScreen.swift.
private struct ProToolsNavigationRow: View {
    let spec: ProToolControl.NavigationSpec
    let accentColor: Color

    var body: some View {
        Button(action: spec.action) {
            HStack(spacing: 10) {
                ProToolsIconBadge(icon: spec.icon, accentColor: accentColor)
                Text(spec.title)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.92))
                Spacer()
                Text(spec.valueLabel)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.35))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
