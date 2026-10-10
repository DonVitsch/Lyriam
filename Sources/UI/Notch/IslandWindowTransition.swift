import AppKit
import QuartzCore

/// Size the real SwiftUI content once, then let Core Animation composite the
/// transition. Window resizing no longer performs a full SwiftUI layout each frame.
@MainActor
final class IslandWindowTransition {
    let container = NSView()
    private var hosting: NSView
    private var layers: [CALayer] = []
    private var completion: DispatchWorkItem?
    private var generation = 0

    init(hosting: NSView) {
        self.hosting = hosting
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(hosting)
        hosting.autoresizingMask = []
    }

    func setFrame(_ frame: CGRect) {
        cancel()
        hosting.alphaValue = 1
        hosting.frame = frame
    }

    func animate(in window: NSWindow, canvas: CGRect, source: CGRect, target: CGRect,
                 update: () -> Void, finish: @escaping () -> Void) {
        let oldImage: CGImage?
        let oldFrame: CGRect
        if !layers.isEmpty {
            oldImage = compositeSnapshot()
            oldFrame = CGRect(origin: .zero, size: container.bounds.size)
        } else {
            oldImage = snapshot()
            oldFrame = CGRect(origin: .zero, size: source.size)
        }
        let previousWindow = window.frame
        cancel()
        generation += 1
        let token = generation
        window.setFrame(canvas, display: false)
        container.frame = CGRect(origin: .zero, size: canvas.size)
        let sourceInCanvas = oldFrame.offsetBy(dx: previousWindow.minX - canvas.minX,
                                              dy: previousWindow.minY - canvas.minY)
        let targetInCanvas = CGRect(x: target.minX - canvas.minX, y: target.minY - canvas.minY,
                                   width: target.width, height: target.height)
        if let oldImage {
            let old = imageLayer(oldImage, frame: sourceInCanvas)
            container.layer?.addSublayer(old)
            layers = [old]
        }
        hosting.alphaValue = 0
        hosting.frame = targetInCanvas
        update()
        // Commit the new SwiftUI endpoint layout underneath the old snapshot.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token else { return }
            self.hosting.alphaValue = 1
            self.hosting.layoutSubtreeIfNeeded()
            let newImage = self.snapshot()
            self.hosting.alphaValue = 0
            let duration: CFTimeInterval = 0.3
            if let newImage {
                let new = self.imageLayer(newImage, frame: targetInCanvas)
                new.opacity = 1
                self.container.layer?.addSublayer(new)
                self.layers.append(new)
                self.move(new, from: sourceInCanvas, to: targetInCanvas, duration: duration)
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.22
                new.add(fade, forKey: "fade")
            }
            if let old = self.layers.first, self.layers.count > 1 {
                self.move(old, from: sourceInCanvas, to: targetInCanvas, duration: duration)
                old.opacity = 0
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.18
                old.add(fade, forKey: "fade")
            }
            let done = DispatchWorkItem { [weak self] in
                guard let self, self.generation == token else { return }
                self.layers.forEach { $0.removeFromSuperlayer() }
                self.layers.removeAll()
                self.hosting.alphaValue = 1
                self.completion = nil
                finish()
            }
            self.completion = done
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: done)
        }
    }

    private func cancel() {
        generation += 1
        completion?.cancel()
        completion = nil
        layers.forEach { $0.removeFromSuperlayer() }
        layers.removeAll()
    }

    private func snapshot() -> CGImage? {
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap.cgImage
    }

    private func compositeSnapshot() -> CGImage? {
        let scale = container.window?.backingScaleFactor ?? 2
        let size = container.bounds.size
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        for layer in layers {
            let visible = layer.presentation() ?? layer
            guard let contents = visible.contents else { continue }
            let image = contents as! CGImage
            context.setAlpha(CGFloat(visible.opacity))
            context.draw(image, in: visible.frame)
        }
        return context.makeImage()
    }

    private func imageLayer(_ image: CGImage, frame: CGRect) -> CALayer {
        let layer = CALayer()
        layer.contents = image
        layer.contentsScale = container.window?.backingScaleFactor ?? 2
        layer.contentsGravity = .resize
        layer.frame = frame
        return layer
    }

    private func move(_ layer: CALayer, from: CGRect, to: CGRect, duration: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = to
        CATransaction.commit()
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = CGPoint(x: from.midX, y: from.midY)
        position.toValue = CGPoint(x: to.midX, y: to.midY)
        let bounds = CABasicAnimation(keyPath: "bounds")
        bounds.fromValue = CGRect(origin: .zero, size: from.size)
        bounds.toValue = CGRect(origin: .zero, size: to.size)
        let group = CAAnimationGroup()
        group.animations = [position, bounds]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.2, 1)
        layer.add(group, forKey: "size")
    }
}
