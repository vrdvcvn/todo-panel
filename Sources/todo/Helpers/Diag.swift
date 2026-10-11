import Foundation
import OSLog

/// Tiny append-only diagnostic log.
///
/// `os_log` is the right tool on macOS but it is awkward to inspect from a
/// terminal. `verify.sh` and any debugging session reads this file directly, so
/// failures (a hotkey that could not be registered, a store that could not be
/// written) leave a trace you can actually see.
enum Diag {
    private static let logger = Logger(subsystem: "com.arda.todo", category: "todo")

    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static var logFileURL: URL {
        TodoStore.directoryURL().appendingPathComponent("todo.log")
    }

    static func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")

        let line = "[\(formatter.string(from: Date()))] \(message)\n"

        lock.lock()
        defer { lock.unlock() }

        let directory = TodoStore.directoryURL()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // The log file will not exist on first run, but its directory already
        // will, because the store created it — so "the directory exists" is
        // not a reason to skip writing.
        guard FileManager.default.fileExists(atPath: logFileURL.path) else {
            try? Data(line.utf8).write(to: logFileURL)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: logFileURL) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    }
}