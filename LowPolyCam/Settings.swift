import Foundation
import AVFoundation
import Combine
import SwiftUI

// MARK: - Physical Device Orientation

enum PhysicalOrientation {
    case portrait
    case landscapeLeft
    case landscapeRight
    case portraitUpsideDown

    var rotationAngle: Double {
        switch self {
        case .portrait: return 0
        case .landscapeLeft: return 90
        case .landscapeRight: return -90
        case .portraitUpsideDown: return 180
        }
    }

    /// Maps our gravity-measured physical orientation directly to AVFoundation's
    /// capture orientation. This is computed straight from the accelerometer, not
    /// from UIDevice.orientation, so no UIKit/AVFoundation landscape-swap applies here
    /// — mapping landscapeLeft/landscapeRight directly (not swapped) is correct.
    var videoOrientation: AVCaptureVideoOrientation {
        switch self {
        case .portrait: return .portrait
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .portraitUpsideDown: return .portraitUpsideDown
        }
    }

    /// iOS 17 deprecated AVCaptureConnection.videoOrientation/isVideoMirrored in
    /// favor of videoRotationAngle. On iOS 17+ devices, setting videoOrientation
    /// on the PHOTO connection is silently a no-op — the still lands with the
    /// sensor's native (landscape) buffer and EXIF orientation = 1, which is
    /// exactly the "flipped/rotated" bug: dimensions come out 4032x3024 instead
    /// of 3024x4032. videoRotationAngle uses a different reference frame than
    /// videoOrientation (it's "how far to rotate the buffer to reach this
    /// orientation", measured the opposite way), so this is its own mapping,
    /// not a passthrough of rotationAngle above.
    var videoRotationAngle: CGFloat {
        switch self {
        case .portrait: return 90
        case .landscapeRight: return 0
        case .landscapeLeft: return 180
        case .portraitUpsideDown: return 270
        }
    }
}

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
        // 4K on iPhone 7 is 30 fps only
        self == .p2160 ? .fps30 : nil
    }

    var detail: String {
        let p = pixels
        return "\(p.w) × \(p.h)"
    }
}

// MARK: - Camera Mode

enum CameraMode: String, CaseIterable, Identifiable {
    case video = "VIDEO"
    case photo = "PHOTO"
    case slowMo = "SLO-MO"

    var id: String { rawValue }
    var label: String { rawValue }
}

// MARK: - Photo Megapixels

enum PhotoMegapixels: Double, CaseIterable, Identifiable {
    case mp2 = 2
    case mp4 = 4
    case mp8 = 8
    case mp12 = 12

    var id: Double { rawValue }

    /// Plain megapixel count (e.g. 12), NOT multiplied by 1,000,000 —
    /// callers that need raw pixel counts do that multiplication themselves.
    var megapixels: Double { rawValue }

    var label: String { "\(Int(rawValue))MP" }
}

// MARK: - Frame rate

enum FrameRate: Int, CaseIterable, Identifiable {
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }
    var value: Int { rawValue }

    var label: String { "\(rawValue) fps" }

    var detail: String {
        switch self {
        case .fps30: return "Standard · lower size"
        case .fps60: return "Smoother motion · more data"
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
        case .high: return "High Quality"
        case .medium: return "Medium Quality"
        case .low: return "Low Quality"
        case .ultraLow: return "Data Saver"
        }
    }

    var detail: String {
        switch self {
        case .high: return "Best video quality, most storage space"
        case .medium: return "Great everyday quality, balanced file size"
        case .low: return "Good quality, less storage space"
        case .ultraLow: return "Smallest files, for filming all day"
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

// MARK: - Max Recording Duration

enum MaxDuration: Int, CaseIterable, Identifiable {
    case off = 0
    case fifteen = 15
    case thirty = 30
    case sixty = 60
    case oneTwenty = 120

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .fifteen: return "15 min"
        case .thirty: return "30 min"
        case .sixty: return "1 hour"
        case .oneTwenty: return "2 hours"
        }
    }

    var subtitle: String {
        switch self {
        case .off: return "Record until you stop"
        case .fifteen: return "Auto-stops after 15 minutes"
        case .thirty: return "Auto-stops after 30 minutes"
        case .sixty: return "Auto-stops after 1 hour"
        case .oneTwenty: return "Auto-stops after 2 hours"
        }
    }

    /// Seconds until auto-stop, or nil when disabled.
    var seconds: TimeInterval? {
        rawValue == 0 ? nil : TimeInterval(rawValue * 60)
    }
}

// MARK: - Grid Style

enum GridStyle: String, CaseIterable, Identifiable {
    case off, thirds, crosshair, square

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .thirds: return "Rule of Thirds"
        case .crosshair: return "Crosshair"
        case .square: return "Center Square"
        }
    }

    var icon: String {
        switch self {
        case .off: return "grid"
        case .thirds: return "grid"
        case .crosshair: return "plus"
        case .square: return "square.dashed"
        }
    }
}

// MARK: - Quick Capture Presets

struct CapturePreset: Identifiable {
    let id: String
    let name: String
    let icon: String
    let detail: String
    let resolution: Resolution
    let quality: Quality
    let frameRate: FrameRate
    let useHEVC: Bool
    let recordAudio: Bool

    static let all: [CapturePreset] = [
        CapturePreset(
            id: "balanced",
            name: "Balanced",
            icon: "scale.3d",
            detail: "1080p · Medium · 30 fps",
            resolution: .p1080,
            quality: .medium,
            frameRate: .fps30,
            useHEVC: true,
            recordAudio: true
        ),
        CapturePreset(
            id: "quality",
            name: "High Quality",
            icon: "sparkles",
            detail: "4K · High · 30 fps",
            resolution: .p2160,
            quality: .high,
            frameRate: .fps30,
            useHEVC: true,
            recordAudio: true
        ),
        CapturePreset(
            id: "allrounder",
            name: "All Rounder",
            icon: "hexagon.fill",
            detail: "1080p · High · 60 fps",
            resolution: .p1080,
            quality: .high,
            frameRate: .fps60,
            useHEVC: true,
            recordAudio: true
        ),
        CapturePreset(
            id: "allday",
            name: "All Day",
            icon: "battery.100",
            detail: "720p · Saver · 30 fps · long shoots",
            resolution: .p720,
            quality: .ultraLow,
            frameRate: .fps30,
            useHEVC: true,
            recordAudio: true
        ),
        CapturePreset(
            id: "social",
            name: "Social",
            icon: "person.2.fill",
            detail: "1080p · Medium · 30 fps · share-ready",
            resolution: .p1080,
            quality: .medium,
            frameRate: .fps30,
            useHEVC: true,
            recordAudio: true
        )
    ]
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
        case .cloudy: return "Golden"
        }
    }

    var icon: String {
        switch self {
        case .auto: return "sparkles"
        case .daylight: return "sun.max.fill"
        case .indoor: return "flame.fill"
        case .fluorescent: return "snowflake"
        case .cloudy: return "sun.dust.fill"
        }
    }

    var kelvin: (temp: Float, tint: Float)? {
        switch self {
        case .auto: return nil
        case .daylight: return (5200, 0)
        case .indoor: return (7200, 5)
        case .fluorescent: return (3800, -5)
        case .cloudy: return (8200, 0)
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
    @Published var maxDuration: MaxDuration {
        didSet { store.set(maxDuration.rawValue, forKey: "maxDuration") }
    }
    @Published var gridStyle: GridStyle {
        didSet { store.set(gridStyle.rawValue, forKey: "gridStyle") }
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
    @Published var autoDimOnRecord: Bool {
        didSet { store.set(autoDimOnRecord, forKey: "autoDimOnRecord") }
    }
    @Published var accentColor: AccentColor {
        didSet { store.set(accentColor.rawValue, forKey: "accentColor") }
    }
    @Published var shutterSoundEnabled: Bool {
        didSet { store.set(shutterSoundEnabled, forKey: "shutterSoundEnabled") }
    }
    @Published var photoMegapixels: PhotoMegapixels {
        didSet { store.set(photoMegapixels.rawValue, forKey: "photoMegapixels") }
    }
    @Published var saveSelfiesUnmirrored: Bool {
        didSet { store.set(saveSelfiesUnmirrored, forKey: "saveSelfiesUnmirrored") }
    }
    @Published var captureFlashConfirmation: Bool {
        didSet { store.set(captureFlashConfirmation, forKey: "captureFlashConfirmation") }
    }
    @Published var hapticFeedbackEnabled: Bool {
        didSet { store.set(hapticFeedbackEnabled, forKey: "hapticFeedbackEnabled") }
    }

    /// Applies a capture preset. Forces video mode for recording-oriented presets.
    func applyPreset(_ preset: CapturePreset) {
        cameraMode = .video
        resolution = preset.resolution
        quality = preset.quality
        frameRate = preset.frameRate
        useHEVC = preset.useHEVC
        // Audio is always on — no silent recordings
        recordAudio = true
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
        maxDuration      = MaxDuration(rawValue: store.integer(forKey: "maxDuration")) ?? .off
        // Migrate old showGrid bool → gridStyle if gridStyle not yet stored
        if let raw = store.string(forKey: "gridStyle"), let style = GridStyle(rawValue: raw) {
            gridStyle = style
        } else if store.object(forKey: "showGrid") as? Bool == true {
            gridStyle = .thirds
        } else {
            gridStyle = .off
        }
        showLevelGauge   = store.object(forKey: "showLevelGauge") as? Bool ?? false
        exposureBias     = store.object(forKey: "exposureBias") as? Float ?? 0.0
        whiteBalance     = WhiteBalancePreset(rawValue: store.string(forKey: "whiteBalance") ?? "") ?? .auto
        torchBrightness  = store.object(forKey: "torchBrightness") as? Float ?? 1.0
        lowTorch         = store.object(forKey: "lowTorch") as? Bool ?? false
        // Always record audio — mute option removed
        recordAudio      = true
        store.set(true, forKey: "recordAudio")
        stabilization    = store.object(forKey: "stabilization") as? Bool ?? true
        useHEVC          = store.object(forKey: "useHEVC") as? Bool ?? true
        showGrid         = store.object(forKey: "showGrid") as? Bool ?? false
        autoDimOnRecord  = store.object(forKey: "autoDimOnRecord") as? Bool ?? false
        accentColor      = AccentColor(rawValue: store.string(forKey: "accentColor") ?? "") ?? .mint
        shutterSoundEnabled = store.object(forKey: "shutterSoundEnabled") as? Bool ?? true
        photoMegapixels  = PhotoMegapixels(rawValue: store.object(forKey: "photoMegapixels") as? Double ?? 12.0) ?? .mp12
        saveSelfiesUnmirrored    = store.object(forKey: "saveSelfiesUnmirrored") as? Bool ?? false
        captureFlashConfirmation = store.object(forKey: "captureFlashConfirmation") as? Bool ?? true
        hapticFeedbackEnabled    = store.object(forKey: "hapticFeedbackEnabled") as? Bool ?? true
    }
}

// MARK: - Accent Colour

enum AccentColor: String, CaseIterable, Identifiable {
    case mint, violet, amber, red, ice

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mint: return "Lens Mint"
        case .violet: return "Dial Lavender"
        case .amber: return "Button Gold"
        case .red: return "Record Red"
        case .ice: return "Ice Cyan"
        }
    }

    var color: Color {
        switch self {
        case .mint: return Palette.mint
        case .violet: return Palette.violet
        case .amber: return Palette.amber
        case .red: return Palette.record
        case .ice: return Palette.ice
        }
    }

    var bright: Color {
        switch self {
        case .mint: return Palette.mintBright
        case .violet: return Palette.violet.opacity(0.9)
        case .amber: return Palette.amberBright
        case .red: return Color(hex: 0xFF7A70)
        case .ice: return Palette.iceBright
        }
    }

    var deep: Color {
        switch self {
        case .mint: return Palette.mintDeep
        case .violet: return Palette.violetDeep
        case .amber: return Palette.amberDeep
        case .red: return Palette.record
        case .ice: return Palette.iceDeep
        }
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

    // Conservative rates for A10 VideoDataOutput+AssetWriter path.
    // Higher values caused systematic frame drops → Photos showed ~24–26 fps.
    private static let videoKbps: [Resolution: [Quality: Int]] = [
        .p2160: [.high: 8000,  .medium: 5500,  .low: 3500, .ultraLow: 2200],
        .p1080: [.high: 6000,  .medium: 3000,  .low: 1500, .ultraLow: 400],
        .p720:  [.high: 3000,  .medium: 1500,  .low: 800,  .ultraLow: 250],
        .p480:  [.high: 1500,  .medium: 800,   .low: 400,  .ultraLow: 130],
        .p320:  [.high: 800,   .medium: 400,   .low: 200,  .ultraLow: 80],
        .p144:  [.high: 300,   .medium: 150,   .low: 80,   .ultraLow: 40]
    ]

    private static let audioKbps: [Quality: Int] = [
        .high: 128, .medium: 64, .low: 32, .ultraLow: 24
    ]

    private static let keyFrameSeconds: [Quality: Int] = [
        .high: 2, .medium: 4, .low: 6, .ultraLow: 10
    ]

    private static let h264Multiplier = 1.6

    private static let fpsMultiplier: [FrameRate: Double] = [
        .fps30: 1.0,
        .fps60: 1.45   // keep 60 fps sustainable on A10 without drops
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
        // Longer GOPs at 4K reduce I-frame spikes that backlog the A10 encoder.
        var gopSeconds = keyFrameSeconds[settings.quality] ?? 4
        if res == .p2160 { gopSeconds = max(gopSeconds, 5) }
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
            // Real-time path: no B-frame reordering (less backlog on A10).
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: plan.videoBitrate,
                AVVideoMaxKeyFrameIntervalKey: plan.keyFrameInterval,
                AVVideoExpectedSourceFrameRateKey: plan.frameRate,
                AVVideoAllowFrameReorderingKey: false
            ]
            if codec == .h264 {
                compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            return [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: plan.width,
                AVVideoHeightKey: plan.height,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
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
