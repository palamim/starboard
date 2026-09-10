import Cocoa

final class SettingsPanelView: NSView {
    private let padding: CGFloat = 12
    private let rowGap: CGFloat = 14
    private let controlWidth: CGFloat = 200
    private let closeButtonSize: CGFloat = 14

    private let cornerRadiusSlider = NSSlider()
    private let tintOpacitySlider = NSSlider()
    private let extraHeightSlider = NSSlider()
    private let stayVisibleCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fontNames: [String]

    var onCornerRadiusChange: ((CGFloat) -> Void)?
    var onTintOpacityChange: ((CGFloat) -> Void)?
    var onFontChange: ((String) -> Void)?
    var onExtraHeightChange: ((CGFloat) -> Void)?
    var onStayVisibleChange: ((Bool) -> Void)?
    var onReset: (() -> Void)?
    var onCancel: (() -> Void)?

    init(
        cornerRadius: CGFloat, tintOpacity: CGFloat, fontNames: [String], selectedFontName: String,
        extraHeight: CGFloat, stayVisibleWhenDockHides: Bool
    ) {
        self.fontNames = fontNames
        let width = controlWidth + padding * 2

        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor

        var y: CGFloat = padding

        let title = Self.makeLabel("Settings", size: 12, weight: .semibold, alpha: 0.85)
        title.frame = NSRect(
            x: padding, y: y, width: controlWidth - closeButtonSize - 6, height: 16)
        addSubview(title)

        let closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!,
            target: self, action: #selector(closeTapped))
        closeButton.frame = NSRect(
            x: width - padding - closeButtonSize, y: y + 1,
            width: closeButtonSize, height: closeButtonSize)
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.5)
        (closeButton.cell as? NSButtonCell)?.imageScaling = .scaleProportionallyDown
        addSubview(closeButton)
        y += 16 + rowGap

        let radiusLabel = Self.makeLabel("Corner radius")
        radiusLabel.frame = NSRect(x: padding, y: y, width: controlWidth, height: 14)
        addSubview(radiusLabel)
        y += 14 + 4

        cornerRadiusSlider.minValue = 0
        cornerRadiusSlider.maxValue = 24
        cornerRadiusSlider.doubleValue = Double(cornerRadius)
        cornerRadiusSlider.isContinuous = true
        cornerRadiusSlider.target = self
        cornerRadiusSlider.action = #selector(cornerRadiusChanged)
        cornerRadiusSlider.frame = NSRect(x: padding, y: y, width: controlWidth, height: 20)
        addSubview(cornerRadiusSlider)
        y += 20 + rowGap

        let opacityLabel = Self.makeLabel("Background opacity")
        opacityLabel.frame = NSRect(x: padding, y: y, width: controlWidth, height: 14)
        addSubview(opacityLabel)
        y += 14 + 4

        tintOpacitySlider.minValue = 0.2
        tintOpacitySlider.maxValue = 1.0
        tintOpacitySlider.doubleValue = Double(tintOpacity)
        tintOpacitySlider.isContinuous = true
        tintOpacitySlider.target = self
        tintOpacitySlider.action = #selector(opacityChanged)
        tintOpacitySlider.frame = NSRect(x: padding, y: y, width: controlWidth, height: 20)
        addSubview(tintOpacitySlider)
        y += 20 + rowGap

        let fontLabel = Self.makeLabel("Font")
        fontLabel.frame = NSRect(x: padding, y: y, width: controlWidth, height: 14)
        addSubview(fontLabel)
        y += 14 + 4

        fontPopup.frame = NSRect(x: padding, y: y, width: controlWidth, height: 22)
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged)
        for name in fontNames {
            fontPopup.addItem(withTitle: TerminalTheme.displayName(forFontName: name))
        }
        if let index = fontNames.firstIndex(of: selectedFontName) {
            fontPopup.selectItem(at: index)
        }
        addSubview(fontPopup)
        y += 22 + rowGap

        let extraHeightLabel = Self.makeLabel("Extra height above Dock")
        extraHeightLabel.frame = NSRect(x: padding, y: y, width: controlWidth, height: 14)
        addSubview(extraHeightLabel)
        y += 14 + 4

        extraHeightSlider.minValue = 0
        extraHeightSlider.maxValue = Double(AppDelegate.maxExtraHeight)
        extraHeightSlider.doubleValue = Double(extraHeight)
        extraHeightSlider.isContinuous = true
        extraHeightSlider.target = self
        extraHeightSlider.action = #selector(extraHeightChanged)
        extraHeightSlider.frame = NSRect(x: padding, y: y, width: controlWidth, height: 20)
        addSubview(extraHeightSlider)
        y += 20 + rowGap

        let checkboxFont = NSFont.systemFont(ofSize: 11)
        stayVisibleCheckbox.attributedTitle = NSAttributedString(
            string: "Stay visible when Dock hides",
            attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.85), .font: checkboxFont])
        stayVisibleCheckbox.state = stayVisibleWhenDockHides ? .on : .off
        stayVisibleCheckbox.target = self
        stayVisibleCheckbox.action = #selector(stayVisibleChanged)
        stayVisibleCheckbox.frame = NSRect(x: padding, y: y, width: controlWidth, height: 18)
        addSubview(stayVisibleCheckbox)
        y += 18 + rowGap

        let resetButton = NSButton(
            title: "Reset to Defaults", target: self, action: #selector(resetTapped))
        resetButton.isBordered = false
        resetButton.contentTintColor = NSColor.white.withAlphaComponent(0.55)
        resetButton.font = NSFont.systemFont(ofSize: 10)
        resetButton.frame = NSRect(x: padding, y: y, width: controlWidth, height: 14)
        addSubview(resetButton)
        y += 14 + padding

        frame = NSRect(x: 0, y: 0, width: width, height: y)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    func setValues(
        cornerRadius: CGFloat, tintOpacity: CGFloat, fontName: String, extraHeight: CGFloat,
        stayVisibleWhenDockHides: Bool
    ) {
        cornerRadiusSlider.doubleValue = Double(cornerRadius)
        tintOpacitySlider.doubleValue = Double(tintOpacity)
        extraHeightSlider.doubleValue = Double(extraHeight)
        stayVisibleCheckbox.state = stayVisibleWhenDockHides ? .on : .off
        if let index = fontNames.firstIndex(of: fontName) {
            fontPopup.selectItem(at: index)
        }
    }

    @objc private func cornerRadiusChanged() {
        onCornerRadiusChange?(CGFloat(cornerRadiusSlider.doubleValue))
    }

    @objc private func opacityChanged() {
        onTintOpacityChange?(CGFloat(tintOpacitySlider.doubleValue))
    }

    @objc private func extraHeightChanged() {
        onExtraHeightChange?(CGFloat(extraHeightSlider.doubleValue))
    }

    @objc private func stayVisibleChanged() {
        onStayVisibleChange?(stayVisibleCheckbox.state == .on)
    }

    @objc private func fontChanged() {
        let index = fontPopup.indexOfSelectedItem
        guard index >= 0, index < fontNames.count else { return }
        onFontChange?(fontNames[index])
    }

    @objc private func resetTapped() {
        onReset?()
    }

    @objc private func closeTapped() {
        onCancel?()
    }

    private static func makeLabel(
        _ text: String, size: CGFloat = 10, weight: NSFont.Weight = .medium, alpha: CGFloat = 0.5
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = NSColor.white.withAlphaComponent(alpha)
        return label
    }
}
