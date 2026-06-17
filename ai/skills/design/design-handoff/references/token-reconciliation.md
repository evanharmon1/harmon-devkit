# Token reconciliation: Claude Design `tokens.css` → shadcn `globals.css`

Read this during **Phase 2** of the `design-handoff` skill. The handoff bundle ships
`project/styles/tokens.css` (the design system's primitives — palette, fonts, spacing, radii,
type scale) plus `project/styles/site.css` (brand overrides, sometimes including a few dark-mode
hints). Your job: merge those into the repo's canonical `src/styles/globals.css` in shadcn's
three-layer **OKLCH** form — by **role**, not by name. It is **not** a drop-in; pasting `tokens.css`
into `globals.css` breaks the system. This is the most error-prone step in the whole handoff, which
is why it has its own reference.

## Why you can't paste it in

The bundle's token model and shadcn's have different _shapes_. Four specific things conflict:

1. **Flat vs three-layer.** `tokens.css` is a flat list of primitives (`--color-*`, `--font-*`,
   `--space-*`, `--radius-*` — sometimes with oddities like `--radius-pill: 980px`). shadcn uses
   three layers: `:root`/`.dark` **semantic** tokens, plus an `@theme inline` **reference** layer
   that exposes them to Tailwind as `--color-*` utilities.
2. **Value/palette-named vs role-named.** The bundle names colors by their _value_ (e.g.
   `--color-ink`, `--color-paper`, `--color-terracotta`, or numbered scales). shadcn's `--primary`,
   `--background`, etc. are _roles_ — and roles require `-foreground` partners plus
   `card`/`popover`/`muted`/`accent`/`destructive`/`border`/`input`/`ring`, which the bundle does
   not contain.
3. **Hex/sRGB vs OKLCH.** `tokens.css` tends to emit hex or sRGB. This repo standardizes on
   **OKLCH** because it is perceptually uniform: stepping lightness by a fixed amount _looks_ like a
   fixed step across every hue, which makes dark mode and contrast predictable (in HSL, yellow blows
   out bright while blue stays dark at the same `L`).
4. **Light-only vs dual-mode.** `tokens.css` + `site.css` rarely carry a complete dark scheme.
   shadcn needs both `:root` and `.dark`. **You author/complete `.dark` yourself.**

So: treat `tokens.css` as a **palette + scale source**, read `chats/chat1.md` and `site.css` for each
color's _intended job_, and merge by hand into the shadcn skeleton below. Map by role, never by name —
the bundle's `--color-primary` is a paint value and is **not** necessarily shadcn's `--primary` role.

## The shadcn `globals.css` skeleton (keep this structure intact)

```css
/* Any hosted-font @import MUST sit above this line — see assets-fonts-favicons.md. */
@import "tailwindcss";
@custom-variant dark (&:is(.dark *));

:root {
  --radius: 0.625rem;

  --background: oklch(…); /* page surface */
  --foreground: oklch(…); /* ink on the surface */
  --card: oklch(…);
  --card-foreground: oklch(…);
  --popover: oklch(…);
  --popover-foreground: oklch(…);
  --primary: oklch(…); /* main brand/interaction color */
  --primary-foreground: oklch(…); /* ink/icon on --primary */
  --secondary: oklch(…);
  --secondary-foreground: oklch(…);
  --muted: oklch(…);
  --muted-foreground: oklch(…); /* low-emphasis text */
  --accent: oklch(…);
  --accent-foreground: oklch(…);
  --destructive: oklch(
    …
  ); /* error/danger — usually a red NOT from the brand palette */
  --destructive-foreground: oklch(…);
  --border: oklch(…);
  --input: oklch(…);
  --ring: oklch(…); /* focus ring */
  /* --chart-1..5 and --sidebar-* only if the app uses charts / a sidebar */
}

.dark {
  /* same token names, dark values you author — see "Author the .dark block" below */
}

@theme inline {
  --color-background: var(--background);
  --color-foreground: var(--foreground);
  --color-primary: var(--primary);
  --color-primary-foreground: var(--primary-foreground);
  /* …one --color-* line per semantic token above… */

  --radius-lg: var(--radius);
  --radius-md: calc(var(--radius) - 2px);
  --radius-sm: calc(var(--radius) - 4px);

  /* font roles live here too, pointing at the families you set up under @theme */
  --font-sans: var(--font-sans);
  --font-mono: var(--font-mono);
}
```

The `inline` keyword matters: it makes the `.dark` overrides flow through to the generated utilities
automatically. **Never hard-code a color into `@theme inline`** — every entry must stay a `var(--…)`
reference, or you break dark mode and theming. `@theme inline` is wiring, not values.

## The merge recipe

1. **Map palette → roles by reading intent, not names.** Read `chats/chat1.md` (the design
   conversation) and `site.css` to learn each color's _job_, then place it. Typical mapping:
   - the deepest ink / darkest neutral → `--foreground`
   - the lightest neutral / page background → `--background`
   - the color the design calls the interaction/accent driver → `--primary`
   - a mid neutral → `--border` / `--input`
   - pick `-foreground` partners that clear **4.5:1** against their surface.
2. **Convert to OKLCH.** Express each merged value as `oklch(L C H)` (L 0–1, C 0–~0.4, H 0–360). Keep
   the brand hue (`H`) consistent across related tokens. Keep chroma `C` under ~0.30 so colors stay
   inside the sRGB gamut on ordinary monitors.
3. **Fill the gaps shadcn needs but the bundle lacks.** `card`/`popover` are often `--background` or a
   near neighbor; `muted`/`accent` are subtle neutral surfaces; `destructive` is a red sourced
   outside the brand palette; `ring` is usually the brand/primary hue. Derive these — the bundle
   won't have them.
4. **Author the `.dark` block.** The bundle can't give you a reliable one. The dependable rule: **hold
   the brand accent hue constant** across modes and **invert neutral lightness**. For `--primary`,
   keep the same `H` (and similar `C`), nudging only `L`; for neutrals
   (`--background`/`--foreground`/`--card`/…), flip the lightness so dark surfaces get a low `L` and
   their foregrounds get a high `L`. Re-check contrast in dark mode independently — it is not implied
   by light mode passing.
5. **Lift scalar tokens almost 1:1, but sanitize oddities.** `--radius`, spacing, and type
   sizes/weights map nearly directly. Watch for prototype artifacts: a `--radius-pill: 980px` is a
   "fully rounded" hack — express it as a `rounded-full` usage, don't feed 980px into `--radius`.
6. **Wire fonts.** Font _roles_ (`--font-sans`, `--font-display`, `--font-mono`) go under `@theme`;
   the font _files_ are self-hosted and declared with `@font-face`. See `assets-fonts-favicons.md`
   for the `@import`-order rule that trips everyone up.
7. **Map `--tw-prose-*` if the app renders long-form prose** — see next section.

## Map `--tw-prose-*` (the Typography-plugin override)

If the app uses `@tailwindcss/typography` (any `.prose` content — articles, docs, marketing copy),
the plugin sets its _own_ text colors through `--tw-prose-*` variables in a later cascade layer. At
runtime those **override your semantic tokens**: body copy paints in the plugin's default grey
instead of your `--foreground`, and dark mode silently breaks — even though `globals.css` is correct
and the static contrast gate is green. This is the canonical "tokens pass, render fails" trap; it's
why Phase 5 measures the _rendered_ page (see `accessibility-verification.md`).

Fix it once by pointing the prose variables at your semantic tokens. Because the tokens already flip
in `.dark`, prose then follows dark mode automatically — you don't need `dark:prose-invert`:

```css
.prose {
  --tw-prose-body: var(--foreground);
  --tw-prose-headings: var(--foreground);
  --tw-prose-bold: var(--foreground);
  --tw-prose-links: var(--primary);
  --tw-prose-quotes: var(--foreground);
  --tw-prose-quote-borders: var(--border);
  --tw-prose-bullets: var(--muted-foreground);
  --tw-prose-counters: var(--muted-foreground);
  --tw-prose-captions: var(--muted-foreground);
  --tw-prose-code: var(--foreground);
  --tw-prose-pre-code: var(--card-foreground);
  --tw-prose-pre-bg: var(--card);
  --tw-prose-hr: var(--border);
  --tw-prose-th-borders: var(--border);
  --tw-prose-td-borders: var(--border);
}
```

## Verify the merge before moving on

Run the static contrast gate the skill ships (copied into the repo as `scripts/check-contrast.mjs`
and wired to `task lint:design` — see `assets/check-contrast.mjs` and
`assets/Taskfile.design.yml`):

```bash
node scripts/check-contrast.mjs src/styles/globals.css   # or: task lint:design
```

It parses every foreground/background pair from `:root` and `.dark` and **fails on any sub-AA text
pair, in either theme** (exit 1). Fix every `FAIL` before you implement components. This is necessary
but **not sufficient** — it sees the tokens, not the painted pixel; rendered contrast is measured in
Phase 5.

## Worked example (illustrative)

Say `chats/chat1.md` describes an "antiqued" palette and `tokens.css` carries `--color-ink #1A1C1E`
(deep ink), `--color-terracotta #B8422E` ("the sole interaction driver"), `--color-paper #F7F5F2`
(warm paper), `--color-stone #6C7278` (muted gray). Read by _role_:

- `#1A1C1E` deep ink → `--foreground` (and the basis for a near-black dark `--background`)
- `#F7F5F2` warm paper → `--background` (light) / its inverse for the dark `--foreground`
- `#B8422E` interaction driver → `--primary` (hold this hue constant in `.dark`)
- `#6C7278` muted gray → `--border` / `--muted-foreground`

Convert each to `oklch(...)`; add a `--primary-foreground` light enough to clear 4.5:1 on the
terracotta; synthesize `card`/`popover`/`muted`/`accent`/`destructive`/`ring`; then author `.dark` by
holding the terracotta hue and inverting the neutrals. Run the gate; fix fails; only then move on.

---

**Footnote — multi-platform.** DTCG / Style Dictionary and a structured `tokens.json` are only worth
it if you later need to ship the same tokens to iOS/Android or a second brand. For a single web app,
`globals.css` in shadcn three-layer form **is** the source of truth — don't over-engineer a token
pipeline you don't need yet.
