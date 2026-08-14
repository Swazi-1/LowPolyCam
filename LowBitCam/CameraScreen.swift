import SwiftUI
import UIKit

struct CameraScreen: View {

    @ObservedObject var settings: AppSettings
    @ObservedObject var recorder: CameraRecorder

    @State private var showSettings = false
    @State private var dimmed = false
    @State private var savedBrightness: CGFloat = UIScreen.main.brightness

    private var plan: EncodePlan { Encoder.plan(for: settings) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: recorder.session)
                .ignoresSafeArea()

            if recorder.permissionDenied {
                permissionMessage
            } else {
                controls
            }

            if dimmed { dimOverlay }
        }
        .statusBar(hidden: true)
        .preferredColorScheme(.dark)
        .onAppear { recorder.start() }
        .onDisappear { recorder.stop() }
        .sheet(isPresented: $showSettings) {
            SettingsScreen(settings: settings, recorder: recorder)
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack {
            topBar
            Spacer()
            if let notice = recorder.notice { noticeBar(notice) }
            bottomBar
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                if recorder.isRecording {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 10, height: 10)
                        Text(Fmt.duration(recorder.elapsed))
                            .font(.system(size: 19, weight: .semibold, design: .monospaced))
                    }
                    Text("clip \(recorder.clipsThisSession)")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                } else {
                    Text("\(settings.resolution.label) · \(settings.quality.label)")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(Int(plan.megabytesPerHour.rounded())) MB / hour")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(Fmt.size(recorder.freeBytes)) free · about \(Fmt.hours(hoursLeft))")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.45))
        .cornerRadius(14)
    }

    private var bottomBar: some View {
        HStack {
            circleButton(system: "gearshape.fill") { showSettings = true }
                .disabled(recorder.isRecording)
                .opacity(recorder.isRecording ? 0.35 : 1)

            Spacer()
            recordButton
            Spacer()

            circleButton(system: recorder.isRecording ? "moon.fill" : "arrow.triangle.2.circlepath.camera.fill") {
                if recorder.isRecording { enterDim() } else { recorder.flipCamera() }
            }
        }
    }

    private var recordButton: some View {
        Button {
            recorder.toggleRecording()
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 76, height: 76)
                RoundedRectangle(cornerRadius: recorder.isRecording ? 6 : 31)
                    .fill(Color.red)
                    .frame(width: recorder.isRecording ? 30 : 62,
                           height: recorder.isRecording ? 30 : 62)
            }
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.18), value: recorder.isRecording)
    }

    private func circleButton(system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 20))
                .foregroundColor(.white)
                .frame(width: 52, height: 52)
                .background(Color.black.opacity(0.45))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func noticeBar(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.6))
            .cornerRadius(12)
            .padding(.bottom, 14)
            .onTapGesture { recorder.notice = nil }
    }

    private var permissionMessage: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill").font(.system(size: 40))
            Text("Camera access is off")
                .font(.system(size: 18, weight: .semibold))
            Text("Turn it on in Settings › LowBitCam.")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.7))
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .padding(.top, 4)
        }
        .foregroundColor(.white)
        .padding(30)
    }

    // MARK: Dim mode

    /// Screen off is not possible while recording - iOS stops the camera. This
    /// is the next best thing: black screen, brightness at zero.
    private var dimOverlay: some View {
        Color.black
            .ignoresSafeArea()
            .overlay(
                Text("tap to wake")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.12))
            )
            .onTapGesture { leaveDim() }
    }

    private func enterDim() {
        savedBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = 0
        dimmed = true
    }

    private func leaveDim() {
        UIScreen.main.brightness = savedBrightness
        dimmed = false
    }

    private var hoursLeft: Double {
        let perHour = plan.megabytesPerHour * 1_000_000
        guard perHour > 0 else { return 0 }
        return Double(max(0, recorder.freeBytes - CameraRecorder.reserveBytes)) / perHour
    }
}
