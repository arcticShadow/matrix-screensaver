# AGENTS.md

## Project overview

`matrix-screensaver` is a macOS `.saver` bundle — a Solarized-dark, brutalist, matrix-rain screensaver with a JS/TS engineering glyph set and the Jude logo emerging from a parallel "ghost" rain stream at center.

## File map

| File | Purpose |
|------|---------|
| `MatrixView.swift` | The entire screensaver — `ScreenSaverView` subclass. Single file, no Xcode project needed. **The single source of truth.** |
| `README.md` | Palette reference, build steps, design notes. |
| `AGENTS.md` | This file. |

## Build & install (no Xcode required)

```bash
swiftc MatrixView.swift \
  -module-name SolarizedMatrix \
  -emit-library -Xlinker -bundle \
  -o build/SolarizedMatrix.saver/Contents/MacOS/SolarizedMatrix \
  -framework ScreenSaver -framework AppKit -framework Foundation \
  -target arm64-apple-macosx13.0

codesign -s - build/SolarizedMatrix.saver

cp -r build/SolarizedMatrix.saver ~/Library/Screen\ Savers/
killall legacyScreenSaver 2>/dev/null; killall ScreenSaverEngine 2>/dev/null
```

The `build/` directory and compiled `.saver` are gitignored — always build from source.

## Activating (macOS 26 Tahoe)

Screen Saver settings moved in macOS 26: **System Settings → Wallpaper → Screen Saver… → toggle to Custom** → select SolarizedMatrix.

## Architecture

`MatrixView` owns a `CGContext` offscreen buffer (`buffer`) that accumulates glyph draws across frames. Each frame:

1. Fade buffer toward `base03` background by `Cfg.fadeAlpha` (source-over composite) — this produces the glowing trail.
2. Draw body glyph + head token for each column into the buffer via AppKit text APIs.
3. Blit the buffer to the screen context via `CGContext.draw(_:in:)`.

This explicit buffer is necessary because `ScreenSaverView.draw()` does not guarantee backing-store preservation between calls.

## Key tunables (`Cfg` in `MatrixView.swift`)

| Constant | Default | Effect |
|----------|---------|--------|
| `fontSize` | `16` | Column width and glyph size |
| `fallMin` / `fallMax` | `0.4` / `1.2` | Row advance per frame (speed range) |
| `fadeAlpha` | `0.018` | Trail length — lower = longer, glowier trails |

## Glyph sets

- **Body** (`bodyGlyphs`): single-char JS/TS operators, punctuation, digits, half-width katakana. Code symbols weighted 2× over katakana.
- **Head** (`headTokens`): multi-char JS/TS keywords and operators (`const`, `await`, `===`, `?.`, `=>`, etc.) drawn as the bright leading glyph of each falling stream.

## Per-stream variation

Each column carries independent `colAlpha` (0.25–1.0) and `colColor` (Solarized accent). Both randomise on reset, giving streams varied brightness as they cycle.

## Jude logo

SVG sourced from `jude.law/images/layout/logo.svg`, embedded as a string constant, loaded as `NSImage`. Rather than a solid watermark, the logo emerges from a parallel "ghost" rain stream: the logo is rendered off-screen and its alpha channel sampled per glyph cell to build a `[col][row]` mask (`buildLogoMask`); a second rain stream is then drawn only on cells inside that mask, in a warmer/brighter palette (`logoStream`). The bounding box is `Cfg.logoSizeRatio` (`0.60`) of `min(width, height)` and stream alpha is `Cfg.logoAlpha` (`0.80`).

## Source of truth

`MatrixView.swift` is the single source of truth — there is no separate browser preview. All tunables live in `Cfg`; edit and rebuild (see *Build & install*) to see changes.
