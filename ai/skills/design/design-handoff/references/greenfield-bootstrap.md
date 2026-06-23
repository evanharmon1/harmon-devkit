# Greenfield bootstrap: standing up a design system from nothing

Read this during **Phase 1**, only when the repo has **no design system yet**. It installs and
configures the design-system layer so the rest of the handoff has somewhere to land. It assumes a
**working frontend app already exists** (a Vite/React or Astro project that builds and runs) — it does
**not** scaffold the framework itself. If there's no app at all, stop and tell the user to create one
first.

## Detect "no design system"

Treat the repo as greenfield when **all** of these are true:

- no `src/styles/globals.css` (or it exists but has no real `:root` semantic tokens), and
- no `components.json` (shadcn isn't initialized), and
- no `/brand` route, and
- styling is ad-hoc (inline styles, CSS modules, or default Tailwind with no token layer).

If a design system _is_ present, skip this file — go straight to Phase 2 and reconcile into the
existing `globals.css` (`token-reconciliation.md`).

## What bootstrap produces

1. Tailwind v4 + shadcn/ui installed and wired for the detected framework.
2. A starter `src/styles/globals.css` in shadcn three-layer OKLCH form (default neutral tokens — Phase
   2 replaces the _values_ with the design's).
3. A `/brand` route stub (filled in during Phase 3 — see `brand-page.md`).
4. `DESIGN.md` (root, AI-facing intent) and `docs/architecture/design-language.md` human docs.
5. The design Taskfile gates: `scripts/check-contrast.mjs` copied in, and `lint:design` /
   `ingest:design` merged into `Taskfile.yml`.

Order matters: install + `shadcn init` first (it writes a default `globals.css`), **then** Phase 2
reconciles the design's tokens into that file. Don't hand-write `globals.css` before `shadcn init` —
let the tool establish the structure, then edit values.

## Per-framework setup

shadcn/ui is React-only. The named primary stack is **React + Vite + TanStack Router**; **React
Router / plain React** and **Astro 6** are fully supported. For any other framework, map the same
three roles — _global stylesheet import_, _component directory_, _route entry_ — onto that
framework's conventions; never block on an unrecognized router.

### React + Vite + TanStack Router (primary)

```bash
pnpm add tailwindcss @tailwindcss/vite
pnpm dlx shadcn@latest init            # choose a base color (Neutral/Stone/Zinc/Gray/Slate); writes components.json + globals.css
```

- **Vite plugin:** add Tailwind to `vite.config.ts`:

  ```ts
  import tailwindcss from "@tailwindcss/vite";
  export default defineConfig({
    plugins: [tailwindcss() /*, …router plugin, react() */],
  });
  ```

- **Path alias:** ensure `@/*→ ./src/*` in `tsconfig.json` and `resolve.alias` in `vite.config.ts`
  (shadcn init prompts for this; components import as `@/components/ui/...`).
- **Global stylesheet:** `src/styles/globals.css` (starts with `@import "tailwindcss";`), imported
  once at the app root (e.g. `src/main.tsx` or `src/routes/__root.tsx`).
- **Components:** shadcn lands in `src/components/ui`.
- **`/brand` route:** file-based at `src/routes/brand.tsx`.

### React + Vite + React Router (or plain React)

Identical install and Tailwind/shadcn wiring as above. Differences:

- **Global stylesheet:** import `src/styles/globals.css` in `src/main.tsx`.
- **`/brand` route:** a normal route — `<Route path="/brand" element={<Brand />} />` (React Router) or
  a `Brand` component mounted at `/brand`.

### Astro 6 (first-class)

```bash
pnpm astro add tailwind                 # wires Tailwind v4 via @tailwindcss/vite
pnpm astro add react                    # @astrojs/react — required: shadcn components are React islands
pnpm dlx shadcn@latest init             # configures components.json + path aliases for Astro
```

- **Global stylesheet:** create `src/styles/globals.css` (`@import "tailwindcss";`) and import it in
  your base layout: `import "../styles/globals.css";` inside `src/layouts/Base.astro`.
- **Components:** shadcn lands in `src/components/ui` (React `.tsx`).
- **`/brand` route:** `src/pages/brand.astro`. Static specimens (swatches, type scale) can be plain
  `.astro`; **interactive** specimens (a theme toggle, hover/focus demos, anything stateful) must be
  React **islands** with a `client:*` directive — e.g. `<ThemeToggle client:load />`,
  `<ButtonSpecimens client:visible />`. See `components-and-states.md` for the island rules.

## Scaffold the design records

- **`DESIGN.md` (root)** — the durable, AI-facing statement of intent. Seed it with sections for
  palette, type scale, spacing, radii, component rules, and the prose "do's and don'ts" tokens can't
  capture. Phase 2/3 fill it from the design; `globals.css` wins for _runtime_ values, `DESIGN.md`
  carries _intent_.
- **`docs/architecture/design-language.md`** — the human-facing visual + UX design language (brand,
  design system, components, accessibility, UX). A stub is fine now; it grows as the design lands.
- **`/brand`** — create the route stub now; build it out in Phase 3 (`brand-page.md`).

## Wire the quality gates

- Copy `assets/check-contrast.mjs` (from this skill) into the repo at `scripts/check-contrast.mjs`. It
  is zero-dependency — it needs only Node, no install.
- Merge `assets/Taskfile.design.yml`'s tasks into the repo's `Taskfile.yml` (create missing ones):
  `lint:design` (the static contrast + off-palette gate), `ingest:design`, and either a
  `verify:design` aggregator or — preferably — add `lint:design` to the repo's existing `verify`/
  `check` deps so the design gate runs on every verification pass.

A note on the starter tokens: shadcn's default `muted-foreground` sits right at the AA borderline, so
`task lint:design` may flag it on the raw defaults. That's expected — tightening it is one of the
first things Phase 2 reconciliation does. Don't chase a green gate on the defaults; get it green after
the design's real tokens are in.

## Then continue

With the design system stood up, proceed to **Phase 2 — token reconciliation**
(`token-reconciliation.md`): replace the default token _values_ with the design's, author `.dark`, and
get the static contrast gate green before implementing components. Before you call the system complete,
run it past `deliverables-checklist.md` so no token category or component family is missed.
