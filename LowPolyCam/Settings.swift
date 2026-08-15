import Foundation
import AVFoundation
import Combine

// MARK: - Resolution

enum Resolution: String, CaseIterable, Identifiable {
    case p1080, p720, p480, p320, p144

    var id: String { rawValue }

    var label: String {
        switch self {
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p480: return "480p"
        case .p320: return "320p"
        case .p144: return "144p"
        }
    }

    /// Always 16:9 so nothing gets cropped when the capture is scaled down.
    var pixels: (w: Int, h: Int) {
        switch self {
        case .p1080: return (1920, 1080)
        case .p720: return (1280, 720)
        case .p480: return (854, 480)
        case .p320: return (568, 320)
        case .p144: return (256, 144)
        }
    }

    /// The sensor only needs to run bigger than 720p when 1080p is actually
    /// wanted - every smaller export is produced by downscaling a 720p
    /// capture, so the camera stays cheap to run for the low tiers.
    var captureDimensions: (w: Int, h: Int) {
        self == .p1080 ? (1920, 1080) : (1280, 720)
    }

    var detail: String {
        let p = pixels
        return "\(p.w) x \(p.h)"
    }
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

// MARK: - Stored settings

final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    private let store = UserDefaults.standard

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

    private init() {
        resolution    = Resolution(rawValue: store.string(forKey: "resolution") ?? "") ?? .p720
        quality       = Quality(rawValue: store.string(forKey: "quality") ?? "") ?? .ultraLow
        frameRate     = FrameRate(rawValue: store.integer(forKey: "frameRate")) ?? .fps30
        saveLocation  = SaveLocation(rawValue: store.string(forKey: "saveLocation") ?? "") ?? .photos
        recordAudio   = store.object(forKey: "recordAudio") as? Bool ?? true
        stabilization = store.object(forKey: "stabilization") as? Bool ?? true
        useHEVC       = store.object(forKey: "useHEVC") as? Bool ?? true
    }
}

// MARK: - Encode plan

struct EncodePlan {
    var width: Int
    var height: Int
    var videoBitrate: Int       // bits per second
    var audioBitrate: Int       // bits per second, 0 when muted
    var keyFrameInterval: Int   // in frames
    var frameRate: Int
    var codec: AVVideoCodecType
    var hasAudio: Bool
    var saveLocation: SaveLocation

    var totalBitrate: Int { videoBitrate + audioBitrate }

    /// Megabytes written per hour of recording.
    var megabytesPerHour: Double {
        Double(totalBitrate) * 3600.0 / 8.0 / 1_000_000.0
    }

    var sizeLabel: String { "\(width) x \(height) · \(frameRate) fps" }
}

enum Encoder {

    // Video bitrate in kbit/s at 30 fps, assuming HEVC. Tweak freely, these
    // are the only numbers that decide how much space an hour of footage
    // takes at the standard frame rate; other rates scale off this via
    // fpsMultiplier below.
    private static let videoKbps: [Resolution: [Quality: Int]] = [
        .p1080: [.high: 4500, .medium: 2200, .low: 1000, .ultraLow: 400],
        .p720: [.high: 2500, .medium: 1200, .low: 600, .ultraLow: 250],
        .p480: [.high: 1200, .medium: 600,  .low: 300, .ultraLow: 130],
        .p320: [.high: 700,  .medium: 350,  .low: 180, .ultraLow: 80],
        .p144: [.high: 250,  .medium: 120,  .low: 70,  .ultraLow: 40]
    ]

    private static let audioKbps: [Quality: Int] = [
        .high: 64, .medium: 48, .low: 32, .ultraLow: 24
    ]

    /// Seconds between keyframes. Longer = smaller files, but seeking gets
    /// coarser and a corrupted spot costs you more.
    private static let keyFrameSeconds: [Quality: Int] = [
        .high: 2, .medium: 4, .low: 6, .ultraLow: 10
    ]

    /// H.264 needs roughly 60% more bits for the same picture as HEVC.
    private static let h264Multiplier = 1.6

    /// More frames per second need more total bits to hold picture quality
    /// steady, since each individual frame gets a smaller slice of the
    /// average bitrate otherwise. Scaled relative to 30 fps.
    private static let fpsMultiplier: [FrameRate: Double] = [
        .fps24: 0.85, .fps30: 1.0, .fps60: 1.6
    ]

    static func plan(for settings: AppSettings) -> EncodePlan {
        let px = settings.resolution.pixels
        let baseKbps = videoKbps[settings.resolution]?[settings.quality] ?? 600
        let codecMultiplier = settings.useHEVC ? 1.0 : h264Multiplier
        let fpsFactor = fpsMultiplier[settings.frameRate] ?? 1.0
        let kbps = Double(baseKbps) * codecMultiplier * fpsFactor
        let gopSeconds = keyFrameSeconds[settings.quality] ?? 4
        let aKbps = settings.recordAudio ? (audioKbps[settings.quality] ?? 32) : 0
        let fps = settings.frameRate.value

        return EncodePlan(
            width: px.w,
            height: px.h,
            videoBitrate: Int(kbps * 1000.0),
            audioBitrate: aKbps * 1000,
            keyFrameInterval: gopSeconds * fps,
            frameRate: fps,
            codec: settings.useHEVC ? .hevc : .h264,
            hasAudio: settings.recordAudio,
            saveLocation: settings.saveLocation
        )
    }

    /// Builds AVCaptureMovieFileOutput video settings, falling back to H.264
    /// (or whatever the connection actually offers) if this device cannot do
    /// HEVC. There is no `canApply`-style dry run for this API, so the codec
    /// is checked against `availableVideoCodecTypes` instead; every other key
    /// here is a plain width/height/bitrate value of the kind that has never
    /// been the cause of a crash.
    static func movieVideoSettings(for plan: EncodePlan, output: AVCaptureMovieFileOutput) -> [String: Any] {
        let available = output.availableVideoCodecTypes
        let codec = available.contains(plan.codec)
            ? plan.codec
            : (available.contains(.h264) ? .h264 : (available.first ?? .h264))

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

    /// Every key here is chosen by us and self-consistent - unlike the
    /// AVAssetWriter crash from before (an inherited "recommended" dictionary
    /// with one key overridden), there is nothing borrowed here that could
    /// clash with the bitrate override.
    static func movieAudioSettings(for plan: EncodePlan) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100,
            AVEncoderBitRateKey: plan.audioBitrate
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
