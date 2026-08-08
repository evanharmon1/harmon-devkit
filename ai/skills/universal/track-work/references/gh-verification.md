# Verification reads set an explicit `--limit`

A `gh … list` run to **verify state** — did the labels get created, is the PR
closed, is the issue claimed — sets an explicit `--limit`, or `--paginate`
**and `--slurp`** for `gh api`. The default returns one page, so a verification
that reads truncated output reports **absence that is actually pagination** —
and reports it with exactly the confidence of a real answer.

This is the dedup search's failure mode (SKILL.md §3) pointed at a different
question, and it costs more here. A dedup search that truncates files a
duplicate: annoying, visible, recoverable at triage. A *verification* that
truncates says the write did not land, and the caller acts on it — re-running
provisioning, reporting a green step as failed, filing an issue for a bug that
does not exist. Nothing downstream can tell that zero from a true one.

## The defaults

| Command | Returns without a flag |
| --- | --- |
| `gh issue list` | 30 |
| `gh pr list` | 30 |
| `gh label list` | 30 |
| `gh api <endpoint>` | one page |

## A filter narrows what was fetched; it never widens it

Observed 2026-08-04 in harmon-init. Immediately after eleven `foreman:*`
labels were created, this returned **0**:

```sh
gh label list --repo <owner/repo> --json name \
  --jq '[.[].name | select(startswith("foreman:"))] | length'
```

The labels existed. `gh label list` sorts by **creation time**, not by name —
`--sort` defaults to `created` — so the eleven labels written moments earlier
sorted last, past the end of the 30-item first page. `--limit 100` returned all
eleven. A post-merge verification came one step from reporting provisioning as
failed.

Their **newness** is what put them out of reach, and that is the part worth
keeping straight: a verification runs right after the write it is checking, so
the rows it is looking for are the newest in the collection — which a
created-ascending default sorts to the far end, behind every row that was
already there. The check is most blind to exactly what it was written to see,
and it gets blinder as the repo accumulates labels.

That is the whole mechanism, and it is why the command reads as safe: the
projection *looks* like a query for `foreman:*` labels, so `0` reads as "no
such labels". The selection ran locally, over a page already cut to 30. Every
`--jq`, `grep`, or `select` over list output has this shape — it can only
narrow what the fetch returned.

## Size the limit to the namespace, not to the answer

A verification's limit cannot be sized to what you expect to find, because what
you expect to find is the thing being measured. Size it to the ceiling of the
namespace being read:

```sh
gh label list --repo <owner/repo> --limit 1000 --json name
```

Verification reads are cheap and run once, so a generous limit costs nothing
worth saving; `gh` pages internally to satisfy a `--limit` above 100 rather
than failing.

## Fetching every page is not reading every page

`--paginate` emits each page as its own JSON document, so a filter applied with
`--jq` runs once **per page** and answers about that page alone:

```console
$ gh api --paginate "repos/<owner>/<repo>/labels?per_page=1" \
    --jq 'any(.name == "bug")'
false
false
true
false
false
```

The label exists — page 3 says so. The defect is that there is no single answer
to read: `--jq` prints one boolean per page, and the command exits **0**
regardless, because `gh`'s status reports whether the *request* succeeded, not
what the filter found. So the exit status carries no information about the
answer, and the obvious way to collapse the output — take the last line —
yields `false` for a label that exists. A genuinely absent label produces the
same last line and the same exit 0, so the two cases are indistinguishable by
either signal. It gets worse as the collection grows: more pages means more
chances the last one disagrees with the answer.

`--slurp` is what wraps the pages into a single array, and `gh api` **refuses
it alongside `--jq`** (`the --slurp option is not supported with --jq or
--template`), so an aggregate read pipes to a standalone `jq`. Fold the pages
to match their shape rather than reaching for a habit: a REST collection
endpoint pages as arrays, while a paginated GraphQL query — and REST endpoints
with a count envelope, like `search/issues` and `actions/runs` — page as
objects, where merging lets a later page overwrite an earlier one.

So: `--jq` with `--paginate` is safe only for a filter you want applied and
printed per page. Anything computing **one** answer over the whole collection —
a membership test, a count, a max — needs the slurped form. `/shepherd` hit
exactly this in its unanswered-thread check, where a reply on page 2 stopped
cancelling its root on page 1.

## A failed read is *unknown*, never *absent*

Truncation is one way a read reports nothing; the others are a network blip,
an expired token, a rate limit, a typo'd repo. They are the same defect —
something the reader did not see, reported as something that does not exist —
and only the first is fixed by `--limit`. So the limit is necessary and not
sufficient.

**Capture the output and check the exit status before believing it is empty.**
Piping `gh` straight into a matcher throws that status away, so a failed fetch
is indistinguishable from a clean miss. And keep the three states apart:
"could not verify" is not "verified absent" — the same reading the
`set-issue-status.sh` exit codes get in SKILL.md §6, and the same reason
`/implement` treats a failed identity lookup as unknown rather than unclaimed.

**Addressing one object directly does not escape this.** `gh api
"repos/<owner>/<repo>/labels/<name>"` looks stronger than listing — one object,
nothing to truncate — but it collapses more states into the same signal, not
fewer:

- Bad credentials exit non-zero exactly as a miss does (`HTTP 401`), so exit
  status alone cannot mean "absent".
- A wrong or unreadable **repo** returns `404` too, identically to a present
  repo with no such label.
- A name containing `/` is read as extra path segments, so it 404s on routing
  rather than on absence. (`gh` percent-encodes spaces on its own, so
  `good first issue` is fine — which is what makes the `/` case easy to miss.)

Use it when you control the name and want the object's *contents*; do not use
it as an existence test for a name you did not validate. `gh issue view <n>`
and `gh pr view <n>` are safe in the same narrow sense: a number is not
path-sensitive, and a failure still has to be read as unknown.

## Where this applies

Both halves of the rule are separate, and a caller can satisfy one without the
other — so read these as two columns, not one badge.

- SKILL.md §3 — the dedup search and the open-PR listing, both `--limit 200`.
- [`cross-repo-work.md`](cross-repo-work.md) — the same search, bound to the
  repo being filed into.
- `/claim` decides whether a repo has the `claim:*` (or legacy `agent:*`) label family at all.
  It sets `--limit 1000`, so truncation cannot fool it — and it then pipes the
  listing into `grep`, so a failed read still reads as "no such family". It is
  the **motivating case for the second half, not an example of it**:
  evanharmon1/harmon-devkit#294 tracks the fix. The consequence is the one
  worth remembering — a transient read failure silently downgrades a real
  claim to an unlabelled one, and the next agent sees no owner.
