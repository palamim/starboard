import Cocoa
import CoreGraphics
import SwiftTerm

enum PanelBuilder {
    static let menuButtonSize: CGFloat = 15
    static let menuButtonInset: CGFloat = 5

    static func makePanel(
        initialFrame: NSRect, theme: Theme, menuTarget: AnyObject, menuAction: Selector
    ) -> (
        panel: KeyablePanel, terminal: LocalProcessTerminalView, tintView: NSView,
        menuButton: NSButton
    ) {
        let panel = KeyablePanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(kCGDockWindowLevel) + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]
        panel.hidesOnDeactivate = false

        let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: panel.frame.size))
        effectView.autoresizingMask = [.width, .height]
        effectView.material = .menu
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = PanelSettings.cornerRadius
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 1
        effectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor

        let tintView = NSView(frame: effectView.bounds)
        tintView.autoresizingMask = [.width, .height]
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = theme.tintColor(opacity: PanelSettings.tintOpacity).cgColor
        effectView.addSubview(tintView)

        let font = TerminalTheme.font(named: PanelSettings.fontName)
        let terminal = LocalProcessTerminalView(
            frame: TerminalLayout.contentFrame(in: effectView.bounds, font: font))
        terminal.autoresizingMask = [.width]
        terminal.font = font
        terminal.nativeBackgroundColor = .clear
        terminal.nativeForegroundColor = theme.foregroundColor
        terminal.layer?.backgroundColor = NSColor.clear.cgColor
        terminal.installColors(theme.ansiPalette)
        terminal.toolTip = "⌘E expand · ⌘T theme · ⌘+/⌘− font size · ⌘Q quit"

        effectView.addSubview(terminal)

        let menuButton = NSButton(
            image: NSImage(
                systemSymbolName: "ellipsis.circle", accessibilityDescription: "Menu")!,
            target: menuTarget, action: menuAction)
        menuButton.frame = NSRect(
            x: effectView.bounds.width - menuButtonSize - menuButtonInset,
            y: effectView.bounds.minY + menuButtonInset,
            width: menuButtonSize, height: menuButtonSize)
        menuButton.autoresizingMask = [.minXMargin]
        menuButton.isBordered = false
        menuButton.imagePosition = .imageOnly
        menuButton.contentTintColor = theme.chromeTintColor
        (menuButton.cell as? NSButtonCell)?.imageScaling = .scaleProportionallyDown
        menuButton.toolTip = "Menu"
        effectView.addSubview(menuButton)

        panel.contentView = effectView

        return (panel, terminal, tintView, menuButton)
    }
}
