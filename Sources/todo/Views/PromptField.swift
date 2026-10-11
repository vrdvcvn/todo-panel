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
    /// False while the settings drawer is open, so tasks cannot be added from
    /// behind it.
    var isEnabled: Bool = true
    let onSubmit: () -> Void
    let onMoveDown: () -> Void
    let onMoveUp: () -> Void
    /// Delete inside an empty field. Fires only when there is nothing to erase,
    /// so it cannot eat characters.
    let onDelete: () -> Void
    let onCancel: () -> Void
    /// Clears a selection without leaving the prompt. Used by Tab.
    let onClearSelection: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private static func placeholder(for text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
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

        field.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .medium)
        field.textColor = Theme.nsPrimary
        field.stringValue = text
        field.placeholderAttributedString = Self.placeholder(for: placeholder)
        PromptFields.register(field, as: fieldKey)

        // Deliberately *not* recording `focusToken` here. `updateNSView` runs
        // immediately after and is what actually takes first responder; if this
        // claimed the token, that call would see it as already handled and skip.
        // A field created on the very update that asks for focus — the blank
        // sub-task row, which appears and is asked to take the caret in the same
        // breath — would sit there with the caret still in the prompt.
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

        // The placeholder changes as you go — the blank sub-task row says
        // "add a sub task" until the first one is saved and "add another sub
        // task" after — and it is only ever set when the field is built
        // otherwise, so the row kept offering to add the *first* sub-task for
        // the rest of the session.
        if field.placeholderAttributedString?.string != placeholder {
            field.placeholderAttributedString = Self.placeholder(for: placeholder)
        }

        if field.stringValue != text {
            field.stringValue = text
        }

        guard context.coordinator.lastFocusToken != focusToken else { return }

        // A disabled field cannot take the caret, so the request has to stay
        // pending rather than being marked handled. Otherwise the moment the
        // field is enabled again — leaving the settings drawer, say — the one
        // token that was going to move focus there has already been spent.
        guard isEnabled else { return }

        if let window = field.window {
            context.coordinator.lastFocusToken = focusToken
            window.makeFirstResponder(field)
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
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PromptField
        var lastFocusToken: Int

        init(_ parent: PromptField) {
            self.parent = parent
            self.lastFocusToken = parent.focusToken
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
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
