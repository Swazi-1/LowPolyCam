import SwiftUI

struct SettingsScreen: View {

    @ObservedObject var settings: AppSettings
    @ObservedObject var recorder: CameraRecorder
    @Environment(\.presentationMode) private var presentation

    private var plan: EncodePlan { Encoder.plan(for: settings) }

    var body: some View {
        NavigationView {
            List {
                resolutionSection
                qualitySection
                frameRateSection
                saveSection
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
    }

    // MARK: Sections

    private var resolutionSection: some View {
        Section(header: Text("Resolution"),
                footer: Text("Recording at \(plan.sizeLabel).")) {
            ForEach(Resolution.allCases) { r in
                row(title: r.label, subtitle: r.detail, selected: settings.resolution == r) {
                    settings.resolution = r
                    recorder.updateCaptureFormat()
                }
            }
        }
    }

    private var frameRateSection: some View {
        Section(header: Text("Frame rate")) {
            ForEach(FrameRate.allCases) { f in
                row(title: f.label, subtitle: f.detail, selected: settings.frameRate == f) {
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

            Toggle("Record sound", isOn: $settings.recordAudio)
                .onChange(of: settings.recordAudio) { _ in recorder.syncMicInput() }
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
            Text("Recording is split into \(Int(CameraRecorder.segmentSeconds / 60))-minute clips, so a crash or a flat battery costs you seconds, not the whole session.")
                .font(.footnote)
                .foregroundColor(.secondary)
            Text("Filming stops when the app leaves the screen. iOS gives no app permission to keep the camera running in the background, so the screen has to stay on. The moon button dims it to black while recording.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Pieces

    private func row(title: String, subtitle: String, selected: Bool, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundColor(.primary)
                    Text(subtitle).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
