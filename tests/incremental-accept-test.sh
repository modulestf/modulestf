#!/bin/bash
# Self-check for host-pass.sh accept after an incremental prior (terraform-module-pr-review,
# references/host-pass.md, Incremental Review): the verdict, the Carry column of the reviewer's
# rule-facts.md, the carried findings and the scope, each with an accept case and a reject case,
# and a rule the table does not name taken as never, as prior takes it. A negative self-check
# mutates temp copies of the script and confirms each weakened copy is caught. No network.
# Needs bash, jq and perl.
# Run: tests/incremental-accept-test.sh
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
REF="$SRC/.agents/skills/terraform-module-pr-review/references"
RF="$SRC/.agents/skills/terraform-module-reviewer/references/rule-facts.md"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/incremental-accept-test.XXXXXX")" && pwd -P)" && [ -n "$TMP" ] || { echo "FAIL no temporary directory"; exit 1; }
[ -n "${KEEP:-}" ] || trap 'rm -rf "$TMP"' EXIT
HPA="$REF/host-pass.sh" # the script under test; the self-check swaps in mutated copies
HEAD=0123456789abcdef0123456789abcdef01234567
BASE=89abcdef0123456789abcdef0123456789abcdef
fails=0

check() { # name, status (0 = holds)
  if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

# --- An incremental prior: one carried finding of a file rule outside the scope, main.tf.

PRIOR="$TMP/prior"; mkdir -p "$PRIOR"
jq -n --arg h "$HEAD" --arg b "$BASE" '{format: 1, mode: "incremental", reason: "ok", head: $h,
  previous_head: $b, previous_merge_base: $b, depth: 1, last_full: "2026-11-14T00:00:00Z", scope: ["main.tf"],
  metrics: {changed_since: 1, changed_total: 1, commits: 1, pages: 1}}' > "$PRIOR/meta.json"
CARRIED='{"file": "outside.tf", "line": 1, "rule_id": "structure.missing-description", "severity": "LOW", "summary": "S.", "suggested_fix": "F."}'
printf '[%s]\n' "$CARRIED" > "$PRIOR/carried.json"; cp "$PRIOR/carried.json" "$PRIOR/carried-task.json"
echo '["main.tf"]' > "$PRIOR/scope-task.json"

# The Carry values used: structure.missing-description is file, structure.grouping never, and
# structure.third-party-promotion is no row of the table.
carry_of() { grep -E "^\| \`$1\` \|" "$RF" | cut -d'|' -f6 | tr -d ' '; }
check "fixture: the Carry values of the rules used" \
  "$([ "$(carry_of structure.missing-description)" = file ] && [ "$(carry_of structure.grouping)" = never ] &&
     [ -z "$(carry_of structure.third-party-promotion)" ]; echo $?)"

INSCOPE='{"file": "main.tf", "line": 2, "rule_id": "structure.missing-description", "severity": "LOW", "summary": "T.", "suggested_fix": "G."}'
NEVER='{"file": "other.tf", "line": 3, "rule_id": "structure.grouping", "severity": "LOW", "summary": "U.", "suggested_fix": "H."}'
OUTSCOPE='{"file": "other.tf", "line": 4, "rule_id": "structure.missing-description", "severity": "LOW", "summary": "V.", "suggested_fix": "I."}'
NOROW='{"file": "other.tf", "line": 5, "rule_id": "structure.third-party-promotion", "severity": "LOW", "summary": "W.", "suggested_fix": "J."}'

inc() { # verdict, findings as JSON objects without id -> the accept line; INC_RULES names another rules file
  printf '%s\n' "${@:2}" | jq -s 'to_entries | map(.value + {id: ("F-00\(.key + 1)")})' > "$TMP/f.json"
  jq -n --arg h "$HEAD" --arg v "$1" '{head_sha: $h, verdict: $v}' > "$TMP/r.json"
  bash "$HPA" accept --prior "$PRIOR" --findings "$TMP/f.json" --result "$TMP/r.json" --rules "${INC_RULES:-$RF}"
}
OK="findings accepted: incremental"

# --- The verdict.
t_verdict_ok() { [ "$(inc "approve with nits" "$CARRIED" "$INSCOPE")" = "$OK" ]; }
t_verdict_bad() { [ "$(inc approve "$CARRIED" "$INSCOPE")" = "findings rejected: the verdict does not follow from the findings" ]; }
t_verdict_ok; check "verdict: approve with nits beside LOW findings is accepted" $?
t_verdict_bad; check "verdict: approve beside LOW findings is rejected" $?

# --- The Carry column: read from the fifth column of each row, never the last.
perl -pe 's/^(\| `[a-z]+\.[a-z0-9-]+` \|(?: [^|]* \|){3}) (?:file|never) \|/$1 maybe |/' "$RF" > "$TMP/nocarry.md"
t_carry_ok() { [ "$(inc "approve with nits" "$CARRIED" "$INSCOPE" "$NEVER")" = "$OK" ]; }
t_carry_bad() { [ "$(INC_RULES="$TMP/nocarry.md" inc "approve with nits" "$CARRIED" "$INSCOPE")" = "findings rejected: no carry column" ]; }
t_carry_ok; check "carry: a file rule in the scope and a never rule outside it are accepted" $?
t_carry_bad; check "carry: a rules file whose Carry column holds no carry value is rejected" $?

# --- The carried findings: each exactly once.
t_carried_ok() { [ "$(inc "approve with nits" "$INSCOPE" "$CARRIED")" = "$OK" ]; }
t_carried_bad() {
  [ "$(inc "approve with nits" "$INSCOPE")" = "findings rejected: a carried finding is missing, changed or repeated" ] &&
    [ "$(inc "approve with nits" "$CARRIED" "$CARRIED")" = "findings rejected: a carried finding is missing, changed or repeated" ]
}
t_carried_ok; check "carried: the carried finding once, in any place, is accepted" $?
t_carried_bad; check "carried: the carried finding missing or repeated is rejected" $?

# --- The scope: a file rule only on a file in the scope.
t_scope_ok() { [ "$(inc "approve with nits" "$CARRIED" "$INSCOPE")" = "$OK" ]; }
t_scope_bad() { [ "$(inc "approve with nits" "$CARRIED" "$OUTSCOPE")" = "findings rejected: a finding outside the scope of an incremental review" ]; }
t_scope_ok; check "scope: a file rule on a file in the scope is accepted" $?
t_scope_bad; check "scope: a file rule on a file outside the scope is rejected" $?

# --- A rule the table does not name is never, as prior takes it: accepted when new, anywhere.
# The verdict is inconclusive, which a ladder that holds such a rule at rule 4 also gives.
t_norow() { [ "$(inc inconclusive "$CARRIED" "$NOROW")" = "$OK" ]; }
t_norow; check "no Carry value: a new finding of a rule the table does not name is never, and accepted" $?

# --- Negative self-check: each mutation of a temp copy must make its named case fail.

mutate() { # name, perl substitution on host-pass.sh, case function
  local d="$TMP/mut-$1"; d="${d// /-}"; mkdir -p "$d"
  cp "$REF/host-pass.sh" "$REF"/*.jq "$d/"
  perl -0pi -e "$2" "$d/host-pass.sh"
  if cmp -s "$d/host-pass.sh" "$REF/host-pass.sh"; then check "self-check: $1 (the mutation changed nothing)" 1; return; fi
  local keep="$HPA" before="$fails"; HPA="$d/host-pass.sh"
  "$3" > /dev/null 2>&1; local s=$?
  HPA="$keep"; fails="$before"
  check "self-check: $1 is caught" "$([ "$s" != 0 ]; echo $?)"
}
mutate "carry read from the last column" 's/\\\|\( \[\^\|\]\* \\\|\)\{3\} \(file\|never\) \\\|/\\|.*\\| (file|never) \\|\$/' t_carry_ok
mutate "a rule the table does not name taken as unknown" 's/\(\$carry\[\.rule_id\] \/\/ "never"\)/(\$carry[.rule_id] \/\/ "unknown")/' t_norow
mutate "the verdict check skipped" 's/\|\|\n    reject "the verdict does not follow from the findings"/|| true/' t_verdict_bad
mutate "the carried check skipped" 's/\|\|\n    reject "a carried finding is missing, changed or repeated"/|| true/' t_carried_bad
mutate "the scope check skipped" 's/\|\|\n    reject "a finding outside the scope of an incremental review"/|| true/' t_scope_bad
mutate "the prior check run in the same shell" 's/\( check_prior "\$prior" "\$head" \)/check_prior "\$prior" "\$head"/' t_scope_bad

echo
if [ "$fails" -eq 0 ]; then echo "incremental accept: all checks hold"; else echo "incremental accept: $fails failed"; exit 1; fi
