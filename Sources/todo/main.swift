import AppKit

// Entry point.
//
// We deliberately use the classic AppKit application lifecycle rather than the
// SwiftUI `App` lifecycle. `todo` is a background agent with no windows and no
// menu bar item, and it needs two things SwiftUI's lifecycle does not give us
// reliably:
//
//   1. `applicationShouldHandleReopen`, so clicking "todo" in Spotlight while it
//      is already running re-opens the panel instead of silently doing nothing.
//   2. Full control over the activation policy.
//
// LSUIElement in Info.plist already keeps us out of the Dock and the menu bar;
// setting the policy explicitly as well makes the intent obvious.

// Before anything touches the app: the self-test runs and exits, so it never
// registers a hotkey, never writes to the real todo list, and leaves nothing
// running behind it.
if CommandLine.arguments.contains("--selftest") {
    MainActor.assumeIsolated { SelfTest.run() }
}

let application = NSApplication.shared

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}