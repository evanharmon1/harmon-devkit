# Token Reconciliation: Claude Design export → shadcn `globals.css`

Read this during **step 2** of the `design-handoff` skill. It explains how to merge the design's token export into this repo's `src/styles/globals.css` correctly. The export is **not** a drop-in; pasting it verbatim breaks the system.

## Why you can't paste the export in

The two token models have different _shapes_, and four specific things conflict:

1. **Flat vs three-layer.** The export (`task export:design` → `.design/theme.scratch.css`) emits a single flat `@theme { … }` block of primitive values. shadcn uses three layers: `:root`/`.dark` semantic tokens + an `@theme inline` reference layer.
2. **Value-named vs role-named.** The export's `primary`/`secondary`/`tertiary`/`neutral` are _palette_ names (a value). shadcn's `--primary`, `--background`, etc. are _roles_, and roles require `-foreground` pairs plus `card`/`popover`/`muted`/`accent`/`destructive`/`border`/`input`/`ring` that the export doesn't have.
3. **Hex vs OKLCH.** The export tends to emit hex/sRGB. This repo standardizes on **OKLCH** (perceptually uniform — makes dark mode and contrast predictable).
4. **Light-only vs dual-mode.** The export has **no dark mode** (the DESIGN.md token schema has no scheme dimension). shadcn needs both `:root` and `.dark`. **You author `.dark` yourself.**

So: treat the export as a **palette source**, read the `DESIGN.md` prose for _role intent_, and merge by hand into the shadcn skeleton.

## The shadcn `globals.css` skeleton (keep this intact)

```css
@import 'tailwindcss';
@custom-variant dark (&:is(.dark *));

:root {
  --radius: 0.625rem;
  --background: oklch(…); /* surface */
  --foreground: oklch(…); /* text/ink on surface */
  --primary: oklch(…); /* main interaction/brand color */
  --primary-foreground: oklch(…); /* text/icon on --primary */
  --secondary: oklch(…);
  --secondary-foreground: oklch(…);
  --muted: oklch(…);
  --muted-foreground: oklch(…);
  --accent: oklch(…);
  --accent-foreground: oklch(…);
  --destructive: oklch(…);
  --border: oklch(…);
  --input: oklch(…);
  --ring: oklch(…);
  --card: oklch(…);
  --card-foreground: oklch(…);
  --popover: oklch(…);
  --popover-foreground: oklch(…);
  /* chart-* and sidebar-* if used */
}

.dark {
  /* same token names, dark values you author (see below) */
}

@theme inline {
  --color-background: var(--background);
  --color-foreground: var(--foreground);
  --color-primary: var(--primary);
  --color-primary-foreground: var(--primary-foreground);
  /* …one --color-* reference per semantic token… */
  --radius-lg: var(--radius);
  /* font roles also live here, e.g. --font-sans, set under @theme */
}
```

The `inline` keyword matters: it makes the `.dark` overrides flow through to the generated utilities automatically. **Never hard-code a color value into `@theme inline`** — it must stay a `var(--…)` reference, or you break dark mode and theming.

## The merge recipe

1. **Map palette → roles by reading the prose.** Don't map by name (the export's `primary` ≠ shadcn's `--primary`). Read `DESIGN.md`'s Colors/Overview prose to learn each color's _job_, then place it. Typical mapping:
   - the deep ink / darkest neutral → `--foreground`
   - the lightest neutral / page background → `--background`
   - the color the prose calls the interaction/accent driver → `--primary`
   - a mid neutral → `--border` / `--input`
   - pick `-foreground` partners that hit **4.5:1** contrast against their surface.
2. **Convert to OKLCH.** Express the merged values as `oklch(L C H)`. Keep the brand hue (`H`) consistent across related tokens.
3. **Fill the gaps shadcn needs but the export lacks** — `card`/`popover` (often = `--background` or a near neighbor), `muted`/`accent` (subtle neutral surfaces), `destructive` (a red not from the brand palette), `ring` (usually the brand/primary hue). Derive these from the palette; the export won't have them.
4. **Author the `.dark` block.** The export can't give you this. A reliable rule: **keep the brand accent hue constant** across modes and **invert neutral lightness** — i.e. for `--primary` use the same `H` (and similar `C`), only nudging `L`; for neutrals (`--background`/`--foreground`/`--card`/etc.) flip the lightness so dark surfaces get dark `L` and their foregrounds get light `L`. Re-check contrast in dark mode separately.
5. **Lift scalar tokens more directly.** `--radius`, spacing, and font sizes/weights from the export can map almost 1:1 — less reconciliation needed than color.
6. **Wire fonts.** Put font _files_ (self-hosted OFL/Apache `.woff2`) referenced via `@font-face`, and font _roles_ (`--font-sans`, `--font-display`, `--font-mono`) under `@theme`. Confirm any hosted-font `@import` sits **above** `@import "tailwindcss"`.

## Worked example (illustrative)

Say `DESIGN.md` describes an "antiqued" palette: `primary #1A1C1E` (deep ink), `tertiary #B8422E` ("the sole interaction driver"), `neutral #F7F5F2` (warm paper), `secondary #6C7278` (muted gray). Read by _role_:

- `#1A1C1E` deep ink → `--foreground` (and a near-black for dark `--background`)
- `#F7F5F2` warm paper → `--background` (light) / its inverse for dark `--foreground`
- `#B8422E` interaction driver → `--primary` (keep this hue constant in `.dark`)
- `#6C7278` muted gray → `--border` / `--muted-foreground`

Then convert each to `oklch(...)`, add `--primary-foreground` (a light tone meeting 4.5:1 on the terracotta), synthesize `card`/`popover`/`muted`/`accent`/`destructive`/`ring`, and author the `.dark` block by holding the terracotta hue and inverting the neutrals.

## After merging

- Run `task lint:design` — confirms `DESIGN.md` token refs resolve and flags WCAG AA contrast failures.
- For repeatable future syncs, prefer regenerating `task export:design` to a _scratch_ file and re-merging deltas over hand-diffing the whole file. Never let the export write directly into `globals.css`.
- If you ever need a true multi-platform pipeline (iOS/Android, or a second brand), that's the trigger to promote `.design/tokens.json` (DTCG) to canonical and compile with Style Dictionary.
