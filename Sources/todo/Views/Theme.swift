import AppKit
import SwiftUI

/// Terminal-flavoured palette: near-black surfaces, one accent green used for
/// the prompt marker, the "done" tick, the login toggle and the expanded list
/// marker, and one red for errors. Nothing else — there is deliberately no
/// second accent to drift out of step with it.
enum Theme {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.067)
    static let surface = Color(red: 0.082, green: 0.086, blue: 0.102)
    static let raised = Color(red: 0.125, green: 0.129, blue: 0.149)
    static let border = Color(red: 0.18, green: 0.19, blue: 0.22)
    /// Selected row. Clearly lighter than `surface` — that is only 7 levels
    /// above the background, which is too quiet to trust when you are picking a
    /// row with the pointer.
    static let selection = Color(red: 0.145, green: 0.150, blue: 0.180)
    static let primary = Color(red: 0.85, green: 0.87, blue: 0.90)
    static let dim = Color(red: 0.42, green: 0.45, blue: 0.50)
    static let accent = Color(red: 0.35, green: 0.82, blue: 0.55)
    static let danger = Color(red: 0.98, green: 0.42, blue: 0.40)

    /// One radius for the panel's fill, its hairline and its clip.
    ///
    /// They were three separate `14`s at one point, which is three chances to
    /// be wrong: a hairline on a different curve from the fill it outlines does
    /// not read as an edge, it reads as a mistake.
    static let cornerRadius: CGFloat = 14

    /// The hairline around the panel.
    ///
    /// `border` — the same cool grey as the dividers inside the panel, which is
    /// what keeps the panel reading as one object rather than a list with a box
    /// drawn round it. Against this background it lands near #2e3038: an edge
    /// you can see over a light wallpaper, and nothing you can name over a dark
    /// one.
    static let panelBorder = border

    static let monospaced = Font.system(size: 13.5, weight: .regular, design: .monospaced)
    static let monospacedSmall = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let promptFont = Font.system(size: 14, weight: .medium, design: .monospaced)

    /// The row's text size as an AppKit font.
    ///
    /// The inline title editor draws with this rather than with the prompt's,
    /// so that editing a task does not make its text jump. A row is 13.5pt
    /// regular and `PromptField` is 14pt medium, and the difference was visible
    /// every single time a typo was corrected.
    static let rowFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)

    /// Shared by every label in the settings popover, so the toggle and the
    /// shortcut rows are the same size rather than three different ones.
    static let settingsLabel = Font.system(size: 12, weight: .regular, design: .monospaced)

    /// Width of the leading marker column.
    ///
    /// The prompt's `>` and the task list's `[]` are different glyphs of
    /// different widths, so without a fixed column the text that follows them
    /// lands in a different place on every line. Both sit left-aligned inside
    /// this width, which puts `add a task`, every task title and the settings
    /// labels into one straight column.
    static let markerWidth: CGFloat = 26

    /// How far each level of sub-task is indented.
    ///
    /// Wide enough to read as a level at a glance, narrow enough that a long
    /// title still has most of the panel's width to wrap into — the indent comes
    /// straight out of the same column the text has to fit in.
    static let indentWidth: CGFloat = 18

    // AppKit equivalents, for the pieces SwiftUI does not draw.
    static let nsBackground = NSColor(red: 0.055, green: 0.055, blue: 0.067, alpha: 1)
    static let nsPrimary = NSColor(red: 0.85, green: 0.87, blue: 0.90, alpha: 1)
    static let nsDim = NSColor(red: 0.42, green: 0.45, blue: 0.50, alpha: 1)
}