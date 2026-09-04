# CLAUDE.md

Guidance for Claude Code working in this repo.

## Commands

- Build: `swift build`
- Run: `.build/debug/Starboard`, backgrounded (`swift run` blocks the
  terminal on stdout/stderr)
- No tests, linters, or CI beyond `.github/workflows/build.yml`.

## Code style

Zero comments in `Sources/Starboard/`, by design — this file is the only
place rationale lives. If you add non-obvious logic, document the *why*
here, not inline.

## Architecture

Plain SPM executable, no Xcode project, no Info.plist — `main.swift` sets
`.accessory` activation policy directly instead. `AppDelegate`'s behavior
is split across `AppDelegate+*.swift` extensions by concern (the invisible
main menu bar, the clickable popup panel menu, Dock-tracking state
machine, Dock-relative geometry, screen resolution, Dock Accessibility
reads, debug logging, theme switching, panel appearance settings, the
Accessibility fallback hint); `DockPresence`, `PanelBuilder`,
`TerminalTheme`, `PanelSettings`, `Theme`, `ThemePickerView`,
`SettingsPanelView`, `TerminalLayout`, `ShellEnvironment`,
`FallbackHintPanel`, and `Mascot` are standalone. Read the code for how it
works — it's small and the names are literal.

Panel corner radius, background tint opacity, and terminal font are all
user-adjustable at runtime via the "Settings…" panel menu item
(`SettingsPanelView`/`AppDelegate+Settings.swift`), persisted in
`UserDefaults` through `PanelSettings`. Corner radius always has a
concrete value (defaults to `TerminalTheme.defaultCornerRadius` until
overridden); tint opacity is `nil` until the user touches the slider, so
switching themes still shows each theme's own baked-in alpha rather than
silently forcing one opacity on every theme; font name likewise falls
back to `TerminalTheme.defaultFontName` (the first installed preferred
Nerd Font, else the system monospace font) until overridden. The font
picker enumerates installed fonts, keeps those marked monospaced by
AppKit, and presents one regular-preferred face per family while storing
its PostScript name. Panel width was deliberately left out of this — the whole
product idea is gluing to the Dock's tray width, so that one stays a
hardcoded constant in `TerminalLayout`.

`Mascot.swift` is a SwiftUI rewrite of the fallback hint's mascot — same
16×13 grid, same walk/blink/wandering-gaze animation as before, but
`Canvas` + `TimelineView` instead of the old `NSView` + `Timer` +
`needsDisplay`, because the AppKit version never actually animated once
embedded in a real panel (see the gotcha below). `FallbackHintPanel`
hosts it via `NSHostingView`. There's a sibling `mascots` repo
(`../mascots`) that documents this same character — including Port's and
agent-patterns' own variants — as a reference, but Starboard does *not*
depend on it: a `../mascots` path dependency in `Package.swift` broke
`swift build` in `.github/workflows/build.yml`, which only checks out
this repo, not a sibling. `Mascot.swift` here is a deliberate,
self-contained copy, not a package import — keep it that way.

## Non-obvious gotchas (not discoverable by reading the code)

- **Dock geometry** comes from the Dock process's Accessibility tree
  (`AXList`), not `CGWindowListCopyWindowInfo` — that window spans the
  whole screen. Requires Accessibility permission; falls back to a fixed
  corner without it. `STARBOARD_DEBUG=1` enables stderr geometry logging.
- **A `launchd`-spawned process doesn't inherit Accessibility trust** the
  way a Terminal- or Login-Items-launched one does, and ad-hoc signing
  pins that trust to the binary's content hash, which changes every
  rebuild. `scripts/install.sh` works around this with a locally
  generated, self-signed certificate so the signing identity — and the
  grant — survives rebuilds. A downloaded release added to Login Items
  doesn't need any of this.
- **Updating an installed build in place** (manual overwrite or `brew
  upgrade`) leaves a stale Accessibility grant that looks enabled in
  System Settings but silently doesn't work. Fix: remove the row and
  re-grant, or `tccutil reset Accessibility com.starboard.app`.
  `scripts/test-release.sh` does this automatically before each local
  test cycle — always test releases through it, not a raw rebuild.
- **SwiftTerm's default child environment omits `SHELL`**, which breaks
  tools that branch on it (e.g. ngrok's zsh completion emitting bash
  syntax). `ShellEnvironment` sets it explicitly — don't pass `nil` for
  `startProcess`'s `environment`.
- **`accessibilityTrusted` is re-checked once per second in
  `refreshCoarseCaches`, not just at launch** — `AXIsProcessTrusted()` was
  originally only called in `applicationDidFinishLaunching`, so revoking
  the grant while Starboard was already running (as opposed to before
  launching it) never got noticed: the fallback hint panel is only ever
  *created* inside the `!accessibilityTrusted` branch, so a session that
  launched trusted would never allocate it no matter what happened to the
  grant afterward. `refreshCoarseCaches` runs on the same ~1s cadence as
  the rest of the coarse Dock-state refresh regardless of auto-hide, so
  piggybacking the trust check there catches both directions (revoke
  mid-session now surfaces the hint; grant mid-session now dismisses it)
  without adding a second timer.
- The Homebrew tap (`Casks/starboard.rb`) is self-hosted, not submitted to
  `homebrew/cask`, because that tap requires notarization and Starboard is
  ad-hoc signed only. `.github/workflows/release.yml` updates the cask's
  version/sha256 automatically on every tag push.
- **Starboard's own menu bar (`NSApp.mainMenu`) never actually appears** —
  `.accessory` apps only get their menu bar shown while active, and the
  panel is a `.nonactivatingPanel` that never makes the app active. A
  visible clickable "Theme" submenu *in that menu bar* was tried and was
  permanently unreachable by mouse. Its key equivalents (Cmd+E, Cmd+T,
  Cmd+Q) still work regardless, because `NSApplication` matches them
  against the responder chain independent of menu-bar visibility. This is
  specific to the installed main menu bar, though — an ad-hoc `NSMenu`
  shown via `.popUp(positioning:at:in:)` from a button click (what
  `AppDelegate+PanelMenu.swift` does) is a completely different code path
  and works fine by mouse, same as any status-item dropdown.
- **The theme picker is its own floating panel, not a subview of the main
  one.** The main panel is only as tall as the Dock's icon tray when
  collapsed (often well under 100pt), and a subview can never draw
  outside its own window's frame — no clipping-mask trick fixes that.
  The picker anchors to the main panel's bottom edge and grows upward
  in screen coordinates instead.
- **The old hand-drawn mascot (AppKit `NSView` + `Timer` +
  `needsDisplay`) never visibly animated once embedded in a real child
  `NSPanel`, even after fixing its `Timer` to run in `.common` run-loop
  mode** (the same fix `AppDelegate+Tracking.swift`'s `trackingTimer`
  needed) — root cause was never found, and the mascot shipped as a still
  image instead. Resolved by *not* fighting AppKit's `needsDisplay`/`Timer`
  path at all: `Mascot.swift` is SwiftUI, driven by
  `TimelineView(.periodic(...))` inside a `Canvas`, hosted via
  `NSHostingView`. Confirmed animating correctly in this exact panel
  recipe (borderless `.nonactivatingPanel` at `kCGDockWindowLevel+1`) by
  screen-diffing two captures of a throwaway panel a fraction of a second
  apart. If a future mascot host in this repo still doesn't animate,
  suspect the host's plumbing before suspecting this pattern — it's known
  to work here.

## Known open items

- Pasted text briefly renders in the wrong foreground color until the
  next keypress (SwiftTerm's own paste path; not investigated further).
- A handful of narrow, deliberately-deferred edge cases in the
  auto-hide-Dock coupling — see PR #7 discussion before touching that
  area.
