import Cocoa

extension AppDelegate {
    static let fallbackHintOverlap: CGFloat = 6
    static let fallbackHintNudgeMessage =
        "Not glued to Dock? Remove Starboard in System Settings → Accessibility, then re-add it."
    static let fallbackHintWelcomeMessage =
        "Starboard needs Accessibility permission to track the Dock's position and size — that's the only thing it reads. macOS will ask in a moment; grant it in System Settings → Privacy & Security → Accessibility and Starboard will snap in beside the Dock."

    func installFallbackHintIfNeeded(hasLaunchedBefore: Bool) {
        guard hintPanel == nil else { return }
        let message = hasLaunchedBefore ? Self.fallbackHintNudgeMessage : Self.fallbackHintWelcomeMessage
        let (hint, tintView, label) = FallbackHintPanel.make(
            message: message, width: Self.fallbackWidth, theme: currentTheme,
            target: self, action: #selector(dismissFallbackHint))
        hintPanel = hint
        hintTintView = tintView
        hintLabel = label
    }

    func applyThemeToFallbackHint(_ theme: Theme) {
        hintTintView?.layer?.backgroundColor = theme.panelTintColor.cgColor
        hintLabel?.textColor = theme.foregroundColor
    }

    @objc func dismissFallbackHint() {
        hintDismissed = true
        guard let hint = hintPanel else { return }
        panel.removeChildWindow(hint)
        hint.orderOut(nil)
    }

    func updateFallbackHintVisibility() {
        guard !accessibilityTrusted, !hintDismissed, let hint = hintPanel else {
            hintPanel?.orderOut(nil)
            return
        }
        guard panel.isVisible, lastPresenceUntracked, !isExpanded else {
            hint.orderOut(nil)
            return
        }
        positionFallbackHint()
        if hint.parent !== panel {
            panel.addChildWindow(hint, ordered: .below)
        }
        hint.orderFront(nil)
    }

    func positionFallbackHint() {
        guard let hint = hintPanel else { return }
        let mainFrame = panel.frame
        hint.setFrameOrigin(
            NSPoint(x: mainFrame.minX, y: mainFrame.maxY - Self.fallbackHintOverlap))
    }
}
