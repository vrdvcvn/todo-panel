import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Lets the settings popover ask for the hotkeys to be re-registered after
    /// the user records a new one. Weak, because nothing should keep an app
    /// delegate alive past `NSApplication.run()`.
    static weak var shared: AppDelegate?

    /// Set by `--settings`; read by the settings popover when it is created.
    static var opensSettingsOnLaunch = false

    private let store = TodoStore()
    private lazy var panel = PanelController(store: store)

    /// `todo --settings` opens the settings popover straight away. There is no
    /// Dock icon and no menu bar item, so without this there is no way to reach
    /// the popover from a script — which makes screenshotting it impossible.
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        Self.opensSettingsOnLaunch = CommandLine.arguments.contains("--settings")
        NSApp.appearance = NSAppearance(named: .darkAqua)

        store.load()
        Diag.log("launched with \(store.items.count) item(s)")

        LoginItem.enableOnFirstRunIfNeeded()

        // Any watcher from a previous run is now redundant, and two processes
        // holding the same shortcut makes the panel flicker.
        HotKeyKeeper.stopStrays()

        try? registerHotKeys()

        // `todo --show` opens the panel at launch. There is no Dock icon and no
        // menu bar item to click, so without this there is no way to drive the
        // app from a script — which makes automated smoke testing impossible.
        if CommandLine.arguments.contains("--show") {
            panel.show()
        }

        if CommandLine.arguments.contains("--settings") {
            panel.setSettingsOpen(true)
        }
    }

    /// Clicking "todo" in Spotlight while it is already running.
    ///
    /// Without this the app is already frontmost (as an agent, it activates
    /// invisibly) and re-opening it does nothing at all, which reads as a
    /// broken app. This makes a second Spotlight click bring the panel back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show()
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Hands the shortcut to `todo-keep` on the way out, so ⌥Space still works
    /// once the app is gone.
    ///
    /// Only reached on a graceful quit — ⌃⌥⌘Q, or Quit from Spotlight. A
    /// force-quit (⌘⌥Esc) kills the process without this running, which leaves
    /// no watcher and no hotkey until todo is launched once more by hand.
    func applicationWillTerminate(_ notification: Notification) {
        HotKeyKeeper.spawn()
    }

    // MARK: - Hotkeys

    func registerHotKeys() throws {
        try HotKeyCenter.shared.registerAll(
            onOpen: { [weak self] in
                // While the recorder is armed, the combination currently bound
                // to "open" must not also toggle the panel.
                guard !HotKeyCenter.shared.isRecording else { return }
                self?.panel.toggle()
            },
            onQuit: { NSApp.terminate(nil) }
        )
    }

    /// Shown only when a shortcut is already owned by something else, which
    /// would otherwise leave the app running with no way to summon or stop it.
    func presentHotKeyFailure(_ error: Error) {
        guard case HotKeyCenter.RegistrationError.conflict(let conflict) = error else { return }

        let combo = conflict.shortcut.display
        Diag.log("hotkey conflict: \(combo) (\(conflict.role))")

        let alert = NSAlert()
        alert.messageText = "\(combo) is already taken"
        alert.informativeText = """
        Another app is using \(combo). Quit that app and change the shortcut \
        from the gear menu in todo, or pick a different combination.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "ok")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}