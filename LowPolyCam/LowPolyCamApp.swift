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
    @StateObject private var settings: AppSettings
    @StateObject private var recorder: CameraRecorder
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let settings = AppSettings.shared
        _settings = StateObject(wrappedValue: settings)
        _recorder = StateObject(wrappedValue: CameraRecorder(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            CameraScreen(settings: settings, recorder: recorder)
                .preferredColorScheme(.dark)
                .tint(settings.accentColor.color)
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
