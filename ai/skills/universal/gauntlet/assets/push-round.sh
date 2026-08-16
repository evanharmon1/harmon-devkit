#!/usr/bin/env bash
# Push one adjudicated gauntlet round, safely.
#
# Three properties must hold for every pre-PR round push, and each one has a
# failure mode that prose could not reliably prevent — every defect below was
# found by review or by running the recipe it replaces:
#
#   1. What lands is the commit the GATE passed, not whatever HEAD resolves to
#      at push time. Git resolves HEAD when the push runs, so a commit hook
#      that rewrites the tree, or anything advancing HEAD between the round
#      commit and the push, publishes a commit no gate ever saw.
#   2. The push touches ONLY this branch. With no refspec on the command line
#      git consults remote.<name>.push, so a wildcard there publishes
#      unrelated local branches that no round reviewed and no scan covered.
#   3. The push never destroys another actor's work — it FAILS instead.
#      --force-with-lease alone does not give this: it asserts the ref is what
#      you last observed, and then authorizes a NON-fast-forward update over
#      it. Observing a divergent head and then leasing against it is exactly
#      how the lease authorizes the clobber it appears to prevent.
#
# Two more traps, both observed live rather than reasoned about:
#
#   - `git ls-remote … | cut -f1` exits 0 even when ls-remote fails, so a
#     transport or auth error is indistinguishable from "branch absent" and
#     silently downgrades to an unleased push.
#   - In zsh an unbraced "$sha:refs/heads/x" applies the :r history modifier
#     and pushes a mangled refspec. This script is bash, and braces every
#     expansion regardless.
#
# Exit: 0 pushed. 2 usage. 3 refused (a property above does not hold; nothing
# was pushed). 4 the push itself failed.

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: push-round.sh --remote NAME --branch NAME --sha SHA [--dry-run]

Push SHA to BRANCH on REMOTE as one adjudicated round.

  --remote NAME   the push remote, already resolved by the entry gate
  --branch NAME   the branch this stage is converging
  --sha SHA       the commit the gate passed — capture it BEFORE the gate
                  (sha="$(git rev-parse HEAD)"), never re-resolve HEAD here
  --dry-run       print the push that would run; touch nothing

Exit 0 pushed, 2 usage, 3 refused, 4 push failed.
EOF
}

die_usage() {
    echo "push-round.sh: $*" >&2
    usage
    exit 2
}

refuse() {
    echo "push-round.sh: refusing to push — $*" >&2
    exit 3
}

remote=
branch=
sha=
dry_run=no

while [ "$#" -gt 0 ]; do
    case "$1" in
    --remote)
        [ "$#" -ge 2 ] || die_usage "--remote needs a value"
        remote="$2"
        shift 2
        ;;
    --branch)
        [ "$#" -ge 2 ] || die_usage "--branch needs a value"
        branch="$2"
        shift 2
        ;;
    --sha)
        [ "$#" -ge 2 ] || die_usage "--sha needs a value"
        sha="$2"
        shift 2
        ;;
    --dry-run)
        dry_run=yes
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *) die_usage "unknown argument: $1" ;;
    esac
done

[ -n "$remote" ] || die_usage "--remote is required"
[ -n "$branch" ] || die_usage "--branch is required"
[ -n "$sha" ] || die_usage "--sha is required"

# Property 1: the SHA must be a real, resolvable commit in THIS repository.
# A caller that passed a tag, a short sha, or a ref name would otherwise have
# it re-resolved at push time, which is the mutable-HEAD hole reopened.
resolved="$(git rev-parse --verify --quiet "${sha}^{commit}" || true)"
[ -n "$resolved" ] || refuse "--sha ${sha} is not a commit in this repository"
[ "$resolved" = "$sha" ] || refuse "--sha ${sha} is not a full commit id (resolves to ${resolved})"

# Read the remote ref, keeping ls-remote's OWN status. A pipeline would
# discard it: cut exits 0 whatever ls-remote did.
ls_out=
ls_rc=0
ls_out="$(git ls-remote "$remote" "refs/heads/${branch}" 2>/dev/null)" || ls_rc=$?
[ "$ls_rc" -eq 0 ] || refuse "git ls-remote ${remote} failed (exit ${ls_rc}) — cannot establish the remote head"

remote_oid="$(printf '%s\n' "$ls_out" | awk 'NF {print $1; exit}')"

lease=
if [ -z "$remote_oid" ]; then
    # Property 3, absent-branch path: lease against emptiness rather than
    # omitting the lease, so a branch created between the read and the push
    # is rejected instead of silently advanced.
    lease="--force-with-lease=refs/heads/${branch}:"
else
    # Property 3, present-branch path: the lease pins concurrency, and the
    # ancestry check is what makes the update fast-forward. Both are needed;
    # neither implies the other.
    if [ "$remote_oid" = "$resolved" ]; then
        echo "push-round.sh: ${remote}/${branch} is already ${resolved} — nothing to push" >&2
        exit 0
    fi
    if ! git merge-base --is-ancestor "$remote_oid" "$resolved" 2>/dev/null; then
        refuse "${remote}/${branch} is at ${remote_oid}, which is not an ancestor of ${resolved} — another actor advanced or reset the branch; reconcile rather than force over it"
    fi
    lease="--force-with-lease=refs/heads/${branch}:${remote_oid}"
fi

if [ "$dry_run" = yes ]; then
    printf 'git push %s %s:refs/heads/%s %s\n' "$remote" "$resolved" "$branch" "$lease"
    exit 0
fi

git push "$remote" "${resolved}:refs/heads/${branch}" "$lease" || exit 4
