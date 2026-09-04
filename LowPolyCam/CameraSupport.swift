//
//  CameraSupport.swift
//  LowPolyCam
//
//  Updated for iOS 27 / Xcode 27 / Swift 6.4.
//  Swift 6 complete concurrency · Observation · Liquid Glass · RotationCoordinator
//

import AVFoundation
import UIKit
import MediaPlayer
import AudioToolbox

// MARK: - Thermal State Display

extension ProcessInfo.ThermalState {
    var shortLabel: String {
        switch self {
        case .nominal, .fair: return "Normal"
        case .serious: return "Warm"
        case .critical: return "Hot"
        @unknown default: return "Normal"
        }
    }

    var icon: String {
        switch self {
        case .nominal, .fair: return "thermometer.low"
        case .serious: return "thermometer.medium"
        case .critical: return "thermometer.high"
        @unknown default: return "thermometer.low"
        }
    }
}

// MARK: - Shutter / Dial Click Sounds

enum SoundPlayer {
    enum Click: SystemSoundID {
        case start = 1117   // begin_record
        case stop = 1118    // end_record
        case shutter = 1108 // photoShutter
        case dial = 1104    // Tock
    }

    static func play(_ click: Click) {
        AudioServicesPlaySystemSound(click.rawValue)
    }
}

// MARK: - Device Model

extension UIDevice {
    /// Human-readable hardware name (e.g. "iPhone 7", "iPhone 15 Pro") for
    /// use in saved-file metadata, resolved from the raw hardware identifier
    /// (e.g. "iPhone9,1"). Falls back to the raw identifier for unrecognized
    /// or newer hardware not yet in this table.
    var modelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let raw = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { ptr in
                String(cString: ptr)
            }
        }

        let map: [String: String] = [
            "iPhone8,4": "iPhone SE",
            "iPhone9,1": "iPhone 7", "iPhone9,3": "iPhone 7",
            "iPhone9,2": "iPhone 7 Plus", "iPhone9,4": "iPhone 7 Plus",
            "iPhone10,1": "iPhone 8", "iPhone10,4": "iPhone 8",
            "iPhone10,2": "iPhone 8 Plus", "iPhone10,5": "iPhone 8 Plus",
            "iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X",
            "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max",
            "iPhone11,8": "iPhone XR",
            "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
            "iPhone12,8": "iPhone SE (2nd generation)",
            "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,6": "iPhone SE (3rd generation)",
            "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,5": "iPhone 16e",
            "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone 17 Air",
            "iPhone19,1": "iPhone 18 Pro", "iPhone19,2": "iPhone 18 Pro Max", "iPhone19,3": "iPhone 18", "iPhone19,4": "iPhone 18 Air"
        ]

        if let friendly = map[raw] { return friendly }
        if raw.hasPrefix("iPhone") { return raw }
        return raw // Simulator or unrecognized hardware — show the raw string.
    }
}

// MARK: - UIImage Orientation → CGImagePropertyOrientation

extension UIImage.Orientation {
    var cgImagePropertyOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

// MARK: - Volume Shutter Observer

final class VolumeButtonObserver: NSObject {
    private var audioSession: AVAudioSession { AVAudioSession.sharedInstance() }
    private var volumeView: MPVolumeView?
    private var isObserving = false
    private var lastVolume: Float?
    private var ignoreUntil: Date = .distantFuture
    /// Volume level we restore to after treating a press as a shutter trigger,
    /// so using the volume buttons does not permanently change system volume.
    private var volumeToRestore: Float?
    var onVolumeTrigger: (() -> Void)?

    func start() {
        guard !isObserving else { return }
        do {
            try audioSession.setActive(true, options: [])
        } catch { }

        Task { @MainActor in
            if self.volumeView == nil {
                let v = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
                v.clipsToBounds = true
                v.alpha = 0.01
                if let window = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first?.windows.first {
                    window.addSubview(v)
                    self.volumeView = v
                }
            }
        }

        lastVolume = audioSession.outputVolume
        ignoreUntil = Date().addingTimeInterval(1.5)
        audioSession.addObserver(self, forKeyPath: "outputVolume", options: [.new, .old], context: nil)
        isObserving = true
    }

    func stop() {
        guard isObserving else { return }
        audioSession.removeObserver(self, forKeyPath: "outputVolume")
        isObserving = false
        Task { @MainActor in
            self.volumeView?.removeFromSuperview()
            self.volumeView = nil
        }
    }

    func ignoreTemporarily(duration: TimeInterval = 1.5) {
        let candidate = Date().addingTimeInterval(duration)
        if candidate > ignoreUntil {
            ignoreUntil = candidate
        }
    }

    /// Best-effort restore of system volume via the hidden MPVolumeView slider.
    private func restoreVolumeIfNeeded() {
        guard let target = volumeToRestore else { return }
        volumeToRestore = nil
        Task { @MainActor [weak self] in
            guard let self = self, let slider = self.volumeView?.subviews.compactMap({ $0 as? UISlider }).first else { return }
            // Ignore the KVO noise we are about to generate.
            self.ignoreTemporarily(duration: 0.8)
            slider.value = target
            self.lastVolume = target
        }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "outputVolume" {
            let currentVol = audioSession.outputVolume
            if Date() < ignoreUntil {
                lastVolume = currentVol
                return
            }
            if let prev = lastVolume {
                if abs(currentVol - prev) > 0.01 {
                    // Remember the *previous* level so we can put it back after
                    // treating this press as a shutter. Works at the extremes
                    // as long as the system still reports a delta (some iOS
                    // versions still fire when volume is clamped).
                    volumeToRestore = prev
                    lastVolume = currentVol
                    onVolumeTrigger?()
                    restoreVolumeIfNeeded()
                }
            } else {
                lastVolume = currentVol
            }
        }
    }
}
