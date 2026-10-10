import Darwin
import Foundation

/// Spawns a child process with its **responsibility disclaimed**.
///
/// Why this matters: when Lyriam is started by launchd (`open Lyriam.app`),
/// macOS marks Lyriam as the *responsible process* for anything it spawns. The
/// `mediaremoted` daemon then evaluates the child's code signature in that
/// light, and because Lyriam is only ad-hoc signed its Apple-signed children
/// (e.g. `/usr/bin/python3`) lose their privileged access — commands are
/// accepted (`true`) and then silently dropped.
///
/// That is exactly why `MRMediaRemoteSendCommand` works when the app is started
/// from a terminal (different responsibility chain) but not from Finder/Dock.
/// `responsibility_spawnattrs_setdisclaim(&attr, 1)` makes the child responsible
/// for itself, restoring the expected behaviour in both cases.
///
/// `Process` cannot express this, so we go through `posix_spawn` directly.
enum DisclaimedProcess {
    private typealias DisclaimFn =
        @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>?, Int32) -> Void

    private static let disclaim: DisclaimFn? = {
        // RTLD_DEFAULT
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                 "responsibility_spawnattrs_setdisclaim") else {
            return nil
        }
        return unsafeBitCast(symbol, to: DisclaimFn.self)
    }()

    /// Runs `path` with `arguments`, waits for it, and returns its exit status.
    /// Returns `nil` if the process could not be spawned.
    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> Int32? {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        disclaim?(&attributes, 1)

        var argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { for case let pointer? in argv { free(pointer) } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, path, nil, &attributes, argv, environ)
        guard spawned == 0 else {
            NowPlayingMonitor.debugLog("posix_spawn(\(path)) failed: \(spawned)")
            return nil
        }

        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return (status >> 8) & 0xFF
    }
}
