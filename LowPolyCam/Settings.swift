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

    var lockedFrameRate: FrameRate? { nil }

    var detail: String {
        let p = pixels
        return "\(p.w) x \(p.h)"
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
        torchBrightness  = store.object(forKey: "torchBrightness") as? Float ?? 1.0
        lowTorch         = store.object(forKey: "lowTorch") as? Bool ?? false
        recordAudio      = store.object(forKey: "recordAudio") as? Bool ?? true
        stabilization    = store.object(forKey: "stabilization") as? Bool ?? true
        useHEVC          = store.object(forKey: "useHEVC") as? Bool ?? true
        showGrid         = store.object(forKey: "showGrid") as? Bool ?? false
        autoDimOnRecord  = store.object(forKey: "autoDimOnRecord") as? Bool ?? false
        accentColor      = AccentColor(rawValue: store.string(forKey: "accentColor") ?? "") ?? .mint
        shutterSoundEnabled = store.object(forKey: "shutterSoundEnabled") as? Bool ?? true
        photoMegapixels  = PhotoMegapixels(rawValue: store.object(forKey: "photoMegapixels") as? Double ?? 12.0) ?? .mp12
    }
}

// MARK: - Accent Colour

enum AccentColor: String, CaseIterable, Identifiable {
    case mint, violet, amber, red

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mint: return "Lens Mint"
        case .violet: return "Dial Lavender"
        case .amber: return "Button Gold"
        case .red: return "Record Red"
        }
    }

    var color: Color {
        switch self {
        case .mint: return Palette.mint
        case .violet: return Palette.violet
        case .amber: return Palette.amber
        case .red: return Palette.record
        }
    }

    var bright: Color {
        switch self {
        case .mint: return Palette.mintBright
        case .violet: return Palette.violet.opacity(0.9)
        case .amber: return Palette.amberBright
        case .red: return Color(hex: 0xFF7A70)
        }
    }

    var deep: Color {
        switch self {
        case .mint: return Palette.mintDeep
        case .violet: return Palette.violetDeep
        case .amber: return Palette.amberDeep
        case .red: return Palette.record
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
