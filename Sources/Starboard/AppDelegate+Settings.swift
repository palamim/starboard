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

    func applyFont() {
        let font = TerminalTheme.font(named: PanelSettings.fontName)
        terminalView.font = font
        terminalView.frame = TerminalLayout.contentFrame(
            in: NSRect(origin: .zero, size: panel.frame.size), font: font)
    }
}
