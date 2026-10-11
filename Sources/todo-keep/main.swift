import AppKit
import Carbon.HIToolbox
import Foundation

// todo-keep — holds the "show the panel" shortcut while `todo.app` is not running.
//
// macOS only delivers a global hotkey to a process that registered it, and a
// RegisterEventHotKey registration dies with the process. So the moment todo is
// quit there is, by definition, nothing listening for ⌥Space. This is that
// something: a deliberately tiny watcher that takes the shortcut, starts todo,
// and gets out of the way.
//
// The hand-off runs both ways so that only one of the two is ever alive:
//   - todo quits        → todo starts this
//   - this starts todo  → this exits
//   - this sees todo    → this exits (covers todo being relaunched from
//                         Spotlight, or started by something else entirely)
// That is what keeps the cost at zero: while the panel is closed you are paying
// for this process instead of the app, not as well as it.
//
// A few dozen lines of the main app are duplicated rather than shared, because
// SwiftPM cannot make one executable target import another. The duplicated
// pieces are deliberately boring — the stored shortcut and the Carbon
// registration — and they must stay in step with `HotKey/Shortcut.swift` and
// `HotKey/GlobalHotKey.swift` in the main target. The defaults key and the
// Codable shape are the contract between them.

// MARK: - The contract with the main app

/// Must match `CFBundleIdentifier` in `build-app.sh`: the main app writes the
/// shortcut to its own standard defaults, and this reads it back by suite.
private let appBundleID = "com.arda.todo"

/// Must match `ShortcutStore.openKey`.
private let openShortcutKey = "todo.shortcut.open"

/// Deliberately blocking. This runs before `NSApplication.run()`, so there is
/// no run loop to schedule on yet, and the whole point is that nothing should
/// happen until todo has finished going.
private func waitForAppToExit(timeout: TimeInterval) {
    let deadline = Date().addingTimeInterval(timeout)
    while isAppRunning(), Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
    }
}

/// Mirrors `HotKey/Shortcut.swift`. Only `Decodable` — this never saves.
private struct Shortcut: Decodable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// Mirrors `Shortcut.defaultOpen` — ⌥Space.
    static let fallback = Shortcut(keyCode: 49, modifiers: UInt32(optionKey))
}

/// Reads the shortcut the app stored.
///
/// By suite, not `standard`: this process has a bundle of its own, so its
/// standard defaults are `com.arda.todo.keep` and would never see what the app
/// wrote. Asking for a suite under the app's identifier is only legitimate
/// because the two identifiers differ — AppKit refuses ("does not make sense")
/// when a process asks for a suite named after its own bundle.
private func loadOpenShortcut() -> Shortcut {
    guard
        let defaults = UserDefaults(suiteName: appBundleID),
        let data = defaults.data(forKey: openShortcutKey),
        let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data)
    else { return .fallback }
    return shortcut
}

/// `…/todo.app/Contents/Library/LoginItems/todo-keep.app/Contents/MacOS/todo-keep`
/// → `…/todo.app`.
///
/// Derived from this binary's own path rather than hard-coded to
/// `/Applications`, so moving or reinstalling the app cannot break it. Note the
/// seven steps: this lives in a *nested* app bundle, because sharing
/// `todo.app` outright makes this process indistinguishable from the real thing
/// to both LaunchServices and UserDefaults — see `isAppRunning` and
/// `loadOpenShortcut`.
private var appURL: URL {
    URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()  // MacOS
        .deletingLastPathComponent()  // Contents
        .deletingLastPathComponent()  // todo-keep.app
        .deletingLastPathComponent()  // LoginItems
        .deletingLastPathComponent()  // Library
        .deletingLastPathComponent()  // Contents
        .deletingLastPathComponent()  // todo.app
}

/// Whether the real app is up.
///
/// Safe to ask directly only because this binary has a bundle of its own
/// (`com.arda.todo.keep`). An earlier version sat directly in `todo.app/Contents/
/// MacOS`, where AppKit resolved our main bundle to the same identifier as the
/// app's — so this function cheerfully reported *itself*, waited out its
/// handover, concluded todo was running and quit about five seconds after every
/// start. The same confusion then made `NSWorkspace` "launch" this process
/// instead of the app.
private func isAppRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID).isEmpty
}

// MARK: - Log

/// A log of its own, beside the app's. The two are never alive at the same
/// time, so there is no interleaving to worry about, and if one is clobbered
/// the other still explains itself.
private let dataDirectory = (FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)
    .first
    ?? URL(fileURLWithPath: NSTemporaryDirectory()))
    .appendingPathComponent("todo", isDirectory: true)

private let logURL = dataDirectory.appendingPathComponent("todo-keep.log")

private func log(_ message: String) {
    let line = "[\(Date())] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }

    // A silent `try?` here would mean the one tool for working out why the
    // shortcut is not being caught is the thing that quietly fails.
    do {
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: logURL.path) {
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: logURL)
        }
    } catch {
        FileHandle.standardError.write(Data("todo-keep: log failed (\(error))\n".utf8))
    }
}

// MARK: - The hotkey

/// Deliberately different from the main app's 'TODO' signature. They should
/// never both be alive, but if they somehow are, this stops the two processes
/// from claiming each other's events.
private let signature: OSType = 0x5444_4F4B // 'TDOK'

private var heldHotKey: EventHotKeyRef?
private var onPress: (() -> Void)?

/// C callback. Cannot capture context, so it hands off to `onPress`.
private func hotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

    var id = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &id
    )

    guard status == noErr, id.signature == signature else {
        return OSStatus(eventNotHandledErr)
    }
    onPress?()
    return noErr
}

private func installHandler() -> Bool {
    var spec = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed)
    )
    var handlerRef: EventHandlerRef?
    let status = InstallEventHandler(
        GetApplicationEventTarget(),
        hotKeyEventHandler,
        1,
        &spec,
        nil,
        &handlerRef
    )
    return status == noErr
}

private func register(_ shortcut: Shortcut) -> OSStatus {
    var reference: EventHotKeyRef?
    let status = RegisterEventHotKey(
        shortcut.keyCode,
        shortcut.modifiers,
        EventHotKeyID(signature: signature, id: 1),
        GetApplicationEventTarget(),
        0,
        &reference
    )
    heldHotKey = status == noErr ? reference : nil
    return status
}

/// Gives the hotkey up before todo is started.
///
/// The order matters. If todo registers the same combination while this process
/// still holds it, macOS delivers the keypress to both and the panel opens and
/// then immediately closes again — which looks exactly like a broken hotkey.
private func release() {
    if let heldHotKey {
        UnregisterEventHotKey(heldHotKey)
    }
    heldHotKey = nil
}

// MARK: - Main

private let application = NSApplication.shared
// A watcher with no windows: no Dock icon, no menu bar item, and no way for it
// to steal focus from whatever the user is doing.
application.setActivationPolicy(.prohibited)

// todo starts us from `applicationWillTerminate`, so at the instant we appear
// the app is almost certainly *still* — it has not finished exiting yet. Testing
// that and standing down would break the hand-off every single time, so wait
// for the app to actually go first. The shortcut belongs to whichever of us is
// alive, and for a moment there are two of us.
waitForAppToExit(timeout: 5)

if isAppRunning() {
    // It never left, so it owns the shortcut and we are redundant.
    log("todo is running and did not exit; standing down")
    exit(0)
}

private let shortcut = loadOpenShortcut()
log("started keyCode=\(shortcut.keyCode) modifiers=\(shortcut.modifiers)")

guard installHandler() else {
    log("InstallEventHandler failed")
    exit(1)
}

let status = register(shortcut)
if status != noErr {
    log("could not register hotkey, status=\(status)")
    exit(1)
}

onPress = {
    log("shortcut pressed; starting todo")
    release()

    // `--show` is what makes the panel come up rather than just the process
    // starting in the background.
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = false
    configuration.arguments = ["--show"]
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
        if let error {
            log("could not start todo: \(error.localizedDescription)")
        } else {
            log("started todo")
        }
        exit(0)
    }
}

// The other half of the hand-off. A timer rather than a notification because it
// also has to cope with todo being started by something other than this
// process — Spotlight, a login item, or the user double-clicking it.
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    if isAppRunning() {
        log("todo is running; standing down")
        exit(0)
    }
}

application.run()
