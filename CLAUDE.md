# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- Build: `swift build`
- Run: `.build/debug/Starboard` (or `swift run`, but `swift run` attaches the
  process's stdout/stderr to the terminal and blocks it — running the built
  binary directly and backgrounding it is usually more convenient for a
  persistent GUI app)
- There are no tests, linters, or CI configured.

## Architecture

Plain Swift Package Manager executable target (`Starboard`), no Xcode
project, no Info.plist. Three files in `Sources/Starboard/`:

- `main.swift` — entry point. Creates `NSApplication.shared`, sets the
  delegate, and calls `app.setActivationPolicy(.accessory)` *before*
  `app.run()`. This is what gives the app no Dock icon and no Cmd+Tab entry
  — there is no Info.plist / `LSUIElement` involved, since SPM executables
  don't bundle one.
- `KeyablePanel.swift` — an `NSPanel` subclass that overrides
  `canBecomeKey` to return `true`. Needed because a borderless panel with
  `.nonactivatingPanel` style won't accept keystrokes otherwise, and
  `.nonactivatingPanel` is what lets the terminal view become key *without*
  activating the app or stealing focus from whatever app the user is
  currently in.
- `AppDelegate.swift` — everything else: builds the panel, tracks the Dock
  to size/position it, and wires up the terminal.
  - The panel's `collectionBehavior` includes `.canJoinAllSpaces` and
    `.fullScreenAuxiliary` so it stays visible across every Space, including
    over full-screen apps. `effectView.layer?.masksToBounds = true` clips
    the (edge-to-edge) terminal view to the panel's rounded corners —
    without it, square corners get painted over the rounded blur.
  - The terminal itself is a [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
    `LocalProcessTerminalView`, started once via
    `startProcess(executable: "/bin/zsh", args: ["-l"], ...)`. This is a
    real PTY-backed shell process, not a `Process` spawned per command —
    that's what makes `cd`, shell history, and arrow-key line editing work
    across commands instead of resetting each time. The `environment` it's
    given is explicit, not SwiftTerm's default — see "The child shell's
    environment" below.
  - `nativeBackgroundColor`/`layer?.backgroundColor` are set to `.clear` on
    the terminal view so the panel's blur shows through behind the text;
    SwiftTerm's Metal renderer is off by default (`useMetalRenderer` starts
    `false`), which is what makes the transparent layer approach work — if
    that ever gets toggled on, the transparency handling would need
    revisiting.
  - `setUpMainMenu()` builds a minimal `NSMenu` (Quit + Edit: Copy/Paste/
    Select All) and sets it as `NSApp.mainMenu`. This menu is never
    visibly shown — the nonactivating panel never makes Starboard the
    frontmost app — but Cmd+C/Cmd+V/Cmd+A only resolve to a view's
    `copy(_:)`/`paste(_:)`/`selectAll(_:)` via AppKit's menu-key-equivalent
    system, so without *some* main menu those keystrokes go nowhere,
    silently, regardless of whether it's ever drawn on screen.

### Dock tracking

The panel positions itself as a companion to the Dock — same height, left
edge touching the Dock's right edge, same bottom margin as the Dock (so
they share a baseline), and its own right edge flush against the screen's
right edge, no margin there at all. A repeating `Timer`
(`dockTrackingInterval`, 1s) recomputes this and
calls `panel.setFrame` whenever it changes, so it follows the Dock live as
it's resized or gains/loses icons — there's no notification to observe for
this, so it's polled.

The Dock's geometry comes from `dockIconTrayFrame()`, which reads the
`AXList` element (the icon row) from the Dock process's accessibility tree
via `AXUIElementCreateApplication` / `AXUIElementCopyAttributeValue`. This
is deliberately **not** `CGWindowListCopyWindowInfo`: on modern macOS the
Dock's own window frame spans the entire screen (the Dock process also
hosts desktop wallpaper/icon interaction — see the sibling "Wallpaper"
window owned by the same process), which is useless for positioning. The
`AXList` box is close but not exact: its bottom edge sits above the Dock's
real bottom margin, and its top edge overshoots above the Dock's real top
edge by a smaller amount — Apple doesn't expose the actual painted chrome
rectangle through Accessibility at all. `dockBottomCorrection` (5pt) and
`dockTopCorrection` (5pt) are empirical fixes for that gap, tuned pixel by
pixel against one real Dock; nudge them if the panel's edges visibly drift
from the Dock's, e.g. at a very different tile size.

Reading another process's accessibility tree requires the user to grant
Starboard Accessibility permission (`AXIsProcessTrustedWithOptions` is
called with the prompt option at launch to trigger the system dialog).
Until granted — or if the Dock's AX tree is ever unreadable —
`fallbackFrame(on:)` is used instead: a fixed-width panel in the
bottom-right corner, with height read from the gap between
`NSScreen.main.frame` and `.visibleFrame` (which doesn't need any special
permission, but also can't reveal the Dock's *width*).

No App Sandbox entitlements are set (SPM executables are unsandboxed by
default), which is required for spawning a shell process at all.

### Why `scripts/install.sh` packages a `.app` bundle

Confirmed by direct debugging (temporary `FileHandle.standardError` calls
around `AXIsProcessTrusted()` and the `AXError` from
`AXUIElementCopyAttributeValue`, logged via the LaunchAgent's
`StandardErrorPath`): a process launched by `launchctl` gets
`AXIsProcessTrusted() == false` and `AXError -25211` (`kAXErrorAPIDisabled`)
even when Accessibility looks granted in System Settings — while the exact
same binary launched directly from a Terminal/Bash shell reports
`trusted == true`. The difference is TCC's "responsible process"
attribution: a process launched interactively from Terminal can inherit
Terminal's own Accessibility trust, but a `launchd`-spawned process has no
such parent to inherit from and needs its own standalone grant. That grant
didn't reliably stick for the raw, unbundled executable — its ad-hoc code
signature (assigned automatically by the toolchain) is content-derived and
changes on every rebuild, giving TCC nothing stable to track.

First attempt at a fix: `install.sh` copies the built binary into a
minimal `Starboard.app` (`Contents/Info.plist` + `Contents/MacOS/Starboard`)
and ad-hoc signs it with an explicit, fixed `--identifier`. This did *not*
fully work — confirmed by rebuilding, reinstalling, and rechecking the
debug log, which still showed `trusted=false` after a rebuild. Even with a
fixed identifier, ad-hoc signing (`codesign --sign -`) has no real signing
authority behind it, so the code requirement macOS ends up checking still
effectively pins to the binary's content, which changes every rebuild.

The actual fix: `install.sh` creates (on first run) a local, self-signed
code-signing certificate (`Starboard Local Signing`, in the login keychain,
trusted for the `codeSign` policy via `security add-trusted-cert`), then
signs the bundle with `codesign --sign "Starboard Local Signing"
--identifier com.starboard.app`. Verified via `codesign -d -r-` that the
resulting designated requirement is
`identifier "com.starboard.app" and certificate leaf = H"<hash>"` — no
binary-content hash in it at all, just the identifier and a hash of the
*certificate*, which stays constant across rebuilds as long as the same
certificate keeps signing it. Confirmed working end-to-end: granted once,
then rebuilt (binary content changed) and reinstalled without any
re-prompt, geometry stayed live-tracked throughout.

Two gotchas hit along the way, both now handled in the script:
- `openssl pkcs12 -export` defaults (OpenSSL 3.x) to AES/SHA-256
  encryption, which macOS's Security framework can't parse
  (`SecKeychainItemImport: MAC verification failed`) — needs the
  `-legacy` flag to fall back to the older RC2/3DES format macOS expects.
- Iterating on the fix (unbundled → ad-hoc bundle → cert-signed bundle,
  all at the same `.build/release/Starboard.app` path) left multiple
  stale "Starboard" entries in System Settings → Accessibility. Only one
  corresponds to the current signing identity; the others do nothing and
  are just clutter — if Accessibility looks granted but the panel still
  won't track the Dock, that's the first thing to check.

`install.sh`'s certificate step is idempotent (`security find-certificate`
checked before creating one), so re-running it doesn't create duplicate
certificates — confirmed via `security find-certificate -a` after a
rebuild, still exactly one match. A macOS login-password prompt (for the
trust-setting change) has recurred on rebuilds that changed the binary,
despite the certificate itself not being recreated — root cause not
pinned down (tried: it's not an auto-lock timeout, per
`security show-keychain-info`). Treated as acceptable rather than a bug
to keep chasing: it reads as a normal "confirm this updated app" prompt
tied to actual code changes, not something that fires on every
`install.sh` run regardless of whether anything changed. The
LaunchAgent's `ProgramArguments` points at
`Starboard.app/Contents/MacOS/Starboard`, not the bare
`.build/release/Starboard`. Running the raw executable directly
(`swift run`, or the debug build) still works for local iteration since it
inherits trust from its Terminal parent — it's specifically the
persistent, `launchd`-launched instance that needs the signed bundle.

### Terminal styling and layout

As of v0.5.3, the panel's color is Starboard's own — a fixed, near-black
`panelTintColor` layered as a plain `NSView` between the `NSVisualEffectView`
blur and the terminal content, not a match for the Dock's own chrome. Dock
tracking (`syncFrameToDock`/`dockIconTrayFrame`) still governs the panel's
*height and position* only. Color was deliberately decoupled: the Dock's
translucency is a private, OS-version-tuned WindowServer recipe (not a
public `NSVisualEffectView.Material`), and both it and Starboard's previous
`.menu` material use `blendingMode = .behindWindow` — i.e. both react live
to whatever's on the desktop — but with different light/dark response
curves, so they visibly drifted apart as wallpaper brightness changed
(confirmed by the user switching from a dark to a bright wallpaper: the
Dock got lighter, Starboard didn't, at a similar rate). Rather than chase
a moving, private target that would also vary across macOS releases,
Starboard now keeps a constant look independent of desktop content —
tune `panelTintColor`'s RGB/alpha directly rather than trying to sample
or approximate the Dock's material.

As of v0.5.4, the 16 ANSI colors are also Starboard's own
(`starboardAnsiPalette`, installed via `terminal.installColors(_:)` —
SwiftTerm's public wrapper around `Terminal.installPalette`, which needs
exactly 16 `Color` entries) — muted ocean blues/teals instead of harsh
primaries, with red/green nodding to a ship's port/starboard navigation
lights. `Color`'s public initializer takes 16-bit (0...65535) components,
not the usual 8-bit hex form, hence the small `ansiColor(_:_:_:)` helper
that scales 8-bit input up (`* 257`, since `255 * 257 == 65535` exactly).
Important distinction for future theming work: this only changes what an
ANSI color code *renders as* in the emulator — it has no effect on *which*
color a shell prompt theme picks for a given segment (e.g. oh-my-zsh's
`robbyrussell` always uses green for its arrow, red for a dirty git
status, etc.); that logic lives entirely in the user's own shell config
and runs identically in any terminal emulator.

The terminal uses Menlo, not `NSFont.monospacedSystemFont` (SF Mono) —
verified programmatically (`CTFontGetGlyphsForCharacters`) that SF Mono is
missing glyphs common shell prompt themes use, e.g. `➤` (U+27A4), which
Menlo has. `terminalFont` is computed once in `AppDelegate.init()` rather
than per-launch, since it's reused by both the initial layout and every
subsequent resize.

### The child shell's environment

`startProcess` is passed an explicit `environment` from
`childEnvironment()` rather than `nil`. Passing `nil` makes SwiftTerm fall
back to `Terminal.getEnvironmentVariables()`, which is a deliberately
minimal allowlist — `TERM`, a hardcoded UTF-8 `LANG`, and a handful of
user identity variables — and notably has no `SHELL`. In a normal terminal
`login(1)` sets that; nothing in this path does, so the child `zsh -l`
starts with `SHELL` unset.

That surfaced as a genuinely confusing bug. Tools that read `$SHELL` to
detect which shell they're being sourced into guess wrong and emit bash
for a zsh session — `ngrok completion`, called from a user's `.zshrc`,
emits a bash completion script ending in
`[[ $(type -t compopt) = "builtin" ]]`, and `type -t` is not valid zsh, so
every launch printed `(eval):type:11434: bad option: -t`. Powerlevel10k's
instant prompt then flagged the stray output as a `.zshrc` configuration
problem, pointing the user at their own config rather than at the
terminal. Worth remembering when triaging anything similar: the minimal
environment means Starboard is not interchangeable with Terminal.app from
a shell-config perspective, and differences show up far downstream.

`SHELL` is appended only if absent rather than assigned unconditionally,
so a future SwiftTerm that provides it wins over our value. It's derived
from `shellExecutable`, the same constant `startProcess` launches, so the
two can't drift.

`terminalContentFrame(in:)` insets by `terminalPadding` (8pt) and then
vertically centers the content within that padding. This exists because
SwiftTerm derives its row count as `Int(height / cellHeight)` — a floor
operation — which almost never divides the available height evenly; a
plain edge inset leaves the leftover slack stuck at the bottom, reading as
content pinned to the top. `estimatedCellHeight(for:)` mirrors SwiftTerm's
own internal calculation (`AppleTerminalView.computeFontDimensions`:
ascent + descent + leading at 1.0 line spacing) so the padding can predict
the row count before SwiftTerm lays out. `terminalFontSize` (11pt) and
`terminalPadding` (8pt) are chosen together so a ~57-60pt Dock height
lands on exactly two visible rows.

Because centering depends on the panel's live height, the terminal's
`autoresizingMask` is `[.width]` only — height is NOT auto-flexible.
`syncFrameToDock()` explicitly recomputes `terminalView.frame` via
`terminalContentFrame(in:)` every time it resizes the panel, rather than
letting AppKit's autoresizing stretch the terminal to fill the new size
(which would rewiden the padding asymmetrically as the panel resizes).

### Expand/collapse

Cmd+E toggles `isExpanded`, growing the panel upward to (almost) full
screen height for when Dock-height (two rows) isn't enough — e.g. running
something like Claude Code in there instead of a couple of shell lines.
Wired through the same hidden `NSMenu` key-equivalent mechanism as
Copy/Paste/Select All (`setUpMainMenu`) — no visible menu, no button, just
a key equivalent that resolves via AppKit's menu system regardless of the
menu never being drawn.

Growth is upward only: `currentFrame()`'s `x`, width, and bottom `y` stay
exactly as they are for the collapsed case — still live-tracking the
Dock — and only the top edge moves, from the Dock's own height up to
`screen.visibleFrame.maxY`. Deliberately `visibleFrame.maxY`, not
`frame.maxY`: the menu bar sits at a higher `NSWindowLevel` than this
panel's `.floating`, so a frame flush with the physical screen top doesn't
get *clipped* there, it gets *drawn over* — confirmed by testing, with
`frame.maxY` the top ~1 row of terminal content and the rounded top
corners were hidden behind the menu bar, not cut off by frame math.
`visibleFrame.maxY` already excludes the menu bar's reserved strip
(notch height included) as a matter of what `NSScreen` reports directly —
no empirical correction constant needed here, unlike
`dockTopCorrection`/`dockBottomCorrection`, which exist only because
Accessibility has no equivalent direct answer for the Dock's painted
chrome.

`syncFrameToDock()`'s 1s timer isn't paused while expanded — it keeps
calling `currentFrame()` every tick regardless, and `currentFrame()`
itself branches on `isExpanded`, so the panel keeps following the Dock's
live x-position/baseline even at full height; only which edge is
Dock-relative (bottom, collapsed) vs. screen-relative (top, expanded)
changes. Toggling calls `syncFrameToDock()` immediately rather than
waiting for the next tick.

### Known issue: pasted text briefly renders in wrong foreground color

Pasted text renders in black instead of the correct theme foreground color
until the next keypress forces a full redraw. Not Starboard's rendering —
`paste(_:)` is SwiftTerm's own (`MacTerminalView.paste`), reached via the
main menu's key equivalent since there's no other paste path (no visible
menu bar, no right-click context menu). Tried and ruled out: routing the
menu's Paste action through a wrapper that calls `terminalView.paste(_:)`
then forces `needsDisplay = true` ~50ms later — didn't help, so the wrong
color is already baked in by the time the pasted text is echoed back and
drawn, not something a post-hoc invalidate can fix. Not yet investigated
further; low priority.

### Watch item: prompt glyphs previously rendered as `?` (status: not recurring, cause unconfirmed)

Some prompt-theme glyphs (oh-my-zsh's `robbyrussell` theme — `➜` U+27A4
and `✗` U+2717) used to intermittently render as `?` during live prompt
redraws (ZLE erasing/repainting an existing prompt line, e.g. after a
`cd` changes the git-status segment). Starboard-side causes were ruled
out by direct testing (font coverage, locale, raw glyph/ANSI rendering,
line wrapping, character-width tables) — see
[SwiftTerm#231](https://github.com/migueldeicaza/SwiftTerm/issues/231)
for the likely upstream cause (SwiftTerm's CoreText glyph-positioning).

Hasn't recurred as of 2026-08-05, cause of the change unknown (possibly
just a Mac restart) — not confirmed fixed. If it comes back, the ruled-out
list above doesn't need re-checking.
