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

// MARK: - Device check (used to warn about memory-heavy settings on older hardware)

enum DeviceTier {
    /// True on iPhone 7 / 7 Plus (A10, 2GB RAM) where 4K recording is more
    /// likely to hit memory pressure during long sessions.
    static var isLowMemoryDevice: Bool {
        ProcessInfo.processInfo.physicalMemory <= 2_500_000_000
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
        case .p320: return (576, 320)
        case .p144: return (256, 144)
        }
    }

    /// Sensor / activeFormat dimensions to request. On iPhone 7 (A10) lower
    /// target resolutions should also drive a lower capture format when the
    /// hardware supports it, otherwise "Data Saver" modes still run the ISP
    /// at 720p and only scale in the encoder (wasted heat and power).
    var captureDimensions: (w: Int, h: Int) {
        switch self {
        case .p2160: return (3840, 2160)
        case .p1080: return (1920, 1080)
        case .p720:  return (1280, 720)
        case .p480:  return (848, 480)
        case .p320:  return (576, 320)
        case .p144:  return (256, 144)
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
        case .high: return "Matches iOS Camera size & quality"
        case .medium: return "Slightly below iOS Camera, balanced size"
        case .low: return "Smaller files, still clear"
        case .ultraLow: return "Smallest usable files for long shoots"
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

    /// One-line description shown under the label in the White Balance sheet.
    var detail: String {
        switch self {
        case .auto: return "Matches white balance to the scene automatically"
        case .daylight: return "Best for outdoor daylight"
        case .indoor: return "Warms up indoor / tungsten lighting"
        case .fluorescent: return "Cools down office / fluorescent lighting"
        case .cloudy: return "Golden, warm tone for overcast or sunset"
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
//
// HOW TO ADD A NEW SETTING
// --------------------------
// 1. Add an `@Published var yourSetting: T` below, with a `didSet` that
//    writes it to `store` (UserDefaults) under a unique key — copy the
//    pattern of any existing property.
// 2. Load its initial value from `store` in `init()` below, with a sensible
//    default for first launch.
// 3. Expose it in the UI:
//    - Settings screen: add one `SettingsToggleSpec` (for a Bool) to the
//      relevant array in SettingsScreen.swift, e.g. `assistToggles`, or use
//      `SettingsPickerRow` directly for a `CaseIterable` enum setting.
//      See SettingsRowKit.swift for both.
//    - Pro Tools drawer: add one `ProToolControl` case (`.toggle`, `.chips`,
//      or `.slider`) to `proToolsDrawerControls` in CameraScreen.swift.
//      See ProToolsControls.swift.
// No other file needs to change — both UIs render from these declarative
// lists rather than needing a new hand-built row per setting.
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
    /// 📊 Opt-in live stats readout (measured fps / bitrate / drop rate)
    /// during recording. Off by default so the HUD layout for everyone
    /// else stays exactly as it was.
    @Published var showRecordingStats: Bool {
        didSet { store.set(showRecordingStats, forKey: "showRecordingStats") }
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
    /// Longevity Mode prioritises battery life, lower heat, and smaller files
    /// on older devices (especially iPhone 7 / A10). When enabled it gently
    /// steers the encoder toward safer settings and strengthens auto-dim.
    @Published var longevityMode: Bool {
        didSet { store.set(longevityMode, forKey: "longevityMode") }
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
        // First-launch defaults: 1080p · 30 fps · High · Photos · split/auto-stop off,
        // stabilisation on, grid/level/dim/longevity off, sounds & haptics on.
        resolution       = Resolution(rawValue: store.string(forKey: "resolution") ?? "") ?? .p1080
        quality          = Quality(rawValue: store.string(forKey: "quality") ?? "") ?? .high
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
        showRecordingStats = store.object(forKey: "showRecordingStats") as? Bool ?? false
        // Default appearance is Dial Lavender. Legacy "mint" installs map to violet
        // (Lens Mint was removed).
        if let raw = store.string(forKey: "accentColor"), raw != "mint",
           let parsed = AccentColor(rawValue: raw) {
            accentColor = parsed
        } else {
            accentColor = .violet
            store.set(AccentColor.violet.rawValue, forKey: "accentColor")
        }
        shutterSoundEnabled = store.object(forKey: "shutterSoundEnabled") as? Bool ?? true
        photoMegapixels  = PhotoMegapixels(rawValue: store.object(forKey: "photoMegapixels") as? Double ?? 12.0) ?? .mp12
        saveSelfiesUnmirrored    = store.object(forKey: "saveSelfiesUnmirrored") as? Bool ?? false
        // Screen-flash confirmation removed from Settings; keep key for migration only.
        captureFlashConfirmation = store.object(forKey: "captureFlashConfirmation") as? Bool ?? false
        hapticFeedbackEnabled    = store.object(forKey: "hapticFeedbackEnabled") as? Bool ?? true
        // Longevity defaults OFF on first launch (user can enable for long sessions).
        longevityMode            = store.object(forKey: "longevityMode") as? Bool ?? false
    }
}

// MARK: - Accent Colour

enum AccentColor: String, CaseIterable, Identifiable {
    case violet, amber, red, ice, aurora, coral

    var id: String { rawValue }

    var label: String {
        switch self {
        case .violet: return "Dial Lavender"
        case .amber: return "Button Gold"
        case .red: return "Record Red"
        case .ice: return "Ice Cyan"
        case .aurora: return "Aurora"
        case .coral: return "Coral Bloom"
        }
    }

    var color: Color {
        switch self {
        case .violet: return Palette.violet
        case .amber: return Palette.amber
        case .red: return Palette.record
        case .ice: return Palette.ice
        case .aurora: return Palette.aurora
        case .coral: return Palette.coral
        }
    }

    var bright: Color {
        switch self {
        case .violet: return Palette.violet.opacity(0.9)
        case .amber: return Palette.amberBright
        case .red: return Color(hex: 0xFF7A70)
        case .ice: return Palette.iceBright
        case .aurora: return Palette.auroraBright
        case .coral: return Palette.coralBright
        }
    }

    var deep: Color {
        switch self {
        case .violet: return Palette.violetDeep
        case .amber: return Palette.amberDeep
        case .red: return Palette.record
        case .ice: return Palette.iceDeep
        case .aurora: return Palette.auroraDeep
        case .coral: return Palette.coralDeep
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

    // Note: A10/A10X Fusion (iPhone 7/7 Plus, iPad 6th/7th gen, iPad Pro
    // 2017) DOES have a real hardware HEVC encoder — it's the chip HEVC
    // recording was introduced for in iOS 11. So HEVC itself was never the
    // cause of the frame-drop issue on this device; codec choice doesn't
    // need to be restricted here. (An earlier version of this file
    // incorrectly assumed A10 lacked hardware HEVC encode and forced H.264
    // for it — that assumption was wrong and has been removed.)

    // Bitrates. High quality now targets roughly what the stock iOS Camera
    // app uses at each resolution (Apple ballparks: ~4K30≈40Mbps HEVC,
    // ~1080p30≈16Mbps HEVC, ~720p30≈8Mbps HEVC). These used to be set much
    // lower ("Conservative rates ... higher values caused systematic frame
    // drops") to defensively work around a bug that made Photos report
    // non-30fps clips — but that bug's real cause was a duplicate-writer
    // race in startSegment (two AVAssetWriters fighting over the same file,
    // see CameraRecorder.swift's segmentStartInFlight guard), NOT the
    // bitrate. With that race fixed, bitrate can go back up to real
    // quality levels without reintroducing the frame-drop symptom.
    private static let videoKbps: [Resolution: [Quality: Int]] = [
        // High ≈ stock iOS Camera HEVC (measured: 1080p30 ≈ 8 Mbps → ~4.8 MB / 5s).
        // Other heights scale by pixel count from that anchor. 4K uses Apple-like
        // ~32 Mbps (pure pixel scale from 1080p would under-rate fine detail).
        // Medium ~70%, Low ~45%, Data Saver ~25%.
        .p2160: [.high: 32000, .medium: 22000, .low: 14500, .ultraLow: 8000],
        .p1080: [.high: 8000,  .medium: 5500,  .low: 3600,  .ultraLow: 2000],
        .p720:  [.high: 3600,  .medium: 2500,  .low: 1600,  .ultraLow: 900],
        .p480:  [.high: 1600,  .medium: 1100,  .low: 700,   .ultraLow: 400],
        .p320:  [.high: 700,   .medium: 500,   .low: 300,   .ultraLow: 180],
        .p144:  [.high: 250,   .medium: 180,   .low: 120,   .ultraLow: 80]
    ]

    private static let audioKbps: [Quality: Int] = [
        .high: 160, .medium: 128, .low: 64, .ultraLow: 32
    ]

    private static let keyFrameSeconds: [Quality: Int] = [
        .high: 2, .medium: 4, .low: 6, .ultraLow: 10
    ]

    private static let h264Multiplier = 1.6

    private static let fpsMultiplier: [FrameRate: Double] = [
        .fps30: 1.0,
        // Slightly conservative so the A10 real-time encoder never falls
        // behind at 1080p60 / 720p60; under-run was the main cause of
        // Photos reporting 56–62 fps instead of a clean 60.00.
        .fps60: 1.30
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

        var kbps = Double(baseKbps) * codecMultiplier * fpsFactor
        // Slow-mo (120/240fps) asks the A10's real-time encoder to sustain
        // 4-8x the throughput of normal 30fps recording. Scaling bitrate up
        // by the same fpsFactor used for the base table (tuned for the
        // *quality* table's much lower base values) compounds once that
        // base table itself is raised for normal-speed quality — the
        // encoder then can't keep up and frames get dropped, which is what
        // was reading back as 217fps instead of 240fps. Slow-mo prioritizes
        // catching every frame over per-frame bit density, so its ceiling
        // is capped independently of the (now much higher) quality-preset
        // base rate.
        //
        // The previous flat 30/20 Mbps ceilings were still too high for the
        // A10's real-time HEVC encoder at 720p240 — frames kept backing up
        // and getting discarded (alwaysDiscardsLateVideoFrames), reading
        // back as ~210 fps in Photos instead of the ~239.9 fps the stock
        // Camera app achieves. Apple's own stock Camera app targets roughly
        // these bitrates for slow-mo (from Apple's published storage specs:
        // 720p@240≈170MB/min, 1080p@120≈130MB/min, 720p@120≈65MB/min) —
        // matching them keeps the encoder comfortably real-time on A10.
        if isSlow {
            // Single rate matched to measured stock Camera (no Quality tiers).
            // 720p@240 ≈ 28 Mbps; 1080p@120 ≈ 20 Mbps; 720p@120 ≈ 12 Mbps.
            let slowMoTargetKbps: Double
            if fps >= 240 {
                // ~10 Mbps H.264 — prioritise writer survival over bitrate.
                slowMoTargetKbps = 10000
            } else if res == .p1080 {
                slowMoTargetKbps = 20000
            } else {
                slowMoTargetKbps = 12000
            }
            kbps = slowMoTargetKbps
        }

        // Longevity Mode: gentle bitrate cut for normal video. For slow-mo
        // we cut less — per-frame bits are already scarce at 120/240 fps and
        // a hard 0.78× made footage look muddy.
        if settings.longevityMode && !isSlow {
            kbps *= 0.78
        }

        // GOP length. Slow-mo needs more frequent I-frames so motion stays
        // sharp when played back at 1/4–1/8 speed; a 4–6 s GOP at 240 fps
        // is nearly a thousand frames between keyframes and looks soft.
        var gopSeconds = keyFrameSeconds[settings.quality] ?? 4
        if res == .p2160 { gopSeconds = max(gopSeconds, 5) }
        if isSlow {
            gopSeconds = min(gopSeconds, 2)   // ≤2 s between I-frames
        }
        if settings.longevityMode && !isSlow {
            gopSeconds = max(gopSeconds, 6)
        }
        let aKbps = settings.recordAudio ? (audioKbps[settings.quality] ?? 32) : 0

        return EncodePlan(
            cameraMode: settings.cameraMode,
            width: px.w,
            height: px.h,
            videoBitrate: Int(kbps * 1000.0),
            audioBitrate: aKbps * 1000,
            keyFrameInterval: gopSeconds * fps,
            frameRate: fps,
            // Match stock Camera: HEVC for 720p+ and for slow-mo (including 240fps)
            // when the user has HEVC enabled. H.264 only for sub-720p normal video
            // (unusual sizes) or when HEVC is turned off in settings.
            codec: {
                // 240fps: H.264 only for third-party AVAssetWriter on A10/iOS 15.
                // Stock Camera uses a private HEVC path; public AVAssetWriter + HEVC
                // at 240fps often fails the first append and aborts the take.
                if isSlow && fps >= 240 { return AVVideoCodecType.h264 }
                if isSlow {
                    return settings.useHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264
                }
                if settings.useHEVC && px.h >= 720 { return AVVideoCodecType.hevc }
                return AVVideoCodecType.h264
            }(),
            // 240fps on A10: audio previously caused finishWriting failures when
            // combined with the video track — restored per user request. If audio
            // dropouts/failures reappear at 240fps specifically, this is the first
            // place to look (see DebugLog "[7] audio input REJECTED" entries).
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
                AVVideoMaxKeyFrameIntervalKey: max(plan.keyFrameInterval, 1),
                AVVideoAllowFrameReorderingKey: false
            ]
            // Expected frame rate helps the encoder; at 240fps some iOS 15
            // builds reject the key with HEVC — try with it first, caller
            // falls back via canApply.
            if plan.frameRate <= 120 {
                compression[AVVideoExpectedSourceFrameRateKey] = plan.frameRate
            }
            if codec == .h264 {
                if plan.frameRate >= 240 {
                    compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264MainAutoLevel
                } else {
                    compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
                }
            }
            // Cap keyframe distance at 240fps (2s × 240 = 480 was fine; keep ≤2s).
            if plan.frameRate >= 240 {
                // I-frame every ~0.5s — lighter on the A10 than a 2s GOP.
                compression[AVVideoMaxKeyFrameIntervalKey] = 120
            }
            return [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: plan.width,
                AVVideoHeightKey: plan.height,
                AVVideoCompressionPropertiesKey: compression
            ]
        }

        // Try preferred codec, then H.264, then bare minimum.
        for codec in [plan.codec, AVVideoCodecType.h264] {
            let settings = build(codec)
            if writer.canApply(outputSettings: settings, forMediaType: .video) {
                return settings
            }
        }
        // Last resort: no compression property dictionary.
        let bare: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: plan.width,
            AVVideoHeightKey: plan.height
        ]
        if writer.canApply(outputSettings: bare, forMediaType: .video) {
            return bare
        }
        return bare
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
