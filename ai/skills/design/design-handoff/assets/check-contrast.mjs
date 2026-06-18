#!/usr/bin/env node
// check-contrast.mjs — static WCAG-AA contrast gate for a shadcn/Tailwind-v4 globals.css
//
// WHAT: parses the semantic color tokens out of a globals.css (the `:root` and `.dark`
// blocks), then proves every foreground/background pair the design relies on meets WCAG AA
// in BOTH themes. It is the *static* half of the dual contrast gate — necessary but not
// sufficient (it sees the tokens, not the color that actually paints; a runtime layer like
// the Tailwind Typography `.prose` plugin can still override a token). Always pair it with the
// rendered-page measurement in Phase 5. See references/accessibility-verification.md.
//
// WHY zero-dependency: this script is bundled by the design-handoff skill and dropped into
// arbitrary target repos to back `task lint:design`. Keeping it dependency-free (pure Node,
// no culori/style-dictionary) means it runs anywhere with just `node` and never needs an
// install step or a lockfile change in the repo being set up.
//
// USAGE:   node check-contrast.mjs [path/to/globals.css]   (default: src/styles/globals.css)
//          node check-contrast.mjs --json [path]           (machine-readable output)
//
// EXIT:    0  every text pair meets AA in every theme present
//          1  at least one text pair fails AA (the gate is red)
//          2  usage/parse error (file missing, no :root block, nothing parseable)
//
// THRESHOLDS (WCAG 2.2 SC 1.4.3 / 1.4.11): normal text 4.5:1, large text & UI components 3:1.
// Ratios are NOT rounded before comparison (4.499 fails 4.5). The static gate can't know a
// token's rendered font-size, so it holds text pairs to the strict 4.5; large-text exceptions
// are judged on the rendered page. Subtle-by-design UI pairs (border/input/ring) are reported
// as warnings, not failures, so an intentionally faint divider doesn't block the build.

import { readFileSync } from "node:fs";

// ---------- color math: OKLCH / hex / rgb -> linear sRGB -> relative luminance ----------

// OKLCH -> linear sRGB (Björn Ottosson's reference matrices). Returns linear-light r,g,b.
function oklchToLinearSrgb(L, C, H) {
  const hr = (H * Math.PI) / 180;
  const a = C * Math.cos(hr);
  const b = C * Math.sin(hr);
  const l_ = L + 0.3963377774 * a + 0.2158037573 * b;
  const m_ = L - 0.1055613458 * a - 0.0638541728 * b;
  const s_ = L - 0.0894841775 * a - 1.291485548 * b;
  const l = l_ ** 3;
  const m = m_ ** 3;
  const s = s_ ** 3;
  return {
    r: 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    g: -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    b: -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
  };
}

const clamp01 = (x) => Math.min(1, Math.max(0, x));

// gamma sRGB channel (0..1) -> linear-light (WCAG 2.x linearization).
function srgbChannelToLinear(v) {
  return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
}

// Parse any supported CSS color into linear-light {r,g,b} in [0,1], or null if unparseable.
// All inputs are normalized to linear light so a single luminance formula covers them.
function parseColorToLinear(raw) {
  const value = raw.trim().toLowerCase();

  if (value.startsWith("oklch(")) {
    const inner = value.slice(6, value.lastIndexOf(")"));
    const [coords] = inner.split("/"); // drop any "/ alpha"
    const nums = coords
      .trim()
      .split(/[\s,]+/)
      .filter(Boolean)
      .map((t) =>
        t === "none"
          ? 0
          : t.endsWith("%")
            ? parseFloat(t) / 100
            : parseFloat(t),
      );
    if (nums.length < 3 || nums.some(Number.isNaN)) return null;
    const lin = oklchToLinearSrgb(nums[0], nums[1], nums[2]);
    return { r: clamp01(lin.r), g: clamp01(lin.g), b: clamp01(lin.b) };
  }

  if (value.startsWith("#")) {
    let hex = value.slice(1);
    if (hex.length === 3 || hex.length === 4)
      hex = [...hex].map((c) => c + c).join("");
    if (hex.length !== 6 && hex.length !== 8) return null;
    const r = parseInt(hex.slice(0, 2), 16) / 255;
    const g = parseInt(hex.slice(2, 4), 16) / 255;
    const b = parseInt(hex.slice(4, 6), 16) / 255;
    if ([r, g, b].some(Number.isNaN)) return null;
    return {
      r: srgbChannelToLinear(r),
      g: srgbChannelToLinear(g),
      b: srgbChannelToLinear(b),
    };
  }

  if (value.startsWith("rgb(") || value.startsWith("rgba(")) {
    const inner = value.slice(value.indexOf("(") + 1, value.lastIndexOf(")"));
    const [coords] = inner.split("/");
    const parts = coords
      .split(/[\s,]+/)
      .filter(Boolean)
      .slice(0, 3);
    if (parts.length < 3) return null;
    const chan = parts.map((p) =>
      p.endsWith("%") ? parseFloat(p) / 100 : parseFloat(p) / 255,
    );
    if (chan.some(Number.isNaN)) return null;
    return {
      r: srgbChannelToLinear(clamp01(chan[0])),
      g: srgbChannelToLinear(clamp01(chan[1])),
      b: srgbChannelToLinear(clamp01(chan[2])),
    };
  }

  return null; // var(), hsl(), named colors, etc. — skipped, not failed
}

const luminance = (c) => 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;

function contrastRatio(c1, c2) {
  const l1 = luminance(c1);
  const l2 = luminance(c2);
  const [hi, lo] = l1 >= l2 ? [l1, l2] : [l2, l1];
  return (hi + 0.05) / (lo + 0.05);
}

// ---------- globals.css parsing ----------

// Pull the declaration body of the first matching `<selector> { ... }` rule (flat, no nesting).
function extractBlock(css, selector) {
  const re = new RegExp(
    `(?:^|[}\\s])${selector.replace(".", "\\.")}\\s*\\{([^}]*)\\}`,
    "m",
  );
  const m = css.match(re);
  return m ? m[1] : null;
}

// Parse `--token: value;` declarations from a block body into a Map.
function parseTokens(blockBody) {
  const tokens = new Map();
  const re = /--([\w-]+)\s*:\s*([^;]+);/g;
  let m;
  while ((m = re.exec(blockBody)) !== null) tokens.set(m[1], m[2].trim());
  return tokens;
}

// ---------- the pairs we audit ----------

// Text pairs are hard failures at 4.5:1. `bg` is the surface, `fg` the ink on it.
const TEXT_PAIRS = [
  ["background", "foreground"],
  ["card", "card-foreground"],
  ["popover", "popover-foreground"],
  ["primary", "primary-foreground"],
  ["secondary", "secondary-foreground"],
  ["muted", "muted-foreground"],
  ["accent", "accent-foreground"],
  ["destructive", "destructive-foreground"],
];

// UI/non-text pairs: reported at 3:1 but warn-only (subtle dividers are legitimately faint).
const UI_PAIRS = [
  ["border", "background"],
  ["input", "background"],
  ["ring", "background"],
];

function auditTheme(label, tokens) {
  const rows = [];
  let failures = 0;

  const evaluate = (bgName, fgName, need, kind) => {
    const bgRaw = tokens.get(bgName);
    const fgRaw = tokens.get(fgName);
    if (bgRaw === undefined || fgRaw === undefined) {
      const missing = bgRaw === undefined ? `--${bgName}` : `--${fgName}`;
      rows.push({
        kind,
        status: "skip",
        pair: `${fgName} / ${bgName}`,
        note: `missing ${missing}`,
      });
      return;
    }
    const bg = parseColorToLinear(bgRaw);
    const fg = parseColorToLinear(fgRaw);
    if (!bg || !fg) {
      rows.push({
        kind,
        status: "skip",
        pair: `${fgName} / ${bgName}`,
        note: "unparseable color",
      });
      return;
    }
    const ratio = contrastRatio(bg, fg);
    const pass = ratio >= need; // no rounding
    let status;
    if (pass) status = "PASS";
    else if (kind === "ui") status = "warn";
    else {
      status = "FAIL";
      failures += 1;
    }
    rows.push({ kind, status, pair: `${fgName} / ${bgName}`, ratio, need });
  };

  for (const [bg, fg] of TEXT_PAIRS) evaluate(bg, fg, 4.5, "text");
  for (const [bg, fg] of UI_PAIRS) evaluate(bg, fg, 3.0, "ui");
  return { label, rows, failures };
}

// ---------- runner ----------

function fmtRow(r) {
  const ratio =
    r.ratio === undefined ? "" : `${r.ratio.toFixed(2)}:1`.padStart(8);
  const need = r.need === undefined ? "" : ` (need ${r.need})`;
  const note = r.note ? `  ${r.note}` : "";
  return `  ${r.status.padEnd(4)} ${r.pair.padEnd(36)} ${ratio}${need}${note}`;
}

function main() {
  const argv = process.argv.slice(2);
  const asJson = argv.includes("--json");
  const path =
    argv.find((a) => !a.startsWith("--")) ?? "src/styles/globals.css";

  let css;
  try {
    css = readFileSync(path, "utf8");
  } catch {
    console.error(`check-contrast: cannot read ${path}`);
    process.exit(2);
  }

  const rootBody = extractBlock(css, ":root");
  if (rootBody === null) {
    console.error(`check-contrast: no :root block found in ${path}`);
    process.exit(2);
  }
  const darkBody = extractBlock(css, ".dark");

  const themes = [auditTheme("light (:root)", parseTokens(rootBody))];
  if (darkBody !== null)
    themes.push(auditTheme("dark (.dark)", parseTokens(darkBody)));

  const evaluated = themes
    .flatMap((t) => t.rows)
    .filter((r) => r.status !== "skip").length;
  if (evaluated === 0) {
    console.error(
      `check-contrast: no parseable foreground/background pairs in ${path}`,
    );
    process.exit(2);
  }

  const totalFailures = themes.reduce((n, t) => n + t.failures, 0);

  if (asJson) {
    console.log(JSON.stringify({ path, totalFailures, themes }, null, 2));
  } else {
    console.log(`\ncontrast report — ${path}`);
    for (const t of themes) {
      console.log(`\n${t.label}`);
      for (const r of t.rows) console.log(fmtRow(r));
    }
    if (darkBody === null)
      console.log(`\n  note: no .dark block — dark mode is unverified here`);
    console.log(
      totalFailures === 0
        ? `\nResult: all text pairs meet AA → pass`
        : `\nResult: ${totalFailures} text pair(s) below AA → fail`,
    );
  }

  process.exit(totalFailures === 0 ? 0 : 1);
}

main();
