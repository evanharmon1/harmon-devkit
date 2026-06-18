# Accessibility verification: the dual contrast gate

Read this during **Phase 2** (static check) and **Phase 5** (rendered check). Contrast is verified at
two levels because each catches what the other misses. Always report ratios as **numbers** — never
"looks fine."

## WCAG AA thresholds (the numbers that matter)

- **Normal text:** ≥ **4.5:1**.
- **Large text:** ≥ **3:1**. Large means ≥ **24px** regular **or** ≥ **18.66px bold** (18pt regular /
  14pt bold).
- **UI components & graphical objects** (icons, form-field borders, focus indicators, chart strokes
  that carry meaning): ≥ **3:1** (WCAG 1.4.11).
- **Formula:** `(L1 + 0.05) / (L2 + 0.05)`, where `L` is relative luminance.
- **Do not round before comparing.** 4.499:1 does **not** meet 4.5:1. The gate compares the unrounded
  value.
- **Don't rely on color alone** to convey information or state (WCAG 1.4.1) — pair color with text, an
  icon, or a shape.
- **Light and dark must each pass independently.** Dark passing is never implied by light passing.

## Level 1 — static token contrast (Phase 2)

The skill ships `scripts/check-contrast.mjs` (wired to `task lint:design`). It parses the semantic
tokens from `:root` and `.dark` in `globals.css`, computes the WCAG ratio for every
foreground/background pair, and **fails (exit 1) on any sub-AA text pair in either theme**. Run it
right after reconciliation and fix every `FAIL` before implementing components.

- **Text pairs** — `background`/`foreground`, and `card`/`popover`/`primary`/`secondary`/`muted`/
  `accent`/`destructive` with their `-foreground` partners → held to **4.5**, hard fail.
- **UI pairs** — `border`/`input`/`ring` against `background` → **3.0**, reported as **warnings**
  (an intentionally subtle divider is legitimately faint; judge it in context rather than blocking the
  build).
- It can't know a token's rendered font size, so it holds text pairs to the strict 4.5; large-text
  exceptions are judged on the page in Phase 5.

This level is **necessary but not sufficient** — it sees the tokens, not the pixel that actually
paints.

## Level 2 — rendered contrast (Phase 5)

A runtime layer can override your token _after_ the cascade, so a green static gate can still ship
illegible text. You must measure the **actual painted color** on the running page.

- **The classic culprit:** `@tailwindcss/typography`'s `.prose` sets `--tw-prose-*` in a later cascade
  layer, replacing your `--foreground` with the plugin's grey — so long-form body text and dark-mode
  prose render wrong even though your `foreground`/`muted-foreground` tokens are correct and the static
  gate is green. Fix it by mapping `--tw-prose-*` to your semantic tokens (see
  `token-reconciliation.md`); `dark:prose-invert` and `prose-headings:*` element modifiers are
  partial, narrower fixes.
- **How to measure:**
  - In the browser console, read the **computed** color against the effective background and compute
    the ratio: `getComputedStyle(el).color` vs the painted background; require ≥ 4.5 (≥ 3 for large
    text). Do it for a real element, not a swatch.
  - Or run **axe-core**, **Lighthouse**, or the browser's built-in accessibility audit on each page —
    they read computed colors and report failures with the measured ratio.
- **Measure in both themes**, for every text role: body, headings, muted/meta, links, on-color-block
  text (text on `bg-primary` and friends), and **especially long-form prose / article bodies** — the
  place runtime layers most often override your colors.
- If anything fails, fix it (e.g. pull the override out of the cascade layer so your token wins) and
  **re-measure** before showing the user. Put the measured numbers in your summary.

## Why both levels, never just one

- **Static alone** misses runtime overrides like the `.prose` trap — it can pass while the page is
  broken.
- **Rendered alone** misses palette regressions the static gate would catch on _every_ build, and only
  covers the pages/states you happened to screenshot.

Keep both: static is the always-on regression guard; rendered is the truth check on real pixels.

## While you're on the running page (cheap wins a novice won't think of)

Not part of the contrast gate, but quick to confirm during Phase 5 and easy to miss:

- **Focus visible** on every interactive element (the `ring`), and everything reachable by keyboard
  (Tab/Shift-Tab).
- **Hit targets** ≥ 24×24 CSS px (WCAG 2.5.8); aim for ≥ 44px for primary touch targets.
- **Images have `alt`**; purely decorative images use `alt=""`.
- **Form inputs have associated `<label>`s** (or `aria-label`).
- **Respect `prefers-reduced-motion`** — gate non-essential animation behind it.
