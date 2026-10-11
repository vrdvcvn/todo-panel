import Foundation

/// A single todo entry.
///
/// This replaces Medo's Core Data `Task` entity. Core Data was dropped because
/// Swift Package Manager has no model compiler (`momc`), so a
/// `.xcdatamodeld` bundle simply cannot be built without Xcode installed.
/// A `Codable` struct gets us the same persistence in a fraction of the code
/// and noticeably less resident memory.
///
/// The `priority` attribute present in the Medo original was intentionally
/// dropped: the brief is a plain list, nothing more.
struct TodoItem: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var done: Bool
    var createdAt: Date

    /// When the task was ticked off, or `nil` while it is open.
    ///
    /// Needed because "newest" means different things for the two groups: an
    /// open task is newest by when you wrote it, but a finished one is newest
    /// by when you finished it. Sorting completed tasks by `createdAt` would
    /// bury the one you just finished under tasks finished days ago.
    var completedAt: Date?

    /// The task this one sits under, or `nil` for a top-level task.
    ///
    /// The list is stored flat and drawn as a tree, rather than nesting a
    /// `children` array inside each item. Flat storage keeps a multi-delete, an
    /// undo or a re-sort to a single array operation instead of a recursive
    /// rewrite of the document, and a subtask cannot end up in a cycle.
    var parentID: UUID?

    /// Whether this task has been opened to show its sub-tasks.
    ///
    /// The positive form, not "collapsed", because the state has three values
    /// and a Bool cannot hold them: never opened, opened, closed. A task that
    /// has never been opened has no sub-tasks *and* no blank row, which is
    /// exactly what a list of flat tasks should look like — so "closed" and
    /// "never opened" have to be different, and only `expanded` says which.
    var expanded: Bool

    init(
        id: UUID = UUID(),
        title: String,
        done: Bool = false,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        parentID: UUID? = nil,
        expanded: Bool = false
    ) {
        self.id = id
        self.title = title
        self.done = done
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.parentID = parentID
        self.expanded = expanded
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, done, createdAt, completedAt, parentID, expanded
    }

    /// Tolerates files written before `completedAt` existed, and back-fills it
    /// from `createdAt` so an already-finished task still sorts sensibly.
    ///
    /// `parentID` and `expanded` are optional for the same reason: a list
    /// written by an earlier build is simply a list of top-level tasks, with
    /// nothing open. Reading it must not require the user to go through
    /// the settings screen and re-save to make the file look new.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        done = try container.decodeIfPresent(Bool.self, forKey: .done) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        if done, completedAt == nil { completedAt = createdAt }
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
        expanded = try container.decodeIfPresent(Bool.self, forKey: .expanded) ?? false
    }
}