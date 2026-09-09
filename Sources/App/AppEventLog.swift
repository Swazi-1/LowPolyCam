import Foundation
import UIKit

/// Keeps one lightweight, user-readable log for the current app run.
/// The next cold launch replaces it so diagnostics never accumulate indefinitely.
enum AppEventLog {
    struct CaptureConfigurationLogSnapshot {
        let label: String
        let context: String
        let isBackCamera: Bool
        let isVirtualDevice: Bool
        let deviceName: String
        let width: Int32
        let height: Int32
        let frameRate: Double
        let codec: String
        let bitRate: Int?
        let zoomFactor: Double
        let whiteBalance: String

        var formattedMessage: String {
            let bitRateText = bitRate.map { "\($0 / 1_000_000) Mbps target" } ?? "bitrate default"
            let lensKind = isVirtualDevice ? "virtual" : "physical"
            let zoomText = abs(zoomFactor.rounded() - zoomFactor) < 0.01
                ? "\(Int(zoomFactor.rounded()))×"
                : String(format: "%.1f×", zoomFactor)
            return "\(label) [\(context)]: \(isBackCamera ? "back" : "front") \(lensKind) \(deviceName), " +
                "\(width)x\(height) @ \(String(format: "%.1f", frameRate)) fps, " +
                "codec=\(codec), \(bitRateText), zoom=\(zoomText), WB=\(whiteBalance)"
        }
    }

    struct SessionLogSnapshot {
        let context: String
        let isRunning: Bool
        let preset: String
        let mode: String
        let isBackCamera: Bool
        let recordingState: String
        let inputNames: [String]
        let outputNames: [String]
        let photoResponsive: Bool
        let liveMetricsAttached: Bool

        var formattedMessage: String {
            "SESSION SNAPSHOT [\(context)]: running=\(isRunning), preset=\(preset), " +
                "mode=\(mode), position=\(isBackCamera ? "back" : "front"), recordingState=\(recordingState), " +
                "inputs=[\(inputNames.joined(separator: ", "))], outputs=[\(outputNames.joined(separator: ", "))], " +
                "photoResponsive=\(photoResponsive), liveMetricsAttached=\(liveMetricsAttached)"
        }
    }

    private static let filename = "LowPolyCam-Session.log"
    private static let queue = DispatchQueue(label: "com.swazi.lowpolycam.eventLog", qos: .utility)
    private static let timestampFormatter = ISO8601DateFormatter()
    private static var handle: FileHandle?
    private static var hasStartedSession = false
    private static var defaultsObserver: NSObjectProtocol?
    private static var settingsSnapshot: [String: String] = [:]
    private static var settingsLogGeneration: UInt64 = 0
    private static var settingsLogScheduled = false
    private static let settingsLogDebounceNanoseconds: UInt64 = 100_000_000

    // Keep this list explicit. Dumping all of UserDefaults would include unrelated iOS
    // framework values, while this records every preference that can affect LowPolyCam.
    private static let diagnosticSettings: [(key: String, defaultValue: String)] = [
        ("appColorScheme", "system"),
        ("iconAppearance", "Ice"),
        ("iconCustomRed", "0.55"),
        ("iconCustomGreen", "0.85"),
        ("iconCustomBlue", "1.0"),
        ("selectedVideoResolution", "1080p"),
        ("selectedVideoFrameRate", "30"),
        ("selectedVideoCodec", "HEVC"),
        ("videoCompression", "High"),
        ("videoStabilizationEnabled", "true"),
        ("selectedSlowMotionResolution", "1080p"),
        ("selectedSlowMotionFrameRate", "240"),
        ("selectedPhotoMegapixels", "12"),
        ("photoFileFormat", "HEIC"),
        ("photoAspect", "4:3"),
        ("burstCount", "5"),
        ("shutterDelay", "0"),
        ("hapticCaptureEnabled", "true"),
        ("hapticStrength", "Medium"),
        ("countdownHaptics", "false"),
        ("zoomSpeed", "1.0"),
        ("tapZoomReset", "true"),
        ("recordingLock", "false"),
        ("lowStorageWarning", "true"),
        ("rememberCaptureMode", "false"),
        ("mirrorSelfies", "false"),
        ("centerCrosshair", "false"),
        ("cameraGridEnabled", "false"),
        ("gridOpacity", "1.0"),
        ("levelMeterEnabled", "true"),
        ("keepScreenAwakeEnabled", "false"),
        ("cameraHUDEnabled", "true"),
        ("cameraHUDResolution", "true"),
        ("cameraHUDFPS", "true"),
        ("cameraHUDRemaining", "true"),
        ("cameraHUDWhiteBalance", "false"),
        ("cameraHUDBattery", "false"),
        ("cameraHUDStorage", "false"),
        ("cameraHUDDroppedFrames", "false"),
        ("thermalHUD", "false"),
        ("hudTextSize", "10.0"),
        ("longevityMode", "false"),
        ("liveRecordingStats", "false"),
        ("liveStatsSize", "Normal"),
        ("liveStatsShowFPS", "true"),
        ("liveStatsShowBitrate", "true"),
        ("liveStatsShowDrops", "true"),
        ("liveStatsX", "0.5"),
        ("liveStatsY", "0.28"),
        ("splitMinutes", "0")
    ]

    static func beginNewSession() {
        // File I/O must never delay the first camera frame. The serial queue also preserves
        // event order: the reset always finishes before the first appended event.
        queue.async {
            beginNewSessionLocked()
        }
    }

    static func event(_ message: String) {
        queue.async {
            beginNewSessionLocked()
            appendLocked(message)
        }
    }

    static func event(_ snapshot: CaptureConfigurationLogSnapshot) {
        queue.async {
            beginNewSessionLocked()
            appendLocked(snapshot.formattedMessage)
        }
    }

    static func event(_ snapshot: SessionLogSnapshot) {
        queue.async {
            beginNewSessionLocked()
            appendLocked(snapshot.formattedMessage)
        }
    }

    static func flush() {
        queue.async {
            beginNewSessionLocked()
            flushPendingSettingsLogLocked()
            try? handle?.synchronize()
        }
    }

    private static func beginNewSessionLocked() {
        guard !hasStartedSession else { return }
        hasStartedSession = true

        let manager = FileManager.default
        guard let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = documents.appendingPathComponent(filename)

        try? handle?.close()
        handle = nil
        try? manager.removeItem(at: url)
        guard manager.createFile(atPath: url.path, contents: nil) else {
            NSLog("LowPolyCam could not create its session log.")
            return
        }
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            NSLog("LowPolyCam could not open its session log: %@", error.localizedDescription)
        }
        appendLocked("LowPolyCam session started")
        appendLocked("Environment: device=\(UIDevice.current.model), iOS=\(UIDevice.current.systemVersion), locale=\(Locale.current.identifier)")
        appendLocked("Environment: thermal=\(thermalStateName(ProcessInfo.processInfo.thermalState)), lowPowerMode=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        installDefaultsObserverLocked()
        settingsSnapshot = currentSettingsLocked()
        appendLocked("Settings snapshot begin")
        for setting in diagnosticSettings {
            appendLocked("SETTING \(setting.key)=\(settingsSnapshot[setting.key] ?? setting.defaultValue)")
        }
        appendLocked("Settings snapshot end")
    }

    private static func appendLocked(_ message: String) {
        let timestamp = timestampFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        handle?.write(data)
    }

    private static func installDefaultsObserverLocked() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: nil
        ) { _ in
            queue.async {
                scheduleSettingsLogLocked()
            }
        }
    }

    /// UserDefaults can emit a notification for every intermediate value while a slider or
    /// color picker is being dragged. Coalesce that burst so diagnostics still capture the
    /// final state without repeatedly scanning every tracked preference and writing to disk.
    private static func scheduleSettingsLogLocked() {
        settingsLogGeneration &+= 1
        let generation = settingsLogGeneration
        settingsLogScheduled = true

        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(settingsLogDebounceNanoseconds))) {
            guard generation == settingsLogGeneration else { return }
            settingsLogScheduled = false
            beginNewSessionLocked()
            logChangedSettingsLocked()
        }
    }

    /// Flush is called when the app is backgrounded. Do not leave a pending settings burst out
    /// of the session log just because its debounce window has not elapsed yet.
    private static func flushPendingSettingsLogLocked() {
        guard settingsLogScheduled else { return }
        settingsLogGeneration &+= 1
        settingsLogScheduled = false
        logChangedSettingsLocked()
    }

    private static func logChangedSettingsLocked() {
        let current = currentSettingsLocked()
        for setting in diagnosticSettings {
            let oldValue = settingsSnapshot[setting.key] ?? setting.defaultValue
            let newValue = current[setting.key] ?? setting.defaultValue
            guard oldValue != newValue else { continue }
            appendLocked("SETTING CHANGED \(setting.key): \(oldValue) -> \(newValue)")
        }
        settingsSnapshot = current
    }

    private static func currentSettingsLocked() -> [String: String] {
        let defaults = UserDefaults.standard
        return Dictionary(uniqueKeysWithValues: diagnosticSettings.map { setting in
            let value = defaults.object(forKey: setting.key)
            return (setting.key, value.map { String(describing: $0) } ?? setting.defaultValue)
        })
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
