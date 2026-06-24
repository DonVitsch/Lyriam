import Foundation
import AppKit
import Combine

/// Reads current playback from Apple Music via AppleScript.
///
/// We deliberately do NOT use the private MediaRemote framework: since
/// macOS 15.4 the system blocks MRMediaRemoteGetNowPlayingInfo for any
/// process that is not signed by Apple, so an ad-hoc / developer-signed
/// app gets empty data. Talking to Music.app directly through Apple Events
/// is the reliable path for our target (Apple Music). Requires the user to
/// grant Automation permission on first run (NSAppleEventsUsageDescription).
@MainActor
final class NowPlayingMonitor: ObservableObject {
    @Published private(set) var current: NowPlayingInfo?

    private var pollTimer: Timer?
    private var lastArtworkKey: String?

    init() {
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { pollTimer?.invalidate() }

    private static let infoScript = """
    tell application "Music"
        if it is not running then return "NOTRUNNING"
        try
            set pState to (player state as string)
        on error
            return "NOTRUNNING"
        end try
        try
            set trackName to name of current track
            set trackArtist to artist of current track
            set trackAlbum to album of current track
            set trackDur to duration of current track
            set trackPos to player position
            return pState & tab & trackName & tab & trackArtist & tab & trackAlbum & tab & trackDur & tab & trackPos
        on error
            return pState & tab & tab & tab & tab & "0" & tab & "0"
        end try
    end tell
    """

    func refresh() {
        let script = Self.infoScript
        Task.detached(priority: .utility) {
            let output = Self.runAppleScript(script)
            await MainActor.run { self.apply(output: output) }
        }
    }

    private func apply(output: String?) {
        guard let output, !output.isEmpty, output != "NOTRUNNING" else {
            current = nil
            return
        }
        let parts = output.components(separatedBy: "\t")
        guard parts.count >= 6 else { current = nil; return }

        var info = NowPlayingInfo()
        info.isPlaying = (parts[0] == "playing")
        info.title = parts[1]
        info.artist = parts[2]
        info.album = parts[3]
        info.duration = TimeInterval(parts[4]) ?? 0
        info.elapsedTime = TimeInterval(parts[5]) ?? 0
        info.elapsedAtUpdate = Date()
        info.bundleID = "com.apple.Music"

        // Fetch artwork only when the track changes (it's expensive).
        let trackKey = "\(info.title)::\(info.artist)::\(info.album)"
        if trackKey != lastArtworkKey {
            lastArtworkKey = trackKey
            info.artwork = current?.artwork // keep old until new loads
            fetchArtwork(for: trackKey)
        } else {
            info.artwork = current?.artwork
        }

        guard !info.title.isEmpty else { current = nil; return }
        current = info
    }

    private func fetchArtwork(for trackKey: String) {
        // Unique file per fetch: avoids concurrent-write corruption AND the
        // NSImage path cache (NSImage(contentsOfFile:) caches by path and would
        // keep returning the first track's art if we reused one filename).
        let path = NSTemporaryDirectory() + "lyricsisland_art_\(UUID().uuidString).dat"
        let script = """
        tell application "Music"
            try
                set artData to data of artwork 1 of current track
                set f to (open for access (POSIX file "\(path)") with write permission)
                set eof f to 0
                write artData to f
                close access f
                return "OK"
            on error
                try
                    close access (POSIX file "\(path)")
                end try
                return "NOART"
            end try
        end tell
        """
        Task.detached(priority: .utility) {
            let result = Self.runAppleScript(script)
            defer { try? FileManager.default.removeItem(atPath: path) }
            guard result == "OK",
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let image = NSImage(data: data) else { return }
            await MainActor.run {
                guard self.lastArtworkKey == trackKey else { return }
                self.current?.artwork = image
            }
        }
    }

    // MARK: - Playback controls (also via Music.app)

    func playPause() { runControl("playpause") }
    func nextTrack() { runControl("next track") }
    func previousTrack() { runControl("previous track") }

    private func runControl(_ command: String) {
        let script = "tell application \"Music\" to \(command)"
        Task.detached(priority: .userInitiated) {
            _ = Self.runAppleScript(script)
            await MainActor.run { self.refresh() }
        }
    }

    nonisolated private static func runAppleScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let out = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return out
        } catch {
            print("[NowPlaying] osascript launch failed: \(error)")
            return nil
        }
    }
}
