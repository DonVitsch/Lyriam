import SwiftUI

/// Clean Dynamic Island silhouette for Mac (Alcove / iPhone DI).
///
/// - Top edge is **full width** and flush with the screen top (no cut-out corners).
/// - Left/right sides drop nearly straight.
/// - Bottom corners use a continuous soft radius.
///
/// The old "outward flare" path inset the body and left transparent top corners;
/// when expanded those corners showed as ugly white arcs against the desktop.
struct DynamicIslandShape: Shape {
    /// Bottom corner radius.
    var bottomRadius: CGFloat = 22
    /// Optional tiny top corner radius (0 = perfectly flush with bezel).
    var topRadius: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, topRadius) }
        set {
            bottomRadius = newValue.first
            topRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let tr = min(max(topRadius, 0), min(w, h) / 2)
        let br = min(max(bottomRadius, 0), w / 2, h - tr)

        var p = Path()

        if tr < 0.5 {
            // Sharp flush top — classic Mac notch island.
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: w, y: 0))
            p.addLine(to: CGPoint(x: w, y: h - br))
            p.addQuadCurve(to: CGPoint(x: w - br, y: h),
                           control: CGPoint(x: w, y: h))
            p.addLine(to: CGPoint(x: br, y: h))
            p.addQuadCurve(to: CGPoint(x: 0, y: h - br),
                           control: CGPoint(x: 0, y: h))
            p.closeSubpath()
        } else {
            // Soft top corners (used lightly when expanded).
            p.move(to: CGPoint(x: 0, y: tr))
            p.addQuadCurve(to: CGPoint(x: tr, y: 0),
                           control: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: w - tr, y: 0))
            p.addQuadCurve(to: CGPoint(x: w, y: tr),
                           control: CGPoint(x: w, y: 0))
            p.addLine(to: CGPoint(x: w, y: h - br))
            p.addQuadCurve(to: CGPoint(x: w - br, y: h),
                           control: CGPoint(x: w, y: h))
            p.addLine(to: CGPoint(x: br, y: h))
            p.addQuadCurve(to: CGPoint(x: 0, y: h - br),
                           control: CGPoint(x: 0, y: h))
            p.closeSubpath()
        }
        return p
    }
}
