---
name: design-handoff
description: >-
  Implement a finished Claude Design in the actual code repo. Use this whenever
  the user has exported a design from Claude Design (Anthropic's design canvas product)
  and wants to turn it into real code — phrases like "I finished designing in
  Claude Design", "implement this design", "do the design handoff", "I exported
  the handoff bundle", "turn this design into code", etc. This is the Claude Design →
  code-repo implementation workflow for the stack in this repo.
  NOTE: this is NOT session/context handoff between
  agent sessions — it is specifically about implementing a visual/UX design in code.
  Trigger it even if the user doesn't say the word "skill".
---

# Design Handoff (Claude Design → repo)

Turn a finished Claude Design into working, on-brand code in this repo. The native Claude Design export drops a **handoff bundle** (usually standalone HTML/CSS/JS, screenshots, the tokens it used, and a README) into the repo; your job is to reconcile that generic bundle into _this repo's_ conventions — not to paste it in verbatim.

The core principle running through every step: **`src/styles/globals.css` is the canonical runtime token source, and `DESIGN.md` is the AI-facing statement of intent.** When they disagree, `globals.css` wins for runtime. The handoff bundle is the reference for the _intended_ design — it stays in place until **the user has reviewed the implementation and approved it**, and only then is it removed before merge. Never assume your implementation is correct; the user decides whether it matches the intent.

## Definition of done

Copy this checklist into your reply at the **start** of the run and tick each
box as you finish it. Do not report the handoff complete until every box is
checked. The three **gates** are blocking — you may not take the action a gate
guards until its box is true.

Reconciliation

- [ ] Implemented from the canonical **un-suffixed** sources, not the `?v=N` snapshots
- [ ] Tokens merged into `globals.css` by **role** (not export name), for Tailwind v4, OKLCH, three-layer — export never blind-pasted
- [ ] `.dark` authored by hand: brand hue held constant, neutrals inverted
- [ ] `DESIGN.md` reconciled, not clobbered

Implementation

- [ ] shadcn/ui + Lucide only; styled **exclusively** with semantic tokens (zero arbitrary hex / one-off color literals)
- [ ] States covered: default, empty, loading, error, disabled
- [ ] `/brand` updated in the **same** change (can't drift from `DESIGN.md`/`globals.css`)
- [ ] Assets placed correctly: static → repo, dynamic/user media → R2; fonts self-hosted OFL/Apache `.woff2` in public/fonts; favicons generated from the mark
- [ ] OKLCH for color values; **three-tier semantic** token naming (primitive → semantic → component).

Gates (each blocks the action it guards — do not proceed until true)

- [ ] **Licensing** (blocks commit): every font/icon/image cleared for commercial use; anything unclear stopped and flagged, not guessed
- [ ] **Contrast** (blocks sign-off): static `task lint:design` green **and** rendered ratios measured on the running page — both themes, every text role incl. long-form prose — reported as **numbers**, never "looks fine". WCAG AA (4.5:1).
- [ ] **Sign-off** (blocks deletion): screenshots shown (both themes, all built states), deltas surfaced, user has **explicitly approved** — not inferred from a green build or your own confidence

Close-out (only once the sign-off gate is true)

- [ ] `task verify` green and the build compiles; hooks never bypassed (`--no-verify` prohibited)
- [ ] Handoff bundle deleted (or a thin screenshot + intent note extracted first if states remain)
- [ ] `docs/design/` updated; DDR flagged if a real design-system decision was made
- [ ] Conventional Commit; PR opened for human review (no direct merge to `main`)

## Inputs

- A handoff bundle at `docs/design/handoff-<feature-or-description>/`. If you can't find one, ask the user where the export landed (or whether they've exported yet) before proceeding.
- The existing repo: `DESIGN.md` (root), `src/styles/globals.css`, `docs/design/`, `Taskfile.yml`, and the project's `CLAUDE.md`.

## Stack (target for all implementation)

TypeScript 6 or above, React, Vite, pnpm, Node 24 or above, Astro 6 or above, Tailwind CSS v4 or above, shadcn/ui, Cloudflare Pages/Workers. Favor **shadcn/ui** for components and **Lucide** for icons.

---

## Procedure

Work through these in order. Explanations of _why_ are included because they change how you make judgment calls.

### 0. Locate and read the bundle

`view` the `docs/design/handoff-<feature>/` directory. Read the README (it states the design intent and structure), look at the screenshots, and note the tokens and component structure it used. This is your spec — but it's a _generic_ spec, not yet adapted to the stack.

**Load the file the prototype actually renders, not a stale snapshot.** Claude Design exports cache-bust its scripts with query strings, e.g. `<script src="sections.jsx?v=18">`, and it _also_ writes a literal file named e.g. `sections.jsx?v=18` next to the canonical `sections.jsx`. Over `file://` the browser strips the `?v=…` query and loads the **plain** file (`sections.jsx`, `components.jsx`, `styles.css`, `app.jsx`) — so the canonical, current design lives in the **un-suffixed** files. The `…?v=N` files are older snapshots; reading them will have you implementing a version the user already iterated past. Open the entry HTML, see which sources it references, and read the plain-named files those resolve to. If two files differ, the larger/un-suffixed one is almost always current — confirm against the screenshots or ask.

### 1. Establish the canonical sources

Before changing anything, read the current `DESIGN.md` (root) and `src/styles/globals.css`. You need to know the existing token system so you _merge into_ it rather than overwrite it. shadcn's `globals.css` is a three-layer structure — `:root`/`.dark` semantic tokens in OKLCH, plus an `@theme inline` reference layer. Internalize that structure now; you'll merge into its semantic slots in step 3.

### 2. Reconcile tokens — **read `references/token-reconciliation.md`**

This is the most error-prone step, so it has its own detailed reference. **Read `references/token-reconciliation.md` and follow it.** In short: the design's token export is flat, light-mode-only, and often hex; shadcn needs three-layer, dual-mode, OKLCH, and semantic. You will map the design's colors into `globals.css` semantic slots **by role**, author the `.dark` block the export can't supply, and never hard-code values into `@theme inline`. Do not blind-paste the export.

To get the export into a scratch file for reference (never write it directly into `globals.css`):

```bash
task export:design   # writes .design/theme.scratch.css and .design/tokens.json
```

### 3. Update `DESIGN.md`

Make `DESIGN.md` (repo root) reflect the design: palette, type scale, spacing, radii, component rules, and the prose "do's and don'ts" that tokens can't capture. If Claude Design generated a `DESIGN.md`, reconcile it into the existing one rather than clobbering. `DESIGN.md` is the durable AI-facing record; the bundle is not.

### 4. Implement components in the stack

Build the UI and components (check for existing ones before building custom) and icons (named imports so they tree-shake). Style **only** with the semantic tokens in `globals.css` — never arbitrary hex or one-off Tailwind color literals. Cover the states the bundle may not show: empty, loading, error, disabled.

**Build and maintain the brand page at `/brand`.** The design system ships a living document that eexplains the brand, design system, style guide, etc. It is not throwaway reference — it must exist as a real, maintained route at **`/brand`**: the public, at-a-glance companion to `DESIGN.md` (intent prose) and `globals.css` (runtime tokens). Implement it in the stack (palette swatches with hex **and** OKLCH, type specimens + scale, logo/monogram lockups, ornaments, button/component specimens, the colour-block, and the OG share-card), styled with the semantic tokens so it tracks the theme toggle. Treat it as a standing deliverable: whenever tokens, type, or brand rules change, **update `/brand` in the same change** so it never drifts from `DESIGN.md`/`globals.css`. If a `/brand` route already exists, reconcile into it rather than duplicating. Link it discreetly (e.g. from the footer).

The /brand page should include the following sections:

- A general explanation of the brand and design system, with the name of the design
- A style guide with OKLCH values and other design tokens, a color palette, and the actual font names
- Components with explanation and examples, including buttons, form elements, and any custom components the design introduced
- Assets like logos, lockups, word marks, icons, favicons, etc
- a brand kit/press kit that makes relevant items like logos and other brand materials downloadable
- When appropriate, social media assets like example posts for LinkedIn, Instagram, Facebook, Bluesky, etc.
- When appropriate, print material assets like flyers, business cards, etc. downloadable as PDFs
- When appropriate, email templates and assets, downloadable as HTML/CSS bundles or snippets, preferably utilizine React Email.
- When appropriate, an example slide deck presentation template in pptx format, making sure the deck is edtiable and not just a flat or image-based deck.

### 5. Handle assets

- **Static assets ship with the app** → the repo: logo variants and brand assets in `public/brand/`, content/marketing images in `public/images/` (stable URL) or `src/assets/` (when imported by a component, so Vite hashes/optimizes them). SVG for logos and vector art.
- **Dynamic / user-generated media** (e.g. customer photos) → **Cloudflare R2**, never the repo.
- **Favicons** → generate the full set (`.ico`, `apple-touch-icon`, PWA manifest icons) from the logo mark at build time (e.g. `vite-plugin-favicon`); don't hand-make sizes.
- **Fonts** → self-host OFL/Apache `.woff2` in `public/fonts/`, declared via `@font-face` with `font-display: swap`. Define families by role (`--font-sans`, `--font-display`, `--font-mono`) in `globals.css` under `@theme`. Prefer variable fonts. Remember the `@import` for any hosted font CSS must come _before_ `@import "tailwindcss"`.
- **Image formats**: prefer AVIF → WebP → PNG/JPEG; SVG for vector. Use responsive `srcset`/`sizes` and `loading="lazy"` below the fold.

### 6. Licensing gate (commercial-use check)

This repo ships commercial products, so **every font, icon, and image must permit commercial use.** Verify before committing:

- Fonts: OFL/Apache only (all Google Fonts qualify). Reject Helvetica/SF Pro/Gotham and other proprietary faces.
- Icons: Lucide (ISC) is safe. Flag Font Awesome free (CC-BY → attribution required).
- Images/stock: confirm the license — "free to download" ≠ "free for commercial use."
- **AI-generated logos**: flag to the human that a prompt-generated logo can usually be _trademarked_ but typically _not copyrighted_ (no human authorship), and recommend substantial human edits + a clearance search before it becomes the brand. Don't silently treat an AI logo as fully protected.

If any asset's license is unclear, **stop and flag it to the user** rather than guessing.

### 7. Run the checks (don't bypass hooks)

```bash
task lint:design   # canonical files; bans off-palette utilities; STATIC token-contrast gate; builds
task check         # typecheck + lint + format (fast static verification)
task verify        # (slower more comprehensive verification)
```

Then build to confirm it compiles. **Never use `--no-verify`** or otherwise skip git hooks — the hooks and CI are authoritative gates, and bypassing them defeats the point.

**Contrast is checked at TWO levels — keep both.**

1. **Static token contrast (here).** `task lint:design` runs a checker that parses the semantic colour tokens out of `globals.css` and proves every foreground/background pair the design relies on meets **WCAG AA in both themes** (4.5:1 text; 3:1 large/UI; purely decorative accents like gilt-on-paper are reported but exempt). This catches a bad palette early and must stay green. If you add a text role or surface, add its pair to the checker.
2. **Rendered contrast (step 8).** The static gate is **necessary but not sufficient** — it sees the _tokens_, not the colour that actually paints. A third-party component layer can override your colour at runtime (e.g. the Tailwind Typography plugin's `.prose` defaults sit in a later cascade layer and replace `--tw-prose-body` with a dark grey, so long-form/dark-mode body renders illegibly even though `ink/ink-soft` are correct). So you **also** measure the computed colour on the running page — see step 8.

Both must pass. Token math alone is not a contrast guarantee; rendered measurement alone misses palette regressions the static gate would catch on every build.

### 8. Verify against the design and get the user's sign-off (REQUIRED)

**Do not assume the implementation is correct, and do not proceed to cleanup on your own judgment.** Before anything is deleted, show the user the result and ask them to approve it.

1. **Make it viewable.** Run the app (`task dev` / the project's run skill) and exercise the implemented screens. Capture screenshots of each implemented view, in **both light and dark mode**, and for the states you built (default, empty, loading, error).
2. **Measure rendered contrast (don't trust the tokens).** On the running pages, read the **computed** colour of real text against its real background and compute the WCAG ratio — in **both themes**, and for every text role: body, headings, muted/meta, links, on-colour-block text, and **especially long-form prose / article bodies** (the place third-party layers like the typography plugin override your colours). A quick way: in the browser, `getComputedStyle(el).color` vs the element's background, run the WCAG ratio, and require **≥ 4.5:1** (≥ 3:1 for large text). If anything fails, fix it (e.g. pull the override out of the cascade layer so your token wins) and re-measure before showing the user. Report the measured ratios in your summary — never claim "passes AA" without a number.
3. **Compare to the bundle.** Put your screenshots next to the bundle's screenshots / `DESIGN.md` intent and call out any deltas you already know about (things you adapted, simplified, or deferred).
4. **Ask explicitly.** Use `AskUserQuestion` (or a direct question) to ask whether the implemented design looks right — e.g. "Does this match the intended design, or are there things to fix before I remove the handoff files?" Surface known compromises so the user is deciding with full information.
5. **Iterate until approved.** If the user wants changes, make them and re-verify. **Loop here — do not advance — until the user explicitly approves.** Approval is the user's call, never yours.

The handoff bundle stays fully in place for this entire step: it is the reference the user compares against.

### 9. Clean up the bundle — only after explicit approval

**Gate:** only do this once the user has approved the implementation in step 8. If approval hasn't been given, **leave `docs/design/handoff-<feature>/` exactly where it is** — it represents the intended design and must outlive an unverified implementation.

Once approved, **delete `docs/design/handoff-<feature>/`** so a stale runnable snapshot can't later mislead an agent into treating it as a source of truth. The only exception: if the design includes states not yet built, extract a _thin_ screenshot + intent note into the relevant spec first, then delete the rest. The durable records are the merged code, the updated `DESIGN.md`/`globals.css`, and any decision record.

### 10. Update human docs and flag decisions

- Update relevant files in `docs/design/` (`brand.md`, `design-system.md`, `components.md`, `accessibility.md`, `ux.md`) and **the `/brand` page (step 4) whenever brand-level things changed — keep it in lockstep with `DESIGN.md`/`globals.css`.** Also update README.md if the design introduced new scripts or usage instructions.
- If this design embodied a genuine, debatable design-system decision (a new token architecture choice, a palette philosophy shift), tell the user it warrants a **DDR** in `/decisions/`. Don't write architecture decisions into this skill or into `DESIGN.md` prose — they belong in a decision record.
- Use Conventional Commits. The bot/agent never merges to `main` directly — open a PR for human review of the diff.

---

## Guardrails (apply throughout)

- **Get sign-off before deleting anything.** The handoff bundle is the record of the _intended_ design. Never delete `docs/design/handoff-<feature>/` (or any handoff file) until the user has reviewed the implementation and explicitly approved it. Approval is the user's decision; don't infer it from a green build or your own confidence.
- **Semantic tokens only.** Never introduce arbitrary hex or one-off Tailwind color literals. Use the `globals.css` semantic tokens.
- **`globals.css` wins over `DESIGN.md`** for runtime. If they drift, flag it.
- **`/brand` is a maintained route, not a doc.** Build it from the design's style guide and keep it synced with the tokens; never let it drift.
- **Read the canonical source files**, not the `?v=N` cache-busted snapshots the export leaves beside them.
- **Don't bypass hooks** (`--no-verify` is prohibited).
- **Conventional Commits**; PR for human review; no direct merges to `main`.

## Reference files

- **`references/token-reconciliation.md`** — the detailed recipe for merging the Claude Design token export into shadcn's three-layer OKLCH semantic structure, including authoring dark mode. Read it during step 2.

## Complements

This skill handles the _reconciliation and wiring_. It pairs well with the `frontend-design` skill (anti-"AI-slop" aesthetic direction) during step 4. It does not depend on any third-party skill.
