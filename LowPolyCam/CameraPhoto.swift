import AVFoundation
import UIKit
import Photos
import MediaPlayer
import CoreMotion
import Combine
import AudioToolbox
import ImageIO

// MARK: - Photo 2.0 review model

/// One capture the post-shutter review sheet can show. Photos saved to the
/// app's own Files location have a stable on-disk `url` we can reload
/// directly; photos saved to the system Photos library do not (PHAsset
/// only), so those are represented purely by their in-memory `image`
/// (already downscaled/encoded the same as what was saved).
struct PhotoReviewItem: Identifiable, Equatable {
    let id = UUID()
    let image: UIImage
    let url: URL?
    let capturedAt = Date()

    static func == (lhs: PhotoReviewItem, rhs: PhotoReviewItem) -> Bool { lhs.id == rhs.id }
}

extension CameraRecorder {

    // MARK: Photo Capture

    /// Center-crops a full-frame still to a 1:1 square when the user has
    /// selected the Square aspect setting. No-op for `.full`. Runs on the
    /// already-downscaled image, so this is cheap even on A10.
    func applyPhotoAspect(_ image: UIImage) -> UIImage {
        guard settings.photoAspect == .square, let cg = image.cgImage else { return image }
        let w = cg.width
        let h = cg.height
        let side = min(w, h)
        guard side < w || side < h else { return image }
        let x = (w - side) / 2
        let y = (h - side) / 2
        guard let cropped = cg.cropping(to: CGRect(x: x, y: y, width: side, height: side)) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    func capturePhoto() {
        capturePhotoInternal(isBurstFrame: false, completion: nil)
    }

    func capturePhotoInternal(isBurstFrame: Bool, completion: (() -> Void)?) {
        guard !isCapturingPhoto, !isRecording, !isSwitchingCamera else {
            completion?()
            return
        }
        guard freeBytes > Self.reserveBytes else {
            notice = "Low storage · Free space needed"
            completion?()
            return
        }

        if settings.saveLocation == .photos { ensurePhotosAccess() }

        isCapturingPhoto = true

        // Burst frames skip the per-shot haptic (10-15 buzzes in ~1.5s feels
        // like a jackhammer, not a shutter) and use a single lighter tick
        // fired once from startBurstCapture's caller instead.
        if settings.hapticFeedbackEnabled && !isBurstFrame {
            let hapticGen = UIImpactFeedbackGenerator(style: settings.hapticIntensity.scaled(.medium))
            hapticGen.prepare()
            hapticGen.impactOccurred()
        }
        // NOTE: the shutter sound and screen flash are triggered from
        // PhotoCaptureProcessor's willBeginCapture callback (fired by
        // AVCapturePhotoOutput right as the sensor actually captures the
        // frame), not here. AVCapturePhotoOutput already plays its own
        // system shutter sound and a system screen-flash the instant
        // capturePhoto() is called; firing our own sound/flash here too
        // produced the "flashes twice / double shutter sound" bug. Doing
        // it from the delegate callback keeps everything to a single,
        // correctly-timed flash + click.

        // Honour the user's photoMegapixels setting (was previously hard-coded
        // to 12 and ignored the persisted preference). Capture is still done
        // at full sensor resolution; PhotoCaptureProcessor downsamples to
        // the chosen megapixel target when encoding.
        let targetMP = settings.photoMegapixels.megapixels
        let destination = settings.saveLocation
        // Front camera preview is mirrored by default (like a real mirror). Some people
        // want the SAVED photo mirrored back too (so text/writing reads correctly),
        // others want it saved exactly as the sensor sees it. New setting controls this.
        let mirrored = isFrontCamera && !settings.saveSelfiesUnmirrored
        let orientation = physicalOrientation.videoOrientation

        sessionQueue.async {
            // On iOS 15 the active format drives both preview AND still aspect
            // ratio. A smooth 16:9 1080p preview only yields ~9MP stills.
            // Briefly switch to a format with full 4:3 12MP still dimensions
            // for the capture, then restore the preview format so the live
            // view stays sharp (not pixelated) the rest of the time.
            var didSwapForStill = false
            if let device = self.cameraInput?.device {
                let stillFormat = CameraFormatSelector.bestPhotoStillFormat(for: device, maxPreviewHeight: 1080, fps: 30)
                if let stillFormat = stillFormat {
                    let stillDims = stillFormat.highResolutionStillImageDimensions
                    let currentStill = device.activeFormat.highResolutionStillImageDimensions
                    let stillArea = Int(stillDims.width) * Int(stillDims.height)
                    let currentArea = Int(currentStill.width) * Int(currentStill.height)
                    if stillArea > currentArea + 500_000 {
                        if self.applyUnifiedHardwareConfiguration(to: device, format: stillFormat, targetFPS: 30) {
                            self.lastAppliedFormatKey = nil // force restore after
                            self.configurePhotoOutput()
                            didSwapForStill = true
                        }
                    }
                }
            }

            let fireCapture: () -> Void = { [weak self] in
                guard let self = self else { return }

                var photoSettings: AVCapturePhotoSettings
                if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                    photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                } else {
                    photoSettings = AVCapturePhotoSettings()
                }

                photoSettings.isHighResolutionPhotoEnabled = self.photoOutput.isHighResolutionCaptureEnabled
                photoSettings.flashMode = .off
                // Match the live preview's rendering: request the same top quality
                // tier the output is configured for (Smart HDR / multi-frame fusion),
                // and let the system apply still-image stabilization if it decides
                // the scene needs it. Previously neither was set, so the discrete
                // still capture rendered flatter/darker than the live feed.
                photoSettings.photoQualityPrioritization = .quality
                if self.photoOutput.isStillImageStabilizationSupported {
                    photoSettings.isAutoStillImageStabilizationEnabled = true
                }

                if let connection = self.photoOutput.connection(with: .video) {
                    if connection.isVideoOrientationSupported {
                        connection.videoOrientation = orientation
                    }
                    if connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = mirrored
                    }
                }

                let shouldRestorePreview = didSwapForStill
                let processor = PhotoCaptureProcessor(targetMegapixels: targetMP, willCapture: { [weak self] in
                    guard let self = self else { return }
                    DispatchQueue.main.async {
                        if self.settings.shutterSoundEnabled { SoundPlayer.play(.shutter) }
                        self.onWillCapturePhoto?()
                    }
                }, completion: { [weak self] image, originalData, metadata, errorMessage in
                    guard let self = self else { return }
                    // Restore smooth preview format as soon as the still is done.
                    if shouldRestorePreview {
                        self.sessionQueue.async {
                            self.applyActiveFormat(forRecording: false)
                        }
                    }
                    DispatchQueue.main.async { self.isCapturingPhoto = false }
                    // The processor is registered on sessionQueue. Remove it on
                    // that same queue because AVCapturePhotoOutput may invoke this
                    // completion on a different thread.
                    self.sessionQueue.async {
                        self.activePhotoProcessors.removeValue(forKey: photoSettings.uniqueID)
                    }

                    guard let image = image else {
                        DispatchQueue.main.async { self.notice = errorMessage ?? "Photo capture failed" }
                        completion?()
                        return
                    }
                    // A non-nil originalData is the camera's own passthrough
                    // bytes (no re-downscale happened) — once we crop for
                    // Square aspect or force a different save format, those
                    // original bytes no longer match the image we're about
                    // to save, so they must not be used in that case.
                    let aspected = self.applyPhotoAspect(image)
                    let needsReencode = self.settings.photoAspect == .square || self.settings.photoFormat == .jpeg
                    self.savePhoto(aspected,
                                    originalData: needsReencode ? nil : originalData,
                                    metadata: metadata,
                                    to: destination,
                                    isBurstFrame: isBurstFrame,
                                    completion: completion)
                })
                self.activePhotoProcessors[photoSettings.uniqueID] = processor
                self.photoOutput.capturePhoto(with: photoSettings, delegate: processor)
            }

            // After a format swap, wait for AE to settle so the still isn't dark.
            if didSwapForStill, let device = self.cameraInput?.device {
                self.waitForExposureSettled(device: device, timeout: 0.25, completion: fireCapture)
            } else {
                fireCapture()
            }
        }
    }

    func savePhoto(_ image: UIImage,
                    originalData: Data? = nil,
                    metadata: [String: Any]?,
                    to destination: SaveLocation,
                    isBurstFrame: Bool = false,
                    completion: (() -> Void)? = nil) {
        DispatchQueue.main.async { self.lastPhotoThumbnail = image }

        // Prefer the camera's original file bytes when we did not downscale
        // AND the user's format setting still matches (HEIC) — re-encoding
        // otherwise makes photos look worse than stock Camera and can even
        // increase file size.
        let wantsJPEG = settings.photoFormat == .jpeg
        let encoded: (data: Data?, isHEIC: Bool) = {
            if !wantsJPEG, let originalData = originalData { return (originalData, true) }
            if wantsJPEG {
                return (PhotoEncoder.encodeJPEG(image, metadata: metadata), false)
            }
            if let data = PhotoEncoder.encodeHEIC(image, metadata: metadata) {
                return (data, true)
            }
            return (PhotoEncoder.encodeJPEG(image, metadata: metadata), false)
        }()
        let resolvedData = encoded.data

        func finishReview(url: URL?) {
            DispatchQueue.main.async {
                let item = PhotoReviewItem(image: image, url: url)
                if isBurstFrame {
                    self.lastBurstReviewItems.insert(item, at: 0)
                } else {
                    self.lastPhotoReviewItem = item
                    self.photoReviewToken += 1
                }
            }
            completion?()
        }

        guard destination == .photos else {
            ioQueue.async {
                guard let data = resolvedData else {
                    DispatchQueue.main.async { self.notice = "Photo failed to save" }
                    completion?()
                    return
                }
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                let ext = encoded.isHEIC ? "heic" : "jpg"
                // Seconds-only names can collide when two photos finish saving
                // quickly. A suffix guarantees the later atomic write cannot
                // silently replace the first photo.
                let suffix = String(format: "%04X", UInt16.random(in: 0...0xFFFF))
                let url = Self.clipsDirectory.appendingPathComponent("LowPolyCam_\(f.string(from: Date()))_\(suffix).\(ext)")
                do {
                    try data.write(to: url, options: .atomic)
                    DispatchQueue.main.async {
                        self.notice = isBurstFrame ? nil : "Photo saved to Files"
                        self.refreshFreeSpace()
                    }
                    finishReview(url: url)
                } catch {
                    DispatchQueue.main.async { self.notice = "Photo failed to save" }
                    completion?()
                }
            }
            return
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .authorized || status == .limited else {
            DispatchQueue.main.async { self.notice = "Enable Photos access in Settings to save" }
            completion?()
            return
        }

        guard let data = resolvedData else {
            DispatchQueue.main.async { self.notice = "Photo failed to save" }
            completion?()
            return
        }

        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            request.addResource(with: .photo, data: data, options: options)
        }) { [weak self] success, _ in
            DispatchQueue.main.async {
                self?.notice = isBurstFrame ? nil : (success ? "Photo saved to Photos" : "Could not save photo")
            }
            // Photos-library saves have no stable local file URL to reopen
            // for review — the sheet falls back to showing the in-memory
            // `image` only (see PhotoReviewItem.url == nil handling in the UI).
            finishReview(url: nil)
        }
    }

    /// Standard QuickTime metadata (make, model, software, creation date) so
    /// recorded clips show device info in the Photos app's "ⓘ" panel, the
    /// same fields the stock Camera app writes.
    static func captureMetadataItems() -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []

        func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = identifier
            m.value = value as NSString
            m.dataType = kCMMetadataBaseDataType_UTF8 as String
            return m
        }

        items.append(item(.quickTimeMetadataMake, "Apple"))
        items.append(item(.quickTimeMetadataModel, UIDevice.current.modelIdentifier))
        items.append(item(.quickTimeMetadataSoftware, "LowPolyCam"))

        let iso8601 = ISO8601DateFormatter()
        items.append(item(.quickTimeMetadataCreationDate, iso8601.string(from: Date())))

        return items
    }


}
