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

    /// Top-level tasks still to do.
    ///
    /// Sub-tasks are counted out. They are steps *inside* a task rather than
    /// tasks of their own, so including them made the footer disagree with the
    /// screen: a list showing eight open rows under one task with three
    /// sub-tasks read "11 open", and there was no way to tell from the number
    /// whether it counted something you could see.
    var openCount: Int {
        items.reduce(0) { $0 + ($1.done || $1.parentID != nil ? 0 : 1) }
    }

    /// Top-level tasks already finished.
    ///
    /// Counted the same way as `openCount` so the two halves of the footer mean
    /// the same thing: how many things, not how many lines.
    var doneCount: Int {
        items.reduce(0) { $0 + ($1.done && $1.parentID == nil ? 1 : 0) }
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

    /// Opens or closes a task's sub-tasks, recording the change.
    ///
    /// Deliberately not the path Return and Tab take to open a branch. Those
    /// open one so the caret can drop into a row underneath, and that row is
    /// very likely to be left empty — and "opened a branch, typed nothing, walked
    /// away" is not something the user did, so it must not cost a ⌘Z press.
    /// `openWithoutHistory(id:)` is the other half of that pair: use it when the
    /// open is in service of typing, and this one when the open *is* the change
    /// — the disclosure triangle, which someone pressed on purpose and expects
    /// ⌘Z to take back.
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

    /// Puts "opened" back to "never opened" on a task with nothing under it.
    ///
    /// The single-task spelling, kept because it is what every caller wants and
    /// what the tests read better than. The rule itself, and the reason it is
    /// not an undo step, live on `collapseChildlessParents(_:)`.
    func collapseIfChildless(id: UUID) {
        collapseChildlessParents([id])
    }

    /// Closes every task in `parents` left with nothing under it.
    ///
    /// Deliberately *not* an undo step, for the reason it exists at all: this is
    /// tidying up after a change, not a change of its own. "Looked at a blank row
    /// and walked away" is not something the user did, and "deleted the last
    /// sub-task" is a delete — a history entry here would mean the first ⌘Z after
    /// a delete restored nothing visible and the second was needed to undo it.
    /// `openWithoutHistory(id:)` is careful not to record one either, so the pair
    /// costs nothing at all.
    ///
    /// Returns the ones it closed, so a caller can tell a no-op from a change.
    @discardableResult
    func collapseChildlessParents(_ parents: [UUID]) -> [UUID] {
        var closed: [UUID] = []
        for parent in parents where !closed.contains(parent) {
            guard let index = items.firstIndex(where: { $0.id == parent }) else { continue }
            guard items[index].expanded, !hasChildren(parent) else { continue }
            items[index].expanded = false
            closed.append(parent)
        }
        if !closed.isEmpty { persist() }
        return closed
    }

    /// Opens a branch so the caret can drop into a row under it, *without*
    /// recording a history step.
    ///
    /// The counterpart to `collapseIfChildless`, and for the same reason:
    /// opening a branch to type into it is not a change to the list yet. Leave
    /// the row empty and nothing happened — so nothing may be left in the undo
    /// history either. Otherwise "add a task, Return, Escape" leaves an entry
    /// in the stack identical to the state before it, and the ⌘Z after that does
    /// nothing at all: it takes two presses to remove the task, which is the one
    /// thing adding a task must never cost.
    ///
    /// The disclosure triangle deliberately does *not* come through here: that
    /// is a change to the list made on purpose, and meant to be undoable.
    func openWithoutHistory(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard !items[index].expanded else { return }
        items[index].expanded = true
        persist()
    }

    /// The task a given item hangs under, or `nil` for a top-level one.
    func parentID(of id: UUID) -> UUID? {
        items.first { $0.id == id }?.parentID
    }

    /// Changes a task's title. One undo step, like everything else.
    @discardableResult
    func rename(id: UUID, to title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        guard items[index].title != trimmed else { return false }
        perform { items[index].title = trimmed }
        return true
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

    /// Whether Tab has anything to open or close on this task.
    ///
    /// False for a sub-task, which is at the depth limit and so has no branch
    /// of its own. Toggling one anyway flips a flag that nothing draws, which
    /// spends a ⌘Z press on a keystroke that changed nothing on screen.
    func canToggleExpanded(id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        return Self.depth(of: item, in: items) < Self.maxDepth
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
    /// Refuses on a task at the depth limit — see `canToggleExpanded`.
    @discardableResult
    func toggleExpanded(id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        guard Self.depth(of: items[index], in: items) < Self.maxDepth else { return false }
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
    ///
    /// Closed, with nothing under it, because that is what "a task" means: a
    /// task that has been opened but has nothing in it is a branch with nothing
    /// in it, and it draws an arrow claiming there is something underneath.
    /// Adding is one `perform`, so one ⌘Z removes it.
    @discardableResult
    func add(_ title: String) -> UUID? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = TodoItem(title: trimmed)
        perform { items.append(item) }
        return item.id
    }

    func toggle(id: UUID) {
        toggle(ids: [id])
    }

    /// Ticks every given task. `true` marks them all done, `false` un-marks
    /// them — decided by the first one, so a mixed selection moves together.
    ///
    /// Refuses on ids that are not on the list at all, so nothing is recorded
    /// for a tick that cannot happen. There is no other no-op: `target` is the
    /// opposite of the first task's state, so at least one always moves.
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
    ///
    /// Branches the delete empties are closed afterwards, so the row above is
    /// never left holding an arrow over an empty space. The parents are resolved
    /// *before* the removal: afterwards the items are gone, and with them the
    /// only record of what they hung under.
    func delete(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let doomed = ids.reduce(into: Set(ids)) { all, id in
            all.formUnion(subTree(of: id))
        }
        // `doomed` is never empty once `ids` is, so the old guard here was
        // vacuous. What actually matters is whether anything on the list matches:
        // deleting ids that are not there has to be a no-op rather than an undo
        // entry that appears to do nothing when it is taken back.
        guard doomed.contains(where: { id in items.contains { $0.id == id } }) else { return }
        let parents = doomed.compactMap { parentID(of: $0) }
        perform { items.removeAll { doomed.contains($0.id) } }
        collapseChildlessParents(parents)
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

        // Built by hand rather than with `Dictionary(uniqueKeysWithValues:)`,
        // which *traps* on a duplicate key. `todos.json` is advertised as
        // hand-editable, so two entries sharing an id is a state the file can
        // easily be put into — and a crash on the way in loses whatever the
        // user was in the middle of. First one wins, same as everywhere else.
        var byID: [UUID: TodoItem] = [:]
        for item in items where byID[item.id] == nil {
            byID[item.id] = item
        }

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

    /// Removes every finished task, as one undoable step.
    ///
    /// Ticking is one keystroke and clearing was impossible, so a list that was
    /// actually being used filled up with struck-through rows that pushed the
    /// work still to do off the bottom of the panel. The only route was picking
    /// each finished task out one at a time and deleting it.
    ///
    /// A finished task takes its sub-tasks with it, as any delete does; an open
    /// task keeps them, so clearing the day's work never throws away a sub-task
    /// still outstanding under something you have not finished.
    func clearCompleted() {
        let finished = items.filter(\.done).map(\.id)
        delete(ids: finished)
    }

    // MARK: - Disk

    func load() {
        ensureDirectory()

        // A reload starts a fresh session of history. Carrying the stacks over
        // would make ⌘Z walk backwards through whatever happened before the
        // panel was opened, which is not what undo is for here.
        undoStack.removeAll()
        redoStack.removeAll()
        canUndo = false
        canRedo = false

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            items = []
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder.todo.decode([TodoItem].self, from: data)
            let (kept, droppedDuplicates) = Self.deduplicated(decoded)
            items = Self.withoutStaleExpansion(kept)
            // Only written back when reading actually changed the *list*.
            //
            // The tempting version is "re-encode and write if the bytes differ",
            // and it quietly throws away anything `TodoItem` does not model —
            // every key somebody added by hand, and their formatting — on the
            // next launch. The file is advertised as hand-editable, so it is
            // their file. Duplicates are the one case where rewriting is the
            // only way the change survives.
            if droppedDuplicates > 0 { persist() }
        } catch {
            quarantineCorruptFile(reason: String(describing: error))
            items = []
        }
    }

    /// Throws away repeated ids, keeping the first occurrence.
    ///
    /// Ids are the list's only identity: they key the `ForEach` in the panel,
    /// the selection set, and the walk `subTree` does. Two rows sharing one id
    /// hand SwiftUI a duplicate id and make every selection operation address
    /// two rows at once, so the file is worth sanitising on the way in rather
    /// than defending against everywhere else afterwards.
    ///
    /// Returns how many were dropped alongside the survivors, so the caller can
    /// tell a file that needed fixing from one that did not.
    /// Drops "opened" from any task that has nothing under it.
    ///
    /// Adding a task opens it — that is what lets the caret drop straight into a
    /// row beneath it — and for a long time nothing took it back. So every task
    /// ever added carried a permanent green `v` and an `"expanded": true`,
    /// including the great majority that never had a sub-task. A list of thirty
    /// reminders looked like a tree, and the marker claimed there was something
    /// in here when there was not.
    ///
    /// Applied on the way *in*, in memory only. Tidying up as rows are dismissed
    /// fixes it going forward but never reaches the tasks already on disk, and
    /// this is exactly the state a list written by an older build is in.
    ///
    /// Deliberately not written back on its own: rewriting a file just because
    /// it decoded into something slightly different would throw away anything
    /// the user has added by hand, and this file is advertised as editable. The
    /// next change to the list writes the tidied version out in the ordinary way.
    private static func withoutStaleExpansion(_ loaded: [TodoItem]) -> [TodoItem] {
        let parents = Set(loaded.compactMap(\.parentID))
        return loaded.map { item in
            guard item.expanded, !parents.contains(item.id) else { return item }
            var tidied = item
            tidied.expanded = false
            return tidied
        }
    }

    private static func deduplicated(_ loaded: [TodoItem]) -> ([TodoItem], Int) {
        var seen: Set<UUID> = []
        var out: [TodoItem] = []
        out.reserveCapacity(loaded.count)
        for item in loaded where seen.insert(item.id).inserted {
            out.append(item)
        }
        let dropped = loaded.count - out.count
        if dropped > 0 {
            Diag.log("todos.json had \(dropped) duplicate id(s); dropped")
        }
        return (out, dropped)
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

    /// Creates the directory *this store's* file lives in.
    ///
    /// Derived from `fileURL` rather than hard-wired to the application support
    /// folder: the self-test points a store at a temporary file, and creating
    /// the real data directory on its behalf would be a side effect of running
    /// a test.
    private func ensureDirectory() {
        let directory = fileURL.deletingLastPathComponent()
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