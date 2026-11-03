function componentMatches(part, pattern) {
  if (part === pattern) return true
  if (!/[*?]/.test(pattern)) return false
  const source = pattern.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.')
  // s and u: `?`/`*` match any code point, line breaks included, as bash case does.
  return new RegExp(`^${source}$`, 'su').test(part)
}

function matchParts(pattern, path, pi = 0, qi = 0) {
  if (pi === pattern.length) return qi === path.length
  if (pattern[pi] === '**') {
    for (let next = qi; next <= path.length; next += 1) if (matchParts(pattern, path, pi + 1, next)) return true
    return false
  }
  return qi < path.length && componentMatches(path[qi], pattern[pi]) && matchParts(pattern, path, pi + 1, qi + 1)
}

export function pathMatches(path, pattern) {
  return matchParts(pattern.split('/'), path.split('/'))
}

