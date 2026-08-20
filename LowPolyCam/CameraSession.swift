import AVFoundation
import UIKit
import Photos
import MediaPlayer
import CoreMotion
import Combine
import AudioToolbox
import ImageIO

extension CameraRecorder {

    // MARK: Session setup

    func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        if let device = Self.camera(at: position, mode: settings.cameraMode, preferPhysical: wantsPhysicalWideLens),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            cameraInput = input
        }

        // On weaker/older hardware (e.g. iPhone 7's A10) the encoder can
        // fall behind under thermal load. Discarding late frames instead of
        // queueing them keeps memory bounded and avoids a growing backlog —
        // dropped frames are already tracked via didDrop/countDroppedFrame.
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        // Delegates stay nil while idle. They are attached only for the
        // duration of a recording (see startRecording / stopRecording) so
        // the system does not deliver every preview frame into the process
        // when nothing is being written — major idle-heat reduction.
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }

        session.commitConfiguration()

        configureVideoConnection()
        refreshCapabilitiesThenApplyFormat()
        configurePhotoOutput()
        refreshTorchState()
        resetFocusAndExposureToAuto()
        syncMicInput()
    }

    // MARK: Photo Output Configuration

    func configurePhotoOutput() {
        guard let device = cameraInput?.device else { return }

        // Enable the highest quality prioritization AVCapturePhotoOutput offers,
        // which lets the system apply the same Smart-HDR / multi-frame scene
        // rendering the live preview already benefits from. Without this, the
        // saved photo can come out noticeably darker/flatter than what was seen
        // live, especially in low light, because the discrete still capture was
        // otherwise using a plainer single-frame render.
        if #available(iOS 13.0, *) {
            photoOutput.maxPhotoQualityPrioritization = .quality
        }
        if #available(iOS 16.0, *) {
            // Use the TRUE max across all formats — device.activeFormat only reflects
            // whatever video format is currently applied (often ~1080p/2MP), not the
            // sensor's real max still-photo resolution.
            let maxDims = device.formats
                .flatMap { $0.supportedMaxPhotoDimensions }
                .max { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }
            if let maxDims = maxDims {
                photoOutput.maxPhotoDimensions = maxDims
            }
        } else {
            // iOS <16 path (this is what iPhone 7 / iOS 15.8 actually uses).
            // NOTE: we deliberately do NOT switch activeFormat here anymore — on
            // iOS <16, activeFormat drives BOTH the live preview AND still capture,
            // so permanently locking it to a high-res-optimized format made the live
            // preview blurry/pixelated. The high-res format swap now happens only
            // briefly, right before actually taking the photo (see capturePhoto()),
            // and is restored immediately after — keeping the live preview smooth.
            photoOutput.isHighResolutionCaptureEnabled = true
        }
    }

    func configureVideoConnection() {
        guard let c = videoOutput.connection(with: .video) else { return }
        if c.isVideoOrientationSupported { c.videoOrientation = .landscapeRight }
        if c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = false
        }
        applyStabilization(to: c)
    }

    func applyStabilization(to connection: AVCaptureConnection? = nil, forceRecording: Bool? = nil) {
        guard let c = connection ?? videoOutput.connection(with: .video) else { return }
        let supported = c.isVideoStabilizationSupported
        if supported {
            // Keep stabilisation ON whenever the user has it enabled (Video /
            // Slow-Mo only), not only while recording. Toggling it at Record
            // start/stop crops the FOV and looks like a flash/flicker — stock
            // Camera does not do that. Still force off at 4K (A10 can't hold
            // 30 fps with stab) and in Photo mode (still path is separate).
            _ = forceRecording // retained for call-site compatibility
            let wantStab = settings.stabilization
                && settings.resolution != .p2160
                && settings.cameraMode != .photo
            c.preferredVideoStabilizationMode = wantStab ? .auto : .off
        }
        DispatchQueue.main.async { self.stabilizationSupported = supported }
    }

    func updateStabilization() {
        sessionQueue.async { self.applyStabilization() }
    }

    func ensureCorrectCameraDevice(for mode: CameraMode) {
        guard let targetDevice = Self.camera(at: position, mode: mode, preferPhysical: wantsPhysicalWideLens) else { return }
        switchCameraInput(to: targetDevice)
    }

    func switchCameraInput(to targetDevice: AVCaptureDevice) {
        guard cameraInput?.device.uniqueID != targetDevice.uniqueID else { return }
        DispatchQueue.main.async { self.volumeObserver?.ignoreTemporarily() }

        session.beginConfiguration()
        if let old = cameraInput { session.removeInput(old) }
        if let input = try? AVCaptureDeviceInput(device: targetDevice), session.canAddInput(input) {
            session.addInput(input)
            cameraInput = input
        }
        session.commitConfiguration()
        configureVideoConnection()
    }

    /// Applies the active camera format + frame rate.
    /// Returns `true` if the sensor format/fps actually changed (caller may
    /// need to wait for AE). Returns `false` when it was already correct —
    /// that path is what keeps Record start/stop flicker-free.
    @discardableResult
    func applyActiveFormat(forRecording: Bool = false, forceLowestIdlePreview: Bool = false) -> Bool {
        DispatchQueue.main.async { self.volumeObserver?.ignoreTemporarily() }
        ensureCorrectCameraDevice(for: settings.cameraMode)
        guard let device = cameraInput?.device else { return false }

        let isSlow = settings.cameraMode == .slowMo && isSlowMoSupportedOnCurrentLens
        var dims: (w: Int, h: Int)
        let fullFPS: Double

        if isSlow {
            if !availableSlowMoRates.contains(settings.slowMoFrameRate) {
                let fallback = availableSlowMoRates.first ?? .fps120
                DispatchQueue.main.async {
                    self.settings.slowMoFrameRate = fallback
                }
            }
            // 240 fps is 720p-only (matches iOS Camera on iPhone).
            if settings.slowMoFrameRate == .fps240, settings.slowMoResolution == .p1080 {
                DispatchQueue.main.async { self.settings.slowMoResolution = .p720 }
                dims = Resolution.p720.captureDimensions
            } else {
                dims = settings.slowMoResolution.captureDimensions
            }
            fullFPS = Double(settings.slowMoFrameRate.value)
        } else {
            dims = settings.resolution.captureDimensions
            if let locked = settings.resolution.lockedFrameRate, settings.frameRate != locked {
                DispatchQueue.main.async {
                    self.settings.frameRate = locked
                    self.notice = "\(self.settings.resolution.label) locked to \(locked.label)"
                }
            }
            fullFPS = Double((settings.resolution.lockedFrameRate ?? settings.frameRate).value)
        }

        // Idle preview: match the recording resolution + fps whenever possible
        // so pressing Record / Stop does not reconfigure the sensor (that was
        // the ~0.5s freeze + flicker). Only Longevity Mode / thermal throttle
        // still force a cooler lower-res idle path.
        let targetFPS: Double
        if forRecording {
            targetFPS = fullFPS
        } else if forceLowestIdlePreview || settings.longevityMode {
            let idleCapH = 720
            if dims.h > idleCapH {
                dims = Resolution.p720.captureDimensions
            }
            let idleFPSCap: Double = forceLowestIdlePreview ? 15.0 : 24.0
            targetFPS = min(fullFPS, idleFPSCap)
        } else {
            // Same dims + fps as recording → applyActiveFormat is a no-op when
            // starting/stopping (lastAppliedFormatKey matches).
            targetFPS = fullFPS
        }

        // Route format selection through the mode-specific policy so Video,
        // Slow-Mo, and Photo stay on separate code paths.
        // Photo live preview stays on a smooth video-sized format; full 12MP
        // stills use a brief swap inside capturePhoto().
        let policy = CaptureModePolicy(cameraMode: settings.cameraMode)
        let request = CaptureFormatRequest(width: dims.w, height: dims.h, fps: targetFPS, policy: policy)
        var format = CaptureModeFormatRouter.selectFormat(device: device, request: request)

        if format == nil && targetFPS == 60 {
            format = CameraFormatSelector.bestVideoFormat(for: device, width: dims.w, height: dims.h, fps: 30)
            if format != nil {
                DispatchQueue.main.async {
                    self.settings.frameRate = .fps30
                    self.notice = "60 fps unavailable · Switched to 30 fps"
                }
            }
        }

        guard let finalFormat = format else {
            if isSlow, let fallbackFormat = CameraFormatSelector.bestSlowMoFormat(for: device, fps: fullFPS) {
                let applyFPS = forRecording ? fullFPS : min(fullFPS, 30.0)
                let newKey = Self.formatKey(device: device, format: fallbackFormat, fps: applyFPS)
                var changed = false
                if newKey != lastAppliedFormatKey {
                    applyUnifiedHardwareConfiguration(to: device, format: fallbackFormat, targetFPS: applyFPS)
                    DispatchQueue.main.async {
                        let dDims = CMVideoFormatDescriptionGetDimensions(fallbackFormat.formatDescription)
                        let closestRes: Resolution = dDims.height >= 1080 ? .p1080 : .p720
                        self.settings.slowMoResolution = closestRes
                        self.notice = "\(self.settings.slowMoFrameRate.label) set to \(closestRes.label)"
                    }
                    refreshZoomLimits()
                    lastAppliedFormatKey = newKey
                    changed = true
                }
                configurePhotoOutput()
                DispatchQueue.main.async { self.volumeObserver?.ignoreTemporarily() }
                return changed
            }

            DispatchQueue.main.async {
                self.notice = "Format adjusted for this lens"
            }
            return false
        }

        let newKey = Self.formatKey(device: device, format: finalFormat, fps: targetFPS)
        var changed = false
        if newKey != lastAppliedFormatKey {
            applyUnifiedHardwareConfiguration(to: device, format: finalFormat, targetFPS: targetFPS)
            refreshZoomLimits()
            lastAppliedFormatKey = newKey
            changed = true
        }
        configurePhotoOutput()
        DispatchQueue.main.async { self.volumeObserver?.ignoreTemporarily() }
        return changed
    }

    func applyUnifiedHardwareConfiguration(to device: AVCaptureDevice, format: AVCaptureDevice.Format, targetFPS: Double) {
        do {
            try device.lockForConfiguration()
            
            // 1. Format & Frame Rate — lock min AND max to the same duration so
            // the sensor runs at a fixed rate (prevents VFR / under-target fps files).
            device.activeFormat = format

            let desiredFPS = max(1.0, targetFPS.rounded())
            // Exact 1/N second frame duration for integer fps (30, 60, 120, 240).
            // Using timescale == fps and value == 1 keeps the media timeline on
            // clean rationals so Photos reports 30.00 instead of 29.97/27.x when
            // every frame is written.
            let fpsInt = max(Int(desiredFPS), 1)
            var minDur = CMTime(value: 1, timescale: CMTimeScale(fpsInt))
            var maxDur = minDur
            if let range = format.videoSupportedFrameRateRanges.first(where: {
                $0.minFrameRate - 0.5 <= desiredFPS && desiredFPS <= $0.maxFrameRate + 0.5
            }) {
                let lo = range.minFrameDuration
                let hi = range.maxFrameDuration
                // minFrameDuration = duration of fastest rate; maxFrameDuration = slowest.
                if CMTimeCompare(minDur, lo) < 0 { minDur = lo }
                if CMTimeCompare(minDur, hi) > 0 { minDur = hi }
                maxDur = minDur
            }
            device.activeVideoMinFrameDuration = minDur
            device.activeVideoMaxFrameDuration = maxDur
            
            // 2. Autofocus — format switches can leave focus/exposure locked or
            // idle; re-enable continuous AF/AE so the viewfinder keeps tracking.
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = true
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.isSubjectAreaChangeMonitoringEnabled = false

            // 3. Pro Settings (Exposure & White Balance)
            let minBias = device.minExposureTargetBias
            let maxBias = device.maxExposureTargetBias
            let clampedBias = max(minBias, min(settings.exposureBias, maxBias))
            device.setExposureTargetBias(clampedBias, completionHandler: nil)

            if let values = settings.whiteBalance.kelvin {
                if device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                    let tempAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: values.temp, tint: values.tint)
                    var gains = device.deviceWhiteBalanceGains(for: tempAndTint)
                    let maxGain = device.maxWhiteBalanceGain
                    gains.redGain = max(1.0, min(gains.redGain.isFinite ? gains.redGain : 1.0, maxGain))
                    gains.greenGain = max(1.0, min(gains.greenGain.isFinite ? gains.greenGain : 1.0, maxGain))
                    gains.blueGain = max(1.0, min(gains.blueGain.isFinite ? gains.blueGain : 1.0, maxGain))
                    device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                }
            } else {
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            }

            // 4. Zoom — preserve the user's current factor across format switches
            // (idle ↔ record). Forcing baseline every time was the main cause
            // of the visible jump/flicker when pressing Record.
            let baseline = CameraFormatSelector.wideAngleBaseline(for: device)
            let ceiling = device.activeFormat.videoMaxZoomFactor
            let floor = device.minAvailableVideoZoomFactor
            let desiredRaw: CGFloat
            if self.zoomBaselineSnapshot > 0, self.zoomFactor > 0 {
                desiredRaw = self.zoomFactor * baseline
            } else {
                desiredRaw = max(baseline, floor)
            }
            device.videoZoomFactor = min(max(desiredRaw, floor), ceiling)

            device.unlockForConfiguration()
        } catch {
            DispatchQueue.main.async { self.notice = "Camera settings busy" }
        }
    }

    func updateCaptureFormat() {
        sessionQueue.async {
            self.refreshCapabilitiesThenApplyFormat()
        }
    }

    func refreshCapabilitiesThenApplyFormat() {
        ensureCorrectCameraDevice(for: settings.cameraMode)
        guard let device = cameraInput?.device else { return }

        let targetDims = settings.cameraMode == .slowMo
            ? settings.slowMoResolution.captureDimensions
            : settings.resolution.captureDimensions

        var rates = Set<FrameRate>()
        var widestPixels = 0
        var slowRates = Set<SlowMoFrameRate>()
        var slowResolutions = Set<Resolution>()

        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let h = Int(dims.height)
            widestPixels = max(widestPixels, Int(dims.width) * Int(dims.height))
            let meetsCurrentResolution = Int(dims.width) >= targetDims.w && Int(dims.height) >= targetDims.h
            if meetsCurrentResolution {
                for rate in FrameRate.allCases {
                    let fps = Double(rate.value)
                    if format.videoSupportedFrameRateRanges.contains(where: {
                        $0.minFrameRate <= (fps + 0.5) && (fps - 0.5) <= $0.maxFrameRate
                    }) {
                        rates.insert(rate)
                    }
                }
            }
            for range in format.videoSupportedFrameRateRanges {
                if range.maxFrameRate >= 119.0 {
                    slowRates.insert(.fps120)
                    if h >= 1080 { slowResolutions.insert(.p1080) }
                    if h >= 720 { slowResolutions.insert(.p720) }
                    if h >= 480 { slowResolutions.insert(.p480) }
                    slowResolutions.insert(.p320)
                    slowResolutions.insert(.p144)
                }
                if range.maxFrameRate >= 239.0 {
                    slowRates.insert(.fps240)
                    if h >= 1080 { slowResolutions.insert(.p1080) }
                    if h >= 720 { slowResolutions.insert(.p720) }
                    if h >= 480 { slowResolutions.insert(.p480) }
                    slowResolutions.insert(.p320)
                    slowResolutions.insert(.p144)
                }
            }
        }

        let supportedRates = FrameRate.allCases.filter { rates.contains($0) }
        let canDo1080 = widestPixels >= 1920 * 1080
        let canDo4K = widestPixels >= 3840 * 2160
        let supportedResolutions = Resolution.allCases.filter { res in
            switch res {
            case .p2160: return canDo4K
            case .p1080: return canDo1080
            default: return true
            }
        }
        // Slow-mo never uses 4K on this device class
        let supportedSlowRates = SlowMoFrameRate.allCases.filter { slowRates.contains($0) }
        let supportedSlowRes = Resolution.allCases.filter {
            $0 != .p2160 && slowResolutions.contains($0)
        }

        // Publish capability lists on main without blocking the session queue
        // (main.sync here previously risked deadlocks / hitches on A10).
        // Named finalRates to avoid shadowing `var rates = Set<FrameRate>()` above.
        let finalRates = supportedRates.isEmpty ? [FrameRate.fps30] : supportedRates
        let resolutions = supportedResolutions.isEmpty ? [Resolution.p720] : supportedResolutions
        let slowRatesOut = supportedSlowRates
        let slowResOut = supportedSlowRes.isEmpty ? [Resolution.p720] : supportedSlowRes
        let slowSupported = !supportedSlowRates.isEmpty

        DispatchQueue.main.async {
            self.availableFrameRates = finalRates
            self.availableResolutions = resolutions
            self.availableSlowMoRates = slowRatesOut
            self.availableSlowMoResolutions = slowResOut
            self.isSlowMoSupportedOnCurrentLens = slowSupported

            if !self.availableFrameRates.contains(self.settings.frameRate) {
                let fallback: FrameRate = self.availableFrameRates.contains(.fps30)
                    ? .fps30 : (self.availableFrameRates.first ?? .fps30)
                self.settings.frameRate = fallback
            }
            if !self.availableResolutions.contains(self.settings.resolution) {
                let fallback: Resolution = self.availableResolutions.first ?? .p720
                self.settings.resolution = fallback
            }
            // 4K locks to 30 fps
            if self.settings.resolution == .p2160, self.settings.frameRate != .fps30 {
                self.settings.frameRate = .fps30
            }

            if self.settings.cameraMode == .slowMo {
                if !self.isSlowMoSupportedOnCurrentLens {
                    self.notice = "Slow-Mo unavailable on front camera"
                    self.settings.cameraMode = .video
                } else if !self.availableSlowMoRates.contains(self.settings.slowMoFrameRate) {
                    self.settings.slowMoFrameRate = self.availableSlowMoRates.first ?? .fps120
                }
            }
        }

        // Default to preview (low-power) rate. Recording path will re-apply
        // the full target rate just before frames start flowing.
        applyActiveFormat(forRecording: false)
    }

    func syncMicInput() {
        // Audio is always required
        if !settings.recordAudio {
            settings.recordAudio = true
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                self?.addOrRemoveMic()
            }
            return
        }
        addOrRemoveMic()
    }

    func addOrRemoveMic() {
        sessionQueue.async {
            DispatchQueue.main.async { self.volumeObserver?.ignoreTemporarily() }
            let want = true // always record sound
            if want, self.micInput == nil {
                guard let mic = AVCaptureDevice.default(for: .audio),
                      let input = try? AVCaptureDeviceInput(device: mic) else { return }
                self.session.beginConfiguration()
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.micInput = input
                }
                self.session.commitConfiguration()
            } else if !want, let input = self.micInput {
                self.session.beginConfiguration()
                self.session.removeInput(input)
                self.session.commitConfiguration()
                self.micInput = nil
            }
        }
    }

    func flipCamera() {
        // Flipping mid-record is not supported (would tear down the writer
        // session). Guard is the single source of truth — no dead branches.
        guard !isRecording, !isSwitchingCamera else { return }

        DispatchQueue.main.async {
            self.isSwitchingCamera = true
            self.volumeObserver?.ignoreTemporarily(duration: 0.6)
        }
        setTorch(on: false)
        sessionQueue.async {
            let next: AVCaptureDevice.Position = (self.position == .back) ? .front : .back
            guard let device = Self.camera(at: next, mode: self.settings.cameraMode, preferPhysical: self.wantsPhysicalWideLens),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                DispatchQueue.main.async { self.isSwitchingCamera = false }
                return
            }

            // Minimal swap — same pattern as stock Camera. Avoid full capability
            // scan on the critical path (that was costing multi-second flips).
            self.session.beginConfiguration()
            if let old = self.cameraInput { self.session.removeInput(old) }
            if self.session.canAddInput(input) {
                self.session.addInput(input)
                self.cameraInput = input
                self.position = next
            } else if let old = self.cameraInput {
                self.session.addInput(old)
            }
            self.session.commitConfiguration()

            self.configureVideoConnection()
            // Light format apply only (no full device.formats walk).
            self.applyActiveFormat(forRecording: false)
            self.refreshTorchState()

            DispatchQueue.main.async {
                self.isFrontCamera = (next == .front)
                self.isSwitchingCamera = false
                self.volumeObserver?.ignoreTemporarily(duration: 0.4)
            }

            // Capabilities (front may lack 60 fps / slo-mo) update after UI unlocks.
            self.refreshCapabilitiesThenApplyFormat()
            self.resetFocusAndExposureToAuto()
        }
    }

    static func camera(at position: AVCaptureDevice.Position, mode: CameraMode, preferPhysical: Bool = false) -> AVCaptureDevice? {
        if position == .back && !preferPhysical {
            let virtualTypes: [AVCaptureDevice.DeviceType] = [
                .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera
            ]
            for type in virtualTypes {
                guard let device = AVCaptureDevice.default(type, for: .video, position: .back) else { continue }
                if mode == .slowMo && !supportsSlowMotion(device) { continue }
                return device
            }
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video)
    }

    static func supportsSlowMotion(_ device: AVCaptureDevice) -> Bool {
        device.formats.contains { format in
            format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 119.0 }
        }
    }

    var wantsPhysicalWideForFrameRate: Bool {
        settings.cameraMode == .video
            && false /* 60 fps removed for iPhone 7 focus */
    }

    var wantsPhysicalWideLens: Bool {
        wantsPhysicalWideForFrameRate
    }


}
