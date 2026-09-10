import Cocoa

extension AppDelegate {
    static let fallbackWidth: CGFloat = 300
    static let fallbackHeight: CGFloat = 64
    static let expandedSizeFraction: CGFloat = 0.75
    static let dockBottomCorrection: CGFloat = 5
    static let dockTopCorrection: CGFloat = 5
    static let minPanelWidth: CGFloat = fallbackWidth
    static let maxExtraHeight: CGFloat = 400

    func resolveDockPresence() -> DockPresence? {
        guard let mainScreen = mainDisplayScreen() ?? NSScreen.screens.first else { return nil }
        let cachedHost = cachedDockHostScreenID.flatMap(screen(for:)) ?? mainScreen

        guard cachedDockOrientation == "bottom" else { return .untracked(host: cachedHost) }
        guard let tray = dockIconTrayFrame(flippedAgainst: mainScreen) else {
            return .untracked(host: cachedHost)
        }

        guard cachedDockAutoHides else {
            guard let trayHost = screenHosting(tray) else {
                return .untracked(host: cachedHost)
            }
            return .revealed(tray: tray, host: trayHost)
        }

        guard let host = screenHosting(tray) else {
            debugLog("verdict", "tray \(tray) touches no screen -> concealed")
            return .concealed(tray: tray, host: cachedHost)
        }
        let concealed = tray.maxY <= host.frame.minY + 1
        debugLog(
            "verdict",
            "tray.maxY=\(tray.maxY) vs host.frame.minY+1=\(host.frame.minY + 1) -> "
                + (concealed ? "concealed" : "revealed"))
        if concealed {
            return .concealed(tray: tray, host: host)
        }
        return .revealed(tray: tray, host: host)
    }

    func frame(for presence: DockPresence) -> NSRect {
        if isExpanded {
            let screen = expansionScreenID.flatMap(screen(for:)) ?? presence.host
            return expandedFrame(on: screen)
        }
        return collapsedGeometry(for: presence)
    }

    func collapsedGeometry(for presence: DockPresence) -> NSRect {
        switch presence {
        case .revealed(let tray, let host):
            return gluedFrame(tray: tray, on: host)
        case .concealed(let tray, let host):
            return PanelSettings.stayVisibleWhenDockHides
                ? gluedFrame(tray: restingTrayFrame(from: tray, on: host), on: host)
                : fallbackFrame(on: host)
        case .untracked(let host):
            return fallbackFrame(on: host)
        }
    }

    func gluedFrame(tray: NSRect, on host: NSScreen) -> NSRect {
        let minY = tray.minY - Self.dockBottomCorrection
        let extraHeight = min(max(PanelSettings.extraHeight, 0), Self.maxExtraHeight)
        let maxY = min(tray.maxY - Self.dockTopCorrection + extraHeight, host.visibleFrame.maxY)

        let naturalWidth = host.frame.maxX - tray.maxX
        let width = max(naturalWidth, Self.minPanelWidth)
        let x = host.frame.maxX - width
        return NSRect(x: x, y: minY, width: width, height: maxY - minY)
    }

    // Auto-hide only slides the Dock's tray vertically -- its Accessibility
    // rect keeps its real x/width even once translated off-screen (confirmed
    // by hand: a hidden tray read back as (581, -58, 518, 58), an exact
    // one-height slide below the screen edge). But the Dock doesn't rest
    // flush with the screen's bottom edge either -- a genuinely revealed
    // tray measured minY=10 on host.frame.minY=0, not 0 -- and that margin
    // isn't a known constant, so host.frame.minY alone undershoots and put
    // the panel's bottom edge below the screen. Using the last *observed*
    // revealed resting position for y (cached in `lastRevealedTray`) and
    // only the concealed tray's current x/width keeps this accurate without
    // hardcoding that margin, and self-corrects the first time the Dock is
    // next seen revealed if launched while already concealed.
    func restingTrayFrame(from tray: NSRect, on host: NSScreen) -> NSRect {
        let restY = lastRevealedTray?.minY ?? host.frame.minY
        let restHeight = lastRevealedTray?.height ?? tray.height
        return NSRect(x: tray.minX, y: restY, width: tray.width, height: restHeight)
    }

    func expandedFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let width = visible.width * Self.expandedSizeFraction
        let height = visible.height * Self.expandedSizeFraction
        let x = visible.minX + (visible.width - width) / 2
        let y = visible.minY + (visible.height - height) / 2
        return NSRect(x: x, y: y, width: width, height: height)
    }

    func fallbackFrame(on screen: NSScreen) -> NSRect {
        let reserved = screen.visibleFrame.minY - screen.frame.minY
        let collapsedHeight = reserved > 4 ? reserved : Self.fallbackHeight
        let x = screen.frame.maxX - Self.fallbackWidth
        let y = screen.frame.minY
        return NSRect(x: x, y: y, width: Self.fallbackWidth, height: collapsedHeight)
    }
}
