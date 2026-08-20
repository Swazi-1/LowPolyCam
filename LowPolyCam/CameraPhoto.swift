import AVFoundation
import UIKit
import Photos
import MediaPlayer
import CoreMotion
import Combine
import AudioToolbox
import ImageIO

extension CameraRecorder {

    // MARK: Photo Capture

    func capturePhoto() {
        guard !isCapturingPhoto, !isRecording, !isSwitchingCamera else { return }
        guard freeBytes > Self.reserveBytes else {
            notice = "Low storage · Free space needed"
            return
        }

        if settings.saveLocation == .photos { ensurePhotosAccess() }

        isCapturingPhoto = true

        if settings.hapticFeedbackEnabled {
            let hapticGen = UIImpactFeedbackGenerator(style: .medium)
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
        let rotationAngle = physicalOrientation.videoRotationAngle

        sessionQueue.async {
            // On iOS 15 the active format drives both preview AND still aspect
            // ratio. A smooth 16:9 1080p preview only yields ~9MP stills.
            // Briefly switch to a format with full 4:3 12MP still dimensions
            // for the capture, then restore the preview format so the live
            // view stays sharp (not pixelated) the rest of the time.
            var didSwapForStill = false
            if #available(iOS 16.0, *) {
                // iOS 16+ uses maxPhotoDimensions; no format swap needed.
            } else if let device = self.cameraInput?.device {
                let stillFormat = CameraFormatSelector.bestPhotoStillFormat(for: device, maxPreviewHeight: 1080, fps: 30)
                if let stillFormat = stillFormat {
                    let stillDims = stillFormat.highResolutionStillImageDimensions
                    let currentStill = device.activeFormat.highResolutionStillImageDimensions
                    let stillArea = Int(stillDims.width) * Int(stillDims.height)
                    let currentArea = Int(currentStill.width) * Int(currentStill.height)
                    if stillArea > currentArea + 500_000 {
                        self.applyUnifiedHardwareConfiguration(to: device, format: stillFormat, targetFPS: 30)
                        self.lastAppliedFormatKey = nil // force restore after
                        self.configurePhotoOutput()
                        didSwapForStill = true
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

                if #available(iOS 16.0, *) {
                    // AVCapturePhotoSettings.maxPhotoDimensions defaults to the
                    // *smallest* supported size, not the max. Explicitly request
                    // the full-sensor dimensions that configurePhotoOutput() set
                    // on the output, so we capture at true max resolution (e.g.
                    // 12MP). PhotoCaptureProcessor then downsamples to the user's
                    // chosen photoMegapixels target when encoding.
                    photoSettings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
                } else {
                    photoSettings.isHighResolutionPhotoEnabled = self.photoOutput.isHighResolutionCaptureEnabled
                }
                photoSettings.flashMode = .off
                // Match the live preview's rendering: request the same top quality
                // tier the output is configured for (Smart HDR / multi-frame fusion),
                // and let the system apply still-image stabilization if it decides
                // the scene needs it. Previously neither was set, so the discrete
                // still capture rendered flatter/darker than the live feed.
                if #available(iOS 13.0, *) {
                    photoSettings.photoQualityPrioritization = .quality
                }
                if self.photoOutput.isStillImageStabilizationSupported {
                    photoSettings.isAutoStillImageStabilizationEnabled = true
                }

                if let connection = self.photoOutput.connection(with: .video) {
                    // videoOrientation/isVideoMirrored are deprecated as of iOS 17 and
                    // are silently ignored on the photo connection there — the still
                    // then saves with the sensor's raw landscape buffer and EXIF
                    // orientation 1, which is the "rotated/flipped" photo bug. Use the
                    // replacement videoRotationAngle/isVideoMirrored(for photo) API
                    // when available, and only fall back to the old API pre-iOS 17.
                    if #available(iOS 17.0, *) {
                        if connection.isVideoRotationAngleSupported(rotationAngle) {
                            connection.videoRotationAngle = rotationAngle
                        }
                        if connection.isVideoMirroringSupported {
                            connection.automaticallyAdjustsVideoMirroring = false
                            connection.isVideoMirrored = mirrored
                        }
                    } else {
                        if connection.isVideoOrientationSupported {
                            connection.videoOrientation = orientation
                        }
                        if connection.isVideoMirroringSupported {
                            connection.automaticallyAdjustsVideoMirroring = false
                            connection.isVideoMirrored = mirrored
                        }
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
                    self.activePhotoProcessors.removeValue(forKey: photoSettings.uniqueID)

                    guard let image = image else {
                        DispatchQueue.main.async { self.notice = errorMessage ?? "Photo capture failed" }
                        return
                    }
                    self.savePhoto(image, originalData: originalData, metadata: metadata, to: destination)
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

    func savePhoto(_ image: UIImage, originalData: Data? = nil, metadata: [String: Any]?, to destination: SaveLocation) {
        DispatchQueue.main.async { self.lastPhotoThumbnail = image }

        // Prefer the camera's original file bytes when we did not downscale —
        // re-encoding HEIC makes photos look worse than stock Camera and can
        // even increase file size.
        let resolvedData: Data? = {
            if let originalData = originalData { return originalData }
            return PhotoEncoder.encodeHEIC(image, metadata: metadata)
                ?? PhotoEncoder.encodeJPEG(image, metadata: metadata)
        }()

        guard destination == .photos else {
            ioQueue.async {
                guard let data = resolvedData else {
                    DispatchQueue.main.async { self.notice = "Photo failed to save" }
                    return
                }
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                let isHEIC = (originalData != nil) || (PhotoEncoder.encodeHEIC(image, metadata: metadata) != nil)
                let ext = isHEIC ? "heic" : "jpg"
                let url = Self.clipsDirectory.appendingPathComponent("LowPolyCam_\(f.string(from: Date())).\(ext)")
                do {
                    try data.write(to: url, options: .atomic)
                    DispatchQueue.main.async {
                        self.notice = "Photo saved to Files"
                        self.refreshFreeSpace()
                    }
                } catch {
                    DispatchQueue.main.async { self.notice = "Photo failed to save" }
                }
            }
            return
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .authorized || status == .limited else {
            DispatchQueue.main.async { self.notice = "Enable Photos access in Settings to save" }
            return
        }

        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            if let data = resolvedData {
                request.addResource(with: .photo, data: data, options: options)
            }
        }) { [weak self] success, _ in
            DispatchQueue.main.async {
                self?.notice = success ? "Photo saved to Photos" : "Could not save photo"
            }
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
