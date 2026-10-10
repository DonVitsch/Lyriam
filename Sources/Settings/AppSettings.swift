import Foundation
import SwiftUI
import AppKit

enum IslandMode: String, CaseIterable, Identifiable {
    case leftSafe       // right cap stops just past the camera — never covers right-side apps (default)
    case notchCentered  // symmetric wings centered on the camera — may cover right-side menu items

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leftSafe:      return "靠左 · 不遮挡右侧 App"
        case .notchCentered: return "摄像头居中 · 对称(可能遮挡右侧)"
        }
    }
}


/// How the expanded card colors itself.
enum ColorStyle: String, CaseIterable, Identifiable {
    case artwork
    case gradient
    case color
    case mono

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .artwork:  return "跟随封面"
        case .gradient: return "渐变"
        case .color:    return "自定义"
        case .mono:     return "单色"
        }
    }
}

/// Which player Lyriam follows for now-playing information.
///
/// Reading is source-agnostic (the system "Now Playing" session plus a
/// CoreAudio check on which process is actually emitting audio); this enum
/// only decides which bundle identifiers are accepted.
enum MediaSourceKind: String, CaseIterable, Identifiable {
    case auto
    case netease
    case appleMusic
    case spotify

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:       return "自动"
        case .netease:    return "网易云音乐"
        case .appleMusic: return "Apple Music"
        case .spotify:    return "Spotify"
        }
    }

    /// Bundle identifiers this source accepts.
    var acceptedBundleIDs: [String] {
        switch self {
        case .auto:       return MediaSourceKind.allKnownBundleIDs
        case .netease:    return [MediaSourceKind.neteaseBundleID]
        case .appleMusic: return [MediaSourceKind.appleMusicBundleID]
        case .spotify:    return [MediaSourceKind.spotifyBundleID]
        }
    }

    /// Prefers AppleScript for Apple Music (its private script dictionary is
    /// the most accurate path) and system media keys for everything else.
    var prefersAppleScriptControl: Bool {
        self == .appleMusic
    }

    static let neteaseBundleID = "com.netease.163music"
    static let appleMusicBundleID = "com.apple.Music"
    static let spotifyBundleID = "com.spotify.client"

    static let allKnownBundleIDs = [neteaseBundleID, appleMusicBundleID, spotifyBundleID]
}

/// Idle activity shown when nothing transient is active.
enum IdleActivity: String, CaseIterable, Identifiable {
    case nowPlaying
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nowPlaying: return "正在播放"
        case .none:       return "不显示"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var islandMode: IslandMode {
        didSet { defaults.set(islandMode.rawValue, forKey: "islandMode") }
    }

    // MARK: - General / Behaviour

    @Published var expandOnHover: Bool {
        didSet { defaults.set(expandOnHover, forKey: "expandOnHover") }
    }
    @Published var hoverDuration: Double {
        didSet { defaults.set(hoverDuration, forKey: "hoverDuration") }
    }
    @Published var contrastOutline: Bool {
        didSet { defaults.set(contrastOutline, forKey: "contrastOutline") }
    }
    @Published var progressiveBlur: Bool {
        didSet { defaults.set(progressiveBlur, forKey: "progressiveBlur") }
    }
    @Published var hideInFullscreen: Bool {
        didSet { defaults.set(hideInFullscreen, forKey: "hideInFullscreen") }
    }
    @Published var hideMenuBarIcon: Bool {
        didSet { defaults.set(hideMenuBarIcon, forKey: "hideMenuBarIcon") }
    }
    @Published var showVolumeHUD: Bool {
        didSet { defaults.set(showVolumeHUD, forKey: "showVolumeHUD") }
    }
    @Published var showBrightnessHUD: Bool {
        didSet { defaults.set(showBrightnessHUD, forKey: "showBrightnessHUD") }
    }
    @Published var replaceSystemHUD: Bool {
        didSet { defaults.set(replaceSystemHUD, forKey: "replaceSystemHUD") }
    }
    @Published var showHeadphoneActivity: Bool {
        didSet { defaults.set(showHeadphoneActivity, forKey: "showHeadphoneActivity") }
    }
    @Published var showChargingActivity: Bool {
        didSet { defaults.set(showChargingActivity, forKey: "showChargingActivity") }
    }
    @Published var clipboardEnabled: Bool {
        didSet { defaults.set(clipboardEnabled, forKey: "clipboardEnabled") }
    }
    @Published var fileShelfEnabled: Bool {
        didSet { defaults.set(fileShelfEnabled, forKey: "fileShelfEnabled") }
    }
    @Published var showCapsLockActivity: Bool {
        didSet { defaults.set(showCapsLockActivity, forKey: "showCapsLockActivity") }
    }
    @Published var showNetworkActivity: Bool {
        didSet { defaults.set(showNetworkActivity, forKey: "showNetworkActivity") }
    }
    @Published var showNetworkDashboard: Bool {
        didSet { defaults.set(showNetworkDashboard, forKey: "showNetworkDashboard") }
    }
    @Published var showLockScreenMusic: Bool {
        didSet { defaults.set(showLockScreenMusic, forKey: "showLockScreenMusic") }
    }
    @Published var forceSimulatedNotch: Bool {
        didSet { defaults.set(forceSimulatedNotch, forKey: "forceSimulatedNotch") }
    }
    @Published var idleActivity: IdleActivity {
        didSet { defaults.set(idleActivity.rawValue, forKey: "idleActivity") }
    }

    /// Which player Lyriam reads now-playing information from.
    @Published var mediaSource: MediaSourceKind {
        didSet { defaults.set(mediaSource.rawValue, forKey: "mediaSource") }
    }

    // MARK: - Gestures

    @Published var swipeToSkip: Bool {
        didSet { defaults.set(swipeToSkip, forKey: "swipeToSkip") }
    }
    @Published var swipeToToggle: Bool {
        didSet { defaults.set(swipeToToggle, forKey: "swipeToToggle") }
    }

    // MARK: - Now Playing

    @Published var colorStyle: ColorStyle {
        didSet { defaults.set(colorStyle.rawValue, forKey: "colorStyle") }
    }
    @Published var useLiveWaveform: Bool {
        didSet { defaults.set(useLiveWaveform, forKey: "useLiveWaveform") }
    }
    @Published var disableCompactWaveform: Bool {
        didSet { defaults.set(disableCompactWaveform, forKey: "disableCompactWaveform") }
    }
    @Published var disableArtworkFlip: Bool {
        didSet { defaults.set(disableArtworkFlip, forKey: "disableArtworkFlip") }
    }
    @Published var showLyricsInExpanded: Bool {
        didSet { defaults.set(showLyricsInExpanded, forKey: "showLyricsInExpanded") }
    }
    @Published var showLyricsOnIsland: Bool {
        didSet { defaults.set(showLyricsOnIsland, forKey: "showLyricsOnIsland") }
    }

    // MARK: - Lyrics appearance (Lyriam extras)

    @Published var fontName: String {
        didSet { defaults.set(fontName, forKey: "fontName") }
    }
    @Published var lyricFontSize: Double {
        didSet { defaults.set(lyricFontSize, forKey: "lyricFontSize") }
    }
    @Published var marqueeSpeed: Double {
        didSet { defaults.set(marqueeSpeed, forKey: "marqueeSpeed") }
    }
    @Published var customColorHex: String {
        didSet { defaults.set(customColorHex, forKey: "customColorHex") }
    }

    /// Notch width/height fine-tuning (Alcove Tuning).
    @Published var notchWidthBias: Double {
        didSet { defaults.set(notchWidthBias, forKey: "notchWidthBias") }
    }
    @Published var notchHeightBias: Double {
        didSet { defaults.set(notchHeightBias, forKey: "notchHeightBias") }
    }

    var customColor: Color {
        get { Color(hex: customColorHex) ?? .white }
        set { customColorHex = newValue.toHex() }
    }

    private init() {
        islandMode = IslandMode(rawValue: defaults.string(forKey: "islandMode") ?? "") ?? .leftSafe
        expandOnHover = defaults.object(forKey: "expandOnHover") as? Bool ?? true
        let hover = defaults.double(forKey: "hoverDuration")
        hoverDuration = hover > 0 ? hover : 0.25
        contrastOutline = defaults.object(forKey: "contrastOutline") as? Bool ?? true
        progressiveBlur = defaults.object(forKey: "progressiveBlur") as? Bool ?? true
        hideInFullscreen = defaults.object(forKey: "hideInFullscreen") as? Bool ?? true
        hideMenuBarIcon = defaults.object(forKey: "hideMenuBarIcon") as? Bool ?? false
        showVolumeHUD = defaults.object(forKey: "showVolumeHUD") as? Bool ?? true
        showBrightnessHUD = defaults.object(forKey: "showBrightnessHUD") as? Bool ?? true
        replaceSystemHUD = defaults.object(forKey: "replaceSystemHUD") as? Bool ?? true
        showHeadphoneActivity = defaults.object(forKey: "showHeadphoneActivity") as? Bool ?? true
        showChargingActivity = defaults.object(forKey: "showChargingActivity") as? Bool ?? true
        clipboardEnabled = defaults.object(forKey: "clipboardEnabled") as? Bool ?? true
        fileShelfEnabled = defaults.object(forKey: "fileShelfEnabled") as? Bool ?? true
        showCapsLockActivity = defaults.object(forKey: "showCapsLockActivity") as? Bool ?? true
        showNetworkActivity = defaults.object(forKey: "showNetworkActivity") as? Bool ?? true
        showNetworkDashboard = defaults.object(forKey: "showNetworkDashboard") as? Bool ?? true
        showLockScreenMusic = defaults.object(forKey: "showLockScreenMusic") as? Bool ?? true
        forceSimulatedNotch = defaults.object(forKey: "forceSimulatedNotch") as? Bool ?? false
        idleActivity = IdleActivity(rawValue: defaults.string(forKey: "idleActivity") ?? "") ?? .nowPlaying
        mediaSource = MediaSourceKind(rawValue: defaults.string(forKey: "mediaSource") ?? "") ?? .auto

        swipeToSkip = defaults.object(forKey: "swipeToSkip") as? Bool ?? true
        swipeToToggle = defaults.object(forKey: "swipeToToggle") as? Bool ?? true

        colorStyle = ColorStyle(rawValue: defaults.string(forKey: "colorStyle") ?? "") ?? .artwork
        useLiveWaveform = defaults.object(forKey: "useLiveWaveform") as? Bool ?? true
        disableCompactWaveform = defaults.object(forKey: "disableCompactWaveform") as? Bool ?? false
        disableArtworkFlip = defaults.object(forKey: "disableArtworkFlip") as? Bool ?? false
        showLyricsInExpanded = defaults.object(forKey: "showLyricsInExpanded") as? Bool ?? true
        showLyricsOnIsland = defaults.object(forKey: "showLyricsOnIsland") as? Bool ?? true

        fontName = defaults.string(forKey: "fontName") ?? "System"
        let size = defaults.double(forKey: "lyricFontSize")
        lyricFontSize = size > 0 ? size : 15
        let speed = defaults.double(forKey: "marqueeSpeed")
        marqueeSpeed = speed > 0 ? speed : 30
        customColorHex = defaults.string(forKey: "customColorHex") ?? "#FFFFFF"
        notchWidthBias = defaults.double(forKey: "notchWidthBias")
        notchHeightBias = defaults.double(forKey: "notchHeightBias")
    }

    func lyricColor(artworkColor: Color?) -> Color {
        switch colorStyle {
        case .mono:     return .white
        case .color:    return customColor
        case .gradient, .artwork:
            return artworkColor?.readableOnDark() ?? .white
        }
    }

    func font(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        if fontName == "System" { return .system(size: size, weight: weight) }
        return .custom(fontName, size: size)
    }

    static var availableFonts: [String] {
        ["System"] + NSFontManager.shared.availableFontFamilies
    }
}
