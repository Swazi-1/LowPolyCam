import AVFoundation
import QuartzCore
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    @Environment(\.cameraTint) private var theme
    let session: AVCaptureSession
    let isFocusExposureLocked: Bool
    let focusExposureLockLabel: String
    let stabilizationEnabled: Bool
    let isPreviewTransitioning: Bool
    let reservesTopHUDSpace: Bool
    var fitsPhoto = false
    let onTapToFocus: (CGPoint) -> Void
    let onLongPressToLock: (CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        configure(view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session { uiView.previewLayer.session = session }
        configure(uiView)
        guard !isPreviewTransitioning else { return }
        uiView.updateRotation()
    }

    private func configure(_ view: PreviewView) {
        view.setReservesTopHUDSpace(reservesTopHUDSpace)
        view.setPreviewTransitioning(isPreviewTransitioning)
        guard !isPreviewTransitioning else { return }
        let gravity: AVLayerVideoGravity = fitsPhoto ? .resizeAspect : .resizeAspectFill
        if view.previewLayer.videoGravity != gravity { view.previewLayer.videoGravity = gravity }
        view.tintColor = UIColor(theme)
        view.onTapToFocus = onTapToFocus
        view.onLongPressToLock = onLongPressToLock
        view.setFocusExposureLocked(isFocusExposureLocked, label: focusExposureLockLabel)
        view.setStabilizationEnabled(stabilizationEnabled)
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    var onTapToFocus: ((CGPoint) -> Void)?
    var onLongPressToLock: ((CGPoint) -> Void)?

    private let focusIndicator = UIView()
    private let lockLabel = UILabel()
    private var hideFocusWorkItem: DispatchWorkItem?
    private var focusExposureLocked = false
    private var reservesTopHUDSpace = false
    private var stabilizationEnabled = true
    private var transitionSnapshot: UIView?
    private var transitionBlurView: UIVisualEffectView?
    private var transitionDimView: UIView?
    private var transitionRevealWorkItem: DispatchWorkItem?
    private var previewTransitioning = false
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationDeviceID: String?
    private weak var rotationConnection: AVCaptureConnection?
    private var lastAppliedRotationAngle: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspectFill
        configureOverlays()
        configureGestures()
    }

    required init?(coder: NSCoder) { nil }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        focusIndicator.layer.borderColor = tintColor.cgColor
        lockLabel.textColor = tintColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !previewTransitioning {
            enableStabilizationIfAvailable()
            updateRotation()
        }
        transitionSnapshot?.frame = bounds
        transitionBlurView?.frame = bounds
        transitionDimView?.frame = bounds

        lockLabel.sizeToFit()
        // The SwiftUI HUD is above this UIKit preview. Reserve enough room for its largest
        // two-line layout so the fixed AE/AF lock pill never sits underneath it.
        let lockLabelTop = safeAreaInsets.top + (reservesTopHUDSpace ? 82 : 54)
        lockLabel.frame = CGRect(
            x: (bounds.width - lockLabel.bounds.width - 24) / 2,
            y: max(lockLabelTop, 70),
            width: lockLabel.bounds.width + 24,
            height: 30
        )
    }

    func updateRotation() {
        guard let input = previewLayer.session?.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: {
            $0.ports.contains(where: { $0.mediaType == .video })
        }) else { return }

        if rotationDeviceID != input.device.uniqueID {
            rotationDeviceID = input.device.uniqueID
            rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: input.device, previewLayer: previewLayer)
            lastAppliedRotationAngle = nil
        }

        guard let connection = previewLayer.connection,
              let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelPreview,
              connection.isVideoRotationAngleSupported(angle) else { return }
        if rotationConnection !== connection {
            rotationConnection = connection
            lastAppliedRotationAngle = nil
        }
        if let previous = lastAppliedRotationAngle, abs(previous - angle) < 0.001 { return }
        connection.videoRotationAngle = angle
        lastAppliedRotationAngle = angle
    }

    func enableStabilizationIfAvailable() {
        guard let connection = previewLayer.connection, connection.isVideoStabilizationSupported else { return }
        let mode: AVCaptureVideoStabilizationMode = stabilizationEnabled ? .auto : .off
        if connection.preferredVideoStabilizationMode != mode {
            connection.preferredVideoStabilizationMode = mode
        }
    }

    func setStabilizationEnabled(_ enabled: Bool) {
        stabilizationEnabled = enabled
        enableStabilizationIfAvailable()
    }

    func setReservesTopHUDSpace(_ reservesSpace: Bool) {
        guard reservesTopHUDSpace != reservesSpace else { return }
        reservesTopHUDSpace = reservesSpace
        setNeedsLayout()
    }

    func setPreviewTransitioning(_ transitioning: Bool) {
        guard transitioning != previewTransitioning else { return }
        previewTransitioning = transitioning
        transitionRevealWorkItem?.cancel()
        transitionRevealWorkItem = nil

        if transitioning {
            removeTransitionCover()

            // Keep a copy of the last visible hierarchy when UIKit can provide one, then blur the
            // whole cover. If the preview layer can't be snapshotted on a device, the live/frozen
            // preview still sits behind the blur so the transition remains visible and intentional.
            if bounds.width > 0, bounds.height > 0,
               let snapshot = snapshotView(afterScreenUpdates: false) {
                snapshot.frame = bounds
                snapshot.isUserInteractionEnabled = false
                snapshot.transform = .identity
                addSubview(snapshot)
                transitionSnapshot = snapshot
            }

            let blur = UIVisualEffectView(effect: nil)
            blur.frame = bounds
            blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            blur.isUserInteractionEnabled = false
            addSubview(blur)
            transitionBlurView = blur

            let dim = UIView(frame: bounds)
            dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            dim.backgroundColor = .black
            dim.alpha = 0
            dim.isUserInteractionEnabled = false
            addSubview(dim)
            transitionDimView = dim

            UIView.animate(
                withDuration: 0.075,
                delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
            ) { [weak self] in
                guard let self else { return }
                blur.effect = UIBlurEffect(style: .regular)
                dim.alpha = 0.06
                self.transitionSnapshot?.transform = CGAffineTransform(scaleX: 1.012, y: 1.012)
            }
        } else {
            revealTransitionWhenPreviewIsRendering()
        }
    }

    private func revealTransitionWhenPreviewIsRendering() {
        let deadline = CACurrentMediaTime() + 0.55

        func scheduleCheck() {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.previewTransitioning else { return }
                let connectionReady = self.previewLayer.connection?.isEnabled == true
                if (self.previewLayer.isPreviewing && connectionReady) || CACurrentMediaTime() >= deadline {
                    // Two display frames keep the cover over the first frame presented after an
                    // input/format commit. This replaces the old fixed 100 ms guess.
                    let reveal = DispatchWorkItem { [weak self] in
                        guard let self, !self.previewTransitioning else { return }
                        self.revealTransitionCover()
                    }
                    self.transitionRevealWorkItem = reveal
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.034, execute: reveal)
                } else {
                    scheduleCheck()
                }
            }
            transitionRevealWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: work)
        }

        scheduleCheck()
    }

    private func revealTransitionCover() {
        let snapshot = transitionSnapshot
        let blur = transitionBlurView
        let dim = transitionDimView
        guard snapshot != nil || blur != nil || dim != nil else { return }

        UIView.animate(
            withDuration: 0.13,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            blur?.effect = nil
            blur?.alpha = 0
            dim?.alpha = 0
            snapshot?.alpha = 0
            snapshot?.transform = .identity
        } completion: { [weak self] _ in
            guard let self, !self.previewTransitioning else { return }
            self.removeTransitionCover()
        }
    }

    private func removeTransitionCover() {
        transitionRevealWorkItem?.cancel()
        transitionRevealWorkItem = nil
        transitionSnapshot?.removeFromSuperview()
        transitionSnapshot = nil
        transitionBlurView?.removeFromSuperview()
        transitionBlurView = nil
        transitionDimView?.removeFromSuperview()
        transitionDimView = nil
    }

    func setFocusExposureLocked(_ isLocked: Bool, label: String) {
        let wasLocked = focusExposureLocked
        focusExposureLocked = isLocked
        if lockLabel.text != label {
            lockLabel.text = label
            setNeedsLayout()
        }
        lockLabel.isHidden = !isLocked
        focusIndicator.layer.borderColor = tintColor.cgColor
        if isLocked {
            hideFocusWorkItem?.cancel()
        } else if wasLocked {
            // Keep a freshly tapped focus box visible; its own timer fades it naturally.
        }
    }

    private func configureOverlays() {
        focusIndicator.isUserInteractionEnabled = false
        focusIndicator.layer.borderWidth = 2
        focusIndicator.layer.borderColor = tintColor.cgColor
        focusIndicator.layer.cornerRadius = 7
        focusIndicator.alpha = 0
        addSubview(focusIndicator)

        lockLabel.isUserInteractionEnabled = false
        lockLabel.text = "AE/AF LOCK"
        lockLabel.textAlignment = .center
        lockLabel.font = .systemFont(ofSize: 13, weight: .bold)
        lockLabel.textColor = tintColor
        lockLabel.backgroundColor = UIColor.black.withAlphaComponent(0.52)
        lockLabel.layer.cornerRadius = 15
        lockLabel.clipsToBounds = true
        lockLabel.isHidden = true
        addSubview(lockLabel)
    }

    private func configureGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.55
        longPress.allowableMovement = 18
        addGestureRecognizer(longPress)

        tap.require(toFail: longPress)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let layerPoint = recognizer.location(in: self)
        showFocusIndicator(at: layerPoint, locked: false)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        onTapToFocus?(devicePoint)
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        let layerPoint = recognizer.location(in: self)
        showFocusIndicator(at: layerPoint, locked: true)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        onLongPressToLock?(devicePoint)
    }

    private func showFocusIndicator(at point: CGPoint, locked: Bool) {
        hideFocusWorkItem?.cancel()
        let side: CGFloat = 72
        focusIndicator.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        focusIndicator.center = CGPoint(
            x: min(max(point.x, side / 2), bounds.width - side / 2),
            y: min(max(point.y, side / 2), bounds.height - side / 2)
        )
        focusIndicator.transform = CGAffineTransform(scaleX: 1.22, y: 1.22)
        focusIndicator.alpha = 1
        // The lock pill reflects the hardware lock state published by CameraManager.
        // A long press only shows the focus box until AF/AE has actually settled and locked.
        if !locked {
            lockLabel.isHidden = true
        }

        UIView.animate(withDuration: 0.18) {
            self.focusIndicator.transform = .identity
        }

        guard !locked else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.focusExposureLocked else { return }
            UIView.animate(withDuration: 0.22) {
                self.focusIndicator.alpha = 0
            }
        }
        hideFocusWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15, execute: workItem)
    }
}
