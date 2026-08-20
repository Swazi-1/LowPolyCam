import AVFoundation
import Foundation

/// Shared tunables and notes for the **Video** and **Slow-Mo** recording pipeline.
///
/// Today the live AVAssetWriter / sample-buffer path still lives on
/// `CameraRecorder` (startRecording / stopRecording / segments / didOutput).
/// Format selection for each mode is already isolated:
/// - Video  → `CaptureModePolicy.video`  → `CameraFormatSelector.bestVideoFormat`
/// - Slow-Mo → `CaptureModePolicy.slowMo` → `CameraFormatSelector.bestSlowMo*`
///
/// Photo does **not** use this pipeline — see `PhotoCaptureSystem`.
///
/// v3.2.x plan: move writer state, segment rolling, and sample-buffer
/// handling into this type so CameraRecorder stays a thin coordinator.
enum VideoRecordingSystem {

    /// Fragment interval written into each MOV (rolling fragments reduce loss).
    static let fragmentSeconds: Double = 4

    /// Stop recording when free space falls below this reserve.
    static let reserveBytes: Int64 = 300 * 1024 * 1024

    /// Seconds of video frames to discard after a format switch at record start
    /// (covers AE/AGC brightness ramp on older silicon).
    static let recordStartWarmupSeconds: Double = 0.15
    static let recordStartWarmupFrameFloor = 2
    /// This used to be a flat 14-frame cap, which is fine at 30/60fps (≈0.23–0.47s)
    /// but silently truncated the 0.15s warmup target at 120/240fps — 14 frames is
    /// only ~58ms at 240fps, well short of the AE/AGC ramp time, which is exactly
    /// why slow-mo clips showed a few dark frames at the very start. The ceiling
    /// now scales with fps so it still bounds discarded frames to roughly the same
    /// *wall-clock* warmup window at any frame rate, instead of a fixed frame count.
    static func recordStartWarmupFrameCeiling(fps: Int) -> Int {
        let scaled = Int((recordStartWarmupSeconds * 1.6 * Double(max(fps, 1))).rounded(.up))
        return max(14, scaled)
    }

    /// Whether the active settings request the slow-motion path.
    static func isSlowMo(settings: AppSettings, lensSupportsSlowMo: Bool) -> Bool {
        settings.cameraMode == .slowMo && lensSupportsSlowMo
    }
}
