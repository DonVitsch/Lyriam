import Foundation
import AppKit

struct NowPlayingInfo: Equatable {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var duration: TimeInterval = 0
    var elapsedTime: TimeInterval = 0
    var elapsedAtUpdate: Date = .distantPast
    var isPlaying: Bool = false
    var bundleID: String = ""
    var artwork: NSImage?

    var liveElapsedTime: TimeInterval {
        guard isPlaying else { return elapsedTime }
        return elapsedTime + Date().timeIntervalSince(elapsedAtUpdate)
    }

    static func == (lhs: NowPlayingInfo, rhs: NowPlayingInfo) -> Bool {
        lhs.title == rhs.title && lhs.artist == rhs.artist && lhs.album == rhs.album
            && lhs.duration == rhs.duration && lhs.isPlaying == rhs.isPlaying
            && lhs.bundleID == rhs.bundleID
    }
}
