//
//  CameraHardware.swift
//  LowPolyCam
//
//  Updated for iOS 27 / Xcode 27 / Swift 6.4.
//  Swift 6 complete concurrency · Observation · Liquid Glass · RotationCoordinator
//

import AVFoundation
import UIKit
import Photos
import MediaPlayer
import CoreMotion
import AudioToolbox
import ImageIO

extension CameraRecorder {

    // MARK: Exposure & White Balance

    func setExposureBias(_ bias: Float) {
        sessionQueue.async {
            guard let device = self.cameraInput?.device else { return }
            do {
                try device.lockForConfiguration()
                let minBias = device.minExposureTargetBias
                let maxBias = device.maxExposureTargetBias
                let clamped = max(minBias, min(bias, maxBias))
                device.setExposureTargetBias(clamped, completionHandler: nil)
                device.unlockForConfiguration()
                Task { @MainActor in self.settings.exposureBias = clamped }
            } catch { }
        }
    }

    func setWhiteBalance(_ preset: WhiteBalancePreset) {
        guard !isSwitchingMode, !isSwitchingCamera, !isCapturingPhoto, !isSaving, !isStartingRecording else { return }
        sessionQueue.async {
            if preset.kelvin == nil {
                // Auto WB is a control change, not an implicit lens change.
                guard let device = self.cameraInput?.device else { return }
                do {
                    try device.lockForConfiguration()
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        device.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                    device.unlockForConfiguration()
                    self.refreshZoomLimits()
                    Task { @MainActor in self.settings.whiteBalance = preset }
                } catch { }
                return
            }

            guard let values = preset.kelvin else { return }

            var device = self.cameraInput?.device
            var lostUltraWide = false

            if let d = device, !d.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                if let fallback = Self.camera(at: self.position, mode: self.settings.cameraMode, preferPhysical: true) {
                    guard !self.wantsRecording else {
                        Task { @MainActor in self.notice = "Change this white balance preset before recording" }
                        return
                    }
                    let fps = self.cameraInput.map { 1 / $0.device.activeVideoMinFrameDuration.seconds } ?? 30
                    let dims = self.settings.cameraMode == .slowMo
                        ? self.settings.slowMoResolution.captureDimensions : self.settings.resolution.captureDimensions
                    guard let format = CameraFormatSelector.bestVideoFormat(for: fallback, width: dims.w, height: dims.h, fps: fps) else {
                        Task { @MainActor in self.notice = "White balance preset unavailable for this format" }
                        return
                    }
                    self.switchCameraInput(to: fallback)
                    guard self.cameraInput?.device.uniqueID == fallback.uniqueID,
                          self.applyUnifiedHardwareConfiguration(to: fallback, format: format, targetFPS: fps) else { return }
                    device = self.cameraInput?.device
                    lostUltraWide = true
                }
            }

            guard let device = device else { return }
            do {
                try device.lockForConfiguration()
                guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else {
                    device.unlockForConfiguration()
                    Task { @MainActor in
                        self.notice = "Manual WB unsupported here"
                    }
                    return
                }
                let tempAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: values.temp, tint: values.tint)
                var gains = device.deviceWhiteBalanceGains(for: tempAndTint)
                let maxGain = device.maxWhiteBalanceGain
                gains.redGain = max(1.0, min(gains.redGain.isFinite ? gains.redGain : 1.0, maxGain))
                gains.greenGain = max(1.0, min(gains.greenGain.isFinite ? gains.greenGain : 1.0, maxGain))
                gains.blueGain = max(1.0, min(gains.blueGain.isFinite ? gains.blueGain : 1.0, maxGain))
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                device.unlockForConfiguration()
                self.refreshZoomLimits()
                Task { @MainActor in
                    self.settings.whiteBalance = preset
                    if lostUltraWide {
                        self.notice = "0.5x unavailable with custom WB"
                    }
                }
            } catch { }
        }
    }

    // MARK: Torch

    func refreshTorchState() {
        let device = cameraInput?.device
        let available = device?.hasTorch ?? false
        let on = (device?.torchMode == .on)
        Task { @MainActor in
            self.hasTorch = available
            self.torchOn = available && on
        }
    }

    func toggleTorch() {
        setTorch(on: !torchOn)
    }

    func setTorch(on: Bool) {
        sessionQueue.async {
            guard let device = self.cameraInput?.device, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if on {
                    let level: Float = self.settings.torchBrightness > 0 ? self.settings.torchBrightness : 1.0
                    let targetLevel = min(level, AVCaptureDevice.maxAvailableTorchLevel)
                    try device.setTorchModeOn(level: targetLevel)
                } else {
                    device.torchMode = .off
                }
                Task { @MainActor in self.torchOn = on }
            } catch {
                Task { @MainActor in self.notice = "Torch is busy" }
            }
        }
    }

    func setLiveTorch(level: Float) {
        sessionQueue.async {
            guard let device = self.cameraInput?.device, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if level > 0.01 {
                    let maxLevel = AVCaptureDevice.maxAvailableTorchLevel
                    let targetLevel = min(level, maxLevel)
                    try device.setTorchModeOn(level: targetLevel)
                    Task { @MainActor in
                        self.torchOn = true
                        self.settings.torchBrightness = level
                    }
                } else {
                    device.torchMode = .off
                    // Keep the user's preferred torch level so the next
                    // torch-on restores it instead of jumping to full/zero.
                    Task { @MainActor in
                        self.torchOn = false
                    }
                }
            } catch { }
        }
    }

    @objc func willResignActive() {
        setTorch(on: false)
        if isRecording || isStartingRecording {
            stopRecording(notice: "Recording stopped (app backgrounded)")
        }
        // Stop the capture session while backgrounded. Without this the
        // session (and therefore the photo/video outputs) kept running with
        // the app suspended, which could let a shutter tap that was already
        // in flight complete and save a photo taken "in the background", and
        // wasted power keeping the sensor active while not visible.
        pauseVolumeMonitoring()
        stopMotionUpdates()
        sessionQueue.async {
            self.applicationActive = false
            if self.session.isRunning { self.session.stopRunning() }
            Task { @MainActor in self.isSessionRunning = false }
        }
    }

    @objc func didBecomeActive() {
        volumeObserver?.ignoreTemporarily(duration: 1.5)
        sessionQueue.async {
            self.applicationActive = true
            guard !self.previewPaused else { return }
            // On a cold launch, didBecomeActive can fire on this queue before
            // start()'s configureSession() has run (both are dispatched to
            // sessionQueue around the same moment — .onAppear vs. the app
            // becoming active — with no ordering guarantee between them).
            // Calling startRunning() on a session with no inputs/outputs yet
            // — then configureSession() mutating it a moment later while it's
            // already running — produced the intermittent gray/frozen preview
            // right after launch. Only (re)start here once setup has happened.
            guard self.isConfigured else { return }
            if !self.session.isRunning { self.session.startRunning() }
            self.refreshTorchState()
            Task { @MainActor in self.isSessionRunning = self.session.isRunning }
        }
        // Restart motion updates cleanly — after being backgrounded (e.g. screen
        // locked for a while), the previous raw angle used for unwrapping the roll
        // is stale and can throw the level gauge off. Restarting resets that state.
        // We always (re)start briefly even with the level gauge UI off, so photo
        // capture's physicalOrientation stays correct instead of freezing at
        // whatever orientation it was in before backgrounding (see startMotionUpdates).
        stopMotionUpdates()
        startMotionUpdates()
        resumeVolumeMonitoring()
    }

    // MARK: Zoom

    func refreshZoomLimits() {
        guard let device = cameraInput?.device else { return }

        let baseline = CameraFormatSelector.wideAngleBaseline(for: device)
        zoomObservation?.invalidate()
        zoomObservation = device.observe(\.videoZoomFactor, options: [.new]) { [weak self] observed, _ in
            self?.sessionQueue.async {
                guard let self, self.cameraInput?.device.uniqueID == observed.uniqueID else { return }
                let actual = observed.videoZoomFactor / baseline
                Task { @MainActor in self.zoomFactor = actual }
            }
        }
        let rawCeiling = min(device.activeFormat.videoMaxZoomFactor, baseline * 8)
        let rawFloor = device.minAvailableVideoZoomFactor
        let hasSlowMoUltraWide = settings.cameraMode == .slowMo
            && position == .back
            && slowMoPhysicalDevice(for: 0.5) != nil

        // Keep the user's zoom factor (UI units) when the format changes.
        let previousFactor = zoomFactor
        zoomBaselineSnapshot = baseline
        rawMaxZoomSnapshot = rawCeiling
        rawMinZoomSnapshot = rawFloor

        let clampedUI = max(rawFloor / baseline, min(previousFactor > 0 ? previousFactor : 1, rawCeiling / baseline))
        // Re-apply on hardware so activeFormat's new zoom range matches UI.
        let raw = clampedUI * baseline
        let clampedRaw = max(rawFloor, min(raw, rawCeiling))
        if abs(device.videoZoomFactor - clampedRaw) > 0.01 {
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clampedRaw
                device.unlockForConfiguration()
            } catch { }
        }

        Task { @MainActor in
            self.maxZoomFactor = rawCeiling / baseline
            self.minZoomFactor = hasSlowMoUltraWide ? 0.5 : rawFloor / baseline
            self.zoomFactor = clampedUI
            // iPhone 7 has one physical (wide) lens, so 1x is the only
            // "real" optical zoom factor — everything past it is a digital
            // crop/interpolation, never a switch to a longer lens.
            self.opticalZoomCeiling = max(1, rawFloor / baseline)
        }
    }

    func setZoom(factor: CGFloat, resetToWide: Bool = false) {
        guard factor.isFinite, !isSwitchingMode, !isSwitchingCamera,
              !isCapturingPhoto, !isStartingRecording, !isSaving else { return }
        sessionQueue.async {
            guard var device = self.cameraInput?.device else { return }

            // Cross the 0.5x/1x boundary by changing physical lenses in
            // Slow-Mo. High-FPS formats are not available through the virtual
            // dual-wide input on this hardware.
            if self.settings.cameraMode == .slowMo,
               self.position == .back,
               let target = self.slowMoPhysicalDevice(for: factor, resetToWide: resetToWide),
               target.uniqueID != device.uniqueID {
                self.switchCameraInput(to: target)
                guard self.cameraInput?.device.uniqueID == target.uniqueID else { return }
                device = target
                let dims = self.settings.slowMoResolution.captureDimensions
                let fps = Double(self.settings.slowMoFrameRate.value)
                if let format = CameraFormatSelector.bestSlowMoAwareFormat(
                    for: target, width: dims.w, height: dims.h, fps: fps
                ) {
                    guard self.applyUnifiedHardwareConfiguration(to: target, format: format, targetFPS: fps) else { return }
                    self.lastAppliedFormatKey = Self.formatKey(device: target, format: format, fps: fps)
                    self.refreshZoomLimits()
                }
            }

            let baseline = CameraFormatSelector.wideAngleBaseline(for: device)
            let rawFloor = device.minAvailableVideoZoomFactor
            let rawCeiling = min(device.activeFormat.videoMaxZoomFactor, baseline * 8)
            let raw = factor * baseline
            let clamped = max(rawFloor, min(raw, rawCeiling))
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
                self.zoomBaselineSnapshot = baseline
                self.rawMinZoomSnapshot = rawFloor
                self.rawMaxZoomSnapshot = rawCeiling
                Task { @MainActor in
                    self.zoomFactor = clamped / baseline
                }
            } catch { }
        }
    }

    // MARK: Focus and exposure

    /// Tap-to-focus: one-shot AF + AE on the tapped point.
    /// continuousAutoFocus for taps often does nothing on older silicon
    /// (iPhone 7) when the mode is already continuous — the lens never
    /// re-racks. autoFocus forces a focus cycle; subject-area monitoring then
    /// returns to continuous AF once the scene changes.
    func focusAndExpose(at point: CGPoint) {
        let clamped = CGPoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )
        // A plain tap always means "focus/expose here and go back to
        // tracking" — it should break any standing focus/exposure lock,
        // the same way it does in stock Camera.
        Task { @MainActor in
            self.focusLocked = false
            self.exposureLocked = false
        }
        applyFocusAndExposure(at: clamped,
                              focus: .autoFocus,
                              exposure: .autoExpose,
                              monitorSubjectArea: true)
        // `autoExpose` is a one-shot measurement. Return to continuous AE/AF
        // once that rack finishes so brightness keeps following the scene.
        // Without this, a single tap could leave the front camera looking dark
        // for the rest of a slow-motion take.
        sessionQueue.async {
            let focusIntent = self.focusGeneration
            let exposureIntent = self.exposureGeneration
            let deviceID = self.cameraInput?.device.uniqueID
            self.sessionQueue.asyncAfter(deadline: .now() + 0.7) {
                guard self.focusGeneration == focusIntent,
                      self.exposureGeneration == exposureIntent,
                      self.cameraInput?.device.uniqueID == deviceID else { return }
                self.applyFocusAndExposure(at: clamped,
                                           focus: .continuousAutoFocus,
                                           exposure: .continuousAutoExposure,
                                           monitorSubjectArea: true)
            }
        }
    }

    func resetFocusAndExposureToAuto() {
        applyFocusAndExposure(at: CGPoint(x: 0.5, y: 0.5),
                              focus: .continuousAutoFocus,
                              exposure: .continuousAutoExposure,
                              monitorSubjectArea: false)
        Task { @MainActor in
            self.focusLocked = false
            self.exposureLocked = false
        }
    }

    /// Tap-and-hold: locks focus at the held point and leaves it there
    /// until the next plain tap or camera switch. Exposure is left alone
    /// (see `lockExposure`) so the two can be locked independently.
    func lockFocus(at point: CGPoint) {
        let clamped = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        sessionQueue.async {
            self.focusGeneration += 1
            let intent = self.focusGeneration
            guard let device = self.cameraInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = clamped
                }
                if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }
                device.unlockForConfiguration()
            } catch { }

            // Give the lens a moment to actually rack focus to the tapped
            // point before freezing it in place — locking immediately would
            // just freeze whatever distance it happened to be sitting at.
            self.sessionQueue.asyncAfter(deadline: .now() + 0.35) {
                guard self.focusGeneration == intent,
                      self.cameraInput?.device.uniqueID == device.uniqueID else { return }
                do {
                    try device.lockForConfiguration()
                    if device.isFocusModeSupported(.locked) {
                        device.focusMode = .locked
                    }
                    // Subject-area monitoring would otherwise silently pull
                    // focus back to auto on the next scene change, defeating
                    // the lock, so suppress it while anything is locked.
                    device.isSubjectAreaChangeMonitoringEnabled = false
                    device.unlockForConfiguration()
                    Task { @MainActor in self.focusLocked = true }
                } catch { }
            }
        }
    }

    func unlockFocus() {
        sessionQueue.async {
            self.focusGeneration += 1
            let intent = self.focusGeneration
            guard let device = self.cameraInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                let otherStillLocked = device.exposureMode == .locked
                device.isSubjectAreaChangeMonitoringEnabled = !otherStillLocked
                device.unlockForConfiguration()
                Task { @MainActor in self.focusLocked = false }
            } catch { }
        }
    }

    func toggleFocusLock(at point: CGPoint) {
        if focusLocked { unlockFocus() } else { lockFocus(at: point) }
    }

    /// Two-finger tap-and-hold: locks exposure at the held point,
    /// independent of focus.
    func lockExposure(at point: CGPoint) {
        let clamped = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        sessionQueue.async {
            self.exposureGeneration += 1
            let intent = self.exposureGeneration
            guard let device = self.cameraInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = clamped
                }
                if device.isExposureModeSupported(.autoExpose) {
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
            } catch { }

            self.sessionQueue.asyncAfter(deadline: .now() + 0.35) {
                guard self.exposureGeneration == intent,
                      self.cameraInput?.device.uniqueID == device.uniqueID else { return }
                do {
                    try device.lockForConfiguration()
                    if device.isExposureModeSupported(.locked) {
                        device.exposureMode = .locked
                    }
                    device.isSubjectAreaChangeMonitoringEnabled = false
                    device.unlockForConfiguration()
                    Task { @MainActor in self.exposureLocked = true }
                } catch { }
            }
        }
    }

    func unlockExposure() {
        sessionQueue.async {
            self.exposureGeneration += 1
            let intent = self.exposureGeneration
            guard let device = self.cameraInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                let otherStillLocked = device.focusMode == .locked
                device.isSubjectAreaChangeMonitoringEnabled = !otherStillLocked
                device.unlockForConfiguration()
                Task { @MainActor in self.exposureLocked = false }
            } catch { }
        }
    }

    func toggleExposureLock(at point: CGPoint) {
        if exposureLocked { unlockExposure() } else { lockExposure(at: point) }
    }

    func applyFocusAndExposure(at point: CGPoint,
                                       focus: AVCaptureDevice.FocusMode,
                                       exposure: AVCaptureDevice.ExposureMode,
                                       monitorSubjectArea: Bool) {
        sessionQueue.async {
            self.focusGeneration += 1
            self.exposureGeneration += 1
            guard let device = self.cameraInput?.device else { return }
            do {
                try device.lockForConfiguration()

                // Focus: set POI first, then mode. If already in the requested
                // mode, briefly leave it so the hardware re-triggers a cycle
                // (otherwise a second tap is a no-op on many devices).
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                }
                if device.isFocusModeSupported(focus) {
                    if device.focusMode == focus {
                        if focus == .autoFocus, device.isFocusModeSupported(.continuousAutoFocus) {
                            device.focusMode = .continuousAutoFocus
                        } else if device.isFocusModeSupported(.locked) {
                            device.focusMode = .locked
                        }
                    }
                    device.focusMode = focus
                } else if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }

                // Exposure: same pattern — POI then mode.
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                }
                if device.isExposureModeSupported(exposure) {
                    if device.exposureMode == exposure {
                        if exposure == .autoExpose, device.isExposureModeSupported(.continuousAutoExposure) {
                            device.exposureMode = .continuousAutoExposure
                        } else if device.isExposureModeSupported(.locked) {
                            device.exposureMode = .locked
                        }
                    }
                    device.exposureMode = exposure
                } else if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }

                device.isSubjectAreaChangeMonitoringEnabled = monitorSubjectArea
                device.unlockForConfiguration()
            } catch { }
        }
    }

    @objc func subjectAreaDidChange(_ notification: Notification) {
        guard let source = notification.object as? AVCaptureDevice else { return }
        sessionQueue.async {
            guard source.uniqueID == self.cameraInput?.device.uniqueID,
                  source.focusMode != .locked, source.exposureMode != .locked else { return }
            self.resetFocusAndExposureToAuto()
        }
    }


}
