#!/usr/bin/env bash
# check-off-palette.sh — the off-palette half of the static design gate (paired
# with check-contrast.mjs). Components must style with semantic design tokens,
# never raw color literals: a hardcoded color skips dark mode AND the contrast
# gate, so it silently breaks theming and accessibility the moment someone
# toggles the theme. The design-handoff skill copies this to scripts/ and wires
# it into `task lint:design` (see Taskfile.design.yml).
#
# Fails (exit 1) when it finds, under the target dir:
#   1. a Tailwind arbitrary-color utility — bg-[#…], text-[oklch(…)] — including
#      a color literal buried inside an arbitrary value (bg-[linear-gradient(…#hex…)]);
#   2. a literal color ANYWHERE in a style value or SVG/HTML presentation
#      attribute — style={{ color: '#…' }}, fill="#…", stroke="rgb(…)", and a
#      literal buried mid-value (background: "linear-gradient(#111, #222)") —
#      anything that isn't a var(--token).
# Modern color functions count: rgb/rgba, hsl/hsla, hwb, lab/lch, oklab/oklch,
# and color(display-p3 …) are all flagged.
# Bracketed SIZES (border-[1.5px], w-[264px]) are fine — only COLORS are flagged.
# KNOWN false positive: an SVG url(#id) reference whose id happens to be 3+ hex
# chars (fill="url(#abc)") — rename the id or review the flagged line.
#
# BLIND SPOT (a human reviewer must still confirm these are intentional): it does
# NOT flag raw Tailwind palette utilities — bg-black, text-white, text-red-500.
# Some are legitimate (a scrim as bg-black/60, constant on-dark chrome as
# text-white), so flagging them all is noise. If your design forbids raw palette
# colors outright, add a stricter pattern here.
#
# USAGE: check-off-palette.sh [dir]   (default: src)
set -euo pipefail

root="${1:-src}"
exts=(--include='*.ts' --include='*.tsx' --include='*.jsx' --include='*.astro')

# Fail-closed: a typo'd/missing target dir must be an error, not a silent
# "clean" (grep's stderr is suppressed below, so it can't report this itself).
if [ ! -d "$root" ]; then
    echo "check-off-palette: target dir '$root' not found" >&2
    exit 2
fi

# The color-function alternation shared by both patterns: legacy + modern CSS
# color functions (rgba?/hsla?/hwb/lab/lch/oklab/oklch/color(display-p3 …)).
colorfn="rgba?\(|oklch\(|oklab\(|hsla?\(|hwb\(|lab\(|lch\(|color\("

# 1) A Tailwind arbitrary utility whose value contains a color literal anywhere
#    inside the brackets (so a gradient with a hex stop is caught, not just bg-[#…]).
arbitrary="(bg|text|border|fill|stroke|ring|from|via|to|outline|decoration|accent|caret|shadow)-\[[^]]*(#[0-9a-fA-F]{3}|$colorfn)"

# 2) A literal color ANYWHERE in a style value or SVG/HTML presentation
#    attribute — not just immediately after the property name, so a hex stop
#    inside a gradient value (background: "linear-gradient(#111, #222)") is
#    caught too. The value run stops at quote/semicolon boundaries so a match
#    can't leak across declarations. Values that only use var(--token) carry
#    no color literal and pass untouched.
attribute="(color|background|background-color|backgroundColor|background-image|backgroundImage|fill|stroke|stop-color|flood-color|border-color|borderColor|outline-color|outlineColor|caret-color|caretColor)[[:space:]]*[:=][[:space:]]*[\"']?[^\"';]*(#[0-9a-fA-F]{3}|$colorfn)"

if matches=$(grep -rEn "${exts[@]}" "$arbitrary|$attribute" "$root" 2>/dev/null); then
    echo "Off-palette color literals found — use semantic tokens instead:" >&2
    echo "$matches" >&2
    exit 1
fi

echo "Off-palette scan: clean (semantic tokens only)."
