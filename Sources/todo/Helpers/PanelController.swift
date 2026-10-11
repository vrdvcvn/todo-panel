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
                if let editor = self.fieldEditor, !self.model.draft.isEmpty {
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
        requestFocus(forCurrentMode: model.mode)
    }

    func show() {
        // Always come back to a clean "add a task" prompt, never to whatever
        // screen or selection was live when the panel was last hidden.
        model.resetToInput()

        let window = self.window ?? makeWindow()
        self.window = window

        center(window)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()

        requestFocus(forCurrentMode: model.mode)

        // SwiftUI applies `updateNSView` during the next layout pass. Asking a
        // second time on the next runloop turn guarantees the right view really
        // is first responder by the time the user's fingers are on the keyboard,
        // rather than only usually being so.
        DispatchQueue.main.async { [weak self] in
            guard let self, window.isVisible else { return }
            self.requestFocus(forCurrentMode: model.mode)
        }
    }

    /// Settings mode has no text field at all, so focus has to go to the list
    /// key catcher — otherwise Escape has nowhere to arrive.
    private func requestFocus(forCurrentMode mode: PanelModel.Mode) {
        switch mode {
        case .input: model.requestInputFocus()
        case .list: model.enterList()
        }
    }

    func hide() {
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

    private func center(_ window: NSWindow) {
        guard let screen = activeScreen() else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(
            NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        )
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