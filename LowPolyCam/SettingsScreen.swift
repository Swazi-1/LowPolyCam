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
                        // Always the selected theme accent — never deep/bright variants.
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
    @State private var showPresetsSheet = false
    @State private var showAboutSheet = false
    @State private var presetHaptic = UISelectionFeedbackGenerator()
    @State private var freeBytesSnapshot: Int64 = 0
    @State private var isFrontSnapshot = false
    @State private var availableResolutions: [Resolution] = Resolution.allCases
    @State private var availableFrameRates: [FrameRate] = FrameRate.allCases
    @State private var availableSlowMoRates: [SlowMoFrameRate] = SlowMoFrameRate.allCases
    @State private var availableSlowMoResolutions: [Resolution] = [.p1080, .p720]
    @State private var availablePhotoMegapixels: [PhotoMegapixels] = PhotoMegapixels.allCases
    @State private var isSlowMoSupported = true
    @State private var stabilizationSupported = true

    private var plan: EncodePlan { Encoder.plan(for: settings) }

    var body: some View {
        NavigationView {
            List {
                summarySection

                if isFrontSnapshot { frontCameraBanner }

                // Strict mode separation — nothing that does not affect the active mode.
                switch settings.cameraMode {
                case .video:
                    quickPresetsEntrySection
                    videoCaptureSection
                    outputSection
                    videoAssistSection
                    advancedSection
                case .slowMo:
                    slowMoFrameRateSection
                    slowMoResolutionSection
                    videoQualitySection
                    slowMoOutputSection
                    slowMoAssistSection
                    advancedSection
                case .photo:
                    // Photo only: size + where to save + framing assists.
                    // No video quality, codec, frame rate, stab, split, etc.
                    photoMegapixelsSection
                    photoBurstSection
                    photoFormatSection
                    photoOutputSection
                    photoAssistSection
                }

                feedbackSection
                appearanceSection

                // Small entry — opens Good to Know sheet
                aboutEntrySection
            }
            .listStyle(InsetGroupedListStyle())
            .id(settings.cameraMode)
            .animation(nil, value: settings.cameraMode)
            .animation(nil, value: settings.accentColor)
            .animation(nil, value: appliedPresetId)
            .transaction { $0.animation = nil }
            .navigationViewStyle(StackNavigationViewStyle())
            .navigationBarTitle("Settings", displayMode: .inline)
            .navigationBarItems(trailing: Button(action: {
                presentation.wrappedValue.dismiss()
            }) {
                Text("Done")
                    .font(.system(size: 16, weight: .bold))
            })
            .sheet(isPresented: $showPresetsSheet) {
                presetsSheet
            }
            .sheet(isPresented: $showAboutSheet) {
                aboutSheet
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(settings.accentColor.color)
        .onAppear {
            syncCapabilitiesFromRecorder()
        }
        .onChange(of: settings.slowMoResolution) { newRes in
            // Instantly re-scope FPS chips to the newly selected slow-mo resolution
            // without waiting for the async format-apply round-trip.
            let rates = recorder.slowRatesByResolution[newRes] ?? []
            availableSlowMoRates = SlowMoFrameRate.allCases.filter { rates.contains($0) }
            if !availableSlowMoRates.contains(settings.slowMoFrameRate) {
                settings.slowMoFrameRate = availableSlowMoRates.first ?? .fps120
            }
            recorder.updateCaptureFormat()
        }
    }

    private func syncCapabilitiesFromRecorder() {
        presetHaptic.prepare()
        freeBytesSnapshot = recorder.freeBytes
        isFrontSnapshot = recorder.isFrontCamera
        availableResolutions = recorder.availableResolutions
        availableFrameRates = recorder.availableFrameRates
        availableSlowMoRates = recorder.availableSlowMoRates
        availableSlowMoResolutions = recorder.availableSlowMoResolutions
        availablePhotoMegapixels = recorder.availablePhotoMegapixels
        isSlowMoSupported = recorder.isSlowMoSupportedOnCurrentLens
        stabilizationSupported = recorder.stabilizationSupported
    }

    // MARK: - Summary card

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(settings.cameraMode.label)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Spacer()
                    Text(compactPlanLabel)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(settings.accentColor.color)
                }
                if settings.cameraMode != .photo {
                    Text("\(shortQualityLabel(settings.quality)) · \(settings.saveLocation.label) · Split \(shortSplitLabel(settings.splitInterval))")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                    Text("~\(Int(plan.megabytesPerHour.rounded())) MB/h · \(Fmt.size(freeBytesSnapshot)) free")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary.opacity(0.9))
                } else {
                    Text("\(settings.photoMegapixels.label) · \(settings.saveLocation.label)")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var compactPlanLabel: String {
        if settings.cameraMode == .photo {
            return settings.photoMegapixels.label
        }
        if settings.cameraMode == .slowMo {
            return "\(settings.slowMoResolution.label) · \(settings.slowMoFrameRate.label)"
        }
        return "\(settings.resolution.label) · \(settings.frameRate.label)"
    }

    // MARK: - Video capture (res + fps + quality in one place)

    private var videoCaptureSection: some View {
        Section(header: sectionHeader("Video", icon: "video.fill"),
                footer: Text("Swipe chips sideways for more options (e.g. 144p).")) {
            labeledChipRow(title: "Resolution", showMoreHint: true) {
                // Front camera: hide unsupported entirely. Rear: show grey/locked.
                let resItems: [Resolution] = isFrontSnapshot
                    ? availableResolutions
                    : Resolution.allCases.filter { $0 != .p144 || availableResolutions.contains(.p144) }
                chipRow(resItems.map { r in
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

            labeledChipRow(title: "Frame rate") {
                let rateItems: [FrameRate] = isFrontSnapshot
                    ? availableFrameRates.filter { !(settings.resolution == .p2160 && $0 == .fps60) }
                    : FrameRate.allCases
                chipRow(rateItems.map { f in
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

            labeledChipRow(title: "Quality") {
                chipRow(Quality.allCases.map { q in
                    ChipItem(id: q.id, label: shortQualityLabel(q),
                              selected: settings.quality == q) {
                        settings.quality = q
                    }
                })
            }
        }
    }

    private func labeledChipRow<Content: View>(title: String, showMoreHint: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
                if showMoreHint {
                    Image(systemName: "chevron.left.2")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                    Text("swipe")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
            content()
        }
        .padding(.vertical, 2)
    }

    // MARK: - Output

    private var outputSection: some View {
        Section(header: sectionHeader("Output", icon: "tray.and.arrow.down.fill"),
                footer: Text(settings.cameraMode == .photo
                             ? settings.saveLocation.detail
                             : "Where clips go, and how long each file runs.")) {
            // Save destination as clear tappable choices
            HStack(spacing: 10) {
                ForEach(SaveLocation.allCases) { loc in
                    let on = settings.saveLocation == loc
                    Button {
                        settings.saveLocation = loc
                        if settings.hapticFeedbackEnabled { presetHaptic.selectionChanged() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: loc == .photos ? "photo.on.rectangle" : "folder.fill")
                                .font(.system(size: 12, weight: .semibold))
                            Text(loc.label)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                        }
                        .foregroundColor(on ? .white : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(on ? settings.accentColor.color : Color.secondary.opacity(0.14))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 8, trailing: 16))

            if settings.cameraMode != .photo {
                HStack(spacing: 8) {
                    Text("Split")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary)
                        .frame(width: 44, alignment: .leading)
                    ForEach(SplitInterval.allCases) { interval in
                        let on = settings.splitInterval == interval
                        Button {
                            settings.splitInterval = interval
                            if settings.hapticFeedbackEnabled { presetHaptic.selectionChanged() }
                        } label: {
                            Text(shortSplitLabel(interval))
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundColor(on ? .white : .primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule().fill(on ? settings.accentColor.color : Color.secondary.opacity(0.14))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }

                Picker(selection: $settings.maxDuration) {
                    ForEach(MaxDuration.allCases) { d in
                        Text(d.label).tag(d)
                    }
                } label: {
                    Label("Auto-stop", systemImage: "timer")
                        .labelStyle(SettingsLabelStyle(color: settings.accentColor.color))
                }

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
                    .background(settings.accentColor.color)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Selfie camera")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Only options this lens supports are shown.")
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
            let resItems: [Resolution] = isFrontSnapshot
                ? availableResolutions
                : Resolution.allCases.filter { $0 != .p144 || availableResolutions.contains(.p144) }
            chipRow(resItems.map { r in
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
            let rateItems: [FrameRate] = isFrontSnapshot
                ? availableFrameRates.filter { !(settings.resolution == .p2160 && $0 == .fps60) }
                : FrameRate.allCases
            chipRow(rateItems.map { f in
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

    /// Video / Slow-Mo bitrate quality only (not used for still photos).
    private var videoQualitySection: some View {
        Section(header: sectionHeader("Quality", icon: "slider.horizontal.3"),
                footer: Text(videoQualityFooter)) {
            chipRow(Quality.allCases.map { q in
                ChipItem(id: q.id, label: shortQualityLabel(q),
                          selected: settings.quality == q) {
                    settings.quality = q
                }
            })
        }
    }

    private var videoQualityFooter: String {
        switch settings.quality {
        case .high: return "Highest bitrate · larger files"
        case .medium: return "Balanced quality and size"
        case .low: return "Smaller files · still clear"
        case .ultraLow: return "Smallest files · longest sessions"
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

    // MARK: - Quick Presets (entry + sheet)

    private var quickPresetsEntrySection: some View {
        Section {
            Button(action: { showPresetsSheet = true }) {
                HStack(spacing: 12) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(settings.accentColor.color)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quick Presets")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)
                        Text("Balanced, Social, All Day…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var presetsSheet: some View {
        NavigationView {
            List {
                ForEach(CapturePreset.all.filter { preset in
                    // Front camera: no 4K, and no 60 fps if the lens can't do it.
                    if recorder.isFrontCamera {
                        if preset.resolution == .p2160 { return false }
                        if preset.frameRate == .fps60 && !recorder.availableFrameRates.contains(.fps60) {
                            return false
                        }
                    }
                    return true
                }) { preset in
                    Button(action: {
                        applyPresetNow(preset)
                        showPresetsSheet = false
                    }) {
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
                                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                                    .foregroundColor(.primary)
                                Text(preset.detail)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary.opacity(0.45))
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationBarTitle("Quick Presets", displayMode: .inline)
            .navigationBarItems(trailing: Button("Cancel") {
                showPresetsSheet = false
            })
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(settings.accentColor.color)
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
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.color))
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

    // MARK: - Assist (mode-specific)
    //
    // Each mode's Capture Assist section picks a subset of `assistToggles`
    // (declared below) plus the `assistGrid` picker. To add a new Assist
    // toggle: add one `SettingsToggleSpec` to `assistToggles`, then list its
    // `id` in whichever mode section(s) should show it — no new `some View`
    // property required. See SettingsRowKit.swift for how the group renders.

    /// Every Capture Assist toggle, keyed by id. Mode sections below select
    /// a subset by id via `assistToggleGroup(ids:)`.
    private var assistToggles: [SettingsToggleSpec] {
        [
            SettingsToggleSpec(
                id: "stabilisation",
                title: "Stabilisation",
                icon: "hand.raised.fill",
                isOn: $settings.stabilization,
                onChange: { _ in recorder.updateStabilization() },
                // Hide (not grey) when this lens cannot stabilise (typical for front camera).
                isVisible: stabilizationSupported
            ),
            SettingsToggleSpec(
                id: "levelMeter",
                title: "Level meter",
                icon: "gyroscope",
                isOn: $settings.showLevelGauge
            ),
            SettingsToggleSpec(
                id: "autoDim",
                title: "Auto-dim when filming",
                icon: "moon.stars.fill",
                isOn: $settings.autoDimOnRecord
            ),
            SettingsToggleSpec(
                id: "longevity",
                title: "Longevity Mode",
                icon: "leaf.fill",
                isOn: $settings.longevityMode,
                onChange: { _ in recorder.refreshIdleFormatIfNeeded() }
            ),
            // 📊 Opt-in live stats readout (measured fps / bitrate) shown in
            // the recording HUD. Off by default — purely additive.
            SettingsToggleSpec(
                id: "recordingStats",
                title: "Live recording stats",
                icon: "waveform.path.ecg",
                isOn: $settings.showRecordingStats
            )
        ]
    }

    /// Renders the subset of `assistToggles` matching `ids`, in `ids` order.
    private func assistToggleGroup(ids: [String]) -> some View {
        let bySpecId = Dictionary(uniqueKeysWithValues: assistToggles.map { ($0.id, $0) })
        let ordered = ids.compactMap { bySpecId[$0] }
        return SettingsToggleGroup(specs: ordered, accentColor: settings.accentColor.color)
    }

    private var videoAssistSection: some View {
        Section(header: sectionHeader("Capture Assist", icon: "viewfinder")) {
            assistToggleGroup(ids: ["stabilisation"])
            assistGrid
            assistToggleGroup(ids: ["levelMeter", "autoDim", "longevity", "recordingStats"])
        }
    }

    private var slowMoAssistSection: some View {
        Section(header: sectionHeader("Capture Assist", icon: "viewfinder"),
                footer: Text("Video-only options (split, HEVC presets) are hidden in Slow-Mo.")) {
            assistGrid
            assistToggleGroup(ids: ["levelMeter", "longevity", "recordingStats"])
        }
    }

    private var photoAssistSection: some View {
        Section(header: sectionHeader("Capture Assist", icon: "viewfinder"),
                footer: Text("Video settings are hidden while you are in Photo mode.")) {
            assistGrid
            assistToggleGroup(ids: ["levelMeter"])
        }
    }

    private var assistGrid: some View {
        SettingsPickerRow(
            title: "Grid overlay",
            icon: "grid",
            accentColor: settings.accentColor.color,
            selection: $settings.gridStyle,
            label: { Text($0.label) }
        )
    }

    // MARK: - Output (mode-specific)

    private var slowMoOutputSection: some View {
        Section(header: sectionHeader("Output", icon: "tray.and.arrow.down.fill")) {
            outputSaveButtons
            infoRow("Space / hour", "\(Int(plan.megabytesPerHour.rounded())) MB")
            infoRow("Room left", Fmt.hours(hoursLeft))
        }
    }

    private var photoOutputSection: some View {
        Section(header: sectionHeader("Output", icon: "tray.and.arrow.down.fill"),
                footer: Text(settings.saveLocation.detail)) {
            outputSaveButtons
        }
    }

    private var outputSaveButtons: some View {
        HStack(spacing: 10) {
            ForEach(SaveLocation.allCases) { loc in
                let on = settings.saveLocation == loc
                Button {
                    settings.saveLocation = loc
                    if settings.hapticFeedbackEnabled { presetHaptic.selectionChanged() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: loc == .photos ? "photo.on.rectangle" : "folder.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text(loc.label)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(on ? .white : .primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(on ? settings.accentColor.color : Color.secondary.opacity(0.14))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 8, trailing: 16))
    }

    // MARK: - Feedback (sounds / haptics)

    private var feedbackSection: some View {
        Section(header: sectionHeader("Sounds & Haptics", icon: "speaker.wave.2.fill")) {
            Toggle(isOn: $settings.shutterSoundEnabled) {
                Label("Shutter & dial sounds", systemImage: "speaker.wave.2.fill")
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.color))
            }

            Toggle(isOn: $settings.hapticFeedbackEnabled) {
                Label("Haptic feedback", systemImage: "hand.tap.fill")
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.color))
            }
        }
    }

    // MARK: - Good to Know entry + sheet

    private var aboutEntrySection: some View {
        Section {
            Button(action: { showAboutSheet = true }) {
                HStack {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(settings.accentColor.color)
                    Text("Good to Know")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var aboutSheet: some View {
        NavigationView {
            List {
                aboutRow(icon: "shield.lefthalf.filled",
                         title: "Crash Safe",
                         body: "Clips save in small pieces so a dead battery rarely loses the whole take.")
                aboutRow(icon: "moon.fill",
                         title: "Cooler When Idle",
                         body: "Preview uses a lighter sensor path until you hit record.")
                aboutRow(icon: "leaf.fill",
                         title: "Longevity Mode",
                         body: "Optional. Lower heat and smaller files for long sessions on older iPhones.")
                aboutRow(icon: "sparkles",
                         title: "Built for iPhone 7",
                         body: "Tuned for A10 and 2 GB RAM on iOS 15.8.x.")
            }
            .listStyle(InsetGroupedListStyle())
            .navigationBarTitle("Good to Know", displayMode: .inline)
            .navigationBarItems(trailing: Button("Done") { showAboutSheet = false })
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(settings.accentColor.color)
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
                iconColor: settings.accentColor.color,
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
            // Only show sizes this lens can deliver (front camera often maxes ~7 MP).
            let mpItems = availablePhotoMegapixels.isEmpty ? PhotoMegapixels.allCases : availablePhotoMegapixels
            chipRow(mpItems.map { mp in
                ChipItem(id: "mp-\(mp.id)", label: mp.label,
                         selected: settings.photoMegapixels == mp) {
                    settings.photoMegapixels = mp
                }
            })
        }
    }

    // MARK: - Photo 2.0: Burst, format, aspect, review

    private var photoBurstSection: some View {
        Section(header: sectionHeader("Burst Mode", icon: "square.stack.3d.up.fill"),
                footer: Text("Press and hold the shutter to fire a burst. A quick tap still takes a single photo.")) {
            chipRow(BurstCount.allCases.map { count in
                ChipItem(id: "burst-\(count.id)", label: "\(count.label) photos",
                         selected: settings.burstCount == count) {
                    settings.burstCount = count
                }
            })
        }
    }

    private var photoFormatSection: some View {
        Section(header: sectionHeader("Format & Framing", icon: "square.on.square")) {
            SettingsPickerRow(
                title: "File format",
                icon: "doc.fill",
                accentColor: settings.accentColor.color,
                selection: $settings.photoFormat,
                label: { Text($0.label) }
            )
            SettingsPickerRow(
                title: "Aspect ratio",
                icon: "crop",
                accentColor: settings.accentColor.color,
                selection: $settings.photoAspect,
                label: { Text($0.label) }
            )
            Toggle(isOn: $settings.photoReviewAfterCapture) {
                Label("Review after capture", systemImage: "eye.fill")
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.color))
            }
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
