import AppKit
import SwiftUI
import Combine

/// Shared island state, driven by the panel and observed by SwiftUI.
@MainActor
final class IslandState: ObservableObject {
    @Published var expanded = false
    @Published var pinned = false
    /// Width of the collapsed bar (points); the bar is right-aligned inside the
    /// (wider) expanded window so its right edge stays at the equalizer cap.
    @Published var barWidth: CGFloat = 575
    // Internal layout segments of the bar.
    @Published var leftWingWidth: CGFloat = 330   // lyrics + album art (left of camera)
    @Published var gap: CGFloat = 185             // camera (painted black)
    @Published var rightCapWidth: CGFloat = 60    // equalizer (right of camera)
    /// Left inset of the bar within the window. 0 when collapsed; when expanded
    /// the window is centered on the camera, so the bar shifts to stay aligned.
    @Published var barLeadingInset: CGFloat = 0
    /// Height of the menu-bar band; the ticker/equalizer are centered in this
    /// top zone so they line up with the real menu bar items (Window/帮助…).
    @Published var menuBarZone: CGFloat = 37
    /// Collapsed bar height. Centered mode adds only a compact lyric band below
    /// the camera instead of extending deep into the screen.
    @Published var barHeight: CGFloat = 58
}

/// "Dynamic island" that wraps the notch: one continuous black bar runs from the
/// lyrics on the left, across the (blacked-out) camera, to the equalizer on the
/// right. The bar's right edge stops at `notchRight + rightCap`, well before the
/// menu bar's status icons, so it never covers them.
///
/// Click-through: while collapsed the window ignores mouse events so the menu
/// bar underneath stays clickable; only when expanded does it accept clicks.
/// Hover is polled from the global mouse location.
final class NotchPanel: NSPanel {
    static let leftWingWidth: CGFloat = 330
    static let rightCapWidth: CGFloat = 34
    static let centeredLeftWingWidth: CGFloat = 52
    static let centeredRightWingWidth: CGFloat = 46
    static let barHeight: CGFloat = 58
    static let cardHeight: CGFloat = 232
    static let expandedWidth: CGFloat = 860
    static var expandedHeight: CGFloat { barHeight + cardHeight }

    let state = IslandState()
    private var trackingTimer: Timer?
    private var barWidth: CGFloat = 575
    private var barLeftScreen: CGFloat = 0   // screen x of bar's left edge
    private var notchCenter: CGFloat = 0     // screen x of camera center
    private var cancellables: Set<AnyCancellable> = []

    init<Content: View>(@ViewBuilder content: (IslandState) -> Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 575, height: NotchPanel.barHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true

        computeGeometry()

        let hosting = NSHostingView(rootView: content(state))
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting

        applyFrame(expanded: false, animated: false)
        startTracking()

        // React to island-mode changes from the settings window.
        AppSettings.shared.$islandMode
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.computeGeometry()
                self.applyFrame(expanded: self.state.expanded, animated: true)
            }
            .store(in: &cancellables)
    }

    deinit { trackingTimer?.invalidate() }

    /// Align the camera gap to the physical notch and pin the right edge to
    /// `notchRight + rightCap`.
    private func computeGeometry() {
        guard let screen = NSScreen.main else { return }
        let notchLeft: CGFloat
        let notchRight: CGFloat
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            notchLeft = left.maxX
            notchRight = right.minX
        } else {
            // No notch: fake a small centered gap so layout still works.
            notchLeft = screen.frame.midX - 90
            notchRight = screen.frame.midX + 90
        }
        let gap = notchRight - notchLeft
        // Geometry depends on the mode:
        //  • leftSafe: wide left wing + tight right cap, never reaches the
        //    right-side apps.
        //  • notchCentered: smaller symmetric wings, centered on the camera
        //    (art top-left, equalizer top-right edge, text centered below).
        let centered = AppSettings.shared.islandMode == .notchCentered
        // Centered mode: compact wings so album art hugs the camera's left edge
        // and the equalizer hugs its right edge; lyrics wrap below the camera.
        let leftWing: CGFloat = centered ? Self.centeredLeftWingWidth : Self.leftWingWidth
        let rightWing: CGFloat = centered ? Self.centeredRightWingWidth : Self.rightCapWidth
        barWidth = leftWing + gap + rightWing
        barLeftScreen = notchLeft - leftWing
        notchCenter = (notchLeft + notchRight) / 2
        state.menuBarZone = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 24
        // Keep just enough room for one lyric line below the physical notch.
        // This makes the visible drop roughly three-fifths of the old 88pt bar.
        state.barHeight = centered ? max(state.menuBarZone + 24, 56) : 58
        state.gap = gap
        state.leftWingWidth = leftWing
        state.rightCapWidth = rightWing
        state.barWidth = barWidth
    }

    private func expandedWindowLeft() -> CGFloat { notchCenter - Self.expandedWidth / 2 }

    private func targetFrame(expanded: Bool) -> NSRect {
        // Both windows are pinned to the screen top. The expanded window includes
        // a transparent menu-bar strip on top so the menu bar shows through and
        // the hover zone still covers the collapsed bar's location (no flicker).
        let width = expanded ? Self.expandedWidth : barWidth
        let height = expanded ? (state.menuBarZone + Self.cardHeight) : state.barHeight
        let x = expanded ? expandedWindowLeft() : barLeftScreen
        guard let screen = NSScreen.main else {
            return NSRect(x: x, y: 0, width: width, height: height)
        }
        return NSRect(x: x, y: screen.frame.maxY - height, width: width, height: height)
    }

    private func applyFrame(expanded: Bool, animated: Bool) {
        setFrame(targetFrame(expanded: expanded), display: true, animate: animated)
    }

    private func collapsedBarRect() -> CGRect {
        guard let screen = NSScreen.main else { return .zero }
        return CGRect(x: barLeftScreen, y: screen.frame.maxY - state.barHeight,
                      width: barWidth, height: state.barHeight)
    }

    private func startTracking() {
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }
    }

    private var fsTick = 0
    private var hiddenForFullScreen = false

    private func updateHover() {
        // Hide entirely while a full-screen app is frontmost (the menu bar / notch
        // area is gone there, so the island would just float over content).
        fsTick += 1
        if fsTick % 5 == 0 { updateFullScreenVisibility() }
        if hiddenForFullScreen { return }

        if state.pinned {
            if !state.expanded { setExpanded(true) }
            return
        }
        let mouse = NSEvent.mouseLocation
        if state.expanded {
            if !targetFrame(expanded: true).insetBy(dx: -6, dy: -6).contains(mouse) {
                setExpanded(false)
            }
        } else if collapsedBarRect().contains(mouse) {
            setExpanded(true)
        }
    }

    private func updateFullScreenVisibility() {
        let fs = NotchPanel.isFrontmostFullScreen()
        if fs, !hiddenForFullScreen {
            hiddenForFullScreen = true
            if state.expanded { setExpanded(false) }
            orderOut(nil)
        } else if !fs, hiddenForFullScreen {
            hiddenForFullScreen = false
            orderFrontRegardless()
        }
    }

    /// True when a full-screen space is active. The reliable cross-case signal
    /// (Apple green-button full screen AND web/HTML5 video full screen) is that
    /// the system menu bar is hidden — CGWindow bounds are unreliable on notched
    /// displays because full-screen content sits below the notch.
    private static func isFrontmostFullScreen() -> Bool {
        guard let screen = NSScreen.main else { return false }
        // In a full-screen space the menu bar auto-hides, so it no longer
        // reserves space at the top of visibleFrame. On the desktop the menu
        // bar (≈ notch height) is always reserved, giving a positive inset.
        let topInset = screen.frame.maxY - screen.visibleFrame.maxY
        return topInset < 1
    }

    private func setExpanded(_ expanded: Bool) {
        guard state.expanded != expanded else { return }
        state.expanded = expanded
        ignoresMouseEvents = !expanded
        applyFrame(expanded: expanded, animated: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
