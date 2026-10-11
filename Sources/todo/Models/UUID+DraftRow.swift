import Foundation

extension UUID {
    /// A stable identity for the blank sub-task row belonging to a parent.
    ///
    /// The blank row is not a task — nothing is saved until you type into it —
    /// but the arrow keys still have to be able to land on it and the highlight
    /// has to have something to sit on. It therefore needs an id like any other
    /// row, and that id has to be the *same* id every time: derive one and the
    /// caret stays on the row it was on, whereas a fresh `UUID()` per render
    /// would drop the highlight on every keystroke.
    ///
    /// Deriving rather than storing avoids a dictionary that has to be kept in
    /// step with the tree. The XOR keeps it out of the v4 space the tasks
    /// themselves are drawn from, so it cannot collide with a real one.
    var draftRowID: UUID {
        var copy = self
        let namespace: [UInt8] = [
            0x9E, 0x37, 0x79, 0xB9, 0x7F, 0x4A, 0x91, 0x0C,
            0xE3, 0xB8, 0x27, 0x4E, 0x2C, 0xD0, 0x6A, 0x5B,
        ]
        withUnsafeMutableBytes(of: &copy) { raw in
            for index in 0..<Swift.min(16, raw.count) {
                raw[index] ^= namespace[index]
            }
        }
        return copy
    }
}
