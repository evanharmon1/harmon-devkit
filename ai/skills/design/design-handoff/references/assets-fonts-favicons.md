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
- Convert TTF/OTF → woff2 with Google's `woff2` tools, or use **Fontsource**, which ships `.woff2`
  directly.
- Define families by **role** in `globals.css` under `@theme` — `--font-sans`, `--font-display`,
  `--font-mono`. Components use `font-sans` / `font-display`; never hardcode a family name in a
  component.
- **Preload** the one or two above-the-fold faces:
  `<link rel="preload" href="/fonts/inter-variable.woff2" as="font" type="font/woff2" crossorigin>`.

```css
/* globals.css — mind the @import ORDER rule below */
@font-face {
  font-family: "Inter";
  src: url("/fonts/inter-variable.woff2") format("woff2");
  font-weight: 100 900; /* variable weight range */
  font-style: normal;
  font-display: swap;
}
@import "tailwindcss";
@theme {
  --font-sans: "Inter", ui-sans-serif, system-ui, sans-serif;
}
```

## The `@import` order rule (this _will_ bite you)

If you load a hosted font via a CSS **`@import url(...)`** (e.g. a Google Fonts URL), that `@import`
**must** sit **above** `@import "tailwindcss";`. Per the CSS spec, a browser ignores any `@import`
that appears after other rules — and Tailwind's import expands into rules — so a font `@import` placed
_after_ it is silently dropped and the font never loads. `@font-face` blocks (which are not
`@import`s) can go anywhere; only `url()`-`@import`s are order-sensitive. Self-hosting with
`@font-face` sidesteps the trap entirely — one more reason to prefer it.

## Favicons: generate the whole set from the mark

Don't hand-make sizes. Generate the modern minimal set from a high-resolution square of the logo mark
at build time:

- `favicon.ico` (multi-size), `favicon.svg`, `apple-touch-icon.png` (180×180), PWA icons (192, 512,
  plus a **maskable** 512), and `site.webmanifest` — roughly five files plus the manifest.
- Tools: **`@vite-pwa/assets-generator`**, `vite-plugin-favicon`, or `pwa-asset-generator`. Point it at
  a clean square SVG/PNG of the mark and commit the generated set to `public/`.
- Add the `<link>`/manifest tags the generator prints to the document head. Include a **maskable** icon
  (with safe-zone padding) so Android doesn't crop the logo.

## Raster images: format + loading

- **Format priority:** AVIF → WebP → PNG/JPEG fallback (AVIF/WebP are dramatically smaller). Serve via
  `<picture>` or a framework image component with a fallback source.
- **Responsive:** `srcset` + `sizes` so a phone fetches a phone-sized image, not the 2000px hero.
- **Lazy-load** below the fold with `loading="lazy"`; keep the above-the-fold/LCP image eager and
  ideally preloaded.
- **SVG** for logos, icons, and vector art — crisp at any size, tiny, and themeable via
  `currentColor`.

## Then

Clear **every** font, icon, and image for commercial use before committing — that's the licensing gate
in `ethics-and-licensing.md`.
