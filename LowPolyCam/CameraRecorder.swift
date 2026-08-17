import AVFoundation
import UIKit
import Photos
import MediaPlayer
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
/// A recording is written as a *fragmented* movie: the playable index is flushed
/// to disk every few seconds, so if the battery dies or iOS kills the app mid-recording,
/// what was filmed up to that moment is still a valid video rather than a dead file.
final class CameraRecorder: NSObject, ObservableObject {

    // MARK: Tunables

    /// How often the movie index is flushed to disk.
    static let fragmentSeconds: Double = 4
    /// Recording stops when free space drops below this.
    static let reserveBytes: Int64 = 300 * 1024 * 1024
    /// Remembers the file being written for power-loss recovery.
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
    @Published private(set) var isFrontCamera = false
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
    @Published var notice: String?

    let session = AVCaptureSession()

    // MARK: Private

    private let settings: AppSettings
    private let sessionQueue = DispatchQueue(label: "lowpolycam.session")
    private let ioQueue = DispatchQueue(label: "lowpolycam.io", qos: .userInitiated)

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var cameraInput: AVCaptureDeviceInput?
    private var micInput: AVCaptureDeviceInput?
    private var position: AVCaptureDevice.Position = .back
    private var isConfigured = false
    private var spaceTimer: Timer?
    private var volumeObserver: VolumeButtonObserver?

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
    private var droppedFrameCount = 0

    private let stopLock = NSLock()
    private var _stopRequested = false
    private var stopRequested: Bool {
        get { stopLock.lock(); defer { stopLock.unlock() }; return _stopRequested }
        set { stopLock.lock(); _stopRequested = newValue; stopLock.unlock() }
    }

    // Zoom snapshots
    private var rawMaxZoomSnapshot: CGFloat = 1
    private var rawMinZoomSnapshot: CGFloat = 1
    private var zoomBaselineSnapshot: CGFloat = 1

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

        NotificationCenter.default.addObserver(
            self, selector: #selector(subjectAreaDidChange),
            name: .AVCaptureDeviceSubjectAreaDidChange, object: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    deinit {
        spaceTimer?.invalidate()
        volumeObserver?.stop()
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
            DispatchQueue.main.async { self.audioLevel = 0 }
        }
    }

    // MARK: Lifecycle

    func start() {
        refreshFreeSpace()
        recoverInterruptedRecording()
        loadLastSavedClip()
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
                DispatchQueue.main.async {
                    self.isSessionRunning = self.session.isRunning
                    // Only start volume shutter observer after session is actively running
                    if self.volumeObserver == nil {
                        let obs = VolumeButtonObserver()
                        obs.onVolumeTrigger = { [weak self] in
                            DispatchQueue.main.async { self?.toggleRecording() }
                        }
                        obs.start()
                        self.volumeObserver = obs
                    }
                }
            }
        }
    }

    func stop() {
        spaceTimer?.invalidate()
        spaceTimer = nil
        volumeObserver?.stop()
        volumeObserver = nil

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
        session.sessionPreset = .inputPriority

        if let device = Self.camera(at: position),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            cameraInput = input
        }

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
        resetFocusAndExposureToAuto()
        syncMicInput()
    }

    private func configureVideoConnection() {
        guard let c = videoOutput.connection(with: .video) else { return }
        if c.isVideoOrientationSupported { c.videoOrientation = .landscapeRight }
        if c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = (position == .front)
        }
        applyStabilization(to: c)
    }

    private func applyStabilization(to connection: AVCaptureConnection? = nil) {
        guard let c = connection ?? videoOutput.connection(with: .video) else { return }
        let supported = c.isVideoStabilizationSupported
        if supported {
            c.preferredVideoStabilizationMode = settings.stabilization ? .auto : .off
        }
        DispatchQueue.main.async { self.stabilizationSupported = supported }
    }

    func updateStabilization() {
        sessionQueue.async { self.applyStabilization() }
    }

    private func applyActiveFormat() {
        guard let device = cameraInput?.device else { return }
        // Safely check if slow motion is both requested and supported on this lens (prevents black screen on selfie flip)
        let isSlow = settings.cameraMode == .slowMo && isSlowMoSupportedOnCurrentLens
        let dims: (w: Int, h: Int)
        let fps: Double

        if isSlow {
            if !availableSlowMoRates.contains(settings.slowMoFrameRate) {
                let fallback = availableSlowMoRates.first ?? .fps120
                DispatchQueue.main.async {
                    self.settings.slowMoFrameRate = fallback
                }
            }
            fps = Double(settings.slowMoFrameRate.value)
            dims = settings.slowMoResolution.captureDimensions
        } else {
            dims = settings.resolution.captureDimensions
            if let locked = settings.resolution.lockedFrameRate, settings.frameRate != locked {
                DispatchQueue.main.async {
                    self.settings.frameRate = locked
                    self.notice = "\(self.settings.resolution.label) films at \(locked.label) only - switched to \(locked.label)."
                }
            }
            fps = Double((settings.resolution.lockedFrameRate ?? settings.frameRate).value)
        }

        guard let format = Self.bestFormat(for: device, width: dims.w, height: dims.h, fps: fps) else {
            if isSlow, let fallbackFormat = Self.bestSlowMoFormat(for: device, fps: fps) {
                do {
                    try device.lockForConfiguration()
                    device.activeFormat = fallbackFormat
                    let d = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
                    device.activeVideoMaxFrameDuration = CMTime.invalid
                    device.activeVideoMinFrameDuration = d
                    device.activeVideoMaxFrameDuration = d
                    device.unlockForConfiguration()
                    DispatchQueue.main.async {
                        let dDims = CMVideoFormatDescriptionGetDimensions(fallbackFormat.formatDescription)
                        let closestRes: Resolution = dDims.height >= 1080 ? .p1080 : .p720
                        self.settings.slowMoResolution = closestRes
                        self.notice = "\(self.settings.slowMoFrameRate.label) runs at \(closestRes.label) on this iPhone."
                    }
                } catch { }
                refreshZoomLimits()
                return
            }

            DispatchQueue.main.async {
                self.notice = "This camera can't do \(dims.w)x\(dims.h) at \(Int(fps)) fps here - using its closest mode instead."
            }
            return
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let d = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
            device.activeVideoMaxFrameDuration = CMTime.invalid
            device.activeVideoMinFrameDuration = d
            device.activeVideoMaxFrameDuration = d
            device.unlockForConfiguration()
        } catch {
            DispatchQueue.main.async { self.notice = "Could not lock this camera's frame rate." }
        }
        refreshZoomLimits()
    }

    private static func bestSlowMoFormat(for device: AVCaptureDevice, fps: Double) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var maxArea = 0
        for format in device.formats {
            let supportsFPS = format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= fps && fps <= $0.maxFrameRate
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
            let areaDelta = Int(dims.width) * Int(dims.height) - width * height
            let score = areaDelta + (format.isVideoBinned ? 1_000_000 : 0)
            if score < bestScore {
                bestScore = score
                best = format
            }
        }
        return best
    }

    func updateCaptureFormat() {
        sessionQueue.async { self.applyActiveFormat() }
    }

    private func refreshCapabilitiesThenApplyFormat() {
        guard let device = cameraInput?.device else { return }

        var rates = Set<FrameRate>()
        var widestPixels = 0
        var slowRates = Set<SlowMoFrameRate>()
        var slowResolutions = Set<Resolution>()

        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let h = Int(dims.height)
            widestPixels = max(widestPixels, Int(dims.width) * Int(dims.height))
            for rate in FrameRate.allCases {
                let fps = Double(rate.value)
                if format.videoSupportedFrameRateRanges.contains(where: {
                    $0.minFrameRate <= fps && fps <= $0.maxFrameRate
                }) {
                    rates.insert(rate)
                }
            }
            for range in format.videoSupportedFrameRateRanges {
                if range.maxFrameRate >= 120 {
                    slowRates.insert(.fps120)
                    if h >= 1080 { slowResolutions.insert(.p1080) }
                    if h >= 720 { slowResolutions.insert(.p720) }
                    if h >= 480 { slowResolutions.insert(.p480) }
                    slowResolutions.insert(.p320)
                    slowResolutions.insert(.p144)
                }
                if range.maxFrameRate >= 240 {
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
        let canDo4K   = widestPixels >= 3840 * 2160
        let supportedResolutions = Resolution.allCases.filter {
            ($0 != .p1080 || canDo1080) && ($0 != .p2160 || canDo4K)
        }
        let supportedSlowRates = SlowMoFrameRate.allCases.filter { slowRates.contains($0) }
        let supportedSlowRes = Resolution.allCases.filter { slowResolutions.contains($0) }

        DispatchQueue.main.async {
            let previousResolution = self.settings.resolution
            self.availableFrameRates = supportedRates.isEmpty ? [.fps30] : supportedRates
            self.availableResolutions = supportedResolutions.isEmpty ? [.p720] : supportedResolutions
            self.availableSlowMoRates = supportedSlowRates
            self.availableSlowMoResolutions = supportedSlowRes.isEmpty ? [.p720] : supportedSlowRes
            self.isSlowMoSupportedOnCurrentLens = !supportedSlowRates.isEmpty

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

            if self.settings.cameraMode == .slowMo {
                if !self.isSlowMoSupportedOnCurrentLens {
                    self.notice = "Slow motion is not supported on the selfie camera. Switched to Video."
                    self.settings.cameraMode = .video
                } else if !self.availableSlowMoRates.contains(self.settings.slowMoFrameRate) {
                    self.settings.slowMoFrameRate = self.availableSlowMoRates.first ?? .fps120
                }
            }

            self.sessionQueue.async { self.applyActiveFormat() }
        }
    }

    func syncMicInput() {
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
            self.resetFocusAndExposureToAuto()
            DispatchQueue.main.async { self.isFrontCamera = (next == .front) }
        }
    }

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
                if on {
                    let level: Float = self.settings.lowTorch ? 0.15 : 1.0
                    let targetLevel = min(level, AVCaptureDevice.maxAvailableTorchLevel)
                    try device.setTorchModeOn(level: targetLevel)
                } else {
                    device.torchMode = .off
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.torchOn = on }
            } catch {
                DispatchQueue.main.async { self.notice = "The torch is busy right now." }
            }
        }
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

        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = baseline
            device.unlockForConfiguration()
        } catch { }

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
                              focus: .autoFocus,
                              exposure: .autoExpose,
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
        let transform = Self.transform(forInterface: currentInterfaceOrientation(),
                                       width: newPlan.width,
                                       height: newPlan.height)

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

        stopRequested = true
        isRecording = false
        isSaving = true
        audioLevel = 0
        UIApplication.shared.isIdleTimerDisabled = false
        notice = message
        refreshFreeSpace()

        var task: UIBackgroundTaskIdentifier = .invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "finishClip") {
            if task != .invalid {
                UIApplication.shared.endBackgroundTask(task)
                task = .invalid
            }
        }

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
        guard isRecording else { return }
        stopRecording(notice: "Recording stopped - the app left the screen.")
    }

    // MARK: Segments & Rolling Split

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
            if plan.hasAudio && !plan.isSlowMo, let aSettings = audioSettings(for: plan, writer: w) {
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
        let start = segmentStart
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
        if end.isValid, start.isValid, CMTimeCompare(end, start) > 0 {
            w.endSession(atSourceTime: end)
        }
        w.finishWriting {
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

            self.generateThumbnail(for: url)
            self.deliver(url, to: destination) {
                DispatchQueue.main.async { self.refreshFreeSpace() }
                completion?()
            }
        }
    }

    private func rotateSegment(at pts: CMTime) {
        guard let oldWriter = writer, let oldVideoIn = videoIn else { return }
        let oldAudioIn = audioIn
        let oldEnd = lastVideoPTS
        let oldStart = segmentStart
        let oldUrl = oldWriter.outputURL
        let destination = plan?.saveLocation ?? .files

        writer = nil; videoIn = nil; audioIn = nil
        segmentStart = .invalid

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

        // Start next file segment seamlessly on the current sample frame
        startSegment(at: pts)
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
            try? FileManager.default.removeItem(at: url)
            return
        }

        defaults.removeObject(forKey: Self.inProgressKey)
        let destination = settings.saveLocation
        generateThumbnail(for: url)
        deliver(url, to: destination) { [weak self] in
            DispatchQueue.main.async {
                self?.notice = "Recovered the recording that was cut short."
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
            options.shouldMoveFile = false
            request.addResource(with: .video, fileURL: url, options: options)
        } completionHandler: { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if success {
                    self.notice = "Clip saved to Photos."
                    self.cleanupOlderClipsExcept(url)
                } else {
                    let reason = error?.localizedDescription ?? "unknown error"
                    self.notice = "Photos refused the clip (\(reason)) - it is still in Files."
                }
            }
            done()
        }
    }

    private func cleanupOlderClipsExcept(_ currentURL: URL?) {
        guard settings.saveLocation == .photos else { return }
        DispatchQueue.global(qos: .background).async {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: Self.clipsDirectory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else { return }
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
        return clipsDirectory.appendingPathComponent("LowPolyCam_\(f.string(from: Date())).mov")
    }

    // MARK: Orientation

    private func currentInterfaceOrientation() -> UIInterfaceOrientation {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.interfaceOrientation ?? .portrait
    }

    private static func transform(forInterface o: UIInterfaceOrientation, width: Int, height: Int) -> CGAffineTransform {
        let w = CGFloat(width)
        let h = CGFloat(height)
        switch o {
        case .portrait:
            return CGAffineTransform(translationX: h, y: 0).rotated(by: .pi / 2)
        case .landscapeLeft:
            return CGAffineTransform(translationX: w, y: h).rotated(by: .pi)
        case .portraitUpsideDown:
            return CGAffineTransform(translationX: 0, y: w).rotated(by: -.pi / 2)
        case .landscapeRight:
            return .identity
        default:
            return CGAffineTransform(translationX: h, y: 0).rotated(by: .pi / 2)
        }
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

        if stopRequested { return }

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
            } else if let splitLimit = plan?.splitInterval.seconds, segmentStart.isValid {
                let duration = CMTimeGetSeconds(CMTimeSubtract(pts, segmentStart))
                if duration >= splitLimit {
                    rotateSegment(at: pts)
                }
            }
        }

        guard let w = writer, w.status == .writing else { return }
        guard segmentStart.isValid, CMTimeCompare(pts, segmentStart) >= 0 else { return }

        if isVideo {
            if videoIn?.isReadyForMoreMediaData == true {
                var bufferToWrite = sampleBuffer
                if let p = plan, p.isSlowMo, segmentStart.isValid {
                    let delta = CMTimeSubtract(pts, segmentStart)
                    let scaledDelta = CMTimeMultiplyByFloat64(delta, multiplier: p.slowMoMultiplier)
                    let scaledPTS = CMTimeAdd(segmentStart, scaledDelta)

                    // FIXED: Safe, modern Swift API for CMSampleBuffer copying!
                    let timingInfo = CMSampleTimingInfo(
                        duration: CMTime(value: 1, timescale: 30),
                        presentationTimeStamp: scaledPTS,
                        decodeTimeStamp: .invalid
                    )

                    if let retimed = try? CMSampleBuffer(copying: sampleBuffer, withNewTiming: [timingInfo]) {
                        bufferToWrite = retimed
                        lastVideoPTS = scaledPTS
                    } else {
                        lastVideoPTS = pts
                    }
                } else {
                    lastVideoPTS = pts
                }
                videoIn?.append(bufferToWrite)
            } else {
                countDroppedFrame()
            }
            pushElapsed(pts)
        } else {
            if plan?.isSlowMo != true, audioIn?.isReadyForMoreMediaData == true {
                audioIn?.append(sampleBuffer)
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard output === videoOutput, wantsRecording else { return }
        countDroppedFrame()
    }

    private func countDroppedFrame() {
        droppedFrameCount += 1
    }

    private func pushElapsed(_ pts: CMTime) {
        guard recordStartPTS.isValid else { return }
        if lastElapsedPush.isValid,
           CMTimeGetSeconds(CMTimeSubtract(pts, lastElapsedPush)) < 0.25 { return }
        lastElapsedPush = pts

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
    var onVolumeTrigger: (() -> Void)?

    func start() {
        guard !isObserving else { return }
        do {
            try audioSession.setActive(true, options: [])
        } catch { }

        // Invisible off-screen MPVolumeView to suppress the stock volume HUD
        if volumeView == nil {
            let v = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
            v.clipsToBounds = true
            v.alpha = 0.01
            if let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first?.windows.first {
                window.addSubview(v)
                volumeView = v
            }
        }

        // Store baseline volume and ignore startup KVO events for 2.5 seconds
        lastVolume = audioSession.outputVolume
        ignoreUntil = Date().addingTimeInterval(2.5)
        audioSession.addObserver(self, forKeyPath: "outputVolume", options: [.new, .old], context: nil)
        isObserving = true
    }

    func stop() {
        guard isObserving else { return }
        audioSession.removeObserver(self, forKeyPath: "outputVolume")
        isObserving = false
        volumeView?.removeFromSuperview()
        volumeView = nil
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "outputVolume" {
            let currentVol = audioSession.outputVolume
            if Date() < ignoreUntil {
                lastVolume = currentVol
                return
            }
            if let prev = lastVolume {
                // Ensure a physical button press delta (standard iOS volume step is ~0.0625)
                if abs(currentVol - prev) > 0.01 {
                    lastVolume = currentVol
                    onVolumeTrigger?()
                }
            } else {
                lastVolume = currentVol
            }
        }
    }
}
