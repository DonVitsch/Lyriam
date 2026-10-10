import AppKit
import Combine
import Foundation

struct ShelfItem: Identifiable, Hashable {
    let id: UUID
    let url: URL

    var name: String { url.lastPathComponent }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }

    init(id: UUID = UUID(), url: URL) {
        self.id = id
        self.url = url
    }
}

/// A shelf of file references: original files are never moved, copied, or deleted.
@MainActor
final class FileShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var lastError: String?

    let maximumItems = 24
    private let persistenceURL: URL?

    private struct FileReference: Codable {
        let id: UUID
        let bookmark: Data
    }

    /// Pass nil as persistenceURL to keep the shelf entirely in memory.
    init(persistenceURL: URL? = FileShelfStore.defaultPersistenceURL) {
        self.persistenceURL = persistenceURL
        restoreReferences()
    }

    nonisolated private static var defaultPersistenceURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.local.lyriam", isDirectory: true)
            .appendingPathComponent("file-shelf.json")
    }

    @discardableResult
    func add(_ urls: [URL]) -> Int {
        lastError = nil
        var added = 0
        for url in urls {
            guard let validated = validatedFileURL(url) else {
                lastError = "Only existing local files and folders can be added."
                continue
            }
            guard !items.contains(where: { $0.url == validated }) else { continue }
            guard items.count < maximumItems else {
                lastError = "The shelf can hold up to \(maximumItems) files."
                break
            }
            items.append(ShelfItem(url: validated))
            added += 1
        }
        if added > 0 { saveReferences() }
        return added
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        saveReferences()
    }

    func clear() {
        items.removeAll()
        lastError = nil
        saveReferences()
    }

    @discardableResult
    func open(_ item: ShelfItem) -> Bool {
        guard FileManager.default.fileExists(atPath: item.url.path) else {
            lastError = "This file is no longer at its saved location."
            return false
        }
        let opened = NSWorkspace.shared.open(item.url)
        if !opened { lastError = "This file could not be opened." }
        return opened
    }

    func reveal(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    private func validatedFileURL(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: normalized.path) else { return nil }
        return normalized
    }

    private func restoreReferences() {
        guard let persistenceURL,
              let data = try? Data(contentsOf: persistenceURL),
              let references = try? JSONDecoder().decode([FileReference].self, from: data) else { return }
        for reference in references.prefix(maximumItems) {
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: reference.bookmark,
                                          options: [.withoutUI, .withoutMounting],
                                          relativeTo: nil,
                                          bookmarkDataIsStale: &stale),
                  let url = validatedFileURL(resolved),
                  !items.contains(where: { $0.url == url }) else { continue }
            items.append(ShelfItem(id: reference.id, url: url))
        }
    }

    private func saveReferences() {
        guard let persistenceURL else { return }
        do {
            let references = try items.map { item in
                FileReference(id: item.id,
                              bookmark: try item.url.bookmarkData(options: .minimalBookmark,
                                                                  includingResourceValuesForKeys: nil,
                                                                  relativeTo: nil))
            }
            let data = try JSONEncoder().encode(references)
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            lastError = "The shelf is available for this session, but its file references could not be saved."
        }
    }
}
