#!/usr/bin/env bash
# Offline filing tests, including the real metadata checker with stubbed network.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/skills/track-work/assets" "$tmp/skills/triage/assets" "$tmp/bin"
cp ai/skills/universal/track-work/assets/file-review-finding.sh \
    ai/skills/universal/track-work/assets/parse-issue-markdown.sh \
    ai/skills/universal/track-work/assets/parse-issue-markdown.awk "$tmp/skills/track-work/assets/"
real_checker="$PWD/ai/skills/universal/track-work/assets/check-issue-metadata.sh"
git -C "$tmp" init -q
git -C "$tmp" remote add origin https://github.com/owner/repo.git
cp label-registry.json "$tmp/label-registry.json"
script="$tmp/skills/track-work/assets/file-review-finding.sh"
fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "TEST FAIL: $*" >&2
    exit 1
}
cat >"$tmp/skills/track-work/assets/check-issue-metadata.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'preflight %s\n' "$*" >>"$FR_CALLS"
[ "${FR_SCENARIO:-}" != preflight-fail ] || exit 1
case "$*" in *--agent-authored*) ;; *) exit 9 ;; esac
args=("$@")
while [ "$#" -gt 0 ]; do
    if [ "$1" = --body-file ]; then cp "$2" "$FR_BODY"; fi
    shift
done
if [ "${FR_REAL_PREFLIGHT:-0}" = 1 ]; then
    exec "$FR_REAL_CHECKER" "${args[@]}"
fi
STUB
cat >"$tmp/skills/track-work/assets/verify-issue-receipt.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'receipt %s\n' "$*" >>"$FR_CALLS"
[ "${FR_SCENARIO:-}" != receipt-fail ] || exit 1
STUB
cat >"$tmp/skills/triage/assets/triage-apply.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'triage %s\n' "$*" >>"$FR_CALLS"
if [ "$1" = native-type ]; then
    echo '{"state":"set","name":"Bug"}'
    exit 0
fi
[ "${TRIAGE_EXECUTE:-}" = 1 ] || exit 9
[ "${FR_SCENARIO:-}" != triage-fail ] || exit 1
priority=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --priority-ai) priority="$2" ;;
    --priority) exit 9 ;;
    esac
    shift
done
[ -n "$priority" ] || exit 9
printf '%s\n' "$priority" >"$FR_PRIORITY"
if [ "$FR_OWNER" = organization ]; then
    printf 'storage field:Priority (AI)=%s\n' "$priority" >>"$FR_CALLS"
else
    printf 'storage label:priority-ai:%s\n' "$priority" >>"$FR_CALLS"
fi
STUB
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >>"$FR_CALLS"
case "$1 $2" in
'api repos/owner/repo')
    if [ "$FR_OWNER" = personal ]; then echo User; else echo Organization; fi
    ;;
'api repos/owner/repo/contents/') echo '[]' ;;
'api orgs/owner/issue-types') printf '%s\n' Bug Task Feature ;;
'label list')
    printf '%s\n' bug area:skills layer:logic domain:agent-workflow ai-generated needs-triage \
        impact:medium risk:low complexity:s priority-ai:p0 priority-ai:p1 priority-ai:p2 priority-ai:p3 tier:standard
    ;;
'issue create')
    [ "${FR_SCENARIO:-}" != create-fail ] || exit 7
    printf '%s\n' 'https://github.com/owner/repo/issues/42'
    ;;
'issue edit')
    case "$*" in *--add-label\ needs-triage) ;; *) exit 9 ;; esac
    ;;
'issue view')
    [ "${FR_SCENARIO:-}" != read-fail ] || exit 1
    priority="$(cat "$FR_PRIORITY")"
    if [ "${FR_SCENARIO:-}" = wrong-priority ]; then priority=p4; fi
    labels='["area:skills","layer:logic","domain:agent-workflow","ai-generated","tier:standard"]'
    if [ "$FR_OWNER" = personal ]; then
        labels="$(jq '. + ["bug","impact:medium","risk:low","complexity:s"]' <<<"$labels")"
        labels="$(jq --arg p "priority-ai:$priority" '. + [$p]' <<<"$labels")"
    fi
    jq '{labels: map({name:.})}' <<<"$labels"
    ;;
'api graphql')
    if [[ "$*" == *'issueFields(first:'* ]]; then
        printf '%s\n' '[{"id":"FI","name":"Impact","options":[{"id":"I1","name":"medium"}]},{"id":"FR","name":"Risk","options":[{"id":"R1","name":"low"}]},{"id":"FC","name":"Complexity","options":[{"id":"C1","name":"s"}]}]'
        exit 0
    fi
    priority="$(cat "$FR_PRIORITY")"
    if [ "${FR_SCENARIO:-}" = wrong-priority ]; then priority=p4; fi
    jq -n --arg p "$priority" '{data:{repository:{issue:{issueFieldValues:{
      pageInfo:{hasNextPage:false},nodes:[
        {field:{name:"Impact"},name:"Medium"},{field:{name:"Risk"},name:"Low"},
        {field:{name:"Complexity"},name:"S"},{field:{name:"Priority (AI)"},name:$p}]}}}}}' |
        if [ "${FR_SCENARIO:-}" = unsupported-node ]; then
            jq '.data.repository.issue.issueFieldValues.nodes += [{}, {field:{name:"Text field"},name:null}]'
        else cat; fi
    ;;
*) exit 9 ;;
esac
STUB
chmod +x "$tmp/bin/gh" "$tmp/skills/track-work/assets/"*.sh "$tmp/skills/triage/assets/triage-apply.sh"
cat >"$tmp/draft.md" <<'BODY'
## Problem

Retain the defect and its design constraints.

```markdown
## Provenance
```

## Acceptance criteria

- [ ] [CI] The regression has a verified follow-up
BODY
cp "$tmp/draft.md" "$tmp/base-draft.md"

run_helper() {
    local rc=0 type_args=()
    : >"$tmp/calls"
    : >"$tmp/priority"
    if [ "$owner" = personal ]; then type_args=(--work-type-label bug); else type_args=(--issue-type Bug); fi
    env PATH="$tmp/bin:$PATH" TRIAGE_EXECUTE=1 FR_OWNER="$owner" FR_SCENARIO="$scenario" \
        FR_CALLS="$tmp/calls" FR_BODY="$tmp/body" FR_PRIORITY="$tmp/priority" \
        FR_REAL_PREFLIGHT="${real_preflight:-0}" FR_REAL_CHECKER="$real_checker" \
        "$script" --repo owner/repo --repo-root "$tmp" --owner-type "$owner" \
        --title '(review): Preserve the finding' --body-file "$tmp/draft.md" \
        --source-pr https://github.com/owner/repo/pull/10 --reviewer 'Codex cloud review' \
        --reviewer-priority "$badge" --adjudicated-priority "$adjudicated" \
        --impact medium --risk low --complexity s "${type_args[@]}" \
        --label area:skills --label layer:logic --label domain:agent-workflow --label ai-generated \
        "$@" >"$tmp/out" 2>"$tmp/err" || rc=$?
    printf '%s\n' "$rc"
}
scenario=normal
for owner in personal organization; do
    for badge in P0 P1 P2 P3; do
        adjudicated="$badge"
        expected="$(printf '%s' "$adjudicated" | tr '[:upper:]' '[:lower:]')"
        [ "$(run_helper)" = 0 ] || fail "$owner $badge: $(cat "$tmp/err")"
        [ "$(cat "$tmp/out")" = 42 ] || fail 'stdout must contain only issue number'
        grep -q -- "--priority-ai $expected --execute" "$tmp/calls" || fail "wrong mapping for $badge"
        if [ "$owner" = personal ]; then
            grep -Fq "storage label:priority-ai:$expected" "$tmp/calls" || fail 'personal priority is a label'
            grep -q -- '--label impact:medium --label risk:low --label complexity:s' "$tmp/calls" || fail 'personal ratings missing at creation'
        else
            grep -Fq "storage field:Priority (AI)=$expected" "$tmp/calls" || fail 'org priority is a field'
            grep -q -- '--type Bug' "$tmp/calls" || fail 'native type missing at creation'
            ! grep -q -- '--label impact:' "$tmp/calls" || fail 'org ratings must not be labels'
        fi
        grep -Fq 'Source PR: https://github.com/owner/repo/pull/10' "$tmp/body" || fail 'source PR lost'
        grep -Fq 'Reviewer: Codex cloud review' "$tmp/body" || fail 'reviewer lost'
        grep -Fq "Reviewer badge: $badge" "$tmp/body" || fail 'raw badge lost'
        [ "$(grep -c '^gh issue create ' "$tmp/calls")" = 1 ] || fail 'must create exactly once'
    done
    badge=P1 adjudicated=P2
    [ "$(run_helper)" = 0 ] || fail 'downgraded finding failed'
    grep -q -- '--priority-ai p2 --execute' "$tmp/calls" || fail 'reviewer badge overrode adjudication'
    grep -Fq 'Reviewer badge: P1' "$tmp/body" || fail 'raw downgrade badge missing'
    grep -Fq 'Adjudicated badge: P2' "$tmp/body" || fail 'adjudicated downgrade badge missing'
    badge=unbadged
    for adjudicated in P0 P1 P2 P3; do
        [ "$(run_helper)" = 0 ] || fail 'unbadged finding failed'
        expected="$(printf '%s' "$adjudicated" | tr '[:upper:]' '[:lower:]')"
        [ "$adjudicated" != P3 ] || expected=p2
        grep -q -- "--priority-ai $expected --execute" "$tmp/calls" || fail 'unbadged priority floor lost'
        grep -Fq 'Reviewer badge: unbadged' "$tmp/body" || fail 'unbadged source missing'
    done
    badge=P2 adjudicated=P2
    for scenario in preflight-fail receipt-fail create-fail; do
        [ "$(run_helper)" != 0 ] || fail "$scenario accepted"
        [ ! -s "$tmp/out" ] || fail "$scenario returned a created number"
        ! grep -q '^triage\|^gh issue edit ' "$tmp/calls" || fail "$scenario wrote after failure"
    done
    for scenario in triage-fail read-fail wrong-priority; do
        [ "$(run_helper)" != 0 ] || fail "$scenario accepted"
        [ "$(cat "$tmp/out")" = 42 ] || fail "$scenario lost existing number"
        grep -Fq 'gh issue edit 42 --repo owner/repo --add-label needs-triage' "$tmp/calls" || fail 'partial failure not marked'
        [ "$(grep -c '^gh issue create ' "$tmp/calls")" = 1 ] || fail 'partial failure recreated issue'
    done
    scenario=normal
    for badge in P4 invalid; do
        [ "$(run_helper)" != 0 ] || fail 'invalid badge accepted'
        [ ! -s "$tmp/calls" ] || fail 'invalid badge reached a dependency'
    done
    badge=P2 adjudicated=P4
    [ "$(run_helper)" != 0 ] || fail 'p4 adjudication accepted'
    [ ! -s "$tmp/calls" ] || fail 'invalid adjudication reached a dependency'
done
# Exercise the helper's exact preflight argv and generated body against the
# real checker. Only GitHub/network and the post-preflight writer are stubbed;
# all receipts remain in the throwaway target checkout.
real_preflight=1 scenario=normal badge=P2 adjudicated=P2
for owner in personal organization; do
    for provenance in absent present; do
        cp "$tmp/base-draft.md" "$tmp/draft.md"
        if [ "$provenance" = present ]; then
            # A fenced heading must not be mistaken for the real heading.
            printf '\n## pRoVeNaNcE ###\n\nExisting provenance.\n' >>"$tmp/draft.md"
        fi
        [ "$(run_helper)" = 0 ] || fail "real metadata checker: $owner provenance $provenance: $(cat "$tmp/err")"
        grep -Fq 'Source PR:' "$tmp/body" || fail 'real preflight lost provenance'
        echo "PASS: real metadata checker $owner provenance $provenance"
    done
done
real_preflight=0 owner=organization scenario=unsupported-node
[ "$(run_helper)" = 0 ] || fail "unsupported org field node: $(cat "$tmp/err")"
echo 'PASS: organization readback ignores unsupported field nodes'
printf 'ALL PASS: review filing mapping, provenance, owner storage, and failure propagation\n'
