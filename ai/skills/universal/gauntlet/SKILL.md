---
name: gauntlet
description: >-
  Run the second-model review gauntlet — adversarial challenge, then verification
  review, each to convergence under its own resolved cap, then the CI mirror and
  the draft PR. Entry: implementation complete and the definition-of-done gate
  green. Exit: a draft PR is open and the shepherd stage takes over. Convergence
  is the exit; fixing findings is not. Invoke as /gauntlet.
disable-model-invocation: true
allowed-tools: Read, Glob, Grep, Edit, Write, Bash(git status:*), Bash(git branch --show-current), Bash(git rev-parse:*), Bash(git merge-base:*), Bash(task --list-all:*), Bash(gh pr list:*), Bash(gh pr view:*), Bash(gh issue view:*), Bash(gh repo view:*)
---

# Gauntlet

**Arguments:** $ARGUMENTS

The stage between "the implementation is done and the definition-of-done gate
is green" and "a draft PR exists". It runs the adversarial second-model review
to convergence, then the verification review to convergence, then the CI
mirror, then the PR-open ritual — and hands the draft to `/shepherd`.

**The central rule: convergence is the exit, fixes are not.** A stage does not
end because you fixed everything the reviewer said. It ends when the rounds
themselves come back clean, because the loop is **self-reinforcing** — each
round's fixes are the next round's input, so it can generate its own work
indefinitely while every individual finding stays defensible. Most of the value
lands in rounds 1–2; unbounded critique loops oscillate, reward-hack, and cost
real money. The reliable stops are an explicit exit condition, a hard budget
with human escalation, and diminishing-returns detection — never the reviewer
declaring itself satisfied.

**The repository's own policy outranks this file.** Where its `AGENTS.md`
states different caps, exit conditions, gates, or sidecar locations, follow
`AGENTS.md` — it is the policy, this skill is the procedure. Read what that
file actually says rather than inferring its vintage: vendored skills sync on
their own release cadence and can lag a policy change made there. A repo with
no second-model reviewer configured is not a repo doing it wrong; in one, this
skill reduces to its entry gate, §2 (the budget line and shepherd cap are
still required downstream), §9, and §10.

Writes — commits, gate runs, `git push`, `gh pr create` — always go through the
normal permission prompt.

## 1. Entry gate

Four things must hold before the first reviewer round. Check them; do not
assume them.

- **The definition-of-done gate is green** (`task verify` where it exists).
  Run it and read the exit code — "should pass" is not a result. A reviewer
  handed a tree that does not build spends its round on the build.
- **The canonical base is established, fresh, and verified — or you stop.**
  Four properties must all hold before round 1, checked in this order, and
  **every failure, error, or uncertainty is a stop, never a fallback**:

  1. `origin` exists and is the repository the PR will target (`gh repo
     view` names the resolved repo; in a fork workflow `origin` is the
     upstream and the fork is a second, differently named push remote).
  2. `git fetch origin` **and** `git remote set-head origin -a` both
     **succeed** — check their exit codes. A stale `origin/HEAD` surviving a
     failed refresh is precisely the state that reviews the wrong diff, so a
     transient remote error here is a stop, not a reason to proceed on what
     is already local.
  3. `refs/remotes/origin/HEAD` exists afterwards, and `default` reads from
     it: `default="$(git symbolic-ref --short refs/remotes/origin/HEAD | sed 's|^origin/||')"`.
     There is deliberately no name-lookup fallback — the bare reviewer
     rounds resolve this **ref**, so a default name known only to a variable
     would let the gate pass while every round reviews something else. A
     remote that advertises no HEAD is a stop to report.
  4. The current branch is nonempty (detached HEAD is a stop) and differs
     from `$default` (the default branch is the wrong place to run a
     gauntlet from).

  Then `base_ref="origin/$default"` — resolved **once, here**; every later
  step consumes it: the merge-base lookup in §2, the bare reviewer rounds in
  §3–4 (their bare run is the only invocation reviewing branch commits and
  working tree together, which is why the topology above is required rather
  than worked around with flags — §7, damper 10), and the release-title
  preflight and PR creation in §10. After a default-branch rename, these
  same four properties are the check that the harness and `$base_ref` agree.

- **The work is committed — `git status --porcelain` is empty.** Bare
  reviewer runs would cover a dirty tree, but the PR pushes only `HEAD`: an
  implementation living in the working tree can pass every round and CI
  locally and then be silently absent from the draft. Commit before round 1;
  each round's fixes then get their own commit and push (§3, step 4), and §10
  re-checks the tree is clean immediately before the push.

- **You can push.** Rounds push (§3, step 4), so the credential is proved here
  rather than discovered after a converged stage. Same rule as the base checks
  above: **every failure, error, or uncertainty is a stop, never a fallback.**

  1. **Resolve the push remote** — the one `gh pr create` will push to.
     Under the fork topology in property 1 above, that is the fork, which is
     *not* `origin`; a repo whose `origin` you can write to is its own push
     remote. Resolve it explicitly rather than assuming a name, and never
     push to a raw URL: a URL push bypasses the named remote and leaves
     stale tracking refs.
  2. **Probe it** — `git push --dry-run -u <remote> <branch>`, and read the
     exit code. Be exact about what this proves. It **does** prove the
     credential: an unauthorized token, an expired one, or an SSO
     authorization the remote refuses fails here, at round 1 — and that is
     the observed failure, a converged stage discovering at `gh pr create`
     that it could never have pushed at all. It does **not** exercise
     anything that evaluates only on a real ref update: branch protection,
     rulesets, and pre-receive hooks all see nothing, because a dry run sends
     no update. Those surface at the first round that pushes, or, on a stage
     whose rounds are all clean, not until §10.

  **The probe writes nothing, and that is deliberate.** Pushing the
  implementation here to prove the remote harder would publish it before §9's
  full gate has run: in a repo whose workflows trigger on branch pushes, that
  executes changed workflow code with repository permissions ahead of the
  review meant to catch it, and it would publish an unscanned tree — `verify`
  excludes the security suite in most repos. A stronger probe is not worth
  reordering the gate around.

If the implementation is not actually finished, stop: this stage reviews a
change, and "the reviewer will tell me what to write" is how round 1 becomes
the design phase.

## 2. Resolve and announce the budget

The numbers live in `.devflow.toml`, never in prose. Read the file; do not
recall it.

**Bind the issue first.** `$ARGUMENTS`, the branch's claim, or the session's
stated target names the issue this change implements; fetch **that issue's**
labels before resolving anything. If no issue can be bound unambiguously, say
so in the announcement — resolution then falls through to `default_rigor`,
and the announcement must name "no issue bound" as the source so a stricter
label cannot be silently skipped.

**Resolution order**, highest precedence first:

1. an explicit instruction in this session;
2. a `rigor:*` label on the issue, **per stage, taking the highest cap
   present — and the highest `min_rounds` floor present, under the same
   principle** — labels are multi-select, so a conflict can only ever buy
   more review, never less, in caps and floor alike. A `rigor:` value naming
   no tier in the file is ignored, not guessed at;
3. `default_rigor` in the file;
4. the built-in fallback **4 / 4 / 4** (challenge / review / shepherd) if the
   file is absent.

**When the change under review edits `.devflow.toml` itself, resolve from the
merge-base copy**, not the branch copy — otherwise a branch can lower the very
gate that is reviewing it, and dropping every tier together would evade the
disclosure below by leaving nothing to be below:

```sh
base="$(git merge-base HEAD "$base_ref")"          # $base_ref from §1
git show "$base:.devflow.toml"                     # absent at the merge base?
```

A merge base that predates `.devflow.toml` — the branch introduces it — is
the absent-file case of the resolution order: the built-in 4 / 4 / 4 and a
floor of 1, not an error and not the branch's own copy.

An explicit human instruction still overrides that.

**`min_rounds` — the floor.** A tier may define `min_rounds` (an integer, 1 or
2 — the two-consecutive exit ends a stage at round 2 whatever the floor says,
so larger values cannot bind; repos that validate the config reject them). In
a repo where nothing validates the file, do not interpret an out-of-range or
non-integer value: clamp it **fail-safe** — every non-numeric value reads as
2, and a numeric one reads as 2 when greater than 1, else 1 — so ambiguity
always buys more review, never less; say so in the announcement, so a typo
retunes the budget visibly rather than silently. It is the minimum
number of rounds a stage must run before the **empty-round instant exit** in §5
may be taken, so a deeper tier can require independent confirmation even when
round 1 comes back clean. **Tolerate its absence: a tier that does not define
it has a floor of 1**, which is the historical behaviour. Note what follows
from the arithmetic — the two-consecutive-clean exit and the capped-clean exit
both consume at least two rounds, so **any floor ≤ 2 is satisfied by
construction** on those paths, and the floor only ever bites the empty-round
shortcut.

**Announce the resolved budget on entering the stage**, filled in from the file:

```text
rigor: standard (default_rigor) → challenge ≤3, review ≤3, shepherd 4, min_rounds 1
```

Name a **tier** only when one tier supplied every number; two retuned tiers can
yield a combination belonging to no single tier, so what you announce is the
caps. Carry the same line into the PR body in §10, so a later round or a
different session can see which budget it is spending instead of inferring one.

**Disclose a reduced budget.** Whenever any resolved cap **or floor** is
**below what `default_rigor` would give**, say so in the announcement and in
the PR body. A
`rigor:*` label is applied by people and verified by nothing — GitHub's triage
role can apply one with no push access at all — so a budget can be retuned by
someone who could not edit `.devflow.toml`. **An agent never applies one to
itself.**

Caps are **ceilings, not quotas**. A stage that meets an exit condition on
round 1 is done, whatever the tier allowed. Nothing here obliges a round to run.

## 3. Challenge loop

`task challenge` — the adversarial pass: architecture and approach,
authorization bypasses, data-loss paths, unsafe rollback, races, hidden
coupling, operational failure modes, needless complexity. Steer it when the
change has an obvious pressure point by passing focus text
(`task challenge -- focus on the migration path`). Every round is a **bare
run** — the one invocation covering branch commits and working tree
together — against the base the entry gate proved equal to `$base_ref`; the
checkout invariant in §1 is what makes bare correct, and no flag substitutes
for it (§7, damper 10).

Each round:

1. **Run it in the background and poll** (§8). A round is 5–15 minutes —
   past most agents' tool-call timeouts.
2. **Adjudicate every finding** through the damper catalog (§7) and record the
   table (§6). Fix only what is confirmed.
3. **Re-run `task verify`** after the fixes.
4. **Commit the round's fixes as their own commit, and push it** to the
   push remote resolved at the entry gate (§7, damper 9). Per **round**, not
   per finding: five fixes are one commit, and a round adjudicated clean with
   nothing to fix commits and pushes nothing. Read step 3's exit code before
   committing — a gate verdict consumed through a pipeline a reader can mask
   is how a failing gate reaches a push. Set the upstream on the first push
   (`-u`), since a new branch has no upstream to infer.

   **Two preconditions, or the rounds stay local.** Branch pushes must
   trigger no workflows, and the repo's `AGENTS.md` must not order the CI
   gate before the branch is pushed. Where either fails, commit each round as
   damper 9 says and push once at §10: the durability is lost, and that is
   the supported fallback rather than a reason to push anyway.
5. **Test the exit rule (§5) and the cap on the round just adjudicated.** An
   exit condition met means the stage is over now — an empty round 1 owes no
   second run (floor permitting), and a capped final round must not launch
   cap+1. Escalate here if adjudicated P0/P1 persist at the cap.
6. Only if no exit holds and the cap is not reached: **re-run bare
   `task challenge`** — never `--base`/`--uncommitted`, which review one
   half of the scope (§7, damper 10) — and the next round begins.

**Round 2 owes the provenance checkpoint** (§7, damper 3) — it is the first
round that can show the loop feeding on itself, and it is not optional.

## 4. Review loop

`task review` — the verification checkpoint: implementation correctness,
consistency with the repo's conventions, error handling, test coverage. Same
adjudication, same table, same backgrounding, same per-round commit-and-push,
same exit rule — under its **own
cap, counted separately**. A converged challenge says nothing about review, and
the two are capped separately even where the tier gives them equal numbers.

**Why serial, not interleaved.** Challenge findings are architectural: fixing
them first avoids spending fine-grained review on code that is about to change.
That is a coarse-to-fine argument, and its known weakness is that review-round
fixes never get a challenge re-pass. Three things mitigate it — whole-branch
scope every round (§7, damper 10), the shepherd's independent cloud review of
the final head, and:

**The stage-regression valve.** When a review round raises a finding that is
**challenge-class in kind** — architecture, trust boundary, data loss — that is
a signal to **re-enter challenge once, with the human's authorization**, not to
stretch review's lens over it. Ask; do not re-enter on your own judgement. A
re-entered challenge runs under the challenge cap's remaining budget, and its
rounds count there.

## 5. The exit rule

A stage — challenge and review counted **separately** — ends when any one of
these holds:

- **Two consecutive rounds adjudicate to zero P0 and zero P1.** Those rounds
  may come back empty, all-P2 as labeled, or P1-labeled and adjudicated down to
  P2. The second such round *is* the independent confirmation; nothing further
  is owed.
- **A single round returns no findings at all** — but only once `min_rounds`
  is met (§2). Below the floor, an empty round is a clean round, not an exit.
- **A capped final round adjudicates to zero P0/P1.** The confirming round it
  would otherwise owe is one the cap forbids, and a clean last round is
  convergence, not the persisting disagreement escalation exists for.

**Severity is read off the adjudicated column of your table, never the
reviewer's label.** Only adjudicated P0/P1 hold a stage open; P2s are deferred
(§7, damper 2) and never suppressed.

**One precondition rides along with every exit:** every P2 deferred during the
stage must already be in the deferred-findings sidecar. An exit that drops a P2
is not an exit — nothing downstream will ever see it again.

**Escalation at the cap is a first-class outcome, not a failure.** If
adjudicated P0/P1 **persist** at the cap, stop, summarize the disagreement and
what each side rests on, and hand it to the maintainer. Do not open the PR
anyway: escalation halts the change, it is not a licence to move to the next
stage. Equally, a decision to stop one loop never transfers to another — each
is bounded for its own reason.

The maintainer may always ask for more rounds. Convergence is a floor on when
you may stop, not a ceiling on what they can order.

**Round accounting is council-ready.** A **round is one pass** — one run of the
stage's reviewer over the whole branch, adjudicated as a unit — regardless of
how many reviewers produced it. Today that is one reviewer. A future panel
(2–3 reviewers of different model families running the same pass in parallel,
majority-confirmed findings gating, singletons carried as P2-class noise
candidates, the author's own family excluded) is still **one round**, and a
tier may then declare one clean panel pass equivalent to the two-consecutive
exit — one panel provides in parallel the independent confirmation two serial
rounds provide over time. Count rounds this way now so the accounting does not
have to change later; do not implement panels here.

## 6. Adjudication table and ledger

**Every round ends in a table.** One row per finding:

| # | Finding | Reviewer P | Adjudicated P | Classification | Evidence | Action | New in this stage? |
|---|---------|-----------|---------------|----------------|----------|--------|--------------------|

`Classification` is confirmed / plausible-but-unproven / false positive.
`Evidence` is what you checked, not an assertion. The last column is the
round-2 provenance checkpoint (§7, damper 3) and is filled from round 2 on.

**The adjudication ledger.** Keep a per-branch record beside the
deferred-findings sidecar, at the path

```sh
ledger="$(git rev-parse --git-path "adjudication-ledger/$(git branch --show-current)")"
mkdir -p "$(dirname "$ledger")"
```

If that `mkdir` fails because a **file** occupies a parent path — an
orphaned ledger from a deleted branch whose name prefixes yours (`feat/foo`
blocking `feat/foo/bar`) — or the ledger path itself is a **directory**
holding nested orphans (the reverse: your `feat/foo` after a deleted
`feat/foo/bar`), the answer is the same accounting the §10 sweep applies,
just earlier because it is in your way: read the orphan records, adopt
anything that belongs to live work, and move the rest aside. Never delete
them blind.

One line per adjudicated finding — and **one line per round outcome**, empty
rounds included (`challenge r1 | no findings`), so a resumed session or a
re-entered stage can count rounds already spent against the cap and floor
instead of restarting the count. Per finding: **path, a few distinctive
substance words, the disposition, and the stage/round it came from**.
Example:

```text
scripts/foo.sh:41 | pid reuse in the watcher loop | declined: recipe deleted (moot) | challenge r2
```

The path is deliberate and matches the deferred-findings sidecar's rationale:
it sits in the **git directory**, so it is deterministic (any later session in
this checkout resolves it the same way, and `git rev-parse` resolves it
correctly inside a linked worktree) and invisible to `git status` — a note in
the worktree would be handed to the next bare reviewer run as part of the
change under review. It is keyed by **branch**, verbatim and without a suffix,
because a clone switches branches in place and one shared file would let branch
B's PR sweep up branch A's record.

**Match every new finding against the ledger first — by location plus
substance, never exact wording.** The same finding rarely returns phrased
identically. A match is a **prior, not a substitute for adjudication**: verify
it against the current head first, because a repeat can also mean the fix was
incomplete or a later edit reintroduced the defect. Only when the code the
disposition rests on is unchanged is the finding answered from the record
rather than re-litigated. This applies across all three passes — challenge rounds, review
rounds, **and the PR's cloud-review rounds under `/shepherd`** — which is why
the ledger outlives the stage and why §10 hands it forward before deleting it.

A finding raised **once and never re-raised by any later pass** is a **noise
candidate**: still adjudicated, but with that prior weighing against it.
Cross-pass consistency is the cheapest signal available here, and it costs a
convention and a `grep` rather than machinery.

## 7. The damper catalog

The loop's fuel is **reflexive fixing**. Every damper below removes fuel.

**1. Findings are hypotheses, not authority.** Verify each against the actual
artifact, its surroundings, the requirements, and the tests. Classify it
confirmed / plausible-but-unproven / false positive. Fix only confirmed
findings; reject the rest **with evidence**, in writing. The anti-sycophancy
rule is explicit: **never fix something to appease the reviewer.** A fix made
to end an argument adds surface the next round will attack, and it is
indistinguishable at the time from a fix that was needed.

**2. Severity gating.** Only adjudicated P0/P1 hold a stage open. P0 breaks
correctness, security, or data integrity in ordinary use, or breaks an existing
contract. P1 is a real defect or a materially wrong design decision with a
plausible trigger. P2 is worth knowing and not stage-blocking: hardening,
unlikely edge cases, maintainability, non-critical test gaps. **Every P2 goes
into the deferred-findings sidecar the moment you defer it** — these runs are
local and their output is ephemeral, and the cloud reviewer reposts only
high-priority findings, so a P2 not written down is simply lost:

```sh
sidecar="$(git rev-parse --git-path "deferred-findings/$(git branch --show-current)")"
mkdir -p "$(dirname "$sidecar")"
```

The same prefix-orphan accounting specified for the ledger in §6 applies
here before the first append: a stale file or directory of a dead branch
occupying this path is read, adopted where live, and moved aside — not
deleted blind, and not left to block the record until §10's sweep.
Append **only if not already listed**, matched by location plus substance — an
unchanged deferred finding is re-reported by design every remaining round, and
appending blindly would hand the shepherd four copies of one finding. A P2 you
judge worth fixing immediately may of course be fixed in place; it just does
not hold the stage open. One accounting note rides with that: a P2 fix
committed after the stage's exit-eligible round is a commit no round of this
stage reviews — that is acceptable only because the next gate in the
pipeline (the other stage's rounds, `task ci`, and the PR's cloud review)
covers it. A P2 fix you would not want reviewed there is a P2 to defer, not
to slip in after convergence. The sidecar rides into the PR body in §10.

**3. Round-2 provenance checkpoint.** For every finding, record on the table
whether its subject **exists only because an earlier round of this same stage
added it**. Findings migrating off the original change and onto prior rounds'
fixes is *the* tell that the loop is feeding on itself, and round 2 is the
first round that can show it. Do not wait for round 3, when only one round is
left. A finding that does get that mark is adjudicated with one of exactly three
dispositions, written out: **delete the scaffolding** (damper 4), **restructure
it to invariants** (damper 5), or **state that it is in scope and why the
change genuinely needs it**. Hardening round
1's scaffolding by reflex and letting round 3 attack the result is not one of
the options.

**4. Deletion of scaffolding.** When a round's findings are about scaffolding
rather than about the change, weigh **removing** that scaffolding against
hardening it once more. A remediation can be correct in the abstract and wrong
for the artifact: a documentation guide that has grown a hand-rolled process
supervisor earns real, defensible P1s about per-run state, process-group
supervision, and PID reuse — and every one of them is mooted by deleting the
recipe. This is not a way to re-score the round that raised them: a confirmed
P0/P1 keeps its adjudicated priority for its own round whether the remedy is a
fix or a deletion, and the remedy either way is input to the **next** round.
What deletion buys is that the next round finds nothing left to re-raise. Name
the mooted findings in the table **and in the message of the commit that
removes the code** — the table is scrollback; the commit is the record a later
session can still find. One endpoint is worth knowing: if the deletion empties
the change entirely, there is no round to converge on, and an empty scope is
refused non-zero by design. That is the answer, not a failure to work around —
a change that has become empty is **abandoned, not reviewed clean**.

**5. Restructure to invariants (deletion by abstraction).** Deletion's
equivalent where the text cannot simply go away because earlier rounds
legitimately demanded it. When the artifact is a spec or a document and the
rounds are playing whack-a-mole with **procedure prose** — each patch spawning
a new corner-case sequence to defend against — replace the procedure with the
**property** it was approximating, universally quantified over all event
sequences. For example: *"no sequence of untrusted mutations may move the
resolved outcome away from what trusted actors' actions alone would produce."*
Then **delegate the mechanism** to the implementation surface, carrying the
review's attack scenarios there as required test cases. The next round finds no
wording seam to attack, and the obligation is preserved rather than dropped.

**6. Scope-splitting.** A **non-blocking** finding that demands a new
mechanism — an adjudicated P2, or work genuinely outside this change's
contract — is spun out as an issue instead of grown onto the branch. The
branch answers the change it set out to make; a mechanism is its own change
with its own review. The sidecar and the ledger are what make deferring
safe — they are why "file it" is a disposition and not a euphemism for
dropping it. **A confirmed P0/P1 in this change never takes this exit**: it
is fixed here, or the stage stops and escalates — filing it away would let
the convergence rule open a PR over a known blocker.

**7. Fingerprint findings across stages, simply.** The ledger of §6, matched by
location plus substance across challenge, review, and the PR's cloud-review
rounds alike. Convention plus `grep`, not machinery. A singleton is a noise
candidate.

**8. Settle by test when prose stalls.** If the same finding is still contested
after **two** adjudications, stop arguing and write the assertion — when a
cheap one exists. It fails: confirmed, fix it. It passes: refuted, with
evidence that cannot rot. Self-correction needs external feedback to work at
all; a third round of prose is the thing that does not. **No cheap assertion
available → escalate**, rather than argue it a third time.

**9. Best-so-far rollback.** Commit each round's fixes as **their own commit**
and push it, so the branch history is a best-so-far record that survives the
machine it was made on. **Returning to an earlier state is a legitimate
adjudication outcome** when later rounds churned without adjudicated
improvement. Running to the cap is not the goal, and the history is what makes
going back cheap enough to actually do.

**Go back by adding, not by rewriting.** Because the rounds are pushed, the
history is published, and rewriting published history is forbidden — no
`reset --hard` over a pushed round, no amend, no force-push, no matter how
much tidier the result would look. Revert the rounds you are undoing
(`git revert`, newest first) and push that; the branch then records both what
was tried and that it was withdrawn, which is what a later round or a
different session needs in order not to retry it. Name the reverted rounds and
why in the revert's message, exactly as damper 4 requires of a deletion.

**Two costs the push does not cover.** It carries commits and nothing else:

- The **deferred-findings sidecar and the adjudication ledger** live in the
  git directory (§6) and are never pushed, so a lost environment costs at
  most the current round's *code* while taking the whole adjudication record.
  A resumed session recovers the commits and still re-runs the stage. Say
  that plainly rather than letting "the rounds are pushed" be read as crash
  recovery; the sidecar's transfer into the PR body in §10 is still the only
  thing that makes those findings durable.
- **A round's commit is secret-scanned before it is pushed.** This is an
  obligation, not a claim about any repo's setup: where a `pre-push` hook
  runs the scan it is automatic, and where none is installed — hook
  installation is opt-in in most generated repos — run the repo's secret
  scan yourself first. The rest of the security suite still runs at §9
  before the PR exists.

**10. Whole-branch scope every round.** Re-run the reviewer **bare** — branch
commits *and* working tree — so a fix can never narrow the re-review to itself.
An explicit `--base`/`--uncommitted` reviews one half only, and a stage that
exits on a half-scoped clean round has confirmed nothing.

**11. Independent judge.** The reviewer is **independent of the authoring
session by design** — a separate instance with none of the author's context,
and a different model family wherever the harness provides one — because
self-review exhibits self-bias and a self-correction blind spot, and a model
grading its own work converges on approving it. Where author and reviewer
unavoidably share a family (a Codex-driven session reviewing with Codex),
say so in the announcement; the shepherd's cloud review of the final head is
then the nearest cross-check, not a substitute for this damper. The
author never disables, bypasses, or reconfigures the gate to pass it. Where an
automatic stop-gate BLOCKs on something you classified P2: adjudicate it on its
own terms — fix it, or state the reasoning — **never** disable the gate. A
BLOCK neither reopens a converged stage nor counts as one of its rounds.

## 8. Backgrounding the reviewer runs

Reviewer rounds run 5–15 minutes, past most agents' tool-call timeouts. **Run
them in the background and poll.** Growing output means running, not hung;
relaunching a live run only doubles the cost.

Use the harness's own tracked background execution — one backgrounded command
per round, which notifies on completion by itself. Three prohibitions, each
from an observed failure:

- **Never hand-roll a `pgrep`/`sleep` watcher.** A watcher polling
  `pgrep -f "<pattern>"` whose **own command line contains that pattern matches
  itself** and loops forever. A live session sat two hours on a review that had
  already finished, because both watchers were watching each other. Where a
  process probe is genuinely unavoidable, use the bracket idiom —
  `pgrep -f "[c]odex-review"` — **and** cross-check liveness against the output
  file's mtime, so a self-match cannot masquerade as a running job.
- **No inner `&`.** A trailing `&` inside an already-backgrounded compound
  command detaches the real work from tracking: the wrapper "completes"
  instantly while the job runs unwatched, and the session reports a round that
  never happened. One backgrounded command per unit of work.
- **Never hand-type an identifier.** SHAs, comment IDs, PR and issue numbers
  are **read from `git rev-parse` or an API response into a variable**, never
  retyped from what you saw. A hand-expanded short SHA sent a readiness gate
  chasing a head that did not exist.

```sh
head="$(git rev-parse HEAD)"          # right
# head=a1b2c3d                        # wrong — retyped from scrollback
```

## 9. CI mirror

`task ci` where it exists — the full local mirror. Fix whatever it catches.
This is the last cheap failure; everything after it costs a round on the PR.

If fixes landed after the last gate run, re-run with a **clean tree**, so
nothing passes on the strength of uncommitted or untracked files the push would
then omit.

## 10. Open the draft PR — the stage's exit ceremony

In order:

1. **Release-title preflight.** Where the repo gates PR titles by touched path,
   check the intended title locally before opening anything:

   ```sh
   PR_TITLE="feat: …" BASE_SHA="$base_ref" task guard:release-title
   ```

   `$base_ref` is the remote-qualified base resolved in §1 — a bare local
   branch name can be stale and misjudge the release-worthiness of the diff.

   Retitle rather than bypass.
2. **Closing keywords are a decision, not a formality** (`track-work`).
   `Closes` hands GitHub permission to drop the issue at merge — correct only
   when this PR finishes **every** acceptance criterion. Anything partial, and
   any umbrella issue, is `Refs`.
3. **Orphan sweep.** List the whole deferred-findings tree and account for
   **every** file, not just this branch's:

   ```sh
   for tree in deferred-findings adjudication-ledger; do
     dir="$(git rev-parse --git-path "$tree")"
     if [ ! -e "$dir" ]; then echo "$tree: empty sweep"
     else ls -R "$dir" || { echo "$tree: listing FAILED — stop"; exit 1; }
     fi
   done
   ```

   Only an **absent** tree is an empty sweep — a change whose stages
   deferred nothing never creates these directories. A tree that exists but
   cannot be fully listed is a stop, not an empty result: opening the PR
   over an unreadable record drops findings.

   A branch renamed or deleted mid-change strands its notes under the old name,
   where nothing will look for them again. Adopt an orphan into this PR if it
   belongs to this work; otherwise leave it and **say it is there**. Listing
   costs one command; migration logic would cost a mechanism that then needs
   its own correctness argument.
4. **Transfer the sidecar into the PR body** under a `## Deferred findings`
   heading, one unchecked task-list item each — `- [ ] <file:line> —
   <finding>` — with enough detail to adjudicate later. The body also carries
   what/why/how-it-was-verified (name the gates you actually ran) and the
   budget line from §2, including the reduced-budget disclosure if one applies.
5. **Re-check ownership immediately before creating.** A claim is not a
   lock: re-read the bound issue and list its linked/open PRs — another
   worker may have opened one during the rounds. On §2's no-issue-bound
   path, the check is the repository's open PRs instead: any PR whose head
   is this branch or whose change covers this work. Either way a live
   duplicate means stop and reconcile, not open a second PR.
6. **`gh pr create --draft`.** Re-check `git status --porcelain` is empty —
   an uncommitted file here is work the push will silently omit — then push
   whatever the rounds have not already pushed, to the push remote resolved
   at the entry gate,
   named explicitly, then create the PR as a **draft** — binding the target
   explicitly when more than one repo is in play: `--repo <upstream>` for the
   base, `--head <owner>:<branch>` when pushing from a fork, and
   `--base "$default"`. An unqualified create in a fork checkout can select
   the fork as base or infer the wrong head. One documented limitation:
   `gh pr create` does not accept an **organization** as the `<owner>` in
   `--head` — from an org-owned fork, create the PR through the web UI or
   another supported path and say so, rather than bending the flags. If `--draft` is
   rejected — GitHub restricts drafts on private repos to paid plans — stop and
   report it; dropping `--draft` reverts the lifecycle rather than fixing it.
7. **Verify the result.** Read
   `headRefOid,isDraft,baseRefName,headRefName,headRepositoryOwner` — the
   base must equal the branch `$base_ref` names, and the head must be
   *this* branch in the repository you pushed to (an alternative creation
   path can bind a different branch that happens to point at the same
   commit, which passes a SHA-only check and then strands the shepherd's
   target gate). Then require the SHA you pushed and `isDraft == true`:

   ```sh
   pushed="$(git rev-parse HEAD)"
   gh pr view <n> --json headRefOid,isDraft,baseRefName,headRefName,headRepositoryOwner
   ```

   A non-draft result is not the normal publication path — reconcile it before
   going further.
8. **Delete the scratch files last** — the deferred-findings sidecar **and the
   adjudication ledger** — only once the PR verifiably exists (step 7's
   check, whichever creation path produced it — the org-fork web path never
   returns a CLI URL) *and*
   you have re-read the body and confirmed the findings are in it. The sidecar
   is the sole durable copy: a rejected push, a validation error, or a lost
   session between the delete and the create takes every deferred finding with
   it, and the shepherd then settles a list it cannot know is short. The
   ledger's durable home is the **PR body**: append its surviving lines under
   a collapsed `## Adjudication record` section (`<details>` is fine) in the
   same edit that carries the deferred findings, re-read the body to confirm
   both sections landed, and only then delete the files. That section is the
   contract the shepherd's cloud-review rounds read to answer a repeat
   finding from the record — a "hand-off note" anywhere else is a location
   nothing downstream is defined to look in.

**The push cadence changes here.** Round-per-push is a *pre-PR* rule, and the
draft existing is what ends it: from this point each push spends a CI run and
starts a fresh current-head cloud-review cycle, so the shepherd batches one
push per its own round rather than one per fix. What does not change is that
nothing already pushed is ever amended, rebased, or force-pushed.

**Then enter the shepherd stage.** The verified draft existing (step 7) is
the trigger for that stage — whichever creation path produced it — not the
end of the work: unpolled checks and
unanswered reviews are its input, and the deferred findings above are still
open. Where the shepherd skill is vendored, enter it the way the repo's
policy says — read `.agents/skills/shepherd/SKILL.md` (or
`.claude/skills/shepherd/SKILL.md`) and follow it; it is user-invocable only,
so it is read, not called. Where it is not vendored, the repo's `AGENTS.md`
shepherd bullet is the procedure. Either way *this* skill's scope ends here:
it never promotes a draft, never runs the readiness gate, and never merges —
and stopping instead of shepherding leaves the PR at an explicitly
non-terminal state.
