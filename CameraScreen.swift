import SwiftUI
import UIKit
import AVKit

struct CameraScreen: View {

    @ObservedObject var settings: AppSettings
    @ObservedObject var recorder: CameraRecorder

    @State private var showSettings = false
    @State private var showPlayer = false
    @State private var showProMenu = false
    @State private var dimmed = false
    @State private var savedBrightness: CGFloat = UIScreen.main.brightness
    @State private var blink = false

    // Countdown State
    @State private var countdownRemaining = 0
    @State private var countdownTimer: Timer?

    // Zoom
    @State private var zoomGestureBase: CGFloat = 1
    @State private var isPinching = false
    @State private var showZoomLabel = false
    @State private var zoomLabelHideToken = 0

    // Tap to focus
    @State private var focusPoint: CGPoint?
    @State private var focusHideToken = 0

    @State private var startHaptic = UIImpactFeedbackGenerator(style: .medium)
    @State private var stopHaptic = UIImpactFeedbackGenerator(style: .light)
    @State private var levelHaptic = UISelectionFeedbackGenerator()

    private var plan: EncodePlan { Encoder.plan(for: settings) }

    var body: some View {
        ZStack {
            // Full-bleed preview layer
            ZStack {
                Color.black

                CameraPreview(session: recorder.session, onTap: { [weak recorder] devicePoint, viewPoint in
                    if showProMenu {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showProMenu = false }
                    }
                    recorder?.focusAndExpose(at: devicePoint)
                    showFocusReticle(at: viewPoint)
                }, onDoubleTap: { [weak recorder] in
                    recorder?.flipCamera()
                })
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            if !isPinching {
                                isPinching = true
                                zoomGestureBase = recorder.zoomFactor
                            }
                            showZoomLabel = true
                            recorder.setZoom(factor: zoomGestureBase * value)
                        }
                        .onEnded { _ in
                            isPinching = false
                            scheduleHideZoomLabel()
                        }
                )

                if let focusPoint {
                    focusReticle.position(focusPoint)
                }

                if settings.showGrid { gridOverlay }

                if settings.showLevelGauge { levelGaugeOverlay }

                if showZoomLabel { zoomLabel }

                if countdownRemaining > 0 { countdownOverlay }

                if dimmed { dimOverlay }
            }
            .ignoresSafeArea()

            // Safe area HUD (Locked strictly to portrait)
            if recorder.permissionDenied {
                permissionMessage
            } else {
                VStack(spacing: 0) {
                    topHUD
                    Spacer()
                    if let notice = recorder.notice { noticeBar(notice) }
                    
                    if showProMenu && !recorder.isRecording && !recorder.isSaving {
                        proToolsDrawer
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .padding(.bottom, 8)
                    }

                    bottomHUD
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .statusBar(hidden: true)
        .accentColor(Palette.mint)
        .onAppear {
            recorder.start()
            startHaptic.prepare()
            stopHaptic.prepare()
            levelHaptic.prepare()
        }
        .onDisappear {
            if dimmed { leaveDim() }
            recorder.stop()
            countdownTimer?.invalidate()
        }
        .onChange(of: recorder.isLevel) { isLevel in
            if isLevel && settings.showLevelGauge {
                levelHaptic.selectionChanged()
            }
        }
        .onChange(of: showSettings) { isPresented in
            if isPresented {
                recorder.stopMotionUpdates()
                recorder.pauseVolumeMonitoring()
            } else {
                recorder.startMotionUpdates()
                recorder.resumeVolumeMonitoring()
            }
        }
        .onChange(of: showPlayer) { isPresented in
            if isPresented {
                recorder.stopMotionUpdates()
                recorder.pauseVolumeMonitoring()
            } else {
                recorder.startMotionUpdates()
                recorder.resumeVolumeMonitoring()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            if dimmed { leaveDim() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsScreen(settings: settings, recorder: recorder)
        }
        .sheet(isPresented: $showPlayer) {
            if let url = recorder.lastClipURL {
                ClipPlayerView(url: url)
            }
        }
    }

    // MARK: Top HUD Bar

    private var topHUD: some View {
        HStack(alignment: .center, spacing: 12) {
            // Top Left: Flashlight Button
            if recorder.hasTorch {
                facetButton(system: recorder.torchOn ? "bolt.fill" : "bolt.slash.fill",
                            tint: recorder.torchOn ? Palette.amber : .white) {
                    recorder.toggleTorch()
                }
            } else {
                Spacer().frame(width: 48, height: 48)
            }

            Spacer()

            compactInfoPill

            Spacer()

            // Top Right: Settings Button
            facetButton(system: "gearshape.fill") { showSettings = true }
                .disabled(recorder.isRecording || recorder.isSaving || recorder.isSwitchingCamera)
                .opacity((recorder.isRecording || recorder.isSaving || recorder.isSwitchingCamera) ? 0.35 : 1)
        }
    }

    private var compactInfoPill: some View {
        VStack(spacing: 2) {
            if recorder.isRecording || recorder.isSaving {
                recordingStatusRow
            } else {
                HStack(spacing: 6) {
                    Text(settings.cameraMode == .slowMo
                         ? "SLO-MO · \(settings.slowMoFrameRate.label)"
                         : "\(settings.resolution.label) · \(settings.quality.label)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(settings.cameraMode == .slowMo ? Palette.amber : Palette.mintBright)

                    Text("·")
                        .foregroundColor(.white.opacity(0.4))

                    Text("\(Int(plan.megabytesPerHour.rounded())) MB/h")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Palette.amber)
                }

                HStack(spacing: 6) {
                    Text(Fmt.size(recorder.freeBytes) + " free")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))

                    if recorder.batteryPercent >= 0 {
                        Text("·")
                            .foregroundColor(.white.opacity(0.4))
                        batteryIndicator
                    }
                }
            }

            if recorder.isRecording && settings.recordAudio {
                audioLevelBar
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
    }

    private var recordingStatusRow: some View {
        HStack(spacing: 8) {
            if recorder.isRecording {
                Facet(sides: 6)
                    .fill(Palette.record)
                    .frame(width: 10, height: 10)
                    .shadow(color: Palette.record, radius: blink ? 5 : 0)
                    .opacity(blink ? 0.3 : 1)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: blink)

                Text("REC")
                    .font(.system(size: 12, weight: .black))
                Text(Fmt.duration(recorder.elapsed))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))

                if recorder.droppedFrames > 0 {
                    Text("\(recorder.droppedFrames)d")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Palette.amber)
                }
            } else if recorder.isSaving {
                ProgressView().tint(Palette.mintBright).scaleEffect(0.7)
                Text("Saving…")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Palette.mintBright)
            }
        }
        .foregroundColor(.white)
        .onAppear { blink = true }
        .onDisappear { blink = false }
    }

    private var batteryIndicator: some View {
        let pct = recorder.batteryPercent
        let color: Color = recorder.batteryCharging ? Palette.mintBright
            : pct <= 20 ? Palette.record
            : pct <= 40 ? Palette.amber
            : .white.opacity(0.8)
        return HStack(spacing: 3) {
            Image(systemName: recorder.batteryCharging ? "battery.100.bolt" : "battery.75")
                .font(.system(size: 10))
            Text("\(pct)%")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(color)
    }

    private var audioLevelBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule()
                    .fill(LinearGradient(colors: [Palette.mintDeep, audioLevelColor], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(3, geo.size.width * CGFloat(recorder.audioLevel)))
                    .animation(.spring(response: 0.2, dampingFraction: 0.8), value: recorder.audioLevel)
            }
        }
        .frame(width: 80, height: 4)
    }

    private var audioLevelColor: Color {
        recorder.audioLevel > 0.85 ? Palette.record
            : recorder.audioLevel > 0.6 ? Palette.amber
            : Palette.mintBright
    }

    // MARK: Floating Pro Mini-Window

    private var proToolsDrawer: some View {
        VStack(spacing: 14) {
            HStack {
                Label("PRO TOOLS", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .black))
                    .foregroundColor(Palette.mintBright)

                Spacer()

                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showProMenu = false }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }

            // EV Exposure Slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Exposure (EV)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Text(String(format: "%@%.1f EV", settings.exposureBias > 0 ? "+" : "", settings.exposureBias))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(Palette.amber)

                    Button("Reset") {
                        settings.exposureBias = 0.0
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Palette.mint)
                    .padding(.leading, 6)
                }

                Slider(value: $settings.exposureBias, in: -2.0...2.0, step: 0.1)
                    .tint(Palette.amber)
                    .onChange(of: settings.exposureBias) { val in
                        recorder.setExposureBias(val)
                    }
            }

            // White Balance Presets 
            VStack(alignment: .leading, spacing: 6) {
                Text("White Balance")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(WhiteBalancePreset.allCases) { preset in
                            let isSelected = settings.whiteBalance == preset
                            Button(action: { settings.whiteBalance = preset }) {
                                HStack(spacing: 5) {
                                    Image(systemName: preset.icon)
                                    Text(preset.label)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                                .foregroundColor(isSelected ? .black : .white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(isSelected ? Palette.mintBright : Color.white.opacity(0.12))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .onChange(of: settings.whiteBalance) { preset in
                    recorder.setWhiteBalance(preset)
                }
            }

            // Quick Toggles Row
            HStack(spacing: 10) {
                Button(action: {
                    withAnimation {
                        settings.showLevelGauge.toggle()
                        if settings.showLevelGauge {
                            recorder.startMotionUpdates()
                        } else {
                            recorder.stopMotionUpdates()
                        }
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "gyroscope")
                        Text("Level Meter")
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(settings.showLevelGauge ? .black : .white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(settings.showLevelGauge ? Palette.mintBright : Color.white.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "timer")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))

                    ForEach(CountdownTimer.allCases) { timer in
                        let isSelected = settings.countdownTimer == timer
                        Button(action: { settings.countdownTimer = timer }) {
                            Text(timer.label)
                                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                                .foregroundColor(isSelected ? .black : .white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(isSelected ? Palette.amber : Color.white.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 15, x: 0, y: 8)
    }

    // MARK: Bottom HUD Bar

    private var bottomHUD: some View {
        VStack(spacing: 12) {
            HStack {
                if !recorder.isRecording && !recorder.isSaving {
                    modeSelector
                        .disabled(recorder.isSwitchingCamera)
                        .opacity(recorder.isSwitchingCamera ? 0.35 : 1)

                    Button(action: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            showProMenu.toggle()
                        }
                    }) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(showProMenu ? Palette.mintBright : .white)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial)
                            .environment(\.colorScheme, .dark)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.2), radius: 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(recorder.isSwitchingCamera)
                    .opacity(recorder.isSwitchingCamera ? 0.35 : 1)
                }
            }

            HStack(alignment: .center) {
                if !recorder.isRecording && !recorder.isSaving, let thumb = recorder.lastClipThumbnail {
                    Button(action: { showPlayer = true }) {
                        Image(uiImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 50, height: 50)
                            .clipShape(Facet(sides: 6, rotation: .pi / 6))
                            .overlay(Facet(sides: 6, rotation: .pi / 6).stroke(Color.white.opacity(0.35), lineWidth: 1.5))
                            .shadow(color: .black.opacity(0.3), radius: 5)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer().frame(width: 50, height: 50)
                }

                Spacer()

                recordButton

                Spacer()

                if recorder.isRecording {
                    facetButton(system: "moon.fill", size: 56) { enterDim() }
                } else {
                    facetButton(system: "arrow.triangle.2.circlepath.camera.fill", size: 56) {
                        recorder.flipCamera()
                    }
                    .disabled(recorder.isSaving || recorder.isSwitchingCamera || countdownRemaining > 0)
                    .opacity((recorder.isSaving || recorder.isSwitchingCamera || countdownRemaining > 0) ? 0.35 : 1)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    private var recordButton: some View {
        Button {
            // Belt-and-suspenders: even though the button is visually
            // disabled while switching cameras, ignore any tap that sneaks
            // through (e.g. one already in flight when the state flips)
            // rather than letting it start a recording.
            guard !recorder.isSwitchingCamera else { return }
            if recorder.isRecording {
                stopHaptic.impactOccurred()
                stopHaptic.prepare()
                recorder.toggleRecording()
            } else {
                if countdownRemaining > 0 {
                    cancelCountdown()
                } else if settings.countdownTimer != .off {
                    startCountdown()
                } else {
                    startHaptic.impactOccurred()
                    startHaptic.prepare()
                    recorder.toggleRecording()
                }
            }
        } label: {
            ZStack {
                Facet(sides: 12)
                    .stroke(LinearGradient(colors: [Palette.mintBright, Palette.mintDeep], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 4)
                    .frame(width: 78, height: 78)
                    .shadow(color: Palette.mint.opacity(0.3), radius: 6)

                Facet(sides: 12)
                    .stroke(Palette.mintDeep.opacity(0.3), lineWidth: 1.5)
                    .frame(width: 66, height: 66)

                if recorder.isSaving {
                    ProgressView().tint(Palette.mintBright).scaleEffect(1.2)
                } else if recorder.isRecording {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [Palette.record, Palette.record.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 32, height: 32)
                        .shadow(color: Palette.record.opacity(0.6), radius: 10)
                } else if countdownRemaining > 0 {
                    Image(systemName: "xmark")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Facet(sides: 12)
                        .fill(LinearGradient(colors: [Palette.record, Palette.record.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 58, height: 58)
                        .shadow(color: Palette.record.opacity(0.4), radius: 6, x: 0, y: 3)
                }
            }
            .frame(width: 84, height: 84)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(recorder.isSaving || recorder.isSwitchingCamera)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: recorder.isRecording)
    }

    private var modeSelector: some View {
        let modes = CameraMode.allCases
        let modeHaptic = UISelectionFeedbackGenerator()

        return HStack(spacing: 0) {
            ForEach(modes) { mode in
                let isActive = settings.cameraMode == mode
                Button {
                    guard settings.cameraMode != mode else { return }
                    modeHaptic.selectionChanged()
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                        settings.cameraMode = mode
                    }
                    recorder.updateCaptureFormat()
                } label: {
                    Text(mode.label)
                        .font(.system(size: 13, weight: isActive ? .bold : .medium))
                        .foregroundColor(isActive
                            ? (mode == .slowMo ? Palette.amber : Palette.mintBright)
                            : .white.opacity(0.6))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 3)
    }

    private func facetButton(system: String,
                             size: CGFloat = 48,
                             tint: Color = .white,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size * 0.38, weight: .medium))
                .foregroundColor(tint)
                .frame(width: size, height: size)
                .background(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .clipShape(Facet(sides: 6, rotation: .pi / 6))
                .overlay(
                    Facet(sides: 6, rotation: .pi / 6)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 3)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Overlays (Level Meter & Countdown)

    private var levelGaugeOverlay: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let isLevel = recorder.isLevel

            ZStack {
                Circle()
                    .stroke(isLevel ? Palette.mintBright : Color.white.opacity(0.3), lineWidth: 1.5)
                    .frame(width: 12, height: 12)

                HStack(spacing: 24) {
                    Rectangle()
                        .fill(isLevel ? Palette.mintBright : Color.white.opacity(0.3))
                        .frame(width: 40, height: 1.5)

                    Spacer().frame(width: 12)

                    Rectangle()
                        .fill(isLevel ? Palette.mintBright : Color.white.opacity(0.3))
                        .frame(width: 40, height: 1.5)
                }
                .rotationEffect(.degrees(-recorder.rollAngle))
                .animation(.spring(response: 0.15, dampingFraction: 0.8), value: recorder.rollAngle)
            }
            .position(x: w / 2, y: h / 2)
            .shadow(color: isLevel ? Palette.mint.opacity(0.6) : .clear, radius: 4)
        }
        .allowsHitTesting(false)
    }

    private var countdownOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                Text("\(countdownRemaining)")
                    .font(.system(size: 84, weight: .black, design: .rounded))
                    .foregroundColor(Palette.amber)
                    .shadow(color: Palette.amber.opacity(0.6), radius: 20)
                    .scaleEffect(1.1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: countdownRemaining)

                Text("Tap shutter to cancel")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .allowsHitTesting(false)
    }

    private func startCountdown() {
        countdownRemaining = settings.countdownTimer.rawValue
        let haptic = UIImpactFeedbackGenerator(style: .heavy)
        haptic.prepare()

        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            haptic.impactOccurred()
            if countdownRemaining > 1 {
                countdownRemaining -= 1
            } else {
                countdownTimer?.invalidate()
                countdownTimer = nil
                countdownRemaining = 0
                guard !recorder.isSwitchingCamera else { return }
                startHaptic.impactOccurred()
                recorder.startRecording()
            }
        }
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownRemaining = 0
    }

    private func noticeBar(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
            .padding(.bottom, 10)
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    recorder.notice = nil
                }
            }
    }

    private var permissionMessage: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 44))
                .foregroundColor(Palette.mint)
                .shadow(color: Palette.mint.opacity(0.5), radius: 10)
            Text("Camera access is off")
                .font(.system(size: 20, weight: .bold))
            Text("Turn it on in Settings › LowPolyCam.")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.7))
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(Palette.mintBright)
            .padding(.top, 8)
        }
        .foregroundColor(.white)
        .padding(32)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
    }

    // MARK: Zoom & Focus

    private var gridOverlay: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height
                for i in 1...2 {
                    let x = w * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))
                    let y = h * CGFloat(i) / 3
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }

    private var zoomLabel: some View {
        Text(String(format: "%.1fx", recorder.zoomFactor))
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 3)
    }

    private func scheduleHideZoomLabel() {
        zoomLabelHideToken += 1
        let token = zoomLabelHideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if zoomLabelHideToken == token {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    showZoomLabel = false
                }
            }
        }
    }

    private var focusReticle: some View {
        Facet(sides: 6, rotation: .pi / 6)
            .stroke(Palette.mintBright, lineWidth: 1.5)
            .frame(width: 56, height: 56)
            .shadow(color: Palette.mint.opacity(0.5), radius: 4)
            .scaleEffect(focusPoint == nil ? 1.2 : 1.0)
            .opacity(focusPoint == nil ? 0 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: focusPoint)
    }

    private func showFocusReticle(at point: CGPoint) {
        focusHideToken += 1
        let token = focusHideToken
        focusPoint = point
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            if focusHideToken == token {
                focusPoint = nil
            }
        }
    }

    // MARK: Dim Mode

    private var dimOverlay: some View {
        Color.black
            .ignoresSafeArea()
            .overlay(
                VStack(spacing: 12) {
                    Facet(sides: 6)
                        .fill(Palette.record)
                        .frame(width: 12, height: 12)
                        .shadow(color: Palette.record, radius: blink ? 6 : 0)
                        .opacity(blink ? 0.3 : 1)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: blink)

                    Text("recording · tap to wake")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.2))
                }
            )
            .onTapGesture { leaveDim() }
    }

    private func enterDim() {
        savedBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = 0
        withAnimation(.easeIn(duration: 0.3)) { dimmed = true }
    }

    private func leaveDim() {
        UIScreen.main.brightness = savedBrightness
        withAnimation(.easeOut(duration: 0.2)) { dimmed = false }
    }
}

// MARK: - In-App Video Preview Player

struct ClipPlayerView: View {
    let url: URL
    @Environment(\.presentationMode) private var presentation
    @State private var player: AVPlayer?
    @State private var loadFailed = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player, !loadFailed {
                    VideoPlayer(player: player)
                        .ignoresSafeArea(edges: .bottom)
                } else if loadFailed {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(Palette.amber)
                            .shadow(color: Palette.amber.opacity(0.5), radius: 10)
                        Text("Unable to play video preview")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text("The clip file could not be found or opened.")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding()
                } else {
                    ProgressView().tint(Palette.mintBright).scaleEffect(1.2)
                }
            }
            .navigationBarTitle("Preview", displayMode: .inline)
            .navigationBarItems(trailing: Button("Done") {
                player?.pause()
                presentation.wrappedValue.dismiss()
            })
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(Palette.mint)
        .onAppear {
            guard FileManager.default.fileExists(atPath: url.path) else {
                loadFailed = true
                return
            }
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}
