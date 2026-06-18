// brand-screenshots.spec.ts — bundled TEMPLATE for the design-handoff cross-browser sweep.
//
// Runs under `task verify:browsers` (i.e. `npx playwright test`). The engine × device axis comes from
// playwright.config.ts `projects` (chromium / firefox / webkit + iPhone / iPad); this spec adds the
// route × theme axis and writes one full-page PNG per route × theme per project, into
// screenshots/<project>/.
//
// It is a PARAMETERIZED template, not a from-scratch write — fill in three spots for the repo:
//   1. ROUTES below (always include "/brand"; add the feature's pages).
//   2. playwright.config.ts must set `use.baseURL` and a `webServer` that starts the dev server.
//   3. setTheme() defaults to shadcn's `.dark` class on <html>; change it only if the repo toggles
//      dark mode differently (a data attribute, a cookie, etc.).
import { test, type Page } from "@playwright/test";

const ROUTES = ["/", "/brand"];
const THEMES = ["light", "dark"] as const;

async function setTheme(page: Page, theme: (typeof THEMES)[number]) {
  await page.emulateMedia({ colorScheme: theme }); // for prefers-color-scheme apps
  await page.evaluate((t) => {
    document.documentElement.classList.toggle("dark", t === "dark"); // for class-based (shadcn) apps
  }, theme);
}

const slugify = (route: string) =>
  route.replace(/[^\w]+/g, "_").replace(/^_|_$/g, "") || "home";

for (const route of ROUTES) {
  for (const theme of THEMES) {
    test(`${route} [${theme}]`, async ({ page }, testInfo) => {
      await page.goto(route, { waitUntil: "networkidle" });
      await setTheme(page, theme);
      await page.evaluate(async () => {
        await document.fonts.ready; // avoid a flash of unstyled text in the capture
      });
      await page.screenshot({
        path: `screenshots/${testInfo.project.name}/${slugify(route)}-${theme}.png`,
        fullPage: true,
      });
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
