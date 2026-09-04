//
//  Settings.swift
//  LowPolyCam
//
//  Updated for iOS 27 / Xcode 27 / Swift 6.4.
//  Swift 6 complete concurrency · Observation · Liquid Glass · RotationCoordinator
//

import Foundation
import AVFoundation
import Combine
import SwiftUI
import UIKit

// MARK: - Physical Device Orientation

enum PhysicalOrientation: Sendable {
    case portrait
    case landscapeLeft
    case landscapeRight
    case portraitUpsideDown

    /// The front camera's sensor is mounted 180° rotated relative to the
    /// rear camera inside the phone's housing (true across iPhones,
    /// including iPhone 7). AVCapturePhotoOutput's connection API already
    /// accounts for this automatically, which is why single-shot photos on
    /// either camera come out correctly rotated. Burst mode bypasses that
    /// connection-level rotation entirely — it reads raw sensor buffers
    /// straight off AVCaptureVideoDataOutput and tags orientation manually
    /// from the phone's physical tilt — so it must apply this same 180°
    /// correction itself when the active camera is the front one, or every
    /// front-camera burst photo comes out rotated a half-turn from correct.
    var rotated180: PhysicalOrientation {
        switch self {
        case .portrait: return .portraitUpsideDown
        case .portraitUpsideDown: return .portrait
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        }
    }

    var rotationAngle: Double {
        switch self {
        case .portrait: return 0
        case .landscapeLeft: return 90
        case .landscapeRight: return -90
        case .portraitUpsideDown: return 180
        }
    }

    /// Rotation applied to photo/video connections. Replaces the removed
    /// `AVCaptureVideoOrientation` / `videoOrientation` path.
    var captureVideoRotationAngle: CGFloat {
        switch self {
        case .portrait: return 90
        case .landscapeRight: return 0
        case .landscapeLeft: return 180
        case .portraitUpsideDown: return 270
        }
    }

    /// EXIF/UIImage orientation to tag a raw CVPixelBuffer captured straight
    /// off the sensor (landscape-right native, uncorrected) — used by burst
    /// mode, which reads frames directly from AVCaptureVideoDataOutput
    /// instead of going through AVCapturePhotoOutput's own connection-level
    /// rotation. `mirrored` should be true only for a front-camera frame
    /// that is being saved mirrored (see CameraPhoto.swift's `mirrored`
    /// flag on the normal still-capture path — burst matches that exactly
    /// so burst and single-shot photos are never inconsistently flipped).
    func imageOrientation(mirrored: Bool) -> UIImage.Orientation {
        switch (self, mirrored) {
        case (.portrait, false): return .right
        case (.portrait, true): return .leftMirrored
        case (.landscapeRight, false): return .up
        case (.landscapeRight, true): return .upMirrored
        case (.landscapeLeft, false): return .down
        case (.landscapeLeft, true): return .downMirrored
        case (.portraitUpsideDown, false): return .left
        case (.portraitUpsideDown, true): return .rightMirrored
        }
    }
}

// Device tier / low-memory check now lives in PerformanceProfile.swift
// (`PerformanceProfile.DeviceTier`) — this file's old copy was unused
// dead code and has been removed.

// MARK: - Resolution

enum Resolution: String, CaseIterable, Identifiable, SettingStorable {
    // Keep the persisted `p320` identifier for existing installs, but expose
    // the standard 360p tier rather than the old non-standard 320p one.
    case p2160, p1080, p720, p480, p320, p144

    var id: String { rawValue }

    var label: String {
        switch self {
        case .p2160: return "4K"
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p480: return "480p"
        case .p320: return "360p"
        case .p144: return "144p"
        }
    }

    var pixels: (w: Int, h: Int) {
        switch self {
        case .p2160: return (3840, 2160)
        case .p1080: return (1920, 1080)
        case .p720: return (1280, 720)
        // Standard 16:9 phone/video tiers. Every dimension is even, which is
        // required by the H.264/HEVC 4:2:0 encoder on iOS 15.
        case .p480: return (854, 480)
        case .p320: return (640, 360)
        case .p144: return (256, 144)
        }
    }

    /// Preferred 16:9 source dimensions used to select the camera format.
    /// The recording pipeline may deliberately use a larger matching source
    /// format for a clean, unzoomed live preview, then hardware-scale only the
    /// saved low-resolution movie.
    var captureDimensions: (w: Int, h: Int) {
        switch self {
        case .p2160: return (3840, 2160)
        case .p1080: return (1920, 1080)
        case .p720:  return (1280, 720)
        case .p480:  return (854, 480)
        case .p320:  return (640, 360)
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

enum CameraMode: String, CaseIterable, Identifiable, SettingStorable {
    case video = "VIDEO"
    case photo = "PHOTO"
    case slowMo = "SLO-MO"

    var id: String { rawValue }
    var label: String { rawValue }
}

// MARK: - Volume Button Action

/// What a physical volume-button press does. Kept separate from the fixed
/// per-mode shutter behavior so it's a single, explicit user choice rather
/// than something inferred from `cameraMode` alone.
enum VolumeButtonAction: String, CaseIterable, Identifiable, SettingStorable {
    case shutter, burst, recording

    var id: String { rawValue }

    var label: String {
        switch self {
        case .shutter: return "Shutter"
        case .burst: return "Burst"
        case .recording: return "Recording"
        }
    }

    var detail: String {
        switch self {
        case .shutter: return "Matches the mode — photo tap or record toggle"
        case .burst: return "Always fires a burst of photos"
        case .recording: return "Always starts or stops video recording"
        }
    }
}

// MARK: - Camera Facing (persisted for "Keep Last Camera")

/// Lightweight, `SettingStorable` stand-in for `AVCaptureDevice.Position`
/// (which isn't itself storable) — only the two positions this app ever
/// selects between (front glass has no telephoto/wide choice to persist).
enum CameraFacing: String, CaseIterable, Identifiable, SettingStorable {
    case back, front

    var id: String { rawValue }

    var avPosition: AVCaptureDevice.Position { self == .front ? .front : .back }

    init(_ position: AVCaptureDevice.Position) {
        self = position == .front ? .front : .back
    }
}

// MARK: - Photo Megapixels

enum PhotoMegapixels: Double, CaseIterable, Identifiable, SettingStorable {
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

// MARK: - Burst Mode (Photo 2.0)

/// Number of frames captured in one burst-mode press. Kept small — this is
/// a 2015-class A10 chip with 2 GB RAM; each frame still goes through the
/// same HEIC encode + Photos write as a normal still, so a burst is really
/// N stills fired back-to-back rather than a dedicated high-speed pipeline.
enum BurstCount: Int, CaseIterable, Identifiable, SettingStorable {
    case count5 = 5
    case count10 = 10
    case count15 = 15

    var id: Int { rawValue }
    var label: String { "\(rawValue)" }
}

/// Saved photo file format. HEIC is smaller and is what stock Camera uses;
/// JPEG is offered for maximum compatibility with older apps/services.
enum PhotoFormat: String, CaseIterable, Identifiable, SettingStorable {
    case heic, jpeg

    var id: String { rawValue }

    var label: String {
        switch self {
        case .heic: return "HEIC"
        case .jpeg: return "JPEG"
        }
    }

    var detail: String {
        switch self {
        case .heic: return "Smaller files · matches Camera app"
        case .jpeg: return "Maximum compatibility"
        }
    }
}

/// Photo aspect ratio. `.full` uses the sensor's native still aspect (4:3 on
/// iPhone 7); `.square` crops to 1:1 for the preview grid + saved file.
enum PhotoAspect: String, CaseIterable, Identifiable, SettingStorable {
    case full, square

    var id: String { rawValue }

    var label: String {
        switch self {
        case .full: return "4:3"
        case .square: return "1:1"
        }
    }

    var detail: String {
        switch self {
        case .full: return "Full sensor frame"
        case .square: return "Cropped to a square"
        }
    }
}

// MARK: - Frame rate

enum FrameRate: Int, CaseIterable, Identifiable, SettingStorable {
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

enum SlowMoFrameRate: Int, CaseIterable, Identifiable, SettingStorable {
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

enum Quality: String, CaseIterable, Identifiable, SettingStorable {
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

enum SaveLocation: String, CaseIterable, Identifiable, SettingStorable {
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

enum SplitInterval: String, CaseIterable, Identifiable, SettingStorable {
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

enum CountdownTimer: Int, CaseIterable, Identifiable, SettingStorable {
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

enum MaxDuration: Int, CaseIterable, Identifiable, SettingStorable {
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

enum GridStyle: String, CaseIterable, Identifiable, SettingStorable {
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

    /// One-line description of what this grid does, shown under the picker
    /// in Settings — same idea as `HUDMotion.detail`.
    var detail: String {
        switch self {
        case .off: return "No overlay"
        case .thirds: return "Classic 3×3 composition guide"
        case .crosshair: return "Center cross for symmetry"
        case .square: return "Centered square for framing"
        }
    }
}

// MARK: - HUD Element Visibility

/// One togglable piece of the live camera HUD. Each case maps to exactly
/// one `AppSettings` bool (see the "HUD Customization" block below) — this
/// enum exists purely to drive the Settings UI list in one place, rather
/// than hand-writing a toggle row per element.
///
/// The shutter button and the Settings gear itself are deliberately NOT
/// included here: hiding the shutter would make the app unusable, and
/// hiding the gear would strand the user with no way back into Settings
/// to turn elements back on.
enum HUDElement: String, CaseIterable, Identifiable {
    case flashButton
    case infoPill
    case batteryInfo
    case storageInfo
    case zoomControl
    case modeSelector
    case galleryThumbnail
    case proToolsButton
    case flipCameraButton
    /// Compact "12MP" readout in the pill while in Photo mode.
    case megapixels
    /// "~X h/min" estimate in the pill, derived from free storage — split
    /// out from `storageInfo` so it can be shown/hidden independently.
    case timeRemaining

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flashButton: return "Flash / Torch button"
        case .infoPill: return "Format info pill"
        case .batteryInfo: return "Battery indicator"
        case .storageInfo: return "Storage & time left"
        case .zoomControl: return "Zoom bar"
        case .modeSelector: return "Mode selector"
        case .galleryThumbnail: return "Last shot thumbnail"
        case .proToolsButton: return "Pro Tools (•••) button"
        case .flipCameraButton: return "Flip camera button"
        case .megapixels: return "Megapixel indicator"
        case .timeRemaining: return "Remaining recording time"
        }
    }

    var icon: String {
        switch self {
        case .flashButton: return "bolt.fill"
        case .infoPill: return "capsule.fill"
        case .batteryInfo: return "battery.75"
        case .storageInfo: return "internaldrive"
        case .zoomControl: return "arrow.left.and.right"
        case .modeSelector: return "list.bullet.rectangle"
        case .galleryThumbnail: return "square.stack.3d.up.fill"
        case .proToolsButton: return "ellipsis"
        case .flipCameraButton: return "arrow.triangle.2.circlepath.camera.fill"
        case .megapixels: return "aspectratio"
        case .timeRemaining: return "clock.fill"
        }
    }
}

/// Controls the spring used to animate HUD elements appearing/disappearing
/// (both from the Customizable HUD toggles above and existing conditional
/// chrome like the level meter / notices). `.off` disables the animation
/// entirely — an instant cut, for anyone who finds motion distracting.
enum HUDMotion: String, CaseIterable, Identifiable, SettingStorable {
    case off, subtle, standard, snappy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .subtle: return "Subtle"
        case .standard: return "Standard"
        case .snappy: return "Snappy"
        }
    }

    var detail: String {
        switch self {
        case .off: return "Instant, no animation"
        case .subtle: return "Slow, gentle ease"
        case .standard: return "Balanced default"
        case .snappy: return "Quick, energetic spring"
        }
    }

    /// nil means "no animation" — pass straight to `.animation(_:value:)`.
    var animation: Animation? {
        switch self {
        case .off: return nil
        case .subtle: return .spring(response: 0.5, dampingFraction: 0.92)
        case .standard: return .spring(response: 0.35, dampingFraction: 0.82)
        case .snappy: return .spring(response: 0.22, dampingFraction: 0.7)
        }
    }

    /// Matching transition for HUD elements that pop in/out entirely
    /// (rather than just resizing), scaled by the same motion preference.
    var transition: AnyTransition {
        switch self {
        case .off: return .identity
        default: return .opacity.combined(with: .scale(scale: 0.85))
        }
    }
}

// MARK: - Haptic Intensity

/// Scales the impact-haptic strength used across the app (shutter, record
/// start/stop, countdown ticks) relative to each event's normal ("standard")
/// weight. Selection haptics (mode/chip taps) are left as-is — iOS doesn't
/// expose an intensity knob for those.
enum HapticIntensity: String, CaseIterable, Identifiable, SettingStorable {
    case light, standard, strong

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return "Light"
        case .standard: return "Standard"
        case .strong: return "Strong"
        }
    }

    var detail: String {
        switch self {
        case .light: return "Softer taps"
        case .standard: return "Default feel"
        case .strong: return "More pronounced taps"
        }
    }

    /// Re-scales a base impact style (as originally hand-tuned per event)
    /// to this intensity level.
    func scaled(_ base: UIImpactFeedbackGenerator.FeedbackStyle) -> UIImpactFeedbackGenerator.FeedbackStyle {
        switch (self, base) {
        case (.light, .heavy):  return .medium
        case (.light, .medium): return .light
        case (.strong, .light): return .medium
        case (.strong, .medium): return .heavy
        default: return base
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

enum WhiteBalancePreset: String, CaseIterable, Identifiable, SettingStorable {
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
// 1. If it's backed by a new enum, make it `RawRepresentable` with a
//    String/Int/Double raw value and add `SettingStorable` to its
//    conformance list (see e.g. `enum Quality: String, ..., SettingStorable`
//    above). Bool/Int/Float/Double/String settings need nothing extra.
// 2. Add ONE line below:
//        @Setting("yourSetting") var yourSetting: T = defaultValue
//    That's it for persistence — no `didSet`, no separate init-loader line.
//    See SettingStorage.swift for how `@Setting` works.
// 3. Expose it in the UI:
//    - Settings screen: add one `SettingsToggleSpec` (for a Bool) to the
//      relevant array in SettingsScreen.swift, e.g. `assistToggles`, or use
//      `SettingsPickerRow` directly for a `CaseIterable` enum setting.
//      See SettingsRowKit.swift for both.
//    - Pro Tools drawer: add one `ProToolControl` case (`.toggle`, `.chips`,
//      `.slider`, or `.navigation`) to `proToolsDrawerControls` in
//      CameraScreen.swift. See ProToolsControls.swift.
// No other file needs to change — both UIs render from these declarative
// lists rather than needing a new hand-built row per setting.
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    private let store = UserDefaults.standard

    // First-launch defaults: 1080p · 30 fps · High · Photos · split/auto-stop off,
    // stabilisation on, grid/level/dim/longevity off, sounds & haptics on.
    @Setting("cameraMode") var cameraMode: CameraMode = .video
    @Setting("slowMoFrameRate") var slowMoFrameRate: SlowMoFrameRate = .fps120
    @Setting("slowMoResolution") var slowMoResolution: Resolution = .p1080
    @Setting("resolution") var resolution: Resolution = .p1080
    @Setting("quality") var quality: Quality = .high
    @Setting("frameRate") var frameRate: FrameRate = .fps30
    @Setting("saveLocation") var saveLocation: SaveLocation = .photos
    @Setting("splitInterval") var splitInterval: SplitInterval = .off
    @Setting("countdownTimer") var countdownTimer: CountdownTimer = .off
    @Setting("maxDuration") var maxDuration: MaxDuration = .off
    @Setting("gridStyle") var gridStyle: GridStyle = .off
    @Setting("showLevelGauge") var showLevelGauge: Bool = false
    @Setting("exposureBias") var exposureBias: Float = 0.0
    @Setting("whiteBalance") var whiteBalance: WhiteBalancePreset = .auto
    @Setting("torchBrightness") var torchBrightness: Float = 1.0
    @Setting("lowTorch") var lowTorch: Bool = false
    // Always on — mute option removed, but this can still be flipped back on
    // at runtime by CameraSession as a safety net (see setupAudioIfNeeded).
    @Setting("recordAudio") var recordAudio: Bool = true
    @Setting("stabilization") var stabilization: Bool = true
    @Setting("useHEVC") var useHEVC: Bool = true
    @Setting("autoDimOnRecord") var autoDimOnRecord: Bool = false
    /// 📊 Opt-in live stats readout (measured fps / bitrate / drop rate)
    /// during recording. Off by default so the HUD layout for everyone
    /// else stays exactly as it was.
    @Setting("showRecordingStats") var showRecordingStats: Bool = false
    // Default appearance is Dial Lavender. A legacy "mint" value (Lens Mint,
    // now removed) simply fails to parse and falls back to this default —
    // no special-case migration code needed.
    @Setting("accentColor") var accentColor: AccentColor = .violet
    @Setting("shutterSoundEnabled") var shutterSoundEnabled: Bool = true
    @Setting("photoMegapixels") var photoMegapixels: PhotoMegapixels = .mp12
    @Setting("saveSelfiesUnmirrored") var saveSelfiesUnmirrored: Bool = false
    // MARK: Photo 2.0
    /// Number of frames captured while the shutter is held in burst mode.
    @Setting("burstCount") var burstCount: BurstCount = .count10
    /// Saved still-photo file format (HEIC vs JPEG).
    @Setting("photoFormat") var photoFormat: PhotoFormat = .heic
    /// Saved/previewed still-photo aspect ratio.
    @Setting("photoAspect") var photoAspect: PhotoAspect = .full
    /// Shows the full-screen review sheet immediately after a photo/burst
    /// finishes capturing, mirroring stock Camera's post-shutter review.
    @Setting("photoReviewAfterCapture") var photoReviewAfterCapture: Bool = false
    // Screen-flash confirmation removed from Settings UI; key kept only so
    // upgrading users' old value still applies (see CameraScreen.swift).
    @Setting("captureFlashConfirmation") var captureFlashConfirmation: Bool = false
    @Setting("hapticFeedbackEnabled") var hapticFeedbackEnabled: Bool = true
    /// Longevity Mode prioritises battery life, lower heat, and smaller files
    /// on older devices (especially iPhone 7 / A10). When enabled it gently
    /// steers the encoder toward safer settings and strengthens auto-dim.
    @Setting("longevityMode") var longevityMode: Bool = false
    /// What a physical volume-button press does. Defaults to matching the
    /// current mode (photo tap / video record toggle) — the pre-existing
    /// behavior — so upgrading users see no change until they opt into
    /// Burst or Recording explicitly.
    @Setting("volumeButtonAction") var volumeButtonAction: VolumeButtonAction = .shutter
    /// When on, the app reopens on whichever camera (front/rear) was active
    /// last time, instead of always resetting to the rear camera.
    @Setting("keepLastCamera") var keepLastCamera: Bool = false
    /// Last camera facing used, kept up to date on every flip regardless of
    /// `keepLastCamera` so the value is ready the moment the toggle is
    /// turned on — only *applied* at launch when that toggle is enabled.
    @Setting("lastCameraPosition") var lastCameraPosition: CameraFacing = .back

    // MARK: HUD Customization
    // Per-element visibility toggles for the live camera HUD. The shutter
    // and Settings gear are intentionally not toggleable here — see
    // `HUDElement`'s doc comment.
    @Setting("hudShowFlashButton") var hudShowFlashButton: Bool = true
    @Setting("hudShowInfoPill") var hudShowInfoPill: Bool = true
    @Setting("hudShowBatteryInfo") var hudShowBatteryInfo: Bool = true
    @Setting("hudShowStorageInfo") var hudShowStorageInfo: Bool = true
    @Setting("hudShowZoomControl") var hudShowZoomControl: Bool = true
    @Setting("hudShowModeSelector") var hudShowModeSelector: Bool = true
    @Setting("hudShowGalleryThumbnail") var hudShowGalleryThumbnail: Bool = true
    @Setting("hudShowProToolsButton") var hudShowProToolsButton: Bool = true
    @Setting("hudShowFlipCameraButton") var hudShowFlipCameraButton: Bool = true
    /// Compact "12MP" readout in the info pill while in Photo mode. Off by
    /// default, same spirit as `showRecordingStats` — purely opt-in chrome.
    @Setting("hudShowMegapixels") var hudShowMegapixels: Bool = false
    /// "~X h/min left" estimate in the info pill, derived from free space.
    /// On by default — this is the pre-existing behavior, just now a
    /// dedicated toggle instead of being bundled into storageInfo.
    @Setting("hudShowTimeRemaining") var hudShowTimeRemaining: Bool = true
    /// Spring style used to animate HUD elements showing/hiding.
    @Setting("hudMotion") var hudMotion: HUDMotion = .standard
    /// Relative strength of impact haptics (shutter, record start/stop, countdown).
    @Setting("hapticIntensity") var hapticIntensity: HapticIntensity = .standard
    /// 6-digit RGB hex (no '#') for the user-picked custom accent color,
    /// used only when `accentColor == .custom`.
    @Setting("customAccentColorHex") var customAccentColorHex: String = "C4A8E8"

    /// Convenience accessor for a `HUDElement`'s current visibility.
    func isHUDElementVisible(_ element: HUDElement) -> Bool {
        switch element {
        case .flashButton: return hudShowFlashButton
        case .infoPill: return hudShowInfoPill
        case .batteryInfo: return hudShowBatteryInfo
        case .storageInfo: return hudShowStorageInfo
        case .zoomControl: return hudShowZoomControl
        case .modeSelector: return hudShowModeSelector
        case .galleryThumbnail: return hudShowGalleryThumbnail
        case .proToolsButton: return hudShowProToolsButton
        case .flipCameraButton: return hudShowFlipCameraButton
        case .megapixels: return hudShowMegapixels
        case .timeRemaining: return hudShowTimeRemaining
        }
    }

    /// Binding into the right bool for a given `HUDElement`, for building
    /// `SettingsToggleSpec`s generically in the Settings UI.
    func binding(for element: HUDElement) -> Binding<Bool> {
        switch element {
        case .flashButton: return Binding(get: { self.hudShowFlashButton }, set: { self.hudShowFlashButton = $0 })
        case .infoPill: return Binding(get: { self.hudShowInfoPill }, set: { self.hudShowInfoPill = $0 })
        case .batteryInfo: return Binding(get: { self.hudShowBatteryInfo }, set: { self.hudShowBatteryInfo = $0 })
        case .storageInfo: return Binding(get: { self.hudShowStorageInfo }, set: { self.hudShowStorageInfo = $0 })
        case .zoomControl: return Binding(get: { self.hudShowZoomControl }, set: { self.hudShowZoomControl = $0 })
        case .modeSelector: return Binding(get: { self.hudShowModeSelector }, set: { self.hudShowModeSelector = $0 })
        case .galleryThumbnail: return Binding(get: { self.hudShowGalleryThumbnail }, set: { self.hudShowGalleryThumbnail = $0 })
        case .proToolsButton: return Binding(get: { self.hudShowProToolsButton }, set: { self.hudShowProToolsButton = $0 })
        case .flipCameraButton: return Binding(get: { self.hudShowFlipCameraButton }, set: { self.hudShowFlipCameraButton = $0 })
        case .megapixels: return Binding(get: { self.hudShowMegapixels }, set: { self.hudShowMegapixels = $0 })
        case .timeRemaining: return Binding(get: { self.hudShowTimeRemaining }, set: { self.hudShowTimeRemaining = $0 })
        }
    }

    /// Custom accent color parsed from `customAccentColorHex`, plus derived
    /// bright/deep variants matching how the built-in presets each hand-tune
    /// their own bright/deep pair (see `AccentColor`).
    var customColor: Color { Color(hexString: customAccentColorHex) }
    var customColorBright: Color { customColor.brightnessScaled(1.3) }
    var customColorDeep: Color { customColor.brightnessScaled(0.68) }

    /// Applies a capture preset. Forces video mode for recording-oriented presets.
    func applyPreset(_ preset: CapturePreset) {
        cameraMode = .video
        resolution = preset.resolution
        quality = preset.quality
        frameRate = preset.frameRate
        useHEVC = preset.useHEVC
    }

    private init() {
        // One-off migration: `gridStyle` replaced the old plain `showGrid`
        // bool. Only needed here because it seeds a *different* setting's
        // key than the one it reads — @Setting can't express that generically.
        // Guarded so it only ever fires once: after this runs, "gridStyle"
        // exists in `store` and this block is skipped on every later launch.
        if store.string(forKey: "gridStyle") == nil,
           store.object(forKey: "showGrid") as? Bool == true {
            gridStyle = .thirds
        }
    }
}

// MARK: - Accent Colour

enum AccentColor: String, CaseIterable, Identifiable, SettingStorable {
    case violet, amber, red, ice, aurora, coral, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .violet: return "Dial Lavender"
        case .amber: return "Button Gold"
        case .red: return "Record Red"
        case .ice: return "Ice Cyan"
        case .aurora: return "Aurora"
        case .coral: return "Coral Bloom"
        case .custom: return "Custom"
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
        // `.custom` has no case-local storage (enums can't hold external
        // state), so it reads from the shared settings singleton — the
        // same pattern used everywhere else a static context needs the
        // live setting (see PerformanceProfile).
        case .custom: return AppSettings.shared.customColor
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
        case .custom: return AppSettings.shared.customColorBright
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
        case .custom: return AppSettings.shared.customColorDeep
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
        // a hard 0.78× made footage look muddy. See PerformanceProfile.swift
        // for the actual multiplier — this is the one place all of Longevity
        // Mode's throttling knobs live now, not just this bitrate cut.
        let profile = PerformanceProfile.current(settings: settings)
        if !isSlow {
            kbps *= profile.videoBitrateMultiplier
        }

        // GOP length. Slow-mo needs more frequent I-frames so motion stays
        // sharp when played back at 1/4–1/8 speed; a 4–6 s GOP at 240 fps
        // is nearly a thousand frames between keyframes and looks soft.
        var gopSeconds = keyFrameSeconds[settings.quality] ?? 4
        if res == .p2160 { gopSeconds = max(gopSeconds, 5) }
        if isSlow {
            gopSeconds = min(gopSeconds, 2)   // ≤2 s between I-frames
        }
        if !isSlow {
            gopSeconds = max(gopSeconds, profile.minKeyFrameSeconds)
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
