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

`/brand` always includes the **core style guide** (Tier 1). The two opt-in layers — the **brand/press
kit** (Tier 2) and **marketing collateral** (Tier 3) — are settled **up front in the intake batch** (see
SKILL.md, "Gather decisions up front") rather than mid-build, so by Phase 3 you already have the answer.
Ask with `AskUserQuestion`:

1. **Scope (multiSelect):** "Beyond the core style guide, what should `/brand` deliver?" — options
   **Brand/press kit** and **Marketing collateral**. Selecting neither means core-only; choosing both is
   fine.
2. **Collateral groups (only if collateral was chosen, multiSelect):** "Which collateral groups?" — offer
   the four buckets from Tier 3 (Social & web, Email, Print, Presentations & documents). A question caps
   at four options, so the buckets fill the slots and the auto **Other** option (free text) captures the
   long tail (motion/video, merch, app-store, audio). For each chosen group, confirm the specifics —
   which platforms, sizes, and formats — before generating.

Default to core-only and add only what the user opts into: a `.pptx` deck and email templates are wasted
effort for a small feature handoff and exactly right for a brand launch. If scope somehow wasn't captured
during intake, ask before building `/brand` rather than assuming.

## Tier 1 — the core living style guide (always)

A real, comprehensive route that both **documents** and **demonstrates** the system. Err toward
completeness: every token, every component, every state. Build every specimen from the **live tokens**
(`getComputedStyle`) so the page can't drift, and give it a stable, queryable structure (anchors,
`data-*` hooks, a machine-readable token export) so it doubles as a source of truth for automation,
visual-regression, and contrast auditing — see "Make it automation-friendly" below. When in doubt,
include it; this is the one place where more is better.

### Foundations

- **Brand & voice** — the design's name, tagline, and a one-line positioning statement; 3–5
  personality adjectives; voice & tone with two or three do/don't microcopy examples; capitalization,
  terminology, and how to refer to the product; date/number formatting conventions.
- **Color** — for **every** semantic token (`background`, `foreground`, `card`/`card-foreground`,
  `popover`/`popover-foreground`, `primary`/`primary-foreground`, `secondary`/`secondary-foreground`,
  `muted`/`muted-foreground`, `accent`/`accent-foreground`, `destructive`/`destructive-foreground`,
  `border`, `input`, `ring`, `chart-1..5`, `sidebar-*`): a swatch with the token name, the live
  `oklch(...)` value, the computed hex, and a one-line "use for…" note. Show every foreground-on-surface
  pairing with its **measured contrast ratio** and an AA/AAA badge. Include any primitive scales, status
  colors (success/warning/info), and gradients the design uses. Show light and dark (side by side or via
  the toggle).
- **Typography** — for each font role (`--font-sans`/`--font-display`/`--font-mono`): the resolved
  family, the fallback stack, the source/license, the weight range, and a live specimen (pangram plus a
  paragraph). The **full type scale**: every step with rem/px size, line-height, letter-spacing, weight,
  and sample text. Rendered `h1`–`h6`, body, lead, small/caption, blockquote, inline `code`, links, and
  ordered/unordered lists. A long-form **`.prose` block** to prove the `--tw-prose-*` mapping holds in
  both themes. Note any responsive `clamp()` behavior.
- **Spacing** — the full scale, each step with rem/px and a visual bar.
- **Sizing & layout** — container max-widths, the breakpoints (name + px), grid columns/gutters, and the
  `max-w-*` scale; note what reflows at each breakpoint.
- **Radius** — each radius token shown on a sample shape.
- **Shadow / elevation** — each shadow token on a sample card, labeled with its elevation level and a
  "use for…" note.
- **Borders, opacity, z-index** — any scales the system defines.
- **Motion** — durations, easings, and named transitions/keyframes with live examples; the
  `prefers-reduced-motion` behavior.
- **Iconography** — the icon set (Lucide), default size(s), stroke width, and a grid of the icons
  actually used; the rules (named imports, one set only).

### Components & patterns

- **Every component** the system ships **and** every custom one the design introduced. For each: all
  **variants** and **sizes**, and all **states** — default, hover, focus-visible, active, disabled,
  loading, error, empty, and where relevant selected/checked/indeterminate/read-only. Add a short usage
  note and a copyable code snippet per component.
- Cover the common families so nothing is missed: **actions** (button variants × sizes, icon button,
  link); **forms** (input, textarea, select, combobox, checkbox, radio, switch, slider, date/file
  inputs — each with label, helper text, and validation/error states); **feedback** (alert, toast,
  dialog/sheet, tooltip, popover, badge, progress, skeleton); **navigation** (tabs, breadcrumbs,
  pagination, menu/dropdown, sidebar); **data display** (table, card, avatar, accordion, list).
- **Patterns/compositions** the design defines — page header, form layout, empty state, card grid — as
  small live examples.

### Brand assets (previewed here; downloadable bundles are Tier 2)

- **Logo system** — full lockup, monogram/mark, and wordmark in light, dark, and single-color variants;
  clear-space and minimum-size rules; and a **misuse** row (don't stretch, recolor, rotate, or add
  effects).
- **Favicon & app icons** previewed at real sizes.
- **Imagery & illustration** direction, and background patterns/textures if the design uses them.

### Make it automation-friendly (well-specced for tooling)

This route is also a machine source of truth, so give it a stable, queryable structure:

- **Stable deep-link anchors** — an `id` on every section and every specimen (e.g. `#color-primary`,
  `#type-scale`, `#component-button--destructive`). Don't reorder or rename casually.
- **`data-*` hooks** on every specimen so Playwright / visual-regression can target exact elements:
  e.g. `data-brand-token="--primary"` on a swatch, and
  `data-brand-specimen="button" data-variant="destructive" data-state="hover"` on a component example.
  Put each specimen in its own labeled, screenshot-isolatable container.
- **A machine-readable token export embedded in the page**, generated from the live tokens
  (`getComputedStyle`) so it never drifts — e.g.
  `<script type="application/json" id="brand-tokens">…</script>` holding every token's name, `oklch`,
  hex, and (for pairs) contrast ratio, plus the breakpoints, type scale, and component inventory.
  Optionally also serve it at `/brand.json` for heavier automation.
- **Keep the DOM semantic and stable** (correct heading order, consistent specimen markup) so scraping
  and visual-regression stay reliable across builds. Every specimen renders from tokens (never
  hardcoded) and works under the light/dark toggle and at every breakpoint — so one page powers token
  docs, visual-regression, and contrast auditing at once.

### Always-on essentials

- A **light/dark toggle** wired to the `.dark` class so every specimen is checkable in both themes.
- An **accessibility note** — the target (WCAG 2.2 AA), the contrast commitment, focus/keyboard support,
  and reduced-motion.
- Link the route discreetly — e.g. from the footer.

## Tier 2 — downloadable brand / press kit (opt-in)

The brand/press kit is the **external-facing** counterpart to the style guide: the assets, metadata,
and copy a partner, journalist, vendor, or downstream system needs to represent the brand correctly.
Build it as both a human page **and** a machine-consumable endpoint, generated from the same tokens and
source as `globals.css`/`DESIGN.md` so it never drifts.

### Contents

- **Logo suite** — primary lockup, monogram/mark, and wordmark; horizontal and stacked variants; in
  full-color, single-color (black, white), and reversed (for dark backgrounds). Each as **SVG**
  (primary) and transparent **PNG** at several resolutions; add PDF/EPS when print vendors need them.
  Include the clear-space rule, minimum size, and a misuse row.
- **Favicon & app-icon set** — `favicon.ico`, `favicon.svg`, `apple-touch-icon.png` (180), PWA icons
  (192/512 plus a maskable), and `site.webmanifest` (the set generated in `assets-fonts-favicons.md`).
- **Color** — the palette as swatches with **hex, oklch, RGB, and CMYK** (add Pantone/spot for print),
  plus a downloadable Adobe swatch file (`.ase`) and a JSON block.
- **Typography** — the brand font files (or links and license), the fallback stack, and a one-page
  type spec (families, roles, scale, weights).
- **Brand guidelines** — a downloadable **PDF brand book** (logo usage, color, type, spacing, voice,
  do's and don'ts): the portable form of Tier 1.
- **Boilerplate copy** — company/product descriptions in short (~25 words), medium (~50), and long
  (~100) forms; the tagline; founder/team bios; key facts (founded, location, category); and a
  press/contact email.
- **Imagery** — approved hero/product shots, team/founder photos, and any brand illustration, at both
  web and print resolution, with usage and credit notes.
- **Links & license** — canonical site, social handles, press contact, and a short usage statement
  (what third parties may and may not do — e.g. don't alter or recolor the logo).

### Packaging & download

- A single **`brand-kit.zip`** at a stable URL, organized into `logo/`, `favicon/`, `color/`, `type/`,
  `guidelines/`, `images/`, and `copy/`, with a `README` manifest at the root.
- A human **press-kit page** (e.g. `/brand/press-kit`, or a section of `/brand`) that previews
  everything and links each asset plus the full zip — with the same stable anchors and `data-*` hooks
  as Tier 1.

### As an automation endpoint

Expose the kit so other systems and agents can consume it programmatically, not just humans:

- **`/brand/kit.json`** (or `/press-kit.json`) — a machine-readable **manifest** carrying a `version`
  and `updatedAt`, every asset with its `name`, `description`, and per-format / per-resolution URLs, the
  full color set (hex/oklch/rgb/cmyk/pantone), font names and license URLs, the boilerplate copy
  variants, social links, and the press contact. Generate it from the same source as the tokens so it
  can't drift.
- **Stable, versioned asset URLs** — each logo/icon/image at a durable path (e.g. `/brand/assets/...`),
  and `brand-kit.zip` at a fixed URL automations can fetch.
- **CORS** — if the JSON or zip will be fetched cross-origin (partner sites, agents), enable permissive
  CORS on those endpoints.
- Keep the manifest the single thing other tools read, and render the page from it — so page and
  endpoint can never disagree. This extends Tier 1's automation structure outward: Tier 1's
  `#brand-tokens` JSON is the _internal_ token truth; this manifest is the _external_ asset/metadata
  truth.

## Tier 3 — collateral (opt-in, chosen by group)

Collateral spans dozens of artifact types, so the user picks **groups** during intake (see "Decide how
far to take it"). Generate only the selected groups, build every piece from the same tokens so it stays
on-brand, and confirm the specifics (which platforms, sizes, formats) before producing. The four
selectable buckets:

- **Social & web** — social profile art (avatar, cover/banner), post/story templates sized per platform
  (LinkedIn, Instagram, X, Facebook, Bluesky, TikTok, YouTube thumbnails), and podcast cover art;
  OG/share cards (static or dynamically generated); display/banner ads in standard IAB sizes. Export at
  the correct per-platform dimensions.
- **Email** — transactional and marketing templates, a newsletter layout, and an email signature; built
  with **React Email**, shipped as HTML/CSS bundles, and tested against major clients (Gmail, Outlook,
  Apple Mail).
- **Print** — business cards, letterhead, flyers, posters, brochures, stickers, and signage as
  **print-ready PDFs** (CMYK, 300dpi, with bleed and crop marks).
- **Presentations & documents** — an **editable** `.pptx` (and/or Google Slides) deck with real text and
  shapes (never a flat, image-based deck), a pitch deck, and a one-pager/sales sheet; plus document
  templates (proposals, reports, case studies, invoices, résumé) for Word / Google Docs / Notion.

Pick **Other** and name it for the long tail:

- **Motion & video** — animated logo (Lottie), social-video templates, intro/outro stingers, animated
  GIFs.
- **Merch & environmental** — apparel, stickers, tote bags, mugs; event/booth banners; office and
  wayfinding signage.
- **Product & app-store** — app-store screenshots and listing graphics, in-app illustration and
  empty-state art, onboarding graphics.
- **Audio & bespoke** — audio-brand stings, sonic logos, or anything one-off.

These groups map onto the design suite's artifact taxonomy in `ai/skills/README.md` (Tokens /
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
