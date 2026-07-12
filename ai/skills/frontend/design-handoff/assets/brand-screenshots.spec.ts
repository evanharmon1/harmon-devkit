// brand-screenshots.spec.ts — bundled TEMPLATE for the design-handoff cross-browser sweep.
//
// Runs under `task verify:browsers` (i.e. `npx playwright test tests/brand-screenshots.spec.ts`).
// The engine × device axis comes from playwright.config.ts `projects` (chromium / firefox / webkit
// + mobile devices like Pixel/iPhone); this spec adds the route × theme axis and writes one
// full-page PNG per route × theme per project, into screenshots/<project>/. It also asserts the
// "no horizontal overflow, ever" rule on every route × theme × project — that guard catches real
// bugs (a lost `hidden` class, an unconstrained intrinsic-width SVG) that green builds sail past.
//
// It is a PARAMETERIZED template, not a from-scratch write — fill in three spots for the repo:
//   1. ROUTES below (always include "/brand"; add the feature's pages).
//   2. playwright.config.ts must set `use.baseURL` and a `webServer` that serves the production
//      build (`build && preview` — see the bundled playwright.config.ts; never the dev server).
//      Astro repos: disable the dev toolbar (`devToolbar: { enabled: false }` in astro.config) —
//      its floating pill lands mid-page in fullPage captures and photobombs every screenshot.
//   3. THEME_STORAGE_KEY / setTheme() — the default seeds localStorage BEFORE load (via
//      addInitScript) so a boot-script theme applies with no flash and islands hydrate in the
//      right theme, plus emulates prefers-color-scheme. If the repo instead toggles a bare class
//      with no boot script, swap in the post-load classList line noted inside setTheme().
import { test, type Page } from "@playwright/test";

const ROUTES = ["/", "/brand"];
const THEMES = ["light", "dark"] as const;
const THEME_STORAGE_KEY = "theme"; // localStorage key the repo's boot script reads

async function setTheme(page: Page, theme: (typeof THEMES)[number]) {
  await page.emulateMedia({ colorScheme: theme }); // for prefers-color-scheme apps
  await page.addInitScript(
    ([key, t]) => localStorage.setItem(key, t), // boot-script apps read this pre-paint
    [THEME_STORAGE_KEY, theme] as const,
  );
  // No boot script? Toggle the class after goto instead:
  //   await page.evaluate((t) => document.documentElement.classList.toggle("dark", t === "dark"), theme);
}

const slugify = (route: string) =>
  route.replace(/[^\w]+/g, "_").replace(/^_|_$/g, "") || "home";

for (const route of ROUTES) {
  for (const theme of THEMES) {
    test(`${route} [${theme}]`, async ({ page }, testInfo) => {
      await setTheme(page, theme); // BEFORE goto — the init script must run at load
      await page.goto(route, { waitUntil: "networkidle" });
      await page.evaluate(async () => {
        await document.fonts.ready; // avoid a flash of unstyled text in the capture
      });
      await page.waitForTimeout(700); // let entrance animations settle
      // Browsers cap captures at 32767 device px per dimension; on 3x mobile
      // devices a tall page (a full /brand) exceeds it. A single capped clip
      // would silently drop everything below the cap, so capture stacked
      // chunks (-part1, -part2, …) that cover through the document bottom.
      const { height, width, dpr } = await page.evaluate(() => ({
        height: document.documentElement.scrollHeight,
        width: document.documentElement.clientWidth,
        dpr: window.devicePixelRatio || 1,
      }));
      const maxCss = Math.floor(32000 / dpr);
      const base = `screenshots/${testInfo.project.name}/${slugify(route)}-${theme}`;
      if (height > maxCss) {
        for (let i = 0; i * maxCss < height; i++) {
          const y = i * maxCss;
          await page.screenshot({
            path: `${base}-part${i + 1}.png`,
            fullPage: true, // with fullPage, clip is document-relative
            clip: { x: 0, y, width, height: Math.min(maxCss, height - y) },
          });
        }
      } else {
        await page.screenshot({ path: `${base}.png`, fullPage: true });
      }
    });
  }
}

// Horizontal-overflow guard: the mobile-first "no horizontal scroll, ever" rule, asserted on
// every route × theme × project — including the mobile devices, where 360px-class viewports
// surface it first. Runs per theme because dark-only overflow is real (a dark-mode-only badge
// or scrollbar-gutter change can overflow while light passes).
for (const route of ROUTES) {
  for (const theme of THEMES) {
    test(`${route} has no horizontal overflow [${theme}]`, async ({ page }) => {
      await setTheme(page, theme); // BEFORE goto — same rule as the screenshot loop
      await page.goto(route, { waitUntil: "networkidle" });
      const overflow = await page.evaluate(
        () =>
          document.documentElement.scrollWidth -
          document.documentElement.clientWidth,
      );
      test
        .expect(overflow, `scrollWidth exceeds viewport by ${overflow}px`)
        .toBeLessThanOrEqual(0);
    });
  }
}

// Optional: per-specimen shots on /brand for component-level visual regression, using the
// data-brand-specimen hooks from brand-page.md. Uncomment and adapt.
//
// test("brand specimens", async ({ page }, testInfo) => {
//   await page.goto("/brand", { waitUntil: "networkidle" });
//   for (const el of await page.locator("[data-brand-specimen]").all()) {
//     const name = await el.getAttribute("data-brand-specimen");
//     await el.screenshot({ path: `screenshots/${testInfo.project.name}/specimen-${name}.png` });
//   }
// });
