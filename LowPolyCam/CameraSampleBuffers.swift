import AVFoundation
import UIKit
import Photos
import MediaPlayer
import CoreMotion
import Combine
import AudioToolbox
import ImageIO
import CoreImage

extension CameraRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        // Hard stop only after drain finished.
        if stopRequested {
            return
        }

        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let isVideo = (output === videoOutput)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let dur = CMSampleBufferGetDuration(sampleBuffer)

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
                ioQueue.async { [weak self] in self?.startSegment(at: pts, firstSampleBuffer: sampleBuffer) }
                return
            }
            if needsRotate {
                ioQueue.async { [weak self] in self?.rotateSegment(at: pts, firstSampleBuffer: sampleBuffer) }
                return
            }
            // Writer still spinning up — buffer this frame instead of
            // dropping it. Dropping here was the main reason short 30 fps
            // clips showed ~27.5 fps in Photos (PTS span included the gap,
            // frame count did not).
            if currentWriter == nil {
                writerLock.lock()
                if segmentStartInFlight {
                    if pendingStartBuffers.count < Self.pendingStartBufferLimit {
                        pendingStartBuffers.append(sampleBuffer)
                    } else {
                        countDroppedFrame()
                    }
                }
                writerLock.unlock()
                return
            }
        }

        guard let currentWriter = currentWriter, currentWriter.status == .writing,
              segStart.isValid, CMTimeCompare(pts, segStart) >= 0 else {
            return
        }

        if isVideo {
            if vIn?.isReadyForMoreMediaData == true {
                let appended = appendVideoSample(sampleBuffer, to: vIn)
                writerLock.lock()
                if appended {
                    lastVideoPTS = Self.endPTS(for: pts, duration: dur, fps: plan?.frameRate ?? 30)
                }
                let drainDone = shouldFinalizeAfterAppend
                writerLock.unlock()
                if drainDone {
                    completeStopDrainIfNeeded(force: false)
                }
                // Encoder is caught up — opportunistically flush a couple
                // of frames buffered from a recent brief stall, if any.
                if !draining {
                    writerLock.lock()
                    let backlog = pendingMidBuffers
                    pendingMidBuffers.removeAll(keepingCapacity: true)
                    writerLock.unlock()
                    if !backlog.isEmpty, let vIn = vIn {
                        var leftover: [CMSampleBuffer] = []
                        for buf in backlog {
                            // Route through appendVideoSample so low-res plans still get scaled.
                            if vIn.isReadyForMoreMediaData, appendVideoSample(buf, to: vIn) {
                                let bPTS = CMSampleBufferGetPresentationTimeStamp(buf)
                                let bDur = CMSampleBufferGetDuration(buf)
                                writerLock.lock()
                                lastVideoPTS = Self.endPTS(for: bPTS, duration: bDur, fps: plan?.frameRate ?? 30)
                                writerLock.unlock()
                            } else {
                                leftover.append(buf)
                            }
                        }
                        writerLock.lock()
                        pendingMidBuffers = leftover
                        writerLock.unlock()
                    }
                }
            } else if draining {
                // Never drop the stop tail — buffer until finalize flushes.
                writerLock.lock()
                if pendingStopBuffers.count < Self.pendingStopBufferLimit {
                    pendingStopBuffers.append(sampleBuffer)
                }
                let drainDone = shouldFinalizeAfterAppend
                writerLock.unlock()
                if drainDone {
                    completeStopDrainIfNeeded(force: false)
                }
            } else {
                // Encoder momentarily busy. Rather than dropping the frame
                // outright, hold it in a small capped buffer to be flushed
                // on a later frame once the encoder catches up. Only a real
                // sustained overload (buffer full) counts as a genuine drop.
                writerLock.lock()
                if pendingMidBuffers.count < Self.pendingMidBufferLimit {
                    pendingMidBuffers.append(sampleBuffer)
                    writerLock.unlock()
                } else {
                    writerLock.unlock()
                    countDroppedFrame()
                }
            }
            if !draining {
                pushElapsed(pts)
            }
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
    }

    /// End timestamp for a written frame. Prefer the buffer's own duration;
    /// if it's invalid (common on some A10 paths), fall back to 1/fps so
    /// endSession does not undershoot and Photos duration stays consistent
    /// with frame count.

    /// Append a camera frame (passthrough CMSampleBuffer → AVAssetWriterInput).
    /// Plan dimensions are forced to the active sensor size at record start.
    @discardableResult
    func appendVideoSample(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) -> Bool {
        guard let input = input, input.isReadyForMoreMediaData else { return false }
        return input.append(sampleBuffer)
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
            DispatchQueue.main.async {
                self.stopRecording(notice: "Storage full · Recording stopped")
            }
            return
        }

        let seconds = CMTimeGetSeconds(CMTimeSubtract(pts, start))
        writerLock.lock()
        let drops = droppedFrameCount
        writerLock.unlock()
        let level = currentAudioLevel()

        // Auto-stop when max duration is reached
        if let limit = self.settings.maxDuration.seconds, seconds >= limit {
            DispatchQueue.main.async {
                self.elapsed = seconds
                self.stopRecording(notice: "Max duration reached · Recording stopped")
            }
            return
        }

        DispatchQueue.main.async {
            self.elapsed = seconds
            if self.droppedFrames != drops { self.droppedFrames = drops }
            self.audioLevel = level
        }
    }

    func currentAudioLevel() -> Float {
        guard let channel = audioOutput.connection(with: .audio)?.audioChannels.first else { return 0 }
        let db = channel.averagePowerLevel
        let normalized = (db + 50) / 50
        return Float(max(0, min(1, normalized)))
    }
}
