import Combine
import Foundation

/// The deadline, rather than the number of timer callbacks, is the clock.
/// This keeps a countdown accurate when the Mac sleeps or the app relaunches.
@MainActor
final class FocusTimerStore: ObservableObject {
    enum Phase: String, Codable { case idle, running, paused, finished }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var duration: TimeInterval = 5 * 60
    @Published private(set) var remainingSeconds: Int = 5 * 60
    @Published private(set) var lastError: String?
    var onFinished: (() -> Void)?

    var progress: Double { min(max(1 - Double(remainingSeconds) / duration, 0), 1) }
    var canConfigure: Bool { phase == .idle || phase == .finished }
    var formattedRemaining: String {
        let hours = remainingSeconds / 3600
        let minutes = (remainingSeconds % 3600) / 60
        let seconds = remainingSeconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    private var deadline: Date?
    private var pausedRemaining: TimeInterval = 5 * 60
    private var timer: Timer?
    private let persistenceURL: URL?
    private let now: () -> Date
    private var protectedUnreadableFile = false

    private struct Snapshot: Codable {
        let phase: Phase
        let duration: TimeInterval
        let remaining: TimeInterval
        let deadline: Date?
    }

    init(persistenceURL: URL? = FocusTimerStore.defaultPersistenceURL, now: @escaping () -> Date = Date.init) {
        self.persistenceURL = persistenceURL
        self.now = now
        restore()
    }

    nonisolated private static var defaultPersistenceURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.local.lyriam", isDirectory: true)
            .appendingPathComponent("focus-timer.json")
    }

    func startMonitoring() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        // The saved deadline keeps running while the app is closed.
    }

    func configure(minutes: Int) {
        guard canConfigure, (1...999).contains(minutes) else { return }
        configure(seconds: minutes * 60)
    }

    func configure(seconds: Int) {
        guard canConfigure, (1...86_399).contains(seconds) else { return }
        duration = TimeInterval(seconds)
        remainingSeconds = Int(duration)
        pausedRemaining = duration
        deadline = nil
        phase = .idle
        save()
    }

    func start() {
        guard canConfigure else { return }
        remainingSeconds = Int(duration)
        pausedRemaining = duration
        deadline = now().addingTimeInterval(duration)
        phase = .running
        save()
    }

    func pause() {
        guard phase == .running, let deadline else { return }
        pausedRemaining = min(max(deadline.timeIntervalSince(now()), 0), duration)
        guard pausedRemaining > 0 else { refresh(); return }
        remainingSeconds = Int(ceil(pausedRemaining))
        self.deadline = nil
        phase = .paused
        save()
    }

    func resume() {
        guard phase == .paused else { return }
        deadline = now().addingTimeInterval(pausedRemaining)
        phase = .running
        save()
    }

    func reset() {
        deadline = nil
        pausedRemaining = duration
        remainingSeconds = Int(duration)
        phase = .idle
        save()
    }

    /// Also called immediately after wake/startMonitoring; safe to call repeatedly.
    func refresh() {
        guard phase == .running, let deadline else { return }
        let remaining = max(deadline.timeIntervalSince(now()), 0)
        remainingSeconds = Int(ceil(min(remaining, duration)))
        guard remaining <= 0 else { return }
        self.deadline = nil
        pausedRemaining = 0
        phase = .finished
        save()
        onFinished?()
    }

    private func restore() {
        guard let persistenceURL, FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
        do {
            let saved = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: persistenceURL))
            guard saved.duration.isFinite, (1...86_399).contains(saved.duration),
                  saved.remaining.isFinite, (0...saved.duration).contains(saved.remaining),
                  saved.phase != .running || saved.deadline != nil,
                  saved.deadline?.timeIntervalSinceReferenceDate.isFinite != false else {
                throw CocoaError(.coderReadCorrupt)
            }
            duration = saved.duration
            phase = saved.phase
            pausedRemaining = saved.remaining
            deadline = saved.deadline
            if phase == .running, let deadline {
                let remaining = max(deadline.timeIntervalSince(now()), 0)
                remainingSeconds = Int(ceil(min(remaining, duration)))
                if remaining <= 0 {
                    // Show an elapsed timer after relaunch, without a stale completion alert.
                    phase = .finished
                    self.deadline = nil
                    pausedRemaining = 0
                }
            } else {
                remainingSeconds = phase == .finished ? 0 : Int(ceil(pausedRemaining))
            }
        } catch {
            protectedUnreadableFile = true
            lastError = "上次计时未能读取；当前计时仅在本次运行有效。"
        }
    }

    private func save() {
        guard !protectedUnreadableFile, let persistenceURL else { return }
        do {
            let snapshot = Snapshot(phase: phase, duration: duration, remaining: pausedRemaining, deadline: deadline)
            let data = try JSONEncoder().encode(snapshot)
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: persistenceURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "计时未能保存，退出 Lyriam 后可能无法恢复。"
        }
    }
}
