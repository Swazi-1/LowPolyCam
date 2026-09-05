//
//  CameraPreview.swift
//  LowPolyCam
//
//  Modern horizon-level camera preview.
//

import SwiftUI
import AVFoundation

/// Live viewfinder driven by AVFoundation's rotation coordinator. It keeps
/// preview rotation off the pixel-buffer recording path, where rotating every
/// 240fps frame would waste hardware bandwidth.
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

    func updateRotationCoordinator() {
        guard let input = previewLayer.session?.inputs
            .compactMap({ $0 as? AVCaptureDeviceInput })
            .first(where: { $0.device.hasMediaType(.video) }) else { return }

        if let coordinator = rotationCoordinator, coordinator.device?.uniqueID == input.device.uniqueID {
            // The same device may have a new connection after graph recovery.
            if let connection = previewLayer.connection,
               connection.isVideoRotationAngleSupported(coordinator.videoRotationAngleForHorizonLevelPreview) {
                connection.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
            }
            return
        }
        rotationObservation?.invalidate()

        let coordinator = AVCaptureDevice.RotationCoordinator(
            device: input.device,
            previewLayer: previewLayer
        )
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak self] coordinator, _ in
            guard let self,
                  let connection = self.previewLayer.connection else { return }
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
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
        updateRotationCoordinator()
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
        view.updateRotationCoordinator()
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
        uiView.updateRotationCoordinator()
        uiView.setNeedsLayout()
    }
}
