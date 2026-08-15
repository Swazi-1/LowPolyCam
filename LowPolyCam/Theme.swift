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

/// Colours lifted from the app icon: the slate camera body, its mint lens,
/// and the purple and amber buttons on top.
enum Palette {
    static let slateDeep   = Color(hex: 0x2B333F)
    static let slate       = Color(hex: 0x4A5567)
    static let slateLight  = Color(hex: 0x6E7A8E)

    static let mint        = Color(hex: 0x8FD3C4)
    static let mintBright  = Color(hex: 0xB2E5D8)
    static let mintDeep    = Color(hex: 0x5FA396)

    static let violet      = Color(hex: 0xA78BC9)
    static let amber       = Color(hex: 0xE6D06B)

    /// Kept a true red - it is the one colour in the interface that has to
    /// read as "recording" before it reads as part of a palette.
    static let record      = Color(hex: 0xE64A38)

    static let panel       = Color(hex: 0x1B212B)
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
