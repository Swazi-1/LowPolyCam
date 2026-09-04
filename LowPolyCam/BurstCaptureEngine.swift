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

        if settings.saveLocation == .photos { ensurePhotosAccess() }
        if settings.shutterSoundEnabled { SoundPlayer.play(.shutter) }
        // Same audio-route/KVO-noise guard used in capturePhoto()/startRecording() —
        // this burst's own shutter sound could otherwise misread as an extra
        // volume-button press partway through.
        suppressVolumeTriggerBriefly(duration: 1.2)

        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let begin = { [weak self] in
                Task { @MainActor in self?.captureNextHighResolutionBurstFrame() }
            }

            // Switch to the highest still-capable format once for the whole
            // burst, then restore the lightweight preview format at the end.
            guard let device = self.cameraInput?.device,
                  let stillFormat = CameraFormatSelector.bestPhotoStillFormat(for: device, maxPreviewHeight: 1080, fps: 30)
            else {
                begin()
                return
            }

            let current = device.activeFormat.largestStillDimensions
            let target = stillFormat.largestStillDimensions
            let needsSwitch = Int(target.width) * Int(target.height) > Int(current.width) * Int(current.height) + 500_000
            guard needsSwitch else {
                begin()
                return
            }
            guard self.applyUnifiedHardwareConfiguration(to: device, format: stillFormat, targetFPS: 30) else {
                begin()
                return
            }

            self.lastAppliedFormatKey = nil
            self.configurePhotoOutput()
            self.waitForExposureSettled(device: device, timeout: 0.25, completion: begin)
        }
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
                self.burstShotsTaken += 1

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
