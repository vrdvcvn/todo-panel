import Foundation

/// Collects the outcome of the self-test.
@MainActor
final class Results {
    private(set) var passed = 0
    private(set) var failures: [String] = []

    func check(_ label: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            passed += 1
        } else {
            failures.append(label)
        }
    }

    func equal<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
        if actual == expected {
            passed += 1
        } else {
            failures.append("\(label) — expected \(expected), got \(actual)")
        }
    }
}

/// `todo --selftest` — checks the logic that is easy to get quietly wrong.
///
/// Deliberately part of the executable rather than a test target: this machine
/// has the Command Line Tools and no full Xcode, so there is no XCTest to link
/// against. A test suite that cannot run is worse than none, because it reads
/// as coverage while checking nothing.
///
/// The other reason these exist: this logic used to be checked by driving the
/// real window with synthetic clicks and keystrokes. That does work, but it
/// fails for reasons that have nothing to do with the code under test — the
/// window was not focused, the hotkey toggled the panel shut, `osascript`
/// dropped a key — and then a real bug and a broken test rig look exactly the
/// same. These run the same rules directly, so a failure means the app is
/// wrong.
///
/// `./verify.sh` runs this.
@MainActor
enum SelfTest {
    static func run() -> Never {
        let r = Results()
        undoAndRedo(r)
        selection(r)
        nesting(r)
        keys(r)

        print("selftest: \(r.passed) passed, \(r.failures.count) failed")
        for failure in r.failures {
            print("  ✗ \(failure)")
        }
        exit(r.failures.isEmpty ? 0 : 1)
    }

    private static func store() -> (TodoStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("todo-selftest-\(UUID().uuidString).json")
        return (TodoStore(fileURL: url), url)
    }

    private static func titles(_ store: TodoStore) -> [String] {
        store.items.map(\.title).sorted()
    }

    // MARK: - Undo

    private static func undoAndRedo(_ r: Results) {
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            s.add("alpha")
            s.add("beta")
            r.equal("undo: two tasks stored", titles(s), ["alpha", "beta"])
            r.check("undo: history available after adding", s.canUndo)

            s.undo()
            r.equal("undo: back to one task", titles(s), ["alpha"])
            r.check("undo: redo available", s.canRedo)

            s.redo()
            r.equal("undo: redo restores both", titles(s), ["alpha", "beta"])
            r.check("undo: redo stack drains", !s.canRedo)
        }

        // The one that matters: a batch delete is a single user action, so it
        // has to come back in a single press. Unwinding it task by task means
        // holding ⌘Z and watching them trickle back one at a time.
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            for t in ["a", "b", "c", "d"] { s.add(t) }
            s.delete(ids: s.items.map(\.id))
            r.check("undo: mass delete empties the list", s.items.isEmpty)
            s.undo()
            r.equal("undo: mass delete undone in one press", titles(s), ["a", "b", "c", "d"])
        }

        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            for t in ["a", "b", "c"] { s.add(t) }
            s.toggle(ids: s.items.map(\.id))
            r.check("undo: mass tick marks everything done", s.items.allSatisfy(\.done))
            r.check("undo: mass tick stamps completion times",
                    s.items.allSatisfy { $0.completedAt != nil })
            s.undo()
            r.check("undo: mass tick undone", s.items.allSatisfy { !$0.done })
        }

        // A mixed selection has to move as one thing. Ticking only the open
        // half would be nonsense, and so would un-ticking only the finished one.
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            s.add("open")
            s.add("already done")
            let done = s.items.first { $0.title == "already done" }!
            s.toggle(id: done.id)
            s.toggle(ids: s.items.map(\.id))
            r.check("undo: mixed selection ticks together", s.items.allSatisfy(\.done))
        }

        // Otherwise redo replays something that never happened.
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            s.add("a")
            s.add("b")
            s.undo()
            r.check("undo: redo is offered after an undo", s.canRedo)
            s.add("c")
            r.check("undo: new action clears the redo branch", !s.canRedo)
            s.redo()
            r.equal("undo: redo does not resurrect the undone task", titles(s), ["a", "c"])
        }

        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            s.undo()
            s.redo()
            r.check("undo: undo on a fresh store is harmless", s.items.isEmpty && !s.canUndo)
        }

        do {
            let (s, url) = store()
            s.add("a")
            s.add("b")
            s.undo()
            let reopened = TodoStore(fileURL: url)
            reopened.load()
            r.equal("undo: survives a reload", reopened.items.map(\.title), ["a"])
            try? FileManager.default.removeItem(at: url)
        }

        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            s.add("   ")
            r.check("undo: blank task costs no history", !s.canUndo && s.items.isEmpty)
        }

        // Ticking several at once stamps them all with the same instant, so
        // without a tie-break the finished group comes out in whatever order
        // the sort happens to produce and ⌘A + Space looks like it is ticking
        // tasks at random. They should keep the order they were already in.
        orderOfABatchTick(r)
    }

    private static func orderOfABatchTick(_ r: Results) {
        let (s, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }

        // Distinct creation times, or the test would be asserting on a tie it
        // created itself.
        for t in ["a", "b", "c"] {
            s.add(t)
            Thread.sleep(forTimeInterval: 0.005)
        }

        let before = s.visibleItems.map(\.title)
        s.toggle(ids: s.items.map(\.id))
        let after = s.visibleItems.map(\.title)

        r.equal("order: ticking all keeps them in the order they were in", after, before)
        r.check("order: the batch really did move", s.visibleItems.allSatisfy(\.done))
    }

    // MARK: - Keys
    //
    // These rules used to live inside the SwiftUI panel, where nothing could
    // reach them: a View cannot be built in a command-line test without a window
    // server. The only way to check them was to drive the real app on a real
    // desktop — which is the user's keyboard and screen, and loses every race
    // with whatever they are typing. They live here now.

    private static func keys(_ r: Results) {
        // Where Shift+Return sends a new sub-task. The bug this exists for:
        // on a sub-task it used to find "no parent to add to", fall through,
        // and jump to the add-a-task bar, so the key did nothing on exactly
        // the rows where it should have been most obvious.
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            let ids = tree(s)

            r.equal("keys: shift+Return on a top-level task targets that task",
                    s.parentForNewSubtask(of: ids.parent), ids.parent)
            r.equal("keys: shift+Return on a sub-task targets its parent",
                    s.parentForNewSubtask(of: ids.child), ids.parent)
            r.equal("keys: shift+Return on a loose task targets that task",
                    s.parentForNewSubtask(of: ids.loose), ids.loose)
            r.check("keys: shift+Return on something that is not a task targets nothing",
                    s.parentForNewSubtask(of: UUID()) == nil)

            // Adding from a sub-task lands as a sibling, still two levels deep.
            let target = s.parentForNewSubtask(of: ids.child)
            r.check("keys: adding from a sub-task is allowed", s.addSubtask("milk", under: target ?? UUID()))
            let branch = s.branches.first { $0.item.id == ids.parent }
            // Oldest first, so the one written earlier stays above.
            r.equal("keys: and the parent now has both sub-tasks",
                    branch?.children.map(\.item.title), ["buy banana", "milk"])
            r.check("keys: still only two levels", s.branches.allSatisfy { $0.depth == 0 && $0.children.allSatisfy { $0.depth == 1 && $0.children.isEmpty } })
        }

        // Tab is one verb: open, close, and never create.
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            s.add("go market")
            let id = s.items.first!.id
            r.check("keys: a task nobody has opened is closed", !s.items.first!.expanded)

            s.toggleExpanded(id: id)
            r.check("keys: tab opens it", s.items.first!.expanded)
            r.equal("keys: and opening creates nothing", s.items.count, 1)

            s.toggleExpanded(id: id)
            r.check("keys: tab closes it again", !s.items.first!.expanded)
            r.equal("keys: and closing creates nothing either", s.items.count, 1)

            s.toggleExpanded(id: id)
            s.undo()
            r.check("keys: a toggle undoes in a single step", !s.items.first!.expanded)
        }

        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            let ids = tree(s)

            r.equal("keys: a blank row resolves to its parent",
                    s.parentOfDraftRow(ids.parent.draftRowID), ids.parent)
            r.check("keys: a top-level task is not mistaken for a blank row",
                    s.parentOfDraftRow(ids.parent) == nil)
            r.check("keys: a sub-task is not mistaken for a blank row",
                    s.parentOfDraftRow(ids.child) == nil)
        }

        // Adding a task and opening it must be one undo step. Two would mean
        // ⌘Z closed the task and left it there, needing a second press to
        // remove — a task undo has to be immune to that.
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            let id = s.addAndOpen("go market")
            r.check("keys: addAndOpen hands back the new task", id != nil)
            r.check("keys: and the task arrives open", s.items.first { $0.id == id }?.expanded == true)
            s.undo()
            r.equal("keys: one undo removes it entirely", s.items.count, 0)
        }
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            s.add("a")
            s.add("b")
            s.add("c")
            s.undo()
            r.equal("keys: add is one undo step", s.items.map(\.title), ["a", "b"])
            s.addAndOpen("d")
            s.undo()
            r.equal("keys: and so is add-and-open", s.items.map(\.title), ["a", "b"])
        }

        // A blank row that was looked at and walked away from has to leave no
        // trace. If showing or hiding one recorded anything, ⌘Z would start
        // undoing things that were never done — the exact thing the user was
        // worried about.
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            let m = PanelModel()

            // Settle on a real state first, then count undo entries precisely.
            s.add("go market")
            s.undo()                      // history is now empty
            r.check("keys: history is empty to begin with", !s.canUndo)

            m.showDraftRow(for: UUID())
            r.check("keys: showing a blank row does not create an undo step", !s.canUndo)
            m.hideDraftRow(for: UUID())
            r.check("keys: hiding one does not either", !s.canUndo)

            // And the same when a bar is opened on a task that exists, which is
            // the path that goes through the store's expanded flag.
            let parent = s.add("go market")
            s.undo()
            r.check("keys: history is empty again", !s.canUndo)
            _ = s.toggleExpanded(id: parent ?? UUID())
            s.undo()
            r.check("keys: a branch toggle does not leave a step behind either", !s.canUndo)
        }

        // The two ends of the list, and the blank row's on-screen life.
        do {
            let m = PanelModel()
            let a = UUID(), b = UUID(), c = UUID()
            let rows = [a, b, c]

            m.select(a)
            r.check("keys: the top row counts as the top", m.isAtTop(of: rows))
            r.check("keys: and not as the bottom", !m.isAtBottom(of: rows))

            m.select(c)
            r.check("keys: the bottom row counts as the bottom", m.isAtBottom(of: rows))
            r.check("keys: and not as the top", !m.isAtTop(of: rows))

            m.select(b)
            r.check("keys: a middle row is neither", !m.isAtTop(of: rows) && !m.isAtBottom(of: rows))

            // An empty list must claim to be at neither end, or the first
            // arrow press out of it would jump straight back to the prompt.
            r.check("keys: an empty list is not at the top", !m.isAtTop(of: []))
            r.check("keys: an empty list is not at the bottom", !m.isAtBottom(of: []))

            // The blank row is on screen because it was asked for, not because
            // the branch happens to be open.
            r.check("keys: a branch is not a blank row", !m.isDraftRowOpen(a))
            m.showDraftRow(for: a)
            r.check("keys: asking for it shows it", m.isDraftRowOpen(a))
            m.showDraftRow(for: a)
            r.check("keys: asking twice is harmless", m.isDraftRowOpen(a))
            m.hideDraftRow(for: a)
            r.check("keys: and it can be taken away", !m.isDraftRowOpen(a))
        }
    }

    // MARK: - Nesting

    /// Build "go market" with a sub-task, plus a loose task alongside. Two
    /// levels is all there is now.
    private static func tree(_ store: TodoStore) -> (parent: UUID, child: UUID, loose: UUID) {
        store.add("go market")
        let parent = store.items.first { $0.title == "go market" }!.id
        store.addSubtask("buy banana", under: parent)
        let child = store.items.first { $0.title == "buy banana" }!.id
        store.add("call mum")
        let loose = store.items.first { $0.title == "call mum" }!.id
        return (parent, child, loose)
    }

    private static func nesting(_ r: Results) {
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            let ids = tree(s)
            let titles = s.visibleRows.map(\.item.title)

            r.equal("nest: the tree is a depth-first walk", titles,
                    ["call mum", "go market", "buy banana"])

            r.equal("nest: depth is counted from the top", s.visibleRows.map(\.depth), [0, 0, 1])
            r.check("nest: the parent knows it has children", s.hasChildren(ids.parent))
            // With two levels a sub-task can never have children, so this is
            // as much a statement about the limit as about the tree.
            r.check("nest: a sub-task never reports children", !s.hasChildren(ids.child))
            r.check("nest: a task with no sub-tasks does not", !s.hasChildren(ids.loose))

            // Closing hides the whole branch, not one level of it.
            s.setExpanded(false, id: ids.parent)
            r.equal("nest: closing hides every descendant",
                    s.visibleRows.map(\.item.title), ["call mum", "go market"])
            r.check("nest: a closed parent is still on screen", s.visibleRows.contains { $0.id == ids.parent })

            s.setExpanded(true, id: ids.parent)
            r.equal("nest: opening brings the branch back",
                    s.visibleRows.map(\.item.title), ["call mum", "go market", "buy banana"])
        }

        // Three levels, so a sub-task can have children but a child of one
        // cannot. Asked for explicitly: deeper trees were ruled out to avoid
        // more edge cases, not because nobody wanted them.
        // A task that has been opened but has nothing under it yet. This is the
        // state Tab puts a task into, and it has to be different from "never
        // opened" — otherwise a flat list would show a blank row under
        // everything, and a fresh task could never grow a branch.
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            s.add("go market")
            let parent = s.items.first!.id
            r.check("nest: a fresh task is not open", !s.items.first!.expanded)
            r.equal("nest: and so has no branch of its own", s.visibleRows.count, 1)

            s.setExpanded(true, id: parent)
            r.check("nest: opening a childless task is remembered", s.items.first!.expanded)
            r.equal("nest: it has no children yet", s.visibleRows.map(\.item.title), ["go market"])

            s.setExpanded(false, id: parent)
            r.check("nest: closing it again is a round trip", !s.items.first!.expanded)
        }

        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            let ids = tree(s)
            r.equal("nest: a sub-tree is the task and everything under it",
                    s.subTree(of: ids.parent), [ids.parent, ids.child])
        }

        // Deleting a parent must not strand its children at the top.
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            let ids = tree(s)
            s.delete(id: ids.parent)
            r.equal("nest: deleting a parent takes its sub-tasks with it",
                    s.items.map(\.title), ["call mum"])
            s.undo()
            r.equal("nest: and one undo brings the whole branch back",
                    s.items.count, 3)
        }

        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            let ids = tree(s)
            s.delete(id: ids.child)
            r.equal("nest: deleting a sub-task leaves the rest alone",
                    s.items.map(\.title).sorted(), ["call mum", "go market"])
        }

        // Selection covers a whole branch, so a delete takes a whole branch...
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            let ids = tree(s)
            s.delete(ids: [ids.parent, ids.loose])
            r.check("nest: deleting a selected parent and a loose task clears both branches",
                    s.items.isEmpty)
        }

        // ...but ticking does not. A parent can be finished while something
        // under it is still outstanding.
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            let ids = tree(s)
            s.toggleRoots(ids: [ids.parent, ids.child])
            r.check("nest: ticking a parent with its sub-tasks ticked leaves them alone",
                    s.items.first { $0.id == ids.parent }!.done && !s.items.first { $0.id == ids.child }!.done)
        }
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            let ids = tree(s)
            s.toggleRoots(ids: [ids.child])
            r.check("nest: ticking only sub-tasks ticks exactly those",
                    s.items.first { $0.id == ids.child }!.done && !s.items.first { $0.id == ids.parent }!.done)
        }
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            let ids = tree(s)
            r.check("nest: a parent starts unticked", !s.items.first { $0.id == ids.parent }!.done)
            s.toggleRoots(ids: [ids.parent])
            r.check("nest: ticking a parent ticks it", s.items.first { $0.id == ids.parent }!.done)
            s.toggleRoots(ids: [ids.parent])
            r.check("nest: and again unticks it", !s.items.first { $0.id == ids.parent }!.done)
        }

        // Adding under a collapsed task would look like nothing happened.
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            s.add("go market")
            let parent = s.items.first!.id
            s.setExpanded(false, id: parent)
            s.addSubtask("buy banana", under: parent)
            r.check("nest: adding under a closed task opens it",
                    s.visibleRows.map(\.item.title) == ["go market", "buy banana"])
            s.undo()
            r.equal("nest: one undo undoes the add and the reopen together",
                    s.items.map(\.title), ["go market"])
        }

        // Sub-tasks run the other way from the top level. A shopping list is
        // written in order and read in order; newest-first turned it upside
        // down so the item you had just added jumped above the ones before it.
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            s.add("go market")
            let parent = s.items.first!.id
            for t in ["first", "second", "third"] {
                s.addSubtask(t, under: parent)
                Thread.sleep(forTimeInterval: 0.004)
            }
            r.equal("nest: sub-tasks stay in the order they were written",
                    s.branches.first?.children.map(\.item.title),
                    ["first", "second", "third"])
        }

        // A list written when there were three levels must not lose its
        // deepest task when the limit moves in.
        do {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("todo-selftest-deep-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            let (s, url2) = store()
            defer { try? FileManager.default.removeItem(at: url2) }
            s.add("go market")
            let parent = s.items.first!.id
            s.addSubtask("buy bananas", under: parent)
            let child = s.items.first { $0.title == "buy bananas" }!.id
            // Written past the old limit, which `addSubtask` would now refuse.
            var deep = s.items
            deep.append(TodoItem(title: "ripe", parentID: child))
            try! JSONEncoder.todo.encode(deep).write(to: url)

            let reopened = TodoStore(fileURL: url)
            reopened.load()
            r.equal("nest: a task from the old third level is kept, promoted to the top",
                    reopened.branches.map { $0.item.title }.sorted(), ["go market", "ripe"])
        }

        // A file edited by hand can point a sub-task at a parent that is not
        // there. Showing it at the top beats silently losing it.
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            s.add("real task")
            s.add("orphan")
            let orphan = s.items.first { $0.title == "orphan" }!
            var edited = s.items
            let index = edited.firstIndex { $0.id == orphan.id }!
            edited[index].parentID = UUID() // nothing owns it
            let data = try! JSONEncoder.todo.encode(edited)
            try! data.write(to: url)

            let reopened = TodoStore(fileURL: url)
            reopened.load()
            r.equal("nest: a sub-task with a missing parent is promoted, not dropped",
                    reopened.branches.map { $0.item.title }.sorted(), ["orphan", "real task"])
            r.check("nest: and it is shown at depth 0",
                    reopened.branches.first { $0.item.title == "orphan" }?.depth == 0)
        }

        // An old file has neither field, and must read as a flat list rather
        // than needing the user to re-save it from the settings screen.
        do {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("todo-selftest-legacy-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            let legacy = """
            [{"id":"11111111-1111-1111-1111-111111111111","title":"from an old build",            "done":false,"createdAt":"2026-01-01T00:00:00Z"}]
            """
            try! Data(legacy.utf8).write(to: url)
            let reopened = TodoStore(fileURL: url)
            reopened.load()
            r.equal("nest: a file written before sub-tasks still loads", reopened.items.count, 1)
            r.check("nest: and every task in it is top level",
                    reopened.branches.count == 1 && reopened.branches[0].depth == 0)
        }
    }

    // MARK: - Selection

    private static func selection(_ r: Results) {
        let model = PanelModel()
        let a = ["a", "b", "c", "d"].map { TodoItem(title: $0) }

        let ids = a.map(\.id)
        let alone = { (id: UUID) in Set([id]) }

        model.select(a[1].id)
        model.select(a[2].id)
        r.equal("select: plain click replaces the selection", model.selection, [a[2].id])

        model.select(a[0].id)
        model.toggleInSelection(a[2].id)
        r.equal("select: ⌘-click adds", model.selection, [a[0].id, a[2].id])
        model.toggleInSelection(a[0].id)
        r.equal("select: ⌘-click on a selected task deselects it", model.selection, [a[2].id])

        model.selectAll(ids)
        model.toggleInSelection(a[1].id)
        r.equal("select: ⌘-click removes from a full selection",
                model.selection, [a[0].id, a[2].id, a[3].id])

        model.select(a[0].id)
        model.extendSelection(to: a[2].id, in: ids)
        r.equal("select: shift-click takes the range",
                model.selection, [a[0].id, a[1].id, a[2].id])

        model.select(a[3].id)
        model.extendSelection(to: a[1].id, in: ids)
        r.equal("select: backwards shift-click takes the same range",
                model.selection, [a[1].id, a[2].id, a[3].id])

        // Repeated shift presses grow outwards from where the drag started, not
        // from whichever row happens to be current.
        model.select(a[1].id)
        model.extendSelection(to: a[2].id, in: ids)
        model.extendSelection(to: a[3].id, in: ids)
        r.equal("select: repeated shift grows from the anchor",
                model.selection, [a[1].id, a[2].id, a[3].id])

        model.selectAll(ids)
        model.moveSelection(by: 1, extending: false, in: ids)
        r.check("select: a plain arrow collapses to one task", model.selection.count == 1)

        model.select(a[0].id)
        model.moveSelection(by: 1, extending: true, in: ids)
        model.moveSelection(by: 1, extending: true, in: ids)
        r.equal("select: shift-arrow extends", model.selection, [a[0].id, a[1].id, a[2].id])

        model.select(a[0].id)
        model.moveSelection(by: -1, extending: false, in: ids)
        r.equal("select: arrows stop at the top", model.selection, [a[0].id])
        model.select(a[3].id)
        model.moveSelection(by: 1, extending: false, in: ids)
        r.equal("select: arrows stop at the bottom", model.selection, [a[3].id])

        // The regression that is why selection tracks identities rather than
        // positions: ticking a task moves it into the completed group, so
        // every task below it shifts up and an index would silently point at
        // the wrong one — and the next keystroke would delete it.
        let resorted = [a[2], a[0], a[1]]
        model.select(a[2].id)
        r.check("select: highlight follows the task, not the row", model.isSelected(resorted[0].id))

        model.selectAll(ids)
        model.retainSelection(in: [a[0].id])
        r.equal("select: a deleted task does not stay highlighted", model.selection, [a[0].id])

        // Picking one row must pick one row. This used to sweep in the whole
        // branch, so ↓ from the add-a-task bar lit up a parent and everything
        // under it, which reads as far more being selected than was.
        do {
            let (st, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            let t = tree(st)
            let m = PanelModel()
            m.select(t.parent)
            r.equal("select: picking a parent picks only the parent", m.selection, [t.parent])
            m.toggleInSelection(t.child)
            r.equal("select: ⌘-click adds just that row", m.selection, [t.parent, t.child])
            m.toggleInSelection(t.parent)
            r.equal("select: ⌘-click takes just that row back out", m.selection, [t.child])
        }

        // A range crosses the nested rows rather than stepping over them.
        do {
            let m = PanelModel()
            let flat = [a[0].id, a[1].id, a[2].id, a[3].id]
            m.select(a[0].id)
            m.extendSelection(to: a[3].id, in: flat)
            r.equal("select: a range includes every row it crosses, nested ones too",
                    m.selection, Set(flat))
        }

        model.selectAll(ids)
        model.requestInputFocus()
        r.check("select: returning to the prompt clears it",
                model.selection.isEmpty && model.mode == .input)

        model.selectAll(ids)
        model.draft = "half a task"
        model.resetToInput()
        r.check("select: reopening clears the highlight", model.selection.isEmpty)
        r.check("select: reopening keeps the draft", model.draft == "half a task")
    }
}
