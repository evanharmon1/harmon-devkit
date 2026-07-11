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
#   2. a literal color in a style value or SVG/HTML presentation attribute —
#      style={{ color: '#…' }}, fill="#…", stroke="rgb(…)" — anything that isn't
#      a var(--token).
# Bracketed SIZES (border-[1.5px], w-[264px]) are fine — only COLORS are flagged.
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

# 1) A Tailwind arbitrary utility whose value contains a color literal anywhere
#    inside the brackets (so a gradient with a hex stop is caught, not just bg-[#…]).
arbitrary="(bg|text|border|fill|stroke|ring|from|via|to|outline|decoration|accent|caret|shadow)-\[[^]]*(#[0-9a-fA-F]{3}|rgb\(|rgba\(|oklch\(|oklab\(|hsl\()"

# 2) A literal color in a style value or SVG/HTML presentation attribute — a
#    hex/rgb/oklch after color:/fill=/stroke= etc. (never matches var(--token),
#    which starts with 'v', so token usage passes untouched).
attribute="(color|background|background-color|backgroundColor|fill|stroke|stop-color|flood-color|border-color|borderColor)[[:space:]]*[:=][[:space:]]*[\"']?(#[0-9a-fA-F]{3}|rgb\(|oklch\(|oklab\(|hsl\()"

if matches=$(grep -rEn "${exts[@]}" "$arbitrary|$attribute" "$root" 2>/dev/null); then
    echo "Off-palette color literals found — use semantic tokens instead:" >&2
    echo "$matches" >&2
    exit 1
fi

echo "Off-palette scan: clean (semantic tokens only)."
