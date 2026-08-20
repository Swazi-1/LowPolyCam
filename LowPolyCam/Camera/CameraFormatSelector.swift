import AVFoundation

/// Format selection policies for the three capture modes.
///
/// Video / Slow-Mo / Photo each need different sensor formats:
/// - **Video** — match target resolution + fps, prefer non-binned, tight rate lock
/// - **Slow-Mo** — high frame-rate formats (120/240), resolution secondary
/// - **Photo** — maximise `highResolutionStillImageDimensions` (12MP 4:3 on iPhone 7)
///   while keeping a usable low-power preview
enum CameraFormatSelector {

    // MARK: - Video

    /// Best format for normal video capture / idle preview at the given size + fps.
    static func bestVideoFormat(for device: AVCaptureDevice, width: Int, height: Int, fps: Double) -> AVCaptureDevice.Format? {
        scoredVideoCandidates(in: device.formats, width: width, height: height, fps: fps).first
    }

    // MARK: - Slow-Mo

    /// Ranked slow-mo candidates that also respect zoom baseline (physical wide).
    static func bestSlowMoAwareFormat(for device: AVCaptureDevice, width: Int, height: Int, fps: Double) -> AVCaptureDevice.Format? {
        let ranked = scoredVideoCandidates(in: device.formats, width: width, height: height, fps: fps)
        guard let fallback = ranked.first else { return nil }
        guard ranked.count > 1 else { return fallback }

        let baseline = wideAngleBaseline(for: device)
        guard baseline > 1 else { return fallback }

        guard (try? device.lockForConfiguration()) != nil else { return fallback }
        defer { device.unlockForConfiguration() }

        for candidate in ranked {
            device.activeFormat = candidate
            if device.minAvailableVideoZoomFactor <= baseline * 1.05 {
                return candidate
            }
        }
        return fallback
    }

    /// Fallback: any format that can hit the slow-mo fps, largest area wins.
    static func bestSlowMoFormat(for device: AVCaptureDevice, fps: Double) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var maxArea = 0
        for format in device.formats {
            let supportsFPS = format.videoSupportedFrameRateRanges.contains {
                $0.maxFrameRate >= (fps - 1.0)
            }
            guard supportsFPS else { continue }
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let area = Int(dims.width) * Int(dims.height)
            if area > maxArea {
                maxArea = area
                best = format
            }
        }
        return best
    }

    // MARK: - Photo

    /// Format optimised for full-resolution stills (iOS 15 / iPhone 7).
    /// High-res stills inherit the active format's aspect ratio / FOV, so a 16:9
    /// 1080p video format only yields ~9MP. Prefer formats whose
    /// highResolutionStillImageDimensions are the full 4:3 sensor (~12MP).
    static func bestPhotoStillFormat(for device: AVCaptureDevice, maxPreviewHeight: Int, fps: Double) -> AVCaptureDevice.Format? {
        struct Candidate {
            let format: AVCaptureDevice.Format
            let stillArea: Int
            let previewH: Int
            let previewArea: Int
            let isBinned: Bool
        }
        var candidates: [Candidate] = []
        for format in device.formats {
            let supportsFPS = format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate - 0.5 <= fps && fps <= $0.maxFrameRate + 0.5
            }
            guard supportsFPS else { continue }

            let still = format.highResolutionStillImageDimensions
            let stillArea = Int(still.width) * Int(still.height)
            guard stillArea > 0 else { continue }

            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            candidates.append(Candidate(
                format: format,
                stillArea: stillArea,
                previewH: Int(dims.height),
                previewArea: Int(dims.width) * Int(dims.height),
                isBinned: format.isVideoBinned
            ))
        }
        guard !candidates.isEmpty else {
            return bestVideoFormat(for: device, width: 1280, height: min(maxPreviewHeight, 720), fps: fps)
        }

        // 1) Max still megapixels
        // 2) Prefer preview height ≤ maxPreviewHeight (idle heat)
        // 3) Prefer smaller preview area among those
        // 4) Prefer non-binned
        candidates.sort { a, b in
            if a.stillArea != b.stillArea { return a.stillArea > b.stillArea }
            let aOver = a.previewH > maxPreviewHeight
            let bOver = b.previewH > maxPreviewHeight
            if aOver != bOver { return !aOver && bOver }
            if a.previewArea != b.previewArea { return a.previewArea < b.previewArea }
            if a.isBinned != b.isBinned { return !a.isBinned && b.isBinned }
            return false
        }
        return candidates.first?.format
    }

    // MARK: - Shared scoring (video + slow-mo resolution match)

    private static func scoredVideoCandidates(in formats: [AVCaptureDevice.Format], width: Int, height: Int, fps: Double) -> [AVCaptureDevice.Format] {
        var scored: [(format: AVCaptureDevice.Format, score: Int)] = []
        for format in formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard Int(dims.width) >= width, Int(dims.height) >= height else { continue }

            guard let matchingRange = format.videoSupportedFrameRateRanges.first(where: {
                $0.minFrameRate <= (fps + 0.5) && (fps - 0.5) <= $0.maxFrameRate
            }) else { continue }

            let areaDelta = Int(dims.width) * Int(dims.height) - width * height

            let rateDelta = matchingRange.maxFrameRate - fps
            let rateScore: Int
            if rateDelta < -0.05 {
                rateScore = 100_000_000 + Int((-rateDelta * 1_000).rounded())
            } else {
                let slack = abs(rateDelta)
                if slack < 0.15 {
                    rateScore = 0
                } else {
                    rateScore = Int((slack * 10_000).rounded())
                }
            }

            let binnedScore = format.isVideoBinned ? 1_000_000 : 0
            let isHDR = format.supportedColorSpaces.contains(.HLG_BT2020)
            let colorScore = isHDR ? 10_000_000 : 0

            let idealDur = CMTime(value: 1, timescale: CMTimeScale(max(1, Int(fps.rounded()))))
            let minDurDelta = abs(CMTimeGetSeconds(matchingRange.minFrameDuration) - CMTimeGetSeconds(idealDur))
            let durScore = Int((minDurDelta * 50_000).rounded())

            let score = areaDelta + rateScore + binnedScore + colorScore + durScore
            scored.append((format, score))
        }
        return scored.sorted { $0.score < $1.score }.map { $0.format }
    }

    /// Virtual device baseline zoom for the physical wide camera.
    static func wideAngleBaseline(for device: AVCaptureDevice) -> CGFloat {
        let constituents = device.constituentDevices
        guard !constituents.isEmpty,
              let wideIndex = constituents.firstIndex(where: {
                  $0.deviceType == .builtInWideAngleCamera
              }),
              wideIndex > 0 else { return 1 }

        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors
        guard wideIndex - 1 < switchOvers.count else { return 1 }
        let value = CGFloat(switchOvers[wideIndex - 1].doubleValue)
        return value > 0 ? value : 1
    }
}
