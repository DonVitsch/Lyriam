import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    private let fonts = AppSettings.availableFonts

    var body: some View {
        Form {
            Section("灵动岛模式") {
                Picker("位置模式", selection: $settings.islandMode) {
                    ForEach(IslandMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("歌词外观") {
                Picker("字体", selection: $settings.fontName) {
                    ForEach(fonts, id: \.self) { Text($0).tag($0) }
                }

                VStack(alignment: .leading) {
                    Text("字号:\(Int(settings.lyricFontSize)) pt")
                    Slider(value: $settings.lyricFontSize, in: 12...32, step: 1)
                }

                VStack(alignment: .leading) {
                    Text("滚动速度:\(Int(settings.marqueeSpeed)) pt/s")
                    Slider(value: $settings.marqueeSpeed, in: 10...80, step: 5)
                }
            }

            Section("歌词颜色") {
                Picker("颜色模式", selection: $settings.lyricColorMode) {
                    ForEach(LyricColorMode.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.radioGroup)

                if settings.lyricColorMode == .custom {
                    ColorPicker("自定义颜色", selection: Binding(
                        get: { settings.customColor },
                        set: { settings.customColor = $0 }
                    ))
                }
            }

            Section {
                Text("提示:歌词过长时会自动横向滚动,速度由上面的滑块控制。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 440)
    }
}
