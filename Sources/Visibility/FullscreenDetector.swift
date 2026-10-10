import AppKit
import CoreGraphics
import ApplicationServices

/// Window geometry works for native fullscreen Spaces and borderless video players.
/// Reading bounds does not request Screen Recording or Accessibility access.
enum FullscreenDetector {
    static func isFullscreen(on screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }

        let displayBounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? NSNumber,
                  owner.int32Value != ProcessInfo.processInfo.processIdentifier,
                  window[kCGWindowOwnerName as String] as? String != "Finder",
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary) else { continue }
            if coversDisplay(bounds, displayBounds: displayBounds, safeAreaTop: screen.safeAreaInsets.top) {
                return true
            }
        }
        // If the user has already granted Accessibility, use the explicit flag as
        // an additional signal. Never trigger a permissions prompt for hiding.
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.1)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let axWindow = unsafeBitCast(focused, to: AXUIElement.self)
        var flag: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, "AXFullScreen" as CFString, &flag) == .success,
              (flag as? NSNumber)?.boolValue == true else { return false }
        // Attribute alone is insufficient with another display in fullscreen.
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return false }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return false }
        let intersection = CGRect(origin: origin, size: dimensions).intersection(displayBounds)
        return !intersection.isNull && intersection.width >= displayBounds.width * 0.8
            && intersection.height >= displayBounds.height * 0.8
    }

    static func coversDisplay(_ bounds: CGRect, displayBounds: CGRect, safeAreaTop: CGFloat) -> Bool {
        let tolerance: CGFloat = 3
        guard bounds.width > 0, bounds.height > 0, !displayBounds.isEmpty else { return false }
        // On notched Macs native fullscreen content can start below the camera.
        // A maximized desktop window still stops above the Dock / screen bottom.
        return abs(bounds.minX - displayBounds.minX) <= tolerance
            && abs(bounds.maxX - displayBounds.maxX) <= tolerance
            && bounds.minY >= displayBounds.minY - tolerance
            && bounds.minY <= displayBounds.minY + max(0, safeAreaTop) + tolerance
            && abs(bounds.maxY - displayBounds.maxY) <= tolerance
    }
}
