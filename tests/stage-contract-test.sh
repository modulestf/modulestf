#!/bin/bash
# shellcheck disable=SC2319 # "$(<test>; echo $?)" passes the test's own status to check
# Self-check for references/stage-contract.jq of terraform-module-pr-review: the pin grammar,
# pin_diff, the stage file key sets, the live pin, the checks classifier and the merge commit
# title, with a negative self-check that mutates a temp copy of the library. No network.
# Run: tests/stage-contract-test.sh
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
SC="$SRC/.agents/skills/terraform-module-pr-review/references/stage-contract.jq" # the library under test
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/stage-contract-test.XXXXXX")" && pwd -P)" && [ -n "$TMP" ] || { echo "FAIL no temporary directory"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
fails=0
check() { if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
[ -f "$SC" ] || { echo "FAIL no $SC"; exit 1; }
JL() { jq -L "$(dirname "$SC")" "$@"; } # the library under test; the self-check swaps in a mutated copy
INC='include "stage-contract";'

S40=0123456789abcdef0123456789abcdef01234567
B40=89abcdef0123456789abcdef0123456789abcdef
M40=fedcba9876543210fedcba9876543210fedcba98
PIN="$(jq -c -n --arg h "$S40" --arg b "$B40" --arg m "$M40" '{target: "o/r#7", number: 7, base_repo: "o/r", head_repo: "f/r",
  base_ref: "main", head_ref: "fix/x", head_sha: $h, base_sha: $b, merge_base: $m}')"

# pin_ok on a pin edited by a jq filter: prints true or false.
pok() { JL -r -n --argjson p "$PIN" "$INC \$p | $1 | pin_ok"; }

[ "$(pok .)" = true ]; check "pin_ok accepts the fixture pin" $?
[ "$(pok '. + {run_id: "r1", skill_version: "0.8.0", diff_hash: "abc"}')" = true ]; check "pin_ok accepts the information keys" $?
[ "$(pok '.head_repo = null')" = true ]; check "pin_ok accepts a null head_repo (a deleted fork)" $?
for k in target number base_repo head_repo base_ref head_ref head_sha base_sha merge_base; do
  [ "$(pok "del(.$k)")" = false ]; check "pin_ok rejects a missing $k" $?
done
[ "$(pok '. + {extra: 1}')" = false ]; check "pin_ok rejects an extra key" $?
[ "$(pok '.head_sha = (.head_sha | .[0:39])')" = false ]; check "pin_ok rejects a 39-char SHA" $?
[ "$(pok '.head_sha = (.head_sha | ascii_upcase)')" = false ]; check "pin_ok rejects an upper-case SHA" $?
[ "$(pok '.merge_base = ""')" = false ]; check "pin_ok rejects an empty merge base" $?
[ "$(pok '.head_ref = "fix x"')" = false ]; check "pin_ok rejects a ref with a space" $?
[ "$(pok '.base_ref = "a..b"')" = false ]; check "pin_ok rejects a ref with .." $?
[ "$(pok '.base_repo = "o/r/x"')" = false ]; check "pin_ok rejects a bad repo" $?
[ "$(pok '.number = "7"')" = false ]; check "pin_ok rejects a string number" $?
[ "$(pok '.number = 8')" = false ]; check "pin_ok rejects a target that names another number" $?
[ "$(pok '.run_id = 5')" = false ]; check "pin_ok rejects a non-string information key" $?
[ "$(JL -r -n "$INC [] | pin_ok")" = false ]; check "pin_ok rejects a non-object" $?

# pin_diff
pd() { JL -r -n --argjson p "$PIN" --argjson l "$1" "$INC \$p | pin_diff(\$l)"; }
[ "$(pd "$PIN")" = null ]; check "pin_diff is null for an identical pin" $?
[ "$(pd "$(jq -c '.base_ref = "release"' <<< "$PIN")")" = base_ref ]; check "pin_diff names a retargeted base ref with equal SHAs" $?
[ "$(pd "$(jq -c '.head_sha = "'"$B40"'" | .base_ref = "x"' <<< "$PIN")")" = base_ref ]; check "pin_diff names the first differing key in pin order" $?
[ "$(pd "$(jq -c '. + {run_id: "other"}' <<< "$PIN")")" = null ]; check "pin_diff ignores the information keys" $?
[ "$(pd "$(jq -c 'del(.merge_base)' <<< "$PIN")")" = merge_base ]; check "pin_diff names a key the live pin lacks" $?

# stage_ok
PLAN="$(jq -c -n --argjson p "$PIN" '{kind: "review-plan", schema: 1, pin: $p, verdict: "approve", proposed_event: "APPROVE", findings: [],
  read_at: "2026-11-10T00:00:00Z", handover_block: "x", module_prefix: "", module_profile: "terraform-aws-modules", reviewer_id: "r"}')"
APPLIED="$(jq -c -n --argjson p "$PIN" --arg h "$S40" '{kind: "applied", schema: 1, pin: $p, new_sha: $h, plan_head_sha: $h, round_verdict: "clean"}')"
sok() { JL -r -n --argjson s "$1" "$INC \$s | $2 | stage_ok(\"$3\")"; }
[ "$(sok "$PLAN" . review-plan)" = true ]; check "stage_ok accepts a review-plan file" $?
[ "$(sok "$APPLIED" . applied)" = true ]; check "stage_ok accepts an applied file" $?
[ "$(sok "$APPLIED" . review-plan)" = false ]; check "stage_ok(review-plan) rejects kind applied" $?
[ "$(sok "$PLAN" . applied)" = false ]; check "stage_ok(applied) rejects kind review-plan" $?
[ "$(sok "$PLAN" '.schema = 2' review-plan)" = false ]; check "stage_ok rejects schema 2" $?
[ "$(sok "$PLAN" '.schema = "1"' review-plan)" = false ]; check "stage_ok rejects a string schema" $?
[ "$(sok "$PLAN" '. + {x: 1}' review-plan)" = false ]; check "stage_ok rejects an unknown field" $?
[ "$(sok "$PLAN" 'del(.reviewer_id)' review-plan)" = false ]; check "stage_ok rejects a missing field" $?
[ "$(sok "$PLAN" '.pin.head_sha = "x"' review-plan)" = false ]; check "stage_ok rejects an invalid pin" $?
[ "$(sok "$PLAN" . other)" = false ]; check "stage_ok rejects an unknown kind" $?

# live_pin: the pin of a pulls GET object plus the merge base
PR="$(jq -c -n --arg h "$S40" --arg b "$B40" '{number: 7, base: {ref: "main", sha: $b, repo: {full_name: "o/r"}}, head: {ref: "fix/x", sha: $h, repo: {full_name: "f/r"}}}')"
[ "$(JL -c -n --argjson pr "$PR" --arg m "$M40" "$INC {pr: \$pr, merge_base: \$m} | live_pin")" = "$PIN" ]; check "live_pin builds the pin from a pull request read" $?
[ "$(JL -r -n --argjson pr "$(jq -c '.head.repo = null' <<< "$PR")" --arg m "$M40" "$INC {pr: \$pr, merge_base: \$m} | live_pin | pin_ok")" = true ]; check "live_pin of a deleted fork is a valid pin" $?

# checks_class: moved from fix-run.jq, unchanged
cc() { JL -r -n --argjson x "$1" "$INC \$x | checks_class | .class"; }
[ "$(cc '{"ok": false, "runs": [], "statuses": [], "pinned_total": 0}')" = "not finished" ]; check "checks_class: a failed read is not finished" $?
[ "$(cc '{"ok": true, "runs": [], "statuses": [], "pinned_total": 0}')" = passing ]; check "checks_class: no checks and none at the pinned head passes" $?
[ "$(cc '{"ok": true, "runs": [{"name": "a", "id": 1, "status": "completed", "conclusion": "success"}], "statuses": [], "pinned_total": 1}')" = passing ]; check "checks_class: a successful run passes" $?
[ "$(cc '{"ok": true, "runs": [{"name": "a", "id": 1, "status": "completed", "conclusion": "failure"}], "statuses": [], "pinned_total": 1}')" = "not finished" ]; check "checks_class: a failed run is not finished" $?

# commit_title
ct() { JL -c -n --arg t "$1" "$INC \$t | commit_title(7)"; }
[ "$(ct $'feat: x\a\n  y')" = '{"title":"feat: x y (#7)","cut":false}' ]; check "commit_title strips controls and collapses whitespace" $?
LONG="$(printf 'a%.0s' $(seq 1 90))"
[ "$(ct "$LONG")" = "{\"title\":\"$(printf 'a%.0s' $(seq 1 72)) (#7)\",\"cut\":true}" ]; check "commit_title cuts a 90-char title to 72 and flags it" $?
[ "$(ct "$(printf 'a%.0s' $(seq 1 72))" | jq -r .cut)" = false ]; check "commit_title does not flag a 72-char title" $?

# --- Negative self-check: each mutation of a temp copy must make its named case fail. ----------
oc=0
mutate() { # name, perl substitution, case command (run with SC at the copy)
  local d="$TMP/mut-$oc"; oc=$((oc + 1)); mkdir -p "$d"
  cp "$SC" "$d/stage-contract.jq"
  perl -0pi -e "$2" "$d/stage-contract.jq"
  if cmp -s "$d/stage-contract.jq" "$SC"; then check "self-check: $1 (the mutation changed nothing)" 1; return; fi
  local keep="$SC" before="$fails"; SC="$d/stage-contract.jq"
  ( eval "$3" ) > /dev/null 2>&1; local s=$?
  SC="$keep"; fails="$before"
  check "self-check: $1 is caught" "$([ "$s" != 0 ]; echo $?)"
}
mutate "the extra-key test dropped" 's/  and \(keys - pin_keys - pin_info_keys \| length\) == 0\n//' \
  '[ "$(pok ". + {extra: 1}")" = false ]'
mutate "base_ref dropped from the pin keys" 's/"base_ref", "head_ref", "head_sha"/"head_ref", "head_sha"/' \
  '[ "$(pd "$(jq -c ".base_ref = \"release\"" <<< "$PIN")")" = base_ref ]'
mutate "the SHA length unchecked" 's/\{40\}\$"\);\ndef repo_ok/{39,41}\$");\ndef repo_ok/' \
  '[ "$(pok ".head_sha = (.head_sha | .[0:39])")" = false ]'
mutate "the schema check dropped" 's/  and \.schema == 1\n//' \
  '[ "$(sok "$PLAN" ".schema = 2" review-plan)" = false ]'
mutate "the key-set check dropped" 's/  and \(\(keys \| sort\) == \(stage_keys\[\$kind\] \| sort\)\);/;/' \
  '[ "$(sok "$PLAN" ". + {x: 1}" review-plan)" = false ]'
mutate "the title cut dropped" 's/\$t\[0:72\]/\$t/' \
  '[ "$(ct "$LONG")" = "{\"title\":\"$(printf "a%.0s" $(seq 1 72)) (#7)\",\"cut\":true}" ]'

if [ "$fails" = 0 ]; then echo "all stage-contract checks passed"; else echo "$fails stage-contract check(s) FAILED"; exit 1; fi
