import SwiftUI
import UIKit

struct PermissionDeniedView: View {
    let permissions: [String]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.circle")
                    .font(.system(size: 58))
                Text("Access Needed")
                    .font(.title.bold())
                Text("Allow \(permissions.joined(separator: ", ")) in Settings to use LowPolyCam.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(32)
            .foregroundStyle(.white)
        }
    }
}
