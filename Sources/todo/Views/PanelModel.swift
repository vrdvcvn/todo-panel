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

    /// Same, for the list key catcher, the inline editor, and the blank
    /// sub-task row. Comparing tokens is how a representable knows a *new*
    /// request arrived rather than re-stealing focus on every SwiftUI update.
    @Published private(set) var listFocusToken: Int = 0
    @Published private(set) var editFocusToken: Int = 0
    @Published private(set) var childFocusToken: Int = 0

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

    func beginEditing(id: UUID) {
        editFocusToken += 1
        select(id)
    }

    func endEditing() {}

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
    /// asked for it — Tab on a task with nothing under it, or Shift+Enter — and
    /// gone again the moment you move away from it.
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
}
