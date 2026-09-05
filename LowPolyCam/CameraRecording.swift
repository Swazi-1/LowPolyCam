//
//  CameraRecording.swift
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
import VideoToolbox

enum CaptureFileNamer {
    private static let lock = NSLock()
    private static let sequenceKey = "nextIMGSequence"
    private static var scannedLibrary = false

    static func nextFileName(extension fileExtension: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        var highest = max(0, UserDefaults.standard.integer(forKey: sequenceKey) - 1)

        func include(_ fileName: String) {
            let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent.uppercased()
            guard stem.hasPrefix("IMG_") else { return }
            let digits = stem.dropFirst(4).prefix { $0.isNumber }
            if let value = Int(digits) { highest = max(highest, value) }
        }

        if let localFiles = try? FileManager.default.contentsOfDirectory(
            at: CameraRecorder.clipsDirectory,
            includingPropertiesForKeys: nil
        ) {
            localFiles.forEach { include($0.lastPathComponent) }
        }

        let photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if !scannedLibrary && (photoStatus == .authorized || photoStatus == .limited) {
            scannedLibrary = true
            let assets = PHAsset.fetchAssets(with: nil)
            assets.enumerateObjects { asset, _, _ in
                PHAssetResource.assetResources(for: asset).forEach {
                    include($0.originalFilename)
                }
            }
        }

        let next = highest + 1
        UserDefaults.standard.set(next + 1, forKey: sequenceKey)
        return String(format: "IMG_%04d.%@", next, fileExtension.uppercased())
    }
}

extension CameraRecorder {

    // MARK: Recording control

    func toggleRecording() {
        (isRecording || isStartingRecording) ? stopRecording(notice: nil) : startRecording()
    }

    func startRecording() {
        // Never start while a previous clip is still finishing — that path
        // used to orphan the prior AVAssetWriter (token mismatch → no finishWriting).
        guard isSessionRunning, !isRecording, !isStartingRecording, !isSaving,
              !isCapturingPhoto, !isBursting, !isSwitchingMode, !isSwitchingCamera else { return }
        // A fast burst temporarily owns the video output's delegate (see
        // BurstCaptureEngine.swift) — never start a recording while one is
        // still collecting frames, or the two would fight over that delegate.
        if isBursting { cancelBurstCapture() }
        DebugLog.reset()
        DebugLog.write("===== startRecording() called =====")
        guard freeBytes > Self.reserveBytes else {
            DebugLog.write("❌ blocked: low storage, freeBytes=\(freeBytes)")
            notice = "Low storage · Free space needed"
            return
        }

        if settings.saveLocation == .photos { ensurePhotosAccess() }
        isStartingRecording = true

        // Same audio-route/KVO-noise guard as photo capture (see
        // CameraPhoto.swift): the start/stop shutter sounds below can cause
        // a spurious "volume changed" read a moment later, which — with the
        // volume button mapped to Shutter or Burst — would misfire as an
        // extra photo/burst right after starting a recording.
        suppressVolumeTriggerBriefly(duration: 1.2)

        var newPlan = Encoder.plan(for: settings, isFrontCamera: isFrontCamera)
        let captureAngle = physicalOrientation.captureVideoRotationAngle

        stopRequested = false
        writerLock.lock()
        isStopDraining = false
        stopDrainDeadlineHost = 0
        pendingStopBuffers.removeAll(keepingCapacity: false)
        pendingStopToken = 0
        pendingStopBackgroundTask = .invalid
        writerLock.unlock()
        recordingSessionToken += 1
        let myToken = recordingSessionToken

        // Check free space more often while recording.
        spaceTimer?.invalidate()
        spaceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshFreeSpace()
        }
        // Refresh immediately instead of waiting for the first 5s tick above —
        // otherwise the HUD's "~X min left" estimate keeps showing the stale
        // idle-timer value (up to 20s old) for the first few seconds of a
        // recording before it catches up.
        refreshFreeSpace()

        notice = nil
        elapsed = 0
        clipsThisSession = 0
        droppedFrames = 0
        audioLevel = 0
        // 📊 targetFPS uses the previous plan's frame rate as a placeholder;
        // it's corrected below the moment newPlan is finalized on sessionQueue.
        statsTracker.reset(targetFPS: Double(newPlan.frameRate))
        recordingStats = statsTracker.snapshot
        if settings.shutterSoundEnabled { SoundPlayer.play(.start) }

        // Format first (usually a no-op now — idle already matches record),
        // then publish isRecording. Skip AE wait when the sensor did not
        // reconfigure so Record feels instant like the stock Camera app.
        sessionQueue.async {
            guard self.recordingSessionToken == myToken, !self.stopRequested else { return }
            let formatChanged = self.applyActiveFormat(forRecording: true)
            guard self.recordingSessionToken == myToken, !self.stopRequested else { return }
            guard let device = self.cameraInput?.device else {
                Task { @MainActor in self.stopRecording(notice: "Camera unavailable") }
                return
            }
            let duration = device.activeVideoMinFrameDuration.seconds
            guard duration.isFinite, duration > 0 else {
                Task { @MainActor in self.stopRecording(notice: "Camera frame rate unavailable") }
                return
            }
            let actualFPS = max(1, Int((1 / duration).rounded()))
            let sensorDimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            var resolvedSlowResolution: Resolution?
            if self.settings.cameraMode == .slowMo,
               (Int(sensorDimensions.width) < newPlan.width || Int(sensorDimensions.height) < newPlan.height) {
                resolvedSlowResolution = Resolution.allCases
                    .filter { $0 != .p2160 && $0.captureDimensions.w <= Int(sensorDimensions.width)
                        && $0.captureDimensions.h <= Int(sensorDimensions.height) }
                    .max { $0.captureDimensions.w * $0.captureDimensions.h < $1.captureDimensions.w * $1.captureDimensions.h }
                if let resolvedSlowResolution {
                    Task { @MainActor in
                        self.settings.slowMoResolution = resolvedSlowResolution
                        self.notice = "Slow-Mo recording at \(resolvedSlowResolution.label)"
                    }
                }
            }
            // The negotiated FPS changes bitrate and GOP as well as the label.
            newPlan = Encoder.plan(for: self.settings,
                                   fpsOverride: actualFPS,
                                   resolutionOverride: resolvedSlowResolution,
                                   isFrontCamera: self.isFrontCamera)
            newPlan.hasAudio = newPlan.hasAudio && self.micInput != nil
            self.applyStabilization(forceRecording: true)

            // Keep the selected output dimensions. The active camera format is
            // allowed to stay at a sharp 16:9 preview size and the hardware
            // pixel-transfer path scales only the frames given to the writer.
            // Replacing this plan with sensor dimensions was why 480p/360p/
            // 144p saved as arbitrary 4:3 formats instead of their labels.
            DebugLog.write("[plan] encode \(newPlan.width)x\(newPlan.height) @\(newPlan.frameRate)fps")
            let transform = Self.transform(
                width: newPlan.width,
                height: newPlan.height,
                isFront: self.isFrontCamera,
                mirrorFront: !self.settings.saveSelfiesUnmirrored,
                angle: captureAngle
            )

            Task { @MainActor in
                guard self.recordingSessionToken == myToken, !self.stopRequested else { return }
                self.isRecording = true
                self.isStartingRecording = false
                UIApplication.shared.isIdleTimerDisabled = true
                self.recordWallStart = Date()
                self.recordElapsedTimer?.invalidate()
                self.recordElapsedTimer = nil // elapsed comes from the media timeline
            }

            let beginCapture: () -> Void = {
                guard self.recordingSessionToken == myToken, !self.stopRequested else { return }
                self.videoOutput.alwaysDiscardsLateVideoFrames = VideoRecordingSystem.discardsLateFrames(isRecording: true)
                self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
                self.audioOutput.setSampleBufferDelegate(self, queue: self.audioQueue)

                self.ioQueue.async {
                    guard self.recordingSessionToken == myToken, !self.stopRequested else { return }
                    self.plan = newPlan
                    self.recordingDestination = self.settings.saveLocation
                    self.clipTransform = transform
                    self.lastElapsedPush = .invalid
                    self.droppedFrameCount = 0
                    self.statsTracker.reset(targetFPS: Double(newPlan.frameRate)) // 📊 final plan fps
                    // Warmup only needed after a real format switch (AE ramp).
                    // When idle already matched record format, start writing
                    // immediately — no discarded frames / no freeze.
                    let warmup: Int
                    if formatChanged {
                        let fps = max(Double(newPlan.frameRate), 1)
                        let rawWarmupFrames = Int((Self.recordStartWarmupSeconds * fps).rounded(.up))
                        let ceiling = Self.recordStartWarmupFrameCeiling(fps: newPlan.frameRate)
                        warmup = min(max(rawWarmupFrames, Self.recordStartWarmupFrameFloor), ceiling)
                    } else {
                        warmup = 0
                    }
                    self.writerLock.lock()
                    self.recordStartPTS = .invalid
                    self.segmentStartInFlight = false
                    self.pendingStartBuffers.removeAll(keepingCapacity: true)
                    self.pendingMidBuffers.removeAll(keepingCapacity: false)
                    self.pendingWarmupFrames = warmup
                    self.wantsRecording = true
                    self.writerLock.unlock()
                }
            }

            if formatChanged, let device = self.cameraInput?.device {
                self.waitForExposureSettled(device: device, timeout: 0.22, completion: beginCapture)
            } else {
                beginCapture()
            }
        }
    }

    func stopRecording(notice message: String?) {
        guard isRecording || isStartingRecording else { return }
        if isStartingRecording && !isRecording {
            recordingSessionToken += 1
            stopRequested = true
            isStartingRecording = false
            notice = message
            return
        }
        isStartingRecording = false

        let myToken = recordingSessionToken
        DebugLog.write("===== stopRecording() called token=\(myToken) =====")

        // Same guard as startRecording()/capturePhoto() — the stop sound
        // below can otherwise register as a false volume-button press a
        // moment later.
        suppressVolumeTriggerBriefly(duration: 1.2)

        if settings.shutterSoundEnabled { SoundPlayer.play(.stop) }
        // Keep sample-buffer delegates attached and keep writing for a short
        // wall-clock window so frames already in the ISP/pipeline (and the
        // frame under the finger at Stop) are appended before we finalize.
        isRecording = false
        isSaving = true
        recordElapsedTimer?.invalidate()
        recordElapsedTimer = nil
        recordWallStart = nil
        audioLevel = 0
        UIApplication.shared.isIdleTimerDisabled = false
        notice = message
        refreshFreeSpace()

        spaceTimer?.invalidate()
        spaceTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.refreshFreeSpace()
        }

        var task: UIBackgroundTaskIdentifier = .invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "finishClip") {
            if task != .invalid {
                UIApplication.shared.endBackgroundTask(task)
                task = .invalid
            }
        }

        // Write everything for ~250ms after Stop, then finalize. High motion
        // near Stop used to drop the tail when the encoder input wasn't ready;
        // those frames are buffered below and flushed before finishWriting.
        // At 120/240fps the record button is disabled and shows a spinner for
        // the entire time isSaving is true — a longer drain window here
        // directly extends how long the UI looks frozen after Stop. High-fps
        // clips already drop frames liberally under load by design, so we
        // shrink the drain window instead of growing it: better a slightly
        // shorter tail than several extra seconds of an unresponsive button.
        let highFPS = (plan?.frameRate ?? 30) >= 120
        let drainWindow: CFTimeInterval = highFPS ? 0.15 : 0.25
        let hardCeiling: Double = highFPS ? 0.3 : 0.45

        DebugLog.write("[stop] draining token=\(myToken) drainWindow=\(drainWindow) hardCeiling=\(hardCeiling) highFPS=\(highFPS)")

        writerLock.lock()
        isStopDraining = true
        stopDrainDeadlineHost = CACurrentMediaTime() + drainWindow
        pendingStopBuffers.removeAll(keepingCapacity: true)
        pendingStopToken = myToken
        pendingStopBackgroundTask = task
        writerLock.unlock()

        // Hard ceiling so we never hang if the camera stalls. This used to
        // run on ioQueue, but at 240fps ioQueue can itself be backed up
        // (segment start/rotate + append bookkeeping all funnel through it),
        // which delayed this asyncAfter block past its deadline and left
        // the drain permanently open — isSaving stuck true, Record dead,
        // and nothing after "stopRecording() called" ever hit the log.
        // A dedicated timer on the main queue can't be blocked by that
        // congestion, so the drain always terminates on schedule.
        DispatchQueue.main.asyncAfter(deadline: .now() + hardCeiling) { [weak self] in
            DebugLog.write("[stop] hard ceiling reached token=\(myToken), forcing drain completion")
            self?.ioQueue.async {
                self?.completeStopDrainIfNeeded(force: true)
            }
        }

        // Independent, UI-side safety valve. Everything above assumes the
        // drain → finishSegment → finishWriting chain actually keeps
        // running, but if anything in that chain hangs somewhere we didn't
        // anticipate (not just the finishWriting call itself, which already
        // has its own watchdog in finishSegment), isSaving could stay true
        // forever with zero log output — a fully dead Record button with no
        // trail to diagnose. This fires independently of that whole chain
        // and force-recovers the UI no matter what got stuck.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self = self, self.isSaving, self.recordingSessionToken == myToken else { return }
            DebugLog.write("❌ stopRecording watchdog: isSaving still true 4s after Stop (token=\(myToken)) — force-recovering UI")
            // Never release the reservation while a writer still owns its
            // file. The writer's terminal callback owns cleanup and readiness.
            self.notice = "Still finishing your recording…"
        }
    }

    /// Finalize the stop drain. `force` is used by the safety timeout.
    func completeStopDrainIfNeeded(force: Bool = false) {
        writerLock.lock()
        let token = pendingStopToken
        var task = pendingStopBackgroundTask
        let pastDeadline = CACurrentMediaTime() >= stopDrainDeadlineHost
        guard token != 0, token == recordingSessionToken, (force || pastDeadline) else {
            let reason = token == 0 ? "already claimed" : (token != recordingSessionToken ? "stale token" : "before deadline")
            writerLock.unlock()
            DebugLog.write("[stop] completeStopDrainIfNeeded skipped (\(reason)) force=\(force) token=\(token) currentToken=\(recordingSessionToken)")
            return
        }
        DebugLog.write("[stop] completeStopDrainIfNeeded firing force=\(force) token=\(token) bufferedStopFrames=\(pendingStopBuffers.count)")
        // Claim the stop so only one path finalizes.
        pendingStopToken = 0
        pendingStopBackgroundTask = .invalid
        isStopDraining = false
        wantsRecording = false
        stopDrainDeadlineHost = 0
        let buffered = pendingMidBuffers + pendingStopBuffers
        pendingStopBuffers.removeAll(keepingCapacity: false)
        pendingStartBuffers.removeAll(keepingCapacity: false)
        pendingMidBuffers.removeAll(keepingCapacity: false)
        let vIn = videoIn
        writerLock.unlock()

        stopRequested = true

        // Flush any frames that arrived while the writer input was busy.
        // Route through appendVideoSample so low-res plans still get scaled.
        if let vIn = vIn {
            for sample in buffered {
                if vIn.isReadyForMoreMediaData {
                    if appendVideoSample(sample, to: vIn) {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                        let dur = CMSampleBufferGetDuration(sample)
                        writerLock.lock()
                        lastVideoPTS = Self.endPTS(for: pts, duration: dur, fps: plan?.frameRate ?? 30)
                        writerLock.unlock()
                        statsTracker.recordAppendedFrame(at: pts)
                    }
                }
            }
        }

        // Detach delegates and drop to idle format only AFTER the last appends.
        sessionQueue.async {
            self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
            self.audioOutput.setSampleBufferDelegate(nil, queue: nil)
            self.videoOutput.alwaysDiscardsLateVideoFrames = VideoRecordingSystem.discardsLateFrames(isRecording: false)
            self.applyActiveFormat(forRecording: false)
            self.applyStabilization()
        }

        DebugLog.write("[stop] dispatching finishSegment to ioQueue token=\(token)")
        ioQueue.async {
            guard token == self.recordingSessionToken else {
                DebugLog.write("[stop] finishSegment skipped, stale token=\(token) currentToken=\(self.recordingSessionToken)")
                Task { @MainActor in self.isSaving = false }
                if task != .invalid {
                    UIApplication.shared.endBackgroundTask(task)
                    task = .invalid
                }
                return
            }
            self.finishSegment {
                DebugLog.write("[stop] finishSegment completion fired, isSaving -> false token=\(token)")
                Task { @MainActor in self.isSaving = false }
                if task != .invalid {
                    UIApplication.shared.endBackgroundTask(task)
                    task = .invalid
                }
            }
        }
    }

    // MARK: Segments & Rolling Split

    func startSegment(at pts: CMTime, firstSampleBuffer: CMSampleBuffer? = nil) {
        DebugLog.write("[0] startSegment called at pts=\(CMTimeGetSeconds(pts)) plan=\(plan != nil) freeBytesSnapshot=\(freeBytesSnapshot)")
        guard let plan = plan else {
            DebugLog.write("❌ no plan, bailing")
            writerLock.lock()
            segmentStartInFlight = false
            writerLock.unlock()
            abortRecordingStart(message: "Encoder setup failed")
            return
        }

        guard freeBytesSnapshot > Self.reserveBytes else {
            DebugLog.write("❌ storage guard failed: freeBytesSnapshot=\(freeBytesSnapshot) reserveBytes=\(Self.reserveBytes)")
            writerLock.lock()
            segmentStartInFlight = false
            pendingStartBuffers.removeAll(keepingCapacity: false)
            pendingMidBuffers.removeAll(keepingCapacity: false)
            wantsRecording = false
            writerLock.unlock()
            Task { @MainActor in
                self.isRecording = false
                self.notice = "Storage full · Recording stopped"
                UIApplication.shared.isIdleTimerDisabled = false
            }
            sessionQueue.async {
                self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
                self.audioOutput.setSampleBufferDelegate(nil, queue: nil)
                self.videoOutput.alwaysDiscardsLateVideoFrames = VideoRecordingSystem.discardsLateFrames(isRecording: false)
            }
            return
        }

        do {
            let url = Self.newClipURL()
            DebugLog.write("[1] clip URL=\(url.lastPathComponent)")
            UserDefaults.standard.set(url.lastPathComponent, forKey: Self.inProgressKey)
            // Persist the destination that was active for this segment so
            // recovery after an interruption does not use a later user change.
            RecordingRecoveryJournal.record(url, destination: recordingDestination)

            let w = try AVAssetWriter(outputURL: url, fileType: .mov)
            DebugLog.write("[2] AVAssetWriter created OK")
            w.movieFragmentInterval = CMTime(seconds: Self.fragmentSeconds, preferredTimescale: 600)
            w.metadata = Self.captureMetadataItems()

            let resolvedVideo = Encoder.videoSettings(for: plan, writer: w)
            let videoSettings = resolvedVideo.settings
            self.plan = resolvedVideo.plan
            DebugLog.write("[3] video settings=\(videoSettings)")
            let sourceHint = firstSampleBuffer.flatMap { CMSampleBufferGetFormatDescription($0) }
            let v = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: videoSettings,
                sourceFormatHint: sourceHint
            )
            v.expectsMediaDataInRealTime = true
            v.performsMultiPassEncodingIfSupported = false
            v.transform = clipTransform
            let canAddVideo = w.canAdd(v)
            DebugLog.write("[4] canAdd video input=\(canAddVideo)")
            guard canAddVideo else { throw RecorderError.cannotAddInput }
            w.add(v)
            DebugLog.write("[5] video input added")
            let pixelAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: plan.width,
                kCVPixelBufferHeightKey as String: plan.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: v,
                sourcePixelBufferAttributes: pixelAttributes
            )
            // The default transfer mode scales the complete source image to
            // the complete destination buffer, exactly what our 16:9 tiers
            // need. Leaving it at the framework default also avoids adding a
            // crop/clean-aperture rule that could change the preview FOV.
            var pool: CVPixelBufferPool?
            let poolStatus = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelAttributes as CFDictionary, &pool)
            guard poolStatus == kCVReturnSuccess, let outputPool = pool else {
                throw RecorderError.cannotAddInput
            }
            self.pixelBufferAdaptor = adaptor
            self.scalePixelBufferPool = outputPool

            var a: AVAssetWriterInput?
            if plan.hasAudio, let aSettings = audioSettings(for: plan, writer: w) {
                DebugLog.write("[6] audio settings=\(aSettings)")
                let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
                ai.expectsMediaDataInRealTime = true
                if w.canAdd(ai) { w.add(ai); a = ai; DebugLog.write("[7] audio input added") }
                else { DebugLog.write("[7] audio input REJECTED by canAdd") }
            } else {
                DebugLog.write("[6] no audio (hasAudio=\(plan.hasAudio))")
            }

            DebugLog.write("[8] calling startWriting()...")
            guard w.startWriting() else {
                DebugLog.write("❌ startWriting() returned FALSE. writer.error=\(w.error?.localizedDescription ?? "nil") status=\(w.status.rawValue)")
                throw w.error ?? RecorderError.cannotAddInput
            }
            DebugLog.write("[8] startWriting() OK status=\(w.status.rawValue)")
            // At 120/240fps a writer can take long enough to initialize that
            // the first trigger frame is already old by the time it is ready.
            // Starting the movie at that old PTS and then appending a much
            // newer frame creates a hole in the media timeline; Photos divides
            // frame count by that hole and reports e.g. 198/213 fps. Keep only
            // the newest startup frame and make it the first frame/timestamp.
            let highFPS = plan.frameRate >= 120
            var firstFrame = firstSampleBuffer
            if highFPS {
                writerLock.lock()
                if let latest = pendingStartBuffers.last {
                    firstFrame = latest
                }
                writerLock.unlock()
            }
            let startPTS = firstFrame.map { CMSampleBufferGetPresentationTimeStamp($0) } ?? pts
            w.startSession(atSourceTime: startPTS)
            DebugLog.write("[9] startSession OK at pts=\(CMTimeGetSeconds(startPTS))")

            // Append the selected first frame synchronously before publishing
            // the writer. This guarantees the session's declared start time
            // has a matching encoded sample and avoids a black first frame.
            var appendedFirstPTS = startPTS
            var appendedFirstFrame = false
            if let first = firstFrame, v.isReadyForMoreMediaData {
                if appendVideoSample(first, to: v) {
                    let dur = CMSampleBufferGetDuration(first)
                    appendedFirstPTS = Self.endPTS(for: startPTS, duration: dur, fps: plan.frameRate)
                    appendedFirstFrame = true
                    DebugLog.write("[9b] first frame appended at segment start ✅")
                } else {
                    DebugLog.write("⚠️ first frame append failed, status=\(w.status.rawValue) error=\(w.error?.localizedDescription ?? "nil")")
                    // If the writer is already dead, bail — publishing a failed
                    // writer made 240fps "record" for one frame then die.
                    if w.status == .failed {
                        w.cancelWriting()
                        throw w.error ?? RecorderError.cannotAddInput
                    }
                }
            } else {
                DebugLog.write("⚠️ no first sample buffer / input not ready yet, black-frame gap possible")
            }

            // Publish writer so live frames can flow. At high FPS, discard the
            // one now-stale startup buffer—only the synchronous latest frame
            // selected above is appended.
            writerLock.lock()
            let buffered = pendingStartBuffers
            pendingStartBuffers.removeAll(keepingCapacity: true)
            pendingMidBuffers.removeAll(keepingCapacity: false)
            let isFirstSegment = !recordStartPTS.isValid
            if isFirstSegment, appendedFirstFrame {
                statsTracker.reset(targetFPS: Double(plan.frameRate))
                statsTracker.recordAppendedFrame(at: startPTS)
            }
            var endPTS = appendedFirstPTS
            if isFirstSegment { recordStartPTS = startPTS }

            if !highFPS {
                for buf in buffered {
                    let bPTS = CMSampleBufferGetPresentationTimeStamp(buf)
                    if CMTimeCompare(bPTS, startPTS) == 0 { continue }
                    if CMTimeCompare(bPTS, startPTS) < 0 { continue }
                    if v.isReadyForMoreMediaData, appendVideoSample(buf, to: v) {
                        let bDur = CMSampleBufferGetDuration(buf)
                        endPTS = Self.endPTS(for: bPTS, duration: bDur, fps: plan.frameRate)
                        statsTracker.recordAppendedFrame(at: bPTS)
                    }
                }
            }

            // Publish only after older startup frames have been flushed. This
            // prevents the live video queue from appending a newer timestamp
            // while startup is still trying to append older buffers.
            writer = w
            videoIn = v
            pixelBufferAdaptor = adaptor
            scalePixelBufferPool = outputPool
            audioIn = a
            segmentStart = startPTS
            lastVideoPTS = endPTS
            segmentStartInFlight = false
            writerLock.unlock()

            Task { @MainActor in self.clipsThisSession += 1 }
            if highFPS {
                DebugLog.write("[10] segment fully started ✅ (high-fps: skipped \(buffered.count) stale buffered frames)")
            } else {
                DebugLog.write("[10] segment fully started ✅ (flushed \(buffered.count) buffered frames)")
            }

        } catch {
            DebugLog.write("❌ startSegment threw: \(error.localizedDescription) | full: \(error)")
            writerLock.lock()
            segmentStartInFlight = false
            pendingStartBuffers.removeAll(keepingCapacity: false)
            pendingMidBuffers.removeAll(keepingCapacity: false)
            writer = nil
            videoIn = nil
            audioIn = nil
            pixelBufferAdaptor = nil
            scalePixelBufferPool = nil
            wantsRecording = false
            writerLock.unlock()
            Task { @MainActor in
                self.isRecording = false
                self.notice = "Encoder error"
                UIApplication.shared.isIdleTimerDisabled = false
            }
            abortRecordingStart(message: "Encoder error")
        }
    }

    /// Restores the idle capture graph if writer creation fails after sample
    /// delegates were attached. Without this, frames continued arriving forever
    /// and a second press could not reliably start a clean take.
    func abortRecordingStart(message: String) {
        stopRequested = true
        sessionQueue.async {
            self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
            self.audioOutput.setSampleBufferDelegate(nil, queue: nil)
            self.videoOutput.alwaysDiscardsLateVideoFrames = VideoRecordingSystem.discardsLateFrames(isRecording: false)
            self.applyActiveFormat(forRecording: false)
        }
        Task { @MainActor in
            self.isRecording = false
            self.isSaving = false
            self.notice = message
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }


    func finishSegment(_ completion: (() -> Void)? = nil) {
        DebugLog.write("[finish] finishSegment entered")
        writerLock.lock()
        guard let w = writer, let v = videoIn else {
            DebugLog.write("[finish] finishSegment called with no writer/videoIn — nothing to finalize")
            writer = nil; videoIn = nil; audioIn = nil; pixelBufferAdaptor = nil; scalePixelBufferPool = nil
            writerLock.unlock()
            completion?()
            return
        }
        let a = audioIn
        // lastVideoPTS already includes the last sample's duration (endPTS).
        let end = lastVideoPTS
        let start = segmentStart
        let destination = recordingDestination
        let url = w.outputURL
        let hadFrames = end.isValid && start.isValid && CMTimeCompare(end, start) > 0

        writer = nil; videoIn = nil; audioIn = nil; pixelBufferAdaptor = nil; scalePixelBufferPool = nil
        segmentStart = .invalid
        lastVideoDuration = .invalid
        writerLock.unlock()

        // Incomplete MOVs (writer died mid-take without finishWriting) are NOT
        // valid for Photos — PHPhotosError 3302. Only delete + message.
        func fileByteSize(_ u: URL) -> Int {
            (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }
        func failIncomplete(_ reason: String) {
            let bytes = fileByteSize(url)
            DebugLog.write("❌ finishSegment \(reason) fileBytes=\(bytes) (incomplete — not sending to Photos)")
            RecordingRecoveryJournal.remove(url)
            try? FileManager.default.removeItem(at: url)
            Task { @MainActor in
                self.notice = "Clip failed to save"
                self.refreshFreeSpace()
            }
            completion?()
        }

        guard w.status == .writing else {
            let err = w.error?.localizedDescription ?? "status=\(w.status.rawValue)"
            // cancelWriting if still possible; then try salvage.
            if w.status == .failed || w.status == .cancelled {
                // already terminal
            } else {
                w.cancelWriting()
            }
            failIncomplete("writer not writing: \(err)")
            return
        }

        if !hadFrames {
            DebugLog.write("⚠️ finishSegment: no video frames written")
            w.cancelWriting()
            failIncomplete("no frames")
            return
        }

        v.markAsFinished()
        a?.markAsFinished()
        w.endSession(atSourceTime: end)
        DebugLog.write("[finish] endSession done, calling finishWriting() status=\(w.status.rawValue)")

        // finishWriting's completion handler has no built-in timeout. If it
        // ever stalls (rare, but seen on iOS 15 under thermal/storage
        // pressure with high-fps H.264 writes), isSaving stayed true forever
        // — Record stayed disabled and the UI looked hung ("stuck saving"),
        // which after a while reads the same as "the recording never saved."
        // This watchdog guarantees completion fires exactly once either way.
        var didFinish = false
        let finishLock = NSLock()
        func finishOnce(_ body: @escaping () -> Void) {
            finishLock.lock()
            guard !didFinish else { finishLock.unlock(); return }
            didFinish = true
            finishLock.unlock()
            body()
        }

        ioQueue.asyncAfter(deadline: .now() + 20.0) {
            finishOnce {
                DebugLog.write("❌ finishWriting watchdog fired (no callback within 20s), status=\(w.status.rawValue)")
                let bytes = fileByteSize(url)
                DebugLog.write("   fileBytes=\(bytes)")
                // Cancel before relinquishing ownership; retain the failed
                // file for recovery rather than deleting a potentially live MOV.
                if w.status == .writing || w.status == .unknown { w.cancelWriting() }
                RecordingRecoveryJournal.remove(url)
                Task { @MainActor in
                    self.notice = "Recording interrupted · Local file retained"
                    self.refreshFreeSpace()
                }
                completion?()
            }
        }

        w.finishWriting {
            finishOnce {
                RecordingRecoveryJournal.remove(url)

                if w.status == .completed {
                    self.generateThumbnail(for: url)

                    // IMPORTANT: finishing the AVAssetWriter is the point at
                    // which the recording pipeline is safely free to start a
                    // new clip. Do not keep isSaving true while Photos imports
                    // the finished MOV — PHPhotoLibrary can take seconds or
                    // stall without blocking the live camera preview. Keeping
                    // completion tied to Photos made the Record button look
                    // frozen even though capture was still alive.
                    completion?()

                    // Photos delivery is post-finalization work and must not
                    // control the Record button's enabled state.
                    self.deliver(url, to: destination) {
                        Task { @MainActor in self.refreshFreeSpace() }
                    }
                    return
                }

                // finishWriting failed — file is not a valid Photos asset (3302).
                let err = w.error?.localizedDescription ?? "status=\(w.status.rawValue)"
                let bytes = fileByteSize(url)
                DebugLog.write("❌ finishWriting not completed: \(err) fileBytes=\(bytes)")
                try? FileManager.default.removeItem(at: url)
                Task { @MainActor in
                    self.notice = "Clip failed to save"
                    self.refreshFreeSpace()
                }
                completion?()
            }
        }
    }

    func rotateSegment(at pts: CMTime, firstSampleBuffer: CMSampleBuffer? = nil) {
        writerLock.lock()
        guard let oldWriter = writer, let oldVideoIn = videoIn else {
            writerLock.unlock()
            return
        }
        let oldAudioIn = audioIn
        let oldEnd = lastVideoPTS
        let oldStart = segmentStart
        let oldUrl = oldWriter.outputURL
        let destination = recordingDestination

        writer = nil; videoIn = nil; audioIn = nil; pixelBufferAdaptor = nil; scalePixelBufferPool = nil
        segmentStart = .invalid
        writerLock.unlock()

        if oldWriter.status == .writing {
            oldVideoIn.markAsFinished()
            oldAudioIn?.markAsFinished()
            if oldEnd.isValid, oldStart.isValid, CMTimeCompare(oldEnd, oldStart) > 0 {
                oldWriter.endSession(atSourceTime: oldEnd)
            }
            oldWriter.finishWriting {
                guard oldWriter.status == .completed else {
                    DebugLog.write("❌ rotated segment failed to finish: \(oldWriter.error?.localizedDescription ?? "status=\(oldWriter.status.rawValue)")")
                    try? FileManager.default.removeItem(at: oldUrl)
                    Task { @MainActor in
                        self.notice = "A video segment failed to save"
                        self.refreshFreeSpace()
                    }
                    return
                }
                RecordingRecoveryJournal.remove(oldUrl)
                self.generateThumbnail(for: oldUrl)
                // 📊 Keep average-bitrate math accurate across segment
                // rotation on long takes: fold the finished segment's bytes
                // in before the new segment's file starts growing from 0.
                let finishedBytes = (try? oldUrl.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                self.statsTracker.carryOverSegmentBytes(Int64(finishedBytes))
                self.deliver(oldUrl, to: destination) {
                    Task { @MainActor in self.refreshFreeSpace() }
                }
            }
        } else {
            DebugLog.write("❌ rotated segment was not writable: status=\(oldWriter.status.rawValue)")
            try? FileManager.default.removeItem(at: oldUrl)
        }

        startSegment(at: pts, firstSampleBuffer: firstSampleBuffer)
    }

    func audioSettings(for plan: EncodePlan, writer w: AVAssetWriter) -> [String: Any]? {

        func valid(_ s: [String: Any]) -> Bool {
            w.canApply(outputSettings: s, forMediaType: .audio)
        }

        if var s = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) {
            let recommended = s
            s[AVEncoderBitRateKey] = plan.audioBitrate
            if valid(s) { return s }
            if valid(recommended) { return recommended }
        }

        let fallback: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100,
            AVEncoderBitRateKey: plan.audioBitrate
        ]
        if valid(fallback) { return fallback }
        return nil
    }

    // MARK: Recovering interrupted recordings

    func recoverInterruptedRecording() {
        var entries = RecordingRecoveryJournal.entries
        if let legacy = UserDefaults.standard.string(forKey: Self.inProgressKey), entries[legacy] == nil {
            entries[legacy] = UserDefaults.standard.string(forKey: Self.inProgressDestinationKey) ?? SaveLocation.files.rawValue
        }
        for (name, rawDestination) in entries {
            guard name == URL(fileURLWithPath: name).lastPathComponent else { continue }
            let url = Self.clipsDirectory.appendingPathComponent(name)
            Task {
                let asset = AVURLAsset(url: url)
                let playable = (try? await asset.load(.isPlayable)) ?? false
                guard playable else {
                    await MainActor.run { self.notice = "Interrupted recording kept in Files for recovery" }
                    continueRecovery(url)
                    return
                }
                generateThumbnail(for: url)
                deliver(url, to: SaveLocation(rawValue: rawDestination) ?? .files) {
                    RecordingRecoveryJournal.remove(url)
                }
            }
        }
    }

    private func continueRecovery(_ url: URL) {
        // Retain damaged bytes; do not repeatedly attempt a Photos import.
        RecordingRecoveryJournal.remove(url)
    }

    // MARK: Delivering finished clips & Thumbnails

    func generateThumbnail(for url: URL) {
        DispatchQueue.global(qos: .utility).async {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 140, height: 140)
            let time = CMTime(seconds: 0.5, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                let img = UIImage(cgImage: cgImage)
                Task { @MainActor in
                    self.lastClipThumbnail = img
                    self.lastClipURL = url
                }
            } else if let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                let img = UIImage(cgImage: cgImage)
                Task { @MainActor in
                    self.lastClipThumbnail = img
                    self.lastClipURL = url
                }
            }
        }
    }

    func ensurePhotosAccess() {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            Task { _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
        }
        // Denied is handled by deliver() — clip is kept in Files, no crash.
    }

    func deliver(_ url: URL, to destination: SaveLocation, done: @escaping () -> Void) {
        guard destination == .photos else {
            Task { @MainActor in self.notice = "Saved to Files" }
            done()
            return
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .authorized || status == .limited else {
            Task { @MainActor in
                self.notice = "Saved to Files (Photo access denied)"
            }
            done()
            return
        }

        func attemptSave(isRetry: Bool) {
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                options.originalFilename = url.lastPathComponent
                request.addResource(with: .video, fileURL: url, options: options)
            } completionHandler: { [weak self] success, error in
                if success {
                    Task { @MainActor in
                        self?.notice = "Saved to Photos"
                    }
                    done()
                    return
                }
                // One retry after a short delay — intermittent Photos import
                // failures are common under thermal/storage pressure on iOS 15.
                if !isRetry {
                    DebugLog.write("⚠️ Photos save failed, retrying once: \(error?.localizedDescription ?? "?")")
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6) {
                        attemptSave(isRetry: true)
                    }
                    return
                }
                DebugLog.write("❌ Photos save failed after retry: \(error?.localizedDescription ?? "?")")
                Task { @MainActor in
                    self?.notice = "Saved to Files (Photos refused)"
                }
                done()
            }
        }
        attemptSave(isRetry: false)
    }

    /// After a successful Photos import, remove local video clips from the
    /// app Documents directory so storage stays low (the intended behaviour
    /// when the user chose "Save to Photos"). Photos themselves are safe in
    /// the library; only our temporary/local copies are removed.
    func cleanupLocalClipsAfterPhotosSave(keeping currentURL: URL?) {
        DispatchQueue.global(qos: .background).async {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: Self.clipsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
            for file in files {
                let ext = file.pathExtension.lowercased()
                guard ext == "mov" || ext == "mp4" else { continue }
                if let current = currentURL, file.lastPathComponent == current.lastPathComponent {
                    continue
                }
                try? fm.removeItem(at: file)
            }
        }
    }

    func loadLastSavedClip() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: Self.clipsDirectory, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return }
            let validClips = files.filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "mov" || ext == "mp4"
            }.sorted { (u1, u2) -> Bool in
                let d1 = (try? u1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let d2 = (try? u2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return d1 > d2
            }

            if let latest = validClips.first {
                let size = (try? latest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if size > 0 {
                    self.generateThumbnail(for: latest)
                }
            }
        }
    }

    // MARK: Storage

    func refreshFreeSpace() {
        DispatchQueue.global(qos: .utility).async {
            let url = URL(fileURLWithPath: NSHomeDirectory())
            let bytes = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? 0
            self.ioQueue.async { self.freeBytesSnapshot = Int64(bytes) }
            Task { @MainActor in self.freeBytes = Int64(bytes) }
        }
    }

    static var clipsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func newClipURL() -> URL {
        clipsDirectory.appendingPathComponent(CaptureFileNamer.nextFileName(extension: "mov"))
    }

    // MARK: Video Matrix Orientation

    static func transform(width: Int, height: Int, isFront: Bool, mirrorFront: Bool, angle: CGFloat = 90) -> CGAffineTransform {
        var rotation = CGAffineTransform(rotationAngle: angle * .pi / 180)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height).applying(rotation)
        rotation.tx -= bounds.minX
        rotation.ty -= bounds.minY
        if isFront && mirrorFront {
            rotation = rotation.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: bounds.width, ty: 0))
        }
        return rotation
    }

    enum RecorderError: LocalizedError {
        case cannotAddInput
        var errorDescription: String? { "Encoder rejected format settings" }
    }
}
