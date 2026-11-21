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
| `Diagnostics/DiagnosticsCore.swift` | Facade the renderer calls: loads config, leases the poller (`startPolling`/`stopPolling`), `panels()` per frame from the clock + latest snapshot. `.manual` polling mode for tests (`pollNow()`). |
| `Diagnostics/Schedule.swift` | `SourceSchedule`: the pure, Codable adaptive scheduling policy (base, throttle, backoff, staleness). Shared with the collector. |
| `Diagnostics/Poller.swift` | `DiagSnapshot`, the source registry (`PollSources.standard`), `PollEngine` (single-threaded tick), `PollerHub` (the one shared background poller, lease-counted). |
| `Diagnostics/HostReaders.swift` | `HostVitals` / `PowerStatus` and the live readers (getloadavg, memory-pressure sysctl, thermal state, IOKit power sources). |
| `Diagnostics/Flavour.swift` | Clock-driven atmosphere lines (scrolling hex, status readout). |
| `Diagnostics/Sessions.swift` | Session discovery (`~/.claude*` dirs with `sessions/`, canonical `<pid>.json` only), `SessionRecord`, `WaitCategory` (the only part of `waitingFor` kept), `Liveness` (`proc_pidinfo` + UTC `procStart`). |
| `Diagnostics/BackgroundAgents.swift` | Background-agent counts per session (`BackgroundAgentScanner`, run inside the sessions scan): fresh unfinished subagent metas, running jobs, live daemon-roster workers; `ProjectDirName` (Claude Code's cwd → project-dir sanitiser); `BackgroundCfg` tunables. |
| `Diagnostics/AgentsPanel.swift` | `AgentClassifier` (ATTENTION/ACTIVE/AWAITING/DORMANT/GHOST, `AgentsCfg` tunables) and the pure AGENTS panel builder (totals, sorted roster, dormant fold, `+N more`). |
| `Diagnostics/Alerts.swift` | Attention alerts: `AlertsCfg` (30 s wait threshold, 60 s period, 4 s duration), `AttentionAlerts.candidates` (live ATTENTION sessions waiting ≥ threshold, oldest first) and `BannerScheduler` (when the takeover banner shows and which session it names). |
| `Diagnostics/Naming.swift` | `DisplayNamer` (the one place a session's on-screen name is decided: `RepoName` when trusted, else salted `Codename`), `ProfileTags`. |
| `Diagnostics/Network.swift` | Trusted-network rule: `NetworkTrust.decide` (trusted / untrusted / unverified), `WiFiStatus` (never prints the name), live `WiFiReader.currentSSID` (SCDynamicStore AirPort `CachedScanRecord`). |
| `Diagnostics/Layout.swift` | `PanelLayout.place`: which corner and width each panel gets. `PanelRotation`: SYS and AGENTS diagonally opposite, stepping clockwise together once per interval (step 0 = SYS top-left, AGENTS bottom-right). |
| `Diagnostics/CollectorState.swift` | The collector state-file schema (`CollectorState`, `UsageSection`, `AccountUsage`, `RefreshSection`/`RefreshSession`) + `CollectorStateStore` (ISO-8601 ms dates). Shared by saver and collector. `hiddenSessionIDs` = the collector's refresh sessions, which `DiagnosticsCore` passes to the AGENTS panel as `excludedSessionIDs`. |
| `Diagnostics/CalendarBlock.swift` | SYS `CALENDAR` lines from the collector state's calendar section: next timed event (`NEXT 14:30 Standup (in 22m)`) or `NOW ▸ <title>`, `EVENT` unless trusted, NO SIGNAL / COLLECTOR OFFLINE / staleness. |
| `Diagnostics/UsageBlock.swift` | Saver side of the collector: `CollectorReader` (poll source `COL`, 5 s) and the SYS `CLAUDE.USAGE` lines (meters, STALE, XTRA, COLLECTOR OFFLINE). |
| `Collector/` | The unsandboxed collector executable (`mise run collector:build`): `Collector.swift` run loop + `CollectorSource` protocol + `AtomicFile`, `UsageSource.swift` (keychain naming, discovery, usage endpoint), `TokenRefresh.swift` (`claude -p` refresh, see below), `CalendarSource.swift` (`gws` agenda, see below), `LiveDeps.swift` (`security`, URLSession allowlist, binary resolution, `LiveProcess`), `CollectorLog.swift`, `main.swift`. |
| `Tests/` | Plain `swiftc` test executable (`main.swift` lists suites, `TestKit.swift` assertion helper, one `*Tests.swift` per seam). |
| `Harness/main.swift` | Offscreen render harness: real MatrixView + fake environment -> PNGs. |
| `mise.toml` | `build`, `test`, `snapshot`, `install`, `package`, `preview`, `clean`, `collector:build` tasks, plus a `collector:uninstall` that delegates to `mise.collector.toml`. **Authoritative build commands.** Never put a `bootstrap` task here (it would make a plain `mise bootstrap` install the collector). |
| `mise.collector.toml` | Opt-in collector install (`mise -E collector bootstrap`): the LaunchAgent `dev.mise.matrix-diag-collector`, the idempotent `bootstrap` task (install binary to `~/.local/libexec/matrix-diag/`, log dir, `--init-config`, kickstart) and the real `collector:uninstall [--purge]`. Self-contained so a release zip can ship it without `mise.toml`. |
| `Collector/ConfigInit.swift` | `ConfigInitializer.createIfMissing` behind `matrix-diag-collector --init-config`: config with defaults + random salt, 0600, O_EXCL, never overwrites. |
| `INSTALL.txt` | Install notes shipped **inside the release zip** (quarantine fix for both binaries, saver, collector with mise, uninstall). Keep in step with README's *Installing a release*. |
| `README.md` | Overlay, config keys, what the saver/collector read, release install (mise + manual `launchctl`), build steps, palette. |
| `AGENTS.md` | This file. |

## Build, test, install (no Xcode required)

```bash
mise run test       # swiftc Diagnostics/*.swift Tests/*.swift -> build/tests/DiagnosticsTests, run it (non-zero on failure)
mise run build      # swiftc MatrixView.swift PanelRenderer.swift Diagnostics/*.swift -> Mach-O bundle, ad-hoc signed
mise run snapshot   # offscreen render to build/snapshot/*.png (+ overlay-debug/-stale/-desktop) and a shared-poller/teardown check; TIMING=1 adds a frame-time check
mise run install    # build + copy to ~/Library/Screen Savers + kill the hosts so they reload
mise run package    # build + collector:build, zip one SolarizedMatrix/ folder -> SolarizedMatrix.saver.zip
mise -E collector bootstrap   # opt-in: install/update the collector LaunchAgent (mise.collector.toml)
mise run collector:uninstall  # remove agent, plist, binary, logs, state; --purge also removes the config
```

mise loads LaunchAgents (bootstrap step 5) before the `bootstrap` task (step 9), so on a first install the agent's first run finds no binary; the task kickstarts it at the end. The task runs on every bootstrap and must stay idempotent. `--init-config` is passed `--config "$HOME/..."` explicitly because the binary otherwise resolves home with `getpwuid`, while the uninstall uses `$HOME`.

Release zip (`mise run package`): a single top-level `SolarizedMatrix/` folder (so Archive Utility never makes a folder ending in `.saver`) holding `SolarizedMatrix.saver`, the prebuilt collector, `mise.collector.toml` and `INSTALL.txt`. The collector must be named exactly `matrix-diag-collector` and sit next to `mise.collector.toml`: the bootstrap task installs `./matrix-diag-collector` when present instead of building (there is no `Collector/` in a release). The task fails unless both binaries are signed Mach-O. `mise.collector.toml` must stay self-contained (no dependency on `mise.toml`), and users must `mise trust` it once in the unpacked folder. No standalone install script: the LaunchAgent is declared only in `mise.collector.toml` (README documents the manual `launchctl` equivalent; keep the two in step). Cutting/publishing a release is the `release` skill's job.

`mise.toml` holds the exact `swiftc` invocations. The `build/` directory and compiled `.saver` are gitignored — always build from source; put every build/test artifact under `build/`.

`mise run test` also fails if anything in `Diagnostics/` imports AppKit/ScreenSaver/Cocoa/SwiftUI.

## Source layout rules

- The single-file rule is relaxed: saver = `MatrixView.swift` + `PanelRenderer.swift` (AppKit) + `Diagnostics/*.swift` (core), compiled as one module. The collector executable compiles `Diagnostics/*.swift` + `Collector/*.swift`, so the core must stay UI-free and free of global side effects.
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
4. Draw the overlay (`DiagnosticsCore.layout()` -> `PanelRenderer`) into the **screen** context, never into the buffer, so it stays crisp.

This explicit buffer is necessary because `ScreenSaverView.draw()` does not guarantee backing-store preservation between calls.

## Diagnostic overlay

- Active when: not `isPreview` (no `DiagnosticsCore` is even created in preview), main display, and config `overlay` is not `false`. Decided in `setup()` and on `viewDidMoveToWindow`, logged once per decision: `log show --predicate 'subsystem == "law.jude.SolarizedMatrix"'`.
- Main display = the view's `window.screen` display ID equals `CGMainDisplayID()` (the menu-bar display, `NSScreen.screens.first`). No window/screen yet → main only if there is one screen. The harness forces it via `displayRoleOverride`.
- Config is loaded once per `DiagnosticsCore`, i.e. once per saver activation (each activation builds a fresh `MatrixView`).
- Polling: one `PollerHub.shared` per process runs every source on a background queue (utility QoS, 0.25 s tick checks which sources are due) and publishes an immutable `DiagSnapshot`; the render thread only copies it under a lock. A view leases the hub only while its overlay is active (`decideOverlay`) and releases in `teardown()` (so terminal `didstop` and `stopAnimation` both stop it); the first lease starts the timer, the last release cancels it and drops the engine. The engine/readers come from the first lease's environment.
- Scheduling (`SourceSchedule`): effective interval = `max(base, 20 × last fetch)`; failures back off `base × 2^n` capped at `10 × base`; a section shows a dim `·12s` marker once its data is older than `2 × max(base, 20 × last fetch)` (backoff deliberately excluded, so failing sources show staleness). Bases: sessions 2 s, vitals 5 s, Wi-Fi 30 s, power 60 s.
- Adding a source: see the header comment in `Diagnostics/Poller.swift` (reader in `DiagnosticsEnvironment`, slot in `DiagSnapshot`, one `.make(...)` line in `PollSources.standard` + `order`, its panel lines).
- Token refresh (`Collector/TokenRefresh.swift`, tunables in `TokenRefreshCfg`): the collector never calls the OAuth token endpoint (the HTTP allowlist only permits GET usage). When an account's token is expired or rejected (401/403) **and** its usage data is > 2 h stale, it runs `claude -p` (haiku, trivial prompt, `--safe-mode --tools "" --strict-mcp-config --no-session-persistence --session-id <uuid>`) so Claude Code refreshes its own token, then fetches usage again in the same run. At most once per hour per account; never for network errors or accounts with no token. The child env always has HOME/USER/LOGNAME (from passwd), drops other credentials and `CLAUDE_CODE_*`, and sets `CLAUDE_CONFIG_DIR` only for non-default dirs (setting it for `~/.claude` changes the keychain service name). The session id is recorded and checkpointed to the state file, then the collector waits 6 s (> the saver's 5 s `COL` poll) before launching, so the AGENTS panel hides the run's live session file from the start. Records are kept 7 days.
- Calendar (`Collector/CalendarSource.swift`, tunables in `CalendarCfg`; saver `Diagnostics/CalendarBlock.swift`): source `CALENDAR`, base 5 min, runs `gws calendar +agenda --days 2 --format json` via `ctx.runAgenda` (live: `LiveProcess.capture`). **gws keys its credential encryption on `$USER`; run without it, it deletes the user's credentials.** So the child env always gets HOME/USER/LOGNAME from passwd, the source refuses to launch with an empty user, and tests only ever use a fake agenda runner — never run the real gws with a stripped env. Keeps summary/start/end/allDay (all-day = bare `YYYY-MM-DD` start), drops ended events and the private `calendar`/`location` fields, re-sorts by real time. Failure (`AUTH` from gws's `{"error":…}` JSON, `EXIT n`, `PARSE`, `TIMEOUT`, `NO GWS`, `NO USER`) keeps the last events, sets `calendar.lastError` and backs off; titles are never logged. Saver: no state / no section → `COLLECTOR OFFLINE`; section never fetched → `NEXT NO SIGNAL`; old → `·12m` marker; title only when `networkTrust().isTrusted`, else `EVENT`; truncated to 24 chars.
- Real home comes from `getpwuid(getuid())`; the sandboxed host's `NSHomeDirectory()` is its container. The sandboxed host *can* read `~/.config/matrix-diag/config.json` (verified).
- AGENTS: session files are read on the poller queue (liveness via `proc_pidinfo` there too); a scan that can't list a sessions dir, or finds session files of which none parse, or a failing sessions source shows `AGENT.LINK SIGNAL LOST`, never zero. Private free text (`name`, `waitingFor` command, cwd, config-dir names) never reaches a `Panel`: names go through `DisplayNamer`, dirs through `ProfileTags`. The renderer passes `core.layout(agentsLineCapacity:)` a per-corner line budget: the panel may grow from its corner only until it comes within `logoClearance` of a logo-mask cell in the columns it spans (cached per corner, rebuilt with the mask in `setup()`). That budget is a hard cap in `AgentsPanel.build` (`fit`): priority is totals, then roster rows (attention, active, awaiting), then the dormant and ghost summaries, with `+N more` on the last line when rows are cut. The full totals block (link, NET, six totals, ROSTER heading) is kept only while it still leaves room for the first row (plus `+N more`); below that the totals fold into one line (`RUN · ATT · ACT · AWT · DOR · BG`, red and pulsing while anything needs attention); with a one-line budget the first attention row alone wins.
- Burn-in rotation: `PanelRotation.step = floor(now / interval) mod 4`, anchored to the wall clock rather than the saver start, so short activations don't keep parking the panels in the same corners. `MatrixView.panelRotationInterval` (defaults to `Cfg.panelRotationInterval`) is the harness hook; `mise run snapshot` writes `rotation-<size>-<step>-sys-<corner>.png` at 1728x1117 and 1440x900 with a 5 s interval. At 1440x900 the logo leaves the AGENTS panel only 3–7 lines (the 52-column panel is wider than the gutter beside the logo), so it shows the folded totals line there.
- AGENTS: session files are read on the poller queue (liveness via `proc_pidinfo` there too); a scan that can't list a sessions dir, or finds session files of which none parse, or a failing sessions source shows `AGENT.LINK SIGNAL LOST`, never zero. Private free text (`name`, `waitingFor` command, cwd, config-dir names) never reaches a `Panel`: names go through `DisplayNamer`, dirs through `ProfileTags`. The renderer sets `agentsMaxLines` from the screen height.
- BACKGROUND: per live session, subagents are read from `<its own config dir>/projects/<sanitised cwd>/<sessionId>/subagents/`; only when that path doesn't hold the session does a fallback list every project dir for the session id, and the answer is cached per session in the poll source's `BackgroundAgentScanner` (so it is not re-run every 2 s). Running jobs (`working`/`starting`) and live roster workers are deduplicated by session id and attributed within the same config dir; unmatched ones count only in the total. Missing or malformed background files are zero, never SIGNAL LOST. Rows show `+N BG` (capped at 99).
- Trusted network: `DiagnosticsCore.networkTrust()` is THE decision for anything showing real names (repo names and calendar titles); `core.namer` carries it. Trusted only when the Wi-Fi name is readable, current (last read succeeded, not older than 2× its interval) and in `trustedSSIDs`; unreadable/failing/stale/not-yet-read → `.unverified` (codenames + `NET UNVERIFIED`); empty `trustedSSIDs` → always `.untrusted`, no tag. Never log, print or commit a Wi-Fi name; tests use made-up names.
- Keep the dismissal guarantees: `autoreleasepool` in `draw`, cached attrs (renderer caches its own), terminal `didstop`, `teardown()` releases buffers, the renderer and the poller lease.
- Real-host check without screen capture (the session is locked while the saver runs): `SM_SWIFT_FLAGS="-D SM_FRAME_DUMP" mise run install` makes the saver write `SolarizedMatrix-frame-<pid>-main-150.png` into its container's `Data/tmp` (`~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/tmp/`). Reinstall without the flag afterwards. That build also logs `draw ms p50=… p99=… max=… polling=… net=<trusted|untrusted|unverified>` every 300 frames and `poller decide/teardown leased=… running=… leases=… starts=…`. Frames drawn during a takeover banner are tallied separately (`banner=true`, every 100 such frames), and each of the first banners also dumps `…-banner0.4.png` (opening glitch burst) and `…-banner2.0.png` (steady red wash).
- Attention alerts: the core decides, the renderer animates. `DiagnosticsCore.banner()` is asked once per frame (it advances the banner cycle) at the top of `drawFrame`; the AGENTS `Panel.pulse` and the ATTENTION line's `pulse` are set by `AgentsPanel.build` whenever any live session is in ATTENTION. The banner fires the moment a session reaches 30 s of waiting (not on a wall-clock boundary), then every 60 s, cycling oldest-first; it hides at once when nothing (or not the named session) is waiting. Banner text is `⚠ OPERATOR REQUIRED — <DisplayNamer name> — <category>` (the same trust-aware `core.namer` as the panel: repo name only on a trusted network, else codename); live permission prompts only say `permission prompt`, so the common case reads `APPROVE`. The red rain is done in the buffer (fade toward a dark red + red body glyphs while the banner shows), so it costs nothing extra and washes back out with the trails; the slice glitch is clipped redraws of the frame image during short bursts only. Main display only (same as the overlay).

## Key tunables (`Cfg` in `MatrixView.swift`)

| Constant | Default | Effect |
|----------|---------|--------|
| `fontSize` | `16` | Column width and glyph size |
| `fallMin` / `fallMax` | `0.4` / `1.2` | Row advance per frame (speed range) |
| `fadeAlpha` | `0.018` | Trail length — lower = longer, glowier trails |
| `overlayFontSize` | `15` | Overlay text size (points) |
| `overlayMargin` | `48` | Overlay inset from the screen edge (points) |
| `panelRotationInterval` | `600` | Seconds before both panels step one corner clockwise (burn-in protection) |
| `logoClearance` | `16` | Minimum gap between the AGENTS panel and the logo's glyph cells (points) |
| `PanelLayout.sysColumns` / `agentsColumns` | `34` / `52` | Panel widths in monospace cells (`Diagnostics/Layout.swift`) |
| `AlertsCfg.waitThreshold` / `bannerPeriod` / `bannerDuration` | `30 s` / `60 s` / `4 s` | When the takeover banner fires (`Diagnostics/Alerts.swift`) |
| `pulsePeriod` | `1.2 s` | AGENTS border / ATTENTION row red pulse |
| `bannerFontSize` | `30` | Takeover banner text size (shrinks to fit 90 % of the width) |
| `glitchWashRate` | `1.5` | Red wash speed during the banner (× `fadeAlpha`) |
| `glitchBurst` / `glitchTailBurst` | `0.8 s` / `0.3 s` | Slice-glitch bursts at the banner's start / end |
| `glitchBands` / `glitchShift` | `6` / `70` | Displaced rain slices per burst frame / max shift (points) |
| `AgentsCfg.awaitingWindow` | `15 min` | Idle sessions younger than this are AWAITING, older ones DORMANT (`Diagnostics/AgentsPanel.swift`) |
| `BackgroundCfg.subagentFreshness` | `5 min` | An unfinished subagent counts only if its transcript changed this recently (crash guard) (`Diagnostics/BackgroundAgents.swift`) |
| `BackgroundCfg.fallbackRetry` | `60 s` | How long a failed cwd-fallback lookup for a session is cached before the project dirs are listed again |
| `overlayDebug` | `false` | Show per-source fetch time / effective interval lines (`DBG.VIT 1.2ms @5s`, `F2` = failing). On in `SM_FRAME_DUMP` builds. |

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
