---
name: design-handoff
description: >-
  Implement a finished Claude Design in this code repo — the Claude Design → code handoff. Use
  whenever the user has a design from Claude Design (Anthropic's design canvas) to turn into real
  code: phrases like "I finished designing in Claude Design", "implement this design", "do the design
  handoff", "Handoff to Claude Code", "I exported the handoff bundle / tokens.css / a .tar.gz design",
  "turn this design into code", or "set up a design system from this design". Handles both a single
  feature AND establishing a new design system in a repo that has none. Targets React + Vite +
  Tailwind v4 + shadcn/ui (Astro 6 and TanStack Router fully supported). This is NOT session/context
  handoff between agent sessions — it is about implementing a visual/UX design in code. Trigger it
  even if the user doesn't say the word "skill".
---

# Design Handoff (Claude Design → repo)

Turn a finished Claude Design into working, on-brand code in this repo. The "Handoff to Claude Code"
export is a **`.tar.gz` bundle** — a README, the design **chat transcript**, prototype HTML/JSX/CSS, a
`tokens.css`, and your uploads. That code is **prototype-grade** (it runs on in-browser Babel + UMD
React); your job is to **port** it into this repo's stack, not paste it in. There are two paths:
**reconcile** into an existing design system, or **bootstrap** a new one when the repo has none.

The core principle running through every step: **`src/styles/globals.css` is the canonical runtime
token source, and `DESIGN.md` is the AI-facing statement of intent.** When they disagree, `globals.css`
wins for runtime. The handoff bundle is the reference for the _intended_ design — it stays in place
until **the user has reviewed the implementation and approved it**, and only then is it removed before
merge. Never assume your implementation is correct; the user decides whether it matches the intent.

## Definition of done

Copy this checklist into your reply at the **start** of the run and tick each box as you finish it. Do
not report the handoff complete until every box is checked. The three **gates** are blocking — you may
not take the action a gate guards until its box is true.

Reconciliation

- [ ] Bundle ingested from the `.tar.gz`: README → chat transcript → HTML → `tokens.css`/`site.css` →
      `js/*.jsx` (read for intent and **ported**, never pasted into `src/`)
- [ ] Framework + router detected; greenfield-vs-brownfield decided
- [ ] Tokens merged into `globals.css` by **role** (not export name) — Tailwind v4, OKLCH, three-layer;
      export never blind-pasted
- [ ] `.dark` authored by hand (brand hue held, neutrals inverted); `--tw-prose-*` mapped if prose is
      used
- [ ] `DESIGN.md` reconciled, not clobbered

Implementation

- [ ] shadcn/ui + Lucide (named imports) only; styled **exclusively** with semantic tokens (zero
      arbitrary hex / one-off color literals)
- [ ] States covered: default, empty, loading, error, disabled
- [ ] `/brand` built/updated in the **same** change (scope chosen up front during intake)
- [ ] Assets placed (static → repo, user media → R2); fonts self-hosted OFL/Apache `.woff2`; favicons
      generated from the mark

Gates (each blocks the action it guards — do not proceed until true)

- [ ] **Licensing** (blocks commit): every font/icon/image cleared for commercial use; AI logos
      flagged; anything unclear stopped, not guessed
- [ ] **Contrast** (blocks sign-off): static `task lint:design` green **and** rendered ratios measured
      on the running page — both themes, every text role incl. long-form prose — reported as
      **numbers**, never "looks fine". WCAG AA (4.5:1 text; 3:1 large/UI).
- [ ] **Sign-off** (blocks deletion): screenshots shown (both themes, all built states), deltas
      surfaced, user has **explicitly approved** — not inferred from a green build or your confidence

Close-out (only once the sign-off gate is true)

- [ ] `task verify` green and the build compiles; hooks never bypassed (`--no-verify` prohibited)
- [ ] Handoff bundle deleted (or a thin screenshot + intent note extracted first if states remain)
- [ ] `docs/design/` and `/brand` updated; DDR flagged if a real design-system decision was made
- [ ] Conventional Commit on a **feature branch**; PR opened for human review (no direct merge to
      `main`)

## Inputs & stack

- A handoff bundle, usually unpacked to `docs/design/handoff-<feature>/`. If you can't find one, ask
  the user where the export landed (or whether they've exported yet) before proceeding.
- The existing repo: `DESIGN.md` (root), `src/styles/globals.css`, `docs/design/`, `Taskfile.yml`, and
  the project's `CLAUDE.md`.
- **Stack target:** TypeScript, React, Vite, pnpm, Tailwind CSS v4, shadcn/ui, Lucide, Cloudflare
  Pages/Workers. Named primary router **TanStack Router**; **React Router**/plain React and **Astro 6**
  fully supported. Favor **shadcn/ui** for components and **Lucide** for icons.

## Detect first: framework, router, design-system state

Before changing anything, read the repo to establish three things — they drive every later
file-placement decision:

- **Framework + router.** Where `/brand`, routes, and shadcn live differs per framework: TanStack →
  `src/routes/brand.tsx` + `src/components/ui`; React Router/plain → a normal `/brand` route; Astro →
  `src/pages/brand.astro` with React **islands** for interactive specimens. Any other framework adapts
  the same three roles (global stylesheet import, component dir, route entry) — never block on an
  unrecognized router. Details in `greenfield-bootstrap.md`, `components-and-states.md`,
  `brand-page.md`.
- **Greenfield vs brownfield.** A design system is present when `globals.css` has real `:root` semantic
  tokens **and** a `/brand` route exists → reconcile into it. Otherwise → bootstrap it first (Phase 1).
- **Where the bundle landed.** Find `docs/design/handoff-*/`; if you can't, ask before proceeding.

## Gather decisions up front (one `AskUserQuestion` batch)

You've now read the design intent and know the framework and greenfield-vs-brownfield — so this is the
moment to ask **everything you'll need from the user at once, in a single `AskUserQuestion` batch** (it
takes up to 4 questions). Front-loading lets Phases 1–5 run uninterrupted instead of stopping to ask
mid-build. Ask about:

- **`/brand` scope** — core style guide → full brand/press kit with collateral (tiers in
  `brand-page.md`); default to the core style guide.
- **Any other genuine ambiguity** the chat transcript left open — e.g. which routes/pages are in scope
  for a feature, whether a specific font/icon set is required, dark mode if not obvious. Only ask what
  you genuinely can't determine yourself; don't pad the batch.

The **one** decision that can't be front-loaded is the **Phase 6 sign-off** — it is approval of the
_built_ result, so it necessarily comes after implementation. Settle everything else here.

---

## Procedure

Work the phases in order. Each gate blocks the action it guards. Explanations of _why_ live in the
referenced files — read the reference when you reach its phase.

### Phase 0 — Ingest the bundle

Decompress the `.tar.gz` and read in the order its README dictates: `README.md` ("CODING AGENTS: READ
THIS FIRST") → `chats/chat1.md` (design intent — the bundle's real value) → the entry HTML →
`tokens.css`/`site.css` → the `js/*.jsx` components → `uploads/` (your inputs, **not** screenshots).
The code is prototype-grade; read it for structure and intent, then **port** it — don't paste
`.jsx`/`.html` into `src/`. Do not expect a `tokens.json`, a machine-readable spec, or per-state
screenshots — none ship. See `ingesting-the-bundle.md`.

### Phase 1 — Greenfield bootstrap (only if no design system exists)

If detection found no design system, stand one up before reconciling: install and configure Tailwind
v4 and shadcn for the detected framework, let `shadcn init` write the default three-layer
`globals.css`, scaffold the `/brand` route, `DESIGN.md`, and `docs/design/`, copy
`scripts/check-contrast.mjs`, and add the design Taskfile tasks. Assumes a working frontend app already
exists. See `greenfield-bootstrap.md`. (Brownfield repos skip to Phase 2.)

### Phase 2 — Reconcile tokens — GATE: static contrast

The most error-prone step; it has its own reference — **read `token-reconciliation.md` and follow
it.** Map the bundle's `tokens.css` into `globals.css`'s semantic slots **by role** (not by name),
express values in OKLCH, fill the roles shadcn needs but the export lacks, author the `.dark` block by
hand (hold brand hue, invert neutrals), and map `--tw-prose-*` if the app renders prose. Reconcile
`DESIGN.md`, don't clobber it. Then run `task lint:design` (`scripts/check-contrast.mjs`) and fix every
sub-AA pair — this static gate must be **green** before you implement. Numbers in
`accessibility-verification.md`.

### Phase 3 — Implement components, assets & `/brand`

Build the UI in the stack: shadcn-first (check for an existing component before building), port the
prototype JSX to typed components, Lucide **named** imports, and style **exclusively** with semantic
tokens — never arbitrary hex. Cover the states the bundle won't show: empty, loading, error, disabled.
Place assets (static → repo, user media → R2), self-host OFL/Apache `.woff2` fonts (mind the `@import`
order), and generate the favicon set. Build/maintain the living `/brand` page to the **scope chosen
during intake** (no need to ask again here). See `components-and-states.md`, `assets-fonts-favicons.md`,
`brand-page.md`.

### Phase 4 — Licensing gate (blocks commit)

Every font, icon, and image must permit commercial use. Fonts OFL/Apache only; Lucide (ISC) is safe;
confirm image licenses ("free to download" ≠ commercial). Flag AI-generated logos: usually
trademark-able but **not** copyrightable — recommend human edits + a clearance search before they
become the brand. If any license is unclear, **stop and flag it** rather than guessing. See
`ethics-and-licensing.md`.

### Phase 5 — Verify — GATE: rendered contrast

Run the gates (`task lint:design`, `check`, `verify` — create any that's missing; never `--no-verify`).
Build, run the app, and screenshot every view in **both light and dark** and for every state. Then
measure **rendered** contrast on the running page (static tokens passing isn't enough — a runtime layer
like `.prose` can override them): computed colors, both themes, every text role incl. long-form prose,
reported as **numbers**. Fix and re-measure failures before showing the user. See
`verification-and-signoff.md`, `accessibility-verification.md`.

### Phase 6 — Sign-off gate (blocks deletion)

Do not assume the implementation is correct. Show the user the screenshots (both themes, all states)
and measured ratios, compare against the bundle's intent and surface every delta, then ask
**explicitly** whether it matches before anything is removed. Iterate and re-verify; **loop here until
the user explicitly approves.** The bundle stays fully in place through this step. See
`verification-and-signoff.md`.

### Phase 7 — Close out (only after approval)

Delete `docs/design/handoff-<feature>/` (or extract a thin screenshot + intent note first if states
remain), update `docs/design/` and `/brand`, and flag a **DDR** in `/decisions/` if a genuine
design-system decision was made. Commit with Conventional Commits on a **feature branch** (direct
commits to `main` are blocked) and open a **PR** for human review — never merge to `main` directly. See
`verification-and-signoff.md`.

---

## Guardrails (apply throughout)

- **Port, don't paste.** The bundle is a prototype; re-implement it idiomatically in the stack.
- **Semantic tokens only.** Never arbitrary hex or one-off Tailwind color literals — they skip dark
  mode and the contrast gate.
- **`globals.css` wins over `DESIGN.md`** for runtime. If they drift, flag it.
- **`/brand` is a maintained route, not a doc.** Keep it synced with the tokens; never let it drift.
- **Get sign-off before deleting anything.** Approval is the user's decision, never inferred from a
  green build or your own confidence.
- **Don't bypass hooks** (`--no-verify` is prohibited).
- **Conventional Commits**; feature branch; PR for human review; no direct merges to `main`.

## Reference files

- **`ingesting-the-bundle.md`** — Phase 0: the verified bundle anatomy and the prototype→production
  port.
- **`token-reconciliation.md`** — Phase 2: `tokens.css` → shadcn three-layer OKLCH `globals.css`, by
  role, including `.dark` and the `--tw-prose-*` mapping.
- **`greenfield-bootstrap.md`** — Phase 1: stand up Tailwind v4 + shadcn + `globals.css` + `/brand` +
  Taskfile, per framework.
- **`components-and-states.md`** — Phase 3: port the JSX, shadcn-first, Lucide, the full UI-state
  matrix.
- **`assets-fonts-favicons.md`** — Phase 3: asset placement, self-hosted fonts (+ the `@import` order
  rule), favicon generation.
- **`accessibility-verification.md`** — Phases 2 & 5: the dual (static + rendered) WCAG AA contrast
  gate.
- **`brand-page.md`** — Phase 3: the living `/brand` style guide, the runtime scope question, and the
  collateral tiers.
- **`ethics-and-licensing.md`** — Phase 4: the commercial-use gate, the AI-logo reality, and vendor
  lock-in.
- **`verification-and-signoff.md`** — Phases 5–7: the gates, the sign-off loop, cleanup, and commit +
  PR.

Bundled assets (the skill installs these into the target repo):

- **`assets/check-contrast.mjs`** — zero-dependency static WCAG-AA token-contrast checker; copy to
  `scripts/check-contrast.mjs`.
- **`assets/Taskfile.design.yml`** — design task snippets (`lint:design`, `ingest:design`) to merge
  into the repo's `Taskfile.yml`.

## Complements

This skill handles the _reconciliation and wiring_. It pairs well with the `frontend-design` skill
(anti-"AI-slop" aesthetic direction) during Phase 3. It does not depend on any third-party skill.
