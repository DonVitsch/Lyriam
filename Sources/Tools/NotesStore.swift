import Combine
import Foundation

struct QuickTodo: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var text: String
    var isComplete = false
}

/// Plain notes and to-dos stay on this Mac. A failed load never overwrites the original file.
@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var note = ""
    @Published private(set) var todos: [QuickTodo] = []
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var lastError: String?
    @Published private(set) var deletedTodo: QuickTodo?
    var canRetrySaving: Bool { !protectedUnreadableFile }

    private let persistenceURL: URL?
    private var saveTask: Task<Void, Never>?
    private var protectedUnreadableFile = false
    private var deletedIndex: Int?

    private struct Snapshot: Codable {
        var note: String
        var todos: [QuickTodo]
    }

    init(persistenceURL: URL? = NotesStore.defaultPersistenceURL) {
        self.persistenceURL = persistenceURL
        restore()
    }

    nonisolated private static var defaultPersistenceURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.local.lyriam", isDirectory: true)
            .appendingPathComponent("quick-notes.json")
    }

    func updateNote(_ text: String) {
        guard text != note else { return }
        note = text
        scheduleSave()
    }

    @discardableResult
    func addTodo(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        todos.append(QuickTodo(text: trimmed))
        scheduleSave()
        return true
    }

    func toggleTodo(_ todo: QuickTodo) {
        guard let index = todos.firstIndex(where: { $0.id == todo.id }) else { return }
        todos[index].isComplete.toggle()
        scheduleSave()
    }

    func deleteTodo(_ todo: QuickTodo) {
        guard let index = todos.firstIndex(where: { $0.id == todo.id }) else { return }
        deletedTodo = todos.remove(at: index)
        deletedIndex = index
        scheduleSave()
    }

    func undoDelete() {
        guard let deletedTodo, let deletedIndex else { return }
        todos.insert(deletedTodo, at: min(deletedIndex, todos.count))
        self.deletedTodo = nil
        self.deletedIndex = nil
        scheduleSave()
    }

    func stop() { flush() }

    /// Used on app termination and by Retry. Atomic writes keep the last saved note intact.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard hasUnsavedChanges, !protectedUnreadableFile else { return }
        guard let persistenceURL else { hasUnsavedChanges = false; return }
        do {
            let data = try JSONEncoder().encode(Snapshot(note: note, todos: todos))
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: persistenceURL, options: .atomic)
            hasUnsavedChanges = false
            lastError = nil
        } catch {
            lastError = "未能保存，内容仍在此窗口中。请重试。"
        }
    }

    private func scheduleSave() {
        hasUnsavedChanges = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 450_000_000) }
            catch { return }
            self?.flush()
        }
    }

    private func restore() {
        guard let persistenceURL, FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: persistenceURL))
            note = snapshot.note
            // Defend SwiftUI's identity requirements while retaining each piece of text.
            var seen = Set<UUID>()
            todos = snapshot.todos.map { todo in
                var item = todo
                if seen.contains(item.id) { item.id = UUID() }
                seen.insert(item.id)
                return item
            }
        } catch {
            protectedUnreadableFile = true
            lastError = "原有便签暂时无法读取，已保留原文件；新内容仅保留在本次运行中。"
        }
    }
}
