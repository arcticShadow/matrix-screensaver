#!/usr/bin/env python3
"""Generate assets/matrix-preview.svg — the animated README preview.

The README needs to *show* the screensaver running without shipping a video
file. This emits a self-contained, CSS-animated SVG that GitHub renders and
animates inline: a Matrix-style code rain in the exact Solarized palette and
glyph set used by MatrixView.swift, plus the breathing Jude-logo "ghost".

"The code way" — no .mp4, no .gif. Just vectors + SMIL animation. Every column
is a falling <g> with its own <animateTransform> translate loop; per-column
dur + (negative) begin give the staggered, never-synced rain. SMIL is used over
CSS @keyframes because it is the most reliable animation method when GitHub
renders the SVG as an <img>.

Keep the palette / glyph / logo constants below in sync with the `Cfg` struct
and glyph sets in MatrixView.swift — this is a portrait of that file.

Usage:
    python3 tools/gen_preview.py > assets/matrix-preview.svg
    # or, the repo way:
    mise run preview
"""

import random
from xml.sax.saxutils import escape

# ── Canvas ──────────────────────────────────────────────────────────────────
W, H = 800, 450     # 16:9 preview surface
CELL = 16           # glyph cell / font size — mirrors Cfg.fontSize
SEED = 0x5031A7     # fixed seed → byte-for-byte reproducible output
OVER = 360          # vertical overscan ≥ tallest trail, so ONE keyframe fits all
END = H + 24        # head's exit point below the bottom edge

# ── Solarized palette (mirrors MatrixView.swift) ────────────────────────────
BG = "#002b36"                              # base03 — background
HEAD = "#eee8d5"                            # base3  — bright head glyph
STREAM = ["#2aa198", "#268bd2", "#859900",  # cyan   blue   green
          "#6c71c4", "#b58900"]             # violet yellow — accent-per-column
LOGO = "#6ef0c2"                            # logoStream teal-green — ghost mark

# ── Glyph sets (mirror bodyGlyphs in MatrixView.swift) ──────────────────────
SYMS = list("{}[]()<>=!+-*/%&|^~?:;.,0123456789#$@\\_'`\"")
KATA = [chr(c) for c in range(0xFF66, 0xFF9E)]   # half-width katakana
BODY = SYMS + KATA

# ── Jude logo paths (from judeSVG in MatrixView.swift, viewBox 0 0 51 51) ───
LOGO_PATHS = [
    "M50.1463 31.968L50.1462 33.7534L46.1633 35.745C42.1765 37.7384 39.7512 41.5076 39.7512 45.7102L39.7512 49.2893L38.0232 50.1533L25.9001 44.0916L25.9 40.9181C25.9 35.3931 29.4187 30.2087 35.095 27.3704L38.0232 25.9063L50.1463 31.968Z",
    "M5.29934e-07 31.968L3.30989e-05 33.7534L3.98294 35.745C7.96978 37.7384 10.3951 41.5076 10.3951 45.7102L10.3951 49.2893L12.1231 50.1533L24.2462 44.0916L24.2462 40.9181C24.2462 35.3931 20.7275 30.2087 15.0513 27.3704L12.1231 25.9063L5.29934e-07 31.968Z",
    "M0 18.1853L3.24129e-05 16.3999L3.98294 14.4083C7.96978 12.4149 10.3951 8.64566 10.3951 4.44307L10.3951 0.864046L12.1231 2.38419e-06L24.2462 6.06174L24.2462 9.2352C24.2462 14.7603 20.7275 19.9446 15.0513 22.7829L12.1231 24.247L0 18.1853Z",
    "M50.1463 18.1853L50.1462 16.3999L46.1633 14.4083C42.1765 12.4149 39.7512 8.64565 39.7512 4.44307L39.7511 0.864044L38.0232 0L25.9001 6.06174L25.9 9.2352C25.9 14.7603 29.4187 19.9446 35.095 22.7829L38.0232 24.247L50.1463 18.1853Z",
]

rng = random.Random(SEED)


def esc(ch):
    """XML-escape a glyph, including quotes (the body set contains < > & " ')."""
    return escape(ch, {'"': "&quot;", "'": "&apos;"})


def num(x):
    """Compact number: trim trailing zeros so the file stays small."""
    return f"{x:.3f}".rstrip("0").rstrip(".")


def drop(x, color):
    """One falling stream at column-centre x: bright head + fading colour trail.

    Outer <g> holds the static column position; the inner <g> carries the SMIL
    translate that loops it top→bottom. A negative `begin` starts it mid-fall so
    the field is full the instant the SVG loads.
    """
    length = rng.randint(6, 22)                 # glyphs in this stream
    dur = rng.uniform(2.8, 6.5)                 # seconds for a full top→bottom fall
    begin = -rng.uniform(0, dur)               # negative → already mid-fall at load
    rows = [f'<g transform="translate({num(x)},0)"><g>',
            f'<animateTransform attributeName="transform" type="translate" '
            f'values="0 {-OVER};0 {END}" dur="{num(dur)}s" '
            f'begin="{num(begin)}s" repeatCount="indefinite"/>']
    # k=0 is the leading head glyph (base3); k>=1 trails upward, fading out.
    rows.append(f'<text class="h">{esc(rng.choice(BODY))}</text>')
    for k in range(1, length):
        op = max(0.05, 0.85 * (1 - k / length))
        rows.append(f'<text y="{-k * CELL}" fill="{color}" '
                    f'opacity="{op:.2f}">{esc(rng.choice(BODY))}</text>')
    rows.append("</g></g>")
    return "".join(rows)


def build():
    cols = W // CELL
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" '
        f'width="{W}" height="{H}" role="img" '
        f'aria-label="Solarized Matrix screensaver — animated preview">',
        # Static styling only (reliable in <img>-rendered SVG); motion is SMIL.
        # Column x comes from each group's translate (+CELL/2), so
        # text-anchor:middle centres the glyph in its cell.
        "<style>",
        "text{font-family:'SF Mono','JetBrains Mono',Menlo,Consolas,"
        "ui-monospace,monospace;font-size:16px;font-weight:600;"
        "text-anchor:middle;dominant-baseline:middle}",
        f".h{{fill:{HEAD}}}",
        "</style>",
        f'<rect width="{W}" height="{H}" fill="{BG}"/>',
        '<filter id="soft" x="-20%" y="-20%" width="140%" height="140%">'
        '<feGaussianBlur stdDeviation="1.1"/></filter>',
    ]

    # Rain. Every column gets a primary drop (accent-colour-per-column, echoing
    # the Swift look); ~45% also get a second, independently-phased stream so the
    # field reads as full and busy rather than one-drop-per-column sparse.
    for i in range(cols):
        x = i * CELL + CELL / 2
        out.append(drop(x, STREAM[i % len(STREAM)]))
        if rng.random() < 0.45:
            out.append(drop(x, rng.choice(STREAM)))

    # Breathing Jude-logo ghost, centred, ~50% of the short edge. Eases in,
    # holds, and fades back out — the mark breathing in and out of the rain
    # (cf. the fade envelope in MatrixView.swift). Starts hidden, mid-cycle.
    scale = (min(W, H) * 0.5) / 51
    lx = W / 2 - 51 * scale / 2
    ly = H / 2 - 51 * scale / 2
    out.append(f'<g filter="url(#soft)" opacity="0" '
               f'transform="translate({num(lx)},{num(ly)}) scale({num(scale)})">')
    out.append('<animate attributeName="opacity" '
               'values="0;0;0.18;0.18;0;0" keyTimes="0;0.16;0.46;0.6;0.9;1" '
               'dur="13s" begin="-4s" repeatCount="indefinite"/>')
    for p in LOGO_PATHS:
        out.append(f'<path d="{p}" fill="{LOGO}"/>')
    out.append("</g>")

    out.append("</svg>")
    return "\n".join(out)


if __name__ == "__main__":
    print(build())
