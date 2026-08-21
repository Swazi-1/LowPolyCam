import AVFoundation
import UIKit
import Photos
import CoreImage

// MARK: - Photo 2.0: Fast Burst Capture
//
// WHY THIS FILE EXISTS
// ---------------------
// The first version of burst mode called AVCapturePhotoOutput.capturePhoto()
// N times in a row. Each call is a full discrete still-capture request —
// sensor re-arm, ISP processing, HEIC encode, disk/Photos write — before the
// next one can even start. That is the only burst mechanism most third-party
// camera tutorials use, and it is genuinely slow: on an A10 chip, 10 shots
// that way took several seconds.
//
// Stock Camera does not do that. It grabs frames straight off the live
// sensor/video stream at close to sensor frame rate, buffers the raw pixel
// data, and defers the expensive HEIC encode + Photos write until after
// (sometimes you'll see "Processing…" in Photos right after a stock burst —
// that's this same deferred-encode idea).
//
// This file reimplements burst mode the same way: attach a lightweight
// AVCaptureVideoDataOutputSampleBufferDelegate for the duration of the
// burst only, grab CVPixelBuffers as fast as they arrive (no per-frame
// encode/save in the hot path), then encode + save everything afterward.
// Capturing N frames this way is bounded by sensor fps (up to ~30fps evens
// in Photo mode's idle preview format), not by the multi-hundred-ms cost of
// a full discrete still capture — which is how stock Camera gets ~10 shots
// in about a second.
//
// This intentionally does NOT touch CameraRecorder's video-recording writer
// state (writer/videoIn/segmentStart/etc in CameraRecorder.swift +
// CameraSampleBuffers.swift) — it uses its own tiny delegate object so it
// can never interfere with an actual video recording's AVAssetWriter session.

/// Owns the temporary video-frame delegate used only while a burst is being
/// captured. Kept as a small standalone object (not CameraRecorder itself)
/// so it can be attached/detached from `videoOutput` without going anywhere
/// near the recording pipeline's own delegate wiring.
final class BurstFrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let targetCount: Int
    private let onFrame: (CVPixelBuffer) -> Void
    private let onComplete: () -> Void
    private var collected = 0
    private let lock = NSLock()
    private var finished = false

    init(targetCount: Int, onFrame: @escaping (CVPixelBuffer) -> Void, onComplete: @escaping () -> Void) {
        self.targetCount = targetCount
        self.onFrame = onFrame
        self.onComplete = onComplete
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lock.lock()
        guard !finished else { lock.unlock(); return }
        collected += 1
        let isDone = collected >= targetCount
        if isDone { finished = true }
        lock.unlock()

        // CVPixelBuffer from a live video connection is only valid to keep
        // using past this callback if retained — CVPixelBufferRetain isn't
        // needed here because CVPixelBuffer is a CF type bridged to a Swift
        // class-like reference; holding the Swift reference keeps the
        // backing IOSurface alive. Copying to a fresh pixel buffer per frame
        // (below, via CIImage → new UIImage at save time) means we never
        // hold the pool's buffer itself for long, which matters because the
        // video connection's pool is small and reused frame to frame.
        onFrame(pixelBuffer)

        if isDone { onComplete() }
    }

    /// Manual cutoff for a user-cancelled burst (fewer than targetCount
    /// frames arrived). Safe to call more than once.
    func stopEarly() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        onComplete()
    }
}

extension CameraRecorder {

    /// Starts a fast burst: attaches a temporary frame grabber to the
    /// already-running video output, collects `settings.burstCount` frames
    /// as fast as the sensor delivers them (no per-frame encode/save while
    /// collecting), then detaches and encodes/saves everything in one pass.
    func startBurstCapture() {
        guard !isBursting, !isCapturingPhoto, !isRecording, !isSwitchingCamera else { return }
        guard freeBytes > Self.reserveBytes else {
            notice = "Low storage · Free space needed"
            return
        }

        let total = settings.burstCount.rawValue
        isBursting = true
        burstShotsTaken = 0
        burstShotsTotal = total
        lastBurstReviewItems = []

        if settings.saveLocation == .photos { ensurePhotosAccess() }
        if settings.shutterSoundEnabled { SoundPlayer.play(.shutter) }

        // Snapshot everything the frame callback needs up front — it fires
        // on videoQueue, off the main thread, and must not touch
        // `settings`/`self` properties that could change mid-burst.
        let mirrored = isFrontCamera && !settings.saveSelfiesUnmirrored
        let orientation = physicalOrientation.imageOrientation(mirrored: mirrored)
        let targetMP = settings.photoMegapixels.megapixels

        var collectedImages: [UIImage] = []
        collectedImages.reserveCapacity(total)
        let bufferLock = NSLock()
        // Own CIContext per burst — pixel-buffer → CGImage conversion happens
        // right in the frame callback (see onFrame below) so we hold each
        // frame for only as long as it takes to copy its pixels out, then
        // immediately let the video output's small buffer pool reclaim the
        // original CVPixelBuffer. Holding 10-15 raw CVPixelBuffers at once
        // would starve that pool and stall/drop the live frames still
        // arriving behind them.
        let frameContext = CIContext(options: [.useSoftwareRenderer: false])

        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            // Video output delegate is normally nil while idle (see
            // configureSession in CameraSession.swift) — attach it just for
            // this burst, on the same dedicated video queue recording uses,
            // so frame delivery has the same priority/behavior as it does
            // during an actual recording.
            let grabber = BurstFrameGrabber(
                targetCount: total,
                onFrame: { pixelBuffer in
                    // Copy pixels out to a UIImage immediately — see the
                    // comment on frameContext above for why this can't wait.
                    let image = Self.image(from: pixelBuffer,
                                            orientation: orientation,
                                            targetMegapixels: targetMP,
                                            context: frameContext)
                    bufferLock.lock()
                    if let image = image { collectedImages.append(image) }
                    let count = collectedImages.count
                    bufferLock.unlock()
                    DispatchQueue.main.async {
                        self.burstShotsTaken = count
                    }
                },
                onComplete: { [weak self] in
                    guard let self = self else { return }
                    self.sessionQueue.async {
                        self.videoOutput.setSampleBufferDelegate(
                            self.isRecording ? self : nil,
                            queue: self.isRecording ? self.videoQueue : nil
                        )
                        self.activeBurstGrabber = nil
                        bufferLock.lock()
                        let images = collectedImages
                        bufferLock.unlock()
                        self.finishBurst(images: images, destination: self.settings.saveLocation)
                    }
                }
            )
            self.activeBurstGrabber = grabber
            self.videoOutput.setSampleBufferDelegate(grabber, queue: self.videoQueue)
        }
    }

    /// Cancels an in-progress burst. Frames already grabbed are still
    /// encoded and saved — cancelling just stops collecting more.
    func cancelBurstCapture() {
        guard isBursting, let grabber = activeBurstGrabber else { return }
        grabber.stopEarly()
    }

    /// Encodes + saves every collected frame. Runs off the main thread;
    /// this is the deferred-heavy-work half of the burst, matching how
    /// stock Camera processes a burst after the fact rather than per-frame.
    /// Frames arrive already converted to UIImage (see onFrame above) — this
    /// stage only does the HEIC/JPEG encode + disk/Photos write per frame.
    private func finishBurst(images: [UIImage], destination: SaveLocation) {
        DispatchQueue.main.async {
            self.isBursting = false
        }
        guard !images.isEmpty else { return }

        ioQueue.async { [weak self] in
            guard let self = self else { return }
            for image in images {
                autoreleasepool {
                    let aspected = self.applyPhotoAspect(image)
                    // Burst frames always go through a full encode — there
                    // is no camera-original HEIC blob for a raw sensor
                    // frame the way there is for an AVCapturePhotoOutput
                    // still, so originalData is always nil here.
                    self.savePhoto(aspected,
                                    originalData: nil,
                                    metadata: nil,
                                    to: destination,
                                    isBurstFrame: true,
                                    completion: nil)
                }
            }
            DispatchQueue.main.async {
                if !self.lastBurstReviewItems.isEmpty {
                    self.lastPhotoReviewItem = self.lastBurstReviewItems.first
                    self.photoReviewToken += 1
                }
            }
        }
    }

    /// Converts one raw sensor pixel buffer into an oriented, downscaled
    /// UIImage — the same downscale-to-target-megapixels behavior
    /// PhotoCaptureProcessor applies to a normal still, so burst photos are
    /// sized consistently with single shots at the same MP setting.
    private static func image(from pixelBuffer: CVPixelBuffer,
                              orientation: UIImage.Orientation,
                              targetMegapixels: Double,
                              context: CIContext) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let full = UIImage(cgImage: cgImage, scale: 1, orientation: orientation)

        let currentPixels = Double(cgImage.width * cgImage.height)
        let targetPixels = targetMegapixels * 1_000_000
        guard targetPixels > 0, currentPixels > targetPixels * 1.02 else { return full }

        let scale = (targetPixels / currentPixels).squareRoot()
        let newWidth = max(1, Int((Double(cgImage.width) * scale).rounded()))
        let newHeight = max(1, Int((Double(cgImage.height) * scale).rounded()))

        UIGraphicsBeginImageContextWithOptions(CGSize(width: newWidth, height: newHeight), true, 1)
        defer { UIGraphicsEndImageContext() }
        full.draw(in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return UIGraphicsGetImageFromCurrentImageContext() ?? full
    }
}
