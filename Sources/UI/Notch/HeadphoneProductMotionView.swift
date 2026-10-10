import AppKit
import AVFoundation
import SwiftUI

extension HeadphoneDevice {
    var animationFamily: String {
        switch productID {
        case 0x2013: return "AirPods_3"
        case 0x2019, 0x201B, 0x2030, 0x2032, 0x2036, 0x2037: return "AirPods_4"
        case 0x200E: return "AirPods_Pro"
        case 0x2014, 0x2024: return "AirPods_Pro_2"
        case 0x2027: return "AirPods_Pro_3"
        case 0x200A, 0x201F, 0x202D: return "AirPods_Max"
        default:
            if symbol == "airpodspro" { return "AirPods_Pro_2" }
            if symbol == "airpodsmax" { return "AirPods_Max" }
            return "AirPods_1"
        }
    }
}

enum HeadphoneAnimationAssets {
    static func url(_ family: String, part: String, ext: String) -> URL? {
        Bundle.main.url(forResource: "\(family)-\(part)", withExtension: ext, subdirectory: "Headphones")
    }
    static func image(_ family: String, part: String) -> NSImage? {
        url(family, part: part, ext: "png").flatMap { NSImage(contentsOf: $0) }
    }
}

struct HeadphoneProductMotionView: View {
    let device: HeadphoneDevice
    var playing = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if device.isAirPods, let image = HeadphoneAnimationAssets.image(device.animationFamily, part: "buds") {
                if playing && !reduceMotion,
                   let url = HeadphoneAnimationAssets.url(device.animationFamily, part: "buds", ext: "mov") {
                    HeadphoneAnimationPlayer(url: url, poster: image)
                } else {
                    Image(nsImage: image).resizable().scaledToFit()
                }
            } else {
                Image(systemName: device.symbol)
                    .font(.system(size: 90, weight: .light)).foregroundStyle(Color(white: 0.3))
            }
        }.accessibilityHidden(true)
    }
}

private struct HeadphoneAnimationPlayer: NSViewRepresentable {
    let url: URL
    let poster: NSImage
    func makeNSView(context: Context) -> HeadphonePlayerView { HeadphonePlayerView(url: url, poster: poster) }
    func updateNSView(_ view: HeadphonePlayerView, context: Context) { view.load(url) }
    static func dismantleNSView(_ view: HeadphonePlayerView, coordinator: ()) { view.stop() }
}

private final class HeadphonePlayerView: NSView {
    private let player = AVQueuePlayer()
    private let playerLayer = AVPlayerLayer()
    private let posterLayer = CALayer()
    private var readiness: NSKeyValueObservation?
    private var looper: AVPlayerLooper?
    private var source: URL?

    init(url: URL, poster: NSImage) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        posterLayer.contents = poster.cgImage(forProposedRect: nil, context: nil, hints: nil)
        posterLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(posterLayer)
        layer?.addSublayer(playerLayer)
        player.isMuted = true
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        readiness = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] playerLayer, _ in
            DispatchQueue.main.async {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                self?.posterLayer.isHidden = playerLayer.isReadyForDisplay
                CATransaction.commit()
            }
        }
        load(url)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        posterLayer.frame = bounds
        CATransaction.commit()
    }
    func load(_ url: URL) {
        guard source != url else { return }
        stop()
        posterLayer.isHidden = false
        source = url
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 1
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.play()
    }
    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        source = nil
    }
}
