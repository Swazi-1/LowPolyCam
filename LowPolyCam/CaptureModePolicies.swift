import AVFoundation
import Foundation

/// High-level capture mode. Maps to the three user-facing camera modes and
/// drives format selection + recording behaviour without mixing the pipelines.
enum CaptureModePolicy {
    case photo
    case video
    case slowMo

    init(cameraMode: CameraMode) {
        switch cameraMode {
        case .photo:  self = .photo
        case .video:  self = .video
        case .slowMo: self = .slowMo
        }
    }
}

/// Target sensor size + fps for a given mode. Pure data — no session mutation.
struct CaptureFormatRequest {
    let width: Int
    let height: Int
    let fps: Double
    let policy: CaptureModePolicy
}

/// Picks the right AVCaptureDevice.Format for the active capture mode.
/// Video / Slow-Mo / Photo stay on separate code paths so changes to one
/// mode do not affect the others.
enum CaptureModeFormatRouter {

    static func selectFormat(device: AVCaptureDevice, request: CaptureFormatRequest) -> AVCaptureDevice.Format? {
        switch request.policy {
        case .photo:
            // Live preview stays on a smooth video-sized format; full 12MP
            // stills are obtained by a brief swap inside photo capture.
            return CameraFormatSelector.bestVideoFormat(
                for: device, width: request.width, height: request.height, fps: request.fps
            )
        case .video:
            return CameraFormatSelector.bestVideoFormat(
                for: device, width: request.width, height: request.height, fps: request.fps
            )
        case .slowMo:
            return CameraFormatSelector.bestSlowMoAwareFormat(
                for: device, width: request.width, height: request.height, fps: request.fps
            ) ?? CameraFormatSelector.bestSlowMoFormat(for: device, fps: request.fps)
        }
    }

    /// Format used only for the moment of still capture (iOS 15 high-res path).
    static func selectPhotoStillFormat(device: AVCaptureDevice, maxPreviewHeight: Int = 1080, fps: Double = 30) -> AVCaptureDevice.Format? {
        CameraFormatSelector.bestPhotoStillFormat(for: device, maxPreviewHeight: maxPreviewHeight, fps: fps)
    }
}
