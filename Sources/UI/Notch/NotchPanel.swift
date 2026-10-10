import AppKit
import SwiftUI
import Combine

/// Shared island state observed by SwiftUI.
@MainActor
final class IslandState: ObservableObject {
    @Published var expanded = false
    @Published var pinned = false
    @Published var selectedPage: IslandPage = .music
    @Published var isReceivingDrop = false
    @Published var isPresentingFilePicker = false
    /// 0…1 morph progress for the island silhouette.
    @Published var expandProgress: CGFloat = 0
    /// Original calibrated collapsed bar and its internal segments.
    @Published var barWidth: CGFloat = 575
    @Published var leftWingWidth: CGFloat = 330
    @Published var gap: CGFloat = 185
    @Published var rightCapWidth: CGFloat = 60
    @Published var barLeadingInset: CGFloat = 0
    @Published var menuBarZone: CGFloat = 37
    @Published var barHeight: CGFloat = 58
    // Activity layouts share the original bar's dimensions.
    var collapsedWidth: CGFloat { barWidth }
    var collapsedHeight: CGFloat { barHeight }
    var leftWing: CGFloat { leftWingWidth }
    var rightWing: CGFloat { rightCapWidth }
    /// Screen X of camera center.
    @Published var notchCenterX: CGFloat = 0
}

/// The original calibrated bar wraps the notch; its expanded card is centered
/// below a transparent menu-bar band.
///
/// Click-through: when collapsed and not pinned, mouse events are accepted only
/// so hover/click can expand; when expanded the full card is interactive.
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
    private var fullscreenTimer: Timer?
    private var userVisible = true
    private var sessionProtected = false
    private var anchoredDisplayNumber: NSNumber?
    private var fullscreenExitTicks = 0
    private var hoverAccum: TimeInterval = 0
    private var lastTick: Date = .distantPast
    private var cancellables: Set<AnyCancellable> = []
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var windowTransition: IslandWindowTransition?
    private var barWidth: CGFloat = 575
    private var barLeftScreen: CGFloat = 0
    private var notchCenter: CGFloat = 0

    /// Optional callbacks for swipe gestures.
    var onSwipeSkipNext: (() -> Void)?
    var onSwipeSkipPrevious: (() -> Void)?
    var onPresentationChange: (() -> Void)?
    var isPointerOverAccessory: (() -> Bool)?

    /// Accessory cards follow the notch without changing this window's outline.
    var accessoryScreen: NSScreen? { geometryScreen }
    var canPresentAccessories: Bool { userVisible && !hiddenForFullScreen && !sessionProtected && isVisible }
    var accessoryAnchorFrame: NSRect {
        var anchor = targetFrame(expanded: state.expanded)
        anchor.origin.x = notchCenter - anchor.width / 2
        return anchor
    }
    func prepareForAccessoryPresentation() -> Bool {
        updateFullScreenVisibility()
        return canPresentAccessories
    }

    init<Content: View>(@ViewBuilder content: (IslandState) -> Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 575, height: NotchPanel.barHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        appearance = NSAppearance(named: .darkAqua)
        hasShadow = true
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        becomesKeyOnlyIfNeeded = true

        computeGeometry()

        let hosting = NSHostingView(rootView: content(state))
        // Native previews must never resize the calibrated window to their ideal size.
        hosting.sizingOptions = []
        let transition = IslandWindowTransition(hosting: hosting)
        windowTransition = transition
        contentView = transition.container

        applyFrame(expanded: false, animated: false)
        startTracking()
        fullscreenTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFullScreenVisibility() }
        }
        if let fullscreenTimer { RunLoop.main.add(fullscreenTimer, forMode: .common) }
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didWakeNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.updateFullScreenVisibility() }
                .store(in: &cancellables)
        }

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.computeGeometry()
                self.applyFrame(expanded: self.state.expanded, animated: false)
                self.updateFullScreenVisibility()
            }
            .store(in: &cancellables)

        // Tuning / mode changes from settings.
        AppSettings.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // Defer one runloop so published values are committed.
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.computeGeometry()
                    self.applyFrame(expanded: self.state.expanded, animated: true)
                    self.updateFullScreenVisibility()
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        trackingTimer?.invalidate()
        fullscreenTimer?.invalidate()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }

    // MARK: - Geometry

    /// Keep the calibrated island on its original display when focus changes.
    /// Re-anchor only when that display is physically disconnected.
    private var geometryScreen: NSScreen? {
        if let anchoredDisplayNumber,
           let existing = NSScreen.screens.first(where: {
               ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == anchoredDisplayNumber
           }) { return existing }
        guard let replacement = NSScreen.main ?? NSScreen.screens.first else { return nil }
        anchoredDisplayNumber = replacement.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return replacement
    }

    private func computeGeometry() {
        guard let screen = geometryScreen else { return }
        let notchLeft: CGFloat
        let notchRight: CGFloat
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            notchLeft = left.maxX
            notchRight = right.minX
        } else {
            // Original fallback for displays without a physical notch.
            notchLeft = screen.frame.midX - 90
            notchRight = screen.frame.midX + 90
        }
        let gap = notchRight - notchLeft
        let centered = AppSettings.shared.islandMode == .notchCentered
        let leftWing = centered ? Self.centeredLeftWingWidth : Self.leftWingWidth
        let rightWing = centered ? Self.centeredRightWingWidth : Self.rightCapWidth
        barWidth = leftWing + gap + rightWing
        barLeftScreen = notchLeft - leftWing
        notchCenter = (notchLeft + notchRight) / 2
        state.menuBarZone = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 24
        state.barHeight = centered ? max(state.menuBarZone + 24, 56) : 58
        state.gap = gap
        state.leftWingWidth = leftWing
        state.rightCapWidth = rightWing
        state.barWidth = barWidth
        state.notchCenterX = notchCenter
    }

    private func expandedWindowLeft() -> CGFloat { notchCenter - Self.expandedWidth / 2 }

    private func targetFrame(expanded: Bool) -> NSRect {
        let width = expanded ? Self.expandedWidth : barWidth
        let height = expanded ? state.menuBarZone + Self.cardHeight : state.barHeight
        let x = expanded ? expandedWindowLeft() : barLeftScreen
        guard let screen = geometryScreen else {
            return NSRect(x: x, y: 0, width: width, height: height)
        }
        return NSRect(x: x, y: screen.frame.maxY - height, width: width, height: height)
    }

    private func applyFrame(expanded: Bool, animated: Bool) {
        state.barLeadingInset = expanded ? barLeftScreen - expandedWindowLeft() : 0
        let frame = targetFrame(expanded: expanded)
        setFrame(frame, display: true)
        windowTransition?.container.frame = CGRect(origin: .zero, size: frame.size)
        windowTransition?.setFrame(CGRect(origin: .zero, size: frame.size))
        onPresentationChange?()
    }

    // MARK: - Hover / expand

    private func startTracking() {
        lastTick = Date()
        trackingTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }
        if let trackingTimer { RunLoop.main.add(trackingTimer, forMode: .common) }
        // Alcove-style swipe gestures + click-to-expand.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseUp]) { [weak self] event in
            self?.handleLocalEvent(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleScroll(event) }
        }
    }

    private var hiddenForFullScreen = false

    private func updateHover() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now

        if hiddenForFullScreen || sessionProtected || !userVisible { return }
        if state.isReceivingDrop || state.isPresentingFilePicker { return }

        if state.pinned {
            if !state.expanded { setExpanded(true) }
            return
        }

        let mouse = NSEvent.mouseLocation
        let over = targetFrame(expanded: state.expanded).insetBy(dx: -4, dy: -4).contains(mouse)
        let settings = AppSettings.shared

        if state.expanded {
            if !over && !isKeyWindow && isPointerOverAccessory?() != true {
                hoverAccum = 0
                // Collapse only after leaving the card.
                setExpanded(false)
            }
        } else if settings.expandOnHover {
            if over {
                hoverAccum += dt
                if hoverAccum >= settings.hoverDuration {
                    setExpanded(true)
                    hoverAccum = 0
                }
            } else {
                hoverAccum = 0
            }
        } else {
            hoverAccum = 0
        }
    }

    private func handleLocalEvent(_ event: NSEvent) {
        if event.type == .leftMouseUp {
            // Click collapsed island → expand (Alcove default when hover-expand is off).
            MainActor.assumeIsolated {
                guard !state.expanded, !state.pinned else { return }
                let mouse = NSEvent.mouseLocation
                if frame.contains(mouse) {
                    setExpanded(true)
                }
            }
        } else if event.type == .scrollWheel {
            MainActor.assumeIsolated { handleScroll(event) }
        }
    }

    private func handleScroll(_ event: NSEvent) {
        guard !hiddenForFullScreen, !sessionProtected, userVisible, state.selectedPage == .music else { return }
        let settings = AppSettings.shared
        let mouse = NSEvent.mouseLocation
        guard frame.insetBy(dx: -8, dy: -8).contains(mouse) else { return }

        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY

        // Vertical swipe → toggle expand (Alcove swipe-to-toggle).
        if settings.swipeToToggle, abs(dy) > abs(dx), abs(dy) > 3 {
            if dy < -2 { setExpanded(true) }
            else if dy > 2, !state.pinned { setExpanded(false) }
            return
        }

        // Horizontal swipe → skip tracks.
        if settings.swipeToSkip, abs(dx) > abs(dy), abs(dx) > 4 {
            if dx < -3 { onSwipeSkipNext?() }
            else if dx > 3 { onSwipeSkipPrevious?() }
        }
    }

    private func updateFullScreenVisibility() {
        let fullscreen = AppSettings.shared.hideInFullscreen
            && geometryScreen.map { FullscreenDetector.isFullscreen(on: $0) } == true
        if fullscreen {
            fullscreenExitTicks = 0
            if !hiddenForFullScreen {
                hiddenForFullScreen = true
                hoverAccum = 0
                setExpanded(false)
                orderOut(nil)
                onPresentationChange?()
            }
        } else if hiddenForFullScreen {
            // Allow Space-transition windows to settle before restoring the island.
            fullscreenExitTicks += 1
            guard !AppSettings.shared.hideInFullscreen || fullscreenExitTicks >= 2 else { return }
            hiddenForFullScreen = false
            fullscreenExitTicks = 0
            if userVisible && !sessionProtected { super.orderFrontRegardless() }
            onPresentationChange?()
        }
    }

    func showIfAllowed() {
        updateFullScreenVisibility()
        if userVisible && !hiddenForFullScreen && !sessionProtected { super.orderFrontRegardless() }
        onPresentationChange?()
    }

    func toggleVisibility() {
        userVisible.toggle()
        if userVisible { showIfAllowed() }
        else { orderOut(nil) }
        onPresentationChange?()
    }

    func openPage(_ page: IslandPage) {
        guard !sessionProtected else { return }
        userVisible = true
        state.selectedPage = page
        showIfAllowed()
        setExpanded(true)
        if (page == .notes || page == .timer) && !hiddenForFullScreen && userVisible { makeKey() }
        else if isKeyWindow { resignKey() }
    }

    func setSessionProtected(_ protected: Bool) {
        guard sessionProtected != protected else { return }
        sessionProtected = protected
        if protected {
            state.pinned = false
            state.selectedPage = .music
            setExpanded(false)
            orderOut(nil)
            onPresentationChange?()
        } else {
            showIfAllowed()
        }
    }

    func setExpanded(_ expanded: Bool) {
        if expanded && (hiddenForFullScreen || sessionProtected || !userVisible) { return }
        if !expanded && isKeyWindow { resignKey() }
        guard state.expanded != expanded else { return }
        let source = frame
        let target = targetFrame(expanded: expanded)
        let update = {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                self.state.expanded = expanded
                self.state.expandProgress = expanded ? 1 : 0
                // Each snapshot uses its own endpoint coordinates.
                self.state.barLeadingInset = 0
            }
        }
        if isVisible, let windowTransition, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            windowTransition.animate(in: self, canvas: targetFrame(expanded: true).union(source),
                                     source: source, target: target, update: update) { [weak self] in
                self?.applyFrame(expanded: expanded, animated: false)
            }
            onPresentationChange?()
        } else {
            update()
            applyFrame(expanded: expanded, animated: false)
        }
    }

    func toggleExpanded() {
        if state.expanded { setExpanded(false) }
        else { openPage(state.selectedPage) }
    }

    override var canBecomeKey: Bool { state.expanded }
    override var canBecomeMain: Bool { false }
}

// Helper so AppKit code can drive a simple animation flag without importing
// SwiftUI animation APIs incorrectly from a non-View context.
@MainActor
private func withAnimation(_ animation: Animation, _ body: () -> Void) {
    SwiftUI.withAnimation(animation, body)
}
