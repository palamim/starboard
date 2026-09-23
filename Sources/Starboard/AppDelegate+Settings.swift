import Cocoa

extension AppDelegate {
    @objc func toggleSettingsPanel(_ sender: Any?) {
        if let existing = settingsPanel {
            existing.orderOut(nil)
            settingsPanel = nil
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(terminalView)
            return
        }

        let view = SettingsPanelView(
            cornerRadius: PanelSettings.cornerRadius,
            tintOpacity: PanelSettings.tintOpacity ?? currentTheme.panelTintColor.alphaComponent,
            fontNames: TerminalTheme.installedFontNames,
            selectedFontName: PanelSettings.fontName ?? TerminalTheme.defaultFontName,
            fontSize: PanelSettings.fontSize,
            extraHeight: PanelSettings.extraHeight,
            stayVisibleWhenDockHides: PanelSettings.stayVisibleWhenDockHides)

        view.onCornerRadiusChange = { [weak self] radius in
            PanelSettings.cornerRadius = radius
            self?.applyCornerRadius()
        }
        view.onTintOpacityChange = { [weak self] opacity in
            PanelSettings.tintOpacity = opacity
            self?.applyTintOpacity()
        }
        view.onFontChange = { [weak self] name in
            PanelSettings.fontName = name
            self?.applyFont()
        }
        view.onFontSizeChange = { [weak self] size in
            PanelSettings.fontSize = size
            self?.applyFont()
        }
        view.onExtraHeightChange = { [weak self] height in
            PanelSettings.extraHeight = height
            self?.runEvaluation()
        }
        view.onStayVisibleChange = { [weak self] stayVisible in
            PanelSettings.stayVisibleWhenDockHides = stayVisible
            self?.runEvaluation()
        }
        view.onReset = { [weak self, weak view] in
            guard let self else { return }
            PanelSettings.resetToDefaults()
            self.applyCornerRadius()
            self.applyTintOpacity()
            self.applyFont()
            self.runEvaluation()
            view?.setValues(
                cornerRadius: PanelSettings.cornerRadius,
                tintOpacity: self.currentTheme.panelTintColor.alphaComponent,
                fontName: TerminalTheme.defaultFontName,
                fontSize: PanelSettings.fontSize,
                extraHeight: PanelSettings.extraHeight,
                stayVisibleWhenDockHides: PanelSettings.stayVisibleWhenDockHides)
        }
        view.onCancel = { [weak self] in self?.toggleSettingsPanel(nil) }

        let origin = NSPoint(
            x: panel.frame.maxX - view.frame.width - 10,
            y: panel.frame.minY)
        let settingsPanelWindow = KeyablePanel(
            contentRect: NSRect(origin: origin, size: view.frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        settingsPanelWindow.level = NSWindow.Level(rawValue: Int(kCGDockWindowLevel) + 2)
        settingsPanelWindow.isOpaque = false
        settingsPanelWindow.backgroundColor = .clear
        settingsPanelWindow.hidesOnDeactivate = false
        settingsPanelWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        settingsPanelWindow.contentView = view

        settingsPanelWindow.makeKeyAndOrderFront(nil)
        settingsPanelWindow.makeFirstResponder(view)
        settingsPanel = settingsPanelWindow
    }

    func applyCornerRadius() {
        (panel.contentView as? NSVisualEffectView)?.layer?.cornerRadius = PanelSettings.cornerRadius
    }

    func applyTintOpacity() {
        tintView.layer?.backgroundColor =
            currentTheme.tintColor(opacity: PanelSettings.tintOpacity).cgColor
    }

    @objc func increaseFontSize(_ sender: Any?) {
        adjustFontSize(to: PanelSettings.fontSize + 1)
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        adjustFontSize(to: PanelSettings.fontSize - 1)
    }

    @objc func resetFontSize(_ sender: Any?) {
        adjustFontSize(to: TerminalTheme.defaultFontSize)
    }

    private func adjustFontSize(to size: CGFloat) {
        PanelSettings.fontSize = size
        applyFont()
        (settingsPanel?.contentView as? SettingsPanelView)?.setFontSize(PanelSettings.fontSize)
    }

    func applyFont() {
        let font = TerminalTheme.font(named: PanelSettings.fontName)
        terminalView.font = font
        terminalView.frame = TerminalLayout.contentFrame(
            in: NSRect(origin: .zero, size: panel.frame.size), font: font)
    }
}
