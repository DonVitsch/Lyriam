import AppKit
import Combine
import CryptoKit
import Foundation
import ImageIO

struct ClipboardImage {
    /// Preserve the original representation so copying a thumbnail never reduces image quality.
    let data: Data
    let pasteboardType: NSPasteboard.PasteboardType
    let thumbnail: NSImage
    let pixelWidth: Int
    let pixelHeight: Int
    let digest: String
    let memoryBytes: Int

    var dimensions: String { "\(pixelWidth) × \(pixelHeight)" }
}

struct ClipboardEntry: Identifiable {
    let id: UUID
    let text: String
    let image: ClipboardImage?
    let copiedAt: Date
    let sourceApp: String?
    var isPinned: Bool

    init(id: UUID = UUID(), text: String, copiedAt: Date = Date(), sourceApp: String? = nil, isPinned: Bool = false) {
        self.id = id
        self.text = text
        self.image = nil
        self.copiedAt = copiedAt
        self.sourceApp = sourceApp
        self.isPinned = isPinned
    }

    init(image: ClipboardImage, sourceApp: String?) {
        self.id = UUID()
        self.text = ""
        self.image = image
        self.copiedAt = Date()
        self.sourceApp = sourceApp
        self.isPinned = false
    }

    var searchText: String {
        [text, sourceApp ?? "", image.map { "Image 图片 照片 Screenshot 截图 \($0.dimensions)" } ?? ""].joined(separator: " ")
    }
    var memoryBytes: Int { image?.memoryBytes ?? text.utf8.count }
}

/// Text and images remain in memory and are discarded when Lyriam quits.
@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipboardEntry] = []
    @Published private(set) var captureNotice: String?
    @Published var enabled: Bool = true {
        didSet {
            // Resume from the current change count, without capturing anything copied while paused.
            lastChangeCount = pasteboard.changeCount
        }
    }

    let maximumUnpinnedItems = 20
    let maximumPinnedItems = 20
    let maximumHistoryBytes = 64 * 1_048_576
    let maximumImageBytes = 20 * 1_048_576
    private let maximumTextBytes = 1_048_576
    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastChangeCount: Int

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        // Existing clipboard content is never imported just because the app started.
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.captureChange() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @discardableResult
    func copy(_ entry: ClipboardEntry) -> Bool {
        pasteboard.clearContents()
        let written: Bool
        if let image = entry.image {
            written = pasteboard.setData(image.data, forType: image.pasteboardType)
        } else {
            written = pasteboard.setString(entry.text, forType: .string)
        }
        // Do not record Lyriam's own clipboard writes on the next polling tick.
        lastChangeCount = pasteboard.changeCount
        return written
    }

    @discardableResult
    func togglePinned(_ entry: ClipboardEntry) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == entry.id }) else { return false }
        if !items[index].isPinned && items.filter({ $0.isPinned }).count >= maximumPinnedItems { return false }
        items[index].isPinned.toggle()
        trimHistory()
        return true
    }

    func delete(_ entry: ClipboardEntry) { items.removeAll { $0.id == entry.id } }
    func clearUnpinned() { items.removeAll { !$0.isPinned }; captureNotice = nil }
    func clear() { items.removeAll(); captureNotice = nil }

    func captureChange() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        guard enabled else { return }

        let types = pasteboard.types ?? []
        guard !types.contains(.fileURL), !containsSensitiveType(types) else { return }
        captureNotice = nil
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        let imageTypes = [NSPasteboard.PasteboardType.png, .tiff].filter { types.contains($0) }
        if !imageTypes.isEmpty {
            for type in imageTypes {
                guard let data = pasteboard.data(forType: type) else { continue }
                guard data.count <= maximumImageBytes else {
                    captureNotice = "这张图片超过 20 MB，未加入历史。"
                    continue
                }
                guard let image = Self.makeImage(data: data, type: type) else {
                    captureNotice = "这张图片无法预览，或尺寸超过支持范围。"
                    continue
                }
                // A second representation may be present on the same pasteboard; store just one.
                guard !items.contains(where: { $0.image?.digest == image.digest }) else { return }
                captureNotice = nil
                insert(ClipboardEntry(image: image, sourceApp: sourceApp))
                return
            }
            return
        }

        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= maximumTextBytes,
              !items.contains(where: { $0.image == nil && $0.text == text }) else { return }
        insert(ClipboardEntry(text: text, sourceApp: sourceApp))
    }

    private static func makeImage(data: Data, type: NSPasteboard.PasteboardType) -> ClipboardImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              width * height <= 64_000_000 else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 384,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
        let thumbnail = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return ClipboardImage(data: data, pasteboardType: type, thumbnail: thumbnail,
                              pixelWidth: width, pixelHeight: height,
                              digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                              memoryBytes: data.count + cgImage.bytesPerRow * cgImage.height)
    }

    private func insert(_ entry: ClipboardEntry) {
        // Pinned items are never silently discarded to make space for a new capture.
        let pinnedBytes = items.filter(\.isPinned).reduce(0) { $0 + $1.memoryBytes }
        guard pinnedBytes + entry.memoryBytes <= maximumHistoryBytes else {
            captureNotice = "剪贴板内存已满，请取消固定或移除部分图片。"
            return
        }
        items.insert(entry, at: 0)
        trimHistory()
    }

    private func containsSensitiveType(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        types.contains { type in
            let value = type.rawValue.lowercased()
            return value == "org.nspasteboard.transienttype"
                || value == "org.nspasteboard.concealedtype"
                || value == "org.nspasteboard.autogeneratedtype"
                || value.contains("onepassword")
                || value.contains("1password")
                || value.contains("agilebits")
                || value.contains("concealed")
                || value.contains("password")
                || value.contains("credential")
                || value.contains("secret")
        }
    }

    private func trimHistory() {
        var unpinnedCount = 0
        var bytes = items.filter(\.isPinned).reduce(0) { $0 + $1.memoryBytes }
        items = items.filter { entry in
            if entry.isPinned { return true }
            unpinnedCount += 1
            guard unpinnedCount <= maximumUnpinnedItems,
                  bytes + entry.memoryBytes <= maximumHistoryBytes else { return false }
            bytes += entry.memoryBytes
            return true
        }
    }

    deinit { timer?.invalidate() }
}
