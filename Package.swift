// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "todo",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "todo",
            path: "Sources/todo"
        ),
        // Ships inside todo.app and holds the open shortcut while the app is
        // closed, so ⌥Space works even when todo is not running. See
        // Sources/todo-keep/main.swift for why it is a separate binary and not
        // a mode of the main one.
        .executableTarget(
            name: "todo-keep",
            path: "Sources/todo-keep"
        ),
    ]
)
