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
            bottomBar
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    if recorder.isRecording || recorder.isSaving {
                        recordingStatusRow
                    }
                    Text("\(settings.resolution.label) · \(settings.quality.label)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Palette.mintBright)
                    Text(plan.sizeLabel)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.55))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    if recorder.batteryPercent >= 0 { batteryIndicator }
                    Text("\(Int(plan.megabytesPerHour.rounded())) MB / hour")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Palette.amber)
                    Text("\(Fmt.size(recorder.freeBytes)) free · about \(Fmt.hours(hoursLeft))")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.55))
                }
            }
            if recorder.isRecording && settings.recordAudio { audioLevelBar }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Palette.panel.opacity(0.72)
                .overlay(Palette.mint.opacity(0.05))
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Palette.mint.opacity(0.18), lineWidth: 1)
        )
    }

    private var recordingStatusRow: some View {
        Group {
            if recorder.isRecording {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Facet(sides: 6)
                            .fill(Palette.record)
                            .frame(width: 12, height: 12)
                            .opacity(blink ? 0.25 : 1)
                            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                                       value: blink)
                        Text("REC")
                            .font(.system(size: 13, weight: .bold))
                        Text(Fmt.duration(recorder.elapsed))
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    }
                    .fixedSize()
                    if recorder.droppedFrames > 0 {
                        Text("\(recorder.droppedFrames) frame\(recorder.droppedFrames == 1 ? "" : "s") dropped")
                            .font(.system(size: 11))
                            .foregroundColor(Palette.amber)
                    }
                }
                .foregroundColor(.white)
                .onAppear { blink = true }
                .onDisappear { blink = false }
            } else if recorder.isSaving {
                HStack(spacing: 8) {
                    ProgressView().tint(Palette.mint).scaleEffect(0.7)
                    Text("Saving…")
                        .font(.system(size: 13, weight: .semibold))
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
            : .white.opacity(0.8)
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
            Text("\(pct)%").font(.system(size: 12, weight: .medium))
        }
        .foregroundColor(color)
    }

    private var audioLevelBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule()
                    .fill(audioLevelColor)
                    .frame(width: max(3, geo.size.width * CGFloat(recorder.audioLevel)))
                    .animation(.easeOut(duration: 0.15), value: recorder.audioLevel)
            }
        }
        .frame(width: 90, height: 5)
    }

    private var audioLevelColor: Color {
        recorder.audioLevel > 0.85 ? Palette.record
            : recorder.audioLevel > 0.6 ? Palette.amber
            : Palette.mint
    }

    private var bottomBar: some View {
        ZStack {
            HStack(spacing: 12) {
                facetButton(system: "gearshape.fill") { showSettings = true }
                    .disabled(recorder.isRecording || recorder.isSaving)
                    .opacity((recorder.isRecording || recorder.isSaving) ? 0.35 : 1)

                if recorder.hasTorch {
                    facetButton(system: recorder.torchOn ? "bolt.fill" : "bolt.slash.fill",
                                tint: recorder.torchOn ? Palette.amber : Palette.mintBright) {
                        recorder.toggleTorch()
                    }
                }

                if !recorder.isRecording && !recorder.isSaving, let thumb = recorder.lastClipThumbnail {
                    Button(action: { showPlayer = true }) {
                        Image(uiImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 50, height: 50)
                            .clipShape(Facet(sides: 6, rotation: .pi / 6))
                            .overlay(
                                Facet(sides: 6, rotation: .pi / 6)
                                    .stroke(Palette.mint, lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }

                Spacer()
            }

            HStack {
                Spacer()

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
                Facet(sides: 12)
                    .stroke(Palette.mint, lineWidth: 4)
                    .frame(width: 78, height: 78)
                Facet(sides: 12)
                    .stroke(Palette.mintDeep.opacity(0.55), lineWidth: 2)
                    .frame(width: 66, height: 66)

                if recorder.isSaving {
                    ProgressView().tint(Palette.mintBright)
                } else if recorder.isRecording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Palette.record)
                        .frame(width: 30, height: 30)
                } else {
                    Facet(sides: 12)
                        .fill(Palette.record)
                        .frame(width: 58, height: 58)
                }
            }
            .frame(width: 84, height: 84)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(recorder.isSaving)
        .animation(.easeInOut(duration: 0.18), value: recorder.isRecording)
    }

    private func facetButton(system: String,
                             tint: Color = Palette.mintBright,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 19))
                .foregroundColor(tint)
                .frame(width: 54, height: 54)
                .background(
                    Facet(sides: 6, rotation: .pi / 6)
                        .fill(Palette.slateDeep.opacity(0.85))
                )
                .overlay(
                    Facet(sides: 6, rotation: .pi / 6)
                        .stroke(Palette.mint.opacity(0.25), lineWidth: 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func noticeBar(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Palette.panel.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Palette.mint.opacity(0.3), lineWidth: 1)
            )
            .padding(.bottom, 14)
            .onTapGesture { recorder.notice = nil }
    }

    private var permissionMessage: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40))
                .foregroundColor(Palette.mint)
            Text("Camera access is off")
                .font(.system(size: 18, weight: .semibold))
            Text("Turn it on in Settings › LowPolyCam.")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.7))
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .foregroundColor(Palette.mintBright)
            .padding(.top, 4)
        }
        .foregroundColor(.white)
        .padding(30)
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
            .stroke(Color.white.opacity(0.35), lineWidth: 0.75)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private var zoomLabel: some View {
        Text(String(format: "%.1fx", recorder.zoomFactor))
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Palette.panel.opacity(0.85)))
            .overlay(Capsule().stroke(Palette.mint.opacity(0.4), lineWidth: 1))
            .transition(.opacity)
    }

    private func scheduleHideZoomLabel() {
        zoomLabelHideToken += 1
        let token = zoomLabelHideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if zoomLabelHideToken == token {
                withAnimation { showZoomLabel = false }
            }
        }
    }

    // MARK: Tap to focus

    private var focusReticle: some View {
        Facet(sides: 6, rotation: .pi / 6)
            .stroke(Palette.mint, lineWidth: 1.5)
            .frame(width: 56, height: 56)
            .opacity(focusPoint == nil ? 0 : 1)
    }

    private func showFocusReticle(at point: CGPoint) {
        focusHideToken += 1
        let token = focusHideToken
        withAnimation(.easeOut(duration: 0.15)) { focusPoint = point }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            if focusHideToken == token {
                withAnimation(.easeIn(duration: 0.2)) { focusPoint = nil }
            }
        }
    }

    // MARK: Dim mode

    private var dimOverlay: some View {
        Color.black
            .ignoresSafeArea()
            .overlay(
                VStack(spacing: 10) {
                    Facet(sides: 6)
                        .fill(Palette.record.opacity(0.5))
                        .frame(width: 10, height: 10)
                    Text("recording · tap to wake")
                        .font(.system(size: 11))
                        .foregroundColor(Palette.mint.opacity(0.16))
                }
            )
            .onTapGesture { leaveDim() }
    }

    private func enterDim() {
        savedBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = 0
        dimmed = true
    }

    private func leaveDim() {
        UIScreen.main.brightness = savedBrightness
        dimmed = false
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

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView().tint(Palette.mint)
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
