#!/usr/bin/env node
// measure-rendered-contrast.mjs — the RENDERED half of the dual contrast gate.
//
// WHAT: the static gate (check-contrast.mjs) proves the tokens; this proves the painted
// pixels. It loads real pages in Chromium, samples the computed color of every key text
// role against its effective (ancestor-composited) background, and reports WCAG ratios for
// both themes. Fails (exit 1) on any pair under 4.5:1 (3:1 for samples marked large).
// This is the Phase 5 "measure the actual painted color" step, as a repeatable script
// instead of a console session — see references/accessibility-verification.md.
//
// It is a PARAMETERIZED template, not a from-scratch write — fill in two spots:
//   1. SAMPLES — one row per [route, selector, label, large?]: every text role the site
//      renders (body, muted/meta, links, text on color blocks, long-form prose). Selector
//      gotcha: `form label` can first-match a hidden honeypot label — target explicitly.
//   2. setTheme — defaults to a localStorage key applied via addInitScript BEFORE load
//      (matches a boot-script theme approach with no flash) plus prefers-color-scheme
//      emulation. Adjust the key/mechanism to the repo.
//
// WHY parsing happens in Node, not the page: with oklch() design tokens, modern Chromium
// serializes computed colors as `oklch(...)` — and colors carrying an opacity modifier as
// `oklab(... / a)`. Canvas fillStyle normalization no longer canonicalizes these to rgb,
// so regex-for-rgb parsers silently fail. This script parses oklch/oklab/rgb/hex itself
// and composites alpha (both semi-transparent backgrounds and semi-transparent text).
//
// WHAT IT CANNOT MODEL (fail-closed): the compositor stacks ancestor background-COLORS only.
// If the element or any ancestor paints a background-image (gradient, photo) or a painted
// ::before/::after, the real ground is unknowable here — those samples are reported as
// UNSUPPORTED and count as failures until verified manually (DevTools eyedropper / pixel
// sampling). Overlay SIBLINGS (an absolutely-positioned scrim between the text and its
// ancestor ground) are NOT detectable at all — see accessibility-verification.md.
//
// USAGE:   node scripts/measure-rendered-contrast.mjs [baseURL]
//          (default http://localhost:4321 — start the dev/preview server first;
//           wire to `task verify:contrast`, see assets/Taskfile.design.yml)

import { chromium } from "@playwright/test";

const BASE = process.argv[2] ?? "http://localhost:4321";
const THEME_STORAGE_KEY = "theme"; // localStorage key the repo's boot script reads

// [route, selector, label, large?] — FILL IN for the repo. Cover every text role.
const SAMPLES = [
  ["/", "h1", "Hero heading", true],
  ["/", "main p", "Body copy"],
  // ["/", "footer a", "Footer link on dark ground"],
  // ["/blog/some-post", ".prose p", "Prose body (the classic runtime-override victim)"],
  // ["/brand", "[data-brand-specimen=\"voice-do\"] li", "Specimen body on raised surface"],
];

/* ---------- color parsing (oklch / oklab / rgb / hex) → sRGB 0–255 ---------- */

function oklchToRgb(L, C, H) {
  const hr = (H * Math.PI) / 180;
  const a = C * Math.cos(hr);
  const b = C * Math.sin(hr);
  const l_ = L + 0.3963377774 * a + 0.2158037573 * b;
  const m_ = L - 0.1055613458 * a - 0.0638541728 * b;
  const s_ = L - 0.0894841775 * a - 1.291485548 * b;
  const l = l_ ** 3;
  const m = m_ ** 3;
  const s = s_ ** 3;
  return [
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
  ].map((c) => {
    const v = Math.min(1, Math.max(0, c));
    return (v <= 0.0031308 ? v * 12.92 : 1.055 * v ** (1 / 2.4) - 0.055) * 255;
  });
}

// Parse a computed CSS color string → { rgb:[r,g,b], alpha } or null.
function parseColor(str) {
  if (!str || str === "transparent") return null;
  const s = str.trim().toLowerCase();
  // oklch(L C H [/ a]) and oklab(L a b [/ a]) — opacity modifiers serialize via oklab.
  const lab = s.startsWith("oklab(");
  if (s.startsWith("oklch(") || lab) {
    const inner = s.slice(6, s.lastIndexOf(")"));
    const [coords, alphaPart] = inner.split("/");
    const nums = coords.trim().split(/\s+/).map(parseFloat);
    if (nums.length < 3 || nums.some(Number.isNaN)) return null;
    const alpha = alphaPart
      ? alphaPart.trim().endsWith("%")
        ? parseFloat(alphaPart) / 100
        : parseFloat(alphaPart)
      : 1;
    const [L, x, y] = nums;
    const [C, H] = lab
      ? [Math.sqrt(x * x + y * y), (Math.atan2(y, x) * 180) / Math.PI]
      : [x, y];
    return { rgb: oklchToRgb(L, C, H), alpha };
  }
  const m = s.match(/rgba?\(([^)]+)\)/);
  if (m) {
    const parts = m[1].split(/[\s,/]+/).map(parseFloat);
    return { rgb: parts.slice(0, 3), alpha: parts[3] ?? 1 };
  }
  if (s.startsWith("#")) {
    const h = s.slice(1);
    return {
      rgb: [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16)),
      alpha: 1,
    };
  }
  return null;
}

/* ---------- WCAG ---------- */

const lin = (c) => {
  const v = c / 255;
  return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
};
const lum = ([r, g, b]) => 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
function ratio(fg, bg) {
  const [hi, lo] = [lum(fg), lum(bg)].sort((a, b) => b - a);
  return (hi + 0.05) / (lo + 0.05);
}

/* ---------- run ---------- */

const browser = await chromium.launch();

let failures = 0;
for (const theme of ["light", "dark"]) {
  console.log(`\n=== ${theme.toUpperCase()} ===`);
  // FRESH page (and context) per theme: init scripts persist for a page's
  // lifetime and run in undefined order, so re-adding one per pass on a shared
  // page would leave BOTH themes' scripts racing on later navigations.
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  await page.emulateMedia({ colorScheme: theme });
  await page.addInitScript(
    ([key, t]) => localStorage.setItem(key, t),
    [THEME_STORAGE_KEY, theme],
  );
  let current = null;
  for (const [route, selector, label, large] of SAMPLES) {
    if (current !== route) {
      await page.goto(BASE + route, { waitUntil: "networkidle" });
      current = route;
    }
    // Raw strings out of the page; parsing/compositing happens in Node (see header).
    const sample = await page.evaluate((sel) => {
      const el = document.querySelector(sel);
      if (!el) return { missing: true };
      const fgRaw = getComputedStyle(el).color;
      const bgChain = [];
      const painted = []; // grounds the solid-color compositor can't model
      const transparent = "rgba(0, 0, 0, 0)";
      let node = el;
      while (node && node.nodeType === 1) {
        const cs = getComputedStyle(node);
        const tag = node.tagName.toLowerCase();
        if (cs.backgroundImage && cs.backgroundImage !== "none")
          painted.push(`background-image on <${tag}>`);
        for (const pseudo of ["::before", "::after"]) {
          const ps = getComputedStyle(node, pseudo);
          if (
            ps.content !== "none" &&
            ((ps.backgroundImage && ps.backgroundImage !== "none") ||
              (ps.backgroundColor &&
                ps.backgroundColor !== transparent &&
                ps.backgroundColor !== "transparent"))
          )
            painted.push(`painted ${pseudo} on <${tag}>`);
        }
        bgChain.push(cs.backgroundColor);
        node = node.parentElement;
      }
      return { fgRaw, bgChain, painted };
    }, selector);

    if (sample.missing) {
      failures++;
      console.log(`  FAIL ${label} — selector not found (${selector})`);
      continue;
    }

    // Fail-closed: a gradient/image/pseudo-element ground would make the
    // solid-color ratio below fiction — never report AA against it.
    if (sample.painted.length > 0) {
      failures++;
      console.log(
        `  UNSUPPORTED ${label} — ${[...new Set(sample.painted)].join("; ")}; ` +
          `measure manually (pixel-sample) and record the ratio`,
      );
      continue;
    }

    const fg = parseColor(sample.fgRaw);
    // Composite the ancestor backgrounds bottom-up over white.
    const layers = sample.bgChain.map(parseColor).filter((c) => c && c.alpha > 0);
    let bg = [255, 255, 255];
    for (let i = layers.length - 1; i >= 0; i--) {
      const { rgb, alpha } = layers[i];
      bg = bg.map((base, k) => rgb[k] * alpha + base * (1 - alpha));
    }
    if (!fg) {
      failures++;
      console.log(`  FAIL ${label} — unparseable color "${sample.fgRaw}"`);
      continue;
    }
    // Semi-transparent text paints blended into its ground — measure that.
    const fgEffective =
      fg.alpha < 1
        ? fg.rgb.map((c, k) => c * fg.alpha + bg[k] * (1 - fg.alpha))
        : fg.rgb;

    const r = ratio(fgEffective, bg);
    const need = large ? 3 : 4.5;
    const ok = r >= need;
    if (!ok) failures++;
    console.log(
      `  ${ok ? "PASS" : "FAIL"} ${label.padEnd(38)} ${r.toFixed(2)}:1 (need ${need})`,
    );
  }
  await page.close();
}

await browser.close();
console.log(
  failures === 0
    ? "\nRendered contrast: all pass"
    : `\n${failures} rendered pair(s) FAIL`,
);
process.exit(failures === 0 ? 0 : 1);
