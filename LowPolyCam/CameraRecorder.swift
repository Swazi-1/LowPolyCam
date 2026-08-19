import AVFoundation
import UIKit
import Photos
import MediaPlayer
import CoreMotion
import Combine
import AudioToolbox
import ImageIO

final class CameraRecorder: NSObject, ObservableObject {

    // MARK: Debug file logger
    // Writes to a plain text file inside the app's Documents folder so it
    // can be pulled off-device via the Files app (On My iPhone > LowPolyCam)
    // without needing Xcode/a Mac. Call DebugLog.write(...) anywhere.
    enum DebugLog {
        static let url: URL = {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return dir.appendingPathComponent("recording_debug_log.txt")
        }()

        private static let dateFormatter: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            return f
        }()

        static func write(_ message: String) {
            // Reuse formatter; append on a utility queue so the hot path
            // (segment start/stop) never blocks on disk open/seek/close.
            let stamp = dateFormatter.string(from: Date())
            let line = "[\(stamp)] \(message)\n"
            print(line, terminator: "")
            guard let data = line.data(using: .utf8) else { return }
            DispatchQueue.global(qos: .utility).async {
                if FileManager.default.fileExists(atPath: url.path) {
                    if let handle = try? FileHandle(forWritingTo: url) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        try? handle.close()
                    }
                } else {
                    try? data.write(to: url)
                }
            }
        }

        static func reset() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Tunables

    static let fragmentSeconds: Double = 4
    static let reserveBytes: Int64 = 300 * 1024 * 1024

    // How long (in seconds) after a fresh record start to silently discard
    // video frames before letting any reach the writer, to cover the AE/AGC
    // brightness ramp on the newly-applied recording format. Frame count is
    // derived from this and the actual recording fps (see startRecording()),
    // clamped to a sane range so a bad fps read can't discard too much or
    // too little.
    static let recordStartWarmupSeconds: Double = 0.15
    static let recordStartWarmupFrameFloor = 2
    static let recordStartWarmupFrameCeiling = 14
    private static let inProgressKey = "inProgressClipName"

    // MARK: Published state

    @Published private(set) var isRecording = false
    @Published private(set) var isSaving = false
    @Published private(set) var isSessionRunning = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var clipsThisSession = 0
    @Published private(set) var droppedFrames = 0
    @Published private(set) var freeBytes: Int64 = 0
    @Published private(set) var hasTorch = false
    @Published private(set) var torchOn = false
    /// Front camera has no physical torch. This drives a screen-illumination
    /// "flash" for selfies instead (see CameraScreen's performFrontFlashCapture),
    /// same idea as the stock Camera app's selfie flash.
    @Published var frontFlashEnabled = false
    @Published private(set) var isFrontCamera = false
    @Published private(set) var isSwitchingCamera = false
    @Published private(set) var stabilizationSupported = true
    @Published private(set) var availableFrameRates: [FrameRate] = FrameRate.allCases
    @Published private(set) var availableResolutions: [Resolution] = Resolution.allCases
    @Published private(set) var availableSlowMoRates: [SlowMoFrameRate] = SlowMoFrameRate.allCases
    @Published private(set) var availableSlowMoResolutions: [Resolution] = [.p1080, .p720]
    @Published private(set) var isSlowMoSupportedOnCurrentLens = true
    @Published private(set) var batteryPercent: Int = -1
    @Published private(set) var batteryCharging = false
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var maxZoomFactor: CGFloat = 1
    @Published private(set) var minZoomFactor: CGFloat = 1
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var lastClipThumbnail: UIImage?
    @Published private(set) var lastClipURL: URL?

    // Photo mode
    @Published private(set) var isCapturingPhoto = false
    @Published private(set) var availablePhotoMegapixels: [PhotoMegapixels] = PhotoMegapixels.allCases
    @Published private(set) var lastPhotoThumbnail: UIImage?

    // Thermal state
    @Published private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    // Level Telemetry & Physical Orientation
    @Published private(set) var physicalOrientation: PhysicalOrientation = .portrait
    @Published private(set) var uiRotationAngle: Double = 0
    @Published private(set) var isLevel: Bool = false
    @Published private(set) var rollAngle: Double = 0
    @Published var notice: String?

    /// Fired the instant the sensor actually captures the photo (from
    /// AVCapturePhotoOutput's willCapturePhotoFor delegate callback), so the
    /// UI's screen-flash overlay is synced to the real capture moment
    /// instead of firing early on button tap.
    var onWillCapturePhoto: (() -> Void)?

    let session = AVCaptureSession()

    // MARK: Private

    private let settings: AppSettings
    private let sessionQueue = DispatchQueue(label: "lowpolycam.session")
    // Video sample buffers land on their own high-priority queue so nothing
    // else (audio delivery, segment rotation, finishWriting bookkeeping) can
    // ever block or delay a video frame. Sharing a single queue for video +
    // audio + writer teardown was causing the AVAssetWriter to miss frames
    // under load (e.g. new AVAssetWriter/encoder session spin-up at segment
    // rotation), which is what made Photos report a non-30 average fps
    // (24.64, 26.51, etc.) even though the file's wall-clock duration was
    // correct — the frame *count* was just short.
    private let videoQueue = DispatchQueue(label: "lowpolycam.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "lowpolycam.audio", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "lowpolycam.io", qos: .userInitiated)
    private let motionManager = CMMotionManager()

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var activePhotoProcessors: [Int64: PhotoCaptureProcessor] = [:]
    private var appliedThermalMitigation = false
    /// Brightness snapshot taken when thermal mitigation first dims the screen.
    /// Restored when thermal state returns to nominal/fair so the screen does
    /// not stay permanently dimmed after cooling down.
    private var thermalSavedBrightness: CGFloat?
    private var cameraInput: AVCaptureDeviceInput?

    // Tracks the (device, format, fps) that was last actually pushed to the
    // hardware via applyUnifiedHardwareConfiguration. startRecording() and
    // stopRecording() both call applyActiveFormat() unconditionally, which
    // used to re-run the full device.lockForConfiguration()/activeFormat/
    // frame-duration/zoom-reset dance every single time — even when the
    // resulting format+fps was identical to what was already running. That
    // redundant reconfiguration is what caused the visible flicker, the
    // momentary "flips to front camera" glitch (it's actually the same
    // camera re-negotiating format), the dark first frame (exposure/format
    // reapplied right as frames start landing in the writer), and zoom
    // snapping back to baseline on every record start/stop. We only touch
    // the hardware again when this key actually changes.
    private var lastAppliedFormatKey: String?

    private static func formatKey(device: AVCaptureDevice, format: AVCaptureDevice.Format, fps: Double) -> String {
        "\(device.uniqueID)|\(ObjectIdentifier(format))|\(fps.rounded())"
    }

    /// Waits for the sensor's auto-exposure to re-converge after a format
    /// switch (e.g. idle preview format -> full recording format). Changing
    /// `activeFormat`/frame duration makes the sensor briefly re-negotiate
    /// exposure/gain; if we start writing frames immediately, the first
    /// handful come out dark and visibly ramp up to normal brightness over
    /// 3-4 frames. Waiting for `isAdjustingExposure` to clear (same signal
    /// AVCapturePhotoOutput effectively waits on internally) fixes this.
    /// Bounded by `timeout` so a device that never reports settled (or is
    /// already locked/manual) can't hang recording start indefinitely.
    private func waitForExposureSettled(device: AVCaptureDevice, timeout: TimeInterval = 0.35, completion: @escaping () -> Void) {
        guard device.isAdjustingExposure else {
            completion()
            return
        }
        var didComplete = false
        var observation: NSKeyValueObservation?
        let lock = NSLock()
        let finish = { [weak self] in
            lock.lock()
            guard !didComplete else { lock.unlock(); return }
            didComplete = true
            lock.unlock()
            observation?.invalidate()
            self?.sessionQueue.async { completion() }
        }
        observation = device.observe(\.isAdjustingExposure, options: [.new]) { dev, _ in
            if !dev.isAdjustingExposure { finish() }
        }
        sessionQueue.asyncAfter(deadline: .now() + timeout) { finish() }
    }
    private var micInput: AVCaptureDeviceInput?
    private var position: AVCaptureDevice.Position = .back
    private var isConfigured = false
    private var spaceTimer: Timer?
    private var volumeObserver: VolumeButtonObserver?

    // Writer state
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private var segmentStart = CMTime.invalid
    private var lastVideoPTS = CMTime.invalid
    private var recordStartPTS = CMTime.invalid
    // Protected by writerLock (together with writer / videoIn / audioIn /
    // segmentStart / lastVideoPTS / recordStartPTS / segmentStartInFlight).
    // These flags are read on videoQueue/audioQueue and written from ioQueue
    // and sessionQueue; previously unprotected → data races under concurrent
    // frame delivery + start/stop.
    private var wantsRecording = false
    // Number of video frames to silently discard right after a *fresh*
    // record start (not segment rotation). Deterministic fallback for the
    // AE/AGC brightness ramp after a format switch. Touched under writerLock.
    private var pendingWarmupFrames = 0
    // Guards against dispatching startSegment more than once for the same
    // segment. Multiple video frames can arrive on videoQueue and all see
    // writer == nil before the *first* startSegment call (running on
    // ioQueue) finishes its setup and assigns `writer` — each of those
    // frames would otherwise fire its own startSegment, all racing to
    // create an AVAssetWriter at the same (or near-identical) file path,
    // which fails with "Cannot Save" (AVFoundationErrorDomain -11823) and
    // was the actual cause of "press record, it instantly stops."
    private var segmentStartInFlight = false
    /// Video frames that arrive while AVAssetWriter is still spinning up
    /// (segmentStartInFlight && writer == nil). Previously these were
    /// silently dropped, which left gaps in the PTS timeline and made
    /// Photos report e.g. 27.52 fps instead of 30.00 on short clips.
    /// Buffered under writerLock and flushed in order once the writer is live.
    private var pendingStartBuffers: [CMSampleBuffer] = []
    private static let pendingStartBufferLimit = 18
    private var plan: EncodePlan?
    private var clipTransform = CGAffineTransform.identity
    private var freeBytesSnapshot: Int64 = .max
    private var lastElapsedPush = CMTime.invalid
    private var droppedFrameCount = 0
    private var recordingDestination: SaveLocation = .files
    /// Destination that was active when the in-progress clip was started.
    /// Stored so recovery after an interruption uses the original location
    /// instead of whatever the user has selected now.
    private static let inProgressDestinationKey = "inProgressClipDestination"

    private let stopLock = NSLock()
    private var _stopRequested = false
    private var stopRequested: Bool {
        get { stopLock.lock(); defer { stopLock.unlock() }; return _stopRequested }
        set { stopLock.lock(); _stopRequested = newValue; stopLock.unlock() }
    }

    // Bumped every time startRecording() runs. A stopRecording() call
    // captures the token of the session it's stopping; if by the time it
    // actually executes on ioQueue the token no longer matches the current
    // session, that stop is stale and must be ignored — otherwise a
    // leftover/delayed stop from a previous tap can tear down a *newer*
    // recording that started in the meantime (start -> stop -> start fast
    // = the newer recording gets killed by the old stop).
    private var recordingSessionToken: Int = 0

    // Guards writer/videoIn/audioIn/segmentStart/lastVideoPTS/recordStartPTS,
    // wantsRecording, pendingWarmupFrames, segmentStartInFlight.
    // Touched from videoQueue, audioQueue and ioQueue concurrently.
    private let writerLock = NSLock()

    private var rawMaxZoomSnapshot: CGFloat = 1
    private var rawMinZoomSnapshot: CGFloat = 1
    private var zoomBaselineSnapshot: CGFloat = 1

    private var lastRawRollAngle: Double?
    private var unwrappedRollAngle: Double = 0

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        refreshFreeSpace()

        NotificationCenter.default.addObserver(
            self, selector: #selector(willResignActive),
            name: UIApplication.willResignActiveNotification, object: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)

        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshBattery),
            name: UIDevice.batteryLevelDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshBattery),
            name: UIDevice.batteryStateDidChangeNotification, object: nil)
        refreshBattery()

        NotificationCenter.default.addObserver(
            self, selector: #selector(subjectAreaDidChange),
            name: .AVCaptureDeviceSubjectAreaDidChange, object: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification, object: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleThermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        thermalState = ProcessInfo.processInfo.thermalState
    }

    // MARK: Thermal State Monitor

    @objc private func handleThermalStateChanged() {
        let state = ProcessInfo.processInfo.thermalState
        DispatchQueue.main.async { [weak self] in
            self?.applyThermalState(state)
        }
    }

    private func applyThermalState(_ state: ProcessInfo.ThermalState) {
        thermalState = state

        switch state {
        case .critical:
            guard !appliedThermalMitigation else { return }
            appliedThermalMitigation = true

            // Auto-Cooling: dim the screen to cut display power draw.
            // Snapshot current brightness so we can restore it later.
            if thermalSavedBrightness == nil {
                thermalSavedBrightness = UIScreen.main.brightness
            }
            if UIScreen.main.brightness > 0.30 {
                UIScreen.main.brightness = 0.30
            }

            // Brightness alone barely touches the ISP/encoder heat that
            // actually drives A10 into critical — those keep running at
            // whatever the idle preview format currently is. If we're not
            // recording, force preview down to the lowest idle path (720p
            // @ 15fps) regardless of Longevity Mode, on top of the normal
            // idle caps in applyActiveFormat(forRecording:false). This is
            // skipped while actively recording so we never touch the
            // AVAssetWriter session mid-clip; the existing free-space/UI
            // notice is the only feedback during an active recording.
            if !isRecording {
                sessionQueue.async { [weak self] in
                    self?.applyActiveFormat(forRecording: false, forceLowestIdlePreview: true)
                    self?.applyStabilization()
                }
            }
            notice = "Phone is hot · Cooling down"

        case .serious:
            if !appliedThermalMitigation {
                if thermalSavedBrightness == nil {
                    thermalSavedBrightness = UIScreen.main.brightness
                }
                if UIScreen.main.brightness > 0.45 {
                    UIScreen.main.brightness = 0.45
                }
                notice = "Phone is warm"
            }

        case .nominal, .fair:
            if appliedThermalMitigation {
                appliedThermalMitigation = false
                // Restore pre-thermal brightness (if we were the ones who dimmed it).
                if let saved = thermalSavedBrightness {
                    UIScreen.main.brightness = saved
                    thermalSavedBrightness = nil
                }
                if !isRecording {
                    sessionQueue.async { [weak self] in
                        self?.applyActiveFormat(forRecording: false)
                        self?.applyStabilization()
                    }
                }
            }

        @unknown default:
            break
        }
    }

    deinit {
        spaceTimer?.invalidate()
        volumeObserver?.stop()
        motionManager.stopDeviceMotionUpdates()
        NotificationCenter.default.removeObserver(self)
        UIDevice.current.isBatteryMonitoringEnabled = false
    }

    @objc private func refreshBattery() {
        let level = UIDevice.current.batteryLevel
        let state = UIDevice.current.batteryState
        DispatchQueue.main.async {
            self.batteryPercent = level < 0 ? -1 : Int((level * 100).rounded())
            self.batteryCharging = (state == .charging || state == .full)
        }
    }

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        if type == .began {
            // Stop a clean segment rather than leaving a truncated/corrupt file
            // when a call, Siri, or another audio client interrupts.
            DispatchQueue.main.async {
                self.audioLevel = 0
                if self.isRecording {
                    self.stopRecording(notice: "Recording stopped (audio interrupted)")
                }
            }
        }
    }

    // MARK: Motion & Gravity Horizon

    func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        lastRawRollAngle = nil
        // Adaptive rate: 6 Hz only when the level-gauge UI is visible.
        // Otherwise 2 Hz is enough for orientation (photo upright + UI rotation)
        // and cuts CoreMotion power noticeably on A10 while idle.
        let hz: Double = settings.showLevelGauge ? 6.0 : 2.0
        motionManager.deviceMotionUpdateInterval = 1.0 / hz
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            guard let self = self, let motion = motion else { return }
            let gx = motion.gravity.x
            let gy = motion.gravity.y
            let angle = atan2(gx, -gy) * (180.0 / .pi)

            let absAngle = abs(angle)
            let newOrientation: PhysicalOrientation
            if absAngle < 45 {
                newOrientation = .portrait
            } else if angle >= 45 && angle < 135 {
                newOrientation = .landscapeLeft
            } else if angle <= -45 && angle > -135 {
                newOrientation = .landscapeRight
            } else {
                newOrientation = .portraitUpsideDown
            }

            let targetUIAngle = newOrientation.rotationAngle
            if self.physicalOrientation != newOrientation {
                self.physicalOrientation = newOrientation
                self.uiRotationAngle = targetUIAngle
            }

            if let last = self.lastRawRollAngle {
                var delta = angle - last
                if delta > 180 { delta -= 360 }
                if delta < -180 { delta += 360 }
                self.unwrappedRollAngle += delta
            } else {
                self.unwrappedRollAngle = angle
            }
            self.lastRawRollAngle = angle

            // Throttle @Published rollAngle updates to avoid rebuilding the
            // entire camera UI at 6 Hz on A10. Publish when the gauge is on
            // and the angle moved enough to matter visually.
            let newUnwrapped = self.unwrappedRollAngle
            if self.settings.showLevelGauge {
                if abs(newUnwrapped - self.rollAngle) >= 0.5 {
                    self.rollAngle = newUnwrapped
                }
            }
            let remainder = abs(angle.truncatingRemainder(dividingBy: 90))
            let isLevelNow = remainder < 1.2 || remainder > 88.8
            if self.isLevel != isLevelNow {
                self.isLevel = isLevelNow
            }
        }
    }

    /// Call when the level-gauge toggle changes so CoreMotion rate tracks UI.
    func refreshMotionUpdateRate() {
        guard motionManager.isDeviceMotionAvailable else { return }
        let hz: Double = settings.showLevelGauge ? 6.0 : 2.0
        motionManager.deviceMotionUpdateInterval = 1.0 / hz
    }

    func stopMotionUpdates() {
        motionManager.stopDeviceMotionUpdates()
        lastRawRollAngle = nil
    }

    // MARK: Volume Monitoring Control

    func pauseVolumeMonitoring() {
        DispatchQueue.main.async {
            self.volumeObserver?.stop()
        }
    }

    func suppressVolumeTriggerBriefly(duration: TimeInterval = 1.0) {
        DispatchQueue.main.async {
            self.volumeObserver?.ignoreTemporarily(duration: duration)
        }
    }

    func resumeVolumeMonitoring() {
        DispatchQueue.main.async {
            if self.volumeObserver == nil {
                let obs = VolumeButtonObserver()
                obs.onVolumeTrigger = { [weak self] in
                    DispatchQueue.main.async { self?.toggleRecording() }
                }
                obs.start()
                self.volumeObserver = obs
            } else {
                self.volumeObserver?.start()
            }
        }
    }

    // MARK: Lifecycle

    func start() {
        refreshFreeSpace()
        recoverInterruptedRecording()
        loadLastSavedClip()
        // Motion updates always run (regardless of the level-gauge UI toggle):
        // they're also what drives physicalOrientation, which photo capture
        // needs to save images right-side-up. Gating this on showLevelGauge
        // meant photos came out rotated/flipped whenever the level gauge was
        // off, since physicalOrientation would just freeze at its default.
        startMotionUpdates()

        spaceTimer?.invalidate()
        // 20s while idle is plenty; tighten to 5s only while recording
        // (see startRecording / stopRecording).
        spaceTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
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
                DispatchQueue.main.async {
                    self.isSessionRunning = self.session.isRunning
                    self.resumeVolumeMonitoring()
                }
            }
        }
    }

    func stop() {
        spaceTimer?.invalidate()
        spaceTimer = nil
        pauseVolumeMonitoring()
        stopMotionUpdates()
        isSwitchingCamera = false

        if isRecording { stopRecording(notice: nil) }
        setTorch(on: false)
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isSessionRunning = false }
        }
    }

    /// Fully pause the capture pipeline (sensor + ISP). Call when a sheet
    /// covers the preview so the phone can cool like the stock Camera app
    /// does when you leave the viewfinder.
    func pausePreviewSession() {
        guard !isRecording else { return }
        pauseVolumeMonitoring()
        stopMotionUpdates()
        setTorch(on: false)
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isSessionRunning = false }
        }
    }

    /// Resume after pausePreviewSession().
    func resumePreviewSession() {
        sessionQueue.async {
            if !self.session.isRunning { self.session.startRunning() }
            self.applyActiveFormat(forRecording: false)
            self.applyStabilization()
            DispatchQueue.main.async { self.isSessionRunning = self.session.isRunning }
        }
        startMotionUpdates()
        resumeVolumeMonitoring()
        refreshTorchState()
    }

    /// Re-apply the low-power idle format (e.g. after toggling Longevity Mode).
    func refreshIdleFormatIfNeeded() {
        guard !isRecording else { return }
        sessionQueue.async {
            self.applyActiveFormat(forRecording: false)
            self.applyStabilization()
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
        session.sessionPreset = .inputPriority

        if let device = Self.camera(at: position, mode: settings.cameraMode, preferPhysical: wantsPhysicalWideLens),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            cameraInput = input
        }

        // On weaker/older hardware (e.g. iPhone 7's A10) the encoder can
        // fall behind under thermal load. Discarding late frames instead of
        // queueing them keeps memory bounded and avoids a growing backlog —
        // dropped frames are already tracked via didDrop/countDroppedFrame.
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        // Delegates stay nil while idle. They are attached only for the
        // duration of a recording (see startRecording / stopRecording) so
        // the system does not deliver every preview frame into the process
        // when nothing is being written — major idle-heat reduction.
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }

        session.commitConfiguration()

        configureVideoConnection()
        refreshCapabilitiesThenApplyFormat()
        configurePhotoOutput()
        refreshTorchState()
        resetFocusAndExposureToAuto()
        syncMicInput()
    }

    // MARK: Photo Output Configuration

    private func configurePhotoOutput() {
        guard let device = cameraInput?.device else { return }

        // Enable the highest quality prioritization AVCapturePhotoOutput offers,
        // which lets the system apply the same Smart-HDR / multi-frame scene
        // rendering the live preview already benefits from. Without this, the
        // saved photo can come out noticeably darker/flatter than what was seen
        // live, especially in low light, because the discrete still capture was
        // otherwise using a plainer single-frame render.
        if #available(iOS 13.0, *) {
            photoOutput.maxPhotoQualityPrioritization = .quality
        }
        if #available(iOS 16.0, *) {
            // Use the TRUE max across all formats — device.activeFormat only reflects
            // whatever video format is currently applied (often ~1080p/2MP), not the
            // sensor's real max still-photo resolution.
            let maxDims = device.formats
                .flatMap { $0.supportedMaxPhotoDimensions }
                .max { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }
            if let maxDims = maxDims {
                photoOutput.maxPhotoDimensions = maxDims
            }
        } else {
            // iOS <16 path (this is what iPhone 7 / iOS 15.8 actually uses).
            // NOTE: we deliberately do NOT switch activeFormat here anymore — on
            // iOS <16, activeFormat drives BOTH the live preview AND still capture,
            // so permanently locking it to a high-res-optimized format made the live
            // preview blurry/pixelated. The high-res format swap now happens only
            // briefly, right before actually taking the photo (see capturePhoto()),
            // and is restored immediately after — keeping the live preview smooth.
            photoOutput.isHighResolutionCaptureEnabled = true
        }
    }

    private func configureVideoConnection() {
        guard let c = videoOutput.connection(with: .video) else { return }
        if c.isVideoOrientationSupported { c.videoOrientation = .landscapeRight }
        if c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = false
        }
        applyStabilization(to: c)
    }

    private func applyStabilization(to connection: AVCaptureConnection? = nil) {
        guard let c = connection ?? videoOutput.connection(with: .video) else { return }
        let supported = c.isVideoStabilizationSupported
        if supported {
            // Stabilisation burns ISP power even on the live preview. Only
            // enable it while actually recording. Also force off at 4K so the
            // A10 encoder can keep a true 30 fps without frame drops.
            let wantStab = isRecording
                && settings.stabilization
                && settings.resolution != .p2160
            c.preferredVideoStabilizationMode = wantStab ? .auto : .off
        }
        DispatchQueue.main.async { self.stabilizationSupported = supported }
    }

    func updateStabilization() {
        sessionQueue.async { self.applyStabilization() }
    }

    private func ensureCorrectCameraDevice(for mode: CameraMode) {
        guard let targetDevice = Self.camera(at: position, mode: mode, preferPhysical: wantsPhysicalWideLens) else { return }
        switchCameraInput(to: targetDevice)
    }

    private func switchCameraInput(to targetDevice: AVCaptureDevice) {
        guard cameraInput?.device.uniqueID != targetDevice.uniqueID else { return }
        DispatchQueue.main.async { self.volumeObserver?.ignoreTemporarily() }

        session.beginConfiguration()
        if let old = cameraInput { session.removeInput(old) }
        if let input = try? AVCaptureDeviceInput(device: targetDevice), session.canAddInput(input) {
            session.addInput(input)
            cameraInput = input
        }
        session.commitConfiguration()
        configureVideoConnection()
    }

    /// Applies the active camera format + frame rate.
    /// - Parameter forRecording: when false (idle preview), force a low-power
    ///   sensor path so the phone stays cool like the stock Camera app.
    ///   High rates / high res are only engaged while actually recording.
    private func applyActiveFormat(forRecording: Bool = false, forceLowestIdlePreview: Bool = false) {
        DispatchQueue.main.async { self.volumeObserver?.ignoreTemporarily() }
        ensureCorrectCameraDevice(for: settings.cameraMode)
        guard let device = cameraInput?.device else { return }

        let isSlow = settings.cameraMode == .slowMo && isSlowMoSupportedOnCurrentLens
        var dims: (w: Int, h: Int)
        let fullFPS: Double

        if isSlow {
            if !availableSlowMoRates.contains(settings.slowMoFrameRate) {
                let fallback = availableSlowMoRates.first ?? .fps120
                DispatchQueue.main.async {
                    self.settings.slowMoFrameRate = fallback
                }
            }
            fullFPS = Double(settings.slowMoFrameRate.value)
            dims = settings.slowMoResolution.captureDimensions
        } else {
            dims = settings.resolution.captureDimensions
            if let locked = settings.resolution.lockedFrameRate, settings.frameRate != locked {
                DispatchQueue.main.async {
                    self.settings.frameRate = locked
                    self.notice = "\(self.settings.resolution.label) locked to \(locked.label)"
                }
            }
            fullFPS = Double((settings.resolution.lockedFrameRate ?? settings.frameRate).value)
        }

        // Idle preview: force a low-power sensor path. Biggest idle heat on A10
        // came from staying at the *recording* resolution (e.g. 4K) and >30 fps.
        // Cap both while not recording. Longevity Mode is stricter still.
        let targetFPS: Double
        if forRecording {
            targetFPS = fullFPS
        } else {
            let idleCapH = (forceLowestIdlePreview || settings.longevityMode) ? 720 : 1080
            if dims.h > idleCapH {
                dims = idleCapH >= 1080
                    ? Resolution.p1080.captureDimensions
                    : Resolution.p720.captureDimensions
            }
            let idleFPSCap: Double = forceLowestIdlePreview ? 15.0 : (settings.longevityMode ? 24.0 : 30.0)
            targetFPS = min(fullFPS, idleFPSCap)
        }

        var format = isSlow
            ? Self.bestSlowMoAwareFormat(for: device, width: dims.w, height: dims.h, fps: targetFPS)
            : Self.bestFormat(for: device, width: dims.w, height: dims.h, fps: targetFPS)

        if format == nil && targetFPS == 60 {
            format = Self.bestFormat(for: device, width: dims.w, height: dims.h, fps: 30)
            if format != nil {
                DispatchQueue.main.async {
                    self.settings.frameRate = .fps30
                    self.notice = "60 fps unavailable · Switched to 30 fps"
                }
            }
        }

        guard let finalFormat = format else {
            if isSlow, let fallbackFormat = Self.bestSlowMoFormat(for: device, fps: fullFPS) {
                let applyFPS = forRecording ? fullFPS : min(fullFPS, 30.0)
                let newKey = Self.formatKey(device: device, format: fallbackFormat, fps: applyFPS)
                if newKey != lastAppliedFormatKey {
                    applyUnifiedHardwareConfiguration(to: device, format: fallbackFormat, targetFPS: applyFPS)
                    DispatchQueue.main.async {
                        let dDims = CMVideoFormatDescriptionGetDimensions(fallbackFormat.formatDescription)
                        let closestRes: Resolution = dDims.height >= 1080 ? .p1080 : .p720
                        self.settings.slowMoResolution = closestRes
                        self.notice = "\(self.settings.slowMoFrameRate.label) set to \(closestRes.label)"
                    }
                    refreshZoomLimits()
                    lastAppliedFormatKey = newKey
                }
                configurePhotoOutput()
                DispatchQueue.main.async { self.volumeObserver?.ignoreTemporarily() }
                return
            }

            DispatchQueue.main.async {
                self.notice = "Format adjusted for this lens"
            }
            return
        }

        let newKey = Self.formatKey(device: device, format: finalFormat, fps: targetFPS)
        if newKey != lastAppliedFormatKey {
            applyUnifiedHardwareConfiguration(to: device, format: finalFormat, targetFPS: targetFPS)
            refreshZoomLimits()
            lastAppliedFormatKey = newKey
        }
        configurePhotoOutput()
        DispatchQueue.main.async { self.volumeObserver?.ignoreTemporarily() }
    }

    private func applyUnifiedHardwareConfiguration(to device: AVCaptureDevice, format: AVCaptureDevice.Format, targetFPS: Double) {
        do {
            try device.lockForConfiguration()
            
            // 1. Format & Frame Rate — lock min AND max to the same duration so
            // the sensor runs at a fixed rate (prevents VFR / under-target fps files).
            device.activeFormat = format

            let desiredFPS = max(1.0, targetFPS.rounded())
            // Exact 1/N second frame duration for integer fps (30, 60, 120, 240).
            // Using timescale == fps and value == 1 keeps the media timeline on
            // clean rationals so Photos reports 30.00 instead of 29.97/27.x when
            // every frame is written.
            let fpsInt = max(Int(desiredFPS), 1)
            var minDur = CMTime(value: 1, timescale: CMTimeScale(fpsInt))
            var maxDur = minDur
            if let range = format.videoSupportedFrameRateRanges.first(where: {
                $0.minFrameRate - 0.5 <= desiredFPS && desiredFPS <= $0.maxFrameRate + 0.5
            }) {
                let lo = range.minFrameDuration
                let hi = range.maxFrameDuration
                // minFrameDuration = duration of fastest rate; maxFrameDuration = slowest.
                if CMTimeCompare(minDur, lo) < 0 { minDur = lo }
                if CMTimeCompare(minDur, hi) > 0 { minDur = hi }
                maxDur = minDur
            }
            device.activeVideoMinFrameDuration = minDur
            device.activeVideoMaxFrameDuration = maxDur
            
            // 2. Autofocus
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = true
            }
            
            // 3. Pro Settings (Exposure & White Balance)
            let minBias = device.minExposureTargetBias
            let maxBias = device.maxExposureTargetBias
            let clampedBias = max(minBias, min(settings.exposureBias, maxBias))
            device.setExposureTargetBias(clampedBias, completionHandler: nil)

            if let values = settings.whiteBalance.kelvin {
                if device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                    let tempAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: values.temp, tint: values.tint)
                    var gains = device.deviceWhiteBalanceGains(for: tempAndTint)
                    let maxGain = device.maxWhiteBalanceGain
                    gains.redGain = max(1.0, min(gains.redGain.isFinite ? gains.redGain : 1.0, maxGain))
                    gains.greenGain = max(1.0, min(gains.greenGain.isFinite ? gains.greenGain : 1.0, maxGain))
                    gains.blueGain = max(1.0, min(gains.blueGain.isFinite ? gains.blueGain : 1.0, maxGain))
                    device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                }
            } else {
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            }

            // 4. Baseline Zoom Prime
            let baseline = Self.wideAngleBaseline(for: device)
            let ceiling = device.activeFormat.videoMaxZoomFactor
            device.videoZoomFactor = min(max(baseline, device.minAvailableVideoZoomFactor), ceiling)

            device.unlockForConfiguration()
        } catch {
            DispatchQueue.main.async { self.notice = "Camera settings busy" }
        }
    }

    private static func bestSlowMoFormat(for device: AVCaptureDevice, fps: Double) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var maxArea = 0
        for format in device.formats {
            let supportsFPS = format.videoSupportedFrameRateRanges.contains {
                $0.maxFrameRate >= (fps - 1.0)
            }
            guard supportsFPS else { continue }
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let area = Int(dims.width) * Int(dims.height)
            if area > maxArea {
                maxArea = area
                best = format
            }
        }
        return best
    }

    private static func scoredCandidates(in formats: [AVCaptureDevice.Format], width: Int, height: Int, fps: Double) -> [AVCaptureDevice.Format] {
        var scored: [(format: AVCaptureDevice.Format, score: Int)] = []
        for format in formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard Int(dims.width) >= width, Int(dims.height) >= height else { continue }

            // Prefer a range that solidly covers the target fps.
            guard let matchingRange = format.videoSupportedFrameRateRanges.first(where: {
                $0.minFrameRate <= (fps + 0.5) && (fps - 0.5) <= $0.maxFrameRate
            }) else { continue }

            let areaDelta = Int(dims.width) * Int(dims.height) - width * height

            // Prefer formats whose max rate is close to the target (more stable
            // fixed-rate capture on older silicon than a wide 1–60 range).
            //
            // Formats whose maxFrameRate falls even slightly short of the
            // target (e.g. 59.5 when asking for 60) used to score identically
            // to an exact 60fps format here, because slack was clamped to 0 in
            // both directions. That let a shortfall format win purely on
            // resolution/binning and get picked — the actual cause of clips
            // landing at 59.44/58fps etc. instead of a true 60. A shortfall
            // format can never actually deliver the requested rate, so it must
            // always lose to any format that can, regardless of other scoring.
            let rateDelta = matchingRange.maxFrameRate - fps
            let rateScore: Int
            if rateDelta < -0.05 {
                // Genuinely can't hit the target fps — heavily disqualify.
                rateScore = 100_000_000 + Int((-rateDelta * 1_000).rounded())
            } else {
                // Tight match (exact or within ~0.1) scores best. Large slack
                // (e.g. a 1-240 range when we want 60) is still usable but
                // less preferred because the sensor may not lock as cleanly.
                let slack = abs(rateDelta)
                if slack < 0.15 {
                    rateScore = 0
                } else {
                    rateScore = Int((slack * 10_000).rounded())
                }
            }

            // Prefer non-binned / non-HDR for predictable encode on A10.
            let binnedScore = format.isVideoBinned ? 1_000_000 : 0
            let isHDR = format.supportedColorSpaces.contains(.HLG_BT2020)
            let colorScore = isHDR ? 10_000_000 : 0

            // Slight preference for formats whose minFrameDuration is already
            // very close to 1/target — these lock more cleanly to a fixed rate.
            let idealDur = CMTime(value: 1, timescale: CMTimeScale(max(1, Int(fps.rounded()))))
            let minDurDelta = abs(CMTimeGetSeconds(matchingRange.minFrameDuration) - CMTimeGetSeconds(idealDur))
            let durScore = Int((minDurDelta * 50_000).rounded())

            let score = areaDelta + rateScore + binnedScore + colorScore + durScore
            scored.append((format, score))
        }
        return scored.sorted { $0.score < $1.score }.map { $0.format }
    }

    private static func bestFormat(for device: AVCaptureDevice, width: Int, height: Int, fps: Double) -> AVCaptureDevice.Format? {
        scoredCandidates(in: device.formats, width: width, height: height, fps: fps).first
    }

    private static func bestSlowMoAwareFormat(for device: AVCaptureDevice, width: Int, height: Int, fps: Double) -> AVCaptureDevice.Format? {
        let ranked = scoredCandidates(in: device.formats, width: width, height: height, fps: fps)
        guard let fallback = ranked.first else { return nil }
        guard ranked.count > 1 else { return fallback }

        let baseline = wideAngleBaseline(for: device)
        guard baseline > 1 else { return fallback }

        guard (try? device.lockForConfiguration()) != nil else { return fallback }
        defer { device.unlockForConfiguration() }

        for candidate in ranked {
            device.activeFormat = candidate
            if device.minAvailableVideoZoomFactor <= baseline * 1.05 {
                return candidate
            }
        }
        return fallback
    }

    func updateCaptureFormat() {
        sessionQueue.async {
            self.refreshCapabilitiesThenApplyFormat()
        }
    }

    private func refreshCapabilitiesThenApplyFormat() {
        ensureCorrectCameraDevice(for: settings.cameraMode)
        guard let device = cameraInput?.device else { return }

        let targetDims = settings.cameraMode == .slowMo
            ? settings.slowMoResolution.captureDimensions
            : settings.resolution.captureDimensions

        var rates = Set<FrameRate>()
        var widestPixels = 0
        var slowRates = Set<SlowMoFrameRate>()
        var slowResolutions = Set<Resolution>()

        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let h = Int(dims.height)
            widestPixels = max(widestPixels, Int(dims.width) * Int(dims.height))
            let meetsCurrentResolution = Int(dims.width) >= targetDims.w && Int(dims.height) >= targetDims.h
            if meetsCurrentResolution {
                for rate in FrameRate.allCases {
                    let fps = Double(rate.value)
                    if format.videoSupportedFrameRateRanges.contains(where: {
                        $0.minFrameRate <= (fps + 0.5) && (fps - 0.5) <= $0.maxFrameRate
                    }) {
                        rates.insert(rate)
                    }
                }
            }
            for range in format.videoSupportedFrameRateRanges {
                if range.maxFrameRate >= 119.0 {
                    slowRates.insert(.fps120)
                    if h >= 1080 { slowResolutions.insert(.p1080) }
                    if h >= 720 { slowResolutions.insert(.p720) }
                    if h >= 480 { slowResolutions.insert(.p480) }
                    slowResolutions.insert(.p320)
                    slowResolutions.insert(.p144)
                }
                if range.maxFrameRate >= 239.0 {
                    slowRates.insert(.fps240)
                    if h >= 1080 { slowResolutions.insert(.p1080) }
                    if h >= 720 { slowResolutions.insert(.p720) }
                    if h >= 480 { slowResolutions.insert(.p480) }
                    slowResolutions.insert(.p320)
                    slowResolutions.insert(.p144)
                }
            }
        }

        let supportedRates = FrameRate.allCases.filter { rates.contains($0) }
        let canDo1080 = widestPixels >= 1920 * 1080
        let canDo4K = widestPixels >= 3840 * 2160
        let supportedResolutions = Resolution.allCases.filter { res in
            switch res {
            case .p2160: return canDo4K
            case .p1080: return canDo1080
            default: return true
            }
        }
        // Slow-mo never uses 4K on this device class
        let supportedSlowRates = SlowMoFrameRate.allCases.filter { slowRates.contains($0) }
        let supportedSlowRes = Resolution.allCases.filter {
            $0 != .p2160 && slowResolutions.contains($0)
        }

        // Publish capability lists on main without blocking the session queue
        // (main.sync here previously risked deadlocks / hitches on A10).
        let rates = supportedRates.isEmpty ? [FrameRate.fps30] : supportedRates
        let resolutions = supportedResolutions.isEmpty ? [Resolution.p720] : supportedResolutions
        let slowRatesOut = supportedSlowRates
        let slowResOut = supportedSlowRes.isEmpty ? [Resolution.p720] : supportedSlowRes
        let slowSupported = !supportedSlowRates.isEmpty

        DispatchQueue.main.async {
            self.availableFrameRates = rates
            self.availableResolutions = resolutions
            self.availableSlowMoRates = slowRatesOut
            self.availableSlowMoResolutions = slowResOut
            self.isSlowMoSupportedOnCurrentLens = slowSupported

            if !self.availableFrameRates.contains(self.settings.frameRate) {
                let fallback: FrameRate = self.availableFrameRates.contains(.fps30)
                    ? .fps30 : (self.availableFrameRates.first ?? .fps30)
                self.settings.frameRate = fallback
            }
            if !self.availableResolutions.contains(self.settings.resolution) {
                let fallback: Resolution = self.availableResolutions.first ?? .p720
                self.settings.resolution = fallback
            }
            // 4K locks to 30 fps
            if self.settings.resolution == .p2160, self.settings.frameRate != .fps30 {
                self.settings.frameRate = .fps30
            }

            if self.settings.cameraMode == .slowMo {
                if !self.isSlowMoSupportedOnCurrentLens {
                    self.notice = "Slow-Mo unavailable on front camera"
                    self.settings.cameraMode = .video
                } else if !self.availableSlowMoRates.contains(self.settings.slowMoFrameRate) {
                    self.settings.slowMoFrameRate = self.availableSlowMoRates.first ?? .fps120
                }
            }
        }

        // Default to preview (low-power) rate. Recording path will re-apply
        // the full target rate just before frames start flowing.
        applyActiveFormat(forRecording: false)
    }

    func syncMicInput() {
        // Audio is always required
        if !settings.recordAudio {
            settings.recordAudio = true
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                self?.addOrRemoveMic()
            }
            return
        }
        addOrRemoveMic()
    }

    private func addOrRemoveMic() {
        sessionQueue.async {
            DispatchQueue.main.async { self.volumeObserver?.ignoreTemporarily() }
            let want = true // always record sound
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
        // Flipping mid-record is not supported (would tear down the writer
        // session). Guard is the single source of truth — no dead branches.
        guard !isRecording, !isSwitchingCamera else { return }

        DispatchQueue.main.async {
            self.isSwitchingCamera = true
            self.volumeObserver?.ignoreTemporarily(duration: 3.0)
        }
        setTorch(on: false)
        sessionQueue.async {
            let next: AVCaptureDevice.Position = (self.position == .back) ? .front : .back
            guard let device = Self.camera(at: next, mode: self.settings.cameraMode, preferPhysical: self.wantsPhysicalWideLens),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                DispatchQueue.main.async { self.isSwitchingCamera = false }
                return
            }

            self.session.beginConfiguration()
            if let old = self.cameraInput { self.session.removeInput(old) }
            if self.session.canAddInput(input) {
                self.session.addInput(input)
                self.cameraInput = input
                self.position = next
            } else {
                if let old = self.cameraInput { self.session.addInput(old) }
            }
            self.session.commitConfiguration()

            self.configureVideoConnection()
            self.refreshCapabilitiesThenApplyFormat()
            self.refreshTorchState()
            self.resetFocusAndExposureToAuto()

            DispatchQueue.main.async {
                self.isFrontCamera = (next == .front)
                self.isSwitchingCamera = false
                self.volumeObserver?.ignoreTemporarily(duration: 1.0)
            }
        }
    }

    private static func camera(at position: AVCaptureDevice.Position, mode: CameraMode, preferPhysical: Bool = false) -> AVCaptureDevice? {
        if position == .back && !preferPhysical {
            let virtualTypes: [AVCaptureDevice.DeviceType] = [
                .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera
            ]
            for type in virtualTypes {
                guard let device = AVCaptureDevice.default(type, for: .video, position: .back) else { continue }
                if mode == .slowMo && !supportsSlowMotion(device) { continue }
                return device
            }
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video)
    }

    private static func supportsSlowMotion(_ device: AVCaptureDevice) -> Bool {
        device.formats.contains { format in
            format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 119.0 }
        }
    }

    private var wantsPhysicalWideForFrameRate: Bool {
        settings.cameraMode == .video
            && false /* 60 fps removed for iPhone 7 focus */
    }

    private var wantsPhysicalWideLens: Bool {
        wantsPhysicalWideForFrameRate
    }

    // MARK: Exposure & White Balance

    func setExposureBias(_ bias: Float) {
        sessionQueue.async {
            guard let device = self.cameraInput?.device else { return }
            do {
                try device.lockForConfiguration()
                let minBias = device.minExposureTargetBias
                let maxBias = device.maxExposureTargetBias
                let clamped = max(minBias, min(bias, maxBias))
                device.setExposureTargetBias(clamped, completionHandler: nil)
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.settings.exposureBias = clamped }
            } catch { }
        }
    }

    func setWhiteBalance(_ preset: WhiteBalancePreset) {
        sessionQueue.async {
            if preset.kelvin == nil {
                self.ensureCorrectCameraDevice(for: self.settings.cameraMode)
                guard let device = self.cameraInput?.device else { return }
                do {
                    try device.lockForConfiguration()
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        device.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                    device.unlockForConfiguration()
                    self.refreshZoomLimits()
                    DispatchQueue.main.async { self.settings.whiteBalance = preset }
                } catch { }
                return
            }

            guard let values = preset.kelvin else { return }

            var device = self.cameraInput?.device
            var lostUltraWide = false

            if let d = device, !d.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                if let fallback = Self.camera(at: self.position, mode: self.settings.cameraMode, preferPhysical: true) {
                    self.switchCameraInput(to: fallback)
                    device = self.cameraInput?.device
                    lostUltraWide = true
                }
            }

            guard let device = device else { return }
            do {
                try device.lockForConfiguration()
                guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else {
                    device.unlockForConfiguration()
                    DispatchQueue.main.async {
                        self.notice = "Manual WB unsupported here"
                    }
                    return
                }
                let tempAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: values.temp, tint: values.tint)
                var gains = device.deviceWhiteBalanceGains(for: tempAndTint)
                let maxGain = device.maxWhiteBalanceGain
                gains.redGain = max(1.0, min(gains.redGain.isFinite ? gains.redGain : 1.0, maxGain))
                gains.greenGain = max(1.0, min(gains.greenGain.isFinite ? gains.greenGain : 1.0, maxGain))
                gains.blueGain = max(1.0, min(gains.blueGain.isFinite ? gains.blueGain : 1.0, maxGain))
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                device.unlockForConfiguration()
                self.refreshZoomLimits()
                DispatchQueue.main.async {
                    self.settings.whiteBalance = preset
                    if lostUltraWide {
                        self.notice = "0.5x unavailable with custom WB"
                    }
                }
            } catch { }
        }
    }

    // MARK: Torch

    func refreshTorchState() {
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

    func setTorch(on: Bool) {
        sessionQueue.async {
            guard let device = self.cameraInput?.device, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                if on {
                    let level: Float = self.settings.torchBrightness > 0 ? self.settings.torchBrightness : 1.0
                    let targetLevel = min(level, AVCaptureDevice.maxAvailableTorchLevel)
                    try device.setTorchModeOn(level: targetLevel)
                } else {
                    device.torchMode = .off
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.torchOn = on }
            } catch {
                DispatchQueue.main.async { self.notice = "Torch is busy" }
            }
        }
    }

    func setLiveTorch(level: Float) {
        sessionQueue.async {
            guard let device = self.cameraInput?.device, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                if level > 0.01 {
                    let maxLevel = AVCaptureDevice.maxAvailableTorchLevel
                    let targetLevel = min(level, maxLevel)
                    try device.setTorchModeOn(level: targetLevel)
                    DispatchQueue.main.async {
                        self.torchOn = true
                        self.settings.torchBrightness = level
                    }
                } else {
                    device.torchMode = .off
                    // Keep the user's preferred torch level so the next
                    // torch-on restores it instead of jumping to full/zero.
                    DispatchQueue.main.async {
                        self.torchOn = false
                    }
                }
                device.unlockForConfiguration()
            } catch { }
        }
    }

    @objc private func willResignActive() {
        setTorch(on: false)
        if isRecording {
            stopRecording(notice: "Recording stopped (app backgrounded)")
        }
        // Stop the capture session while backgrounded. Without this the
        // session (and therefore the photo/video outputs) kept running with
        // the app suspended, which could let a shutter tap that was already
        // in flight complete and save a photo taken "in the background", and
        // wasted power keeping the sensor active while not visible.
        pauseVolumeMonitoring()
        stopMotionUpdates()
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isSessionRunning = false }
        }
    }

    @objc private func didBecomeActive() {
        sessionQueue.async {
            if !self.session.isRunning { self.session.startRunning() }
            self.refreshTorchState()
            DispatchQueue.main.async { self.isSessionRunning = self.session.isRunning }
        }
        // Restart motion updates cleanly — after being backgrounded (e.g. screen
        // locked for a while), the previous raw angle used for unwrapping the roll
        // is stale and can throw the level gauge off. Restarting resets that state.
        // We always (re)start briefly even with the level gauge UI off, so photo
        // capture's physicalOrientation stays correct instead of freezing at
        // whatever orientation it was in before backgrounding (see startMotionUpdates).
        stopMotionUpdates()
        startMotionUpdates()
        resumeVolumeMonitoring()
    }

    // MARK: Zoom

    private static func wideAngleBaseline(for device: AVCaptureDevice) -> CGFloat {
        let constituents = device.constituentDevices
        guard !constituents.isEmpty,
              let wideIndex = constituents.firstIndex(where: {
                  $0.deviceType == .builtInWideAngleCamera
              }),
              wideIndex > 0 else { return 1 }

        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors
        guard wideIndex - 1 < switchOvers.count else { return 1 }
        let value = CGFloat(switchOvers[wideIndex - 1].doubleValue)
        return value > 0 ? value : 1
    }

    private func refreshZoomLimits() {
        guard let device = cameraInput?.device else { return }

        let baseline = Self.wideAngleBaseline(for: device)
        let rawCeiling = min(device.activeFormat.videoMaxZoomFactor, baseline * 8)
        let rawFloor = device.minAvailableVideoZoomFactor

        zoomBaselineSnapshot = baseline
        rawMaxZoomSnapshot = rawCeiling
        rawMinZoomSnapshot = rawFloor

        DispatchQueue.main.async {
            self.maxZoomFactor = rawCeiling / baseline
            self.minZoomFactor = rawFloor / baseline
            self.zoomFactor = 1
        }
    }

    func setZoom(factor: CGFloat) {
        sessionQueue.async {
            guard let device = self.cameraInput?.device else { return }
            let baseline = self.zoomBaselineSnapshot
            let raw = factor * baseline
            let clamped = max(self.rawMinZoomSnapshot, min(raw, self.rawMaxZoomSnapshot))
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.zoomFactor = clamped / baseline }
            } catch { }
        }
    }

    // MARK: Focus and exposure

    func focusAndExpose(at point: CGPoint) {
        applyFocusAndExposure(at: point,
                              focus: .continuousAutoFocus,
                              exposure: .continuousAutoExposure,
                              monitorSubjectArea: true)
    }

    func resetFocusAndExposureToAuto() {
        applyFocusAndExposure(at: CGPoint(x: 0.5, y: 0.5),
                              focus: .continuousAutoFocus,
                              exposure: .continuousAutoExposure,
                              monitorSubjectArea: false)
    }

    private func applyFocusAndExposure(at point: CGPoint,
                                       focus: AVCaptureDevice.FocusMode,
                                       exposure: AVCaptureDevice.ExposureMode,
                                       monitorSubjectArea: Bool) {
        sessionQueue.async {
            guard let device = self.cameraInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(focus) {
                    device.focusPointOfInterest = point
                    device.focusMode = focus
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(exposure) {
                    device.exposurePointOfInterest = point
                    device.exposureMode = exposure
                }
                device.isSubjectAreaChangeMonitoringEnabled = monitorSubjectArea
                device.unlockForConfiguration()
            } catch { }
        }
    }

    @objc private func subjectAreaDidChange() {
        resetFocusAndExposureToAuto()
    }

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
            // On iOS <16, still-photo resolution is tied to activeFormat, which is
            // also what drives the live preview. To get a true 12MP photo without
            // permanently degrading the preview, briefly switch to the highest-res
            // format just for this one capture, then switch back immediately after.
            var restoreFormat: AVCaptureDevice.Format?
            if #unavailable(iOS 16.0), let device = self.cameraInput?.device {
                let bestFormat = device.formats.max { a, b in
                    let aDims = a.highResolutionStillImageDimensions
                    let bDims = b.highResolutionStillImageDimensions
                    return Int(aDims.width) * Int(aDims.height) < Int(bDims.width) * Int(bDims.height)
                }
                if let bestFormat = bestFormat,
                   (device.activeFormat.highResolutionStillImageDimensions.width != bestFormat.highResolutionStillImageDimensions.width ||
                    device.activeFormat.highResolutionStillImageDimensions.height != bestFormat.highResolutionStillImageDimensions.height) {
                    restoreFormat = device.activeFormat
                    do {
                        try device.lockForConfiguration()
                        device.activeFormat = bestFormat
                        device.unlockForConfiguration()
                    } catch {
                        restoreFormat = nil
                    }
                }
            }

            var photoSettings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                photoSettings = AVCapturePhotoSettings()
            }

            if #available(iOS 16.0, *) {
                // Don't constrain maxPhotoDimensions - capture full sensor resolution
                // Let AVCapturePhotoSettings default to maximum available
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

            let processor = PhotoCaptureProcessor(targetMegapixels: targetMP, willCapture: { [weak self] in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    if self.settings.shutterSoundEnabled { SoundPlayer.play(.shutter) }
                    self.onWillCapturePhoto?()
                }
            }, completion: { [weak self] image, metadata, errorMessage in
                guard let self = self else { return }
                DispatchQueue.main.async { self.isCapturingPhoto = false }
                self.activePhotoProcessors.removeValue(forKey: photoSettings.uniqueID)

                // Restore the smooth-preview format now that capture is done.
                if let restoreFormat = restoreFormat, let device = self.cameraInput?.device {
                    self.sessionQueue.async {
                        do {
                            try device.lockForConfiguration()
                            device.activeFormat = restoreFormat
                            device.unlockForConfiguration()
                        } catch {
                            // Preview may stay at capture resolution until next mode change — not ideal but not broken.
                        }
                    }
                }

                guard let image = image else {
                    DispatchQueue.main.async { self.notice = errorMessage ?? "Photo capture failed" }
                    return
                }
                self.savePhoto(image, metadata: metadata, to: destination)
            })
            self.activePhotoProcessors[photoSettings.uniqueID] = processor
            self.photoOutput.capturePhoto(with: photoSettings, delegate: processor)
        }
    }

    private func savePhoto(_ image: UIImage, metadata: [String: Any]?, to destination: SaveLocation) {
        DispatchQueue.main.async { self.lastPhotoThumbnail = image }

        guard destination == .photos else {
            ioQueue.async {
                let heicData = Self.encodeHEIC(image, metadata: metadata)
                let data = heicData ?? Self.encodeJPEG(image, metadata: metadata)
                guard let data = data else {
                    DispatchQueue.main.async { self.notice = "Photo failed to save" }
                    return
                }
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                let ext = (heicData != nil) ? "heic" : "jpg"
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
            if let heicData = Self.encodeHEIC(image, metadata: metadata) {
                request.addResource(with: .photo, data: heicData, options: options)
            } else if let jpegData = Self.encodeJPEG(image, metadata: metadata) {
                request.addResource(with: .photo, data: jpegData, options: options)
            }
        }) { [weak self] success, _ in
            DispatchQueue.main.async {
                self?.notice = success ? "Photo saved to Photos" : "Could not save photo"
            }
        }
    }

    /// Encodes as HEIC (what the native Camera app uses) at near-lossless
    /// quality, preserving the image's orientation plus the original EXIF /
    /// TIFF / lens capture metadata (ISO, shutter speed, aperture, focal
    /// length, device model, etc.) so it shows up in the Photos "ⓘ" panel.
    /// Falls back to nil on devices/simulators without HEIC encoder support
    /// so callers can use JPEG instead.
    private static func encodeHEIC(_ image: UIImage, metadata: [String: Any]?) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) else {
            return nil
        }
        var properties = Self.metadataMatchingDimensions(metadata, cgImage: cgImage)
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.92
        properties[kCGImagePropertyOrientation as String] = image.imageOrientation.cgImagePropertyOrientation.rawValue
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// JPEG fallback path that still carries the original capture metadata.
    private static func encodeJPEG(_ image: UIImage, metadata: [String: Any]?) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        var properties = Self.metadataMatchingDimensions(metadata, cgImage: cgImage)
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.95
        properties[kCGImagePropertyOrientation as String] = image.imageOrientation.cgImagePropertyOrientation.rawValue
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Copies the original capture metadata (ISO, shutter speed, lens, GPS,
    /// device model, etc.) but corrects the pixel-dimension fields so they
    /// match the (possibly downscaled) output image, since a mismatch there
    /// can confuse readers of the file.
    private static func metadataMatchingDimensions(_ metadata: [String: Any]?, cgImage: CGImage) -> [String: Any] {
        var properties = metadata ?? [:]
        if var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = cgImage.width
            exif[kCGImagePropertyExifPixelYDimension as String] = cgImage.height
            properties[kCGImagePropertyExifDictionary as String] = exif
        }
        properties[kCGImagePropertyPixelWidth as String] = cgImage.width
        properties[kCGImagePropertyPixelHeight as String] = cgImage.height
        return properties
    }

    /// Standard QuickTime metadata (make, model, software, creation date) so
    /// recorded clips show device info in the Photos app's "ⓘ" panel, the
    /// same fields the stock Camera app writes.
    private static func captureMetadataItems() -> [AVMetadataItem] {
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

    // MARK: Recording control

    func toggleRecording() {
        isRecording ? stopRecording(notice: nil) : startRecording()
    }

    func startRecording() {
        guard !isRecording else { return }
        DebugLog.reset()
        DebugLog.write("===== startRecording() called =====")
        guard freeBytes > Self.reserveBytes else {
            DebugLog.write("❌ blocked: low storage, freeBytes=\(freeBytes)")
            notice = "Low storage · Free space needed"
            return
        }

        if settings.saveLocation == .photos { ensurePhotosAccess() }

        let newPlan = Encoder.plan(for: settings)
        let transform = Self.transform(width: newPlan.width, height: newPlan.height, isFront: isFrontCamera)

        stopRequested = false
        recordingSessionToken += 1
        let myToken = recordingSessionToken

        // Switch sensor to the full target rate (60 / 120 / 240) and attach
        // the sample-buffer delegates only while recording. This keeps idle
        // preview cool and ensures every delivered frame is at the exact
        // rate the encode plan expects.
        //
        // Order matters: apply format + attach delegates *first*, then set
        // wantsRecording. Otherwise early frames can land at the idle 30 fps
        // (or during the format transition) and pull the average down in
        // Photos (especially on short clips).
        // Mark recording before the session work so applyStabilization sees it.
        isRecording = true
        UIApplication.shared.isIdleTimerDisabled = true

        // Check free space more often while recording.
        spaceTimer?.invalidate()
        spaceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshFreeSpace()
        }

        sessionQueue.async {
            self.applyActiveFormat(forRecording: true)
            self.applyStabilization()

            let beginCapture: () -> Void = {
                // Bail if a newer start/stop already superseded this one while
                // we were waiting for exposure to settle.
                guard self.recordingSessionToken == myToken, self.isRecording, !self.stopRequested else { return }
                self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
                self.audioOutput.setSampleBufferDelegate(self, queue: self.audioQueue)

                self.ioQueue.async {
                    self.plan = newPlan
                    self.recordingDestination = self.settings.saveLocation
                    self.clipTransform = transform
                    self.lastElapsedPush = .invalid
                    self.droppedFrameCount = 0
                    // Scale by fps so the discard covers a consistent real-world
                    // settle time — at 240fps slow-mo the same wall-clock ramp
                    // spans many more frames than at 30fps, so a fixed frame
                    // count would under-cover high frame rates and over-cover
                    // low ones.
                    let fps = max(Double(newPlan.frameRate), 1)
                    let rawWarmupFrames = Int((Self.recordStartWarmupSeconds * fps).rounded(.up))
                    let warmup = min(max(rawWarmupFrames, Self.recordStartWarmupFrameFloor), Self.recordStartWarmupFrameCeiling)
                    self.writerLock.lock()
                    self.recordStartPTS = .invalid
                    self.segmentStartInFlight = false
                    self.pendingStartBuffers.removeAll(keepingCapacity: true)
                    self.pendingWarmupFrames = warmup
                    self.wantsRecording = true
                    self.writerLock.unlock()
                }
            }

            if let device = self.cameraInput?.device {
                // Cap the wait itself: the sensor was already running (idle
                // preview) before this call, so this only covers the tail
                // end of AE re-converging to the new record format/exposure
                // target — not a cold start. 0.35s keeps worst-case record
                // start latency imperceptible while still catching the
                // common 2-4 frame dark ramp.
                self.waitForExposureSettled(device: device, timeout: 0.35, completion: beginCapture)
            } else {
                beginCapture()
            }
        }

        notice = nil
        elapsed = 0
        clipsThisSession = 0
        droppedFrames = 0
        audioLevel = 0
        if settings.shutterSoundEnabled { SoundPlayer.play(.start) }
    }

    func stopRecording(notice message: String?) {
        guard isRecording else { return }

        // Snapshot which recording session this stop belongs to. If a
        // *newer* recording has started by the time this actually runs on
        // ioQueue (possible if stop/start are tapped in quick succession,
        // or a prior stop was still finishing up), bail out instead of
        // tearing down the newer session. Without this, a fast
        // stop -> start could let the old stop's async work land after the
        // new recording began, instantly killing it — matching the
        // "start, stop, start again -> instantly errors/instantly saves a
        // blank clip" pattern.
        let myToken = recordingSessionToken

        if settings.shutterSoundEnabled { SoundPlayer.play(.stop) }
        stopRequested = true
        isRecording = false
        isSaving = true
        audioLevel = 0
        UIApplication.shared.isIdleTimerDisabled = false
        notice = message
        refreshFreeSpace()

        // Immediately drop back to low-power idle preview and stop delivering
        // sample buffers. Also turn stabilisation off so the ISP cools down.
        sessionQueue.async {
            self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
            self.audioOutput.setSampleBufferDelegate(nil, queue: nil)
            self.applyActiveFormat(forRecording: false)
            self.applyStabilization()
        }

        // Relax free-space polling while idle again.
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

        ioQueue.async {
            guard myToken == self.recordingSessionToken else {
                // A newer recording has already started; this stop is
                // stale, do not touch its writer/state.
                DispatchQueue.main.async { self.isSaving = false }
                if task != .invalid {
                    UIApplication.shared.endBackgroundTask(task)
                    task = .invalid
                }
                return
            }
            self.writerLock.lock()
            self.wantsRecording = false
            self.pendingStartBuffers.removeAll(keepingCapacity: false)
            self.writerLock.unlock()
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

    private func startSegment(at pts: CMTime, firstSampleBuffer: CMSampleBuffer? = nil) {
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
                if v.append(first) {
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
            writer = w
            videoIn = v
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
                if v.isReadyForMoreMediaData, v.append(buf) {
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
            wantsRecording = false
            writerLock.unlock()
            DispatchQueue.main.async {
                self.isRecording = false
                self.notice = "Encoder error"
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }


    private func finishSegment(_ completion: (() -> Void)? = nil) {
        writerLock.lock()
        guard let w = writer, let v = videoIn else {
            writer = nil; videoIn = nil; audioIn = nil
            writerLock.unlock()
            completion?()
            return
        }
        let a = audioIn
        let end = lastVideoPTS
        let start = segmentStart
        let destination = recordingDestination
        let url = w.outputURL

        writer = nil; videoIn = nil; audioIn = nil
        segmentStart = .invalid
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

    private func rotateSegment(at pts: CMTime, firstSampleBuffer: CMSampleBuffer? = nil) {
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

        writer = nil; videoIn = nil; audioIn = nil
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

    private func audioSettings(for plan: EncodePlan, writer w: AVAssetWriter) -> [String: Any]? {

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

    private func recoverInterruptedRecording() {
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

    private func generateThumbnail(for url: URL) {
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

    private func ensurePhotosAccess() {
        guard PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
    }

    private func deliver(_ url: URL, to destination: SaveLocation, done: @escaping () -> Void) {
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
                    // Free the local copy now that Photos has its own; also
                    // purge any older leftover clips so Documents does not
                    // accumulate when the user always chooses Photos.
                    self.cleanupLocalClipsAfterPhotosSave(keeping: nil)
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
    private func cleanupLocalClipsAfterPhotosSave(keeping currentURL: URL?) {
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

    private func loadLastSavedClip() {
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

    private static func newClipURL() -> URL {
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

    private static func transform(width: Int, height: Int, isFront: Bool) -> CGAffineTransform {
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

// MARK: - Thermal State Display

extension ProcessInfo.ThermalState {
    var shortLabel: String {
        switch self {
        case .nominal, .fair: return "Normal"
        case .serious: return "Warm"
        case .critical: return "Hot"
        @unknown default: return "Normal"
        }
    }

    var icon: String {
        switch self {
        case .nominal, .fair: return "thermometer.low"
        case .serious: return "thermometer.medium"
        case .critical: return "thermometer.high"
        @unknown default: return "thermometer.low"
        }
    }
}

// MARK: - Shutter / Dial Click Sounds

enum SoundPlayer {
    enum Click: SystemSoundID {
        case start = 1117   // begin_record
        case stop = 1118    // end_record
        case shutter = 1108 // photoShutter
        case dial = 1104    // Tock
    }

    static func play(_ click: Click) {
        AudioServicesPlaySystemSound(click.rawValue)
    }
}

// MARK: - Device Model

extension UIDevice {
    /// Human-readable hardware name (e.g. "iPhone 7", "iPhone 15 Pro") for
    /// use in saved-file metadata, resolved from the raw hardware identifier
    /// (e.g. "iPhone9,1"). Falls back to the raw identifier for unrecognized
    /// or newer hardware not yet in this table.
    var modelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let raw = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { ptr in
                String(cString: ptr)
            }
        }

        let map: [String: String] = [
            "iPhone8,4": "iPhone SE",
            "iPhone9,1": "iPhone 7", "iPhone9,3": "iPhone 7",
            "iPhone9,2": "iPhone 7 Plus", "iPhone9,4": "iPhone 7 Plus",
            "iPhone10,1": "iPhone 8", "iPhone10,4": "iPhone 8",
            "iPhone10,2": "iPhone 8 Plus", "iPhone10,5": "iPhone 8 Plus",
            "iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X",
            "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max",
            "iPhone11,8": "iPhone XR",
            "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
            "iPhone12,8": "iPhone SE (2nd generation)",
            "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,6": "iPhone SE (3rd generation)",
            "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,5": "iPhone 16e"
        ]

        if let friendly = map[raw] { return friendly }
        if raw.hasPrefix("iPhone") { return raw }
        return raw // Simulator or unrecognized hardware — show the raw string.
    }
}

// MARK: - UIImage Orientation → CGImagePropertyOrientation

extension UIImage.Orientation {
    var cgImagePropertyOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

// MARK: - Photo Capture Processor

/// Handles a single AVCapturePhotoOutput capture, decoding the delivered
/// image and downscaling it to the requested megapixel target while
/// preserving the original aspect ratio, EXIF orientation, and camera
/// metadata (ISO, shutter speed, lens, focal length, aperture, etc.) so it
/// still shows up in the Photos app's "ⓘ" info panel.
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {

    private let targetMegapixels: Double
    private let willCapture: () -> Void
    private let completion: (UIImage?, [String: Any]?, String?) -> Void

    init(targetMegapixels: Double,
         willCapture: @escaping () -> Void,
         completion: @escaping (UIImage?, [String: Any]?, String?) -> Void) {
        self.targetMegapixels = targetMegapixels
        self.willCapture = willCapture
        self.completion = completion
    }

    /// Fires right as the sensor captures the frame — this is when we play
    /// our shutter sound / trigger our screen-flash overlay, so they land
    /// exactly on the real capture moment instead of on button-tap.
    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        willCapture()
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error = error {
            completion(nil, nil, error.localizedDescription)
            return
        }
        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            completion(nil, nil, "Could not read photo data")
            return
        }
        // photo.metadata carries the real capture info from the sensor
        // (ISO, exposure time, aperture, focal length, lens/device model).
        let resized = Self.resize(image, toMegapixels: targetMegapixels)
        completion(resized, photo.metadata, nil)
    }

    /// Downscales while keeping aspect ratio and orientation. Never upscales.
    private static func resize(_ image: UIImage, toMegapixels targetMP: Double) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let currentPixels = Double(cg.width * cg.height)
        let targetPixels = targetMP * 1_000_000
        guard targetPixels > 0, currentPixels > targetPixels * 1.02 else { return image }

        let scale = (targetPixels / currentPixels).squareRoot()
        let newWidth = max(1, Int((Double(cg.width) * scale).rounded()))
        let newHeight = max(1, Int((Double(cg.height) * scale).rounded()))

        let colorSpace = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        var bitmapInfo = cg.bitmapInfo.rawValue
        // Normalize to a context-compatible alpha layout.
        bitmapInfo = (bitmapInfo & ~CGBitmapInfo.alphaInfoMask.rawValue) | CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(data: nil,
                                       width: newWidth,
                                       height: newHeight,
                                       bitsPerComponent: 8,
                                       bytesPerRow: 0,
                                       space: colorSpace,
                                       bitmapInfo: bitmapInfo) else { return image }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        guard let scaledCG = context.makeImage() else { return image }
        return UIImage(cgImage: scaledCG, scale: 1, orientation: image.imageOrientation)
    }
}

// MARK: - Sample buffers

extension CameraRecorder: AVCaptureVideoDataOutputSampleBufferDelegate,
                          AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        if stopRequested {
            writerLock.lock()
            let stillWanted = wantsRecording
            writerLock.unlock()
            if stillWanted { DebugLog.write("⚠️ frame dropped: stopRequested=true while wantsRecording=true (race)") }
            return
        }

        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let isVideo = (output === videoOutput)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let dur = CMSampleBufferGetDuration(sampleBuffer)

        // Snapshot all shared state under one lock hold so video and audio
        // paths stay consistent and we never leave the lock held across
        // the (potentially blocking) append path.
        writerLock.lock()
        let currentlyWants = wantsRecording
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
                vIn?.append(sampleBuffer)
                writerLock.lock()
                lastVideoPTS = Self.endPTS(for: pts, duration: dur, fps: plan?.frameRate ?? 30)
                writerLock.unlock()
            } else {
                // Prefer a clean drop over blocking the real-time video queue.
                // Drops still hurt average-fps reporting in Photos, so keep
                // bitrates conservative on A10 (see Encoder ceilings).
                countDroppedFrame()
            }
            pushElapsed(pts)
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

    private func countDroppedFrame() {
        writerLock.lock()
        droppedFrameCount += 1
        writerLock.unlock()
    }

    /// End timestamp for a written frame. Prefer the buffer's own duration;
    /// if it's invalid (common on some A10 paths), fall back to 1/fps so
    /// endSession does not undershoot and Photos duration stays consistent
    /// with frame count.
    private static func endPTS(for pts: CMTime, duration: CMTime, fps: Int) -> CMTime {
        if duration.isValid && duration.isNumeric && duration.seconds > 0 {
            return CMTimeAdd(pts, duration)
        }
        let safeFPS = max(fps, 1)
        let oneFrame = CMTime(value: 1, timescale: CMTimeScale(safeFPS))
        return CMTimeAdd(pts, oneFrame)
    }

    private func pushElapsed(_ pts: CMTime) {
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

    private func currentAudioLevel() -> Float {
        guard let channel = audioOutput.connection(with: .audio)?.audioChannels.first else { return 0 }
        let db = channel.averagePowerLevel
        let normalized = (db + 50) / 50
        return Float(max(0, min(1, normalized)))
    }
}

// MARK: - Volume Shutter Observer

final class VolumeButtonObserver: NSObject {
    private var audioSession: AVAudioSession { AVAudioSession.sharedInstance() }
    private var volumeView: MPVolumeView?
    private var isObserving = false
    private var lastVolume: Float?
    private var ignoreUntil: Date = .distantFuture
    /// Volume level we restore to after treating a press as a shutter trigger,
    /// so using the volume buttons does not permanently change system volume.
    private var volumeToRestore: Float?
    var onVolumeTrigger: (() -> Void)?

    func start() {
        guard !isObserving else { return }
        do {
            try audioSession.setActive(true, options: [])
        } catch { }

        DispatchQueue.main.async {
            if self.volumeView == nil {
                let v = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
                v.clipsToBounds = true
                v.alpha = 0.01
                if let window = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first?.windows.first {
                    window.addSubview(v)
                    self.volumeView = v
                }
            }
        }

        lastVolume = audioSession.outputVolume
        ignoreUntil = Date().addingTimeInterval(1.5)
        audioSession.addObserver(self, forKeyPath: "outputVolume", options: [.new, .old], context: nil)
        isObserving = true
    }

    func stop() {
        guard isObserving else { return }
        audioSession.removeObserver(self, forKeyPath: "outputVolume")
        isObserving = false
        DispatchQueue.main.async {
            self.volumeView?.removeFromSuperview()
            self.volumeView = nil
        }
    }

    func ignoreTemporarily(duration: TimeInterval = 1.5) {
        let candidate = Date().addingTimeInterval(duration)
        if candidate > ignoreUntil {
            ignoreUntil = candidate
        }
    }

    /// Best-effort restore of system volume via the hidden MPVolumeView slider.
    private func restoreVolumeIfNeeded() {
        guard let target = volumeToRestore else { return }
        volumeToRestore = nil
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let slider = self.volumeView?.subviews.compactMap({ $0 as? UISlider }).first else { return }
            // Ignore the KVO noise we are about to generate.
            self.ignoreTemporarily(duration: 0.8)
            slider.value = target
            self.lastVolume = target
        }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "outputVolume" {
            let currentVol = audioSession.outputVolume
            if Date() < ignoreUntil {
                lastVolume = currentVol
                return
            }
            if let prev = lastVolume {
                if abs(currentVol - prev) > 0.01 {
                    // Remember the *previous* level so we can put it back after
                    // treating this press as a shutter. Works at the extremes
                    // as long as the system still reports a delta (some iOS
                    // versions still fire when volume is clamped).
                    volumeToRestore = prev
                    lastVolume = currentVol
                    onVolumeTrigger?()
                    restoreVolumeIfNeeded()
                }
            } else {
                lastVolume = currentVol
            }
        }
    }
}
