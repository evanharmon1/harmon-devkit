# Components & states: porting the prototype into real UI

Read this during **Phase 3**. Turn the bundle's prototype JSX into idiomatic, typed components in the
repo's stack — styled exclusively with semantic tokens, and covering every UI state, not just the
happy path the prototype shows.

## shadcn-first: don't build what already exists

Before building any custom component, check whether **shadcn already provides it** — button, input,
dialog, dropdown-menu, card, tabs, sheet, sonner (toast), etc. shadcn copies _source_ into your repo
(`src/components/ui`), so you own it and restyle it through tokens — there's no runtime dependency and
very low lock-in. Add with:

```bash
pnpm dlx shadcn@latest add button card dialog input   # etc.
```

Only build a custom component when the design introduces something shadcn doesn't have — and even
then, compose it from shadcn primitives where you can.

## Port the JSX, don't copy it

The bundle's `.jsx` runs on in-browser Babel + UMD React (see `ingesting-the-bundle.md`).
Re-implement it; never drop it into `src/`:

- convert to **typed `.tsx`** with real module imports (no `window` globals);
- replace inline style objects and ad-hoc classes with **Tailwind v4 utilities**;
- extract repeated structure into small components;
- preserve the prototype's structure and intent (cross-check `chats/chat1.md`), but write it the way
  this repo writes components.

## Style only with semantic tokens

Never introduce an arbitrary hex or a one-off color literal. Use the semantic token utilities:
`bg-background text-foreground`, `bg-primary text-primary-foreground`, `bg-muted text-muted-foreground`,
`border-border`, `ring-ring`, `bg-destructive text-destructive-foreground`, and so on. The off-palette
guard in `task lint:design` fails the build on arbitrary color utilities like `bg-[#1a1c1e]` or
`text-[oklch(...)]` (see `assets/Taskfile.design.yml`). **Why it matters:** semantic tokens flip
automatically in dark mode and are contrast-checked by the gate; a hardcoded color does neither, so it
silently breaks theming _and_ accessibility the moment someone toggles the theme.

## Icons: Lucide, named imports only

- Use **Lucide** (`lucide-react`) and import **by name**:
  `import { Camera, Check } from "lucide-react"`. Named imports tree-shake — only the icons you use
  ship to users.
- **Caveat:** Vite does **not** tree-shake in _dev_, so the dev bundle pulls the whole library and can
  feel heavy. Judge the real cost in the **production** build / bundle analyzer, not in dev. For very
  large icon counts, per-icon subpath imports (`lucide-react/icons/camera`) trim a little more.
- **Never mix icon libraries.** Two icon sets bloat the bundle and look visually inconsistent
  (different grids, stroke widths, optical sizing). Pick Lucide and map the design's icons to the
  nearest Lucide glyph; if one is genuinely missing, draw a one-off SVG that matches Lucide's 24×24 /
  2px-stroke conventions so it sits in the same visual family.

## Cover every UI state (the prototype usually shows one)

The bundle typically renders only the default, populated state. Real components need the full matrix.
For each interactive surface, build **and** verify:

- **default** — the populated, resting state.
- **empty** — no data yet (lists, search results, dashboards): a deliberate, designed empty state, not
  a blank rectangle.
- **loading** — skeletons or spinners; reserve space so layout doesn't jump when data arrives.
- **error** — a failed fetch or validation: a clear, recoverable message styled with `destructive`
  tokens.
- **disabled** — non-interactive and visually distinct (reduced emphasis), and not focusable where
  that's appropriate.

Plus the interaction states the tokens already support: **hover**, **focus-visible** (the `ring`),
**active**, and **checked/selected**. Never signal state by color alone (WCAG 1.4.1) — pair color with
an icon, text, or shape so it survives color-blindness and grayscale. You'll screenshot each built
state in **both themes** during Phase 5.

## Framework notes (routing/mounting differs; the rules above don't)

- **TanStack Router** — file-based routes under `src/routes/`. Put page entries there; co-locate
  route-specific components or keep shared ones in `src/components`.
- **React Router / plain React** — mount components on normal routes.
- **Astro 6** — interactive shadcn components must be React **islands**: wrap them with a `client:*`
  directive — `client:load` for above-the-fold interactivity, `client:visible` to defer until
  scrolled into view, `client:idle` for low-priority widgets. Purely static specimens can stay
  `.astro` and ship zero JS. A stateful shadcn component placed in an `.astro` file _without_ a client
  directive will render but never hydrate — it won't be interactive, which is a common and confusing
  Astro mistake.

## Astro trap: `asChild` cannot cross the framework boundary

`<Button asChild><a href="…">…</a></Button>` written in a **`.astro`** file renders a **bare,
completely unstyled anchor** — no classes, no `data-slot`, nothing. Radix `Slot` works by cloning a
React element child, but Astro passes its children across the boundary as opaque pre-rendered HTML,
so there is nothing to clone and the child passes through untouched. This fails **silently**: the
build is green, the page renders, and every CTA is a plain text link (it can even un-hide a
`hidden md:inline-flex` responsive class and break mobile layout). `asChild` is fine **inside**
`.tsx` islands, where children are real React elements.

For static templates, apply the variants to a real anchor instead — a small `ButtonLink.astro`:

```astro
---
import { buttonVariants } from "@/components/ui/button";
import { cn } from "@/lib/utils";
interface Props {
  href: string;
  variant?: "default" | "outline" | "ghost" | "link"; // match the repo's variants
  size?: "sm" | "default" | "lg";
  class?: string;
}
const { href, variant = "default", size = "default", class: className } = Astro.props;
---

<a href={href} class={cn(buttonVariants({ variant, size }), "no-underline", className)}>
  <slot />
</a>
```

The sweep's horizontal-overflow guard (`assets/brand-screenshots.spec.ts`) and the rendered checks
are what catch this class of bug — another reason not to skip Phase 5 on "it builds".

## Then

Place assets and fonts (`assets-fonts-favicons.md`), build responsively across viewports and engines
(`responsive-and-cross-browser.md`), clear licensing (`ethics-and-licensing.md`), build and maintain
`/brand` (`brand-page.md`), and verify with sign-off (`verification-and-signoff.md` and
`accessibility-verification.md`).
