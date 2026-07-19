# Assets, fonts & favicons

Read this during **Phase 3**. It covers where every asset belongs, how to self-host fonts correctly
(and the `@import` order that silently breaks if you get it wrong), and how to generate a complete
favicon set instead of hand-making sizes.

## Where assets live

**Static, ships with the app → the repo:**

- `public/` — files referenced by a **stable URL string** (favicons, OG/share images, `robots.txt`).
  Served as-is, not hashed.
- `src/assets/` — files **imported by a component**, so Vite hashes and optimizes them (most images,
  logos used inside JSX).
- Rule of thumb: reference it by string URL → `public/`; `import logo from "./logo.svg"` →
  `src/assets/`.
- Logos and vector art are **SVG**. Brand assets → `public/brand/`; content/marketing images →
  `src/assets/` (imported) or `public/images/` (URL-referenced).

**Dynamic / user-generated media → NOT the repo.** Customer uploads, user photos, anything created at
runtime belong in object storage (**Cloudflare R2** or equivalent). The repo is for assets that ship
with the build; user media is runtime data and must never be committed.

## Self-host fonts (don't hotlink)

- Self-host **OFL/Apache** `.woff2` in `public/fonts/`. Self-hosting is faster, privacy-preserving (no
  third-party request), and avoids layout shift from a slow font CDN. Licensing is a gate — OFL/Apache
  only; see `ethics-and-licensing.md`.
- Prefer **variable fonts**: a single `.woff2` covers the whole weight/optical-size range and is
  smaller than shipping many static cuts.
- Declare with `@font-face` + **`font-display: swap`** so text renders immediately in the fallback and
  swaps in when the webfont arrives (no flash of invisible text).
- **The lowest-friction self-hosting path is Fontsource as an npm dependency** — it _is_
  self-hosting (the woff2 ships from your origin via the bundler), version-pinned, and each package
  carries the font's LICENSE file (handy for the licensing gate and for redistributing woff2 +
  license inside a press kit). Prefer the variable packages:

  ```css
  /* globals.css — package imports are @imports: they MUST sit above tailwindcss (order rule below) */
  @import "@fontsource-variable/space-grotesk";
  @import "@fontsource-variable/jetbrains-mono";
  @import "tailwindcss";
  @theme {
    /* Fontsource variable families register as "<Family> Variable" */
    --font-sans: "Space Grotesk Variable", "Space Grotesk", ui-sans-serif, system-ui, sans-serif;
  }
  ```

  Manual alternative: convert TTF/OTF → woff2 with Google's `woff2` tools and declare `@font-face`
  yourself (the block below).
- Define families by **role** in `globals.css` under `@theme` — `--font-sans`, `--font-display`,
  `--font-mono`. Components use `font-sans` / `font-display`; never hardcode a family name in a
  component.
- **Preload** the one or two above-the-fold faces:
  `<link rel="preload" href="/fonts/inter-variable.woff2" as="font" type="font/woff2" crossorigin>`.

```css
/* globals.css — imports FIRST (order rule below), @font-face after them */
@import "tailwindcss";
@font-face {
  font-family: "Inter";
  src: url("/fonts/inter-variable.woff2") format("woff2");
  font-weight: 100 900; /* variable weight range */
  font-style: normal;
  font-display: swap;
}
@theme {
  --font-sans: "Inter", ui-sans-serif, system-ui, sans-serif;
}
```

## The `@import` order rule (this _will_ bite you)

Per the CSS spec, an `@import` that appears after **any other rule** is silently ignored — and
"other rule" includes a `@font-face` block, not just Tailwind's expanded rules. Two consequences:

- **Every `@import` goes at the very top of the stylesheet**, before `@font-face`, `@theme`, or
  anything else. A `@font-face` placed above `@import "tailwindcss";` kills the Tailwind import —
  the whole framework silently fails to load.
- **Order among the imports matters too:** a hosted-font `@import url(...)` (e.g. a Google Fonts
  URL) or a Fontsource package import must sit **above** `@import "tailwindcss";`, because
  Tailwind's import expands into rules that would invalidate any `@import` after it.

Self-hosting with `@font-face` avoids the hosted-font `@import` — one more reason to prefer it —
but the `@font-face` block itself still belongs **after** all the imports.

## Favicons: generate the whole set from the mark

Don't hand-make sizes. Generate the modern minimal set from a high-resolution square of the logo mark
at build time:

- `favicon.ico` (multi-size), `favicon.svg`, `apple-touch-icon.png` (180×180), PWA icons (192, 512,
  plus a **maskable** 512), and `site.webmanifest` — roughly five files plus the manifest.
- Tools: **`@vite-pwa/assets-generator`**, `vite-plugin-favicon`, or `pwa-asset-generator`. Point it at
  a clean square SVG/PNG of the mark and commit the generated set to `public/`.
- Add the `<link>`/manifest tags the generator prints to the document head. Include a **maskable** icon
  (with safe-zone padding) so Android doesn't crop the logo.

## Logo exports: generate them too, not just favicons

Favicons are wired into the app so they always get made; **logos are the ones that get forgotten** —
they end up as inline JSX or one loose SVG, and there's no file to hand Stripe, Polar, GitHub,
LinkedIn, or a README. Generate them in the same pass, from the source SVGs and the live tokens:

- **Source of truth:** clean SVGs in `public/brand/logo/` — square mark, horizontal lockup, wordmark.
- **Render the ladder** into `public/brand/logo/`: square mark PNG at **64/128/256/512/1024**, lockup
  and wordmark PNG at **400/800/1600 wide**, each in full-color, reversed/white, and single-color
  black — plus a **padded solid-background square** for circular-crop avatars (GitHub, LinkedIn,
  Slack) and a `logos.zip`.
- **How:** the zero-dependency Playwright renderer (`scripts/build-brand-assets.mjs` behind
  `task brand:assets`) described in `brand-page.md` — `page.setContent()` with the SVG inlined and a
  `file://` `@font-face`, then `page.screenshot` at an exact viewport. This also makes the PNGs
  **font-true** (see the SVG `<text>` caveat below).
- Surface every file as a labeled download on `/brand` — see the download matrix in `brand-page.md`.

## Raster images: format + loading

- **Format priority:** AVIF → WebP → PNG/JPEG fallback (AVIF/WebP are dramatically smaller). Serve via
  `<picture>` or a framework image component with a fallback source.
- **Responsive:** `srcset` + `sizes` so a phone fetches a phone-sized image, not the 2000px hero.
- **Lazy-load** below the fold with `loading="lazy"`; keep the above-the-fold/LCP image eager and
  ideally preloaded.
- **SVG** for logos, icons, and vector art — crisp at any size, tiny, and themeable via
  `currentColor`.
- **SVG marks that use live `<text>`** (wordmarks set in the brand font) render correctly on the
  site — the self-hosted font is loaded — but are **font-dependent as standalone files**: opened
  elsewhere they fall back to whatever the viewer has installed. For press kits and downloads,
  either outline the text or ship **font-true PNG renders** alongside (render the SVG in headless
  Chromium with a `file://` `@font-face` pointing at the repo's woff2, then screenshot — zero new
  dependencies; see the collateral pattern in `brand-page.md`).

## Then

Clear **every** font, icon, and image for commercial use before committing — that's the licensing gate
in `ethics-and-licensing.md`.
