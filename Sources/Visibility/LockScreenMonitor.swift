import AppKit
import Combine
import CoreGraphics

/// Tracks protection separately from display sleep and fast user switching, so
/// private pages are hidden even when the lock-screen music card is disabled.
@MainActor
final class LockScreenMonitor: ObservableObject {
    @Published private(set) var isLocked = false
    @Published private(set) var isSessionActive = true
    @Published private(set) var screensAwake = true
    @Published private(set) var isSessionProtected = false
    var onStateChange: (() -> Void)?

    private var distributedObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var timer: Timer?

    var canShowLockScreenMusic: Bool { isLocked && isSessionActive && screensAwake }

    func start() {
        guard timer == nil else { return }
        refreshSession()
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setLocked(true) }
        })
        distributedObservers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setLocked(false) }
        })
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let oldState = self.state
                // Hide private pages immediately. The session dictionary can
                // lag this event briefly, so let the next poll reconcile it.
                self.isSessionActive = false
                self.publishProtection(previous: oldState)
            }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSession(fallbackActive: true) }
        })
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setScreensAwake(false) }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshSession()
                    self?.setScreensAwake(true)
                }
            })
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSession() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        distributedObservers.forEach(DistributedNotificationCenter.default().removeObserver)
        distributedObservers.removeAll()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
    }

    private func refreshSession(fallbackActive: Bool? = nil) {
        let oldState = state
        if let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if let onConsole = dictionary[kCGSessionOnConsoleKey as String] as? Bool {
                isSessionActive = onConsole
            } else if let fallbackActive {
                isSessionActive = fallbackActive
            }
            // This system-provided key and the distributed lock notifications
            // are observational only. If absent, preserve the last lock event.
            if let locked = dictionary["CGSSessionScreenIsLocked"] as? Bool {
                isLocked = locked
            }
        } else {
            // No Quartz user session: never reveal an ordinary user panel.
            isSessionActive = false
        }
        publishProtection(previous: oldState)
    }

    private func setLocked(_ locked: Bool) {
        let oldState = state
        isLocked = locked
        if let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any],
           let onConsole = dictionary[kCGSessionOnConsoleKey as String] as? Bool {
            isSessionActive = onConsole
        }
        publishProtection(previous: oldState)
    }

    private func setScreensAwake(_ awake: Bool) {
        let oldState = state
        screensAwake = awake
        publishProtection(previous: oldState)
    }

    private var state: [Bool] { [isLocked, isSessionActive, screensAwake] }

    private func publishProtection(previous: [Bool]) {
        isSessionProtected = isLocked || !isSessionActive || !screensAwake
        if state != previous { onStateChange?() }
    }
}
