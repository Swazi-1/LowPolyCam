import Foundation
import AVFoundation
import Combine

// MARK: - Resolution

enum Resolution: String, CaseIterable, Identifiable {
    case p720, p480, p320, p144

    var id: String { rawValue }

    var label: String {
        switch self {
        case .p720: return "720p"
        case .p480: return "480p"
        case .p320: return "320p"
        case .p144: return "144p"
        }
    }

    /// Always 16:9 so nothing gets cropped when the 1280x720 capture is scaled down.
    var pixels: (w: Int, h: Int) {
        switch self {
        case .p720: return (1280, 720)
        case .p480: return (854, 480)
        case .p320: return (568, 320)
        case .p144: return (256, 144)
        }
    }

    var detail: String {
        let p = pixels
        return "\(p.w) x \(p.h)"
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
    @Published var recordAudio: Bool {
        didSet { store.set(recordAudio, forKey: "recordAudio") }
    }
    /// HEVC gives roughly the same picture as H.264 at ~40% of the size.
    /// The iPhone 7 (A10) can encode it in hardware. H.264 is here only as a
    /// fallback for players that choke on HEVC.
    @Published var useHEVC: Bool {
        didSet { store.set(useHEVC, forKey: "useHEVC") }
    }

    private init() {
        resolution  = Resolution(rawValue: store.string(forKey: "resolution") ?? "") ?? .p720
        quality     = Quality(rawValue: store.string(forKey: "quality") ?? "") ?? .ultraLow
        recordAudio = store.object(forKey: "recordAudio") as? Bool ?? true
        useHEVC     = store.object(forKey: "useHEVC") as? Bool ?? true
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

    var totalBitrate: Int { videoBitrate + audioBitrate }

    /// Megabytes written per hour of recording.
    var megabytesPerHour: Double {
        Double(totalBitrate) * 3600.0 / 8.0 / 1_000_000.0
    }
}

enum Encoder {

    /// Frames per second. Dropping this to 15 is the single biggest extra
    /// saving available - it roughly halves every number below.
    static let frameRate = 30

    // Video bitrate in kbit/s, assuming HEVC. Tweak freely, these are the
    // only numbers that decide how much space an hour of footage takes.
    private static let videoKbps: [Resolution: [Quality: Int]] = [
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

    static func plan(for settings: AppSettings) -> EncodePlan {
        let px = settings.resolution.pixels
        let baseKbps = videoKbps[settings.resolution]?[settings.quality] ?? 600
        let kbps = settings.useHEVC ? Double(baseKbps) : Double(baseKbps) * h264Multiplier
        let gopSeconds = keyFrameSeconds[settings.quality] ?? 4
        let aKbps = settings.recordAudio ? (audioKbps[settings.quality] ?? 32) : 0

        return EncodePlan(
            width: px.w,
            height: px.h,
            videoBitrate: Int(kbps * 1000.0),
            audioBitrate: aKbps * 1000,
            keyFrameInterval: gopSeconds * frameRate,
            frameRate: frameRate,
            codec: settings.useHEVC ? .hevc : .h264,
            hasAudio: settings.recordAudio
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
        return build(.h264)
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
