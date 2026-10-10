import SwiftUI

/// Compact Alcove-style waveform bars (right wing of the collapsed island).
/// Uses a multi-frequency sine mix so it reads like a live spectrum without
/// needing an audio tap permission.
struct WaveformView: View {
    var isPlaying: Bool
    var barCount: Int = 5
    var color: Color = .white
    var maxHeight: CGFloat = 16
    var barWidth: CGFloat = 2.5
    var spacing: CGFloat = 2.2
    /// When false, draw a flat resting waveform.
    var enabled: Bool = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.04, paused: !isPlaying || !enabled)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    let h = barHeight(index: i, t: t)
                    Capsule(style: .continuous)
                        .fill(color.opacity(isPlaying && enabled ? 0.95 : 0.45))
                        .frame(width: barWidth, height: h)
                }
            }
            .frame(height: maxHeight)
        }
    }

    private func barHeight(index: Int, t: TimeInterval) -> CGFloat {
        guard isPlaying, enabled else {
            // Resting pattern — short center-weighted bars
            let rest: [CGFloat] = [0.35, 0.55, 0.8, 0.55, 0.35, 0.45, 0.3]
            let f = rest[index % rest.count]
            return max(3, maxHeight * f * 0.45)
        }
        // Multi-frequency mix for a livelier spectrum look
        let phase = Double(index) * 0.85
        let a = abs(sin(t * 5.2 + phase))
        let b = abs(sin(t * 3.1 + phase * 1.7))
        let c = abs(sin(t * 7.4 + phase * 0.4))
        let mix = (a * 0.5 + b * 0.3 + c * 0.2)
        // Emphasize center bars slightly
        let center = Double(barCount - 1) / 2
        let dist = abs(Double(index) - center) / max(center, 1)
        let weight = 1.0 - dist * 0.25
        return max(3, maxHeight * CGFloat(mix * weight))
    }
}

/// Wider expanded-card waveform strip under the progress bar.
struct ExpandedWaveform: View {
    var isPlaying: Bool
    var color: Color = .white
    var barCount: Int = 32

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: !isPlaying)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let spacing: CGFloat = 2
                let totalSpacing = spacing * CGFloat(barCount - 1)
                let barW = max(1.5, (geo.size.width - totalSpacing) / CGFloat(barCount))
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(0..<barCount, id: \.self) { i in
                        let phase = Double(i) * 0.35
                        let a = abs(sin(t * 4.5 + phase))
                        let b = abs(cos(t * 2.8 + phase * 1.3))
                        let mix = isPlaying ? (a * 0.65 + b * 0.35) : 0.12
                        Capsule(style: .continuous)
                            .fill(color.opacity(0.35 + mix * 0.55))
                            .frame(width: barW, height: max(3, geo.size.height * CGFloat(mix)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }
}
