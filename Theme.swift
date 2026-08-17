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

/// Upgraded vibrant, modern palette. Deep OLED blacks with neon-tinted accents.
enum Palette {
    static let slateDeep   = Color(hex: 0x15161A) // Deep OLED-friendly dark
    static let slate       = Color(hex: 0x24262D)
    static let slateLight  = Color(hex: 0x4A4E5C)

    static let mint        = Color(hex: 0x00F0B5) // Vibrant neon mint
    static let mintBright  = Color(hex: 0x80FFDF)
    static let mintDeep    = Color(hex: 0x00A87E)

    static let violet      = Color(hex: 0xAF52DE) // Apple's native system purple
    static let amber       = Color(hex: 0xFFD60A) // Apple's native system yellow

    static let record      = Color(hex: 0xFF453A) // Brighter, classic Apple record red

    static let panel       = Color(hex: 0x111112)
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
