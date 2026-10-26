import Foundation
import SwiftUI

/// UI state for the panel, shared between the panel controller (which needs to
/// ask for focus) and the SwiftUI views (which need to render it).
///
/// This exists because the panel is created once and then hidden and shown for
/// the life of the process. SwiftUI `@State` would survive that, but the
/// controller also needs to drive it, so it lives in a small observable object.
@MainActor
final class PanelModel: ObservableObject {
    enum Mode {
        /// Caret in a text field — plain typing.
        case input
        /// Selection in the list — arrows, space, delete.
        case list
    }

    /// Which text field the caret is in.
    ///
    /// There are two: the one at the top of the panel, and the blank row under
    /// an expanded task where its next sub-task is typed. Both are real
    /// `NSTextField`s and both need to be able to take the caret, so this is
    /// what decides which one `requestInputFocus()` is asking.
    enum InputTarget: Equatable {
        case root
        case child(UUID)
        /// An existing task's title, being corrected.
        ///
        /// A third kind of field because being unable to fix a typo is not a
        /// small gap. A mistyped task could only be dealt with by deleting it
        /// and typing it again — which loses its place in the list *and* every
        /// sub-task under it, over one wrong letter.
        case edit(UUID)
    }

    @Published var draft: String = ""
    @Published private(set) var mode: Mode = .input

    /// Whether the settings screen is open.
    ///
    /// Lives here rather than in `PanelView` because `PanelController` needs to
    /// read it to decide where to put keyboard focus: settings mode has no text
    /// field, so focus has to go to the list key catcher or Escape goes nowhere.
    @Published var showingSettings = false

    /// Where the caret is. Defaults to the top prompt.
    @Published private(set) var inputTarget: InputTarget = .root

    /// The selected rows.
    ///
    /// A set of identities, not a list of positions. Selection was originally a
    /// single integer index, which silently broke the moment the list
    /// re-sorted: ticking an item off moved it down, so the unchanged index
    /// suddenly pointed at a different task and the next keystroke deleted the
    /// wrong one. Identities survive re-sorting, re-ordering and deletion.
    @Published private(set) var selection: Set<UUID> = []

    /// Where a shift-extended selection started from.
    private var anchor: UUID?

    /// The end of the selection that the arrow keys move.
    ///
    /// Separate from the anchor on purpose. With only an anchor, holding shift
    /// and pressing ↓ twice would extend by one row, then compute the same
    /// target again and extend by one row forever — the selection would refuse
    /// to grow past two tasks. The anchor stays put; this end walks.
    private var focus: UUID?

    /// Half-typed sub-task text, one entry per expanded parent.
    ///
    /// Held per parent rather than as a single string so that collapsing a
    /// branch and opening it again does not silently throw away what was being
    /// typed into it.
    @Published private(set) var childDrafts: [UUID: String] = [:]

    /// Bumped to ask the top field to become first responder.
    @Published private(set) var inputFocusToken: Int = 0

    /// Same, for the list key catcher, the inline title editor and the blank
    /// sub-task row. Comparing tokens is how a representable knows a *new*
    /// request arrived rather than re-stealing focus on every SwiftUI update.
    @Published private(set) var listFocusToken: Int = 0
    @Published private(set) var editFocusToken: Int = 0
    @Published private(set) var childFocusToken: Int = 0

    /// The row the keyboard should be scrolled to, or `nil`.
    ///
    /// Set only by the arrow keys, and read once by the list.
    ///
    /// This used to be `onChange(of: selection)`, which meant *every* way of
    /// changing the selection also scrolled — including clicking a row with the
    /// pointer, which yanked it to the middle of the panel. The pointer is
    /// already looking at the row it clicked; moving the viewport to prove it is
    /// there is the definition of a scroll nobody asked for.
    @Published private(set) var scrollTarget: UUID?

    func noteKeyboardMove(to id: UUID) {
        scrollTarget = id
    }

    func clearScrollTarget() {
        scrollTarget = nil
    }

    // MARK: - Focus

    /// Puts the panel back to "ready to type a task" whenever it is opened.
    ///
    /// The panel is hidden and shown dozens of times a session, and resuming
    /// where you left off is the wrong default: opening onto the settings
    /// screen means the first keypress lands nowhere useful, and opening with a
    /// task still selected means Space ticks that task instead of whatever you
    /// were about to type.
    ///
    /// The draft is deliberately kept. Reopening the panel is not a reason to
    /// throw away half a task someone already typed.
    func resetToInput() {
        showingSettings = false
        requestInputFocus()
    }

    /// Moves the caret back to the top prompt and drops the selection.
    ///
    /// The two always move together. Highlighted rows left behind while the
    /// caret is in the prompt say "these tasks are the ones your keys will act
    /// on", which is not true there — Space types a space and Delete edits text
    /// — so the highlight is just a lie about what is about to happen.
    func requestInputFocus() {
        mode = .input
        inputTarget = .root
        clearSelection()
        inputFocusToken += 1
        PromptFields.focus(PromptFields.root)
    }

    /// Puts the caret in a parent's blank sub-task row.
    func requestChildFocus(_ parent: UUID) {
        mode = .input
        inputTarget = .child(parent)
        clearSelection()
        childFocusToken += 1
        PromptFields.focus(PromptFields.child(parent))
    }

    func enterList() {
        mode = .list
        listFocusToken += 1
    }

    /// Records that the caret landed in a field because the *user* put it there,
    /// rather than because we asked for it.
    ///
    /// `inputTarget` is otherwise only moved by the focus requests above, and
    /// clicking straight into a field is not one of them. So after clicking
    /// into the top prompt, `inputTarget` still named whatever sub-task row the
    /// keyboard had been in — and `focusedText` then reported that row as empty,
    /// which sent ⌘Z off to undo a task instead of undoing the characters in
    /// front of you.
    ///
    /// Deliberately does not touch the selection or bump a focus token: the
    /// user has already done both.
    func adoptInputTarget(_ target: InputTarget) {
        guard inputTarget != target else { return }
        inputTarget = target
        mode = .input
    }

    // MARK: - Editing a title

    /// Where the caret should land when a title editor opens.
    ///
    /// Every route into an edit is "I want to fix something", and where the
    /// caret lands decides what one keystroke does next: at the end, the keys
    /// you press are more text; at the start, they are a correction of the
    /// word you got wrong. ← and → are how you choose between them.
    enum EditCaret: Equatable {
        case start
        case end
    }

    /// The task whose title is being edited, and the text in that field.
    ///
    /// Kept apart from the sub-task drafts because they answer different
    /// questions: a sub-task draft is something not yet written down, and
    /// leaving it alone has to throw it away. A title edit is a correction to
    /// something that already exists, and leaving it has to leave it as it was.
    @Published private(set) var editing: UUID?
    @Published private(set) var editDraft: String = ""

    /// Where the caret was asked to go. Held rather than passed straight to the
    /// field because the field is created and updated later, and by then the
    /// call that asked for it has long gone.
    private var editCaret: EditCaret = .end

    private var editOriginal = ""

    /// Opens `id`'s title for editing. The current text is passed in rather than
    /// looked up, because the store is the one that owns the list and the model
    /// has no business holding a second copy of it.
    ///
    /// Defaults to `.end`: the commonest edit is "I left a character off the
    /// end", and a caret at the start would send the next letter to the front.
    func beginEditing(id: UUID, title: String, caret: EditCaret = .end) {
        editing = id
        editOriginal = title
        editDraft = title
        editCaret = caret
        inputTarget = .edit(id)
        mode = .input
        editFocusToken += 1
    }

    /// The character offset the editor's caret should sit at.
    ///
    /// An offset rather than an `EditCaret`, because the field can only be told
    /// where to put the caret in absolute terms, and `.end` moves as you type.
    /// The field clamps it to what it actually holds — the draft can change
    /// between the request and the field being updated — and clamping there
    /// keeps that detail in one place.
    var editCaretOffset: Int {
        editCaret == .start ? 0 : editDraft.count
    }

    func setEditDraft(_ text: String) {
        guard editDraft != text else { return }
        editDraft = text
    }

    /// Ends the edit without saving. Returns the title to put back.
    func cancelEditing() {
        editDraft = editOriginal
        endEditing()
    }

    /// Ends the edit and hands back the text, for the caller to commit.
    func endEditing() {
        editing = nil
        editDraft = ""
        editOriginal = ""
        if case .edit = inputTarget { inputTarget = .root }
    }

    /// The row to put the keyboard on after an edit ends.
    ///
    /// Back in the list rather than up at the add-a-task bar: fixing a typo is
    /// something you do *to* a task, and the next thing you want is usually to
    /// carry on with the list. The row stays selected so Return and Space still
    /// apply to the task just corrected.
    func finishEditing() {
        let id = editing
        endEditing()
        guard let id else { return }
        select(id)
        enterList()
    }

    // MARK: - Sub-task keys

    /// The two places the list stops and hands the caret back to the prompt.
    ///
    /// `↑` off the top row and `↓` off the bottom row both land on the
    /// add-a-task bar, so the list is a loop you can walk out of at either end.
    func isAtTop(of ids: [UUID]) -> Bool {
        focusedRow == ids.first && !ids.isEmpty
    }

    func isAtBottom(of ids: [UUID]) -> Bool {
        focusedRow == ids.last && !ids.isEmpty
    }

    // MARK: - Sub-task drafts

    func draft(for parent: UUID) -> String {
        childDrafts[parent] ?? ""
    }

    /// Writes back through the binding, but only when it really changed.
    ///
    /// Every keystroke in the inline field runs this, and an unconditional
    /// publish would redraw the whole list on each character.
    func setDraft(_ text: String, for parent: UUID) {
        guard childDrafts[parent] != text else { return }
        childDrafts[parent] = text
    }

    /// Parents whose blank sub-task row is currently on screen.
    ///
    /// Deliberately separate from the branch being open. Tying the row to "the
    /// branch is open" left a stray `> add another sub task` sitting under every
    /// branch for as long as it was open, which is clutter you have to look past
    /// to read the sub-tasks you actually wrote. It is now there because you
    /// asked for it — Return or Tab on the task, or Return on a sub-task row —
    /// and gone again the moment you move away from it.
    @Published private(set) var openDraftRows: Set<UUID> = []

    func showDraftRow(for parent: UUID) {
        guard !openDraftRows.contains(parent) else { return }
        openDraftRows.insert(parent)
    }

    func hideDraftRow(for parent: UUID) {
        guard openDraftRows.contains(parent) else { return }
        openDraftRows.remove(parent)
    }

    func isDraftRowOpen(_ parent: UUID) -> Bool {
        openDraftRows.contains(parent)
    }

    func clearDraft(for parent: UUID) {
        guard childDrafts[parent] != nil else { return }
        childDrafts[parent] = nil
    }

    /// Takes away every blank sub-task row left unused, and says which parents
    /// no longer have a reason to be open.
    ///
    /// For when the panel is being put away. Closing the panel is a way of
    /// leaving a row, and an empty one left behind that way came straight back
    /// next time — a `> add a sub task` prompt hanging under a task nobody
    /// asked for one under, waiting for the rest of the session.
    ///
    /// The caller gets the parents back because closing the panel is also the
    /// moment to drop their "opened" flag; see `TodoStore.collapseIfChildless`.
    @discardableResult
    func discardUnusedDraftRows() -> [UUID] {
        let unused = openDraftRows.filter { draftIsBlank($0) }
        openDraftRows.subtract(unused)
        return Array(unused)
    }

    /// Whether a blank sub-task row is unused.
    ///
    /// Trimmed, because "unused" has to mean the same thing everywhere. The
    /// save path tests the trimmed text and the dismissal paths used to test the
    /// raw one, so a row holding nothing but spaces was blank to one and full
    /// to the other — Return declined to add a task, Delete declined to remove
    /// the row, and nothing could shift it either way.
    func draftIsBlank(_ parent: UUID) -> Bool {
        draft(for: parent).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whatever text the caret is actually sitting in.
    ///
    /// There are two fields, and the obvious answer — `draft` — is only one of
    /// them. Anything deciding "is there typing worth protecting here?" has to
    /// ask about the field that is focused, not the one at the top of the
    /// panel: while the caret was in a blank sub-task row `draft` was empty, so
    /// ⌘Z decided nothing was being typed and undid a task instead.
    var focusedText: String {
        switch inputTarget {
        case .root: return draft
        case .child(let parent): return draft(for: parent)
        case .edit: return editDraft
        }
    }

    /// Whether the caret is in a title that already exists.
    ///
    /// A different question from "is there typing worth protecting", and the
    /// two disagree in the one case that matters. The top prompt holds something
    /// that does not exist yet, so an empty prompt means ⌘Z belongs to the list
    /// — there is nothing to recover. A title editor holds a task that was
    /// already there: emptying it and pressing ⌘Z is unmistakably asking for the
    /// words back, and answering with "here is your task, deleted" is the worst
    /// thing the key could do.
    var isEditingTitle: Bool {
        if case .edit = inputTarget { return true }
        return false
    }

    /// The blank sub-task row the caret is in, if it is in one.
    ///
    /// The counterpart to `focusedRow` for the same reason. `requestChildFocus`
    /// clears the selection, so the row the caret is sitting in is the one row
    /// the selection cannot name — and anything that has to work out "is the
    /// keyboard in a blank row?" has to ask here instead.
    var focusedDraftParent: UUID? {
        if case .child(let parent) = inputTarget { return parent }
        return nil
    }

    // MARK: - Selecting

    func isSelected(_ id: UUID) -> Bool { selection.contains(id) }

    /// The one row a key acts on, which is not the same question as "is
    /// anything selected".
    ///
    /// A selection can cover a whole branch — picking a parent brings its
    /// sub-tasks with it — so the set is rarely the thing to read the row from.
    /// `Set` has no order either, so `selection.first` is arbitrary and would
    /// send Tab to whichever branch happened to hash lower. The keyboard is on
    /// one row: that is the focus, falling back to the anchor of a
    /// shift-extended selection.
    var focusedRow: UUID? { focus ?? anchor ?? selection.first }

    /// Plain click or plain arrow: replace the selection with just this one.
    func select(_ id: UUID?) {
        selection = id.map { [$0] } ?? []
        anchor = id
        focus = id
    }

    /// ⌘-click: add or remove this one row, leaving the rest alone.
    func toggleInSelection(_ id: UUID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
        anchor = id
        focus = id
    }

    /// Shift-click or shift-arrow: extend from the anchor to this row.
    ///
    /// Every row the range crosses is selected, sub-tasks included. A range is
    /// about what is between two points on screen, and quietly skipping the
    /// nested rows in between would leave holes in the highlight.
    func extendSelection(to id: UUID, in ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let start = anchor.flatMap { ids.firstIndex(of: $0) } ?? 0
        guard let end = ids.firstIndex(of: id) else { return }
        selection = Set(ids[min(start, end)...max(start, end)])
    }

    func selectAll(_ ids: [UUID]) {
        selection = Set(ids)
        anchor = ids.first
        focus = ids.last
    }

    func clearSelection() {
        selection = []
        anchor = nil
        focus = nil
    }

    // MARK: - Keyboard movement

    /// Arrow keys, over the ordered row ids — which include the blank sub-task
    /// rows as well as tasks, so ↓ can land on one.
    ///
    /// With `extending`, keeps the anchor and drags the other end.
    func moveSelection(by offset: Int, extending: Bool, in ids: [UUID]) {
        guard !ids.isEmpty else {
            clearSelection()
            return
        }

        // Start from the moving end if we have one; otherwise from wherever the
        // selection happens to end, so a plain arrow after a ⌘-click carries on
        // from the row last picked rather than snapping to the top.
        let current: Int
        if let focus, let index = ids.firstIndex(of: focus) {
            current = index
        } else if let last = ids.last(where: { selection.contains($0) }) {
            current = ids.firstIndex(of: last) ?? 0
        } else {
            // Just off the near edge, so the first press lands on a real row.
            current = offset >= 0 ? -1 : ids.count
        }

        let next = min(max(0, current + offset), ids.count - 1)

        if extending, let anchor {
            let start = ids.firstIndex(of: anchor) ?? next
            selection = Set(ids[min(start, next)...max(start, next)])
        } else {
            selection = [ids[next]]
            self.anchor = ids[next]
        }
        focus = ids[next]

        // The only route into `scrollTarget`: the keyboard walking off the edge
        // of the screen is the one case where the list has to follow.
        scrollTarget = ids[next]
    }

    /// Drops selected rows that are no longer on screen.
    ///
    /// Called after every change to the list, because collapsing a branch, or
    /// deleting a task, takes rows away — and a highlight left on a row that is
    /// gone would have the next keystroke act on nothing.
    func retainSelection(in ids: [UUID]) {
        let live = Set(ids)
        selection = selection.intersection(live)
        if let anchor, !live.contains(anchor) { self.anchor = nil }
        if let focus, !live.contains(focus) { self.focus = nil }
    }

    /// Forgets half-typed sub-task text belonging to tasks that are gone.
    ///
    /// `childDrafts` and `openDraftRows` are keyed by parent, so an undo or a
    /// delete that removes a task would otherwise leave its entries behind for
    /// good — a row that can never be drawn, and text that comes back if a new
    /// task ever happens to reuse the id. Neither is cleared anywhere else:
    /// only the field that happened to be focused drops its text.
    ///
    /// Keyed off every task in the store, not the rows on screen, so closing a
    /// branch does not throw away what was typed into it.
    func pruneDrafts(under existing: Set<UUID>) {
        // Snapshots, not live views: removing from a `Set` while iterating it
        // is undefined, and the loop variable would be skipped.
        let staleDrafts = childDrafts.keys.filter { !existing.contains($0) }
        for parent in staleDrafts {
            childDrafts[parent] = nil
        }

        let staleRows = openDraftRows.filter { !existing.contains($0) }
        for parent in staleRows {
            openDraftRows.remove(parent)
        }
    }
}
