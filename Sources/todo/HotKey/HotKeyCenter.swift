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
        /// Re-registering needs a live delegate to ask. Reported separately
        /// because the recorder shows every error as "already taken", and
        /// telling somebody their combination is taken when the real problem is
        /// that nothing could be registered with is worse than saying nothing.
        case appUnavailable
    }

    // MARK: - Registration

    func registerAll(
        onOpen: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) throws {
        unregisterAll()

        // Both are attempted even when the first one fails.
        //
        // They used to be registered in sequence with an early `throw`, so a
        // combination another app already owned — almost always ⌥Space, which
        // other hotkey managers like — also cost us ⌃⌥⌘Q. The result is the
        // worst outcome available to an app with no Dock icon and no menu bar
        // item: running, impossible to summon, and impossible to stop except
        // from Activity Monitor.
        openKey = GlobalHotKey(
            keyCode: ShortcutStore.open.keyCode,
            modifiers: ShortcutStore.open.modifiers,
            action: onOpen
        )
        quitKey = GlobalHotKey(
            keyCode: ShortcutStore.quit.keyCode,
            modifiers: ShortcutStore.quit.modifiers,
            action: onQuit
        )

        // Says what actually registered, not what was asked for. The log is the
        // only place a refused shortcut is visible at all, and a line claiming
        // both are live when one is not is worse than none.
        Diag.log(
            "hotkeys: open=\(openKey == nil ? "REFUSED \(ShortcutStore.open.display)" : ShortcutStore.open.display)"
            + " quit=\(quitKey == nil ? "REFUSED \(ShortcutStore.quit.display)" : ShortcutStore.quit.display)"
        )

        // Reported worst-first: not being able to summon the panel is the more
        // serious of the two, so it is the one that decides the thrown error.
        if openKey == nil {
            throw RegistrationError.conflict(.init(shortcut: ShortcutStore.open, role: .open))
        }
        if quitKey == nil {
            throw RegistrationError.conflict(.init(shortcut: ShortcutStore.quit, role: .quit))
        }
    }

    /// Adopts a newly recorded shortcut. If the combination turns out to be
    /// taken, the previous one is put back — leaving the app with no way to be
    /// summoned would be worse than refusing the change.
    func apply(_ shortcut: Shortcut, for role: Conflict.Role) throws {
        let previous = role == .open ? ShortcutStore.open : ShortcutStore.quit
        guard shortcut != previous else { return }

        // Re-registering needs the delegate. Optional-chaining through a nil
        // one would swallow the whole operation: the new combination would be
        // written to disk and reported as a success while never being
        // registered, so the box would show a shortcut that does nothing.
        guard let app = AppDelegate.shared else {
            throw RegistrationError.appUnavailable
        }

        if role == .open { ShortcutStore.open = shortcut } else { ShortcutStore.quit = shortcut }

        do {
            try app.registerHotKeys()
        } catch {
            if role == .open { ShortcutStore.open = previous } else { ShortcutStore.quit = previous }
            try? app.registerHotKeys()
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