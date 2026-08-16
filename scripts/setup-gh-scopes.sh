#!/usr/bin/env bash
# setup-gh-scopes.sh — give the OPERATOR's interactive gh credential every scope
# this repo's tooling needs, and prove the grant actually landed.
#
# Run via `task setup:gh-scopes`. The required list is not stated here — it
# comes from scripts/gh-scopes.sh, the one place status.sh, the devcontainer's
# gh_auth_help banner, and this script all read (issues #827, #596).
#
# OPERATOR / DEV PROFILE ONLY. This mints a human credential, so it refuses in
# the two contexts where doing that would be wrong:
#
#   1. An env token (GH_TOKEN / GITHUB_TOKEN and the enterprise variants) is
#      set. That token OVERRIDES the stored one, so `gh auth refresh` would
#      quietly repair a credential the current shell will never use — and in a
#      bot container it is the credential-escalation ADR 0004 exists to
#      prevent. The remedy there is to reissue the token at its source.
#   2. There is no TTY. The refresh is a browser device-code flow; an agent or
#      a CI job cannot complete it, and neither should re-mint the operator's
#      credential unattended.
#
# Read-only until the refresh: it prints the current scopes, then asks gh for
# the missing ones. Token VALUES are never printed or captured.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=scripts/gh-scopes.sh
. "${REPO_ROOT}/scripts/gh-scopes.sh"

die() {
    echo "setup:gh-scopes: $*" >&2
    exit 1
}

command -v gh >/dev/null 2>&1 || die "gh is not installed (brew install gh)"

# 1. Env-token refusal, for the token family gh actually uses on THIS host.
#
#    The four variables are not interchangeable: gh reads GH_TOKEN /
#    GITHUB_TOKEN for github.com (and ghe.com), and GH_ENTERPRISE_TOKEN /
#    GITHUB_ENTERPRISE_TOKEN for a GitHub Enterprise Server host. Refusing on
#    any of the four blocked a legitimate dual-host workflow — an exported
#    GH_ENTERPRISE_TOKEN for a GHES account stopped a github.com refresh that
#    it does not override, and vice versa.
#
#    Where the variable DOES apply, the refusal stands: an env token overrides
#    the stored credential, so `gh auth refresh` would repair something this
#    shell never uses — and in a bot container it is the credential escalation
#    ADR 0004 exists to prevent.
#
#    Resolved before the TTY check because the host is needed either way, and
#    named individually because the fix differs per variable.
HOSTNAME_ARG="$(gh_target_host)"

case "${HOSTNAME_ARG}" in
github.com | *.ghe.com) env_token_vars="GH_TOKEN GITHUB_TOKEN" ;;
*) env_token_vars="GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN" ;;
esac

for var in ${env_token_vars}; do
    if [ -n "${!var:-}" ]; then
        die "${var} is set, and gh uses it for ${HOSTNAME_ARG}. An env token
  overrides the stored credential, so 'gh auth refresh' would fix something
  this shell never uses. Reissue ${var} at its source with the scopes:
  $(gh_scopes_request_list)
  (In a bot container this is the intended state — see docs/guides/bot-account.md.)"
    fi
done

# 2. TTY refusal. Both directions are required: the device-code flow prints a
#    code to be read (stdout) and waits on a keypress (stdin).
if [ ! -t 0 ] || [ ! -t 1 ]; then
    die "no TTY. The scope refresh is an interactive browser device-code flow —
  run 'task setup:gh-scopes' yourself in a terminal. Agents and CI must not
  re-mint the operator's credential."
fi

# HOSTNAME_ARG is resolved above, from the repository exactly as status.sh
# derives it — not a github.com assumption. In an Enterprise checkout with no
# GH_HOST, status.sh warns about the ghe.example.com credential and names this
# task; refreshing github.com here would edit an unrelated credential and leave
# the one the warning was about still under-scoped.
REQUEST_LIST="$(gh_scopes_request_list)"

# gh_auth_status_active — `gh auth status` narrowed to the ONE credential this
# task refreshes. `gh auth refresh` updates only the ACTIVE account, while a
# bare `--hostname` read reports every account on that host: concatenating
# those scope lines lets one account's grants satisfy a requirement the
# refreshed account still lacks, and the verification below would report a
# success that did not happen. Same narrowing, and the same pre-2.40 fallback,
# that status.sh uses.
gh_auth_status_active() {
    local out rc=0
    out="$(gh auth status --active --hostname "${HOSTNAME_ARG}" 2>&1)" || rc=$?
    case "${out}" in
    *"unknown flag"*)
        # gh predates --active (2.40). Multi-account per host arrived WITH
        # 2.40, so on a gh this old one host means one account and the
        # narrowing is already complete.
        rc=0
        out="$(gh auth status --hostname "${HOSTNAME_ARG}" 2>&1)" || rc=$?
        ;;
    esac
    printf '%s\n' "${out}"
    return "${rc}"
}

# `gh auth status` is the only place scopes are readable — they are a
# server-side property of the token, not something stored locally. Captured
# with 2>&1 because gh has moved this report between stdout and stderr across
# versions; only the scope LINE is ever printed back.
scopes_before=""
if status_out="$(gh_auth_status_active)"; then
    scopes_before="$(printf '%s\n' "${status_out}" |
        grep -i 'token scopes:' || true)"
else
    die "not logged in to ${HOSTNAME_ARG}. Run:
  gh auth login --hostname ${HOSTNAME_ARG} --git-protocol https --web --scopes \"${REQUEST_LIST}\""
fi

# 3. Refuse a stored NON-OAuth credential before touching it. A fine-grained
#    PAT or a GitHub App installation token carries permissions, not OAuth
#    scopes. Running `gh auth refresh` against one completes a device flow and
#    STORES A NEW CLASSIC TOKEN — silently replacing a deliberately narrow
#    credential with a broad one, and then reporting success. That is the
#    opposite of the source-side remedy documented in docs/project-management.md.
#
#    The credential class is established POSITIVELY, from the token's own
#    prefix, rather than inferred from the shape of the scope line. Inferring it
#    does not work: an earlier revision refused only a scope line that was
#    present and unquoted, treating a MISSING line as "unknown — an older gh, or
#    a changed output format". But a missing line is precisely what current gh
#    prints for a fine-grained PAT (verified on gh 2.97.0: no `Token scopes:`
#    line at all, not `Token scopes: none`), so the refusal never fired for the
#    one credential class it existed to protect, and the permissive arm ran the
#    refresh.
#
#    GitHub's prefixes are the discriminator: `gho_` (OAuth) and `ghp_` (classic
#    PAT) are refreshable, `github_pat_` (fine-grained), `ghs_` (App
#    installation) and `ghu_` (App user-to-server) are not. The token is read
#    into a variable and only its prefix is ever branched on — it is never
#    printed, passed as an argument, or written anywhere.
#
#    Anything else — `gh auth token` failing, or a prefix GitHub adds later —
#    fails CLOSED. Refusing is safe here in a way that proceeding is not: the
#    remedy names the one command that fixes an under-scoped OAuth login, so a
#    legitimate user is redirected rather than stranded, whereas proceeding on
#    an unrecognized credential is the credential-broadening this guard exists
#    to prevent.
active_token=""
active_token="$(gh auth token --hostname "${HOSTNAME_ARG}" 2>/dev/null)" || active_token=""
case "${active_token}" in
gho_* | ghp_*) ;; # a classic OAuth/PAT credential — refreshable, proceed
github_pat_* | ghs_* | ghu_*)
    die "the stored credential for ${HOSTNAME_ARG} is a fine-grained PAT or a GitHub App
  token, which carries permissions rather than OAuth scopes. 'gh auth refresh'
  would replace it with a broad classic token instead of fixing it. Grant the
  matching permission where that token was issued."
    ;;
*)
    die "could not identify the credential class for ${HOSTNAME_ARG} from its token, so
  refreshing it might replace a deliberately narrow credential with a broad
  classic one. If this is an OAuth login that is merely under-scoped, re-run:
  gh auth login --hostname ${HOSTNAME_ARG} --git-protocol https --web --scopes \"${REQUEST_LIST}\""
    ;;
esac
unset active_token

echo "==> Host:            ${HOSTNAME_ARG}"
echo "==> Current scopes:  ${scopes_before:-<none reported>}"
echo "==> Required:        $(gh_scopes_human "${GH_REQUIRED_SCOPES}")"
echo "==> Requesting:      ${REQUEST_LIST}"
echo ""

# Nothing to do? Say so and stop, WITHOUT opening a browser. `gh auth refresh`
# is an interactive OAuth flow even when it would change nothing, so an
# unconditional run makes the documented sequence (log in with the derived
# scopes, then run this to verify) authenticate twice, and every idempotent
# re-run repeats it. The docs promise this requests the MISSING scopes; this is
# that promise kept.
if [ -z "$(gh_scopes_missing_requested "${scopes_before}")" ]; then
    echo "Already complete — no refresh needed."
    exit 0
fi

gh auth refresh --hostname "${HOSTNAME_ARG}" -s "${REQUEST_LIST}"

# 3. Verify the grant LANDED. `gh auth refresh` can exit 0 having granted less
#    than was asked for — a browser flow the operator edited, an org that
#    restricts the scope. Reporting success off the exit code alone would put
#    the session right back into the failure this task exists to end.
verify_out="$(gh_auth_status_active)" ||
    die "post-refresh 'gh auth status' failed — the credential may be broken."
scopes_after="$(printf '%s\n' "${verify_out}" | grep -i 'token scopes:' || true)"

echo ""
echo "==> New scopes:      ${scopes_after:-<none reported>}"

case "${scopes_after}" in
*"'"*) ;;
*)
    die "no OAuth scopes reported after the refresh. A fine-grained PAT or an
  App token carries permissions rather than scopes — grant Projects access
  where that token was issued instead."
    ;;
esac

# Every REQUESTED scope, not merely the required alternation: the refresh was
# handed both Projects scopes, and coming back with only the read one leaves
# board writes broken while satisfying `project|read:project`.
missing="$(gh_scopes_missing_requested "${scopes_after}")"
if [ -n "${missing}" ]; then
    die "the refresh did not grant: $(gh_scopes_human "${missing}").
  Re-run and approve every scope, or check whether the organization restricts
  them (Settings → Third-party access)."
fi

echo ""
echo "All requested scopes present: $(gh_scopes_request_list)"
