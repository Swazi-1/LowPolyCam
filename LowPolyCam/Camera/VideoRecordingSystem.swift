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
    static let recordStartWarmupFrameCeiling = 14

    /// Whether the active settings request the slow-motion path.
    static func isSlowMo(settings: AppSettings, lensSupportsSlowMo: Bool) -> Bool {
        settings.cameraMode == .slowMo && lensSupportsSlowMo
    }
}
