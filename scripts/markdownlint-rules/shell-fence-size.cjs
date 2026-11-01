"use strict";

// Report one aggregate per file, including zero, so the caller can detect
// missing parser output rather than silently accepting an unchecked file.
module.exports = {
  names: ["SHELLFENCESIZE"],
  description: "Measure fenced shell snippets",
  tags: ["code"],
  parser: "micromark",
  function: function (params, onError) {
    let total = 0;
    let longest = 0;
    function walk(tokens) {
      for (const token of tokens) {
        if (token.type === "codeFenced") {
          const fences = token.children.filter((child) => child.type === "codeFencedFence");
          const info = fences[0].children.find((child) => child.type === "codeFencedFenceInfo");
          if (info && /^(sh|bash|shell|console)$/.test(info.text)) {
            const lastLine = fences.length > 1 ? fences[1].startLine : token.endLine + (token.endColumn > 1 ? 1 : 0);
            const size = lastLine - fences[0].startLine - 1;
            total += size;
            longest = Math.max(longest, size);
          }
        } else if (token.children) {
          walk(token.children);
        }
      }
    }
    walk(params.parsers.micromark.tokens);
    onError({ lineNumber: 1, detail: `total=${total}, longest=${longest}` });
  }
};
