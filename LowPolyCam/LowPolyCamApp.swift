import SwiftUI

@main
struct LowPolyCamApp: App {

    @StateObject private var settings = AppSettings.shared
    @StateObject private var recorder = CameraRecorder(settings: AppSettings.shared)

    var body: some Scene {
        WindowGroup {
            CameraScreen(settings: settings, recorder: recorder)
                .preferredColorScheme(.dark)
        }
    }
}
