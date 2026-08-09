import AppKit

/// Small preferences window over `ThemeStore.Config`. The Dock panel is the
/// live preview — changes save to `config.json` and re-apply immediately.
///
/// Opened via Cmd+, (accessory apps have no visible Settings menu). Stays a
/// normal titled window; Starboard remains `.accessory` with no Dock icon.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let getConfig: () -> ThemeStore.Config
    private let resolvedTheme: () -> Theme
    private let updateConfig: ((inout ThemeStore.Config) -> Void) -> Void
    private let resetOverrides: () -> Void
    private let openConfigFile: () -> Void

    private var themePopUp: NSPopUpButton!
    private var fontPopUp: NSPopUpButton!
    private var sizeField: NSTextField!
    private var sizeStepper: NSStepper!
    private var tintWell: NSColorWell!
    private var foregroundWell: NSColorWell!
    /// Suppresses control actions while `reloadFromStore` pushes values in.
    private var isLoading = false

    private static let minFontSize: Double = 9
    private static let maxFontSize: Double = 18
    private static let defaultFontMenuTitle = "Default (automatic)"

    init(
        getConfig: @escaping () -> ThemeStore.Config,
        resolvedTheme: @escaping () -> Theme,
        updateConfig: @escaping ((inout ThemeStore.Config) -> Void) -> Void,
        resetOverrides: @escaping () -> Void,
        openConfigFile: @escaping () -> Void
    ) {
        self.getConfig = getConfig
        self.resolvedTheme = resolvedTheme
        self.updateConfig = updateConfig
        self.resetOverrides = resetOverrides
        self.openConfigFile = openConfigFile

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Starboard Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSettings() {
        reloadFromStore()
        guard let window else { return }
        // Accessory apps aren't frontmost; without this the window can open
        // behind whatever the user was in and look like Cmd+, did nothing.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Push current store values into controls (after Cmd+T, file reload, etc.).
    func reloadFromStore() {
        isLoading = true
        defer { isLoading = false }

        let config = getConfig()
        let theme = resolvedTheme()

        let themeName = config.theme.lowercased()
        if let index = Theme.builtInOrder.firstIndex(of: themeName) {
            themePopUp.selectItem(at: index)
        } else {
            themePopUp.selectItem(at: 0)
        }

        populateFontMenu(selected: config.fontName)

        let size = config.fontSize ?? Double(Theme.defaultFontSize)
        sizeField.doubleValue = size
        sizeStepper.doubleValue = size

        tintWell.color = config.panelTint?.nsColor ?? theme.panelTint
        foregroundWell.color = config.foreground?.nsColor ?? theme.foreground
    }

    // MARK: - UI

    private func buildContent() -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 340))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        themePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        for name in Theme.builtInOrder {
            themePopUp.addItem(withTitle: Self.displayName(forTheme: name))
            themePopUp.lastItem?.representedObject = name
        }
        themePopUp.target = self
        themePopUp.action = #selector(themeChanged(_:))
        stack.addArrangedSubview(labeledRow("Theme", themePopUp))

        fontPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        fontPopUp.target = self
        fontPopUp.action = #selector(fontChanged(_:))
        stack.addArrangedSubview(labeledRow("Font", fontPopUp))

        sizeField = NSTextField(string: "")
        sizeField.alignment = .right
        sizeField.font = .systemFont(ofSize: NSFont.systemFontSize)
        sizeField.translatesAutoresizingMaskIntoConstraints = false
        sizeField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        sizeField.target = self
        sizeField.action = #selector(sizeFieldChanged(_:))

        sizeStepper = NSStepper()
        sizeStepper.minValue = Self.minFontSize
        sizeStepper.maxValue = Self.maxFontSize
        sizeStepper.increment = 1
        sizeStepper.valueWraps = false
        sizeStepper.target = self
        sizeStepper.action = #selector(sizeStepperChanged(_:))

        let sizeRow = NSStackView(views: [sizeField, sizeStepper])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 6
        stack.addArrangedSubview(labeledRow("Size", sizeRow))

        tintWell = NSColorWell()
        tintWell.target = self
        tintWell.action = #selector(tintChanged(_:))
        tintWell.translatesAutoresizingMaskIntoConstraints = false
        tintWell.widthAnchor.constraint(equalToConstant: 52).isActive = true
        tintWell.heightAnchor.constraint(equalToConstant: 24).isActive = true
        stack.addArrangedSubview(labeledRow("Panel tint", tintWell))

        foregroundWell = NSColorWell()
        foregroundWell.target = self
        foregroundWell.action = #selector(foregroundChanged(_:))
        foregroundWell.translatesAutoresizingMaskIntoConstraints = false
        foregroundWell.widthAnchor.constraint(equalToConstant: 52).isActive = true
        foregroundWell.heightAnchor.constraint(equalToConstant: 24).isActive = true
        stack.addArrangedSubview(labeledRow("Text color", foregroundWell))

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let resetButton = NSButton(title: "Reset to Theme Defaults", target: self, action: #selector(resetClicked(_:)))
        resetButton.bezelStyle = .rounded
        let editFileButton = NSButton(title: "Edit Config File…", target: self, action: #selector(editFileClicked(_:)))
        editFileButton.bezelStyle = .rounded
        buttonRow.addArrangedSubview(resetButton)
        buttonRow.addArrangedSubview(editFileButton)
        stack.addArrangedSubview(buttonRow)

        let hint = NSTextField(labelWithString: "The Dock panel updates live. Font changes may alter how many rows fit.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 3
        hint.preferredMaxLayoutWidth = 340
        stack.addArrangedSubview(hint)

        return root
    }

    private func labeledRow(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 88).isActive = true

        control.translatesAutoresizingMaskIntoConstraints = false
        if let popUp = control as? NSPopUpButton {
            popUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        }

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func populateFontMenu(selected: String?) {
        fontPopUp.removeAllItems()
        fontPopUp.addItem(withTitle: Self.defaultFontMenuTitle)
        fontPopUp.lastItem?.representedObject = ""

        let fonts = Self.availableTerminalFontNames()
        let preferred = Theme.preferredFontNames.filter { fonts.contains($0) }
        let preferredSet = Set(preferred)
        let rest = fonts.filter { !preferredSet.contains($0) }.sorted()

        if !preferred.isEmpty {
            fontPopUp.menu?.addItem(.separator())
            for name in preferred {
                fontPopUp.addItem(withTitle: name)
                fontPopUp.lastItem?.representedObject = name
            }
        }
        if !rest.isEmpty {
            fontPopUp.menu?.addItem(.separator())
            for name in rest {
                fontPopUp.addItem(withTitle: name)
                fontPopUp.lastItem?.representedObject = name
            }
        }

        if let selected, !selected.isEmpty,
           let item = fontPopUp.itemArray.first(where: { ($0.representedObject as? String) == selected }) {
            fontPopUp.select(item)
        } else if let selected, !selected.isEmpty, NSFont(name: selected, size: 12) != nil {
            // Custom name from config that's missing from the enumerated list.
            fontPopUp.addItem(withTitle: selected)
            fontPopUp.lastItem?.representedObject = selected
            fontPopUp.select(fontPopUp.lastItem)
        } else {
            fontPopUp.selectItem(at: 0)
        }
    }

    /// Installed fixed-pitch fonts, by PostScript name (what `NSFont(name:)` takes).
    private static func availableTerminalFontNames() -> Set<String> {
        var names = Set<String>()
        let manager = NSFontManager.shared
        for family in manager.availableFontFamilies {
            guard let members = manager.availableMembers(ofFontFamily: family) else { continue }
            for member in members {
                guard let postScript = member.first as? String else { continue }
                guard let font = NSFont(name: postScript, size: 12) else { continue }
                if font.isFixedPitch {
                    names.insert(postScript)
                }
            }
        }
        // Preferred list may use display-ish names that still resolve.
        for preferred in Theme.preferredFontNames {
            if NSFont(name: preferred, size: 12) != nil {
                names.insert(preferred)
            }
        }
        return names
    }

    private static func displayName(forTheme name: String) -> String {
        switch name {
        case "ocean": return "Ocean"
        case "dark": return "Dark"
        case "light": return "Light"
        case "system": return "System"
        default: return name.capitalized
        }
    }

    // MARK: - Actions

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        guard !isLoading else { return }
        guard let name = sender.selectedItem?.representedObject as? String else { return }
        updateConfig { $0.theme = name }
        // Refresh wells to the new theme's defaults when those fields aren't overridden.
        reloadFromStore()
    }

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        guard !isLoading else { return }
        let value = sender.selectedItem?.representedObject as? String ?? ""
        updateConfig { $0.fontName = value.isEmpty ? nil : value }
    }

    @objc private func sizeFieldChanged(_ sender: NSTextField) {
        guard !isLoading else { return }
        let clamped = min(max(sender.doubleValue, Self.minFontSize), Self.maxFontSize)
        sender.doubleValue = clamped
        sizeStepper.doubleValue = clamped
        updateConfig { $0.fontSize = clamped }
    }

    @objc private func sizeStepperChanged(_ sender: NSStepper) {
        guard !isLoading else { return }
        sizeField.doubleValue = sender.doubleValue
        updateConfig { $0.fontSize = sender.doubleValue }
    }

    @objc private func tintChanged(_ sender: NSColorWell) {
        guard !isLoading else { return }
        updateConfig { $0.panelTint = ThemeStore.RGBA(sender.color) }
    }

    @objc private func foregroundChanged(_ sender: NSColorWell) {
        guard !isLoading else { return }
        updateConfig { $0.foreground = ThemeStore.RGBA(sender.color) }
    }

    @objc private func resetClicked(_ sender: Any?) {
        resetOverrides()
        reloadFromStore()
    }

    @objc private func editFileClicked(_ sender: Any?) {
        openConfigFile()
    }
}
