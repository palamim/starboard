import AppKit
import SwiftTerm

/// Whether a theme pins light/dark chrome, or follows the system appearance.
enum ThemeAppearance: String, Codable, CaseIterable {
    case dark
    case light
    /// Resolves to Ocean in dark mode and Light in light mode at apply time.
    case system
}

/// One complete look for the panel: chrome tint, terminal foreground, ANSI
/// palette, and font. Built-ins live in `Theme.builtIns`; user overrides
/// layer on top via `ThemeStore`.
struct Theme {
    var name: String
    var panelTint: NSColor
    var foreground: NSColor
    /// Edge stroke on the blurred panel. Light themes need a dark stroke;
    /// dark themes keep the faint white highlight.
    var borderColor: NSColor
    /// Exactly 16 SwiftTerm `Color`s (ANSI 0-15).
    var ansi: [Color]
    /// Preferred PostScript/family name; nil means walk `preferredFontNames`.
    var fontName: String?
    var fontSize: CGFloat
    var appearance: ThemeAppearance

    /// Preferred terminal fonts, best first. Nerd Font variants come ahead
    /// of plain Menlo because prompt themes like Powerlevel10k draw their
    /// separators and icons from the Nerd Font private-use ranges that no
    /// stock macOS font carries. The first name that resolves wins.
    static let preferredFontNames = [
        "MesloLGS NF",
        "MesloLGS Nerd Font",
        "Hack Nerd Font",
        "FiraCode Nerd Font",
        "JetBrainsMono Nerd Font",
        "Menlo",
    ]

    static let defaultFontSize: CGFloat = 11

    /// Cycle order for Cmd+T.
    static let builtInOrder = ["ocean", "dark", "light", "system"]

    static var builtIns: [String: Theme] {
        [
            ocean.name: ocean,
            dark.name: dark,
            light.name: light,
            system.name: system,
        ]
    }

    /// Current default — muted ocean blues/teals, port/starboard red/green.
    static let ocean = Theme(
        name: "ocean",
        panelTint: NSColor(calibratedRed: 0.02, green: 0.035, blue: 0.06, alpha: 0.65),
        foreground: NSColor(calibratedWhite: 0.92, alpha: 1),
        borderColor: NSColor.white.withAlphaComponent(0.2),
        ansi: [
            ansiColor(20, 24, 33),    // black
            ansiColor(198, 74, 90),   // red — port light
            ansiColor(79, 157, 105),  // green — starboard light
            ansiColor(196, 154, 62),  // yellow — brass
            ansiColor(58, 124, 165),  // blue — deep ocean
            ansiColor(133, 110, 168), // magenta — dusk
            ansiColor(69, 156, 156),  // cyan — seafoam
            ansiColor(196, 190, 172), // white — sand
            ansiColor(75, 87, 99),    // bright black — slate
            ansiColor(222, 102, 118), // bright red
            ansiColor(111, 191, 135), // bright green
            ansiColor(224, 186, 105), // bright yellow
            ansiColor(95, 168, 211),  // bright blue
            ansiColor(169, 143, 201), // bright magenta
            ansiColor(114, 214, 207), // bright cyan
            ansiColor(230, 224, 208), // bright white — foam
        ],
        fontName: nil,
        fontSize: defaultFontSize,
        appearance: .dark
    )

    /// Neutral dark — less blue in the chrome, slightly punchier ANSI.
    static let dark = Theme(
        name: "dark",
        panelTint: NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.06, alpha: 0.72),
        foreground: NSColor(calibratedWhite: 0.90, alpha: 1),
        borderColor: NSColor.white.withAlphaComponent(0.18),
        ansi: [
            ansiColor(30, 30, 34),
            ansiColor(220, 80, 80),
            ansiColor(90, 180, 110),
            ansiColor(210, 170, 70),
            ansiColor(80, 140, 220),
            ansiColor(170, 120, 200),
            ansiColor(70, 180, 180),
            ansiColor(210, 210, 210),
            ansiColor(90, 90, 96),
            ansiColor(255, 110, 110),
            ansiColor(120, 210, 140),
            ansiColor(240, 200, 100),
            ansiColor(120, 170, 255),
            ansiColor(200, 150, 230),
            ansiColor(100, 220, 220),
            ansiColor(245, 245, 245),
        ],
        fontName: nil,
        fontSize: defaultFontSize,
        appearance: .dark
    )

    /// Airier chrome for bright desktops — still a *dark terminal*.
    ///
    /// Cursor Agent (and similar Ink TUIs) probe the host for light/dark
    /// and, in light mode, currently paint black prompt bars while using
    /// dark default foreground — unreadable. A paper-white Starboard
    /// theme trips that path via OSC 11 / COLORFGBG. So "light" here means
    /// a loftier panel tint with light text and a dark-terminal ANSI
    /// palette, not an inverted light-terminal. TUIs stay on their dark
    /// theme and remain legible.
    static let light = Theme(
        name: "light",
        panelTint: NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.24, alpha: 0.50),
        foreground: NSColor(calibratedWhite: 0.93, alpha: 1),
        borderColor: NSColor.white.withAlphaComponent(0.28),
        ansi: ocean.ansi,
        fontName: nil,
        fontSize: defaultFontSize,
        appearance: .dark
    )

    /// Follows `NSApp.effectiveAppearance`; visual tokens come from Ocean
    /// or Light at resolve time so we don't duplicate palettes here.
    static let system = Theme(
        name: "system",
        panelTint: ocean.panelTint,
        foreground: ocean.foreground,
        borderColor: ocean.borderColor,
        ansi: ocean.ansi,
        fontName: nil,
        fontSize: defaultFontSize,
        appearance: .system
    )

    /// If this theme is `.system`, return Ocean or Light for the current
    /// appearance; otherwise return self. Preserves `name` as "system"
    /// when resolving so the config key doesn't flip under the user.
    func resolved(isDark: Bool) -> Theme {
        guard appearance == .system else { return self }
        var base = isDark ? Theme.ocean : Theme.light
        base.name = name
        base.appearance = .system
        base.fontName = fontName
        base.fontSize = fontSize
        return base
    }

    static func resolveFont(name: String?, size: CGFloat) -> NSFont {
        if let name, let font = NSFont(name: name, size: size) {
            return font
        }
        return preferredFontNames.lazy.compactMap { NSFont(name: $0, size: size) }.first
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// `Color`'s public initializer takes 16-bit (0...65535) components;
    /// this takes the familiar 8-bit (0...255) form and scales up
    /// (`* 257` maps 0...255 onto 0...65535 exactly).
    static func ansiColor(_ red: UInt16, _ green: UInt16, _ blue: UInt16) -> Color {
        Color(red: red * 257, green: green * 257, blue: blue * 257)
    }
}

/// File-private alias so built-in palette literals stay readable.
private func ansiColor(_ red: UInt16, _ green: UInt16, _ blue: UInt16) -> Color {
    Theme.ansiColor(red, green, blue)
}
