# The `/brand` page: a living style guide

Read this during **Phase 3**. `/brand` is a real, maintained **route** in the app — not a throwaway
doc. It is the public, at-a-glance companion to `DESIGN.md` (intent prose) and `globals.css` (runtime
tokens): the place the brand, design system, and style guide are shown and, where appropriate, made
downloadable.

## It must never drift — read the tokens, don't retype them

The cardinal rule: `/brand` renders **from the same CSS variables the app uses**, via
`getComputedStyle` — it never hardcodes hex values copied out of `globals.css`. A swatch reads the
live token and displays it:

```ts
const v = getComputedStyle(document.documentElement)
  .getPropertyValue("--primary")
  .trim();
// render the swatch from `v`, and show both the oklch() string and a computed hex
```

The spacing, radius, and shadow specimens read their tokens the same way. Because the page reads
**live** tokens, it tracks the theme toggle automatically and can never disagree with `globals.css`.
Whenever tokens, type, or brand rules change, update `/brand` **in the same change** so it stays in
lockstep with `DESIGN.md` / `globals.css`. If a `/brand` route already exists, reconcile into it
rather than duplicating.

## Decide how far to take it (asked up front)

`/brand` can range from a single-page style guide to a full brand/press kit with downloadable
collateral. The right scope depends on the handoff, so it's settled **up front in the intake batch**
(see SKILL.md, "Gather decisions up front") rather than mid-build — by the time you reach Phase 3 you
already have the answer. Offer the tiers below, defaulting to the core style guide and adding
collateral the user opts into. A `.pptx` deck and email templates are wasted effort for a small feature
handoff and exactly right for a brand launch — let the user decide. If the scope somehow wasn't
captured during intake, ask before building `/brand` rather than assuming.

## Tier 1 — the core living style guide (always)

A real route that explains and demonstrates the system:

- **Overview** — the design's name, a short brand explanation, voice/tone in a sentence or two.
- **Color** — palette swatches showing **both `oklch(...)` and hex** for each semantic token, grouped
  by role, with the foreground-on-surface pairings and their **measured contrast ratios**.
- **Type** — specimens of each family/role and the full type scale (sizes, weights, line-heights) with
  real sample text.
- **Spacing / radius / shadow** scales rendered as visual specimens (read from tokens).
- **Logo & monogram** lockups, with clear-space and minimum-size rules.
- **Component specimens** — buttons, form elements, and any custom components the design introduced,
  shown in **all states** (default, hover, focus, active, disabled, loading, error, empty) so the page
  doubles as a visual-regression reference.
- A **light/dark toggle** wired to the `.dark` class so every specimen can be checked in both themes.

Link it discreetly — e.g. from the footer.

## Tier 2 — downloadable brand / press kit (opt-in)

- Downloadable logos, wordmarks, monograms, and favicons (SVG + PNG) with usage do's and don'ts.
- A press/brand-kit bundle (zip) of the above for external use.

## Tier 3 — collateral (opt-in, "when it makes sense")

Generate only what the user asks for:

- **Social media** — example posts/templates for LinkedIn, Instagram, Facebook, Bluesky, etc.
- **Print** — flyers, business cards, and the like, downloadable as PDFs.
- **Email** — templates and snippets, downloadable as HTML/CSS bundles, preferably built with **React
  Email**.
- **Slides** — an example deck template in `.pptx` that is genuinely **editable** (real text and
  shapes), not a flat, image-based deck.

These tiers map onto the design suite's artifact taxonomy in `ai/skills/README.md` (Tokens /
Components / Pages & Templates / Assets / Collateral), so `/brand` stays aligned with the broader
design-suite roadmap.

## Where `/brand` lives per framework

- **TanStack Router** — file-based route at `src/routes/brand.tsx`.
- **React Router / plain React** — a normal route/component mounted at `/brand`.
- **Astro 6** — `src/pages/brand.astro`. Static specimens (swatches, type, scales) render as `.astro`
  with zero JS; the **live/interactive** pieces — the theme toggle, stateful component demos, and the
  `getComputedStyle` swatch readouts (which run client-side) — are React **islands** with the right
  `client:*` directive (see `components-and-states.md`).

## Keep it in lockstep

`/brand` is a standing deliverable, listed in the skill's Definition of Done. Treat "update `/brand`"
as part of **any** change that touches tokens, type, components, or brand assets — it explains the
system and must never fall behind `globals.css` / `DESIGN.md`.
