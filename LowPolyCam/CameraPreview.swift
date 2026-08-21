import SwiftUI
import AVFoundation

final class PreviewView: UIView {

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    var onTap: ((CGPoint, CGPoint) -> Void)?
    var onDoubleTap: (() -> Void)?
    /// One-finger tap-and-hold — used for Focus Lock.
    var onLongPress: ((CGPoint, CGPoint) -> Void)?
    /// Two-finger tap-and-hold — used for Exposure Lock, kept as a
    /// separate gesture so the two locks can be set independently.
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
        // Don't let a long-press-in-progress also fire as a plain tap once
        // the finger lifts — the two moments should map to two different
        // actions (focus+expose vs. lock focus), not both.
        singleTap.require(toFail: longPress)

        let twoFingerLongPress = UILongPressGestureRecognizer(target: self, action: #selector(handleTwoFingerLongPress))
        twoFingerLongPress.minimumPressDuration = 0.45
        twoFingerLongPress.numberOfTouchesRequired = 2

        addGestureRecognizer(singleTap)
        addGestureRecognizer(doubleTap)
        addGestureRecognizer(longPress)
        addGestureRecognizer(twoFingerLongPress)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        guard let c = previewLayer.connection, c.isVideoOrientationSupported else { return }
        let o = window?.windowScene?.interfaceOrientation ?? .portrait
        if let v = AVCaptureVideoOrientation(rawValue: o.rawValue), c.videoOrientation != v {
            c.videoOrientation = v
        }
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
        uiView.setNeedsLayout()
    }
}
