# AGENTS.md

## Project overview

`matrix-screensaver` is a macOS `.saver` bundle — a Solarized-dark, brutalist, matrix-rain screensaver with a JS/TS engineering glyph set and the Jude logo emerging from a parallel "ghost" rain stream at center — plus a Matrix-console **diagnostic overlay** (spec: GitHub issue #1).

## File map

| Path | Purpose |
|------|---------|
| `MatrixView.swift` | The `ScreenSaverView` subclass: rain, logo, lifecycle/teardown, and *where* the overlay is drawn. AppKit. |
| `PanelRenderer.swift` | AppKit drawing of panel models (palette, font, box, rows, attribute caches). Owns no content decisions. |
| `Diagnostics/` | **UI-free diagnostics core** (Foundation/Darwin only, never AppKit/ScreenSaver). Everything testable lives here. |
| `Diagnostics/Environment.swift` | `DiagnosticsEnvironment`: injected clock, real home, config path, boot time, time zone. New outside-world inputs go here. |
| `Diagnostics/Config.swift` | `ConfigLoader` / `DiagConfig` for `~/.config/matrix-diag/config.json`. |
| `Diagnostics/PanelModel.swift` | `Panel` / `PanelLine` / `Severity` / `LineStyle` value types. |
| `Diagnostics/SysPanel.swift` | Pure builder for the SYS panel. One file per panel/source. |
| `Diagnostics/DiagnosticsCore.swift` | Facade the renderer calls: loads config, `panels()` per frame. |
| `Tests/` | Plain `swiftc` test executable (`main.swift` lists suites, `TestKit.swift` assertion helper, one `*Tests.swift` per seam). |
| `Harness/main.swift` | Offscreen render harness: real MatrixView + fake environment -> PNGs. |
| `mise.toml` | `build`, `test`, `snapshot`, `install`, `package`, `preview`, `clean` tasks. **Authoritative build commands.** |
| `README.md` | Palette reference, build steps, design notes. |
| `AGENTS.md` | This file. |

## Build, test, install (no Xcode required)

```bash
mise run test       # swiftc Diagnostics/*.swift Tests/*.swift -> build/tests/DiagnosticsTests, run it (non-zero on failure)
mise run build      # swiftc MatrixView.swift PanelRenderer.swift Diagnostics/*.swift -> Mach-O bundle, ad-hoc signed
mise run snapshot   # offscreen render to build/snapshot/*.png (overlay, overlay-off, preview, secondary-display)
mise run install    # build + copy to ~/Library/Screen Savers + kill the hosts so they reload
```

`mise.toml` holds the exact `swiftc` invocations. The `build/` directory and compiled `.saver` are gitignored — always build from source; put every build/test artifact under `build/`.

`mise run test` also fails if anything in `Diagnostics/` imports AppKit/ScreenSaver/Cocoa/SwiftUI.

## Source layout rules

- The single-file rule is relaxed: saver = `MatrixView.swift` + `PanelRenderer.swift` (AppKit) + `Diagnostics/*.swift` (core), compiled as one module. A future collector executable compiles `Diagnostics/*.swift` + its own `main.swift`, so the core must stay UI-free and free of global side effects.
- Content decisions (what a line says, its severity) belong in the core and are tested there. The renderer only maps `Severity`/`LineStyle` to colours and geometry.
- Anything from the outside world (time, files, home, Wi-Fi, process liveness, …) is a member of `DiagnosticsEnvironment`, never called directly from a builder.
- Tests assert on the panel model at the highest seam (`DiagnosticsCore` with a fake home tree via `FakeWorld` in `Tests/CoreTests.swift`, or a panel builder), never on drawing or private helpers. Expected values are literals.
- Add a test suite: new `Tests/FooTests.swift` with `func fooTests()`, then call it from `Tests/main.swift`.

## Activating (macOS 26 Tahoe)

Screen Saver settings moved in macOS 26: **System Settings → Wallpaper → Screen Saver… → toggle to Custom** → select SolarizedMatrix.

## Architecture

`MatrixView` owns a `CGContext` offscreen buffer (`buffer`) that accumulates glyph draws across frames. Each frame:

1. Fade buffer toward `base03` background by `Cfg.fadeAlpha` (source-over composite) — this produces the glowing trail.
2. Draw body glyph + head token for each column into the buffer via AppKit text APIs.
3. Blit the buffer to the screen context via `CGContext.draw(_:in:)`.
4. Draw the overlay (`DiagnosticsCore.panels()` -> `PanelRenderer`) into the **screen** context, never into the buffer, so it stays crisp.

This explicit buffer is necessary because `ScreenSaverView.draw()` does not guarantee backing-store preservation between calls.

## Diagnostic overlay

- Active when: not `isPreview` (no `DiagnosticsCore` is even created in preview), main display, and config `overlay` is not `false`. Decided in `setup()` and on `viewDidMoveToWindow`, logged once per decision: `log show --predicate 'subsystem == "law.jude.SolarizedMatrix"'`.
- Main display = the view's `window.screen` display ID equals `CGMainDisplayID()` (the menu-bar display, `NSScreen.screens.first`). No window/screen yet → main only if there is one screen. The harness forces it via `displayRoleOverride`.
- Config is loaded once per `DiagnosticsCore`, i.e. once per saver activation (each activation builds a fresh `MatrixView`).
- Real home comes from `getpwuid(getuid())`; the sandboxed host's `NSHomeDirectory()` is its container. The sandboxed host *can* read `~/.config/matrix-diag/config.json` (verified).
- Keep the dismissal guarantees: `autoreleasepool` in `draw`, cached attrs (renderer caches its own), terminal `didstop`, `teardown()` releases buffers and the renderer.
- Real-host check without screen capture (the session is locked while the saver runs): `SM_SWIFT_FLAGS="-D SM_FRAME_DUMP" mise run install` makes the saver write `SolarizedMatrix-frame-<pid>-main-150.png` into its container's `Data/tmp` (`~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/tmp/`). Reinstall without the flag afterwards.

## Key tunables (`Cfg` in `MatrixView.swift`)

| Constant | Default | Effect |
|----------|---------|--------|
| `fontSize` | `16` | Column width and glyph size |
| `fallMin` / `fallMax` | `0.4` / `1.2` | Row advance per frame (speed range) |
| `fadeAlpha` | `0.018` | Trail length — lower = longer, glowier trails |
| `overlayFontSize` | `15` | Overlay text size (points) |
| `overlayColumns` | `34` | Overlay panel width in monospace cells |
| `overlayMargin` | `48` | Overlay inset from the screen edge (points) |

## Glyph sets

- **Body** (`bodyGlyphs`): single-char JS/TS operators, punctuation, digits, half-width katakana. Code symbols weighted 2× over katakana.
- **Head** (`headTokens`): multi-char JS/TS keywords and operators (`const`, `await`, `===`, `?.`, `=>`, etc.) drawn as the bright leading glyph of each falling stream.

## Per-stream variation

Each column carries independent `colAlpha` (0.25–1.0) and `colColor` (Solarized accent). Both randomise on reset, giving streams varied brightness as they cycle.

## Jude logo

SVG sourced from `jude.law/images/layout/logo.svg`, embedded as a string constant, loaded as `NSImage`. Rather than a solid watermark, the logo emerges from a parallel "ghost" rain stream: the logo is rendered off-screen and its alpha channel sampled per glyph cell to build a `[col][row]` mask (`buildLogoMask`); a second rain stream is then drawn only on cells inside that mask, in a warmer/brighter palette (`logoStream`). The bounding box is `Cfg.logoSizeRatio` (`0.60`) of `min(width, height)` and stream alpha is `Cfg.logoAlpha` (`0.80`).

## Source of truth

The Swift sources are the single source of truth — `assets/matrix-preview.svg` is only an impression. Rendering tunables live in `Cfg` (`MatrixView.swift`); edit and rebuild (see *Build, test, install*), or `mise run snapshot` to see changes without installing.

## Agent skills

### Issue tracker

Issues and specs live in GitHub Issues for `arcticShadow/matrix-screensaver` (via the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` and `docs/adr/` at the repo root, created lazily. See `docs/agents/domain.md`.
