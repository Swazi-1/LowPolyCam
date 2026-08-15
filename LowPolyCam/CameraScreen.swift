import SwiftUI
import UIKit

struct CameraScreen: View {

    @ObservedObject var settings: AppSettings
    @ObservedObject var recorder: CameraRecorder

    @State private var showSettings = false
    @State private var dimmed = false
    @State private var savedBrightness: CGFloat = UIScreen.main.brightness
    @State private var blink = false

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
        VStack(spacing: 0) {
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
            VStack(alignment: .leading, spacing: 3) {
                Text("\(settings.resolution.label) · \(settings.quality.label)")
                    .font(.system(size: 15, weight: .semibold))
                Text(plan.sizeLabel)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
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
        .overlay(recordingBadge, alignment: .bottom)
    }

    /// Sits just under the top bar while filming, and stays put (as "Saving…")
    /// until the clip is actually written - so tapping stop always visibly
    /// does something right away, even before the file finishes.
    private var recordingBadge: some View {
        Group {
            if recorder.isRecording {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 11, height: 11)
                        .opacity(blink ? 0.25 : 1)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                                   value: blink)
                    Text("REC")
                        .font(.system(size: 13, weight: .bold))
                    Text(Fmt.duration(recorder.elapsed))
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    Text("· clip \(recorder.clipsThisSession)")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.black.opacity(0.75)))
                .overlay(Capsule().stroke(Color.red.opacity(0.8), lineWidth: 1.5))
                .offset(y: 26)
                .onAppear { blink = true }
                .onDisappear { blink = false }
            } else if recorder.isSaving {
                HStack(spacing: 8) {
                    ProgressView().tint(.white).scaleEffect(0.7)
                    Text("Saving…")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.black.opacity(0.75)))
                .offset(y: 26)
            }
        }
    }

    /// The record button sits in a ZStack, not a shared HStack with the other
    /// controls - a single row with Spacers between unevenly-counted buttons
    /// (2 on the left once the torch button appears, only 1 on the right)
    /// pushes the middle button off true center. Each side lays itself out
    /// independently against its own edge, so the record button stays exactly
    /// centered no matter how many buttons appear next to it.
    private var bottomBar: some View {
        ZStack {
            HStack {
                circleButton(system: "gearshape.fill") { showSettings = true }
                    .disabled(recorder.isRecording || recorder.isSaving)
                    .opacity((recorder.isRecording || recorder.isSaving) ? 0.35 : 1)

                if recorder.hasTorch {
                    circleButton(system: recorder.torchOn ? "bolt.fill" : "bolt.slash.fill",
                                 tint: recorder.torchOn ? .yellow : .white) {
                        recorder.toggleTorch()
                    }
                }

                Spacer()
            }

            HStack {
                Spacer()

                if recorder.isRecording {
                    circleButton(system: "moon.fill") { enterDim() }
                } else {
                    circleButton(system: "arrow.triangle.2.circlepath.camera.fill") {
                        recorder.flipCamera()
                    }
                    .disabled(recorder.isSaving)
                    .opacity(recorder.isSaving ? 0.35 : 1)
                }
            }

            recordButton
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
                if recorder.isSaving {
                    ProgressView().tint(.white)
                } else {
                    RoundedRectangle(cornerRadius: recorder.isRecording ? 6 : 31)
                        .fill(Color.red)
                        .frame(width: recorder.isRecording ? 30 : 62,
                               height: recorder.isRecording ? 30 : 62)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(recorder.isSaving)
        .animation(.easeInOut(duration: 0.18), value: recorder.isRecording)
    }

    private func circleButton(system: String,
                              tint: Color = .white,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 20))
                .foregroundColor(tint)
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
            .background(Color.black.opacity(0.7))
            .cornerRadius(12)
            .padding(.bottom, 14)
            .onTapGesture { recorder.notice = nil }
    }

    private var permissionMessage: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill").font(.system(size: 40))
            Text("Camera access is off")
                .font(.system(size: 18, weight: .semibold))
            Text("Turn it on in Settings › LowPolyCam.")
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
                VStack(spacing: 10) {
                    Circle()
                        .fill(Color.red.opacity(0.55))
                        .frame(width: 9, height: 9)
                    Text("recording · tap to wake")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.16))
                }
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
