// playwright.config.ts — bundled TEMPLATE for the design-handoff cross-browser gate.
//
// Serves the built site and runs assets/brand-screenshots.spec.ts across the three
// engines + mobile, for `task verify:browsers`. Copy to the repo root and adjust
// the two FILL spots (the build/serve command + PORT, and the device set if you
// want different targets). Pairs with assets/brand-screenshots.spec.ts.
//
// Why `build && preview` over `dev`: the production build is what ships and has no
// HMR/error-overlay flicker, so screenshots and the horizontal-overflow guard are
// stabler and truer. Swap to your dev command if a build is too slow to gate on.
//
// Astro note: disable the dev toolbar (`devToolbar: { enabled: false }` in
// astro.config) — its floating pill lands mid-page in full-page captures and
// photobombs every screenshot.
import { defineConfig, devices } from "@playwright/test";

// FILL: the port your `preview`/`start` server listens on.
// Astro preview → 4321 · Vite preview → 4173 · Next start → 3000.
const PORT = 4321;
const baseURL = `http://localhost:${PORT}`;

export default defineConfig({
  testDir: "tests",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  reporter: [["list"]],
  use: { baseURL, trace: "off" },
  // The engine × device axis (the spec adds the route × theme axis on top).
  // Mobile Safari is iOS WebKit; Mobile Chrome is Android Chromium — together
  // they cover the phone field. Swap iPad in if tablet layouts differ.
  projects: [
    { name: "chromium", use: { ...devices["Desktop Chrome"] } },
    { name: "firefox", use: { ...devices["Desktop Firefox"] } },
    { name: "webkit", use: { ...devices["Desktop Safari"] } },
    { name: "Mobile Safari", use: { ...devices["iPhone 13"] } },
    { name: "Mobile Chrome", use: { ...devices["Pixel 5"] } },
  ],
  webServer: {
    // FILL: the build+serve command for the repo.
    // Vite: `pnpm build && pnpm preview --port <PORT>` · Next: `pnpm build && pnpm start`.
    command: `pnpm build && pnpm preview --port ${PORT}`,
    url: baseURL,
    timeout: 120_000,
    reuseExistingServer: !process.env.CI,
    stdout: "ignore",
    stderr: "pipe",
  },
});
