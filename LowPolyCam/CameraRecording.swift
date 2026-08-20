import AVFoundation
import UIKit
import Photos
import MediaPlayer
import CoreMotion
import Combine
import AudioToolbox
import ImageIO

extension CameraRecorder {

    // MARK: Recording control

    func toggleRecording() {
        isRecording ? stopRecording(notice: nil) : startRecording()
    }

    func startRecording() {
        // Never start while a previous clip is still finishing — that path
        // used to orphan the prior AVAssetWriter (token mismatch → no finishWriting).
        guard !isRecording, !isSaving else { return }
        DebugLog.reset()
        DebugLog.write("===== startRecording() called =====")
        guard freeBytes > Self.reserveBytes else {
            DebugLog.write("❌ blocked: low storage, freeBytes=\(freeBytes)")
            notice = "Low storage · Free space needed"
            return
        }

        if settings.saveLocation == .photos { ensurePhotosAccess() }

        var newPlan = Encoder.plan(for: settings)

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

        notice = nil
        elapsed = 0
        clipsThisSession = 0
        droppedFrames = 0
        audioLevel = 0
        if settings.shutterSoundEnabled { SoundPlayer.play(.start) }

        // Format first (usually a no-op now — idle already matches record),
        // then publish isRecording. Skip AE wait when the sensor did not
        // reconfigure so Record feels instant like the stock Camera app.
        sessionQueue.async {
            guard self.recordingSessionToken == myToken, !self.stopRequested else { return }
            let formatChanged = self.applyActiveFormat(forRecording: true)
            guard self.recordingSessionToken == myToken, !self.stopRequested else { return }
            self.applyStabilization(forceRecording: true)

            // The requested resolution (e.g. 1080p Slow-Mo) isn't always what the
            // sensor can actually deliver at the requested fps — on hardware that
            // can't hit e.g. 1080p240, applyActiveFormat above silently falls back
            // to a lower-res sensor format. If the encoder is still told to write
            // the originally-requested (higher) dimensions, it upscales the lower
            // native sensor image into the bigger frame, which looks soft/noisy
            // despite a high bitrate. Read back what the sensor actually locked to
            // and make the encoder match it exactly — no upscale.
            if let device = self.cameraInput?.device {
                let activeDims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                let sensorW = Int(activeDims.width)
                let sensorH = Int(activeDims.height)
                if sensorW > 0, sensorH > 0 {
                    let requestedIsPortrait = newPlan.height > newPlan.width
                    let (outW, outH) = requestedIsPortrait ? (sensorH, sensorW) : (sensorW, sensorH)
                    if outW != newPlan.width || outH != newPlan.height {
                        newPlan.width = outW
                        newPlan.height = outH
                    }
                }
            }
            let transform = Self.transform(width: newPlan.width, height: newPlan.height, isFront: self.isFrontCamera)

            DispatchQueue.main.async {
                guard self.recordingSessionToken == myToken, !self.stopRequested else { return }
                self.isRecording = true
                UIApplication.shared.isIdleTimerDisabled = true
                self.recordWallStart = Date()
                self.recordElapsedTimer?.invalidate()
                let token = myToken
                self.recordElapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    guard let self = self, self.isRecording, self.recordingSessionToken == token,
                          let start = self.recordWallStart else { return }
                    self.elapsed = Date().timeIntervalSince(start)
                }
                if let timer = self.recordElapsedTimer {
                    RunLoop.main.add(timer, forMode: .common)
                }
            }

            let beginCapture: () -> Void = {
                guard self.recordingSessionToken == myToken, !self.stopRequested else { return }
                self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
                self.audioOutput.setSampleBufferDelegate(self, queue: self.audioQueue)

                self.ioQueue.async {
                    self.plan = newPlan
                    self.recordingDestination = self.settings.saveLocation
                    self.clipTransform = transform
                    self.lastElapsedPush = .invalid
                    self.droppedFrameCount = 0
                    // Warmup only needed after a real format switch (AE ramp).
                    // When idle already matched record format, start writing
                    // immediately — no discarded frames / no freeze.
                    let warmup: Int
                    if formatChanged {
                        let fps = max(Double(newPlan.frameRate), 1)
                        let rawWarmupFrames = Int((Self.recordStartWarmupSeconds * fps).rounded(.up))
                        warmup = min(max(rawWarmupFrames, Self.recordStartWarmupFrameFloor), Self.recordStartWarmupFrameCeiling)
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
        guard isRecording else { return }

        let myToken = recordingSessionToken

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
        writerLock.lock()
        isStopDraining = true
        stopDrainDeadlineHost = CACurrentMediaTime() + 0.25
        pendingStopBuffers.removeAll(keepingCapacity: true)
        pendingStopToken = myToken
        pendingStopBackgroundTask = task
        writerLock.unlock()

        // Hard ceiling so we never hang if the camera stalls.
        ioQueue.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.completeStopDrainIfNeeded(force: true)
        }
    }

    /// Finalize the stop drain. `force` is used by the safety timeout.
    func completeStopDrainIfNeeded(force: Bool = false) {
        writerLock.lock()
        let token = pendingStopToken
        var task = pendingStopBackgroundTask
        let pastDeadline = CACurrentMediaTime() >= stopDrainDeadlineHost
        guard token != 0, token == recordingSessionToken, (force || pastDeadline) else {
            writerLock.unlock()
            return
        }
        // Claim the stop so only one path finalizes.
        pendingStopToken = 0
        pendingStopBackgroundTask = .invalid
        isStopDraining = false
        wantsRecording = false
        stopDrainDeadlineHost = 0
        let buffered = pendingStopBuffers
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
                    }
                }
            }
        }

        // Detach delegates and drop to idle format only AFTER the last appends.
        sessionQueue.async {
            self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
            self.audioOutput.setSampleBufferDelegate(nil, queue: nil)
            self.applyActiveFormat(forRecording: false)
            self.applyStabilization()
        }

        ioQueue.async {
            guard token == self.recordingSessionToken else {
                DispatchQueue.main.async { self.isSaving = false }
                if task != .invalid {
                    UIApplication.shared.endBackgroundTask(task)
                    task = .invalid
                }
                return
            }
            self.finishSegment {
                DispatchQueue.main.async { self.isSaving = false }
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
            DispatchQueue.main.async {
                self.isRecording = false
                self.notice = "Storage full · Recording stopped"
                UIApplication.shared.isIdleTimerDisabled = false
            }
            return
        }

        do {
            let url = Self.newClipURL()
            DebugLog.write("[1] clip URL=\(url.lastPathComponent)")
            UserDefaults.standard.set(url.lastPathComponent, forKey: Self.inProgressKey)
            // Persist the destination that was active for this segment so
            // recovery after an interruption does not use a later user change.
            UserDefaults.standard.set(recordingDestination.rawValue, forKey: Self.inProgressDestinationKey)

            let w = try AVAssetWriter(outputURL: url, fileType: .mov)
            DebugLog.write("[2] AVAssetWriter created OK")
            w.movieFragmentInterval = CMTime(seconds: Self.fragmentSeconds, preferredTimescale: 600)
            w.metadata = Self.captureMetadataItems()

            let videoSettings = Encoder.videoSettings(for: plan, writer: w)
            DebugLog.write("[3] video settings=\(videoSettings)")
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            v.expectsMediaDataInRealTime = true
            v.transform = clipTransform
            let canAddVideo = w.canAdd(v)
            DebugLog.write("[4] canAdd video input=\(canAddVideo)")
            guard canAddVideo else { throw RecorderError.cannotAddInput }
            w.add(v)
            DebugLog.write("[5] video input added")
            // Adaptor lets us scale camera frames down to the exact selected
            // resolution (144p/320p/480p). Appending raw sample buffers often
            // keeps the sensor size (e.g. 960×540 → 540×960 portrait).
            let srcAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: plan.width,
                kCVPixelBufferHeightKey as String: plan.height
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: v, sourcePixelBufferAttributes: srcAttrs)

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
            w.startSession(atSourceTime: pts)
            DebugLog.write("[9] startSession OK at pts=\(CMTimeGetSeconds(pts))")

            // Append the actual frame that triggered this segment right now,
            // synchronously, before anything else can touch the writer. Without
            // this the session's declared start time (pts) has no matching
            // encoded sample, which is what produced the black first frame.
            var appendedFirstPTS = pts
            if let first = firstSampleBuffer, v.isReadyForMoreMediaData {
                // Assign adaptor before first append so scaling can run.
                pixelBufferAdaptor = adaptor
                videoIn = v
                if appendVideoSample(first, to: v) {
                    let dur = CMSampleBufferGetDuration(first)
                    appendedFirstPTS = Self.endPTS(for: pts, duration: dur, fps: plan.frameRate)
                    DebugLog.write("[9b] first frame appended at segment start ✅")
                } else {
                    DebugLog.write("⚠️ first frame append failed, status=\(w.status.rawValue) error=\(w.error?.localizedDescription ?? "nil")")
                }
            } else {
                DebugLog.write("⚠️ no first sample buffer / input not ready yet, black-frame gap possible")
            }

            // Drain frames that arrived while the writer was starting so their
            // PTS timeline stays contiguous with the first frame. Without this
            // Photos reports average fps well below the target (e.g. 27.52 vs 30).
            writerLock.lock()
            let buffered = pendingStartBuffers
            pendingStartBuffers.removeAll(keepingCapacity: true)
            pendingMidBuffers.removeAll(keepingCapacity: false)
            writer = w
            videoIn = v
            pixelBufferAdaptor = adaptor
            audioIn = a
            segmentStart = pts
            var endPTS = appendedFirstPTS
            if !recordStartPTS.isValid { recordStartPTS = pts }
            segmentStartInFlight = false
            writerLock.unlock()

            for buf in buffered {
                let bPTS = CMSampleBufferGetPresentationTimeStamp(buf)
                // Skip the seed frame if it was also handed in as firstSampleBuffer
                // (same PTS) — already appended above.
                if CMTimeCompare(bPTS, pts) == 0 { continue }
                if CMTimeCompare(bPTS, pts) < 0 { continue }
                // Route through appendVideoSample so low-res plans still get scaled.
                if v.isReadyForMoreMediaData, appendVideoSample(buf, to: v) {
                    let bDur = CMSampleBufferGetDuration(buf)
                    endPTS = Self.endPTS(for: bPTS, duration: bDur, fps: plan.frameRate)
                }
            }

            writerLock.lock()
            lastVideoPTS = endPTS
            writerLock.unlock()

            DispatchQueue.main.async { self.clipsThisSession += 1 }
            DebugLog.write("[10] segment fully started ✅ (flushed \(buffered.count) buffered frames)")

        } catch {
            DebugLog.write("❌ startSegment threw: \(error.localizedDescription) | full: \(error)")
            writerLock.lock()
            segmentStartInFlight = false
            pendingStartBuffers.removeAll(keepingCapacity: false)
            pendingMidBuffers.removeAll(keepingCapacity: false)
            wantsRecording = false
            writerLock.unlock()
            DispatchQueue.main.async {
                self.isRecording = false
                self.notice = "Encoder error"
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }


    func finishSegment(_ completion: (() -> Void)? = nil) {
        writerLock.lock()
        guard let w = writer, let v = videoIn else {
            writer = nil; videoIn = nil; audioIn = nil; pixelBufferAdaptor = nil
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

        writer = nil; videoIn = nil; audioIn = nil; pixelBufferAdaptor = nil
        segmentStart = .invalid
        lastVideoDuration = .invalid
        writerLock.unlock()

        guard w.status == .writing else {
            w.cancelWriting()
            completion?()
            return
        }

        v.markAsFinished()
        a?.markAsFinished()
        if end.isValid, start.isValid, CMTimeCompare(end, start) > 0 {
            w.endSession(atSourceTime: end)
        }
        w.finishWriting {
            UserDefaults.standard.removeObject(forKey: Self.inProgressKey)
            UserDefaults.standard.removeObject(forKey: Self.inProgressDestinationKey)

            guard w.status == .completed else {
                DispatchQueue.main.async {
                    self.notice = "Clip failed to save"
                    self.refreshFreeSpace()
                }
                completion?()
                return
            }

            self.generateThumbnail(for: url)
            self.deliver(url, to: destination) {
                DispatchQueue.main.async { self.refreshFreeSpace() }
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

        writer = nil; videoIn = nil; audioIn = nil; pixelBufferAdaptor = nil
        segmentStart = .invalid
        writerLock.unlock()

        if oldWriter.status == .writing {
            oldVideoIn.markAsFinished()
            oldAudioIn?.markAsFinished()
            if oldEnd.isValid, oldStart.isValid, CMTimeCompare(oldEnd, oldStart) > 0 {
                oldWriter.endSession(atSourceTime: oldEnd)
            }
            oldWriter.finishWriting {
                self.generateThumbnail(for: oldUrl)
                self.deliver(oldUrl, to: destination) {
                    DispatchQueue.main.async { self.refreshFreeSpace() }
                }
            }
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
        let defaults = UserDefaults.standard
        guard let name = defaults.string(forKey: Self.inProgressKey) else { return }

        let url = Self.clipsDirectory.appendingPathComponent(name)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0

        guard size > 0 else {
            defaults.removeObject(forKey: Self.inProgressKey)
            defaults.removeObject(forKey: Self.inProgressDestinationKey)
            try? FileManager.default.removeItem(at: url)
            return
        }

        // Prefer the destination that was active when the clip was started
        // (stored at segment start). Fall back to current setting only if
        // the key is missing (older builds / interrupted before the key was added).
        let destRaw = defaults.string(forKey: Self.inProgressDestinationKey)
        let destination = destRaw.flatMap { SaveLocation(rawValue: $0) } ?? settings.saveLocation

        defaults.removeObject(forKey: Self.inProgressKey)
        defaults.removeObject(forKey: Self.inProgressDestinationKey)
        generateThumbnail(for: url)
        deliver(url, to: destination) { [weak self] in
            DispatchQueue.main.async {
                self?.notice = "Recovered interrupted clip"
                self?.refreshFreeSpace()
            }
        }
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
                DispatchQueue.main.async {
                    self.lastClipThumbnail = img
                    self.lastClipURL = url
                }
            } else if let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                let img = UIImage(cgImage: cgImage)
                DispatchQueue.main.async {
                    self.lastClipThumbnail = img
                    self.lastClipURL = url
                }
            }
        }
    }

    func ensurePhotosAccess() {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
        }
        // Denied is handled by deliver() — clip is kept in Files, no crash.
    }

    func deliver(_ url: URL, to destination: SaveLocation, done: @escaping () -> Void) {
        guard destination == .photos else {
            DispatchQueue.main.async { self.notice = "Saved to Files" }
            done()
            return
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .authorized || status == .limited else {
            DispatchQueue.main.async {
                self.notice = "Saved to Files (Photo access denied)"
            }
            done()
            return
        }

        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            // Keep the source file until we know Photos accepted it, then
            // delete it ourselves. Using shouldMoveFile=true is risky if the
            // library later fails to import (file would be gone).
            options.shouldMoveFile = false
            request.addResource(with: .video, fileURL: url, options: options)
        } completionHandler: { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if success {
                    self.notice = "Saved to Photos"
                    // Keep the local copy so Recorded Clips gallery can list it.
                    // User can delete from the gallery when they want the space.
                } else {
                    self.notice = "Saved to Files (Photos refused)"
                }
            }
            done()
        }
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
            DispatchQueue.main.async { self.freeBytes = Int64(bytes) }
        }
    }

    static var clipsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func newClipURL() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        // A plain timestamp string only has 1-second resolution, so if
        // startSegment somehow runs more than once in the same second
        // (e.g. duplicate dispatches racing on ioQueue), two writers could
        // both try to create/open the exact same file path at once —
        // AVAssetWriter's startWriting() then fails with "Cannot Save"
        // (AVFoundationErrorDomain -11823 / NSOSStatusErrorDomain -12412)
        // because the OS won't let two writers claim the same file. A short
        // random suffix guarantees uniqueness even if that race happens, as
        // a defense-in-depth alongside the dedicated startSegment guard.
        let suffix = String(format: "%04X", UInt16.random(in: 0...0xFFFF))
        return clipsDirectory.appendingPathComponent("LowPolyCam_\(f.string(from: Date()))_\(suffix).mov")
    }

    // MARK: Video Matrix Orientation

    static func transform(width: Int, height: Int, isFront: Bool) -> CGAffineTransform {
        let w = CGFloat(width)
        let h = CGFloat(height)

        if !isFront {
            return CGAffineTransform(translationX: h, y: 0).rotated(by: .pi / 2)
        } else {
            return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        }
    }

    enum RecorderError: LocalizedError {
        case cannotAddInput
        var errorDescription: String? { "Encoder rejected format settings" }
    }
}
