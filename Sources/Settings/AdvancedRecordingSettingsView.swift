import SwiftUI

struct AdvancedRecordingSettingsView: View {
    @Environment(\.cameraTint) private var theme
    @ObservedObject var camera: CameraManager
    var positionStats: () -> Void
    @AppStorage("splitMinutes") private var splitMinutes = 0
    @AppStorage("appColorScheme") private var appColorScheme = "system"

    var body: some View {
        SettingsPage {
            if camera.recoverableRecordingCount > 0 {
                SettingsCard(title: "Recovery", symbol: "arrow.clockwise.circle.fill") {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(camera.recoverableRecordingCount) recording\(camera.recoverableRecordingCount == 1 ? "" : "s") waiting")
                                .font(.subheadline.weight(.semibold))
                            Text("Retry saving recordings that Photos could not import earlier.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Retry") {
                            camera.retryRecoverableRecordings()
                        }
                        .font(.caption.weight(.bold))
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            if camera.captureMode != .photo {
                SettingsCard(title: "Recording Format", symbol: "square.split.2x1") {
                    ThemeMenu(title: "Split Recording", selection: $splitMinutes, options: [(0, "Off"), (15, "Every 15 minutes"), (30, "Every 30 minutes"), (60, "Every hour"), (120, "Every 2 hours")])
                    Text("Split clips save separately with a brief gap between files. Codec availability depends on the selected camera format.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            RecordingExtrasSettings(camera: camera, positionStats: positionStats)
        }
        .tint(theme)
        .accentColor(theme)
        .preferredColorScheme(resolvedColorScheme(appColorScheme))
        .navigationTitle("Advanced Recording")
        .navigationBarTitleDisplayMode(.inline)
    }
}
