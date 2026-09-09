import SwiftUI
import UIKit

struct AppearanceSettingsView: View {
    @AppStorage("iconAppearance") private var appearance = "Ice"
    @AppStorage("iconCustomRed") private var red = 0.55
    @AppStorage("iconCustomGreen") private var green = 0.85
    @AppStorage("iconCustomBlue") private var blue = 1.0
    @AppStorage("appColorScheme") private var appColorScheme = "system"
    private var accent = CameraAccent()
    private let names = ["Ice", "Sunset", "Mint", "Lavender", "Coral", "Custom"]

    var body: some View {
        SettingsPage {
            VStack(spacing: 16) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 60, weight: .light))
                    .foregroundStyle(accent.color)
                    .shadow(color: accent.color.opacity(0.45), radius: 18)
                Text(appearance.uppercased())
                    .font(.system(.headline, design: .rounded)).tracking(4)
                HStack(spacing: 20) {
                    ForEach(["bolt.fill", "viewfinder", "gearshape.fill"], id: \.self) { symbol in
                        Image(systemName: symbol).foregroundStyle(accent.color)
                            .frame(width: 46, height: 46)
                            .background(accent.color.opacity(0.14), in: Circle())
                    }
                }
                Text("Your camera, your color").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 24)
            .background(LinearGradient(colors: [accent.color.opacity(0.22), Color(uiColor: .secondarySystemGroupedBackground)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))
            SettingsCard(title: "Choose a Theme", symbol: "paintpalette.fill") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(names, id: \.self) { name in
                        Button { appearance = name } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 5) {
                                    ForEach([1.0, 0.7, 0.4], id: \.self) { opacity in
                                        Circle().fill(color(for: name).opacity(opacity)).frame(width: 20, height: 20)
                                    }
                                    Spacer(minLength: 0)
                                    if appearance == name {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(color(for: name))
                                    }
                                }
                                Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            }
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(color(for: name).opacity(appearance == name ? 0.18 : 0.06), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(color(for: name).opacity(appearance == name ? 0.8 : 0.12)))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                if appearance == "Custom" {
                    ColorPicker("Custom Accent", selection: Binding(get: { accent.color }, set: { value in
                        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                        UIColor(value).getRed(&r, green: &g, blue: &b, alpha: &a)
                        red = Double(r); green = Double(g); blue = Double(b)
                    }), supportsOpacity: false)
                }
            }
        }
        .tint(accent.color).accentColor(accent.color)
        .preferredColorScheme(resolvedColorScheme(appColorScheme))
        .navigationTitle("Appearance").navigationBarTitleDisplayMode(.inline)
    }

    private func color(for name: String) -> Color {
        switch name {
        case "Sunset": return Color(red: 1, green: 0.58, blue: 0.3)
        case "Mint": return Color(red: 0.4, green: 0.95, blue: 0.7)
        case "Lavender": return Color(red: 0.77, green: 0.64, blue: 1)
        case "Coral": return Color(red: 1.0, green: 0.43, blue: 0.48)
        case "Custom": return Color(red: red, green: green, blue: blue)
        default: return Color(red: 0.65, green: 0.88, blue: 1)
        }
    }
}

struct VideoPresetsView: View {
    @ObservedObject var camera: CameraManager
    @Environment(\.cameraTint) private var theme
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appColorScheme") private var appColorScheme = "system"
    @State private var preview: VideoQuickPreset = .balanced
    var body: some View {
        StaticSettingsPage {
            VStack(spacing: 9) {
                Image(systemName: "video.fill")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(theme).shadow(color: theme.opacity(0.4), radius: 14)
                Text(preview.rawValue).font(.title3.weight(.bold))
                VStack(spacing: 5) {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 6, height: 6)
                        Text("REC  00:00:12").font(.system(.caption, design: .monospaced).weight(.bold))
                    }
                    HStack(spacing: 12) {
                        Label(preview.resolution.rawValue, systemImage: "viewfinder")
                        Label("\(preview.frameRate.rawValue) fps", systemImage: "speedometer")
                        Text("HEVC")
                    }.font(.caption2.weight(.semibold)).foregroundStyle(theme)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(theme.opacity(0.4)))
                Text("HUD preview · example recording timer").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(LinearGradient(colors: [theme.opacity(0.22), Color(uiColor: .secondarySystemGroupedBackground)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))
            SettingsCard(title: "Choose a Preset", symbol: "wand.and.stars", contentSpacing: 7) {
                ForEach(VideoQuickPreset.allCases) { preset in
                    Button { preview = preset } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.rawValue).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                Text(preset.detail).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: preview == preset ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(theme)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(theme.opacity(preview == preset ? 0.16 : 0.04), in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Button {
                    camera.applyQuickPreset(preview) { success in
                        if success { dismiss() }
                    }
                } label: {
                    Text("Use \(preview.rawValue)").font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(theme, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.black)
                }.buttonStyle(.plain)
            }
        }
        .onAppear {
            preview = VideoQuickPreset.allCases.first {
                $0.resolution == camera.selectedResolution &&
                $0.frameRate == camera.selectedFrameRate &&
                $0.compression == camera.videoCompression &&
                camera.selectedVideoCodec == "HEVC"
            } ?? .balanced
        }
        .preferredColorScheme(resolvedColorScheme(appColorScheme))
        .navigationTitle("Video Presets").navigationBarTitleDisplayMode(.inline)
    }
}
