//
//  CameraScreen.swift
//  LowPolyCam
//
//  Updated for iOS 27 / Xcode 27 / Swift 6.4.
//  Swift 6 complete concurrency · Observation · Liquid Glass · RotationCoordinator
//

import SwiftUI
import UIKit
import AVKit

struct CameraScreen: View {

    @ObservedObject var settings: AppSettings
    @ObservedObject var recorder: CameraRecorder

    @State private var showSettings = false
    @State private var showPlayer = false
    @State private var showProMenu = false
    @State private var showWhiteBalanceSheet = false
    @State private var showGallery = false
    @State private var showPhotoReview = false
    @State private var reviewedPhotoReviewToken = 0
    @State private var dimmed = false
    @State private var savedBrightness: CGFloat = UIScreen.main.brightness
    @State private var blink = false

    // Countdown State
    @State private var countdownRemaining = 0
    @State private var countdownTimer: Timer?

    // Zoom
    @State private var zoomGestureBase: CGFloat = 1
    @State private var isPinching = false
    // True while the user's finger is down on the 1x zoom dial dragging it
    // left/right — separate from `isPinching` (two-finger pinch on the
    // preview) so the two gestures never fight over `zoomGestureBase`.
    @State private var isZoomDialDragging = false
    @State private var lastRecordButtonTap = Date.distantPast

    // Tap to focus
    @State private var focusPoint: CGPoint?
    @State private var focusHideToken = 0
    /// True while the reticle shown at `focusPoint` is for a tap-and-hold
    /// lock rather than a plain focus/expose tap — drawn in a different
    /// color so the two moments are visually distinct.
    @State private var focusReticleIsLock = false
    /// True for the brief "just landed, still oversized" instant right
    /// after a tap; flips false a beat later to trigger the converge-in
    /// spring. Separate from `focusPoint` so the pop + settle can be its
    /// own two-stage motion instead of one flat fade/scale.
    @State private var focusReticleExpanded = true
    /// Drives the slow breathing pulse shown only while a tap-and-hold
    /// lock is active on screen, so a lock visibly reads as "still on"
    /// rather than a static box.
    @State private var focusReticlePulsing = false

    // Notice Auto-Dismiss
    @State private var noticeHideToken = 0

    // Capture flash confirmation
    @State private var showCaptureFlash = false
    /// A short, opaque-enough cover hides AVFoundation's format switch from
    /// the viewfinder instead of exposing a frozen or black frame.
    @State private var modeTransitionOpacity: Double = 0
    @State private var modeTransitionLabel = ""
    // Sustained screen-illumination for the selfie "flash" — separate from
    // showCaptureFlash above, which is just the brief post-shutter blink.
    @State private var screenFlashIlluminating = false
    @State private var frontFlashSavedBrightness: CGFloat = UIScreen.main.brightness

    @State private var startHaptic = UIImpactFeedbackGenerator(style: .medium)
    @State private var stopHaptic = UIImpactFeedbackGenerator(style: .light)
    @State private var levelHaptic = UISelectionFeedbackGenerator()
    // Reused instead of created per-render (see zoomControl/modeSelector) —
    // allocating + preparing a new UIFeedbackGenerator on every SwiftUI body
    // re-evaluation is wasted work that adds up on slower A10-class devices.
    @State private var zoomHaptic = UISelectionFeedbackGenerator()
    @State private var modeHaptic = UISelectionFeedbackGenerator()

    private var plan: EncodePlan { Encoder.plan(for: settings) }

    /// Rebuilds the prepared impact-haptic generators at the user's chosen
    /// intensity. `UIImpactFeedbackGenerator`'s style is fixed at init, so
    /// changing intensity means swapping the generator instance rather than
    /// mutating one in place.
    private func applyHapticIntensity() {
        startHaptic = UIImpactFeedbackGenerator(style: settings.hapticIntensity.scaled(.medium))
        stopHaptic = UIImpactFeedbackGenerator(style: settings.hapticIntensity.scaled(.light))
        startHaptic.prepare()
        stopHaptic.prepare()
    }

    var body: some View {
        cameraRootView
            .statusBar(hidden: true)
            .tint(settings.accentColor.color)
            .onAppear(perform: handleAppear)
            .onDisappear(perform: handleDisappear)
            .onChange(of: settings.hapticIntensity) { _, _ in
                applyHapticIntensity()
            }
            .onChange(of: recorder.isLevel) { _, isLevel in
                if isLevel && settings.showLevelGauge && settings.hapticFeedbackEnabled {
                    levelHaptic.selectionChanged()
                }
            }
            .onChange(of: recorder.isRecording) { _, isRecording in
                if !isRecording && dimmed {
                    leaveDim()
                }
            }
            .onChange(of: recorder.elapsed) { _, sec in
                let delay = PerformanceProfile.current(settings: settings).autoDimDelaySeconds
                if settings.autoDimOnRecord && recorder.isRecording && !dimmed && sec >= delay {
                    enterDim()
                }
            }
            .onChange(of: recorder.notice) { _, newNotice in
                handleNoticeChange(newNotice)
            }
            .onChange(of: showSettings) { _, isPresented in
                if isPresented {
                    recorder.pausePreviewSession()
                } else {
                    recorder.resumePreviewSession()
                }
            }
            .onChange(of: showPlayer) { _, isPresented in
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
                PhotoLibraryScreen()
            }
            .sheet(isPresented: $showPhotoReview) {
                PhotoReviewScreen(
                    settings: settings,
                    item: recorder.lastPhotoReviewItem,
                    burstItems: recorder.lastBurstReviewItems
                )
            }
            .onChange(of: recorder.photoReviewToken) { _, token in
                guard settings.photoReviewAfterCapture, token != reviewedPhotoReviewToken else { return }
                reviewedPhotoReviewToken = token
                showPhotoReview = true
            }
    }

    private var cameraRootView: some View {
        ZStack {
            cameraPreviewLayer

            if recorder.permissionDenied {
                permissionMessage
            } else {
                cameraHUDLayer
            }
        }
    }

    private var cameraPreviewLayer: some View {
        ZStack {
            Color.black

            CameraPreview(session: recorder.session, onTap: { [weak recorder] devicePoint, viewPoint in
                if showProMenu {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showProMenu = false }
                }
                recorder?.focusAndExpose(at: devicePoint)
                showFocusReticle(at: viewPoint, locked: false)
            }, onDoubleTap: { [weak recorder] in
                recorder?.flipCamera()
            }, onLongPress: { [weak recorder] devicePoint, viewPoint in
                guard let recorder else { return }
                if settings.hapticFeedbackEnabled { zoomHaptic.selectionChanged() }
                recorder.lockFocus(at: devicePoint)
                showFocusReticle(at: viewPoint, locked: true)
            }, onTwoFingerLongPress: { [weak recorder] devicePoint, viewPoint in
                guard let recorder else { return }
                if settings.hapticFeedbackEnabled { zoomHaptic.selectionChanged() }
                recorder.lockExposure(at: devicePoint)
                showFocusReticle(at: viewPoint, locked: true)
            })
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        if !isPinching {
                            isPinching = true
                            zoomGestureBase = recorder.zoomFactor
                        }
                        recorder.suppressVolumeTriggerBriefly()
                        recorder.setZoom(factor: zoomGestureBase * value)
                    }
                    .onEnded { _ in
                        isPinching = false
                        recorder.suppressVolumeTriggerBriefly()
                    }
            )

            if let focusPoint {
                focusReticle.position(focusPoint)
            }

            if settings.gridStyle != .off { gridOverlay }
            if settings.showLevelGauge { levelGaugeOverlay }
            if countdownRemaining > 0 { countdownOverlay }

            Color.black
                .opacity(recorder.isSwitchingCamera ? 1 : 0)
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.18), value: recorder.isSwitchingCamera)

            Color.black
                .opacity(modeTransitionOpacity)
                .allowsHitTesting(false)
                .overlay(
                    Group {
                        if recorder.isSwitchingMode {
                            Text(modeTransitionLabel)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(.white.opacity(0.9))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Palette.slateDeep.opacity(0.8)))
                        }
                    }
                )

            Color.white
                .opacity(showCaptureFlash ? 0.85 : 0)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.18), value: showCaptureFlash)

            Color.white
                .opacity(screenFlashIlluminating ? 1 : 0)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.15), value: screenFlashIlluminating)

            if dimmed { dimOverlay }
        }
        .ignoresSafeArea()
    }

    private var cameraHUDLayer: some View {
        ZStack {
            VStack(spacing: 0) {
                topHUD

                if recorder.focusLocked || recorder.exposureLocked {
                    focusExposureLockBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 8)
                }

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

            if showProMenu && !recorder.isRecording && !recorder.isSaving {
                Color.black.opacity(0.4)
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
                        .padding(.horizontal, 14)
                        .padding(.bottom, 40)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(20)
                .allowsHitTesting(true)
            }
        }
    }

    private func handleAppear() {
        recorder.start()
        applyHapticIntensity()
        startHaptic.prepare()
        stopHaptic.prepare()
        levelHaptic.prepare()
        zoomHaptic.prepare()
        modeHaptic.prepare()
        recorder.onWillCapturePhoto = {
            guard settings.captureFlashConfirmation, recorder.isFrontCamera else { return }
            showCaptureFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                showCaptureFlash = false
            }
        }
    }

    private func handleDisappear() {
        if dimmed { leaveDim() }
        recorder.stop()
        countdownTimer?.invalidate()
    }

    private func handleNoticeChange(_ newNotice: String?) {
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

    // MARK: Top HUD Bar

    // Extra tap-target padding for the two most-used top-HUD buttons (flash,
    // settings). Kept as a shared constant so both stay in sync instead of
    // drifting to different inset values.
    private let topHUDHitSlop: CGFloat = 18

    private var topHUD: some View {
        HStack(alignment: .center, spacing: 8) {
            Group {
                if settings.hudShowFlashButton, recorder.hasTorch {
                    facetButton(system: recorder.torchOn ? "bolt.fill" : "bolt.slash.fill",
                                size: 40,
                                tint: recorder.torchOn ? settings.accentColor.bright : .white,
                                hitSlop: topHUDHitSlop) {
                        recorder.toggleTorch()
                    }
                    .transition(settings.hudMotion.transition)
                } else if settings.hudShowFlashButton, recorder.isFrontCamera {
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
                    .transition(settings.hudMotion.transition)
                } else {
                    // Keep layout balanced whether hidden by the HUD setting
                    // or genuinely unavailable on this lens.
                    Color.clear.frame(width: 40, height: 40)
                }
            }

            Spacer(minLength: 4)

            Group {
                if settings.hudShowInfoPill {
                    compactInfoPill
                        // Let the actual safe-area width distribute space. This
                        // stays centered on iPhone 11/Pro/Max instead of using a
                        // process-wide UIScreen measurement.
                        .frame(maxWidth: .infinity)
                        .layoutPriority(1)
                        .transition(settings.hudMotion.transition)
                }
            }

            Spacer(minLength: 4)

            // Always visible — hiding the way back into Settings would
            // strand anyone who hides other HUD elements from here.
            facetButton(system: "gearshape.fill", size: 40, hitSlop: topHUDHitSlop) { showSettings = true }
                .disabled(recorder.isRecording || recorder.isSaving || recorder.isSwitchingCamera || recorder.isBursting)
                .opacity((recorder.isRecording || recorder.isSaving || recorder.isSwitchingCamera || recorder.isBursting) ? 0.35 : 1)
        }
        .animation(settings.hudMotion.animation, value: settings.hudShowFlashButton)
        .animation(settings.hudMotion.animation, value: settings.hudShowInfoPill)
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

    /// Whether the pill's "~X h/min left" estimate should render this frame
    /// — its own toggle, storage-derived data available, and not Photo mode
    /// (a photo count estimate would need a different formula entirely).
    private var showsTimeRemainingInPill: Bool {
        settings.hudShowTimeRemaining && settings.cameraMode != .photo && plan.megabytesPerHour > 0
    }

    private var compactInfoPill: some View {
        // Precomputed once per render so the separator dots between pill
        // segments below can each ask "did anything before me render?"
        // without repeating these conditions inline.
        let showStorage = settings.hudShowStorageInfo
        let showTimeRemaining = showsTimeRemainingInPill
        let showBattery = settings.hudShowBatteryInfo && recorder.batteryPercent >= 0
        let showThermal = recorder.thermalState != .nominal && recorder.thermalState != .fair

        return VStack(spacing: 3) {
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

                        if settings.hudShowMegapixels {
                            Text(settings.photoMegapixels.label)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(.white.opacity(0.92))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }

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

                        let sensorFPS = recorder.activeSensorFPS >= 100
                            ? Int(recorder.activeSensorFPS.rounded())
                            : settings.slowMoFrameRate.value
                        Text("\(sensorFPS) fps")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(abs(Double(sensorFPS - settings.slowMoFrameRate.value)) <= 1
                                             ? .white : Palette.warning)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    } else {
                        Text("VIDEO")
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

                        Text("\(settings.resolution.label) · \(settings.frameRate.label)")
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
                    if showStorage {
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
                    }

                    if showTimeRemaining {
                        let hoursLeft = Double(max(0, recorder.freeBytes - 300_000_000)) / 1_000_000.0 / plan.megabytesPerHour
                        if showStorage {
                            Text("·")
                                .foregroundColor(Palette.slateLight)
                                .font(.system(size: 11, weight: .bold))
                        }
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

                    if showBattery {
                        if showStorage || showTimeRemaining {
                            Text("·")
                                .foregroundColor(Palette.slateLight)
                                .font(.system(size: 11, weight: .bold))
                        }
                        batteryIndicator
                    }

                    if showThermal {
                        if showStorage || showTimeRemaining || showBattery {
                            Text("·")
                                .foregroundColor(Palette.slateLight)
                                .font(.system(size: 11, weight: .bold))
                        }
                        thermalIndicator
                    }
                }
                .lineLimit(1)
                .animation(settings.hudMotion.animation, value: settings.hudShowStorageInfo)
                .animation(settings.hudMotion.animation, value: settings.hudShowBatteryInfo)
                .animation(settings.hudMotion.animation, value: settings.hudShowTimeRemaining)
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
        VStack(alignment: .leading, spacing: 3) {
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
                        .fixedSize()
                    Text(Fmt.duration(recorder.elapsed))
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .fixedSize()

                    if let limit = settings.maxDuration.seconds {
                        Text("/ " + Fmt.duration(limit))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.55))
                            .fixedSize()
                    }

                    // Battery while filming — same indicator as idle HUD.
                    if settings.hudShowBatteryInfo {
                        Text("·")
                            .foregroundColor(Palette.slateLight)
                            .font(.system(size: 11, weight: .bold))
                            .fixedSize()
                        batteryIndicator
                    }

                    if recorder.droppedFrames > 0 {
                        Text("\(recorder.droppedFrames)d")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(settings.accentColor.bright)
                            .fixedSize()
                    }
                } else if recorder.isSaving {
                    ProgressView().tint(settings.accentColor.bright).scaleEffect(0.7)
                    Text("Saving…")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(settings.accentColor.bright)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.72)

            // 📊 Opt-in live stats (measured fps / bitrate) — Settings toggle,
            // off by default. Kept on its OWN row under REC/timer/battery
            // instead of tacked onto that line — cramming it in-line was
            // forcing the whole pill wider than its screen-edge cap, which
            // squeezed the flash/settings icons off to the side. A second
            // row grows the pill down instead of sideways, matching how the
            // idle-state pill already stacks its two info rows.
            if recorder.isRecording && (settings.showRecordingStats || showsTimeRemainingInPill) {
                HStack(spacing: 5) {
                    if settings.showRecordingStats {
                        HStack(spacing: 3) {
                            Image(systemName: "speedometer")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Palette.slateLight)
                            Text(recorder.recordingStats.measuredFPSLabel)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.68))
                        }
                        Text("·")
                            .foregroundColor(Palette.slateLight)
                            .font(.system(size: 11, weight: .bold))
                        HStack(spacing: 3) {
                            Image(systemName: "waveform")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Palette.slateLight)
                            // Real on-disk bitrate is unavailable for the first
                            // few seconds of every clip (AVAssetWriter only
                            // flushes bytes at each movie-fragment boundary), so
                            // fall back to the configured target bitrate instead
                            // of showing a bare "--" the whole time.
                            Text(recorder.recordingStats.currentBitrateBps > 0
                                 ? recorder.recordingStats.currentBitrateLabel
                                 : RecordingStatsSnapshot.formatBitrate(Double(plan.videoBitrate)) + "*")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.68))
                        }
                    }

                    // "~X h/min left" — was only ever built in the idle
                    // (non-recording) branch above, so it vanished the
                    // instant recording started even though the HUD toggle
                    // for it was on. Same formula, same look, just also
                    // rendered while recorder.isRecording is true.
                    if showsTimeRemainingInPill {
                        if settings.showRecordingStats {
                            Text("·")
                                .foregroundColor(Palette.slateLight)
                                .font(.system(size: 11, weight: .bold))
                        }
                        let hoursLeft = Double(max(0, recorder.freeBytes - 300_000_000)) / 1_000_000.0 / plan.megabytesPerHour
                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Palette.slateLight)
                            Text("~" + Fmt.hours(hoursLeft))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.68))
                        }
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
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
    //
    // The drawer body below only handles the header + card chrome. The
    // actual controls (Timer, Level meter, Exposure, White balance, ...)
    // are described as data in `proToolsDrawerControls` and rendered by
    // `ProToolsControlList` (see ProToolsControls.swift). To add a new
    // Pro Tools control, add one entry to `proToolsDrawerControls` — no
    // new hand-built VStack/HStack block needed.

    /// The list of controls shown in the Pro Tools ("Shoot") drawer, in
    /// display order. This is the single place to touch when adding,
    /// removing, or reordering a Pro Tools control.
    private var proToolsDrawerControls: [ProToolControl] {
        let controls: [ProToolControl] = [
            .chips(ProToolControl.ChipsSpec(
                id: "timer",
                icon: "timer",
                title: "Timer",
                items: CountdownTimer.allCases.map { timer in
                    ProToolControl.ChipsSpec.Item(
                        id: timer.label,
                        label: timer.label,
                        selected: settings.countdownTimer == timer,
                        action: { settings.countdownTimer = timer }
                    )
                }
            )),
            .toggle(ProToolControl.ToggleSpec(
                id: "levelMeter",
                icon: "gyroscope",
                title: "Level meter",
                isOn: $settings.showLevelGauge,
                onChange: { _ in recorder.refreshMotionUpdateRate() }
            )),
            .slider(ProToolControl.SliderSpec(
                id: "exposure",
                icon: "plusminus.circle.fill",
                title: "Exposure",
                value: $settings.exposureBias,
                range: -2.0...2.0,
                step: 0.1,
                valueLabel: { String(format: "%@%.1f EV", $0 > 0 ? "+" : "", $0) },
                onChange: { recorder.setExposureBias($0) },
                defaultValue: 0
            )),
            .navigation(ProToolControl.NavigationSpec(
                id: "whiteBalance",
                icon: settings.whiteBalance.icon,
                title: "White balance",
                valueLabel: settings.whiteBalance.label,
                action: {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        showWhiteBalanceSheet = true
                    }
                }
            ))
        ]
        return controls
    }

    private var proToolsDrawer: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(settings.accentColor.color)
                    Text("Pro Tools")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                Spacer()
                Button(action: {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) { showProMenu = false }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 22, height: 22)
                        .background(Palette.slateMid)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 2)

            // No ScrollView: with the zoom-presets row gone, the remaining
            // controls (Timer, Level meter, Exposure, White balance) fit
            // without scrolling even on iPhone 7's 667pt-tall screen, and
            // the drawer's own compact row spacing (see ProToolsControls.swift)
            // keeps it that way as a hard requirement, not just today's fit.
            ProToolsControlList(
                controls: proToolsDrawerControls,
                accentColor: settings.accentColor.color,
                hapticsEnabled: settings.hapticFeedbackEnabled
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Palette.slateDeep.opacity(0.97))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .compositingGroup()
        .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 4)
        .sheet(isPresented: $showWhiteBalanceSheet) {
            whiteBalanceSheet
        }
    }

    // MARK: White Balance sheet
    //
    // Same "icon badge + title + subtitle + chevron" list pattern as Quick
    // Presets in SettingsScreen.swift, so picking a white balance preset
    // feels like the rest of the app instead of a one-off row of chips.
    private var whiteBalanceSheet: some View {
        NavigationView {
            List {
                ForEach(WhiteBalancePreset.allCases) { preset in
                    Button(action: {
                        settings.whiteBalance = preset
                        recorder.setWhiteBalance(preset)
                        showWhiteBalanceSheet = false
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: preset.icon)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 30, height: 30)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(settings.accentColor.color)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.label)
                                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                                    .foregroundColor(.primary)
                                Text(preset.detail)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if settings.whiteBalance == preset {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(settings.accentColor.color)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("White Balance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { showWhiteBalanceSheet = false }
                }
            }
        }
        .tint(settings.accentColor.color)
        .presentationDetents([.height(410)])
        .presentationDragIndicator(.visible)
    }

    // MARK: Bottom HUD Bar (Live Zoom Always Visible)

    private var bottomHUD: some View {
        VStack(spacing: 8) {
            // Full-width drag pad (not a small button) so zooming never
            // requires precisely tapping a tiny target — see zoomControl.
            // Hiding this only removes the visible bar; pinch-to-zoom on
            // the preview keeps working regardless.
            if settings.hudShowZoomControl {
                zoomControl
                    .disabled(recorder.isSwitchingCamera || recorder.isSaving)
                    .opacity((recorder.isSwitchingCamera || recorder.isSaving) ? 0.35 : 1)
                    .transition(settings.hudMotion.transition)
            }

            if settings.hudShowModeSelector, !recorder.isRecording && !recorder.isSaving {
                modeSelector
                    .disabled(recorder.isSwitchingCamera || recorder.isBursting)
                    .opacity((recorder.isSwitchingCamera || recorder.isBursting) ? 0.35 : 1)
                    .frame(maxWidth: .infinity, alignment: .center)
                    // Sit a bit lower above the shutter (same size/design).
                    .padding(.top, 6)
                    .transition(settings.hudMotion.transition)
            }

            ZStack(alignment: .center) {
                // recordButton is centered via ZStack overlay so it stays perfectly
                // centered regardless of asymmetric content in the HStack row below.
                recordButton

                HStack(alignment: .center, spacing: 12) {
                    if settings.hudShowGalleryThumbnail {
                        Group {
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
                                // Same invisible hit-area expansion as the other HUD
                                // icons (see facetButton's hitSlop) — the thumbnail's
                                // visible size stays 44x44, only the tappable area grows.
                                .contentShape(Rectangle().inset(by: -8))
                            } else {
                                facetButton(system: "square.stack.3d.up.fill", size: 44) { showGallery = true }
                                    .disabled(recorder.isRecording || recorder.isSaving)
                                    .opacity((recorder.isRecording || recorder.isSaving) ? 0.35 : 1)
                            }
                        }
                        .transition(settings.hudMotion.transition)
                    }

                    Spacer()

                    // "..." button positioned between shutter and flip-camera button
                    if settings.hudShowProToolsButton, !recorder.isRecording && !recorder.isSaving {
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
                        .transition(settings.hudMotion.transition)
                    }

                    if recorder.isRecording {
                        // The dim/moon button is a recording control, not a
                        // hideable HUD element — always shown while filming.
                        facetButton(system: "moon.fill", size: 44) { enterDim() }
                    } else if settings.hudShowFlipCameraButton {
                        facetButton(system: "arrow.triangle.2.circlepath.camera.fill", size: 44) {
                            recorder.flipCamera()
                        }
                        .disabled(recorder.isSaving || recorder.isSwitchingCamera || recorder.isCapturingPhoto || recorder.isBursting || countdownRemaining > 0)
                        .opacity((recorder.isSaving || recorder.isSwitchingCamera || recorder.isCapturingPhoto || recorder.isBursting || countdownRemaining > 0) ? 0.35 : 1)
                        .transition(settings.hudMotion.transition)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .animation(settings.hudMotion.animation, value: settings.hudShowZoomControl)
        .animation(settings.hudMotion.animation, value: settings.hudShowModeSelector)
        .animation(settings.hudMotion.animation, value: settings.hudShowGalleryThumbnail)
        .animation(settings.hudMotion.animation, value: settings.hudShowProToolsButton)
        .animation(settings.hudMotion.animation, value: settings.hudShowFlipCameraButton)
    }

    private func handleShutterTap() {
        guard !recorder.isSwitchingCamera, !isPinching, !recorder.isCapturingPhoto, !recorder.isSaving else { return }
        let now = Date()
        guard now.timeIntervalSince(lastRecordButtonTap) > 0.4 else { return }
        lastRecordButtonTap = now

        if settings.cameraMode == .photo {
            if recorder.isBursting {
                recorder.cancelBurstCapture()
                return
            }
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
    }

    /// Photo-mode press-and-hold → burst mode. Only armed in Photo mode,
    /// outside a countdown, with nothing else already in flight — a plain
    /// tap still falls through to `handleShutterTap()` via the Button below,
    /// so short presses behave exactly as before and nothing shifts.
    private func handleShutterLongPress() {
        guard settings.cameraMode == .photo,
              countdownRemaining == 0,
              !recorder.isBursting,
              !recorder.isCapturingPhoto,
              !recorder.isSaving,
              !recorder.isSwitchingCamera else { return }
        if settings.hapticFeedbackEnabled {
            startHaptic.impactOccurred()
            startHaptic.prepare()
        }
        recorder.startBurstCapture()
    }

    private var recordButton: some View {
        Button(action: handleShutterTap) {
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

                // Burst-mode progress ring — fills in as frames are captured,
                // drawn just inside the outer ring so it never changes the
                // button's footprint or nudges neighboring HUD icons.
                if recorder.isBursting && recorder.burstShotsTotal > 0 {
                    Circle()
                        .trim(from: 0, to: CGFloat(recorder.burstShotsTaken) / CGFloat(recorder.burstShotsTotal))
                        .stroke(Palette.record, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .frame(width: 76, height: 76)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.1), value: recorder.burstShotsTaken)
                }

                // Inner track
                Facet(sides: 12)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1.5)
                    .frame(width: 66, height: 66)

                if recorder.isBursting {
                    // Burst counter takes over the center glyph while firing —
                    // same visual weight/position as the other center states
                    // below, so the button never appears to resize.
                    Text("\(recorder.burstShotsTaken)/\(recorder.burstShotsTotal)")
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Palette.record.opacity(0.85)))
                } else if recorder.isSaving || recorder.isCapturingPhoto {
                    // At 120/240fps finishWriting has a lot more to flush than at
                    // 30/60fps (no movie fragments at 240fps, far more frames
                    // encoded), so this spinner can sit here for a couple of
                    // seconds on a long slow-mo clip. A bare spinner in that case
                    // reads as the app being stuck — the ring animation makes it
                    // clear something is still actively happening.
                    ProgressView().tint(settings.accentColor.bright).scaleEffect(1.25)
                        .overlay(
                            Circle()
                                .stroke(settings.accentColor.bright.opacity(0.35), lineWidth: 2)
                                .frame(width: 60, height: 60)
                                .rotationEffect(.degrees(blink ? 360 : 0))
                                .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: blink)
                        )
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
        // Visual size stays 82 (ring is 76pt); expand the touch target a bit
        // further than before so it's comfortably larger than the visible
        // colored ring on every side.
        .frame(width: 118, height: 118)
        .contentShape(Circle())
        .disabled(recorder.isSaving || recorder.isSwitchingCamera || recorder.isCapturingPhoto)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: recorder.isRecording)
        // Press-and-hold for burst mode, photo mode only. Uses a plain
        // LongPressGesture (not `.sequenced`) alongside the Button above —
        // SwiftUI dispatches the Button's tap action only when this gesture
        // does not itself consume the touch as a completed long-press, so a
        // quick tap still reaches handleShutterTap() unchanged.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in handleShutterLongPress() }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onEnded { _ in
                    if recorder.isBursting { recorder.cancelBurstCapture() }
                }
        )
    }

    private var modeSelector: some View {
        let modes = CameraMode.allCases

        return HStack(spacing: 2) {
            ForEach(modes) { mode in
                let isActive = settings.cameraMode == mode
                Button {
                    guard settings.cameraMode != mode else { return }
                    let previous = settings.cameraMode
                    DebugLog.write("modeSelector: \(previous) -> \(mode)")
                    modeHaptic.selectionChanged()
                    switchCaptureMode(to: mode)
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

    private func switchCaptureMode(to mode: CameraMode) {
        guard !recorder.isSwitchingMode,
              !recorder.isRecording,
              !recorder.isSaving,
              !recorder.isBursting else { return }

        recorder.isSwitchingMode = true
        modeTransitionLabel = mode.label
        withAnimation(.easeOut(duration: 0.12)) {
            modeTransitionOpacity = 0.68
        }

        // Let the cover reach opacity before the sensor starts negotiating its
        // new format. This makes Video ⇄ Photo ⇄ Slow-Mo feel intentional on
        // iPhone 7 rather than showing the preview's transient frozen frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            recorder.activeSensorFPS = 0
            settings.cameraMode = mode
            recorder.updateCaptureFormat {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                    withAnimation(.easeIn(duration: 0.20)) {
                        modeTransitionOpacity = 0
                    }
                    recorder.isSwitchingMode = false
                }
            }
        }
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
        let haptic = UIImpactFeedbackGenerator(style: settings.hapticIntensity.scaled(.heavy))
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

    /// Persistent "what's locked" pill — stays up the whole time a lock is
    /// active (unlike the reticle flash, which fades in ~1s), since AF/AE
    /// lock can otherwise be a silent state that's easy to forget is on and
    /// then blame for a blurry/blown-out shot. Tapping either badge (or the
    /// whole pill) releases both locks and returns to continuous AF/AE.
    private var focusExposureLockBar: some View {
        HStack(spacing: 10) {
            if recorder.focusLocked {
                lockChip(label: "AF LOCK", icon: "camera.metering.spot")
            }
            if recorder.exposureLocked {
                lockChip(label: "AE LOCK", icon: "sun.max.fill")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Palette.panel.opacity(0.9))
                .background(Capsule().fill(Palette.slateDeep.opacity(usesLightweightMaterial ? 0.55 : 0.3)))
        )
        .overlay(Capsule().stroke(Palette.amber.opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 4)
        .onTapGesture {
            if settings.hapticFeedbackEnabled { levelHaptic.selectionChanged() }
            if recorder.focusLocked { recorder.unlockFocus() }
            if recorder.exposureLocked { recorder.unlockExposure() }
        }
    }

    private func lockChip(label: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Image(systemName: "lock.fill")
                .font(.system(size: 8, weight: .bold))
            Text(label)
                .font(.system(size: 11, weight: .black, design: .rounded))
        }
        .foregroundColor(Palette.slateDeep)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Palette.amber))
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

    // MARK: Zoom dial (drag-to-zoom, like the native Camera app's "1x" pill)

    /// Hard ceiling for the drag gesture, per spec — independent of whatever
    /// `recorder.maxZoomFactor` the hardware reports, then clamped to it so
    /// we never ask the session for more zoom than the lens can deliver.
    private let zoomDialMaxFactor: CGFloat = 8
    private var zoomDialMinFactor: CGFloat { max(0.5, recorder.minZoomFactor) }

    private func zoomDialLabel(_ factor: CGFloat) -> String {
        if abs(factor - factor.rounded()) < 0.05 {
            return "\(Int(factor.rounded()))x"
        }
        return String(format: "%.1fx", factor)
    }

    /// A full-width invisible drag pad (not a tiny button) so you never have
    /// to land your finger precisely on the "1x" pill to zoom — touch down
    /// and drag ANYWHERE across this bar. Sensitivity is derived from the
    /// pad's actual measured width so that swiping from the center out to
    /// either edge always covers the complete 1x–8x range, regardless of
    /// screen size. A tap that doesn't move never changes the zoom — only
    /// dragging does, so an accidental tap never resets your zoom.
    private var zoomControl: some View {
        GeometryReader { geo in
            // Half the pad's width is the travel available from the center
            // (where the finger typically starts) out to one edge; dividing
            // that by log2(max) gives the exact points-per-doubling needed
            // so reaching the edge reaches 8x, not something short of it.
            let halfWidth = max(geo.size.width / 2, 60)
            let doublingsNeeded = log2(zoomDialMaxFactor / zoomDialMinFactor)
            let pointsPerDoubling = halfWidth / doublingsNeeded

            HStack(spacing: 8) {
                if recorder.minZoomFactor <= 0.51 {
                    Button {
                        recorder.setZoom(factor: 0.5)
                        if settings.hapticFeedbackEnabled { zoomHaptic.selectionChanged() }
                    } label: {
                        Text("0.5x")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(abs(recorder.zoomFactor - 0.5) < 0.08 ? settings.accentColor.bright : .white.opacity(0.72))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Palette.panel.opacity(0.78)))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    recorder.setZoom(factor: 1)
                    if settings.hapticFeedbackEnabled { zoomHaptic.selectionChanged() }
                } label: {
                    Text(zoomDialLabel(recorder.zoomFactor))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(Palette.panel.opacity(0.88))
                                .background(Capsule().fill(Palette.slateDeep.opacity(usesLightweightMaterial ? 0.55 : 0.3)))
                        )
                        .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        if !isZoomDialDragging {
                            isZoomDialDragging = true
                            zoomGestureBase = recorder.zoomFactor
                            if settings.hapticFeedbackEnabled { zoomHaptic.selectionChanged() }
                        }
                        recorder.suppressVolumeTriggerBriefly()
                        // Exponential mapping (not linear) so the feel matches
                        // native iOS: the same finger travel produces a
                        // proportional zoom change wherever you are in the
                        // range, instead of 1x->2x taking the same distance
                        // as 7x->8x.
                        let factor = zoomGestureBase * pow(2, -value.translation.width / pointsPerDoubling)
                        let clamped = min(max(factor, zoomDialMinFactor), min(zoomDialMaxFactor, recorder.maxZoomFactor))
                        recorder.setZoom(factor: clamped)
                    }
                    .onEnded { _ in
                        // Lifting the finger never snaps back to 1x — the zoom
                        // stays wherever you dragged it to, exactly like the
                        // native Camera app.
                        isZoomDialDragging = false
                        recorder.suppressVolumeTriggerBriefly()
                    }
            )
        }
        .frame(height: 54)
    }

    private var focusReticle: some View {
        let reticleColor = focusReticleIsLock ? Palette.amber : settings.accentColor.bright
        // Settled scale is 1.0, plus a slow ±6% breathing pulse only while
        // a lock is actively held on screen — a plain focus tap never pulses.
        let settledScale: CGFloat = (focusReticleIsLock && focusReticlePulsing) ? 1.06 : 1.0
        return ZStack {
            // Thin square outline — classic camera-app focus box, not a hexagon.
            // Slightly thicker for that first "just landed" instant, thinning
            // as it settles, mirroring how stock camera apps snap a focus box in.
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(reticleColor, lineWidth: focusReticleExpanded ? 1.8 : 1.2)
                .frame(width: 64, height: 64)

            // Small corner tick marks for that "locking on" feel.
            ForEach(0..<4) { i in
                Rectangle()
                    .fill(reticleColor)
                    .frame(width: 8, height: 2)
                    .offset(x: (i % 2 == 0 ? -1 : 1) * 28, y: (i < 2 ? -1 : 1) * 32)
            }

            // Small center dot to mark the exact focus point.
            Circle()
                .fill(reticleColor)
                .frame(width: 4, height: 4)

            // A small padlock badge on top-right of the box for tap-and-hold
            // locks, so the reticle itself communicates "locked" without
            // needing to read the AF/AE pill elsewhere on screen.
            if focusReticleIsLock {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Palette.slateDeep)
                    .padding(3)
                    .background(Circle().fill(reticleColor))
                    .offset(x: 30, y: -30)
            }
        }
        .shadow(color: reticleColor.opacity(focusReticleExpanded ? 0.7 : 0.4), radius: focusReticleExpanded ? 8 : 3)
        // Two-stage motion: the box pops in slightly oversized (a snappy
        // "acquired" moment), then converges to its resting size a beat
        // later — closer to how stock camera apps animate focus acquisition
        // than a single flat fade. `focusPoint == nil` still governs the
        // overall appear/disappear so it fades out from wherever it was.
        .scaleEffect(focusPoint == nil ? 1.4 : (focusReticleExpanded ? 1.25 : settledScale))
        .opacity(focusPoint == nil ? 0 : 1)
        .animation(.spring(response: 0.32, dampingFraction: 0.62), value: focusReticleExpanded)
        .animation(.easeInOut(duration: 0.9), value: focusReticlePulsing)
        .animation(.spring(response: 0.26, dampingFraction: 0.7), value: focusPoint)
    }

    private func showFocusReticle(at point: CGPoint, locked: Bool) {
        focusHideToken += 1
        let token = focusHideToken
        focusReticleIsLock = locked
        focusReticleExpanded = true
        focusReticlePulsing = false
        focusPoint = point

        // Let the oversized "just landed" frame render for one beat, then
        // converge to resting size — the pop-then-settle read that makes a
        // focus acquisition feel deliberate rather than just a fade-in box.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard focusHideToken == token else { return }
            focusReticleExpanded = false
            if locked {
                // Continuous gentle pulse for as long as the lock reticle
                // stays visible, so an active lock visibly reads as "on".
                withAnimation(Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    focusReticlePulsing = true
                }
            }
        }

        // Give a lock confirmation a beat longer on screen than a plain
        // focus tap, since it's confirming a mode change, not just a spot.
        let holdDuration: Double = locked ? 1.3 : 0.9
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration) {
            if focusHideToken == token {
                focusPoint = nil
                focusReticlePulsing = false
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
    @Environment(\.dismiss) private var dismiss
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
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        player?.pause()
                        dismiss()
                    }
                }
            }
        }
        .tint(Palette.violet)
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
