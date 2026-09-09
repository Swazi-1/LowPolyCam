import AVFoundation
import UIKit
import Darwin

enum CameraMovieMetadata {
    private static let hardwareIdentifier: String = {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        }
    }()

    private static let friendlyNames = [
        "iPhone12,1": "iPhone 11",
        "iPhone12,3": "iPhone 11 Pro",
        "iPhone12,5": "iPhone 11 Pro Max"
    ]

    private static let model: String = {
        Self.friendlyNames[Self.hardwareIdentifier] ??
            (Self.hardwareIdentifier.isEmpty ? UIDevice.current.model : Self.hardwareIdentifier)
    }()

    private static let creationDateFormatter = ISO8601DateFormatter()

    static func items(isSlowMotion: Bool = false) -> [AVMetadataItem] {
        // Keep the exact hardware identifier when the friendly name is unknown instead of
        // degrading every newer iPhone to the generic string "iPhone".
        let values: [(AVMetadataIdentifier, String)] = [
            (.quickTimeMetadataMake, "Apple"),
            (.quickTimeMetadataModel, Self.model),
            (.quickTimeMetadataSoftware, "LowPolyCam"),
            (.quickTimeMetadataCreationDate, Self.creationDateFormatter.string(from: Date()))
        ]
        var result: [AVMetadataItem] = values.map { key, value in
            let item = AVMutableMetadataItem()
            item.identifier = key
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            item.value = value as NSString
            return item
        }

        if isSlowMotion {
            let intent = AVMutableMetadataItem()
            intent.identifier = .quickTimeMetadataFullFrameRatePlaybackIntent
            // 0 tells players the HFR movie is intended for slow-motion playback.
            intent.value = NSNumber(value: 0)
            result.append(intent)
        }
        return result
    }
}
