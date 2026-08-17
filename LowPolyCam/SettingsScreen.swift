import SwiftUI

struct SettingsLabelStyle: LabelStyle {
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 14) {
            configuration.icon
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(color)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: color.opacity(0.3), radius: 3, x: 0, y: 2)

            configuration.title
                .font(.system(size: 16, weight: .medium))
        }
    }
}

struct SettingsScreen: View {

    @ObservedObject var settings: AppSettings
    @ObservedObject var recorder: CameraRecorder
    @Environment(\.presentationMode) private var presentation

    private var plan: EncodePlan { Encoder.plan(for: settings) }

    var body: some View {
        NavigationView {
            List {
                if recorder.isFrontCamera { frontCameraBanner }
                if settings.cameraMode == .slowMo {
                    slowMoFrameRateSection
                    slowMoResolutionSection
                } else {
                    resolutionSection
                    frameRateSection
                }
                qualitySection
                saveSection
                splitSection
                estimateSection
                cameraSection
                advancedSection
                aboutSection
            }
            .listStyle(InsetGroupedListStyle())
            .navigationBarTitle("Settings", displayMode: .inline)
            .navigationBarItems(trailing: Button(action: {
                presentation.wrappedValue.dismiss()
            }) {
                Text("Done")
                    .font(.system(size: 16, weight: .bold))
            })
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(Palette.mint)
    }

    // MARK: Sections

    private var frontCameraBanner: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "person.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Palette.violet)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: Palette.violet.opacity(0.3), radius: 4, x: 0, y: 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Selfie camera")
                        .font(.system(size: 16, weight: .bold))
                    Text("It offers fewer options than the back camera. Anything it cannot do is greyed out.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var resolutionSection: some View {
        Section(header: Text("Resolution").font(.system(size: 13, weight: .semibold)),
                footer: Text("Recording at \(plan.sizeLabel).")) {
            ForEach(Resolution.allCases) { r in
                row(title: r.label,
                    subtitle: recorder.availableResolutions.contains(r) ? r.detail : "Not on this camera",
                    selected: settings.resolution == r,
                    enabled: recorder.availableResolutions.contains(r)) {
                    settings.resolution = r
                    recorder.updateCaptureFormat()
                }
            }
        }
    }

    private var frameRateSection: some View {
        let locked = settings.resolution.lockedFrameRate
        return Section(header: Text("Frame rate").font(.system(size: 13, weight: .semibold)),
                footer: Text(locked != nil
                             ? "\(settings.resolution.label) films at \(locked!.label) only."
                             : recorder.availableFrameRates.count < FrameRate.allCases.count
                             ? "This camera films at \(recorder.availableFrameRates.map { $0.label }.joined(separator: " or ")) only."
                             : "Higher frame rates look smoother and take more space.")) {
            ForEach(FrameRate.allCases) { f in
                let enabled = recorder.availableFrameRates.contains(f) && (locked == nil || locked == f)
                row(title: f.label,
                    subtitle: enabled ? f.detail : (locked != nil ? "\(settings.resolution.label) only films at \(locked!.label)" : "Not on this camera"),
                    selected: settings.frameRate == f,
                    enabled: enabled) {
                    settings.frameRate = f
                    recorder.updateCaptureFormat()
                }
            }
        }
    }

    private var qualitySection: some View {
        Section(header: Text("Quality").font(.system(size: 13, weight: .semibold))) {
            ForEach(Quality.allCases) { q in
                row(title: q.label, subtitle: q.detail, selected: settings.quality == q) {
                    settings.quality = q
                }
            }
        }
    }

    private var saveSection: some View {
        Section(header: Text("Save recordings to").font(.system(size: 13, weight: .semibold))) {
            ForEach(SaveLocation.allCases) { s in
                row(title: s.label, subtitle: s.detail, selected: settings.saveLocation == s) {
                    settings.saveLocation = s
                }
            }
        }
    }

    private var splitSection: some View {
        Section(header: Text("Split recordings").font(.system(size: 13, weight: .semibold)),
                footer: Text("Splitting into shorter segments makes large files easier to transfer, edit, and share, without losing any frames between clips.")) {
            ForEach(SplitInterval.allCases) { interval in
                row(title: interval.label, subtitle: interval.detail, selected: settings.splitInterval == interval) {
                    settings.splitInterval = interval
                }
            }
        }
    }

    private var estimateSection: some View {
        Section(header: Text("What that costs").font(.system(size: 13, weight: .semibold))) {
            info("Space per hour", "\(Int(plan.megabytesPerHour.rounded())) MB")
            info("Room left on this phone", Fmt.hours(hoursLeft))
            info("Bitrate", "\(plan.videoBitrate / 1000) kbit/s video"
                 + (plan.hasAudio ? " + \(plan.audioBitrate / 1000) audio" : ""))
            info("Free space", Fmt.size(recorder.freeBytes))
        }
    }

    private var cameraSection: some View {
        Section(header: Text("Camera Tools").font(.system(size: 13, weight: .semibold)),
                footer: Text(recorder.stabilizationSupported
                             ? "Stabilisation steadies the picture. Turning it off gives a slightly wider view and uses a little less power."
                             : "This camera does not offer stabilisation, so the switch has no effect here.")) {

            Toggle(isOn: $settings.stabilization) {
                Label("Optical stabilisation", systemImage: "hand.raised.fill")
                    .labelStyle(SettingsLabelStyle(color: Palette.violet))
            }
            .onChange(of: settings.stabilization) { _ in recorder.updateStabilization() }
            .disabled(!recorder.stabilizationSupported)

            Toggle(isOn: $settings.showLevelGauge) {
                Label("Horizon level meter", systemImage: "gyroscope")
                    .labelStyle(SettingsLabelStyle(color: Palette.mint))
            }

            Toggle(isOn: $settings.recordAudio) {
                Label("Record sound", systemImage: "mic.fill")
                    .labelStyle(SettingsLabelStyle(color: Palette.mintDeep))
            }
            .onChange(of: settings.recordAudio) { _ in recorder.syncMicInput() }

            Toggle(isOn: $settings.showGrid) {
                Label("Grid overlay", systemImage: "grid")
                    .labelStyle(SettingsLabelStyle(color: Palette.slateLight))
            }
        }
    }

    private var advancedSection: some View {
        Section(header: Text("Video format").font(.system(size: 13, weight: .semibold)),
                footer: Text(settings.useHEVC
                             ? "HEVC gets the same picture into roughly half the space. Plays on the iPhone and in VLC. Switch to H.264 if some other player refuses the files."
                             : "H.264 plays everywhere but needs about 60% more space for the same picture as HEVC.")) {

            row(title: "HEVC", subtitle: "Smaller files, the modern default", icon: "sparkles", iconColor: Palette.mintDeep, selected: settings.useHEVC) {
                settings.useHEVC = true
            }
            row(title: "H.264", subtitle: "Bigger files, plays on almost anything", icon: "film.fill", iconColor: Palette.slateLight, selected: !settings.useHEVC) {
                settings.useHEVC = false
            }
        }
    }

    private var aboutSection: some View {
        Section(header: Text("Good to know").font(.system(size: 13, weight: .semibold))) {
            Text("A recording is written a few seconds at a time in fragments, so if the battery dies mid-recording, the footage up to that moment survives and is filed away next time the app opens.")
                .font(.footnote)
                .foregroundColor(.secondary)
            Text("Filming stops when the app leaves the screen. iOS gives no app permission to keep the camera running in the background, so the screen has to stay on. The moon button dims it to black while recording.")
                .font(.footnote)
                .foregroundColor(.secondary)
            Text("Double-tap anywhere on the preview to quickly flip between cameras.")
                .font(.footnote)
                .foregroundColor(.secondary)
            Text("Physical Volume Up and Volume Down buttons also act as a shutter to start and stop recording.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Slow-Mo sections

    private var slowMoFrameRateSection: some View {
        Section(header: Text("Slow-Mo Speed").font(.system(size: 13, weight: .semibold)),
                footer: Text(recorder.isSlowMoSupportedOnCurrentLens
                             ? "Higher fps = smoother, slower playback."
                             : "Slow motion is not available on this camera lens.")) {
            ForEach(SlowMoFrameRate.allCases) { rate in
                let available = recorder.availableSlowMoRates.contains(rate)
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
        Section(header: Text("Slow-Mo Resolution").font(.system(size: 13, weight: .semibold)),
                footer: Text("Some frame rates limit the maximum resolution on this iPhone.")) {
            ForEach(Resolution.allCases) { r in
                let available = recorder.availableSlowMoResolutions.contains(r)
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

    // MARK: Pieces

    private func row(title: String,
                     subtitle: String,
                     icon: String? = nil,
                     iconColor: Color? = nil,
                     selected: Bool,
                     enabled: Bool = true,
                     tap: @escaping () -> Void) -> some View {
        Button(action: { if enabled { tap() } }) {
            HStack(spacing: 14) {
                if let icon = icon, let color = iconColor {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(enabled ? color : Color.gray.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: enabled ? color.opacity(0.3) : .clear, radius: 3, x: 0, y: 2)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(enabled ? .primary : .secondary)
                    Text(subtitle)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if selected && enabled {
                    Image(systemName: "checkmark")
                        .foregroundColor(Palette.mintDeep)
                        .font(.system(size: 16, weight: .bold))
                } else if !enabled {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.secondary.opacity(0.4))
                        .font(.system(size: 13))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 16, weight: .regular))
            Spacer()
            Text(value)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)
        }
    }

    private var hoursLeft: Double {
        let perHour = plan.megabytesPerHour * 1_000_000
        guard perHour > 0 else { return 0 }
        return Double(max(0, recorder.freeBytes - CameraRecorder.reserveBytes)) / perHour
    }
}
