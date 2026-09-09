import SwiftUI
import UIKit
import AVFoundation

private struct CameraTintKey: EnvironmentKey {
    static let defaultValue = Color(red: 0.65, green: 0.88, blue: 1)
}
extension EnvironmentValues {
    var cameraTint: Color {
        get { self[CameraTintKey.self] }
        set { self[CameraTintKey.self] = newValue }
    }
}

enum VideoCompression: String, CaseIterable, Identifiable {
    case dataSaver = "Data Saver", medium = "Medium", high = "High"
    var id: String { rawValue }
    var bitsPerPixel: Double {
        switch self { case .dataSaver: return 0.055; case .medium: return 0.10; case .high: return 0.18 }
    }
}

enum VideoQuickPreset: String, CaseIterable, Identifiable {
    case balanced = "Balanced", highQuality = "High Quality", allRounder = "All Rounder", allDay = "All Day", social = "Social"
    var id: String { rawValue }
    var resolution: VideoResolution { self == .highQuality ? .p4k : self == .allDay ? .p720 : .p1080 }
    var frameRate: VideoFrameRate { self == .allRounder ? .fps60 : .fps30 }
    var compression: VideoCompression {
        switch self {
        case .highQuality, .allRounder: return .high
        case .allDay, .social: return .dataSaver
        case .balanced: return .medium
        }
    }
    var detail: String { "\(resolution.rawValue) · \(compression.rawValue) · \(frameRate.rawValue) fps · HEVC" }
}

enum CameraHaptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let heavy = UIImpactFeedbackGenerator(style: .heavy)
    static func fire(strength selectedStrength: String? = nil, captureOnly: Bool = false) {
        let defaults = UserDefaults.standard
        if captureOnly, !(defaults.object(forKey: "hapticCaptureEnabled") as? Bool ?? true) { return }
        let strength = selectedStrength ?? defaults.string(forKey: "hapticStrength") ?? "Medium"
        // Reapply this when feedback is requested because iOS does not expose a reliable
        // notification for a hardware mute-switch change while the app remains open.
        try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
        let generator = strength == "Low" ? light : strength == "Strong" ? heavy : medium
        generator.prepare()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            generator.impactOccurred(intensity: strength == "Low" ? 0.45 : strength == "Strong" ? 1 : 0.7)
        }
    }
}

struct CameraAccent: DynamicProperty {
    @AppStorage("iconAppearance") private var preset = "Ice"
    @AppStorage("iconCustomRed") private var red = 0.55
    @AppStorage("iconCustomGreen") private var green = 0.85
    @AppStorage("iconCustomBlue") private var blue = 1.0
    var color: Color {
        switch preset {
        case "Sunset": return Color(red: 1, green: 0.58, blue: 0.3)
        case "Mint": return Color(red: 0.4, green: 0.95, blue: 0.7)
        case "Lavender": return Color(red: 0.77, green: 0.64, blue: 1)
        case "Coral": return Color(red: 1.0, green: 0.43, blue: 0.48)
        case "Custom": return Color(red: red, green: green, blue: blue)
        default: return Color(red: 0.65, green: 0.88, blue: 1)
        }
    }
}

struct CapturePreferencesView: View {
    @ObservedObject var camera: CameraManager
    init(camera: CameraManager) { self.camera = camera }
    @AppStorage("appColorScheme") private var appColorScheme = "system"

    var body: some View {
        SettingsPage {
            SettingsCard(title: "Capture Settings", symbol: "camera.fill") {
                NavigationLink {
                    ShutterHapticsSettingsView()
                } label: {
                    SettingsNavigationRow(
                        title: "Shutter & Haptics",
                        subtitle: "Timer, feedback and strength",
                        symbol: "timer"
                    )
                }
                .buttonStyle(.plain)

                SettingsDivider()

                NavigationLink {
                    ZoomRecordingSettingsView(camera: camera)
                } label: {
                    SettingsNavigationRow(
                        title: "Zoom & Recording",
                        subtitle: "Zoom feel and capture safeguards",
                        symbol: "plus.magnifyingglass"
                    )
                }
                .buttonStyle(.plain)

                SettingsDivider()

                NavigationLink {
                    CameraControlsSettingsView(camera: camera)
                } label: {
                    SettingsNavigationRow(
                        title: "Camera Controls",
                        subtitle: "Mode memory, guides and reset",
                        symbol: "slider.horizontal.3"
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .preferredColorScheme(resolvedColorScheme(appColorScheme))
        .navigationTitle("Capture")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ShutterHapticsSettingsView: View {
    @AppStorage("shutterDelay") private var shutterDelay = 0
    @AppStorage("hapticCaptureEnabled") private var haptics = true
    @AppStorage("hapticStrength") private var strength = "Medium"

    var body: some View {
        SettingsPage {
            SettingsCard(title: "Shutter", symbol: "timer") {
                ThemeMenu(title: "Timer", selection: $shutterDelay, options: [(0, "Off"), (3, "3 seconds"), (10, "10 seconds")])
            }

            SettingsCard(title: "Capture Haptics", symbol: "waveform") {
                SettingsToggleRow(
                    title: "Haptic Capture",
                    subtitle: "Feel a tap when the shutter starts or stops",
                    isOn: $haptics
                )
                SettingsDivider()
                ThemeMenu(
                    title: "Strength",
                    selection: $strength,
                    options: ["Low", "Medium", "Strong"].map { ($0, $0) },
                    onSelect: { CameraHaptics.fire(strength: $0) }
                )
                .disabled(!haptics)
            }
        }
        .navigationTitle("Shutter & Haptics")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ZoomRecordingSettingsView: View {
    @ObservedObject var camera: CameraManager
    @AppStorage("zoomSpeed") private var zoomSpeed = 1.0
    @AppStorage("tapZoomReset") private var tapZoomReset = true
    @AppStorage("recordingLock") private var recordingLock = false
    @AppStorage("lowStorageWarning") private var lowStorageWarning = true

    var body: some View {
        SettingsPage {
            SettingsCard(title: "Zoom", symbol: "plus.magnifyingglass") {
                ThemeMenu(title: "Zoom Speed", selection: $zoomSpeed, options: [(0.5, "Slow"), (1.0, "Normal"), (1.5, "Fast")])
                SettingsDivider()
                SettingsToggleRow(
                    title: "Tap Zoom to Reset",
                    subtitle: "Tap the zoom value to return to 1×",
                    isOn: $tapZoomReset
                )
            }

            SettingsCard(title: "Capture Safeguards", symbol: "lock.shield.fill") {
                if camera.captureMode != .photo {
                    SettingsToggleRow(
                        title: "Lock Recording Controls",
                        subtitle: "Hold the shutter for one second to stop",
                        isOn: $recordingLock
                    )
                    SettingsDivider()
                }
                SettingsToggleRow(
                    title: "Low Storage Warning",
                    subtitle: "Warn before storage gets too low",
                    isOn: $lowStorageWarning
                )
            }
        }
        .navigationTitle("Zoom & Recording")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CameraControlsSettingsView: View {
    @Environment(\.cameraTint) private var theme
    @ObservedObject var camera: CameraManager
    @AppStorage("countdownHaptics") private var countdownHaptics = false
    @AppStorage("rememberCaptureMode") private var rememberCaptureMode = false
    @AppStorage("centerCrosshair") private var crosshair = false
    @AppStorage("mirrorSelfies") private var mirrorSelfies = false

    var body: some View {
        SettingsPage {
            SettingsCard(title: "Camera Controls", symbol: "slider.horizontal.3") {
                SettingsToggleRow(title: "Countdown Haptics", subtitle: "Tap along with the shutter timer", isOn: $countdownHaptics)
                SettingsDivider()
                SettingsToggleRow(title: "Remember Camera Mode", subtitle: "Open in the last used capture mode", isOn: $rememberCaptureMode)
                SettingsDivider()
                SettingsToggleRow(title: "Center Crosshair", subtitle: "Show a marker at the frame center", isOn: $crosshair)
                SettingsDivider()
                SettingsToggleRow(title: "Mirror Saved Selfies", subtitle: "Save selfies as they appear in preview", isOn: $mirrorSelfies)
            }

            SettingsCard(title: "Reset", symbol: "arrow.counterclockwise") {
                Button {
                    camera.setExposureBias(0)
                    camera.selectWhiteBalancePreset(.auto)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(theme)
                            .frame(width: 34, height: 34)
                            .background(theme.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reset Exposure & WB")
                                .font(.subheadline.weight(.semibold))
                            Text("Restore automatic exposure and color")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Camera Controls")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ThemeMenu<Value: Hashable>: View {
    @Environment(\.cameraTint) private var theme
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    var onSelect: ((Value) -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: min(3, max(1, options.count))), spacing: 8) {
                ForEach(options, id: \.0) { value, label in
                    Button {
                        selection = value
                        onSelect?(value)
                    } label: {
                        Text(label)
                            .font(.caption.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .padding(.horizontal, 4)
                            .background(selection == value ? theme : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(selection == value ? Color.black : Color.primary)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityAddTraits(selection == value ? .isSelected : [])
                }
            }
        }
    }
}

struct SettingsPage<Content: View>: View {
    @Environment(\.cameraTint) private var theme
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ScrollView {
            VStack(spacing: 18) { content }
                .padding(.horizontal, 16).padding(.vertical, 14)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .tint(theme)
    }
}
