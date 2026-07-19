# Responsive & cross-browser verification

Read this during **Phase 3** (build responsively) and **Phase 5** (verify the matrix). The bundle's
prototype is usually a single desktop layout; production has to work across viewport sizes **and**
rendering engines. Responsive and cross-browser are two axes of the same job: prove the design holds at
phone/tablet/desktop widths, on Chromium, Firefox, and WebKit.

## Build responsive (mobile-first)

- **Mobile-first.** Style the small screen first, then layer up with Tailwind breakpoints: `sm` 640px,
  `md` 768px, `lg` 1024px, `xl` 1280px, `2xl` 1536px. An unprefixed utility applies at all sizes; `md:`
  applies at ≥768px. Design the phone layout, then add `md:`/`lg:` overrides for wider screens.
- **No fixed-width layouts.** Use fluid and relative units, `max-w-*` with `mx-auto`, and grid/flex
  that reflows. Reach for `clamp()` on type and spacing where the scale should breathe between
  breakpoints.
- **Container queries** (`@container` with `@sm:`/`@md:` variants, built into Tailwind v4) when a
  component should respond to **its own container** rather than the viewport — e.g. a card that's
  full-width on mobile but sits in a narrow sidebar on desktop.
- **Touch.** Targets ≥44px on coarse pointers (the 24px floor is in `accessibility-verification.md`),
  and never gate an essential action behind `hover` — there is no hover on touch, so provide a tap
  path.
- **Mobile viewport height.** Use `dvh`/`svh`, not `vh`, for full-height layouts — mobile browser
  chrome makes `100vh` overflow and jump as the address bar collapses.
- **Responsive images** (`srcset`/`sizes`, AVIF/WebP) are covered in `assets-fonts-favicons.md`.
- **Check as you build** at representative widths: ~375 (phone), ~768 (tablet / iPad portrait), ~1024
  (iPad landscape / small laptop), ~1280–1440 (desktop). Watch for horizontal overflow at 320–375px —
  it's the most common responsive bug.

## The engines that matter

Three rendering engines cover the real-world field:

- **Chromium** → Chrome, Edge, Brave, most Android browsers.
- **Gecko** → Firefox.
- **WebKit** → Safari (macOS) **and** Mobile Safari (iOS/iPadOS — every iOS browser is WebKit under the
  hood, even "Chrome" on iPhone).

Pass on all three at your breakpoints and you've covered the matrix.

## Tooling: Playwright is the primary tool

Playwright drives **chromium, firefox, and webkit** from one config, emulates devices/viewports, and
produces repeatable screenshots — and it can read computed styles, so it doubles for the rendered
contrast check in `accessibility-verification.md`.

**Set it up if the repo doesn't have it.** Check for `@playwright/test`; if it's missing (always the
case in a greenfield repo), provision it — the same way this skill provisions its other gates:

```bash
pnpm add -D @playwright/test
npx playwright install            # download the chromium/firefox/webkit binaries (once)
```

Then drop in the bundled **`assets/playwright.config.ts`** (copy it to the repo root) and add the
`verify:browsers` task from `assets/Taskfile.design.yml`, so the cross-engine sweep runs like every
other gate. It wires `baseURL` + a `webServer` + the engine × device matrix; you fill two spots — the
build/serve command + port, and the device set if you want different targets:

```ts
// assets/playwright.config.ts (excerpt) — build & serve, then the cross-engine × device matrix
const PORT = 4321; // Astro preview; Vite preview 4173
export default defineConfig({
  testDir: "tests",
  use: { baseURL: `http://localhost:${PORT}` },
  projects: [
    { name: "chromium", use: { ...devices["Desktop Chrome"] } },
    { name: "firefox", use: { ...devices["Desktop Firefox"] } },
    { name: "webkit", use: { ...devices["Desktop Safari"] } },
    { name: "Mobile Safari", use: { ...devices["iPhone 13"] } }, // iOS WebKit
    { name: "Mobile Chrome", use: { ...devices["Pixel 5"] } }, // Android Chromium
  ],
  webServer: {
    command: `pnpm build && pnpm preview --port ${PORT}`, // production build ≈ what ships
    url: `http://localhost:${PORT}`,
    reuseExistingServer: !process.env.CI,
  },
});
```

Serve the **production build** (`build && preview`), not the dev server — no HMR/error-overlay flicker,
so screenshots and the horizontal-overflow guard are stabler and truer to what ships.

For a quick ad-hoc capture without a test file, the Playwright CLI takes one screenshot per device:

```bash
npx playwright screenshot --device="iPhone 14" http://localhost:5173/brand brand-iphone.png
```

For the full Phase 5 sweep, use the bundled **`assets/brand-screenshots.spec.ts`** template, run by
`task verify:browsers`. It is a parameterized harness, not a from-scratch write: the engine × device
axis comes from the `projects` above, and the spec adds the route × theme axis, writing one full-page
PNG per route × theme per project. Fill in three spots and it works:

- **`ROUTES`** — always include `/brand`, plus the feature's pages.
- **`baseURL` and `webServer`** (in the config above) — point them at the production
  `build && preview` server, as wired above (never the dev server — see the rule under the config).
- **`setTheme()`** — defaults to shadcn's `.dark` class on `<html>`; change it only if the repo toggles
  dark mode differently (data attribute, cookie).

To capture per-specimen shots on `/brand`, extend the spec to locate the `data-brand-specimen` hooks
(`brand-page.md`); the template includes a commented starting point.

**WebKit ≈ Safari, not identical.** Playwright's WebKit is the open-source engine — very close to
Safari and the best automated proxy for Safari and iOS Safari, but it lacks Apple-proprietary bits and
may differ in version. For a high-stakes Safari-only issue, confirm on a real device / actual Safari or
a cloud lab (BrowserStack, LambdaTest, Sauce Labs).

### Playwright vs agent-browser

- **agent-browser** (Chromium / Chrome DevTools Protocol) is great for the agent to interactively
  explore, click through flows, and grab quick screenshots — use it for ad-hoc visual checks and
  dogfooding. It is Chromium-only, so it does **not** prove cross-engine behavior.
- **Playwright** is the systematic matrix tool (three engines × viewports × themes) and is what
  produces the cross-browser sign-off evidence.

Use whatever the repo standardizes on for interactive poking, but use Playwright (or a cloud lab) for
the actual cross-engine verification.

If Playwright genuinely can't run here and only **agent-browser** is available, you can still do the
Chromium responsive pass with it — but the **cross-engine** half of gate ③ is then unmet. Provision
Playwright (or use a cloud lab); if neither is possible, **flag the gap to the user** rather than
reporting the cross-browser gate as PASS.

## The Phase 5 matrix

Capture every implemented view across `{light, dark}` × `{phone ~375, tablet ~768/1024, desktop
~1280}` × `{chromium, firefox, webkit}`. That's the screenshot set you present at sign-off. You don't
need every cell for a trivial view — but every distinct layout, and the `/brand` page, should cover the
full matrix, and any layout that changes at a breakpoint must be shown on both sides of it. Re-run the
rendered-contrast check at these widths too: a reflow can change what overlaps what.

## Common responsive / cross-engine gotchas

- **Horizontal overflow** at narrow widths (the #1 RWD bug) — check 320–375px first.
- **`100vh` overflow** on mobile → use `dvh`/`svh`.
- **iOS:** inputs need ≥16px font or Safari auto-zooms on focus; honor safe-area insets
  (`env(safe-area-inset-*)`) for notches; mind the tap-highlight color.
- **WebKit/Safari:** older flex `gap`, `backdrop-filter`, `position: sticky` inside `overflow`,
  date/time input styling. Let Autoprefixer / Tailwind emit `-webkit-` prefixes — don't hand-write
  them.
- **Firefox:** scrollbar styling, the odd grid/subgrid edge case, form-control rendering.
