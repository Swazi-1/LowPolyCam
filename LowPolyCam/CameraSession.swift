//
//  CameraSession.swift
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

    // MARK: Session setup

    func configureSession() {
        DebugLog.write("configureSession() start position=\(position) mode=\(settings.cameraMode)")
        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        if let device = Self.camera(at: position, mode: settings.cameraMode, preferPhysical: wantsPhysicalWideLens),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            cameraInput = input
            DebugLog.write("configureSession() camera input added: \(device.localizedName)")
        } else {
            DebugLog.write("❌ configureSession() failed to add camera input for position=\(position) mode=\(settings.cameraMode)")
        }

        // Idle delegates are detached, so this is mostly a defensive default.
        // Recording flips it off and uses a small bounded application queue so
        // a momentary encoder pause doesn't silently turn 240fps into ~210fps.
        videoOutput.alwaysDiscardsLateVideoFrames = VideoRecordingSystem.discardsLateFrames(isRecording: false)
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

        // Photo dimensions belong to the active camera format. Configure them
        // while the capture graph is still being assembled; changing them after
        // a live 4K60 format swap can make AVFoundation raise an exception.
        configurePhotoOutput(for: cameraInput?.device)
        session.commitConfiguration()

        configureVideoConnection()
        refreshCapabilitiesThenApplyFormat()
        refreshTorchState()
        resetFocusAndExposureToAuto()
        syncMicInput()
        DebugLog.write("configureSession() done")
    }

    // MARK: Photo Output Configuration

    func configurePhotoOutput(for device: AVCaptureDevice? = nil) {
        guard let device = device ?? cameraInput?.device else { return }

        photoOutput.maxPhotoQualityPrioritization = .quality
        if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
            Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
        }) {
            let current = photoOutput.maxPhotoDimensions
            if current.width != largest.width || current.height != largest.height {
                photoOutput.maxPhotoDimensions = largest
            }
        }
    }

    func configureVideoConnection() {
        guard let c = videoOutput.connection(with: .video) else { return }
        // iOS 17+: videoOrientation is deprecated — RotationCoordinator owns preview/output angles.
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
            // Stab at 120/240fps is not viable on A10 and can break the writer.
            let wantStab = settings.stabilization
                && settings.cameraMode != .photo
                && settings.cameraMode != .slowMo
            c.preferredVideoStabilizationMode = wantStab ? .auto : .off
        }
        Task { @MainActor in self.stabilizationSupported = supported }
    }

    func updateStabilization() {
        sessionQueue.async { self.applyStabilization() }
    }

    func ensureCorrectCameraDevice(for mode: CameraMode) {
        let targetDevice: AVCaptureDevice?
        if mode == .slowMo, position == .back {
            let requestedZoom = zoomFactor > 0 ? zoomFactor : 1
            targetDevice = slowMoPhysicalDevice(for: requestedZoom)
                ?? Self.camera(at: position, mode: mode, preferPhysical: true)
        } else {
            targetDevice = Self.camera(at: position, mode: mode, preferPhysical: wantsPhysicalWideLens)
        }
        guard let targetDevice else { return }
        switchCameraInput(to: targetDevice)
    }

    /// Slow-Mo needs explicit physical-lens routing on iPhone 11. Its virtual
    /// dual-wide device does not expose the high-frame-rate formats, so 0.5x
    /// cannot be reached by changing `videoZoomFactor` alone.
    func slowMoPhysicalDevice(for displayedZoom: CGFloat, resetToWide: Bool = false) -> AVCaptureDevice? {
        guard position == .back else {
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
        }
        let type: AVCaptureDevice.DeviceType = ZoomPolicy.useUltraWide(
            zoom: Double(displayedZoom),
            currentlyUltraWide: cameraInput?.device.deviceType == .builtInUltraWideCamera,
            reset: resetToWide)
            ? .builtInUltraWideCamera : .builtInWideAngleCamera
        guard let device = AVCaptureDevice.default(type, for: .video, position: .back) else { return nil }
        let dims = settings.slowMoResolution.captureDimensions
        let fps = Double(settings.slowMoFrameRate.value)
        return CameraFormatSelector.bestSlowMoAwareFormat(
            for: device, width: dims.w, height: dims.h, fps: fps
        ) == nil ? nil : device
    }

    func switchCameraInput(to targetDevice: AVCaptureDevice) {
        guard cameraInput?.device.uniqueID != targetDevice.uniqueID else { return }
        DebugLog.write("switchCameraInput() -> \(targetDevice.localizedName) mode=\(settings.cameraMode)")
        Task { @MainActor in self.volumeObserver?.ignoreTemporarily() }

        // Create and validate the replacement before removing the live input.
        // If input creation/configuration fails, preserving the old input keeps
        // the preview usable instead of leaving the session with no camera.
        guard let input = try? AVCaptureDeviceInput(device: targetDevice) else {
            DebugLog.write("❌ switchCameraInput() failed to create AVCaptureDeviceInput")
            Task { @MainActor in self.notice = "Could not switch camera" }
            return
        }

        session.beginConfiguration()
        let old = cameraInput
        if let old = old { session.removeInput(old) }
        if session.canAddInput(input) {
            session.addInput(input)
            cameraInput = input
            lastAppliedFormatKey = nil
            // The previous input may have left maxPhotoDimensions set to a
            // value the replacement lens cannot provide (notably 4K60 wide →
            // Photo dual-wide). Update it before committing the new graph.
            configurePhotoOutput(for: targetDevice)
        } else if let old = old, session.canAddInput(old) {
            // Restore the existing input if the replacement is rejected.
            session.addInput(old)
            configurePhotoOutput(for: old.device)
            DebugLog.write("❌ switchCameraInput() rejected new input, restored previous")
            Task { @MainActor in self.notice = "Could not switch camera" }
        } else {
            DebugLog.write("❌ switchCameraInput() rejected new input, no previous input to restore")
            Task { @MainActor in self.notice = "Could not switch camera" }
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
        Task { @MainActor in self.volumeObserver?.ignoreTemporarily() }
        ensureCorrectCameraDevice(for: settings.cameraMode)
        guard var device = cameraInput?.device else { return false }

        let isSlow = settings.cameraMode == .slowMo && isSlowMoSupportedOnCurrentLens
        var dims: (w: Int, h: Int)
        let fullFPS: Double

        if settings.cameraMode == .photo {
            // Photo preview must not inherit a persisted 4K60 video request.
            dims = (1920, 1080)
            fullFPS = 30
        } else if isSlow {
            let selectedRate: SlowMoFrameRate
            if !availableSlowMoRates.contains(settings.slowMoFrameRate) {
                let fallback = availableSlowMoRates.first ?? .fps120
                selectedRate = fallback
                Task { @MainActor in
                    self.settings.slowMoFrameRate = fallback
                }
            } else {
                selectedRate = settings.slowMoFrameRate
            }
            // Use the validated local value immediately. The published setting
            // update above is asynchronous because this runs on sessionQueue.
            fullFPS = Double(selectedRate.value)
            dims = settings.slowMoResolution.captureDimensions
        } else {
            dims = settings.resolution.captureDimensions
            if let locked = settings.resolution.lockedFrameRate, settings.frameRate != locked {
                Task { @MainActor in
                    self.settings.frameRate = locked
                    self.notice = "\(self.settings.resolution.label) locked to \(locked.label)"
                }
            }
            fullFPS = Double((settings.resolution.lockedFrameRate ?? settings.frameRate).value)
        }

        // Idle preview: match the recording resolution + fps whenever possible
        // so pressing Record / Stop does not reconfigure the sensor (that was
        // the ~0.5s freeze + flicker). PerformanceProfile decides when a
        // lighter idle format is worth the trade-off — Longevity Mode,
        // critical thermal, and (gently) constrained hardware all feed into
        // it. See PerformanceProfile.swift.
        var targetFPS: Double
        // Slow-Mo must run at its final high frame rate before the user taps
        // Record. Letting idle preview fall back to 30 fps forced a second
        // sensor renegotiation at record start, which produced the brief
        // flicker and unreliable first high-speed segment on iPhone 7.
        if forRecording || isSlow {
            targetFPS = fullFPS
        } else {
            let profile = PerformanceProfile.current(settings: settings, thermalState: thermalState)
            let cap = profile.idlePreviewCap(forceLowest: forceLowestIdlePreview)
            if let capRes = cap.resolution, dims.h > capRes.captureDimensions.h {
                dims = capRes.captureDimensions
            }
            targetFPS = min(fullFPS, cap.fps)
        }

        // Route format selection through the mode-specific policy so Video,
        // Slow-Mo, and Photo stay on separate code paths.
        // Photo live preview stays on a smooth video-sized format; full 12MP
        // stills use a brief swap inside capturePhoto().
        let policy = CaptureModePolicy(cameraMode: settings.cameraMode)
        let request = CaptureFormatRequest(width: dims.w, height: dims.h, fps: targetFPS, policy: policy)
        var format = CaptureModeFormatRouter.selectFormat(device: device, request: request)

        // Some virtual dual-wide devices expose 0.5x/1x switching but omit
        // their 4K60 format even though the physical wide camera supports it.
        // Route only that unsupported combination to the physical wide lens;
        // lower rates stay on the virtual device so 0.5x remains available.
        if format == nil,
           position == .back,
           settings.cameraMode == .video,
           targetFPS >= 59,
           let physicalWide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let physicalFormat = CaptureModeFormatRouter.selectFormat(device: physicalWide, request: request) {
            switchCameraInput(to: physicalWide)
            guard cameraInput?.device.uniqueID == physicalWide.uniqueID else { return false }
            device = physicalWide
            format = physicalFormat
        }

        if format == nil && targetFPS == 60 {
            format = CameraFormatSelector.bestVideoFormat(for: device, width: dims.w, height: dims.h, fps: 30)
            if format != nil {
                targetFPS = 30
                Task { @MainActor in
                    self.settings.frameRate = .fps30
                    self.notice = "60 fps unavailable · Switched to 30 fps"
                }
            }
        }

        guard let finalFormat = format else {
            if isSlow, let fallbackFormat = CameraFormatSelector.bestSlowMoFormat(for: device, fps: fullFPS) {
                let applyFPS = fullFPS
                let newKey = Self.formatKey(device: device, format: fallbackFormat, fps: applyFPS)
                var changed = false
                if newKey != lastAppliedFormatKey {
                    guard applyUnifiedHardwareConfiguration(to: device, format: fallbackFormat, targetFPS: applyFPS) else {
                        return false
                    }
                    Task { @MainActor in
                        let dDims = CMVideoFormatDescriptionGetDimensions(fallbackFormat.formatDescription)
                        let closestRes: Resolution = dDims.height >= 1080 ? .p1080 : .p720
                        self.settings.slowMoResolution = closestRes
                        self.notice = "\(self.settings.slowMoFrameRate.label) set to \(closestRes.label)"
                    }
                    refreshZoomLimits()
                    lastAppliedFormatKey = newKey
                    changed = true
                }
                Task { @MainActor in self.volumeObserver?.ignoreTemporarily() }
                return changed
            }

            Task { @MainActor in
                self.notice = "Format adjusted for this lens"
            }
            return false
        }

        let newKey = Self.formatKey(device: device, format: finalFormat, fps: targetFPS)
        var changed = false
        if newKey != lastAppliedFormatKey {
            guard applyUnifiedHardwareConfiguration(to: device, format: finalFormat, targetFPS: targetFPS) else {
                return false
            }
            refreshZoomLimits()
            lastAppliedFormatKey = newKey
            changed = true
        }
        Task { @MainActor in self.volumeObserver?.ignoreTemporarily() }
        return changed
    }

    @discardableResult
    func applyUnifiedHardwareConfiguration(to device: AVCaptureDevice, format: AVCaptureDevice.Format, targetFPS: Double) -> Bool {
        // Unsupported durations raise Objective-C exceptions, not Swift
        // errors. Validate before touching either the graph or the device.
        guard targetFPS.isFinite, targetFPS > 0,
              format.videoSupportedFrameRateRanges.contains(where: {
                  $0.minFrameRate - 0.5 <= targetFPS && targetFPS <= $0.maxFrameRate + 0.5
              }) else {
            Task { @MainActor in self.notice = "This camera format does not support the requested frame rate" }
            return false
        }
        // AVFoundation batches active-format and duration changes atomically;
        // the preview sees one graph update instead of partially-applied state.
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            
            // 1. Format & Frame Rate — lock min AND max to the same duration so
            // the sensor runs at a fixed rate (prevents VFR / under-target fps files).
            device.activeFormat = format
            if format.supportedColorSpaces.contains(.sRGB) { device.activeColorSpace = .sRGB }
            focusGeneration += 1
            exposureGeneration += 1
            // Keep the photo output's dimensions in the same atomic session
            // transaction as its backing format. This avoids the 4K60 crash
            // caused by briefly pairing an old still dimension with a new
            // video format on iPhone 11-class cameras.
            configurePhotoOutput(for: device)

            let desiredFPS = max(1.0, targetFPS.rounded())
            // Automatic low-light frame-rate switching conflicts with an exact
            // min/max duration. Changing activeFormat resets it, then we keep it
            // explicitly disabled so 240 means a fixed sensor cadence.
            if format.isAutoVideoFrameRateSupported {
                device.isAutoVideoFrameRateEnabled = false
            }

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

            let actualDuration = device.activeVideoMinFrameDuration.seconds
            let actualFPS = actualDuration > 0 ? 1.0 / actualDuration : 0
            DebugLog.write(String(format: "[sensor] requested %.2ffps, active %.2ffps", desiredFPS, actualFPS))
            Task { @MainActor in
                self.activeSensorFPS = actualFPS
                if abs(actualFPS - desiredFPS) > 0.75 {
                    self.notice = String(format: "Camera negotiated %.0f fps", actualFPS)
                }
            }
            
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
            Task { @MainActor in self.focusLocked = false; self.exposureLocked = false }
            device.isSubjectAreaChangeMonitoringEnabled = true

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

            return true
        } catch {
            DebugLog.write("❌ applyActiveFormat() lockForConfiguration failed: \(error.localizedDescription)")
            Task { @MainActor in self.notice = "Camera settings busy" }
            return false
        }
    }

    func updateCaptureFormat(completion: (() -> Void)? = nil) {
        sessionQueue.async {
            self.refreshCapabilitiesThenApplyFormat(completion: completion)
        }
    }

    func refreshCapabilitiesThenApplyFormat(completion: (() -> Void)? = nil) {
        DebugLog.write("refreshCapabilitiesThenApplyFormat() mode=\(settings.cameraMode) position=\(position)")
        ensureCorrectCameraDevice(for: settings.cameraMode)
        guard let device = cameraInput?.device else {
            DebugLog.write("❌ refreshCapabilitiesThenApplyFormat() no cameraInput.device after ensureCorrectCameraDevice")
            Task { @MainActor in completion?() }
            return
        }

        let targetDims = settings.cameraMode == .slowMo
            ? settings.slowMoResolution.captureDimensions
            : settings.resolution.captureDimensions

        var rates = Set<FrameRate>()
        var widestPixels = 0
        // Per-resolution slow-mo FPS support (key fix for Bug 2).
        var slowByRes: [Resolution: Set<SlowMoFrameRate>] = [:]
        var slowResolutions = Set<Resolution>()
        // Per-resolution *video* FPS support. Built the same way as `slowByRes`
        // below: a resolution's supported rates only ever grow from a full scan
        // of every format, independent of whichever resolution is currently
        // selected. Without this, `rates` (scoped to `targetDims`, i.e. the
        // resolution active *right now*) got stored as if it were the device's
        // entire fps capability — so recording 4K (30 fps only on this device
        // class) permanently wiped 60 fps from the list for every resolution,
        // including 1080p/720p which really do support it.
        var ratesByRes: [Resolution: Set<FrameRate>] = [:]

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

            // Same rate test as above, but recorded against every standard
            // resolution this format actually covers, not just `targetDims`.
            var ratesForThisVideoFormat = Set<FrameRate>()
            for rate in FrameRate.allCases {
                let fps = Double(rate.value)
                if format.videoSupportedFrameRateRanges.contains(where: {
                    $0.minFrameRate <= (fps + 0.5) && (fps - 0.5) <= $0.maxFrameRate
                }) {
                    ratesForThisVideoFormat.insert(rate)
                }
            }
            if !ratesForThisVideoFormat.isEmpty {
                var coveredRes: [Resolution] = []
                if h >= 2160 { coveredRes.append(.p2160) }
                if h >= 1080 { coveredRes.append(.p1080) }
                if h >= 720 { coveredRes.append(.p720) }
                if h >= 480 { coveredRes.append(.p480) }
                coveredRes.append(.p320)
                coveredRes.append(.p144)
                for res in coveredRes {
                    ratesByRes[res, default: []].formUnion(ratesForThisVideoFormat)
                }
            }

            // Map each high-FPS format to the resolutions it can actually deliver.
            // A format whose active dimensions are only 720p must not advertise
            // 240 fps as available for 1080p.
            var ratesForThisFormat = Set<SlowMoFrameRate>()
            for range in format.videoSupportedFrameRateRanges {
                if range.maxFrameRate >= 119.0 { ratesForThisFormat.insert(.fps120) }
                if range.maxFrameRate >= 239.0 { ratesForThisFormat.insert(.fps240) }
            }
            guard !ratesForThisFormat.isEmpty else { continue }

            // Resolutions this format can cover (sensor height threshold).
            var resForFormat: [Resolution] = []
            if h >= 1080 { resForFormat.append(.p1080) }
            if h >= 720 { resForFormat.append(.p720) }
            if h >= 480 { resForFormat.append(.p480) }
            // Lower tiers are always reachable via downscale from a higher format.
            resForFormat.append(.p320)
            resForFormat.append(.p144)

            for res in resForFormat {
                slowResolutions.insert(res)
                slowByRes[res, default: []].formUnion(ratesForThisFormat)
            }
        }

        // Advertise normal-video rates supplied by a virtual camera's
        // constituent lenses too. This is what makes 4K60 selectable on
        // iPhone 11 when the dual-wide virtual device itself only lists 4K30.
        if settings.cameraMode != .slowMo {
            for constituent in device.constituentDevices {
                for format in constituent.formats {
                    let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    let h = Int(dims.height)
                    let formatRates = FrameRate.allCases.filter { rate in
                        let fps = Double(rate.value)
                        return format.videoSupportedFrameRateRanges.contains {
                            $0.minFrameRate <= fps + 0.5 && $0.maxFrameRate >= fps - 0.5
                        }
                    }
                    var covered: [Resolution] = []
                    if h >= 2160 { covered.append(.p2160) }
                    if h >= 1080 { covered.append(.p1080) }
                    if h >= 720 { covered.append(.p720) }
                    if h >= 480 { covered.append(.p480) }
                    covered.append(contentsOf: [.p320, .p144])
                    for resolution in covered {
                        ratesByRes[resolution, default: []].formUnion(formatRates)
                    }
                }
            }
            let selectedResolution = settings.resolution
            if let constituentRates = ratesByRes[selectedResolution] {
                rates.formUnion(constituentRates)
            }
        }

        let supportedRates = FrameRate.allCases.filter { rates.contains($0) }
        let isFront = (device.position == .front)
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
        let supportedSlowRes = Resolution.allCases.filter {
            $0 != .p2160 && slowResolutions.contains($0)
        }

        // Scope available FPS to the currently selected slow-mo resolution.
        let selectedSlowRes = settings.slowMoResolution
        let ratesForSelected = slowByRes[selectedSlowRes] ?? []
        let supportedSlowRates = SlowMoFrameRate.allCases.filter { ratesForSelected.contains($0) }

        // Max still-photo megapixels for this lens (front is often ~7 MP).
        let maxStillPixels: Int = device.formats.map { format in
            let d = format.largestStillDimensions
            return Int(d.width) * Int(d.height)
        }.max() ?? 0
        let maxMP = Double(maxStillPixels) / 1_000_000.0
        // Allow a small tolerance so e.g. 11.9 MP still counts as 12 MP.
        let supportedPhotoMP = PhotoMegapixels.allCases.filter { $0.megapixels <= maxMP + 0.5 }

        let finalRates = supportedRates.isEmpty ? [FrameRate.fps30] : supportedRates
        let resolutions = supportedResolutions.isEmpty ? [Resolution.p720] : supportedResolutions
        let slowRatesOut = supportedSlowRates
        let slowResOut = supportedSlowRes.isEmpty ? [Resolution.p720] : supportedSlowRes
        let slowSupported = !slowByRes.isEmpty
        let photoMPOut = supportedPhotoMP.isEmpty ? [PhotoMegapixels.mp2] : supportedPhotoMP
        let slowByResOut = slowByRes
        let ratesByResOut = ratesByRes

        let previousPosition = lastCapabilitiesCameraPosition
        lastCapabilitiesCameraPosition = device.position
        Task { @MainActor in
            self.activeSensorFPS = 0
            self.availableFrameRates = finalRates
            self.availableResolutions = resolutions
            self.availableSlowMoRates = slowRatesOut
            self.availableSlowMoResolutions = slowResOut
            self.slowRatesByResolution = slowByResOut
            self.frameRatesByResolution = ratesByResOut
            self.isSlowMoSupportedOnCurrentLens = slowSupported
            self.availablePhotoMegapixels = photoMPOut

            if !self.availableFrameRates.contains(self.settings.frameRate) {
                let fallback: FrameRate = self.availableFrameRates.contains(.fps30)
                    ? .fps30 : (self.availableFrameRates.first ?? .fps30)
                self.settings.frameRate = fallback
            }
            if !self.availableResolutions.contains(self.settings.resolution) {
                let fallback: Resolution = self.availableResolutions.first ?? .p720
                self.settings.resolution = fallback
            }
            // Front iPhone cameras have a smaller still sensor. Do not let
            // that temporary 8MP limit overwrite the user's rear-camera
            // choice (normally 12MP) when switching lenses.
            if previousPosition == .back && isFront {
                self.rearPhotoMegapixelsBeforeFront = self.settings.photoMegapixels
            }
            if previousPosition == .front && !isFront,
               let saved = self.rearPhotoMegapixelsBeforeFront,
               self.availablePhotoMegapixels.contains(saved) {
                self.settings.photoMegapixels = saved
                self.rearPhotoMegapixelsBeforeFront = nil
            } else if !self.availablePhotoMegapixels.contains(self.settings.photoMegapixels) {
                self.settings.photoMegapixels = self.availablePhotoMegapixels.max(by: { $0.megapixels < $1.megapixels }) ?? .mp2
            }

            if self.settings.cameraMode == .slowMo {
                if !self.isSlowMoSupportedOnCurrentLens {
                    self.notice = "Slow-Mo unavailable on front camera"
                    self.settings.cameraMode = .video
                } else {
                    if !self.availableSlowMoResolutions.contains(self.settings.slowMoResolution) {
                        self.settings.slowMoResolution = self.availableSlowMoResolutions.first ?? .p720
                    }
                    // Re-scope FPS to (possibly updated) resolution.
                    let scoped = self.slowRatesByResolution[self.settings.slowMoResolution] ?? []
                    let scopedList = SlowMoFrameRate.allCases.filter { scoped.contains($0) }
                    self.availableSlowMoRates = scopedList
                    if !scopedList.contains(self.settings.slowMoFrameRate) {
                        self.settings.slowMoFrameRate = scopedList.first ?? .fps120
                    }
                }
            }

            // Apply only after the published mode/rate fallbacks above have
            // completed. The previous immediate call raced this MainActor
            // block, which is why the HUD could say 30 or keep a yellow 240
            // while the sensor was already running at another slow-mo rate.
            self.sessionQueue.async {
                self.applyActiveFormat(forRecording: false)
                let finish: () -> Void = {
                    self.waitForPreviewFrame(completion: completion)
                }
                if let appliedDevice = self.cameraInput?.device {
                    self.waitForExposureSettled(device: appliedDevice, timeout: 0.25, completion: finish)
                } else {
                    finish()
                }
            }
        }
    }

    func syncMicInput() {
        if settings.recordAudio && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            Task { [weak self] in
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                self?.addOrRemoveMic()
            }
            return
        }
        addOrRemoveMic()
    }

    func addOrRemoveMic() {
        sessionQueue.async {
            Task { @MainActor in self.volumeObserver?.ignoreTemporarily() }
            let want = self.settings.recordAudio && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
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
        guard !isRecording, !isStartingRecording, !isSaving, !isCapturingPhoto,
              !isBursting, !isSwitchingMode, !isSwitchingCamera else { return }

        let finishFlipUI: () -> Void = {
            Task { @MainActor in
                // Use the actual position: input replacement can fail and the
                // previous camera is restored in that case.
                self.isFrontCamera = (self.position == .front)
                self.isSwitchingCamera = false
                // Kept up to date on every flip regardless of whether "Keep
                // last camera" is on, so the value is ready the instant that
                // toggle gets turned on — it's only *applied* at launch.
                self.settings.lastCameraPosition = CameraFacing(self.position)
                // Restarting samples the current system volume and ignores the
                // initial KVO noise, so a camera-input swap cannot be mistaken
                // for a volume-button shutter press.
                self.resumeVolumeMonitoring()
            }
        }

        let beginFlip: () -> Void = {
            // The volume observer can receive a KVO change while AVFoundation
            // swaps camera inputs. Fully stop it for the transaction rather
            // than merely ignoring a fixed time window.
            self.volumeObserver?.stop()
            self.isSwitchingCamera = true
            self.setTorch(on: false)
            self.sessionQueue.async {
                let next: AVCaptureDevice.Position = (self.position == .back) ? .front : .back
                DebugLog.write("flipCamera() \(self.position) -> \(next) mode=\(self.settings.cameraMode)")
                guard let device = Self.camera(at: next, mode: self.settings.cameraMode, preferPhysical: self.wantsPhysicalWideLens),
                      let input = try? AVCaptureDeviceInput(device: device) else {
                    DebugLog.write("❌ flipCamera() could not resolve/create input for \(next)")
                    finishFlipUI()
                    return
                }

                // Minimal swap — same pattern as stock Camera.
                self.session.beginConfiguration()
                let old = self.cameraInput
                if let old = old { self.session.removeInput(old) }
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.cameraInput = input
                    self.position = next
                    self.configurePhotoOutput(for: device)
                    self.lastAppliedFormatKey = nil
                } else if let old = old, self.session.canAddInput(old) {
                    // Restore the previous camera if the replacement is rejected.
                    self.session.addInput(old)
                    DebugLog.write("❌ flipCamera() new input rejected, restored previous")
                    Task { @MainActor in self.notice = "Could not switch camera" }
                } else {
                    DebugLog.write("❌ flipCamera() new input rejected, no previous input to restore")
                    Task { @MainActor in self.notice = "Could not switch camera" }
                }
                self.session.commitConfiguration()

                self.configureVideoConnection()
                self.refreshTorchState()

                // Capability scan + format apply before volume shutter resumes.
                self.refreshCapabilitiesThenApplyFormat(completion: finishFlipUI)
                self.resetFocusAndExposureToAuto()
                DebugLog.write("flipCamera() done, position=\(self.position)")
            }
        }

        if Thread.isMainThread {
            beginFlip()
        } else {
            DispatchQueue.main.async(execute: beginFlip)
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
        false
    }

    var wantsPhysicalWideLens: Bool {
        wantsPhysicalWideForFrameRate
    }


}
