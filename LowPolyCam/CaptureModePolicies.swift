//
//  CaptureModePolicies.swift
//  LowPolyCam
//
//  Updated for iOS 27 / Xcode 27 / Swift 6.4.
//  Swift 6 complete concurrency · Observation · Liquid Glass · RotationCoordinator
//

import AVFoundation
import Foundation

/// High-level capture mode. Maps to the three user-facing camera modes and
/// drives format selection + recording behaviour without mixing the pipelines.
enum CaptureModePolicy: Sendable {
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
struct CaptureFormatRequest: Sendable {
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
            // Full-resolution still format is selected only at shutter time.
            // The viewfinder must use a sharp video-sized format.
            return CameraFormatSelector.bestVideoFormat(
                for: device, width: request.width, height: request.height, fps: request.fps
            )
        case .video:
            return CameraFormatSelector.bestVideoFormat(
                for: device, width: request.width, height: request.height, fps: request.fps
            )
        case .slowMo:
            // Do not silently choose any high-FPS format here. The caller can
            // then resolve/publish the actual lower resolution instead of
            // upscaling a smaller sensor stream into the requested output.
            return CameraFormatSelector.bestSlowMoAwareFormat(
                for: device, width: request.width, height: request.height, fps: request.fps
            )
        }
    }

    /// Format used only for the moment of still capture (iOS 15 high-res path).
    static func selectPhotoStillFormat(device: AVCaptureDevice, maxPreviewHeight: Int = 1080, fps: Double = 30) -> AVCaptureDevice.Format? {
        CameraFormatSelector.bestPhotoStillFormat(for: device, maxPreviewHeight: maxPreviewHeight, fps: fps)
    }
}
