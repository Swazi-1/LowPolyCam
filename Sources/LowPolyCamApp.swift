import SwiftUI

@main
struct LowPolyCamApp: App {
    @StateObject private var permissionManager = PermissionManager()
    private var accent = CameraAccent()
    @AppStorage("appColorScheme") private var appColorScheme = "system"

    init() {
        AppEventLog.beginNewSession()
        AppEventLog.event("App initialized")
    }

    var body: some Scene {
        WindowGroup {
            ContentView(permissionManager: permissionManager)
                .environment(\.cameraTint, accent.color)
                .tint(accent.color)
                .accentColor(accent.color)
                .preferredColorScheme(resolvedColorScheme(appColorScheme))
        }
    }
}
