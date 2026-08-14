import AVFoundation
import UIKit
import Combine

/// Capture pipeline.
///
/// The camera always runs at 1280x720/30. The chosen resolution and quality are
/// applied by the encoder (AVAssetWriter scales down for us), so changing a
/// setting never has to tear down and rebuild the capture session.
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
    @Published private(set) var isSessionRunning = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var clipsThisSession = 0
    @Published private(set) var freeBytes: Int64 = 0
    @Published var notice: String?

    let session = AVCaptureSession()

    // MARK: Private

    private let settings: AppSettings
    private let sessionQueue = DispatchQueue(label: "lowbitcam.session")
    private let ioQueue = DispatchQueue(label: "lowbitcam.io")

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
        session.sessionPreset = .hd1280x720

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
        lockFrameRate()
        syncMicInput()
    }

    /// The buffers are kept in the sensor's own landscape orientation and the
    /// rotation is stored as metadata on the file instead. Rotating pixels for
    /// hours would cost real battery for no benefit.
    private func configureVideoConnection() {
        guard let c = videoOutput.connection(with: .video) else { return }
        if c.isVideoOrientationSupported { c.videoOrientation = .landscapeRight }
        if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .auto }
        if c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = false
        }
    }

    private func lockFrameRate() {
        guard let device = cameraInput?.device else { return }
        let fps = Double(Encoder.frameRate)
        let supported = device.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= fps && fps <= $0.maxFrameRate
        }
        guard supported else { return }
        do {
            try device.lockForConfiguration()
            let d = CMTime(value: 1, timescale: CMTimeScale(Encoder.frameRate))
            device.activeVideoMinFrameDuration = d
            device.activeVideoMaxFrameDuration = d
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = true
            }
            device.unlockForConfiguration()
        } catch {
            // Not fatal - we just record at whatever rate the device picks.
        }
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
            self.lockFrameRate()
        }
    }

    private static func camera(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video)
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

        let newPlan = Encoder.plan(for: settings)
        let transform = Self.transform(forInterface: currentInterfaceOrientation())

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

        // Keep the app alive long enough to close the file if we are on the way
        // to the background.
        var task = UIApplication.shared.beginBackgroundTask(withName: "finishClip")

        ioQueue.async {
            self.wantsRecording = false
            self.finishSegment {
                if task != .invalid {
                    UIApplication.shared.endBackgroundTask(task)
                    task = .invalid
                }
            }
        }

        isRecording = false
        UIApplication.shared.isIdleTimerDisabled = false
        notice = message
        refreshFreeSpace()
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
            DispatchQueue.main.async { self.refreshFreeSpace() }
            completion?()
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
        return clipsDirectory.appendingPathComponent("LowBitCam_\(f.string(from: Date())).mov")
    }

    // MARK: Orientation

    private func currentInterfaceOrientation() -> UIInterfaceOrientation {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.interfaceOrientation ?? .portrait
    }

    /// The buffers arrive in `.landscapeRight`. This is the rotation a player
    /// has to apply to show the clip the way the phone was held.
    private static func transform(forInterface o: UIInterfaceOrientation) -> CGAffineTransform {
        let angle: CGFloat
        switch o {
        case .portrait:           angle = .pi / 2
        case .landscapeRight:     angle = 0
        case .landscapeLeft:      angle = .pi
        case .portraitUpsideDown: angle = -.pi / 2
        default:                  angle = .pi / 2
        }
        return CGAffineTransform(rotationAngle: angle)
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
