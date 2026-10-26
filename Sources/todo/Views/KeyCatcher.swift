import AppKit
import SwiftUI

/// An invisible view that becomes first responder while the list has focus.
///
/// The panel has two input modes. In `.input` the caret is in `PromptField`
/// and typing goes into the draft. In `.list` nothing is editable, so this
/// view takes the keys instead and routes them to the panel.
///
/// Routing through a real `NSView` rather than SwiftUI's `.onKeyPress` is
/// deliberate: key handling then depends only on the responder chain, which is
/// fully predictable, instead of on SwiftUI's focus resolution across a
/// `ScrollView` that also wants arrow keys.
struct KeyCatcher: NSViewRepresentable {
    /// Bumped to ask for first responder; see `PromptField` for why this is a
    /// token rather than a `Bool`.
    let focusToken: Int
    /// Returns `true` if the event was consumed.
    let onKey: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.onKey = onKey
        context.coordinator.lastFocusToken = focusToken
        return view
    }

    func updateNSView(_ view: KeyCatcherView, context: Context) {
        view.onKey = onKey

        guard context.coordinator.lastFocusToken != focusToken else { return }

        // Deferred, and the token is only spent once the keyboard is actually
        // here. This is the one focus request that arrives from inside a
        // gesture callback — clicking a task — and taking first responder
        // mid-SwiftUI-pass is swallowed often enough to matter. Spending the
        // token on a request that did not happen made it worse: the highlight
        // said the list had the keyboard while the caret was still in the
        // prompt, so Space typed a space and Delete edited text.
        guard focusToken > 0 else {
            context.coordinator.lastFocusToken = focusToken
            return
        }

        DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
            guard let view, let window = view.window else { return }
            coordinator?.lastFocusToken = focusToken
            window.makeFirstResponder(view)
        }
    }

    final class Coordinator: NSObject {
        var lastFocusToken: Int = 0
    }
}

final class KeyCatcherView: NSView {
    var onKey: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if let onKey, onKey(event) { return }
        super.keyDown(with: event)
    }

    // The enclosing ScrollView grabs the arrow keys for scrolling. Consuming
    // them here keeps list navigation under our own control.
    override func scrollWheel(with event: NSEvent) {}
}