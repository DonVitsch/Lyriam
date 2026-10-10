import Foundation
import Combine

enum IslandPage: String, CaseIterable, Identifiable {
    case music, controls, devices, clipboard, files, timer, notes, mirror
    var id: String { rawValue }
    var title: String {
        switch self {
        case .music: return "音乐"
        case .controls: return "控制"
        case .devices: return "耳机"
        case .clipboard: return "剪贴板"
        case .files: return "文件中转站"
        case .timer: return "倒计时"
        case .notes: return "便签待办"
        case .mirror: return "小镜子"
        }
    }
    var symbol: String {
        switch self {
        case .music: return "music.note"
        case .controls: return "slider.horizontal.3"
        case .devices: return "headphones"
        case .clipboard: return "doc.on.clipboard"
        case .files: return "tray"
        case .timer: return "alarm"
        case .notes: return "checklist"
        case .mirror: return "camera"
        }
    }
}

enum IslandActivity {
    case hud(SystemHUDKind, Double, Bool, atLimit: Bool = false)
    case headphones(HeadphoneDevice, Bool)
    case power(Bool, Int?)
    case capsLock(Bool)
    case network(Bool)
    case timerFinished

    var key: String {
        switch self {
        case let .hud(kind, _, _, _): return "hud-\(kind.rawValue)"
        case let .headphones(device, connected): return "device-\(device.id)-\(connected)"
        case let .power(connected, _): return "power-\(connected)"
        case let .capsLock(enabled): return "caps-lock-\(enabled)"
        case let .network(connected): return "network-\(connected)"
        case .timerFinished: return "timer-finished"
        }
    }
    var priority: Int {
        switch self { case .hud: return 5; case .headphones, .capsLock, .network: return 2; case .timerFinished: return 4; case .power: return 1 }
    }
    var duration: TimeInterval {
        switch self { case .hud, .capsLock: return 1.7; case .headphones, .network: return 4; case .power: return 3; case .timerFinished: return 8 }
    }
    var page: IslandPage {
        switch self { case .hud, .power, .capsLock, .network: return .controls; case .headphones: return .devices; case .timerFinished: return .timer }
    }
}

/// Events replace content inside the existing silhouette, never its geometry.
@MainActor
final class IslandActivityCenter: ObservableObject {
    @Published private(set) var current: IslandActivity?
    @Published private(set) var feedbackSequence: UInt64 = 0
    private var expiry: Date = .distantPast
    private var pending: [(IslandActivity, Date)] = []
    private var dismissal: DispatchWorkItem?

    func present(_ activity: IslandActivity) {
        let deadline = Date().addingTimeInterval(activity.duration)
        if let current, current.priority > activity.priority, expiry > Date() {
            pending.removeAll { $0.0.key == activity.key || $0.1 <= Date() }
            pending.append((activity, deadline))
            return
        }
        if let current, current.priority < activity.priority, expiry > Date() {
            pending.append((current, expiry))
        }
        install(activity, until: deadline)
    }

    func clear() {
        dismissal?.cancel()
        dismissal = nil
        pending.removeAll()
        current = nil
    }

    private func install(_ activity: IslandActivity, until deadline: Date) {
        dismissal?.cancel()
        feedbackSequence &+= 1
        current = activity
        expiry = deadline
        let item = DispatchWorkItem { [weak self] in self?.advance() }
        dismissal = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: item)
    }

    private func advance() {
        pending.removeAll { $0.1 <= Date() }
        pending.sort { $0.0.priority > $1.0.priority }
        if let next = pending.first {
            pending.removeFirst()
            install(next.0, until: next.1)
        } else {
            current = nil
            dismissal = nil
        }
    }
}
