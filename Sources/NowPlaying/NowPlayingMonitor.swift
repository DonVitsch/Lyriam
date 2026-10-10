import AppKit
import ApplicationServices
import Combine
import Foundation

/// Opt-in trace, off unless the process is started with `LYRIAM_DEBUG=1` — or
/// the marker file `/tmp/lyriam-debug-on` exists (handy when the app is started
/// with `open`, where environment variables cannot be passed).
/// Lyriam is an LSUIElement app with no window to inspect, so this is the
/// quickest way to answer "why is the island showing nothing?".
private let lyriamDebugEnabled = ProcessInfo.processInfo.environment["LYRIAM_DEBUG"] != nil
    || FileManager.default.fileExists(atPath: "/tmp/lyriam-debug-on")

/// Reads what is currently playing and exposes it as `NowPlayingInfo`.
///
/// Two data sources are combined:
///
/// 1. `AudioOutputWatcher` (public CoreAudio API) tells us *which app* is
///    actually emitting audio. This is how we honour the Media Source setting
///    and how browser tabs playing a video are filtered out.
/// 2. `SystemNowPlayingReader` (MediaRemote through osascript) supplies the
///    track metadata: title, artist, album, duration and playhead.
///
/// Historically this class talked to Apple Music over AppleScript only. That
/// does not generalise: NetEase Cloud Music ships no AppleScript dictionary
/// (`.sdef`), and since macOS 15.4 apps that are not Apple-signed cannot call
/// MediaRemote directly. The osascript bridge solves the second problem and
/// CoreAudio the first.
@MainActor
final class NowPlayingMonitor: ObservableObject {
    @Published private(set) var current: NowPlayingInfo?

    private let audio = AudioOutputWatcher()
    private let reader = SystemNowPlayingReader()
    private let artworkSource = RemoteLyricsSource()

    private var pollTimer: Timer?
    private var lastArtworkKey: String?
    private var refreshInFlight = false

    /// Last app we positively identified as the audio source. Kept so the
    /// island can stay resident while that app is merely paused — the user only
    /// wants "not playing" once the player is actually gone.
    private var stickyOwner: String?

    init() {
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { pollTimer?.invalidate() }

    nonisolated static func debugLog(_ message: String) {
        guard lyriamDebugEnabled else { return }
        let line = "[\(Date())] \(message)\n"
        let path = "/tmp/lyriam-nowplaying.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Polling

    func refresh() {
        // Test scaffolding: lets the control path be driven from outside the app
        // (Lyriam has no window to click). Only armed when tracing is enabled.
        // Usage: touch /tmp/lyriam-debug-on && echo 4 > /tmp/lyriam-cmd
        if lyriamDebugEnabled,
           let raw = try? String(contentsOfFile: "/tmp/lyriam-cmd", encoding: .utf8),
           let code = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            try? FileManager.default.removeItem(atPath: "/tmp/lyriam-cmd")
            Self.debugLog("TESTHOOK invoking command \(code)")
            perform(MediaRemoteCommand(rawValue: code) ?? .togglePlayPause)
            return
        }

        guard !refreshInFlight else { return }
        refreshInFlight = true

        let allowed = AppSettings.shared.mediaSource.acceptedBundleIDs
        let previousOwner = stickyOwner
        let reader = self.reader
        let audio = self.audio

        Task.detached(priority: .utility) {
            let activeBundleIDs = audio.activeOutputBundleIDs()

            // 1. A configured player is producing sound right now — the only
            //    way to be sure MediaRemote's item belongs to it, since
            //    MediaRemote exposes no bundle identifier.
            if let owner = allowed.first(where: { base in
                activeBundleIDs.contains { $0 == base || $0.hasPrefix(base + ".") }
            }) {
                let snapshot = reader.read()
                await MainActor.run {
                    self.refreshInFlight = false
                    self.stickyOwner = owner
                    guard let snapshot else { return }
                    self.apply(
                        snapshot,
                        bundleID: owner,
                        isPlaying: (snapshot.playbackRate ?? 1) > 0
                    )
                }
                return
            }

            // 2. Nothing we follow is producing sound. NetEase (and other CEF
            //    players) keep their output stream open for a few seconds after
            //    pausing and then release it — which is exactly the moment the
            //    old implementation dropped to "not playing". Stay resident
            //    instead, and only clear once the player itself is gone.
            //
            //    Note we deliberately do NOT try to detect "some other app took
            //    over playback": browsers hold a silent output stream open
            //    almost permanently (`com.google.chrome.helper` sits at
            //    IsRunningOutput=1 while nothing is audible), so that check is
            //    always true and would defeat the whole point. Not re-reading
            //    MediaRemote here is what keeps a browser video's title from
            //    leaking into the card.
            let ownerStillRunning = previousOwner.map(Self.isApplicationRunning) ?? false

            await MainActor.run {
                self.refreshInFlight = false
                Self.debugLog(
                    "no owner | audio=\(activeBundleIDs.sorted().joined(separator: ","))"
                    + " previous=\(previousOwner ?? "-")"
                    + " ownerRunning=\(ownerStillRunning)"
                )
                if previousOwner != nil, ownerStillRunning {
                    self.markPaused()
                } else {
                    self.stickyOwner = nil
                    self.applyNothing()
                }
            }
        }
    }

    /// Keeps the current card on screen but stops the transport/waveform.
    /// Deliberately does *not* re-read MediaRemote: with no audio being
    /// produced we cannot tell whether the session still belongs to us, and
    /// re-reading would risk showing another app's stale title.
    private func markPaused() {
        guard var info = current, info.isPlaying else { return }
        info.isPlaying = false
        current = info
        Self.debugLog("keep resident, paused: \(info.title)")
    }

    private func applyNothing() {
        guard current != nil else { return }
        current = nil
        lastArtworkKey = nil
    }

    private func apply(
        _ snapshot: SystemNowPlayingReader.Snapshot,
        bundleID: String,
        isPlaying: Bool
    ) {
        var info = NowPlayingInfo()
        info.title = snapshot.title
        info.artist = snapshot.artist
        info.album = snapshot.album
        info.duration = snapshot.duration
        info.elapsedTime = snapshot.elapsedTime
        info.elapsedAtUpdate = Date()
        info.bundleID = bundleID
        // NetEase and Apple Music both publish playbackRate: 1 while playing,
        // 0 while paused. Only fall back to "is it producing audio" when the
        // key is missing.
        info.isPlaying = isPlaying

        // Artwork only when the track changes — it is expensive.
        let trackKey = "\(info.title)::\(info.artist)::\(info.album)::\(bundleID)"
        if trackKey != lastArtworkKey {
            lastArtworkKey = trackKey
            info.artwork = current?.artwork
            fetchArtwork(for: trackKey, bundleID: bundleID, title: info.title, artist: info.artist)
        } else {
            info.artwork = current?.artwork
        }

        current = info
        Self.debugLog("apply: \(info.title) / \(info.artist) playing=\(info.isPlaying) owner=\(bundleID)")
    }

    // MARK: - Source classification

    private nonisolated static func isApplicationRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    // MARK: - Artwork

    private func fetchArtwork(for trackKey: String, bundleID: String, title: String, artist: String) {
        if bundleID == MediaSourceKind.appleMusicBundleID {
            fetchAppleMusicArtwork(for: trackKey)
            return
        }
        Task.detached(priority: .utility) { [artworkSource = self.artworkSource] in
            guard let url = await artworkSource.fetchArtworkURL(title: title, artist: artist) else { return }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data) else { return }
            await MainActor.run {
                guard self.lastArtworkKey == trackKey else { return }
                self.current?.artwork = image
            }
        }
    }

    /// Apple Music artwork straight from the app — exact, and cheaper than
    /// searching a third-party API.
    private func fetchAppleMusicArtwork(for trackKey: String) {
        // Unique file per fetch: avoids concurrent-write corruption AND the
        // NSImage path cache (NSImage(contentsOfFile:) caches by path and would
        // keep returning the first track's art if we reused one filename).
        let path = NSTemporaryDirectory() + "lyriyam_art_\(UUID().uuidString).dat"
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
            let result = SystemNowPlayingReader.runAppleScript(script)
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

    // MARK: - Playback controls

    func playPause() { perform(.togglePlayPause) }
    func nextTrack() { perform(.nextTrack) }
    func previousTrack() { perform(.previousTrack) }

    /// `MRMediaRemoteCommand` values (verified on macOS 27).
    private enum MediaRemoteCommand: Int {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case nextTrack = 4
        case previousTrack = 5
    }

    private func perform(_ command: MediaRemoteCommand) {
        if usesAppleScriptControl {
            let verb: String
            switch command {
            case .nextTrack:     verb = "next track"
            case .previousTrack: verb = "previous track"
            default:             verb = "playpause"
            }
            runAppleScriptControl(verb)
            return
        }

        // Apple Music uses its supported AppleScript dictionary above. For
        // other players, post the system media key directly: MediaRemote can
        // report that a private command was accepted while silently dropping
        // it, so its success result is not useful for transport control.
        Self.postMediaKey(command)
        Self.requestAccessibilityPermissionIfNeeded()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.refresh()
        }
    }

    /// One-time system prompt so the fallback path can start working.
    private nonisolated static func requestAccessibilityPermissionIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        Self.debugLog("accessibility not granted — media key fallback will not work until it is")
    }

    /// Apple Music exposes a script dictionary, so drive it directly.
    private var usesAppleScriptControl: Bool {
        if let bundle = current?.bundleID, !bundle.isEmpty {
            return bundle == MediaSourceKind.appleMusicBundleID
        }
        return AppSettings.shared.mediaSource == .appleMusic
    }

    private func runAppleScriptControl(_ verb: String) {
        let script = "tell application \"Music\" to \(verb)"
        Task.detached(priority: .userInitiated) {
            _ = SystemNowPlayingReader.runAppleScript(script)
            try? await Task.sleep(nanoseconds: 400_000_000)
            await MainActor.run { self.refresh() }
        }
    }

    /// Synthesises an `NX_SYSDEFINED` system media key press.
    private nonisolated static func postMediaKey(_ command: MediaRemoteCommand) {
        let code: Int
        switch command {
        case .nextTrack:     code = 17
        case .previousTrack: code = 18
        default:             code = 16
        }
        let down = (code << 16) | (0xA << 8)
        let up = (code << 16) | (0xB << 8)
        for data1 in [down, up] {
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
        Self.debugLog("posted fallback media key \(code)")
    }
}
