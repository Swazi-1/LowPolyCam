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
        case .p480: return (848, 480) // 848 is divisible by 16 for hardware VideoToolbox encoder alignment
        case .p320: return (568, 320)
        case .p144: return (256, 144)
        }
    }

    /// The sensor only needs to run bigger than 720p when 1080p or 4K is
    /// actually wanted - every smaller export is produced by downscaling a
    /// 720p capture, so the camera stays cheap to run for the low tiers.
    var captureDimensions: (w: Int, h: Int) {
        switch self {
        case .p2160: return (3840, 2160)
        case .p1080: return (1920, 1080)
        default: return (1280, 720)
        }
    }

    /// 4K is locked to 30 fps - it's the only rate the hardware/encoder combo
    /// on supported devices actually holds steady at this size.
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
    @Published var lowTorch: Bool {
        didSet { store.set(lowTorch, forKey: "lowTorch") }
    }
    @Published var recordAudio: Bool {
        didSet { store.set(recordAudio, forKey: "recordAudio") }
    }
    /// Video stabilisation (what the iPhone's OIS feeds into). On by default,
    /// because that is how the camera already behaves.
    @Published var stabilization: Bool {
        didSet { store.set(stabilization, forKey: "stabilization") }
    }
    /// HEVC gives roughly the same picture as H.264 at ~40% of the size.
    /// The iPhone 7 (A10) can encode it in hardware. H.264 is here only as a
    /// fallback for players that choke on HEVC.
    @Published var useHEVC: Bool {
        didSet { store.set(useHEVC, forKey: "useHEVC") }
    }
    /// Rule-of-thirds composition grid. Purely a preview overlay - it is
    /// never baked into the recorded video.
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
    var videoBitrate: Int       // bits per second
    var audioBitrate: Int       // bits per second, 0 when muted
    var keyFrameInterval: Int   // in frames
    var frameRate: Int
    var codec: AVVideoCodecType
    var hasAudio: Bool
    var saveLocation: SaveLocation
    var splitInterval: SplitInterval

    var isSlowMo: Bool { cameraMode == .slowMo }
    var slowMoPlaybackFPS: Int { 30 }
    
    // FIXED: Multiplier should be frameRate / 30.0 (e.g. 120 / 30 = 4x slow mo)
    // The previous math (30 / 120) made it a 4x fast-forward timelapse!
    var slowMoMultiplier: Double { Double(frameRate) / 30.0 }

    var totalBitrate: Int { videoBitrate + audioBitrate }

    /// Megabytes written per hour of recording.
    var megabytesPerHour: Double {
        Double(totalBitrate) * 3600.0 / 8.0 / 1_000_000.0
    }

    var sizeLabel: String {
        if isSlowMo {
            return "\(width) x \(height) · \(frameRate) fps (\(Int(slowMoMultiplier))x Slow-Mo)"
        }
        return "\(width) x \(height) · \(frameRate) fps"
    }
}

enum Encoder {

    // Video bitrate in kbit/s at 30 fps, assuming HEVC.
    private static let videoKbps: [Resolution: [Quality: Int]] = [
        .p2160: [.high: 13500, .medium: 8000, .low: 4000, .ultraLow: 1800],
        .p1080: [.high: 4500, .medium: 2200, .low: 1000, .ultraLow: 400],
        .p720: [.high: 2500, .medium: 1200, .low: 600, .ultraLow: 250],
        .p480: [.high: 1200, .medium: 600,  .low: 300, .ultraLow: 130],
        .p320: [.high: 700,  .medium: 350,  .low: 180, .ultraLow: 80],
        .p144: [.high: 250,  .medium: 120,  .low: 70,  .ultraLow: 40]
    ]

    private static let audioKbps: [Quality: Int] = [
        .high: 64, .medium: 48, .low: 32, .ultraLow: 24
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
            keyFrameInterval: gopSeconds * (isSlow ? 30 : fps),
            frameRate: fps,
            codec: settings.useHEVC ? .hevc : .h264,
            hasAudio: settings.recordAudio,
            saveLocation: settings.saveLocation,
            splitInterval: settings.splitInterval
        )
    }

    /// Builds the AVAssetWriter video settings, quietly falling back to H.264
    /// if this device cannot apply the HEVC settings. `canApply` is an instance
    /// method on AVAssetWriter, so the writer the settings are headed for has
    /// to already exist.
    static func videoSettings(for plan: EncodePlan, writer: AVAssetWriter) -> [String: Any] {

        func build(_ codec: AVVideoCodecType) -> [String: Any] {
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: plan.videoBitrate,
                AVVideoMaxKeyFrameIntervalKey: plan.keyFrameInterval,
                AVVideoExpectedSourceFrameRateKey: plan.isSlowMo ? 30 : plan.frameRate,
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
        // The picked codec is not usable here - fall back rather than crash.
        let fallback = build(.h264)
        if writer.canApply(outputSettings: fallback, forMediaType: .video) {
            return fallback
        }
        // Last resort: let the system choose everything except the size.
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

    /// "3 d 4 h" / "12 h" / "45 min"
    static func hours(_ h: Double) -> String {
        if h.isInfinite || h.isNaN { return "-" }
        if h < 1 { return "\(Int(h * 60)) min" }
        if h < 48 { return "\(Int(h)) h" }
        return "\(Int(h / 24)) d \(Int(h.truncatingRemainder(dividingBy: 24))) h"
    }
}
