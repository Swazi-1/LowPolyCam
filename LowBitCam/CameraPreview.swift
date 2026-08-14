import SwiftUI
import AVFoundation

final class PreviewView: UIView {

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let c = previewLayer.connection, c.isVideoOrientationSupported else { return }
        // AVCaptureVideoOrientation and UIInterfaceOrientation share raw values.
        let o = window?.windowScene?.interfaceOrientation ?? .portrait
        if let v = AVCaptureVideoOrientation(rawValue: o.rawValue) {
            c.videoOrientation = v
        }
    }
}

struct CameraPreview: UIViewRepresentable {

    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        uiView.setNeedsLayout()
    }
}
