import SwiftUI
import UIKit
import AVKit

struct CameraScreen: View {

    @ObservedObject var settings: AppSettings
    @ObservedObject var recorder: CameraRecorder

    @State private var showSettings = false
    @State private var showPlayer = false
    @State private var dimmed = false
    @State private var savedBrightness: CGFloat = UIScreen.main.brightness
    @State private var blink = false

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

    private var plan: EncodePlan { Encoder.plan(for: settings) }

    var body: some View {
        ZStack {
            // Full-bleed layer
            ZStack {
                Color.black

                CameraPreview(session: recorder.session) { devicePoint, viewPoint in
                    recorder.focusAndExpose(at: devicePoint)
                    showFocusReticle(at: viewPoint)
                }
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

                if showZoomLabel { zoomLabel }

                if dimmed { dimOverlay }
            }
            .ignoresSafeArea()

            // Safe area UI layer
            if recorder.permissionDenied {
                permissionMessage
            } else {
                controls
            }
        }
        .statusBar(hidden: true)
        .preferredColorScheme(.dark)
        .accentColor(Palette.mint)
        .onAppear {
            recorder.start()
            startHaptic.prepare()
            stopHaptic.prepare()
        }
        .onDisappear {
            if dimmed { leaveDim() }
            recorder.stop()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willResignActiveNotification)) { _ in
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

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            if let notice = recorder.notice { noticeBar(notice) }
            if !recorder.isRecording && !recorder.isSaving {
                modeSelector
                    .padding(.bottom, 14)
            }
            bottomBar
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if recorder.isRecording || recorder.isSaving {
                        recordingStatusRow
                    }
                    if settings.cameraMode == .slowMo {
                        Text("SLO-MO · \(settings.slowMoFrameRate.label) (\(settings.slowMoFrameRate.multiplierLabel))")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(Palette.amber)
                            .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                    } else {
                        Text("\(settings.resolution.label) · \(settings.quality.label)")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(Palette.mintBright)
                            .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                    }
                    Text(plan.sizeLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    if recorder.batteryPercent >= 0 { batteryIndicator }
                    Text("\(Int(plan.megabytesPerHour.rounded())) MB / hour")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Palette.amber)
                        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                    Text("\(Fmt.size(recorder.freeBytes)) free · about \(Fmt.hours(hoursLeft))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            if recorder.isRecording && settings.recordAudio { audioLevelBar }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
    }

    private var recordingStatusRow: some View {
        Group {
            if recorder.isRecording {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Facet(sides: 6)
                            .fill(Palette.record)
                            .frame(width: 12, height: 12)
                            .shadow(color: Palette.record, radius: blink ? 6 : 0)
                            .opacity(blink ? 0.3 : 1)
                            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: blink)
                        
                        Text("REC")
                            .font(.system(size: 13, weight: .black))
                            .shadow(color: .black.opacity(0.5), radius: 2)
                        Text(Fmt.duration(recorder.elapsed))
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .shadow(color: .black.opacity(0.5), radius: 2)
                    }
                    .fixedSize()
                    if recorder.droppedFrames > 0 {
                        Text("\(recorder.droppedFrames) frame\(recorder.droppedFrames == 1 ? "" : "s") dropped")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Palette.amber)
                    }
                }
                .foregroundColor(.white)
                .onAppear { blink = true }
                .onDisappear { blink = false }
            } else if recorder.isSaving {
                HStack(spacing: 8) {
                    ProgressView().tint(Palette.mintBright).scaleEffect(0.8)
                    Text("Saving…")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Palette.mintBright)
                }
            }
        }
    }

    private var batteryIndicator: some View {
        let pct = recorder.batteryPercent
        let color: Color = recorder.batteryCharging ? Palette.mintBright
            : pct <= 20 ? Palette.record
            : pct <= 40 ? Palette.amber
            : .white.opacity(0.9)
        let symbol: String = {
            if recorder.batteryCharging { return "battery.100.bolt" }
            switch pct {
            case ..<13: return "battery.0"
            case ..<38: return "battery.25"
            case ..<63: return "battery.50"
            case ..<88: return "battery.75"
            default: return "battery.100"
            }
        }()
        return HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 13))
            Text("\(pct)%").font(.system(size: 12, weight: .bold))
        }
        .foregroundColor(color)
        .shadow(color: .black.opacity(0.5), radius: 2)
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
        .frame(width: 90, height: 5)
    }

    private var audioLevelColor: Color {
        recorder.audioLevel > 0.85 ? Palette.record
            : recorder.audioLevel > 0.6 ? Palette.amber
            : Palette.mintBright
    }

    private var bottomBar: some View {
        ZStack {
            // LEFT CONTROLS
            HStack(spacing: 12) {
                facetButton(system: "gearshape.fill") { showSettings = true }
                    .disabled(recorder.isRecording || recorder.isSaving)
                    .opacity((recorder.isRecording || recorder.isSaving) ? 0.35 : 1)

                if recorder.hasTorch {
                    facetButton(system: recorder.torchOn ? "bolt.fill" : "bolt.slash.fill",
                                tint: recorder.torchOn ? Palette.amber : .white) {
                        recorder.toggleTorch()
                    }
                }
                Spacer()
            }

            // RIGHT CONTROLS
            HStack(spacing: 12) {
                Spacer()

                if !recorder.isRecording && !recorder.isSaving, let thumb = recorder.lastClipThumbnail {
                    Button(action: { showPlayer = true }) {
                        Image(uiImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 50, height: 50)
                            .clipShape(Facet(sides: 6, rotation: .pi / 6))
                            .overlay(
                                Facet(sides: 6, rotation: .pi / 6)
                                    .stroke(Color.white.opacity(0.3), lineWidth: 1.5)
                            )
                            .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 3)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }

                if recorder.isRecording {
                    facetButton(system: "moon.fill") { enterDim() }
                } else {
                    facetButton(system: "arrow.triangle.2.circlepath.camera.fill") {
                        recorder.flipCamera()
                    }
                    .disabled(recorder.isSaving)
                    .opacity(recorder.isSaving ? 0.35 : 1)
                }
            }
            
            // CENTER RECORD BUTTON
            recordButton
        }
    }

    private var recordButton: some View {
        Button {
            if recorder.isRecording {
                stopHaptic.impactOccurred()
                stopHaptic.prepare()
            } else {
                startHaptic.impactOccurred()
                startHaptic.prepare()
            }
            recorder.toggleRecording()
        } label: {
            ZStack {
                // Outer ring
                Facet(sides: 12)
                    .stroke(LinearGradient(colors: [Palette.mintBright, Palette.mintDeep], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 4)
                    .frame(width: 78, height: 78)
                    .shadow(color: Palette.mint.opacity(0.3), radius: 6, x: 0, y: 0)

                // Inner track
                Facet(sides: 12)
                    .stroke(Palette.mintDeep.opacity(0.3), lineWidth: 1.5)
                    .frame(width: 66, height: 66)

                if recorder.isSaving {
                    ProgressView().tint(Palette.mintBright).scaleEffect(1.2)
                } else if recorder.isRecording {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [Palette.record, Palette.record.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 32, height: 32)
                        .shadow(color: Palette.record.opacity(0.6), radius: 10, x: 0, y: 0) // Glowing effect
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
        .disabled(recorder.isSaving)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: recorder.isRecording)
    }

    // Glassmorphic mode selector
    @State private var modeSelectorOffset: CGFloat = 0

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
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .shadow(color: isActive ? .black.opacity(0.5) : .clear, radius: 2)
                }
                .buttonStyle(.plain)
            }
        }
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    let horizontal = value.translation.width
                    if horizontal < -20, settings.cameraMode == .video {
                        modeHaptic.selectionChanged()
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                            settings.cameraMode = .slowMo
                        }
                        recorder.updateCaptureFormat()
                    } else if horizontal > 20, settings.cameraMode == .slowMo {
                        modeHaptic.selectionChanged()
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                            settings.cameraMode = .video
                        }
                        recorder.updateCaptureFormat()
                    }
                }
        )
    }

    private func facetButton(system: String,
                             tint: Color = .white,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 19, weight: .medium))
                .foregroundColor(tint)
                .frame(width: 52, height: 52)
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
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
            .padding(.bottom, 14)
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    recorder.notice = nil
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
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

    // MARK: Zoom & Grid

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
        .transition(.opacity)
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
            .transition(.scale.combined(with: .opacity))
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

    // MARK: Tap to focus

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

    // MARK: Dim mode

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

    private var hoursLeft: Double {
        let perHour = plan.megabytesPerHour * 1_000_000
        guard perHour > 0 else { return 0 }
        return Double(max(0, recorder.freeBytes - CameraRecorder.reserveBytes)) / perHour
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
