import Cocoa
import ApplicationServices
import CoreGraphics
import CoreText
import SwiftTerm

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var terminalView: LocalProcessTerminalView!
    private var tintView: NSView!
    private var effectView: NSVisualEffectView!
    private var trackingTimer: Timer!
    private var themeStore = ThemeStore()
    private var settingsWindow: SettingsWindowController?
    /// Last-seen `appearanceIsDark` while the active theme is `system`, so
    /// the Dock timer can re-resolve when macOS flips light/dark without a
    /// dedicated appearance observer (the NSApplication notification isn't
    /// available on every SDK we build against).
    private var lastAppearanceIsDark: Bool?
    /// Toggled by the hidden Cmd+E menu item. When true, `currentFrame()`
    /// grows the panel upward to the top of the screen instead of matching
    /// the Dock's height — the bottom edge (and x/width) still track the
    /// Dock live, only the top edge changes.
    private var isExpanded = false

    private let fallbackWidth: CGFloat = 300
    private let fallbackHeight: CGFloat = 64
    private let fallbackRightMargin: CGFloat = 8
    /// Floor for the Dock-glued panel width. The panel's natural width is
    /// whatever gap remains between the Dock's right edge and the screen's
    /// right edge — with a crowded Dock that gap can shrink to a few dozen
    /// points, which reads as "Starboard didn't open" rather than a usable
    /// terminal. When the gap undershoots this, the panel grows leftward
    /// (overlapping Dock icons) so it stays visible.
    private let minimumPanelWidth: CGFloat = 300
    private let cornerRadius: CGFloat = 12
    /// `com.apple.dock`'s preferences domain -- read directly (not via
    /// Accessibility) to detect orientation/auto-hide, since both are
    /// meaningful even before Accessibility permission is granted.
    private let dockPreferencesDomain = "com.apple.dock" as CFString
    private let dockTrackingInterval: TimeInterval = 1.0
    /// Empirical corrections for the gap between the Dock's AXList (icon
    /// row) bounding box and its actual painted chrome, which Accessibility
    /// doesn't expose directly. Tuned against a real Dock; nudge these if
    /// the panel's edges drift from the Dock's over time or on other
    /// displays/tile sizes.
    private let dockBottomCorrection: CGFloat = 5
    private let dockTopCorrection: CGFloat = 5
    /// Inset between the panel's edge and the terminal content. Chosen
    /// together with the default 11pt theme font size so that, at a Dock
    /// height around 57-60pt, exactly two terminal rows fit.
    private let terminalPadding: CGFloat = 8
    /// The shell launched in the panel's pseudo-terminal, and the value
    /// exported as `SHELL` to it (see `childEnvironment`) — kept as one
    /// constant so those two can't drift apart.
    private static let shellExecutable = "/bin/zsh"
    /// Live font from the active theme. Updated by `applyTheme`; used by
    /// `terminalContentFrame` so row count tracks font-size changes.
    private var terminalFont: NSFont

    override init() {
        // Placeholder until applyResolvedTheme runs in didFinishLaunching —
        // can't read themeStore here before all stored properties are set.
        terminalFont = Theme.resolveFont(name: nil, size: Theme.defaultFontSize)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Triggers the system Accessibility permission prompt on first
        // launch if not already granted. Needed to read the Dock's icon
        // tray geometry precisely; falls back to an approximation until
        // it's granted (see fallbackFrame below). Result captured (not
        // discarded) to drive the in-terminal hint fed below.
        let promptOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let accessibilityTrusted = AXIsProcessTrustedWithOptions(promptOptions)

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
        effectView.layer?.borderWidth = 1

        // Theme tint layered on top of the system blur. Deliberately not
        // sampling the Dock's material — that recipe is private and drifts
        // with wallpaper/macOS releases; themes own a constant tint instead.
        let tintView = NSView(frame: effectView.bounds)
        tintView.autoresizingMask = [.width, .height]
        tintView.wantsLayer = true
        effectView.addSubview(tintView)

        let terminal = LocalProcessTerminalView(frame: terminalContentFrame(in: effectView.bounds))
        // Width only — height is recomputed and recentered explicitly in
        // syncFrameToDock, since SwiftTerm's row count is a floor() of
        // pixel height and rarely divides it evenly, leaving slack that
        // needs to be centered rather than pinned to the top or bottom.
        terminal.autoresizingMask = [.width]
        // Let the blur behind the panel show through instead of the
        // terminal's own opaque background.
        terminal.nativeBackgroundColor = .clear
        terminal.layer?.backgroundColor = NSColor.clear.cgColor
        // Discoverability for the hidden key equivalents — no menu bar or
        // Dock icon to put these in. Kept on a tooltip so it doesn't eat
        // the ~2 visible terminal rows.
        terminal.toolTip = "⌘E expand · ⌘T theme · ⌘, settings · ⌘Q quit"

        effectView.addSubview(terminal)
        panel.contentView = effectView

        self.panel = panel
        self.effectView = effectView
        self.tintView = tintView
        self.terminalView = terminal

        applyResolvedTheme()
        lastAppearanceIsDark = appearanceIsDark

        panel.orderFrontRegardless()
        panel.makeFirstResponder(terminal)

        // Ad-hoc signing pins the Accessibility grant to this exact
        // binary's content hash, not the app's path/identifier, so
        // updating Starboard in place (same /Applications/Starboard.app)
        // leaves System Settings showing a "Starboard" row that's already
        // checked on, but silently no longer valid for the new binary --
        // and re-checking that same box doesn't fix it, only removing
        // the row and letting a fresh one get created does. Fed directly
        // into the terminal (bypassing the shell entirely, so it can't be
        // mistaken for shell output or land in history) since that's the
        // only UI this menu-bar-less, Dock-icon-less app has to say
        // anything at all -- there's nowhere else a user would see this.
        // Kept to one short line deliberately: a multi-line explainer
        // (tried first) reads fine right when it's fed, but this panel
        // only ever shows ~2 rows, so it scrolls out of view almost
        // immediately once the shell starts producing its own output --
        // longer didn't mean clearer, just more of it to scroll back to.
        if !accessibilityTrusted {
            terminal.feed(text: "Not glued to Dock? Remove Starboard in System Settings → Accessibility, then re-add it.\r\n\r\n")
        }

        // A persistent login shell, not a new Process per command: cd/pwd
        // state survives between commands, same as a normal terminal tab.
        terminal.startProcess(
            executable: Self.shellExecutable,
            args: ["-l"],
            environment: childEnvironment(),
            currentDirectory: NSHomeDirectory()
        )

        let timer = Timer(timeInterval: dockTrackingInterval, repeats: true) { [weak self] _ in
            self?.syncFrameToDock()
            self?.reloadThemeIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    /// Appearance is "dark" when the app's effective appearance matches
    /// darkAqua — used to resolve the `system` theme to Ocean vs Light.
    private var appearanceIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func applyResolvedTheme() {
        apply(themeStore.resolvedTheme(isDark: appearanceIsDark))
    }

    /// Pushes a resolved theme onto the live panel and terminal. Font-size
    /// changes recompute the content frame so the row count stays honest.
    private func apply(_ theme: Theme) {
        guard panel != nil, terminalView != nil, tintView != nil, effectView != nil else { return }

        // Always darkAqua so OSC 11 background probes (Cursor Agent, etc.)
        // don't classify the clear/blurred panel as a light terminal and
        // enter Agent's broken light prompt-bar styling.
        panel.appearance = NSAppearance(named: .darkAqua)

        tintView.layer?.backgroundColor = theme.panelTint.cgColor
        effectView.layer?.borderColor = theme.borderColor.cgColor

        terminalFont = Theme.resolveFont(name: theme.fontName, size: theme.fontSize)
        terminalView.font = terminalFont
        terminalView.nativeForegroundColor = theme.foreground
        terminalView.installColors(theme.ansi)

        // Font metrics changed → row geometry may have changed even if the
        // panel's outer frame didn't.
        terminalView.frame = terminalContentFrame(in: NSRect(origin: .zero, size: panel.frame.size))
        panel.invalidateShadow()
    }

    /// Cheap poll from the Dock timer: pick up hand-edits to config.json
    /// and system appearance flips (for the `system` theme) without a
    /// dedicated file or appearance observer.
    private func reloadThemeIfNeeded() {
        var needsApply = themeStore.reload()
        let dark = appearanceIsDark
        if themeStore.config.theme.lowercased() == Theme.system.name, lastAppearanceIsDark != dark {
            needsApply = true
        }
        lastAppearanceIsDark = dark
        guard needsApply else { return }
        applyResolvedTheme()
        settingsWindow?.reloadFromStore()
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
    ///
    /// Always advertise a dark terminal to children (`COLORFGBG=15;0`,
    /// `TERM_THEME=dark`). Cursor Agent's light theme still paints black
    /// prompt bars with dark text (known CLI bug); forcing dark keeps the
    /// TUI readable inside every Starboard theme. Only applied at shell
    /// start — cycling themes later won't rewrite a live process env.
    private func childEnvironment() -> [String] {
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        if !environment.contains(where: { $0.hasPrefix("SHELL=") }) {
            environment.append("SHELL=\(Self.shellExecutable)")
        }
        if !environment.contains(where: { $0.hasPrefix("COLORFGBG=") }) {
            environment.append("COLORFGBG=15;0")
        }
        if !environment.contains(where: { $0.hasPrefix("TERM_THEME=") }) {
            environment.append("TERM_THEME=dark")
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
        appMenu.addItem(withTitle: "Cycle Theme", action: #selector(cycleTheme(_:)), keyEquivalent: "t")
        let settingsItem = appMenu.addItem(
            withTitle: "Settings…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
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

    /// Cmd+T — ocean → dark → light → system → ocean, persisted to config.
    /// No in-terminal echo: feeding text into a live TUI (Cursor Agent)
    /// injects junk into its input stream.
    @objc private func cycleTheme(_ sender: Any?) {
        _ = themeStore.cycleBuiltIn()
        applyResolvedTheme()
        settingsWindow?.reloadFromStore()
    }

    /// Cmd+, — preferences window over the same `config.json` ThemeStore.
    @objc private func openSettings(_ sender: Any?) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                getConfig: { [weak self] in
                    self?.themeStore.config ?? .default
                },
                resolvedTheme: { [weak self] in
                    guard let self else { return Theme.ocean }
                    return self.themeStore.resolvedTheme(isDark: self.appearanceIsDark)
                },
                updateConfig: { [weak self] body in
                    guard let self else { return }
                    self.themeStore.modify(body)
                    self.applyResolvedTheme()
                },
                resetOverrides: { [weak self] in
                    guard let self else { return }
                    self.themeStore.resetOverrides()
                    self.applyResolvedTheme()
                },
                openConfigFile: { [weak self] in
                    guard let self else { return }
                    let url = self.themeStore.ensureConfigFile()
                    NSWorkspace.shared.open(url)
                }
            )
        }
        settingsWindow?.showSettings()
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
    ///
    /// Follows a bottom-anchored Dock onto whichever display currently
    /// hosts it — including a secondary monitor. Left/right Dock and
    /// auto-hide still return nil from `dockIconTrayFrame` (those need a
    /// different axis / live visibility signal) and fall back the same
    /// way as a missing Accessibility grant. The existing 1s poll picks
    /// up Dock moves between displays, orientation changes, and
    /// connect/disconnect without extra observers.
    private func currentFrame() -> NSRect {
        guard let mainScreen = mainDisplayScreen() else {
            return NSRect(x: 0, y: 0, width: fallbackWidth, height: fallbackHeight)
        }

        guard let rawDock = dockIconTrayFrame(mainScreen: mainScreen),
              let screen = screenHosting(rawDock) else {
            return fallbackFrame(on: mainScreen)
        }
        // The AXList's box doesn't quite match the Dock's painted chrome
        // on either edge: its bottom sits above the Dock's real bottom
        // margin, and its top overshoots above the Dock's real top edge
        // (by a smaller amount) — independently tuned corrections for each.
        let minY = rawDock.minY - dockBottomCorrection
        let maxY = rawDock.maxY - dockTopCorrection
        let dock = NSRect(x: rawDock.minX, y: minY, width: rawDock.width, height: maxY - minY)

        let naturalWidth = max(screen.frame.maxX - dock.maxX, 0)
        // Crowded Docks leave almost no gap (seen as low as ~40pt with
        // ~35 icons on a 2056pt-wide display). Grow left into the Dock's
        // space rather than rendering a sliver that looks like a no-op.
        let width = max(naturalWidth, minimumPanelWidth)
        let x = screen.frame.maxX - width
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

    /// Used whenever `dockIconTrayFrame` can't be trusted: Accessibility
    /// permission not granted, the Dock's AX tree unreadable, a left/right
    /// Dock, or an auto-hiding Dock. Anchored to the main display (not
    /// whichever screen has keyboard focus) so the panel doesn't jump as
    /// focus moves. The height macOS reserves for the Dock is still
    /// readable without any special permission, from the gap between the
    /// screen's full frame and its visible frame — just not the Dock's
    /// actual width, so this can't touch its right edge.
    private func fallbackFrame(on screen: NSScreen) -> NSRect {
        let reserved = screen.visibleFrame.minY - screen.frame.minY
        let collapsedHeight = reserved > 4 ? reserved : fallbackHeight
        let x = screen.frame.maxX - fallbackWidth - fallbackRightMargin
        // Flush with the screen's true bottom edge — the same baseline the
        // glued panel sits on (dock.minY in currentFrame() also lands right
        // at the Dock's real bottom margin, a hair above this edge, not
        // padded away from it). No separate bottom margin here; only the
        // right edge keeps one, so the panel doesn't touch the screen's
        // corner.
        let y = screen.frame.minY
        let height = isExpanded ? screen.visibleFrame.maxY - y : collapsedHeight
        return NSRect(x: x, y: y, width: fallbackWidth, height: height)
    }

    /// The display identified by `CGMainDisplayID()` — Quartz/Accessibility
    /// coordinates are anchored to this display's top-left, and it's the
    /// stable fallback target when the Dock tray can't be read. Deliberately
    /// not `NSScreen.main`, which tracks keyboard focus and would make the
    /// panel jump screens as the user works across monitors.
    private func mainDisplayScreen() -> NSScreen? {
        let mainDisplayID = CGMainDisplayID()
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == mainDisplayID
        }
    }

    /// Screen whose frame contains the Dock tray's center. Used so the
    /// panel follows the Dock onto a secondary display instead of staying
    /// pinned to the main one.
    private func screenHosting(_ rect: NSRect) -> NSScreen? {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        if let match = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return match
        }
        // Degenerate: tray sits on a boundary or slightly outside every
        // frame (rounding / chrome corrections). Prefer the screen with
        // the largest intersection area.
        return NSScreen.screens
            .map { screen -> (NSScreen, CGFloat) in
                let overlap = screen.frame.intersection(rect)
                let area = overlap.isNull ? 0 : overlap.width * overlap.height
                return (screen, area)
            }
            .filter { $0.1 > 0 }
            .max(by: { $0.1 < $1.1 })?
            .0
    }

    /// "bottom", "left", or "right". Absent entirely counts as "bottom":
    /// the key is only written once the user changes it away from the
    /// default.
    private func dockOrientation() -> String {
        CFPreferencesAppSynchronize(dockPreferencesDomain)
        return (CFPreferencesCopyAppValue("orientation" as CFString, dockPreferencesDomain) as? String) ?? "bottom"
    }

    private func dockAutoHides() -> Bool {
        (CFPreferencesCopyAppValue("autohide" as CFString, dockPreferencesDomain) as? Bool) ?? false
    }

    /// Tight bounding box of the Dock's icon tray — the `AXList` child of
    /// the Dock process's accessibility tree — in AppKit coordinates.
    /// Deliberately not the Dock's own window frame: on modern macOS that
    /// frame spans the entire screen (the Dock process also hosts desktop
    /// wallpaper/icon interaction), which is useless for positioning.
    ///
    /// Returns nil if Accessibility permission hasn't been granted, the
    /// Dock's AX tree can't be read, the Dock isn't bottom-anchored, or
    /// it's set to auto-hide — any of which means "don't track, fall
    /// back" to the caller. Which *display* the Dock is on is not a nil
    /// condition: the AppKit rect is global, and `screenHosting` picks
    /// the screen afterward.
    private func dockIconTrayFrame(mainScreen: NSScreen) -> NSRect? {
        guard dockOrientation() == "bottom", !dockAutoHides() else { return nil }

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

        // AX is Quartz's top-left-origin space, always anchored to the
        // *main* display's top-left regardless of which screen the Dock
        // is on. Flip Y against mainScreen.frame.maxY (not the Dock's
        // screen height, and not mainScreen.frame.height alone — those
        // diverge when a secondary display has a non-zero minY). X maps
        // 1:1 into AppKit's global space, including negative origins on
        // displays arranged to the left of main.
        let flippedY = mainScreen.frame.maxY - position.y - size.height
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
