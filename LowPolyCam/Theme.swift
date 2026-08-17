import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8)  & 0xFF) / 255,
                  blue:  Double( hex        & 0xFF) / 255,
                  opacity: 1)
    }
}

/// Palette extracted directly from the 3D low-poly camera icon:
/// - Dusty slate blue body
/// - Seafoam / sage mint lens rings
/// - Butter yellow hexagonal buttons
/// - Pastel lavender top dial
enum Palette {
    // Body & Background Slate Blues
    static let slateDeep   = Color(hex: 0x141820) // Deep background base
    static let slate       = Color(hex: 0x222B38) // Low-poly shadow tone
    static let slateMid    = Color(hex: 0x3D4A5E) // Camera body mid-tone
    static let slateLight  = Color(hex: 0x6B7B94) // Camera body highlight

    // Lens Seafoam / Sage Mint
    static let mint        = Color(hex: 0x68C4A8) // Outer lens ring
    static let mintBright  = Color(hex: 0x98ECD4) // Inner lens aperture highlight
    static let mintDeep    = Color(hex: 0x42967E) // Lens shadow ring

    // Top Dial Lavender
    static let violet      = Color(hex: 0xBFA2DB) // Lavender shutter dial
    static let violetDeep  = Color(hex: 0x8667A8)

    // Side Buttons Butter Yellow
    static let amber       = Color(hex: 0xF5D365) // Hexagonal yellow buttons
    static let amberBright = Color(hex: 0xFFE58F)
    static let amberDeep   = Color(hex: 0xD4AD37)

    // Shutter / Recording Coral Red
    static let record      = Color(hex: 0xFF5454)

    static let panel       = Color(hex: 0x1A212C)
}

/// A regular polygon - the faceted motif the icon is built from. Used instead
/// of plain circles so the controls belong to the same visual family.
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
