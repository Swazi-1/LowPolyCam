import AVFoundation
import UIKit
import Photos
import MediaPlayer
import CoreMotion
import Combine
import AudioToolbox
import ImageIO
import CoreImage

final class CameraRecorder: NSObject, ObservableObject {

    // MARK: Tunables

    // Recording tunables — owned by VideoRecordingSystem (shared Video + Slow-Mo).
    static let fragmentSeconds: Double = VideoRecordingSystem.fragmentSeconds
    static let reserveBytes: Int64 = VideoRecordingSystem.reserveBytes
    static let recordStartWarmupSeconds: Double = VideoRecordingSystem.recordStartWarmupSeconds
    static let recordStartWarmupFrameFloor = VideoRecordingSystem.recordStartWarmupFrameFloor
    static func recordStartWarmupFrameCeiling(fps: Int) -> Int {
        VideoRecordingSystem.recordStartWarmupFrameCeiling(fps: fps)
    }
    static let inProgressKey = "inProgressClipName"

    // Used by the stop-recording flow in CameraRecording.swift to guard
    // against a stale background task finishing after a newer one started.
    var pendingStopToken: Int = 0
    var pendingStopBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    // MARK: Published state

    @Published var isRecording = false
    @Published var isSaving = false
    @Published var isSessionRunning = false
    @Published var permissionDenied = false
    @Published var elapsed: TimeInterval = 0
    @Published var clipsThisSession = 0
    @Published var droppedFrames = 0
    @Published var freeBytes: Int64 = 0
    @Published var hasTorch = false
    @Published var torchOn = false
    /// Front camera has no physical torch. This drives a screen-illumination
    /// "flash" for selfies instead (see CameraScreen's performFrontFlashCapture),
    /// same idea as the stock Camera app's selfie flash.
    @Published var frontFlashEnabled = false
    @Published var isFrontCamera = false
    @Published var isSwitchingCamera = false
    @Published var stabilizationSupported = true
    @Published var availableFrameRates: [FrameRate] = FrameRate.allCases
    @Published var availableResolutions: [Resolution] = Resolution.allCases
    @Published var availableSlowMoRates: [SlowMoFrameRate] = SlowMoFrameRate.allCases
    @Published var availableSlowMoResolutions: [Resolution] = [.p1080, .p720]
    /// Per-resolution map of slow-mo FPS support. Used so selecting e.g. 1080p
    /// only offers FPS rates the hardware can actually deliver at that size
    /// (iPhone 7: 240 fps is available at 720p but not at 1080p).
    var slowRatesByResolution: [Resolution: Set<SlowMoFrameRate>] = [:]
    @Published var isSlowMoSupportedOnCurrentLens = true
    @Published var batteryPercent: Int = -1
    @Published var batteryCharging = false
    @Published var zoomFactor: CGFloat = 1
    @Published var maxZoomFactor: CGFloat = 1
    @Published var minZoomFactor: CGFloat = 1
    @Published var audioLevel: Float = 0
    @Published var lastClipThumbnail: UIImage?
    @Published var lastClipURL: URL?

    // Photo mode
    @Published var isCapturingPhoto = false
    @Published var availablePhotoMegapixels: [PhotoMegapixels] = PhotoMegapixels.allCases
    @Published var lastPhotoThumbnail: UIImage?

    // Thermal state
    @Published var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    // Level Telemetry & Physical Orientation
    @Published var physicalOrientation: PhysicalOrientation = .portrait
    @Published var uiRotationAngle: Double = 0
    @Published var isLevel: Bool = false
    @Published var rollAngle: Double = 0
    @Published var notice: String?

    /// Fired the instant the sensor actually captures the photo (from
    /// AVCapturePhotoOutput's willCapturePhotoFor delegate callback), so the
    /// UI's screen-flash overlay is synced to the real capture moment
    /// instead of firing early on button tap.
    var onWillCapturePhoto: (() -> Void)?

    let session = AVCaptureSession()

    // MARK: Private

    let settings: AppSettings
    let sessionQueue = DispatchQueue(label: "lowpolycam.session")
    // Video sample buffers land on their own high-priority queue so nothing
    // else (audio delivery, segment rotation, finishWriting bookkeeping) can
    // ever block or delay a video frame. Sharing a single queue for video +
    // audio + writer teardown was causing the AVAssetWriter to miss frames
    // under load (e.g. new AVAssetWriter/encoder session spin-up at segment
    // rotation), which is what made Photos report a non-30 average fps
    // (24.64, 26.51, etc.) even though the file's wall-clock duration was
    // correct — the frame *count* was just short.
    let videoQueue = DispatchQueue(label: "lowpolycam.video", qos: .userInteractive)
    let audioQueue = DispatchQueue(label: "lowpolycam.audio", qos: .userInitiated)
    let ioQueue = DispatchQueue(label: "lowpolycam.io", qos: .userInitiated)
    /// Dedicated stop/finalize lane. Stop completion must not wait behind
    /// camera/storage work queued on ioQueue, especially at 120/240fps.
    let finalizeQueue = DispatchQueue(label: "lowpolycam.finalize", qos: .userInitiated)
    let motionManager = CMMotionManager()

    let videoOutput = AVCaptureVideoDataOutput()
    let audioOutput = AVCaptureAudioDataOutput()
    let photoOutput = AVCapturePhotoOutput()
    var activePhotoProcessors: [Int64: PhotoCaptureProcessor] = [:]
    var appliedThermalMitigation = false
    /// Brightness snapshot taken when thermal mitigation first dims the screen.
    /// Restored when thermal state returns to nominal/fair so the screen does
    /// not stay permanently dimmed after cooling down.
    var thermalSavedBrightness: CGFloat?
    var cameraInput: AVCaptureDeviceInput?

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
    var lastAppliedFormatKey: String?

    static func formatKey(device: AVCaptureDevice, format: AVCaptureDevice.Format, fps: Double) -> String {
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
    func waitForExposureSettled(device: AVCaptureDevice, timeout: TimeInterval = 0.35, completion: @escaping () -> Void) {
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
    var micInput: AVCaptureDeviceInput?
    var position: AVCaptureDevice.Position = .back
    var isConfigured = false
    var spaceTimer: Timer?
    var volumeObserver: VolumeButtonObserver?

    // Writer state
    var writer: AVAssetWriter?
    var videoIn: AVAssetWriterInput?
    var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    /// Shared software CIContext for downscaling camera frames to 144p/320p/480p.
    /// Software renderer is intentional: Metal CI into non-Metal pool buffers
    /// fails silently on iPhone 7 / iOS 15.8.
    lazy var scaleCIContext: CIContext = CIContext(options: [.useSoftwareRenderer: true])
    /// Own pool for downscaled frames (144p/320p/480p). Created per segment so
    /// the first clip after launch is not missing a pool (adaptor.pixelBufferPool
    /// is often still nil on the first append after startWriting on iOS 15).
    var scalePixelBufferPool: CVPixelBufferPool?
    var audioIn: AVAssetWriterInput?
    var segmentStart = CMTime.invalid
    var lastVideoPTS = CMTime.invalid
    /// Duration of the last appended video sample — used so endSession
    /// covers the final frame instead of ending at its start PTS.
    var lastVideoDuration = CMTime.invalid
    var recordStartPTS = CMTime.invalid
    // Protected by writerLock (together with writer / videoIn / audioIn /
    // segmentStart / lastVideoPTS / recordStartPTS / segmentStartInFlight).
    // These flags are read on videoQueue/audioQueue and written from ioQueue
    // and sessionQueue; previously unprotected → data races under concurrent
    // frame delivery + start/stop.
    var wantsRecording = false
    /// Wall-clock stop drain: after Stop, keep writing video until this host time.
    var stopDrainDeadlineHost: CFTimeInterval = 0
    var isStopDraining = false
    /// Frames that arrived during stop while the writer input was not ready.
    var pendingStopBuffers: [CMSampleBuffer] = []
    static let pendingStopBufferLimit = 20
    /// Frames that arrive mid-recording during a brief encoder stall.
    /// Previously these were dropped outright the instant
    /// `isReadyForMoreMediaData` was false, which is what made Photos
    /// report an average fps below the target (e.g. 56.7 instead of 60)
    /// even though every frame was captured — frame count in the file was
    /// lower than the real-time span. Buffering a couple of frames and
    /// flushing them the moment the encoder catches up recovers most of
    /// that shortfall. Kept small and capped per-callback on purpose: at
    /// high fps a callback only has a few ms, so this only absorbs brief
    /// hiccups, not a sustained overload.
    var pendingMidBuffers: [CMSampleBuffer] = []
    static let pendingMidBufferLimit = 4
    // Number of video frames to silently discard right after a *fresh*
    // record start (not segment rotation). Deterministic fallback for the
    // AE/AGC brightness ramp after a format switch. Touched under writerLock.
    var pendingWarmupFrames = 0
    // Guards against dispatching startSegment more than once for the same
    // segment. Multiple video frames can arrive on videoQueue and all see
    // writer == nil before the *first* startSegment call (running on
    // ioQueue) finishes its setup and assigns `writer` — each of those
    // frames would otherwise fire its own startSegment, all racing to
    // create an AVAssetWriter at the same (or near-identical) file path,
    // which fails with "Cannot Save" (AVFoundationErrorDomain -11823) and
    // was the actual cause of "press record, it instantly stops."
    var segmentStartInFlight = false
    /// Video frames that arrive while AVAssetWriter is still spinning up
    /// (segmentStartInFlight && writer == nil). Previously these were
    /// silently dropped, which left gaps in the PTS timeline and made
    /// Photos report e.g. 27.52 fps instead of 30.00 on short clips.
    /// Buffered under writerLock and flushed in order once the writer is live.
    var pendingStartBuffers: [CMSampleBuffer] = []
    static let pendingStartBufferLimit = 18
    var plan: EncodePlan?
    var clipTransform = CGAffineTransform.identity
    var freeBytesSnapshot: Int64 = .max
    var lastElapsedPush = CMTime.invalid
    var recordWallStart: Date?
    var recordElapsedTimer: Timer?
    var droppedFrameCount = 0
    var recordingDestination: SaveLocation = .files
    /// Destination that was active when the in-progress clip was started.
    /// Stored so recovery after an interruption uses the original location
    /// instead of whatever the user has selected now.
    static let inProgressDestinationKey = "inProgressClipDestination"

    let stopLock = NSLock()
    var _stopRequested = false
    var stopRequested: Bool {
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
    var recordingSessionToken: Int = 0

    // Guards writer/videoIn/audioIn/segmentStart/lastVideoPTS/recordStartPTS,
    // wantsRecording, pendingWarmupFrames, segmentStartInFlight.
    // Touched from videoQueue, audioQueue and ioQueue concurrently.
    let writerLock = NSLock()

    var rawMaxZoomSnapshot: CGFloat = 1
    var rawMinZoomSnapshot: CGFloat = 1
    var zoomBaselineSnapshot: CGFloat = 1

    var lastRawRollAngle: Double?
    var unwrappedRollAngle: Double = 0

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

    func applyThermalState(_ state: ProcessInfo.ThermalState) {
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
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        // Volume shutter must match the current mode — photo
                        // mode used to start a video recording by mistake.
                        if self.settings.cameraMode == .photo {
                            self.capturePhoto()
                        } else {
                            self.toggleRecording()
                        }
                    }
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
        volumeObserver?.ignoreTemporarily(duration: 1.5)
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

    func requestAccess(_ done: @escaping (Bool) -> Void) {
        // Camera → Mic → Photos (add-only). Photos is requested up front so the
        // first Save-to-Photos recording never hits an unexpected auth path.
        AVCaptureDevice.requestAccess(for: .video) { videoOK in
            guard videoOK else { done(false); return }
            let afterAudio = {
                let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
                if status == .notDetermined {
                    PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in
                        done(true)
                    }
                } else {
                    done(true)
                }
            }
            if self.settings.recordAudio {
                AVCaptureDevice.requestAccess(for: .audio) { _ in afterAudio() }
            } else {
                afterAudio()
            }
        }
    }
}
