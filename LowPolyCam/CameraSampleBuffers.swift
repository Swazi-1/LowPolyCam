//
//  CameraSampleBuffers.swift
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
import CoreImage
import VideoToolbox

extension CameraRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        if output === videoOutput, previewReadyCompletion != nil,
           let expected = previewExpectedDimensions,
           let description = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let received = CMVideoFormatDescriptionGetDimensions(description)
            if received.width == expected.width && received.height == expected.height {
                finishPreviewReadiness(success: true)
            }
            return
        }

        // Hard stop only after drain finished.
        if stopRequested {
            return
        }

        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let isVideo = (output === videoOutput)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        writerLock.lock()
        var currentlyWants = wantsRecording
        var shouldFinalizeAfterAppend = false
        let draining = isStopDraining
        if draining {
            currentlyWants = true
            if isVideo && CACurrentMediaTime() >= stopDrainDeadlineHost {
                shouldFinalizeAfterAppend = true
            }
        }
        if !currentlyWants {
            let hasWriter = writer != nil
            writerLock.unlock()
            if hasWriter {
                DebugLog.write("finishSegment triggered from didOutput (wantsRecording=false, writer still present)")
                finishSegment()
            }
            return
        }

        // Silently discard the first few video frames after a fresh record
        // start — AE/AGC brightness ramp. Counter lives under writerLock.
        if isVideo && pendingWarmupFrames > 0 {
            pendingWarmupFrames -= 1
            writerLock.unlock()
            return
        }

        var needsNewSegment = false
        var needsRotate = false
        if isVideo {
            needsNewSegment = (writer == nil) && !segmentStartInFlight
            if writer != nil, let splitLimit = plan?.splitInterval.seconds, segmentStart.isValid {
                let duration = CMTimeGetSeconds(CMTimeSubtract(pts, segmentStart))
                needsRotate = duration >= splitLimit
            }
            if needsNewSegment { segmentStartInFlight = true }
        }

        let currentWriter = writer
        let vIn = videoIn
        let aIn = audioIn
        let segStart = segmentStart
        writerLock.unlock()

        // Starting or rotating a segment must never happen on the video
        // delivery queue (setup latency drops subsequent frames).
        if isVideo {
            if needsNewSegment {
                DebugLog.write("first video frame arrived, dispatching startSegment to ioQueue")
                startSegment(at: pts, firstSampleBuffer: sampleBuffer)
                return
            }
            if needsRotate {
                rotateSegment(at: pts, firstSampleBuffer: sampleBuffer)
                return
            }
            // Writer still spinning up — buffer this frame instead of
            // dropping it. Dropping here was the main reason short 30 fps
            // clips showed ~27.5 fps in Photos (PTS span included the gap,
            // frame count did not).
            if currentWriter == nil {
                writerLock.lock()
                var droppedForStats = false // 📊 set inside lock, reported after unlock
                if segmentStartInFlight {
                    // At 120/240fps, never retain a backlog. Flushing 12–14
                    // stale buffers at segment start poisoned AVAssetWriter on
                    // iOS 15/A10, but one newest buffer is safe and prevents
                    // a large first-timestamp gap.
                    let highFPS = (plan?.frameRate ?? 30) >= 120
                    if highFPS {
                        // Writer setup takes long enough to lose dozens of 240fps
                        // frames. Keep exactly the newest one—not a backlog—so
                        // startSegment can begin the movie timeline from a frame
                        // near the moment the writer becomes ready. Retaining a
                        // whole high-speed backlog used to destabilize iOS 15/A10;
                        // one latest buffer avoids that while eliminating the
                        // large initial PTS gap that Photos read as ~200 fps.
                        pendingStartBuffers.removeAll(keepingCapacity: true)
                        pendingStartBuffers.append(sampleBuffer)
                    } else if pendingStartBuffers.count < Self.pendingStartBufferLimit {
                        pendingStartBuffers.append(sampleBuffer)
                    } else {
                        // Same lock ownership as the high-FPS branch above.
                        droppedFrameCount += 1
                        droppedForStats = true
                    }
                }
                writerLock.unlock()
                // 📊 statsTracker shares no lock with writerLock, so this is
                // safe here even though countDroppedFrame() itself isn't.
                if droppedForStats { statsTracker.recordDroppedFrame() }
                return
            }
        }

        // Do NOT auto-stop on .failed here — at 240fps the writer can briefly
        // report failed on a bad append and this used to instantly end recording.
        // finishSegment salvage handles real failures when the user stops.
        guard let currentWriter = currentWriter, currentWriter.status == .writing,
              segStart.isValid, CMTimeCompare(pts, segStart) >= 0 else {
            if let currentWriter, currentWriter.status == .failed {
                let reason = currentWriter.error?.localizedDescription ?? "unknown encoder failure"
                DebugLog.write("❌ writer failed during capture: \(reason)")
                Task { @MainActor in
                    if self.isRecording {
                        self.stopRecording(notice: "Encoder stopped · Clip could not continue")
                    }
                }
            }
            return
        }

        if isVideo {
            let targetFPS = plan?.frameRate ?? 30

            // Drain older frames before the current frame. Beta 2 appended the
            // newest frame first and only then tried its backlog, which can send
            // decreasing timestamps to AVAssetWriter. At high frame rates it
            // avoided that failure by dropping every busy frame instead — the
            // direct cause of ~210fps files from a 240fps sensor stream.
            writerLock.lock()
            var orderedBatch = pendingMidBuffers
            pendingMidBuffers.removeAll(keepingCapacity: true)
            if draining {
                orderedBatch.append(contentsOf: pendingStopBuffers)
                pendingStopBuffers.removeAll(keepingCapacity: true)
            }
            writerLock.unlock()
            orderedBatch.append(sampleBuffer)

            var firstUnwrittenIndex: Int?
            var appendedEndPTS: CMTime?
            var droppedInBatch = 0

            for index in orderedBatch.indices {
                let buffer = orderedBatch[index]
                guard let input = vIn, input.isReadyForMoreMediaData else {
                    firstUnwrittenIndex = index
                    break
                }

                if appendVideoSample(buffer, to: input) {
                    let bufferPTS = CMSampleBufferGetPresentationTimeStamp(buffer)
                    let bufferDuration = CMSampleBufferGetDuration(buffer)
                    appendedEndPTS = Self.endPTS(for: bufferPTS, duration: bufferDuration, fps: targetFPS)
                    statsTracker.recordAppendedFrame(at: bufferPTS)
                } else {
                    // A single malformed/scaler frame must not poison ordering
                    // for every later frame in the batch.
                    droppedInBatch += 1
                }
            }

            if let firstUnwrittenIndex {
                let unwritten = Array(orderedBatch[firstUnwrittenIndex...])
                writerLock.lock()
                if draining {
                    pendingStopBuffers.append(contentsOf: unwritten)
                    let overflow = max(0, pendingStopBuffers.count - Self.pendingStopBufferLimit)
                    if overflow > 0 {
                        pendingStopBuffers.removeLast(overflow)
                        droppedInBatch += overflow
                    }
                } else {
                    pendingMidBuffers.append(contentsOf: unwritten)
                    let limit = VideoRecordingSystem.backpressureFrameLimit(fps: targetFPS)
                    let overflow = max(0, pendingMidBuffers.count - limit)
                    if overflow > 0 {
                        // Keep the oldest frames so timestamps remain continuous;
                        // discard only new arrivals beyond the bounded time window.
                        pendingMidBuffers.removeLast(overflow)
                        droppedInBatch += overflow
                    }
                }
                writerLock.unlock()
            }

            writerLock.lock()
            if let appendedEndPTS { lastVideoPTS = appendedEndPTS }
            if droppedInBatch > 0 { droppedFrameCount += droppedInBatch }
            writerLock.unlock()
            if droppedInBatch > 0 { statsTracker.recordDroppedFrame(count: droppedInBatch) }

            if shouldFinalizeAfterAppend {
                DebugLog.write("[stop] drain deadline reached in didOutput, finalizing")
                completeStopDrainIfNeeded(force: false)
            }
            if !draining { pushElapsed(pts) }
        } else {
            if aIn?.isReadyForMoreMediaData == true {
                aIn?.append(sampleBuffer)
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        writerLock.lock()
        let currentlyWants = wantsRecording
        writerLock.unlock()
        guard output === videoOutput, currentlyWants else { return }
        countDroppedFrame()
    }

    func countDroppedFrame() {
        writerLock.lock()
        droppedFrameCount += 1
        writerLock.unlock()
        statsTracker.recordDroppedFrame() // 📊 no lock shared with writerLock
    }

    /// End timestamp for a written frame. Prefer the buffer's own duration;
    /// if it's invalid (common on some A10 paths), fall back to 1/fps so
    /// endSession does not undershoot and Photos duration stays consistent
    /// with frame count.

    /// Append a camera frame. Matching formats stay on the zero-copy sample
    /// path; lower tiers use VideoToolbox's hardware scaler and retain their
    /// exact selected dimensions in the saved movie.
    @discardableResult
    func appendVideoSample(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) -> Bool {
        guard let input = input, input.isReadyForMoreMediaData else { return false }
        guard let plan = plan,
              let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return input.append(sampleBuffer)
        }

        let sourceWidth = CVPixelBufferGetWidth(sourceBuffer)
        let sourceHeight = CVPixelBufferGetHeight(sourceBuffer)
        guard sourceWidth != plan.width || sourceHeight != plan.height else {
            return input.append(sampleBuffer)
        }

        guard let adaptor = pixelBufferAdaptor,
              let pool = scalePixelBufferPool else {
            DebugLog.write("❌ missing scaler for \(sourceWidth)x\(sourceHeight) → \(plan.width)x\(plan.height)")
            return false
        }

        var scaledBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &scaledBuffer) == kCVReturnSuccess,
              let destinationBuffer = scaledBuffer else {
            DebugLog.write("⚠️ scaler output pool exhausted")
            return false
        }

        // Core Image scaling is hardware-backed on the supported device and
        // keeps the low-resolution recording path independent of newer APIs.
        let sourceImage = CIImage(cvPixelBuffer: sourceBuffer)
        let scaleX = CGFloat(plan.width) / CGFloat(sourceWidth)
        let scaleY = CGFloat(plan.height) / CGFloat(sourceHeight)
        let scale = max(scaleX, scaleY)
        let scaledImage = sourceImage
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: (CGFloat(plan.width) - CGFloat(sourceWidth) * scale) / 2,
                y: (CGFloat(plan.height) - CGFloat(sourceHeight) * scale) / 2))
        scaleContext.render(scaledImage, to: destinationBuffer)

        return adaptor.append(destinationBuffer, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    static func endPTS(for pts: CMTime, duration: CMTime, fps: Int) -> CMTime {
        if duration.isValid && duration.isNumeric && duration.seconds > 0 {
            return CMTimeAdd(pts, duration)
        }
        let safeFPS = max(fps, 1)
        let oneFrame = CMTime(value: 1, timescale: CMTimeScale(safeFPS))
        return CMTimeAdd(pts, oneFrame)
    }

    func pushElapsed(_ pts: CMTime) {
        writerLock.lock()
        let start = recordStartPTS
        writerLock.unlock()
        guard start.isValid else { return }
        if lastElapsedPush.isValid,
           CMTimeGetSeconds(CMTimeSubtract(pts, lastElapsedPush)) < 0.25 { return }
        lastElapsedPush = pts

        if freeBytesSnapshot <= Self.reserveBytes {
            Task { @MainActor in
                self.stopRecording(notice: "Storage full · Recording stopped")
            }
            return
        }

        let seconds = CMTimeGetSeconds(CMTimeSubtract(pts, start))
        writerLock.lock()
        let drops = droppedFrameCount
        let outputURL = writer?.outputURL // 📊 read-only, same lock writer already lives under
        writerLock.unlock()
        let level = currentAudioLevel()

        // 📊 Cheap: just a stat() call on the currently-open output file.
        // Same io cost class as the existing fileByteSize() helper used
        // elsewhere in the recording path (finishSegment).
        if let outputURL = outputURL {
            let bytes = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            statsTracker.sample(currentFileBytes: Int64(bytes))
        }
        let statsSnapshot = statsTracker.snapshot

        // Auto-stop when max duration is reached
        if let limit = self.settings.maxDuration.seconds, seconds >= limit {
            Task { @MainActor in
                self.elapsed = seconds
                self.stopRecording(notice: "Max duration reached · Recording stopped")
            }
            return
        }

        Task { @MainActor in
            self.elapsed = seconds
            if self.droppedFrames != drops { self.droppedFrames = drops }
            self.audioLevel = level
            self.recordingStats = statsSnapshot // 📊
        }
    }

    func currentAudioLevel() -> Float {
        guard let channel = audioOutput.connection(with: .audio)?.audioChannels.first else { return 0 }
        let db = channel.averagePowerLevel
        let normalized = (db + 50) / 50
        return Float(max(0, min(1, normalized)))
    }
}
