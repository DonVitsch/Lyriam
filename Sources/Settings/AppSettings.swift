import Foundation
import SwiftUI
import AppKit

/// Placement modes for the collapsed island. All modes wrap the notch (the
/// camera gap stays aligned to the physical notch); they differ in how far the
/// bar extends to the right of the camera.
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

/// How the lyric text is colored.
enum LyricColorMode: String, CaseIterable, Identifiable {
    case followArtwork  // derived from the album-art theme color
    case custom         // a fixed user-chosen color
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .followArtwork: return "跟随封面主题色"
        case .custom:        return "自定义颜色"
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
    /// "System" means the default system font; otherwise an installed family name.
    @Published var fontName: String {
        didSet { defaults.set(fontName, forKey: "fontName") }
    }
    /// Base lyric font size used in the collapsed bar (CJK uses this directly,
    /// Latin scales down a little).
    @Published var lyricFontSize: Double {
        didSet { defaults.set(lyricFontSize, forKey: "lyricFontSize") }
    }
    /// Marquee scroll speed (points per second) for over-long lyric lines.
    @Published var marqueeSpeed: Double {
        didSet { defaults.set(marqueeSpeed, forKey: "marqueeSpeed") }
    }
    @Published var lyricColorMode: LyricColorMode {
        didSet { defaults.set(lyricColorMode.rawValue, forKey: "lyricColorMode") }
    }
    @Published var customColorHex: String {
        didSet { defaults.set(customColorHex, forKey: "customColorHex") }
    }

    /// The fixed user color (backed by `customColorHex`).
    var customColor: Color {
        get { Color(hex: customColorHex) ?? .white }
        set { customColorHex = newValue.toHex() }
    }

    private init() {
        islandMode = IslandMode(rawValue: defaults.string(forKey: "islandMode") ?? "") ?? .leftSafe
        fontName = defaults.string(forKey: "fontName") ?? "System"
        let size = defaults.double(forKey: "lyricFontSize")
        lyricFontSize = size > 0 ? size : 20
        let speed = defaults.double(forKey: "marqueeSpeed")
        marqueeSpeed = speed > 0 ? speed : 30
        lyricColorMode = LyricColorMode(rawValue: defaults.string(forKey: "lyricColorMode") ?? "") ?? .custom
        customColorHex = defaults.string(forKey: "customColorHex") ?? "#FFFFFF"
    }

    /// Resolve the lyric text color given the current album-art theme color.
    func lyricColor(artworkColor: Color?) -> Color {
        switch lyricColorMode {
        case .custom:       return customColor
        case .followArtwork: return artworkColor?.readableOnDark() ?? .white
        }
    }

    /// Resolve the chosen font family into a SwiftUI Font at the given size.
    func font(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        if fontName == "System" { return .system(size: size, weight: weight) }
        return .custom(fontName, size: size)
    }

    /// Installed font families, with "System" first, for the picker.
    static var availableFonts: [String] {
        ["System"] + NSFontManager.shared.availableFontFamilies
    }
}
