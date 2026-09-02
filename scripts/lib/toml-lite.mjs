// scripts/lib/toml-lite.mjs
//
// A hand-rolled parser for the subset of TOML the Dev flow v2 `.devflow.toml`
// v2 shape actually uses: nested `[a.b]` table headers, scalar key = value
// assignments, strings/numbers/booleans, arrays (including multi-line), and
// inline tables (including one whose value is itself a multi-line array,
// e.g. `{ any = [\n  { predicate = "x" },\n] }` — legal TOML, since a
// newline is disallowed only directly between an inline table's braces, not
// inside a nested value spanning them). No dependency is pulled in for this
// on purpose, matching scripts/lib/json-schema-subset.mjs (a hand-rolled
// JSON-Schema-subset engine built for the identical reason: this repo ships
// no root package.json / node_modules, so an `import` of a third-party
// parser would not resolve).
//
// Deliberately unsupported, and rejected with a clear error rather than
// silently mis-parsed: triple-quoted (multi-line) strings and
// array-of-tables (`[[...]]`) — neither appears in this repo's config shape.
//
// Deliberately more lenient than the TOML spec in one way: whitespace
// (including newlines) and comments are insignificant between every token,
// so this parser does not enforce "one key = value per line" or "no
// trailing comma". Every fixture in this repo is hand-authored and
// well-formed, so accepting a slightly larger language than strict TOML
// costs nothing here and keeps the tokenizer simple.

export class TomlError extends Error {}

function tokenize(text) {
  const tokens = [];
  let i = 0;
  const n = text.length;
  const lineAt = (pos) => text.slice(0, pos).split("\n").length;
  const isBareKeyChar = (ch) => /[A-Za-z0-9_-]/.test(ch);

  while (i < n) {
    const ch = text[i];
    if (ch === " " || ch === "\t" || ch === "\r" || ch === "\n") {
      i++;
      continue;
    }
    if (ch === "#") {
      while (i < n && text[i] !== "\n") i++;
      continue;
    }
    const startLine = lineAt(i);
    if (ch === "[") {
      tokens.push({ type: "lbracket", line: startLine });
      i++;
      continue;
    }
    if (ch === "]") {
      tokens.push({ type: "rbracket", line: startLine });
      i++;
      continue;
    }
    if (ch === "{") {
      tokens.push({ type: "lbrace", line: startLine });
      i++;
      continue;
    }
    if (ch === "}") {
      tokens.push({ type: "rbrace", line: startLine });
      i++;
      continue;
    }
    if (ch === "=") {
      tokens.push({ type: "equals", line: startLine });
      i++;
      continue;
    }
    if (ch === ",") {
      tokens.push({ type: "comma", line: startLine });
      i++;
      continue;
    }
    if (ch === ".") {
      tokens.push({ type: "dot", line: startLine });
      i++;
      continue;
    }
    if (ch === '"' || ch === "'") {
      const quote = ch;
      if (text.slice(i, i + 3) === quote.repeat(3)) {
        throw new TomlError(
          `line ${startLine}: multi-line (triple-quoted) strings are not supported by this TOML subset`,
        );
      }
      let j = i + 1;
      let out = "";
      while (j < n && text[j] !== quote) {
        if (text[j] === "\n") {
          throw new TomlError(`line ${startLine}: unterminated string`);
        }
        if (quote === '"' && text[j] === "\\") {
          const esc = text[j + 1];
          const simple = { n: "\n", t: "\t", r: "\r", '"': '"', "\\": "\\", b: "\b", f: "\f" };
          if (esc in simple) {
            out += simple[esc];
            j += 2;
            continue;
          }
          if (esc === "u" || esc === "U") {
            const len = esc === "u" ? 4 : 8;
            const hex = text.slice(j + 2, j + 2 + len);
            if (!/^[0-9a-fA-F]+$/.test(hex) || hex.length !== len) {
              throw new TomlError(`line ${startLine}: malformed \\${esc} escape`);
            }
            out += String.fromCodePoint(parseInt(hex, 16));
            j += 2 + len;
            continue;
          }
          throw new TomlError(`line ${startLine}: unsupported escape sequence \\${esc}`);
        }
        out += text[j];
        j++;
      }
      if (j >= n) throw new TomlError(`line ${startLine}: unterminated string`);
      tokens.push({ type: "string", value: quote === "'" ? text.slice(i + 1, j) : out, line: startLine });
      i = j + 1;
      continue;
    }
    if (ch === "+" || ch === "-" || /[0-9]/.test(ch)) {
      let j = i;
      if (text[j] === "+" || text[j] === "-") j++;
      let sawDigit = false;
      while (j < n && /[0-9_]/.test(text[j])) {
        j++;
        sawDigit = true;
      }
      let isFloat = false;
      if (text[j] === "." && /[0-9]/.test(text[j + 1] || "")) {
        isFloat = true;
        j++;
        while (j < n && /[0-9_]/.test(text[j])) j++;
      }
      if (text[j] === "e" || text[j] === "E") {
        isFloat = true;
        j++;
        if (text[j] === "+" || text[j] === "-") j++;
        while (j < n && /[0-9_]/.test(text[j])) j++;
      }
      if (!sawDigit) throw new TomlError(`line ${startLine}: malformed number`);
      const raw = text.slice(i, j).replace(/_/g, "");
      tokens.push({
        type: "number",
        value: isFloat ? Number.parseFloat(raw) : Number.parseInt(raw, 10),
        isFloat,
        line: startLine,
      });
      i = j;
      continue;
    }
    if (isBareKeyChar(ch)) {
      let j = i;
      while (j < n && isBareKeyChar(text[j])) j++;
      const word = text.slice(i, j);
      if (word === "true" || word === "false") {
        tokens.push({ type: "bool", value: word === "true", line: startLine });
      } else {
        tokens.push({ type: "bareword", value: word, line: startLine });
      }
      i = j;
      continue;
    }
    throw new TomlError(`line ${startLine}: unexpected character ${JSON.stringify(ch)}`);
  }
  tokens.push({ type: "eof", line: lineAt(i) });
  return tokens;
}

function setPath(node, parts, value, fullKeyForError) {
  let cur = node;
  for (let idx = 0; idx < parts.length - 1; idx++) {
    const key = parts[idx];
    if (!(key in cur)) cur[key] = {};
    if (typeof cur[key] !== "object" || cur[key] === null || Array.isArray(cur[key])) {
      throw new TomlError(`key path "${fullKeyForError}" conflicts with an existing non-table value at "${key}"`);
    }
    cur = cur[key];
  }
  const last = parts[parts.length - 1];
  if (last in cur) {
    throw new TomlError(`duplicate key "${fullKeyForError}"`);
  }
  cur[last] = value;
}

function ensurePath(root, parts) {
  let node = root;
  for (const key of parts) {
    if (!(key in node)) node[key] = {};
    if (typeof node[key] !== "object" || node[key] === null || Array.isArray(node[key])) {
      throw new TomlError(`table header path conflicts with an existing non-table value at "${key}"`);
    }
    node = node[key];
  }
  return node;
}

class Parser {
  constructor(tokens) {
    this.tokens = tokens;
    this.pos = 0;
  }

  peek() {
    return this.tokens[this.pos];
  }

  next() {
    return this.tokens[this.pos++];
  }

  expect(type) {
    const t = this.next();
    if (t.type !== type) {
      const shown = "value" in t ? ` (${JSON.stringify(t.value)})` : "";
      throw new TomlError(`line ${t.line}: expected ${type}, got ${t.type}${shown}`);
    }
    return t;
  }

  parseKeyPart() {
    const t = this.next();
    if (t.type === "bareword") return t.value;
    if (t.type === "string") return t.value;
    if (t.type === "bool") return String(t.value);
    throw new TomlError(`line ${t.line}: expected a key, got ${t.type}`);
  }

  parseDottedKey() {
    const parts = [this.parseKeyPart()];
    while (this.peek().type === "dot") {
      this.next();
      parts.push(this.parseKeyPart());
    }
    return parts;
  }

  parseValue() {
    const t = this.peek();
    if (t.type === "string") {
      this.next();
      return t.value;
    }
    if (t.type === "number") {
      this.next();
      return t.value;
    }
    if (t.type === "bool") {
      this.next();
      return t.value;
    }
    if (t.type === "lbracket") return this.parseArray();
    if (t.type === "lbrace") return this.parseInlineTable();
    throw new TomlError(`line ${t.line}: expected a value, got ${t.type}`);
  }

  parseArray() {
    this.expect("lbracket");
    const items = [];
    while (this.peek().type !== "rbracket") {
      items.push(this.parseValue());
      if (this.peek().type === "comma") {
        this.next();
        continue;
      }
      break;
    }
    this.expect("rbracket");
    return items;
  }

  parseInlineTable() {
    this.expect("lbrace");
    const obj = {};
    while (this.peek().type !== "rbrace") {
      const keyParts = this.parseDottedKey();
      this.expect("equals");
      const value = this.parseValue();
      setPath(obj, keyParts, value, keyParts.join("."));
      if (this.peek().type === "comma") {
        this.next();
        continue;
      }
      break;
    }
    this.expect("rbrace");
    return obj;
  }
}

/**
 * Parse a TOML document (the subset described above) into a plain JS object.
 * Throws TomlError on anything it cannot represent.
 */
export function parseToml(text) {
  const tokens = tokenize(text);
  const parser = new Parser(tokens);
  const root = {};
  let current = root;
  while (parser.peek().type !== "eof") {
    if (parser.peek().type === "lbracket") {
      const startLine = parser.peek().line;
      parser.next();
      if (parser.peek().type === "lbracket") {
        throw new TomlError(`line ${startLine}: array-of-tables ([[...]]) is not supported by this TOML subset`);
      }
      const keyParts = parser.parseDottedKey();
      parser.expect("rbracket");
      current = ensurePath(root, keyParts);
      continue;
    }
    const keyParts = parser.parseDottedKey();
    parser.expect("equals");
    const value = parser.parseValue();
    setPath(current, keyParts, value, keyParts.join("."));
  }
  return root;
}
