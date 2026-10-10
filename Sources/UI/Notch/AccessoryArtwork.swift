import SwiftUI

/// Vector artwork traced from the user's small AirPods reference; sharp at every scale.
struct AirPodsLogo: View {
    var body: some View {
        AirPodsLogoShape().fill(style: FillStyle(eoFill: true))
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

private struct AirPodsLogoShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Unified outlines avoid holes where each stem meets the earbud.
        p.move(to: CGPoint(x: 17, y: 15))
        p.addCurve(to: CGPoint(x: 10, y: 3), control1: CGPoint(x: 20, y: 9), control2: CGPoint(x: 15, y: 3))
        p.addCurve(to: CGPoint(x: 10, y: 19), control1: CGPoint(x: -1, y: 3), control2: CGPoint(x: -1, y: 19))
        p.addLine(to: CGPoint(x: 12, y: 19))
        p.addLine(to: CGPoint(x: 12, y: 34.5))
        p.addQuadCurve(to: CGPoint(x: 17, y: 34.5), control: CGPoint(x: 14.5, y: 39.5))
        p.closeSubpath()
        p.move(to: CGPoint(x: 25, y: 15))
        p.addCurve(to: CGPoint(x: 32, y: 3), control1: CGPoint(x: 22, y: 9), control2: CGPoint(x: 27, y: 3))
        p.addCurve(to: CGPoint(x: 32, y: 19), control1: CGPoint(x: 43, y: 3), control2: CGPoint(x: 43, y: 19))
        p.addLine(to: CGPoint(x: 30, y: 19))
        p.addLine(to: CGPoint(x: 30, y: 34.5))
        p.addQuadCurve(to: CGPoint(x: 25, y: 34.5), control: CGPoint(x: 27.5, y: 39.5))
        p.closeSubpath()
        var leftVent = Path(ellipseIn: CGRect(x: 5, y: 7, width: 5.2, height: 2.9))
        leftVent = leftVent.applying(CGAffineTransform(translationX: -7.6, y: -8.4)
            .concatenating(CGAffineTransform(rotationAngle: -.pi / 6))
            .concatenating(CGAffineTransform(translationX: 7.6, y: 8.4)))
        p.addPath(leftVent)
        p.addEllipse(in: CGRect(x: 13.5, y: 10, width: 2.2, height: 4.5))
        p.addEllipse(in: CGRect(x: 33, y: 7, width: 2.6, height: 5))
        p.addEllipse(in: CGRect(x: 27, y: 9, width: 3.8, height: 2.6))
        return p.applying(CGAffineTransform(scaleX: rect.width / 42, y: rect.height / 42)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

struct ChargingLevelBar: View {
    let value: Double
    let connected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let blue = Color(red: 0.16, green: 0.59, blue: 1)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !connected || reduceMotion)) { timeline in
            Canvas { context, size in
                let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
                context.fill(track, with: .color(blue.opacity(0.18)))
                let filled = CGRect(x: 0, y: 0, width: size.width * min(max(value, 0), 1), height: size.height)
                guard filled.width > 0 else { return }
                let fill = Path(roundedRect: filled, cornerRadius: size.height / 2)
                context.fill(fill, with: .linearGradient(Gradient(colors: [blue, Color(red: 0.32, green: 0.8, blue: 1)]), startPoint: .zero, endPoint: CGPoint(x: filled.width, y: 0)))
                if connected && !reduceMotion {
                    let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    let x = CGFloat(phase) * (filled.width + 42) - 42
                    context.clip(to: fill)
                    context.fill(Path(CGRect(x: x, y: 0, width: 42, height: size.height)), with: .linearGradient(Gradient(colors: [.clear, .white.opacity(0.9), .clear]), startPoint: CGPoint(x: x, y: 0), endPoint: CGPoint(x: x + 42, y: 0)))
                }
            }
        }.accessibilityLabel("电池电量 \(Int(value * 100))%")
    }
}
