import AppKit
import SwiftUI

/// The floating panel: a prompt on top, the list below, a key hint at the
/// bottom.
///
/// Layout and single-task row styling descend from Medo's `TasksListView` and
/// `SingleTaskView`, with the priority gradients, timestamps and context menus
/// removed in favour of the terminal look.
struct PanelView: View {
    @ObservedObject var store: TodoStore
    @ObservedObject var model: PanelModel
    let onClose: () -> Void

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var shortcutError: String?

    /// One line in the list: either a task, or the blank row under an expanded
    /// task where the next sub-task gets typed.
    ///
    /// The blank row is on screen only because something asked for it — Return
    /// or Tab on a task, or Return on a sub-task row — and it goes again the
    /// moment it is left unused. It is a row like any other while it is there:
    /// the arrow keys land on it and it can be highlighted.
    private enum ListRow: Identifiable {
        case task(TodoStore.Branch)
        case draft(parent: TodoStore.Branch)

        var id: UUID {
            switch self {
            case .task(let branch): return branch.item.id
            case .draft(let parent): return parent.item.id.draftRowID
            }
        }

        var depth: Int {
            switch self {
            case .task(let branch): return branch.depth
            case .draft(let parent): return parent.depth + 1
            }
        }
    }

    private var rows: [ListRow] {
        var out: [ListRow] = []

        // A depth-first walk of the whole tree, descending only into branches
        // that are open. `branches` rather than `visibleRows`, because this
        // needs the children in order to walk them — `visibleRows` has already
        // pruned the closed ones.
        func walk(_ branch: TodoStore.Branch) {
            out.append(.task(branch))
            guard branch.item.expanded else { return }
            branch.children.forEach(walk)
            // The blank row comes last, after everything already saved, so it
            // reads as "the next one" rather than as the first. It belongs to
            // an *opened* task, not to one that happens to have children:
            // opening a task with nothing under it yet is how you ask for a
            // sub-task in the first place, so the row has to be there before
            // there is anything to show. It stops at the depth limit, where
            // there is no deeper level to add.
            if branch.depth < TodoStore.maxDepth, model.isDraftRowOpen(branch.item.id) {
                out.append(.draft(parent: branch))
            }
        }

        store.branches.forEach(walk)
        return out
    }

    private var rowIDs: [UUID] { rows.map(\.id) }

    private var tasks: [TodoItem] { rows.compactMap { row in
        if case .task(let branch) = row { return branch.item }
        return nil
    } }

    /// The selected tasks, in the order they appear on screen.
    private var selectedItems: [TodoItem] {
        tasks.filter { model.isSelected($0.id) }
    }

    /// The task a row id belongs to, or `nil` for a blank sub-task row.
    ///
    /// Row ids are the thing the keyboard has; tasks are the thing everything
    /// else works in. A key that acts on a task — Return to edit it, the arrows
    /// to correct it — has to cross that gap, and a blank row has nothing on
    /// the other side of it.
    private func task(with id: UUID) -> TodoItem? {
        tasks.first { $0.id == id }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if model.showingSettings {
                    settingsHeader
                    Divider().overlay(Theme.border)
                    settingsBody
                } else {
                    inputBar
                    Divider().overlay(Theme.border)
                    list
                }
                footer
            }
        }
        .frame(width: PanelController.panelSize.width, height: PanelController.panelSize.height)
        .background(Theme.background)
        // The hairline that makes the panel an object rather than a hole.
        //
        // Drawn *over* the background and *before* the clip, so it sits on top of
        // everything — including the footer's own fill, which runs edge to edge
        // and would otherwise paint over it at the bottom corners. `strokeBorder`
        // rather than `stroke`: it draws inside the shape, so the panel stays
        // 460×540 to the pixel and nothing reflows.
        //
        // `Theme.border`, the same cool grey as the dividers inside the panel.
        // One hairline for the edge and the same one for the rows inside it is
        // what keeps the panel reading as one thing.
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(Theme.panelBorder, lineWidth: 1)
        )
        // The clip must come *after* the background. Previously the background
        // was a bare Color inside the ZStack, which filled the whole frame as a
        // square — so the rounded clip on the content behind it never had any
        // effect and the four corners stayed square no matter what.
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        // No `.shadow` here, and that is deliberate rather than a shortcut.
        //
        // A shadow is a blur spreading *outward* from the edge, and a window can
        // only draw inside itself. The window is exactly the size of the panel,
        // so the blur had nowhere to fall — and instead of being clipped it
        // displaced the panel by its own `y` offset. Measured off a screenshot:
        // the panel came out 17pt too low, its bottom two corners drawn outside
        // the window, with no shadow anywhere around it (the desktop was flat
        // right up to the edge). That is the dark wedge at the corners.
        //
        // Giving the shadow room would mean a window larger than the panel, and
        // the invisible band that comes with it swallows clicks near the panel —
        // including the click that dismisses whatever it is covering. The
        // hairline above earns the edge on its own, and costs none of that.
        .background(
            KeyCatcher(focusToken: model.listFocusToken, onKey: handleListKey)
                .frame(width: 0, height: 0)
        )
        .preferredColorScheme(.dark)
        .onChange(of: store.items) { _, _ in
            model.retainSelection(in: rowIDs)
            model.pruneDrafts(under: Set(store.items.map(\.id)))
            abandonCaretOnClosedBranch()
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            // Always green. A prompt marker that dims when the caret is
            // elsewhere says "you cannot type here", which is not true and is
            // not what the colour is for.
            Text(">")
                .font(Theme.promptFont)
                .foregroundStyle(Theme.accent)
                .frame(width: Theme.markerWidth, alignment: .leading)

            PromptField(
                fieldKey: PromptFields.root,
                text: $model.draft,
                focusToken: model.inputFocusToken,
                placeholder: "add a task",
                isEnabled: !model.showingSettings,
                onSubmit: submit,
                onMoveDown: enterList,
                // ↑ in the add-a-task bar jumps to the *last* row, matching
                // ↓ in the list jumping back here. ↓ used to be the only way
                // in, which made it the only way to reach the bottom of a
                // long list without walking the whole thing.
                onMoveUp: {
                    guard let last = rowIDs.last else { return }
                    activateRow(last)
                },
                // Nothing to dismiss here: Delete in an empty top prompt is
                // already a no-op, and letting it through would be the same.
                onDelete: {},
                onCancel: onClose,
                onClearSelection: { model.select(nil) },
                // Clicking straight into the prompt is not a focus request, so
                // without this the model goes on believing the keyboard is
                // wherever we last sent it.
                onEditingBegan: { model.adoptInputTarget(.root) }
            )
            .frame(height: 24)
        }
        .frame(height: 24)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if tasks.isEmpty {
            VStack(spacing: 10) {
                Text("nothing to do")
                    .font(Theme.monospaced)
                    .foregroundStyle(Theme.dim)
                Text("type above, then press return")
                    .font(Theme.monospacedSmall)
                    .foregroundStyle(Theme.dim.opacity(0.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            rowView(row)
                                .id(row.id)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: model.scrollTarget) { _, id in
                    // Only the arrow keys set this. Watching the selection
                    // instead meant clicking a row scrolled it to the middle
                    // of the panel — the pointer had just put the row under it,
                    // so the only thing the scroll accomplished was losing the
                    // rows either side of what you were reading.
                    guard let id else { return }
                    proxy.scrollTo(id, anchor: .center)
                    model.clearScrollTarget()
                }
            }
        }
    }

    /// Takes the keyboard off a blank sub-task row whose branch has closed.
    ///
    /// A branch can close with the caret still in its blank row — from the
    /// disclosure triangle, or from ⌘Z undoing the open — and the row is only
    /// drawn while the branch is open. So the field goes with it while the model
    /// goes on saying the keyboard is in there, and every keystroke after that
    /// is delivered to a text field that is not on screen: nothing is typed and
    /// nothing is heard. The view is the only place that knows the row is gone,
    /// so the reconciliation has to happen here.
    private func abandonCaretOnClosedBranch() {
        guard let parent = model.focusedDraftParent else { return }
        let stillOpen = store.items.first { $0.id == parent }?.expanded ?? false
        guard !stillOpen else { return }
        model.hideDraftRow(for: parent)
        model.requestInputFocus()
    }

    /// Take a blank sub-task row away when it is being left unused.
    ///
    /// Called from every route that moves the caret off one, not just the
    /// arrow keys in the list. Leaving a row via its own ↑/↓ went through
    /// `activateRow`, which never checked, so the row stayed behind after you
    /// had plainly decided not to use it.
    ///
    /// Model-only, and that is the point: nothing here touches the store, so it
    /// cannot leave a mark in the undo history. A blank row you looked at and
    /// walked away from must be as though it had never been opened, or ⌘Z would
    /// start undoing things that were never done.
    private func dismissUnusedBlankRow() {
        // The row being left is the one the caret is in, which is not the same
        // question as "which row is selected". `requestChildFocus` clears the
        // selection on the way in — deliberately, so a highlight cannot lie
        // about what the keys are about to do — and that means every route out
        // of a blank row arrived here with `focusedRow` nil and left the row
        // sitting on screen for good. Arrowing off an empty sub-task row was
        // supposed to take it away, and never did.
        let parent: UUID?
        if let focused = model.focusedDraftParent {
            parent = focused
        } else if let row = model.focusedRow {
            parent = draftParent(for: row)
        } else {
            parent = nil
        }

        guard let parent, model.draftIsBlank(parent) else { return }
        hideDraftRow(for: parent)
    }

    /// Takes a blank sub-task row away, and drops the parent's "opened" flag if
    /// there is nothing left under it.
    ///
    /// Adding a task opens it so the caret can drop into a row beneath it, and
    /// that flag was never taken back. Every task ever added kept a permanent
    /// green `v` down the right-hand edge and an `"expanded": true` in the file,
    /// including the great majority that never had a sub-task — so a plain list
    /// of thirty reminders looked like a tree, and the marker claimed there was
    /// something in here when there was not.
    ///
    /// Every route that hides a row goes through here, because the flag and the
    /// row are the same decision.
    private func hideDraftRow(for parent: UUID) {
        model.hideDraftRow(for: parent)
        store.collapseIfChildless(id: parent)
    }

    /// Put the keyboard on a row: a task takes the list, a blank sub-task row
    /// takes the caret.
    private func activateRow(_ id: UUID) {
        if let editing = model.editing, editing != id {
            commitEdit()
        }
        if draftParent(for: id) == nil {
            dismissUnusedBlankRow()
        }
        if let parent = draftParent(for: id) {
            model.requestChildFocus(parent)
        } else {
            model.select(id)
            model.enterList()
        }
    }

    @ViewBuilder
    private func rowView(_ row: ListRow) -> some View {
        switch row {
        case .task(let branch):
            taskRow(branch, isSelected: model.isSelected(branch.item.id))
        case .draft(let parent):
            draftRow(parent, isSelected: model.isSelected(parent.item.id.draftRowID))
        }
    }

    /// The blank row under an expanded task, where the next sub-task is typed.
    ///
    /// It is inline in the list rather than in the top bar, because reaching a
    /// sub-task with ↓ and starting to type has to be one continuous motion. A
    /// draft that was already half-written stays where it is when the branch is
    /// collapsed and opened again.
    private func draftRow(_ parent: TodoStore.Branch, isSelected: Bool) -> some View {
        let id = parent.item.id
        let isFocused = model.inputTarget == .child(id)
        let hasChildren = parent.children.count > 0

        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(">")
                .font(Theme.promptFont)
                .foregroundStyle(Theme.accent)
                .frame(width: Theme.markerWidth, alignment: .leading)

            PromptField(
                fieldKey: PromptFields.child(id),
                text: Binding(
                    get: { model.draft(for: id) },
                    set: { model.setDraft($0, for: id) }
                ),
                focusToken: isFocused ? model.childFocusToken : 0,
                placeholder: hasChildren ? "add another sub task" : "add a sub task",
                isEnabled: isFocused,
                // Return saves this one and leaves a fresh blank row
                // underneath, for writing several in a row without arrowing.
                onSubmit: { commitDraft(under: id) },
                // ⇧Return is the same verb, not a second one. It used to be the
                // only key that stayed in the row, so it is an alias now.
                onSubmitAndContinue: { commitDraft(under: id) },
                onMoveDown: {
                    // Down steps to the row below, and off the bottom of the
                    // list into the add-a-task bar. Handing the keyboard to the
                    // list wholesale put the caret on the *first* task, so ↓
                    // from a sub-task at the bottom threw you back to the top
                    // instead of stepping down.
                    let blankRow = id.draftRowID
                    if let index = rowIDs.firstIndex(of: blankRow), index + 1 < rowIDs.count {
                        activateRow(rowIDs[index + 1])
                    } else {
                        // Stepping off the end is still *leaving the row*, so an
                        // untouched one goes with it.
                        dismissUnusedBlankRow()
                        model.requestInputFocus()
                    }
                },
                onMoveUp: {
                    // Up from a blank sub-task row goes to the row above it —
                    // normally the sub-task you just added, not the parent.
                    // Jumping straight to the parent skipped over everything
                    // you had just written, so ↑ could not be used to edit the
                    // sub-task you were looking at.
                    // `id` here is the parent's; the row this handler belongs
                    // to is the blank one, whose id is derived from it. Using
                    // the parent directly found row 0 and sent ↑ back to the
                    // top of the list, which is what it did before.
                    let blankRow = id.draftRowID
                    // A blank row is always preceded by its own parent, so
                    // there is always something above it — but indexing is
                    // indexing, and an empty list should walk away quietly
                    // rather than trap.
                    guard !rowIDs.isEmpty else { return }
                    let above = rowIDs[max(0, (rowIDs.firstIndex(of: blankRow) ?? 1) - 1)]
                    activateRow(above)
                },
                onDelete: { eraseBlankRow(for: id) },
                onCancel: {
                    // Escape leaves the row like any other route out of it, so an
                    // empty one disappears instead of sitting under the branch
                    // for the rest of the session.
                    dismissUnusedBlankRow()
                    model.requestInputFocus()
                },
                onClearSelection: { model.clearSelection() },
                onEditingBegan: { model.adoptInputTarget(.child(id)) }
            )
            .frame(height: 24)
        }
        .font(Theme.monospaced)
        .padding(.leading, 16 + CGFloat(parent.depth + 1) * Theme.indentWidth)
        .padding(.trailing, 16)
        .padding(.vertical, 6)
        .background(isSelected ? Theme.selection : Color.clear)
        // The same rule down the indent that a saved sub-task draws, so the
        // line does not break for one row's height at the blank one — which is
        // the row you are being invited to type into, and the last place the
        // branch should stop reading as a branch.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.border)
                .frame(width: 1)
                .padding(.leading, 16 + CGFloat(parent.depth) * Theme.indentWidth + 6)
        }
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(Theme.accent).frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        // Clicking the row puts the caret in it. Without this the only way in
        // was Tab, so after arrowing past it the field could not be reached
        // with the pointer at all.
        .onTapGesture { model.requestChildFocus(id) }
    }

    private func taskRow(_ branch: TodoStore.Branch, isSelected: Bool) -> some View {
        let item = branch.item
        let isEditing = model.editing == item.id
        // Only a task with something under it gets an arrow.
        //
        // It used to be `item.expanded || hasChildren`, which drew a green `v`
        // on every task ever added — adding opened a task so the caret could
        // drop beneath it — including the great majority that never had a
        // sub-task. A list of thirty reminders looked like a tree, and the
        // marker claimed there was something in here when there was not. The
        // "opened" flag is real state; it is just not a reason to draw
        // something.
        let expandable = store.hasChildren(item.id) && branch.depth < TodoStore.maxDepth

        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            // The marker is its own button, so clicking the brackets ticks the
            // task without also moving the selection.
            Button {
                store.toggle(id: item.id)
            } label: {
                Text(item.done ? "[x]" : "[]")
                    .foregroundStyle(item.done ? Theme.accent : Theme.dim)
                    .frame(width: Theme.markerWidth, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Wraps rather than truncating. `lineLimit(1)` was cutting long
            // tasks off with an ellipsis, which hides exactly the part you need
            // to read before deciding what to do with it. Sub-tasks get the same
            // treatment; the indent eats into the width, which is the cost of
            // nesting and the reason it stops at three levels.
            if isEditing {
                titleEditor(item)
            } else {
                Text(item.title)
                    .strikethrough(item.done, color: Theme.dim)
                    .foregroundStyle(item.done ? Theme.dim : Theme.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)

            // The disclosure sits at the far right, the way a tree view puts it,
            // and only on a task that actually has something underneath.
            if expandable {
                Button {
                    toggleExpanded(item)
                } label: {
                    // The one marker that carries state: green while the branch
                    // is open, grey while it is closed. Tying it to where the
                    // caret was made it grey the moment you arrowed away, which
                    // read as "this list is closed" when it was not.
                    Text(item.expanded ? "v" : ">")
                        .font(Theme.monospaced)
                        .foregroundStyle(item.expanded ? Theme.accent : Theme.dim)
                        .frame(width: 12, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(Theme.monospaced)
        .padding(.leading, 16 + CGFloat(branch.depth) * Theme.indentWidth)
        .padding(.trailing, 16)
        .padding(.vertical, 6)
        .background(isSelected ? Theme.selection : Color.clear)
        // A rule down the indent, so a run of sub-tasks reads as belonging to
        // the task above them.
        //
        // Indent alone was not enough. Eighteen points is a nudge, not a
        // grouping: by the third sub-task the parent is off the top of what you
        // are looking at and the rows read as loose items that happen to sit a
        // little further right. A tree view solves this with a guide line, and
        // the reason it works is that it is continuous — you read membership
        // from the line, not from measuring the text.
        .overlay(alignment: .leading) {
            if branch.depth > 0 {
                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 1)
                    .padding(.leading, 16 + CGFloat(branch.depth - 1) * Theme.indentWidth + 6)
            }
        }
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(Theme.accent).frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        // SwiftUI's tap gesture does not report modifiers, so the live global
        // state is read instead — the same thing a native list view does.
        //
        // Clicking a row that is *already* highlighted opens it for editing.
        // Not a double-click: by the time the second click arrived the row had
        // been selected by the first, so the gesture was really "select, then
        // edit", wearing a hat that made it feel like something else — and
        // double-click is not available on a trackpad without a deliberate
        // second press. A first click still only selects; ⌘-click and
        // ⇧-click are about what is in the selection and never edit.
        .onTapGesture {
            let modifiers = NSEvent.modifierFlags
            let plain = !modifiers.contains(.command) && !modifiers.contains(.shift)
            if plain, model.isSelected(item.id), model.focusedRow == item.id {
                beginEditing(item, caret: .end)
            } else {
                selectWithMouse(item.id, modifiers: modifiers)
            }
        }
        .contextMenu {
            Button(item.done ? "mark as not done" : "mark as done") {
                store.toggle(id: item.id)
            }
            if !isEditing {
                Button("edit title") { beginEditing(item, caret: .end) }
            }
            if expandable {
                Button(item.expanded ? "close sub tasks" : "open sub tasks") {
                    toggleExpanded(item)
                }
            }
            Divider()
            Button("delete", role: .destructive) { delete(id: item.id) }
        }
    }


    /// Clicking a row selects it *and* hands the keyboard to the list, so Space
    /// and Delete afterwards act on whatever the pointer just picked.
    ///
    /// Without the hand-off the caret is still sitting in the prompt, so Space
    /// would type a space into a draft instead of ticking the task. It is
    /// skipped while a draft is being typed, so clicking a task mid-sentence
    /// does not pull the keyboard away mid-word.
    ///
    /// The test is the text in the field the caret is actually in, not the one
    /// at the top: the panel has two, and only the top one used to be
    /// consulted — so typing a sub-task and clicking a task pulled the keyboard
    /// away mid-word anyway.
    private func selectWithMouse(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        // Clicking somewhere else is committing an open correction, the same as
        // clicking away in any list. Left open it would sit there looking
        // editable long after you had moved on, with the caret nowhere.
        if let editing = model.editing, editing != id {
            commitEdit()
        }
        if draftParent(for: id) == nil {
            dismissUnusedBlankRow()
        }
        if modifiers.contains(.command) {
            model.toggleInSelection(id)
        } else if modifiers.contains(.shift) {
            model.extendSelection(to: id, in: rowIDs)
        } else {
            model.select(id)
        }
        if model.focusedText.isEmpty {
            model.enterList()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(countLabel)

            Spacer(minLength: 0)

            Text(hint)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            SettingsButton(isOpen: model.showingSettings) { toggleSettings() }
        }
        .font(Theme.monospacedSmall)
        .foregroundStyle(Theme.dim)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Theme.surface)
    }

    /// What is outstanding.
    ///
    /// Shows the finished count as soon as there are any, because that is the
    /// moment they become something you want to throw away — and the hint
    /// beside it is the only place the key that does it can be advertised.
    private var countLabel: String {
        store.doneCount > 0 ? "\(store.openCount) open · \(store.doneCount) done" : "\(store.openCount) open"
    }

    private var hint: String {
        if model.showingSettings { return "esc to go back" }
        if model.mode == .input { return "↓ list · esc close" }

        // Only the verbs that are not guessable: ↑↓, Space and ⌫ say what they
        // do, and each of them is written on a row. Enter and ⇧Enter mean
        // something new here, and neither is written anywhere.
        //
        // The short form of the plan's wording, because the long one does not
        // fit: measured at 11pt monospaced this row has 394pt for the count and
        // the hint together, and "↵ sub task · ⇧↵ edit · tab · space · esc" plus
        // "· ⇧⌫ clear done" is 462pt with a two-digit count — so `lineLimit(1)`
        // would have clipped it, which is the bug the shortened form exists to
        // avoid. This one is 374pt, which fits.
        var text = "↵ sub · ⇧↵ edit · tab · esc"
        if store.doneCount > 0 {
            text += " · ⇧⌫ clear done"
        }
        return text
    }

    /// Header shown in place of the prompt while settings are open.
    private var settingsHeader: some View {
        HStack(spacing: 8) {
            Text(">")
                .font(Theme.promptFont)
                .foregroundStyle(Theme.accent)
                .frame(width: Theme.markerWidth, alignment: .leading)
            // Dimmed to match the `add a task` placeholder. Both rows stand in
            // for the same thing — a line you type into — so they should not
            // differ in brightness when you move between them.
            Text("settings")
                .font(Theme.promptFont)
                .foregroundStyle(Theme.dim)
            Spacer(minLength: 0)
        }
        // Without this the header is two `Text`s and therefore ~17pt tall,
        // while the prompt row is 50pt because it wraps a 24pt text field. The
        // 7pt difference put the header and its divider visibly higher.
        .frame(height: 24)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    /// Settings fill the content area, stacked from the top and scrollable so
    /// that adding more rows later cannot push them out of reach or overlap the
    /// footer. The scroll indicator is hidden to match the task list.
    private var settingsBody: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        launchAtLogin.toggle()
                        do {
                            try LoginItem.setEnabled(launchAtLogin)
                            Diag.log("launch at login: \(launchAtLogin)")
                        } catch {
                            // Snap the marker back — the change did not happen.
                            launchAtLogin = LoginItem.isEnabled
                            loginError = error.localizedDescription
                        }
                    } label: {
                        Text(launchAtLogin ? "[x]" : "[]")
                            .font(Theme.settingsLabel)
                            .foregroundStyle(launchAtLogin ? Theme.accent : Theme.dim)
                            .frame(width: Theme.markerWidth, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    Text("start at login")
                        .font(Theme.settingsLabel)
                        .foregroundStyle(Theme.primary)
                }

                // Inset to the content margin, ending flush with the text
                // below it. Running it edge to edge made it read as a line
                // cutting across the whole panel.
                Divider().overlay(Theme.border)

                shortcutRow("open todo", role: .open)
                shortcutRow("quit todo", role: .quit)

                if let loginError {
                    errorText(loginError)
                }
                if let shortcutError {
                    errorText(shortcutError)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            // 12, not 14: a task row sits 6pt of scroll padding plus 6pt of
            // row padding below the divider. 14 put every settings row 2pt
            // below the first task, which read as misaligned.
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
    }

    /// Label on the left, recorder on the right, on one line — the same shape
    /// as the toggle above it.
    private func shortcutRow(_ label: String, role: HotKeyCenter.Conflict.Role) -> some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: Theme.markerWidth, height: 1)
            Text(label)
                .font(Theme.settingsLabel)
                .foregroundStyle(Theme.primary)
                .frame(width: 88, alignment: .leading)
            KeyRecorder(
                role: role,
                onConflict: { shortcutError = $0 },
                isActive: model.showingSettings
            ) {
                // Recording ends with the keyboard still in the invisible
                // capture view. Give it back to the panel, which is what makes
                // Escape close the drawer afterwards.
                model.enterList()
            }
        }
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Theme.danger)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Behaviour

    /// Enter at the top prompt.
    ///
    /// Saves the task and leaves the caret where it is. It used to save the task
    /// *and* open it *and* drop the caret into a sub-task row under it, so
    /// adding three reminders left the list full of opened branches with nothing
    /// in them, an arrow on every row, and the keyboard somewhere nobody had
    /// asked it to be.
    ///
    /// Enter is "one more thing", so it stays here and the next Enter is the
    /// next thing. Sub-tasks are asked for: ↵ on a highlighted task, or Tab.
    private func submit() {
        let text = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.draft = ""
        store.add(text)
    }

    private func enterList() {
        // Land on something selected so the highlight has somewhere to start.
        // One row, even when it is a task with sub-tasks: ↓ into the list is a
        // navigation step, not a request for the whole branch.
        if model.selection.isEmpty, let first = rowIDs.first {
            model.select(first)
        }
        model.enterList()
    }

    private func toggleSettings() {
        model.showingSettings.toggle()
        if model.showingSettings {
            // Re-read on open: the state can be changed behind our back in
            // System Settings ▸ Login Items, and a stale switch would lie.
            launchAtLogin = LoginItem.isEnabled
            loginError = nil
            shortcutError = nil
            // Hand the keyboard to the list, not the prompt: the prompt is
            // disabled behind the drawer, and Escape has to reach the handler
            // that closes the drawer rather than the whole panel.
            model.enterList()
        } else {
            model.requestInputFocus()
        }
    }

    /// Keys while the list has focus.
    private func handleListKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // With settings showing, the list is not on screen — only leave.
        if model.showingSettings {
            if Int(event.keyCode) == Int(KeyCode.escape) {
                model.showingSettings = false
                model.requestInputFocus()
            }
            return true
        }

        let command = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)

        // Undo and redo are handled by an event monitor in PanelController so
        // they work from the prompt too. Select all is list-specific.
        if command, event.charactersIgnoringModifiers == "a" {
            model.selectAll(rowIDs)
            return true
        }

        // Everything below acts on the selection, and every one of them is
        // meant to be a bare keystroke. A combination that got here with
        // ⌃⌥ or ⌘ still held is somebody else's shortcut — ⌥Space most of all,
        // which is this app's own global hotkey and can only be reaching the
        // panel if it failed to register. Acting on it would tick whatever
        // happened to be selected, or throw the selection away.
        guard !command,
              !modifiers.contains(.control),
              !modifiers.contains(.option)
        else { return false }

        switch Int(event.keyCode) {
        case Int(KeyCode.arrowDown):
            // Down off the bottom row goes back to the add-a-task bar, so the
            // list is a loop you can walk out of at either end. Stopping dead
            // at the last task left the keyboard with nowhere to go but Esc.
            if !shift, model.isAtBottom(of: rowIDs) {
                // Leaving the list is leaving the row too, so an untouched
                // blank row at the very bottom goes with it.
                dismissUnusedBlankRow()
                model.requestInputFocus()
                return true
            }
            moveSelection(by: 1, extending: shift)
            return true

        case Int(KeyCode.arrowUp):
            // Up from the very top goes back to the add-a-task bar. Tab used to
            // be the way out of the list, and it now means "sub-tasks", so
            // without this there would be no keyboard route back to the prompt.
            if !shift, model.isAtTop(of: rowIDs) {
                model.requestInputFocus()
                return true
            }
            moveSelection(by: -1, extending: shift)
            return true

        case Int(KeyCode.space):
            tickSelection()
            return true

        case Int(KeyCode.delete), Int(KeyCode.forwardDelete):
            // Shift+Delete throws away everything already finished. Ticking is
            // one keystroke and this is the only thing that undoes a day of
            // it; without it the list fills with struck-through rows and the
            // work still to do gets pushed off the bottom of the panel.
            if shift {
                store.clearCompleted()
                model.select(nil)
                return true
            }

            // Delete on a blank sub-task row takes the row away rather than the
            // task above it. It used to remove the last sub-task, which is the
            // opposite of what the key means everywhere else in a text field.
            //
            // Only when that row is the whole selection. ⌘A puts the moving end
            // of the selection on the *last* row, which is a blank sub-task row
            // whenever one is open — so ⌘A then ⌫ erased a stray prompt and
            // left every selected task standing, which is the precise opposite
            // of what the two keys together say.
            if selectedItems.isEmpty,
               let id = model.focusedRow,
               let parent = draftParent(for: id) {
                eraseBlankRow(for: parent)
                return true
            }
            deleteSelected()
            return true

        case Int(KeyCode.tab):
            tabPressed()
            return true

        case Int(KeyCode.returnKey) where shift:
            // Shift+Enter corrects the highlighted task's title, caret at the
            // end. The one that used to do this — "add a sub-task under whatever
            // is highlighted" — is plain Enter now, which is what a row of
            // things inside a task should be reached by.
            //
            // A blank sub-task row is not a task, so there is no title to
            // correct. In practice the caret is in that field whenever the row
            // is on screen, so this never gets here; consuming the key rather
            // than falling through keeps it from meaning something else.
            guard let id = model.focusedRow, draftParent(for: id) == nil,
                  let item = task(with: id) else { return true }
            beginEditing(item, caret: .end)
            return true

        case Int(KeyCode.arrowLeft), Int(KeyCode.arrowRight):
            // ← and → correct the title, with the caret at whichever end you
            // are pointing at: the last word, or the first. A typo at the end
            // of a title is the common one, and putting the caret at the start
            // of the row would send the letters meant for the end to the front.
            //
            // Arrows in a list move the selection everywhere else, so the one
            // thing this must never do is move it here — hence the return
            // rather than letting them fall through.
            guard let id = model.focusedRow else { return true }
            if draftParent(for: id) != nil {
                // A blank row has no title; the caret belongs in it, which is
                // also where arrowing onto a row from the list would have put
                // it.
                activateRow(id)
                return true
            }
            guard let item = task(with: id) else { return true }
            beginEditing(item, caret: Int(event.keyCode) == Int(KeyCode.arrowRight) ? .end : .start)
            return true

        case Int(KeyCode.returnKey):
            // Enter opens the blank sub-task row under whatever is highlighted,
            // caret and all. On a sub-task that resolves through to its parent,
            // so it adds a *sibling* rather than a third level.
            //
            // This is the only way to start a sub-task now that Tab on a
            // childless task does the same thing rather than being the only way
            // — two roads to one place, not two jobs.
            if let id = model.focusedRow {
                let target = draftParent(for: id) ?? store.parentForNewSubtask(of: id)
                if let target {
                    // `openWithoutHistory`, not `setExpanded`: what is being
                    // opened is a prompt to type into, not a change to the list.
                    // The row below is empty far more often than not, and an
                    // undo step for an open that was then abandoned would make
                    // the first ⌘Z after adding a task do nothing at all.
                    store.openWithoutHistory(id: target)
                    model.showDraftRow(for: target)
                    model.requestChildFocus(target)
                    return true
                }
            }
            // Nothing highlighted: there is no task to put a sub-task under, so
            // the only sensible place for the keyboard is back at the prompt.
            model.requestInputFocus()
            return true

        case Int(KeyCode.escape):
            // Escape is "I'm done with the list": drop the highlight and hand
            // the caret back. Enter used to mean this and now means something
            // else, and a selection left showing while the caret is in the
            // prompt claims the next keypress will act on that task, which is no
            // longer true.
            dismissUnusedBlankRow()
            model.requestInputFocus()
            return true

        default:
            return false
        }
    }

    /// Moves the selection and, if it lands on a blank sub-task row, puts the
    /// caret in that field rather than on the list.
    private func moveSelection(by offset: Int, extending: Bool) {
        // Moving away takes a blank row with it, unless something was typed into
        // it. A row you never used should not still be sitting under the list
        // just because you looked at the sub-tasks above it.
        if !extending {
            dismissUnusedBlankRow()
        }
        model.moveSelection(by: offset, extending: extending, in: rowIDs)
        if !extending, let id = model.focusedRow {
            activateRow(id)
        }
    }

    /// The parent a blank row belongs to, or `nil` if the id is a real task.
    private func draftParent(for id: UUID) -> UUID? {
        store.parentOfDraftRow(id)
    }

    /// Tab on a task with nothing under it turns it into a list; on anything
    /// else it opens or closes the branch it already is.
    ///
    /// The first half is new. Tab used to be three things at once — toggle, and
    /// *create* a sub-task row when the task had none — which meant one key was
    /// doing two unrelated jobs and the only way to tell which had happened was
    /// to look at the screen. Flipping a flag on a task with nothing under it
    /// drew nothing at all, so Tab on a plain task looked broken.
    ///
    /// On a childless task there is nothing to open or close, so it does the
    /// other useful thing instead: open the branch and put the caret in a blank
    /// row beneath it. Enter does the same thing — two roads to one place,
    /// which is why neither key is doing the other's job.
    private func tabPressed() {
        guard let focused = model.focusedRow else {
            model.requestInputFocus()
            return
        }

        // A blank sub-task row is not a task, so it has no branch to open or
        // close — but the branch it belongs to does, and Tab there means "open
        // or close this one". Resolving through to the parent is also what
        // keeps ⌘A then Tab working: select-all puts the selection's moving end
        // on the *last* row, which is a blank row whenever one is open, so the
        // old guard below sent the key back to the prompt and threw the whole
        // selection away instead of toggling anything.
        let id = draftParent(for: focused) ?? focused

        // A sub-task has no branch of its own, so there is nothing for Tab to
        // open. The store refuses rather than flipping a flag nothing reads —
        // which would otherwise cost a ⌘Z press on a keystroke that changed
        // nothing on screen.
        guard store.canToggleExpanded(id: id) else {
            model.requestInputFocus()
            return
        }

        if !store.hasChildren(id) {
            // As in the Return path above: this open exists so a row can be typed
            // into, and an abandoned row is not a change worth an undo step.
            store.openWithoutHistory(id: id)
            model.showDraftRow(for: id)
            model.requestChildFocus(id)
            return
        }

        // Closing takes the blank row with it: "show me this task's sub-tasks"
        // should not leave a stray prompt sitting in among them. Opening leaves
        // it be — if it was open a moment ago it is open now.
        if !store.toggleExpanded(id: id) {
            hideDraftRow(for: id)
        }
        // Stay on the row, in the list. The caret does not move to a sub-task
        // row because Tab is not what makes one here.
        model.select(id)
        model.enterList()
    }

    /// Turns the half-typed sub-task into a real one.
    ///
    /// Return saves it and stays, with a fresh blank row underneath for the next
    /// one — writing three sub-tasks is Return, Return, Return rather than
    /// Return, Return, Return, Escape. ⇧Return does exactly the same thing: it
    /// used to be the only key that kept you in the row, so it is an alias now
    /// rather than a different verb, and there is no reason to learn two.
    ///
    /// An *empty* row is the way out: it is taken away and the caret goes back
    /// to the add-a-task bar. It used to go through `eraseBlankRow`, which ends
    /// in `enterList()`, so the keyboard stayed among the tasks and the next
    /// letter typed was a command: Space ticked something, ⌫ deleted it.
    private func commitDraft(under parent: UUID) {
        let text = model.draft(for: parent)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            model.clearDraft(for: parent)
            hideDraftRow(for: parent)
            model.requestInputFocus()
            return
        }

        // Refused means the parent is gone or is already at the depth limit, and
        // there is nothing to save it under. Leave the row and the text exactly
        // as they are: clearing them and then asking for the caret would put the
        // keyboard in a field that is never going to exist.
        guard store.addSubtask(trimmed, under: parent) else { return }

        model.clearDraft(for: parent)
        model.showDraftRow(for: parent)
        model.requestChildFocus(parent)
    }

    /// The row's title, editable in place.
    ///
    /// The same `PromptField` the prompt bar uses, rather than a new kind of
    /// control, so it behaves like every other field in the app: Return saves,
    /// Escape puts it back, ⌘A selects the text, ⌘Z undoes what you typed.
    /// A second, subtly different text control would be a second set of bugs.
    ///
    /// Drawn at the row's own size. `PromptField` defaults to the prompt's
    /// 14pt medium, and rows are 13.5pt regular — so switching a task into edit
    /// mode visibly grew the text and shifted the row's baseline under the
    /// caret. It has to look like the same row with a cursor in it.
    private func titleEditor(_ item: TodoItem) -> some View {
        PromptField(
            fieldKey: PromptFields.edit(item.id),
            text: Binding(
                get: { model.editDraft },
                set: { model.setEditDraft($0) }
            ),
            focusToken: model.editFocusToken,
            placeholder: "",
            font: Theme.rowFont,
            // Asked for after the field has the keyboard, or AppKit's own
            // select-all-on-focus would wipe it: opening a title to fix its
            // last word arrived with the whole title selected.
            initialCaret: model.editCaretOffset,
            isEnabled: true,
            onSubmit: { commitEdit() },
            onMoveDown: { commitEdit() },
            onMoveUp: { commitEdit() },
            onDelete: {},
            onCancel: { cancelEdit() },
            onClearSelection: {},
            onEditingBegan: { model.adoptInputTarget(.edit(item.id)) }
        )
        .frame(height: 20)
    }

    private func beginEditing(_ item: TodoItem, caret: PanelModel.EditCaret) {
        // Commit whatever was open — but *not* through `commitEdit`, which ends
        // by handing the keyboard to the list. This function is about to give
        // the keyboard to the editor, and two focus requests in one turn is a
        // race: the list catcher and the field both ask, on the next runloop
        // turn, and whichever block lands last wins. When it was the list, the
        // row showed a caret that could not be typed into and the next keypress
        // was a command against the list.
        if let open = model.editing {
            let text = model.editDraft
            model.endEditing()
            store.rename(id: open, to: text)
        }
        dismissUnusedBlankRow()
        model.beginEditing(id: item.id, title: item.title, caret: caret)
    }

    private func commitEdit() {
        guard let id = model.editing else { return }
        let text = model.editDraft
        model.finishEditing()
        store.rename(id: id, to: text)
    }

    private func cancelEdit() {
        guard model.editing != nil else { return }
        model.cancelEditing()
        model.enterList()
    }

    /// Space, on whatever is selected.
    ///
    /// Roots only: ticking a parent leaves what is under it alone.
    ///
    /// And then the keyboard moves on. This is the single most repeated action
    /// in the app — working down a day's list, Space, Space, Space — and it
    /// used to be impossible to do. Ticking sinks the task to the finished
    /// group at the bottom, the highlight followed it down, and the list then
    /// scrolled to follow the highlight: one keystroke at the top of the list
    /// threw you to the bottom of it. Space again un-ticked the task and threw
    /// you back. You could tick exactly one task and then you were lost.
    ///
    /// Leaving the highlight on the row that took its place is what makes the
    /// repeat possible. It is the same rule `deleteSelected` already used for
    /// deletes, and it keeps the guarantee the highlight-follows-the-task rule
    /// exists for: the row under the green edge is always the row the next
    /// keystroke will act on, never one you have to go and find again.
    private func tickSelection() {
        let ids = selectedItems.map(\.id)
        guard !ids.isEmpty else { return }

        // Where the highlight should end up, worked out *before* the tick:
        // the slot the ticked task is vacating.
        guard let slot = tasks.firstIndex(where: { ids.contains($0.id) }) else { return }

        store.toggleRoots(ids: ids)

        // Only for a single task. After a mass tick there is no "next" — every
        // selected row has just moved to the bottom at once — so the selection
        // is left exactly where it was.
        guard ids.count == 1 else { return }

        // `tasks` again rather than a copy taken before the tick: the rule is
        // about the list as it is now, and it also has to step back when the
        // tick moved nothing. See `PanelModel.selectionAfterChange`.
        model.select(model.selectionAfterChange(
            slot: slot,
            change: .ticked,
            changed: ids,
            after: tasks.map(\.id)
        ))
    }

    /// Takes an unused blank sub-task row away, leaving the branch and the
    /// sub-tasks already saved under it alone, and puts the highlight on the
    /// last row of that branch.
    ///
    /// Closing the branch would have hidden the sub-tasks as well, which is a
    /// different thing: this is about a stray prompt sitting under a list you
    /// are reading. Tab or ↵ brings the row back, and so does adding a
    /// sub-task.
    private func eraseBlankRow(for parent: UUID) {
        // Never throw away something half-typed.
        //
        // Trimmed, because `commitDraft` decides "nothing written" on the
        // trimmed text and this guard was testing the raw one. Two spaces in the
        // row therefore satisfied neither: Return refused to save a blank task,
        // Delete refused to remove the row, and ⌫ could not rescue it either —
        // `PromptField` only reports a delete when the field is *completely*
        // empty, so with characters to erase it went back to the field. The row
        // was stuck.
        guard model.draftIsBlank(parent) else { return }
        model.clearDraft(for: parent)
        hideDraftRow(for: parent)
        // Hand the highlight to the branch the row belonged to, so Delete from
        // the list lands on a task rather than on nothing. Matching on the task
        // itself, rather than on ids, is what makes an actual sub-task match.
        let last = rows.last { row in
            guard case .task(let branch) = row else { return false }
            return branch.item.id == parent || branch.item.parentID == parent
        }
        model.select(last?.id)
        model.enterList()
    }

    /// The triangle and the right-click menu: open or close the branch.
    ///
    /// Closing takes the blank row with it, exactly as Tab does. Without that,
    /// the row is dropped from the view while the model still says the caret is
    /// in it — and a caret in a field that is no longer there swallows every key
    /// that follows, so the panel goes deaf until something else is clicked.
    private func toggleExpanded(_ item: TodoItem) {
        let opening = !item.expanded
        store.setExpanded(opening, id: item.id)
        if !opening { hideDraftRow(for: item.id) }
    }

    /// Deletes everything selected, as one undoable step.
    private func deleteSelected() {
        guard let slot = model.focusedRow.flatMap({ id in
            tasks.firstIndex(where: { $0.id == id })
        }) ?? selectedItems.first.flatMap({ item in
            tasks.firstIndex(where: { $0.id == item.id })
        }) else { return }

        let ids = selectedItems.map(\.id)
        store.delete(ids: ids)

        // `tasks` after the delete, not "the old list minus these ids": deleting
        // a parent takes its sub-tasks with it, and those were never selected.
        model.select(model.selectionAfterChange(
            slot: slot,
            change: .deleted,
            changed: ids,
            after: tasks.map(\.id)
        ))
    }

    /// Single-task delete, from the row's right-click menu.
    private func delete(id: UUID) {
        guard let slot = tasks.firstIndex(where: { $0.id == id }) else { return }
        store.delete(id: id)
        model.select(model.selectionAfterChange(
            slot: slot,
            change: .deleted,
            changed: [id],
            after: tasks.map(\.id)
        ))
    }
}

/// The gear in the footer. Toggles the settings section in place.
private struct SettingsButton: View {
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOpen ? "gearshape.fill" : "gearshape")
                .font(.system(size: 10))
                .foregroundStyle(isOpen ? Theme.primary : Theme.dim)
        }
        .buttonStyle(.plain)
    }
}