import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct IslandActivityView: View {
    let activity: IslandActivity
    let state: IslandState
    var feedbackSequence: UInt64 = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var symbol: String {
        switch activity {
        case let .hud(kind, _, muted, _): return muted ? "speaker.slash.fill" : kind.symbol
        case let .headphones(device, _): return device.symbol
        case let .power(connected, _): return connected ? "bolt.fill" : "battery.100percent"
        case .capsLock: return "capslock.fill"
        case let .network(connected): return connected ? "wifi" : "wifi.slash"
        case .timerFinished: return "timer"
        }
    }
    private var accent: Color {
        switch activity { case .hud, .capsLock: return .white; case let .headphones(_, connected), let .network(connected): return connected ? .mint : .orange; case .power: return Color(red: 0.16, green: 0.59, blue: 1); case .timerFinished: return .orange }
    }
    private var trailing: String {
        switch activity {
        case let .hud(_, value, muted, _): return "\(Int(((muted ? 0 : value) * 100).rounded()))%"
        case let .headphones(_, connected): return connected ? "checkmark" : "xmark"
        case let .power(_, value): return value.map { "\($0)%" } ?? "bolt"
        case let .capsLock(enabled): return enabled ? "ON" : "OFF"
        case let .network(connected): return connected ? "checkmark" : "xmark"
        case .timerFinished: return "checkmark"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Group {
                    if case let .headphones(device, _) = activity, device.isAirPods && device.symbol == "airpods" {
                        AirPodsLogo().frame(width: 19, height: 19)
                    } else if case let .hud(kind, _, muted, _) = activity {
                        HUDFeedbackIcon(kind: kind, muted: muted, sequence: feedbackSequence)
                    } else {
                        Image(systemName: symbol)
                    }
                }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accent)
                    .padding(.leading, 12)
                    .frame(width: state.leftWing)
                Color.clear.frame(width: state.gap)
                Group {
                    if trailing == "checkmark" || trailing == "xmark" || trailing == "bolt" {
                        Image(systemName: trailing).font(.system(size: 12, weight: .semibold))
                    } else {
                        Text(trailing).font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .contentTransition(.numericText())
                    }
                }
                .foregroundStyle(accent)
                .padding(.trailing, 12)
                .frame(width: state.rightWing)
            }
            .frame(height: state.menuBarZone)
            Group {
                switch activity {
                case let .hud(kind, value, muted, _):
                    HStack(spacing: 8) {
                        Text(kind.title).font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.65))
                        IslandLevelBar(value: muted ? 0 : value, tint: .white)
                            .frame(height: 4)
                    }
                case let .headphones(device, connected):
                    Text("\(device.name) · \(connected ? "已连接" : "已断开")")
                        .font(.system(size: 10, weight: .medium)).lineLimit(1)
                        .foregroundStyle(.white.opacity(0.85))
                case let .power(connected, percentage):
                    VStack(spacing: 2) {
                        Text(connected ? "已接通电源" : "使用电池")
                            .font(.system(size: 9, weight: .medium)).foregroundStyle(accent.opacity(0.9))
                        ChargingLevelBar(value: Double(percentage ?? 0) / 100, connected: connected)
                            .frame(height: 4)
                    }
                case let .capsLock(enabled):
                    Text(enabled ? "Caps Lock On" : "Caps Lock Off")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                case let .network(connected):
                    Text(connected ? "Network connected" : "Network disconnected")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                case .timerFinished:
                    Text("时间到").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .frame(height: max(state.collapsedHeight - state.menuBarZone - 7, 12))
            .padding(.horizontal, 28).padding(.bottom, 7)
        }
        .frame(width: state.barWidth, height: state.barHeight)
        .modifier(HUDLimitFeedback(sequence: feedbackSequence, atLimit: atLimit))
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.25, dampingFraction: 1), value: trailing)
        .accessibilityElement(children: .combine)
        .onTapGesture { NotificationCenter.default.post(name: .lyriamOpenIslandPage, object: activity.page) }
        .help("点击查看详情")
    }

    private var atLimit: Bool {
        if case let .hud(_, _, _, limit) = activity { return limit }
        return false
    }
}

/// The trigger is the key press, including presses that leave the level unchanged.
struct HUDFeedbackIcon: View {
    let kind: SystemHUDKind
    let muted: Bool
    let sequence: UInt64
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse: UInt64 = 0

    var body: some View {
        Image(systemName: muted ? "speaker.slash.fill" : kind.symbol)
            .symbolEffect(.bounce, options: .nonRepeating, value: pulse)
            .keyframeAnimator(initialValue: 0.0, trigger: pulse) { icon, degrees in
                icon.rotationEffect(.degrees(kind == .brightness ? degrees : 0))
            } keyframes: { _ in
                LinearKeyframe(12.0, duration: 0.08)
                SpringKeyframe(0.0, duration: 0.24, spring: .snappy)
            }
            .onAppear { if !reduceMotion { pulse &+= 1 } }
            .onChange(of: sequence) { _, _ in if !reduceMotion { pulse &+= 1 } }
    }
}

struct HUDLimitFeedback: ViewModifier {
    let sequence: UInt64
    let atLimit: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shake: UInt64 = 0
    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 0.0, trigger: shake) { view, offset in
            view.offset(x: offset)
        } keyframes: { _ in
            LinearKeyframe(atLimit && !reduceMotion ? -2.0 : 0.0, duration: 0.045)
            LinearKeyframe(atLimit && !reduceMotion ? 2.0 : 0.0, duration: 0.07)
            LinearKeyframe(atLimit && !reduceMotion ? -1.0 : 0.0, duration: 0.055)
            LinearKeyframe(0.0, duration: 0.05)
        }
        .onAppear { if atLimit && !reduceMotion { shake &+= 1 } }
        .onChange(of: sequence) { _, _ in if atLimit && !reduceMotion { shake &+= 1 } }
    }
}

struct ExpandedHUDFeedback: View {
    let kind: SystemHUDKind
    let value: Double
    let muted: Bool
    let atLimit: Bool
    let sequence: UInt64
    var body: some View {
        HStack(spacing: 5) {
            HUDFeedbackIcon(kind: kind, muted: muted, sequence: sequence)
                .font(.system(size: 11, weight: .semibold))
            Text("\(kind.title) \(Int(((muted ? 0 : value) * 100).rounded()))%")
                .font(.system(size: 10, weight: .medium).monospacedDigit()).fixedSize()
            IslandLevelBar(value: muted ? 0 : value).frame(width: 28, height: 3)
        }
        .foregroundStyle(.white)
        .modifier(HUDLimitFeedback(sequence: sequence, atLimit: atLimit))
        .accessibilityLabel("\(kind.title) \(Int((value * 100).rounded())) percent\(atLimit ? ", limit reached" : "")")
    }
}

struct IslandLevelBar: View {
    let value: Double
    var tint: Color = .white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(tint).frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 1), value: value)
    }
}

struct SystemControlsView: View {
    @ObservedObject var controls: SystemControlsMonitor
    @ObservedObject var battery: BatteryMonitor
    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                controlCard(kind: .volume,
                            value: controls.muted ? 0 : controls.volume, available: controls.volumeAvailable,
                            detail: controls.outputName.isEmpty ? "Audio output" : controls.outputName,
                            set: controls.setVolume)
                controlCard(kind: .brightness, value: controls.brightness,
                            available: controls.brightnessAvailable, detail: "Built-in display", set: controls.setBrightness)
            }
            HStack(spacing: 8) {
                if battery.hasBattery {
                    Image(systemName: battery.isPluggedIn ? "battery.100percent.bolt" : "battery.100percent")
                        .foregroundStyle(battery.isPluggedIn ? Color.mint : .white.opacity(0.6))
                    Text(battery.isCharging ? "Charging" : battery.isPluggedIn ? "Power connected" : "On battery")
                    if let percentage = battery.percentage {
                        Text("\(percentage)%").monospacedDigit()
                    }
                }
                Spacer()
                Button(controls.muted ? "Unmute" : "Mute", action: controls.toggleMute)
                    .buttonStyle(.plain).disabled(!controls.muteAvailable)
                    .foregroundStyle(.white.opacity(controls.muteAvailable ? 0.8 : 0.3))
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
        }
        .padding(.top, 5)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private func controlCard(kind: SystemHUDKind, value: Double, available: Bool,
                             detail: String, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HUDFeedbackIcon(kind: kind, muted: kind == .volume && controls.muted,
                                sequence: kind == .volume ? controls.volumeFeedback : controls.brightnessFeedback)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(available ? 0.92 : 0.45))
                Spacer()
                Text(kind.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            }
            Text(available ? "\(Int((value * 100).rounded()))%" : "—")
                .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(available ? 1 : 0.45))
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.15), value: value)
            Slider(value: Binding(get: { value }, set: set), in: 0...1)
                .tint(.white).disabled(!available).accessibilityLabel(kind.title)
            Text(available ? detail : "Adjustment unavailable")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .modifier(HUDLimitFeedback(sequence: kind == .volume ? controls.volumeFeedback : controls.brightnessFeedback,
                                   atLimit: kind == .volume ? controls.volumeAtLimit : controls.brightnessAtLimit))
    }
}

struct HeadphonesView: View {
    @ObservedObject var monitor: BluetoothDevicesMonitor
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("蓝牙耳机").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { monitor.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6)).help("刷新设备状态")
                Button("蓝牙设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
                }
                .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
            }
            if monitor.devices.isEmpty {
                IslandEmptyView(symbol: "headphones", title: "等待耳机连接",
                                detail: monitor.statusMessage ?? "连接 AirPods 或其他蓝牙耳机后，状态会显示在这里。")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(monitor.devices) { device in deviceCard(device) }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .foregroundStyle(.white)
    }

    private func deviceCard(_ device: HeadphoneDevice) -> some View {
        HStack(spacing: 15) {
            ZStack {
                Circle().fill(device.isConnected ? Color.mint.opacity(0.10) : .white.opacity(0.04))
                Group {
                    if device.isAirPods && device.symbol == "airpods" {
                        AirPodsLogo().frame(width: 34, height: 34)
                    } else {
                        Image(systemName: device.symbol).font(.system(size: 30, weight: .light))
                    }
                }.foregroundStyle(device.isConnected ? .white : .white.opacity(0.4))
            }.frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 7) {
                Text(device.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(device.isConnected ? Color.mint : .gray).frame(width: 5, height: 5)
                    Text(device.isAudioOutput ? "正在使用 · 音频输出" : device.isConnected ? "已连接" : "未连接")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                }
                HStack(spacing: 12) {
                    if let level = device.leftBatteryLevel { batteryLabel("左耳", level) }
                    if let level = device.rightBatteryLevel { batteryLabel("右耳", level) }
                    if let level = device.caseBatteryLevel { batteryLabel("充电盒", level) }
                    if device.leftBatteryLevel == nil && device.rightBatteryLevel == nil,
                       let level = device.batteryLevel { batteryLabel("电量", level) }
                }
            }
            Spacer(minLength: 0)
            if device.isConnected {
                Button("显示连接卡片") {
                    NotificationCenter.default.post(name: .lyriamShowHeadphoneConnection, object: device)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.white.opacity(0.08), in: Capsule())
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    private func batteryLabel(_ title: String, _ level: Int) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.white.opacity(0.45))
            Text("\(level)%").monospacedDigit().foregroundStyle(level <= 20 ? Color.orange : .mint)
        }.font(.system(size: 10, weight: .medium))
    }
}

struct FileShelfView: View {
    @ObservedObject var store: FileShelfStore
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("文件暂存").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("添加文件") {
                    let picker = NSOpenPanel()
                    picker.canChooseFiles = true; picker.canChooseDirectories = true; picker.allowsMultipleSelection = true
                    NotificationCenter.default.post(name: .lyriamBeginFilePicker, object: nil)
                    NSApp.activate(ignoringOtherApps: true)
                    picker.begin { response in
                        MainActor.assumeIsolated {
                            if response == .OK { _ = store.add(picker.urls) }
                            NotificationCenter.default.post(name: .lyriamEndFilePicker, object: nil)
                            NotificationCenter.default.post(name: .lyriamOpenIslandPage, object: IslandPage.files)
                        }
                    }
                }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
                Button { store.clear() } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.45)).help("移除所有文件引用")
            }
            if store.items.isEmpty {
                IslandEmptyView(symbol: "tray.and.arrow.down", title: "把文件拖到岛上",
                                detail: "从 Finder 拖入 → 切到聊天、邮件或浏览器 → 从这里拖出发送。这里只保存引用，原文件留在原处。")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 95), spacing: 8)], spacing: 8) {
                        ForEach(store.items) { item in
                            VStack(spacing: 6) {
                                Image(nsImage: item.icon).resizable().scaledToFit().frame(width: 38, height: 38)
                                Text(item.name).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity).frame(height: 82)
                            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                            .onTapGesture(count: 2) { store.open(item) }
                            .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider(object: item.url as NSURL) }
                            .contextMenu {
                                Button("打开") { store.open(item) }
                                Button("在 Finder 中显示") { store.reveal(item) }
                                Divider()
                                Button("移出暂存区") { store.remove(item) }
                            }
                        }
                    }
                }.scrollIndicators(.hidden)
            }
            if let error = store.lastError {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .foregroundStyle(.white)
    }
}

struct IslandEmptyView: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(.white.opacity(0.3))
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            Text(detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center).lineLimit(3)
        }
        .padding(.horizontal, 24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
