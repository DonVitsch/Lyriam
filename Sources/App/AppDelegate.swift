import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let nowPlaying = NowPlayingMonitor()
    private let lyrics = LyricsRepository()
    private let sync = LyricsSyncEngine()
    private var panel: NotchPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var settingsHotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no Dock icon, menu-bar-only app

        let panel = NotchPanel { state in
            NotchView(nowPlaying: self.nowPlaying, lyrics: self.lyrics, sync: self.sync, state: state,
                      onOpenSettings: { [weak self] in self?.openSettings() })
        }
        panel.orderFrontRegardless()
        self.panel = panel

        setupMainMenu()      // registers ⌘, while the app is active
        setupStatusItem()
        observeNowPlaying()

        // System-wide ⌘, — the only way an accessory app can catch it, since it
        // never becomes the frontmost app.
        settingsHotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_Comma),
                                      modifiers: UInt32(cmdKey)) { [weak self] in
            self?.openSettings()
        }
    }

    /// A minimal main menu so the standard ⌘, opens Settings while the app is
    /// active (e.g. after opening Settings once from the menu bar icon).
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 Lyriam", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 440),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            window.title = "Lyriam 设置"
            window.contentView = NSHostingView(rootView: SettingsView())
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        // Become a regular app while Settings is open: shows in the Dock, can be
        // focused, and the standard ⌘, works while it's frontmost.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let bundle = Bundle.main
        if let iconPath = bundle.path(forResource: "AppIcon", ofType: "png"),
           let icon = NSImage(contentsOfFile: iconPath) {
            var scaledIcon = icon
            scaledIcon.size = NSSize(width: 18, height: 18)
            item.button?.image = scaledIcon
        } else {
            item.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Lyriam")
        }

        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let toggleItem = NSMenuItem(title: "显示/隐藏歌词岛", action: #selector(togglePanel), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    @objc private func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // Back to a dockless menu-bar app once Settings closes.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    private func observeNowPlaying() {
        nowPlaying.$current
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                guard let self else { return }
                guard let info, !info.title.isEmpty else {
                    self.sync.stop()
                    self.panel?.orderFrontRegardless()
                    return
                }
                self.lyrics.load(title: info.title, artist: info.artist)
            }
            .store(in: &cancellables)

        lyrics.$currentLines
            .receive(on: DispatchQueue.main)
            .sink { [weak self] lines in
                guard let self else { return }
                self.sync.start(lines: lines) { [weak self] in
                    self?.nowPlaying.current?.liveElapsedTime ?? 0
                }
            }
            .store(in: &cancellables)
    }
}
