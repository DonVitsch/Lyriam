import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let nowPlaying = NowPlayingMonitor()
    private let lyrics = LyricsRepository()
    private let sync = LyricsSyncEngine()
    private let activities = IslandActivityCenter()
    private let systemControls = SystemControlsMonitor()
    private let headphones = BluetoothDevicesMonitor()
    private let headphonePopup = HeadphoneConnectionPopupController()
    private let battery = BatteryMonitor()
    private let clipboard = ClipboardStore()
    private let fileShelf = FileShelfStore()
    private let focusTimer = FocusTimerStore()
    private let notes = NotesStore()
    private let camera = CameraMirrorController()
    private let network = NetworkDashboardMonitor.shared
    private let systemStatus = SystemStatusMonitor()
    private let lockMonitor = LockScreenMonitor()
    private lazy var lockScreenMusic = LockScreenMusicPanelController(nowPlaying: nowPlaying)
    private var panel: NotchPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var settingsHotKey: GlobalHotKey?
    private var clipboardHotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        lockMonitor.start()

        let panel = NotchPanel { state in
            NotchView(
                nowPlaying: self.nowPlaying,
                lyrics: self.lyrics,
                sync: self.sync,
                state: state,
                activities: self.activities,
                systemControls: self.systemControls,
                headphones: self.headphones,
                battery: self.battery,
                clipboard: self.clipboard,
                fileShelf: self.fileShelf,
                focusTimer: self.focusTimer,
                notes: self.notes,
                camera: self.camera,
                network: self.network,
                onOpenSettings: { [weak self] in self?.openSettings() }
            )
        }
        panel.onSwipeSkipNext = { [weak self] in self?.nowPlaying.nextTrack() }
        panel.onSwipeSkipPrevious = { [weak self] in self?.nowPlaying.previousTrack() }
        self.panel = panel
        panel.onPresentationChange = { [weak self] in
            self?.syncHeadphonePopup()
            self?.syncExpandedTools()
        }
        panel.isPointerOverAccessory = { [weak self] in self?.headphonePopup.isPointerInside ?? false }
        panel.setSessionProtected(lockMonitor.isSessionProtected)
        panel.showIfAllowed()
        lockMonitor.onStateChange = { [weak self] in self?.syncSessionState() }
        panel.state.$selectedPage.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncExpandedTools() }.store(in: &cancellables)
        syncSessionState()

        NotificationCenter.default.addObserver(
            forName: .lyriamCollapseIsland,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel?.state.pinned = false
                self?.panel?.setExpanded(false)
            }
        }

        NotificationCenter.default.addObserver(forName: .lyriamOpenIslandPage, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                if let page = note.object as? IslandPage { self?.panel?.openPage(page) }
            }
        }
        NotificationCenter.default.addObserver(forName: .lyriamShowHeadphoneConnection, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                if let device = note.object as? HeadphoneDevice {
                    self?.showHeadphoneConnection(device, connected: device.isConnected)
                }
            }
        }
        NotificationCenter.default.addObserver(forName: .lyriamBeginFilePicker, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel?.state.isPresentingFilePicker = true }
        }
        NotificationCenter.default.addObserver(forName: .lyriamEndFilePicker, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel?.state.isPresentingFilePicker = false }
        }
        startActivities()
        setupMainMenu()
        setupStatusItem()
        observeNowPlaying()
        observeSettings()

        settingsHotKey = GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_Comma),
            modifiers: UInt32(cmdKey)
        ) { [weak self] in
            self?.openSettings()
        }
        clipboardHotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            guard AppSettings.shared.clipboardEnabled else { return }
            self?.panel?.openPage(.clipboard)
        }
    }

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
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.title = "Lyriam"
            window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(rootView: SettingsView())
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func setupStatusItem() {
        applyMenuBarVisibility()
    }

    private func applyMenuBarVisibility() {
        if AppSettings.shared.hideMenuBarIcon {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
            }
            return
        }
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let bundle = Bundle.main
        if let iconPath = bundle.path(forResource: "AppIcon", ofType: "png"),
           let icon = NSImage(contentsOfFile: iconPath) {
            icon.size = NSSize(width: 18, height: 18)
            item.button?.image = icon
        } else {
            item.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Lyriam")
        }

        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let toggleItem = NSMenuItem(title: "显示 / 隐藏灵动岛", action: #selector(togglePanel), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        let expandItem = NSMenuItem(title: "展开 / 收起", action: #selector(toggleExpand), keyEquivalent: "")
        expandItem.target = self
        menu.addItem(expandItem)
        let headphonesItem = NSMenuItem(title: "耳机", action: #selector(openHeadphones), keyEquivalent: "")
        headphonesItem.target = self
        menu.addItem(headphonesItem)
        let clipboardItem = NSMenuItem(title: "剪贴板  ⌃⌥V", action: #selector(openClipboard), keyEquivalent: "")
        clipboardItem.target = self
        menu.addItem(clipboardItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    private func startActivities() {
        systemStatus.onCapsLockChange = { [weak self] enabled in
            guard let self, AppSettings.shared.showCapsLockActivity, !self.lockMonitor.isSessionProtected else { return }
            self.activities.present(.capsLock(enabled))
        }
        systemStatus.onNetworkChange = { [weak self] connected in
            guard let self, AppSettings.shared.showNetworkActivity, !self.lockMonitor.isSessionProtected else { return }
            self.activities.present(.network(connected))
        }
        focusTimer.onFinished = { [weak self] in
            guard let self, !self.lockMonitor.isSessionProtected else { return }
            self.activities.present(.timerFinished)
            NSSound(named: "Glass")?.play()
        }
        systemControls.onHUD = { [weak self] kind, value, muted, atLimit in
            let settings = AppSettings.shared
            guard kind == .volume ? settings.showVolumeHUD : settings.showBrightnessHUD else { return }
            self?.activities.present(.hud(kind, value, muted, atLimit: atLimit))
        }
        headphones.onConnectionChange = { [weak self] device, connected in
            self?.showHeadphoneConnection(device, connected: connected)
        }
        headphones.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] devices in
                for device in devices { self?.headphonePopup.updateDevice(device) }
            }
            .store(in: &cancellables)
        battery.onChange = { [weak self] connected, percentage in
            guard AppSettings.shared.showChargingActivity else { return }
            self?.activities.present(.power(connected, percentage))
        }
        clipboard.enabled = AppSettings.shared.clipboardEnabled
        systemControls.start()
        MediaKeyHUDController.shared.canPresentHUD = { [weak self] in
            self?.panel?.canPresentAccessories == true && self?.lockMonitor.isSessionProtected == false
        }
        MediaKeyHUDController.shared.start(controls: systemControls)
        headphones.start()
        battery.start()
        clipboard.start()
        systemStatus.start()
        focusTimer.startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        systemControls.stop()
        MediaKeyHUDController.shared.stop()
        headphones.stop()
        battery.stop()
        clipboard.stop()
        activities.clear()
        headphonePopup.dismiss(animated: false)
        systemStatus.stop()
        focusTimer.stop()
        notes.stop()
        camera.stop()
        network.stop()
        lockMonitor.stop()
        lockScreenMusic.hide()
    }

    private func syncExpandedTools() {
        let visible = panel?.canPresentAccessories == true && panel?.state.expanded == true
            && !lockMonitor.isSessionProtected
        camera.setPageVisible(visible && panel?.state.selectedPage == .mirror)
        network.setActive(visible && AppSettings.shared.showNetworkDashboard)
    }

    private func syncSessionState() {
        panel?.setSessionProtected(lockMonitor.isSessionProtected)
        camera.setScreenLocked(lockMonitor.isSessionProtected)
        if lockMonitor.isSessionProtected { activities.clear(); headphonePopup.dismiss(animated: false) }
        syncExpandedTools()
        lockScreenMusic.update(enabled: AppSettings.shared.showLockScreenMusic, monitor: lockMonitor)
    }

    private func showHeadphoneConnection(_ device: HeadphoneDevice, connected: Bool) {
        guard AppSettings.shared.showHeadphoneActivity, let panel,
              panel.prepareForAccessoryPresentation(), let screen = panel.accessoryScreen else { return }
        headphonePopup.present(device: device, connected: connected,
                               anchorFrame: panel.accessoryAnchorFrame, screen: screen)
    }

    private func syncHeadphonePopup() {
        guard let panel, panel.canPresentAccessories, let screen = panel.accessoryScreen else {
            headphonePopup.dismiss(animated: false)
            return
        }
        headphonePopup.updateAnchor(anchorFrame: panel.accessoryAnchorFrame, screen: screen)
    }

    private func observeSettings() {
        AppSettings.shared.$showNetworkDashboard.receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                self.syncExpandedTools()
            }.store(in: &cancellables)
        AppSettings.shared.$showLockScreenMusic.receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                self.lockScreenMusic.update(enabled: enabled, monitor: self.lockMonitor)
            }.store(in: &cancellables)
        AppSettings.shared.$showHeadphoneActivity
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                if !enabled { self?.headphonePopup.dismiss(animated: false) }
            }
            .store(in: &cancellables)
        AppSettings.shared.$clipboardEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.clipboard.enabled = enabled
                if !enabled { self?.clipboard.clear() }
                if !enabled && self?.panel?.state.selectedPage == .clipboard {
                    self?.panel?.state.selectedPage = .music
                }
            }
            .store(in: &cancellables)
        AppSettings.shared.$fileShelfEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                if !enabled && self?.panel?.state.selectedPage == .files {
                    self?.panel?.state.selectedPage = .music
                }
            }
            .store(in: &cancellables)
        AppSettings.shared.$hideMenuBarIcon
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyMenuBarVisibility() }
            .store(in: &cancellables)
    }

    @objc private func togglePanel() { panel?.toggleVisibility() }
    @objc private func openHeadphones() { panel?.openPage(.devices) }
    @objc private func openClipboard() {
        guard AppSettings.shared.clipboardEnabled else { return }
        panel?.openPage(.clipboard)
    }

    @objc private func toggleExpand() {
        panel?.toggleExpanded()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

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
                    return
                }
                // Only load lyrics when idle activity wants now-playing content.
                if AppSettings.shared.idleActivity == .nowPlaying {
                    self.lyrics.load(title: info.title, artist: info.artist)
                }
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
