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
/// A recording is one continuous file, however long it runs, the way the
/// built-in Camera app behaves. It is written as a *fragmented* movie: the
/// playable index is flushed to disk every few seconds, so if the battery dies
/// or iOS kills the app mid-recording, what was filmed up to that moment is
/// still a valid video rather than a dead file. On the next launch
/// `recoverInterruptedRecording` finds it and files it away properly.
final class CameraRecorder: NSObject, ObservableObject {

    // MARK: Tunables

    /// How often the movie index is flushed to disk. This is what makes an
    /// interrupted recording survive - worst case you lose this many seconds
    /// off the end, not the whole file.
    static let fragmentSeconds: Double = 4
    /// Recording stops when free space drops below this.
    static let reserveBytes: Int64 = 300 * 1024 * 1024
    /// Remembers the file being written, so a recording cut short by a flat
    /// battery can be picked up again next launch.
    private static let inProgressKey = "inProgressClipName"

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
    /// Frames the system threw away, plus any the encoder was not ready for.
    /// Shown live while recording: if this stays at 0 the recording really is
    /// hitting its full frame rate, and if it climbs we know precisely where
    /// the loss is rather than having to infer it from the finished file.
    @Published private(set) var droppedFrames = 0
    @Published private(set) var freeBytes: Int64 = 0
    @Published private(set) var hasTorch = false
    @Published private(set) var torchOn = false
    @Published private(set) var isFrontCamera = false
    @Published private(set) var stabilizationSupported = true
    /// What the camera currently in use can actually do. The front camera on
    /// an iPhone 7 tops out at 30 fps, so the unavailable choices are shown
    /// greyed out rather than silently doing nothing.
    @Published private(set) var availableFrameRates: [FrameRate] = FrameRate.allCases
    @Published private(set) var availableResolutions: [Resolution] = Resolution.allCases
    /// -1 while the phone has not reported a level yet (simulators, or the
    /// first instant after enabling monitoring).
    @Published private(set) var batteryPercent: Int = -1
    @Published private(set) var batteryCharging = false
    /// Current zoom, so the UI can show "2.3x" without asking the device
    /// directly from the main thread.
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var maxZoomFactor: CGFloat = 1
    /// Below 1.0 only on a phone whose back camera folds an ultra-wide lens
    /// into the same virtual device - stays 1.0 on a single-lens phone.
    @Published private(set) var minZoomFactor: CGFloat = 1
    /// 0...1, read from the system's own per-channel level rather than
    /// decoding PCM by hand - cheap enough to poll a few times a second.
    @Published private(set) var audioLevel: Float = 0
    @Published var notice: String?

    let session = AVCaptureSession()

    // MARK: Private

    private let settings: AppSettings
    private let sessionQueue = DispatchQueue(label: "lowpolycam.session")
    /// Frames arrive on this queue and are handed straight to the encoder, so
    /// it has to win against background work - at 60 fps there are only ~16 ms
    /// between frames, and anything that delays this queue shows up directly
    /// as a dropped frame.
    private let ioQueue = DispatchQueue(label: "lowpolycam.io", qos: .userInitiated)

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
    /// Capture-queue-only running total, mirrored to `droppedFrames` for the UI.
    private var droppedFrameCount = 0

    /// Set the instant stop is tapped, from whatever thread taps it.
    ///
    /// Frames are no longer discarded when they arrive late (that was costing
    /// us frame rate), which means a burst of them can be sitting in the
    /// capture queue at any moment. The block that actually closes the file is
    /// queued behind those, so on its own "stop" could take visibly long to
    /// happen - worst on the front camera, where a heavier fallback capture
    /// format makes the backlog deeper. Checking this flag at the very top of
    /// the frame handler lets that backlog drain in an instant instead.
    private let stopLock = NSLock()
    private var _stopRequested = false
    private var stopRequested: Bool {
        get { stopLock.lock(); defer { stopLock.unlock() }; return _stopRequested }
        set { stopLock.lock(); _stopRequested = newValue; stopLock.unlock() }
    }

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        refreshFreeSpace()
        NotificationCenter.default.addObserver(
            self, selector: #selector(willResignActive),
            name: UIApplication.willResignActiveNotification, object: nil)

        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshBattery),
            name: UIDevice.batteryLevelDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshBattery),
            name: UIDevice.batteryStateDidChangeNotification, object: nil)
        refreshBattery()

        // Posted by the capture device itself once the scene has moved on
        // from whatever was tapped - the cue to stop holding that point.
        NotificationCenter.default.addObserver(
            self, selector: #selector(subjectAreaDidChange),
            name: .AVCaptureDeviceSubjectAreaDidChange, object: nil)
    }

    @objc private func refreshBattery() {
        let level = UIDevice.current.batteryLevel
        let state = UIDevice.current.batteryState
        DispatchQueue.main.async {
            self.batteryPercent = level < 0 ? -1 : Int((level * 100).rounded())
            self.batteryCharging = (state == .charging || state == .full)
        }
    }

    // MARK: Lifecycle

    func start() {
        refreshFreeSpace()
        recoverInterruptedRecording()
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

        // This is the frame-rate fix. Left at `true`, AVFoundation throws away
        // any frame that arrives while the delegate queue is still busy with
        // the previous one - at 1080p60 that quietly costs a fraction of a
        // frame per second and is exactly why recordings measured ~59.35 fps
        // instead of ~59.97. Set to false, a briefly-late frame waits its turn
        // instead of being discarded.
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoOutput.setSampleBufferDelegate(self, queue: ioQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        audioOutput.setSampleBufferDelegate(self, queue: ioQueue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        session.commitConfiguration()

        configureVideoConnection()
        refreshCapabilitiesThenApplyFormat()
        refreshTorchState()
        // Start in continuous auto explicitly rather than trusting whatever
        // the device happened to default to.
        resetFocusAndExposureToAuto()
        syncMicInput()
    }

    /// The buffers are kept in the sensor's own landscape orientation and the
    /// rotation is stored as metadata on the file instead. Rotating pixels for
    /// hours would cost real battery for no benefit.
    ///
    /// The front camera is mirrored here so the recording matches the
    /// mirrored preview you were looking at while filming. Without this the
    /// preview is a mirror but the saved clip is not, which reads as the
    /// selfie video being "flipped" the moment you play it back.
    private func configureVideoConnection() {
        guard let c = videoOutput.connection(with: .video) else { return }
        if c.isVideoOrientationSupported { c.videoOrientation = .landscapeRight }
        if c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = (position == .front)
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

        // 4K only holds up at 30 fps here - keep Settings in sync rather than
        // silently hunting for an unsupported 4K+60 format.
        if let locked = settings.resolution.lockedFrameRate, settings.frameRate != locked {
            DispatchQueue.main.async {
                self.settings.frameRate = locked
                self.notice = "\(self.settings.resolution.label) films at \(locked.label) only - switched to \(locked.label)."
            }
        }
        let fps = Double((settings.resolution.lockedFrameRate ?? settings.frameRate).value)

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
        // The zoom ceiling depends on the format just chosen above.
        refreshZoomLimits()
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

    /// Works out what the camera now in use is actually capable of, corrects
    /// the current selection if it is asking for something impossible (the
    /// iPhone 7 front camera has no 60 fps mode at all), and only then applies
    /// the format. Doing it in that order avoids a pointless "can't do that"
    /// notice on every flip to the selfie camera.
    private func refreshCapabilitiesThenApplyFormat() {
        guard let device = cameraInput?.device else { return }

        var rates = Set<FrameRate>()
        var widestPixels = 0
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            widestPixels = max(widestPixels, Int(dims.width) * Int(dims.height))
            for rate in FrameRate.allCases {
                let fps = Double(rate.value)
                if format.videoSupportedFrameRateRanges.contains(where: {
                    $0.minFrameRate <= fps && fps <= $0.maxFrameRate
                }) {
                    rates.insert(rate)
                }
            }
        }

        let supportedRates = FrameRate.allCases.filter { rates.contains($0) }
        let canDo1080 = widestPixels >= 1920 * 1080
        let canDo4K   = widestPixels >= 3840 * 2160
        let supportedResolutions = Resolution.allCases.filter {
            ($0 != .p1080 || canDo1080) && ($0 != .p2160 || canDo4K)
        }

        DispatchQueue.main.async {
            let previousResolution = self.settings.resolution
            self.availableFrameRates = supportedRates.isEmpty ? [.fps30] : supportedRates
            self.availableResolutions = supportedResolutions.isEmpty ? [.p720] : supportedResolutions

            if !self.availableFrameRates.contains(self.settings.frameRate) {
                let fallback: FrameRate = self.availableFrameRates.contains(.fps30)
                    ? .fps30 : (self.availableFrameRates.first ?? .fps30)
                self.settings.frameRate = fallback
                self.notice = "This camera only films at \(self.availableFrameRates.map { $0.label }.joined(separator: " or ")) - switched to \(fallback.label)."
            }
            if !self.availableResolutions.contains(self.settings.resolution) {
                let fallback: Resolution = self.availableResolutions.first ?? .p720
                self.settings.resolution = fallback
                self.notice = "This camera does not go up to \(previousResolution.label) - switched to \(fallback.label)."
            }

            self.sessionQueue.async { self.applyActiveFormat() }
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
            self.refreshCapabilitiesThenApplyFormat()
            self.refreshTorchState()
            // A point tapped on the old camera means nothing on the new one.
            self.resetFocusAndExposureToAuto()
            DispatchQueue.main.async { self.isFrontCamera = (next == .front) }
        }
    }

    /// On the back camera, prefers a "virtual device" spanning multiple
    /// physical lenses over a single fixed one - that is what lets one
    /// continuous pinch sweep from ultra-wide through wide to telephoto, the
    /// system switching lenses automatically at the right zoom factor, the
    /// same way the built-in Camera app behaves. Tried widest-range first,
    /// falling all the way back to a single lens on a phone (like the
    /// iPhone 7) that only has one to begin with. The front camera is always
    /// a single lens on every iPhone to date, so it skips straight to that.
    private static func camera(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if position == .back {
            let virtualTypes: [AVCaptureDevice.DeviceType] = [
                .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera
            ]
            for type in virtualTypes {
                if let device = AVCaptureDevice.default(type, for: .video, position: .back) {
                    return device
                }
            }
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
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

    // MARK: Zoom

    /// Everything the app shows and accepts is "display zoom", the scale
    /// people actually read: 1.0 is the normal wide lens, 0.5 is ultra-wide,
    /// 2.0 is telephoto. AVFoundation's own `videoZoomFactor` uses a
    /// different scale on a multi-lens virtual device - there, 1.0 means the
    /// *widest* constituent lens, so on a phone with an ultra-wide, raw 1.0
    /// is what a user calls 0.5x and the normal lens only starts at raw 2.0.
    /// These snapshots hold the raw values; `zoomBaseline` converts between
    /// the two scales.
    ///
    /// Session-queue-owned, because `setZoom` runs there and must not read
    /// the `@Published` copies directly - the same class of cross-thread read
    /// that caused the front-camera orientation bug earlier.
    private var rawMaxZoomSnapshot: CGFloat = 1
    private var rawMinZoomSnapshot: CGFloat = 1
    /// The raw `videoZoomFactor` that corresponds to display 1.0x.
    private var zoomBaselineSnapshot: CGFloat = 1

    /// Finds the raw zoom factor at which the ordinary wide-angle lens takes
    /// over - that is the point a user would call "1x".
    ///
    /// On a single-lens phone (iPhone 7) there are no constituents and this
    /// is simply 1.0. On an iPhone 11 (ultra-wide + wide) the wide lens is
    /// the second constituent, so the answer is the first switch-over value,
    /// normally 2.0. On a wide + telephoto phone the wide lens is already
    /// first, so it is 1.0 again.
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
        // Cap at 8x *as displayed*, since `videoMaxZoomFactor` on some
        // formats reports numbers in the thousands - digital crop far past
        // anything usable.
        let rawCeiling = min(device.activeFormat.videoMaxZoomFactor, baseline * 8)
        let rawFloor = device.minAvailableVideoZoomFactor

        zoomBaselineSnapshot = baseline
        rawMaxZoomSnapshot = rawCeiling
        rawMinZoomSnapshot = rawFloor

        // Start on the ordinary wide lens, which means raw `baseline` - not
        // raw 1.0. Setting raw 1.0 here is what previously made the app open
        // on the ultra-wide lens while the label claimed 1.0x.
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = baseline
            device.unlockForConfiguration()
        } catch {
            // Not fatal - the zoom just stays wherever it already was.
        }

        DispatchQueue.main.async {
            self.maxZoomFactor = rawCeiling / baseline
            self.minZoomFactor = rawFloor / baseline
            self.zoomFactor = 1
        }
    }

    /// `factor` is an absolute *display* zoom (1.0 = the normal lens), not a
    /// delta - the caller (a pinch gesture) tracks the running value itself
    /// and hands over where it wants to land.
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
            } catch {
                // Not fatal - the zoom just does not change this time.
            }
        }
    }

    // MARK: Focus and exposure

    /// `point` is in the device's own 0...1 coordinate space, already
    /// converted from the tap location by the preview layer - the recorder
    /// itself has no idea how the preview is laid out on screen.
    ///
    /// `.autoFocus`/`.autoExpose` are *one-shot* modes: they adjust once at
    /// the given point and then hold, which is what a tap should do. On its
    /// own that means the exposure never recovers afterwards - walk into a
    /// darker room and the picture stays stuck at the old brightness. So
    /// subject-area monitoring is switched on at the same time, and when the
    /// scene changes enough the device posts a notification and control goes
    /// back to continuous auto. That is the behaviour the built-in Camera app
    /// has.
    func focusAndExpose(at point: CGPoint) {
        applyFocusAndExposure(at: point,
                              focus: .autoFocus,
                              exposure: .autoExpose,
                              monitorSubjectArea: true)
    }

    /// Hands focus and exposure back to the camera, metering off the centre
    /// of the frame again.
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
            } catch {
                // Not fatal - focus/exposure just stay where they were.
            }
        }
    }

    /// Fired by the device once the scene has changed enough that the point
    /// tapped earlier is no longer meaningful.
    @objc private func subjectAreaDidChange() {
        resetFocusAndExposureToAuto()
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
        let transform = Self.transform(forInterface: currentInterfaceOrientation())

        stopRequested = false

        ioQueue.async {
            self.plan = newPlan
            self.clipTransform = transform
            self.recordStartPTS = .invalid
            self.lastElapsedPush = .invalid
            self.droppedFrameCount = 0
            self.wantsRecording = true
        }

        notice = nil
        elapsed = 0
        clipsThisSession = 0
        droppedFrames = 0
        audioLevel = 0
        isRecording = true
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stopRecording(notice message: String?) {
        guard isRecording else { return }

        // Takes effect immediately, ahead of anything already queued, so any
        // backlog of frames is skipped rather than encoded first.
        stopRequested = true

        // isSaving flips the record button into a spinner immediately, so the
        // tap is never left looking like it did nothing while the clip
        // finishes writing and (if Photos is the destination) importing.
        isRecording = false
        isSaving = true
        audioLevel = 0
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
            // Remembered before a single frame is written, so an interrupted
            // recording can be found again on the next launch.
            UserDefaults.standard.set(url.lastPathComponent, forKey: Self.inProgressKey)

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
            // The file is closed either way, so it is no longer "in progress"
            // and must not be picked up again by the recovery pass.
            UserDefaults.standard.removeObject(forKey: Self.inProgressKey)

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

    // MARK: Recovering an interrupted recording

    /// If the battery died (or iOS killed the app) while filming, the movie is
    /// still on disk and - because it was written in fragments - still
    /// playable up to the last few seconds before the cut. This picks it up on
    /// the next launch and files it where the rest of the recordings go.
    private func recoverInterruptedRecording() {
        let defaults = UserDefaults.standard
        guard let name = defaults.string(forKey: Self.inProgressKey) else { return }

        let url = Self.clipsDirectory.appendingPathComponent(name)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0

        // An empty or missing file is just leftover bookkeeping - clear it and
        // say nothing.
        guard size > 0 else {
            defaults.removeObject(forKey: Self.inProgressKey)
            try? FileManager.default.removeItem(at: url)
            return
        }

        defaults.removeObject(forKey: Self.inProgressKey)
        let destination = settings.saveLocation
        deliver(url, to: destination) { [weak self] in
            DispatchQueue.main.async {
                self?.notice = "Recovered the recording that was cut short."
                self?.refreshFreeSpace()
            }
        }
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
    /// Deliberately identical for both cameras: setting `videoOrientation` on
    /// the connection already normalises each sensor's own mounting, so a
    /// front-camera special case here would be double-correcting. An earlier
    /// version added 180 degrees for the front camera and, because it read a
    /// value published asynchronously to the main thread, produced clips that
    /// were upside down only some of the time.
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

        // Anything still queued when stop was tapped is dropped on the floor
        // rather than encoded, so the block that closes the file gets to run
        // straight away instead of waiting out the backlog.
        if stopRequested { return }

        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let isVideo = (output === videoOutput)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        guard wantsRecording else {
            if writer != nil { finishSegment() }
            return
        }

        // One file per recording, no matter how long it runs.
        if isVideo, writer == nil {
            startSegment(at: pts)
        }

        guard let w = writer, w.status == .writing else { return }
        guard segmentStart.isValid, CMTimeCompare(pts, segmentStart) >= 0 else { return }

        if isVideo {
            if videoIn?.isReadyForMoreMediaData == true {
                videoIn?.append(sampleBuffer)
                lastVideoPTS = pts
            } else {
                // The encoder could not take this frame in time. Counted so a
                // shortfall is visible live rather than only showing up as an
                // odd frame rate in the finished file.
                countDroppedFrame()
            }
            pushElapsed(pts)
        } else {
            if audioIn?.isReadyForMoreMediaData == true {
                audioIn?.append(sampleBuffer)
            }
        }
    }

    /// Fires when AVFoundation itself discards a frame before it ever reaches
    /// us - the other half of the same picture.
    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard output === videoOutput, wantsRecording else { return }
        countDroppedFrame()
    }

    /// Counted on the capture queue only. Publishing to the main thread on
    /// every drop would mean a burst of drops causes a burst of main-thread
    /// work - the measurement making the problem it measures worse - so the
    /// running total is pushed alongside the elapsed time instead, four times
    /// a second.
    private func countDroppedFrame() {
        droppedFrameCount += 1
    }

    /// Publishes the running time about four times a second instead of thirty.
    private func pushElapsed(_ pts: CMTime) {
        guard recordStartPTS.isValid else { return }
        if lastElapsedPush.isValid,
           CMTimeGetSeconds(CMTimeSubtract(pts, lastElapsedPush)) < 0.25 { return }
        lastElapsedPush = pts

        // A recording is no longer chopped into segments, so this is the only
        // place left that can notice the disk filling up mid-recording.
        if freeBytesSnapshot <= Self.reserveBytes {
            DispatchQueue.main.async {
                self.stopRecording(notice: "Stopped - storage is almost full.")
            }
            return
        }

        let seconds = CMTimeGetSeconds(CMTimeSubtract(pts, recordStartPTS))
        let drops = droppedFrameCount
        let level = currentAudioLevel()
        DispatchQueue.main.async {
            self.elapsed = seconds
            if self.droppedFrames != drops { self.droppedFrames = drops }
            self.audioLevel = level
        }
    }

    /// Reads the system's own per-channel power level rather than decoding
    /// PCM samples by hand - cheap enough to call from here, four times a
    /// second, without adding real load to the capture path.
    private func currentAudioLevel() -> Float {
        guard let channel = audioOutput.connection(with: .audio)?.audioChannels.first else { return 0 }
        // averagePowerLevel is roughly -160 (silence) to 0 (loudest) dBFS.
        // -50 dB is a quiet room; anything below that reads as silence here.
        let db = channel.averagePowerLevel
        let normalized = (db + 50) / 50
        return Float(max(0, min(1, normalized)))
    }
}
