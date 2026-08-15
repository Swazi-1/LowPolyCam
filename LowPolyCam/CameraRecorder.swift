import AVFoundation
import UIKit
import Photos
import Combine

/// Capture pipeline.
///
/// The sensor runs at 720p for every export at 720p or below - the encoder
/// scales down for us - and only switches up to a real 1080p capture format
/// when 1080p is actually selected. Frame rate (24/30/60) is applied by
/// searching the device's own formats for one that actually supports it and
/// locking to it directly, rather than trusting a session preset to guess
/// right; that is also what keeps 60 fps steady instead of stuttering.
///
/// Long recordings are split into segments (see `segmentSeconds`) and each
/// segment is written as a fragmented movie, so a crash, a dead battery or iOS
/// killing the app costs you at most a few seconds - not the whole recording.
final class CameraRecorder: NSObject, ObservableObject {

    // MARK: Tunables

    /// A new file is started every this many seconds while recording.
    static let segmentSeconds: Double = 600          // 10 minutes
    /// How often the movie index is flushed to disk. Worst-case loss on a crash.
    static let fragmentSeconds: Double = 4
    /// Recording stops when free space drops below this.
    static let reserveBytes: Int64 = 300 * 1024 * 1024

    // MARK: Published state

    @Published private(set) var isRecording = false
    /// True from the moment "stop" is tapped until the clip is actually
    /// written and delivered. The record button shows a spinner and ignores
    /// taps during this window, so a slow save never looks like a dead tap.
    @Published private(set) var isSaving = false
    @Published private(set) var isSessionRunning = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var clipsThisSession = 0
    @Published private(set) var freeBytes: Int64 = 0
    @Published private(set) var hasTorch = false
    @Published private(set) var torchOn = false
    @Published private(set) var isFrontCamera = false
    @Published private(set) var stabilizationSupported = true
    @Published var notice: String?

    let session = AVCaptureSession()

    // MARK: Private

    private let settings: AppSettings
    private let sessionQueue = DispatchQueue(label: "lowpolycam.session")
    private let ioQueue = DispatchQueue(label: "lowpolycam.io")

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var cameraInput: AVCaptureDeviceInput?
    private var micInput: AVCaptureDeviceInput?
    private var position: AVCaptureDevice.Position = .back
    private var isConfigured = false
    private var spaceTimer: Timer?

    // Writer state. Only ever touched on ioQueue.
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private var segmentStart = CMTime.invalid
    private var lastVideoPTS = CMTime.invalid
    private var recordStartPTS = CMTime.invalid
    private var wantsRecording = false
    private var plan: EncodePlan?
    private var clipTransform = CGAffineTransform.identity
    private var freeBytesSnapshot: Int64 = .max
    private var lastElapsedPush = CMTime.invalid

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        refreshFreeSpace()
        NotificationCenter.default.addObserver(
            self, selector: #selector(willResignActive),
            name: UIApplication.willResignActiveNotification, object: nil)
    }

    // MARK: Lifecycle

    func start() {
        refreshFreeSpace()
        spaceTimer?.invalidate()
        spaceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshFreeSpace()
        }

        requestAccess { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                DispatchQueue.main.async { self.permissionDenied = true }
                return
            }
            self.sessionQueue.async {
                if !self.isConfigured {
                    self.configureSession()
                    self.isConfigured = true
                }
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async { self.isSessionRunning = self.session.isRunning }
            }
        }
    }

    func stop() {
        spaceTimer?.invalidate()
        spaceTimer = nil
        if isRecording { stopRecording(notice: nil) }
        setTorch(on: false)
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isSessionRunning = false }
        }
    }

    private func requestAccess(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { videoOK in
            guard videoOK else { done(false); return }
            guard self.settings.recordAudio else { done(true); return }
            AVCaptureDevice.requestAccess(for: .audio) { _ in done(true) }
        }
    }

    // MARK: Session setup

    private func configureSession() {
        session.beginConfiguration()

        // Resolution and frame rate are both driven by an explicitly chosen
        // AVCaptureDevice.Format (see applyActiveFormat), not a canned preset -
        // presets cannot express "1080p at 60 fps specifically."
        session.sessionPreset = .inputPriority

        if let device = Self.camera(at: position),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            cameraInput = input
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoOutput.setSampleBufferDelegate(self, queue: ioQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        audioOutput.setSampleBufferDelegate(self, queue: ioQueue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        session.commitConfiguration()

        configureVideoConnection()
        applyActiveFormat()
        refreshTorchState()
        syncMicInput()
    }

    /// The buffers are kept in the sensor's own landscape orientation and the
    /// rotation is stored as metadata on the file instead. Rotating pixels for
    /// hours would cost real battery for no benefit.
    private func configureVideoConnection() {
        guard let c = videoOutput.connection(with: .video) else { return }
        if c.isVideoOrientationSupported { c.videoOrientation = .landscapeRight }
        if c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = false
        }
        applyStabilization(to: c)
    }

    /// OIS/video stabilisation. Not every camera or format supports it - the
    /// front camera on older phones generally does not - so the UI is told
    /// whether the switch actually does anything here.
    private func applyStabilization(to connection: AVCaptureConnection? = nil) {
        guard let c = connection ?? videoOutput.connection(with: .video) else { return }
        let supported = c.isVideoStabilizationSupported
        if supported {
            c.preferredVideoStabilizationMode = settings.stabilization ? .auto : .off
        }
        DispatchQueue.main.async { self.stabilizationSupported = supported }
    }

    /// Called when the toggle changes.
    func updateStabilization() {
        sessionQueue.async { self.applyStabilization() }
    }

    /// Finds a real capture format for the resolution+frame rate currently
    /// selected in Settings and locks the device to it. Called at setup, after
    /// flipping cameras (front and back support different combinations), and
    /// whenever the resolution or frame rate setting changes.
    private func applyActiveFormat() {
        guard let device = cameraInput?.device else { return }
        let dims = settings.resolution.captureDimensions
        let fps = Double(settings.frameRate.value)

        guard let format = Self.bestFormat(for: device, width: dims.w, height: dims.h, fps: fps) else {
            DispatchQueue.main.async {
                self.notice = "This camera can't do \(dims.w)x\(dims.h) at \(Int(fps)) fps here - using its closest mode instead."
            }
            return
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let d = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
            device.activeVideoMinFrameDuration = d
            device.activeVideoMaxFrameDuration = d
            // Low-light boost quietly drops the effective frame rate to gather
            // more light per frame - exactly what fights a steady 60 fps, so
            // it stays off; a locked frame rate matters more here than
            // brightness in dark scenes.
            device.unlockForConfiguration()
        } catch {
            DispatchQueue.main.async { self.notice = "Could not lock this camera's frame rate." }
        }
    }

    /// Searches the device's own formats for the smallest one that is still
    /// big enough for `width`x`height` and actually supports `fps` - a session
    /// preset cannot express an exact resolution+frame-rate combination like
    /// "1080p at 60".
    private static func bestFormat(for device: AVCaptureDevice, width: Int, height: Int, fps: Double) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var bestScore = Int.max
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard Int(dims.width) >= width, Int(dims.height) >= height else { continue }
            let supportsFPS = format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= fps && fps <= $0.maxFrameRate
            }
            guard supportsFPS else { continue }
            // Prefer the closest match in area, and penalise pixel-binned
            // formats (lower real detail) when a same-size unbinned one exists.
            let areaDelta = Int(dims.width) * Int(dims.height) - width * height
            let score = areaDelta + (format.isVideoBinned ? 1_000_000 : 0)
            if score < bestScore {
                bestScore = score
                best = format
            }
        }
        return best
    }

    /// Called from Settings when resolution or frame rate changes.
    func updateCaptureFormat() {
        sessionQueue.async { self.applyActiveFormat() }
    }

    /// Adds or removes the microphone to match the setting. With audio off the
    /// app never touches the audio session, so music keeps playing.
    func syncMicInput() {
        // The mic prompt may not have been shown yet if sound was off at first launch.
        if settings.recordAudio,
           AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                self?.addOrRemoveMic()
            }
            return
        }
        addOrRemoveMic()
    }

    private func addOrRemoveMic() {
        sessionQueue.async {
            let want = self.settings.recordAudio
            if want, self.micInput == nil {
                guard let mic = AVCaptureDevice.default(for: .audio),
                      let input = try? AVCaptureDeviceInput(device: mic) else { return }
                self.session.beginConfiguration()
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.micInput = input
                }
                self.session.commitConfiguration()
            } else if !want, let input = self.micInput {
                self.session.beginConfiguration()
                self.session.removeInput(input)
                self.session.commitConfiguration()
                self.micInput = nil
            }
        }
    }

    func flipCamera() {
        guard !isRecording else { return }
        setTorch(on: false)
        sessionQueue.async {
            let next: AVCaptureDevice.Position = (self.position == .back) ? .front : .back
            guard let device = Self.camera(at: next),
                  let input = try? AVCaptureDeviceInput(device: device) else { return }

            self.session.beginConfiguration()
            if let old = self.cameraInput { self.session.removeInput(old) }
            if self.session.canAddInput(input) {
                self.session.addInput(input)
                self.cameraInput = input
                self.position = next
            } else if let old = self.cameraInput {
                self.session.addInput(old)
            }
            self.session.commitConfiguration()

            self.configureVideoConnection()
            self.applyActiveFormat()
            self.refreshTorchState()
            DispatchQueue.main.async { self.isFrontCamera = (next == .front) }
        }
    }

    private static func camera(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video)
    }

    // MARK: Torch

    private func refreshTorchState() {
        let device = cameraInput?.device
        let available = device?.hasTorch ?? false
        let on = (device?.torchMode == .on)
        DispatchQueue.main.async {
            self.hasTorch = available
            self.torchOn = available && on
        }
    }

    func toggleTorch() {
        setTorch(on: !torchOn)
    }

    private func setTorch(on: Bool) {
        sessionQueue.async {
            guard let device = self.cameraInput?.device, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                device.torchMode = on ? .on : .off
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.torchOn = on }
            } catch {
                DispatchQueue.main.async { self.notice = "The torch is busy right now." }
            }
        }
    }

    // MARK: Recording control

    func toggleRecording() {
        isRecording ? stopRecording(notice: nil) : startRecording()
    }

    func startRecording() {
        guard !isRecording else { return }
        guard freeBytes > Self.reserveBytes else {
            notice = "Not enough free space to start."
            return
        }

        if settings.saveLocation == .photos { ensurePhotosAccess() }

        let newPlan = Encoder.plan(for: settings)
        // Read the main-thread-synchronised mirror of the camera position,
        // not the raw session-queue-owned `position` var, so this can never
        // race a flip that is still in flight.
        let transform = Self.transform(forInterface: currentInterfaceOrientation(), isFrontCamera: isFrontCamera)

        ioQueue.async {
            self.plan = newPlan
            self.clipTransform = transform
            self.recordStartPTS = .invalid
            self.lastElapsedPush = .invalid
            self.wantsRecording = true
        }

        notice = nil
        elapsed = 0
        clipsThisSession = 0
        isRecording = true
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stopRecording(notice message: String?) {
        guard isRecording else { return }

        // isSaving flips the record button into a spinner immediately, so the
        // tap is never left looking like it did nothing while the clip
        // finishes writing and (if Photos is the destination) importing.
        isRecording = false
        isSaving = true
        UIApplication.shared.isIdleTimerDisabled = false
        notice = message
        refreshFreeSpace()

        // Keep the app alive long enough to close the file - and, for Photos,
        // to finish the import - if we are on the way to the background.
        var task = UIApplication.shared.beginBackgroundTask(withName: "finishClip")

        ioQueue.async {
            self.wantsRecording = false
            self.finishSegment {
                DispatchQueue.main.async { self.isSaving = false }
                if task != .invalid {
                    UIApplication.shared.endBackgroundTask(task)
                    task = .invalid
                }
            }
        }
    }

    @objc private func willResignActive() {
        // iOS shuts the camera down in the background, there is no entitlement
        // that changes this. Close the file cleanly instead of losing it.
        guard isRecording else { return }
        stopRecording(notice: "Recording stopped - the app left the screen.")
    }

    // MARK: Segments

    private func startSegment(at pts: CMTime) {
        guard let plan = plan else { return }

        guard freeBytesSnapshot > Self.reserveBytes else {
            wantsRecording = false
            DispatchQueue.main.async {
                self.isRecording = false
                self.notice = "Stopped - storage is almost full."
                UIApplication.shared.isIdleTimerDisabled = false
            }
            return
        }

        do {
            let url = Self.newClipURL()
            let w = try AVAssetWriter(outputURL: url, fileType: .mov)
            w.movieFragmentInterval = CMTime(seconds: Self.fragmentSeconds, preferredTimescale: 600)

            let v = AVAssetWriterInput(mediaType: .video,
                                       outputSettings: Encoder.videoSettings(for: plan, writer: w))
            v.expectsMediaDataInRealTime = true
            v.transform = clipTransform
            guard w.canAdd(v) else { throw RecorderError.cannotAddInput }
            w.add(v)

            var a: AVAssetWriterInput?
            if plan.hasAudio, let aSettings = audioSettings(for: plan, writer: w) {
                let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
                ai.expectsMediaDataInRealTime = true
                if w.canAdd(ai) { w.add(ai); a = ai }
            }

            guard w.startWriting() else {
                throw w.error ?? RecorderError.cannotAddInput
            }
            w.startSession(atSourceTime: pts)

            writer = w
            videoIn = v
            audioIn = a
            segmentStart = pts
            lastVideoPTS = pts
            if !recordStartPTS.isValid { recordStartPTS = pts }

            DispatchQueue.main.async { self.clipsThisSession += 1 }

        } catch {
            wantsRecording = false
            let text = error.localizedDescription
            DispatchQueue.main.async {
                self.isRecording = false
                self.notice = "Could not start recording: \(text)"
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    private func finishSegment(_ completion: (() -> Void)? = nil) {
        guard let w = writer, let v = videoIn else {
            writer = nil; videoIn = nil; audioIn = nil
            completion?()
            return
        }
        let a = audioIn
        let end = lastVideoPTS
        let destination = plan?.saveLocation ?? .files
        let url = w.outputURL

        writer = nil; videoIn = nil; audioIn = nil
        segmentStart = .invalid

        guard w.status == .writing else {
            w.cancelWriting()
            completion?()
            return
        }

        v.markAsFinished()
        a?.markAsFinished()
        if end.isValid { w.endSession(atSourceTime: end) }
        w.finishWriting {
            guard w.status == .completed else {
                let reason = w.error?.localizedDescription ?? "unknown error"
                DispatchQueue.main.async {
                    self.notice = "Clip failed to save: \(reason)"
                    self.refreshFreeSpace()
                }
                completion?()
                return
            }
            // completion (which ends the background task and clears isSaving)
            // waits for the Photos import too, not just the file write - a
            // backgrounded app was previously free to get its background time
            // revoked mid-import, which could silently drop the clip.
            self.deliver(url, to: destination) {
                DispatchQueue.main.async { self.refreshFreeSpace() }
                completion?()
            }
        }
    }

    /// AVAssetWriterInput does not throw on invalid settings - it raises an
    /// Objective-C exception, which crashes the app outright since Swift has no
    /// way to catch it. Every candidate is checked with `canApply` before it is
    /// ever handed to a real input, so a bad bitrate degrades quietly instead.
    private func audioSettings(for plan: EncodePlan, writer w: AVAssetWriter) -> [String: Any]? {

        func valid(_ s: [String: Any]) -> Bool {
            w.canApply(outputSettings: s, forMediaType: .audio)
        }

        if var s = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) {
            let recommended = s
            s[AVEncoderBitRateKey] = plan.audioBitrate
            if valid(s) { return s }
            // Our bitrate override made it invalid - the untouched recommended
            // settings are guaranteed valid, so use those instead of crashing.
            if valid(recommended) { return recommended }
        }

        let fallback: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100,
            AVEncoderBitRateKey: plan.audioBitrate
        ]
        if valid(fallback) { return fallback }

        // Nothing validated - record video-only rather than crash.
        return nil
    }

    // MARK: Delivering finished clips

    private func ensurePhotosAccess() {
        guard PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
    }

    private func deliver(_ url: URL, to destination: SaveLocation, done: @escaping () -> Void) {
        guard destination == .photos else {
            DispatchQueue.main.async { self.notice = "Clip saved to Files." }
            done()
            return
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .authorized || status == .limited else {
            DispatchQueue.main.async {
                self.notice = "No photo access - clip kept in Files instead."
            }
            done()
            return
        }

        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            // Move rather than copy, so a clip never takes up space twice.
            options.shouldMoveFile = true
            request.addResource(with: .video, fileURL: url, options: options)
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                if success {
                    self.notice = "Clip saved to Photos."
                } else {
                    let reason = error?.localizedDescription ?? "unknown error"
                    self.notice = "Photos refused the clip (\(reason)) - it is still in Files."
                }
            }
            done()
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

    private static func newClipURL() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return clipsDirectory.appendingPathComponent("LowPolyCam_\(f.string(from: Date())).mov")
    }

    // MARK: Orientation

    private func currentInterfaceOrientation() -> UIInterfaceOrientation {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.interfaceOrientation ?? .portrait
    }

    /// The buffers arrive in `.landscapeRight`. This is the rotation a player
    /// has to apply to show the clip the way the phone was held.
    ///
    /// The front sensor is physically mounted 180 degrees rotated relative to
    /// the back one, so the same nominal buffer orientation needs the
    /// opposite rotation to come out upright - without this, front-camera
    /// clips record flipped regardless of which way the phone was held.
    private static func transform(forInterface o: UIInterfaceOrientation, isFrontCamera: Bool) -> CGAffineTransform {
        let angle: CGFloat
        switch o {
        case .portrait:           angle = .pi / 2
        case .landscapeRight:     angle = 0
        case .landscapeLeft:      angle = .pi
        case .portraitUpsideDown: angle = -.pi / 2
        default:                  angle = .pi / 2
        }
        return CGAffineTransform(rotationAngle: isFrontCamera ? angle + .pi : angle)
    }

    enum RecorderError: LocalizedError {
        case cannotAddInput
        var errorDescription: String? { "the encoder rejected these settings" }
    }
}

// MARK: - Sample buffers

extension CameraRecorder: AVCaptureVideoDataOutputSampleBufferDelegate,
                          AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let isVideo = (output === videoOutput)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        guard wantsRecording else {
            if writer != nil { finishSegment() }
            return
        }

        if isVideo {
            if writer == nil {
                startSegment(at: pts)
            } else if segmentStart.isValid,
                      CMTimeGetSeconds(CMTimeSubtract(pts, segmentStart)) >= Self.segmentSeconds {
                finishSegment()
                startSegment(at: pts)
            }
        }

        guard let w = writer, w.status == .writing else { return }
        guard segmentStart.isValid, CMTimeCompare(pts, segmentStart) >= 0 else { return }

        if isVideo {
            if videoIn?.isReadyForMoreMediaData == true {
                videoIn?.append(sampleBuffer)
                lastVideoPTS = pts
            }
            pushElapsed(pts)
        } else {
            if audioIn?.isReadyForMoreMediaData == true {
                audioIn?.append(sampleBuffer)
            }
        }
    }

    /// Publishes the running time about four times a second instead of thirty.
    private func pushElapsed(_ pts: CMTime) {
        guard recordStartPTS.isValid else { return }
        if lastElapsedPush.isValid,
           CMTimeGetSeconds(CMTimeSubtract(pts, lastElapsedPush)) < 0.25 { return }
        lastElapsedPush = pts
        let seconds = CMTimeGetSeconds(CMTimeSubtract(pts, recordStartPTS))
        DispatchQueue.main.async { self.elapsed = seconds }
    }
}
