import AVFoundation
import Foundation

struct CameraFormatSelector {
    typealias SlowMotionFrameRate = CameraManager.SlowMotionFrameRate

    struct VideoFormatSelection {
        let availableResolutions: [VideoResolution]
        let resolution: VideoResolution
        let frameRate: VideoFrameRate
        let supportedFrameRates: [VideoFrameRate]
        let supportedDevices: [AVCaptureDevice]
        let selectedFormatByDeviceID: [String: AVCaptureDevice.Format]
    }

    struct SlowMotionFormatSelection {
        let availableResolutions: [VideoResolution]
        let resolution: VideoResolution
        let frameRate: SlowMotionFrameRate
        let supportedFrameRates: [SlowMotionFrameRate]
        let supportedDevices: [AVCaptureDevice]
        let selectedFormatByDeviceID: [String: AVCaptureDevice.Format]
        let availableResolutionsByDeviceID: [String: [VideoResolution]]
        let supportedFrameRatesByDeviceID: [String: [SlowMotionFrameRate]]
    }

    let selectedVideoCodec: String
    let selectedResolution: VideoResolution
    let selectedFrameRate: VideoFrameRate

    func bestPhotoFormat(for device: AVCaptureDevice) -> (format: AVCaptureDevice.Format, dimensions: CMVideoDimensions)? {
        struct Candidate {
            let format: AVCaptureDevice.Format
            let photoDimensions: CMVideoDimensions
            let photoPixels: Int64
            let previewPixels: Int64
            let supports30FPS: Bool
        }

        var best: Candidate?
        for format in device.formats {
            guard let photoDimensions = format.supportedMaxPhotoDimensions.max(by: { lhs, rhs in
                Int64(lhs.width) * Int64(lhs.height) < Int64(rhs.width) * Int64(rhs.height)
            }) else { continue }

            let videoDimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let candidate = Candidate(
                format: format,
                photoDimensions: photoDimensions,
                photoPixels: Int64(photoDimensions.width) * Int64(photoDimensions.height),
                previewPixels: Int64(videoDimensions.width) * Int64(videoDimensions.height),
                supports30FPS: format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
            )

            guard let current = best else {
                best = candidate
                continue
            }

            // Max still-photo resolution always wins. When still resolution ties, prefer
            // the sharpest live-preview format first so Photo mode never chooses a softer
            // preview just because another format happens to include 30 fps.
            if candidate.photoPixels > current.photoPixels ||
                (candidate.photoPixels == current.photoPixels && candidate.previewPixels > current.previewPixels) ||
                (candidate.photoPixels == current.photoPixels && candidate.previewPixels == current.previewPixels && candidate.supports30FPS && !current.supports30FPS) {
                best = candidate
            }
        }

        guard let best else { return nil }
        return (best.format, best.photoDimensions)
    }

    /// Resolves the active Video selection with one local capability scan. The result keeps
    /// the selected format for each supported device, so CameraManager does not rescan the
    /// selected device after the capability pass.
    func videoFormatSelection(
        for devices: [AVCaptureDevice],
        requestedResolution: VideoResolution? = nil,
        requestedFrameRate: VideoFrameRate? = nil
    ) -> VideoFormatSelection {
        let resolutions = VideoResolution.allCases
        let frameRates = VideoFrameRate.allCases
        var hasFormatByResolution = Array(repeating: false, count: resolutions.count)
        var ratesByResolution = Array(repeating: [VideoFrameRate](), count: resolutions.count)
        var ratesByDeviceAndResolution = Array(
            repeating: Array(repeating: [VideoFrameRate](), count: resolutions.count),
            count: devices.count
        )
        var formatsByDeviceAndResolution = Array(
            repeating: Array(repeating: [AVCaptureDevice.Format](), count: resolutions.count),
            count: devices.count
        )

        for (deviceIndex, device) in devices.enumerated() {
            for candidate in device.formats {
                guard formatSupportsSelectedCodec(candidate) else { continue }
                let dimensions = CMVideoFormatDescriptionGetDimensions(candidate.formatDescription)
                guard let resolutionIndex = resolutions.firstIndex(where: {
                    $0.dimensions.width == dimensions.width && $0.dimensions.height == dimensions.height
                }) else { continue }
                hasFormatByResolution[resolutionIndex] = true
                formatsByDeviceAndResolution[deviceIndex][resolutionIndex].append(candidate)

                for frameRate in frameRates where format(candidate, supports: resolutions[resolutionIndex], at: frameRate) {
                    if !ratesByResolution[resolutionIndex].contains(frameRate) {
                        ratesByResolution[resolutionIndex].append(frameRate)
                    }
                    if !ratesByDeviceAndResolution[deviceIndex][resolutionIndex].contains(frameRate) {
                        ratesByDeviceAndResolution[deviceIndex][resolutionIndex].append(frameRate)
                    }
                }
            }
        }

        let availableResolutions = resolutions.enumerated().compactMap { index, resolution in
            hasFormatByResolution[index] ? resolution : nil
        }
        let wantedResolution = requestedResolution ?? selectedResolution
        let resolution = availableResolutions.contains(wantedResolution)
            ? wantedResolution
            : (availableResolutions.first ?? .p1080)
        let resolutionIndex = resolutions.firstIndex(of: resolution) ?? 0
        let supportedFrameRates = frameRates.filter { ratesByResolution[resolutionIndex].contains($0) }
        let wantedFrameRate = requestedFrameRate ?? selectedFrameRate
        let frameRate = supportedFrameRates.contains(wantedFrameRate)
            ? wantedFrameRate
            : (supportedFrameRates.first ?? .fps30)
        let supportedDevices = devices.enumerated().compactMap { index, device in
            ratesByDeviceAndResolution[index][resolutionIndex].contains(frameRate) ? device : nil
        }
        var selectedFormatByDeviceID: [String: AVCaptureDevice.Format] = [:]
        for (index, device) in devices.enumerated()
            where ratesByDeviceAndResolution[index][resolutionIndex].contains(frameRate) {
            let candidates = formatsByDeviceAndResolution[index][resolutionIndex].filter {
                format($0, supports: resolution, at: frameRate)
            }
            if let selectedFormat = preferredRecordingFormat(from: candidates) {
                selectedFormatByDeviceID[device.uniqueID] = selectedFormat
            }
        }

        return VideoFormatSelection(
            availableResolutions: availableResolutions,
            resolution: resolution,
            frameRate: frameRate,
            supportedFrameRates: supportedFrameRates,
            supportedDevices: supportedDevices,
            selectedFormatByDeviceID: selectedFormatByDeviceID
        )
    }

    /// Resolves the active Slo-Mo selection with one local capability scan. The result carries
    /// the selected format and the chosen lens's capability lists so later configuration steps do
    /// not rescan the same device formats.
    func slowMotionFormatSelection(
        for devices: [AVCaptureDevice],
        requestedResolution: VideoResolution? = nil,
        requestedFrameRate: SlowMotionFrameRate? = nil
    ) -> SlowMotionFormatSelection {
        let resolutions = VideoResolution.allCases
        let frameRates = SlowMotionFrameRate.allCases
        var ratesByResolution = Array(repeating: [SlowMotionFrameRate](), count: resolutions.count)
        var ratesByDeviceAndResolution = Array(
            repeating: Array(repeating: [SlowMotionFrameRate](), count: resolutions.count),
            count: devices.count
        )
        var formatsByDeviceAndResolution = Array(
            repeating: Array(repeating: [AVCaptureDevice.Format](), count: resolutions.count),
            count: devices.count
        )

        for (deviceIndex, device) in devices.enumerated() {
            for candidate in device.formats {
                guard formatSupportsSelectedCodec(candidate) else { continue }
                let dimensions = CMVideoFormatDescriptionGetDimensions(candidate.formatDescription)
                guard let resolutionIndex = resolutions.firstIndex(where: {
                    $0.dimensions.width == dimensions.width && $0.dimensions.height == dimensions.height
                }) else { continue }
                formatsByDeviceAndResolution[deviceIndex][resolutionIndex].append(candidate)

                for frameRate in frameRates {
                    let fps = Double(frameRate.rawValue)
                    guard candidate.videoSupportedFrameRateRanges.contains(where: {
                        $0.minFrameRate <= fps + 0.5 && $0.maxFrameRate >= fps - 0.5
                    }) else { continue }
                    if !ratesByResolution[resolutionIndex].contains(frameRate) {
                        ratesByResolution[resolutionIndex].append(frameRate)
                    }
                    if !ratesByDeviceAndResolution[deviceIndex][resolutionIndex].contains(frameRate) {
                        ratesByDeviceAndResolution[deviceIndex][resolutionIndex].append(frameRate)
                    }
                }
            }
        }

        let availableResolutions = resolutions.enumerated().compactMap { index, resolution in
            ratesByResolution[index].isEmpty ? nil : resolution
        }
        let wantedResolution = requestedResolution ?? .p1080
        let resolution = availableResolutions.contains(wantedResolution)
            ? wantedResolution
            : (availableResolutions.contains(.p1080) ? .p1080 : (availableResolutions.first ?? .p1080))
        let resolutionIndex = resolutions.firstIndex(of: resolution) ?? 0
        let supportedFrameRates = frameRates.filter { ratesByResolution[resolutionIndex].contains($0) }
        let wantedFrameRate = requestedFrameRate ?? .fps240
        let frameRate = supportedFrameRates.contains(wantedFrameRate)
            ? wantedFrameRate
            : (supportedFrameRates.last ?? .fps120)
        let supportedDevices = devices.enumerated().compactMap { index, device in
            ratesByDeviceAndResolution[index][resolutionIndex].contains(frameRate) ? device : nil
        }
        var selectedFormatByDeviceID: [String: AVCaptureDevice.Format] = [:]
        var availableResolutionsByDeviceID: [String: [VideoResolution]] = [:]
        var supportedFrameRatesByDeviceID: [String: [SlowMotionFrameRate]] = [:]
        for (index, device) in devices.enumerated()
            where ratesByDeviceAndResolution[index][resolutionIndex].contains(frameRate) {
            let deviceRates = ratesByDeviceAndResolution[index]
            availableResolutionsByDeviceID[device.uniqueID] = resolutions.enumerated().compactMap {
                deviceRates[$0.offset].isEmpty ? nil : $0.element
            }
            supportedFrameRatesByDeviceID[device.uniqueID] = frameRates.filter {
                deviceRates[resolutionIndex].contains($0)
            }
            if let selectedFormat = bestSlowMotionFormat(
                from: formatsByDeviceAndResolution[index][resolutionIndex],
                resolution: resolution,
                frameRate: frameRate
            ) {
                selectedFormatByDeviceID[device.uniqueID] = selectedFormat
            }
        }

        return SlowMotionFormatSelection(
            availableResolutions: availableResolutions,
            resolution: resolution,
            frameRate: frameRate,
            supportedFrameRates: supportedFrameRates,
            supportedDevices: supportedDevices,
            selectedFormatByDeviceID: selectedFormatByDeviceID,
            availableResolutionsByDeviceID: availableResolutionsByDeviceID,
            supportedFrameRatesByDeviceID: supportedFrameRatesByDeviceID
        )
    }

    func preferredRecordingFormat(for device: AVCaptureDevice, resolution: VideoResolution, rate: VideoFrameRate) -> AVCaptureDevice.Format? {
        let formats = device.formats.filter { format($0, supports: resolution, at: rate) }
        return preferredRecordingFormat(from: formats)
    }

    private func preferredRecordingFormat(from formats: [AVCaptureDevice.Format]) -> AVCaptureDevice.Format? {
        if selectedVideoCodec == "H264" {
            // H.264 needs an 8-bit source; a 10-bit/HDR first match can expose HEVC only.
            return formats.first {
                let type = CMFormatDescriptionGetMediaSubType($0.formatDescription)
                return type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            } ?? formats.first
        }
        return formats.first
    }

    func slowMotionResolutions(for devices: [AVCaptureDevice]) -> [VideoResolution] {
        VideoResolution.allCases.filter { resolution in
            SlowMotionFrameRate.allCases.contains { rate in
                devices.contains { device in
                    device.formats.contains { supportsSlowMotion($0, resolution: resolution, frameRate: rate) }
                }
            }
        }
    }

    func supportsSlowMotion(
        _ candidate: AVCaptureDevice.Format,
        resolution: VideoResolution,
        frameRate: SlowMotionFrameRate
    ) -> Bool {
        let dimensions = CMVideoFormatDescriptionGetDimensions(candidate.formatDescription)
        guard dimensions.width == resolution.dimensions.width,
              dimensions.height == resolution.dimensions.height,
              formatSupportsSelectedCodec(candidate) else { return false }
        let fps = Double(frameRate.rawValue)
        return candidate.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= fps + 0.5 && $0.maxFrameRate >= fps - 0.5
        }
    }

    func bestSlowMotionFormat(for device: AVCaptureDevice, resolution: VideoResolution, frameRate: SlowMotionFrameRate) -> AVCaptureDevice.Format? {
        bestSlowMotionFormat(from: device.formats, resolution: resolution, frameRate: frameRate)
    }

    private func bestSlowMotionFormat(
        from formats: [AVCaptureDevice.Format],
        resolution: VideoResolution,
        frameRate: SlowMotionFrameRate
    ) -> AVCaptureDevice.Format? {
        let requestedFPS = Double(frameRate.rawValue)
        let candidates = formats.filter {
            supportsSlowMotion($0, resolution: resolution, frameRate: frameRate)
        }

        // Prefer the format whose supported range is closest to the requested HFR. This keeps
        // 120 fps on a 120-oriented format when one exists instead of needlessly selecting a
        // 240-oriented sensor mode.
        return candidates.min { lhs, rhs in
            let lhsMax = lhs.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? .greatestFiniteMagnitude
            let rhsMax = rhs.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? .greatestFiniteMagnitude
            let lhsDistance = abs(lhsMax - requestedFPS)
            let rhsDistance = abs(rhsMax - requestedFPS)
            if abs(lhsDistance - rhsDistance) > 0.01 { return lhsDistance < rhsDistance }
            let lhsPixels = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rhsPixels = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return Int64(lhsPixels.width) * Int64(lhsPixels.height) > Int64(rhsPixels.width) * Int64(rhsPixels.height)
        }
    }

    func format(_ format: AVCaptureDevice.Format, supports resolution: VideoResolution, at frameRate: VideoFrameRate? = nil) -> Bool {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        guard dimensions.width == resolution.dimensions.width, dimensions.height == resolution.dimensions.height else { return false }
        guard let frameRate else { return true }
        return format.videoSupportedFrameRateRanges.contains {
            let requestedRate = Double(frameRate.rawValue)
            return $0.minFrameRate <= requestedRate + 0.5 && $0.maxFrameRate >= requestedRate - 0.5
        }
    }

    func formatSupportsSelectedCodec(_ format: AVCaptureDevice.Format) -> Bool {
        guard selectedVideoCodec == "H264" else { return true }
        let type = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        return type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
            type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }
}
