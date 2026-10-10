import AppKit
import ApplicationServices
import Combine
import CoreGraphics

/// Consumes only supported volume/brightness keys after a successful direct
/// hardware change. The native HUD therefore never receives that key press.
@MainActor
final class MediaKeyHUDController: ObservableObject {
    static let shared = MediaKeyHUDController()
    @Published private(set) var status = "等待启动"
    @Published private(set) var active = false
    @Published private(set) var permissionRequired = false
    @Published private(set) var handledKeys = 0
    var canPresentHUD: () -> Bool = { false }
    private weak var controls: SystemControlsMonitor?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var permissionTimer: Timer?
    private var settingsSubscription: AnyCancellable?
    private var consumed: [Int: Bool] = [:]

    func start(controls: SystemControlsMonitor) {
        self.controls = controls
        settingsSubscription = AppSettings.shared.$replaceSystemHUD.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reconcile() }
        reconcile()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        reconcile()
    }

    func stop() {
        permissionTimer?.invalidate(); permissionTimer = nil
        settingsSubscription?.cancel(); settingsSubscription = nil
        removeTap()
        controls = nil
    }

    private func reconcile() {
        guard AppSettings.shared.replaceSystemHUD else {
            removeTap(); permissionRequired = false; status = "使用系统提示"; return
        }
        guard AXIsProcessTrusted() else {
            removeTap(); permissionRequired = true
            status = "需要辅助功能权限，授权后由 Lyriam 接管音量和亮度按键。"
            return
        }
        permissionRequired = false
        if let tap, CGEvent.tapIsEnabled(tap: tap) { active = true; status = "已接管媒体键"; return }
        removeTap()
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(1 << 14), callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<MediaKeyHUDController>.fromOpaque(context).takeUnretainedValue()
                return MainActor.assumeIsolated { owner.handle(type: type, event: event) }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            status = "当前无法接管，音量和亮度仍由系统控制。"; return
        }
        tap = created
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        active = CGEvent.tapIsEnabled(tap: created)
        status = active ? "已接管媒体键" : "当前无法接管，音量和亮度仍由系统控制。"
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; consumed.removeAll(); active = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard type.rawValue == 14, let key = NSEvent(cgEvent: event), key.subtype.rawValue == 8 else { return pass }
        let code = (key.data1 >> 16) & 0xFFFF
        guard [0, 1, 2, 3, 7].contains(code) else { return pass }
        let state = (key.data1 >> 8) & 0xFF
        if state == 0xB { return consumed.removeValue(forKey: code) != nil ? nil : pass }
        guard state == 0xA else { return pass }
        let flags = event.flags
        let fine = consumed[code] ?? (flags.contains(.maskShift) && flags.contains(.maskAlternate))
        // Preserve modifier shortcuts that open Sound/Display settings.
        guard !flags.contains(.maskCommand), !flags.contains(.maskControl),
              !flags.contains(.maskAlternate) || fine else { return pass }
        let settings = AppSettings.shared
        let enabled = (code == 2 || code == 3) ? settings.showBrightnessHUD : settings.showVolumeHUD
        guard enabled, canPresentHUD(), controls?.applyMediaKey(code: code, fine: fine) == true else {
            consumed.removeValue(forKey: code)
            return pass
        }
        consumed[code] = fine
        handledKeys += 1
        return nil
    }
}
