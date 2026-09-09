import SwiftUI
import Foundation
import CoreMotion
import UIKit

struct CameraIconButton: View {
    let symbol: String
    let isEnabled: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: { CameraHaptics.fire(); action() }) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 48, height: 48)
                .background(.black.opacity(0.28), in: Circle())
        }
        .foregroundStyle(isEnabled ? color : .white.opacity(0.35))
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch symbol {
        case "bolt.fill": return "Torch"
        case "gearshape.fill": return "Settings"
        case "ellipsis": return "Pro Tools"
        default: return "Switch camera"
        }
    }
}

struct RecordButton: View {
    @Environment(\.cameraTint) private var theme
    let isRecording: Bool
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: 76, height: 76)
                RoundedRectangle(cornerRadius: isRecording ? 7 : 34)
                    .fill(.red)
                    .frame(width: isRecording ? 30 : 62, height: isRecording ? 30 : 62)
            }
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

struct PhotoButton: View {
    let isCapturing: Bool
    let onTap: () -> Void
    let onBurstStart: () -> Void
    let onBurstEnd: () -> Void

    @State private var isPressing = false
    @State private var burstStarted = false
    @State private var holdTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white, lineWidth: 4)
                .frame(width: 76, height: 76)
            Circle()
                .fill(.white)
                .frame(width: 62, height: 62)
                .scaleEffect(isCapturing || isPressing ? 0.86 : 1)
        }
        .animation(.easeOut(duration: 0.12), value: isCapturing || isPressing)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressing else { return }
                    isPressing = true
                    burstStarted = false
                    holdTask?.cancel()
                    holdTask = Task { @MainActor in
                        do { try await Task.sleep(nanoseconds: 450_000_000) } catch { return }
                        guard isPressing else { return }
                        burstStarted = true
                        onBurstStart()
                    }
                }
                .onEnded { _ in
                    isPressing = false
                    holdTask?.cancel()
                    holdTask = nil
                    if burstStarted {
                        burstStarted = false
                        onBurstEnd()
                    } else {
                        onTap()
                    }
                }
        )
        .onDisappear {
            holdTask?.cancel()
            holdTask = nil
            isPressing = false
            if burstStarted {
                burstStarted = false
                onBurstEnd()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Take photo")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
    }
}

struct CaptureModeSelector: View {
    @Environment(\.cameraTint) private var theme
    let selectedMode: CameraManager.CaptureMode
    let isEnabled: Bool
    let unavailableModes: [CameraManager.CaptureMode]
    let onSelect: (CameraManager.CaptureMode) -> Void

    init(
        selectedMode: CameraManager.CaptureMode,
        isEnabled: Bool,
        unavailableModes: [CameraManager.CaptureMode] = [],
        onSelect: @escaping (CameraManager.CaptureMode) -> Void
    ) {
        self.selectedMode = selectedMode
        self.isEnabled = isEnabled
        self.unavailableModes = unavailableModes
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(spacing: 22) {
            ForEach(CameraManager.CaptureMode.allCases) { mode in
                let modeSupported = !unavailableModes.contains { $0 == mode }
                let modeEnabled = isEnabled && modeSupported
                Button {
                    guard modeEnabled else { return }
                    onSelect(mode)
                } label: {
                    HStack(spacing: 4) {
                        Text(mode.rawValue)
                        if !modeSupported {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8, weight: .bold))
                        }
                    }
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(selectedMode == mode ? theme : .white.opacity(modeSupported ? 0.65 : 0.35))
                }
                .disabled(!modeEnabled)
                .accessibilityLabel(modeSupported ? mode.rawValue : "\(mode.rawValue), locked")
                .accessibilityHint(modeSupported ? "" : "Unavailable for the current camera format.")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(.black.opacity(0.34), in: Capsule())
        .opacity(isEnabled ? 1 : 0.7)
    }
}

struct ZoomIndicator: View {
    @Environment(\.cameraTint) private var theme
    let label: String

    var body: some View {
        Text(label)
            .font(.system(.subheadline, design: .rounded).weight(.bold))
            .monospacedDigit()
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(.black.opacity(0.42), in: Capsule())
            .foregroundStyle(.white)
            .accessibilityLabel("Active camera lens \(label)")
    }
}

struct RecordingTimer: View {
    @Environment(\.cameraTint) private var theme
    let duration: TimeInterval

    var body: some View {
        Text(timerText)
            .font(.system(.body, design: .monospaced).weight(.bold))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.red.opacity(0.92), in: Capsule())
            .foregroundStyle(.white)
    }

    private var timerText: String {
        let totalSeconds = Int(duration)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

private struct RecordingClockText: View {
    @ObservedObject var clock: RecordingClockState

    var body: some View {
        let totalSeconds = Int(clock.elapsedSeconds)
        Text(String(
            format: "%02d:%02d:%02d",
            totalSeconds / 3_600,
            (totalSeconds / 60) % 60,
            totalSeconds % 60
        ))
        .font(.system(size: 12, weight: .bold, design: .monospaced))
        .foregroundStyle(.white)
    }
}

/// The HUD receives only the camera state it displays. Zoom and toast updates therefore no
/// longer directly invalidate this view through CameraManager's broad ObservableObject stream.
struct CameraHUDSnapshot: Equatable {
    let isRecording: Bool
    let captureModeLabel: String
    let isPhotoMode: Bool
    let resolutionLabel: String
    let frameRateLabel: String?
    let remainingLabel: String
    let whiteBalanceLabel: String
    let availableStorageBytes: Int64
    let lastFrameGaps: Int?
}

struct CameraHUD: View {
    @AppStorage("cameraHUDBattery") private var showBattery = false
    @AppStorage("cameraHUDStorage") private var showStorage = false
    @AppStorage("cameraHUDDroppedFrames") private var showDroppedFrames = false
    @State private var batteryLevel: Float = -1
    @AppStorage("thermalHUD") private var showThermal = false
    @AppStorage("hudTextSize") private var hudTextSize = 10.0
    @State private var thermalState = ProcessInfo.processInfo.thermalState
    let snapshot: CameraHUDSnapshot
    let recordingClock: RecordingClockState
    let showResolution: Bool
    let showFPS: Bool
    let showRemaining: Bool
    let showWhiteBalance: Bool
    let maxWidth: CGFloat

    init(
        snapshot: CameraHUDSnapshot,
        recordingClock: RecordingClockState,
        showResolution: Bool,
        showFPS: Bool,
        showRemaining: Bool,
        showWhiteBalance: Bool,
        maxWidth: CGFloat
    ) {
        self.snapshot = snapshot
        self.recordingClock = recordingClock
        self.showResolution = showResolution
        self.showFPS = showFPS
        self.showRemaining = showRemaining
        self.showWhiteBalance = showWhiteBalance
        self.maxWidth = maxWidth
    }

    var body: some View {
        CameraHUDContent(
            snapshot: snapshot,
            recordingClock: recordingClock,
            showResolution: showResolution,
            showFPS: showFPS,
            showRemaining: showRemaining,
            showWhiteBalance: showWhiteBalance,
            showBattery: showBattery,
            batteryLevel: batteryLevel,
            showStorage: showStorage,
            showThermal: showThermal,
            thermalState: thermalState,
            showDroppedFrames: showDroppedFrames,
            textSize: hudTextSize,
            maxWidth: maxWidth
        )
        .equatable()
            .task(id: showBattery) {
                UIDevice.current.isBatteryMonitoringEnabled = showBattery
                batteryLevel = showBattery ? UIDevice.current.batteryLevel : -1
            }
            .onDisappear {
                if showBattery { UIDevice.current.isBatteryMonitoringEnabled = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
                batteryLevel = UIDevice.current.batteryLevel
            }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                thermalState = ProcessInfo.processInfo.thermalState
            }
    }
}

private struct CameraHUDContent: View, Equatable {
    @Environment(\.cameraTint) private var theme
    let snapshot: CameraHUDSnapshot
    let recordingClock: RecordingClockState
    let showResolution: Bool
    let showFPS: Bool
    let showRemaining: Bool
    let showWhiteBalance: Bool
    let showBattery: Bool
    let batteryLevel: Float
    let showStorage: Bool
    let showThermal: Bool
    let thermalState: ProcessInfo.ThermalState
    let showDroppedFrames: Bool
    let textSize: Double
    let maxWidth: CGFloat

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot == rhs.snapshot &&
        lhs.showResolution == rhs.showResolution &&
        lhs.showFPS == rhs.showFPS &&
        lhs.showRemaining == rhs.showRemaining &&
        lhs.showWhiteBalance == rhs.showWhiteBalance &&
        lhs.showBattery == rhs.showBattery &&
        lhs.batteryLevel == rhs.batteryLevel &&
        lhs.showStorage == rhs.showStorage &&
        lhs.showThermal == rhs.showThermal &&
        lhs.thermalState.rawValue == rhs.thermalState.rawValue &&
        lhs.showDroppedFrames == rhs.showDroppedFrames &&
        lhs.textSize == rhs.textSize &&
        lhs.maxWidth == rhs.maxWidth
    }

    var body: some View {
        let hudItems = items
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(snapshot.isRecording ? Color.red : theme).frame(width: 5, height: 5)
                Text(snapshot.isRecording ? "REC" : snapshot.captureModeLabel)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(theme)
                if snapshot.isRecording {
                    RecordingClockText(clock: recordingClock)
                }
            }
            if !hudItems.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(hudItems.enumerated()), id: \.offset) { _, item in
                            Label(item, systemImage: symbol(for: item))
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                        ForEach(Array(hudItems.enumerated()), id: \.offset) { _, item in
                            Label(item, systemImage: symbol(for: item))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                    .frame(maxWidth: maxWidth - 20)
                }
            }
        }
        .font(.system(size: textSize, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(theme)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 20))
        .background(theme.opacity(0.22), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20).stroke(theme.opacity(0.35), lineWidth: 1)
        }
        // Keep the black pill only as wide as its content. The outer frame centers it in the
        // safe gap between Flash and Settings without creating empty "Dynamic Island" space.
        .frame(maxWidth: maxWidth)
        .accessibilityLabel(([snapshot.captureModeLabel] + hudItems).joined(separator: ", "))
    }

    private var items: [String] {
        var result: [String] = []
        if showResolution { result.append(snapshot.resolutionLabel) }
        if showFPS, let fps = snapshot.frameRateLabel { result.append("\(fps)fps") }
        if showRemaining { result.append(snapshot.remainingLabel) }
        if showWhiteBalance { result.append(snapshot.whiteBalanceLabel) }
        if showBattery { result.append(batteryLevel < 0 ? "BAT —" : "BAT \(Int(batteryLevel * 100))%") }
        if showStorage { result.append(String(format: "%.1f GB", Double(snapshot.availableStorageBytes) / 1_000_000_000)) }
        if showThermal {
            switch thermalState {
            case .nominal: result.append("Cool")
            case .fair: result.append("Warm")
            case .serious: result.append("Hot")
            case .critical: result.append("Critical")
            @unknown default: result.append("Temp —")
            }
        }
        if showDroppedFrames, !snapshot.isPhotoMode {
            result.append(snapshot.lastFrameGaps.map { "Gaps \($0)*" } ?? "Gaps —*")
        }
        return result
    }

    private func symbol(for item: String) -> String {
        if item.contains("fps") { return "speedometer" }
        if item.hasPrefix("BAT") { return "battery.100percent" }
        if item.contains("GB") { return "internaldrive" }
        if item.hasPrefix("Gaps") { return "waveform.path" }
        if ["Cool", "Warm", "Hot", "Critical", "Temp —"].contains(item) { return "thermometer.medium" }
        if item.hasPrefix("~") { return snapshot.isPhotoMode ? "photo.on.rectangle" : "clock" }
        if item == snapshot.whiteBalanceLabel { return "sun.max" }
        return "viewfinder"
    }
}

struct ProToolsPopup: View {
    @Environment(\.cameraTint) private var theme
    @ObservedObject var camera: CameraManager
    @Binding var isLevelMeterEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("PRO TOOLS")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))

            VStack(spacing: 8) {
                HStack {
                    Text("EV")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Reset") {
                        camera.setExposureBias(0)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .buttonStyle(.plain)
                    Text(evLabel)
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundStyle(theme)
                        .frame(width: 42, alignment: .trailing)
                }

                Slider(
                    value: Binding(
                        get: { Double(camera.exposureBias) },
                        set: { camera.setExposureBias(Float($0)) }
                    ),
                    in: -2...2,
                    step: 0.1
                )
                .tint(theme)
            }

            Divider()
                .overlay(.white.opacity(0.15))

            HStack(spacing: 12) {
                Text("White Balance")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Menu {
                    ForEach(CameraManager.WhiteBalancePreset.allCases) { preset in
                        Button {
                            camera.selectWhiteBalancePreset(preset)
                        } label: {
                            if camera.whiteBalancePreset == preset {
                                Label(preset.rawValue, systemImage: "checkmark")
                            } else {
                                Text(preset.rawValue)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(camera.whiteBalancePreset.rawValue)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .frame(minWidth: 112, alignment: .trailing)
                    .foregroundStyle(theme)
                }
            }

            Divider()
                .overlay(.white.opacity(0.15))

            Toggle("Level Meter", isOn: $isLevelMeterEnabled)
                .font(.subheadline.weight(.semibold))
                .tint(theme)
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(width: 310)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var evLabel: String {
        abs(camera.exposureBias) < 0.05 ? "0.0" : String(format: "%+.1f", camera.exposureBias)
    }
}

struct CameraLevelMeterHost: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var monitor = CameraLevelMonitor()
    let enabled: Bool

    var body: some View {
        Group {
            if enabled {
                CameraLevelOverlay(
                    angle: monitor.angle,
                    isAvailable: monitor.isAvailable,
                    isLevel: monitor.isLevel
                )
                .offset(y: -8)
                .allowsHitTesting(false)
            }
        }
        .onAppear { updateRunningState() }
        .onChange(of: enabled) { _, _ in updateRunningState() }
        .onChange(of: scenePhase) { _, _ in updateRunningState() }
        .onDisappear { monitor.stop() }
    }

    private func updateRunningState() {
        if enabled && scenePhase == .active {
            monitor.start()
        } else {
            monitor.stop()
        }
    }
}

struct CameraLevelOverlay: View {
    @Environment(\.cameraTint) private var theme
    let angle: Double
    let isAvailable: Bool
    let isLevel: Bool

    var body: some View {
        ZStack {
            HStack(spacing: 132) {
                Capsule()
                    .fill(.white.opacity(0.72))
                    .frame(width: 52, height: 3)
                Capsule()
                    .fill(.white.opacity(0.72))
                    .frame(width: 52, height: 3)
            }

            Capsule()
                .fill(isLevel ? theme : .white)
                .frame(width: 104, height: isLevel ? 5 : 4)
                .rotationEffect(.radians(-angle))
        }
        .frame(width: 260, height: 72)
        .opacity(isAvailable ? 1 : 0.30)
        .animation(.easeOut(duration: 0.10), value: isLevel)
        .accessibilityLabel(isLevel ? "Camera level" : "Camera not level")
    }
}

struct CameraGridOverlay: View {
    @Environment(\.cameraTint) private var theme
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width
                let height = geometry.size.height
                for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                    path.move(to: CGPoint(x: width * fraction, y: 0))
                    path.addLine(to: CGPoint(x: width * fraction, y: height))
                    path.move(to: CGPoint(x: 0, y: height * fraction))
                    path.addLine(to: CGPoint(x: width, y: height * fraction))
                }
            }
            .stroke(.white.opacity(0.28), lineWidth: 0.8)
        }
    }
}

final class CameraLevelMonitor: ObservableObject {
    struct Measurement: Equatable {
        var angle: Double = 0
        var isAvailable = false
        var levelDeviation: Double = .infinity

        var isLevel: Bool {
            let tolerance = 1.5 * Double.pi / 180
            return isAvailable && levelDeviation <= tolerance
        }
    }

    @Published private(set) var measurement = Measurement()

    private let motionManager = CMMotionManager()
    private var lastRawRoll: Double?
    private var unwrappedRoll: Double = 0
    private var filteredAngle: Double = 0

    var angle: Double { measurement.angle }
    var isAvailable: Bool { measurement.isAvailable }
    var isLevel: Bool { measurement.isLevel }

    func start() {
        guard motionManager.isDeviceMotionAvailable else {
            resetMeasurement()
            return
        }
        guard !motionManager.isDeviceMotionActive else { return }

        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, error in
            guard let self else { return }
            guard error == nil, let gravity = motion?.gravity else {
                self.resetMeasurement()
                return
            }

            let horizonStrength = hypot(gravity.x, gravity.y)
            guard horizonStrength > 0.06 else {
                self.resetMeasurement()
                return
            }

            let rawRoll = atan2(gravity.x, -gravity.y)
            if let lastRawRoll = self.lastRawRoll {
                // Unwrap the -π/+π boundary so the indicator keeps rotating continuously.
                let delta = atan2(sin(rawRoll - lastRawRoll), cos(rawRoll - lastRawRoll))
                self.unwrappedRoll += delta
                self.filteredAngle += (self.unwrappedRoll - self.filteredAngle) * 0.50
            } else {
                self.unwrappedRoll = rawRoll
                self.filteredAngle = rawRoll
            }
            self.lastRawRoll = rawRoll

            let quarterTurn = Double.pi / 2
            let nearestLevel = (self.filteredAngle / quarterTurn).rounded() * quarterTurn
            let next = Measurement(
                angle: self.filteredAngle,
                isAvailable: true,
                levelDeviation: abs(self.filteredAngle - nearestLevel)
            )
            let availabilityChanged = next.isAvailable != self.measurement.isAvailable
            let levelChanged = next.isLevel != self.measurement.isLevel
            let angleChanged = abs(next.angle - self.measurement.angle) >= 0.002
            if availabilityChanged || levelChanged || angleChanged {
                self.measurement = next
            }
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        resetMeasurement()
    }

    private func resetMeasurement() {
        lastRawRoll = nil
        unwrappedRoll = 0
        filteredAngle = 0
        let reset = Measurement()
        if measurement != reset {
            measurement = reset
        }
    }
}
