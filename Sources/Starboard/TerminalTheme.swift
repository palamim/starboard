import Cocoa

enum TerminalTheme {
    static let fontSize: CGFloat = 11
    static let padding: CGFloat = 8
    static let defaultCornerRadius: CGFloat = 12

    static let systemFontName = "__system__"

    private static let preferredDefaultFontNames = [
        "MesloLGS NF",
        "MesloLGS Nerd Font",
        "Hack Nerd Font",
        "FiraCode Nerd Font",
        "JetBrainsMono Nerd Font",
        "Menlo",
    ]

    static var installedFontNames: [String] {
        var fontsByFamily: [String: NSFont] = [:]

        for name in NSFontManager.shared.availableFonts {
            guard let font = NSFont(name: name, size: fontSize),
                  font.fontDescriptor.symbolicTraits.contains(.monoSpace)
            else { continue }

            let family = (font.familyName ?? font.fontName).lowercased()
            guard let current = fontsByFamily[family] else {
                fontsByFamily[family] = font
                continue
            }

            let candidateRank = faceRank(font)
            let currentRank = faceRank(current)
            if candidateRank < currentRank
                || (candidateRank == currentRank
                    && font.fontName.localizedStandardCompare(current.fontName) == .orderedAscending)
            {
                fontsByFamily[family] = font
            }
        }

        let fontNames = fontsByFamily.values.map(\.fontName).sorted {
            displayName(forFontName: $0).localizedStandardCompare(displayName(forFontName: $1))
                == .orderedAscending
        }
        return fontNames + [systemFontName]
    }

    static var defaultFontName: String {
        preferredDefaultFontNames.first { NSFont(name: $0, size: fontSize) != nil }
            ?? systemFontName
    }

    static func displayName(forFontName name: String) -> String {
        guard name != systemFontName else { return "SF Mono (System)" }
        return NSFont(name: name, size: fontSize)?.familyName ?? name
    }

    static func font(named name: String?) -> NSFont {
        let resolvedName = name ?? defaultFontName
        if resolvedName == systemFontName {
            return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        return NSFont(name: resolvedName, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    private static func faceRank(_ font: NSFont) -> Int {
        let traits = font.fontDescriptor.symbolicTraits
        let stylePenalty = (traits.contains(.bold) ? 100 : 0) + (traits.contains(.italic) ? 100 : 0)
        let weightPenalty = abs(NSFontManager.shared.weight(of: font) - 5)
        return stylePenalty + weightPenalty
    }
}
