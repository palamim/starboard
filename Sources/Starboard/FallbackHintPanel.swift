import Cocoa

enum FallbackHintPanel {
    static let padding: CGFloat = 10
    static let closeButtonSize: CGFloat = 14

    static func make(
        message: String, width: CGFloat, theme: Theme, target: AnyObject, action: Selector
    ) -> (panel: NSPanel, tintView: NSView, label: NSTextField) {
        let textWidth = width - padding * 2 - closeButtonSize - 4
        let font = TerminalTheme.font
        let attributed = NSAttributedString(string: message, attributes: [.font: font])
        let textHeight = ceil(
            attributed.boundingRect(
                with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height)
        let height = textHeight + padding * 2

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.level = NSWindow.Level(rawValue: Int(kCGDockWindowLevel) + 1)
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]
        panel.hidesOnDeactivate = false

        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        let effectView = NSVisualEffectView(frame: bounds)
        effectView.material = .menu
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = TerminalTheme.cornerRadius
        effectView.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 1
        effectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor

        let tintView = NSView(frame: bounds)
        tintView.autoresizingMask = [.width, .height]
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = theme.panelTintColor.cgColor
        effectView.addSubview(tintView)

        let label = NSTextField(wrappingLabelWithString: message)
        label.translatesAutoresizingMaskIntoConstraints = true
        label.frame = NSRect(x: padding, y: padding, width: textWidth, height: textHeight)
        label.font = font
        label.textColor = theme.foregroundColor
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        effectView.addSubview(label)

        let closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")!,
            target: target, action: action)
        closeButton.frame = NSRect(
            x: width - padding - closeButtonSize,
            y: height - padding - closeButtonSize,
            width: closeButtonSize, height: closeButtonSize)
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        (closeButton.cell as? NSButtonCell)?.imageScaling = .scaleProportionallyDown
        effectView.addSubview(closeButton)

        panel.contentView = effectView

        return (panel, tintView, label)
    }
}
