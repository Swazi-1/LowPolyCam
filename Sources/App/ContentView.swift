import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var permissionManager: PermissionManager

    var body: some View {
        Group {
            switch permissionManager.state {
            case .ready:
                CameraView()
            case .denied(let permissions):
                PermissionDeniedView(permissions: permissions)
            case .checking, .requesting:
                PermissionGateView(permissionManager: permissionManager)
            }
        }
        .task {
            await permissionManager.requestRequiredPermissionsIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            permissionManager.refreshAuthorizationState()
        }
    }
}
