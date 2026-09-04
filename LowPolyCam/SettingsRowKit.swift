//
//  SettingsRowKit.swift
//  LowPolyCam
//
//  Updated for iOS 27 / Xcode 27 / Swift 6.4.
//  Swift 6 complete concurrency · Observation · Liquid Glass · RotationCoordinator
//

import SwiftUI
import UIKit

// MARK: - Settings row kit
//
// WHY THIS FILE EXISTS
// ---------------------
// SettingsScreen.swift used to have one hand-written `some View` property
// per toggle (assistStabilisation, assistGrid, assistLevel, assistAutoDim,
// assistRecordingStats, assistLongevity, ...), each re-typing the same
// `Toggle { Label(...).labelStyle(SettingsLabelStyle(...)) }` boilerplate.
// Adding a new on/off setting meant copy-pasting one of those and updating
// four things by hand (title, icon, binding, and the section that lists it).
//
// `SettingsToggleRow` and `SettingsPickerRow` below collapse that to a
// single call. A whole group of toggles becomes one array literal via
// `SettingsToggleGroup`.
//
// HOW TO ADD A NEW TOGGLE SETTING
// ---------------------------------
// 1. Add the `@Setting` property to AppSettings in Settings.swift (see the
//    "HOW TO ADD A NEW SETTING" comment there).
// 2. In SettingsScreen.swift, add one `SettingsToggleSpec` to the relevant
//    section's array (e.g. `videoAssistToggles`), or call
//    `SettingsToggleRow(...)` directly inside a `Section`.
// That's it — no new `some View` property needed.

/// Describes one on/off row: title, icon, and the setting it's bound to.
/// A `Section` can render a list of these via `SettingsToggleGroup`.
struct SettingsToggleSpec: Identifiable {
    let id: String
    let title: String
    let icon: String
    let isOn: Binding<Bool>
    /// Side effect to run after the user flips this toggle, e.g.
    /// `recorder.updateStabilization()`. Optional.
    var onChange: ((Bool) -> Void)? = nil
    /// When false, this row is skipped entirely (e.g. stabilisation on a
    /// lens that can't stabilise). Defaults to always-visible.
    var isVisible: Bool = true

    init(id: String, title: String, icon: String, isOn: Binding<Bool>, onChange: ((Bool) -> Void)? = nil, isVisible: Bool = true) {
        self.id = id
        self.title = title
        self.icon = icon
        self.isOn = isOn
        self.onChange = onChange
        self.isVisible = isVisible
    }
}

/// Fires a short, light tap for any toggle flip in Settings, at the user's
/// chosen haptic strength — the same feedback the shutter/record buttons
/// use, just at the lighter `.light` base so a screen full of toggles
/// doesn't feel like a jackhammer. Used by every row below, so flipping
/// *any* switch in the app gives the same tactile confirmation.
func fireSettingsToggleHaptic(_ settings: AppSettings) {
    guard settings.hapticFeedbackEnabled else { return }
    let generator = UIImpactFeedbackGenerator(style: settings.hapticIntensity.scaled(.light))
    generator.impactOccurred()
}

/// A single toggle row matching the existing Settings look
/// (`SettingsLabelStyle`-styled icon + title, standard `Toggle`).
struct SettingsToggleRow: View {
    let spec: SettingsToggleSpec
    let accentColor: Color
    let settings: AppSettings

    var body: some View {
        Toggle(isOn: Binding(
            get: { spec.isOn.wrappedValue },
            set: { newValue in
                spec.isOn.wrappedValue = newValue
                spec.onChange?(newValue)
                fireSettingsToggleHaptic(settings)
            }
        )) {
            Label(spec.title, systemImage: spec.icon)
                .labelStyle(SettingsLabelStyle(color: accentColor))
        }
    }
}

/// Renders a list of `SettingsToggleSpec`s as rows inside the enclosing
/// `Section` (skipping any marked `isVisible == false`). Use this instead
/// of writing one `some View` property per toggle.
struct SettingsToggleGroup: View {
    let specs: [SettingsToggleSpec]
    let accentColor: Color
    let settings: AppSettings

    var body: some View {
        ForEach(specs.filter { $0.isVisible }) { spec in
            SettingsToggleRow(spec: spec, accentColor: accentColor, settings: settings)
        }
    }
}

/// Describes a single-select picker row (e.g. Grid overlay: Off / Thirds /
/// Crosshair / Square) using the same `SettingsLabelStyle` chrome as
/// `SettingsToggleRow`, for `CaseIterable` settings.
struct SettingsPickerRow<Value: Hashable & CaseIterable & Identifiable, Content: View>: View where Value.AllCases: RandomAccessCollection {
    let title: String
    let icon: String
    let accentColor: Color
    @Binding var selection: Value
    let label: (Value) -> Content

    var body: some View {
        Picker(selection: $selection) {
            ForEach(Value.allCases) { value in
                label(value).tag(value)
            }
        } label: {
            Label(title, systemImage: icon)
                .labelStyle(SettingsLabelStyle(color: accentColor))
        }
    }
}
