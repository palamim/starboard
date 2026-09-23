import Cocoa

enum PanelSettings {
    private static let cornerRadiusKey = "settings.cornerRadius"
    private static let tintOpacityKey = "settings.tintOpacity"
    private static let fontNameKey = "settings.fontName"
    private static let fontSizeKey = "settings.fontSize"
    private static let extraHeightKey = "settings.extraHeight"
    private static let stayVisibleWhenDockHidesKey = "settings.stayVisibleWhenDockHides"

    static var cornerRadius: CGFloat {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: cornerRadiusKey) != nil else {
                return TerminalTheme.defaultCornerRadius
            }
            return CGFloat(defaults.double(forKey: cornerRadiusKey))
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: cornerRadiusKey) }
    }

    static var tintOpacity: CGFloat? {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: tintOpacityKey) != nil else { return nil }
            return CGFloat(defaults.double(forKey: tintOpacityKey))
        }
        set {
            if let newValue {
                UserDefaults.standard.set(Double(newValue), forKey: tintOpacityKey)
            } else {
                UserDefaults.standard.removeObject(forKey: tintOpacityKey)
            }
        }
    }

    static var fontName: String? {
        get { UserDefaults.standard.string(forKey: fontNameKey) }
        set { UserDefaults.standard.set(newValue, forKey: fontNameKey) }
    }

    static var fontSize: CGFloat {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: fontSizeKey) != nil else {
                return TerminalTheme.defaultFontSize
            }
            return CGFloat(defaults.double(forKey: fontSizeKey))
        }
        set {
            let clamped = min(max(newValue.rounded(), TerminalTheme.minFontSize), TerminalTheme.maxFontSize)
            UserDefaults.standard.set(Double(clamped), forKey: fontSizeKey)
        }
    }

    static var extraHeight: CGFloat {
        get { CGFloat(UserDefaults.standard.double(forKey: extraHeightKey)) }
        set { UserDefaults.standard.set(Double(newValue), forKey: extraHeightKey) }
    }

    static var stayVisibleWhenDockHides: Bool {
        get { UserDefaults.standard.bool(forKey: stayVisibleWhenDockHidesKey) }
        set { UserDefaults.standard.set(newValue, forKey: stayVisibleWhenDockHidesKey) }
    }

    static func resetToDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: cornerRadiusKey)
        defaults.removeObject(forKey: tintOpacityKey)
        defaults.removeObject(forKey: fontNameKey)
        defaults.removeObject(forKey: fontSizeKey)
        defaults.removeObject(forKey: extraHeightKey)
        defaults.removeObject(forKey: stayVisibleWhenDockHidesKey)
    }
}
