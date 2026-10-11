import Foundation

/// Hands the "show the panel" shortcut over to `todo-keep` while the app is
/// closed.
///
/// A global hotkey only exists inside the process that registered it. Quit
/// `todo` and macOS forgets the shortcut entirely, so there is nothing left to
/// catch ⌥Space — which is why the panel could only ever be summoned while it
/// was already open. `todo-keep` is a ~4 MB watcher that takes the shortcut in
/// the gap and starts the app when it is pressed.
///
/// The two stand down for each other, so only one is ever running: this starts
/// the watcher on the way out, and the watcher exits as soon as it sees the app
/// come up. That is what makes the idle cost zero rather than an extra process
/// on top of the usual one.
enum HotKeyKeeper {
    /// `todo.app/Contents/Library/LoginItems/todo-keep.app/Contents/MacOS/todo-keep`.
    ///
    /// A nested bundle of its own, not a second file in `Contents/MacOS` — see
    /// the note in `build-app.sh` about why sharing the app's bundle identifier
    /// breaks both the UserDefaults read and the launch.
    static var executableURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems/todo-keep.app/Contents/MacOS/todo-keep")
    }

    /// Starts the watcher. Called as the app is quitting, so the shortcut
    /// survives the quit.
    static func spawn() {
        let url = executableURL
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            Diag.log("todo-keep is missing from the bundle; the shortcut will not work while quit")
            return
        }

        let process = Process()
        process.executableURL = url
        // The watcher logs for itself. Inheriting our handles would keep the
        // parent's stdout open for as long as it lives, which outlives us.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            Diag.log("started todo-keep (pid \(process.processIdentifier))")
        } catch {
            Diag.log("could not start todo-keep: \(error.localizedDescription)")
        }
    }

    /// Stops any watcher left over from a previous run.
    ///
    /// The watcher already watches for the app and stands down on its own, so
    /// this is belt and braces — but "both processes hold the same shortcut"
    /// makes the panel open and close again in the same keystroke, and a race
    /// that only shows up occasionally is worse than one that cannot happen.
    static func stopStrays() {
        let running = Process()
        running.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        running.arguments = ["-x", "todo-keep"]
        running.standardOutput = FileHandle.nullDevice
        running.standardError = FileHandle.nullDevice
        try? running.run()
        running.waitUntilExit()
    }
}
