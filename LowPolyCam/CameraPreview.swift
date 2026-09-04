//
//  CameraPreview.swift
//  LowPolyCam
//
//  iOS 15-compatible camera preview.
//

import SwiftUI
import AVFoundation

/// Live viewfinder. Uses the iOS 15 `videoOrientation` API instead of the
/// iOS 17+ `AVCaptureDevice.RotationCoordinator`, preserving the project's
/// iPhone 7 / iOS 15 deployment target.
final class PreviewView: UIView {

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    var onTap: ((CGPoint, CGPoint) -> Void)?
    var onDoubleTap: (() -> Void)?
    var onLongPress: ((CGPoint, CGPoint) -> Void)?
    var onTwoFingerLongPress: ((CGPoint, CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        longPress.minimumPressDuration = 0.45
        longPress.numberOfTouchesRequired = 1
        singleTap.require(toFail: longPress)

        let twoFingerLongPress = UILongPressGestureRecognizer(target: self, action: #selector(handleTwoFingerLongPress))
        twoFingerLongPress.minimumPressDuration = 0.45
        twoFingerLongPress.numberOfTouchesRequired = 2

        addGestureRecognizer(singleTap)
        addGestureRecognizer(doubleTap)
        addGestureRecognizer(longPress)
        addGestureRecognizer(twoFingerLongPress)

        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        applyPreviewOrientation()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    @objc private func deviceOrientationDidChange() {
        applyPreviewOrientation()
    }

    func applyPreviewOrientation() {
        guard let connection = previewLayer.connection, connection.isVideoOrientationSupported else { return }
        switch UIDevice.current.orientation {
        case .portrait:
            connection.videoOrientation = .portrait
        case .portraitUpsideDown:
            connection.videoOrientation = .portraitUpsideDown
        case .landscapeLeft:
            // Device orientation is from the user's perspective; the video
            // connection uses the camera's perspective, so these are swapped.
            connection.videoOrientation = .landscapeRight
        case .landscapeRight:
            connection.videoOrientation = .landscapeLeft
        default:
            break
        }
    }

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        let viewPoint = gesture.location(in: self)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint)
        onTap?(devicePoint, viewPoint)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        onDoubleTap?()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let viewPoint = gesture.location(in: self)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint)
        onLongPress?(devicePoint, viewPoint)
    }

    @objc private func handleTwoFingerLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let viewPoint = gesture.location(in: self)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint)
        onTwoFingerLongPress?(devicePoint, viewPoint)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyPreviewOrientation()
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var onTap: ((CGPoint, CGPoint) -> Void)? = nil
    var onDoubleTap: (() -> Void)? = nil
    var onLongPress: ((CGPoint, CGPoint) -> Void)? = nil
    var onTwoFingerLongPress: ((CGPoint, CGPoint) -> Void)? = nil

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onTap = onTap
        view.onDoubleTap = onDoubleTap
        view.onLongPress = onLongPress
        view.onTwoFingerLongPress = onTwoFingerLongPress
        view.applyPreviewOrientation()
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        uiView.onTap = onTap
        uiView.onDoubleTap = onDoubleTap
        uiView.onLongPress = onLongPress
        uiView.onTwoFingerLongPress = onTwoFingerLongPress
        uiView.applyPreviewOrientation()
        uiView.setNeedsLayout()
    }
}
