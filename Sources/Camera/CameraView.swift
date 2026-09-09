import SwiftUI
import UIKit

struct CameraView: View {
    private enum StoragePollingState: Hashable {
        case inactive
        case covered
        case idle
        case recording

        var intervalNanoseconds: UInt64? {
            switch self {
            case .idle: return 30_000_000_000
            case .recording: return 5_000_000_000
            case .inactive, .covered: return nil
            }
        }
    }

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraManager()
    @AppStorage("levelMeterEnabled") private var isLevelMeterEnabled = true
    @AppStorage("cameraGridEnabled") private var isGridEnabled = false
    @AppStorage("cameraHUDEnabled") private var isHUDEnabled = true
    @AppStorage("cameraHUDResolution") private var hudResolution = true
    @AppStorage("cameraHUDFPS") private var hudFPS = true
    @AppStorage("cameraHUDRemaining") private var hudRemaining = true
    @AppStorage("cameraHUDWhiteBalance") private var hudWhiteBalance = false
    @AppStorage("hapticCaptureEnabled") private var isHapticCaptureEnabled = true
    @AppStorage("keepScreenAwakeEnabled") private var keepScreenAwakeEnabled = false
    @State private var isShowingSettings = false
    @State private var isShowingProTools = false
    @State private var dragStartZoom: CGFloat?
    @State private var countdown = 0
    @State private var shutterTask: Task<Void, Never>?
    @State private var zoomWidth: CGFloat = 320
    @AppStorage("shutterDelay") private var shutterDelay = 0
    @AppStorage("centerCrosshair") private var crosshair = false
    @AppStorage("zoomSpeed") private var zoomSpeed = 1.0
    @AppStorage("tapZoomReset") private var tapZoomReset = true
    @AppStorage("recordingLock") private var recordingLock = false
    @AppStorage("lowStorageWarning") private var lowStorageWarning = true
    @AppStorage("gridOpacity") private var gridOpacity = 1.0
    @AppStorage("countdownHaptics") private var countdownHaptics = false
    @AppStorage("mirrorSelfies") private var mirrorSelfies = false
    @State private var warnedAboutStorage = false
    @AppStorage("liveRecordingStats") private var liveStats = false
    @AppStorage("photoAspect") private var photoAspect = "4:3"
    @AppStorage("longevityMode") private var longevity = false
    @State private var editingStats = false
    @State private var restoreBrightness: CGFloat?
    private var accent = CameraAccent()

    var body: some View {
        ZStack {
            CameraPreview(
                session: camera.session,
                isFocusExposureLocked: camera.isFocusExposureLocked,
                focusExposureLockLabel: camera.focusExposureLockLabel,
                stabilizationEnabled: camera.captureMode == .video && camera.isVideoStabilizationEnabled,
                isPreviewTransitioning: camera.isPreviewTransitioning || camera.isLensTransitioning,
                reservesTopHUDSpace: isHUDEnabled,
                fitsPhoto: camera.captureMode == .photo,
                onTapToFocus: { if !editingStats { camera.focusAndExpose(at: $0) } },
                onLongPressToLock: { if !editingStats { camera.lockFocusAndExposure(at: $0) } }
            )
            .ignoresSafeArea()

            if camera.captureMode == .photo && photoAspect == "1:1" {
                GeometryReader { proxy in
                    let side = min(proxy.size.width, proxy.size.height)
                    VStack(spacing: 0) {
                        Color.black.opacity(0.7)
                        Color.clear.frame(height: side).overlay(Rectangle().stroke(.white.opacity(0.5)))
                        Color.black.opacity(0.7)
                    }
                }.ignoresSafeArea().allowsHitTesting(false)
            }

            LinearGradient(colors: [.black.opacity(0.48), .clear, .black.opacity(0.60)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if isGridEnabled {
                CameraGridOverlay()
                    .opacity(gridOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            if crosshair {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.7))
                    .allowsHitTesting(false)
            }

            if countdown > 0 {
                Button { cancelCountdown() } label: {
                    VStack {
                        Text("\(countdown)").font(.system(size: 64, weight: .bold, design: .rounded))
                        Text("Tap to cancel").font(.caption)
                    }
                    .padding(24)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 24))
                }.foregroundStyle(.white).zIndex(10)
            }

            CameraLevelMeterHost(enabled: isLevelMeterEnabled && !isShowingSettings)

            VStack {
                topControls
                Spacer()
                statusToast
                bottomControls
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .allowsHitTesting(!editingStats && !camera.isPreviewTransitioning)

            if isShowingProTools {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { isShowingProTools = false }

                VStack {
                    Spacer()
                    HStack {
                        ProToolsPopup(camera: camera, isLevelMeterEnabled: $isLevelMeterEnabled)
                        Spacer()
                    }
                }
                .padding(.leading, 14)
                .padding(.bottom, 132)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
            }

        }
        .overlay {
            if editingStats || (liveStats && camera.isRecording) {
                LiveStatsOverlay(stats: camera.liveStats, editing: editingStats) { editingStats = false }
            }
        }
        .onChange(of: camera.isRecording) { _, recording in
            AppEventLog.event("Camera UI: recording visible state changed to \(recording)")
            if recording && longevity && camera.captureMode == .video {
                if restoreBrightness == nil { restoreBrightness = UIScreen.main.brightness }
                UIScreen.main.brightness = min(UIScreen.main.brightness, 0.25)
            } else if let brightness = restoreBrightness {
                UIScreen.main.brightness = brightness
                restoreBrightness = nil
            }
        }
        .preferredColorScheme(.dark)
        .tint(accent.color)
        .task {
            camera.start()
            updateIdleTimer(for: scenePhase)
        }
        .task(id: storagePollingState) {
            guard let interval = storagePollingState.intervalNanoseconds else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled, storagePollingState.intervalNanoseconds == interval else { return }
                camera.refreshAvailableStorage()
            }
        }
        .onChange(of: keepScreenAwakeEnabled) { _, _ in
            updateIdleTimer(for: scenePhase)
        }
        .onChange(of: mirrorSelfies) { _, _ in
            camera.refreshMovieOutputSettings()
        }
        .onChange(of: scenePhase) { _, phase in
            updateIdleTimer(for: phase)
            if phase == .active {
                camera.appDidBecomeActive()
                camera.refreshAvailableStorage()
            } else {
                cancelCountdown()
                if let brightness = restoreBrightness {
                    UIScreen.main.brightness = brightness
                    restoreBrightness = nil
                }
                camera.appDidBecomeInactive(isBackground: phase == .background)
            }
        }
        .onDisappear {
            cancelCountdown()
            camera.stop()
            if let brightness = restoreBrightness { UIScreen.main.brightness = brightness; restoreBrightness = nil }
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .sheet(isPresented: $isShowingSettings) {
            VideoSettingsView(camera: camera) {
                isShowingSettings = false
                isShowingProTools = false
                cancelCountdown()
                editingStats = true
            }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: camera.captureMode) { _, _ in cancelCountdown() }
        .onChange(of: camera.availableStorageBytes) { _, bytes in
            if bytes > 1_000_000_000 { warnedAboutStorage = false }
            if lowStorageWarning, bytes > 0, bytes < 1_000_000_000, !warnedAboutStorage {
                warnedAboutStorage = true
                camera.postStatus("Storage is below 1 GB. Long recordings may stop early.")
            }
        }
        .onChange(of: isShowingSettings) { _, showing in
            if showing { cancelCountdown() }
            AppEventLog.event("Camera UI: Settings sheet \(showing ? "opened" : "closed")")
        }
        .onChange(of: isShowingProTools) { _, showing in
            AppEventLog.event("Camera UI: Pro controls \(showing ? "opened" : "closed")")
        }
    }

    private var topControls: some View {
        GeometryReader { proxy in
            let hudMaxWidth = max(120, proxy.size.width - 112)
            let hudSnapshot = CameraHUDSnapshot(
                isRecording: camera.isRecording,
                captureModeLabel: camera.captureMode.rawValue,
                isPhotoMode: camera.captureMode == .photo,
                resolutionLabel: camera.hudResolutionLabel,
                frameRateLabel: camera.hudFrameRateLabel,
                remainingLabel: camera.hudRemainingLabel,
                whiteBalanceLabel: hudWhiteBalanceLabel,
                availableStorageBytes: camera.availableStorageBytes,
                lastFrameGaps: camera.lastFrameGaps
            )

            ZStack {
                HStack {
                    CameraIconButton(symbol: "bolt.fill", isEnabled: camera.torchAvailable && !camera.isLensTransitioning && !(camera.isRecording && recordingLock), color: camera.isTorchOn ? accent.color : accent.color.opacity(0.65)) {
                        camera.toggleTorch()
                    }
                    Spacer()
                    CameraIconButton(symbol: "gearshape.fill", isEnabled: !camera.isRecording && !camera.isRecordingStarting && !camera.isFinalizingRecording && !camera.isCapturingPhoto && !camera.isLensTransitioning, color: accent.color) {
                        isShowingSettings = true
                    }
                }

                if isHUDEnabled {
                    CameraHUD(
                        snapshot: hudSnapshot,
                        recordingClock: camera.recordingClock,
                        showResolution: hudResolution,
                        showFPS: hudFPS,
                        showRemaining: hudRemaining,
                        showWhiteBalance: hudWhiteBalance,
                        maxWidth: hudMaxWidth
                    )
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 116)
    }

    private var bottomControls: some View {
        VStack(spacing: 14) {
                ZStack {
                    Color.clear
                    ZoomIndicator(label: camera.zoomLabel)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .padding(.horizontal, -22)
                .background(GeometryReader { proxy in
                    Color.clear.onAppear { zoomWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in zoomWidth = width }
                })
                .gesture(zoomGesture)
                .allowsHitTesting(!(camera.isRecording && recordingLock))

            CaptureModeSelector(
                selectedMode: camera.captureMode,
                isEnabled: !camera.isRecording && !camera.isRecordingStarting && !camera.isFinalizingRecording && !camera.isCapturingPhoto && !camera.isLensTransitioning && countdown == 0,
                unavailableModes: CameraManager.CaptureMode.allCases.filter { !camera.isCaptureModeSupported($0) },
                onSelect: { camera.selectCaptureMode($0) }
            )
                .padding(.bottom, 8)

            HStack {
                CameraIconButton(symbol: "ellipsis", isEnabled: !camera.isRecording && !camera.isRecordingStarting && !camera.isFinalizingRecording && !camera.isCapturingPhoto && !camera.isLensTransitioning && countdown == 0, color: accent.color) {
                    withAnimation(.easeOut(duration: 0.16)) { isShowingProTools.toggle() }
                }
                Spacer()
                if camera.captureMode == .photo {
                    PhotoButton(
                        isCapturing: camera.isCapturingPhoto,
                        onTap: {
                            guard !editingStats else { return }
                            shutterPressed()
                        },
                        onBurstStart: {
                            guard !editingStats else { return }
                            cancelCountdown()
                            captureHaptic()
                            camera.captureBurst()
                        },
                        onBurstEnd: {
                            camera.stopBurst()
                        }
                    )
                } else if camera.isRecording && recordingLock {
                    Image(systemName: "lock.fill")
                        .font(.title2).foregroundStyle(accent.color)
                        .frame(width: 76, height: 76)
                        .background(.black.opacity(0.6), in: Circle())
                        .overlay(Circle().stroke(.red, lineWidth: 3))
                        .onLongPressGesture(minimumDuration: 1) { CameraHaptics.fire(captureOnly: true); camera.startOrStopRecording() }
                        .accessibilityLabel("Recording locked. Hold to stop")
                        .accessibilityAction(named: "Stop recording") { camera.startOrStopRecording() }
                } else {
                    RecordButton(isRecording: camera.isRecording, isEnabled: !camera.isRecordingStarting && !camera.isFinalizingRecording && !camera.isLensTransitioning) {
                        shutterPressed()
                    }
                }
            Spacer()
            CameraIconButton(symbol: "camera.rotate", isEnabled: !camera.isRecording && !camera.isRecordingStarting && !camera.isFinalizingRecording && !camera.isCapturingPhoto && !camera.isLensTransitioning && countdown == 0, color: accent.color) {
                camera.switchCamera()
            }
            }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var statusToast: some View {
        if let message = camera.statusMessage {
            HStack {
                Spacer(minLength: 0)
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(.black.opacity(0.75), in: Capsule())
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .transition(.opacity)
            .task(id: camera.statusMessageID) {
                let id = camera.statusMessageID
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                camera.clearStatus(id: id)
            }
        }
    }

    private var zoomGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStartZoom == nil {
                    dragStartZoom = camera.zoomFactor
                    camera.beginZoomInteraction()
                    AppEventLog.event("Zoom gesture began at \(camera.zoomLabel)")
                }
                guard let dragStartZoom else { return }
                let screenWidth = max(zoomWidth, 1)
                let zoomRange = camera.maximumZoomFactor - camera.minimumZoomFactor
                let requestedZoom = dragStartZoom - (value.translation.width / screenWidth * zoomRange * zoomSpeed)
                camera.setZoomFactor(requestedZoom)
            }
            .onEnded { value in
                if tapZoomReset, abs(value.translation.width) < 4, abs(value.translation.height) < 4 {
                    camera.setZoomFactor(1)
                    AppEventLog.event("Zoom gesture tapped: reset requested to 1×")
                }
                AppEventLog.event("Zoom gesture ended at \(camera.zoomLabel)")
                camera.endZoomInteraction()
                dragStartZoom = nil
            }
    }

    private func captureHaptic() {
        guard isHapticCaptureEnabled else { return }
        AppEventLog.event("Capture haptic requested")
        CameraHaptics.fire(captureOnly: true)
    }

    private var hudWhiteBalanceLabel: String {
        switch camera.whiteBalancePreset {
        case .auto: return "AWB"
        case .daylight: return "Day"
        case .cloudy: return "Cloud"
        case .tungsten: return "Tung"
        case .fluorescent: return "Fluor"
        }
    }

    private func cancelCountdown() {
        if countdown > 0 || shutterTask != nil {
            AppEventLog.event("Shutter countdown canceled at \(countdown) seconds remaining")
        }
        shutterTask?.cancel()
        shutterTask = nil
        countdown = 0
    }

    private func shutterPressed() {
        AppEventLog.event("Shutter pressed: mode=\(camera.captureMode.rawValue), recording=\(camera.isRecording), delay=\(shutterDelay)s")
        if countdown > 0 { cancelCountdown(); return }
        if camera.isRecording { captureHaptic(); camera.startOrStopRecording(); return }
        guard !camera.isRecordingStarting, !camera.isFinalizingRecording,
              shutterTask == nil, camera.isSessionRunning else {
            AppEventLog.event("Shutter ignored: starting=\(camera.isRecordingStarting), finalizing=\(camera.isFinalizingRecording), pendingCountdown=\(shutterTask != nil), sessionRunning=\(camera.isSessionRunning)")
            return
        }
        let mode = camera.captureMode
        shutterTask = Task { @MainActor in
            countdown = shutterDelay
            if countdown > 0 { AppEventLog.event("Shutter countdown started: \(countdown)s") }
            while countdown > 0 {
                if countdownHaptics { CameraHaptics.fire() }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                countdown -= 1
            }
            guard !Task.isCancelled, scenePhase == .active, camera.captureMode == mode else { return }
            AppEventLog.event("Shutter executing: mode=\(mode.rawValue)")
            captureHaptic()
            if mode == .photo { camera.capturePhoto() } else { camera.startOrStopRecording() }
            shutterTask = nil
        }
    }

    private func updateIdleTimer(for phase: ScenePhase) {
        UIApplication.shared.isIdleTimerDisabled = keepScreenAwakeEnabled && phase == .active
    }

    private var storagePollingState: StoragePollingState {
        guard scenePhase == .active else { return .inactive }
        guard !isShowingSettings else { return .covered }
        return camera.isRecording ? .recording : .idle
    }
}
