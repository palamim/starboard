import Cocoa

extension AppDelegate {
    func applyTheme(_ theme: Theme, persist: Bool) {
        currentTheme = theme
        tintView.layer?.backgroundColor = theme.panelTintColor.cgColor
        terminalView.nativeForegroundColor = theme.foregroundColor
        terminalView.installColors(theme.ansiPalette)
        applyThemeToFallbackHint(theme)
        if persist {
            UserDefaults.standard.set(theme.id, forKey: "themeID")
        }
    }

    @objc func toggleThemePicker(_ sender: Any?) {
        if let pickerPanel = themePickerPanel {
            pickerPanel.orderOut(nil)
            themePickerPanel = nil
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(terminalView)
            return
        }

        let picker = ThemePickerView(themes: Theme.all, selectedID: currentTheme.id)
        picker.onCommit = { [weak self] theme in
            self?.applyTheme(theme, persist: true)
            self?.toggleThemePicker(nil)
        }
        picker.onCancel = { [weak self] in self?.toggleThemePicker(nil) }

        let origin = NSPoint(
            x: panel.frame.maxX - picker.frame.width - 10,
            y: panel.frame.minY)
        let pickerPanel = KeyablePanel(
            contentRect: NSRect(origin: origin, size: picker.frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        pickerPanel.level = NSWindow.Level(rawValue: Int(kCGDockWindowLevel) + 2)
        pickerPanel.isOpaque = false
        pickerPanel.backgroundColor = .clear
        pickerPanel.hidesOnDeactivate = false
        pickerPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        pickerPanel.contentView = picker

        pickerPanel.makeKeyAndOrderFront(nil)
        pickerPanel.makeFirstResponder(picker)
        themePickerPanel = pickerPanel
    }
}
