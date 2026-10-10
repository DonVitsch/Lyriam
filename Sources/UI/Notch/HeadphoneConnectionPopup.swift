import AppKit
import SwiftUI
import Combine

/// A separate accessory window, so connection feedback never changes the
/// calibrated collapsed or expanded silhouette of the island itself.
@MainActor
final class HeadphoneConnectionPopupController {
    private let model = HeadphonePopupPresentation()
    private let panel: HeadphoneConnectionPanel
    private var dismissalTimer: Timer?
    private var closeTask: Task<Void, Never>?
    private var deadline: Date?
    private var remainingTime: TimeInterval = 6
    private var hovering = false
    private var presentationGeneration = 0

    var isVisible: Bool { panel.isVisible }
    var isPointerInside: Bool { panel.isVisible && panel.frame.contains(NSEvent.mouseLocation) }

    init() {
        panel = HeadphoneConnectionPanel(
            contentRect: NSRect(origin: .zero, size: HeadphonePopupMetrics.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        // Full-screen suppression is coordinated by the owning NotchPanel.
        // This accessory does not opt into full-screen auxiliary presentation.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: HeadphonePopupStage(
            model: model,
            onClose: { [weak self] in self?.dismiss() },
            onHover: { [weak self] in self?.setHovering($0) }
        ))
        hosting.sizingOptions = []
        panel.contentView = hosting
    }

    deinit {
        dismissalTimer?.invalidate()
        closeTask?.cancel()
    }

    /// `anchorFrame` uses AppKit screen coordinates. Its midpoint should be the
    /// physical notch center, and its bottom edge the current island's bottom.
    func present(device: HeadphoneDevice, connected: Bool, anchorFrame: NSRect, screen: NSScreen) {
        presentationGeneration += 1
        let generation = presentationGeneration
        closeTask?.cancel()
        closeTask = nil
        dismissalTimer?.invalidate()
        deadline = nil
        remainingTime = 6
        model.device = device
        model.connected = connected
        updateAnchor(anchorFrame: anchorFrame, screen: screen)
        panel.orderFrontRegardless()
        hovering = panel.frame.insetBy(dx: 20, dy: 20).contains(NSEvent.mouseLocation)
        // Commit the initial hidden pose first; subsequent events can reverse
        // an in-flight dismissal without replacing or activating the window.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentationGeneration == generation else { return }
            self.model.presented = true
            if !self.hovering { self.scheduleDismissal() }
        }
    }

    func updateAnchor(anchorFrame: NSRect, screen: NSScreen) {
        let size = HeadphonePopupMetrics.windowSize
        let margin: CGFloat = 8
        let x = min(max(anchorFrame.midX - size.width / 2, screen.frame.minX + margin),
                    screen.frame.maxX - size.width - margin)
        // Twenty points of transparent inset leave a visible twelve-point gap
        // below the island, with room for the card's shadow and entrance motion.
        let y = max(screen.visibleFrame.minY + margin,
                    anchorFrame.minY + 8 - size.height)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    /// Refresh asynchronously arriving battery readings without restarting the
    /// connection animation or its remaining visible time.
    func updateDevice(_ device: HeadphoneDevice) {
        guard model.device?.id == device.id, panel.isVisible else { return }
        model.device = device
        model.connected = device.isConnected
    }

    func dismiss(animated: Bool = true) {
        presentationGeneration += 1
        let generation = presentationGeneration
        dismissalTimer?.invalidate()
        dismissalTimer = nil
        deadline = nil
        hovering = false
        closeTask?.cancel()
        model.presented = false
        guard animated, panel.isVisible else {
            panel.orderOut(nil)
            return
        }
        let delay: UInt64 = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 180_000_000 : 400_000_000
        closeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self,
                  self.presentationGeneration == generation else { return }
            self.panel.orderOut(nil)
        }
    }

    private func setHovering(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value
        if value {
            if let deadline { remainingTime = max(0.1, deadline.timeIntervalSinceNow) }
            dismissalTimer?.invalidate()
            dismissalTimer = nil
            deadline = nil
        } else if model.presented {
            scheduleDismissal()
        }
    }

    private func scheduleDismissal() {
        dismissalTimer?.invalidate()
        deadline = Date().addingTimeInterval(remainingTime)
        let timer = Timer(timeInterval: remainingTime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissalTimer = timer
    }
}

private final class HeadphoneConnectionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private enum HeadphonePopupMetrics {
    static let cardSize = CGSize(width: 360, height: 304)
    static let windowSize = CGSize(width: 400, height: 344)
}

@MainActor
private final class HeadphonePopupPresentation: ObservableObject {
    @Published var device: HeadphoneDevice?
    @Published var connected = true
    @Published var presented = false
}

private struct HeadphonePopupStage: View {
    @ObservedObject var model: HeadphonePopupPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        ZStack {
            if let device = model.device {
                HeadphoneConnectionCard(
                    device: device, connected: model.connected,
                    onClose: onClose, onHover: onHover, animateMotion: model.presented
                )
                .scaleEffect(reduceMotion || model.presented ? 1 : 0.94, anchor: .top)
                .offset(y: reduceMotion || model.presented ? 0 : -16)
                .opacity(model.presented ? 1 : 0)
                .allowsHitTesting(model.presented)
            }
        }
        .frame(width: HeadphonePopupMetrics.windowSize.width, height: HeadphonePopupMetrics.windowSize.height)
        .animation(reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.36, dampingFraction: 1), value: model.presented)
        .environment(\.colorScheme, .light)
    }
}

/// Real product footage on the left; a fixed charging case and its own battery on the right.
struct HeadphoneConnectionCard: View {
    let device: HeadphoneDevice
    let connected: Bool
    let onClose: () -> Void
    var onHover: (Bool) -> Void = { _ in }
    var animateMotion = true
    private let ink = Color(red: 0.1, green: 0.11, blue: 0.13)
    private let secondaryInk = Color(white: 0.45)
    private var hasCase: Bool { device.isAirPods && device.symbol != "airpodsmax" }

    var body: some View {
        VStack(spacing: 0) {
            Text(device.name)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(ink).multilineTextAlignment(.center)
                .lineLimit(2).minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity).frame(height: 48)
                .padding(.horizontal, 38).padding(.top, 19)
            HStack(spacing: 5) {
                Circle().fill(connected ? Color.green : secondaryInk).frame(width: 4, height: 4)
                Text(connected ? "已连接" : "已断开").font(.system(size: 10, weight: .medium)).foregroundStyle(secondaryInk)
            }.padding(.top, 2)
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 4) {
                    HeadphoneProductMotionView(device: device, playing: connected && animateMotion)
                        .frame(width: hasCase ? 148 : 190, height: 142)
                    if connected {
                        HStack(spacing: 16) {
                            if device.leftBatteryLevel != nil || device.rightBatteryLevel != nil {
                                HeadphoneBatteryRing(label: "左耳", value: device.leftBatteryLevel)
                                HeadphoneBatteryRing(label: "右耳", value: device.rightBatteryLevel)
                            } else {
                                HeadphoneBatteryRing(label: hasCase ? "耳机" : "电量", value: device.batteryLevel)
                            }
                        }
                    }
                }.frame(width: hasCase ? 156 : 240)
                if hasCase {
                    VStack(spacing: 4) {
                        Group {
                            if let image = HeadphoneAnimationAssets.image(device.animationFamily, part: "case") {
                                Image(nsImage: image).resizable().scaledToFit()
                            }
                        }.frame(width: 140, height: 142)
                        if connected { HeadphoneBatteryRing(label: "充电盒", value: device.caseBatteryLevel) }
                    }.frame(width: 148)
                }
            }
            .frame(maxWidth: .infinity).padding(.top, 6)
            .opacity(connected ? 1 : 0.55)
            Spacer(minLength: 0)
        }
        .frame(width: HeadphonePopupMetrics.cardSize.width, height: HeadphonePopupMetrics.cardSize.height)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(white: 0.985))
                .overlay { RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white, lineWidth: 1) }
                .shadow(color: .black.opacity(0.17), radius: 12, y: 6)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(secondaryInk).frame(width: 24, height: 24)
                    .background(Color.black.opacity(0.055), in: Circle())
            }.buttonStyle(.plain).help("关闭连接卡片").accessibilityLabel("关闭连接卡片").padding(12)
        }
        .onHover(perform: onHover).environment(\.colorScheme, .light)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(device.name)，\(connected ? "已连接" : "已断开")")
    }
}

private struct HeadphoneBatteryRing: View {
    let label: String
    let value: Int?
    private var level: Int? { value.map { min(100, max(0, $0)) } }
    private var tint: Color { (level ?? 100) <= 15 ? .red : Color(red: 0.16, green: 0.72, blue: 0.34) }
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.black.opacity(0.07), lineWidth: 3)
                if let level {
                    Circle().trim(from: 0, to: Double(level) / 100)
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                }
                Text(level.map { "\($0)%" } ?? "—")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(white: 0.16)).monospacedDigit()
            }.frame(width: 35, height: 35)
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(Color(white: 0.45))
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label)，\(level.map { "\($0)%" } ?? "电量暂不可用")")
    }
}
