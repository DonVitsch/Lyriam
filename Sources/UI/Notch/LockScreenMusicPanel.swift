import AppKit
import SwiftUI
import Combine

/// A deliberately separate, media-only surface. Clipboard, notes, files and
/// device controls are never hosted in a window visible without login.
@MainActor
final class LockScreenMusicPanelController {
    private let panel: LockScreenMediaPanel
    private let nowPlaying: NowPlayingMonitor
    private var mayPresent = false
    private var cancellable: AnyCancellable?
    private var screenObserver: NSObjectProtocol?

    init(nowPlaying: NowPlayingMonitor) {
        self.nowPlaying = nowPlaying
        panel = LockScreenMediaPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 148),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // Public AppKit API; no authentication or system settings are changed.
        panel.canBecomeVisibleWithoutLogin = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: LockScreenMusicView(nowPlaying: nowPlaying))
        cancellable = nowPlaying.$current.sink { [weak self] info in
            guard let self else { return }
            self.refresh(hasTrack: info?.title.isEmpty == false)
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func update(enabled: Bool, monitor: LockScreenMonitor) {
        mayPresent = enabled && monitor.canShowLockScreenMusic
        refresh()
    }

    func hide() {
        mayPresent = false
        panel.orderOut(nil)
    }

    private func refresh(hasTrack: Bool? = nil) {
        guard mayPresent, hasTrack ?? (nowPlaying.current?.title.isEmpty == false),
              let screen = NSScreen.screens.first else {
            panel.orderOut(nil)
            return
        }
        let size = panel.frame.size
        // Keep the card above the central login controls and below the notch.
        let topInset = max(screen.safeAreaInsets.top, 24) + 28
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2,
                                     y: screen.frame.maxY - topInset - size.height))
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}

private final class LockScreenMediaPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct LockScreenMusicView: View {
    @ObservedObject var nowPlaying: NowPlayingMonitor

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 13).fill(Color.white.opacity(0.08))
                if let art = nowPlaying.current?.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note").font(.system(size: 30)).foregroundStyle(.white.opacity(0.65))
                }
            }
            .frame(width: 110, height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill").font(.system(size: 8))
                    Text("LYRIAM").font(.system(size: 9, weight: .semibold)).tracking(1.6)
                }
                .foregroundStyle(.white.opacity(0.48))
                Text(nowPlaying.current?.title ?? "未在播放")
                    .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(.white)
                Text(nowPlaying.current?.artist ?? "")
                    .font(.system(size: 12)).lineLimit(1)
                    .foregroundStyle(.white.opacity(0.65))
                HStack(spacing: 28) {
                    mediaButton("backward.fill", label: "上一首", action: nowPlaying.previousTrack)
                    mediaButton(nowPlaying.current?.isPlaying == true ? "pause.fill" : "play.fill",
                                label: nowPlaying.current?.isPlaying == true ? "暂停" : "播放", action: nowPlaying.playPause)
                    mediaButton("forward.fill", label: "下一首", action: nowPlaying.nextTrack)
                }
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(19)
        .frame(width: 460, height: 148)
        .background(Color(white: 0.045).opacity(0.96), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }

    private func mediaButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(label)
        .help(label)
    }
}
