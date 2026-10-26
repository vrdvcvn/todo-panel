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
        focus(r)
        editing(r)
        caret(r)
        resilience(r)
        dailyUse(r)

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

        // Adding a task must leave it closed. It used to arrive open, with the
        // caret dropped into a sub-task row beneath it, so every task ever
        // added kept an arrow and an `"expanded": true` on disk — including the
        // overwhelming majority that never had a sub-task.
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            let id = s.add("go market")
            r.check("keys: add hands back the new task", id != nil)
            // The other half of the same promise — that adding a task implies no
            // blank sub-task row under it — is `submit()` not calling
            // `showDraftRow`, which is a view rule with no command-line test and
            // no honest way to fake one. It is covered by the manual pass in the
            // plan's Verification section. This is the half that was wrong.
            r.check("keys: and the task arrives closed", s.items.first { $0.id == id }?.expanded == false)
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
            s.add("d")
            s.undo()
            r.equal("keys: and so is every other add", s.items.map(\.title), ["a", "b"])
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

    // MARK: - Focus

    /// Which field the caret is in, and what the keys should do about it.
    ///
    /// Every one of these was a question the panel answered about the wrong
    /// field. The panel has two, and focus requests only ever moved the answer
    /// one way — so clicking straight into a field left the model still
    /// describing the field the keyboard was last *sent* to. ⌘Z then decided
    /// there was no typing to protect and undid a task instead.
    private static func focus(_ r: Results) {
        let m = PanelModel()
        let parent = UUID()

        m.draft = "call mum"
        r.equal("focus: the top prompt is the focused field to begin with",
                m.focusedText, "call mum")
        r.check("focus: and nothing is focused in a blank row", m.focusedDraftParent == nil)

        m.requestChildFocus(parent)
        r.check("focus: the caret can be in a blank sub-task row",
                m.focusedDraftParent == parent)
        r.equal("focus: which reports the root draft, which is empty",
                m.focusedText, "")

        m.setDraft("buy milk", for: parent)
        r.equal("focus: and reports the sub-task text instead",
                m.focusedText, "buy milk")

        // Clicking into the top prompt is not a focus request, so nothing else
        // moves the answer. This is that route.
        m.adoptInputTarget(.root)
        r.equal("focus: clicking into the prompt makes it the focused field",
                m.focusedText, "call mum")
        r.check("focus: and nothing is in a blank row any more",
                m.focusedDraftParent == nil)
        r.check("focus: clicking into a field is not a list keypress",
                m.mode == .input)

        // ...and it must not quietly undo the selection, which is a different
        // thing that only a deliberate hand-off should do.
        let task = UUID()
        m.select(task)
        m.adoptInputTarget(.child(parent))
        r.equal("focus: adopting a field leaves the selection alone",
                m.selection, [task])

        // "Unused" has to mean the same thing to every rule that asks, or a row
        // holding nothing but spaces is blank to the save path and full to the
        // dismissal path: Return declines to add a task, Delete declines to
        // remove the row, and nothing else can move it either.
        m.setDraft("   ", for: parent)
        r.check("focus: a row holding only spaces counts as unused",
                m.draftIsBlank(parent))
        m.setDraft(" x ", for: parent)
        r.check("focus: a row with real text does not", !m.draftIsBlank(parent))
        r.check("focus: an untouched row counts as unused",
                m.draftIsBlank(UUID()))

        m.showDraftRow(for: parent)
        r.check("focus: a row asked for is on screen", m.isDraftRowOpen(parent))
        m.pruneDrafts(under: [])
        r.check("focus: and is forgotten when its task is gone",
                !m.isDraftRowOpen(parent))
        r.check("focus: along with the half-typed text in it", m.focusedText != " x ")
    }

    // MARK: - Editing

    /// Correcting a title in place, and where the caret lands when you do.
    private static func editing(_ r: Results) {
        let m = PanelModel()
        let id = UUID()

        m.beginEditing(id: id, title: "buy binto")
        r.check("edit: the field being corrected is the focused one",
                m.inputTarget == .edit(id))
        r.check("edit: and it is the only thing ⌘Z would undo", m.focusedText == "buy binto")
        r.check("edit: a new edit starts with the title, not a blank",
                m.editDraft == "buy binto")
            r.check("edit: a title already exists, so ⌘Z is always about the text",
                    m.isEditingTitle)

        // Where the caret goes is the whole point of ← and →: one keystroke
        // after the editor opens either appends to the title or rewrites it from
        // the front. Asking for the start has to survive, and has to be a
        // position rather than a flag — the field is the only thing that knows
        // how long the text is at the moment it is drawn.
        r.equal("edit: a new edit asks for the end by default", m.editCaretOffset, 9)
        m.beginEditing(id: id, title: "buy binto", caret: .end)
        r.equal("edit: ⇧Return asks for the end", m.editCaretOffset, 9)
        m.beginEditing(id: id, title: "buy binto", caret: .start)
        r.equal("edit: ← asks for the start", m.editCaretOffset, 0)
        // The end is a position, not a fixed number, so it moves as the title is
        // typed — which is also why it has to be re-asked for here: the caret
        // asked for is the one in force until the next edit begins.
        m.beginEditing(id: id, title: "buy milk", caret: .end)
        r.equal("edit: and the end follows the text as it is typed",
                m.editCaretOffset, 8)

        // Escape puts the old one back without touching the store — which is
        // what the store tests below check. The model's own job is to stop
        // pointing at the task, so nothing downstream can commit the text.
        m.cancelEditing()
        r.check("edit: Escape ends the edit", m.editing == nil)
        r.check("edit: and leaves nothing behind to commit",
                m.editDraft.isEmpty && m.inputTarget == .root)

        // Return keeps it, and hands the keyboard back to the list with the row
        // still picked — so Space straight after a correction ticks the task
        // you just fixed, not whatever the list re-sorted into place.
        m.beginEditing(id: id, title: "buy binto")
        m.setEditDraft("buy milk")
        m.finishEditing()
        r.check("edit: committing ends the edit", m.editing == nil)
        r.equal("edit: the keyboard goes back to the list", m.mode, .list)
        r.equal("edit: with the row still selected", m.selection, [id])
        r.equal("edit: and the text is the caller's to commit", m.editDraft, "")

        // The top prompt is the opposite case: it holds something that does not
        // exist yet, so an empty one means ⌘Z belongs to the list.
        let fresh = PanelModel()
        r.check("edit: an empty prompt is not a title being edited",
                !fresh.isEditingTitle)
    }

    // MARK: - Caret placement

    /// Where the caret lands when a title editor opens.
    ///
    /// Two coordinate systems meet here and they do not agree. `PanelModel`
    /// counts characters, because that is what `String.count` means and what the
    /// person typing thinks they are doing; AppKit's `NSRange` counts UTF-16
    /// units, because that is what a text buffer is made of. The first mismatch
    /// this found was an emoji: one character, two units, and the caret landed
    /// inside the surrogate pair, where AppKit put it back wherever it liked.
    private static func caret(_ r: Results) {
        let m = PanelModel()
        // Ten characters, eleven UTF-16 units.
        m.beginEditing(id: UUID(), title: "buy milk 🎉", caret: .end)
        r.equal("caret: the end is counted in characters, not UTF-16 units",
                m.editCaretOffset, 10)
        m.beginEditing(id: UUID(), title: "buy milk 🎉", caret: .start)
        r.equal("caret: and the start is always zero", m.editCaretOffset, 0)

        // The conversion itself, rather than only the contract it serves — a
        // helper nothing can reach is a helper nothing can check.
        r.equal("caret: a character offset becomes a UTF-16 offset",
                PromptField.utf16Offset(10, in: "buy milk 🎉"), 11)
        r.equal("caret: plain ASCII is its own conversion",
                PromptField.utf16Offset(8, in: "buy milk"), 8)
        r.equal("caret: and nothing before the text is no offset at all",
                PromptField.utf16Offset(-1, in: "buy milk"), 0)
    }

    // MARK: - Resilience

    /// A hand-editable file is allowed to be a strange one, and nothing here may
    /// cost the user their list.
    private static func resilience(_ r: Results) {
        // Ids are the list's only identity. Two rows sharing one used to be
        // handed straight to SwiftUI as a `ForEach` key, and `toggleRoots` built
        // a dictionary with `uniqueKeysWithValues:` — which traps rather than
        // failing, so pressing Space on such a list killed the process.
        do {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("todo-selftest-dupes-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }

            let shared = UUID()
            let list = [
                TodoItem(id: shared, title: "first", createdAt: Date(timeIntervalSince1970: 100)),
                TodoItem(id: shared, title: "second", createdAt: Date(timeIntervalSince1970: 200)),
                TodoItem(title: "third"),
            ]
            try! JSONEncoder.todo.encode(list).write(to: url)

            let reopened = TodoStore(fileURL: url)
            reopened.load()
            r.equal("load: a repeated id is dropped, not doubled",
                    reopened.items.map(\.title), ["first", "third"])
            r.check("load: and the file is corrected on disk",
                    try! String(contentsOf: url, encoding: .utf8).contains("\"second\"") == false)
            // Would have trapped.
            reopened.toggleRoots(ids: reopened.items.map(\.id))
            r.check("load: ticking such a list survives", reopened.items.allSatisfy(\.done))
        }

        // Keys in the file that this build does not model are the user's, and
        // reading the list must not quietly delete them.
        do {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("todo-selftest-extra-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }

            let id = UUID()
            let hand = """
            [{"id":"\(id.uuidString)","title":"hand written","done":false,\
            "createdAt":"2026-01-01T00:00:00Z","priority":3}]
            """
            try! Data(hand.utf8).write(to: url)

            let store = TodoStore(fileURL: url)
            store.load()
            r.equal("load: a hand-written field does not stop the list loading",
                    store.items.map(\.title), ["hand written"])
            r.check("load: and reading it does not rewrite the file",
                    try! String(contentsOf: url, encoding: .utf8).contains("\"priority\""))
        }

        // A reload is the start of a session, not a point in a timeline.
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            s.add("a")
            s.add("b")
            s.undo()
            r.check("load: there is something to undo first", s.canUndo)

            s.load()
            r.check("load: a reload starts a fresh history", !s.canUndo && !s.canRedo)
            r.equal("load: and leaves the list alone", titles(s), ["a"])
        }

        // An action that changes nothing must not spend a ⌘Z press.
        //
        // One block, not two. It was written twice, byte for byte down to the
        // assertion labels, so eight of the count were really four — and a count
        // that overstates what is covered is worse than a low one, because it is
        // the number people read to decide whether anything is checked here.
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            s.add("a")
            s.undo()
            r.check("quiet: history is empty to begin with", !s.canUndo)

            s.delete(ids: [UUID()])
            r.check("quiet: deleting something that is not there costs no history",
                    !s.canUndo)

            s.toggle(ids: [UUID()])
            r.check("quiet: ticking something that is not there costs no history",
                    !s.canUndo)
        }

        // Tab opens or closes a branch, and turns a task with nothing under it
        // into a list. On a sub-task it has no branch to act on at all, and the
        // store says so rather than flipping a flag nothing draws — which used
        // to cost a ⌘Z press on a keystroke that changed nothing on screen.
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            let ids = tree(s)

            r.check("tab: a task with a branch can be toggled",
                    s.canToggleExpanded(id: ids.parent))
            r.check("tab: a sub-task cannot", !s.canToggleExpanded(id: ids.child))
            r.check("tab: neither can something that is not there",
                    !s.canToggleExpanded(id: UUID()))

            let depth = s.canUndo
            s.toggleExpanded(id: ids.child)
            r.equal("tab: toggling a sub-task leaves the flag alone",
                    s.items.first { $0.id == ids.child }?.expanded, false)
            r.equal("tab: and records nothing to undo", s.canUndo, depth)
        }
    }

    // MARK: - Daily use

    /// The things a person does every day, and what used to happen to them.
    private static func dailyUse(_ r: Results) {
        // A new task is a task, not a branch. It used to arrive open, with the
        // caret dropped into a sub-task row beneath it, and nothing ever took
        // that back — so every task ever added kept a permanent green `v` and
        // an `"expanded": true` on disk, including the overwhelming majority
        // that never had a sub-task. A plain list of thirty reminders looked
        // like a tree.
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            let id = s.add("buy milk")
            r.check("daily: a new task arrives closed", s.items.first?.expanded == false)

            // Opened by hand — which is all a branch ever was — and then left
            // with nothing under it.
            s.setExpanded(true, id: id ?? UUID())
            r.check("daily: opening it is still possible", s.items.first?.expanded == true)

            s.collapseIfChildless(id: id ?? UUID())
            r.check("daily: leaving it with nothing under it takes the flag back",
                    s.items.first?.expanded == false)
            r.check("daily: and the arrow goes with it",
                    s.branches.first { $0.item.id == id }?.children.isEmpty == true)
        }

        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            let ids = tree(s)
            s.collapseIfChildless(id: ids.parent)
            // `tree` leaves the parent open; collapsing must not have closed a
            // branch that still has something in it.
            r.check("daily: a task with sub-tasks stays open",
                    s.items.first { $0.id == ids.parent }?.expanded == true)
            s.setExpanded(false, id: ids.parent)
            s.collapseIfChildless(id: ids.parent)
            r.equal("daily: and once emptied it goes back",
                    s.items.first { $0.id == ids.parent }?.expanded, false)
        }

        // "Looked at a blank row and walked away" must stay out of the history.
        // A step for it would mean the first ⌘Z after adding a task does nothing
        // visible and the second removes it — the two-press undo a task add has
        // to be immune to.
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            s.add("buy milk")
            s.undo()
            r.check("daily: nothing to undo to begin with", !s.canUndo)

            s.add("buy milk")
            r.check("daily: adding one is a step", s.canUndo)
        }
        // And the same for opening a branch to type into it, which is what
        // Return and Tab now both do. Open it, change nothing, close it: the
        // list is exactly as it was, so the history has to be exactly as it was
        // too — one ⌘Z has to remove the task, not tidy up after it.
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            let id = s.add("buy milk")
            r.check("keys: adding one is the only step so far", s.canUndo)

            s.openWithoutHistory(id: id ?? UUID())
            r.check("keys: opening a branch to type into it works",
                    s.items.first?.expanded == true)

            s.collapseIfChildless(id: id ?? UUID())
            r.check("keys: leaving it empty closes it again",
                    s.items.first?.expanded == false)

            s.undo()
            r.equal("keys: so one undo still removes the task", s.items.count, 0)
            r.check("keys: with nothing left to undo", !s.canUndo)
        }

        // Taking the last sub-task out of a branch has to take the branch's
        // "opened" with it, or the row above is left holding an arrow over an
        // empty space. And it must not cost an undo step of its own: one ⌘Z
        // after a delete brings the branch back exactly as it was.
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            let ids = tree(s)

            s.delete(ids: [ids.child])
            r.check("daily: deleting the last sub-task closes the parent",
                    s.items.first { $0.id == ids.parent }?.expanded == false)

            s.undo()
            r.equal("daily: and one undo brings the branch back intact",
                    s.branches.first { $0.id == ids.parent }?.children.map(\.item.title),
                    ["buy banana"])
            r.check("daily: still open, because it has something under it",
                    s.items.first { $0.id == ids.parent }?.expanded == true)
        }

        // A branch is only closed once the *last* thing under it goes, however
        // many deletes it takes to get there.
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            let ids = tree(s)
            s.addSubtask("buy bread", under: ids.parent)
            let bread = s.items.first { $0.title == "buy bread" }!.id

            s.delete(ids: [ids.child])
            r.check("daily: a branch with a sub-task left stays open",
                    s.items.first { $0.id == ids.parent }?.expanded == true)

            s.delete(ids: [bread])
            r.check("daily: and closes when the last one goes",
                    s.items.first { $0.id == ids.parent }?.expanded == false)
        }

        // A list written by an older build has the stale flag all over it, and
        // it should not come back on screen.
        do {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("todo-selftest-stale-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            let lonely = UUID()
            let list = [
                TodoItem(id: lonely, title: "never had a sub task", expanded: true),
                TodoItem(title: "plain"),
            ]
            try! JSONEncoder.todo.encode(list).write(to: url)

            let reopened = TodoStore(fileURL: url)
            reopened.load()
            r.check("daily: a stale flag from an older build is ignored on load",
                    reopened.items.first { $0.id == lonely }?.expanded == false)
            r.check("daily: and reading it did not rewrite the user's file",
                    try! String(contentsOf: url, encoding: .utf8).contains("\"expanded\" : true"))
        }

        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            let ids = tree(s)
            let reopened = TodoStore(fileURL: url)
            reopened.load()
            // The parent here really does have sub-tasks, so its "opened" is
            // telling the truth and must survive the tidying.
            r.check("daily: a genuine 'opened' survives the tidying",
                    reopened.items.first { $0.id == ids.parent }?.expanded == true)
        }

        // Fixing a typo. There was no way to do it at all, which meant deleting
        // the task — losing its place in the list and every sub-task under it —
        // over one wrong letter.
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            s.add("call mum")
            let loose = s.items[0].id

            r.check("edit: a rename to the same text does nothing",
                    !s.rename(id: loose, to: "call mum"))
            r.check("edit: a rename to nothing is refused",
                    !s.rename(id: loose, to: "   "))
            // One undo still removes the task, which is only true if neither
            // refusal was recorded.
            s.undo()
            r.check("edit: neither refusal cost an undo step", s.items.isEmpty)
        }

        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            s.add("call mum")
            let loose = s.items[0].id

            r.check("edit: a real rename works",
                    s.rename(id: loose, to: "  call mum and dad  "))
            r.equal("edit: and is trimmed", s.items.first?.title, "call mum and dad")

            s.undo()
            r.equal("edit: one undo puts the title back", s.items.first?.title, "call mum")
        }

        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            let ids = tree(s)
            r.check("edit: a sub-task's parent is still there to be renamed",
                    s.rename(id: ids.child, to: "buy bananas"))
            r.equal("edit: and renaming it leaves the tree alone", s.items.count, 3)
        }

        // Clearing the day's work. Ticking was one keystroke and clearing was
        // impossible, so a used list filled with struck-through rows and the
        // work still to do got pushed off the bottom of the panel.
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            s.add("a")
            s.add("b")
            s.add("c")
            s.toggle(ids: s.items.map(\.id))
            r.equal("daily: three finished", s.doneCount, 3)

            s.clearCompleted()
            r.check("daily: clearing empties the list", s.items.isEmpty)
            s.undo()
            r.equal("daily: and one undo brings back the whole day", s.items.count, 3)
            r.check("daily: with them still finished", s.doneCount == 3)
        }

        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            s.add("a")
            s.add("b")
            s.toggle(id: s.items[1].id)
            s.clearCompleted()
            r.equal("daily: clearing keeps what is still open",
                    s.items.map(\.title), ["a"])
        }

        // The footer has to agree with the screen. Counting sub-tasks made a list
        // showing eight open rows read "11 open", and nothing on screen said
        // where the other three came from.
        do {
            let (s, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            let ids = tree(s)
            r.equal("daily: the count matches the rows on screen", s.openCount, 2)
            r.equal("daily: and so does the finished count", s.doneCount, 0)

            s.toggle(id: ids.loose)
            r.equal("daily: a finished task is counted once", s.doneCount, 1)
            let openBefore = s.openCount
            s.toggle(id: ids.child)
            r.check("daily: a finished sub-task does not inflate it", s.doneCount == 1)
            r.equal("daily: and does not move the open count either",
                    s.openCount, openBefore)
        }

        do {
            // Loaded from disk rather than built, because "nothing is finished"
            // is the state a freshly opened panel is in, and a freshly opened
            // panel has no undo history to spend.
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("todo-selftest-nofin-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            try! JSONEncoder.todo.encode([TodoItem(title: "a"), TodoItem(title: "b")])
                .write(to: url)

            let s = TodoStore(fileURL: url)
            s.load()
            r.check("daily: nothing finished, and no history to begin with",
                    !s.canUndo && s.doneCount == 0)

            s.clearCompleted()
            r.check("daily: clearing nothing costs nothing", !s.canUndo && s.items.count == 2)
        }

        // The scrolling rule. Following every selection change scrolled the row
        // you had just *clicked* to the middle of the panel — the pointer had
        // put it on screen, so the only thing the scroll achieved was losing
        // the rows either side of what you were reading.
        do {
            let m = PanelModel()
            let ids = [UUID(), UUID(), UUID()]

            m.select(ids[0])
            r.check("scroll: clicking a row asks for no scroll", m.scrollTarget == nil)

            m.moveSelection(by: 1, extending: false, in: ids)
            r.equal("scroll: the arrow keys do ask for one", m.scrollTarget, ids[1])
            m.clearScrollTarget()
            r.check("scroll: and the list clears it once it has followed", m.scrollTarget == nil)

            m.toggleInSelection(ids[2])
            r.check("scroll: ⌘-clicking does not either", m.scrollTarget == nil)
        }

        // Closing the panel is a way of leaving a blank sub-task row, so an
        // empty one left behind that way came straight back next time.
        do {
            let m = PanelModel()
            let (a, b) = (UUID(), UUID())
            m.showDraftRow(for: a)
            m.setDraft("buy milk", for: b)

            let discarded = m.discardUnusedDraftRows()
            r.equal("daily: only the unused row is taken away", discarded, [a])
            r.check("daily: and it is gone", !m.isDraftRowOpen(a))
            r.equal("daily: the one with text in it stays", m.draft(for: b), "buy milk")
        }

        do {
            let m = PanelModel()
            r.check("daily: nothing to discard to begin with",
                    m.discardUnusedDraftRows().isEmpty)
        }
    }
}
