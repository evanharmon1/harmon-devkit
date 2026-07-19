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
SKILL.md Phase 0, "Decide up front") rather than mid-build, so by Phase 3 you already have the answer.
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

> Coverage check: run this section past `deliverables-checklist.md` so no token category (chart palette,
> gradients, named z-index layers, named animations, …) is forgotten.

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

### Brand assets — logos and icons, previewed **and downloadable** (always)

Tier 1 ships **real, downloadable logo and icon files**, not just previews. This is the common failure
mode: favicons get generated (they're wired into the app) while logos stay as inline JSX or a single
SVG nobody can grab — so the first time the user has to upload a logo to Stripe, Polar, GitHub,
LinkedIn, or a README, there's no file to give. A core-only `/brand` must still answer "where do I
download the logo?" Tier 2 extends this into a full press kit; it does not own the basics.

- **Logo system** — full lockup, monogram/mark, and wordmark in light, dark, and single-color variants;
  clear-space and minimum-size rules; and a **misuse** row (don't stretch, recolor, rotate, or add
  effects).
- **Favicon & app icons** previewed at real sizes, with the generated set downloadable too.
- **Imagery & illustration** direction, and background patterns/textures if the design uses them.

**No logo in the bundle? Say so — don't silently skip the section.** If the design never produced a
mark, surface it in the chat and offer the options (derive a monogram/wordmark from the brand font and
tokens, or leave a placeholder and flag it). Silently shipping a `/brand` page with no logo section is
how this gap goes unnoticed until launch day.

#### The download matrix (always generated)

Every variant ships as **SVG** (primary, scalable, `currentColor` where apt) plus **transparent PNG** at
a fixed size ladder, so any upload target is covered without re-exporting. Ship each file with a visible
**download button** next to its preview, the **exact pixel dimensions labeled**, and a
`logos.zip` (mark + lockup + wordmark, all variants and sizes) for grabbing everything at once.

| Asset                        | Formats           | Sizes                                | Covers                                                                                      |
| ---------------------------- | ----------------- | ------------------------------------ | ------------------------------------------------------------------------------------------- |
| **Square mark** (icon/avatar) | SVG + PNG         | 64, 128, 256, 512, 1024 px           | Stripe/Polar brand icon (≥128), GitHub org avatar (≥500), LinkedIn logo (300), X (400), Instagram (320+), YouTube channel icon (800), Slack/Discord (512), npm/docs favicons |
| **Horizontal lockup**        | SVG + PNG         | 400, 800, 1600 px wide               | READMEs (~600–800 @2x), docs headers, partner/vendor "send us your logo" asks, email signatures |
| **Wordmark**                 | SVG + PNG         | 400, 800, 1600 px wide               | Text-only contexts, footers, press mentions                                                   |
| **Favicon / app icons**      | ICO, SVG, PNG     | the generated set (16–512 + maskable) | Browsers, iOS/Android home screens, PWA                                                       |

Rules that make the files actually usable:

- **Three color variants** per asset: full-color, **reversed/white** (for dark backgrounds), and
  **single-color black** — platforms and print vendors ask for all three, and a full-color-only kit
  gets recolored badly by someone else.
- **Both transparent and solid-background** square marks. Some platforms (payment dashboards, app
  directories) composite an avatar onto an unpredictable background; a solid-bg variant with the brand
  color and correct internal padding is what you want there.
- **Padding/safe zone** — square avatars need the mark inset (roughly 10–15%) so circular crops
  (GitHub, LinkedIn, Slack) don't clip it. Export a padded square variant, not just a tight crop.
- **PNGs are font-true renders**, not browser-dependent SVG. If the wordmark uses live `<text>` in the
  brand font, outline it or render the PNGs in headless Chromium with the repo's woff2 loaded — see
  `assets-fonts-favicons.md`.
- **Generate, never hand-place.** Even at Tier 1, produce these with the zero-dependency
  Playwright renderer described below under Tier 3 ("Zero-dependency asset rendering"), wired to
  `task brand:assets`, driven from the live tokens and the source SVGs. Regenerate after any brand
  change; never hand-edit an output. Tier 2/3 then add stages to the _same_ script rather than
  inventing a second pipeline.
- Serve them from **stable paths** (`public/brand/logo/…`) so a README, a partner, or an automation can
  hotlink without the URL moving.

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

- **Logo suite** — the Tier 1 download matrix (above) is the baseline; Tier 2 adds the rest: **stacked**
  in addition to horizontal variants, **PDF/EPS** for print vendors, and larger/print-resolution
  renders. Same generator, more stages — don't rebuild the pipeline. Include the clear-space rule,
  minimum size, and a misuse row.
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
- **Email** — transactional and marketing templates, a newsletter layout, and an email signature;
  hand-built **table-HTML with inline styles and system font stacks** (the zero-dependency pattern
  below — email clients can't load brand fonts reliably anyway), shipped as HTML/CSS bundles and
  tested against major clients (Gmail, Outlook, Apple Mail). React Email is an acceptable
  alternative only when the repo already carries that dependency — don't add it just for this.
- **Print** — business cards, letterhead, flyers, posters, brochures, stickers, and signage as PDFs.
  The zero-dependency recipe below yields **digital-proof PDFs** (RGB, rendered at bleed size);
  true **print-ready** output (CMYK color, 300dpi, bleed _plus crop marks_) needs a dedicated
  production export/conversion step and print-vendor validation before packaging — never label the
  CSS-generated PDFs print-ready.
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

### Zero-dependency asset rendering (the proven pattern)

Used at **every tier** — Tier 1's logo/icon downloads, Tier 2's kit, and Tier 3's collateral all come
out of this one script; later tiers add stages rather than a second pipeline.

Rendering does **not** need image/PDF libraries (`satori`, `astro-og-canvas`, `sharp`, React
Email…) — the repo's existing Playwright renders everything, driven by one script (e.g.
`scripts/build-brand-assets.mjs`, wired to a `task brand:assets`):

- **Parse the live tokens** from `globals.css` (same extraction approach as `check-contrast.mjs`)
  so every artifact is _generated from_ the system and can't drift; regenerate after any token
  change, never hand-edit outputs.
- **HTML template strings + `page.setContent()`** — no server needed. Load brand fonts with a
  `file://` `@font-face` pointing at the repo's woff2 (Fontsource packages work:
  `node_modules/@fontsource-variable/<font>/files/…`), inline the logo SVGs, and
  `await page.evaluate(() => document.fonts.ready)` before capturing.
- **PNGs** via `page.screenshot` with an exact-size viewport/clip (OG cards 1200×630, platform
  banners, avatars); **PDFs** via `page.pdf({ printBackground: true, preferCSSPageSize: true })`
  with `@page { size: … }` — print pieces render at **bleed size** (e.g. a 3.5×2in card at
  3.75×2.25in) with type inside the safe zone. These are **digital proofs**, not print-ready
  files: they're RGB with no crop marks, and the CMYK values in the spec sheet are
  digital-derived — a print vendor must convert and validate before production (see the Print
  bucket above).
- **Email** stays hand-built table-HTML with inline styles and system font stacks (email clients
  can't load brand fonts reliably); a slide deck works well as an unlisted print-styled route the
  user exports via Print → PDF.
- Emit **`kit.json`** (versioned manifest: colors in hex/rgb/oklch/cmyk, font names + licenses,
  asset URLs, boilerplate copy) from the same parsed tokens, and assemble `brand-kit.zip` from the
  generated tree — the Tier 2 endpoint and the zip stay in lockstep by construction.

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
