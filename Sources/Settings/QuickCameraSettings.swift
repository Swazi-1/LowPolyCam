import SwiftUI

struct QuickCameraSettings: View {
    @ObservedObject var camera: CameraManager
    @AppStorage("cameraGridEnabled") private var grid = false
    @AppStorage("gridOpacity") private var opacity = 1.0
    @AppStorage("levelMeterEnabled") private var level = true
    @Environment(\.cameraTint) private var theme

    var body: some View {
        SettingsCard(title: "Quick Controls", symbol: "slider.horizontal.3") {
            if camera.captureMode == .video {
                SettingsToggleRow(
                    title: "Stabilization",
                    subtitle: "Reduce camera shake",
                    symbol: "dot.radiowaves.left.and.right",
                    isOn: Binding(get: { camera.isVideoStabilizationEnabled }, set: camera.setVideoStabilizationEnabled)
                )
                SettingsDivider()
            }

            SettingsToggleRow(title: "Grid", subtitle: "Show composition grid", symbol: "grid", isOn: $grid)

            if grid {
                SettingsSubRow {
                    HStack {
                        Text("Grid Opacity")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(opacity * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $opacity, in: 0.2...1)
                        .tint(theme)
                        .accessibilityLabel("Grid opacity")
                }
            }

            SettingsDivider()

            SettingsToggleRow(title: "Level", subtitle: "Show horizon level", symbol: "gyroscope", isOn: $level)
        }
    }
}
