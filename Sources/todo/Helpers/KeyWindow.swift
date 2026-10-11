import AppKit

/// A borderless window that is still allowed to take keyboard focus.
///
/// The key detail, carried over from Medo: an `NSApplication` running under
/// the `.accessory` policy — which `todo` does, so it stays out of the Dock and
/// the menu bar — cannot normally make a window key. Overriding
/// `canBecomeKey` is what allows typing into the panel at all.
final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Tab opens and closes sub-tasks; it is not "move to the next view".
    ///
    /// AppKit treats Tab as a key equivalent for key-view traversal, and key
    /// equivalents are matched *before* the keystroke is delivered — so the
    /// first responder jumped to the next view willing to take focus, which is
    /// the prompt, and the panel then read it as "the user went back to the
    /// input field". The list never saw the key, and Tab appeared to do nothing.
    ///
    /// Declining the key equivalent is what lets it through: AppKit carries on
    /// to ordinary key handling, and the row that has the keyboard gets the
    /// keystroke like any other.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Int(event.keyCode) == KeyCode.tab, event.modifierFlags.isEmpty {
            return false
        }
        return super.performKeyEquivalent(with: event)
    }
}