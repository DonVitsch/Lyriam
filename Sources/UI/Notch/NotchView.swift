import SwiftUI
import AppKit

struct NotchView: View {
    @ObservedObject var nowPlaying: NowPlayingMonitor
    @ObservedObject var lyrics: LyricsRepository
    @ObservedObject var sync: LyricsSyncEngine
    @ObservedObject var state: IslandState
    @ObservedObject private var settings = AppSettings.shared
    var onOpenSettings: () -> Void = {}

    @State private var glow: Color = .clear

    private var barHeight: CGFloat { state.barHeight }
    private let cardHeight = NotchPanel.cardHeight

    var body: some View {
        VStack(spacing: 0) {
            if state.expanded {
                Color.clear.frame(height: state.menuBarZone)   // menu bar shows through here
                card
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                barRow
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: state.expanded)
        .task(id: nowPlaying.current?.artwork.map { ObjectIdentifier($0) }) {
            glow = nowPlaying.current?.artwork?.averageColor() ?? .clear
        }
    }

    // MARK: - Menu-bar row: two wings wrapping the notch

    /// One continuous black bar, entirely left of the camera (its right edge
    /// hugs the notch). Right-aligned within the window so that when the window
    /// grows wider on expand, the bar stays pinned at the top-right.
    private var barRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: state.barLeadingInset)   // keeps bar aligned to notch
            barContent.frame(width: state.barWidth)
            Spacer(minLength: 0)
        }
        .frame(height: barHeight)
    }

    /// One continuous black bar: lyrics · album art · [camera, blacked out] · equalizer.
    /// The ticker and equalizer are centered in the top menu-bar band so they
    /// align with the real menu items; the enlarged album art hangs below.
    private var barContent: some View {
        ZStack {
            barBackground
            if settings.islandMode == .notchCentered {
                centeredBar
            } else {
                leftSafeBar
            }
        }
        .frame(height: barHeight)
    }

    /// leftSafe mode: lyrics ticker · album art · [camera] · equalizer cap.
    private var leftSafeBar: some View {
        let artSize = barHeight - 4
        return HStack(spacing: 0) {
            leftWing(artSize: artSize).frame(width: state.leftWingWidth)
            Color.clear.frame(width: state.gap)
            PlayingBars(isPlaying: nowPlaying.current?.isPlaying ?? false)
                .frame(height: state.menuBarZone)
                .frame(maxHeight: .infinity, alignment: .top)
                .frame(width: state.rightCapWidth, alignment: .center)   // centered in the right cap
        }
    }

    /// notchCentered mode: album art top-left (hugging camera), equalizer at the
    /// far-right edge, and the lyric/title text centered below the camera.
    private var centeredBar: some View {
        VStack(spacing: 0) {
            // Lock both indicators into the real menu-bar band. Previously this
            // row was vertically centered by the surrounding ZStack, which made
            // it fall into the lyric area.
            centeredTopRow
                .frame(height: state.menuBarZone, alignment: .top)

            // Keep a single compact lyric line immediately below the camera.
            Text(collapsedText)
                .font(settings.font(size: centeredFontSize))
                .foregroundStyle(lyricTextColor)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 20)
                .padding(.bottom, 2)
        }
        .frame(height: barHeight, alignment: .top)
    }

    private var centeredTopRow: some View {
        let indicatorSize = max(state.menuBarZone - 8, 22)
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                artwork(size: indicatorSize, corner: 7)
            }
            .frame(width: state.leftWingWidth)
            .padding(.trailing, 4)

            Color.clear.frame(width: state.gap)   // physical camera

            HStack(spacing: 0) {
                PlayingBars(isPlaying: nowPlaying.current?.isPlaying ?? false)
                Spacer(minLength: 0)
            }
            .frame(width: state.rightCapWidth)
            .padding(.leading, 6)
        }
        .frame(height: state.menuBarZone, alignment: .center)
    }

    private var centeredFontSize: CGFloat {
        min(settings.lyricFontSize, 16)
    }

    private func leftWing(artSize: CGFloat) -> some View {
        // Showing a lyric line (any language): center vertically in the whole
        // bar + larger font. Showing the title (no lyrics): keep it in the top
        // menu-bar band, small, aligned with the menu items.
        let lyricMode = currentLyricLine != nil
        let base = settings.lyricFontSize
        let fontSize: CGFloat = lyricMode ? (isCJKLyric ? base : base * 0.82) : 13
        return ZStack {
            // Enlarged album art, hugging the camera (trailing), centered vertically.
            artwork(size: artSize, corner: 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            Marquee(text: collapsedText,
                    font: settings.font(size: fontSize),
                    color: lyricTextColor,
                    speed: settings.marqueeSpeed,
                    isPlaying: nowPlaying.current?.isPlaying ?? false)
                .frame(height: lyricMode ? barHeight : state.menuBarZone)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: lyricMode ? .leading : .topLeading)   // .leading centers vertically
                .padding(.trailing, artSize + 12)
        }
        .padding(.leading, 16)
    }

    /// Lyric text color per settings (custom color or album-art theme color).
    private var lyricTextColor: Color {
        settings.lyricColor(artworkColor: glow == .clear ? nil : glow)
    }

    /// True when the bar is showing an actual lyric line written in CJK script.
    private var isCJKLyric: Bool {
        guard currentLyricLine != nil else { return false }
        return collapsedText.unicodeScalars.contains { s in
            (0x4E00...0x9FFF).contains(s.value) ||   // CJK unified ideographs
            (0x3040...0x30FF).contains(s.value) ||   // Japanese kana
            (0xAC00...0xD7A3).contains(s.value)      // Korean hangul
        }
    }

    @ViewBuilder
    private var barBackground: some View {
        if settings.islandMode == .notchCentered && !state.expanded {
            CenteredIslandShape(topFlare: 12, bottomRadius: 20)
                .fill(Color.black)
        } else {
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: state.expanded ? 0 : 16,
                bottomTrailingRadius: state.expanded ? 0 : 16,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(Color.black)
        }
    }

    private var collapsedText: String {
        if let line = currentLyricLine { return line }
        guard let info = nowPlaying.current, !info.title.isEmpty else { return "未在播放" }
        return info.artist.isEmpty ? info.title : "\(info.title) - \(info.artist)"
    }

    private var currentLyricLine: String? {
        guard let idx = sync.currentIndex, lyrics.currentLines.indices.contains(idx) else { return nil }
        return lyrics.currentLines[idx].text
    }

    // MARK: - Dropped card

    private var card: some View {
        HStack(spacing: 18) {
            playerPane
            Divider().overlay(Color.white.opacity(0.12))
            lyricsPane
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                Color.black
                RadialGradient(colors: [glow.opacity(0.55), .clear],
                               center: .topLeading, startRadius: 10, endRadius: 420)
                LinearGradient(colors: [glow.opacity(0.25), .clear],
                               startPoint: .bottomTrailing, endPoint: .center)
            }
        )
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: 20, bottomLeadingRadius: 30,
            bottomTrailingRadius: 30, topTrailingRadius: 20, style: .continuous))
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 14) {
                settingsButton
                pinButton
                quitButton
            }
            .padding(10)
        }
    }

    private var settingsButton: some View {
        Button { onOpenSettings() } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
        }
        .buttonStyle(.plain)
        .help("设置")
    }

    private var pinButton: some View {
        Button { state.pinned.toggle() } label: {
            Image(systemName: state.pinned ? "pin.fill" : "pin")
                .font(.system(size: 12))
                .foregroundStyle(state.pinned ? Color.yellow : .white.opacity(0.6))
        }
        .buttonStyle(.plain)
        .help(state.pinned ? "取消固定" : "固定展开")
    }

    private var quitButton: some View {
        Button { NSApp.terminate(nil) } label: {
            Image(systemName: "power")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
        .buttonStyle(.plain)
        .help("退出 Lyriam")
    }

    private var playerPane: some View {
        HStack(spacing: 18) {
            artwork(size: 180, corner: 16)
                .id(nowPlaying.current?.title ?? "")
                .transition(.scale.combined(with: .opacity))
            VStack(alignment: .leading, spacing: 8) {
                Text(nowPlaying.current?.title ?? "未在播放")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white).lineLimit(1)
                Text(nowPlaying.current?.artist ?? "")
                    .font(.system(size: 15)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                progressBar
                controls
            }
            .frame(width: 230, alignment: .leading)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: nowPlaying.current?.title)
    }

    private func artwork(size: CGFloat, corner: CGFloat) -> some View {
        Group {
            if let art = nowPlaying.current?.artwork {
                Image(nsImage: art).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    private var progressBar: some View {
        let elapsed = nowPlaying.current?.liveElapsedTime ?? 0
        let duration = nowPlaying.current?.duration ?? 0
        let fraction = duration > 0 ? min(max(elapsed / duration, 0), 1) : 0
        return VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule().fill(Color.white.opacity(0.9)).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 5)
            HStack {
                Text(timeString(elapsed)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text(timeString(duration)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 28) {
            Spacer()
            controlButton("backward.fill", size: 18) { nowPlaying.previousTrack() }
            controlButton((nowPlaying.current?.isPlaying ?? false) ? "pause.fill" : "play.fill", size: 22) {
                nowPlaying.playPause()
            }
            controlButton("forward.fill", size: 18) { nowPlaying.nextTrack() }
            Spacer()
        }
        .padding(.top, 2)
    }

    private func controlButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size)).foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private var lyricsPane: some View {
        lyricLines
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.top, 28)   // nudge the lyric block downward
    }

    @ViewBuilder
    private var lyricLines: some View {
        if lyrics.isLoading {
            Text("正在加载歌词…").font(.system(size: 16)).foregroundStyle(.white.opacity(0.4))
        } else if lyrics.currentLines.isEmpty {
            Text("暂无歌词").font(.system(size: 16)).foregroundStyle(.white.opacity(0.4))
        } else {
            let idx = sync.currentIndex ?? -1
            VStack(alignment: .leading, spacing: 12) {
                ForEach(visibleWindow(around: idx), id: \.self) { i in
                    Text(lyrics.currentLines[i].text)
                        .font(settings.font(size: i == idx ? 23 : 17, weight: i == idx ? .bold : .regular))
                        .foregroundStyle(i == idx ? lyricTextColor : Color.white.opacity(0.45))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .animation(.easeInOut(duration: 0.25), value: idx)
                }
            }
        }
    }

    private func visibleWindow(around idx: Int) -> [Int] {
        let count = lyrics.currentLines.count
        guard count > 0 else { return [] }
        let center = idx < 0 ? 0 : idx
        let start = max(0, center - 1)
        let end = min(count - 1, start + 2)
        return Array(start...end)
    }

    private func timeString(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Centered island silhouette: a full-width top band flows outward into the
/// menu bar, then turns inward with two concave shoulder curves. The hanging
/// body finishes with Apple's softer continuous-looking lower corners.
/// Notch-style island: top edge flush with the screen top and full width, with
/// small OUTWARD-flaring fillets at the two top corners (so it grows smoothly
/// out of the menu bar, not an inward dent), and Apple-style rounded corners at
/// the bottom. One continuous shape.
private struct CenteredIslandShape: Shape {
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

/// Animated equalizer bars shown in the right wing.
struct PlayingBars: View {
    var isPlaying: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: !isPlaying)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<4, id: \.self) { i in
                    let h = isPlaying ? (4 + 11 * abs(sin(t * 4 + Double(i) * 0.9))) : 4
                    Capsule().fill(Color.white.opacity(0.9)).frame(width: 3, height: h)
                }
            }
            .frame(width: 24, height: 18)
        }
    }
}
