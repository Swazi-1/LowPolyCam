import SwiftUI

// MARK: - Lightweight label style (keeps List scrolling smooth on A10)

struct SettingsLabelStyle: LabelStyle {
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(color)
                )
            configuration.title
                .font(.system(size: 16, weight: .medium, design: .rounded))
        }
    }
}

struct SettingsScreen: View {

    @ObservedObject var settings: AppSettings
    /// Recorder is only used for one-shot capability checks + format updates.
    /// We intentionally do NOT observe live battery/free-space ticks while the
    /// sheet is open — that was the main source of scroll stutter in photo / slo-mo.
    let recorder: CameraRecorder
    @Environment(\.presentationMode) private var presentation

    @State private var appliedPresetId: String? = nil
    @State private var presetHaptic = UISelectionFeedbackGenerator()
    @State private var freeBytesSnapshot: Int64 = 0
    @State private var isFrontSnapshot = false
    @State private var availableResolutions: [Resolution] = Resolution.allCases
    @State private var availableFrameRates: [FrameRate] = FrameRate.allCases
    @State private var availableSlowMoRates: [SlowMoFrameRate] = SlowMoFrameRate.allCases
    @State private var availableSlowMoResolutions: [Resolution] = [.p1080, .p720]
    @State private var isSlowMoSupported = true
    @State private var stabilizationSupported = true

    private var plan: EncodePlan { Encoder.plan(for: settings) }

    var body: some View {
        NavigationView {
            List {
                // 1. Appearance first — quick visual change
                appearanceSection

                // 2. Mode-specific capture controls
                if settings.cameraMode == .slowMo {
                    if isFrontSnapshot { frontCameraBanner }
                    slowMoFrameRateSection
                    slowMoResolutionSection
                    qualitySection
                } else if settings.cameraMode == .photo {
                    // Photo uses full sensor — keep UI light
                    qualitySection
                } else {
                    if isFrontSnapshot { frontCameraBanner }
                    presetsSection
                    resolutionSection
                    frameRateSection
                    qualitySection
                }

                // 3. Save / duration
                saveSection
                if settings.cameraMode != .photo {
                    splitSection
                    maxDurationSection
                }

                // 4. Tools & feedback
                cameraSection
                feedbackSection

                // 5. Format + cost
                advancedSection
                estimateSection

                // 6. About
                aboutSection
            }
            .listStyle(InsetGroupedListStyle())
            // No implicit animations while scrolling
            .animation(nil, value: settings.cameraMode)
            .animation(nil, value: settings.accentColor)
            .animation(nil, value: appliedPresetId)
            .navigationBarTitle("Settings", displayMode: .inline)
            .navigationBarItems(trailing: Button(action: {
                presentation.wrappedValue.dismiss()
            }) {
                Text("Done")
                    .font(.system(size: 16, weight: .bold))
            })
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(settings.accentColor.color)
        .onAppear {
            presetHaptic.prepare()
            // Snapshot once — prevents continuous body rebuilds from live stats
            freeBytesSnapshot = recorder.freeBytes
            isFrontSnapshot = recorder.isFrontCamera
            availableResolutions = recorder.availableResolutions
            availableFrameRates = recorder.availableFrameRates
            availableSlowMoRates = recorder.availableSlowMoRates
            availableSlowMoResolutions = recorder.availableSlowMoResolutions
            isSlowMoSupported = recorder.isSlowMoSupportedOnCurrentLens
            stabilizationSupported = recorder.stabilizationSupported
        }
    }

    // MARK: - Banner

    private var frontCameraBanner: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "person.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(settings.accentColor.deep)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Selfie camera")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Standard video only. Unsupported options stay greyed out.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Capture

    private var resolutionSection: some View {
        Section(header: sectionHeader("Resolution", icon: "rectangle.dashed"),
                footer: Text("Recording at \(plan.sizeLabel).")) {
            ForEach(Resolution.allCases.filter { $0 != .p144 || availableResolutions.contains(.p144) }) { r in
                let enabled = availableResolutions.contains(r)
                row(title: r.label,
                    subtitle: enabled ? r.detail : "Not on this camera",
                    selected: settings.resolution == r,
                    enabled: enabled) {
                    settings.resolution = r
                    if let locked = r.lockedFrameRate {
                        settings.frameRate = locked
                    }
                    recorder.updateCaptureFormat()
                }
            }
        }
    }

    private var frameRateSection: some View {
        Section(header: sectionHeader("Frame Rate", icon: "timer"),
                footer: Text(settings.resolution == .p2160
                             ? "4K is limited to 30 fps on this iPhone."
                             : "60 fps looks smoother and uses more space.")) {
            ForEach(FrameRate.allCases) { f in
                let enabled = availableFrameRates.contains(f)
                    && !(settings.resolution == .p2160 && f == .fps60)
                row(title: f.label,
                    subtitle: enabled ? f.detail : (settings.resolution == .p2160 ? "Not with 4K" : "Not on this camera"),
                    selected: settings.frameRate == f,
                    enabled: enabled) {
                    settings.frameRate = f
                    recorder.updateCaptureFormat()
                }
            }
        }
    }

    private var qualitySection: some View {
        Section(header: sectionHeader("Quality", icon: "slider.horizontal.3")) {
            ForEach(Quality.allCases) { q in
                row(title: q.label, subtitle: q.detail, selected: settings.quality == q) {
                    settings.quality = q
                }
            }
        }
    }

    // MARK: - Quick Presets

    private var presetsSection: some View {
        Section(header: sectionHeader("Quick Presets", icon: "bolt.fill"),
                footer: Text("One tap applies instantly. Tweak anything after.")) {
            ForEach(CapturePreset.all) { preset in
                Button(action: { applyPresetNow(preset) }) {
                    HStack(spacing: 12) {
                        Image(systemName: preset.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(settings.accentColor.color)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundColor(.primary)
                            Text(preset.detail)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 4)

                        if appliedPresetId == preset.id {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(settings.accentColor.color)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary.opacity(0.45))
                        }
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PresetButtonStyle())
            }
        }
    }

    private func applyPresetNow(_ preset: CapturePreset) {
        presetHaptic.selectionChanged()
        presetHaptic.prepare()
        appliedPresetId = preset.id

        settings.applyPreset(preset)
        recorder.updateCaptureFormat()
        recorder.syncMicInput()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if appliedPresetId == preset.id { appliedPresetId = nil }
        }
    }

    // MARK: - Save / Split / Duration

    private var saveSection: some View {
        Section(header: sectionHeader("Save To", icon: "folder.fill")) {
            ForEach(SaveLocation.allCases) { s in
                row(title: s.label, subtitle: s.detail, selected: settings.saveLocation == s) {
                    settings.saveLocation = s
                }
            }
        }
    }

    private var splitSection: some View {
        Section(header: sectionHeader("Split Recordings", icon: "scissors"),
                footer: Text("Shorter segments are easier to transfer and edit. No frames are lost.")) {
            ForEach(SplitInterval.allCases) { interval in
                row(title: interval.label, subtitle: interval.detail, selected: settings.splitInterval == interval) {
                    settings.splitInterval = interval
                }
            }
        }
    }

    private var maxDurationSection: some View {
        Section(header: sectionHeader("Auto-Stop", icon: "timer"),
                footer: Text("Stops recording when the timer hits the limit.")) {
            Picker(selection: $settings.maxDuration) {
                ForEach(MaxDuration.allCases) { d in
                    Text(d.label).tag(d)
                }
            } label: {
                Label("Max duration", systemImage: "timer")
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.deep))
            }
            if settings.maxDuration != .off {
                Text(settings.maxDuration.subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Estimates (uses snapshot — no live updates)

    private var estimateSection: some View {
        Section(header: sectionHeader("Storage Cost", icon: "internaldrive")) {
            infoRow("Space per hour", "\(Int(plan.megabytesPerHour.rounded())) MB")
            infoRow("Room left", Fmt.hours(hoursLeft))
            infoRow("Bitrate", "\(plan.videoBitrate / 1000) kbit/s"
                     + (plan.hasAudio ? " + \(plan.audioBitrate / 1000) audio" : ""))
            infoRow("Free space", Fmt.size(freeBytesSnapshot))
        }
    }

    // MARK: - Camera tools

    private var cameraSection: some View {
        Section(header: sectionHeader("Camera Tools", icon: "camera.fill"),
                footer: Text(stabilizationSupported
                             ? "Stabilisation steadies the picture. Off = slightly wider view."
                             : "This camera does not offer stabilisation.")) {

            Toggle(isOn: $settings.stabilization) {
                Label("Optical stabilisation", systemImage: "hand.raised.fill")
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.deep))
            }
            .onChange(of: settings.stabilization) { _ in recorder.updateStabilization() }
            .disabled(!stabilizationSupported)

            Toggle(isOn: $settings.showLevelGauge) {
                Label("Horizon level meter", systemImage: "gyroscope")
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.color))
            }

            Toggle(isOn: $settings.recordAudio) {
                Label("Record sound", systemImage: "mic.fill")
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.bright))
            }
            .onChange(of: settings.recordAudio) { _ in recorder.syncMicInput() }

            Picker(selection: $settings.gridStyle) {
                ForEach(GridStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            } label: {
                Label("Grid overlay", systemImage: "grid")
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.color))
            }

            Toggle(isOn: $settings.saveSelfiesUnmirrored) {
                Label("Save selfies unmirrored", systemImage: "arrow.left.and.right")
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.deep))
            }
        }
    }

    // MARK: - Feedback

    private var feedbackSection: some View {
        Section(header: sectionHeader("Feedback", icon: "hand.tap.fill"),
                footer: Text("Sounds, haptics and on-screen cues. None change what is recorded.")) {

            Toggle(isOn: $settings.autoDimOnRecord) {
                Label("Auto-dim when filming", systemImage: "moon.stars.fill")
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.deep))
            }

            Toggle(isOn: $settings.shutterSoundEnabled) {
                Label("Shutter & dial sounds", systemImage: "speaker.wave.2.fill")
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.bright))
            }

            Toggle(isOn: $settings.hapticFeedbackEnabled) {
                Label("Haptic feedback", systemImage: "hand.tap.fill")
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.color))
            }

            Toggle(isOn: $settings.captureFlashConfirmation) {
                Label("Flash on capture", systemImage: "bolt.badge.a.fill")
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.bright))
            }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section(header: sectionHeader("Appearance", icon: "paintpalette.fill"),
                footer: Text("Accent colour for shutter, highlights and controls.")) {
            HStack(spacing: 0) {
                ForEach(AccentColor.allCases) { color in
                    let isSelected = settings.accentColor == color
                    Button(action: {
                        settings.accentColor = color
                        presetHaptic.selectionChanged()
                    }) {
                        VStack(spacing: 5) {
                            ZStack {
                                Facet(sides: 6, rotation: .pi / 6)
                                    .fill(
                                        LinearGradient(
                                            colors: [color.bright, color.color],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 34, height: 34)
                                    .shadow(color: color.color.opacity(isSelected ? 0.45 : 0.15),
                                            radius: isSelected ? 6 : 2)

                                if isSelected {
                                    Facet(sides: 6, rotation: .pi / 6)
                                        .stroke(Color.white, lineWidth: 2.2)
                                        .frame(width: 40, height: 40)
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(Palette.slateDeep)
                                }
                            }
                            .frame(width: 42, height: 42)

                            Text(shortAccentName(color))
                                .font(.system(size: 9, weight: isSelected ? .bold : .medium, design: .rounded))
                                .foregroundColor(isSelected ? color.bright : .secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(color.label)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func shortAccentName(_ color: AccentColor) -> String {
        switch color {
        case .mint: return "Mint"
        case .violet: return "Lavender"
        case .amber: return "Gold"
        case .red: return "Red"
        case .ice: return "Ice"
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        Section(header: sectionHeader("Video Format", icon: "film"),
                footer: Text(settings.useHEVC
                             ? "HEVC packs the same picture into roughly half the space."
                             : "H.264 plays everywhere but needs more space.")) {

            row(title: "HEVC",
                subtitle: "Smaller files · modern default",
                icon: "sparkles",
                iconColor: settings.accentColor.color,
                selected: settings.useHEVC) {
                settings.useHEVC = true
            }
            row(title: "H.264",
                subtitle: "Bigger files · plays on everything",
                icon: "film.fill",
                iconColor: settings.accentColor.deep,
                selected: !settings.useHEVC) {
                settings.useHEVC = false
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section(header: sectionHeader("Good to Know", icon: "info.circle.fill")) {
            aboutRow(icon: "shield.lefthalf.filled",
                     title: "Crash & Power Loss Safe",
                     body: "Video is saved in short fragments. If the battery dies, footage up to that moment is recovered.")
            aboutRow(icon: "moon.fill",
                     title: "Screen Must Stay On",
                     body: "iOS does not allow background filming. Use the moon button to dim while recording.")
            aboutRow(icon: "hand.tap.fill",
                     title: "Quick Shortcuts",
                     body: "Double-tap the preview to flip cameras. Volume Up/Down work as a shutter.")
        }
    }

    // MARK: - Slow-Mo

    private var slowMoFrameRateSection: some View {
        Section(header: sectionHeader("Slow-Mo Speed", icon: "tortoise.fill"),
                footer: Text(isSlowMoSupported
                             ? "Higher fps = smoother, slower playback."
                             : "Slow motion is not available on this camera lens.")) {
            ForEach(SlowMoFrameRate.allCases) { rate in
                let available = availableSlowMoRates.contains(rate)
                row(title: "\(rate.label)  (\(rate.multiplierLabel) slow)",
                    subtitle: available ? rate.detail : "Not available on this camera",
                    selected: settings.slowMoFrameRate == rate,
                    enabled: available) {
                    settings.slowMoFrameRate = rate
                    recorder.updateCaptureFormat()
                }
            }
        }
    }

    private var slowMoResolutionSection: some View {
        Section(header: sectionHeader("Slow-Mo Resolution", icon: "rectangle.dashed"),
                footer: Text("Some frame rates limit the maximum resolution on this iPhone.")) {
            ForEach(Resolution.allCases.filter { $0 != .p2160 }) { r in
                let available = availableSlowMoResolutions.contains(r)
                row(title: r.label,
                    subtitle: available ? r.detail : "Not available at \(settings.slowMoFrameRate.label)",
                    selected: settings.slowMoResolution == r,
                    enabled: available) {
                    settings.slowMoResolution = r
                    recorder.updateCaptureFormat()
                }
            }
        }
    }

    // MARK: - Building blocks

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(settings.accentColor.color)
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .textCase(nil)
        }
    }

    private func row(title: String,
                     subtitle: String,
                     icon: String? = nil,
                     iconColor: Color? = nil,
                     selected: Bool,
                     enabled: Bool = true,
                     tap: @escaping () -> Void) -> some View {
        Button(action: {
            guard enabled else { return }
            if settings.hapticFeedbackEnabled {
                presetHaptic.selectionChanged()
            }
            tap()
        }) {
            HStack(spacing: 12) {
                if let icon = icon, let color = iconColor {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(enabled ? color : Color.gray.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundColor(enabled ? .primary : .secondary)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                if selected && enabled {
                    Image(systemName: "checkmark")
                        .foregroundColor(settings.accentColor.color)
                        .font(.system(size: 15, weight: .bold))
                } else if !enabled {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.secondary.opacity(0.4))
                        .font(.system(size: 12))
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 15, weight: .regular, design: .rounded))
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func aboutRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(settings.accentColor.bright)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text(body)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private var hoursLeft: Double {
        let perHour = plan.megabytesPerHour * 1_000_000
        guard perHour > 0 else { return 0 }
        return Double(max(0, freeBytesSnapshot - CameraRecorder.reserveBytes)) / perHour
    }
}

// MARK: - Snappy preset button

private struct PresetButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
