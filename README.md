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
| `Collector/` | Optional unsandboxed collector (`mise run collector:build`): per-account Claude usage -> `~/.local/state/matrix-diag/collector-state.json`, which the saver's SYS panel reads. |
| `Harness/` | Offscreen render harness (`mise run snapshot`): renders rain + overlay to PNGs with a fake environment. |
| `build/SolarizedMatrix.saver/` | Bundle skeleton (`Info.plist` + `MacOS/`). Rebuild the binary from source. |
| `assets/matrix-preview.svg` | The animated preview shown above. Generated, not hand-edited. |
| `tools/gen_preview.py` | Generator for the preview SVG (`mise run preview`); mirrors the look from `MatrixView.swift`. |
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
(went idle under 15 minutes ago, amber) and DORMANT. A roster lists the
sessions that matter, attention first, each under a stable salted codename
(`IRON-LATTICE`) with a three-letter profile tag; only the category of a
prompt (`APPROVE BASH`, `INPUT NEEDED`) is ever shown, never the command. If
the session files can't be parsed it says `AGENT.LINK SIGNAL LOST` rather than
showing zero. Usage limits and calendar are on the way — see issue #1.

To turn it off without rebuilding, create `~/.config/matrix-diag/config.json`:

```json
{ "overlay": false }
```

The file is optional (missing or malformed → defaults) and is read at each
activation. It is personal and never committed. Other keys reserved by the spec
(`trustedSSIDs`, `codenameSalt`, `profileTags`) are accepted and ignored for now.

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

## Installing the pre-built release

Download `SolarizedMatrix.saver.zip`, unzip, then double-click `SolarizedMatrix.saver` to install.

**"App is damaged" / Gatekeeper warning?**  
macOS tags files downloaded from the internet with a quarantine attribute and blocks unsigned bundles. Fix it with one command after installing:

```bash
xattr -cr ~/Library/Screen\ Savers/SolarizedMatrix.saver
```

Then open System Settings ▸ Screen Saver and pick **SolarizedMatrix**.

**Prefer to avoid the workaround?** Clone the repo and build it yourself (see section below) — locally-built bundles are never quarantined.

---

## Building the .saver (no Xcode required)

### With mise (recommended)

[mise](https://mise.jdx.dev) wraps the reproducible steps as tasks:

```bash
mise run build      # compile + ad-hoc sign          -> build/SolarizedMatrix.saver
mise run test       # build + run the diagnostics-core tests (non-zero on failure)
mise run snapshot   # render rain + overlay offscreen -> build/snapshot/*.png
mise run install    # build, then install to ~/Library/Screen Savers and reload
mise run package    # build, then zip a distributable -> SolarizedMatrix.saver.zip
```

Set the version in one place — `SM_VERSION` in `mise.toml` — and it's stamped into
the generated `Info.plist`. Cutting a full GitHub release is documented in the
`release` skill under `.claude/skills/release/`.

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
