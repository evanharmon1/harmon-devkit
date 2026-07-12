#!/usr/bin/env node
// check-contrast.mjs — static WCAG-AA contrast gate for a shadcn/Tailwind-v4 globals.css
//
// WHAT: parses the semantic color tokens out of a globals.css (the `@theme`, `:root` and
// `.dark` blocks, cascade-merged so dark inherits what it doesn't redefine), resolves
// `var(--x)` indirection to the real colors, then proves every foreground/background pair
// the design relies on — including the status `-text` roles it auto-discovers and checks on
// the light grounds — meets WCAG AA in BOTH themes. It is the *static* half of the dual contrast gate — necessary but not
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

// ALPHA: translucent colors are never scored as their opaque value. A translucent foreground is
// composited over the audited background (in gamma sRGB, as browsers blend) before scoring; a
// translucent background can't be composited statically (what's beneath is unknowable here), so
// the pair is reported as a skip — verify it on the rendered page (Phase 5) — never as a PASS.

// ---------- color math: OKLCH / hex / rgb -> gamma sRGB (+ alpha) -> relative luminance ----------

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

// linear-light channel (0..1) -> gamma sRGB (inverse of the above).
function linearChannelToSrgb(v) {
  return v <= 0.0031308 ? v * 12.92 : 1.055 * v ** (1 / 2.4) - 0.055;
}

// "0.6", "60%", or undefined -> alpha in [0,1] (undefined means opaque).
function parseAlpha(part) {
  if (part === undefined) return 1;
  const t = part.trim();
  const a = t.endsWith("%") ? parseFloat(t) / 100 : parseFloat(t);
  return Number.isNaN(a) ? 1 : clamp01(a);
}

// Parse any supported CSS color into { r, g, b, alpha } — channels gamma-encoded
// sRGB in [0,1] — or null if unparseable. Gamma (not linear) is the working space
// so alpha compositing below matches how browsers actually blend.
function parseColor(raw) {
  const value = raw.trim().toLowerCase();

  if (value.startsWith("oklch(")) {
    const inner = value.slice(6, value.lastIndexOf(")"));
    const [coords, alphaPart] = inner.split("/");
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
    return {
      r: linearChannelToSrgb(clamp01(lin.r)),
      g: linearChannelToSrgb(clamp01(lin.g)),
      b: linearChannelToSrgb(clamp01(lin.b)),
      alpha: parseAlpha(alphaPart),
    };
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
    const alpha = hex.length === 8 ? parseInt(hex.slice(6, 8), 16) / 255 : 1;
    return { r, g, b, alpha: Number.isNaN(alpha) ? 1 : alpha };
  }

  if (value.startsWith("rgb(") || value.startsWith("rgba(")) {
    const inner = value.slice(value.indexOf("(") + 1, value.lastIndexOf(")"));
    const [coords, slashAlpha] = inner.split("/");
    const parts = coords.split(/[\s,]+/).filter(Boolean);
    if (parts.length < 3) return null;
    const chan = parts
      .slice(0, 3)
      .map((p) => (p.endsWith("%") ? parseFloat(p) / 100 : parseFloat(p) / 255));
    if (chan.some(Number.isNaN)) return null;
    // Alpha rides either after "/" (modern) or as the 4th component (legacy rgba()).
    const alpha = parseAlpha(slashAlpha ?? parts[3]);
    return {
      r: clamp01(chan[0]),
      g: clamp01(chan[1]),
      b: clamp01(chan[2]),
      alpha,
    };
  }

  return null; // var(), hsl(), named colors, etc. — skipped, not failed
}

// Source-over composite of a translucent color onto an opaque backdrop (gamma
// space, matching browser blending). Returns an opaque color.
function compositeOver(fg, backdrop) {
  const a = fg.alpha;
  return {
    r: fg.r * a + backdrop.r * (1 - a),
    g: fg.g * a + backdrop.g * (1 - a),
    b: fg.b * a + backdrop.b * (1 - a),
    alpha: 1,
  };
}

const luminance = (c) =>
  0.2126 * srgbChannelToLinear(c.r) +
  0.7152 * srgbChannelToLinear(c.g) +
  0.0722 * srgbChannelToLinear(c.b);

function contrastRatio(c1, c2) {
  const l1 = luminance(c1);
  const l2 = luminance(c2);
  const [hi, lo] = l1 >= l2 ? [l1, l2] : [l2, l1];
  return (hi + 0.05) / (lo + 0.05);
}

// ---------- globals.css parsing ----------

// Pull the declaration body of the first matching `<selector> { ... }` rule,
// with balanced-brace matching so nested blocks (@keyframes inside @theme, a
// @media inside a layer) don't truncate the capture.
function extractBlock(css, selector) {
  const startRe = new RegExp(
    `(?:^|[}\\s])${selector.replace(/[.\\]/g, "\\$&")}\\s*\\{`,
    "m",
  );
  const m = css.match(startRe);
  if (!m) return null;
  const open = m.index + m[0].length;
  let depth = 1;
  for (let i = open; i < css.length; i++) {
    if (css[i] === "{") depth++;
    else if (css[i] === "}" && --depth === 0) return css.slice(open, i);
  }
  return null;
}

// Every `@theme` block's declarations (constants like --color-brand), merged.
// Needed so var() chains that terminate in @theme constants resolve.
function extractThemeTokens(css) {
  const tokens = new Map();
  const re = /@theme[^{]*\{/g;
  let m;
  while ((m = re.exec(css)) !== null) {
    const open = m.index + m[0].length;
    let depth = 1;
    for (let i = open; i < css.length; i++) {
      if (css[i] === "{") depth++;
      else if (css[i] === "}" && --depth === 0) {
        for (const [k, v] of parseTokens(css.slice(open, i))) tokens.set(k, v);
        break;
      }
    }
  }
  return tokens;
}

// Parse `--token: value;` declarations from a block body into a Map.
function parseTokens(blockBody) {
  const tokens = new Map();
  const re = /--([\w-]+)\s*:\s*([^;]+);/g;
  let m;
  while ((m = re.exec(blockBody)) !== null) tokens.set(m[1], m[2].trim());
  return tokens;
}

// Resolve a value that is entirely a var() reference (with optional fallback)
// through the token map, so the canonical indirection this skill prescribes
// (`--background: var(--paper)`) audits the real color instead of skipping.
function resolveVar(tokens, raw) {
  let value = raw?.trim();
  for (let hops = 0; hops < 16 && value; hops++) {
    const m = value.match(/^var\(\s*--([\w-]+)\s*(?:,\s*([^)]+))?\)$/);
    if (!m) break;
    value = tokens.get(m[1])?.trim() ?? m[2]?.trim();
  }
  return value;
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

// REPO-SPECIFIC text pairs — extend when the design renders text on grounds
// beyond the shadcn defaults AND beyond the auto-discovered `-text` roles below
// (a brand marquee, a footer well, constant on-dark chrome helpers). Names are
// token names WITHOUT the leading `--`; @theme constants use their full name
// (e.g. "color-blue"). Example (a constant blue marquee + an on-dark helper):
//   ["color-blue", "color-on-dark-soft"],
const EXTRA_TEXT_PAIRS = [];

// AUTO-DISCOVERED text pairs. The skill's core rule is "status text on light uses
// the `-text` role, never the bright fill" — so every `*-text` token
// (success-text, info-text, warning-text, destructive-text, …) is proven as text
// on the common light grounds (background + card) BY DEFAULT, not only when the
// operator remembers to hand-fill EXTRA_TEXT_PAIRS. muted-foreground gets the same
// treatment (it renders on the page and on cards, not just the muted surface).
// This is what catches a `-text` role that's AA on paper (#fff) but sub-AA on a
// warm/tinted page background — a real failure the fixed default pairs miss.
function autoTextPairs(tokens) {
  const pairs = [];
  const on = (surface, fg) => {
    if (tokens.has(surface) && tokens.has(fg)) pairs.push([surface, fg]);
  };
  for (const name of tokens.keys()) {
    if (name.startsWith("color-")) continue; // skip the @theme mirror (var()s back → dupes)
    if (/-text$/.test(name)) {
      on("background", name);
      on("card", name);
    }
  }
  on("background", "muted-foreground");
  on("card", "muted-foreground");
  return pairs;
}

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
    const bgRaw = resolveVar(tokens, tokens.get(bgName));
    const fgRaw = resolveVar(tokens, tokens.get(fgName));
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
    const bg = parseColor(bgRaw);
    const fg = parseColor(fgRaw);
    if (!bg || !fg) {
      rows.push({
        kind,
        status: "skip",
        pair: `${fgName} / ${bgName}`,
        note: "unparseable color",
      });
      return;
    }
    // A translucent BACKGROUND can't be scored statically — what it composites
    // onto is unknowable here. Never PASS it on the opaque value: report it as
    // unsupported and require the rendered check (Phase 5).
    if (bg.alpha < 1) {
      rows.push({
        kind,
        status: "skip",
        pair: `${fgName} / ${bgName}`,
        note: `translucent background (alpha ${+bg.alpha.toFixed(3)}) — unsupported statically, verify rendered (Phase 5)`,
      });
      return;
    }
    // A translucent FOREGROUND paints blended into its ground — score the
    // composited color, not the opaque one.
    const fgEffective = fg.alpha < 1 ? compositeOver(fg, bg) : fg;
    const ratio = contrastRatio(bg, fgEffective);
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

  // Text pairs from all three sources (fixed defaults, repo-specific, and the
  // auto-discovered `-text` roles), de-duplicated on a `bg|fg` key.
  const seen = new Set();
  for (const [bg, fg] of [...TEXT_PAIRS, ...EXTRA_TEXT_PAIRS, ...autoTextPairs(tokens)]) {
    const key = `${bg}|${fg}`;
    if (seen.has(key)) continue;
    seen.add(key);
    evaluate(bg, fg, 4.5, "text");
  }
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

  // Cascade order: @theme constants < :root < .dark overrides. Dark inherits
  // every :root token it doesn't redefine, exactly as the browser cascades —
  // so `--background: var(--paper)` resolves against the dark `--paper`.
  const themeTokens = extractThemeTokens(css);
  const lightTokens = new Map([...themeTokens, ...parseTokens(rootBody)]);

  const themes = [auditTheme("light (:root)", lightTokens)];
  if (darkBody !== null)
    themes.push(
      auditTheme(
        "dark (.dark)",
        new Map([...lightTokens, ...parseTokens(darkBody)]),
      ),
    );

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
