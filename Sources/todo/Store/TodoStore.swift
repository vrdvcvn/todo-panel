import Foundation

/// Persistence for the todo list.
///
/// Writes a plain JSON array to
/// `~/Library/Application Support/todo/todos.json`.
///
/// Design notes:
/// - Written after every mutation, atomically. The dataset is a handful of
///   short strings, so there is nothing to gain from debouncing and a lot to
///   lose: if the app is force-quit the list is never out of date.
/// - A corrupt or unreadable file is moved aside rather than deleted, so a
///   hand-edited or half-written file can never silently destroy your list.
@MainActor
final class TodoStore: ObservableObject {
    @Published private(set) var items: [TodoItem] = []
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var undoStack: [[TodoItem]] = []
    private var redoStack: [[TodoItem]] = []
    private let historyLimit = 100

    private let fileURL: URL

    init(fileURL: URL = TodoStore.defaultURL()) {
        self.fileURL = fileURL
    }

    // MARK: - Locations

    nonisolated static func directoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("todo", isDirectory: true)
    }

    nonisolated static func defaultURL() -> URL {
        directoryURL().appendingPathComponent("todos.json")
    }

    /// Open items first, then completed — and both groups newest first, so the
    /// thing you just touched is the one you can see.
    ///
    /// "Newest" is per group: an open task by when you wrote it, a finished one
    /// by when you ticked it.
    ///
    /// The tie-break matters. Ticking several at once gives them all the same
    /// `completedAt`, and a comparator with nothing to separate them leaves the
    /// order down to the sort's internals — so ⌘A then Space would file the
    /// tasks into the finished group in an arbitrary order and they would appear
    /// to jump around. Falling back to `createdAt` keeps a batch exactly where
    /// it already was, which is what "they got checked, just not in order" is
    /// really describing.
    ///
    /// This is a flat, un-nested list: sub-tasks sit next to their parent and
    /// `visibleRows` is what groups them for display.
    var visibleItems: [TodoItem] {
        items.sorted(by: Self.newestFirst)
    }

    /// Oldest first, for sub-tasks.
    ///
    /// Deliberately the opposite of the top level. A sub-task list is a list you
    /// write down in order — "buy bananas, then bread" — and sorting it
    /// newest-first turned a shopping list upside down, so the item you just
    /// added jumped above the ones before it.
    private static func oldestFirst(_ lhs: TodoItem, _ rhs: TodoItem) -> Bool {
        if lhs.done != rhs.done { return !lhs.done }
        if lhs.done {
            let left = lhs.completedAt ?? lhs.createdAt
            let right = rhs.completedAt ?? rhs.createdAt
            if left != right { return left < right }
        }
        return lhs.createdAt < rhs.createdAt
    }

    /// Open before done, then newest first, with `createdAt` breaking ties so
    /// a batch ticked in one go keeps the order it was already in.
    private static func newestFirst(_ lhs: TodoItem, _ rhs: TodoItem) -> Bool {
        if lhs.done != rhs.done { return !lhs.done }
        if lhs.done {
            let left = lhs.completedAt ?? lhs.createdAt
            let right = rhs.completedAt ?? rhs.createdAt
            if left != right { return left > right }
        }
        return lhs.createdAt > rhs.createdAt
    }

    var openCount: Int {
        items.reduce(0) { $0 + ($1.done ? 0 : 1) }
    }

    // MARK: - Nesting

    /// How deep a sub-task may go.
    ///
    /// Two levels: a task and its sub-tasks. Three was tried and dropped —
    /// with Shift+Enter appending into whatever is highlighted, a third level
    /// is one more thing to think about while writing, and one more indent
    /// eating the width a long title has to wrap into.
    static let maxDepth = 1

    /// A task together with the sub-tasks currently on screen beneath it.
    ///
    /// The tree is rebuilt from the flat list on every read rather than kept
    /// beside it. For a list of tens of items that costs nothing, and it means
    /// the two can never disagree — there is no second copy to go stale after a
    /// delete, a re-sort or an undo.
    struct Branch: Identifiable {
        let item: TodoItem
        let children: [Branch]
        /// 0 for a top-level task, 1 for its sub-tasks, and so on.
        let depth: Int

        var id: UUID { item.id }
    }

    /// The whole list as a tree.
    var branches: [Branch] {
        var childrenOf: [UUID: [TodoItem]] = [:]
        var topLevel: [TodoItem] = []

        // How far each item sits below the top, so that anything past the depth
        // limit can be lifted rather than hidden.
        func depthOf(_ item: TodoItem) -> Int? {
            var depth = 0
            var current = item
            var budget = items.count + 1
            while let parentID = current.parentID {
                budget -= 1
                guard budget > 0, let parent = items.first(where: { $0.id == parentID }) else {
                    return nil // dangling, or a cycle in a hand-edited file
                }
                depth += 1
                current = parent
            }
            return depth
        }

        for item in items {
            // Promoted to the top when its parent is missing, or when it sits
            // below the depth limit left over from a list written when there
            // were three levels. Losing a task to a dangling pointer — or to a
            // limit that has since moved — is worse than showing it at the
            // wrong level.
            guard let parentID = item.parentID,
                  let depth = depthOf(item),
                  depth <= Self.maxDepth,
                  items.contains(where: { $0.id == parentID })
            else {
                topLevel.append(item)
                continue
            }
            childrenOf[parentID, default: []].append(item)
        }

        func build(_ item: TodoItem, depth: Int) -> Branch {
            // At the depth limit a branch has no children to show, and must not
            // be treated as collapsible.
            let kids: [Branch] = depth < Self.maxDepth
                ? (childrenOf[item.id] ?? [])
                    .sorted(by: Self.oldestFirst)
                    .map { build($0, depth: depth + 1) }
                : []
            return Branch(item: item, children: kids, depth: depth)
        }

        return topLevel.sorted(by: Self.newestFirst).map { build($0, depth: 0) }
    }

    /// The branches as a flat list, for the arrow keys and the rows on screen.
    ///
    /// A closed task contributes itself and nothing else, so navigating never
    /// lands the caret on a row that is not there.
    var visibleRows: [Branch] {
        var rows: [Branch] = []
        func walk(_ branch: Branch) {
            rows.append(branch)
            if branch.item.expanded {
                branch.children.forEach(walk)
            }
        }
        branches.forEach(walk)
        return rows
    }

    /// Whether a task has any sub-tasks at all, open or closed.
    func hasChildren(_ id: UUID) -> Bool {
        items.contains { $0.parentID == id }
    }

    /// Adds a sub-task under `parentID`, refusing past the depth limit.
    @discardableResult
    func addSubtask(_ title: String, under parentID: UUID) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let parent = items.first(where: { $0.id == parentID }) else { return false }
        guard Self.depth(of: parent, in: items) < Self.maxDepth else { return false }

        perform {
            items.append(TodoItem(title: trimmed, parentID: parentID))
            // Adding under a closed task would look like nothing happened, so
            // open it. Both in one history entry, or undo would leave the
            // sub-task behind with its parent shut.
            if let index = items.firstIndex(where: { $0.id == parentID }) {
                items[index].expanded = true
            }
        }
        return true
    }

    /// Opens or closes a task's sub-tasks.
    ///
    /// A task that was never opened becomes "closed" the first time Tab
    /// closes it, which is the same thing as never having been opened again —
    /// so closing one and leaving it is indistinguishable from not having
    /// touched it, and the list goes back to looking flat.
    func setExpanded(_ expanded: Bool, id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].expanded != expanded else { return }
        perform { items[index].expanded = expanded }
    }

    /// How far below the top a task sits.
    private static func depth(of item: TodoItem, in items: [TodoItem]) -> Int {
        var depth = 0
        var current = item
        // Bounded by the item count: a hand-edited file can hold a cycle (a
        // parented to b, b to a) and this has to terminate rather than hang.
        var budget = items.count
        while let parentID = current.parentID, budget > 0 {
            budget -= 1
            guard let parent = items.first(where: { $0.id == parentID }) else { break }
            depth += 1
            current = parent
        }
        return depth
    }

    /// Tab's whole job: open a task's sub-tasks, or close them again.
    ///
    /// It also used to *create* a sub-task when the task had none, which made one
    /// key do two unrelated things, and the only way to tell which had happened
    /// was to look at the screen. Creating is Shift+Return's job, so this is a
    /// single verb.
    ///
    /// Returns the new state, so the caller can drop a blank row when the branch
    /// closes. One history entry, so undo takes a toggle back in one press.
    @discardableResult
    func toggleExpanded(id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        let now = !items[index].expanded
        perform { items[index].expanded = now }
        return now
    }

    /// Where a new sub-task would go for a given task.
    ///
    /// Under the task itself when it is top level, and under its parent when it
    /// is already a sub-task — so adding from a sub-task adds a *sibling*.
    /// Nesting stops at two levels, so a sub-task cannot take one of its own.
    ///
    /// This lived in the view, where no test could reach it, and returned nil
    /// for a sub-task. Every caller then treated that as "nothing to do" and
    /// fell back to the top prompt, so the shortcut silently did nothing on
    /// exactly the rows where it should have been most obvious.
    func parentForNewSubtask(of id: UUID) -> UUID? {
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        return item.parentID ?? item.id
    }

    /// The parent a blank sub-task row belongs to, or `nil` if the id is a
    /// real task. The inverse of `draftRowID`, and needs the same test.
    func parentOfDraftRow(_ id: UUID) -> UUID? {
        items.first { $0.id.draftRowID == id }?.id
    }

    /// A task plus every sub-task beneath it, at any depth.
    func subTree(of id: UUID) -> Set<UUID> {
        var found: Set<UUID> = [id]
        var grew = true
        while grew {
            grew = false
            for item in items {
                guard let parentID = item.parentID,
                      found.contains(parentID),
                      !found.contains(item.id) else { continue }
                found.insert(item.id)
                grew = true
            }
        }
        return found
    }

    // MARK: - History

    /// Undo works by snapshotting the whole list rather than by recording an
    /// inverse for each operation. The list is a handful of short strings, so
    /// the memory is nothing, and it means every operation is undoable by
    /// construction — including combinations and multi-task edits — instead of
    /// only the ones someone remembered to write an inverse for.
    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(items)
        items = previous
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        persist()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(items)
        items = next
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        persist()
    }

    private func perform(_ change: () -> Void) {
        undoStack.append(items)
        if undoStack.count > historyLimit {
            undoStack.removeFirst(undoStack.count - historyLimit)
        }
        redoStack.removeAll()
        change()
        canUndo = true
        canRedo = false
        persist()
    }

    // MARK: - Mutations

    /// Adds a top-level task and hands back its id.
    @discardableResult
    func add(_ title: String) -> UUID? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = TodoItem(title: trimmed)
        perform { items.append(item) }
        return item.id
    }

    /// Adds a top-level task already open, so the caret can go straight into a
    /// sub-task row under it.
    ///
    /// Open *and* added, or add and then open, are both deliberate. Doing it in
    /// two steps would put two entries in the undo history, so one ⌘Z would
    /// close the task and leave it sitting there, and the second would be
    /// needed to remove it — which is exactly the kind of thing a task undo has
    /// to be immune to. One `perform`, one press, gone.
    @discardableResult
    func addAndOpen(_ title: String) -> UUID? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = TodoItem(title: trimmed, expanded: true)
        perform { items.append(item) }
        return item.id
    }

    func toggle(id: UUID) {
        toggle(ids: [id])
    }

    /// Ticks every given task. `true` marks them all done, `false` un-marks
    /// them — decided by the first one, so a mixed selection moves together.
    func toggle(ids: [UUID]) {
        let wanted = ids.compactMap { id in items.first(where: { $0.id == id })?.done }
        guard !wanted.isEmpty else { return }
        let target = !wanted[0]
        let stamp = Date()
        perform {
            for index in items.indices where ids.contains(items[index].id) {
                items[index].done = target
                items[index].completedAt = target ? stamp : nil
            }
        }
    }

    func delete(id: UUID) {
        delete(ids: [id])
    }

    /// One history entry for the whole batch, so undo brings back everything
    /// that was deleted at once rather than one task per press.
    ///
    /// Deleting a task also deletes everything under it. Leaving the children
    /// behind would strand them at the top of the list with no way to tell what
    /// they belonged to — and "buy banana" surviving the deletion of "go market"
    /// is not a state anyone would ask for.
    func delete(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let doomed = ids.reduce(into: Set(ids)) { all, id in
            all.formUnion(subTree(of: id))
        }
        guard !doomed.isEmpty else { return }
        perform { items.removeAll { doomed.contains($0.id) } }
    }

    /// Ticks the top of each selected branch and nothing below it.
    ///
    /// Selection deliberately covers whole sub-trees, so that a delete takes a
    /// whole branch. Ticking is the opposite: ticking "go market" and finding
    /// that "buy banana" ticked itself too is a surprise, and a parent can
    /// perfectly well be finished while something under it is still outstanding.
    /// So the selection is trimmed to the items that have no selected ancestor
    /// before anything is ticked.
    func toggleRoots(ids: [UUID]) {
        let selected = Set(ids)
        guard !selected.isEmpty else { return }

        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        func hasSelectedAncestor(_ id: UUID) -> Bool {
            var current = byID[id]
            var budget = items.count
            while let parentID = current?.parentID, budget > 0 {
                budget -= 1
                if selected.contains(parentID) { return true }
                current = byID[parentID]
            }
            return false
        }

        toggle(ids: selected.filter { !hasSelectedAncestor($0) })
    }

    func clearCompleted() {
        let finished = items.filter(\.done).map(\.id)
        delete(ids: finished)
    }

    // MARK: - Disk

    func load() {
        ensureDirectory()

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            items = []
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            items = try JSONDecoder.todo.decode([TodoItem].self, from: data)
        } catch {
            quarantineCorruptFile(reason: String(describing: error))
            items = []
        }
    }

    private func persist() {
        ensureDirectory()
        do {
            let data = try JSONEncoder.todo.encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Diag.log("failed to write \(fileURL.path): \(error)")
        }
    }

    private func ensureDirectory() {
        let directory = TodoStore.directoryURL()
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Diag.log("failed to create \(directory.path): \(error)")
        }
    }

    private func quarantineCorruptFile(reason: String) {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = TodoStore.directoryURL().appendingPathComponent("todos-corrupt-\(stamp).json")
        Diag.log("todos.json unreadable (\(reason)); moved to \(backup.lastPathComponent)")
        try? FileManager.default.moveItem(at: fileURL, to: backup)
    }
}

extension JSONEncoder {
    static var todo: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var todo: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}