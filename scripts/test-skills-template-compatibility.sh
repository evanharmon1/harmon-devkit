#!/usr/bin/env bash
# Exercise the consumer contract against the skills actually selected for sync.
# This is deliberately not a promise about every future devkit/template pair.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { # shell-robustness: ok — fail() always ends in exit 1, so its own status is never read as an assertion result
    echo "skills-template-compatibility: $*" >&2
    echo "Update the consumer template (or coordinate its contract update) before retrying this skills version; do not downgrade silently or bypass this gate." >&2
    echo "Known boundary: harmon-devkit v0.65.0 needs the claim-release repair shipped in harmon-init v5.14.0: https://github.com/evanharmon1/harmon-init/pull/1872" >&2
    exit 1
}

command -v yq >/dev/null 2>&1 || fail "yq is required to establish compatibility"
pin="$(yq -er '.source.ref' .skills-sync.yaml)" || fail "cannot read the requested skills version"
[[ "$pin" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || fail "invalid requested skills version: $pin"
major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
# Match the stable-tag bounds used by the release sync before numeric comparison.
[ "${#major}" -le 5 ] && [ "${#minor}" -le 5 ] && [ "${#BASH_REMATCH[3]}" -le 5 ] ||
    fail "requested skills version is too large: $pin"

workflows=(.github/workflows/claim-release.yml
    'template/.github/workflows/[% if claim_release_available %]claim-release.yml[% endif %].jinja')
selected=0
for workflow in "${workflows[@]}"; do
    [ -f "$workflow" ] || continue
    selected=1
    # v0.65.0 added delivery-PR label writes. Offline gh stubs cannot prove
    # token permissions, so check that separate, observed consumer obligation.
    # Job permissions replace the workflow default when present.
    if ((10#$major > 0 || 10#$minor >= 65)) &&
        [ -f .claude/skills/track-work/assets/clear-needs-review.sh ]; then
        yq -o=json "$workflow" | jq -e '
            def can_write_prs:
                if type == "object" then .["pull-requests"] == "write"
                else . == "write-all" end;
            .permissions as $defaults |
            [.jobs[] | (if has("permissions") then .permissions else $defaults end) | can_write_prs] |
            length > 0 and all' >/dev/null ||
            fail "$pin: $workflow needs pull-requests: write for delivery-PR cleanup"
    fi
done
if [ "$selected" -eq 0 ]; then
    echo "skills-template-compatibility: $pin has no claim-release consumer; no cleanup contract to exercise"
    exit 0
fi
[ -f scripts/test-claim-release-merged.sh ] || fail "$pin: missing consumer contract scripts/test-claim-release-merged.sh"
bash scripts/test-claim-release-merged.sh || fail "$pin: consumer contract scripts/test-claim-release-merged.sh failed"
echo "skills-template-compatibility: $pin passed the selected consumer cleanup contract"
