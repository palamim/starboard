import ApplicationServices
import Cocoa
import CoreGraphics
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
    /// Toggled by the hidden Cmd+E menu item. When true, `frame(for:)`
    /// ignores the Dock entirely and centers the panel within the screen's
    /// visible area at `expandedSizeFraction` of its width/height —
    /// collapsing goes back to the Dock-glued frame.
    private var isExpanded = false
    /// The screen an expanded panel was expanded on, stored as a display ID
    /// rather than an `NSScreen`: screen objects are invalidated by display
    /// reconfiguration and keep reporting stale frames afterwards, so a
    /// cached object would silently re-centre onto coordinates that no
    /// longer exist. Re-resolved to a live screen on every use.
    private var expansionScreenID: CGDirectDisplayID?
    /// Coarse-cadence caches, refreshed about once a second (see `tick`).
    /// The Dock's preferences are cross-process reads and the host screen
    /// comes from a window-list scan; neither belongs on a hotter path.
    private var cachedDockOrientation = "bottom"
    private var cachedDockAutoHides = false
    private var cachedDockHostScreenID: CGDirectDisplayID?
    /// Per-channel suppression of repeated debug lines. Keyed by channel
    /// because several kinds of line are emitted per evaluation and they
    /// alternate - a single "last line" would never match and would suppress
    /// nothing at all.
    private var lastDebugLine: [String: String] = [:]

    private let fallbackWidth: CGFloat = 300
    private let fallbackHeight: CGFloat = 64
    private let cornerRadius: CGFloat = 12
    /// Fraction of the screen's visible area (both width and height) the
    /// panel resizes to when expanded — centered within that area, entirely
    /// independent of the Dock's own position/size while expanded.
    private let expandedSizeFraction: CGFloat = 0.75
    /// `com.apple.dock`'s preferences domain -- read directly (not via
    /// Accessibility) to detect orientation/auto-hide, since both are
    /// meaningful even before Accessibility permission is granted.
    private let dockPreferencesDomain = "com.apple.dock" as CFString
    /// Starboard's own panel color — a near-black deep navy, independent of
    /// the Dock's material and whatever's on the desktop behind it. First
    /// pass; tune the RGB/alpha here to taste.
    private let panelTintColor = NSColor(calibratedRed: 0.02, green: 0.035, blue: 0.06, alpha: 0.65)
    private let dockTrackingInterval: TimeInterval = 1.0
    /// Below this, the panel stops shrinking and grows leftward over the
    /// Dock's rightmost icons instead. A wide or icon-heavy Dock on a
    /// narrow display can leave only a few characters of room to its right;
    /// overlapping a couple of icons is mildly ugly, a 40pt terminal is
    /// useless. Same value as `fallbackWidth` on purpose - one "narrowest
    /// useful panel" number, not two.
    private var minPanelWidth: CGFloat { fallbackWidth }
    /// `STARBOARD_DEBUG=1` gates stderr instrumentation, and it stays in the
    /// build permanently: this positions itself against geometry read from
    /// other processes across whatever display arrangement the user happens
    /// to have, and "it's 200pt off on one monitor" is unanswerable without
    /// numbers. Re-adding instrumentation after the fact means rebuilding
    /// and reproducing on a machine that isn't ours.
    private static let debugEnabled =
        ProcessInfo.processInfo.environment["STARBOARD_DEBUG"] == "1"
    /// Channels that log transitions rather than per-tick state, and are
    /// therefore never repeat-suppressed (see `debugLog`).
    private static let debugEventChannels: Set<String> = [
        "expand", "screens",
    ]
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
    /// `static` so `init()` can reference it while initializing
    /// `terminalFont` — Swift forbids touching `self` before every stored
    /// property is set, which is why the font size used to be duplicated as
    /// a literal there instead.
    private static let terminalFontSize: CGFloat = 11
    /// Preferred terminal fonts, best first. Nerd Font variants come ahead
    /// of plain Menlo because prompt themes like Powerlevel10k draw their
    /// separators and icons from the Nerd Font private-use ranges
    /// (e.g.  U+E0B0,  U+F179) that no stock macOS font carries — without
    /// one, those render as Last Resort's box-with-question-mark. Add your
    /// own to the front of this list; the first name that resolves wins.
    private static let preferredFontNames = [
        "MesloLGS NF",
        "MesloLGS Nerd Font",
        "Hack Nerd Font",
        "FiraCode Nerd Font",
        "JetBrainsMono Nerd Font",
        "Menlo",
    ]
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
        ansiColor(20, 24, 33),  // black
        ansiColor(198, 74, 90),  // red — port light
        ansiColor(79, 157, 105),  // green — starboard light
        ansiColor(196, 154, 62),  // yellow — brass
        ansiColor(58, 124, 165),  // blue — deep ocean
        ansiColor(133, 110, 168),  // magenta — dusk
        ansiColor(69, 156, 156),  // cyan — seafoam
        ansiColor(196, 190, 172),  // white — sand
        ansiColor(75, 87, 99),  // bright black — slate
        ansiColor(222, 102, 118),  // bright red
        ansiColor(111, 191, 135),  // bright green
        ansiColor(224, 186, 105),  // bright yellow
        ansiColor(95, 168, 211),  // bright blue
        ansiColor(169, 143, 201),  // bright magenta
        ansiColor(114, 214, 207),  // bright cyan
        ansiColor(230, 224, 208),  // bright white — foam
    ]

    override init() {
        // First installed font from preferredFontNames, falling back to the
        // monospaced system font (SF Mono) only if none resolve. SF Mono is
        // last on purpose: it's missing glyphs common prompt themes use
        // (e.g. ➜ U+27A4), so it's a worse floor than Menlo, which has
        // broad coverage and is what Terminal.app has defaulted to for
        // years. Menlo in turn still lacks the Nerd Font ranges, hence the
        // patched variants ahead of it.
        //
        // NSFont(name:) returns nil for a name that isn't installed, so a
        // typo here degrades silently rather than failing the build — worth
        // checking the resolved font if the prompt looks wrong.
        let size = Self.terminalFontSize
        terminalFont =
            Self.preferredFontNames.lazy.compactMap { NSFont(name: $0, size: size) }.first
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Triggers the system Accessibility permission prompt on first
        // launch if not already granted. Needed to read the Dock's icon
        // tray geometry precisely; falls back to an approximation until
        // it's granted (see fallbackFrame below). Result captured (not
        // discarded) to drive the in-terminal hint fed below.
        let promptOptions =
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let accessibilityTrusted = AXIsProcessTrustedWithOptions(promptOptions)

        setUpMainMenu()

        // Before anything reads the Dock: the presence resolution below
        // runs entirely off these caches, and at launch nothing has filled
        // them in yet.
        refreshCoarseCaches()
        let initialPresence = resolveDockPresence()
        let initialFrame =
            initialPresence.map { frame(for: $0) }
            ?? NSRect(x: 0, y: 0, width: fallbackWidth, height: fallbackHeight)

        let panel = KeyablePanel(
            contentRect: initialFrame,
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
        // applyFrame, since SwiftTerm's row count is a floor() of
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
        // The only discoverability hint for Cmd+E/Cmd+Q: there's no menu
        // bar, Dock icon, or button to put one in, and feeding it into the
        // terminal as text (tried for the Accessibility hint above) reads
        // poorly in a panel this short -- it scrolls out of view almost
        // immediately and needs the user to scroll back up to find it. A
        // tooltip costs nothing until someone's cursor is actually
        // sitting still over the panel, which is exactly when it's useful
        // and never otherwise in the way.
        terminal.toolTip = "⌘E expand · ⌘Q quit"

        effectView.addSubview(terminal)
        panel.contentView = effectView

        self.panel = panel
        self.terminalView = terminal

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
            terminal.feed(
                text:
                    "Not glued to Dock? Remove Starboard in System Settings → Accessibility, then re-add it.\r\n"
            )
        }

        // A persistent login shell, not a new Process per command: cd/pwd
        // state survives between commands, same as a normal terminal tab.
        terminal.startProcess(
            executable: Self.shellExecutable,
            args: ["-l"],
            environment: Self.childEnvironment(),
            currentDirectory: NSHomeDirectory()
        )

        let timer = Timer(timeInterval: dockTrackingInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer

        // Unplugging the display the panel is on would otherwise strand a
        // terminal at coordinates that no longer exist, with no way back
        // until the user happens to move it.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
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
        appMenu.addItem(
            withTitle: "Toggle Expanded", action: #selector(toggleExpanded(_:)), keyEquivalent: "e")
        appMenu.addItem(
            withTitle: "Quit Starboard", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(
            withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    /// Cmd+E, resolved the same key-equivalent way as Copy/Paste/Select All
    /// above — reaches here even though the hidden menu is never drawn.
    /// Flips between the Dock-glued default and a centered, screen-relative
    /// size, then applies immediately rather than waiting for the next
    /// tracking tick.
    @objc private func toggleExpanded(_ sender: Any?) {
        // Without this, Cmd+E can act on up-to-1s-stale orientation/
        // auto-hide/host state if the user changes Dock settings or moves
        // displays right before pressing it — every other caller of
        // `resolveDockPresence()` refreshes first too.
        refreshCoarseCaches()
        let presence = resolveDockPresence()

        if isExpanded {
            isExpanded = false
            expansionScreenID = nil
            applyFrame(
                presence.map { collapsedGeometry(for: $0) }
                    ?? NSRect(x: 0, y: 0, width: fallbackWidth, height: fallbackHeight))
        } else {
            isExpanded = true
            // The screen the panel is *sitting on*, not the Dock's host, and
            // captured once here rather than re-derived later. Those two are
            // routinely different on a multi-display setup, and centring on
            // the Dock's host would throw a window the user is actively
            // typing in onto a different monitor.
            let screen = expansionScreen(fallingBackTo: presence?.host)
            expansionScreenID = screen.flatMap(displayID(of:))
            if let screen {
                applyFrame(expandedFrame(on: screen))
            }
        }
        debugLog("expand", "isExpanded=\(isExpanded) screen=\(describe(expansionScreenID))")
    }

    /// The screen an expansion is anchored to: the one the panel is mostly
    /// on, then the one its frame overlaps most, then the Dock's host.
    private func expansionScreen(fallingBackTo host: NSScreen?) -> NSScreen? {
        panel.screen ?? screenWithGreatestIntersection(with: panel.frame) ?? host
            ?? mainDisplayScreen()
    }

    /// One tick of the tracking loop: refresh the coarse caches, then
    /// re-evaluate where the panel belongs.
    private func tick() {
        refreshCoarseCaches()
        runEvaluation()
    }

    private func refreshCoarseCaches() {
        cachedDockOrientation = dockOrientation()
        cachedDockAutoHides = dockAutoHides()

        // A fixed Dock is fully described by the screens themselves:
        // exactly one reserves a bottom strip, and it's the host. Free, and
        // it keeps the window-list scan (which walks every window on the
        // system) off the common configuration's once-a-second path - it's
        // only needed when nothing reserves a bottom strip, i.e. a vertical
        // or auto-hiding Dock.
        let host =
            cachedDockAutoHides
            ? dockWindowHostScreen()
            : (screenReservingBottomStrip() ?? dockWindowHostScreen())
        cachedDockHostScreenID = host.flatMap(displayID(of:))
    }

    private func screenReservingBottomStrip() -> NSScreen? {
        NSScreen.screens.first { $0.visibleFrame.minY - $0.frame.minY > 4 }
    }

    private func runEvaluation() {
        guard let presence = resolveDockPresence() else {
            // `resolveDockPresence()` only returns nil when there's no
            // screen at all to attach to (e.g. a transient empty
            // `NSScreen.screens` during sleep/wake or display teardown).
            // Falling back to a concrete rect here, rather than leaving the
            // panel exactly where it last was, matches every other
            // presence-less path in this file.
            applyFrame(NSRect(x: 0, y: 0, width: fallbackWidth, height: fallbackHeight))
            return
        }
        evaluate(presence)
    }

    /// Applies the geometry a presence implies.
    private func evaluate(_ presence: DockPresence) {
        debugLog(
            "state",
            "\(presence.summary) orientation=\(cachedDockOrientation) "
                + "autohide=\(cachedDockAutoHides) "
                + "expansion=\(describe(expansionScreenID))")
        applyFrame(frame(for: presence))
    }

    private func applyFrame(_ frame: NSRect) {
        guard panel.frame != frame else { return }
        debugLog("frame", "\(frame)")
        panel.setFrame(frame, display: true)
        terminalView.frame = terminalContentFrame(in: NSRect(origin: .zero, size: frame.size))
    }

    /// A display can disappear out from under the panel. Clearing the
    /// stranded case here rather than waiting for the next tick keeps a
    /// terminal the user is looking at from sitting at coordinates that no
    /// longer exist.
    @objc private func screenParametersChanged(_ notification: Notification) {
        refreshCoarseCaches()
        let presence = resolveDockPresence()
        debugLog("screens", "configuration changed; panel at \(panel.frame)")

        // Still reachable: the arrangement changed but nothing is stranded.
        if NSScreen.screens.contains(where: { $0.frame.intersects(panel.frame) }) {
            if let presence { evaluate(presence) }
            return
        }

        guard let presence else { return }
        if isExpanded {
            // The captured screen is the one that just disappeared. An
            // expanded panel doesn't chase the Dock between displays; that
            // doesn't mean it should stay on a display that no longer exists.
            expansionScreenID = displayID(of: presence.host)
            applyFrame(expandedFrame(on: presence.host))
        } else {
            applyFrame(collapsedGeometry(for: presence))
        }
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

    /// What the Dock is doing right now, and where. Replaces the older
    /// "did `dockIconTrayFrame` return a rect" question, which collapsed
    /// genuinely different situations into one nil.
    private enum DockPresence {
        /// Tray rect readable and on screen. Glue to it.
        case revealed(tray: NSRect, host: NSScreen)
        /// Vertical Dock, an auto-hiding Dock, no Accessibility permission,
        /// or an unreadable AX tree. Fallback geometry on `host`.
        case untracked(host: NSScreen)

        /// Never optional: a host that can't be resolved from the Dock at
        /// all still falls back to a real screen, so every case can name
        /// the display its geometry belongs on.
        var host: NSScreen {
            switch self {
            case .revealed(_, let host), .untracked(let host):
                return host
            }
        }

        var summary: String {
            switch self {
            case .revealed(let tray, let host):
                return "revealed tray=\(tray) host=\(host.frame)"
            case .untracked(let host):
                return "untracked host=\(host.frame)"
            }
        }
    }

    /// Resolves the Dock's presence, off the coarse caches plus one
    /// Accessibility read. Returns nil only when there is no screen at all
    /// to attach anything to.
    private func resolveDockPresence() -> DockPresence? {
        // Quartz and Accessibility coordinates are anchored to the main
        // display's top-left corner no matter how the displays are
        // arranged, so this screen is the reference frame for every flip
        // below, not the screen the Dock happens to be on.
        guard let mainScreen = mainDisplayScreen() ?? NSScreen.screens.first else { return nil }
        // Resolved before any early exit, so `.untracked` has a host to
        // carry too - a fallback corner on the Dock's display beats a
        // fallback corner on whichever display happens to be main.
        let cachedHost = cachedDockHostScreenID.flatMap(screen(for:)) ?? mainScreen

        // The one surviving orientation guard: a vertical Dock changes
        // which axis the panel would have to hug, which is a different
        // layout problem, not a tweak to this one.
        guard cachedDockOrientation == "bottom" else { return .untracked(host: cachedHost) }
        // An auto-hiding Dock keeps the untracked/fallback behaviour it has
        // always had, now on its own host display rather than whichever one
        // happens to be main. Guarding here rather than after the tray read
        // keeps a cross-process Accessibility call off the once-a-second
        // path entirely in that configuration.
        guard !cachedDockAutoHides else { return .untracked(host: cachedHost) }
        guard let tray = dockIconTrayFrame(flippedAgainst: mainScreen) else {
            return .untracked(host: cachedHost)
        }
        // A fixed Dock's tray is always on some real screen. If it isn't
        // (a stale/garbage AX read, most likely mid display-reconfiguration
        // — the exact moment this is riskiest to trust), fall back rather
        // than glue the panel to coordinates that don't correspond to
        // anything on screen.
        guard let trayHost = screenHosting(tray) else {
            return .untracked(host: cachedHost)
        }

        // A fixed Dock's tray is always on screen, so the tray itself is the
        // most direct statement of which display it belongs to.
        return .revealed(tray: tray, host: trayHost)
    }

    /// Geometry for a presence, expanded case first: an expanded panel is
    /// fully determined without a tray rect at all, which is what lets
    /// Cmd+E behave identically whether the Dock is revealed or untracked.
    private func frame(for presence: DockPresence) -> NSRect {
        if isExpanded {
            let screen = expansionScreenID.flatMap(screen(for:)) ?? presence.host
            return expandedFrame(on: screen)
        }
        return collapsedGeometry(for: presence)
    }

    private func collapsedGeometry(for presence: DockPresence) -> NSRect {
        switch presence {
        case .revealed(let tray, let host):
            return gluedFrame(tray: tray, on: host)
        case .untracked(let host):
            return fallbackFrame(on: host)
        }
    }

    /// A companion to the Dock: same height, same baseline, left edge
    /// against the Dock's right edge, right edge flush with the host
    /// screen's.
    ///
    /// Note the anchor: the width is decided first and `x` derived from it,
    /// the reverse of how this used to work. That's what lets the panel
    /// stop at `minPanelWidth` and grow leftward over the Dock's rightmost
    /// icons instead of overflowing past the screen's right edge.
    private func gluedFrame(tray: NSRect, on host: NSScreen) -> NSRect {
        // The AXList's box doesn't quite match the Dock's painted chrome
        // on either edge: its bottom sits above the Dock's real bottom
        // margin, and its top overshoots above the Dock's real top edge
        // (by a smaller amount) — independently tuned corrections for each.
        let minY = tray.minY - dockBottomCorrection
        let maxY = tray.maxY - dockTopCorrection

        let naturalWidth = host.frame.maxX - tray.maxX
        let width = max(naturalWidth, minPanelWidth)
        let x = host.frame.maxX - width
        return NSRect(x: x, y: minY, width: width, height: maxY - minY)
    }

    /// Centered within the screen's visible area (already excluding the
    /// menu bar, and the Dock's own reserved strip whenever it isn't set to
    /// auto-hide) at `expandedSizeFraction` of both dimensions. Deliberately
    /// independent of `dockIconTrayFrame` — sizing off the Dock-glued frame
    /// would tie the expanded size to whatever gap a given Dock happens to
    /// leave (as narrow as a few characters wide behind a large or
    /// icon-heavy Dock), and growing left to compensate would mean drawing
    /// directly over the Dock itself. Centering avoids both: expanded size
    /// is constant regardless of Dock configuration, and never overlaps it.
    private func expandedFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let width = visible.width * expandedSizeFraction
        let height = visible.height * expandedSizeFraction
        let x = visible.minX + (visible.width - width) / 2
        let y = visible.minY + (visible.height - height) / 2
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// Used whenever there's no tray rect to glue to: Accessibility
    /// permission not granted, the Dock's AX tree unreadable, an
    /// auto-hiding Dock, or a left/right Dock. The height macOS reserves
    /// for the Dock is still readable without any special permission, from
    /// the gap between the screen's full frame and its visible frame - just
    /// not the Dock's actual width, so this can't touch its right edge.
    /// Collapsed only - `frame(for:)` handles the expanded case itself
    /// before ever reaching here.
    ///
    /// Always called with the Dock's *host* screen, vertical Dock included:
    /// a rule that branches on Dock orientation for a layout that isn't
    /// orientation-dependent is a special case nobody remembers later, and
    /// a future vertical-Dock implementation inherits correct screen
    /// selection for free.
    private func fallbackFrame(on screen: NSScreen) -> NSRect {
        let reserved = screen.visibleFrame.minY - screen.frame.minY
        let collapsedHeight = reserved > 4 ? reserved : fallbackHeight
        let x = screen.frame.maxX - fallbackWidth
        // Flush with the screen's true bottom edge — the same baseline the
        // glued panel sits on (the tray-derived minY in gluedFrame also
        // lands right at the Dock's real bottom margin, a hair above this
        // edge, not padded away from it). No separate bottom margin here;
        // only the right edge keeps one, so the panel doesn't touch the
        // screen's corner.
        let y = screen.frame.minY
        return NSRect(x: x, y: y, width: fallbackWidth, height: collapsedHeight)
    }

    /// The display hosting the menu bar — i.e. the Dock's home in the
    /// supported configuration — identified via `CGMainDisplayID()`
    /// rather than `NSScreen.main`, which tracks whichever screen
    /// currently has keyboard focus. Using focus here would make this
    /// panel jump screens as the user works across multiple displays,
    /// exactly the "jumping" this is meant to avoid. Quartz/Accessibility
    /// coordinates (used below) are anchored to this display's top-left
    /// corner regardless of how displays are arranged relative to it.
    private func mainDisplayScreen() -> NSScreen? {
        screen(for: CGMainDisplayID())
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { self.displayID(of: $0) == displayID }
    }

    private func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }

    /// The screen a rect belongs to: the one containing its centre, with a
    /// greatest-overlap tiebreak for rects that straddle an edge by a
    /// rounding error. Nil when the rect touches no screen at all.
    private func screenHosting(_ rect: NSRect) -> NSScreen? {
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(centre) }) { return hit }
        return screenWithGreatestIntersection(with: rect)
    }

    private func screenWithGreatestIntersection(with rect: NSRect) -> NSScreen? {
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let overlap = screen.frame.intersection(rect)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best
    }

    /// Which display the Dock belongs to, from its own window's bounds.
    ///
    /// Those bounds span the host display entirely, so they say nothing
    /// about where the icons are - but they are a reliable, permission-free
    /// statement of *which* display the Dock is on, and they stay correct
    /// while it's concealed, which is exactly when the tray rect can't
    /// answer that question.
    ///
    /// Filtered on pid *and* layer 20. What was actually measured is that
    /// the pid alone returned exactly one window on one machine, on one
    /// macOS version; a sibling "Wallpaper" window owned by the same
    /// process is documented historically, and a per-display one is
    /// plausible elsewhere. Matching several full-display windows on
    /// different displays with no tiebreak would silently resolve the wrong
    /// host - the exact class of bug this tracking exists to fix - so
    /// anything other than a single match declines to guess.
    private func dockWindowHostScreen() -> NSScreen? {
        guard let dockApp = dockApplication(), let mainScreen = mainDisplayScreen() else {
            return nil
        }
        guard
            let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
                as? [[String: Any]]
        else {
            return nil
        }

        let matches = windows.filter {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == dockApp.processIdentifier
                && ($0[kCGWindowLayer as String] as? Int) == 20
        }
        guard matches.count == 1,
            let boundsValue = matches[0][kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsValue)
        else {
            debugLog(
                "dockwindow",
                "expected exactly one layer-20 Dock window, got \(matches.count); "
                    + "falling back to the main display")
            return nil
        }

        // Quartz: top-left origin, anchored to the main display.
        let appKitY = mainScreen.frame.maxY - (bounds.origin.y + bounds.height)
        let frame = NSRect(
            x: bounds.origin.x, y: appKitY, width: bounds.width, height: bounds.height)
        debugLog("dockwindow", "bounds \(bounds) -> \(frame)")
        return screenWithGreatestIntersection(with: frame)
    }

    private func dockApplication() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.apple.dock"
        }
    }

    private func describe(_ displayID: CGDirectDisplayID?) -> String {
        guard let displayID else { return "none" }
        guard let screen = screen(for: displayID) else { return "\(displayID) (gone)" }
        return "\(displayID) \(screen.frame)"
    }

    /// Suppresses repeats per channel, then writes to stderr. At a 60ms
    /// cadence the unsuppressed stream is unreadable, and a single
    /// "last line emitted" doesn't work once more than one kind of line is
    /// written per evaluation: the kinds alternate, so every line differs
    /// from the one before it and nothing is ever suppressed.
    private func debugLog(_ channel: String, _ message: String) {
        guard Self.debugEnabled else { return }
        // Event channels are exempt: they fire on transitions rather than
        // per tick, so they can't flood, and suppressing them loses the
        // history entirely - "concealing with the Dock" is worded the same
        // every time, so a run with six conceals in it logged one.
        if !Self.debugEventChannels.contains(channel) {
            guard lastDebugLine[channel] != message else { return }
            lastDebugLine[channel] = message
        }
        guard let data = "[starboard.\(channel)] \(message)\n".data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

    /// "bottom", "left", or "right". Absent entirely counts as "bottom":
    /// the key is only written once the user changes it away from the
    /// default.
    private func dockOrientation() -> String {
        CFPreferencesAppSynchronize(dockPreferencesDomain)
        return
            (CFPreferencesCopyAppValue("orientation" as CFString, dockPreferencesDomain) as? String)
            ?? "bottom"
    }

    private func dockAutoHides() -> Bool {
        (CFPreferencesCopyAppValue("autohide" as CFString, dockPreferencesDomain) as? Bool) ?? false
    }

    /// Tight bounding box of the Dock's icon tray — the `AXList` child of
    /// the Dock process's accessibility tree — read via the Accessibility
    /// API. This is deliberately not the Dock's own window frame: on
    /// modern macOS that frame spans the entire screen (the Dock process
    /// also hosts desktop wallpaper/icon interaction), which is useless
    /// for positioning. Returns nil if Accessibility permission hasn't
    /// been granted yet or the Dock's AX tree can't be read, which means
    /// "don't track, fall back" to the caller.
    private func dockIconTrayFrame(flippedAgainst mainScreen: NSScreen) -> NSRect? {
        guard let dockApp = dockApplication() else { return nil }

        let axApp = AXUIElementCreateApplication(dockApp.processIdentifier)

        var childrenRef: AnyObject?
        guard
            AXUIElementCopyAttributeValue(axApp, kAXChildrenAttribute as CFString, &childrenRef)
                == .success,
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

        // AX coordinates are Quartz's top-left-origin space, anchored to
        // the main display regardless of how displays are arranged; flip
        // to AppKit's bottom-left-origin space, still relative to that
        // same origin.
        //
        // Against `mainScreen.frame.maxY`, not the host screen's own
        // height. Those two agree only when the Dock is on the main
        // display, which used to be the only case this code allowed. On a
        // display at y = -212 and 1329pt tall they differ by 111pt (the
        // 1440 - 1329 difference in heights): the correct flip puts a
        // concealed tray at maxY = -212, exactly that screen's bottom edge,
        // while flipping against the screen's own height gives -323.
        let flippedY = mainScreen.frame.maxY - position.y - size.height
        let frame = NSRect(x: position.x, y: flippedY, width: size.width, height: size.height)
        debugLog("tray", "ax position \(position) size \(size) -> \(frame)")
        return frame
    }

    private func axRole(of element: AXUIElement) -> String? {
        var roleRef: AnyObject?
        guard
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
                == .success
        else {
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
