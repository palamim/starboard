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
    `startProcess(executable: Self.shellExecutable, args: ["-l"], environment:
    Self.childEnvironment(), ...)`. This is a real PTY-backed shell process,
    not a `Process` spawned per command — that's what makes `cd`, shell
    history, and arrow-key line editing work across commands instead of
    resetting each time. The `environment` is explicit, not SwiftTerm's
    default — see "The child shell's environment" below.
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
`screen.frame` and `.visibleFrame` (which doesn't need any special
permission, but also can't reveal the Dock's *width*). Its bottom edge
sits flush with `screen.frame.minY`, no added margin — deliberately
matching the glued baseline (`dock.minY`, a hair above that same edge)
rather than floating an arbitrary margin above it, which read as visibly
too high before this was tightened.

`dockIconTrayFrame(mainScreen:)` returns nil — same fallback path — for
two configurations it deliberately doesn't attempt to track, rather than
tracking them partially or incorrectly:
- **Left/right Dock** (`dockOrientation()`, reading the `orientation` key
  from the `com.apple.dock` preferences domain directly — no
  Accessibility needed for this part). A non-bottom Dock would need the
  panel hugging a different axis entirely, not a tweak to this logic.
- **Auto-hide Dock** (`dockAutoHides()`, same domain, `autohide` key).
  There's no live "Dock is currently shown/hidden" signal to poll
  cheaply, and gluing to where a hidden Dock *would* be defeats the
  point of an auto-hidden Dock.

A Dock on a **secondary display** is supported. AX/Quartz coordinates
are always anchored to the main display's top-left (`CGMainDisplayID()`,
not focus-tracking `NSScreen.main`), so the Y-flip uses
`mainScreen.frame.maxY`, producing a global AppKit rect that may sit on
any attached screen — including ones with negative origins.
`screenHosting(_:)` then picks the `NSScreen` containing that tray's
center, and `currentFrame()` sizes the panel against *that* screen. The
panel follows the Dock when it moves between displays; it does *not*
follow keyboard focus. Fallback (when AX/orientation/autohide block
tracking) still anchors to the main display so the panel doesn't jump
with focus.

Because `currentFrame()` calls `dockIconTrayFrame(mainScreen:)` fresh on
every tick of the existing 1s polling `Timer`, left/right Dock,
auto-hide, display connect/disconnect, and Dock moves between screens
all get picked up on the next tick automatically, in either direction,
the same way a resized Dock already does.

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
- If you have both a build-from-source copy (installed via
  `scripts/install.sh`) and a downloaded release installed, expect two
  "Starboard" entries in the Accessibility list, since each is signed
  differently. If the one you just enabled doesn't seem to take, remove
  the other entry (select it, click **−**) and re-enable the remaining
  one.

### Login Items are a simpler path for downloaded builds

The certificate dance above exists specifically for a `launchd`
LaunchAgent, i.e. `scripts/install.sh`'s install path — it's not needed
for a downloaded release `.app` that a user adds to Login Items
(System Settings → General → Login Items & Extensions → +) instead.
Confirmed end-to-end after a full restart: the ad-hoc-signed downloaded
build, added to Login Items and nothing else, came up already glued to
the Dock — fast, and with no Accessibility re-prompt. Plausible
explanation, not independently verified: Login Items are launched via
loginwindow, which (like a Terminal-launched process, and unlike a bare
`launchd` LaunchAgent) has a "responsible process" TCC can attribute
trust through, so the same content-hash-pinned ad-hoc signature that
fails for a raw LaunchAgent works fine here. Practical takeaway: a
downloaded build doesn't need `install.sh`'s LaunchAgent/certificate
machinery at all — Login Items alone is enough, and is what the README
now recommends for that path. `install.sh` remains the right tool for
the build-from-source loop, where the binary (and its ad-hoc signature)
changes on every rebuild and Login Items won't re-resolve that on its
own the way the certificate-based signature does.

### Updating a downloaded build in place leaves a stale, silently-broken Accessibility grant

Confirmed by hand (using `scripts/test-release.sh` to simulate a real
update — rebuild, then overwrite `/Applications/Starboard.app` with the
new binary at the same path): the previous version's Accessibility grant
does not carry over, but it also doesn't cleanly disappear or prompt
fresh either. System Settings keeps showing the same "Starboard" row,
still checked on, and re-launching Starboard still triggers the "would
like to control this computer" system alert (i.e. `AXIsProcessTrusted`
correctly reports false) — but toggling that existing checkbox off and
back on does **not** fix it; the panel stays pinned to the fallback
corner. Only removing the row entirely (System Settings' **−** button,
or `tccutil reset Accessibility com.starboard.app` from a terminal) and
letting a fresh one get created — either by re-enabling from the prompt
or adding the app back — actually restores tracking. Root cause: the
same one behind the `install.sh` gotchas above — ad-hoc signing pins the
grant to the binary's content hash, not the bundle path/identifier, so
the stored row's requirement silently no longer matches the new binary
at that path. A checkbox toggle just flips the existing (mismatched)
row; it doesn't regenerate the requirement, only deleting-and-recreating
the row does.

Two places this is handled:
- `scripts/test-release.sh` runs `tccutil reset Accessibility
  com.starboard.app` before reopening the freshly built app, so every
  local test cycle gets a real, working prompt instead of a silently
  stale one. Scoped to Starboard's own bundle ID only — doesn't touch
  any other app's grants.
- `AppDelegate.swift` captures `AXIsProcessTrustedWithOptions`'s return
  value (previously discarded) and, when false, feeds a short explainer
  directly into the terminal view via SwiftTerm's `feed(text:)` — before
  `startProcess` starts the shell, so it can't be mistaken for shell
  output or land in history. This is the only way to guarantee the fix
  reaches a real downloaded-release user hitting this after an update,
  independent of whether they read the README: Starboard has no menu
  bar, no Dock icon, and no other visible UI to put a hint in, but
  everyone who hits this *will* be looking at the terminal, wondering
  why it's not glued to the Dock. First attempt was a three-line
  explainer; cut to one short line after testing it for real — this
  panel only ever shows ~2 rows, so anything longer scrolls out of view
  almost as soon as the shell starts producing its own output, and
  needs scrolling back up to even find. Same reasoning kept the Cmd+E/
  Cmd+Q hint (`terminal.toolTip`, set right below where colors are
  installed) out of the terminal entirely — a hover tooltip costs
  nothing until it's actually useful, instead of permanently competing
  for space in an already-tiny panel.

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

### Terminal styling and layout (themes)

Panel tint, border, foreground, ANSI palette, and font live in
`Theme.swift` / `ThemeStore.swift`, not as loose constants in
`AppDelegate`. Built-ins: `ocean` (default — muted ocean blues/teals,
port/starboard red/green), `dark`, `light`, and `system` (resolves to
Ocean or Light from `NSApp.effectiveAppearance`). `ThemeStore` reads
`~/Library/Application Support/Starboard/config.json`; optional keys
(`fontName`, `fontSize`, `panelTint`, `foreground`, `borderColor`,
`ansi`) override the built-in. Cmd+T cycles built-ins and saves; Cmd+,
opens the config (creating a starter file if needed). The Dock-tracking
1s timer also reloads the file and re-resolves `system` on appearance
flips.

Color stays deliberately decoupled from the Dock's material: the Dock's
translucency is a private WindowServer recipe, and chasing it drifted
apart from wallpaper/macOS changes. Themes own a constant tint layered
between the `NSVisualEffectView` blur and the terminal. Dock tracking
still governs height and position only.

ANSI colors are installed via `terminal.installColors(_:)` (SwiftTerm's
wrapper around `Terminal.installPalette`, exactly 16 `Color` entries).
`Theme.ansiColor` scales 8-bit RGB to `Color`'s 16-bit components
(`* 257`). This only changes what an ANSI index *renders as*; shell
prompt themes still pick which index to use.

The terminal resolves its font from the theme's `fontName` when set,
otherwise `Theme.preferredFontNames`: patched Nerd Font variants first,
then Menlo, with `NSFont.monospacedSystemFont` (SF Mono) as last resort.
SF Mono is deliberately last — verified programmatically
(`CTFontGetGlyphsForCharacters`) that it's missing glyphs common shell
prompt themes use, e.g. `➤` (U+27A4), which Menlo has.

Menlo alone isn't enough for the popular prompt themes, though. Anything
Nerd Font-based — Powerlevel10k in either `nerdfont-complete` or
`nerdfont-v3` mode, Starship's presets, oh-my-posh — draws its segment
separators and icons from the Nerd Font private-use ranges (`` U+E0B0,
`` U+F179 and neighbors). No font shipped with macOS carries those, so
every one of them renders as Last Resort's box-with-question-mark. A user
with such a prompt sees it intact in their other terminal and mangled in
Starboard, which reads as a Starboard rendering bug rather than a missing
font. Hence the preference list: it costs nothing when no Nerd Font is
installed (it falls through to Menlo, the previous behavior) and fixes the
prompt outright when one is.

Note that `NSFont(name:)` returns nil for a name that isn't installed, so
a typo in that list fails silently rather than at build time — if the
prompt looks wrong, check which entry actually resolved.

`terminalFont` is a `var` updated by `apply(_ theme:)`, so font-size
changes from config or Cmd+T recompute `terminalContentFrame`. Placeholder
font in `init()` is replaced once views exist.

Changing the font family or size changes the row count.
`terminalContentFrame` derives rows as `floor(usableHeight / cellHeight)`
from `estimatedCellHeight`, and Nerd Font patching raises a font's
vertical metrics — enough that a Dock-height panel tuned to two rows with
Menlo can land on one. Default theme size is 11pt with `terminalPadding`
8pt; drop either if that happens.

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
