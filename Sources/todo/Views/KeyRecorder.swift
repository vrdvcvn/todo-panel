import AppKit
import SwiftUI

/// Click to arm, then press the combination you want.
///
/// The capture view is a real `NSView` taking first responder rather than
/// SwiftUI's `.onKeyPress`, because a recorder has to see the key *before* the
/// text field does and has to keep seeing it while only modifiers are held —
/// which needs the responder chain, not SwiftUI's focus model.
struct KeyRecorder: View {
    let role: HotKeyCenter.Conflict.Role
    let onConflict: (String) -> Void

    @State private var isRecording = false

    private var current: Shortcut {
        role == .open ? ShortcutStore.open : ShortcutStore.quit
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(isRecording ? Theme.background : Theme.raised)

            Text(isRecording ? "press keys…" : current.display)
                .font(Theme.settingsLabel)
                .foregroundStyle(isRecording ? Theme.accent : Theme.primary)
                .lineLimit(1)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isRecording ? Theme.accent : Theme.border, lineWidth: 1)
        )
        .frame(height: 21)
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onTapGesture { beginRecording() }
        .background(captureLayer)
    }

    private var captureLayer: some View {
        CaptureView(
            isRecording: isRecording,
            onCapture: { shortcut in
                finish()
                adopt(shortcut)
            },
            onCancel: { finish() }
        )
        .frame(width: 0, height: 0)
    }

    private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        HotKeyCenter.shared.beginRecording()
    }

    private func finish() {
        isRecording = false
        HotKeyCenter.shared.endRecording()
    }

    private func adopt(_ shortcut: Shortcut) {
        do {
            try HotKeyCenter.shared.apply(shortcut, for: role)
        } catch {
            onConflict("that combination is already taken")
        }
    }
}

private struct CaptureView: NSViewRepresentable {
    let isRecording: Bool
    let onCapture: (Shortcut) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> CaptureNSView {
        let view = CaptureNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ view: CaptureNSView, context: Context) {
        view.onCapture = onCapture
        view.onCancel = onCancel
        guard isRecording else { return }
        // Focus on the next runloop turn: this is called during a SwiftUI
        // layout pass, and taking first responder mid-pass is unreliable.
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }

    final class CaptureNSView: NSView {
        var onCapture: ((Shortcut) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            let shortcut = Shortcut(event: event)

            // Plain Escape backs out without changing anything.
            if shortcut.keyCode == 53, shortcut.modifiers == 0 {
                onCancel?()
                return
            }

            // A bare key with no modifier would swallow that key everywhere on
            // the system — a global shortcut for, say, Space would break typing
            // in every app. Require at least one modifier.
            guard shortcut.modifiers != 0 else {
                NSSound.beep()
                return
            }

            onCapture?(shortcut)
        }

        // Modifiers alone arrive here, not in keyDown. Nothing to do — the
        // recorder shows a static prompt — but the override keeps them from
        // bubbling into the panel.
        override func flagsChanged(with event: NSEvent) {}
    }
}