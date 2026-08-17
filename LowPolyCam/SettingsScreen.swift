import SwiftUI

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
            .navigationBarItems(trailing: Button("Done") {
                presentation.wrappedValue.dismiss()
            })
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(Palette.mint)
    }

    // MARK: Sections

    /// Explains up front why some rows below are greyed out, rather than
    /// leaving them looking broken.
    private var frontCameraBanner: some View {
        Section {
            HStack(spacing: 12) {
                Facet(sides: 6, rotation: .pi / 6)
                    .fill(Palette.violet.opacity(0.25))
                    .frame(width: 34, height: 34)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Palette.violet)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selfie camera")
                        .font(.system(size: 15, weight: .semibold))
                    Text("It offers fewer options than the back camera. Anything it cannot do is greyed out.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var resolutionSection: some View {
        Section(header: Text("Resolution"),
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
        return Section(header: Text("Frame rate"),
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
        Section(header: Text("Quality")) {
            ForEach(Quality.allCases) { q in
                row(title: q.label, subtitle: q.detail, selected: settings.quality == q) {
                    settings.quality = q
                }
            }
        }
    }

    private var saveSection: some View {
        Section(header: Text("Save recordings to")) {
            ForEach(SaveLocation.allCases) { s in
                row(title: s.label, subtitle: s.detail, selected: settings.saveLocation == s) {
                    settings.saveLocation = s
                }
            }
        }
    }

    private var splitSection: some View {
        Section(header: Text("Split recordings"),
                footer: Text("Splitting into shorter segments makes large files easier to transfer, edit, and share, without losing any frames between clips.")) {
            ForEach(SplitInterval.allCases) { interval in
                row(title: interval.label, subtitle: interval.detail, selected: settings.splitInterval == interval) {
                    settings.splitInterval = interval
                }
            }
        }
    }

    private var estimateSection: some View {
        Section(header: Text("What that costs")) {
            info("Space per hour", "\(Int(plan.megabytesPerHour.rounded())) MB")
            info("Room left on this phone", Fmt.hours(hoursLeft))
            info("Bitrate", "\(plan.videoBitrate / 1000) kbit/s video"
                 + (plan.hasAudio ? " + \(plan.audioBitrate / 1000) audio" : ""))
            info("Free space", Fmt.size(recorder.freeBytes))
        }
    }

    private var cameraSection: some View {
        Section(header: Text("Camera"),
                footer: Text(recorder.stabilizationSupported
                             ? "Steadies the picture. Turning it off gives a slightly wider view and uses a little less power."
                             : "This camera does not offer stabilisation, so the switch has no effect here.")) {

            Toggle("Optical image stabilisation", isOn: $settings.stabilization)
                .onChange(of: settings.stabilization) { _ in recorder.updateStabilization() }
                .disabled(!recorder.stabilizationSupported)

            Toggle("Low-power torch", isOn: $settings.lowTorch)
                .disabled(!recorder.hasTorch)

            Toggle("Record sound", isOn: $settings.recordAudio)
                .onChange(of: settings.recordAudio) { _ in recorder.syncMicInput() }

            Toggle("Grid overlay", isOn: $settings.showGrid)
        }
    }

    private var advancedSection: some View {
        Section(header: Text("Video format"),
                footer: Text(settings.useHEVC
                             ? "HEVC gets the same picture into roughly half the space. Plays on the iPhone and in VLC. Switch to H.264 if some other player refuses the files."
                             : "H.264 plays everywhere but needs about 60% more space for the same picture as HEVC.")) {
            row(title: "HEVC", subtitle: "Smaller files, the modern default", selected: settings.useHEVC) {
                settings.useHEVC = true
            }
            row(title: "H.264", subtitle: "Bigger files, plays on almost anything", selected: !settings.useHEVC) {
                settings.useHEVC = false
            }
        }
    }

    private var aboutSection: some View {
        Section(header: Text("Good to know")) {
            Text("A recording is written a few seconds at a time in fragments, so if the battery dies mid-recording, the footage up to that moment survives and is filed away next time the app opens.")
                .font(.footnote)
                .foregroundColor(.secondary)
            Text("Filming stops when the app leaves the screen. iOS gives no app permission to keep the camera running in the background, so the screen has to stay on. The moon button dims it to black while recording.")
                .font(.footnote)
                .foregroundColor(.secondary)
            Text("Physical Volume Up and Volume Down buttons also act as a shutter to start and stop recording.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Slow-Mo sections

    private var slowMoFrameRateSection: some View {
        Section(header: Text("Slow-Mo Speed"),
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
        Section(header: Text("Slow-Mo Resolution"),
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
                     selected: Bool,
                     enabled: Bool = true,
                     tap: @escaping () -> Void) -> some View {
        Button(action: { if enabled { tap() } }) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundColor(enabled ? .primary : .secondary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if selected && enabled {
                    Image(systemName: "checkmark")
                        .foregroundColor(Palette.mintDeep)
                        .font(.system(size: 15, weight: .semibold))
                } else if !enabled {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.secondary.opacity(0.5))
                        .font(.system(size: 12))
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
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }

    private var hoursLeft: Double {
        let perHour = plan.megabytesPerHour * 1_000_000
        guard perHour > 0 else { return 0 }
        return Double(max(0, recorder.freeBytes - CameraRecorder.reserveBytes)) / perHour
    }
}
