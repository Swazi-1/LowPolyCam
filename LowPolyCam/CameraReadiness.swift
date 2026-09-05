import AVFoundation

extension CameraRecorder {
    /// Exposure settling is not proof of a live preview. Complete a mode
    /// transition only once the applied sensor format delivers a fresh frame.
    /// Delegate ownership and callback ownership both live on the writer queue.
    func waitForPreviewFrame(completion: (() -> Void)?) {
        guard let completion else { return }
        guard session.isRunning, !previewPaused, applicationActive,
              let device = cameraInput?.device else {
            Task { @MainActor in completion() }
            return
        }
        let expected = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let token = UUID()
        ioQueue.async {
            self.previewReadyToken = token
            self.previewExpectedDimensions = expected
            self.previewReadyCompletion = completion
            self.sessionQueue.async {
                self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
            }
            self.ioQueue.asyncAfter(deadline: .now() + 2) {
                guard self.previewReadyToken == token, self.previewReadyCompletion != nil else { return }
                self.finishPreviewReadiness(success: false)
            }
        }
    }

    func finishPreviewReadiness(success: Bool) {
        let completion = previewReadyCompletion
        previewReadyCompletion = nil
        previewExpectedDimensions = nil
        sessionQueue.async {
            self.writerLock.lock()
            let recording = self.wantsRecording || self.isStopDraining
            self.writerLock.unlock()
            if !recording { self.videoOutput.setSampleBufferDelegate(nil, queue: nil) }
            Task { @MainActor in
                if !success {
                    self.notice = "Camera preview did not resume · Reopen the camera"
                    self.isSessionRunning = false
                }
                completion?()
            }
        }
    }
}
