import AVFoundation
import UIKit
import Photos
import MediaPlayer
import CoreMotion
import Combine
import AudioToolbox
import ImageIO
import CoreImage
import VideoToolbox

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
    /// 📊 Live recording stats (measured FPS, dropped-frame rate, bitrate).
    /// Fed from the existing sample-buffer/elapsed path in
    /// CameraSampleBuffers.swift — see RecordingStatsSystem.swift.
    @Published var recordingStats = RecordingStatsSnapshot()
    @Published var freeBytes: Int64 = 0
    @Published var hasTorch = false
    @Published var torchOn = false
    /// Front camera has no physical torch. This drives a screen-illumination
    /// "flash" for selfies instead (see CameraScreen's performFrontFlashCapture),
    /// same idea as the stock Camera app's selfie flash.
    @Published var frontFlashEnabled = false
    @Published var isFrontCamera = false
    @Published var isSwitchingCamera = false
    /// True while changing Video / Photo / Slow-Mo formats. The UI uses this
    /// to cover the unavoidable sensor renegotiation with a short fade.
    @Published var isSwitchingMode = false
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
    /// Zoom factor (UI units, 1x = the physical wide lens) beyond which the
    /// image is no longer coming straight off the sensor at native
    /// resolution but is being digitally cropped/interpolated. iPhone 7 has
    /// a single physical (wide) lens, so this is always 1x — there is no
    /// second optical lens for the system to switch to.
    @Published var opticalZoomCeiling: CGFloat = 1
    /// True while focus is locked at a fixed point (tap-and-hold on the
    /// preview) instead of continuously re-focusing.
    @Published var focusLocked = false
    /// True while exposure is locked at a fixed point (two-finger
    /// tap-and-hold on the preview) instead of continuously re-metering.
    @Published var exposureLocked = false
    @Published var audioLevel: Float = 0
    @Published var lastClipThumbnail: UIImage?
    @Published var lastClipURL: URL?

    // Photo mode
    @Published var isCapturingPhoto = false
    @Published var availablePhotoMegapixels: [PhotoMegapixels] = PhotoMegapixels.allCases
    @Published var lastPhotoThumbnail: UIImage?
    // MARK: Photo 2.0 — Burst mode
    /// True while a burst sequence is actively firing frames.
    @Published var isBursting = false
    /// Frames captured so far in the current burst (for the on-screen counter).
    @Published var burstShotsTaken = 0
    /// Total frames requested for the current burst (settings.burstCount at
    /// the moment the burst started — snapshotted so a mid-burst settings
    /// change can't desync the counter).
    @Published var burstShotsTotal = 0
    /// URLs (Files) or nothing (Photos, which has no stable local URL) for
    /// the most recently completed burst, freshest first. Used to seed the
    /// post-capture review sheet with "swipe through this burst".
    @Published var lastBurstReviewItems: [PhotoReviewItem] = []
    /// The single most recent capture (single shot or last burst frame),
    /// used to open the post-capture review sheet.
    @Published var lastPhotoReviewItem: PhotoReviewItem?
    /// Bumped every time a fresh capture (single or burst) finishes, so the
    /// UI can open the review sheet exactly once per capture via onChange.
    @Published var photoReviewToken: Int = 0
    /// Full-resolution bursts are a sequence of still captures. Cancellation
    /// finishes the current still cleanly, then restores the preview format.
    var burstCancellationRequested = false

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
    /// The rear-camera photo choice is remembered while the front lens limits
    /// its available megapixels, then restored when the rear lens returns.
    var rearPhotoMegapixelsBeforeFront: PhotoMegapixels?
    var lastCapabilitiesCameraPosition: AVCaptureDevice.Position?

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
    /// Scaler used when the sharp camera preview is larger than the selected
    /// saved-video tier. Core Image is available throughout the supported
    /// platform range and avoids an extra capture-session reconfiguration.
    let scaleContext = CIContext(options: [.useSoftwareRenderer: false])
    /// Own pool for downscaled video frames. It is created per segment rather
    /// than relying on adaptor.pixelBufferPool, which can still be nil for the
    /// first append on iOS 15.
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
    /// 📊 Backing tracker for `recordingStats`. Touched only from the same
    /// places that already touch droppedFrameCount/lastVideoPTS — never
    /// takes writerLock itself, so it cannot introduce a new deadlock path.
    let statsTracker = RecordingStatsTracker()
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

        // 🧪 Camera-lifecycle recovery. Without these, an AVCaptureSession
        // runtime error (common on A10 under thermal/media-services stress)
        // or a system interruption (phone call, Siri, another app grabbing
        // the camera) silently leaves the session stopped with no observer
        // ever finding out — the preview just goes black and stays that way
        // until the app is killed and relaunched. See handleRuntimeError /
        // handleSessionWasInterrupted below.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRuntimeError),
            name: .AVCaptureSessionRuntimeError, object: session)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSessionWasInterrupted),
            name: .AVCaptureSessionWasInterrupted, object: session)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSessionInterruptionEnded),
            name: .AVCaptureSessionInterruptionEnded, object: session)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSessionDidStartRunning),
            name: .AVCaptureSessionDidStartRunning, object: session)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSessionDidStopRunning),
            name: .AVCaptureSessionDidStopRunning, object: session)
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
            // Keep this separate from the critical-state flag below. A later
            // .critical notification must still apply the stronger preview
            // throttle and 30% brightness cap.
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
            // Serious heat only dims the screen; it does not set the critical
            // preview-throttle flag. Restore whenever we own a saved brightness
            // snapshot so a serious-only event cannot leave the display dimmed.
            if appliedThermalMitigation || thermalSavedBrightness != nil {
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

        DebugLog.write("🎙️ audio interruption type=\(type == .began ? "began" : "ended") wasRecording=\(isRecording)")

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
        // Adaptive rate: full rate only when the level-gauge UI is visible;
        // otherwise a slow trickle is enough for orientation (photo upright
        // + UI rotation). Longevity Mode trims both further — CoreMotion
        // polling is a small but constant power draw for as long as the
        // camera is open. See PerformanceProfile.motionUpdateHz.
        let hz = PerformanceProfile.current(settings: settings, thermalState: thermalState)
            .motionUpdateHz(gaugeVisible: settings.showLevelGauge)
        motionManager.deviceMotionUpdateInterval = 1.0 / hz
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            guard let self = self, let motion = motion else { return }
            let gx = motion.gravity.x
            let gy = motion.gravity.y
            let gz = motion.gravity.z

            // atan2(gx, -gy) reads rotation *around the z-axis* (screen facing
            // you dead-on). That's only meaningful when the phone is roughly
            // upright. Point the camera steeply up or down — aiming up at a
            // shelf, or flat on a desk — and gx/gy both collapse toward zero
            // while gz dominates; at that point atan2 is amplifying sensor
            // noise, not measuring orientation, and can snap to *any* of the
            // four quadrants almost at random. That's what produced photos
            // saved sideways/upside-down when shot at a steep tilt: the last
            // noisy reading just happened to land in the wrong 90° bucket.
            // Guard: only trust the reading once the horizontal gravity
            // component is large enough to actually distinguish portrait
            // from landscape. Below that, keep the last known-good
            // orientation rather than following the noise.
            let horizontalMagnitude = (gx * gx + gy * gy).squareRoot()
            guard horizontalMagnitude > 0.35 else { return }
            _ = gz // (kept for clarity of the guard's reasoning above)

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

    /// Call when the level-gauge toggle (or Longevity Mode) changes so
    /// CoreMotion rate tracks the UI. See PerformanceProfile.motionUpdateHz.
    func refreshMotionUpdateRate() {
        guard motionManager.isDeviceMotionAvailable else { return }
        let hz = PerformanceProfile.current(settings: settings, thermalState: thermalState)
            .motionUpdateHz(gaugeVisible: settings.showLevelGauge)
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
        DebugLog.write("===== CameraRecorder.start() called (isConfigured=\(isConfigured)) =====")
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
            DebugLog.write("start() requestAccess granted=\(granted)")
            guard granted else {
                DispatchQueue.main.async { self.permissionDenied = true }
                return
            }
            self.sessionQueue.async {
                if !self.isConfigured {
                    DebugLog.write("start() configureSession() beginning")
                    self.configureSession()
                    self.isConfigured = true
                    DebugLog.write("start() configureSession() done, inputs=\(self.session.inputs.count) outputs=\(self.session.outputs.count)")
                }
                self.startRunningWithRetry(attempt: 1)
            }
        }
    }

    /// Kicks off `AVCaptureSession.startRunning()` and confirms it actually
    /// took effect. `startRunning()` can silently no-op (isRunning stays
    /// false, no error/notification) right after the app relaunches into an
    /// interrupted state, or immediately after a media-services reset — the
    /// old code called it once and just trusted it, which on an iPhone 7
    /// occasionally left the preview permanently black until force-quit.
    /// Retrying a couple of times with a short backoff clears that without
    /// needing the user to do anything.
    private func startRunningWithRetry(attempt: Int, maxAttempts: Int = 3) {
        if !session.isRunning {
            DebugLog.write("start() calling session.startRunning() attempt=\(attempt)")
            session.startRunning()
        }
        let running = session.isRunning
        DebugLog.write("start() post-startRunning isRunning=\(running) attempt=\(attempt)")
        DispatchQueue.main.async {
            self.isSessionRunning = running
            self.resumeVolumeMonitoring()
        }
        guard !running, attempt < maxAttempts else {
            if !running {
                DebugLog.write("❌ start() gave up after \(attempt) attempts, session still not running")
                DispatchQueue.main.async { self.notice = "Camera failed to start" }
            }
            return
        }
        sessionQueue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.startRunningWithRetry(attempt: attempt + 1, maxAttempts: maxAttempts)
        }
    }

    func stop() {
        DebugLog.write("===== CameraRecorder.stop() called (wasRunning=\(session.isRunning), isRecording=\(isRecording)) =====")
        spaceTimer?.invalidate()
        spaceTimer = nil
        pauseVolumeMonitoring()
        stopMotionUpdates()
        isSwitchingCamera = false

        if isRecording { stopRecording(notice: nil) }
        if isBursting { cancelBurstCapture() }
        setTorch(on: false)
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isSessionRunning = false }
        }
    }

    // MARK: Runtime error / interruption recovery

    @objc private func handleRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
        let code = (error?.code).map { AVError.Code(rawValue: $0) }
        DebugLog.write("❌ AVCaptureSessionRuntimeError: \(error?.localizedDescription ?? "unknown") code=\(String(describing: code))")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.isRecording {
                self.stopRecording(notice: "Recording stopped (camera error)")
            }
        }

        // .mediaServicesWereReset invalidates the whole capture graph — the
        // existing session/inputs/outputs are dead and must be rebuilt from
        // scratch, not just restarted. Anything else, a plain restart is
        // usually enough (this mirrors what AVFoundation's own docs
        // recommend for runtime-error recovery).
        let needsFullReconfigure = (code == .mediaServicesWereReset)
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if needsFullReconfigure {
                DebugLog.write("🔧 media services reset — reconfiguring capture session from scratch")
                if self.session.isRunning { self.session.stopRunning() }
                self.session.beginConfiguration()
                self.session.inputs.forEach { self.session.removeInput($0) }
                self.session.outputs.forEach { self.session.removeOutput($0) }
                self.session.commitConfiguration()
                self.cameraInput = nil
                self.micInput = nil
                self.isConfigured = false
                self.configureSession()
                self.isConfigured = true
            }
            self.startRunningWithRetry(attempt: 1)
        }
    }

    @objc private func handleSessionWasInterrupted(_ notification: Notification) {
        var reasonText = "unknown"
        if let raw = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
           let reason = AVCaptureSession.InterruptionReason(rawValue: raw) {
            switch reason {
            case .videoDeviceNotAvailableInBackground: reasonText = "videoDeviceNotAvailableInBackground"
            case .audioDeviceInUseByAnotherClient: reasonText = "audioDeviceInUseByAnotherClient"
            case .videoDeviceInUseByAnotherClient: reasonText = "videoDeviceInUseByAnotherClient"
            case .videoDeviceNotAvailableWithMultipleForegroundApps: reasonText = "videoDeviceNotAvailableWithMultipleForegroundApps"
            case .videoDeviceNotAvailableDueToSystemPressure: reasonText = "videoDeviceNotAvailableDueToSystemPressure"
            @unknown default: reasonText = "unknown(\(raw))"
            }
        }
        DebugLog.write("⚠️ AVCaptureSessionWasInterrupted reason=\(reasonText) isRecording=\(isRecording)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isSessionRunning = false
            if self.isRecording {
                self.stopRecording(notice: "Recording stopped (camera interrupted)")
            } else {
                self.notice = "Camera interrupted"
            }
        }
    }

    @objc private func handleSessionInterruptionEnded(_ notification: Notification) {
        DebugLog.write("✅ AVCaptureSessionInterruptionEnded, restarting session")
        sessionQueue.async { [weak self] in
            self?.startRunningWithRetry(attempt: 1)
        }
    }

    @objc private func handleSessionDidStartRunning(_ notification: Notification) {
        DebugLog.write("session didStartRunning")
    }

    @objc private func handleSessionDidStopRunning(_ notification: Notification) {
        DebugLog.write("session didStopRunning")
    }

    /// Fully pause the capture pipeline (sensor + ISP). Call when a sheet
    /// covers the preview so the phone can cool like the stock Camera app
    /// does when you leave the viewfinder.
    func pausePreviewSession() {
        guard !isRecording else { return }
        if isBursting { cancelBurstCapture() }
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

    /// Re-apply every Longevity-Mode-sensitive live setting (idle preview
    /// format + CoreMotion rate) — call after toggling Longevity Mode.
    /// See PerformanceProfile.swift.
    func refreshIdleFormatIfNeeded() {
        refreshMotionUpdateRate()
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
