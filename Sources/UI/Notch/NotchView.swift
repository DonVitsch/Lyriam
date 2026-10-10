import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Alcove-style Dynamic Island with Lyriam lyrics always on:
/// - Collapsed: artwork · camera · waveform + **lyric marquee**
/// - Expanded: media card + **synced lyrics**
struct NotchView: View {
    @ObservedObject var nowPlaying: NowPlayingMonitor
    @ObservedObject var lyrics: LyricsRepository
    @ObservedObject var sync: LyricsSyncEngine
    @ObservedObject var state: IslandState
    @ObservedObject var activities: IslandActivityCenter
    @ObservedObject var systemControls: SystemControlsMonitor
    @ObservedObject var headphones: BluetoothDevicesMonitor
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var fileShelf: FileShelfStore
    @ObservedObject var focusTimer: FocusTimerStore
    @ObservedObject var notes: NotesStore
    @ObservedObject var camera: CameraMirrorController
    @ObservedObject var network: NetworkDashboardMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var settings = AppSettings.shared
    var onOpenSettings: () -> Void = {}

    @State private var glow: Color = .clear
    private var barHeight: CGFloat { state.barHeight }

    private var isPlaying: Bool { nowPlaying.current?.isPlaying ?? false }
    private var hasTrack: Bool {
        guard let t = nowPlaying.current?.title else { return false }
        return !t.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if state.expanded {
                // Original v0.1 transparent menu-bar strip: never paint this black.
                Color.clear.frame(height: state.menuBarZone)
                expandedContent
                    .frame(width: NotchPanel.expandedWidth, height: NotchPanel.cardHeight)
                    .clipped()
                    .background(
                        ZStack {
                            Color.black
                            RadialGradient(colors: [glow.opacity(0.55), .clear],
                                           center: .topLeading, startRadius: 10, endRadius: 420)
                            LinearGradient(colors: [glow.opacity(0.25), .clear],
                                           startPoint: .bottomTrailing, endPoint: .center)
                        }
                    )
                    .clipShape(LegacyExpandedShape())
                    .transition(.opacity)
            } else {
                HStack(spacing: 0) {
                    Color.clear.frame(width: state.barLeadingInset)
                    ZStack {
                        barBackground
                        Group {
                            if let activity = activities.current {
                                IslandActivityView(activity: activity, state: state, feedbackSequence: activities.feedbackSequence)
                            } else if settings.islandMode == .notchCentered {
                                centeredBar
                            } else {
                                leftSafeBar
                            }
                        }
                        .frame(width: state.barWidth, height: state.barHeight)
                        .mask(barBackground)
                    }
                    .frame(width: state.barWidth, height: state.barHeight)
                    Spacer(minLength: 0)
                }
                .frame(height: state.barHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        // The window transition is composited by AppKit, without a second layout animation.
        .animation(nil, value: state.expanded)
        .animation(.easeInOut(duration: 0.18), value: activities.current?.key)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $state.isReceivingDrop, perform: receiveFiles)
        .onChange(of: state.isReceivingDrop) { _, targeted in
            if targeted && settings.fileShelfEnabled {
                NotificationCenter.default.post(name: .lyriamOpenIslandPage, object: IslandPage.files)
            }
        }
        .task(id: nowPlaying.current?.artwork.map { ObjectIdentifier($0) }) {
            glow = nowPlaying.current?.artwork?.averageColor() ?? .clear
        }
    }

    // MARK: - Collapsed

    /// leftSafe mode: lyrics ticker · album art · [camera] · equalizer cap.
    private var leftSafeBar: some View {
        let artSize = barHeight - 2
        return HStack(spacing: 0) {
            leftWing(artSize: artSize).frame(width: state.leftWingWidth)
            Color.clear.frame(width: state.gap)
            WaveformView(isPlaying: isPlaying, barCount: 4, maxHeight: 15, barWidth: 3, spacing: 3, enabled: settings.useLiveWaveform)
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
                .frame(height: centeredTopHeight, alignment: .top)

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
        let indicatorSize = min(state.leftWingWidth - 16, centeredTopHeight - 2)
        return HStack(spacing: 0) {
            artwork(size: indicatorSize, corner: 8)
            .padding(.leading, 12)
            .frame(width: state.leftWingWidth)

            Color.clear.frame(width: state.gap)   // physical camera

            WaveformView(isPlaying: isPlaying, barCount: 4, maxHeight: 15, barWidth: 3, spacing: 3, enabled: settings.useLiveWaveform)
            .padding(.trailing, 12)
            .frame(width: state.rightCapWidth)
        }
        .frame(height: centeredTopHeight, alignment: .center)
    }

    private var centeredTopHeight: CGFloat { min(state.menuBarZone + 4, barHeight - 20) }

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

    private var availablePages: [IslandPage] {
        IslandPage.allCases.filter {
            ($0 != .clipboard || settings.clipboardEnabled) && ($0 != .files || settings.fileShelfEnabled)
        }
    }

    private func receiveFiles(_ providers: [NSItemProvider]) -> Bool {
        guard settings.fileShelfEnabled else { return false }
        let supported = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !supported.isEmpty else { return false }
        for provider in supported {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let value = item as? URL { url = value }
                else if let value = item as? Data { url = URL(dataRepresentation: value, relativeTo: nil) }
                else if let value = item as? String { url = URL(string: value) }
                else { url = nil }
                guard let url, url.isFileURL else { return }
                Task { @MainActor in _ = fileShelf.add([url]) }
            }
        }
        NotificationCenter.default.post(name: .lyriamOpenIslandPage, object: IslandPage.files)
        return true
    }

    private var indicatorSize: CGFloat {
        max(min(state.menuBarZone - 12, 18), 14)
    }

    private var collapsedFontSize: CGFloat {
        let base = settings.lyricFontSize
        if currentLyricLine != nil {
            return isCJKLyric ? min(base, 14) : min(base * 0.85, 13)
        }
        return 11
    }

    private var collapsedText: String {
        if settings.showLyricsOnIsland, let line = currentLyricLine, !line.isEmpty {
            return line
        }
        guard let info = nowPlaying.current, !info.title.isEmpty else {
            return "未在播放"
        }
        return info.artist.isEmpty ? info.title : "\(info.title)  ·  \(info.artist)"
    }

    // MARK: - Expanded

    private var expandedContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    ForEach(availablePages) { page in
                        Button {
                            NotificationCenter.default.post(name: .lyriamOpenIslandPage, object: page)
                        } label: {
                            Image(systemName: page.symbol)
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 32, height: 26)
                                .foregroundStyle(state.selectedPage == page ? .white : .white.opacity(0.65))
                                .background(state.selectedPage == page ? .white.opacity(0.10) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(IslandPressStyle()).help(page.title)
                        .accessibilityLabel(page.title)
                    }
                    if case let .hud(kind, value, muted, atLimit) = activities.current {
                        ExpandedHUDFeedback(kind: kind, value: value, muted: muted,
                                            atLimit: atLimit, sequence: activities.feedbackSequence)
                            .padding(.leading, 5)
                    } else {
                        Text(state.selectedPage.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7)).padding(.leading, 5)
                    }
                    Spacer(minLength: 0)
                    if settings.showNetworkDashboard {
                        NetworkDashboardStatusView(monitor: network)
                        .frame(maxWidth: 180, alignment: .trailing)
                        .padding(.trailing, 10)
                    }
                    chromeButtons
                }
                .padding(.bottom, 10)

                Group {
                    switch state.selectedPage {
                    case .music:
                        if settings.showLyricsInExpanded {
                            HStack(alignment: .top, spacing: 18) {
                                playerColumn.frame(width: 410, alignment: .leading)
                                lyricsColumn.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            }
                        } else {
                            playerColumn.frame(maxWidth: .infinity)
                        }
                    case .controls:
                        SystemControlsView(controls: systemControls, battery: battery)
                    case .devices:
                        HeadphonesView(monitor: headphones)
                    case .clipboard:
                        ClipboardHistoryView(store: clipboard)
                    case .files:
                        FileShelfView(store: fileShelf)
                    case .timer:
                        FocusTimerView(store: focusTimer)
                    case .notes:
                        QuickNotesView(store: notes)
                    case .mirror:
                        CameraMirrorView(controller: camera)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(.opacity)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var chromeButtons: some View {
        HStack(spacing: 10) {
            iconButton("gearshape", help: "设置") { onOpenSettings() }
            iconButton(state.pinned ? "pin.fill" : "pin",
                       help: state.pinned ? "取消固定" : "固定展开",
                       accent: state.pinned ? Color.yellow : nil) {
                state.pinned.toggle()
                if state.pinned { state.expanded = true }
            }
            iconButton("power", help: "退出 Lyriam") { NSApp.terminate(nil) }
        }
    }

    private var playerColumn: some View {
        HStack(spacing: 18) {
            artwork(size: 168, corner: 16)
            VStack(alignment: .leading, spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(nowPlaying.current?.title ?? "未在播放")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(nowPlaying.current?.artist ?? "")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                progressBar
                controls
                if settings.useLiveWaveform {
                    ExpandedWaveform(isPlaying: isPlaying, color: .white.opacity(0.8), barCount: 28)
                        .frame(height: 12)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private var lyricsColumn: some View {
        Group {
            if lyrics.isLoading {
                Text("正在加载歌词…")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.4))
            } else if lyrics.currentLines.isEmpty {
                Text("暂无歌词")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                let idx = sync.currentIndex ?? -1
                VStack(alignment: .center, spacing: 10) {
                    ForEach(visibleWindow(around: idx), id: \.self) { i in
                        Text(lyrics.currentLines[i].text)
                            .font(settings.font(
                                size: i == idx ? 17 : 13,
                                weight: i == idx ? .bold : .regular
                            ))
                            .foregroundStyle(i == idx ? lyricTextColor : Color.white.opacity(0.38))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .fixedSize(horizontal: false, vertical: true)
                            .animation(.easeInOut(duration: 0.2), value: idx)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 8)
    }

    // MARK: - Shared

    private var lyricTextColor: Color {
        settings.lyricColor(artworkColor: glow == .clear ? nil : glow)
    }

    private var currentLyricLine: String? {
        guard let idx = sync.currentIndex, lyrics.currentLines.indices.contains(idx) else { return nil }
        let t = lyrics.currentLines[idx].text
        return t.isEmpty ? nil : t
    }

    private var isCJKLyric: Bool {
        guard currentLyricLine != nil else { return false }
        return collapsedText.unicodeScalars.contains { s in
            (0x4E00...0x9FFF).contains(s.value)
                || (0x3040...0x30FF).contains(s.value)
                || (0xAC00...0xD7A3).contains(s.value)
        }
    }

    private func artwork(size: CGFloat, corner: CGFloat) -> some View {
        Group {
            if let art = nowPlaying.current?.artwork {
                Image(nsImage: art).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: hasTrack ? "music.note" : "moon.zzz")
                        .font(.system(size: size * 0.36))
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
                    Capsule().fill(Color.white.opacity(0.14))
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: max(3, geo.size.width * fraction))
                }
            }
            .frame(height: 3.5)
            HStack {
                Text(timeString(elapsed))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.42))
                Spacer()
                Text(timeString(duration))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.42))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 26) {
            Spacer(minLength: 0)
            controlButton("backward.fill", size: 14) { nowPlaying.previousTrack() }
            controlButton(isPlaying ? "pause.fill" : "play.fill", size: 18) {
                nowPlaying.playPause()
            }
            controlButton("forward.fill", size: 14) { nowPlaying.nextTrack() }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func controlButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(IslandPressStyle())
    }

    private func iconButton(_ symbol: String, help: String, accent: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent ?? Color.white.opacity(0.5))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func visibleWindow(around idx: Int) -> [Int] {
        let count = lyrics.currentLines.count
        guard count > 0 else { return [] }
        let center = idx < 0 ? 0 : idx
        let start = max(0, center - 1)
        let end = min(count - 1, center + 1)
        return Array(start...end)
    }

    private func timeString(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension Notification.Name {
    static let lyriamShowHeadphoneConnection = Notification.Name("lyriamShowHeadphoneConnection")
    static let lyriamCollapseIsland = Notification.Name("lyriamCollapseIsland")
    static let lyriamBeginFilePicker = Notification.Name("lyriamBeginFilePicker")
    static let lyriamEndFilePicker = Notification.Name("lyriamEndFilePicker")
    static let lyriamOpenIslandPage = Notification.Name("lyriamOpenIslandPage")
}

struct IslandPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .scaleEffect(reduceMotion ? 1 : configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
