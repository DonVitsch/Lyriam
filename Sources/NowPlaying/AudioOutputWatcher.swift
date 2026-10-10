import CoreAudio
import Foundation

/// Reports which process is currently emitting audio, using the public
/// CoreAudio process-object API (`kAudioHardwarePropertyProcessObjectList`,
/// macOS 14.4+).
///
/// Why this exists: the private MediaRemote framework gives us the system
/// "Now Playing" item (title/artist/album/duration/elapsed) but — on current
/// macOS — no bundle identifier for the app that produced it. Enumerating
/// audio processes fills that gap using a *public* API, and it also lets us
/// ignore browser tabs that happen to be playing a video.
///
/// Four-character codes are taken straight from
/// `CoreAudio.framework/Headers/AudioHardware.h`:
/// `kAudioHardwarePropertyProcessObjectList = 'prs#'`,
/// `kAudioProcessPropertyPID = 'ppid'`, `kAudioProcessPropertyBundleID = 'pbid'`,
/// `kAudioProcessPropertyIsRunningOutput = 'piro'`,
/// `kAudioProcessPropertyIsRunning = 'pir?'`.
/// (Guessing these codes silently returns 0 rather than erroring, so they must
/// not be invented.)
///
/// Requires no special entitlement. Input-only processes (microphones) are
/// deliberately excluded.
struct AudioOutputWatcher {
    struct ActiveProcess: Equatable {
        let pid: pid_t
        let bundleID: String
    }

    private static func selector(_ string: String) -> AudioObjectPropertySelector {
        var result: UInt32 = 0
        for byte in string.utf8 { result = (result << 8) + UInt32(byte) }
        return result
    }

    private static func address(_ key: String) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector(key),
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Every audio process currently pushing audio to an output device.
    func activeOutputProcesses() -> [ActiveProcess] {
        var listAddress = Self.address("prs#")
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.compactMap { id in
            guard flag(id, "piro") else { return nil }
            guard let bundleID = bundleID(id), !bundleID.isEmpty else { return nil }
            return ActiveProcess(pid: pid(id), bundleID: bundleID)
        }
    }

    /// Bundle identifiers of every process currently emitting audio.
    func activeOutputBundleIDs() -> Set<String> {
        Set(activeOutputProcesses().map(\.bundleID))
    }

    /// Reads a `UInt32`-valued process property. Returns false on any error,
    /// so a mistyped selector degrades to "not playing" instead of crashing.
    private func flag(_ id: AudioObjectID, _ key: String) -> Bool {
        var address = Self.address(key)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    private func pid(_ id: AudioObjectID) -> pid_t {
        var address = Self.address("ppid")
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    private func bundleID(_ id: AudioObjectID) -> String? {
        var address = Self.address("pbid")
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
