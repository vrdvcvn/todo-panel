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
    /// The blank row is on screen from the moment a branch opens and stays
    /// there even after Escape, so it is a row like any other — the arrow keys
    /// land on it and it can be highlighted.
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
            // pressing Tab on a task with nothing under it yet is how you ask
            // for a sub-task in the first place, so the row has to be there
            // before there is anything to show. It stops at the depth limit,
            // where there is no deeper level to add.
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
        // The clip must come *after* the background. Previously the background
        // was a bare Color inside the ZStack, which filled the whole frame as a
        // square — so the rounded clip on the content behind it never had any
        // effect and the four corners stayed square no matter what.
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.55), radius: 40, x: 0, y: 18)
        .background(
            KeyCatcher(focusToken: model.listFocusToken, onKey: handleListKey)
                .frame(width: 0, height: 0)
        )
        .preferredColorScheme(.dark)
        .onChange(of: store.items) { model.retainSelection(in: rowIDs) }
        // `onChange` does not fire for the initial value, so a panel opened
        // with `--settings` would never ask to be resized.
        
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
                // ↑ in the add-a-task bar is "caret to the start of the line",
                // which is the normal thing to want there, so this does nothing.
                onMoveUp: {
                    // ↑ in the add-a-task bar jumps to the *last* row, matching
                    // ↓ in the list jumping back here. ↓ used to be the only way
                    // in, which made it the only way to reach the bottom of a
                    // long list without walking the whole thing.
                    guard let last = rowIDs.last else { return }
                    activateRow(last)
                },
                // Nothing to dismiss here: Delete in an empty top prompt is
                // already a no-op, and letting it through would be the same.
                onDelete: {},
                onCancel: onClose,
                onClearSelection: { model.select(nil) }
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
        if tasks.isEmpty && store.branches.isEmpty {
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
                .onChange(of: model.selection) { _, newValue in
                    // Follow the topmost selected row, not whichever one
                    // happened to change last.
                    guard let id = rows.first(where: { newValue.contains($0.id) })?.id else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
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
        guard let id = model.focusedRow,
              let parent = draftParent(for: id),
              model.draft(for: parent).isEmpty else { return }
        model.hideDraftRow(for: parent)
    }

    /// Put the keyboard on a row: a task takes the list, a blank sub-task row
    /// takes the caret.
    private func activateRow(_ id: UUID) {
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
                onSubmit: { commitDraft(under: id, keepGoing: false) },
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
                    let above = rowIDs[max(0, (rowIDs.firstIndex(of: blankRow) ?? 1) - 1)]
                    activateRow(above)
                },
                onDelete: { eraseBlankRow(for: id) },
                onCancel: { model.requestInputFocus() },
                onClearSelection: { model.clearSelection() }
            )
            .frame(height: 24)
        }
        .font(Theme.monospaced)
        .padding(.leading, 16 + CGFloat(parent.depth + 1) * Theme.indentWidth)
        .padding(.trailing, 16)
        .padding(.vertical, 6)
        .background(isSelected ? Theme.selection : Color.clear)
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
        // The arrow is shown on anything that has been opened, even if it is
        // closed again with nothing typed — otherwise the row that created the
        // sub-task would leave no way back to it. Once there are real children
        // it stays for good.
        let expandable = (item.expanded || store.hasChildren(item.id))
            && branch.depth < TodoStore.maxDepth

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
            Text(item.title)
                .strikethrough(item.done, color: Theme.dim)
                .foregroundStyle(item.done ? Theme.dim : Theme.primary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

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
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(Theme.accent).frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        // SwiftUI's tap gesture does not report modifiers, so the live global
        // state is read instead — the same thing a native list view does.
        .onTapGesture { selectWithMouse(item.id, modifiers: NSEvent.modifierFlags) }
        .contextMenu {
            Button(item.done ? "mark as not done" : "mark as done") {
                store.toggle(id: item.id)
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
    private func selectWithMouse(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
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
        if model.draft.isEmpty {
            model.enterList()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text("\(store.openCount) open")

            Spacer()

            Text(hint)

            SettingsButton(isOpen: model.showingSettings) { toggleSettings() }
        }
        .font(Theme.monospacedSmall)
        .foregroundStyle(Theme.dim)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Theme.surface)
    }

    private var hint: String {
        if model.showingSettings { return "esc to go back" }
        if model.mode == .input { return "↓ list · esc close" }
        // Kept short enough to sit on one line. The first version of this ran to
        // "↑↓ move · tab sub tasks · space toggle · ⌫ remove · esc type" and
        // wrapped, which turned the footer into two lines and pushed the panel
        // taller than the fixed frame.
        return "↑↓ move · tab sub tasks · space · ⌫ · esc"
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
            KeyRecorder(role: role, onConflict: { shortcutError = $0 })
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
    /// Saves the task and drops the caret into a sub-task row under it, so
    /// "go market" ⏎ then "buy bananas" is one continuous motion. The task is
    /// added already open as a single undo step — see `addAndOpen`.
    private func submit() {
        let text = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.draft = ""

        guard let id = store.addAndOpen(text) else { return }
        model.showDraftRow(for: id)
        model.requestChildFocus(id)
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

    private func cancelInput() {
        // Escape peels one layer at a time: out of settings, out of the list,
        // out of the draft, then out of the panel.
        if model.showingSettings {
            model.showingSettings = false
            model.requestInputFocus()
            return
        }
        if !model.draft.isEmpty {
            model.draft = ""
            model.requestInputFocus()
            return
        }
        onClose()
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

        switch Int(event.keyCode) {
        case Int(KeyCode.arrowDown):
            // Down off the bottom row goes back to the add-a-task bar, so the
            // list is a loop you can walk out of at either end. Stopping dead
            // at the last task left the keyboard with nowhere to go but Esc.
            if !shift, model.isAtBottom(of: rowIDs) {
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
            if !selectedItems.isEmpty {
                // Roots only: ticking a parent leaves what is under it alone.
                store.toggleRoots(ids: selectedItems.map(\.id))
            }
            return true

        case Int(KeyCode.delete), Int(KeyCode.forwardDelete):
            // Delete on a blank sub-task row takes the row away rather than the
            // task above it. It used to remove the last sub-task, which is the
            // opposite of what the key means everywhere else in a text field.
            if let id = model.focusedRow, let parent = draftParent(for: id) {
                eraseBlankRow(for: parent)
                return true
            }
            deleteSelected()
            return true

        case Int(KeyCode.tab):
            tabPressed()
            return true

        case Int(KeyCode.returnKey) where shift:
            // Shift+Return appends a sub-task under whatever is highlighted.
            // This is how you get back to adding one: once the blank row is gone
            // there is no prompt to type into, and the old route — Delete on the
            // row to remove it, then Tab to bring it back — meant a closed branch
            // could never be added to again.
            if let id = model.focusedRow, let parent = store.parentForNewSubtask(of: id) {
                store.setExpanded(true, id: parent)
                model.showDraftRow(for: parent)
                model.requestChildFocus(parent)
                return true
            }
            model.requestInputFocus()
            return true

        case Int(KeyCode.returnKey), Int(KeyCode.escape):
            // Return and Escape both mean "I'm done with the list": drop the
            // highlight and hand the caret back. A selection left showing while
            // the caret is in the prompt claims the next keypress will act on
            // that task, which is no longer true.
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

    /// Tab opens and closes a task's sub-tasks. That is all it does.
    ///
    /// It used to be three things at once — toggle, and *create* a sub-task when
    /// the task had none — which meant one key was doing two unrelated jobs and
    /// the only way to tell which had happened was to look at the screen.
    /// Creating is Shift+Return's job now, so Tab is one verb.
    private func tabPressed() {
        guard let id = model.focusedRow else {
            model.requestInputFocus()
            return
        }

        // On a blank sub-task row there is no branch to open or close, so the
        // key goes back to the top prompt rather than being swallowed.
        guard draftParent(for: id) == nil else {
            model.requestInputFocus()
            return
        }
        store.toggleExpanded(id: id)
        // Any blank row goes with it. Toggling means "show me this task's
        // sub-tasks", and a stray prompt in among them is not part of that.
        model.hideDraftRow(for: id)
        // Stay on the row, in the list. The caret does not move to a sub-task
        // row because Tab is not what makes one.
        model.select(id)
        model.enterList()
    }

    /// Turns the half-typed sub-task into a real one.
    ///
    /// Return saves it and leaves — the caret goes back to the add-a-task bar
    /// and the blank row goes away, so a list of one finished sub-task is not
    /// left with a prompt hanging under it. Shift+Enter saves it and stays,
    /// with a fresh blank row under the one you just added, for the case where
    /// you are writing several in a row.
    private func commitDraft(under parent: UUID, keepGoing: Bool) {
        let text = model.draft(for: parent)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Nothing written: Return leaves, Shift+Enter just re-arms the row
            // it is already on.
            if keepGoing {
                model.requestChildFocus(parent)
            } else {
                eraseBlankRow(for: parent)
            }
            return
        }

        _ = store.addSubtask(trimmed, under: parent)
        model.clearDraft(for: parent)

        if keepGoing {
            model.showDraftRow(for: parent)
            model.requestChildFocus(parent)
        } else {
            model.hideDraftRow(for: parent)
            model.requestInputFocus()
        }
    }

    /// Dismiss the blank sub-task row, leaving the branch and its sub-tasks
    /// alone, and put the highlight on the last one.
    ///
    /// Closing the branch would have hidden the sub-tasks as well, which is a
    /// different thing: this is about a stray prompt sitting under a list you
    /// are reading. Tab brings the row back, and so does adding a sub-task.
    private func eraseBlankRow(for parent: UUID) {
        // Never throw away something half-typed. The keyboard path only gets
        // here from an empty field, so this is belt and braces for the
        // list-level Delete, where the row can be selected with a draft in it.
        guard model.draft(for: parent).isEmpty else { return }
        model.hideDraftRow(for: parent)
        // The row just dismissed is still in `rows` until the next render, and
        // it is the last one in its own branch — so it has to be skipped or the
        // highlight lands on a row that is no longer there. Matching on the task
        // itself, rather than on ids, is what makes an actual sub-task match.
        let last = rows.last { row in
            guard case .task(let branch) = row else { return false }
            return branch.item.id == parent || branch.item.parentID == parent
        }
        model.select(last?.id)
        model.enterList()
    }

    private func toggleExpanded(_ item: TodoItem) {
        store.setExpanded(!item.expanded, id: item.id)
    }

    /// Deletes everything selected, as one undoable step.
    private func deleteSelected() {
        guard let index = model.focusedRow.flatMap({ id in
            tasks.firstIndex(where: { $0.id == id })
        }) ?? selectedItems.first.flatMap({ item in
            tasks.firstIndex(where: { $0.id == item.id })
        }) else { return }

        let ids = selectedItems.map(\.id)
        // Keep the highlight in roughly the same visual slot afterwards:
        // whatever slid into the gap, or the row before it if the list emptied.
        let survivors = tasks.filter { !ids.contains($0.id) }
        store.delete(ids: ids)

        if survivors.isEmpty {
            model.select(nil)
        } else {
            model.select(survivors[min(index, survivors.count - 1)].id)
        }
    }

    /// Single-task delete, from the row's right-click menu.
    private func delete(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let remaining = tasks.filter { $0.id != id }
        store.delete(id: id)

        if remaining.isEmpty {
            model.select(nil)
        } else {
            model.select(remaining[min(index, remaining.count - 1)].id)
        }
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