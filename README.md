# Solarized Matrix — Brutalist macOS Screensaver

Starter kit. The visual design is lifted from the **Inbox Triage V2** artifact's
"code river" canvas background and its Solarized-dark palette, reworked into a
full-screen matrix-rain screensaver with a brutalist mono overlay.

## What's here

| File | Purpose |
|------|---------|
| `preview.html` | Open in any browser → see the exact look, full screen. The visual source of truth. |
| `MatrixView.swift` | `ScreenSaverView` port of the effect. Drop into an Xcode Screen Saver target. |
| `README.md` | This file — palette reference + build/install steps + a prompt for code mode. |

Open `preview.html` first to confirm the aesthetic. Tunables (`CFG` in the HTML,
`Cfg` in the Swift) are kept 1:1 so adjusting one is easy to mirror.

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

## Building the .saver (Xcode required)

1. Xcode → **File ▸ New ▸ Project ▸ macOS ▸ Screen Saver** → name it `SolarizedMatrix`.
2. Delete the generated `*.swift` view file; add `MatrixView.swift`.
3. In `Info.plist`, set **Principal class** (`NSPrincipalClass`) to `$(PRODUCT_MODULE_NAME).MatrixView`.
4. Build (⌘B). Product is `SolarizedMatrix.saver` under `~/Library/Developer/Xcode/DerivedData/.../Build/Products/`.
5. Double-click the `.saver` to install, or copy it to `~/Library/Screen Savers/`.
6. System Settings ▸ Screen Saver → pick **SolarizedMatrix**.

Note: macOS runs modern screensavers out of process (`legacyScreenSaver`). If a
build doesn't refresh, log out/in or run `killall legacyScreenSaver`.

## Open design choices (decide in code mode)

- **Glyphs**: currently katakana + code symbols mixed. Switch to pure katakana or pure code by editing the glyph set.
- **Brutalist overlay**: the HTML has a hard border frame, big mono wordmark, clock, and scanlines. The Swift starter renders rain only — porting the overlay (text + frame + scanlines) is the natural next step.
- **Config sheet**: `hasConfigureSheet` is `false`. Add a sheet to expose speed/colors at runtime if wanted.
- **Multi-display**: ScreenSaverView handles this, but test per-monitor sizing.

## Prompt to paste into code mode

> I'm building a macOS screensaver: a Solarized-dark, brutalist, matrix-rain
> effect. `preview.html` is the visual source of truth and `MatrixView.swift`
> is a starter `ScreenSaverView` port (tunables mirror the HTML's `CFG`).
> Please: (1) scaffold an Xcode Screen Saver project named `SolarizedMatrix`
> wired to `MatrixView` as the principal class, (2) port the brutalist overlay
> from `preview.html` (border frame, large mono "MATRIX / SOLARIZED // DARK"
> wordmark, live clock, scanlines) into the Swift view, (3) build with
> `xcodebuild`, install to `~/Library/Screen Savers/`, and help me preview it.
> Keep the katakana+code glyph mix and the bright base3 head glyph.
