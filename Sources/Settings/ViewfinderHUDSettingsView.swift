import SwiftUI

struct ViewfinderHUDSettingsView: View {
    @Environment(\.cameraTint) private var theme
    @ObservedObject var camera: CameraManager
    @AppStorage("keepScreenAwakeEnabled") private var keepScreenAwakeEnabled = false
    @AppStorage("cameraHUDEnabled") private var isHUDEnabled = true
    @AppStorage("appColorScheme") private var appColorScheme = "system"

    var body: some View {
        SettingsPage {
            SettingsCard(title: "Viewfinder", symbol: "viewfinder") {
                SettingsToggleRow(
                    title: "Keep Screen Awake",
                    subtitle: "Prevent Auto-Lock while LowPolyCam is open",
                    symbol: "sun.max.fill",
                    isOn: $keepScreenAwakeEnabled
                )
            }

            SettingsCard(title: "Camera HUD", symbol: "capsule.fill") {
                SettingsToggleRow(
                    title: "Show Camera HUD",
                    subtitle: "Show the in-camera info capsule",
                    symbol: "capsule.fill",
                    isOn: $isHUDEnabled
                )
                SettingsDivider()
                NavigationLink {
                    CameraHUDSettingsView(camera: camera)
                } label: {
                    SettingsNavigationRow(
                        title: "HUD Content & Style",
                        subtitle: "Choose the info and text size",
                        symbol: "text.line.first.and.arrowtriangle.forward"
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .tint(theme)
        .accentColor(theme)
        .preferredColorScheme(resolvedColorScheme(appColorScheme))
        .navigationTitle("Viewfinder & HUD")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CameraHUDSettingsView: View {
    @ObservedObject var camera: CameraManager
    @AppStorage("cameraHUDResolution") private var hudResolution = true
    @AppStorage("cameraHUDFPS") private var hudFPS = true
    @AppStorage("cameraHUDRemaining") private var hudRemaining = true
    @AppStorage("cameraHUDWhiteBalance") private var hudWhiteBalance = false
    @AppStorage("cameraHUDBattery") private var hudBattery = false
    @AppStorage("cameraHUDStorage") private var hudStorage = false
    @AppStorage("cameraHUDDroppedFrames") private var hudDroppedFrames = false
    @AppStorage("thermalHUD") private var hudThermal = false
    @AppStorage("hudTextSize") private var hudTextSize = 10.0

    var body: some View {
        SettingsPage {
            SettingsCard(title: "Main Info", symbol: "viewfinder") {
                SettingsToggleRow(
                    title: "Resolution",
                    subtitle: camera.captureMode == .photo ? "Selected photo resolution" : "Selected video resolution",
                    isOn: $hudResolution
                )

                if camera.captureMode != .photo {
                    SettingsDivider()
                    SettingsToggleRow(
                        title: "FPS",
                        subtitle: camera.captureMode == .sloMo ? "Selected Slo-Mo frame rate" : "Selected video frame rate",
                        isOn: $hudFPS
                    )
                }

                SettingsDivider()
                SettingsToggleRow(
                    title: camera.captureMode == .photo ? "Photos Remaining" : "Time Remaining",
                    subtitle: camera.captureMode == .photo ? "Estimated photos left" : "Estimated recording time left",
                    isOn: $hudRemaining
                )
                SettingsDivider()
                SettingsToggleRow(title: "White Balance", subtitle: "Active white-balance preset", isOn: $hudWhiteBalance)
            }

            SettingsCard(title: "Device Info", symbol: "iphone") {
                SettingsToggleRow(title: "Battery", subtitle: "Current battery percentage", isOn: $hudBattery)
                SettingsDivider()
                SettingsToggleRow(title: "Free Storage", subtitle: "Available space on this iPhone", isOn: $hudStorage)
                SettingsDivider()
                SettingsToggleRow(title: "Thermal Status", subtitle: "Current device temperature state", isOn: $hudThermal)
                if camera.captureMode != .photo {
                    SettingsDivider()
                    SettingsToggleRow(title: "Frame Gaps", subtitle: "Missing intervals in the last saved clip", isOn: $hudDroppedFrames)
                }
            }

            SettingsCard(title: "HUD Appearance", symbol: "textformat.size") {
                ThemeMenu(title: "Text Size", selection: $hudTextSize, options: [(10.0, "Compact"), (12.0, "Large")])
            }
        }
        .navigationTitle("Camera HUD")
        .navigationBarTitleDisplayMode(.inline)
    }
}
