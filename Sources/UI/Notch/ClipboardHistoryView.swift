import AppKit
import SwiftUI

struct ClipboardHistoryView: View {
    @ObservedObject var store: ClipboardStore
    @State private var copiedID: UUID?
    @State private var previewID: UUID?
    @State private var notice: String?

    private var entries: [ClipboardEntry] {
        store.items.sorted { $0.isPinned != $1.isPinned ? $0.isPinned : $0.copiedAt > $1.copiedAt }
    }
    private var previewEntry: ClipboardEntry? {
        entries.first { $0.id == previewID && $0.image != nil }
    }

    var body: some View {
        VStack(spacing: 8) {
            historyActions
            if entries.isEmpty {
                IslandEmptyView(symbol: "doc.on.clipboard", title: "复制文字或图片，就会出现在这里",
                                detail: store.enabled ? "支持 PNG、TIFF 图片 · 历史仅保留在本次运行中" : "记录已暂停，点击“继续”开启")
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(entries) { entry in clipboardRow(entry) }
                        }
                    }.scrollIndicators(.hidden)
                    if let entry = previewEntry, let image = entry.image {
                        imagePreview(entry, image: image)
                            .frame(width: 230)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            if let message = notice ?? store.captureNotice {
                Text(message).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .onExitCommand {
            if previewID != nil { previewID = nil }
            else { NotificationCenter.default.post(name: .lyriamCollapseIsland, object: nil) }
        }
    }

    private var historyActions: some View {
        HStack(spacing: 8) {
            Text("\(store.items.count) 条内容").font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.6))
            Spacer()
            Button(store.enabled ? "暂停" : "继续") { store.enabled.toggle() }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.white.opacity(0.75))
            Button { store.clearUnpinned() } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6)).help("清空未固定的历史")
        }
        .padding(.horizontal, 2).padding(.vertical, 2)
    }

    private func clipboardRow(_ entry: ClipboardEntry) -> some View {
        HStack(spacing: 8) {
            Button { copy(entry) } label: {
                HStack(alignment: .center, spacing: 9) {
                    if let image = entry.image {
                        Image(nsImage: image.thumbnail).resizable().scaledToFit()
                            .frame(width: 62, height: 44)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .accessibilityLabel("图片缩略图")
                    } else {
                        Image(systemName: copiedID == entry.id ? "checkmark" : "text.alignleft")
                            .foregroundStyle(copiedID == entry.id ? Color.mint : .white.opacity(0.65)).frame(width: 16)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.image.map { "图片 · \($0.dimensions)" } ?? entry.text)
                            .font(.system(size: 12)).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(copiedID == entry.id ? "已复制" : entry.sourceApp ?? (entry.image == nil ? "文本" : "图片"))
                            .font(.system(size: 9)).foregroundStyle(copiedID == entry.id ? Color.mint : .white.opacity(0.6))
                    }
                }
                .contentShape(Rectangle())
            }.buttonStyle(.plain).help(entry.image == nil ? "复制文本" : "复制原始图片")
            if entry.image != nil {
                Button { previewID = previewID == entry.id ? nil : entry.id } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain).foregroundStyle(previewID == entry.id ? Color.white : .white.opacity(0.65))
                .help("预览图片").accessibilityLabel("预览图片")
            }
            Button {
                if !store.togglePinned(entry) { notice = "最多可以固定 20 条内容。" }
            } label: { Image(systemName: entry.isPinned ? "pin.fill" : "pin") }
                .buttonStyle(.plain).foregroundStyle(entry.isPinned ? Color.yellow : .white.opacity(0.6))
                .help(entry.isPinned ? "取消固定" : "固定到顶部")
            Button { store.delete(entry) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6)).help("移除这条记录")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.white.opacity(previewID == entry.id ? 0.10 : 0.055), in: RoundedRectangle(cornerRadius: 10))
    }

    private func imagePreview(_ entry: ClipboardEntry, image: ClipboardImage) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(image.dimensions).font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button { previewID = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6)).help("关闭预览")
            }
            Image(nsImage: image.thumbnail).resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("图片预览")
            Button { copy(entry) } label: {
                Label(copiedID == entry.id ? "已复制图片" : "复制原始图片", systemImage: copiedID == entry.id ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).foregroundStyle(copiedID == entry.id ? .mint : .white)
        }
        .padding(9).frame(maxHeight: .infinity)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }

    private func copy(_ entry: ClipboardEntry) {
        if store.copy(entry) { copiedID = entry.id; notice = nil }
        else { notice = "复制失败，请重试。" }
    }
}
