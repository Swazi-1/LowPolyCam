import AVFoundation
import UIKit
import Photos
import Combine

/// Capture pipeline, built on AVCaptureMovieFileOutput - the same direct
/// hardware-to-disk recorder the built-in Camera app uses. An earlier version
/// of this class hand-rolled the pipeline with AVCaptureVideoDataOutput and a
/// manual AVAssetWriter, copying every frame across queues and re-validating
/// it in app code; at 1080p60 on an A10 that left less headroom than Apple's
/// own path and measurably dropped frames (~59.35 fps instead of ~59.97).
/// Handing frames to the system output directly is what closes that gap.
///
/// The trade-off: AVCaptureMovieFileOutput does not support the seamless
/// writer-swap this app used to do at each 10-minute segment cut, so segment
/// boundaries now have a brief real gap (tens to low-hundreds of ms) instead
/// of being perfectly continuous. Within a segment, recording should be
/// smoother than before.
///
/// The sensor runs at 720p for every export at 720p or below - the output
/// scales down for us - and only switches up to a real 1080p capture format
/// when 1080p is actually selected. Frame rate (24/30/60) is applied by
/// searching the device's own formats for one that actually supports it and
/// locking to it directly.
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
    /// User-initiated QoS so our own configuration calls are not left waiting
    /// behind lower-priority work - the actual frame-by-frame encode happens
    /// inside AVFoundation's own real-time threads, not on this queue.
    private let sessionQueue = DispatchQueue(label: "lowpolycam.session", qos: .userInitiated)

    private let movieOutput = AVCaptureMovieFileOutput()
    private var cameraInput: AVCaptureDeviceInput?
    private var micInput: AVCaptureDeviceInput?
    private var position: AVCaptureDevice.Position = .back
    private var isConfigured = false
    private var spaceTimer: Timer?
    private var elapsedTimer: Timer?

    private var plan: EncodePlan?
    private var currentDestination: SaveLocation = .files
    /// True from the moment recording starts until the moment it is told to
    /// stop - read inside the recording delegate to decide whether a
    /// finished segment should roll straight into the next one.
    private var wantsRecording = false
    private var recordingStartDate: Date?
    private var freeBytesSnapshot: Int64 = .max
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

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

        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }

        session.commitConfiguration()

        configureMirrorAndStabilization()
        applyActiveFormat()
        refreshTorchState()
        syncMicInput()
    }

    /// Mirroring and stabilisation are configured once at setup (and again
    /// after flipping cameras); output orientation is set separately, fresh
    /// at the start of each recording, since it depends on how the phone is
    /// being held right then.
    private func configureMirrorAndStabilization() {
        guard let c = movieOutput.connection(with: .video) else { return }
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
        guard let c = connection ?? movieOutput.connection(with: .video) else { return }
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
            // more light per frame - exactly what fights a steady frame rate,
            // so it stays off.
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

            self.configureMirrorAndStabilization()
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
        let orientation = Self.captureOrientation(for: currentInterfaceOrientation())

        notice = nil
        elapsed = 0
        clipsThisSession = 0
        isRecording = true
        UIApplication.shared.isIdleTimerDisabled = true
        recordingStartDate = Date()
        startElapsedTimer()

        sessionQueue.async {
            self.plan = newPlan
            self.currentDestination = newPlan.saveLocation
            self.wantsRecording = true
            self.movieOutput.movieFragmentInterval = CMTime(seconds: Self.fragmentSeconds, preferredTimescale: 600)
            self.movieOutput.maxRecordedDuration = CMTime(seconds: Self.segmentSeconds, preferredTimescale: 1)
            self.movieOutput.minFreeDiskSpaceLimit = Self.reserveBytes
            self.applyRecordingSettings(plan: newPlan, orientation: orientation)
            self.beginSegment()
        }
    }

    /// Applies encode settings and orientation once, at the start of a
    /// recording session - they hold for every segment that session rolls
    /// through, since Settings cannot be reached again until recording stops.
    private func applyRecordingSettings(plan: EncodePlan, orientation: AVCaptureVideoOrientation) {
        guard let videoConnection = movieOutput.connection(with: .video) else { return }
        if videoConnection.isVideoOrientationSupported {
            videoConnection.videoOrientation = orientation
        }
        let videoSettings = Encoder.movieVideoSettings(for: plan, output: movieOutput)
        movieOutput.setOutputSettings(videoSettings, for: videoConnection)

        if plan.hasAudio, let audioConnection = movieOutput.connection(with: .audio) {
            movieOutput.setOutputSettings(Encoder.movieAudioSettings(for: plan), for: audioConnection)
        }
    }

    private func beginSegment() {
        guard freeBytesSnapshot > Self.reserveBytes else {
            wantsRecording = false
            DispatchQueue.main.async {
                self.isRecording = false
                self.isSaving = false
                self.notice = "Stopped - storage is almost full."
                UIApplication.shared.isIdleTimerDisabled = false
            }
            endBackgroundTaskIfNeeded()
            return
        }
        movieOutput.startRecording(to: Self.newClipURL(), recordingDelegate: self)
    }

    func stopRecording(notice message: String?) {
        guard isRecording else { return }

        // isSaving flips the record button into a spinner immediately, so the
        // tap is never left looking like it did nothing while the last
        // segment finishes writing and (if Photos is the destination)
        // importing.
        isRecording = false
        isSaving = true
        UIApplication.shared.isIdleTimerDisabled = false
        notice = message
        stopElapsedTimer()
        refreshFreeSpace()

        // Keep the app alive long enough to close the file - and, for Photos,
        // to finish the import - if we are on the way to the background.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "finishClip")

        sessionQueue.async {
            self.wantsRecording = false
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()   // finishes on the delegate below
            } else {
                // Stop landed in the brief gap between two segments - there is
                // nothing in flight to wait for.
                DispatchQueue.main.async { self.isSaving = false }
                self.endBackgroundTaskIfNeeded()
            }
        }
    }

    @objc private func willResignActive() {
        // iOS shuts the camera down in the background, there is no entitlement
        // that changes this. Close the file cleanly instead of losing it.
        guard isRecording else { return }
        stopRecording(notice: "Recording stopped - the app left the screen.")
    }

    private func endBackgroundTaskIfNeeded() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    // MARK: Elapsed time

    /// Wall-clock based rather than derived from media timestamps - simpler,
    /// and it reflects true recording duration even if a frame were ever
    /// dropped, which a PTS-derived clock would not.
    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.recordingStartDate else { return }
            self.elapsed = Date().timeIntervalSince(start)
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
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
            self.sessionQueue.async { self.freeBytesSnapshot = Int64(bytes) }
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

    /// AVCaptureVideoOrientation and UIInterfaceOrientation share raw values.
    /// Setting this directly on the connection lets the system map it through
    /// the sensor's own mounting rotation and mirroring - which differs
    /// between the front and back cameras - rather than us reimplementing
    /// that mapping by hand.
    private static func captureOrientation(for o: UIInterfaceOrientation) -> AVCaptureVideoOrientation {
        AVCaptureVideoOrientation(rawValue: o.rawValue) ?? .portrait
    }
}

// MARK: - Recording delegate

extension CameraRecorder: AVCaptureFileOutputRecordingDelegate {

    func fileOutput(_ output: AVCaptureFileOutput,
                    didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async { self.clipsThisSession += 1 }
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {

        // A non-nil error here does not necessarily mean the clip is bad -
        // stopRecording() and hitting maxRecordedDuration both legitimately
        // report one. The flag in the error's userInfo is the real signal.
        let nsError = error as NSError?
        let recordedOK = (nsError == nil)
            || ((nsError?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false)

        guard recordedOK else {
            let reason = error?.localizedDescription ?? "unknown error"
            DispatchQueue.main.async { self.notice = "Clip failed to save: \(reason)" }
            continueOrFinish()
            return
        }

        deliver(outputFileURL, to: currentDestination) { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async { self.refreshFreeSpace() }
            self.continueOrFinish()
        }
    }

    /// Rolls straight into the next segment if the user is still recording,
    /// or wraps things up if this was the final segment after a stop.
    private func continueOrFinish() {
        sessionQueue.async {
            if self.wantsRecording {
                self.beginSegment()
            } else {
                DispatchQueue.main.async { self.isSaving = false }
                self.endBackgroundTaskIfNeeded()
            }
        }
    }
}
