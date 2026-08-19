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
                // Active setup summary
                summarySection

                if isFrontSnapshot { frontCameraBanner }

                // Capture — mode-specific, fewer separate sections
                if settings.cameraMode == .slowMo {
                    slowMoFrameRateSection
                    slowMoResolutionSection
                    qualitySection
                } else if settings.cameraMode == .photo {
                    photoMegapixelsSection
                    qualitySection
                } else {
                    presetsSection
                    videoCaptureSection
                }

                // Output
                outputSection

                // Assist + feedback side by side in spirit (separate list groups)
                captureAssistSection
                feedbackSection

                // Codec
                advancedSection

                // Theme + about
                appearanceSection
                aboutSection
            }
            .listStyle(InsetGroupedListStyle())
            // Isolate list identity per mode so photo/slo-mo don't reuse heavy video cells
            .id(settings.cameraMode)
            // Kill implicit animations that fight scrolling on A10
            .animation(nil, value: settings.cameraMode)
            .animation(nil, value: settings.accentColor)
            .animation(nil, value: appliedPresetId)
            .transaction { $0.animation = nil }
            // Drop the pull-down "search over the list" gesture recognizer
            // some iOS 15 List/NavigationView combos install even with no
            // .searchable() attached — it can compete with normal scroll's
            // gesture recognizer on older hardware, showing up as random
            // stutter that isn't tied to any one row's content.
            .navigationViewStyle(StackNavigationViewStyle())
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

    // MARK: - Summary card

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(settings.cameraMode.label.uppercased())
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(settings.accentColor.bright)
                        .tracking(0.8)
                    Spacer()
                    Text(plan.sizeLabel)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.85))
                }
                HStack(spacing: 16) {
                    summaryStat(title: "Quality", value: shortQualityLabel(settings.quality))
                    summaryStat(title: "Save", value: settings.saveLocation.label)
                    if settings.cameraMode != .photo {
                        summaryStat(title: "Split", value: shortSplitLabel(settings.splitInterval))
                    }
                }
                if settings.cameraMode != .photo {
                    Text("~\(Int(plan.megabytesPerHour.rounded())) MB/hr · \(Fmt.size(freeBytesSnapshot)) free")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func summaryStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Video capture (res + fps + quality in one place)

    private var videoCaptureSection: some View {
        Section(header: sectionHeader("Video", icon: "video.fill"),
                footer: Text("Recording at \(plan.sizeLabel).")) {
            Text("Resolution")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
            chipRow(Resolution.allCases
                .filter { $0 != .p144 || availableResolutions.contains(.p144) }
                .map { r in
                    ChipItem(id: r.id, label: r.label,
                             enabled: availableResolutions.contains(r),
                             selected: settings.resolution == r) {
                        settings.resolution = r
                        if let locked = r.lockedFrameRate {
                            settings.frameRate = locked
                        }
                        recorder.updateCaptureFormat()
                    }
                })

            Text("Frame rate")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
                .padding(.top, 6)
            chipRow(FrameRate.allCases.map { f in
                let enabled = availableFrameRates.contains(f)
                    && !(settings.resolution == .p2160 && f == .fps60)
                return ChipItem(id: "fr-\(f.id)", label: f.label,
                                 enabled: enabled,
                                 selected: settings.frameRate == f) {
                    settings.frameRate = f
                    recorder.updateCaptureFormat()
                }
            })

            Text("Quality")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
                .padding(.top, 6)
            chipRow(Quality.allCases.map { q in
                ChipItem(id: q.id, label: shortQualityLabel(q),
                          selected: settings.quality == q) {
                    settings.quality = q
                }
            })
        }
    }

    // MARK: - Output (save + split + auto-stop + storage)

    private var outputSection: some View {
        Section(header: sectionHeader("Output", icon: "tray.and.arrow.down.fill")) {
            Text("Save to")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
            chipRow(SaveLocation.allCases.map { s in
                ChipItem(id: s.id, label: s.label, selected: settings.saveLocation == s) {
                    settings.saveLocation = s
                }
            })

            if settings.cameraMode != .photo {
                Text("Split clips")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
                    .padding(.top, 6)
                chipRow(SplitInterval.allCases.map { interval in
                    ChipItem(id: interval.id, label: shortSplitLabel(interval),
                              selected: settings.splitInterval == interval) {
                        settings.splitInterval = interval
                    }
                })

                Picker(selection: $settings.maxDuration) {
                    ForEach(MaxDuration.allCases) { d in
                        Text(d.label).tag(d)
                    }
                } label: {
                    Label("Auto-stop", systemImage: "timer")
                        .labelStyle(SettingsLabelStyle(color: settings.accentColor.deep))
                }
                .padding(.top, 4)

                infoRow("Space / hour", "\(Int(plan.megabytesPerHour.rounded())) MB")
                infoRow("Room left", Fmt.hours(hoursLeft))
            }
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
            chipRow(Resolution.allCases
                .filter { $0 != .p144 || availableResolutions.contains(.p144) }
                .map { r in
                    ChipItem(id: r.id, label: r.label,
                             enabled: availableResolutions.contains(r),
                             selected: settings.resolution == r) {
                        settings.resolution = r
                        if let locked = r.lockedFrameRate {
                            settings.frameRate = locked
                        }
                        recorder.updateCaptureFormat()
                    }
                })
        }
    }

    private var frameRateSection: some View {
        Section(header: sectionHeader("Frame Rate", icon: "timer"),
                footer: Text(settings.resolution == .p2160
                             ? "4K is limited to 30 fps on this iPhone."
                             : "60 fps looks smoother and uses more space.")) {
            chipRow(FrameRate.allCases.map { f in
                let enabled = availableFrameRates.contains(f)
                    && !(settings.resolution == .p2160 && f == .fps60)
                return ChipItem(id: "fr-\(f.id)", label: f.label,
                                 enabled: enabled,
                                 selected: settings.frameRate == f) {
                    settings.frameRate = f
                    recorder.updateCaptureFormat()
                }
            })
        }
    }

    private var qualitySection: some View {
        Section(header: sectionHeader("Quality", icon: "slider.horizontal.3"),
                footer: Text(settings.quality.detail)) {
            chipRow(Quality.allCases.map { q in
                ChipItem(id: q.id, label: shortQualityLabel(q),
                          selected: settings.quality == q) {
                    settings.quality = q
                }
            })
        }
    }

    private func shortQualityLabel(_ q: Quality) -> String {
        switch q {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        case .ultraLow: return "Data Saver"
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
        Section(header: sectionHeader("Save To", icon: "folder.fill"),
                footer: Text(settings.saveLocation.detail)) {
            chipRow(SaveLocation.allCases.map { s in
                ChipItem(id: s.id, label: s.label, selected: settings.saveLocation == s) {
                    settings.saveLocation = s
                }
            })
        }
    }

    private var splitSection: some View {
        Section(header: sectionHeader("Split Recordings", icon: "scissors"),
                footer: Text("Shorter segments are easier to transfer and edit. No frames are lost.")) {
            chipRow(SplitInterval.allCases.map { interval in
                ChipItem(id: interval.id, label: shortSplitLabel(interval),
                          selected: settings.splitInterval == interval) {
                    settings.splitInterval = interval
                }
            })
        }
    }

    private func shortSplitLabel(_ interval: SplitInterval) -> String {
        switch interval {
        case .off: return "Off"
        case .oneHour: return "1 hr"
        case .fourHours: return "4 hr"
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

    // MARK: - Capture assist (while shooting)

    private var captureAssistSection: some View {
        Section(header: sectionHeader("Capture Assist", icon: "viewfinder"),
                footer: Text("Stabilisation, grid and longevity affect how the camera runs while you shoot.")) {

            Toggle(isOn: $settings.stabilization) {
                Label("Stabilisation", systemImage: "hand.raised.fill")
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.deep))
            }
            .onChange(of: settings.stabilization) { _ in recorder.updateStabilization() }
            .disabled(!stabilizationSupported)

            Picker(selection: $settings.gridStyle) {
                ForEach(GridStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            } label: {
                Label("Grid overlay", systemImage: "grid")
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.color))
            }

            Toggle(isOn: $settings.showLevelGauge) {
                Label("Level meter", systemImage: "gyroscope")
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.color))
            }

            Toggle(isOn: $settings.autoDimOnRecord) {
                Label("Auto-dim when filming", systemImage: "moon.stars.fill")
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.deep))
            }

            Toggle(isOn: $settings.longevityMode) {
                Label("Longevity Mode", systemImage: "leaf.fill")
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.color))
            }
            .onChange(of: settings.longevityMode) { _ in
                recorder.refreshIdleFormatIfNeeded()
            }

            Toggle(isOn: $settings.saveSelfiesUnmirrored) {
                Label("Save selfies unmirrored", systemImage: "arrow.left.and.right")
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.deep))
            }
        }
    }

    // MARK: - Feedback (sounds / haptics)

    private var feedbackSection: some View {
        Section(header: sectionHeader("Sounds & Haptics", icon: "speaker.wave.2.fill")) {
            Toggle(isOn: $settings.shutterSoundEnabled) {
                Label("Shutter & dial sounds", systemImage: "speaker.wave.2.fill")
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.bright))
            }

            Toggle(isOn: $settings.hapticFeedbackEnabled) {
                Label("Haptic feedback", systemImage: "hand.tap.fill")
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.color))
            }

            Toggle(isOn: $settings.captureFlashConfirmation) {
                Label("Screen flash on capture", systemImage: "bolt.badge.a.fill")
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.bright))
            }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section(header: sectionHeader("Theme", icon: "paintpalette.fill"),
                footer: Text("Accent for shutter, highlights and controls.")) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(AccentColor.allCases) { color in
                        let isSelected = settings.accentColor == color
                        Button(action: {
                            settings.accentColor = color
                            presetHaptic.selectionChanged()
                        }) {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [color.bright, color.color],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 36, height: 36)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.white, lineWidth: isSelected ? 2.5 : 0)
                                    )
                                    .shadow(color: color.color.opacity(isSelected ? 0.45 : 0.12),
                                            radius: isSelected ? 6 : 2)
                                Text(shortAccentName(color))
                                    .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .rounded))
                                    .foregroundColor(isSelected ? color.bright : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(color.label)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func shortAccentName(_ color: AccentColor) -> String {
        switch color {
        case .violet: return "Lavender"
        case .amber: return "Gold"
        case .red: return "Red"
        case .ice: return "Ice"
        case .aurora: return "Aurora"
        case .coral: return "Coral"
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
                     title: "Crash Safe",
                     body: "Saved in fragments — footage survives a dead battery.")
            aboutRow(icon: "moon.fill",
                     title: "Screen Stays On",
                     body: "No background filming on iOS. Use the moon button to dim.")
            aboutRow(icon: "hand.tap.fill",
                     title: "Shortcuts",
                     body: "Double-tap preview to flip cameras. Volume keys = shutter.")
            aboutRow(icon: "leaf.fill",
                     title: "Longevity Mode",
                     body: "Tuned for iPhone 7 & older chips — cooler, longer, smaller files.")
            aboutRow(icon: "sparkles",
                     title: "Horizon Edition",
                     body: "Built with imagination for the devices that keep going.")
        }
    }

    // MARK: - Photo

    private var photoMegapixelsSection: some View {
        Section(header: sectionHeader("Photo Size", icon: "camera.fill"),
                footer: Text("Captured at full sensor resolution, then saved at the size you pick. Lower MP uses less storage.")) {
            chipRow(PhotoMegapixels.allCases.map { mp in
                ChipItem(id: "mp-\(mp.id)", label: mp.label,
                         selected: settings.photoMegapixels == mp) {
                    settings.photoMegapixels = mp
                }
            })
        }
    }

    // MARK: - Slow-Mo

    private var slowMoFrameRateSection: some View {
        Section(header: sectionHeader("Slow-Mo Speed", icon: "tortoise.fill"),
                footer: Text(isSlowMoSupported
                             ? "Higher fps = smoother, slower playback."
                             : "Slow motion is not available on this camera lens.")) {
            chipRow(SlowMoFrameRate.allCases.map { rate in
                let available = availableSlowMoRates.contains(rate)
                return ChipItem(id: "sm-\(rate.id)", label: "\(rate.label) (\(rate.multiplierLabel))",
                                 enabled: available,
                                 selected: settings.slowMoFrameRate == rate) {
                    settings.slowMoFrameRate = rate
                    recorder.updateCaptureFormat()
                }
            })
        }
    }

    private var slowMoResolutionSection: some View {
        Section(header: sectionHeader("Slow-Mo Resolution", icon: "rectangle.dashed"),
                footer: Text("Some frame rates limit the maximum resolution on this iPhone.")) {
            chipRow(Resolution.allCases.filter { $0 != .p2160 }.map { r in
                let available = availableSlowMoResolutions.contains(r)
                return ChipItem(id: r.id, label: r.label,
                                 enabled: available,
                                 selected: settings.slowMoResolution == r) {
                    settings.slowMoResolution = r
                    recorder.updateCaptureFormat()
                }
            })
        }
    }

    // MARK: - Compact chip picker

    private struct ChipItem: Identifiable {
        let id: String
        let label: String
        var enabled: Bool = true
        var selected: Bool = false
        let action: () -> Void
    }

    private func chipRow(_ items: [ChipItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    Button(action: {
                        guard item.enabled else { return }
                        if settings.hapticFeedbackEnabled { presetHaptic.selectionChanged() }
                        item.action()
                    }) {
                        HStack(spacing: 4) {
                            Text(item.label)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                            if !item.enabled {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 9, weight: .bold))
                            }
                        }
                        .foregroundColor(
                            item.selected && item.enabled ? .white
                            : (item.enabled ? .primary : .secondary.opacity(0.5))
                        )
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(item.selected && item.enabled
                                      ? settings.accentColor.color
                                      : Color.secondary.opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!item.enabled)
                }
            }
            .padding(.vertical, 2)
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
