import SwiftUI

// v0.1.0 installed-app silhouette. Preserve this path exactly.
struct CenteredIslandShape: Shape {
    var topFlare: CGFloat = 12
    var bottomRadius: CGFloat = 20

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let f = min(topFlare, w / 2, h / 2)
        let b = min(bottomRadius, (w - 2 * f) / 2, h - f)

        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))                                   // top-left, at screen top
        p.addQuadCurve(to: CGPoint(x: f, y: f),                           // outward flare → body left
                       control: CGPoint(x: f, y: 0))
        p.addLine(to: CGPoint(x: f, y: h - b))                           // left side
        p.addQuadCurve(to: CGPoint(x: f + b, y: h),                       // bottom-left rounded
                       control: CGPoint(x: f, y: h))
        p.addLine(to: CGPoint(x: w - f - b, y: h))                       // bottom edge
        p.addQuadCurve(to: CGPoint(x: w - f, y: h - b),                   // bottom-right rounded
                       control: CGPoint(x: w - f, y: h))
        p.addLine(to: CGPoint(x: w - f, y: f))                           // right side
        p.addQuadCurve(to: CGPoint(x: w, y: 0),                           // outward flare → top-right
                       control: CGPoint(x: w - f, y: 0))
        p.closeSubpath()                                                  // top edge
        return p
    }
}


struct LegacyExpandedShape: Shape {
    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 30,
                               bottomTrailingRadius: 30, topTrailingRadius: 20, style: .continuous).path(in: rect)
    }
}
