import AppKit
import Combine
import CoreAudio
import CoreGraphics
import Darwin

enum SystemHUDKind: String, Identifiable {
    case volume
    case brightness

    var id: String { rawValue }
    var symbol: String { self == .volume ? "speaker.wave.2.fill" : "sun.max.fill" }
    var title: String { self == .volume ? "Volume" : "Brightness" }
}

/// Observes and adjusts the real hardware state.
@MainActor
final class SystemControlsMonitor: ObservableObject {
    @Published private(set) var volume: Double = 0
    @Published private(set) var muted = false
    @Published private(set) var volumeAvailable = false
    @Published private(set) var muteAvailable = false
    @Published private(set) var brightness: Double = 0
    @Published private(set) var brightnessAvailable = false
    @Published private(set) var outputName = ""
    @Published private(set) var volumeFeedback: UInt64 = 0
    @Published private(set) var brightnessFeedback: UInt64 = 0
    @Published private(set) var volumeAtLimit = false
    @Published private(set) var brightnessAtLimit = false

    /// Mute and limit feedback are separate, so unchanged extreme values still pulse.
    var onHUD: ((SystemHUDKind, Double, Bool, Bool) -> Void)?

    private struct AudioListener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private var started = false
    private var outputDevice = AudioObjectID(kAudioObjectUnknown)
    private var systemListeners: [AudioListener] = []
    private var deviceListeners: [AudioListener] = []
    private var volumeAddresses: [AudioObjectPropertyAddress] = []
    private var muteAddresses: [AudioObjectPropertyAddress] = []
    private var pollTimer: Timer?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var brightnessDisplay: CGDirectDisplayID?
    private var lastBrightnessKey = Date.distantPast
    private var lastBrightnessHUD = Date.distantPast
    private var lastVolumeHUD = Date.distantPast
    private var pendingVolumeKey: DispatchWorkItem?
    private var pendingBrightnessKey: DispatchWorkItem?
    private let displayServices = DisplayBrightnessService()
    private var brightnessScale = SystemBrightnessScale()
    private var commandedBrightness: (display: CGDirectDisplayID, raw: Double, slider: Double)?
    private var pendingBrightnessTarget: Double?

    func start() {
        guard !started else { return }
        started = true
        lastBrightnessKey = .distantPast
        attachOutputDevice()
        refreshBrightness(notify: false)

        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.started else { return }
                self.attachOutputDevice()
            }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
            systemListeners.append(AudioListener(object: AudioObjectID(kAudioObjectSystemObject), address: address, block: block))
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.observeMediaKey(event)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.observeMediaKey(event)
            return event
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshBrightness(notify: false) }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.started else { return }
                self.attachOutputDevice()
                self.refreshBrightness(notify: false)
            }
        }
        // Brightness has no public change subscription. Polling also recovers
        // CoreAudio listeners if the audio service or output device is replaced.
        pollTimer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.started else { return }
                if Self.defaultOutputDevice() != self.outputDevice {
                    self.attachOutputDevice()
                } else {
                    self.refreshVolume(notify: true)
                }
                self.refreshBrightness(notify: true)
            }
        }
        if let pollTimer { RunLoop.main.add(pollTimer, forMode: .common) }
    }

    func stop() {
        started = false
        pollTimer?.invalidate()
        pollTimer = nil
        pendingVolumeKey?.cancel()
        pendingBrightnessKey?.cancel()
        pendingVolumeKey = nil
        pendingBrightnessKey = nil
        pendingBrightnessTarget = nil
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        globalKeyMonitor = nil
        localKeyMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        screenObserver = nil
        wakeObserver = nil
        Self.removeListeners(systemListeners)
        Self.removeListeners(deviceListeners)
        systemListeners.removeAll()
        deviceListeners.removeAll()
    }

    deinit {
        pollTimer?.invalidate()
        pendingVolumeKey?.cancel()
        pendingBrightnessKey?.cancel()
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        Self.removeListeners(systemListeners)
        Self.removeListeners(deviceListeners)
    }

    func setVolume(_ value: Double) {
        _ = applyVolume(value)
    }

    private func applyVolume(_ value: Double, atLimit: Bool = false) -> Bool {
        guard value.isFinite, volumeAvailable else { return false }
        let target = min(1, max(0, value))
        let levels = volumeAddresses.map { Self.readFloat(outputDevice, address: $0) ?? 0 }
        let highest = levels.max() ?? 0
        var succeeded = false
        // Some outputs expose separate channel controls. Retain their balance.
        for (index, var address) in volumeAddresses.enumerated() {
            let scaled = highest > 0 && volumeAddresses.count > 1
                ? target * Double(levels[index] / highest) : target
            var scalar = Float32(scaled)
            succeeded = AudioObjectSetPropertyData(outputDevice, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar) == noErr || succeeded
        }
        guard succeeded else { refreshVolume(notify: false); return false }
        if target > 0, muted { setMute(false) }
        refreshVolume(notify: false)
        emitVolumeHUD(atLimit: atLimit)
        return true
    }

    func toggleMute() {
        guard muteAvailable else { return }
        if !muteAddresses.isEmpty {
            if setMute(!muted) {
                refreshVolume(notify: false)
                if volumeAvailable { emitVolumeHUD() }
            }
        }
    }

    func setBrightness(_ value: Double) {
        _ = applyBrightness(value)
    }

    private func applyBrightness(_ value: Double, atLimit: Bool = false) -> Bool {
        guard value.isFinite, brightnessAvailable, let display = brightnessDisplay else { return false }
        let target = min(1, max(0, value))
        let rawTarget = brightnessScale.hardwareValue(for: target)
        guard displayServices.set(display: display, value: Float(rawTarget)) else {
            refreshBrightness(notify: false)
            return false
        }
        // Preserve the logical notch when a panel clamps several dark-end
        // slider positions to the same physical minimum backlight reading.
        if let raw = displayServices.get(display: display),
           abs(Double(raw) - rawTarget) < 0.002 || (rawTarget <= 0.01 && raw <= 0.011) {
            commandedBrightness = (display, Double(raw), target)
        }
        refreshBrightness(notify: false)
        emitBrightnessHUD(atLimit: atLimit)
        return true
    }

    /// A key is consumed only after a hardware write succeeds.
    func applyMediaKey(code: Int, fine: Bool) -> Bool {
        switch code {
        case 0, 1:
            refreshVolume(notify: false)
            let up = code == 0
            let current = muted ? 0 : volume
            return applyVolume(SystemLevelSteps.next(current, up: up, fine: fine),
                               atLimit: SystemLevelSteps.isBeyondLimit(current, up: up))
        case 2, 3:
            refreshBrightness(notify: false)
            let up = code == 2
            return applyBrightness(SystemLevelSteps.next(brightness, up: up, fine: fine),
                                   atLimit: SystemLevelSteps.isBeyondLimit(brightness, up: up))
        case 7:
            guard muteAvailable, setMute(!muted) else { return false }
            refreshVolume(notify: false)
            emitVolumeHUD()
            return true
        default: return false
        }
    }

    private func attachOutputDevice() {
        Self.removeListeners(deviceListeners)
        deviceListeners.removeAll()
        outputDevice = Self.defaultOutputDevice()
        volumeAddresses.removeAll()
        muteAddresses.removeAll()
        outputName = Self.readName(outputDevice) ?? ""
        guard outputDevice != kAudioObjectUnknown else {
            volumeAvailable = false
            muteAvailable = false
            muted = false
            return
        }

        let mainVolume = Self.address(kAudioDevicePropertyVolumeScalar)
        if Self.isSettable(outputDevice, address: mainVolume) {
            volumeAddresses = [mainVolume]
        } else {
            var stereoAddress = Self.address(kAudioDevicePropertyPreferredChannelsForStereo)
            var channels: [UInt32] = [1, 2]
            var size = UInt32(MemoryLayout<UInt32>.size * channels.count)
            let status = channels.withUnsafeMutableBytes { bytes in
                AudioObjectGetPropertyData(outputDevice, &stereoAddress, 0, nil, &size, bytes.baseAddress!)
            }
            if status != noErr { channels = [1, 2] }
            volumeAddresses = Array(Set(channels)).sorted().compactMap { channel in
                let address = Self.address(kAudioDevicePropertyVolumeScalar, element: channel)
                return Self.isSettable(outputDevice, address: address) ? address : nil
            }
        }
        let mainMute = Self.address(kAudioDevicePropertyMute)
        if Self.isSettable(outputDevice, address: mainMute) {
            muteAddresses = [mainMute]
        } else {
            muteAddresses = volumeAddresses.compactMap {
                let address = Self.address(kAudioDevicePropertyMute, element: $0.mElement)
                return Self.isSettable(outputDevice, address: address) ? address : nil
            }
        }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.started else { return }
                self.refreshVolume(notify: true)
            }
        }
        for var address in volumeAddresses + muteAddresses {
            if AudioObjectAddPropertyListenerBlock(outputDevice, &address, .main, block) == noErr {
                deviceListeners.append(AudioListener(object: outputDevice, address: address, block: block))
            }
        }
        refreshVolume(notify: false)
    }

    private func refreshVolume(notify: Bool) {
        let oldVolume = volume
        let oldMute = muted
        let wasAvailable = volumeAvailable
        let values = volumeAddresses.compactMap { Self.readFloat(outputDevice, address: $0) }
        volumeAvailable = !values.isEmpty
        if let value = values.max(), value.isFinite { volume = Double(min(1, max(0, value))) }
        let muteValues = muteAddresses.compactMap { Self.readUInt32(outputDevice, address: $0) }
        muteAvailable = !muteValues.isEmpty
        muted = !muteValues.isEmpty && muteValues.allSatisfy { $0 != 0 }
        if notify, wasAvailable, volumeAvailable,
           abs(volume - oldVolume) > 0.001 || muted != oldMute {
            emitVolumeHUD()
        }
    }

    private func refreshBrightness(notify: Bool) {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success else {
            brightnessAvailable = false
            brightnessDisplay = nil
            return
        }
        let oldBrightness = brightness
        let oldDisplay = brightnessDisplay
        let wasAvailable = brightnessAvailable
        // Only operate on a real internal display. HDMI/DisplayPort brightness
        // needs a separately supported DDC provider and is never faked here.
        let internalDisplays = displays.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsActive($0) != 0 }
        for display in internalDisplays {
            if let value = displayServices.get(display: display), value.isFinite, value >= 0, value <= 1 {
                brightnessDisplay = display
                brightnessAvailable = true
                if oldDisplay != display {
                    brightnessScale = SystemBrightnessScale()
                    commandedBrightness = nil
                }
                if let command = commandedBrightness, command.display == display,
                   abs(command.raw - Double(value)) < 0.002 {
                    brightness = command.slider
                } else {
                    commandedBrightness = nil
                    brightnessScale.recognizeNativeNotch(Double(value))
                    brightness = value <= 0.011 ? 0 : brightnessScale.sliderValue(for: Double(value))
                }
                let change = abs(brightness - oldBrightness)
                let hasRecentKey = Date().timeIntervalSince(lastBrightnessKey) < 1.2
                // Passive media-key events can be unavailable without macOS
                // Accessibility access. A significant real brightness change
                // still produces feedback; tiny ambient adjustments stay quiet.
                let significantChange = change >= (1.0 / 32.0 - 0.001)
                if notify, pendingBrightnessKey == nil, wasAvailable, oldDisplay == display,
                   change > 0.001, hasRecentKey || significantChange {
                    emitBrightnessHUD()
                }
                return
            }
        }
        brightnessDisplay = nil
        brightnessAvailable = false
    }

    private func observeMediaKey(_ event: NSEvent) {
        guard started, event.subtype.rawValue == 8 else { return }
        let key = (event.data1 >> 16) & 0xffff
        let state = (event.data1 >> 8) & 0xff
        guard state == 0x0a else { return }
        switch key {
        case 0, 1, 7: // NX_KEYTYPE_SOUND_UP, SOUND_DOWN, MUTE
            pendingVolumeKey?.cancel()
            let keyTime = Date()
            let atLimit = key != 7 && SystemLevelSteps.isBeyondLimit(muted ? 0 : volume, up: key == 0)
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.started else { return }
                self.refreshVolume(notify: false)
                if self.volumeAvailable, self.lastVolumeHUD < keyTime { self.emitVolumeHUD(atLimit: atLimit) }
                self.pendingVolumeKey = nil
            }
            pendingVolumeKey = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        case 2, 3: // NX_KEYTYPE_BRIGHTNESS_UP, BRIGHTNESS_DOWN
            lastBrightnessKey = Date()
            pendingBrightnessKey?.cancel()
            let keyTime = lastBrightnessKey
            let previous = pendingBrightnessTarget ?? brightness
            let atLimit = SystemLevelSteps.isBeyondLimit(previous, up: key == 2)
            let fine = event.modifierFlags.contains([.shift, .option])
            let target = SystemLevelSteps.next(previous, up: key == 2, fine: fine)
            pendingBrightnessTarget = target
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.started else { return }
                self.refreshBrightness(notify: false)
                if let display = self.brightnessDisplay, let raw = self.displayServices.get(display: display), raw <= 0.011 {
                    self.commandedBrightness = (display, Double(raw), target)
                    self.brightness = target
                }
                if self.brightnessAvailable, self.lastBrightnessHUD < keyTime { self.emitBrightnessHUD(atLimit: atLimit) }
                self.pendingBrightnessKey = nil
                self.pendingBrightnessTarget = nil
            }
            pendingBrightnessKey = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
        default: break
        }
    }

    private func emitVolumeHUD(atLimit: Bool = false) {
        lastVolumeHUD = Date()
        volumeAtLimit = atLimit
        volumeFeedback &+= 1
        onHUD?(.volume, volume, muted, atLimit)
    }

    private func emitBrightnessHUD(atLimit: Bool = false) {
        lastBrightnessHUD = Date()
        brightnessAtLimit = atLimit
        brightnessFeedback &+= 1
        onHUD?(.brightness, brightness, false, atLimit)
    }

    @discardableResult
    private func setMute(_ isMuted: Bool) -> Bool {
        var succeeded = false
        for var address in muteAddresses {
            var flag: UInt32 = isMuted ? 1 : 0
            succeeded = AudioObjectSetPropertyData(outputDevice, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &flag) == noErr || succeeded
        }
        return succeeded
    }

    nonisolated private static func address(_ selector: AudioObjectPropertySelector,
                                            scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput,
                                            element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    nonisolated private static func defaultOutputDevice() -> AudioObjectID {
        readUInt32(AudioObjectID(kAudioObjectSystemObject), address: address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)) ?? AudioObjectID(kAudioObjectUnknown)
    }

    nonisolated private static func readFloat(_ object: AudioObjectID, address: AudioObjectPropertyAddress) -> Float32? {
        var address = address
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    nonisolated private static func readUInt32(_ object: AudioObjectID, address: AudioObjectPropertyAddress) -> UInt32? {
        var address = address
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    nonisolated private static func readName(_ object: AudioObjectID) -> String? {
        guard object != kAudioObjectUnknown else { return nil }
        var address = address(kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        // CoreAudio's name property returns a caller-owned CFString.
        return value?.takeRetainedValue() as String?
    }

    nonisolated private static func isSettable(_ object: AudioObjectID, address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable = DarwinBoolean(false)
        return AudioObjectHasProperty(object, &address)
            && AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    nonisolated private static func removeListeners(_ listeners: [AudioListener]) {
        for var listener in listeners {
            AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, .main, listener.block)
        }
    }
}

/// DisplayServices is resolved at runtime so unsupported macOS versions and
/// displays leave the brightness control unavailable without a linker failure.
private final class DisplayBrightnessService {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private let handle: UnsafeMutableRawPointer?
    private let getter: GetBrightness?
    private let setter: SetBrightness?

    init() {
        handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL)
        if let handle,
           let getSymbol = dlsym(handle, "DisplayServicesGetBrightness"),
           let setSymbol = dlsym(handle, "DisplayServicesSetBrightness") {
            getter = unsafeBitCast(getSymbol, to: GetBrightness.self)
            setter = unsafeBitCast(setSymbol, to: SetBrightness.self)
        } else {
            getter = nil
            setter = nil
        }
    }

    deinit { if let handle { dlclose(handle) } }

    func get(display: CGDirectDisplayID) -> Float? {
        guard let getter, setter != nil else { return nil }
        var value: Float = 0
        return getter(display, &value) == 0 ? value : nil
    }

    func set(display: CGDirectDisplayID, value: Float) -> Bool {
        setter?(display, value) == 0
    }
}
