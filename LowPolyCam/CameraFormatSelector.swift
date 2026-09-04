//
//  CameraFormatSelector.swift
//  LowPolyCam
//
//  Updated for iOS 27 / Xcode 27 / Swift 6.4.
//  Swift 6 complete concurrency · Observation · Liquid Glass · RotationCoordinator
//

import AVFoundation

/// Format selection policies for the three capture modes.
///
/// Video / Slow-Mo / Photo each need different sensor formats:
/// - **Video** — match target resolution + fps, prefer non-binned, tight rate lock
/// - **Slow-Mo** — high frame-rate formats (120/240), resolution secondary
/// - **Photo** — maximise `largestStillDimensions` (12MP 4:3 on iPhone 7)
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
        let originalFormat = device.activeFormat
        // Probing a virtual camera's zoom range requires temporarily selecting
        // formats, but this helper is only a selector. Always put the hardware
        // back; applyActiveFormat() performs the one real configuration change.
        defer {
            device.activeFormat = originalFormat
            device.unlockForConfiguration()
        }

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
                $0.minFrameRate <= fps + 0.5 && $0.maxFrameRate >= fps - 0.5
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
    /// largestStillDimensions are the full 4:3 sensor (~12MP).
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

            let still = format.largestStillDimensions
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
            // Prefer formats that can cover the target. Tiny targets (144p/360p)
            // rarely exist natively — we still pick the smallest available and
            // the encoder scales down via AVVideoWidth/Height.
            guard Int(dims.width) >= width, Int(dims.height) >= height else { continue }

            guard let matchingRange = format.videoSupportedFrameRateRanges.first(where: {
                $0.minFrameRate <= (fps + 0.5) && (fps - 0.5) <= $0.maxFrameRate
            }) else { continue }

            let areaDelta = Int(dims.width) * Int(dims.height) - width * height

            // The source format controls the preview crop too. A 4:3 format
            // can have a smaller area delta than 1280x720 for 480p, but it
            // visibly zooms a portrait aspect-fill preview and then has to be
            // stretched into a 16:9 file. Prefer matching the requested
            // aspect ratio first so low tiers keep the stock-Camera-like FOV.
            let targetAspect = Double(width) / Double(height)
            let formatAspect = Double(dims.width) / Double(dims.height)
            let aspectScore = Int((abs(formatAspect - targetAspect) * 100_000_000).rounded())

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

            let score = areaDelta + aspectScore + rateScore + binnedScore + colorScore + durScore
            scored.append((format, score))
        }
        return scored.sorted { $0.score < $1.score }.map { $0.format }
    }

    /// Virtual device baseline zoom for the physical wide camera.
    static func wideAngleBaseline(for device: AVCaptureDevice) -> CGFloat {
        // A physical ultra-wide camera reports its own optical view as raw
        // 1x. In the app (and Apple's Camera UI) that same view is displayed
        // as 0.5x relative to the main wide lens.
        if device.deviceType == .builtInUltraWideCamera { return 2 }
        let constituents = device.constituentDevices
        guard !constituents.isEmpty,
              let wideIndex = constituents.firstIndex(where: {
                  $0.deviceType == .builtInWideAngleCamera
              }),
              wideIndex > 0 else { return 1 }

        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors
        guard wideIndex - 1 < switchOvers.count else { return 1 }
        let raw = switchOvers[wideIndex - 1]
        let value = CGFloat(truncating: raw as NSNumber)
        return value > 0 ? value : 1
    }
}

// MARK: - Still dimensions

extension AVCaptureDevice.Format {
    /// Largest still size exposed by the active modern photo format.
    var largestStillDimensions: CMVideoDimensions {
        if let dimensions = supportedMaxPhotoDimensions.max(by: {
            Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
        }) {
            return dimensions
        }
        return CMVideoFormatDescriptionGetDimensions(formatDescription)
    }
}
