import AVFoundation
import UIKit
import Photos
import MediaPlayer
import CoreMotion
import Combine
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
                DispatchQueue.main.async { self.settings.exposureBias = clamped }
            } catch { }
        }
    }

    func setWhiteBalance(_ preset: WhiteBalancePreset) {
        sessionQueue.async {
            if preset.kelvin == nil {
                self.ensureCorrectCameraDevice(for: self.settings.cameraMode)
                guard let device = self.cameraInput?.device else { return }
                do {
                    try device.lockForConfiguration()
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        device.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                    device.unlockForConfiguration()
                    self.refreshZoomLimits()
                    DispatchQueue.main.async { self.settings.whiteBalance = preset }
                } catch { }
                return
            }

            guard let values = preset.kelvin else { return }

            var device = self.cameraInput?.device
            var lostUltraWide = false

            if let d = device, !d.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                if let fallback = Self.camera(at: self.position, mode: self.settings.cameraMode, preferPhysical: true) {
                    self.switchCameraInput(to: fallback)
                    device = self.cameraInput?.device
                    lostUltraWide = true
                }
            }

            guard let device = device else { return }
            do {
                try device.lockForConfiguration()
                guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else {
                    device.unlockForConfiguration()
                    DispatchQueue.main.async {
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
                DispatchQueue.main.async {
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
        DispatchQueue.main.async {
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
                if on {
                    let level: Float = self.settings.torchBrightness > 0 ? self.settings.torchBrightness : 1.0
                    let targetLevel = min(level, AVCaptureDevice.maxAvailableTorchLevel)
                    try device.setTorchModeOn(level: targetLevel)
                } else {
                    device.torchMode = .off
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.torchOn = on }
            } catch {
                DispatchQueue.main.async { self.notice = "Torch is busy" }
            }
        }
    }

    func setLiveTorch(level: Float) {
        sessionQueue.async {
            guard let device = self.cameraInput?.device, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                if level > 0.01 {
                    let maxLevel = AVCaptureDevice.maxAvailableTorchLevel
                    let targetLevel = min(level, maxLevel)
                    try device.setTorchModeOn(level: targetLevel)
                    DispatchQueue.main.async {
                        self.torchOn = true
                        self.settings.torchBrightness = level
                    }
                } else {
                    device.torchMode = .off
                    // Keep the user's preferred torch level so the next
                    // torch-on restores it instead of jumping to full/zero.
                    DispatchQueue.main.async {
                        self.torchOn = false
                    }
                }
                device.unlockForConfiguration()
            } catch { }
        }
    }

    @objc func willResignActive() {
        setTorch(on: false)
        if isRecording {
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
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isSessionRunning = false }
        }
    }

    @objc func didBecomeActive() {
        volumeObserver?.ignoreTemporarily(duration: 1.5)
        sessionQueue.async {
            if !self.session.isRunning { self.session.startRunning() }
            self.refreshTorchState()
            DispatchQueue.main.async { self.isSessionRunning = self.session.isRunning }
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
        let rawCeiling = min(device.activeFormat.videoMaxZoomFactor, baseline * 8)
        let rawFloor = device.minAvailableVideoZoomFactor

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

        DispatchQueue.main.async {
            self.maxZoomFactor = rawCeiling / baseline
            self.minZoomFactor = rawFloor / baseline
            self.zoomFactor = clampedUI
        }
    }

    func setZoom(factor: CGFloat) {
        sessionQueue.async {
            guard let device = self.cameraInput?.device else { return }
            let baseline = self.zoomBaselineSnapshot
            let raw = factor * baseline
            let clamped = max(self.rawMinZoomSnapshot, min(raw, self.rawMaxZoomSnapshot))
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.zoomFactor = clamped / baseline }
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
        applyFocusAndExposure(at: clamped,
                              focus: .autoFocus,
                              exposure: .autoExpose,
                              monitorSubjectArea: true)
    }

    func resetFocusAndExposureToAuto() {
        applyFocusAndExposure(at: CGPoint(x: 0.5, y: 0.5),
                              focus: .continuousAutoFocus,
                              exposure: .continuousAutoExposure,
                              monitorSubjectArea: false)
    }

    func applyFocusAndExposure(at point: CGPoint,
                                       focus: AVCaptureDevice.FocusMode,
                                       exposure: AVCaptureDevice.ExposureMode,
                                       monitorSubjectArea: Bool) {
        sessionQueue.async {
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

    @objc func subjectAreaDidChange() {
        resetFocusAndExposureToAuto()
    }


}
