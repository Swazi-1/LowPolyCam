import SwiftUI

struct LiveStatsOverlay: View {
    @ObservedObject var stats: LiveRecordingStatsState
    var editing: Bool
    var finish: () -> Void
    @AppStorage("liveStatsX") private var x = 0.5
    @AppStorage("liveStatsY") private var y = 0.28
    @AppStorage("liveStatsSize") private var size = "Normal"
    @AppStorage("liveStatsShowFPS") private var showFPS = true
    @AppStorage("liveStatsShowBitrate") private var showBitrate = true
    @AppStorage("liveStatsShowDrops") private var showDrops = true
    @State private var dragOrigin: CGPoint?
    @State private var dragPosition: CGPoint?
    @Environment(\.cameraTint) private var theme

    var body: some View {
        GeometryReader { proxy in
            let compact = size == "Compact"
            let width = min(CGFloat(compact ? 176 : 238), max(120, proxy.size.width - 24))
            let rows = max(1, [showFPS, showBitrate, showDrops].filter { $0 }.count)
            let height = CGFloat(rows * (compact ? 17 : 22) + (compact ? 16 : 24) + ((!compact || editing) ? 20 : 0))
            let travelX = max(1, proxy.size.width - width - 24)
            let travelY = max(1, proxy.size.height - height - 24)
            VStack(alignment: .leading, spacing: 6) {
                if !compact || editing {
                    Text(editing ? "DRAG TO POSITION" : "LIVE RECORDING").font(.caption2.bold()).foregroundStyle(theme)
                }
                if showFPS { metric(compact ? "FPS" : "Capture FPS", stats.fps.map { String(format: "%.1f", $0) } ?? "—") }
                if showBitrate { metric(compact ? "Bitrate" : "File bitrate", stats.mbps.map { String(format: "%.1f Mbps", $0) } ?? "—") }
                if showDrops { metric(compact ? "Drops*" : "Capture drops", stats.drops.map { String($0) } ?? "N/A") }
                if !showFPS && !showBitrate && !showDrops { Text("No stats selected").font(.caption) }
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(compact ? 8 : 12)
            .frame(width: width, height: height)
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.opacity(0.65)))
            .position(x: 12 + width / 2 + CGFloat(min(max(dragPosition.map { Double($0.x) } ?? x, 0), 1)) * travelX,
                      y: 12 + height / 2 + CGFloat(min(max(dragPosition.map { Double($0.y) } ?? y, 0), 1)) * travelY)
            .gesture(DragGesture().onChanged { value in
                guard editing else { return }
                if dragOrigin == nil {
                    let origin = CGPoint(x: CGFloat(x), y: CGFloat(y))
                    dragOrigin = origin
                    dragPosition = origin
                }
                guard let origin = dragOrigin else { return }
                dragPosition = CGPoint(
                    x: min(max(origin.x + value.translation.width / travelX, 0), 1),
                    y: min(max(origin.y + value.translation.height / travelY, 0), 1)
                )
            }.onEnded { _ in
                if let final = dragPosition {
                    x = Double(final.x)
                    y = Double(final.y)
                }
                dragOrigin = nil
                dragPosition = nil
            })
            .allowsHitTesting(editing)

            if editing {
                VStack {
                    HStack {
                        Button("Reset") { dragOrigin = nil; dragPosition = nil; x = 0.5; y = 0.28 }
                        Spacer()
                        Button("Done", action: finish).fontWeight(.bold)
                    }
                    .padding().background(.black.opacity(0.85), in: Capsule())
                    Spacer()
                }.padding(12).tint(theme)
            }
        }
        .dynamicTypeSize(.medium ... .large)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(minLength: 6); Text(value).monospacedDigit() }
            .lineLimit(1).minimumScaleFactor(0.75)
    }
}

struct RecordingExtrasSettings: View {
    @ObservedObject var camera: CameraManager
    var positionStats: () -> Void
    @AppStorage("longevityMode") private var longevity = false
    @AppStorage("liveRecordingStats") private var stats = false
    var body: some View {
        Group {
            if camera.captureMode == .video {
                SettingsCard(title: "Long Sessions & Stats", symbol: "battery.100percent") {
                    SettingsToggleRow(title: "Longevity Mode", subtitle: "Uses 720p, 30 fps, HEVC and Data Saver, then dims the screen while recording. Your previous setup returns when turned off.", isOn: Binding(get: { longevity }, set: { camera.applyLongevityMode($0) }))
                    SettingsDivider()
                    liveStatsControls
                }
            } else if camera.captureMode == .sloMo {
                SettingsCard(title: "Recording Stats", symbol: "chart.bar.xaxis") {
                    liveStatsControls
                }
            }
        }
        .onChange(of: stats) { _, _ in camera.refreshLiveMetrics() }
    }

    @ViewBuilder
    private var liveStatsControls: some View {
        SettingsToggleRow(title: "Live Recording Stats", subtitle: "Shows recording FPS, file bitrate and monitored frame drops. Uses a little extra processing.", isOn: $stats)
        SettingsDivider()
        NavigationLink {
            LiveStatsSettings(positionStats: positionStats)
        } label: {
            SettingsNavigationRow(title: "Live Stats Settings", subtitle: "Size, information and position", symbol: "chart.bar.xaxis")
        }.buttonStyle(.plain)
    }
}


struct LiveStatsSettings: View {
    var positionStats: () -> Void
    @AppStorage("appColorScheme") private var appColorScheme = "system"
    @AppStorage("liveStatsSize") private var size = "Normal"
    @AppStorage("liveStatsShowFPS") private var showFPS = true
    @AppStorage("liveStatsShowBitrate") private var showBitrate = true
    @AppStorage("liveStatsShowDrops") private var showDrops = true
    var body: some View {
        SettingsPage {
            SettingsCard(title: "Appearance", symbol: "textformat.size") {
                ThemeMenu(title: "Panel Size", selection: $size, options: [("Compact", "Compact"), ("Normal", "Normal")])
                Text("Compact uses shorter labels and less space. The panel adjusts to your selected stats.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsCard(title: "Information", symbol: "list.bullet") {
                SettingsToggleRow(title: "Capture FPS", subtitle: "Active recording frame rate", isOn: $showFPS)
                SettingsDivider()
                SettingsToggleRow(title: "File Bitrate", subtitle: "Measured recording data in Mbps", isOn: $showBitrate)
                SettingsDivider()
                SettingsToggleRow(title: "Capture Drops", subtitle: "Frames dropped by the monitoring output; not encoder drops", isOn: $showDrops)
            }
            SettingsCard(title: "Position", symbol: "arrow.up.and.down.and.arrow.left.and.right") {
                Button("Position Live Stats", action: positionStats).padding(.vertical, 8)
                Text("Drag the panel on your camera screen. Camera buttons are disabled while positioning. The chosen size and information are used in the editor and during recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .preferredColorScheme(resolvedColorScheme(appColorScheme))
        .navigationTitle("Live Stats")
        .navigationBarTitleDisplayMode(.inline)
    }
}
