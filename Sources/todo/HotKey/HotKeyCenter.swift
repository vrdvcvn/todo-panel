import Foundation
import os

/// Owns the two global hotkeys and lets them be changed at runtime.
///
/// Registration lives here rather than in `AppDelegate` so that recording a new
/// shortcut can re-register immediately instead of needing a restart — the
/// whole point of a recorder is being able to try a combination and feel it
/// straight away.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var openKey: GlobalHotKey?
    private var quitKey: GlobalHotKey?

    /// Set while the recorder is waiting for a keypress, so that pressing the
    /// combination currently bound to "open" does not also toggle the panel
    /// out from under the person recording.
    private(set) var isRecording = false

    private init() {}

    func beginRecording() { isRecording = true }
    func endRecording() { isRecording = false }

    // MARK: - Errors

    struct Conflict: Error {
        let shortcut: Shortcut
        let role: Role

        enum Role { case open, quit }
    }

    enum RegistrationError: Error {
        case conflict(Conflict)
        case noModifiers
    }

    // MARK: - Registration

    func registerAll(
        onOpen: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) throws {
        unregisterAll()

        guard let newOpen = GlobalHotKey(
            keyCode: ShortcutStore.open.keyCode,
            modifiers: ShortcutStore.open.modifiers,
            action: onOpen
        ) else {
            throw RegistrationError.conflict(.init(shortcut: ShortcutStore.open, role: .open))
        }
        openKey = newOpen

        guard let newQuit = GlobalHotKey(
            keyCode: ShortcutStore.quit.keyCode,
            modifiers: ShortcutStore.quit.modifiers,
            action: onQuit
        ) else {
            unregisterAll()
            throw RegistrationError.conflict(.init(shortcut: ShortcutStore.quit, role: .quit))
        }
        quitKey = newQuit

        Diag.log("hotkeys: open=\(ShortcutStore.open.display) quit=\(ShortcutStore.quit.display)")
    }

    /// Adopts a newly recorded shortcut. If the combination turns out to be
    /// taken, the previous one is put back — leaving the app with no way to be
    /// summoned would be worse than refusing the change.
    func apply(_ shortcut: Shortcut, for role: Conflict.Role) throws {
        let previous = role == .open ? ShortcutStore.open : ShortcutStore.quit
        guard shortcut != previous else { return }

        if role == .open { ShortcutStore.open = shortcut } else { ShortcutStore.quit = shortcut }

        do {
            try AppDelegate.shared?.registerHotKeys()
        } catch {
            if role == .open { ShortcutStore.open = previous } else { ShortcutStore.quit = previous }
            try? AppDelegate.shared?.registerHotKeys()
            throw error
        }
    }

    func unregisterAll() {
        openKey?.unregister()
        quitKey?.unregister()
        openKey = nil
        quitKey = nil
    }
}