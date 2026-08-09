import AppKit
import Foundation
import SwiftTerm

/// Persisted theme selection and optional per-field overrides.
///
/// Lives at `~/Library/Application Support/Starboard/config.json`. Missing
/// file means built-in Ocean with no overrides — Starboard never requires
/// the user to create one. Cmd+, writes a starter file (if needed) and
/// opens it; Cmd+T cycles `theme` among the built-ins and saves.
struct ThemeStore {
    struct RGBA: Codable, Equatable {
        var r: Double
        var g: Double
        var b: Double
        var a: Double

        init(r: Double, g: Double, b: Double, a: Double) {
            self.r = r
            self.g = g
            self.b = b
            self.a = a
        }

        init(_ color: NSColor) {
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            let converted = color.usingColorSpace(.genericRGB) ?? color
            converted.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            r = Double(red)
            g = Double(green)
            b = Double(blue)
            a = Double(alpha)
        }

        var nsColor: NSColor {
            NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
        }
    }

    struct Config: Codable, Equatable {
        /// Built-in name: ocean, dark, light, system.
        var theme: String
        var fontName: String?
        var fontSize: Double?
        var panelTint: RGBA?
        var foreground: RGBA?
        var borderColor: RGBA?
        /// Exactly 16 `#RRGGBB` or `#RRGGBBAA` strings when present.
        var ansi: [String]?

        static let `default` = Config(theme: Theme.ocean.name)

        init(
            theme: String,
            fontName: String? = nil,
            fontSize: Double? = nil,
            panelTint: RGBA? = nil,
            foreground: RGBA? = nil,
            borderColor: RGBA? = nil,
            ansi: [String]? = nil
        ) {
            self.theme = theme
            self.fontName = fontName
            self.fontSize = fontSize
            self.panelTint = panelTint
            self.foreground = foreground
            self.borderColor = borderColor
            self.ansi = ansi
        }
    }

    private(set) var config: Config
    let configURL: URL

    init(fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("Starboard", isDirectory: true)
        configURL = dir.appendingPathComponent("config.json")
        config = Self.loadConfig(from: configURL) ?? .default
    }

    /// Apply an in-place config edit and persist. Used by the Settings window
    /// and any other UI that mutates individual fields.
    mutating func modify(_ body: (inout Config) -> Void) {
        body(&config)
        save()
    }

    /// Drop font/size/color/ANSI overrides; keep the selected built-in theme.
    mutating func resetOverrides() {
        modify { config in
            config.fontName = nil
            config.fontSize = nil
            config.panelTint = nil
            config.foreground = nil
            config.borderColor = nil
            config.ansi = nil
        }
    }

    /// Built-in + overrides, with `.system` resolved against `isDark`.
    func resolvedTheme(isDark: Bool) -> Theme {
        let baseName = Theme.builtIns[config.theme.lowercased()] != nil
            ? config.theme.lowercased()
            : Theme.ocean.name
        var theme = Theme.builtIns[baseName] ?? Theme.ocean
        theme = theme.resolved(isDark: isDark)

        if let fontName = config.fontName, !fontName.isEmpty {
            theme.fontName = fontName
        }
        if let fontSize = config.fontSize, fontSize > 0 {
            theme.fontSize = CGFloat(fontSize)
        }
        if let panelTint = config.panelTint {
            theme.panelTint = panelTint.nsColor
        }
        if let foreground = config.foreground {
            theme.foreground = foreground.nsColor
        }
        if let borderColor = config.borderColor {
            theme.borderColor = borderColor.nsColor
        }
        if let ansi = config.ansi, let colors = Self.parseAnsi(ansi) {
            theme.ansi = colors
        }
        return theme
    }

    /// Advance to the next built-in name, persist, return the new config theme key.
    @discardableResult
    mutating func cycleBuiltIn() -> String {
        let current = config.theme.lowercased()
        let order = Theme.builtInOrder
        let index = order.firstIndex(of: current).map { ($0 + 1) % order.count } ?? 0
        config.theme = order[index]
        save()
        return config.theme
    }

    /// Ensure the Application Support directory and a readable starter
    /// config exist, then return the URL for the caller to open.
    mutating func ensureConfigFile() -> URL {
        let dir = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: configURL.path) {
            // Seed with the active selection plus commented-friendly defaults
            // written as real JSON (comments aren't valid JSON).
            save()
        }
        return configURL
    }

    func save() {
        let dir = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: configURL, options: .atomic)
    }

    /// Re-read from disk. Returns true if the config value changed.
    @discardableResult
    mutating func reload() -> Bool {
        let loaded = Self.loadConfig(from: configURL) ?? .default
        guard loaded != config else { return false }
        config = loaded
        return true
    }

    private static func loadConfig(from url: URL) -> Config? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    private static func parseAnsi(_ hexColors: [String]) -> [Color]? {
        guard hexColors.count == 16 else { return nil }
        var colors: [Color] = []
        colors.reserveCapacity(16)
        for hex in hexColors {
            guard let (r, g, b) = parseHex(hex) else { return nil }
            colors.append(Theme.ansiColor(r, g, b))
        }
        return colors
    }

    /// Accepts `#RGB`, `#RRGGBB`, optional `0x` prefix; alpha ignored if present.
    private static func parseHex(_ string: String) -> (UInt16, UInt16, UInt16)? {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.lowercased().hasPrefix("0x") { s = String(s.dropFirst(2)) }
        guard let value = UInt32(s, radix: 16) else { return nil }
        switch s.count {
        case 3:
            let r = UInt16((value >> 8) & 0xF) * 17
            let g = UInt16((value >> 4) & 0xF) * 17
            let b = UInt16(value & 0xF) * 17
            return (r, g, b)
        case 6, 8:
            let rgb = s.count == 8 ? (value >> 8) : value
            let r = UInt16((rgb >> 16) & 0xFF)
            let g = UInt16((rgb >> 8) & 0xFF)
            let b = UInt16(rgb & 0xFF)
            return (r, g, b)
        default:
            return nil
        }
    }
}
