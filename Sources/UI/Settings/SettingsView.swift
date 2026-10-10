import ApplicationServices
import SwiftUI

/// Alcove-inspired settings: sidebar sections + grouped cards.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var mediaKeys = MediaKeyHUDController.shared
    @State private var tab: SettingsTab = .general

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general, activities, nowPlaying, lyrics, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general:    return "通用"
            case .activities: return "活动"
            case .nowPlaying: return "正在播放"
            case .lyrics:     return "歌词"
            case .about:      return "关于"
            }
        }
        var symbol: String {
            switch self {
            case .general:    return "gearshape"
            case .activities: return "sparkles"
            case .nowPlaying: return "play.circle.fill"
            case .lyrics:     return "text.quote"
            case .about:      return "info.circle"
            }
        }
        var tint: Color {
            switch self {
            case .general:    return .gray
            case .activities: return .cyan
            case .nowPlaying: return .pink
            case .lyrics:     return .mint
            case .about:      return .secondary
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 180)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 640, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Lyriam")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 6)

            ForEach(SettingsTab.allCases) { t in
                Button {
                    tab = t
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: t.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(t.tint)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(t.tint.opacity(0.15))
                            )
                        Text(t.title)
                            .font(.system(size: 13, weight: tab == t ? .semibold : .regular))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(tab == t ? Color.primary.opacity(0.08) : .clear)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }
            Spacer()
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    @ViewBuilder
    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(tab.title)
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.bottom, 2)

                switch tab {
                case .general:    generalSection
                case .activities: activitiesSection
                case .nowPlaying: nowPlayingSection
                case .lyrics:     lyricsSection
                case .about:      aboutSection
                }
            }
            .padding(24)
        }
    }

    // MARK: - Sections

    private var generalSection: some View {
        VStack(spacing: 14) {
            card {
                toggleRow("全屏时自动隐藏", isOn: $settings.hideInFullscreen)
                Divider().opacity(0.4)
                toggleRow("隐藏菜单栏图标", isOn: $settings.hideMenuBarIcon)
            }

            sectionLabel("空闲显示")
            card {
                Picker("空闲显示", selection: $settings.idleActivity) {
                    ForEach(IdleActivity.allCases) { a in
                        Text(a.displayName).tag(a)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            sectionLabel("行为")
            card {
                toggleRow("高对比描边", isOn: $settings.contrastOutline)
                Divider().opacity(0.4)
                toggleRow("渐进模糊", isOn: $settings.progressiveBlur)
                Divider().opacity(0.4)
                toggleRow("悬停自动展开", isOn: $settings.expandOnHover)
                if settings.expandOnHover {
                    Divider().opacity(0.4)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("悬停触发延迟")
                            Spacer()
                            Text(String(format: "%.2f 秒", settings.hoverDuration))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $settings.hoverDuration, in: 0.1...1.0, step: 0.05)
                    }
                    .padding(.vertical, 2)
                }
            }

            sectionLabel("手势")
            card {
                toggleRow("滑动切换歌曲", isOn: $settings.swipeToSkip)
                Divider().opacity(0.4)
                toggleRow("滑动展开／收起", isOn: $settings.swipeToToggle)
            }
        }
    }

    private var activitiesSection: some View {
        VStack(spacing: 14) {
            sectionLabel("系统活动")
            card {
                toggleRow("音量提示动画", isOn: $settings.showVolumeHUD)
                Divider().opacity(0.4)
                toggleRow("亮度提示动画", isOn: $settings.showBrightnessHUD)
                Divider().opacity(0.4)
                toggleRow("接管系统音量和亮度提示", isOn: $settings.replaceSystemHUD)
                Divider().opacity(0.4)
                toggleRow("耳机连接动画", isOn: $settings.showHeadphoneActivity)
                Divider().opacity(0.4)
                toggleRow("充电动画", isOn: $settings.showChargingActivity)
                Divider().opacity(0.4)
                toggleRow("大写锁定提示", isOn: $settings.showCapsLockActivity)
                Divider().opacity(0.4)
                toggleRow("网络连接提醒", isOn: $settings.showNetworkActivity)
            }
            HStack {
                Text(mediaKeys.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if settings.replaceSystemHUD && mediaKeys.permissionRequired {
                    Button("授权辅助功能", action: mediaKeys.requestPermission).controlSize(.small)
                }
            }
            Text("接管后，音量和亮度按键由 Lyriam 调节并显示提示。全屏隐藏、锁屏或设备不支持调节时交还系统。耳机连接卡片独立显示在岛的下方。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            sectionLabel("快捷工具")
            card {
                toggleRow("剪贴板历史", isOn: $settings.clipboardEnabled)
                Divider().opacity(0.4)
                toggleRow("文件中转站", isOn: $settings.fileShelfEnabled)
                Divider().opacity(0.4)
                toggleRow("展开时显示网络状态", isOn: $settings.showNetworkDashboard)
                Divider().opacity(0.4)
                toggleRow("锁屏音乐", isOn: $settings.showLockScreenMusic)
            }
            Text("剪贴板记录开启后复制的文字和图片，支持预览与重新复制；保留最近 20 条和最多 20 条固定内容，受内存容量限制。历史仅存于内存，退出后清空；标记为敏感的内容会跳过。⌃⌥V 打开剪贴板。文件暂存适合跨应用拖拽：先放入，再拖到聊天、邮件或浏览器；移除引用不会删除原文件。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("倒计时到点提醒，便签与待办自动保存。小镜子点击开启后使用摄像头，收起或离开页面即停止。展开时在顶部显示本机流量和出口地区。锁屏音乐展示封面、歌曲和播放控制。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nowPlayingSection: some View {
        VStack(spacing: 14) {
            sectionLabel("媒体来源")
            card {
                Picker("媒体来源", selection: $settings.mediaSource) {
                    ForEach(MediaSourceKind.allCases) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            Text(mediaSourceHint)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            card {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("播放控制权限")
                            .font(.system(size: 13))
                        Text("控制播放／切歌优先走免权限接口；若系统拒绝该接口，会回退为发送系统媒体键，这一步需要辅助功能权限。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("授权辅助功能", action: requestAccessibilityPermission)
                        .controlSize(.small)
                }
            }

            sectionLabel("配色风格")
            card {
                Picker("配色", selection: $settings.colorStyle) {
                    ForEach(ColorStyle.allCases) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if settings.colorStyle == .color {
                    Divider().opacity(0.4)
                    ColorPicker("自定义颜色", selection: Binding(
                        get: { settings.customColor },
                        set: { settings.customColor = $0 }
                    ))
                }
            }

            sectionLabel("波形与封面")
            card {
                toggleRow("实时波形", isOn: $settings.useLiveWaveform)
                Divider().opacity(0.4)
                toggleRow("关闭紧凑波形", isOn: $settings.disableCompactWaveform)
                Divider().opacity(0.4)
                toggleRow("关闭封面翻转", isOn: $settings.disableArtworkFlip)
            }
        }
    }

    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }

    private var mediaSourceHint: String {        switch settings.mediaSource {
        case .auto:
            return "自动跟随正在出声的播放器：网易云音乐、Apple Music、Spotify。浏览器里的视频不会触发。"
        case .netease:
            return "只读取网易云音乐。曲目信息来自系统「正在播放」，封面由网易云接口补齐。"
        case .appleMusic:
            return "只读取 Apple Music，通过其脚本接口获取最精确的信息。"
        case .spotify:
            return "只读取 Spotify。曲目信息来自系统「正在播放」。"
        }
    }

    private var lyricsSection: some View {
        VStack(spacing: 14) {
            // Hard requirements called out explicitly.
            card {
                toggleRow("收起时在岛上显示歌词", isOn: $settings.showLyricsOnIsland)
                Divider().opacity(0.4)
                toggleRow("展开时显示歌词", isOn: $settings.showLyricsInExpanded)
            }

            sectionLabel("外观")
            card {
                Picker("字体", selection: $settings.fontName) {
                    ForEach(AppSettings.availableFonts.prefix(40), id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Divider().opacity(0.4)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("字号")
                        Spacer()
                        Text("\(Int(settings.lyricFontSize)) pt")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.lyricFontSize, in: 11...28, step: 1)
                }
                Divider().opacity(0.4)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("滚动速度")
                        Spacer()
                        Text("\(Int(settings.marqueeSpeed)) pt/秒")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.marqueeSpeed, in: 10...80, step: 5)
                }
            }

            Text("收起态优先显示当前歌词行；没有歌词时回退为「歌名 · 歌手」。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            card {
                HStack(spacing: 14) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 28))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.black)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lyriam")
                            .font(.system(size: 16, weight: .semibold))
                        Text("仿灵动岛 · 同步歌词 · 系统活动 · 快捷工具")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            Text("v0.6.0 · 歌词、系统活动与快捷工具")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Chrome helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.switch)
    }
}
