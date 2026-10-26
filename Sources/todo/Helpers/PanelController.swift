import AppKit
import SwiftUI

/// Owns the floating panel: creating it once, then showing, hiding and
/// positioning it.
///
/// Adapted from Medo's `View.openNewWindow(isTransparent:)` helper, with the
/// pieces that app did not need (a HUD window, `isMovableByWindowBackground`)
/// dropped and explicit show/hide added.
@MainActor
final class PanelController {
    static let panelSize = NSSize(width: 460, height: 540)

    private let store: TodoStore
    private let model = PanelModel()
    private var window: KeyWindow?
    private var historyMonitor: Any?

    init(store: TodoStore) {
        self.store = store
        installHistoryMonitor()
    }

    /// Undo, redo and select-all, in one place, for both the prompt and the list.
    ///
    /// A local event monitor rather than per-view key handling, because a local
    /// monitor sees the key before anything else does. Handling it in the list
    /// view would mean it silently did nothing whenever the caret happened to
    /// be in the prompt, which is where you are most of the time.
    ///
    /// It also handles the prompt's own ⌘A and text-undo, which the text field
    /// cannot do by itself: ⌘A is not reaching the field editor's
    /// `doCommandBy:` at all, and with no menu bar there is nothing above it in
    /// the responder chain that would pick the command up either.
    private func installHistoryMonitor() {
        historyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains(.command) else { return event }

            let key = event.charactersIgnoringModifiers
            // ⇧⌘Z is the macOS spelling of redo; ⌘Y is what plenty of people
            // reach for out of habit. Both are accepted.
            let isRedo = key == "y" || modifiers.contains(.shift)

            switch key {
            case "a" where self.fieldEditor != nil:
                self.fieldEditor?.selectAll(nil)
                return nil

            case "z", "y":
                // A focused field with text in it means ⌘Z belongs to the text:
                // there are characters worth recovering, and losing them is
                // worse than making someone press undo twice.
                //
                // `focusedText` rather than `model.draft`, because the panel has
                // three kinds of field. While the caret was in a blank sub-task
                // row the root draft is empty — so the test below was false,
                // ⌘Z fell through to the task history, and one keystroke removed
                // a task instead of undoing the characters you had just typed.
                //
                // A title editor is always about the text, empty or not: it is
                // holding a task that already exists, and emptying it and asking
                // for it back must not delete it.
                if let editor = self.fieldEditor,
                   self.model.isEditingTitle || !self.model.focusedText.isEmpty {
                    isRedo ? editor.undoManager?.redo() : editor.undoManager?.undo()
                    return nil
                }
                if isRedo {
                    self.store.redo()
                } else {
                    self.store.undo()
                }
                return nil

            default:
                break
            }

            // Everything else — ⌘A over the list, for one — belongs to whoever
            // has the keyboard.
            return event
        }
    }

    /// The field editor behind the prompt, but only while the prompt actually
    /// holds the keyboard.
    ///
    /// Deliberately keyed off real focus rather than `model.mode`: those can
    /// disagree — clicking into the prompt with a draft already typed leaves
    /// the mode on `.list` — and a command that is silently dropped is worse
    /// than one routed to the wrong place. Over the list the first responder is
    /// the key catcher, an `NSView` that matches neither case, so this is nil
    /// and the list gets the key instead.
    private var fieldEditor: NSTextView? {
        if let view = window?.firstResponder as? NSTextView { return view }
        guard let field = window?.firstResponder as? NSTextField else { return nil }
        return field.currentEditor() as? NSTextView
    }

    /// Whether the panel is showing *where the user is looking*.
    ///
    /// `NSWindow.isVisible` alone is not good enough, and the difference is
    /// exactly the fullscreen case. It answers "is this window showing
    /// somewhere", across every Space — so a panel left open on the desktop
    /// still reports `true` while you are looking at a fullscreen app, which
    /// has its own Space and no copy of it. `toggle()` then hid the panel
    /// instead of showing it, and the keypress appeared to do nothing: you
    /// pressed ⌥Space, nothing came up, and the panel you could see on the
    /// desktop was gone too.
    ///
    /// `isOnActiveSpace` is the other half of the question, and asking both
    /// means the hotkey does the only thing that makes sense from wherever the
    /// user happens to be: if you cannot see it here, show it here.
    var isVisible: Bool {
        guard let window else { return false }
        return window.isVisible && window.isOnActiveSpace
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func setSettingsOpen(_ open: Bool) {
        // `show()` resets to the input screen, so the flag is set afterwards.
        if !isVisible { show() }
        model.showingSettings = open
        focusForCurrentScreen()
    }

    func show() {
        // Always come back to a clean "add a task" prompt, never to whatever
        // screen or selection was live when the panel was last hidden.
        model.resetToInput()

        let window = self.window ?? makeWindow()
        self.window = window

        // Two Spaces, two answers. The hotkey is pressed from whichever one the
        // user is looking at, and `isVisible` has already said this Space does
        // not have the panel in it.
        Diag.log("show (visible=\(window.isVisible) onActiveSpace=\(window.isOnActiveSpace))")

        // A window already ordered in on *another* Space does not migrate when
        // you order it in again from here: it stays where it was, which reads as
        // ⌥Space doing nothing — the panel is on the desktop, you are in a
        // fullscreen app, and there is nothing in front of you. Taking it out
        // first is what makes the Space switch below a move rather than a
        // second order-in to an existing one.
        if window.isVisible && !window.isOnActiveSpace {
            window.orderOut(nil)
        }

        center(window)

        // Activate *before* ordering front. The other order leaves the panel
        // behind the app it was summoned over for a runloop turn, which is long
        // enough to see.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Belt and braces: `makeKeyAndOrderFront` is a request, and a window
        // that has just been moved between Spaces can be refused by an app that
        // is still animating. This one is not a request.
        window.orderFrontRegardless()
        window.makeKey()

        focusForCurrentScreen()

        // SwiftUI applies `updateNSView` during the next layout pass. Asking a
        // second time on the next runloop turn guarantees the right view really
        // is first responder by the time the user's fingers are on the keyboard,
        // rather than only usually being so.
        DispatchQueue.main.async { [weak self] in
            guard let self, window.isVisible else { return }
            self.focusForCurrentScreen()
        }
    }

    /// Puts the keyboard where the screen that is currently showing wants it.
    ///
    /// The settings drawer is the reason this is not just `model.mode`: it has
    /// no text field at all, so the caret cannot go anywhere and Escape needs
    /// the list key catcher to arrive. Routing on the mode alone sent focus to
    /// the prompt behind the drawer — a field that is not on screen, and is
    /// disabled while the drawer is open, so it refuses first responder and
    /// Escape goes nowhere. That is the state `todo --settings` opens in, which
    /// is the only way a script can reach the drawer at all.
    /// Saves an open title edit, if there is one.
    ///
    /// Closing the panel in the middle of a correction is not a reason to throw
    /// the correction away — it is the same as walking away from a half-typed
    /// task, which is kept on purpose.
    private func commitEdit() {
        guard let id = model.editing else { return }
        let text = model.editDraft
        model.finishEditing()
        store.rename(id: id, to: text)
    }

    private func focusForCurrentScreen() {
        if model.showingSettings {
            model.enterList()
            return
        }
        switch model.mode {
        case .input: model.requestInputFocus()
        case .list: model.enterList()
        }
    }

    func hide() {
        // A recorder that is still armed must be disarmed here. The capture
        // view asks for the keyboard a runloop turn after it is armed, so if
        // the panel is hidden in that window it was never first responder and
        // nothing else will ever bring the recorder back down — leaving
        // `HotKeyCenter` in recording mode, where it goes on ignoring the
        // panel's own hotkey. ⌥Space would then do nothing at all, silently.
        HotKeyCenter.shared.endRecording()

        // An open edit would otherwise be abandoned mid-word with the caret no
        // longer anywhere, and the next one would start from a half-typed title.
        if model.editing != nil { commitEdit() }

        // Closing the panel is a way of leaving a blank sub-task row, and the
        // rule for that — take the row, and with it the "opened" flag — lives
        // in `PanelView.hideDraftRow(for:)`. This is the one route the view
        // cannot see, because the panel is on its way out and nothing is
        // driving it. The loop stays; the rule does not get restated.
        for parent in model.discardUnusedDraftRows() {
            store.collapseIfChildless(id: parent)
        }

        guard let window else { return }
        window.orderOut(nil)
        window.resignKey()

        // Hand focus back to whatever was in front. `NSApp.hide` would also
        // work but it changes the app's own visibility state, which an agent
        // app has no use for.
        NSApp.keyWindow?.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: false)
    }

    // MARK: - Window

    private func makeWindow() -> KeyWindow {
        let window = KeyWindow(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Above the normal window level, which is what `.floating` already
        // gave us — and still not high enough. Apps that go fullscreen often
        // raise their own window, and the panel then lands *behind* the very
        // thing it was summoned over: invisible on a fullscreen app, perfectly
        // visible on the desktop, which is a maddening combination to tell from
        // the outside. `.statusBar` clears the levels apps reach for while
        // presenting, without floating over the menu bar itself.
        window.level = .statusBar

        // Belongs to every Space, so the hotkey behaves the same from a
        // fullscreen app as from the desktop. `.fullScreenAuxiliary` is what
        // allows it to be drawn there at all; without it the window exists in
        // that Space's terms but is never shown. `.stationary` keeps it from
        // animating across during a Space switch.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        window.contentView = NSHostingView(
            rootView: PanelView(
                store: store,
                model: model,
                onClose: { [weak self] in self?.hide() }
            )
        )

        return window
    }

    /// Puts the panel in the middle of the display, wherever the pointer is.
    ///
    /// Centred on `frame`, not on `visibleFrame` — and the difference is 16.5pt
    /// on this Mac. `visibleFrame` reserves the menu bar *even when it is set to
    /// auto-hide and is not on screen*, so centring in it pushed the panel below
    /// the middle of the display every time, for a menu bar nobody can see.
    /// Measured: the window was landing at y 238 when the middle is y 221.
    ///
    /// Clamped afterwards so centring can never put the panel where something
    /// would cover it. A Dock, or a menu bar that *is* showing, eats into the
    /// usable area, and a panel behind the Dock is worse than one notch off
    /// centre. On a screen too small to hold it, the clamp gives up and lets it
    /// overflow rather than shoving it somewhere arbitrary.
    private func center(_ window: NSWindow) {
        guard let screen = activeScreen() else { return }
        let size = window.frame.size

        var x = screen.frame.midX - size.width / 2
        var y = screen.frame.midY - size.height / 2

        let visible = screen.visibleFrame
        x = min(max(x, visible.minX), max(visible.minX, visible.maxX - size.width))
        y = min(max(y, visible.minY), max(visible.minY, visible.maxY - size.height))

        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Prefers the display the pointer is on, so the panel appears where the
    /// user is looking on a multi-monitor setup.
    private func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}