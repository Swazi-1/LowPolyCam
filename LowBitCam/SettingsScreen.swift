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
                estimateSection
                advancedSection
                filesSection
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
        Section(header: Text("Resolution")) {
            ForEach(Resolution.allCases) { r in
                row(title: r.label, subtitle: r.detail, selected: settings.resolution == r) {
                    settings.resolution = r
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

    private var estimateSection: some View {
        Section(header: Text("What that costs")) {
            info("Space per hour", "\(Int(plan.megabytesPerHour.rounded())) MB")
            info("Room left on this phone", Fmt.hours(hoursLeft))
            info("Bitrate", "\(plan.videoBitrate / 1000) kbit/s video"
                 + (plan.hasAudio ? " + \(plan.audioBitrate / 1000) audio" : ""))
            info("Free space", Fmt.size(recorder.freeBytes))
        }
    }

    private var advancedSection: some View {
        Section(header: Text("Advanced")) {
            Toggle("Record sound", isOn: $settings.recordAudio)
                .onChange(of: settings.recordAudio) { _ in recorder.syncMicInput() }

            Toggle("HEVC (smaller files)", isOn: $settings.useHEVC)

            Text(settings.useHEVC
                 ? "HEVC gets the same picture into roughly half the space. Plays on the iPhone and in VLC. Turn it off if some other player refuses the files."
                 : "H.264 plays everywhere but needs about 60% more space for the same picture.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private var filesSection: some View {
        Section(header: Text("Recordings")) {
            Text("Clips land in the Files app under On My iPhone › LowBitCam. Recording is split into \(Int(CameraRecorder.segmentSeconds / 60))-minute files, so a crash or a flat battery costs you seconds, not the whole session.")
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
