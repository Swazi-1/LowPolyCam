```swift
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
        guard !isBursting, !isCapturingPhoto, !isRecording, !isSwitchingCamera else { return }
        guard freeBytes > Self.reserveBytes else {
            notice = "Low storage · Free space needed"
            return
        }

        burstShotsTaken = 0
        burstShotsTotal = settings.burstCount.rawValue
        burstCancellationRequested = false
        lastBurstReviewItems = []
        isBursting = true

        if settings.saveLocation == .photos {
            ensurePhotosAccess()
        }

        if settings.shutterSoundEnabled {
            SoundPlayer.play(.shutter)
        }

        suppressVolumeTriggerBriefly(duration: 1.2)

        sessionQueue.async { [weak self] in
            self?.prepareBurstCapture()
        }
    }

    private func prepareBurstCapture() {
        let begin: () -> Void = { [weak self] in
            Task { @MainActor in
                self?.captureNextHighResolutionBurstFrame()
            }
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

        let currentDimensions = device.activeFormat.largestStillDimensions
        let targetDimensions = stillFormat.largestStillDimensions

        let currentWidth = Int(currentDimensions.width)
        let currentHeight = Int(currentDimensions.height)
        let targetWidth = Int(targetDimensions.width)
        let targetHeight = Int(targetDimensions.height)

        let currentPixels = currentWidth * currentHeight
        let targetPixels = targetWidth * targetHeight
        let switchThreshold = currentPixels + 500_000
        let needsSwitch = targetPixels > switchThreshold

        guard needsSwitch else {
            begin()
            return
        }

        guard applyUnifiedHardwareConfiguration(
            to: device,
            format: stillFormat,
            targetFPS: 30
        ) else {
            begin()
            return
        }

        lastAppliedFormatKey = nil
        configurePhotoOutput()

        waitForExposureSettled(
            device: device,
            timeout: 0.25,
            completion: begin
        )
    }

    func cancelBurstCapture() {
        guard isBursting else { return }
        burstCancellationRequested = true
    }

    private func captureNextHighResolutionBurstFrame() {
        guard isBursting else { return }

        guard !burstCancellationRequested,
              burstShotsTaken < burstShotsTotal else {
            finishHighResolutionBurst()
            return
        }

        capturePhotoInternal(isBurstFrame: true) { [weak self] in
            Task { @MainActor in
                guard let self else { return }

                self.burstShotsTaken += 1

                if self.burstCancellationRequested ||
                    self.burstShotsTaken >= self.burstShotsTotal {
                    self.finishHighResolutionBurst()
                } else {
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
            guard let self else { return }
            _ = self.applyActiveFormat(forRecording: false)
        }

        if !lastBurstReviewItems.isEmpty {
            lastPhotoReviewItem = lastBurstReviewItems.first
            photoReviewToken += 1
        }
    }
}
```
