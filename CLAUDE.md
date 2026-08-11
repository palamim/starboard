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
(`dockTrackingInterval`, 1s) drives `tick()`
(`refreshCoarseCaches()` then `runEvaluation()`), which recomputes this
and calls `panel.setFrame` whenever it changes, so it follows the Dock
live as it's resized or gains/loses icons — there's no notification to
observe for that, so it's polled. (Display connect/disconnect *does* have
a notification — see "Reacting to display changes immediately" below.)

The Dock's geometry comes from `dockIconTrayFrame(flippedAgainst:)`, which
reads the `AXList` element (the icon row) from the Dock process's
accessibility tree via `AXUIElementCreateApplication` /
`AXUIElementCopyAttributeValue`. This is deliberately **not**
`CGWindowListCopyWindowInfo`: on modern macOS the Dock's own window frame
spans the entire screen (the Dock process also hosts desktop
wallpaper/icon interaction — see the sibling "Wallpaper" window owned by
the same process), which is useless for positioning. The `AXList` box is
close but not exact: its bottom edge sits above the Dock's real bottom
margin, and its top edge overshoots above the Dock's real top edge by a
smaller amount — Apple doesn't expose the actual painted chrome rectangle
through Accessibility at all. `dockBottomCorrection` (5pt) and
`dockTopCorrection` (5pt) are empirical fixes for that gap, tuned pixel by
pixel against one real Dock; nudge them if the panel's edges visibly drift
from the Dock's, e.g. at a very different tile size or a different
display.

Reading another process's accessibility tree requires the user to grant
Starboard Accessibility permission (`AXIsProcessTrustedWithOptions` is
called with the prompt option at launch to trigger the system dialog).
Until granted — or if the Dock's AX tree is ever unreadable —
`fallbackFrame(on:)` is used instead: a fixed-width panel in the
bottom-right corner of the Dock's *host* screen (see below — not
necessarily the main display), with height read from the gap between that
screen's `frame` and `.visibleFrame` (which doesn't need any special
permission, but also can't reveal the Dock's *width*). Its bottom edge
sits flush with that screen's bottom edge, no added margin — deliberately
matching the glued baseline (the tray-derived `minY` in `gluedFrame`, a
hair above that same edge) rather than floating an arbitrary margin above
it, which read as visibly too high before this was tightened.

`dockIconTrayFrame` also returns nil — same fallback path — for two
configurations it deliberately doesn't attempt to track, rather than
tracking them partially or incorrectly:
- **Left/right Dock** (`dockOrientation()`, reading the `orientation` key
  from the `com.apple.dock` preferences domain directly — no
  Accessibility needed for this part). A non-bottom Dock would need the
  panel hugging a different axis entirely, not a tweak to this logic.
- **Auto-hide Dock** (`dockAutoHides()`, same domain, `autohide` key).
  There's no live "Dock is currently shown/hidden" signal to poll
  cheaply, and gluing to where a hidden Dock *would* be defeats the
  point of an auto-hidden Dock. (Its *host display* is still tracked,
  though — only the glued geometry falls back. Coupling the panel to the
  Dock's own conceal/reveal cycle is tracked as a follow-up, not done
  here.)

#### Following the Dock across displays

Through v0.8.4, tracking only ever worked for a Dock on the main display
(`CGMainDisplayID()`) — a Dock on any other screen fell back to the fixed
corner, on whichever screen happened to be main, same as the two
configurations above. The panel now follows the Dock's actual host
screen instead.

Two ways `refreshCoarseCaches()` finds that host, tried in order, once a
second like everything else here:
1. **`screenReservingBottomStrip()`** — for a fixed (non-auto-hide) Dock,
   macOS reserves a strip at the bottom of exactly one screen's
   `visibleFrame`, and that's the Dock's screen. Free: no cross-process
   call at all, just comparing `NSScreen.screens`' own geometry, so it's
   what the common case costs.
2. **`dockWindowHostScreen()`** — used when nothing reserves a strip
   (mid-transition) or the Dock is set to auto-hide, where nothing ever
   reserves one. Scans every window (`CGWindowListCopyWindowInfo`) for
   ones owned by the Dock's process at window layer 20, and reads that
   window's bounds — which span its *entire* host screen, so they say
   nothing about icon positions, but they're a reliable, permission-free
   statement of *which* screen the Dock is on, and stay correct even
   while the Dock is concealed (exactly when the tray rect can't answer
   that question at all). Filtered on pid *and* layer 20 rather than pid
   alone: what was actually measured is that pid alone returned exactly
   one window on one machine, on one macOS version, and a sibling
   "Wallpaper" window on the same process is already documented above —
   a per-display window elsewhere is plausible. Anything other than
   exactly one match declines to guess (logged via `STARBOARD_DEBUG`, see
   below) rather than silently resolving the wrong screen, which would be
   the exact class of bug this exists to fix.

Measured cost of the fallback path: idle CPU over a 120s window, with
auto-hide off, was equal within noise to the pre-multi-display baseline
(0.47% of one core vs. 0.49%). With auto-hide on — where the cheap
bottom-strip check never applies and `dockWindowHostScreen()`'s window-list
scan runs every tick — it rose from 0.01% to 0.67%. Reported as a known,
deliberate tradeoff (a scan once a second, only in a configuration that
already opted out of the free path), not something flagged as a problem
to fix.

The resolved host feeds `resolveDockPresence()`, which now returns a
`DockPresence` (`.revealed(tray:host:)` or `.untracked(host:)`) instead of
a bare optional rect — replacing the old collapsed "did
`dockIconTrayFrame` return something" question, which couldn't
distinguish "no Accessibility permission" from "wrong screen" from
"nothing to glue to yet," and didn't carry a host screen at all for the
fallback case. `DockPresence.host` is never optional: even a Dock that
can't be read at all still resolves to a real screen (the cached host, or
main display, or `NSScreen.screens.first`) before ever reaching
`fallbackFrame(on:)`, so the fixed-corner fallback lands on the *Dock's*
screen, not whichever one happens to be main.

Coordinates need one more fix once a second display can host the Dock:
Accessibility/Quartz coordinates are anchored to the *main* display's
top-left corner no matter how the displays are physically arranged, so
`dockIconTrayFrame(flippedAgainst:)` always flips against
`mainScreen.frame.maxY`, never the host screen's own height — those two
only agree when the Dock happens to be on the main display, which used to
be the only case this code ever ran on. (Measured case: a secondary
display at `y = -212`, `1329pt` tall — flipping against its own height
instead of the main display's would be off by 111pt, since
`1440 - 1329 == 111`.) The AXList-vs-real-Dock sanity check moved with it:
where the old single-screen version rejected a flipped frame that didn't
land inside *that one* `screen.frame`, `resolveDockPresence()` now checks
it against `screenHosting(tray)` — every connected screen, centre-point
first with a greatest-overlap tiebreak for a rect straddling an edge by a
rounding error — and falls back to `.untracked` if it lands on none of
them, which is now specifically the stale/garbage-AX-read case, not "this
Dock is on some other screen" (that's a legitimate, trackable case in its
own right now).

One more change alongside the multi-display work: the glued panel's width
now floors at `minPanelWidth` (300pt, same value as `fallbackWidth` on
purpose — one "narrowest useful panel" number, not two) and grows
*leftward* over the Dock's rightmost icons rather than shrinking toward
zero, for a wide or icon-heavy Dock on a narrow display. A couple of
overlapped icons reads better than an unusable sliver of terminal. Width
is recomputed from scratch inside `gluedFrame(tray:on:)` on every
evaluation rather than latched once — if the Dock later shrinks and the
gap re-widens past 300pt, the panel returns to flush, non-overlapping
geometry on its own, with nothing to reset.

#### Reacting to display changes immediately

`NSApplication.didChangeScreenParametersNotification` is now observed
(`screenParametersChanged(_:)`), on top of the 1s poll — added because an
unplugged/reconfigured display can strand the panel at coordinates that
no longer exist, and waiting up to a second to notice reads as the app
hanging. It refreshes the caches and re-evaluates immediately; if the
panel's *own* current frame no longer intersects any connected screen at
all, it's re-anchored right away rather than left to the next tick —
collapsed goes back to the (possibly new) host's glued or fallback frame,
expanded re-centers on the Dock's host screen specifically (see
Expand/collapse below for why that differs from the screen an expansion
normally anchors to).

Left/right Dock and auto-hide still don't get their own notification —
there's no live signal for either — and stay on the 1s poll, picked up on
the next `tick()` the same way a resized Dock already is.

#### Diagnosing this remotely

`STARBOARD_DEBUG=1` in the environment gates `debugLog(_:_:)`, which
writes tagged lines (`state`, `tray`, `dockwindow`, `screens`, `expand`,
`frame`) to stderr. Left compiled into every build permanently, unlike a
one-off debugging print: this positions itself off geometry read from
other processes across whatever display arrangement a user happens to
have, and "it's 200pt off on one of my monitors" has no answer without
numbers from that specific machine — re-adding instrumentation after the
fact means shipping a new build and asking someone to reproduce it again.
Per-channel repeat suppression (`lastDebugLine`) keeps the once-a-tick
channels (`state`, `frame`, `tray`) from flooding when nothing's
changing; transition channels (`expand`, `screens`) are exempt since they
fire on real events rather than every tick and would otherwise lose
history — "concealing with the Dock" reads the same every time, so a run
with six conceals in it would log only the first without the exemption.

No App Sandbox entitlements are set (SPM executables are unsandboxed by
default), which is required for spawning a shell process at all.

#### Window level

As of v0.9.1, `panel.level` sits one level above the Dock's own window
level (`kCGDockWindowLevel`, 20) instead of `.floating` (3). `.floating`
predates Dock tracking entirely and happened to work by coincidence for a
plain bottom Dock at default size, but it actually sits *below* the
Dock's real level — so a wide or icon-heavy Dock, or icon magnification
pushing a hovered icon taller than the Dock's own baseline, painted over
the panel's edge instead of the reverse. Pre-existing and unrelated to
the multi-display work above — the Dock's window level doesn't depend on
which screen it's on, so this applies identically regardless of Dock
host.

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

### Homebrew cask

`Casks/starboard.rb` makes this repo usable directly as a Homebrew tap
(`brew tap palamim/starboard https://github.com/palamim/starboard`, then
`brew install --cask palamim/starboard/starboard`). It's a self-hosted
tap rather than a submission to the official `homebrew/cask` repo,
because that tap now requires notarized casks and Starboard is ad-hoc
signed only.

`.github/workflows/release.yml`'s existing tag-triggered job rewrites
the cask's `version` and `sha256` and pushes the change straight to
`main` on every release tag — so the tap can never point at a stale
build, and there's no separate manual step to forget. The checksum is
computed from the `Starboard.zip` already sitting in the runner's
workspace (from the same job's `Package` step) rather than fetched from
the GitHub Releases API, since release asset digests are computed there
asynchronously and may not be ready yet. `checkout` was switched to
`fetch-depth: 0` for this job because the default shallow clone doesn't
have `main`'s history available to push onto from a tag build. The
commit is skipped (not force-pushed, not amended) if the cask is
already at that version, so re-running the job is a no-op rather than an
empty commit.

Functionally, `brew upgrade` is just another way of doing the same
in-place overwrite of `/Applications/Starboard.app` that a manual
re-download does — so it hits the exact same stale Accessibility grant
described above, and the cask's `caveats` block repeats the same
`tccutil reset Accessibility com.starboard.app` fix rather than a
Homebrew-specific one, since there isn't one.

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

The terminal resolves its font from `preferredFontNames`, taking the first
name that's actually installed: patched Nerd Font variants first, then
Menlo, with `NSFont.monospacedSystemFont` (SF Mono) as the last-resort
fallback. SF Mono is deliberately last — verified programmatically
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

`terminalFontSize` is `static` so `init()` can read it while initializing
`terminalFont`; Swift forbids touching `self` before every stored property
is set, which is why the size was previously duplicated as a literal in
`init()` while the property itself went unused. `terminalFont` is computed
once in `AppDelegate.init()` rather than per-launch, since it's reused by
both the initial layout and every subsequent resize.

Changing the font family changes the row count. `terminalContentFrame`
derives rows as `floor(usableHeight / cellHeight)` from
`estimatedCellHeight`, and Nerd Font patching raises a font's vertical
metrics — enough that a Dock-height panel tuned to two rows with Menlo can
land on one. `terminalFontSize` (11pt) and `terminalPadding` (8pt) are the
knobs; drop either a point if that happens.

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

Cmd+E toggles `isExpanded`, for when Dock-height (two rows) isn't enough —
e.g. running something like Claude Code in there instead of a couple of
shell lines. Wired through the same hidden `NSMenu` key-equivalent
mechanism as Copy/Paste/Select All (`setUpMainMenu`) — no visible menu, no
button, just a key equivalent that resolves via AppKit's menu system
regardless of the menu never being drawn.

Originally (through v0.8.1) this only grew the panel upward to full
screen height, leaving `x`/width/bottom-`y` exactly as in the collapsed,
Dock-glued case — only the top edge moved. A Show HN comment
(2026-08-10) surfaced the flaw: a wide or icon-heavy Dock can leave a
Dock-to-screen-edge gap only a few characters wide, and since that scheme
left width completely untouched, expanding did nothing to fix it —
useless for the exact "run a real CLI agent in here" case `isExpanded`
exists for.

As of the fix, `frame(for:)` branches to `expandedFrame(on:)` *before*
touching Dock geometry at all: expanded mode centers the panel within
`screen.visibleFrame` at `expandedSizeFraction` (0.75) of both width and
height, fully independent of the Dock's own position/size. Centering was
chosen over the other option considered — growing left from the Dock's
right edge to compensate for a narrow gap — because that would mean
drawing the panel directly over Dock icons while expanded, which breaks
the "glued companion, never overlapping" character the rest of this file
holds to even in the collapsed case. Sizing off `visibleFrame` rather than
`frame` reuses the same trick the old height-only expand relied on:
`visibleFrame` already excludes the menu bar's reserved strip (notch
height included), and — as long as the Dock isn't set to auto-hide — the
Dock's own reserved strip too, so a centered rect sized from it can't
cover the menu bar above or the Dock below without any extra
Dock-avoidance math. (Known gap: with an auto-hiding Dock, `visibleFrame`
doesn't reserve that strip, so the centered box can reach down to where
the Dock would appear on hover — not addressed, since tracking a
Dock that hides is already out of scope elsewhere in this file.)

As of the multi-display rework, which screen an expansion centers *on* is
no longer always the Dock's host. It's captured once, as a display ID
rather than a cached `NSScreen` — screen objects go stale and keep
reporting their old frame after a reconfiguration, which a raw cached
reference would silently re-center onto — via
`expansionScreen(fallingBackTo:)`: the screen the panel is currently
sitting on (`panel.screen`), then the one its frame overlaps most, then
the Dock's host, then main. Deliberately the panel's *own* screen first,
not the Dock's: those routinely differ once the panel can live on a
non-main display, and centering a freshly-expanded panel on the Dock's
host would throw a window the user is actively typing in onto a
different monitor than the one they're looking at. The one exception is
`screenParametersChanged`'s stranded-panel case (see "Reacting to display
changes immediately" above): if the screen an expanded panel was actually
on just disappeared, there's no "own screen" left to prefer, so that path
re-centers on the Dock's host specifically, as the least-arbitrary screen
still connected.

`tick()`'s 1s timer isn't paused while expanded — it keeps calling
`runEvaluation()` every tick regardless, so a resized or reconnected
display is still picked up live; there's just no Dock state left to track
in that branch, since `expandedFrame` never reads the Dock's geometry.
Toggling calls `refreshCoarseCaches()` and applies immediately rather
than waiting for the next tick.

### Watch item: auto-hide coupling edge cases (PR #7)

PR #7 ("Hide alongside an auto-hiding Dock") couples the panel's own
visibility to an auto-hiding Dock's conceal/reveal cycle, holding the
panel in place rather than following it off screen while the panel is
exempt (key window, or expanded — see `isHeld`/`evaluate(_:)`). Review
before merging found one issue worth fixing first — `isFrozen` could get
stuck `true` for an expanded session because the freeze condition fired
symmetrically on a Dock *reveal* as well as a conceal — which is fixed via
`wasConcealed`-tracking and a same-display self-correction in
`evaluate(_:)`. The items below are real but narrower, deliberately left
open rather than blocking the PR on them:

- **Stale `collapsedFrame` replay.** `collapseTarget(for:)` validates the
  remembered frame with `NSScreen.screens.contains(where: {
  $0.frame.intersects(remembered) })`, while `applyFrame` and
  `restoreLastFullyVisibleFrameIfStranded` both use the stricter
  `.contains(...)` for the identical question on the same value. Neither
  checks the remembered frame belongs to the Dock's *current* host either.
  If a display resizes (not disconnects) or the Dock migrates screens
  while a panel is held, a later Cmd+E collapse can replay a
  partially-off-screen or wrong-monitor frame.
- **A transient AX read failure during genuine concealment reads as
  `.untracked` instead of `.concealed`.** `resolveDockPresence()`'s
  `guard let tray = dockIconTrayFrame(...) else { return .untracked(...) }`
  runs before the auto-hide branch is ever reached, so if the AX call
  itself fails (not just an odd tray reading) while the Dock is genuinely
  hidden, the panel briefly shows at the fallback corner before
  self-correcting next tick.
- **`.concealed`+exempt doesn't call `restoreLastFullyVisibleFrameIfStranded`**
  the way `.revealed`'s mid-slide branch does. Low-probability (needs the
  run loop to stall past the ~250ms conceal slide, e.g. sleep/wake), but
  the asymmetry is real and undocumented in the code itself.
- **Launch-time visibility depends on a single AX read with no retry.** A
  misclassified first read (`initialPresence` in
  `applicationDidFinishLaunching`) leaves the panel invisible at launch
  until the next ~1s coarse tick corrects it — a minor regression from the
  previous unconditional `panel.orderFrontRegardless()` at launch.
- **The zero-`NSScreen.screens` fallback in `runEvaluation()` ignores
  `isExpanded`**, shrinking an expanded panel to the small collapsed rect
  for as long as the condition holds. A specific consequence inside the
  exact path the PR author already flagged as untestable/unobserved (a Mac
  can't actually reach zero connected screens while running), not a new
  gap on top of it.

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
