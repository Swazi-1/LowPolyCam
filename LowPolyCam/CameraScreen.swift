import SwiftUI
import UIKit
import AVKit

struct CameraScreen: View {

    @ObservedObject var settings: AppSettings
    @ObservedObject var recorder: CameraRecorder

    @State private var showSettings = false
    @State private var showPlayer = false
    @State private var showProMenu = false
    @State private var showGallery = false
    @State private var dimmed = false
    @State private var savedBrightness: CGFloat = UIScreen.main.brightness
    @State private var blink = false

    // Countdown State
    @State private var countdownRemaining = 0
    @State private var countdownTimer: Timer?

    // Zoom
    @State private var zoomGestureBase: CGFloat = 1
    @State private var isPinching = false
    @State private var lastRecordButtonTap = Date.distantPast
    @State private var showZoomLabel = false
    @State private var zoomLabelHideToken = 0

    // Tap to focus
    @State private var focusPoint: CGPoint?
    @State private var focusHideToken = 0

    // Notice Auto-Dismiss
    @State private var noticeHideToken = 0

    // Capture flash confirmation
    @State private var showCaptureFlash = false
    // Sustained screen-illumination for the selfie "flash" — separate from
    // showCaptureFlash above, which is just the brief post-shutter blink.
    @State private var screenFlashIlluminating = false
    @State private var frontFlashSavedBrightness: CGFloat = UIScreen.main.brightness

    @State private var startHaptic = UIImpactFeedbackGenerator(style: .medium)
    @State private var stopHaptic = UIImpactFeedbackGenerator(style: .light)
    @State private var levelHaptic = UISelectionFeedbackGenerator()
    // Reused instead of created per-render (see zoomPresetRow/modeSelector) —
    // allocating + preparing a new UIFeedbackGenerator on every SwiftUI body
    // re-evaluation is wasted work that adds up on slower A10-class devices.
    @State private var zoomHaptic = UISelectionFeedbackGenerator()
    @State private var modeHaptic = UISelectionFeedbackGenerator()

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
                            recorder.suppressVolumeTriggerBriefly()
                            recorder.setZoom(factor: zoomGestureBase * value)
                        }
                        .onEnded { _ in
                            isPinching = false
                            recorder.suppressVolumeTriggerBriefly()
                            scheduleHideZoomLabel()
                        }
                )

                if let focusPoint {
                    focusReticle.position(focusPoint)
                }

                if settings.gridStyle != .off { gridOverlay }

                if settings.showLevelGauge { levelGaugeOverlay }

                if showZoomLabel { zoomLabel }

                if countdownRemaining > 0 { countdownOverlay }

                Color.black
                    .opacity(recorder.isSwitchingCamera ? 1 : 0)
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.18), value: recorder.isSwitchingCamera)

                // Quick white flash confirming a photo was taken (like Camera.app).
                Color.white
                    .opacity(showCaptureFlash ? 0.85 : 0)
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.18), value: showCaptureFlash)

                // Sustained screen flash for selfies — front camera has no
                // physical torch, so we light the whole screen white (and
                // max out brightness) the way iOS's Camera app does, giving
                // the sensor a moment to re-expose before the shutter fires.
                Color.white
                    .opacity(screenFlashIlluminating ? 1 : 0)
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.15), value: screenFlashIlluminating)

                if dimmed { dimOverlay }
            }
            .ignoresSafeArea()

            // Safe area HUD — layout is fixed; Pro sheet overlays so opening it
            // never expands the VStack or clips edge icons.
            if recorder.permissionDenied {
                permissionMessage
            } else {
                VStack(spacing: 0) {
                    topHUD

                    if let notice = recorder.notice {
                        noticeBar(notice)
                            .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
                            .padding(.top, 8)
                    }

                    Spacer(minLength: 0)

                    bottomHUD
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                // Overlay Pro panel above the HUD so bottom controls stay put.
                if showProMenu && !recorder.isRecording && !recorder.isSaving {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                showProMenu = false
                            }
                        }
                        .transition(.opacity)

                    VStack {
                        Spacer(minLength: 0)
                        proToolsDrawer
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(20)
                }
            }
        }
        .statusBar(hidden: true)
        .accentColor(settings.accentColor.color)
        .onAppear {
            recorder.start()
            startHaptic.prepare()
            stopHaptic.prepare()
            levelHaptic.prepare()
            zoomHaptic.prepare()
            modeHaptic.prepare()
            // Sync the screen-flash overlay to the moment the sensor actually
            // captures the frame (not to button-tap), so it fires exactly once.
            // On rear camera, iOS's system already shows a flash from the hardware,
            // so only show our custom overlay on front camera to match iOS Camera.app.
            recorder.onWillCapturePhoto = {
                guard settings.captureFlashConfirmation, recorder.isFrontCamera else { return }
                showCaptureFlash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { showCaptureFlash = false }
            }
        }
        .onDisappear {
            if dimmed { leaveDim() }
            recorder.stop()
            countdownTimer?.invalidate()
        }
        .onChange(of: recorder.isLevel) { isLevel in
            if isLevel && settings.showLevelGauge && settings.hapticFeedbackEnabled {
                levelHaptic.selectionChanged()
            }
        }
        // Auto-Wake when recording stops (manual stop, auto-split, or storage full)
        .onChange(of: recorder.isRecording) { isRecording in
            if !isRecording && dimmed {
                leaveDim()
            }
        }
        // Auto-Dim Battery Saver (dims to black after 10s of recording)
        .onChange(of: recorder.elapsed) { sec in
            if settings.autoDimOnRecord && recorder.isRecording && !dimmed && sec >= 10 {
                enterDim()
            }
        }
        .onChange(of: recorder.notice) { newNotice in
            guard newNotice != nil else { return }
            noticeHideToken += 1
            let token = noticeHideToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if noticeHideToken == token {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        recorder.notice = nil
                    }
                }
            }
        }
        .onChange(of: showSettings) { isPresented in
            if isPresented {
                // Full sensor stop while the settings sheet covers the preview —
                // biggest single idle-heat win when you're not looking at the camera.
                recorder.pausePreviewSession()
            } else {
                recorder.resumePreviewSession()
            }
        }
        .onChange(of: showPlayer) { isPresented in
            if isPresented {
                recorder.pausePreviewSession()
            } else {
                recorder.resumePreviewSession()
            }
        }
        .onChange(of: showGallery) { isPresented in
            if isPresented {
                recorder.pausePreviewSession()
            } else {
                recorder.resumePreviewSession()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            if dimmed { leaveDim() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsScreen(settings: settings, recorder: recorder)
                .interactiveDismissDisabled(false)
        }
        .sheet(isPresented: $showPlayer) {
            if let url = recorder.lastClipURL {
                ClipPlayerView(url: url)
            }
        }
        .sheet(isPresented: $showGallery) {
            ClipGalleryScreen(settings: settings)
        }
    }

    // MARK: Top HUD Bar

    // Extra tap-target padding for the two most-used top-HUD buttons (flash,
    // settings). Kept as a shared constant so both stay in sync instead of
    // drifting to different inset values.
    private let topHUDHitSlop: CGFloat = 18

    private var topHUD: some View {
        HStack(alignment: .center, spacing: 8) {
            if recorder.hasTorch {
                facetButton(system: recorder.torchOn ? "bolt.fill" : "bolt.slash.fill",
                            size: 40,
                            tint: recorder.torchOn ? settings.accentColor.bright : .white,
                            hitSlop: topHUDHitSlop) {
                    recorder.toggleTorch()
                }
            } else if recorder.isFrontCamera {
                // No physical torch on the front camera — this toggles the
                // screen-illumination flash used at capture time instead
                // (see performFrontFlashCapture), same idea as stock Camera.
                facetButton(system: recorder.frontFlashEnabled ? "bolt.fill" : "bolt.slash.fill",
                            size: 40,
                            tint: recorder.frontFlashEnabled ? settings.accentColor.bright : .white,
                            hitSlop: topHUDHitSlop) {
                    recorder.frontFlashEnabled.toggle()
                    if settings.hapticFeedbackEnabled { levelHaptic.selectionChanged() }
                }
            } else {
                // Keep layout balanced even when torch is unavailable.
                Color.clear.frame(width: 40, height: 40)
            }

            Spacer(minLength: 4)

            compactInfoPill
                // Hard cap so the pill never forces the side icons past the
                // screen edge on iPhone 7–class widths. Content can still
                // shrink via minimumScaleFactor when needed.
                .frame(maxWidth: UIScreen.main.bounds.width - 112)
                .layoutPriority(1)

            Spacer(minLength: 4)

            facetButton(system: "gearshape.fill", size: 40, hitSlop: topHUDHitSlop) { showSettings = true }
                .disabled(recorder.isRecording || recorder.isSaving || recorder.isSwitchingCamera)
                .opacity((recorder.isRecording || recorder.isSaving || recorder.isSwitchingCamera) ? 0.35 : 1)
        }
    }

    private var dataRateLabel: String {
        let mb = plan.megabytesPerHour
        if mb >= 1000 {
            return String(format: "%.1f GB/h", mb / 1000.0)
        } else {
            return "\(Int(mb.rounded())) MB/h"
        }
    }

    private var qualityShortLabel: String {
        switch settings.quality {
        case .high: return "High"
        case .medium: return "Med"
        case .low: return "Low"
        case .ultraLow: return "Saver"
        }
    }

    private var compactInfoPill: some View {
        VStack(spacing: 3) {
            if recorder.isRecording || recorder.isSaving {
                recordingStatusRow
            } else {
                HStack(spacing: 5) {
                    if settings.cameraMode == .photo {
                        Text("PHOTO")
                            .font(.system(size: 10, weight: .black, design: .rounded))
                            .foregroundColor(Palette.slateDeep)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(settings.accentColor.bright)
                            .clipShape(Capsule())

                        if recorder.isCapturingPhoto {
                            ProgressView().tint(settings.accentColor.bright).scaleEffect(0.6)
                        }
                    } else if settings.cameraMode == .slowMo {
                        Text("SLO-MO")
                            .font(.system(size: 10, weight: .black, design: .rounded))
                            .foregroundColor(Palette.slateDeep)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(settings.accentColor.bright)
                            .clipShape(Capsule())

                        Text(settings.slowMoFrameRate.label)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    } else {
                        Text(settings.resolution.label)
                            .font(.system(size: 10, weight: .black, design: .rounded))
                            .foregroundColor(Palette.slateDeep)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(
                                LinearGradient(
                                    colors: [settings.accentColor.bright, settings.accentColor.color],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .clipShape(Capsule())

                        Text(qualityShortLabel)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.92))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }

                    if settings.cameraMode != .photo {
                        Text("·")
                            .foregroundColor(Palette.slateLight)
                            .font(.system(size: 11, weight: .bold))

                        Text(dataRateLabel)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(settings.accentColor.bright)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .lineLimit(1)

                HStack(spacing: 5) {
                    HStack(spacing: 3) {
                        Image(systemName: "internaldrive")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Palette.slateLight)
                        Text(Fmt.size(recorder.freeBytes) + " free")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.68))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }

                    if settings.cameraMode != .photo, plan.megabytesPerHour > 0 {
                        let hoursLeft = Double(max(0, recorder.freeBytes - 300_000_000)) / 1_000_000.0 / plan.megabytesPerHour
                        Text("·")
                            .foregroundColor(Palette.slateLight)
                            .font(.system(size: 11, weight: .bold))
                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Palette.slateLight)
                            Text("~" + Fmt.hours(hoursLeft))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.68))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }

                    if recorder.batteryPercent >= 0 {
                        Text("·")
                            .foregroundColor(Palette.slateLight)
                            .font(.system(size: 11, weight: .bold))
                        batteryIndicator
                    }

                    if recorder.thermalState != .nominal && recorder.thermalState != .fair {
                        Text("·")
                            .foregroundColor(Palette.slateLight)
                            .font(.system(size: 11, weight: .bold))
                        thermalIndicator
                    }
                }
                .lineLimit(1)
            }

            if recorder.isRecording && settings.recordAudio {
                audioLevelBar
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(minHeight: 36)
        .background(
            ZStack {
                // Single shared shape reused for both fills below so they can
                // never drift apart by even a fraction of a point at the corners.
                Palette.panel.opacity(0.84)
                // Flat fill on A10 — ultraThinMaterial is a live GPU blur.
                Palette.slateDeep.opacity(usesLightweightMaterial ? 0.55 : 0.25)
            }
        )
        // Clip to the ACTUAL rounded shape (not the bounding box) so the
        // material/fill never bleeds past the curve into a squared-off
        // sliver at the corners — this is what `.clipped()` was missing,
        // since it only clips to the rectangular frame.
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            settings.accentColor.bright.opacity(0.5),
                            Color.white.opacity(0.1),
                            settings.accentColor.color.opacity(0.22)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 4)
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

                if let limit = settings.maxDuration.seconds {
                    Text("/ " + Fmt.duration(limit))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.55))
                }

                if recorder.droppedFrames > 0 {
                    Text("\(recorder.droppedFrames)d")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(settings.accentColor.bright)
                }
            } else if recorder.isSaving {
                ProgressView().tint(settings.accentColor.bright).scaleEffect(0.7)
                Text("Saving…")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(settings.accentColor.bright)
            }
        }
        .foregroundColor(.white)
        .onAppear { blink = true }
        .onDisappear { blink = false }
    }

    private var batteryIndicator: some View {
        let pct = recorder.batteryPercent
        let color: Color = recorder.batteryCharging ? settings.accentColor.bright
            : pct <= 20 ? Palette.record
            : pct <= 40 ? settings.accentColor.bright
            : .white.opacity(0.8)
        return HStack(spacing: 3) {
            Image(systemName: recorder.batteryCharging ? "battery.100.bolt" : "battery.75")
                .font(.system(size: 10))
            Text("\(pct)%")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(color)
    }

    private var thermalIndicator: some View {
        let state = recorder.thermalState
        let color: Color = state == .critical ? Palette.record
            : state == .serious ? settings.accentColor.bright
            : .white.opacity(0.7)
        return HStack(spacing: 3) {
            Image(systemName: state.icon)
                .font(.system(size: 10))
            Text(state.shortLabel)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(color)
    }

    private var audioLevelBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule()
                    .fill(LinearGradient(colors: [settings.accentColor.deep, audioLevelColor], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(3, geo.size.width * CGFloat(recorder.audioLevel)))
                    .animation(.spring(response: 0.2, dampingFraction: 0.8), value: recorder.audioLevel)
            }
        }
        .frame(width: 80, height: 4)
    }

    private var audioLevelColor: Color {
        recorder.audioLevel > 0.85 ? Palette.record
            : recorder.audioLevel > 0.6 ? settings.accentColor.bright
            : settings.accentColor.color
    }

    // MARK: Pro Tools Menu

    private func proToolsSectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(settings.accentColor.color)
            Text(title.uppercased())
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.5))
                .tracking(0.6)
        }
    }

    private func proToolsChip(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: {
            if settings.hapticFeedbackEnabled { modeHaptic.selectionChanged() }
            action()
        }) {
            Text(label)
                .font(.system(size: 12, weight: selected ? .semibold : .medium, design: .rounded))
                .foregroundColor(selected ? Palette.slateDeep : .white.opacity(0.85))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(selected ? settings.accentColor.color : Palette.slateMid.opacity(0.6))
                )
        }
        .buttonStyle(.plain)
    }

    /// A single full-width settings-style row: icon, title, optional subtitle,
    /// and a trailing control. Rows sit inside one continuous card separated
    /// by hairline dividers, closer to how Settings itself lays things out
    /// rather than everything crammed into loose floating chips.
    private func proToolsRow<Trailing: View>(
        icon: String,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 30, height: 30)
                .background(Palette.slateMid)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.white.opacity(0.45))
                }
            }

            Spacer(minLength: 8)

            trailing()
        }
        .padding(.vertical, 4)
    }

    private var proToolsDrawer: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Compact header row
            HStack(spacing: 8) {
                Text("Shoot")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Spacer(minLength: 0)
                Button(action: {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) { showProMenu = false }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 26, height: 26)
                        .background(Palette.slateMid)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            // Timer chips + Level toggle on one dense row
            HStack(spacing: 8) {
                ForEach(CountdownTimer.allCases) { timer in
                    proToolsChip(label: timer.label, selected: settings.countdownTimer == timer) {
                        settings.countdownTimer = timer
                    }
                }
                Spacer(minLength: 6)
                Text("Level")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
                Toggle("", isOn: Binding(
                    get: { settings.showLevelGauge },
                    set: { newValue in
                        settings.showLevelGauge = newValue
                        recorder.refreshMotionUpdateRate()
                    }
                ))
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: settings.accentColor.color))
                .scaleEffect(0.85)
            }

            // Exposure compact
            HStack(spacing: 10) {
                Text(String(format: "%@%.1f", settings.exposureBias > 0 ? "+" : "", settings.exposureBias))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(settings.exposureBias == 0 ? .white.opacity(0.45) : .white)
                    .frame(width: 42, alignment: .leading)
                Slider(value: $settings.exposureBias, in: -2.0...2.0, step: 0.1)
                    .tint(settings.accentColor.color)
                    .onChange(of: settings.exposureBias) { val in
                        recorder.setExposureBias(val)
                    }
                if abs(settings.exposureBias) > 0.01 {
                    Button("0") {
                        settings.exposureBias = 0
                        recorder.setExposureBias(0)
                    }
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Palette.slateMid)
                    .clipShape(Capsule())
                    .buttonStyle(.plain)
                }
            }

            // White balance chips — single tight row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(WhiteBalancePreset.allCases) { preset in
                        proToolsChip(label: preset.label, selected: settings.whiteBalance == preset) {
                            settings.whiteBalance = preset
                            recorder.setWhiteBalance(preset)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Palette.slateDeep.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .compositingGroup()
        .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 4)
    }

    // MARK: Bottom HUD Bar (Live Zoom Always Visible)

    private var bottomHUD: some View {
        VStack(spacing: 8) {
            // Zoom preset row stays visible & interactive during recording
            zoomPresetRow
                .disabled(recorder.isSwitchingCamera || recorder.isSaving)
                .opacity((recorder.isSwitchingCamera || recorder.isSaving) ? 0.35 : 1)

            if !recorder.isRecording && !recorder.isSaving {
                modeSelector
                    .disabled(recorder.isSwitchingCamera)
                    .opacity(recorder.isSwitchingCamera ? 0.35 : 1)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            ZStack(alignment: .center) {
                // recordButton is centered via ZStack overlay so it stays perfectly
                // centered regardless of asymmetric content in the HStack row below.
                recordButton

                HStack(alignment: .center, spacing: 12) {
                    if !recorder.isRecording && !recorder.isSaving,
                       let thumb = recorder.lastClipThumbnail ?? recorder.lastPhotoThumbnail {
                        Button(action: { showGallery = true }) {
                            Image(uiImage: thumb)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 44, height: 44)
                                .clipShape(Facet(sides: 6, rotation: .pi / 6))
                                .overlay(Facet(sides: 6, rotation: .pi / 6).stroke(settings.accentColor.color.opacity(0.7), lineWidth: 1.5))
                                .shadow(color: .black.opacity(0.3), radius: 5)
                        }
                        .buttonStyle(.plain)
                    } else {
                        facetButton(system: "square.stack.3d.up.fill", size: 44) { showGallery = true }
                            .disabled(recorder.isRecording || recorder.isSaving)
                            .opacity((recorder.isRecording || recorder.isSaving) ? 0.35 : 1)
                    }

                    Spacer()

                    // "..." button positioned between shutter and flip-camera button
                    if !recorder.isRecording && !recorder.isSaving {
                        Button(action: {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                showProMenu.toggle()
                            }
                        }) {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(showProMenu ? settings.accentColor.bright : .white)
                                .frame(width: 36, height: 36)
                                .background(Palette.panel.opacity(0.85))
                                .environment(\.colorScheme, .dark)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Palette.slateLight.opacity(0.35), lineWidth: 0.8))
                                .shadow(color: .black.opacity(0.2), radius: 4)
                        }
                        .buttonStyle(.plain)
                        .disabled(recorder.isSwitchingCamera)
                        .opacity(recorder.isSwitchingCamera ? 0.35 : 1)
                    }

                    if recorder.isRecording {
                        facetButton(system: "moon.fill", size: 44) { enterDim() }
                    } else {
                        facetButton(system: "arrow.triangle.2.circlepath.camera.fill", size: 44) {
                            recorder.flipCamera()
                        }
                        .disabled(recorder.isSaving || recorder.isSwitchingCamera || recorder.isCapturingPhoto || countdownRemaining > 0)
                        .opacity((recorder.isSaving || recorder.isSwitchingCamera || recorder.isCapturingPhoto || countdownRemaining > 0) ? 0.35 : 1)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private var recordButton: some View {
        Button {
            guard !recorder.isSwitchingCamera, !isPinching, !recorder.isCapturingPhoto, !recorder.isSaving else { return }
            let now = Date()
            guard now.timeIntervalSince(lastRecordButtonTap) > 0.4 else { return }
            lastRecordButtonTap = now

            if settings.cameraMode == .photo {
                if countdownRemaining > 0 {
                    cancelCountdown()
                } else if settings.countdownTimer != .off {
                    startCountdown()
                } else {
                    triggerPhotoCapture()
                }
                return
            }

            if recorder.isRecording {
                if settings.hapticFeedbackEnabled {
                    stopHaptic.impactOccurred()
                    stopHaptic.prepare()
                }
                if dimmed { leaveDim() }
                recorder.toggleRecording()
            } else {
                if countdownRemaining > 0 {
                    cancelCountdown()
                } else if settings.countdownTimer != .off {
                    startCountdown()
                } else {
                    if settings.hapticFeedbackEnabled {
                        startHaptic.impactOccurred()
                        startHaptic.prepare()
                    }
                    recorder.toggleRecording()
                }
            }
        } label: {
            ZStack {
                // Soft outer glow
                Facet(sides: 12)
                    .fill(settings.accentColor.color.opacity(0.18))
                    .frame(width: 82, height: 82)
                    .blur(radius: 8)

                // Outer ring
                Facet(sides: 12)
                    .stroke(
                        LinearGradient(
                            colors: [settings.accentColor.bright, settings.accentColor.deep],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 3.5
                    )
                    .frame(width: 76, height: 76)
                    .shadow(color: settings.accentColor.color.opacity(0.45), radius: 10)

                // Inner track
                Facet(sides: 12)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1.5)
                    .frame(width: 66, height: 66)

                if recorder.isSaving || recorder.isCapturingPhoto {
                    ProgressView().tint(settings.accentColor.bright).scaleEffect(1.25)
                } else if recorder.isRecording {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Palette.record, Palette.record.opacity(0.82)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 30, height: 30)
                        .shadow(color: Palette.record.opacity(0.7), radius: 12)
                } else if countdownRemaining > 0 {
                    Image(systemName: "xmark")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Facet(sides: 12)
                        .fill(
                            LinearGradient(
                                colors: [Color.white, Color.white.opacity(0.9)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 54, height: 54)
                        .shadow(color: Color.white.opacity(0.4), radius: 6, x: 0, y: 2)
                        .overlay(
                            Facet(sides: 12)
                                .stroke(Color.black.opacity(0.06), lineWidth: 1)
                                .frame(width: 54, height: 54)
                        )
                }
            }
            .frame(width: 82, height: 82)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .disabled(recorder.isSaving || recorder.isSwitchingCamera || recorder.isCapturingPhoto)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: recorder.isRecording)
    }

    private var modeSelector: some View {
        let modes = CameraMode.allCases

        return HStack(spacing: 2) {
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
                        .font(.system(size: 13, weight: isActive ? .bold : .semibold, design: .rounded))
                        .foregroundColor(isActive ? Palette.slateDeep : .white.opacity(0.72))
                        // Fixed horizontal padding keeps the control the same
                        // width across modes so it never expands/clips at edges.
                        .frame(minWidth: 58)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            Group {
                                if isActive {
                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: [settings.accentColor.bright, settings.accentColor.color],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .shadow(color: settings.accentColor.color.opacity(0.4), radius: 4, y: 2)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            Capsule()
                .fill(Palette.panel.opacity(0.88))
                .background(Capsule().fill(Palette.slateDeep.opacity(usesLightweightMaterial ? 0.55 : 0.3)))
        )
        .overlay(
            Capsule()
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
        // Centered, never forced wider than content so it stays clear of screen edges.
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func facetButton(system: String,
                             size: CGFloat = 40,
                             tint: Color = .white,
                             hitSlop: CGFloat = 8,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: size, height: size)
                .background(
                    Facet(sides: 6, rotation: .pi / 6)
                        .fill(Palette.panel.opacity(0.88))
                        .background(
                            Facet(sides: 6, rotation: .pi / 6)
                                .fill(Palette.slateDeep.opacity(usesLightweightMaterial ? 0.55 : 0.3))
                        )
                )
                .overlay(
                    Facet(sides: 6, rotation: .pi / 6)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.22), Color.white.opacity(0.06)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 5)
        }
        .buttonStyle(.plain)
        // Negative inset grows the TAPPABLE area on every side without
        // changing the button's actual layout size — neighboring buttons don't shift.
        // hitSlop is per-caller so the most-reached-for buttons (flash, settings)
        // can get an even bigger invisible hit area than the default.
        .contentShape(Rectangle().inset(by: -hitSlop))
    }

    // MARK: Overlays (Level Meter & Countdown)

    private var levelGaugeOverlay: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let isLevel = recorder.isLevel

            ZStack {
                Circle()
                    .stroke(isLevel ? settings.accentColor.bright : Color.white.opacity(0.3), lineWidth: 1.5)
                    .frame(width: 12, height: 12)

                HStack(spacing: 24) {
                    Rectangle()
                        .fill(isLevel ? settings.accentColor.bright : Color.white.opacity(0.3))
                        .frame(width: 40, height: 1.5)

                    Spacer().frame(width: 12)

                    Rectangle()
                        .fill(isLevel ? settings.accentColor.bright : Color.white.opacity(0.3))
                        .frame(width: 40, height: 1.5)
                }
                .rotationEffect(.degrees(-recorder.rollAngle))
                .animation(.spring(response: 0.15, dampingFraction: 0.8), value: recorder.rollAngle)
            }
            .position(x: w / 2, y: h / 2)
            .shadow(color: isLevel ? settings.accentColor.color.opacity(0.6) : .clear, radius: 4)
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
                    .foregroundColor(settings.accentColor.bright)
                    .shadow(color: settings.accentColor.color.opacity(0.6), radius: 20)
                    .scaleEffect(1.1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: countdownRemaining)

                Text("Tap shutter to cancel")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Photo capture (routes selfie flash through screen illumination)

    private func triggerPhotoCapture() {
        if recorder.isFrontCamera && recorder.frontFlashEnabled {
            performFrontFlashCapture()
        } else {
            recorder.capturePhoto()
        }
    }

    private func performFrontFlashCapture() {
        frontFlashSavedBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = 1.0
        screenFlashIlluminating = true

        // Restore brightness only after the sensor actually fires
        // (onWillCapturePhoto), not on a fixed timer after capturePhoto() —
        // on A10 the capture can land later than 0.12s and underexpose.
        let previousHook = recorder.onWillCapturePhoto
        recorder.onWillCapturePhoto = {
            previousHook?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                screenFlashIlluminating = false
                UIScreen.main.brightness = frontFlashSavedBrightness
                recorder.onWillCapturePhoto = previousHook
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            recorder.capturePhoto()
            // Safety: if willCapture never fires, still restore after 2s.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if screenFlashIlluminating {
                    screenFlashIlluminating = false
                    UIScreen.main.brightness = frontFlashSavedBrightness
                    recorder.onWillCapturePhoto = previousHook
                }
            }
        }
    }

    private func startCountdown() {
        countdownRemaining = settings.countdownTimer.rawValue
        let haptic = UIImpactFeedbackGenerator(style: .heavy)
        haptic.prepare()

        countdownTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            haptic.impactOccurred()
            if countdownRemaining > 1 {
                countdownRemaining -= 1
            } else {
                countdownTimer?.invalidate()
                countdownTimer = nil
                countdownRemaining = 0
                guard !recorder.isSwitchingCamera, !recorder.isSaving else { return }
                if settings.cameraMode == .photo {
                    triggerPhotoCapture()
                } else {
                    startHaptic.impactOccurred()
                    recorder.startRecording()
                }
            }
        }
        // Common modes so the countdown keeps ticking during scroll/drag.
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownRemaining = 0
    }

    private func noticeBar(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(settings.accentColor.bright)

            Text(text)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.95))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(
            Capsule()
                .fill(Palette.panel.opacity(0.9))
                .background(Capsule().fill(Palette.slateDeep.opacity(usesLightweightMaterial ? 0.55 : 0.3)))
        )
        .overlay(
            Capsule()
                .stroke(settings.accentColor.bright.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 5)
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                recorder.notice = nil
            }
        }
    }

    private var permissionMessage: some View {
        VStack(spacing: 18) {
            ZStack {
                Facet(sides: 6, rotation: .pi / 6)
                    .fill(settings.accentColor.color.opacity(0.2))
                    .frame(width: 80, height: 80)
                Image(systemName: "camera.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(settings.accentColor.bright)
            }
            .shadow(color: settings.accentColor.color.opacity(0.4), radius: 16)

            Text("Camera access is off")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text("Turn it on in Settings › LowPolyCam.")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundColor(Palette.slateDeep)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [settings.accentColor.bright, settings.accentColor.color],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .shadow(color: settings.accentColor.color.opacity(0.4), radius: 8, y: 3)
            .padding(.top, 6)
        }
        .foregroundColor(.white)
        .padding(36)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Palette.panel.opacity(0.92))
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Palette.slateDeep.opacity(usesLightweightMaterial ? 0.55 : 0.3))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 28, x: 0, y: 14)
    }

    // MARK: Zoom & Focus

    private var gridOverlay: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Path { path in
                switch settings.gridStyle {
                case .off:
                    break
                case .thirds:
                    for i in 1...2 {
                        let x = w * CGFloat(i) / 3
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: h))
                        let y = h * CGFloat(i) / 3
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: w, y: y))
                    }
                case .crosshair:
                    path.move(to: CGPoint(x: w / 2, y: 0))
                    path.addLine(to: CGPoint(x: w / 2, y: h))
                    path.move(to: CGPoint(x: 0, y: h / 2))
                    path.addLine(to: CGPoint(x: w, y: h / 2))
                case .square:
                    let side = min(w, h) * 0.72
                    let rect = CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
                    path.addRect(rect)
                    // center cross ticks
                    let tick: CGFloat = 12
                    path.move(to: CGPoint(x: w / 2 - tick, y: h / 2))
                    path.addLine(to: CGPoint(x: w / 2 + tick, y: h / 2))
                    path.move(to: CGPoint(x: w / 2, y: h / 2 - tick))
                    path.addLine(to: CGPoint(x: w / 2, y: h / 2 + tick))
                }
            }
            .stroke(Color.white.opacity(0.28), lineWidth: 0.7)
        }
        .allowsHitTesting(false)
    }

    private var zoomPresets: [CGFloat] {
        var options: [CGFloat] = []
        if recorder.minZoomFactor <= 0.6 { options.append(0.5) }
        options.append(1)
        if recorder.maxZoomFactor >= 1.9 { options.append(2) }
        if recorder.maxZoomFactor >= 4.9 { options.append(5) }
        return options
    }

    private func zoomLabel(for preset: CGFloat) -> String {
        if preset == preset.rounded() {
            return "\(Int(preset))x"
        }
        return String(format: "%.1fx", preset)
    }

    private var zoomPresetRow: some View {
        HStack(spacing: 6) {
            ForEach(zoomPresets, id: \.self) { preset in
                let isSelected = abs(recorder.zoomFactor - preset) < 0.05
                Button(action: {
                    zoomHaptic.selectionChanged()
                    if settings.shutterSoundEnabled { SoundPlayer.play(.dial) }
                    recorder.suppressVolumeTriggerBriefly()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        recorder.setZoom(factor: preset)
                    }
                    showZoomLabel = true
                    scheduleHideZoomLabel()
                }) {
                    Text(zoomLabel(for: preset))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundColor(isSelected ? Palette.slateDeep : .white.opacity(0.85))
                        .frame(width: 36, height: 36)
                        .background(
                            Group {
                                if isSelected {
                                    Circle()
                                        .fill(
                                            LinearGradient(
                                                colors: [settings.accentColor.bright, settings.accentColor.color],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .shadow(color: settings.accentColor.color.opacity(0.45), radius: 6)
                                } else {
                                    Circle()
                                        .fill(Palette.slateMid.opacity(0.65))
                                }
                            }
                        )
                        .overlay(
                            Circle()
                                .stroke(isSelected ? Color.clear : Color.white.opacity(0.12), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelected)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Palette.panel.opacity(0.88))
                .background(Capsule().fill(Palette.slateDeep.opacity(usesLightweightMaterial ? 0.55 : 0.3)))
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        // Keep the control centered without forcing full-bleed width that can
        // push neighboring bottom-HUD elements toward the screen edges.
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var zoomLabel: some View {
        Text(String(format: "%.1fx", recorder.zoomFactor))
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Palette.panel.opacity(0.9))
                    .background(Capsule().fill(Palette.slateDeep.opacity(usesLightweightMaterial ? 0.55 : 0.3)))
            )
            .overlay(
                Capsule()
                    .stroke(settings.accentColor.bright.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 4)
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
        ZStack {
            // Thin square outline — classic camera-app focus box, not a hexagon.
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(settings.accentColor.bright, lineWidth: 1.2)
                .frame(width: 64, height: 64)

            // Small corner tick marks for that "locking on" feel.
            ForEach(0..<4) { i in
                Rectangle()
                    .fill(settings.accentColor.bright)
                    .frame(width: 8, height: 2)
                    .offset(x: (i % 2 == 0 ? -1 : 1) * 28, y: (i < 2 ? -1 : 1) * 32)
            }

            // Small center dot to mark the exact focus point.
            Circle()
                .fill(settings.accentColor.bright)
                .frame(width: 4, height: 4)
        }
        .shadow(color: settings.accentColor.color.opacity(0.5), radius: 4)
        .scaleEffect(focusPoint == nil ? 1.3 : 1.0)
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
        guard !dimmed else { return }
        if UIScreen.main.brightness > 0.05 {
            savedBrightness = UIScreen.main.brightness
        }
        UIScreen.main.brightness = 0
        withAnimation(.easeIn(duration: 0.3)) { dimmed = true }
    }

    private func leaveDim() {
        guard dimmed else { return }
        let target = savedBrightness > 0.05 ? savedBrightness : 0.5
        UIScreen.main.brightness = target
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
                    ProgressView().tint(Palette.violet.opacity(0.95)).scaleEffect(1.2)
                }
            }
            .navigationBarTitle("Preview", displayMode: .inline)
            .navigationBarItems(trailing: Button("Done") {
                player?.pause()
                presentation.wrappedValue.dismiss()
            })
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(Palette.violet)
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
