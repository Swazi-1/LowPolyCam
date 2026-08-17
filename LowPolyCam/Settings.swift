import Foundation
import AVFoundation
import Combine

// MARK: - Resolution

enum Resolution: String, CaseIterable, Identifiable {
    case p2160, p1080, p720, p480, p320, p144

    var id: String { rawValue }

    var label: String {
        switch self {
        case .p2160: return "4K"
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p480: return "480p"
        case .p320: return "320p"
        case .p144: return "144p"
        }
    }

    /// Always 16:9 (or closest mod-16 aligned) so nothing gets cropped when the capture is scaled down.
    var pixels: (w: Int, h: Int) {
        switch self {
        case .p2160: return (3840, 2160)
        case .p1080: return (1920, 1080)
        case .p720: return (1280, 720)
        case .p480: return (848, 480)
        case .p320: return (568, 320)
        case .p144: return (256, 144)
        }
    }

    var captureDimensions: (w: Int, h: Int) {
        switch self {
        case .p2160: return (3840, 2160)
        case .p1080: return (1920, 1080)
        default: return (1280, 720)
        }
    }

    var lockedFrameRate: FrameRate? {
        self == .p2160 ? .fps30 : nil
    }

    var detail: String {
        let p = pixels
        return "\(p.w) x \(p.h)"
    }
}

// MARK: - Camera Mode

enum CameraMode: String, CaseIterable, Identifiable {
    case video = "VIDEO"
    case slowMo = "SLO-MO"

    var id: String { rawValue }
    var label: String { rawValue }
}

// MARK: - Frame rate

enum FrameRate: Int, CaseIterable, Identifiable {
    case fps24 = 24, fps30 = 30, fps60 = 60

    var id: Int { rawValue }
    var value: Int { rawValue }

    var label: String { "\(rawValue) fps" }

    var detail: String {
        switch self {
        case .fps24: return "Film-like motion"
        case .fps30: return "Standard, smallest files"
        case .fps60: return "Smoothest motion, largest files"
        }
    }
}

// MARK: - Slow-Mo Frame Rate

enum SlowMoFrameRate: Int, CaseIterable, Identifiable {
    case fps120 = 120
    case fps240 = 240

    var id: Int { rawValue }
    var value: Int { rawValue }

    var label: String { "\(rawValue) fps" }

    var multiplierLabel: String {
        self == .fps120 ? "4x" : "8x"
    }

    var detail: String {
        switch self {
        case .fps120: return "4x slow motion (smooth, standard high speed)"
        case .fps240: return "8x slow motion (ultra slow speed)"
        }
    }

    var speedFactor: Double {
        Double(rawValue) / 30.0
    }
}

// MARK: - Quality

enum Quality: String, CaseIterable, Identifiable {
    case high, medium, low, ultraLow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        case .ultraLow: return "Ultra low"
        }
    }

    var detail: String {
        switch self {
        case .high: return "Looks good, uses the most space"
        case .medium: return "Everyday quality"
        case .low: return "Soft, but easy to watch"
        case .ultraLow: return "Rough. For filming all day"
        }
    }
}

// MARK: - Where clips end up

enum SaveLocation: String, CaseIterable, Identifiable {
    case photos, files

    var id: String { rawValue }

    var label: String {
        switch self {
        case .photos: return "Photos"
        case .files: return "Files"
        }
    }

    var detail: String {
        switch self {
        case .photos: return "Shows up in the camera roll"
        case .files: return "On My iPhone / LowPolyCam"
        }
    }
}

// MARK: - File Splitting

enum SplitInterval: String, CaseIterable, Identifiable {
    case off, oneHour, fourHours

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off (one long file)"
        case .oneHour: return "Every 1 hour"
        case .fourHours: return "Every 4 hours"
        }
    }

    var detail: String {
        switch self {
        case .off: return "Single continuous recording"
        case .oneHour: return "Splits into ~1-hour files"
        case .fourHours: return "Splits into ~4-hour files"
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .off: return nil
        case .oneHour: return 3600
        case .fourHours: return 14400
        }
    }
}

// MARK: - Countdown Timer

enum CountdownTimer: Int, CaseIterable, Identifiable {
    case off = 0
    case three = 3
    case ten = 10

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .three: return "3s"
        case .ten: return "10s"
        }
    }
}

// MARK: - White Balance Presets

enum WhiteBalancePreset: String, CaseIterable, Identifiable {
    case auto, daylight, indoor, fluorescent, cloudy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .daylight: return "Sunny"
        case .indoor: return "Warm"
        case .fluorescent: return "Cool"
        case .cloudy: return "Cloudy"
        }
    }

    var icon: String {
        switch self {
        case .auto: return "sparkles"
        case .daylight: return "sun.max.fill"
        case .indoor: return "lightbulb.fill"
        case .fluorescent: return "building.2.fill"
        case .cloudy: return "cloud.fill"
        }
    }

    var kelvin: (temp: Float, tint: Float)? {
        switch self {
        case .auto: return nil
        case .daylight: return (5500, 0)
        case .indoor: return (3000, 0)
        case .fluorescent: return (4000, 10)
        case .cloudy: return (6500, 0)
        }
    }
}

// MARK: - Stored settings

final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    private let store = UserDefaults.standard

    @Published var cameraMode: CameraMode {
        didSet { store.set(cameraMode.rawValue, forKey: "cameraMode") }
    }
    @Published var slowMoFrameRate: SlowMoFrameRate {
        didSet { store.set(slowMoFrameRate.rawValue, forKey: "slowMoFrameRate") }
    }
    @Published var slowMoResolution: Resolution {
        didSet { store.set(slowMoResolution.rawValue, forKey: "slowMoResolution") }
    }
    @Published var resolution: Resolution {
        didSet { store.set(resolution.rawValue, forKey: "resolution") }
    }
    @Published var quality: Quality {
        didSet { store.set(quality.rawValue, forKey: "quality") }
    }
    @Published var frameRate: FrameRate {
        didSet { store.set(frameRate.rawValue, forKey: "frameRate") }
    }
    @Published var saveLocation: SaveLocation {
        didSet { store.set(saveLocation.rawValue, forKey: "saveLocation") }
    }
    @Published var splitInterval: SplitInterval {
        didSet { store.set(splitInterval.rawValue, forKey: "splitInterval") }
    }
    @Published var countdownTimer: CountdownTimer {
        didSet { store.set(countdownTimer.rawValue, forKey: "countdownTimer") }
    }
    @Published var showLevelGauge: Bool {
        didSet { store.set(showLevelGauge, forKey: "showLevelGauge") }
    }
    @Published var exposureBias: Float {
        didSet { store.set(exposureBias, forKey: "exposureBias") }
    }
    @Published var whiteBalance: WhiteBalancePreset {
        didSet { store.set(whiteBalance.rawValue, forKey: "whiteBalance") }
    }
    @Published var torchBrightness: Float {
        didSet { store.set(torchBrightness, forKey: "torchBrightness") }
    }
    @Published var lowTorch: Bool {
        didSet { store.set(lowTorch, forKey: "lowTorch") }
    }
    @Published var recordAudio: Bool {
        didSet { store.set(recordAudio, forKey: "recordAudio") }
    }
    @Published var stabilization: Bool {
        didSet { store.set(stabilization, forKey: "stabilization") }
    }
    @Published var useHEVC: Bool {
        didSet { store.set(useHEVC, forKey: "useHEVC") }
    }
    @Published var showGrid: Bool {
        didSet { store.set(showGrid, forKey: "showGrid") }
    }

    private init() {
        cameraMode       = CameraMode(rawValue: store.string(forKey: "cameraMode") ?? "") ?? .video
        slowMoFrameRate  = SlowMoFrameRate(rawValue: store.integer(forKey: "slowMoFrameRate")) ?? .fps120
        slowMoResolution = Resolution(rawValue: store.string(forKey: "slowMoResolution") ?? "") ?? .p1080
        resolution       = Resolution(rawValue: store.string(forKey: "resolution") ?? "") ?? .p720
        quality          = Quality(rawValue: store.string(forKey: "quality") ?? "") ?? .medium
        frameRate        = FrameRate(rawValue: store.integer(forKey: "frameRate")) ?? .fps30
        saveLocation     = SaveLocation(rawValue: store.string(forKey: "saveLocation") ?? "") ?? .photos
        splitInterval    = SplitInterval(rawValue: store.string(forKey: "splitInterval") ?? "") ?? .off
        countdownTimer   = CountdownTimer(rawValue: store.integer(forKey: "countdownTimer")) ?? .off
        showLevelGauge   = store.object(forKey: "showLevelGauge") as? Bool ?? false
        exposureBias     = store.object(forKey: "exposureBias") as? Float ?? 0.0
        whiteBalance     = WhiteBalancePreset(rawValue: store.string(forKey: "whiteBalance") ?? "") ?? .auto
        torchBrightness  = store.object(forKey: "torchBrightness") as? Float ?? 0.15
        lowTorch         = store.object(forKey: "lowTorch") as? Bool ?? true
        recordAudio      = store.object(forKey: "recordAudio") as? Bool ?? true
        stabilization    = store.object(forKey: "stabilization") as? Bool ?? true
        useHEVC          = store.object(forKey: "useHEVC") as? Bool ?? true
        showGrid         = store.object(forKey: "showGrid") as? Bool ?? false
    }
}

// MARK: - Encode plan

struct EncodePlan {
    var cameraMode: CameraMode
    var width: Int
    var height: Int
    var videoBitrate: Int
    var audioBitrate: Int
    var keyFrameInterval: Int
    var frameRate: Int
    var codec: AVVideoCodecType
    var hasAudio: Bool
    var saveLocation: SaveLocation
    var splitInterval: SplitInterval

    var isSlowMo: Bool { cameraMode == .slowMo }

    var totalBitrate: Int { videoBitrate + audioBitrate }

    var megabytesPerHour: Double {
        Double(totalBitrate) * 3600.0 / 8.0 / 1_000_000.0
    }

    var sizeLabel: String {
        if isSlowMo {
            return "\(width) x \(height) · \(frameRate) fps (Slow-Mo)"
        }
        return "\(width) x \(height) · \(frameRate) fps"
    }
}

enum Encoder {

    private static let videoKbps: [Resolution: [Quality: Int]] = [
        .p2160: [.high: 24000, .medium: 12000, .low: 6000, .ultraLow: 1800],
        .p1080: [.high: 8000,  .medium: 4000,  .low: 2000, .ultraLow: 400],
        .p720:  [.high: 4000,  .medium: 2000,  .low: 1000, .ultraLow: 250],
        .p480:  [.high: 2000,  .medium: 1000,  .low: 500,  .ultraLow: 130],
        .p320:  [.high: 1000,  .medium: 500,   .low: 250,  .ultraLow: 80],
        .p144:  [.high: 400,   .medium: 200,   .low: 100,  .ultraLow: 40]
    ]

    private static let audioKbps: [Quality: Int] = [
        .high: 128, .medium: 64, .low: 32, .ultraLow: 24
    ]

    private static let keyFrameSeconds: [Quality: Int] = [
        .high: 2, .medium: 4, .low: 6, .ultraLow: 10
    ]

    private static let h264Multiplier = 1.6

    private static let fpsMultiplier: [FrameRate: Double] = [
        .fps24: 0.85, .fps30: 1.0, .fps60: 1.6
    ]

    static func plan(for settings: AppSettings) -> EncodePlan {
        let isSlow = settings.cameraMode == .slowMo
        let res = isSlow ? settings.slowMoResolution : settings.resolution
        let fps = isSlow ? settings.slowMoFrameRate.value : settings.frameRate.value
        let px = res.pixels

        let baseKbps = videoKbps[res]?[settings.quality] ?? 600
        let codecMultiplier = settings.useHEVC ? 1.0 : h264Multiplier
        let fpsFactor: Double
        if isSlow {
            fpsFactor = fps >= 240 ? 4.2 : 2.5
        } else {
            fpsFactor = fpsMultiplier[settings.frameRate] ?? 1.0
        }

        let kbps = Double(baseKbps) * codecMultiplier * fpsFactor
        let gopSeconds = keyFrameSeconds[settings.quality] ?? 4
        let aKbps = settings.recordAudio ? (audioKbps[settings.quality] ?? 32) : 0

        return EncodePlan(
            cameraMode: settings.cameraMode,
            width: px.w,
            height: px.h,
            videoBitrate: Int(kbps * 1000.0),
            audioBitrate: aKbps * 1000,
            keyFrameInterval: gopSeconds * fps,
            frameRate: fps,
            codec: settings.useHEVC ? .hevc : .h264,
            hasAudio: settings.recordAudio,
            saveLocation: settings.saveLocation,
            splitInterval: settings.splitInterval
        )
    }

    static func videoSettings(for plan: EncodePlan, writer: AVAssetWriter) -> [String: Any] {

        func build(_ codec: AVVideoCodecType) -> [String: Any] {
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: plan.videoBitrate,
                AVVideoMaxKeyFrameIntervalKey: plan.keyFrameInterval,
                AVVideoExpectedSourceFrameRateKey: plan.frameRate,
                AVVideoAllowFrameReorderingKey: true
            ]
            if codec == .h264 {
                compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            return [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: plan.width,
                AVVideoHeightKey: plan.height,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
                AVVideoCompressionPropertiesKey: compression
            ]
        }

        let preferred = build(plan.codec)
        if writer.canApply(outputSettings: preferred, forMediaType: .video) {
            return preferred
        }
        let fallback = build(.h264)
        if writer.canApply(outputSettings: fallback, forMediaType: .video) {
            return fallback
        }
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: plan.width,
            AVVideoHeightKey: plan.height
        ]
    }
}

// MARK: - Formatting helpers

enum Fmt {

    static func size(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useGB, .useMB]
        return f.string(fromByteCount: max(0, bytes))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    static func hours(_ h: Double) -> String {
        if h.isInfinite || h.isNaN { return "-" }
        if h < 1 { return "\(Int(h * 60)) min" }
        if h < 48 { return "\(Int(h)) h" }
        return "\(Int(h / 24)) d \(Int(h.truncatingRemainder(dividingBy: 24))) h"
    }
}
```

---

### `CameraPreview.swift`

```swift
import SwiftUI
import AVFoundation

final class PreviewView: UIView {

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    var onTap: ((CGPoint, CGPoint) -> Void)?
    var onDoubleTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2

        singleTap.require(toFail: doubleTap)

        addGestureRecognizer(singleTap)
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        let viewPoint = gesture.location(in: self)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint)
        onTap?(devicePoint, viewPoint)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        onDoubleTap?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let c = previewLayer.connection, c.isVideoOrientationSupported else { return }
        let o = window?.windowScene?.interfaceOrientation ?? .portrait
        if let v = AVCaptureVideoOrientation(rawValue: o.rawValue) {
            c.videoOrientation = v
        }
    }
}

struct CameraPreview: UIViewRepresentable {

    let session: AVCaptureSession
    var onTap: ((CGPoint, CGPoint) -> Void)? = nil
    var onDoubleTap: (() -> Void)? = nil

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onTap = onTap
        view.onDoubleTap = onDoubleTap
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        uiView.onTap = onTap
        uiView.onDoubleTap = onDoubleTap
        uiView.setNeedsLayout()
    }
}
```

---

### `CameraRecorder.swift`

```swift
import AVFoundation
import UIKit
import Photos
import MediaPlayer
import CoreMotion
import Combine

final class CameraRecorder: NSObject, ObservableObject {

    // MARK: Tunables

    static let fragmentSeconds: Double = 4
    static let reserveBytes: Int64 = 300 * 1024 * 1024
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
    @Published private(set) var isLevel: Bool = false
    @Published private(set) var rollAngle: Double = 0
    @Published var notice: String?

    let session = AVCaptureSession()

    // MARK: Private

    private let settings: AppSettings
    private let sessionQueue = DispatchQueue(label: "lowpolycam.session")
    private let ioQueue = DispatchQueue(label: "lowpolycam.io", qos: .userInitiated)
    private let motionManager = CMMotionManager()

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var cameraInput: AVCaptureDeviceInput?
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
            DispatchQueue.main.async { self.audioLevel = 0 }
        }
    }

    // MARK: Motion / Level Meter

    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            guard let self = self, let motion = motion else { return }
            let roll = motion.attitude.roll * (180.0 / .pi)
            self.rollAngle = roll
            let normalizedRoll = abs(roll.truncatingRemainder(dividingBy: 90))
            let level = normalizedRoll < 1.0 || normalizedRoll > 89.0
            if self.isLevel != level {
                self.isLevel = level
            }
        }
    }

    private func stopMotionUpdates() {
        motionManager.stopDeviceMotionUpdates()
    }

    // MARK: Lifecycle

    func start() {
        refreshFreeSpace()
        recoverInterruptedRecording()
        loadLastSavedClip()
        startMotionUpdates()

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
        stopMotionUpdates()

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
                    
                    if device.isSmoothAutoFocusSupported {
                        device.isSmoothAutoFocusEnabled = true
                    }
                    
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
            
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = true
            }
            
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
            guard let device = self.cameraInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if let values = preset.kelvin {
                    let tempAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: values.temp, tint: values.tint)
                    var gains = device.deviceWhiteBalanceGains(for: tempAndTint)
                    let maxGain = device.maxWhiteBalanceGain
                    gains.redGain = max(1.0, min(gains.redGain, maxGain))
                    gains.greenGain = max(1.0, min(gains.greenGain, maxGain))
                    gains.blueGain = max(1.0, min(gains.blueGain, maxGain))
                    if device.isWhiteBalanceModeSupported(.locked) {
                        device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                    }
                } else {
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        device.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.settings.whiteBalance = preset }
            } catch { }
        }
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

    func setTorch(on: Bool) {
        sessionQueue.async {
            guard let device = self.cameraInput?.device, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                if on {
                    let level: Float = self.settings.torchBrightness > 0 ? self.settings.torchBrightness : 0.15
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
                    DispatchQueue.main.async {
                        self.torchOn = false
                        self.settings.torchBrightness = 0
                    }
                }
                device.unlockForConfiguration()
            } catch { }
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
                videoIn?.append(sampleBuffer)
                lastVideoPTS = pts
            } else {
                countDroppedFrame()
            }
            pushElapsed(pts)
        } else {
            if audioIn?.isReadyForMoreMediaData == true {
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
```

---

### `CameraScreen.swift`

```swift
import SwiftUI
import UIKit
import AVKit

struct CameraScreen: View {

    @ObservedObject var settings: AppSettings
    @ObservedObject var recorder: CameraRecorder

    @State private var showSettings = false
    @State private var showPlayer = false
    @State private var showProMenu = false
    @State private var dimmed = false
    @State private var savedBrightness: CGFloat = UIScreen.main.brightness
    @State private var blink = false

    // Countdown State
    @State private var countdownRemaining = 0
    @State private var countdownTimer: Timer?

    // Zoom
    @State private var zoomGestureBase: CGFloat = 1
    @State private var isPinching = false
    @State private var showZoomLabel = false
    @State private var zoomLabelHideToken = 0

    // Tap to focus
    @State private var focusPoint: CGPoint?
    @State private var focusHideToken = 0

    @State private var startHaptic = UIImpactFeedbackGenerator(style: .medium)
    @State private var stopHaptic = UIImpactFeedbackGenerator(style: .light)
    @State private var levelHaptic = UISelectionFeedbackGenerator()

    private var plan: EncodePlan { Encoder.plan(for: settings) }

    var body: some View {
        ZStack {
            // Full-bleed preview layer
            ZStack {
                Color.black

                CameraPreview(session: recorder.session, onTap: { devicePoint, viewPoint in
                    if showProMenu {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showProMenu = false }
                    }
                    recorder.focusAndExpose(at: devicePoint)
                    showFocusReticle(at: viewPoint)
                }, onDoubleTap: {
                    recorder.flipCamera()
                })
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            if !isPinching {
                                isPinching = true
                                zoomGestureBase = recorder.zoomFactor
                            }
                            showZoomLabel = true
                            recorder.setZoom(factor: zoomGestureBase * value)
                        }
                        .onEnded { _ in
                            isPinching = false
                            scheduleHideZoomLabel()
                        }
                )

                if let focusPoint {
                    focusReticle.position(focusPoint)
                }

                if settings.showGrid { gridOverlay }

                if settings.showLevelGauge { levelGaugeOverlay }

                if showZoomLabel { zoomLabel }

                if countdownRemaining > 0 { countdownOverlay }

                if dimmed { dimOverlay }
            }
            .ignoresSafeArea()

            // Safe area HUD
            if recorder.permissionDenied {
                permissionMessage
            } else {
                VStack(spacing: 0) {
                    topHUD
                    Spacer()
                    if let notice = recorder.notice { noticeBar(notice) }
                    
                    if showProMenu && !recorder.isRecording && !recorder.isSaving {
                        proToolsDrawer
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .padding(.bottom, 8)
                    }

                    bottomHUD
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .statusBar(hidden: true)
        .preferredColorScheme(.dark)
        .accentColor(Palette.mint)
        .onAppear {
            recorder.start()
            startHaptic.prepare()
            stopHaptic.prepare()
            levelHaptic.prepare()
        }
        .onDisappear {
            if dimmed { leaveDim() }
            recorder.stop()
            countdownTimer?.invalidate()
        }
        .onChange(of: recorder.isLevel) { isLevel in
            if isLevel && settings.showLevelGauge {
                levelHaptic.selectionChanged()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            if dimmed { leaveDim() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsScreen(settings: settings, recorder: recorder)
        }
        .sheet(isPresented: $showPlayer) {
            if let url = recorder.lastClipURL {
                ClipPlayerView(url: url)
            }
        }
    }

    // MARK: Top HUD Bar

    private var topHUD: some View {
        HStack(alignment: .center, spacing: 12) {
            // Top Left: Flashlight Button
            if recorder.hasTorch {
                facetButton(system: recorder.torchOn ? "bolt.fill" : "bolt.slash.fill",
                            tint: recorder.torchOn ? Palette.amber : .white) {
                    recorder.toggleTorch()
                }
            } else {
                Spacer().frame(width: 48, height: 48)
            }

            Spacer()

            // Center Compact Pill (Fits perfectly on all iPhone screens)
            compactInfoPill

            Spacer()

            // Top Right: Settings Button
            facetButton(system: "gearshape.fill") { showSettings = true }
                .disabled(recorder.isRecording || recorder.isSaving)
                .opacity((recorder.isRecording || recorder.isSaving) ? 0.35 : 1)
        }
    }

    private var compactInfoPill: some View {
        VStack(spacing: 2) {
            if recorder.isRecording || recorder.isSaving {
                recordingStatusRow
            } else {
                HStack(spacing: 6) {
                    Text(settings.cameraMode == .slowMo
                         ? "SLO-MO · \(settings.slowMoFrameRate.label)"
                         : "\(settings.resolution.label) · \(settings.quality.label)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(settings.cameraMode == .slowMo ? Palette.amber : Palette.mintBright)

                    Text("·")
                        .foregroundColor(.white.opacity(0.4))

                    Text("\(Int(plan.megabytesPerHour.rounded())) MB/h")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Palette.amber)
                }

                HStack(spacing: 6) {
                    Text(Fmt.size(recorder.freeBytes) + " free")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))

                    if recorder.batteryPercent >= 0 {
                        Text("·")
                            .foregroundColor(.white.opacity(0.4))
                        batteryIndicator
                    }
                }
            }

            if recorder.isRecording && settings.recordAudio {
                audioLevelBar
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
    }

    private var recordingStatusRow: some View {
        HStack(spacing: 8) {
            if recorder.isRecording {
                Facet(sides: 6)
                    .fill(Palette.record)
                    .frame(width: 10, height: 10)
                    .shadow(color: Palette.record, radius: blink ? 5 : 0)
                    .opacity(blink ? 0.3 : 1)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: blink)

                Text("REC")
                    .font(.system(size: 12, weight: .black))
                Text(Fmt.duration(recorder.elapsed))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))

                if recorder.droppedFrames > 0 {
                    Text("\(recorder.droppedFrames)d")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Palette.amber)
                }
            } else if recorder.isSaving {
                ProgressView().tint(Palette.mintBright).scaleEffect(0.7)
                Text("Saving…")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Palette.mintBright)
            }
        }
        .foregroundColor(.white)
        .onAppear { blink = true }
        .onDisappear { blink = false }
    }

    private var batteryIndicator: some View {
        let pct = recorder.batteryPercent
        let color: Color = recorder.batteryCharging ? Palette.mintBright
            : pct <= 20 ? Palette.record
            : pct <= 40 ? Palette.amber
            : .white.opacity(0.8)
        return HStack(spacing: 3) {
            Image(systemName: recorder.batteryCharging ? "battery.100.bolt" : "battery.75")
                .font(.system(size: 10))
            Text("\(pct)%")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(color)
    }

    private var audioLevelBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule()
                    .fill(LinearGradient(colors: [Palette.mintDeep, audioLevelColor], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(3, geo.size.width * CGFloat(recorder.audioLevel)))
                    .animation(.spring(response: 0.2, dampingFraction: 0.8), value: recorder.audioLevel)
            }
        }
        .frame(width: 80, height: 4)
    }

    private var audioLevelColor: Color {
        recorder.audioLevel > 0.85 ? Palette.record
            : recorder.audioLevel > 0.6 ? Palette.amber
            : Palette.mintBright
    }

    // MARK: Floating Pro Mini-Window

    private var proToolsDrawer: some View {
        VStack(spacing: 12) {
            HStack {
                Label("PRO TOOLS", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .black))
                    .foregroundColor(Palette.mintBright)

                Spacer()

                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showProMenu = false }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }

            // EV Exposure Slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Exposure (EV)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Text(String(format: "%@%.1f EV", settings.exposureBias > 0 ? "+" : "", settings.exposureBias))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(Palette.amber)

                    Button("Reset") {
                        recorder.setExposureBias(0.0)
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Palette.mint)
                    .padding(.leading, 6)
                }

                Slider(value: Binding(
                    get: { settings.exposureBias },
                    set: { val in recorder.setExposureBias(val) }
                ), in: -2.0...2.0, step: 0.1)
                .tint(Palette.amber)
            }

            // White Balance Presets
            VStack(alignment: .leading, spacing: 6) {
                Text("White Balance")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))

                HStack(spacing: 6) {
                    ForEach(WhiteBalancePreset.allCases) { preset in
                        let isSelected = settings.whiteBalance == preset
                        Button(action: { recorder.setWhiteBalance(preset) }) {
                            HStack(spacing: 4) {
                                Image(systemName: preset.icon)
                                Text(preset.label)
                            }
                            .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                            .foregroundColor(isSelected ? .black : .white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(isSelected ? Palette.mintBright : Color.white.opacity(0.12))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Quick Toggles Row: Level Meter & Countdown Timer
            HStack(spacing: 10) {
                // Level Toggle
                Button(action: {
                    withAnimation { settings.showLevelGauge.toggle() }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "gyroscope")
                        Text("Level Meter")
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(settings.showLevelGauge ? .black : .white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(settings.showLevelGauge ? Palette.mintBright : Color.white.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                // Timer Pills
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))

                    ForEach(CountdownTimer.allCases) { timer in
                        let isSelected = settings.countdownTimer == timer
                        Button(action: { settings.countdownTimer = timer }) {
                            Text(timer.label)
                                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                                .foregroundColor(isSelected ? .black : .white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(isSelected ? Palette.amber : Color.white.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 15, x: 0, y: 8)
    }

    // MARK: Bottom HUD Bar

    private var bottomHUD: some View {
        VStack(spacing: 12) {
            // Mode Selector + Quick Pro (...) Button
            HStack {
                if !recorder.isRecording && !recorder.isSaving {
                    modeSelector

                    Button(action: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            showProMenu.toggle()
                        }
                    }) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(showProMenu ? Palette.mintBright : .white)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial)
                            .environment(\.colorScheme, .dark)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.2), radius: 4)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Bottom Shutter Row (Gallery Left, Record Center, Flip Right)
            HStack(alignment: .center) {
                // Left: Gallery Thumbnail
                if !recorder.isRecording && !recorder.isSaving, let thumb = recorder.lastClipThumbnail {
                    Button(action: { showPlayer = true }) {
                        Image(uiImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 50, height: 50)
                            .clipShape(Facet(sides: 6, rotation: .pi / 6))
                            .overlay(Facet(sides: 6, rotation: .pi / 6).stroke(Color.white.opacity(0.35), lineWidth: 1.5))
                            .shadow(color: .black.opacity(0.3), radius: 5)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer().frame(width: 50, height: 50)
                }

                Spacer()

                // Center: Record Button
                recordButton

                Spacer()

                // Right: Enlarged Camera Flip Button (or Moon Screen Dimmer while recording)
                if recorder.isRecording {
                    facetButton(system: "moon.fill", size: 56) { enterDim() }
                } else {
                    facetButton(system: "arrow.triangle.2.circlepath.camera.fill", size: 56) {
                        recorder.flipCamera()
                    }
                    .disabled(recorder.isSaving)
                    .opacity(recorder.isSaving ? 0.35 : 1)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    private var recordButton: some View {
        Button {
            if recorder.isRecording {
                stopHaptic.impactOccurred()
                stopHaptic.prepare()
                recorder.toggleRecording()
            } else {
                if countdownRemaining > 0 {
                    cancelCountdown()
                } else if settings.countdownTimer != .off {
                    startCountdown()
                } else {
                    startHaptic.impactOccurred()
                    startHaptic.prepare()
                    recorder.toggleRecording()
                }
            }
        } label: {
            ZStack {
                Facet(sides: 12)
                    .stroke(LinearGradient(colors: [Palette.mintBright, Palette.mintDeep], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 4)
                    .frame(width: 78, height: 78)
                    .shadow(color: Palette.mint.opacity(0.3), radius: 6)

                Facet(sides: 12)
                    .stroke(Palette.mintDeep.opacity(0.3), lineWidth: 1.5)
                    .frame(width: 66, height: 66)

                if recorder.isSaving {
                    ProgressView().tint(Palette.mintBright).scaleEffect(1.2)
                } else if recorder.isRecording {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [Palette.record, Palette.record.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 32, height: 32)
                        .shadow(color: Palette.record.opacity(0.6), radius: 10)
                } else if countdownRemaining > 0 {
                    Image(systemName: "xmark")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Facet(sides: 12)
                        .fill(LinearGradient(colors: [Palette.record, Palette.record.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 58, height: 58)
                        .shadow(color: Palette.record.opacity(0.4), radius: 6, x: 0, y: 3)
                }
            }
            .frame(width: 84, height: 84)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(recorder.isSaving)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: recorder.isRecording)
    }

    private var modeSelector: some View {
        let modes = CameraMode.allCases
        let modeHaptic = UISelectionFeedbackGenerator()

        return HStack(spacing: 0) {
            ForEach(modes) { mode in
                let isActive = settings.cameraMode == mode
                Button {
                    guard settings.cameraMode != mode else { return }
                    modeHaptic.selectionChanged()
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                        settings.cameraMode = mode
                    }
                    recorder.updateCaptureFormat()
                } label: {
                    Text(mode.label)
                        .font(.system(size: 13, weight: isActive ? .bold : .medium))
                        .foregroundColor(isActive
                            ? (mode == .slowMo ? Palette.amber : Palette.mintBright)
                            : .white.opacity(0.6))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 3)
    }

    private func facetButton(system: String,
                             size: CGFloat = 48,
                             tint: Color = .white,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size * 0.38, weight: .medium))
                .foregroundColor(tint)
                .frame(width: size, height: size)
                .background(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .clipShape(Facet(sides: 6, rotation: .pi / 6))
                .overlay(
                    Facet(sides: 6, rotation: .pi / 6)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 3)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Overlays (Level Meter & Countdown)

    private var levelGaugeOverlay: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let isLevel = recorder.isLevel

            ZStack {
                // Center Crosshair
                Circle()
                    .stroke(isLevel ? Palette.mintBright : Color.white.opacity(0.3), lineWidth: 1.5)
                    .frame(width: 12, height: 12)

                // Left and Right Horizon Lines
                HStack(spacing: 24) {
                    Rectangle()
                        .fill(isLevel ? Palette.mintBright : Color.white.opacity(0.3))
                        .frame(width: 40, height: 1.5)

                    Spacer().frame(width: 12)

                    Rectangle()
                        .fill(isLevel ? Palette.mintBright : Color.white.opacity(0.3))
                        .frame(width: 40, height: 1.5)
                }
                .rotationEffect(.degrees(-recorder.rollAngle))
                .animation(.spring(response: 0.2, dampingFraction: 0.8), value: recorder.rollAngle)
            }
            .position(x: w / 2, y: h / 2)
            .shadow(color: isLevel ? Palette.mint.opacity(0.6) : .clear, radius: 4)
        }
        .allowsHitTesting(false)
    }

    private var countdownOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                Text("\(countdownRemaining)")
                    .font(.system(size: 84, weight: .black, design: .rounded))
                    .foregroundColor(Palette.amber)
                    .shadow(color: Palette.amber.opacity(0.6), radius: 20)
                    .scaleEffect(1.1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: countdownRemaining)

                Text("Tap shutter to cancel")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .allowsHitTesting(false)
    }

    private func startCountdown() {
        countdownRemaining = settings.countdownTimer.rawValue
        let haptic = UIImpactFeedbackGenerator(style: .heavy)
        haptic.prepare()

        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            haptic.impactOccurred()
            if countdownRemaining > 1 {
                countdownRemaining -= 1
            } else {
                countdownTimer?.invalidate()
                countdownTimer = nil
                countdownRemaining = 0
                startHaptic.impactOccurred()
                recorder.startRecording()
            }
        }
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownRemaining = 0
    }

    private var noticeBar(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
            .padding(.bottom, 10)
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    recorder.notice = nil
                }
            }
    }

    private var permissionMessage: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 44))
                .foregroundColor(Palette.mint)
                .shadow(color: Palette.mint.opacity(0.5), radius: 10)
            Text("Camera access is off")
                .font(.system(size: 20, weight: .bold))
            Text("Turn it on in Settings › LowPolyCam.")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.7))
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(Palette.mintBright)
            .padding(.top, 8)
        }
        .foregroundColor(.white)
        .padding(32)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
    }

    // MARK: Zoom & Focus

    private var gridOverlay: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height
                for i in 1...2 {
                    let x = w * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))
                    let y = h * CGFloat(i) / 3
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }

    private var zoomLabel: some View {
        Text(String(format: "%.1fx", recorder.zoomFactor))
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 3)
    }

    private func scheduleHideZoomLabel() {
        zoomLabelHideToken += 1
        let token = zoomLabelHideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if zoomLabelHideToken == token {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    showZoomLabel = false
                }
            }
        }
    }

    private var focusReticle: some View {
        Facet(sides: 6, rotation: .pi / 6)
            .stroke(Palette.mintBright, lineWidth: 1.5)
            .frame(width: 56, height: 56)
            .shadow(color: Palette.mint.opacity(0.5), radius: 4)
            .scaleEffect(focusPoint == nil ? 1.2 : 1.0)
            .opacity(focusPoint == nil ? 0 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: focusPoint)
    }

    private func showFocusReticle(at point: CGPoint) {
        focusHideToken += 1
        let token = focusHideToken
        focusPoint = point
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            if focusHideToken == token {
                focusPoint = nil
            }
        }
    }

    // MARK: Dim Mode

    private var dimOverlay: some View {
        Color.black
            .ignoresSafeArea()
            .overlay(
                VStack(spacing: 12) {
                    Facet(sides: 6)
                        .fill(Palette.record)
                        .frame(width: 12, height: 12)
                        .shadow(color: Palette.record, radius: blink ? 6 : 0)
                        .opacity(blink ? 0.3 : 1)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: blink)

                    Text("recording · tap to wake")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.2))
                }
            )
            .onTapGesture { leaveDim() }
    }

    private func enterDim() {
        savedBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = 0
        withAnimation(.easeIn(duration: 0.3)) { dimmed = true }
    }

    private func leaveDim() {
        UIScreen.main.brightness = savedBrightness
        withAnimation(.easeOut(duration: 0.2)) { dimmed = false }
    }
}

// MARK: - In-App Video Preview Player

struct ClipPlayerView: View {
    let url: URL
    @Environment(\.presentationMode) private var presentation
    @State private var player: AVPlayer?
    @State private var loadFailed = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player, !loadFailed {
                    VideoPlayer(player: player)
                        .ignoresSafeArea(edges: .bottom)
                } else if loadFailed {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(Palette.amber)
                            .shadow(color: Palette.amber.opacity(0.5), radius: 10)
                        Text("Unable to play video preview")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text("The clip file could not be found or opened.")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding()
                } else {
                    ProgressView().tint(Palette.mintBright).scaleEffect(1.2)
                }
            }
            .navigationBarTitle("Preview", displayMode: .inline)
            .navigationBarItems(trailing: Button("Done") {
                player?.pause()
                presentation.wrappedValue.dismiss()
            })
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(Palette.mint)
        .onAppear {
            guard FileManager.default.fileExists(atPath: url.path) else {
                loadFailed = true
                return
            }
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}
```

---

### `SettingsScreen.swift`

```swift
import SwiftUI

struct SettingsLabelStyle: LabelStyle {
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 14) {
            configuration.icon
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(color)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: color.opacity(0.3), radius: 3, x: 0, y: 2)

            configuration.title
                .font(.system(size: 16, weight: .medium))
        }
    }
}

struct SettingsScreen: View {

    @ObservedObject var settings: AppSettings
    @ObservedObject var recorder: CameraRecorder
    @Environment(\.presentationMode) private var presentation

    private var plan: EncodePlan { Encoder.plan(for: settings) }

    var body: some View {
        NavigationView {
            List {
                if recorder.isFrontCamera { frontCameraBanner }
                if settings.cameraMode == .slowMo {
                    slowMoFrameRateSection
                    slowMoResolutionSection
                } else {
                    resolutionSection
                    frameRateSection
                }
                qualitySection
                saveSection
                splitSection
                estimateSection
                cameraSection
                advancedSection
                aboutSection
            }
            .listStyle(InsetGroupedListStyle())
            .navigationBarTitle("Settings", displayMode: .inline)
            .navigationBarItems(trailing: Button(action: {
                presentation.wrappedValue.dismiss()
            }) {
                Text("Done")
                    .font(.system(size: 16, weight: .bold))
            })
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(Palette.mint)
    }

    // MARK: Sections

    private var frontCameraBanner: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "person.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Palette.violet)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: Palette.violet.opacity(0.3), radius: 4, x: 0, y: 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Selfie camera")
                        .font(.system(size: 16, weight: .bold))
                    Text("It offers fewer options than the back camera. Anything it cannot do is greyed out.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var resolutionSection: some View {
        Section(header: Text("Resolution").font(.system(size: 13, weight: .semibold)),
                footer: Text("Recording at \(plan.sizeLabel).")) {
            ForEach(Resolution.allCases) { r in
                row(title: r.label,
                    subtitle: recorder.availableResolutions.contains(r) ? r.detail : "Not on this camera",
                    selected: settings.resolution == r,
                    enabled: recorder.availableResolutions.contains(r)) {
                    settings.resolution = r
                    recorder.updateCaptureFormat()
                }
            }
        }
    }

    private var frameRateSection: some View {
        let locked = settings.resolution.lockedFrameRate
        return Section(header: Text("Frame rate").font(.system(size: 13, weight: .semibold)),
                footer: Text(locked != nil
                             ? "\(settings.resolution.label) films at \(locked!.label) only."
                             : recorder.availableFrameRates.count < FrameRate.allCases.count
                             ? "This camera films at \(recorder.availableFrameRates.map { $0.label }.joined(separator: " or ")) only."
                             : "Higher frame rates look smoother and take more space.")) {
            ForEach(FrameRate.allCases) { f in
                let enabled = recorder.availableFrameRates.contains(f) && (locked == nil || locked == f)
                row(title: f.label,
                    subtitle: enabled ? f.detail : (locked != nil ? "\(settings.resolution.label) only films at \(locked!.label)" : "Not on this camera"),
                    selected: settings.frameRate == f,
                    enabled: enabled) {
                    settings.frameRate = f
                    recorder.updateCaptureFormat()
                }
            }
        }
    }

    private var qualitySection: some View {
        Section(header: Text("Quality").font(.system(size: 13, weight: .semibold))) {
            ForEach(Quality.allCases) { q in
                row(title: q.label, subtitle: q.detail, selected: settings.quality == q) {
                    settings.quality = q
                }
            }
        }
    }

    private var saveSection: some View {
        Section(header: Text("Save recordings to").font(.system(size: 13, weight: .semibold))) {
            ForEach(SaveLocation.allCases) { s in
                row(title: s.label, subtitle: s.detail, selected: settings.saveLocation == s) {
                    settings.saveLocation = s
                }
            }
        }
    }

    private var splitSection: some View {
        Section(header: Text("Split recordings").font(.system(size: 13, weight: .semibold)),
                footer: Text("Splitting into shorter segments makes large files easier to transfer, edit, and share, without losing any frames between clips.")) {
            ForEach(SplitInterval.allCases) { interval in
                row(title: interval.label, subtitle: interval.detail, selected: settings.splitInterval == interval) {
                    settings.splitInterval = interval
                }
            }
        }
    }

    private var estimateSection: some View {
        Section(header: Text("What that costs").font(.system(size: 13, weight: .semibold))) {
            info("Space per hour", "\(Int(plan.megabytesPerHour.rounded())) MB")
            info("Room left on this phone", Fmt.hours(hoursLeft))
            info("Bitrate", "\(plan.videoBitrate / 1000) kbit/s video"
                 + (plan.hasAudio ? " + \(plan.audioBitrate / 1000) audio" : ""))
            info("Free space", Fmt.size(recorder.freeBytes))
        }
    }

    private var cameraSection: some View {
        Section(header: Text("Camera Tools").font(.system(size: 13, weight: .semibold)),
                footer: Text(recorder.stabilizationSupported
                             ? "Stabilisation steadies the picture. Turning it off gives a slightly wider view and uses a little less power."
                             : "This camera does not offer stabilisation, so the switch has no effect here.")) {

            Toggle(isOn: $settings.stabilization) {
                Label("Optical stabilisation", systemImage: "hand.raised.fill")
                    .labelStyle(SettingsLabelStyle(color: Palette.violet))
            }
            .onChange(of: settings.stabilization) { _ in recorder.updateStabilization() }
            .disabled(!recorder.stabilizationSupported)

            Toggle(isOn: $settings.showLevelGauge) {
                Label("Horizon level meter", systemImage: "gyroscope")
                    .labelStyle(SettingsLabelStyle(color: Palette.mint))
            }

            Toggle(isOn: $settings.recordAudio) {
                Label("Record sound", systemImage: "mic.fill")
                    .labelStyle(SettingsLabelStyle(color: Palette.mintDeep))
            }
            .onChange(of: settings.recordAudio) { _ in recorder.syncMicInput() }

            Toggle(isOn: $settings.showGrid) {
                Label("Grid overlay", systemImage: "grid")
                    .labelStyle(SettingsLabelStyle(color: Palette.slateLight))
            }
        }
    }

    private var advancedSection: some View {
        Section(header: Text("Video format").font(.system(size: 13, weight: .semibold)),
                footer: Text(settings.useHEVC
                             ? "HEVC gets the same picture into roughly half the space. Plays on the iPhone and in VLC. Switch to H.264 if some other player refuses the files."
                             : "H.264 plays everywhere but needs about 60% more space for the same picture as HEVC.")) {

            row(title: "HEVC", subtitle: "Smaller files, the modern default", icon: "sparkles", iconColor: Palette.mintDeep, selected: settings.useHEVC) {
                settings.useHEVC = true
            }
            row(title: "H.264", subtitle: "Bigger files, plays on almost anything", icon: "film.fill", iconColor: Palette.slateLight, selected: !settings.useHEVC) {
                settings.useHEVC = false
            }
        }
    }

    private var aboutSection: some View {
        Section(header: Text("Good to know").font(.system(size: 13, weight: .semibold))) {
            Text("A recording is written a few seconds at a time in fragments, so if the battery dies mid-recording, the footage up to that moment survives and is filed away next time the app opens.")
                .font(.footnote)
                .foregroundColor(.secondary)
            Text("Filming stops when the app leaves the screen. iOS gives no app permission to keep the camera running in the background, so the screen has to stay on. The moon button dims it to black while recording.")
                .font(.footnote)
                .foregroundColor(.secondary)
            Text("Double-tap anywhere on the preview to quickly flip between cameras.")
                .font(.footnote)
                .foregroundColor(.secondary)
            Text("Physical Volume Up and Volume Down buttons also act as a shutter to start and stop recording.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Slow-Mo sections

    private var slowMoFrameRateSection: some View {
        Section(header: Text("Slow-Mo Speed").font(.system(size: 13, weight: .semibold)),
                footer: Text(recorder.isSlowMoSupportedOnCurrentLens
                             ? "Higher fps = smoother, slower playback."
                             : "Slow motion is not available on this camera lens.")) {
            ForEach(SlowMoFrameRate.allCases) { rate in
                let available = recorder.availableSlowMoRates.contains(rate)
                row(title: "\(rate.label)  (\(rate.multiplierLabel) slow)",
                    subtitle: available ? rate.detail : "Not available on this camera",
                    selected: settings.slowMoFrameRate == rate,
                    enabled: available) {
                    settings.slowMoFrameRate = rate
                    recorder.updateCaptureFormat()
                }
            }
        }
    }

    private var slowMoResolutionSection: some View {
        Section(header: Text("Slow-Mo Resolution").font(.system(size: 13, weight: .semibold)),
                footer: Text("Some frame rates limit the maximum resolution on this iPhone.")) {
            ForEach(Resolution.allCases) { r in
                let available = recorder.availableSlowMoResolutions.contains(r)
                row(title: r.label,
                    subtitle: available ? r.detail : "Not available at \(settings.slowMoFrameRate.label)",
                    selected: settings.slowMoResolution == r,
                    enabled: available) {
                    settings.slowMoResolution = r
                    recorder.updateCaptureFormat()
                }
            }
        }
    }

    // MARK: Pieces

    private func row(title: String,
                     subtitle: String,
                     icon: String? = nil,
                     iconColor: Color? = nil,
                     selected: Bool,
                     enabled: Bool = true,
                     tap: @escaping () -> Void) -> some View {
        Button(action: { if enabled { tap() } }) {
            HStack(spacing: 14) {
                if let icon = icon, let color = iconColor {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(enabled ? color : Color.gray.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: enabled ? color.opacity(0.3) : .clear, radius: 3, x: 0, y: 2)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(enabled ? .primary : .secondary)
                    Text(subtitle)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if selected && enabled {
                    Image(systemName: "checkmark")
                        .foregroundColor(Palette.mintDeep)
                        .font(.system(size: 16, weight: .bold))
                } else if !enabled {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.secondary.opacity(0.4))
                        .font(.system(size: 13))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 16, weight: .regular))
            Spacer()
            Text(value)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)
        }
    }

    private var hoursLeft: Double {
        let perHour = plan.megabytesPerHour * 1_000_000
        guard perHour > 0 else { return 0 }
        return Double(max(0, recorder.freeBytes - CameraRecorder.reserveBytes)) / perHour
    }
}
