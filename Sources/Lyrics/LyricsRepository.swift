import Foundation

@MainActor
final class LyricsRepository: ObservableObject {
    @Published private(set) var currentLines: [LyricLine] = []
    @Published private(set) var isLoading: Bool = false

    private let remote = RemoteLyricsSource()
    private var memoryCache: [String: [LyricLine]] = [:]
    private var lastKey: String?
    private var inFlightTask: Task<Void, Never>?

    private var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Lyriam", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func load(title: String, artist: String, embeddedLyrics: String? = nil) {
        let key = "\(title)::\(artist)"
        guard key != lastKey else { return }
        lastKey = key
        inFlightTask?.cancel()

        if let embedded = embeddedLyrics {
            currentLines = LRCParser.parse(embedded)
            if !currentLines.isEmpty { return }
        }

        if let cached = memoryCache[key] {
            currentLines = cached
            return
        }
        if let onDisk = readFromDisk(key: key) {
            currentLines = onDisk
            memoryCache[key] = onDisk
            return
        }

        currentLines = []
        isLoading = true
        inFlightTask = Task { [weak self] in
            guard let self else { return }
            let lines = await self.remote.fetchLyrics(title: title, artist: artist) ?? []
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.currentLines = lines
                self.isLoading = false
                self.memoryCache[key] = lines
                if !lines.isEmpty { self.writeToDisk(key: key, lines: lines) }
            }
        }
    }

    private func cacheFileURL(key: String) -> URL {
        let safeName = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString
        return cacheDirectory.appendingPathComponent(safeName).appendingPathExtension("lrc")
    }

    private func readFromDisk(key: String) -> [LyricLine]? {
        let url = cacheFileURL(key: key)
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let lines = LRCParser.parse(text)
        return lines.isEmpty ? nil : lines
    }

    private func writeToDisk(key: String, lines: [LyricLine]) {
        let lrcText = lines.map { line -> String in
            let totalSeconds = line.time
            let minutes = Int(totalSeconds / 60)
            let seconds = totalSeconds - Double(minutes * 60)
            return String(format: "[%02d:%05.2f]%@", minutes, seconds, line.text)
        }.joined(separator: "\n")
        try? lrcText.write(to: cacheFileURL(key: key), atomically: true, encoding: .utf8)
    }
}
