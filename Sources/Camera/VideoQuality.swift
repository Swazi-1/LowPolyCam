import Foundation

enum VideoResolution: String, CaseIterable, Identifiable {
    case p4k = "4K"
    case p1080 = "1080p"
    case p720 = "720p"

    var id: String { rawValue }

    var dimensions: (width: Int32, height: Int32) {
        switch self {
        case .p4k: (3840, 2160)
        case .p1080: (1920, 1080)
        case .p720: (1280, 720)
        }
    }
}

enum VideoFrameRate: Int, CaseIterable, Identifiable {
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }
    var label: String { "\(rawValue) fps" }
}
