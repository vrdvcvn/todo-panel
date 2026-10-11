# todo

Derived from **[Medo](https://github.com/Aayush9029/Medo)** by Aayush Pokharel —
a minimal open-source macOS todo app. Medo provided the panel layout, the
floating-window approach and the `KeyWindow` trick that lets a background agent
app take keyboard focus.

## Changes from the original

Medo is a menu bar app with priorities, timestamps, URL schemes, a preferences
window and Core Data persistence. `todo` keeps the good parts and drops the
rest:

| | Medo | todo |
|---|---|---|
| Entry point | SwiftUI `App` lifecycle | AppKit `NSApplication` delegate |
| Presence | `MenuBarExtra` in the menu bar | Nothing — no Dock icon, no menu bar item |
| Show/hide | menu commands | Global hotkeys, Carbon `RegisterEventHotKey` |
| Persistence | Core Data | `Codable` → `todos.json` |
| Features | priorities, timestamps, deep links, stats | a plain list |
| Project | `.xcodeproj`, needs Xcode | Swift Package Manager, needs only Command Line Tools |

Core Data was not a stylistic choice: Swift Package Manager has no model
compiler, so a `.xcdatamodeld` bundle cannot be built without Xcode installed.

## Also derived from

- **[soffes/HotKey](https://github.com/soffes/HotKey)** (MIT), itself inspired
  by PTHotKey — the Carbon `RegisterEventHotKey` wrapper in
  `Sources/todo/HotKey/GlobalHotKey.swift`, reduced to what this app needs.

`todo` is distributed under Medo's GPL-3.0 licence; see `LICENSE`.