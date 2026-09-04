//
//  CameraPreview.swift
//  LowPolyCam
//
//  Updated for iOS 27 / Xcode 27 / Swift 6.4.
//  Swift 6 complete concurrency · Observation · Liquid Glass · RotationCoordinator
//

import SwiftUI
import AVFoundation

/// Live viewfinder. Orientation is driven by `AVCaptureDevice.RotationCoordinator`
/// (the iOS 17+ replacement for the deprecated `videoOrientation` property).
final class PreviewView: UIView {

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    var onTap: ((CGPoint, CGPoint) -> Void)?
    var onDoubleTap: (() -> Void)?
    var onLongPress: ((CGPoint, CGPoint) -> Void)?
    var onTwoFingerLongPress: ((CGPoint, CGPoint) -> Void)?

    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attachRotationCoordinator(for device: AVCaptureDevice?) {
        rotationObservation?.invalidate()
        rotationObservation = nil
        rotationCoordinator = nil
        guard let device else { return }

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        applyPreviewRotation()
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] coord, _ in
            let angle = coord.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor in
                self?.apply(videoRotationAngle: angle)
            }
        }
    }

    func applyPreviewRotation() {
        guard let coordinator = rotationCoordinator else { return }
        apply(videoRotationAngle: coordinator.videoRotationAngleForHorizonLevelPreview)
    }

    private func apply(videoRotationAngle angle: CGFloat) {
        guard let connection = previewLayer.connection else { return }
        guard connection.isVideoRotationAngleSupported(angle) else { return }
        if connection.videoRotationAngle != angle {
            connection.videoRotationAngle = angle
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
        applyPreviewRotation()
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
        view.attachRotationCoordinator(for: currentDevice)
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
        uiView.attachRotationCoordinator(for: currentDevice)
        uiView.setNeedsLayout()
    }

    private var currentDevice: AVCaptureDevice? {
        session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device }.first
    }
}
