# Gemini Code Review Style Guide

This style guide supplements the repository's contributor guidelines and defines priorities for automated AI pull request reviews.

## Review Priorities

1. **Correctness & Safety:** Flag logic bugs, race conditions, edge-case failures, unhandled errors, and data loss risks.
2. **Security:** Flag hardcoded secrets, injection vulnerabilities, unvalidated input, and insecure defaults. Never suggest committing credentials.
3. **Actionable Suggestions:** Provide specific, reproducible explanations and, when appropriate, suggest code fixes using markdown code suggestions.

## What to Avoid (Noise Reduction)

- **Style and Formatting:** Do not flag indentation, whitespace, quotes, line length, or style nits that are already covered by repository linters and formatters.
- **Generic Requests:** Avoid vague comments such as "add tests" or "refactor this" without describing a concrete failure mode or untested edge case.
- **Merge & Gate Authority:** Do not advise waiving repository verification gates, bypassing CI checks, or auto-merging.
