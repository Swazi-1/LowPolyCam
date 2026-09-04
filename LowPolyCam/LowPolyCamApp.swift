//
//  LowPolyCamApp.swift
//  LowPolyCam
//
//  Updated for iOS 27 / Xcode 27 / Swift 6.4.
//  Swift 6 complete concurrency · Observation · Liquid Glass · RotationCoordinator
//

import SwiftUI

@main
struct LowPolyCamApp: App {
    @State private var settings = AppSettings.shared
    @State private var recorder: CameraRecorder
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let settings = AppSettings.shared
        _settings = State(initialValue: settings)
        _recorder = State(initialValue: CameraRecorder(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            CameraScreen(settings: settings, recorder: recorder)
                .preferredColorScheme(.dark)
                .tint(settings.accentColor.color)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                recorder.start()
            }
        }
    }
}

#Preview("Camera") {
    CameraScreen(
        settings: AppSettings.shared,
        recorder: CameraRecorder(settings: AppSettings.shared)
    )
    .preferredColorScheme(.dark)
}
