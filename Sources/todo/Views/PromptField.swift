import AppKit
import SwiftUI

/// The `> ` input line.
///
/// A bare `NSTextField` rather than a SwiftUI `TextField`, because it is the
/// only version that lets us intercept Return, Down and Escape reliably via
/// `control(_:textView:doCommandBy:)`. Getting that wrong is how a command
/// palette ends up inserting a newline instead of adding an item.
///
/// `focusToken` is compared between updates: when it changes, the field takes
/// first responder. Comparing rather than simply always focusing means a
/// re-render never steals focus out from under an in-progress edit.
///
/// `fieldKey` names the field so that `PromptFields` can put the caret in it
/// directly, which is what the blank sub-task row needs. Its field is created
/// and asked to take focus in the same pass, so by the time the representable is
/// asked to focus it is not yet in a window and `makeFirstResponder` is a
/// no-op; asking again from a registry keyed by name, one runloop turn later,
/// is the difference between the caret arriving and it silently not.
struct PromptField: NSViewRepresentable {
    /// Names this field within `PromptFields`, so focus can be requested for it
    /// by whoever needs it rather than only by its own update.
    let fieldKey: String

    @Binding var text: String
    let focusToken: Int
    let placeholder: String
    /// The font to draw the text in, or `nil` for the prompt's own.
    ///
    /// Only the title editor needs one: it sits inside a task row, and a row is
    /// 13.5pt regular while this control is 14pt medium — so switching a task
    /// into edit mode visibly grew its text, and the row's baseline moved with
    /// it. A field that always draws its own text at one size cannot be dropped
    /// into a row that has already chosen one.
    var font: NSFont?
    /// Where to put the caret once the field has the keyboard, or `nil` to let
    /// it wherever it likes.
    ///
    /// Applied *after* taking first responder, because that is what puts the
    /// caret at the end and selects everything. Ask first and the selection
    /// wins: opening a title to fix its last word would select the whole thing,
    /// and the next character typed would replace the title.
    var initialCaret: Int?
    /// False while the settings drawer is open, so tasks cannot be added from
    /// behind it.
    var isEnabled: Bool = true
    let onSubmit: () -> Void
    /// Shift+Return. See the delegate — AppKit reports both Returns as the
    /// same selector, so this is the only way to tell them apart.
    ///
    /// Deliberately kept even though every call site now hands it the same
    /// closure as `onSubmit`, and even though ⇧Return no longer means anything
    /// the plain one does not. Without it there is nothing to detect the shift
    /// with: AppKit routes both through `insertNewline:` and the field cannot
    /// tell which was pressed. The duplication is the honest shape of that API,
    /// not an oversight.
    var onSubmitAndContinue: (() -> Void)?
    let onMoveDown: () -> Void
    let onMoveUp: () -> Void
    /// Delete inside an empty field. Fires only when there is nothing to erase,
    /// so it cannot eat characters.
    let onDelete: () -> Void
    let onCancel: () -> Void
    /// Clears a selection without leaving the prompt. Used by Tab.
    let onClearSelection: () -> Void
    /// The user clicked into this field.
    ///
    /// Focus requests go the other way — we ask a field to take the keyboard —
    /// so nothing told the model when the caret arrived by a click. That left
    /// `inputTarget` naming the field the keyboard was last *sent* to, and every
    /// question asked of "the focused field" was answered about the wrong one.
    var onEditingBegan: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// The prompt's own text style, and the default for every field.
    static let promptFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .medium)

    /// The prompt's placeholder style, which is *not* its text style.
    ///
    /// Kept apart because they have always differed: the placeholder is a
    /// stand-in for text nobody has written, so it is drawn lighter. Folding it
    /// into `promptFont` made `add a task` and `add a sub task` half a step
    /// bolder the moment the editor gained a font of its own.
    private static let promptPlaceholderFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    private var resolvedFont: NSFont { font ?? Self.promptFont }
    private var resolvedPlaceholderFont: NSFont { font ?? Self.promptPlaceholderFont }

    private static func placeholder(for text: String, font: NSFont) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: Theme.nsDim,
            ]
        )
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        // Single line, scrolled sideways — the way a browser's search field
        // behaves. `NSTextField` defaults to `wraps = true`, so long input
        // wrapped onto a second line and then scrolled *vertically* inside the
        // 24pt frame, shoving the first line off the top of the panel.
        field.cell?.wraps = false
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byClipping
        field.cell?.isScrollable = true

        field.font = resolvedFont
        field.textColor = Theme.nsPrimary
        field.stringValue = text
        field.placeholderAttributedString = Self.placeholder(for: placeholder, font: resolvedPlaceholderFont)
        PromptFields.register(field, as: fieldKey)

        // Deliberately *not* recording `focusToken` here. `updateNSView` runs
        // immediately after and is what actually takes first responder; if this
        // claimed the token, that call would see it as already handled and skip.
        // A field created on the very update that asks for focus — the blank
        // sub-task row, and the inline title editor — would sit there with the
        // caret still wherever it was.
        return field
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        PromptFields.unregister(field)
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        // The coordinator holds a copy of this struct to invoke its callbacks.
        // Without refreshing it here that copy stays frozen at whatever the
        // view was when it was first created, so any callback reading later
        // state sees the initial values — which is how Escape closed the whole
        // panel instead of just leaving the settings drawer.
        context.coordinator.parent = self

        field.isEditable = isEnabled
        field.isSelectable = isEnabled
        if field.font != resolvedFont {
            field.font = resolvedFont
        }

        // The placeholder changes as you go — the blank sub-task row says
        // "add a sub task" until the first one is saved and "add another sub
        // task" after — and it is only ever set when the field is built
        // otherwise, so the row kept offering to add the *first* sub-task for
        // the rest of the session.
        if field.placeholderAttributedString?.string != placeholder {
            field.placeholderAttributedString = Self.placeholder(for: placeholder, font: resolvedPlaceholderFont)
        }

        if field.stringValue != text {
            field.stringValue = text
        }

        // The token, not the text: a field only ever takes the caret on a fresh
        // request, never because its contents happened to change.
        //
        // Deliberately *not* also re-applied when `initialCaret` moves. `.end`
        // is the end of the text, so it grows with every keystroke — asking
        // again on each one would haul the caret back to the end of the title
        // after every character, and ← could not move it.
        guard context.coordinator.lastFocusToken != focusToken else { return }

        // Zero is "this field is not the one with the keyboard" — a blank
        // sub-task row under another branch is created with 0 while the caret
        // is somewhere else entirely, and it must not take it. Anything above
        // zero is a real request, including the first update a freshly created
        // field gets, which is how a field that appears *because* it should be
        // typed into ends up with the caret.
        guard focusToken > 0 else {
            context.coordinator.lastFocusToken = focusToken
            return
        }

        // A disabled field cannot take the caret, so the request has to stay
        // pending rather than being marked handled. Otherwise the moment the
        // field is enabled again — leaving the settings drawer, say — the one
        // token that was going to move focus there has already been spent.
        guard isEnabled else { return }

        let requested = initialCaret
        if let window = field.window {
            context.coordinator.lastFocusToken = focusToken
            window.makeFirstResponder(field)
            Self.placeCaret(requested, in: field)
        } else {
            // Not attached to a window yet. `makeFirstResponder` on a detached
            // field is a no-op, and marking the request handled would lose it
            // for good — which is what happened to the blank sub-task row: it
            // is created and asked to take the caret in the same pass, so it is
            // always still unattached when the request arrives. Retry next turn.
            let coordinator = context.coordinator
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                coordinator.lastFocusToken = focusToken
                window.makeFirstResponder(field)
                Self.placeCaret(requested, in: field)
            }
        }
    }

    /// The UTF-16 offset `characterOffset` characters into `text`.
    ///
    /// `initialCaret` is a `String.count` offset and has to stay one — an offset
    /// counted in UTF-16 units puts the caret in the wrong place for any title
    /// with an emoji or an accent, and lands it *inside* a surrogate pair, where
    /// AppKit snaps it to whichever half it feels like. "buy milk 🎉" is ten
    /// characters and eleven units, so the two disagree by exactly one.
    ///
    /// `NSRange` is UTF-16 all the way down and cannot be talked out of it, so
    /// the conversion happens here, once, at the boundary. Not `private`: the
    /// self-test calls it, because a conversion that cannot be reached is a
    /// conversion that cannot be checked.
    static func utf16Offset(_ characterOffset: Int, in text: String) -> Int {
        guard characterOffset > 0 else { return 0 }
        return text.prefix(characterOffset).utf16.count
    }

    /// Puts the caret where it was asked to go, once the field has the keyboard.
    ///
    /// After `makeFirstResponder` and never before: that is the moment
    /// `NSTextField` selects the whole string. Move the caret first and the
    /// selection lands afterwards, so a title opened to fix its last word
    /// arrived selected, and the next character typed replaced the whole thing.
    private static func placeCaret(_ caret: Int?, in field: NSTextField, retry: Bool = true) {
        guard let caret else { return }
        guard let editor = field.currentEditor() as? NSTextView else {
            // The field editor is not up yet on the turn the focus changed, and
            // it is the thing that holds the selection — so it is the whole
            // request. One turn later is enough; a second failure means the
            // field is not being edited at all, and retrying forever would keep
            // a closure hanging on to it.
            guard retry else { return }
            DispatchQueue.main.async { placeCaret(caret, in: field, retry: false) }
            return
        }
        let text = editor.string
        let offset = min(utf16Offset(caret, in: text), (text as NSString).length)
        editor.selectedRange = NSRange(location: max(0, offset), length: 0)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PromptField
        /// Starts at 0 whatever the field was created with, so that a field
        /// created *on* the update which asks for focus still acts on that
        /// request. Adopting the parent's token here — which is what this used
        /// to do — made every such field look as though the request had already
        /// been handled: the inline title editor opened with the caret left
        /// behind in the list, so the keys meant for the title went to the
        /// panel as commands.
        var lastFocusToken: Int = 0

        init(_ parent: PromptField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        /// Fires for a click as well as for a programmatic focus request, which
        /// is the whole point: this is the only signal that the caret arrived by
        /// the user's own hand.
        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.onEditingBegan?()
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // AppKit routes Return *and* Shift+Return through the same
                // `insertNewline:` — there is no separate selector to switch on,
                // which is why Shift+Return used to reach `onSubmit` and behave
                // exactly like a plain Return. The row you were writing several
                // sub-tasks into collapsed after the first one, and the
                // "leave a fresh blank row underneath" path below was dead
                // code that nothing could call.
                //
                // Modifier flags are read here, inside the command dispatch,
                // because they are the live hardware state for this keystroke.
                let keepGoing = NSEvent.modifierFlags.contains(.shift)
                    && parent.onSubmitAndContinue != nil
                if keepGoing, let onSubmitAndContinue = parent.onSubmitAndContinue {
                    onSubmitAndContinue()
                } else {
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveDown()
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveUp()
                return true
            case #selector(NSResponder.deleteBackward(_:)),
                 #selector(NSResponder.deleteForward(_:)):
                if parent.text.isEmpty {
                    parent.onDelete()
                    return true
                }
                return false
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            case #selector(NSResponder.insertTab(_:)),
                 #selector(NSResponder.insertBacktab(_:)):
                // Reached when a task was picked with the pointer and focus
                // stayed here. Tab drops that highlight rather than leaving it
                // behind, matching what Return does from the list.
                parent.onClearSelection()
                return true

            default:
                return false
            }
        }
    }
}

/// The live `NSTextField`s, by name, so focus can be aimed at one directly.
///
/// Weak values: a view that has gone must not be kept alive by this table, or a
/// field that is no longer on screen would keep being asked to take the caret.
enum PromptFields {
    /// The field at the top of the panel.
    static let root = "root"

    /// The blank row under a given parent.
    static func child(_ parent: UUID) -> String { "child-\(parent)" }

    /// An existing task's title, being corrected.
    static func edit(_ task: UUID) -> String { "edit-\(task)" }

    private static var fields: [String: WeakField] = [:]

    private final class WeakField {
        weak var field: NSTextField?
        init(_ field: NSTextField) { self.field = field }
    }

    static func register(_ field: NSTextField, as key: String) {
        fields[key] = WeakField(field)
    }

    static func unregister(_ field: NSTextField) {
        fields = fields.filter { $0.value.field !== field }
    }

    /// Puts the caret in the named field, once the runloop has caught up.
    ///
    /// Deferred because the usual reason to call this is a field that has only
    /// just been added to the hierarchy; asking immediately would be too early,
    /// and asking from the representable's own update is too early for the same
    /// reason.
    static func focus(_ key: String) {
        DispatchQueue.main.async {
            guard let field = fields[key]?.field, let window = field.window else { return }
            window.makeFirstResponder(field)
        }
    }
}
