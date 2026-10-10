import Foundation

/// Reads the system-wide "Now Playing" item through the private MediaRemote
/// framework, using `/usr/bin/osascript` as a privileged intermediary.
///
/// Background: since macOS 15.4 the `mediaremoted` daemon checks the caller's
/// code signature before handing out now-playing data, so a Developer-ID /
/// ad-hoc signed app like Lyriam gets nothing when it loads MediaRemote
/// itself. `osascript` is an Apple-signed system binary, so loading the
/// framework from inside it passes the check. This is the same bypass used by
/// ungive/mediaremote-adapter, LyricsX, boring.notch and friends.
///
/// Two API details are version-specific and were verified on this machine
/// (macOS 27): the entry point is the *class* method
/// `+[MRNowPlayingRequest localNowPlayingItem]` (there is no
/// `-nowPlayingItem`), and the payload is the `kMRMediaRemoteNowPlayingInfo*`
/// dictionary exposed by `MRContentItem.nowPlayingInfo`. `MRContentItem` also
/// has no `parentApplicationBundleIdentifier`, which is why the owning app is
/// resolved separately via `AudioOutputWatcher`.
struct SystemNowPlayingReader {
    struct Snapshot {
        var title: String = ""
        var artist: String = ""
        var album: String = ""
        var duration: TimeInterval = 0
        var elapsedTime: TimeInterval = 0
        /// 1 while playing, 0 while paused. Absent for some players.
        var playbackRate: Double?

        var isEmpty: Bool { title.isEmpty }
    }

    private static let script = """
    ObjC.import("Foundation");
    var bundle = $.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework");
    bundle.load;
    var out = { ok: false };
    var request = $.NSClassFromString("MRNowPlayingRequest");
    var item = request.localNowPlayingItem;
    if (item) {
        var info = item.nowPlayingInfo;
        if (info) {
            var d = ObjC.deepUnwrap(info);
            out.ok = true;
            out.title = d["kMRMediaRemoteNowPlayingInfoTitle"] || "";
            out.artist = d["kMRMediaRemoteNowPlayingInfoArtist"] || "";
            out.album = d["kMRMediaRemoteNowPlayingInfoAlbum"] || "";
            out.duration = d["kMRMediaRemoteNowPlayingInfoDuration"] || 0;
            out.elapsed = d["kMRMediaRemoteNowPlayingInfoElapsedTime"] || 0;
            if (d["kMRMediaRemoteNowPlayingInfoPlaybackRate"] !== undefined) {
                out.rate = d["kMRMediaRemoteNowPlayingInfoPlaybackRate"];
            }
        }
    }
    JSON.stringify(out);
    """

    /// Runs the reader synchronously. Call from a background context: it spawns
    /// a process.
    nonisolated func read() -> Snapshot? {
        guard let output = Self.runJavaScript(Self.script),
              let data = output.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              raw["ok"] as? Bool == true else {
            return nil
        }

        var snapshot = Snapshot()
        snapshot.title = Self.string(raw["title"])
        snapshot.artist = Self.string(raw["artist"])
        snapshot.album = Self.string(raw["album"])
        snapshot.duration = Self.double(raw["duration"])
        snapshot.elapsedTime = Self.double(raw["elapsed"])
        snapshot.playbackRate = (raw["rate"] as? NSNumber)?.doubleValue
        return snapshot.isEmpty ? nil : snapshot
    }

    private static func string(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func double(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    nonisolated static func runJavaScript(_ source: String) -> String? {
        runScript(arguments: ["-l", "JavaScript", "-e", source])
    }

    /// Executes AppleScript source (as opposed to JXA). Artwork extraction and
    /// Music transport controls rely on Music.app's AppleScript dictionary.
    nonisolated static func runAppleScript(_ source: String) -> String? {
        runScript(arguments: ["-e", source])
    }

    private nonisolated static func runScript(arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            print("[SystemNowPlayingReader] osascript launch failed: \(error)")
            return nil
        }
    }
}
