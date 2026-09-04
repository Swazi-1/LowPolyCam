//
//  Theme.swift
//  LowPolyCam
//
//  Updated for iOS 27 / Xcode 27 / Swift 6.4.
//  Swift 6 complete concurrency · Observation · Liquid Glass · RotationCoordinator
//

import SwiftUI
import UIKit

// MARK: - Hex Color

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8)  & 0xFF) / 255,
                  blue:  Double( hex        & 0xFF) / 255,
                  opacity: opacity)
    }

    /// Parses a 6-digit RGB hex string (optional leading "#"), used to load
    /// the user's custom accent color from `AppSettings.customAccentColorHex`.
    /// Falls back to `fallback` (Dial Lavender by default) if unparsable.
    init(hexString: String, fallback: UInt32 = 0xC4A8E8) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 6, let value = UInt32(s, radix: 16) {
            self.init(hex: value)
        } else {
            self.init(hex: fallback)
        }
    }

    /// Best-effort 6-digit RGB hex string for persisting a color picked via
    /// SwiftUI's `ColorPicker` (which only ever hands back a `Color`).
    func toHexString() -> String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X",
                      Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    /// Returns a lighter ("bright") or darker ("deep") variant of this color
    /// by scaling HSB brightness — mirrors how the built-in accent presets
    /// each hand-author a bright/deep pair, but derived automatically for
    /// any custom color the user picks.
    func brightnessScaled(_ multiplier: Double) -> Color {
        let ui = UIColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let newB = min(1, max(0, b * CGFloat(multiplier)))
        // Lightening a color also reads better with a touch less saturation
        // (matches the airier look of the hand-tuned "bright" presets).
        let newS = multiplier > 1 ? max(0, s * 0.82) : s
        return Color(hue: Double(h), saturation: Double(newS), brightness: Double(newB), opacity: Double(a))
    }
}

// MARK: - Palette
/// Refined low-poly camera palette.
/// Keeps the original icon DNA (slate body, mint lens, amber buttons, lavender dial)
/// but with deeper blacks, cleaner accents, and better contrast for modern UI.

enum Palette {
    // Backgrounds — deeper, more cinematic
    static let slateDeep   = Color(hex: 0x0B0E14)   // Near-black canvas
    static let slate       = Color(hex: 0x161C26)   // Primary surface
    static let slateMid    = Color(hex: 0x2A3444)   // Elevated surface
    static let slateLight  = Color(hex: 0x5A6B84)   // Secondary text / borders
    static let panel       = Color(hex: 0x121820)   // Cards & drawers

    // Lens Mint
    static let mint        = Color(hex: 0x5ED4B0)
    static let mintBright  = Color(hex: 0xA8F5DE)
    static let mintDeep    = Color(hex: 0x2F9A7C)

    // Dial Lavender
    static let violet      = Color(hex: 0xC4A8E8)
    static let violetDeep  = Color(hex: 0x8B6BB8)

    // Button Gold
    static let amber       = Color(hex: 0xF7D56E)
    static let amberBright = Color(hex: 0xFFE9A0)
    static let amberDeep   = Color(hex: 0xC9A42E)

    // Record Red
    static let record      = Color(hex: 0xFF4D5A)
    static let recordSoft  = Color(hex: 0xFF7A84)

    // Ice Cyan — special fifth accent
    static let ice         = Color(hex: 0x4EC8F0)
    static let iceBright   = Color(hex: 0xA8ECFF)
    static let iceDeep     = Color(hex: 0x1A8FB8)

    // Aurora — cosmic violet
    static let aurora      = Color(hex: 0xA78BFA)
    static let auroraBright = Color(hex: 0xC4B5FD)
    static let auroraDeep  = Color(hex: 0x7C3AED)
    static let auroraTeal  = Color(hex: 0x2DD4BF)

    // Coral Bloom — warm rose-coral accent
    static let coral       = Color(hex: 0xFF6B6B)
    static let coralBright = Color(hex: 0xFF9A9A)
    static let coralDeep   = Color(hex: 0xE04545)

    // Semantic
    static let success     = Color(hex: 0x4ADE80)
    static let warning     = Color(hex: 0xFBBF24)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary  = Color.white.opacity(0.38)
    static let separator     = Color.white.opacity(0.08)
}

// MARK: - Facet Shape (signature low-poly motif)

struct Facet: Shape {
    var sides: Int = 6
    /// Extra rotation in radians, on top of the flat-top default.
    var rotation: Double = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard sides >= 3 else { return path }
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        for i in 0..<sides {
            let angle = rotation - .pi / 2 + (2 * Double.pi * Double(i) / Double(sides))
            let point = CGPoint(x: centre.x + radius * CGFloat(cos(angle)),
                                y: centre.y + radius * CGFloat(sin(angle)))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Design Tokens

enum Design {
    static let cornerRadius: CGFloat = 16
    static let cornerRadiusSm: CGFloat = 10
    static let cornerRadiusLg: CGFloat = 22
    static let controlSize: CGFloat = 48
    static let shutterOuter: CGFloat = 88
    static let shutterInner: CGFloat = 68
    static let hudPadding: CGFloat = 16
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.82)
}

// MARK: - Device check
//
// Canonical check now lives in PerformanceProfile.swift
// (`PerformanceProfile.DeviceTier.current`) — this is a thin alias kept so
// the many `usesLightweightMaterial ? ... : ...` call sites below don't
// all need renaming.

var usesLightweightMaterial: Bool {
    PerformanceProfile.DeviceTier.current == .constrained
}

/// System material surface used by the modern iPhone-only interface.
struct AdaptiveMaterialFill: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
    }
}

// MARK: - Glass / Material helpers
//
// A restrained glass treatment keeps camera controls readable over both very
// bright and very dark previews without hiding the image beneath them.

struct GlassBackground: View {
    var cornerRadius: CGFloat = Design.cornerRadius
    var opacity: Double = 0.72
    var borderOpacity: Double = 0.14

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.08),
                                Palette.panel.opacity(opacity * 0.48),
                                Palette.slateDeep.opacity(opacity * 0.28)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(borderOpacity + 0.08),
                                Color.white.opacity(borderOpacity * 0.4)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
    }
}

struct FacetGlassBackground: View {
    var sides: Int = 6
    var rotation: Double = .pi / 6
    var opacity: Double = 0.82

    var body: some View {
        Facet(sides: sides, rotation: rotation)
            .fill(Palette.panel.opacity(opacity * 0.4))
            .overlay(
                Facet(sides: sides, rotation: rotation)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                Facet(sides: sides, rotation: rotation)
                    .stroke(Color.white.opacity(0.14), lineWidth: 0.9)
            )
    }
}

// MARK: - Reusable UI Components

struct FacetIconButton: View {
    let systemName: String
    var size: CGFloat = Design.controlSize
    var tint: Color = .white
    var filled: Bool = false
    var accent: Color = Palette.violet
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundColor(filled ? Palette.slateDeep : tint)
                .frame(width: size, height: size)
                .background(
                    Group {
                        if filled {
                            Facet(sides: 6, rotation: .pi / 6)
                                .fill(
                                    LinearGradient(
                                        colors: [accent, accent.opacity(0.75)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        } else {
                            FacetGlassBackground(sides: 6, rotation: .pi / 6)
                        }
                    }
                )
                .shadow(color: filled ? accent.opacity(0.35) : .black.opacity(0.35),
                        radius: filled ? 10 : 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle().inset(by: -8))
    }
}

struct InfoPill: View {
    let content: AnyView
    var accent: Color = Palette.violet

    init<Content: View>(accent: Color = Palette.violet, @ViewBuilder content: () -> Content) {
        self.accent = accent
        self.content = AnyView(content())
    }

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Palette.panel.opacity(0.78))
                    .background(
                        Group {
                            if usesLightweightMaterial {
                                Capsule().fill(Palette.slateDeep.opacity(0.55))
                            } else {
                                Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                            }
                        }
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [accent.opacity(0.45), Color.white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 6)
    }
}

struct ChipButton: View {
    let title: String
    var isSelected: Bool
    var accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(isSelected ? Palette.slateDeep : .white.opacity(0.9))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Group {
                        if isSelected {
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [accent, accent.opacity(0.8)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        } else {
                            Capsule()
                                .fill(Palette.slateMid.opacity(0.7))
                        }
                    }
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.clear : Color.white.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: isSelected ? accent.opacity(0.35) : .clear, radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }
}

struct SectionCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
                .fill(Palette.panel.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Typography helpers

enum AppFont {
    static func title(_ size: CGFloat = 20) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }
    static func headline(_ size: CGFloat = 16) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }
    static func body(_ size: CGFloat = 15) -> Font {
        .system(size: size, weight: .medium, design: .default)
    }
    static func caption(_ size: CGFloat = 12) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }
    static func mono(_ size: CGFloat = 14) -> Font {
        .system(size: size, weight: .bold, design: .monospaced)
    }
}
