import AppKit
import Network

/// Lightweight state changes; starting the app never generates a notification.
@MainActor
final class SystemStatusMonitor {
    var onCapsLockChange: ((Bool) -> Void)?
    var onNetworkChange: ((Bool) -> Void)?
    private var capsTimer: Timer?
    private var lastCapsLock = false
    private var pathMonitor: NWPathMonitor?
    private var networkState: Bool?
    private var pendingNetwork: DispatchWorkItem?
    private var generation = 0

    func start() {
        guard capsTimer == nil else { return }
        generation += 1
        let currentGeneration = generation
        lastCapsLock = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let enabled = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
                guard enabled != self.lastCapsLock else { return }
                self.lastCapsLock = enabled
                self.onCapsLockChange?(enabled)
            }
        }
        capsTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration else { return }
                self.receivedNetworkState(connected)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.local.lyriam.network-status"))
    }

    private func receivedNetworkState(_ connected: Bool) {
        pendingNetwork?.cancel()
        guard let previous = networkState else { networkState = connected; return }
        guard previous != connected else { return }
        // Ignore brief handovers between Wi-Fi/Ethernet; report a stable change.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.networkState = connected
            self.onNetworkChange?(connected)
        }
        pendingNetwork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (connected ? 0.5 : 2), execute: work)
    }

    func stop() {
        generation += 1
        capsTimer?.invalidate(); capsTimer = nil
        pathMonitor?.cancel(); pathMonitor = nil
        pendingNetwork?.cancel(); pendingNetwork = nil
        networkState = nil
    }

    deinit { capsTimer?.invalidate(); pathMonitor?.cancel(); pendingNetwork?.cancel() }
}
