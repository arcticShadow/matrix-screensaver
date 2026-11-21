# Solarized Matrix — Brutalist macOS Screensaver

A Solarized-dark, brutalist, matrix-rain screensaver for macOS. Half-width
katakana and a JS/TS engineering glyph set; bright base3 head glyph; Solarized
accent colour-per-column.

## Preview

<p align="center">
  <img src="assets/matrix-preview.svg" width="720"
       alt="Animated preview of the Solarized Matrix screensaver: a Solarized-dark code rain of half-width katakana and JS/TS glyphs with bright base3 heads, and the Jude logo breathing in and out of the rain." />
</p>

> The clip above is **not a video file** — it's a self-contained animated SVG
> (`assets/matrix-preview.svg`): vector glyphs driven by SMIL animation, which
> GitHub renders and loops inline. It mirrors the palette and glyph set from
> `MatrixView.swift`. Regenerate it with `mise run preview` — or directly,
> `python3 tools/gen_preview.py > assets/matrix-preview.svg`. It's an
> *impression* of the look, not a frame-exact capture — the real thing runs at
> 30 fps with longer, glowing trails.

## What's here

| File | Purpose |
|------|---------|
| `MatrixView.swift` | The `ScreenSaverView` subclass: rain, logo, lifecycle. The source of truth for the look. |
| `PanelRenderer.swift` | Draws the diagnostic overlay's panels (AppKit). |
| `Diagnostics/` | UI-free diagnostics core: config, panel model, panel builders. No AppKit, unit-tested. |
| `Tests/` | Plain `swiftc` test executable for the core (`mise run test`; no XCTest). |
| `Collector/` | Optional unsandboxed collector (`mise run collector:build`): per-account Claude usage and upcoming calendar events (`gws`) -> `~/.local/state/matrix-diag/collector-state.json`, which the saver's SYS panel reads. Expired tokens are refreshed by Claude Code itself via a hidden `claude -p` run (at most hourly, once data is 2 h stale); those runs never appear in AGENTS. |
| `mise.collector.toml` | Opt-in LaunchAgent install for the collector (`mise -E collector bootstrap`; see below). |
| `Harness/` | Offscreen render harness (`mise run snapshot`): renders rain + overlay to PNGs with a fake environment. |
| `build/SolarizedMatrix.saver/` | Bundle skeleton (`Info.plist` + `MacOS/`). Rebuild the binary from source. |
| `assets/matrix-preview.svg` | The animated preview shown above. Generated, not hand-edited. |
| `tools/gen_preview.py` | Generator for the preview SVG (`mise run preview`); mirrors the look from `MatrixView.swift`. |
| `INSTALL.txt` | Short install notes shipped inside the release zip. |
| `README.md` | This file — palette reference + build/install steps. |

Tunables live in the `Cfg` struct at the top of `MatrixView.swift` — glyph cell
size, fall speed, trail fade, the logo size/alpha, and overlay size/margin are all there.

## Diagnostic overlay

On the main display (never in the System Settings preview, never on secondary
displays) a Matrix-console **SYS** panel sits over the rain: clock, date,
system uptime (`CONSTRUCT.UPTIME 4d 03:12`), saver uptime, host vitals (load
average, memory pressure, thermal state), battery level and power source
(omitted on desktops) and a couple of atmospheric flavour lines. A single
background poller refreshes each source on its own interval (vitals 5 s,
battery 60 s), slows itself down if a read is slow or failing, and marks a
section with a dim `·12s` when its data is getting old.

In the opposite corner an **AGENTS** panel counts your Claude Code sessions
across every `~/.claude*` config directory (CLI and Claude Desktop): RUNNING,
ACTIVE, ATTENTION (blocked on a permission prompt or question, red), AWAITING
(went idle under 15 minutes ago, amber) and DORMANT, plus BACKGROUND: the
in-flight subagents, running background jobs and daemon workers behind them
(each roster row shows its own `+N BG`). A roster lists the
sessions that matter, attention first, each under a stable salted codename
(`IRON-LATTICE`) with a three-letter profile tag; only the category of a
prompt (`APPROVE BASH`, `INPUT NEEDED`) is ever shown, never the command. If
the session files can't be parsed it says `AGENT.LINK SIGNAL LOST` rather than
showing zero. To spare OLED/XDR screens from burn-in, the two panels rotate
clockwise together one corner every 10 minutes, always diagonally opposite and
clear of the logo (the roster shortens if the logo is in its way, folding the totals into one line before it drops an attention row). While any session is blocked on you, the AGENTS border and its ATTENTION row
pulse red. Once a session has waited 30 s, a centre takeover banner
(`⚠ OPERATOR REQUIRED — IRON-LATTICE — APPROVE BASH`) shows for ~4 s every
60 s, cycling oldest-first through the waiting sessions, while the rain glitches
and washes red behind it.

With the optional collector installed (below), SYS also shows Claude usage per
account and a CALENDAR line: the next upcoming timed event
(`NEXT 14:30 Standup (in 22m)`, amber within 5 minutes) or `NOW ▸ <title>` while
one is in progress. All-day events are skipped. Event titles follow the same
trusted-network rule as repo names and read `EVENT` anywhere else.
SYS never grows into the logo or off the screen either: with many accounts it
drops the flavour lines first, then folds the calmest accounts into a
`+N ACCOUNTS` line (accounts near a limit stay listed longest); the clock and
date always show.

Real repo names replace the codenames only on a **trusted network**: when the
current Wi-Fi name can be read and is one of the `trustedSSIDs` in your config
(checked every 30 s). Anywhere else the roster keeps codenames. If the Wi-Fi
name can't be read at all (Wi-Fi off, wired, macOS redaction, any error) the
panel also shows `NET UNVERIFIED`. With no `trustedSSIDs` it always uses
codenames.

### Config file

`~/.config/matrix-diag/config.json` is read by the saver (at each activation) and
the collector. It is optional: missing or malformed means defaults, and each key
is checked on its own, so one bad value keeps only that key's default. It is
personal and never committed. The collector's install creates it (only if
missing) with a random salt; without the collector, create it by hand if you want
anything other than the defaults.

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `overlay` | bool | `true` | `false` turns the overlay off (plain rain) without rebuilding. |
| `trustedSSIDs` | array of strings | `[]` | Wi-Fi names on which real repo names and event titles are shown. Empty = codenames everywhere. |
| `codenameSalt` | string | random per activation | Keeps codenames stable. Without it codenames change every time the saver starts. Keep it secret: anyone with it can confirm a guessed repo. |
| `profileTags` | object | `{}` | Config-dir basename → tag (up to 3 letters/digits). Unlisted dirs: `.claude` → `WRK`, `.claude-<name>` → first three letters of `<name>`, uppercased. |

Placeholder example (use your own values):

```json
{
  "overlay": true,
  "trustedSSIDs": ["<your home Wi-Fi name>"],
  "codenameSalt": "<any long random string>",
  "profileTags": { ".claude-<name>": "LAB" }
}
```

### What it reads

The saver reads only local files and system state. Only the optional collector
touches credentials or the network.

**The saver** (sandboxed, no credentials):

- `~/.claude*/sessions/*.json`: the live per-session files Claude Code writes
  (status, kind, entrypoint, cwd, timestamps). The free-text `waitingFor` command
  is reduced to a category and never shown.
- Background work per session: `~/.claude*/projects/<project>/<session>/subagents/*.meta.json`
  (and the matching transcript's modification time, never its contents),
  `~/.claude*/jobs/*/state.json` and `~/.claude*/daemon/roster.json`.
- Host vitals (load, memory pressure, thermal state, uptime), battery, and the
  current Wi-Fi name (only to compare with `trustedSSIDs`; never drawn or logged).
- `~/.config/matrix-diag/config.json` and the collector's state file
  `~/.local/state/matrix-diag/collector-state.json`.

**The collector** (optional, unsandboxed LaunchAgent, runs every 60 s and fetches each
source at most every 5 minutes):

- **Keychain:** for each `~/.claude*` directory, the Claude Code OAuth token, read
  with `/usr/bin/security find-generic-password -s <service> -w` (Claude Code's own
  keychain item; `security` is the client that item trusts, so no prompts).
  The token stays in memory and is never written or logged.
- **Network:** one `GET https://api.anthropic.com/api/oauth/usage` per account with
  that token (5-hour, 7-day and extra-usage figures). That is the only request the
  collector itself makes (an allowlist enforces it); it never calls the OAuth
  refresh endpoint. `gws` and `claude` below make their own requests.
- **Token refresh:** when an account's token has expired and its data is over 2 h
  old, at most once an hour it runs `claude -p` (small model, trivial prompt, no
  tools, no session persistence) with that account's config dir, so Claude Code
  refreshes its own token. These runs are hidden from the AGENTS panel.
- **Calendar:** `gws calendar +agenda --days 2 --format json`
  ([Google Workspace CLI](https://github.com/googleworkspace/cli), the single
  signed-in account). Only each event's title, start, end and all-day flag are kept.
- It does **not** read session files, transcripts or repos. It writes only the
  state file, its log (`~/Library/Logs/matrix-diag/collector.log`: errors and state
  changes, truncated past 1 MB) and, on install, the config file.

Without the collector, the usage and calendar lines show `COLLECTOR OFFLINE` and
everything else works.

## Solarized Dark palette

```
base03  #002b36   background        cyan    #2aa198
base02  #073642                     blue    #268bd2
base01  #586e75   borders/dim       green   #859900
base0   #839496   body              violet  #6c71c4
base1   #93a1a1   bright            yellow  #b58900
base3   #eee8d5   bright head glyph orange  #cb4b16
                                    red     #dc322f
                                    magenta #d33682
```

Column glyphs cycle through cyan → blue → green → violet → yellow; the leading
"head" glyph is base3 (`#eee8d5`) for the classic bright-tip matrix look.

## Installing a release

Download `SolarizedMatrix.saver.zip` from the GitHub release and unzip it. You get
one folder, `SolarizedMatrix/`:

| File | What it is |
|------|------------|
| `SolarizedMatrix.saver` | The screensaver. |
| `matrix-diag-collector` | The optional collector, prebuilt (arm64, ad-hoc signed). |
| `mise.collector.toml` | Its LaunchAgent declaration and install/uninstall tasks for [mise](https://mise.jdx.dev). |
| `INSTALL.txt` | A short version of this section. |

### Gatekeeper / quarantine

Both binaries are only ad-hoc signed, and macOS quarantines anything downloaded
from the internet: the saver then fails with *"App is damaged"* and the collector
is killed on launch. Clear the quarantine attribute on the unpacked folder first
(adjust the path to where you unzipped it):

```bash
xattr -cr ~/Downloads/SolarizedMatrix
```

or on each installed copy afterwards:

```bash
xattr -cr ~/Library/Screen\ Savers/SolarizedMatrix.saver
xattr -d com.apple.quarantine ~/.local/libexec/matrix-diag/matrix-diag-collector
```

(The mise install below already strips it from the collector copy it installs.)
Building from source avoids this entirely: locally built files are never quarantined.

### The screensaver

Double-click `SolarizedMatrix.saver` (macOS asks to install it for the current
user), or `cp -R SolarizedMatrix.saver ~/Library/Screen\ Savers/`. Then pick it:
**System Settings → Wallpaper → Screen Saver… → Custom → SolarizedMatrix**
(macOS 26; earlier versions: **System Settings → Screen Saver**).

### The collector with mise (optional)

Read [What it reads](#what-it-reads) first. From the unpacked folder:

```bash
cd ~/Downloads/SolarizedMatrix
mise trust mise.collector.toml
mise -E collector bootstrap --only macos-launchd-agents,task
```

That installs the LaunchAgent `~/Library/LaunchAgents/dev.mise.matrix-diag-collector.plist`,
copies the **prebuilt** `matrix-diag-collector` to `~/.local/libexec/matrix-diag/`
(stripping quarantine), creates `~/Library/Logs/matrix-diag/`, creates
`~/.config/matrix-diag/config.json` if it is missing (printing its path), and
starts the agent. `--only …` skips any bootstrap parts from your global mise
config; drop it to apply those too. Re-running it (for example from a newer
release) is safe. Add your `trustedSSIDs` to the config file afterwards.

Uninstall (from the same folder):

```bash
mise -E collector run collector:uninstall           # agent, plist, binary, logs, state; keeps config
mise -E collector run collector:uninstall --purge   # ...and the config file (your salt) too
```

Keeping the config means a reinstall keeps your codenames.

### The collector without mise (optional)

The same install by hand, from the unpacked folder (the label matches the mise
one, so you can switch later):

```bash
cd ~/Downloads/SolarizedMatrix
mkdir -p ~/.local/libexec/matrix-diag ~/Library/Logs/matrix-diag ~/Library/LaunchAgents
cp matrix-diag-collector ~/.local/libexec/matrix-diag/
xattr -d com.apple.quarantine ~/.local/libexec/matrix-diag/matrix-diag-collector 2>/dev/null || true
~/.local/libexec/matrix-diag/matrix-diag-collector --init-config --config ~/.config/matrix-diag/config.json

cat > ~/Library/LaunchAgents/dev.mise.matrix-diag-collector.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.mise.matrix-diag-collector</string>
  <key>ProgramArguments</key>
  <array><string>$HOME/.local/libexec/matrix-diag/matrix-diag-collector</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>60</integer>
  <key>ProcessType</key><string>Background</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key><string>$HOME</string>
    <key>USER</key><string>$USER</string>
  </dict>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/matrix-diag/launchd.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/matrix-diag/launchd.log</string>
</dict>
</plist>
EOF

launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.mise.matrix-diag-collector.plist
```

`HOME` and `USER` must be in the agent's environment: `gws` and `claude` need them.
To update, copy the new binary over the old one (and clear its quarantine), then
`launchctl kickstart -k gui/$(id -u)/dev.mise.matrix-diag-collector`.

Uninstall by hand:

```bash
launchctl bootout gui/$(id -u)/dev.mise.matrix-diag-collector
rm -f ~/Library/LaunchAgents/dev.mise.matrix-diag-collector.plist
rm -rf ~/.local/libexec/matrix-diag ~/Library/Logs/matrix-diag ~/.local/state/matrix-diag
rm -rf ~/.config/matrix-diag   # only to purge the config (salt, trusted SSIDs)
```

---

## Building the .saver (no Xcode required)

### With mise (recommended)

[mise](https://mise.jdx.dev) wraps the reproducible steps as tasks:

```bash
mise run build      # compile + ad-hoc sign          -> build/SolarizedMatrix.saver
mise run test       # build + run the diagnostics-core tests (non-zero on failure)
mise run snapshot   # render rain + overlay offscreen -> build/snapshot/*.png
mise run install    # build, then install to ~/Library/Screen Savers and reload
mise run package    # build saver + collector, zip   -> SolarizedMatrix.saver.zip
```

Set the version in one place — `SM_VERSION` in `mise.toml` — and it's stamped into
the generated `Info.plist`. Cutting a full GitHub release is documented in the
`release` skill under `.claude/skills/release/`.

`mise run package` zips one `SolarizedMatrix/` folder: the saver, the collector
built by `collector:build` (named `matrix-diag-collector`, next to
`mise.collector.toml`, which is how the bootstrap task knows to install it instead
of building), `mise.collector.toml` and `INSTALL.txt`. It fails if either binary
is not a valid signed Mach-O.

### Installing the collector from a checkout (optional)

The usage and calendar blocks in the SYS panel need the unsandboxed collector, run by
launchd every 60 s (see [What it reads](#what-it-reads)). It writes
`~/.local/state/matrix-diag/collector-state.json`. Without it the saver shows
`COLLECTOR OFFLINE` there and everything else still works. If `gws` is missing or
signed out (`gws auth login`), the calendar shows `NO SIGNAL` (or its last events,
marked stale) and the collector retries with backoff.

It is opt-in: it lives in `mise.collector.toml`, which only loads with `-E collector`,
so a plain `mise bootstrap` (or your global machine bootstrap) never installs it.

```bash
mise -E collector bootstrap             # install or update, then (re)start the agent
mise -E collector bootstrap --dry-run   # preview
mise run collector:uninstall            # unload + remove agent, binary, logs, state
mise run collector:uninstall --purge    # ...and the config file too
```

`mise -E collector bootstrap` also applies your global mise bootstrap parts; add
`--only macos-launchd-agents,task` to install just the collector. It installs:

- the LaunchAgent `~/Library/LaunchAgents/dev.mise.matrix-diag-collector.plist`
- the binary `~/.local/libexec/matrix-diag/matrix-diag-collector` (built from source,
  or copied from a prebuilt `matrix-diag-collector` next to `mise.collector.toml`)
- logs in `~/Library/Logs/matrix-diag/` (`collector.log`: errors and changes only)
- `~/.config/matrix-diag/config.json`, **only if missing**, with defaults and a random
  codename salt. Its path is printed; add your trusted SSIDs there. It is never
  overwritten, and uninstall keeps it (unless `--purge`) so your codenames survive a
  reinstall.

Re-running the bootstrap is safe: it reinstalls the binary only if it changed and
restarts the agent. `mise run install` (the saver) is unaffected.

### By hand

The same underlying steps (`mise.toml` is the authoritative version — notably it
also generates `Contents/Info.plist`, which the bundle needs in order to load):

```bash
mkdir -p build/SolarizedMatrix.saver/Contents/MacOS

swiftc MatrixView.swift PanelRenderer.swift Diagnostics/*.swift \
  -module-name SolarizedMatrix \
  -emit-library -Xlinker -bundle \
  -o build/SolarizedMatrix.saver/Contents/MacOS/SolarizedMatrix \
  -framework ScreenSaver -framework AppKit -framework Foundation \
  -target arm64-apple-macosx13.0

codesign -s - build/SolarizedMatrix.saver

cp -r build/SolarizedMatrix.saver ~/Library/Screen\ Savers/
killall legacyScreenSaver 2>/dev/null; killall ScreenSaverEngine 2>/dev/null
```

Verify the output is a **bundle**, not a dylib — macOS will refuse to run a
screensaver built as a shared library:

```bash
file build/SolarizedMatrix.saver/Contents/MacOS/SolarizedMatrix
# → Mach-O 64-bit bundle arm64
```

### Activating (macOS 26 Tahoe)

Screen Saver settings moved: **System Settings → Wallpaper → Screen Saver… → toggle to Custom** → select **SolarizedMatrix**.

On earlier macOS versions: **System Settings → Screen Saver**.

Note: macOS runs screensavers out of process (`legacyScreenSaver`). If a build
doesn't refresh, log out/in or run `killall legacyScreenSaver`.

### Xcode (optional)

If you prefer an Xcode project: **File ▸ New ▸ Project ▸ macOS ▸ Screen Saver** → name it `SolarizedMatrix`, replace the generated view with `MatrixView.swift`, add `PanelRenderer.swift` and `Diagnostics/*.swift`, set **Principal class** to `SolarizedMatrix.MatrixView`, and build.

## Open design choices

- **Glyphs**: currently katakana + code symbols mixed. Switch to pure katakana or pure code by editing the glyph set.
- **Config sheet**: `hasConfigureSheet` is `false`. Add a sheet to expose speed/colors at runtime if wanted.
- **Multi-display**: ScreenSaverView handles this, but test per-monitor sizing.
