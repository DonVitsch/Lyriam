import Combine
import Foundation
import IOKit.ps

@MainActor
final class BatteryMonitor: ObservableObject {
    @Published private(set) var percentage: Int?
    @Published private(set) var isCharging = false
    @Published private(set) var hasBattery = false
    @Published private(set) var isPluggedIn = false

    /// Fires for charger connection/disconnection, including a full battery.
    /// The Boolean denotes external power, not whether charging is active.
    var onChange: ((Bool, Int?) -> Void)?

    private var notificationSource: CFRunLoopSource?
    private var fallbackTimer: Timer?
    private var started = false
    private var hasInitialReading = false

    func start() {
        guard !started else { return }
        started = true
        hasInitialReading = false
        refresh(notify: false)

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            // The notification source is installed only on the main run loop.
            MainActor.assumeIsolated { monitor.refresh(notify: true) }
        }, context)?.takeRetainedValue() {
            notificationSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        } else {
            fallbackTimer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh(notify: true) }
            }
            if let fallbackTimer { RunLoop.main.add(fallbackTimer, forMode: .common) }
        }
    }

    func stop() {
        started = false
        if let notificationSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), notificationSource, .commonModes)
            CFRunLoopSourceInvalidate(notificationSource)
        }
        notificationSource = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        hasInitialReading = false
    }

    deinit {
        if let notificationSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), notificationSource, .commonModes)
            CFRunLoopSourceInvalidate(notificationSource)
        }
        fallbackTimer?.invalidate()
    }

    private func refresh(notify: Bool) {
        guard started,
              let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return }
        let oldPower = isPluggedIn
        let previouslyHadBattery = hasBattery
        var found: [String: Any]?
        for source in sources {
            guard let values = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  values[kIOPSIsPresentKey] as? Bool != false else { continue }
            found = values
            break
        }
        hasBattery = found != nil
        if let found {
            if let current = found[kIOPSCurrentCapacityKey] as? Int,
               let maximum = found[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                percentage = min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
            } else {
                percentage = nil
            }
            isCharging = found[kIOPSIsChargingKey] as? Bool ?? false
            isPluggedIn = found[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        } else {
            percentage = nil
            isCharging = false
            isPluggedIn = false
        }
        if notify, hasInitialReading, previouslyHadBattery, hasBattery, oldPower != isPluggedIn {
            onChange?(isPluggedIn, percentage)
        }
        hasInitialReading = true
    }
}
