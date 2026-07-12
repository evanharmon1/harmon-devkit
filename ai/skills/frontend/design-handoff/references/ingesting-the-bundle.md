# Ingesting the bundle: what Claude Design actually hands off

Read this during **Phase 0**. It covers what the "Handoff to Claude Code" export really is, how to
open it, what to read and in what order, and the single most important mental shift: **the bundle is
a prototype, not production code — you _port_ it, you don't copy it.**

## Be defensive about the format

Claude Design is a fast-moving research preview, and its handoff is a **proprietary, non-standard**
format (not DTCG/W3C tokens, not Figma) that can change without notice. So **don't hard-code the
layout** — parse for _intent_, not for exact filenames or folders. The anatomy below is the common
shape as of now, not a contract: read what's actually present, and if a piece is named or structured
differently, adapt. The same posture lets this skill handle other design tools (e.g. Google Stitch),
whose bundles differ but carry the same ingredients — intent, tokens, markup, assets. Whatever the
format, the destination is identical: the repo's canonical `globals.css` / `DESIGN.md` / `/brand`, with
the bundle treated as a proposal.

## What the export actually is

"Handoff to Claude Code" has shipped as a **gzipped tarball** (`.tar.gz`, served as
`application/gzip`) and, in newer exports, as a `.zip` — the format is a moving target, so identify
the coding handoff by its **contents** (the README + `chats/` + project shape below), never by
extension alone. Claude Design's separate "Download as .zip" menu item is a different **raw-assets
export**: it has no README/chats and is _not_ the coding handoff — if what you extracted lacks that
shape, ask the user for the "Handoff to Claude Code" export.

**Treat the archive as untrusted input.** A crafted bundle entry with an absolute path, a `..`
component, or a link entry can write outside `specs/` during extraction (zip-slip). List and
validate the entries before extracting — `task ingest:design` (backed by the skill's
`ingest-design.sh`, which the skill copies into `scripts/`) does exactly that, and is the
preferred path:

```bash
task ingest:design BUNDLE=<bundle>.tar.gz   # validates entries (no absolute/.. /link paths), then extracts to specs/
# manual equivalent — the listing grep MUST come back empty before any tar -xzf:
tar -tzf <bundle>.tar.gz | grep -E '^/|(^|/)\.\.(/|$)'   # any hit → refuse to extract
tar -xzf <bundle>.tar.gz -C specs/
```

It extracts to a single project directory. Move/rename it to `specs/handoff-<feature>/` — do this
**even when the user pre-placed it under another name**: consistent naming is what the repo's ignore
conventions and future sessions key off.

## Shield the bundle from repo tooling (do this at ingest, not when CI breaks)

The bundle is vendored prototype content sitting inside a linted repo — left unshielded, it fails
`verify` in ways that look like your bugs: prettier/eslint attack its `.jsx` (and prettier would
_reformat the sign-off reference_), markdownlint its `readme.md`, yamllint any `.yml` it carries,
JSON-hygiene checks choke on empty manifest files (hygiene scripts often scan **untracked** files
too), and framework typechecks (`astro check`, `tsc`) sweep its bundled JS. Cover every surface the
repo lints:

- `.gitignore` → `specs/*/` (bundles are deleted at sign-off, never committed; top-level
  `specs/*.md` stay tracked)
- `.prettierignore` → `specs/*/`
- eslint flat config `ignores` → `'specs/'`
- `.yamllint` `ignore:` → `specs/*/`
- markdownlint invocation → `'#specs/*/**'`
- `tsconfig.json` → `"exclude": ["specs"]` (this is what `astro check` respects)

Repos standardized with **harmon-init** ship these ignores out of the box — check before adding
duplicates. One more anatomy note: bundles sometimes contain a copy of **this skill itself** under
`uploads/` (the designer uploaded it so the design would be handoff-aware) — treat it as reference
input like any other upload; the canonical skill lives in the repo, and skill scripts inside the
bundle may be renamed `.txt` to keep Claude Design's compiler happy.

## Anatomy (verified, current as of mid-2026)

```text
<project>/
  README.md                # headed "CODING AGENTS: READ THIS FIRST"
  chats/chat1.md           # the full Claude Design conversation — design intent & rationale
  project/
    *.html                 # an HTML shell + a print-ready variant
    js/*.jsx               # small JSX component files; the root app.jsx is imported LAST
    styles/tokens.css      # design-system primitives (palette, fonts, spacing, radii, type scale)
    styles/site.css        # brand overrides, sometimes including a few dark-mode bits
    uploads/               # YOUR uploaded inputs (photos, sketches) — NOT rendered UI screenshots
```

File names are project-specific, not a fixed schema — treat the _shape_ (README + chat + HTML/JSX +
`tokens.css`/`site.css` + uploads) as the contract, not the exact filenames.

## Read order (the README dictates it)

1. **`README.md`** — it states the structure and tells coding agents what to read.
2. **`chats/chat1.md`** — the intent. This is the bundle's real advantage over a static Figma export:
   it preserves _why_ — the decisions made, what was tried and rejected, the rationale behind the
   palette and layout. Read it; it resolves ambiguity that later steps would otherwise have to guess.
3. **The entry HTML, in full** — see how the sections compose into a page.
4. **Follow the imports** — `project/js/*.jsx` (root `app.jsx` last), then `styles/tokens.css` and
   `styles/site.css`.
5. **`uploads/`** — your original source inputs, for reference.

## It's a prototype — port it, don't copy it

The bundle runs in a browser with **no build step**: pinned-unpkg **UMD React 18.3.1** + ReactDOM +
`@babel/standalone`, JSX transpiled in the browser via `type="text/babel"`, components shared on
`window` through `Object.assign`, and uniquely-named inline style objects. That is _prototype-grade_.
It must become real code in the repo's stack — this translation is the central job of the handoff:

| Bundle (prototype)                       | Repo (production)                                                                   |
| ---------------------------------------- | ----------------------------------------------------------------------------------- |
| in-browser Babel + UMD React on `window` | the repo's Vite + React + TypeScript build, real ES module imports                  |
| `type="text/babel"` `.jsx`               | typed `.tsx` components (`components-and-states.md`)                                |
| inline style objects / ad-hoc classes    | Tailwind v4 utilities driven by semantic tokens (`token-reconciliation.md`)         |
| the static HTML shell                    | the repo's routing — TanStack Router / React Router / Astro pages (`brand-page.md`) |
| `tokens.css` flat primitives             | shadcn three-layer OKLCH `globals.css` (`token-reconciliation.md`)                  |

Read the prototype for **structure and intent**, then re-implement it idiomatically. **Do not** drop
the bundle's `.jsx`/`.html` into `src/`.

## What the bundle does NOT contain (correct these assumptions)

- **No machine-readable spec / `tokens.json` / DTCG file.** The "spec" _is_ the code plus the chat.
  Parse `tokens.css` and the JSX/HTML; don't wait for a structured token export that isn't there.
- **No per-state screenshots.** `uploads/` holds _your_ inputs, not rendered UI states. You generate
  screenshots yourself during Phase 5 verification.
- **No `?v=N` cache-busted files.** Current exports use clean, un-suffixed paths. _Defensive note:_ if
  you ever do encounter a `sections.jsx?v=18`-style file beside a plain `sections.jsx`, the plain file
  is canonical — read it and ignore the `?v=…` snapshot. This is not expected in current bundles; if
  you see it widely, the export format changed and this skill needs revisiting.

## After ingest

Inventory what you got — the `tokens.css` palette/scales, the component list under `js/`, the fonts
referenced, the `uploads/` — then **detect the framework, router, and mode** (SKILL.md Phase 0):
`establish-design-system` (no system yet — `greenfield-bootstrap.md`), `evolve-design-system`
(changing the system — `evolving-the-system.md`), or `implement-feature` (a feature against an existing
system). Leave the bundle in `specs/handoff-<feature>/` **untouched**: it is the reference the
user signs off against in Phase 6 and is not removed until Phase 7, after explicit approval.
