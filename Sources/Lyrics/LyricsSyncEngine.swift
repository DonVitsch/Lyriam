import Foundation
import Combine

@MainActor
final class LyricsSyncEngine: ObservableObject {
    @Published private(set) var currentIndex: Int?

    private var timer: Timer?
    private var lines: [LyricLine] = []
    private var elapsedProvider: (() -> TimeInterval)?

    func start(lines: [LyricLine], elapsedProvider: @escaping () -> TimeInterval) {
        self.lines = lines
        self.elapsedProvider = elapsedProvider
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        currentIndex = nil
    }

    private func tick() {
        guard let elapsedProvider, !lines.isEmpty else {
            currentIndex = nil
            return
        }
        let elapsed = elapsedProvider()
        var newIndex: Int?
        for (i, line) in lines.enumerated() {
            if line.time <= elapsed {
                newIndex = i
            } else {
                break
            }
        }
        if newIndex != currentIndex {
            currentIndex = newIndex
        }
    }
}
