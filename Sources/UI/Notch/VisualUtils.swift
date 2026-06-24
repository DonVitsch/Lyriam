import SwiftUI
import AppKit
import CoreImage

// MARK: - Dominant color extraction (for album-art glow)

extension NSImage {
    /// Average color of the image, used to tint the island's glow background.
    func averageColor() -> Color? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cg = bitmap.cgImage else { return nil }
        let ci = CIImage(cgImage: cg)
        let extent = ci.extent
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ci,
            kCIInputExtentKey: CIVector(cgRect: extent),
        ]), let output = filter.outputImage else { return nil }

        var bitmapPixel = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(output,
                       toBitmap: &bitmapPixel,
                       rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        return Color(.sRGB,
                     red: Double(bitmapPixel[0]) / 255.0,
                     green: Double(bitmapPixel[1]) / 255.0,
                     blue: Double(bitmapPixel[2]) / 255.0,
                     opacity: 1.0)
    }
}

// MARK: - Color hex <-> string, and dark-background readability

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255,
                  opacity: 1)
    }

    func toHex() -> String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Brighten/cap so the color stays legible on the island's black background.
    func readableOnDark() -> Color {
        let ns = NSColor(self).usingColorSpace(.deviceRGB) ?? .white
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double(h), saturation: Double(min(s, 0.75)), brightness: Double(max(b, 0.8)))
    }
}

// MARK: - Marquee (single-line horizontal scrolling text)

struct Marquee: View {
    let text: String
    var font: Font = .system(size: 15, weight: .semibold)
    var color: Color = .white
    var speed: Double = 30 // points per second
    /// When false the scroll freezes (e.g. playback paused).
    var isPlaying: Bool = true

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var startDate = Date()    // anchor; reset on each new line
    @State private var pausedAt: Date?

    private let leadIn: Double = 1.2          // hold at the start before scrolling

    var body: some View {
        GeometryReader { geo in
            let needsScroll = textWidth > containerWidth + 1
            TimelineView(.animation(minimumInterval: 0.02, paused: !needsScroll || !isPlaying)) { timeline in
                let gap: CGFloat = 44
                let period = Double(textWidth + gap) / speed
                let elapsed = max(0, timeline.date.timeIntervalSince(startDate) - leadIn)
                let phase = needsScroll ? CGFloat((elapsed.truncatingRemainder(dividingBy: period)) / period) : 0
                let offset = -phase * (textWidth + gap)

                HStack(spacing: gap) {
                    label
                    if needsScroll { label }
                }
                .offset(x: needsScroll ? offset : 0)
                .frame(width: geo.size.width, height: geo.size.height,
                       alignment: needsScroll ? .leading : .center)  // .leading/.center both center vertically
                .clipped()
            }
            .onAppear { containerWidth = geo.size.width; resetScroll() }
            .onChange(of: geo.size.width) { _, w in containerWidth = w }
            .onChange(of: text) { _, _ in resetScroll() }   // new lyric line → start from the head
            .onChange(of: isPlaying) { _, playing in
                // Freeze while paused and resume from the same spot (shift the
                // anchor forward by the paused duration so it doesn't jump).
                if playing {
                    if let p = pausedAt { startDate = startDate.addingTimeInterval(Date().timeIntervalSince(p)); pausedAt = nil }
                } else {
                    pausedAt = Date()
                }
            }
        }
    }

    private func resetScroll() {
        startDate = Date()
        pausedAt = isPlaying ? nil : Date()
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { textWidth = g.size.width }
                        .onChange(of: text) { _, _ in textWidth = g.size.width }
                }
            )
    }
}
