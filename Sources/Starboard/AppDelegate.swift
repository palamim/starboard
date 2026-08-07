import Cocoa
import ApplicationServices
import CoreText
import SwiftTerm

/// `Color`'s public initializer takes 16-bit (0...65535) components; this
/// takes the familiar 8-bit (0...255) form and scales up (`* 257` maps
/// 0...255 onto 0...65535 exactly, since 255 * 257 == 65535).
private func ansiColor(_ red: UInt16, _ green: UInt16, _ blue: UInt16) -> Color {
    Color(red: red * 257, green: green * 257, blue: blue * 257)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var terminalView: LocalProcessTerminalView!
    private var trackingTimer: Timer!
    /// Toggled by the hidden Cmd+E menu item. When true, `currentFrame()`
    /// grows the panel upward to the top of the screen instead of matching
    /// the Dock's height — the bottom edge (and x/width) still track the
    /// Dock live, only the top edge changes.
    private var isExpanded = false

    private let fallbackWidth: CGFloat = 300
    private let fallbackHeight: CGFloat = 64
    private let fallbackMargin: CGFloat = 8
    private let cornerRadius: CGFloat = 12
    /// Starboard's own panel color — a near-black deep navy, independent of
    /// the Dock's material and whatever's on the desktop behind it. First
    /// pass; tune the RGB/alpha here to taste.
    private let panelTintColor = NSColor(calibratedRed: 0.02, green: 0.035, blue: 0.06, alpha: 0.65)
    private let dockTrackingInterval: TimeInterval = 1.0
    /// Empirical corrections for the gap between the Dock's AXList (icon
    /// row) bounding box and its actual painted chrome, which Accessibility
    /// doesn't expose directly. Tuned against a real Dock; nudge these if
    /// the panel's edges drift from the Dock's over time or on other
    /// displays/tile sizes.
    private let dockBottomCorrection: CGFloat = 5
    private let dockTopCorrection: CGFloat = 5
    /// Inset between the panel's edge and the terminal content, and the
    /// font size that content renders at. Chosen together so that, at a
    /// Dock height around 57-60pt, exactly two terminal rows fit — the
    /// current line and the one before it.
    private let terminalPadding: CGFloat = 8
    /// The shell launched in the panel's pseudo-terminal, and the value
    /// exported as `SHELL` to it (see `childEnvironment`) — kept as one
    /// constant so those two can't drift apart.
    private static let shellExecutable = "/bin/zsh"
    private let terminalFontSize: CGFloat = 11
    private let terminalFont: NSFont
    /// Starboard's own ANSI palette (indices 0-15: black/red/green/yellow/
    /// blue/magenta/cyan/white, then bright variants) — muted ocean blues
    /// and teals instead of the harsh primaries most terminal defaults use,
    /// with red/green nodding to a ship's port/starboard navigation lights.
    /// This only changes what an ANSI color code *renders as*; it has no
    /// effect on which color a shell prompt theme chooses to use for a
    /// given segment — that logic lives in the user's own shell config
    /// (e.g. oh-my-zsh), independent of the terminal emulator. First pass;
    /// tune to taste.
    private let starboardAnsiPalette: [Color] = [
        ansiColor(20, 24, 33),    // black
        ansiColor(198, 74, 90),   // red — port light
        ansiColor(79, 157, 105),  // green — starboard light
        ansiColor(196, 154, 62),  // yellow — brass
        ansiColor(58, 124, 165),  // blue — deep ocean
        ansiColor(133, 110, 168), // magenta — dusk
        ansiColor(69, 156, 156),  // cyan — seafoam
        ansiColor(196, 190, 172), // white — sand
        ansiColor(75, 87, 99),    // bright black — slate
        ansiColor(222, 102, 118), // bright red
        ansiColor(111, 191, 135), // bright green
        ansiColor(224, 186, 105), // bright yellow
        ansiColor(95, 168, 211),  // bright blue
        ansiColor(169, 143, 201), // bright magenta
        ansiColor(114, 214, 207), // bright cyan
        ansiColor(230, 224, 208), // bright white — foam
    ]

    override init() {
        // Menlo, not the system SF Mono: SF Mono is missing glyphs common
        // shell prompt themes use (e.g. ➜ U+27A4), which render as a
        // fallback placeholder instead. Menlo has broad coverage here and
        // is what Terminal.app itself has defaulted to for years.
        terminalFont = NSFont(name: "Menlo", size: 11) ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Triggers the system Accessibility permission prompt on first
        // launch if not already granted. Needed to read the Dock's icon
        // tray geometry precisely; falls back to an approximation until
        // it's granted (see fallbackFrame below).
        let promptOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(promptOptions)

        setUpMainMenu()

        let panel = KeyablePanel(
            contentRect: currentFrame(),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        // Present on every Space, including full-screen ones, and skip
        // the app switcher / window cycling entirely.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false

        let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: panel.frame.size))
        effectView.autoresizingMask = [.width, .height]
        effectView.material = .menu
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = cornerRadius
        // Clip subviews to the rounded shape too — otherwise the terminal
        // view (which fills the whole panel edge-to-edge) can paint square
        // corners over the rounded blur.
        effectView.layer?.masksToBounds = true
        // A faint edge highlight, similar to the Dock's own subtle stroke.
        effectView.layer?.borderWidth = 1
        effectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor

        // Starboard's own fixed tint, layered on top of the system blur.
        // The Dock's exact color/opacity is a private, OS-version-tuned
        // recipe (not a public material) that reacts live to the desktop
        // behind it — chasing it means drifting apart on every wallpaper
        // and macOS release. This tint is constant instead: always close
        // to black, independent of what's behind the panel.
        let tintView = NSView(frame: effectView.bounds)
        tintView.autoresizingMask = [.width, .height]
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = panelTintColor.cgColor
        effectView.addSubview(tintView)

        let terminal = LocalProcessTerminalView(frame: terminalContentFrame(in: effectView.bounds))
        // Width only — height is recomputed and recentered explicitly in
        // syncFrameToDock, since SwiftTerm's row count is a floor() of
        // pixel height and rarely divides it evenly, leaving slack that
        // needs to be centered rather than pinned to the top or bottom.
        terminal.autoresizingMask = [.width]
        terminal.font = terminalFont
        // Let the blur behind the panel show through instead of the
        // terminal's own opaque background.
        terminal.nativeBackgroundColor = .clear
        terminal.nativeForegroundColor = .labelColor
        terminal.layer?.backgroundColor = NSColor.clear.cgColor
        terminal.installColors(starboardAnsiPalette)

        effectView.addSubview(terminal)
        panel.contentView = effectView

        self.panel = panel
        self.terminalView = terminal

        panel.orderFrontRegardless()
        panel.makeFirstResponder(terminal)

        // A persistent login shell, not a new Process per command: cd/pwd
        // state survives between commands, same as a normal terminal tab.
        terminal.startProcess(
            executable: Self.shellExecutable,
            args: ["-l"],
            environment: Self.childEnvironment(),
            currentDirectory: NSHomeDirectory()
        )

        let timer = Timer(timeInterval: dockTrackingInterval, repeats: true) { [weak self] _ in
            self?.syncFrameToDock()
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    /// SwiftTerm's defaults plus `SHELL`.
    ///
    /// Passing `nil` for `startProcess`'s `environment` makes it fall back to
    /// `Terminal.getEnvironmentVariables()`, a deliberately minimal set —
    /// `TERM`, `LANG`, and a few identity variables — that does not include
    /// `SHELL`. In a normal terminal `login(1)` sets that; nothing does here,
    /// so the child shell starts with `SHELL` empty.
    ///
    /// That's not cosmetic. Tools that read `$SHELL` to decide which dialect
    /// to emit guess wrong and produce bash for a zsh session: `ngrok
    /// completion`, run from `.zshrc`, emits a bash completion script whose
    /// `[[ $(type -t compopt) = "builtin" ]]` line makes zsh fail with
    /// `type: bad option: -t` on every launch. Powerlevel10k's instant prompt
    /// then reports the resulting stray output as a configuration warning,
    /// which points at the user's `.zshrc` rather than at the terminal — the
    /// original symptom was several layers removed from this line.
    ///
    /// Appended rather than assigned unconditionally, so that if a future
    /// SwiftTerm starts providing `SHELL` itself, its value wins instead of
    /// being silently shadowed by ours.
    private static func childEnvironment() -> [String] {
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        if !environment.contains(where: { $0.hasPrefix("SHELL=") }) {
            environment.append("SHELL=\(shellExecutable)")
        }
        return environment
    }

    /// Cmd+C/Cmd+V/Cmd+A only reach a view's copy(_:)/paste(_:)/selectAll(_:)
    /// via AppKit's menu-key-equivalent system — there's no such routing
    /// without a main menu at all, which an accessory app with no Dock icon
    /// otherwise has no reason to set up. This menu is never shown (the
    /// nonactivating panel never makes Starboard the frontmost app, so its
    /// menu bar never displays); it exists purely so those key equivalents
    /// resolve to the terminal view's standard responder-chain actions.
    private func setUpMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "Toggle Expanded", action: #selector(toggleExpanded(_:)), keyEquivalent: "e")
        appMenu.addItem(withTitle: "Quit Starboard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    /// Cmd+E, resolved the same key-equivalent way as Copy/Paste/Select All
    /// above — reaches here even though the hidden menu is never drawn.
    /// Flips between the Dock-height default and full screen height, then
    /// applies immediately rather than waiting for the next tracking tick.
    @objc private func toggleExpanded(_ sender: Any?) {
        isExpanded.toggle()
        syncFrameToDock()
    }

    private func syncFrameToDock() {
        let frame = currentFrame()
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
        terminalView.frame = terminalContentFrame(in: NSRect(origin: .zero, size: frame.size))
    }

    /// Padded frame for the terminal content, vertically centered within
    /// that padding. SwiftTerm derives its row count as
    /// `floor(height / cellHeight)`, which rarely divides the available
    /// height evenly — the leftover slack is centered here rather than
    /// left stuck at the top, which is what a plain edge inset produces.
    private func terminalContentFrame(in bounds: NSRect) -> NSRect {
        let usableWidth = bounds.width - terminalPadding * 2
        let usableHeight = bounds.height - terminalPadding * 2
        let cellHeight = estimatedCellHeight(for: terminalFont)
        let rows = max(1, Int(usableHeight / cellHeight))
        let contentHeight = CGFloat(rows) * cellHeight
        let verticalSlack = (usableHeight - contentHeight) / 2
        return NSRect(
            x: bounds.minX + terminalPadding,
            y: bounds.minY + terminalPadding + verticalSlack,
            width: max(usableWidth, 0),
            height: max(contentHeight, 0)
        )
    }

    /// Mirrors SwiftTerm's own internal cell-height calculation (ascent +
    /// descent + leading, at its default 1.0 line spacing) so the padding
    /// above can predict its row count before SwiftTerm itself lays out.
    private func estimatedCellHeight(for font: NSFont) -> CGFloat {
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        return ceil(ascent + descent + leading)
    }

    /// Sizes and positions the panel as a companion to the Dock: same
    /// height, same bottom margin (so they sit on one baseline), left edge
    /// touching the Dock's right edge, and its own right edge flush against
    /// the screen's right edge (no margin there at all).
    private func currentFrame() -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 0, y: 0, width: fallbackWidth, height: fallbackHeight)
        }

        guard let rawDock = dockIconTrayFrame() else {
            return fallbackFrame(on: screen)
        }
        // The AXList's box doesn't quite match the Dock's painted chrome
        // on either edge: its bottom sits above the Dock's real bottom
        // margin, and its top overshoots above the Dock's real top edge
        // (by a smaller amount) — independently tuned corrections for each.
        let minY = rawDock.minY - dockBottomCorrection
        let maxY = rawDock.maxY - dockTopCorrection
        let dock = NSRect(x: rawDock.minX, y: minY, width: rawDock.width, height: maxY - minY)

        let x = dock.maxX
        let width = max(screen.frame.maxX - x, 0)
        // Same bottom edge either way — dock.minY is the shared baseline —
        // but expanded grows the top edge up to the menu bar instead of
        // stopping at the Dock's own height. visibleFrame.maxY (not
        // frame.maxY) is what excludes the menu bar's reserved strip
        // (including notch height) — frame.maxY is the physical screen
        // edge, which the menu bar draws over since it sits at a higher
        // window level than this panel's .floating, not something a frame
        // that merely stops short of it can avoid.
        let height = isExpanded ? screen.visibleFrame.maxY - dock.minY : dock.height
        return NSRect(x: x, y: dock.minY, width: width, height: height)
    }

    /// Used before Accessibility permission is granted (or if the Dock's
    /// AX tree is ever unavailable). The height macOS reserves for the
    /// Dock is still readable without any special permission, from the gap
    /// between the screen's full frame and its visible frame — just not
    /// the Dock's actual width, so this can't touch its right edge.
    private func fallbackFrame(on screen: NSScreen) -> NSRect {
        let reserved = screen.visibleFrame.minY - screen.frame.minY
        let collapsedHeight = reserved > 4 ? reserved : fallbackHeight
        let x = screen.frame.maxX - fallbackWidth - fallbackMargin
        let y = screen.frame.minY + fallbackMargin
        let height = isExpanded ? screen.visibleFrame.maxY - y : collapsedHeight
        return NSRect(x: x, y: y, width: fallbackWidth, height: height)
    }

    /// Tight bounding box of the Dock's icon tray — the `AXList` child of
    /// the Dock process's accessibility tree — read via the Accessibility
    /// API. This is deliberately not the Dock's own window frame: on
    /// modern macOS that frame spans the entire screen (the Dock process
    /// also hosts desktop wallpaper/icon interaction), which is useless
    /// for positioning. Returns nil if Accessibility permission hasn't
    /// been granted yet, or the Dock's AX tree can't be read.
    private func dockIconTrayFrame() -> NSRect? {
        guard let screen = NSScreen.main else { return nil }
        guard let dockApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" }) else {
            return nil
        }

        let axApp = AXUIElementCreateApplication(dockApp.processIdentifier)

        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement]
        else {
            return nil
        }

        guard let list = children.first(where: { axRole(of: $0) == (kAXListRole as String) }) else {
            return nil
        }

        guard let position = axPoint(list, kAXPositionAttribute as CFString),
              let size = axSize(list, kAXSizeAttribute as CFString)
        else {
            return nil
        }

        // AX coordinates are Quartz's top-left-origin space; flip to
        // AppKit's bottom-left-origin space.
        let flippedY = screen.frame.height - position.y - size.height
        return NSRect(x: position.x, y: flippedY, width: size.width, height: size.height)
    }

    private func axRole(of element: AXUIElement) -> String? {
        var roleRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success else {
            return nil
        }
        return roleRef as? String
    }

    private func axPoint(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
        var valueRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &valueRef) == .success,
              let axValue = valueRef
        else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func axSize(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
        var valueRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &valueRef) == .success,
              let axValue = valueRef
        else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(axValue as! AXValue, .cgSize, &size) else { return nil }
        return size
    }
}
