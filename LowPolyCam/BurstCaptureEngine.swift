//
//  BurstCaptureEngine.swift
//  LowPolyCam
//
//  Updated for iOS 27 / Xcode 27 / Swift 6.4.
//  Swift 6 complete concurrency · Observation · Liquid Glass · RotationCoordinator
//

import AVFoundation

// MARK: - Full-resolution burst capture

extension CameraRecorder {

    /// Captures a burst through AVCapturePhotoOutput, not the live video
    /// stream. This preserves the selected megapixel limit, correct 4:3 photo
    /// aspect, mirroring, and orientation on both iPhone 7 cameras.
    func startBurstCapture() {
        guard isSessionRunning, !isBursting, !isCapturingPhoto, !isRecording,
              !isStartingRecording, !isSaving, !isSwitchingMode, !isSwitchingCamera else { return }
        guard freeBytes > Self.reserveBytes else {
            notice = "Low storage · Free space needed"
            return
        }

        burstShotsTaken = 0
        burstShotsTotal = settings.burstCount.rawValue
        burstCancellationRequested = false
        lastBurstReviewItems = []
        isBursting = true

        if settings.saveLocation == .photos { ensurePhotosAccess() }
        if settings.shutterSoundEnabled { SoundPlayer.play(.shutter) }
        // Same audio-route/KVO-noise guard used in capturePhoto()/startRecording() —
        // this burst's own shutter sound could otherwise misread as an extra
        // volume-button press partway through.
        suppressVolumeTriggerBriefly(duration: 1.2)

        sessionQueue.async { [weak self] in
            self?.prepareAndBeginBurstCapture()
        }
    }

    /// Runs on `sessionQueue`. Switches to the highest still-capable format
    /// once for the whole burst (if needed), then restores the lightweight
    /// preview format at the end via `begin()`.
    private func prepareAndBeginBurstCapture() {
        let begin: () -> Void = { [weak self] in
            Task { @MainActor in self?.captureNextHighResolutionBurstFrame() }
        }

        guard let device = cameraInput?.device else {
            begin()
            return
        }
        let stillFormat = CameraFormatSelector.bestPhotoStillFormat(
            for: device,
            maxPreviewHeight: 1080,
            fps: 30
        )
        guard let stillFormat else {
            begin()
            return
        }

        guard formatIncreasesStillResolution(from: device.activeFormat, to: stillFormat) else {
            begin()
            return
        }
        guard applyUnifiedHardwareConfiguration(to: device, format: stillFormat, targetFPS: 30) else {
            begin()
            return
        }

        lastAppliedFormatKey = nil
        waitForExposureSettled(device: device, timeout: 0.25, completion: begin)
    }

    /// Whether `target`'s still-image resolution is meaningfully larger than
    /// `current`'s (broken out into typed sub-expressions so the type
    /// checker doesn't have to solve one large mixed-type expression).
    private func formatIncreasesStillResolution(
        from current: AVCaptureDevice.Format,
        to target: AVCaptureDevice.Format
    ) -> Bool {
        let currentDimensions = current.largestStillDimensions
        let targetDimensions = target.largestStillDimensions

        let currentWidth: Int = Int(currentDimensions.width)
        let currentHeight: Int = Int(currentDimensions.height)
        let targetWidth: Int = Int(targetDimensions.width)
        let targetHeight: Int = Int(targetDimensions.height)

        let currentPixelCount: Int = currentWidth * currentHeight
        let targetPixelCount: Int = targetWidth * targetHeight
        let threshold: Int = 500_000

        return targetPixelCount > currentPixelCount + threshold
    }

    /// Ends a burst after its current still has completed, rather than
    /// cancelling AVCapturePhotoOutput halfway through a capture.
    func cancelBurstCapture() {
        guard isBursting else { return }
        burstCancellationRequested = true
    }

    private func captureNextHighResolutionBurstFrame() {
        guard isBursting else { return }
        guard !burstCancellationRequested, burstShotsTaken < burstShotsTotal else {
            finishHighResolutionBurst()
            return
        }

        capturePhotoInternal(isBurstFrame: true) { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                let savedCount = self.lastBurstReviewItems.count
                guard savedCount > self.burstShotsTaken else {
                    self.finishHighResolutionBurst()
                    return
                }
                self.burstShotsTaken = savedCount

                if self.burstCancellationRequested || self.burstShotsTaken >= self.burstShotsTotal {
                    self.finishHighResolutionBurst()
                } else {
                    // Yield one turn between stills so the progress UI stays
                    // responsive and AVCapturePhotoOutput can re-arm cleanly.
                    Task { @MainActor in
                        self.captureNextHighResolutionBurstFrame()
                    }
                }
            }
        }
    }

    private func finishHighResolutionBurst() {
        guard isBursting else { return }
        isBursting = false
        burstCancellationRequested = false

        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            _ = self.applyActiveFormat(forRecording: false)
        }

        if !lastBurstReviewItems.isEmpty {
            lastPhotoReviewItem = lastBurstReviewItems.first
            photoReviewToken += 1
        }
    }
}
