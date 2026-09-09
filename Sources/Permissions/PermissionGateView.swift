import SwiftUI

struct PermissionGateView: View {
    @ObservedObject var permissionManager: PermissionManager

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 58, weight: .light))
                Text("Preparing Camera")
                    .font(.title2.bold())
                ProgressView()
                    .tint(.white)
            }
            .foregroundStyle(.white)
        }
    }
}
