//
//  PerformanceProfile.swift
//  LowPolyCam
//
//  Updated for iOS 27 / Xcode 27 / Swift 6.4.
//  Swift 6 complete concurrency · Observation · Liquid Glass · RotationCoordinator
//

import Foundation

// MARK: - Performance / Longevity system
//
// WHY THIS FILE EXISTS
// ---------------------
// Before this file, "should we go easier on the hardware right now?" was
// answered independently in four different places, each re-deriving its
// own version of the same inputs:
//
//   - CameraSession.applyActiveFormat: `forceLowestIdlePreview ||
//     settings.longevityMode`, with the 720p/15fps/24fps numbers inlined.
//   - CameraRecorder.startMotionUpdates / refreshMotionUpdateRate: only
//     looked at `settings.showLevelGauge` — Longevity Mode had NO effect
//     on CoreMotion power draw at all, even though it runs continuously
//     the whole time the camera is open.
//   - Settings.swift's `Encoder.plan(for:)`: its own `settings.longevityMode
//     && !isSlow` checks with the 0.78 bitrate cut and 6s GOP floor inlined.
//   - Settings.swift's dead `DeviceTier.isLowMemoryDevice` and Theme.swift's
//     `usesLightweightMaterial` were two separate copies of the exact same
//     `physicalMemory <= 2_500_000_000` check.
//
// `PerformanceProfile` is the one place all of that lives now. Every site
// above reads its answer from a `PerformanceProfile` instead of
// re-deriving it, so tuning "how aggressive Longevity Mode is" (or adding
// a new throttling knob) means touching this file, not hunting through
// four others.
//
// HOW TO ADD A NEW THROTTLING KNOB
// -----------------------------------
// 1. Add one property or method here, with a doc comment explaining what
//    it trades off and which inputs (`tier` / `thermalState` /
//    `longevityEnabled`) drive it.
// 2. At the call site, get a profile via `PerformanceProfile.current(...)`
//    and read the new property instead of re-checking `settings.longevityMode`
//    or `ProcessInfo` directly.

/// Everything currently known about how hard the app should be leaning on
/// the hardware: the device's own ceiling, live thermal pressure, and the
/// user's own Longevity Mode preference. Build one via `.current(...)`.
struct PerformanceProfile {

    /// Coarse hardware bucket. `.constrained` covers iPhone 7/7 Plus-class
    /// devices (A10, ≤2GB RAM) — the hardware this app is explicitly tuned
    /// for — where every throttling knob below matters most.
    enum DeviceTier: Equatable {
        case constrained
        case standard
        case modern

        /// The single source of truth for "is this a low-memory / A10-class
        /// device?" — everything else in the app should read this instead
        /// of checking `ProcessInfo.processInfo.physicalMemory` itself.
        static var current: DeviceTier {
            let mem = ProcessInfo.processInfo.physicalMemory
            if mem <= 2_500_000_000 { return .constrained }
            if mem <= 6_000_000_000 { return .standard }
            return .modern
        }
    }

    let tier: DeviceTier
    let thermalState: ProcessInfo.ThermalState
    let longevityEnabled: Bool

    /// Builds a profile from live state. `thermalState` defaults to
    /// `.nominal` for call sites (like encode-plan bitrate math) that don't
    /// have — and don't need — live thermal data; thermal throttling only
    /// ever touches the idle preview, never an in-progress recording.
    static func current(settings: AppSettings, thermalState: ProcessInfo.ThermalState = .nominal) -> PerformanceProfile {
        PerformanceProfile(tier: .current, thermalState: thermalState, longevityEnabled: settings.longevityMode)
    }

    // MARK: Idle preview
    //
    // While not recording, the preview can run at a lighter format than
    // whatever's about to be recorded — nobody's judging preview quality
    // the way they'd judge the actual footage. `forceLowest` is the
    // thermal-critical override: it always wins over Longevity Mode's
    // softer cap because it means the device needs relief *right now*.

    /// Resolution + frame-rate cap for the idle (non-recording) preview.
    /// `resolution == nil` means "no cap — match the recording format".
    func idlePreviewCap(forceLowest: Bool) -> (resolution: Resolution?, fps: Double) {
        if forceLowest {
            return (.p720, 15.0)
        }
        if longevityEnabled {
            return (.p720, 24.0)
        }
        if tier == .constrained {
            // Gentle baseline even with Longevity Mode off: on A10-class
            // hardware there's no visible benefit to an idle preview above
            // 30fps (nobody's scrutinizing the live view), so this quietly
            // saves ISP/encoder heat whenever frameRate is set to 60fps —
            // full resolution and fps are still used the moment Record is
            // pressed.
            return (nil, 30.0)
        }
        return (nil, .infinity)
    }

    // MARK: CoreMotion
    //
    // The level gauge needs a visibly smooth rate when it's on screen;
    // otherwise 1-2Hz is plenty for orientation (upright photos + UI
    // rotation). CoreMotion polling is a small but *constant* power draw —
    // it runs the whole time the camera is open, not just while recording —
    // so Longevity Mode trims it further in both cases.

    /// CoreMotion `deviceMotionUpdateInterval` rate, in Hz.
    func motionUpdateHz(gaugeVisible: Bool) -> Double {
        if gaugeVisible {
            return longevityEnabled ? 4.0 : 6.0
        } else {
            return longevityEnabled ? 1.0 : 2.0
        }
    }

    // MARK: Encoding
    //
    // Longevity Mode only — thermal state intentionally never touches an
    // in-progress recording's bitrate/GOP (would mean reconfiguring the
    // AVAssetWriter mid-clip). See CameraRecorder.applyThermalState.

    /// Multiplies the computed video bitrate for normal (non-slow-mo) video.
    var videoBitrateMultiplier: Double {
        longevityEnabled ? 0.78 : 1.0
    }

    /// Floor for the keyframe interval, in seconds, for normal video.
    /// `0` means "no floor — use the quality preset's own GOP length".
    /// A longer GOP is a little heavier to scrub through but noticeably
    /// lighter on the encoder.
    var minKeyFrameSeconds: Int {
        longevityEnabled ? 6 : 0
    }

    // MARK: UI behaviour

    /// Seconds of recording before Auto-Dim kicks in, when the user has
    /// Auto-Dim enabled. The screen is one of the largest power draws
    /// during a long take, so Longevity Mode dims sooner.
    var autoDimDelaySeconds: Double {
        longevityEnabled ? 5 : 10
    }
}
