#!/bin/bash
# Self-check for the host render of terraform-module-pr-review (references/render-comment.sh and
# render-comment.jq): the worked examples of comment-format.md byte for byte, the verdict of
# every rule of verdict.md's ladder and the clamps on the proposed event, the What to do section
# and the Fix block of grouping rule 7, the leak scan, the at-mention step and refused inputs. A negative self-check mutates temp copies of the script
# and confirms each weakened copy is caught. No network. Needs bash and jq.
# Run: tests/render-comment-test.sh
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
REF="$SRC/.agents/skills/terraform-module-pr-review/references"
CF="$REF/comment-format.md"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/render-comment-test.XXXXXX")" && pwd -P)" && [ -n "$TMP" ] || { echo "FAIL no temporary directory"; exit 1; }
[ -n "${KEEP:-}" ] || trap 'rm -rf "$TMP"' EXIT
fails=0
HEAD=0123456789abcdef0123456789abcdef01234567
BASE=89abcdef0123456789abcdef0123456789abcdef
RCU="$REF/render-comment.sh" # the script under test; the self-check swaps in mutated copies
mkdir -p "$TMP/rundir"

check() { # name, status (0 = holds)
  if [ "$1" != "" ] && [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

# --- Fixtures.

n=0
f() { # rule, severity, file, line|null, summary, fix [, extra jq object] -> one finding
  n=$((n + 1))
  jq -nc --arg id "$(printf 'F-%03d' "$n")" --arg r "$1" --arg s "$2" --arg f "$3" --arg l "$4" \
    --arg sum "$5" --arg fix "$6" --argjson x "${7-"{}"}" \
    '{id: $id, rule_id: $r, severity: $s, file: $f, line: (if $l == "null" then null else ($l | tonumber) end),
      summary: $sum, suggested_fix: $fix, source: "llm"} + $x'
}
# stdin findings -> file, numbered F-001 on in order, since f runs in subshells
list() {
  jq -s 'to_entries | map(.value + {id: ("F-" + ("00\(.key + 1)" | .[-3:]))})' > "$TMP/$1.json"
  echo "$TMP/$1.json"
}

host() { # name [, jq update] -> host.json path
  jq -n --arg h "$HEAD" --arg b "$BASE" '{format: 1, repo: "example/terraform-aws-thing", number: 7,
    head_sha: $h, base_sha: $b, merge_base: $b, prefix: "",
    state: {state: "open", merged: false, draft: false, base_is_default: true, self_authored: false},
    signals: {threads: "pass", review_decision: "none", mergeability: "pass"}, own_review: null,
    could_not_run: [], unresolved_threads: [],
    conversation: {path: "graphql", omitted: null, considered: 0, bot_considered: 0, counts: {}, notes: []},
    related: {status: "not-applicable", open_unlinked: [], sidebar_not_read: false}} | '"${2-.}" > "$TMP/host-$1.json"
  echo "$TMP/host-$1.json"
}

checks() { # name, pass|fail|unknown [, jq update] -> checks directory
  local d="$TMP/checks-$1" runs='[]'
  case "$2" in
    fail) runs='[{"app_slug":"ci","check_suite_id":2,"conclusion":"failure","id":1,"status":"completed"}]' ;;
    unknown) runs='[{"app_slug":"ci","check_suite_id":2,"conclusion":null,"id":1,"status":"in_progress"}]' ;;
  esac
  mkdir -p "$d"
  jq -n --arg h "$HEAD" --arg s "$2" --argjson runs "$runs" '{format: 1, head_sha: $h, signal: $s, reads: "ok",
    own_check: null, own_check_dropped: 0, own_jobs_dropped: 0, own_jobs_unreadable: false,
    check_runs: $runs, statuses: {state: "success", total_count: 0}} | '"${3-.}" > "$d/checks.json"
  echo "$d"
}

runf() { # name [, jq update] -> run file
  jq -n '{format: 1, triage: false, plan_ran: false, verify_gaps: [],
    coverage: {class: "complete", inert: false, unplanned: []},
    behaviour: {status: "ran", reason: null, triggers: [], claims: [], capped: 0},
    counts: {"instruction-like-text-from-others": 0, "conversation-claims-unread": 0,
             "review.quoted-claim-unverifiable": 0}} | '"${2-.}" > "$TMP/run-$1.json"
  echo "$TMP/run-$1.json"
}

HOST="$(host default)"
CHK="$(checks pass pass)"
RUNF="$(runf default)"
printf 'The change looks right.\n' > "$TMP/assess.txt"
ASSESS="$TMP/assess.txt"

# render findings [host] [checks] [run] [assessment file] [extra args...]: runs the script into a
# fresh output directory. Sets O (the directory), ST (the exit status) and MSG (stdout and stderr).
oc=0
render() {
  oc=$((oc + 1)); O="$TMP/out-$oc"; mkdir -p "$O"
  local fi="$1" ho="${2:-$HOST}" ch="${3:-$CHK}" ru="${4:-$RUNF}" as="${5:-$ASSESS}"
  shift 5 2> /dev/null || shift $#
  MSG="$(bash "$RCU" --head "$HEAD" --findings "$fi" --host "$ho" --checks "$ch" --run "$ru" \
    --assessment "$as" --run-dir "$TMP/rundir" --out "$O" "$@" 2>&1)"; ST=$?
}
verdict() { jq -r '.verdict + " " + .proposed_event' "$O/result.json" 2> /dev/null; }
rule() { printf '%s' "$MSG" | sed -n 's/^rendered .* (ladder rule \([0-9]\)), .*/\1/p'; }
empty_out() { [ -z "$(ls -A "$O")" ]; }

# The Nth markdown fence of comment-format.md, without its fence lines.
fence() { awk -v want="$1" '/^```markdown$/ { k++; if (k == want) { on = 1; next } } on && /^```$/ { exit } on' "$CF"; }
nofix() { grep -v '^ *- Fix: '; }
# Run 1 of pull request 410 predates the Fix lines, the Fix blocks of grouping rule 7 and the
# What to do section, so all three are removed from a render before it is compared with run 1.
run1() {
  perl -0pe 's/### What to do\n\n.*?\n\n(?=### Findings)//s;
    s/\n\n<details><summary>Fix for each location \(\d+\)<\/summary>\n\n.*?\n\n<\/details>(?:\n(?=\n- ))?//gs' | nofix
}

# --- Worked example (comment-format.md, Worked Example): three renders of one change.

WFIX1='In `modules/logging/main.tf`, set `retention_in_days` on the log group from a new `variable "log_retention_in_days"` in `modules/logging/variables.tf`, with the current literal as its default so existing callers keep it.'
WM="$(f coverage.optional-argument-unexposed MEDIUM modules/logging/main.tf 31 "The log group's retention argument is set to a literal, so callers cannot change how long logs are kept." "$WFIX1")"
WL="$(f structure.grouping LOW variables.tf 88 "The new variable sits between two unrelated groups instead of with the other logging inputs." 'Move the new variable in `variables.tf` into the logging inputs'"'"' group.')"
WF="$(printf '%s\n%s\n' "$WM" "$WL" | list worked)"
fence 6 | sed -n 1,3p > "$TMP/assess-worked.txt"

render "$WF" "" "" "" "$TMP/assess-worked.txt"
check "worked example 1: the body byte for byte" "$(cmp -s "$O/comment.md" <(fence 6); echo $?)"
check "worked example 1: block at rule 6, proposes REQUEST_CHANGES" "$([ "$(verdict)" = "block REQUEST_CHANGES" ] && [ "$(rule)" = 6 ]; echo $?)"

H2="$(host threads '.signals.threads = "unknown" | .could_not_run = [{kind: "thread-resolution-unknown"}]')"
render "$WF" "$H2" "" "" "$TMP/assess-worked.txt"
check "worked example 2: the body byte for byte" "$(cmp -s "$O/comment.md" <(fence 7); echo $?)"
check "worked example 2: inconclusive at rule 4, proposes COMMENT" "$([ "$(verdict)" = "inconclusive COMMENT" ] && [ "$(rule)" = 4 ]; echo $?)"

fence 8 | sed -n 1,2p > "$TMP/assess-worked3.txt"
render "$(printf '%s\n' "$WL" | list worked3)" "" "" "" "$TMP/assess-worked3.txt"
awk '/^### Findings$/ { exit } { print }' "$O/comment.md" | sed '$d' > "$TMP/worked3-head.md"
check "worked example 3: the body up to its findings byte for byte" "$(cmp -s "$TMP/worked3-head.md" <(fence 8); echo $?)"
check "worked example 3: approve with nits at rule 7" "$([ "$(verdict)" = "approve with nits COMMENT" ] && [ "$(rule)" = 7 ]; echo $?)"

# --- Example: Fix lines.

n=0
{ f scope.profile-file HIGH .github/workflows/security.yml null "New workflow file running Trivy, Checkov and Gitleaks; the profile's workflow set is exactly the five templates." "Remove the workflow."
  f scope.profile-file HIGH .github/workflows/test.yml null "New workflow file running Terraform native tests; the profile's workflow set is exactly the five templates." "Remove the workflow."
  f structure.comment-redundant MEDIUM main.tf 7 "The comment at line 7 restates the conditional on the next line." "Remove the comment."
  f coverage.attribute-not-output MEDIUM outputs.tf null "No output exposes the created role's \`unique_id\`, a stable computed attribute of \`aws_iam_role\`." "Add an \`iam_role_unique_id\` output with a \`try()\` fallback."
  f structure.flag-polarity MEDIUM variables.tf 200 "\`create_air_gapped_vault\` is a \`create_*\` boolean that defaults to \`false\`." "Rename it to \`enable_air_gapped_vault\`, since the air-gapped vault is opt in, or default it to \`true\`."
} | list fixlines > /dev/null
render "$TMP/fixlines.json"
awk '/^### Findings$/ { on = 1; getline; next } on && /^### / { exit } on' "$O/comment.md" > "$TMP/fixlines.md"
check "fix lines example: the findings byte for byte" "$(cmp -s "$TMP/fixlines.md" <(fence 3); echo $?)"

# --- Pull request 410. The reviewer's order is the Before block for MEDIUM and LOW, and the
# HIGH section of the collapsed render. Both examples predate the Fix line, so each finding gets
# the same placeholder fix, which merges nothing the summaries keep apart, and the Fix lines are
# removed from the render before the comparison.

parse_flat() { # severity-labelled "- `rule` - `loc` - summary" lines -> findings
  awk '/^\*\*[A-Z]+\*\*$/ { gsub(/\*/, ""); sev = $0; next } /^- `/ { print sev "\t" $0 }' |
  while IFS="$(printf '\t')" read -r sev line; do
    rule="${line#- \`}"; rule="${rule%%\`*}"
    rest="${line#- \`$rule\` - \`}"; loc="${rest%%\`*}"; sum="${rest#"$loc"\` - }"
    case "$loc" in *:[0-9]*) file="${loc%:*}"; ln="${loc##*:}" ;; *) file="$loc"; ln=null ;; esac
    f "$rule" "$sev" "$file" "$ln" "$sum" "Fix placeholder."
  done
}
n=0
{ fence 5 | awk '/^\*\*HIGH\*\*$/ { on = 1 } /^\*\*MEDIUM\*\*$/ { exit } on' |
    awk '/^- `[^`]*` \([0-9]+\):$/ { r = $2; next } /^  - `/ { sub(/^  - /, "- " r " - "); print; next } { print }' |
    parse_flat
  fence 1 | parse_flat
} | list pr410 > /dev/null
check "pull request 410: 30 findings, 3 HIGH, 16 MEDIUM, 11 LOW" "$(jq -e 'length == 30 and ([.[] | .severity] | group_by(.) | map(length)) == [3, 11, 16]' "$TMP/pr410.json" > /dev/null; echo $?)"

jq -r -L "$REF" 'include "render-comment"; findings_md(2; 1000; "")' "$TMP/pr410.json" |
  awk '/^\*\*MEDIUM\*\*$/ { on = 1 } on' | run1 > "$TMP/grouped.md"
check "pull request 410: grouped MEDIUM and LOW byte for byte" "$(cmp -s "$TMP/grouped.md" <(fence 2); echo $?)"

fence 5 | sed -n 1p > "$TMP/assess-410.txt"
H410="$(host pr410 '.conversation.considered = 1')"
render "$TMP/pr410.json" "$H410" "" "" "$TMP/assess-410.txt"
check "pull request 410: grouped and collapsed body byte for byte" "$(run1 < "$O/comment.md" | cmp -s - <(fence 5); echo $?)"
check "pull request 410: block at rule 2" "$([ "$(verdict)" = "block REQUEST_CHANGES" ] && [ "$(rule)" = 2 ]; echo $?)"
check "pull request 410: findings.json in body order with the seven fields" "$(jq -e --slurpfile in "$TMP/pr410.json" '
  length == 30 and (map(.id) | sort) == ($in[0] | map(.id) | sort)
  and .[0].rule_id == "examples.example-broken" and .[3].rule_id == "review.check-not-run"
  and all(.[]; keys == ["file","id","line","rule_id","severity","suggested_fix","summary"])' "$O/findings.json" > /dev/null; echo $?)"
check "pull request 410: result.json" "$(jq -e --arg h "$HEAD" --arg b "$BASE" '. == {target: "example/terraform-aws-thing#7",
  number: 7, head_sha: $h, base_sha: $b, verdict: "block", proposed_event: "REQUEST_CHANGES"}' "$O/result.json" > /dev/null; echo $?)"

# --- The ladder: one case per rule, and the orderings verdict.md calls out.

n=0
one() { f "$@" | list "case$n"; } # one finding -> file
pair() { { f "$1" "$2" a.tf 1 "First." "Fix."; f "$3" "$4" b.tf 2 "Second." "Fix."; } | list "case$n"; }
NONE="$(printf '' | list none)"
# The What to do section of the last render, without trailing blank lines; empty when absent.
todo() {
  awk '/^### What to do$/ { on = 1; print; next } on && /^### / { exit }
    on { if ($0 == "") b++; else { while (b > 0) { print ""; b-- } print } }' "$O/comment.md"
}
# The four facts comment-format.md, What to Do, says the ladder makes hold. The renderer does
# not check them, so every ladder case does.
invariant() {
  case "$(rule)" in
    1|2|3|5|6) todo | grep -q '^- \[ \] ' ;;
    7) jq -e 'all(.[]; .severity == "LOW")' "$O/findings.json" > /dev/null && ! todo | grep -q '^- \[ \] ' ;;
    8) jq -e 'all(.[]; .rule_id == "review.tool-disputed")' "$O/findings.json" > /dev/null && [ -z "$(todo)" ] ;;
    0) todo | grep -q '^- `[^`]*`.* one way to restore compatibility; see Findings\.$' ;;
    # Rule 4 renders What to do only with an item other than Optional and the gaps line; a list
    # of those alone gives way to the action line, and section 4 or 5 holds the unknowns.
    4) if [ -n "$(todo)" ]; then todo | grep -v -e '^- Optional: ' -e ' could not run; see Checks that could not run\.$' | grep -q '^- '
       else grep -qE '^### (Findings|Checks that could not run)$' "$O/comment.md"; fi ;;
    *) false ;;
  esac
}
ladder() { # name, expected "verdict EVENT", expected rule, render args...
  local name="$1" want="$2" r="$3"; shift 3
  render "$@"
  check "ladder: $name -> $want, rule $r" "$([ "$ST" = 0 ] && [ "$(verdict)" = "$want" ] && [ "$(rule)" = "$r" ]; echo $?)"
  check "ladder: $name, What to do invariant" "$(invariant; echo $?)"
}
ladder "a CRITICAL compat break alone" "hold for the next major COMMENT" 0 "$(pair compat.output-removed CRITICAL structure.grouping MEDIUM)"
ladder "a CRITICAL compat break and a HIGH non-compat finding" "block REQUEST_CHANGES" 1 "$(pair compat.output-removed CRITICAL structure.docs-contradict-code HIGH)"
ladder "a HIGH compat break alone" "block REQUEST_CHANGES" 2 "$(one compat.variable-removed HIGH a.tf 1 "S." "F.")"
# compat.claim-contradicts-analysis sits one band below the compat.* code finding that refutes its
# claim: HIGH only beside a CRITICAL one, which arms rule 0 itself.
ladder "a CRITICAL compat break and the HIGH description finding it refutes" "hold for the next major COMMENT" 0 "$(pair compat.output-removed CRITICAL compat.claim-contradicts-analysis HIGH)"
ladder "a HIGH compat break and the MEDIUM description finding it refutes" "block REQUEST_CHANGES" 2 "$(pair compat.variable-removed HIGH compat.claim-contradicts-analysis MEDIUM)"
ladder "a CRITICAL non-compat finding" "block REQUEST_CHANGES" 1 "$(one structure.docs-contradict-code CRITICAL a.tf 1 "S." "F.")"
ladder "a HIGH finding and a failing check" "block REQUEST_CHANGES" 2 "$(one structure.docs-contradict-code HIGH a.tf 1 "S." "F.")" "" "$(checks fail fail)"
ladder "a failing check" "block REQUEST_CHANGES" 3 "$NONE" "" "$(checks fail fail)"
grep -qxF 'Failing host signal: checks. A failing host signal blocks merge (ladder rule 3).' "$O/comment.md"; check "ladder: rule 3 names the signal" $?
ladder "a conflict with a queued check" "block REQUEST_CHANGES" 3 "$NONE" "$(host conflict '.signals.mergeability = "fail"')" "$(checks unknown unknown)"
grep -qxF 'Failing host signal: mergeability. A failing host signal blocks merge (ladder rule 3).' "$O/comment.md"; check "ladder: the conflict is named, not the queued check" $?
ladder "changes requested by a reviewer" "block REQUEST_CHANGES" 3 "$NONE" "$(host cr '.signals.review_decision = "fail"')"
ladder "a queued check" "inconclusive COMMENT" 4 "$NONE" "" "$(checks unknown unknown)"
ladder "thread resolution unread and no finding" "inconclusive COMMENT" 4 "$NONE" "$(host tu '.signals.threads = "unknown"')"
ladder "reviews unread" "inconclusive COMMENT" 4 "$NONE" "$(host ru '.signals.review_decision = "unknown"')"
ladder "mergeability null twice" "inconclusive COMMENT" 4 "$NONE" "$(host mu '.signals.mergeability = "unknown"')"
ladder "a review.check-not-run finding" "inconclusive COMMENT" 4 "$(one review.check-not-run MEDIUM . null "Check B did not run." "no code change: none.")"
ladder "a review.no-change-identified finding" "inconclusive COMMENT" 4 "$(one review.no-change-identified MEDIUM . null "The workspace is stale." "no code change: none.")"
ladder "a patch unavailable" "inconclusive COMMENT" 4 "$NONE" "$(host pu '.could_not_run = [{kind: "patch-unavailable", path: "main.tf"}]')"
ladder "an example not verified" "inconclusive COMMENT" 4 "$NONE" "" "" "$(runf gap '.verify_gaps = [{dir: "examples/complete", reason: "not run: environment"}]')"
grep -qxF -- '- Verification of `examples/complete`: not run: environment.' "$O/comment.md"; check "ladder: the unverified example is listed in section 5" $?
# Plan coverage (verify-pass.md, Plan coverage): a non-inert change without complete coverage is
# an unknown, whatever the findings below rule 4; each unplanned example is listed after the
# verification gaps, and the What to do count takes them.
ladder "coverage none for want of a profile" "inconclusive COMMENT" 4 "$NONE" "" "" \
  "$(runf cov-none '.coverage = {class: "none", inert: false, unplanned: [{dir: "examples/a", reason: "no AWS profile named"}, {dir: "examples/b", reason: "no AWS profile named"}]}')"
t_cov_lines() {
  awk '/^### Checks that could not run$/ { on = 1; next } on' "$O/comment.md" > "$TMP/cov-s5.txt"
  printf '%s\n' '' '- 2 examples were not planned: no AWS profile named.' '  - `examples/a`' '  - `examples/b`' | cmp -s - "$TMP/cov-s5.txt" &&
    [ -z "$(todo)" ] && sed -n 3,5p "$O/comment.md" | cmp -s - <(printf '%s\n' '**Inconclusive.**' '' 'To get a conclusive review: name an AWS profile.') &&
    grep -qxF -- "$(jq -nr -L "$(dirname "$RCU")" 'include "render-comment"; texts["rationale-4-listed"]')" "$O/comment.md"
}
t_cov_lines; check "coverage: the unplanned examples are section 5, one clause per reason with the names under it, golden; the action line in place of What to do" $?
render "$NONE" "$(host covcnt '.signals.mergeability = "unknown"')" "" "$TMP/run-cov-none.json"
grep -qxF -- '- 2 checks could not run; see Checks that could not run.' "$O/comment.md" && ! grep -qF 'To get a conclusive review' "$O/comment.md"
check "coverage: beside another rule 4 item, What to do counts the unplanned examples and no action line renders" $?
ladder "partial coverage under a LOW finding" "inconclusive COMMENT" 4 "$(one structure.grouping LOW a.tf 1 "S." "F.")" "" "" \
  "$(runf cov-part '.verify_gaps = [{dir: "examples/c", reason: "init failed"}] | .coverage = {class: "partial", inert: false, unplanned: [{dir: "examples/d", reason: "plan gate G1"}]}')"
grep -A4 -xF '### Checks that could not run' "$O/comment.md" | tail -n 3 | cmp -s - <(printf '%s\n' '- Verification of `examples/c`: `init` failed.' '- 1 example was not planned: plan gate G1.' '  - `examples/d`')
check "coverage: the verification gaps come first, then the unplanned examples" $?
ladder "a module with no example directory" "inconclusive COMMENT" 4 "$NONE" "" "" \
  "$(runf cov-noex '.coverage = {class: "none", inert: false, unplanned: [{dir: "examples", reason: "no example directory"}]}')"
awk '/^### Checks that could not run$/ { on = 1; next } on' "$O/comment.md" |
  cmp -s - <(printf '%s\n' '' "$(jq -nr -L "$(dirname "$RCU")" 'include "render-comment"; texts["unplanned-no-examples"]')")
check "coverage: no example directory renders its own fixed line" $?
ladder "an inert change: unplanned examples are information, not unknowns" "approve APPROVE" 8 "$NONE" "" "" \
  "$(runf cov-inert '.coverage = {class: "none", inert: true, unplanned: [{dir: "examples/a", reason: "no AWS profile named"}]}')"
awk '/^### Checks that could not run$/ { on = 1; next } on' "$O/comment.md" |
  cmp -s - <(printf '%s\n' '' "$(jq -nr -L "$(dirname "$RCU")" 'include "render-comment"; texts["unplanned-inert"]')" '- 1 example was not planned: no AWS profile named.' '  - `examples/a`')
check "coverage: an inert change lists its unplanned examples under the inert line" $?
! grep -qF 'checks could not run' "$O/comment.md" && ! grep -qF 'check could not run' "$O/comment.md"
check "coverage: an inert change counts no unplanned example as a gap" $?
ladder "a triage run with a LOW finding" "inconclusive COMMENT" 4 "$(one structure.grouping LOW a.tf 1 "S." "F.")" "" "" "$(runf triage '.triage = true')"
grep -qxF 'Triage only: the full review of this change has not run yet.' "$O/comment.md"; check "ladder: the triage line follows the verdict" $?
ladder "a triage run with a HIGH finding" "block REQUEST_CHANGES" 2 "$(one structure.docs-contradict-code HIGH a.tf 1 "S." "F.")" "" "" "$TMP/run-triage.json"
ladder "an unresolved thread" "changes suggested COMMENT" 5 "$(one structure.grouping LOW a.tf 1 "S." "F.")" "$(host ut '.unresolved_threads = [{path: "a.tf", line: 1}, {path: "b.tf", line: null}]')"
grep -qxF -- '- `a.tf:1`: this review has a finding at the same path and line.' "$O/comment.md" \
  && grep -qxF -- '- `b.tf`: this review has no finding at the same path and line.' "$O/comment.md"
check "ladder: existing threads matched by path and line" $?
ladder "a MEDIUM finding" "block REQUEST_CHANGES" 6 "$(one structure.grouping MEDIUM a.tf 1 "S." "F.")"
ladder "a LOW finding" "approve with nits COMMENT" 7 "$(one structure.grouping LOW a.tf 1 "S." "F.")"
ladder "nothing" "approve APPROVE" 8 "$NONE"
ladder "a LOW tool finding and a note disputing it" "approve with nits COMMENT" 7 "$(pair structure.grouping LOW review.tool-disputed LOW)"
ladder "a HIGH finding and a note disputing it" "block REQUEST_CHANGES" 2 "$(pair structure.docs-contradict-code HIGH review.tool-disputed LOW)"
ladder "a disputed note alone" "approve APPROVE" 8 "$(one review.tool-disputed LOW a.tf 1 "S." "F.")"
grep -qxF '**Disputed tool findings**' "$O/comment.md" && ! grep -q '^\*\*LOW\*\*' "$O/comment.md"
check "ladder: the disputed note renders under its own label" $?
ladder "a draft with a MEDIUM finding" "block COMMENT" 6 "$(one structure.grouping MEDIUM a.tf 1 "S." "F.")" "$(host draft '.state.draft = true')"
ladder "a closed pull request with nothing" "approve COMMENT" 8 "$NONE" "$(host closed '.state.state = "closed"')"
ladder "a merged pull request with nothing" "approve COMMENT" 8 "$NONE" "$(host merged '.state.state = "closed" | .state.merged = true')"
CR="$(checks rejected pass)"; touch "$CR/extra"
ladder "a rejected checks file" "inconclusive COMMENT" 4 "$NONE" "" "$CR"
grep -qxF "Checks: the host's check runs file was rejected." "$O/comment.md"; check "ladder: the rejected checks file is said" $?

# --- Collapsing: the check-not-run rule, and the disputed note outside the count.

n=0
{ f structure.grouping MEDIUM a.tf 1 "M." "F."
  f review.check-not-run LOW . null "Check B did not run." "no code change: none."
  for i in 1 2 3 4 5 6 7 8 9; do f structure.argument-order LOW "f$i.tf" 1 "L$i." "F."; done
} | list fold4 > /dev/null
render "$TMP/fold4.json"
check "collapse: under rule 4 the check-not-run group stays in full" "$([ "$(rule)" = 4 ] && grep -qF -- '- `review.check-not-run` - `.` - Check B did not run.' "$O/comment.md" && grep -qF '<details><summary><code>structure.argument-order</code> (9)</summary>' "$O/comment.md"; echo $?)"
jq '. + [{id: "F-900", rule_id: "structure.docs-contradict-code", severity: "HIGH", file: "h.tf", line: 1, summary: "H.", suggested_fix: "F.", source: "llm"}]' "$TMP/fold4.json" > "$TMP/fold2.json"
render "$TMP/fold2.json"
check "collapse: under rule 2 the check-not-run group folds" "$([ "$(rule)" = 2 ] && grep -qF '<details><summary><code>review.check-not-run</code> (1)</summary>' "$O/comment.md"; echo $?)"
n=0
{ for i in 1 2 3 4 5 6 7 8 9 10; do f structure.argument-order LOW "f$i.tf" 1 "L$i." "F."; done
  f review.tool-disputed LOW a.tf 1 "D." "F."; } | list ten > /dev/null
render "$TMP/ten.json"
check "collapse: a disputed note does not count toward the threshold" "$([ "$ST" = 0 ] && ! grep -q '<details><summary><code>' "$O/comment.md"; echo $?)"

# --- Sections 6 and 8 from host.json.

H68="$(host s68 '.related = {status: "ok", open_unlinked: ["#12"], sidebar_not_read: true}
  | .conversation = {path: "rest", omitted: null, considered: 2, bot_considered: 3,
                     counts: {"minimized-excluded": 3, "over-size": 1, "bot-over-size": 1}, notes: []}')"
C68="$(checks s68 pass '.own_check = "modulestf review" | .own_check_dropped = 1')"
R68="$(runf s68 '.counts["instruction-like-text-from-others"] = 1 | .counts["review.quoted-claim-unverifiable"] = 2')"
render "$NONE" "$H68" "$C68" "$R68"
cat > "$TMP/s68.md" <<'EOF'
### Pull request state

Open issue #12 is not set to close on merge. Add `Closes #12` to the description.

Sidebar links not read.

Checks: the host's own check `modulestf review` excluded.

### Conversation comments

Conversation comments considered: 2. Not considered: over-size:1, minimized-excluded:3. Notes: instruction-like-text-from-others:1.

Bot comments considered: 3. Not considered: bot-over-size:1.

Claims quoted from the discussion and not confirmed from the code: 2.
EOF
check "sections 6 and 8: the fixed lines" "$(awk '/^### Pull request state$/ { on = 1 } on' "$O/comment.md" | cmp -s - "$TMP/s68.md"; echo $?)"
# A judgment reply with no counts: the run file carries null, never 0, and no count line is rendered.
RNULL="$(runf nullcounts '.counts = null')"
t_null_counts() {
  render "$NONE" "$H68" "$C68" "$RNULL"
  [ "$ST" = 0 ] && awk '/^### Conversation comments$/ { on = 1 } on' "$O/comment.md" |
    cmp -s - <(printf '### Conversation comments\n\nConversation comments considered: 2. Not considered: over-size:1, minimized-excluded:3.\n\nBot comments considered: 3. Not considered: bot-over-size:1.\n\nCounts: not reported by the review run.\n')
}
t_null_counts; check "section 8: null counts render the one counts line and keep the rest" $?
# Null counts alone are enough for the section: one line, never a 0.
t_null_alone() {
  render "$NONE" "" "" "$RNULL"
  [ "$ST" = 0 ] && awk '/^### Conversation comments$/ { on = 1 } on' "$O/comment.md" |
    cmp -s - <(printf '### Conversation comments\n\nCounts: not reported by the review run.\n')
}
t_null_alone; check "section 8: null counts alone render the one counts line" $?
t_zero_counts() { render "$NONE"; [ "$ST" = 0 ] && ! grep -q 'Counts: not reported' "$O/comment.md"; }
t_zero_counts; check "section 8: zero counts render no counts line" $?
render "$NONE" "$(host omit '.conversation.omitted = "fetch-failed" | .conversation.considered = 4')"
grep -qxF 'Conversation and bot comments not considered: fetch-failed.' "$O/comment.md" \
  && ! grep -q 'considered: 4' "$O/comment.md"
check "section 8: a whole-class omission is one line" $?
render "$NONE" "$(host relfail '.related.status = "failed"')"
check "section 6: related issues that could not be read" "$([ "$ST" = 0 ] && awk '/^### Pull request state$/ { on = 1 } on' "$O/comment.md" | cmp -s - <(printf '### Pull request state\n\nRelated issues could not be read, so closing keywords were not checked.\n'); echo $?)"

# --- Prefix: Step 8 puts the module root back in front of every path.

n=0
t_prefix() {
render "$(one structure.grouping LOW main.tf 3 "S." "F.")" "$(host prefix '.prefix = "modules/x" | .unresolved_threads = [{path: "modules/x/main.tf", line: 3}]')"
grep -qF -- '- `structure.grouping` - `modules/x/main.tf:3` - S.' "$O/comment.md" \
  && grep -qxF -- '- `modules/x/main.tf:3`: this review has a finding at the same path and line.' "$O/comment.md" \
  && jq -e '.[0].file == "modules/x/main.tf"' "$O/findings.json" > /dev/null
}
t_prefix; check "prefix: paths in the body, a thread already repository-relative and findings.json" $?

# --- Collapse rule 3 with Fix lines: over 10 findings, MEDIUM the highest severity, so MEDIUM
# stays in full and LOW folds with its Fix lines inside the block.

t_fold_medium() {
  n=0
  { f structure.grouping MEDIUM a.tf 1 "M." "Fix M."
    for i in 1 2 3 4 5 6 7 8 9; do f structure.argument-order LOW "f$i.tf" 2 "Order." "Reorder."; done
    f structure.argument-order LOW g.tf null "Other." "Move."
  } | list foldm > /dev/null
  render "$TMP/foldm.json"
  cat > "$TMP/foldm.md" <<'EOF'
**MEDIUM**

- `structure.grouping` - `a.tf:1` - M.
  - Fix: Fix M.

**LOW**

<details><summary><code>structure.argument-order</code> (10)</summary>

- `f1.tf:2`, `f2.tf:2`, `f3.tf:2`, `f4.tf:2`, `f5.tf:2`, `f6.tf:2`, `f7.tf:2`, `f8.tf:2`, `f9.tf:2` - Order.
  - Fix: Reorder.
- `g.tf` - Other.
  - Fix: Move.

</details>
EOF
  [ "$(rule)" = 6 ] && awk '/^### Findings$/ { on = 1; getline; next } on' "$O/comment.md" | cmp -s - "$TMP/foldm.md"
}
t_fold_medium; check "collapse: MEDIUM highest stays in full, LOW folds with its Fix lines, byte for byte" $?
n=0
{ for i in 1 2 3 4 5 6 7 8 9 10 11; do f structure.argument-order LOW "f$i.tf" 1 "L$i." "F."; done; } | list allow > /dev/null
render "$TMP/allow.json"
check "collapse: over 10 findings all LOW stay in full" "$([ "$(rule)" = 7 ] && ! grep -q '<details><summary><code>' "$O/comment.md" && [ "$(grep -c '^- `structure.argument-order` (11):$' "$O/comment.md")" = 1 ]; echo $?)"

# --- Every fixed line of sections 5 and 6 at once, the whole body compared.

t_sections() {
  local h c r
  h="$(host s56 '.prefix = "modules/x" | .signals = {threads: "unknown", review_decision: "unknown", mergeability: "fail"}
    | .could_not_run = [{kind: "patch-unavailable", path: "main.tf"}, {kind: "thread-resolution-unknown"},
                        {kind: "prose-truncated"}, {kind: "threads-over-count", count: 3}]
    | .related = {status: "too-many", open_unlinked: [], sidebar_not_read: false}')"
  c="$(checks s56 unknown '.check_runs = [] | .own_jobs_dropped = 1 | .own_jobs_unreadable = true')"
  r="$(runf s56 '.verify_gaps = [{dir: "examples/complete", reason: "init failed"}]')"
  render "$NONE" "$h" "$c" "$r"
  cat > "$TMP/s56.md" <<'EOF'
The change looks right.

**Changes requested before merge.**

Failing host signal: mergeability. A failing host signal blocks merge (ladder rule 3).

### What to do

To make this mergeable, resolve each checklist item below and push.

- [ ] Resolve the merge conflict.

### Checks that could not run

- The patch of `modules/x/main.tf` was unavailable, so its changes could not be read.
- Review thread resolution: the thread query was unavailable, so review comments were grouped by reply instead. Whether the open threads are resolved is unknown.
- Quoted prose was truncated, so part of the discussion was not read.
- 3 review thread comments over the count did not reach the review.
- Verification of `examples/complete`: `init` failed.

### Pull request state

Checks: unknown. Not mergeable. Review decision: unknown. Thread resolution: unknown.

Related issues exceed 10, so closing keywords were not checked.

Checks: the jobs of the host's own workflow runs excluded.

Checks: the host's own jobs could not be read.
EOF
  cmp -s "$O/comment.md" "$TMP/s56.md"
}
t_sections; check "sections 5 and 6: every fixed line, the whole body byte for byte" $?

# --- The fixed strings: comment-format.md, Host Render Strings, equals the script's table.

t_table() {
  awk '/^## Host Render Strings$/ { on = 1; next } on && /^## / { exit } on && /^\| `/' "$CF" |
    jq -R -s 'split("\n") | map(select(length > 0)
      | capture("^\\| `(?<key>[^`]+)` \\| (?<value>.*) \\|$")) | from_entries' > "$TMP/doc-texts.json" &&
  jq -e -n -L "$(dirname "$RCU")" --slurpfile d "$TMP/doc-texts.json" \
    'include "render-comment"; ($d[0] | length) > 30 and $d[0] == texts' > /dev/null 2>&1
}
t_table; check "strings: the Host Render Strings table equals the script's strings" $?

# The reviewer writes short by default: the length targets, the COMPACT caps below, are stated
# word for word in the findings schema and in the caller instruction of the handover.
LT='Write short: a `summary` of at most 200 characters and a `suggested_fix` of at most 250, or at most 600 for a `needs decision:` fix, one clause per option. The hard caps stay 500 and 600. A finding over the short targets is valid; the COMPACT render refuses it, and the comment renders in STANDARD only with `--standard`.'
t_targets_stated() {
  awk '/^## Length Targets$/ { on = 1; next } on && /^## / { exit } on' \
    "$SRC/.agents/skills/terraform-module-reviewer/references/findings-schema.md" | grep -qF -- "$LT" &&
    awk '/^## Handover$/ { on = 1; next } on && /^## / { exit } on' "$REF/github-io.md" | grep -qF -- "$LT"
}
t_targets_stated; check "strings: the length targets are stated in the findings schema and the handover" $?
# A COMPACT refusal gives one piece of advice, the same in the script, SKILL.md Step 10, the
# handover and Tiers.
ADVICE='send it back to the reviewer once; if it keeps the finding because it is within the schema targets, render with --standard'
t_advice() {
  grep -qF -- "\$refuse; $ADVICE\"" "$RCU" &&
    grep -F -- '- **Step 10 - Render.**' "$SRC/.agents/skills/terraform-module-pr-review/SKILL.md" | grep -qF -- "\`$ADVICE\`" &&
    awk '/^## Handover$/ { on = 1; next } on && /^## / { exit } on' "$REF/github-io.md" | grep -qF -- "\`$ADVICE\`" &&
    awk '/^## Tiers$/ { on = 1; next } on && /^## / { exit } on' "$CF" | grep -qF -- "\`$ADVICE\`"
}
t_advice; check "strings: the COMPACT refusal advice is one sentence in the script, SKILL.md Step 10, the handover and Tiers" $?

# --- Leak scan: a match blocks every file and says what matched and where.

t_leak_path() {
  render "$(one structure.grouping LOW a.tf 1 "See /home/alice/src/x for details." "F.")"
  [ "$ST" = 1 ] && empty_out && printf '%s' "$MSG" | grep -qF 'leak scan: /home/ in finding F-'
}
t_leak_path; check "leak scan: an absolute path in a summary blocks the render" $?
render "$NONE" "" "" "" "$(printf 'Built in %s.\n' "$TMP/rundir/clone" > "$TMP/a-run.txt"; echo "$TMP/a-run.txt")"
check "leak scan: the run directory in the assessment" "$([ "$ST" = 1 ] && empty_out && printf '%s' "$MSG" | grep -qF 'the run directory in the assessment'; echo $?)"
render "$(one structure.grouping LOW a.tf 1 "Token ghp_abc in a comment." "F.")"
check "leak scan: a token shape" "$([ "$ST" = 1 ] && empty_out; echo $?)"
FAKE_SERVICE_TOKEN=s3cr3tvalue-0123456789
export FAKE_SERVICE_TOKEN
render "$(one structure.grouping LOW a.tf 1 "S." "Set it to s3cr3tvalue-0123456789.")"
check "leak scan: the value of a secret-named variable, by name only" "$([ "$ST" = 1 ] && empty_out && printf '%s' "$MSG" | grep -qF 'the value of FAKE_SERVICE_TOKEN' && ! printf '%s' "$MSG" | grep -qF 's3cr3tvalue'; echo $?)"
unset FAKE_SERVICE_TOKEN
AK="$(one structure.grouping LOW a.tf 1 "Key AKIAABCDEFGHIJKLMNOP seen." "F.")"
render "$AK"
check "leak scan: a credential shape passes when no plan pass ran" "$([ "$ST" = 0 ]; echo $?)"
render "$AK" "" "" "$(runf plan '.plan_ran = true')"
check "leak scan: a credential shape blocks after a plan pass" "$([ "$ST" = 1 ] && empty_out; echo $?)"
render "$(one structure.grouping LOW a.tf 1 "See /home/runner." "F.")" "$(host tmpref '.related = {status: "ok", open_unlinked: ["a/b#1"], sidebar_not_read: false}')"
check "leak scan: the source is the finding, not the host records" "$(printf '%s' "$MSG" | grep -qF 'in finding F-'; echo $?)"

# --- At-mentions: wrapped outside code spans, left alone inside them.

t_mention() {
  printf 'Thanks to @alice.\n' > "$TMP/a-at.txt"
  render "$(one structure.grouping LOW a.tf 1 'Ask @octo-org/team, not `@kept` or ``a @b``.' "F.")" "" "" "" "$TMP/a-at.txt"
  [ "$ST" = 0 ] && grep -qxF 'Thanks to `@alice`.' "$O/comment.md" \
    && grep -qF 'Ask `@octo-org/team`, not `@kept` or ``a @b``.' "$O/comment.md"
}
t_mention; check "at-mention: bare mentions wrapped, spans untouched" $?
render "$(one structure.grouping LOW a.tf 1 'An odd ` backtick and @x.' "F.")"
check "at-mention: a mention a wrap cannot neutralize blocks the render" "$([ "$ST" = 1 ] && empty_out; echo $?)"

# --- Refused inputs: exit 2 and nothing written.

refused() { # name, render args...
  local name="$1"; shift
  render "$@"
  check "refused: $name" "$([ "$ST" = 2 ] && empty_out; echo $?)"
}
GOOD="$(f structure.grouping LOW a.tf 1 "S." "F.")"
bad() { printf '%s\n' "$GOOD" | jq -c "$1" | jq -s . > "$TMP/bad-$2.json"; echo "$TMP/bad-$2.json"; }
printf 'not json' > "$TMP/notjson.json"; refused "findings that are not JSON" "$TMP/notjson.json"
printf '[]\n[]\n' > "$TMP/two.json"; refused "two JSON values" "$TMP/two.json"
printf '{}' > "$TMP/obj.json"; refused "findings that are not an array" "$TMP/obj.json"
refused "an unknown key" "$(bad '.extra = 1' key)"
refused "no source" "$(bad 'del(.source)' nosrc)"
refused "a source outside the list" "$(bad '.source = "model"' src)"
refused "a bad id" "$(bad '.id = "X-1"' id)"
refused "a bad severity" "$(bad '.severity = "INFO"' sev)"
refused "a bad rule_id" "$(bad '.rule_id = "style.x"' rule)"
refused "a review rule at CRITICAL" "$(bad '.rule_id = "review.check-not-run" | .severity = "CRITICAL" | .source = "host" | .subject = "compat.x@.:a"' revcrit)"
refused "a disputed note above LOW" "$(bad '.rule_id = "review.tool-disputed" | .severity = "MEDIUM"' disp)"
refused "an absolute path" "$(bad '.file = "/etc/passwd"' abs)"
refused "a .. segment" "$(bad '.file = "a/../../b.tf"' dotdot)"
refused "a backtick in a path" "$(bad '.file = "a`b.tf"' tick)"
refused "a line of 0" "$(bad '.line = 0' line)"
refused "a newline in a summary" "$(bad '.summary = "a\nb"' nl)"
refused "an empty fix" "$(bad '.suggested_fix = ""' fix)"
refused "a summary over 500 characters" "$(bad '.summary = ("a" * 501)' sumbig)"
refused "a fix over 600 characters" "$(bad '.suggested_fix = ("a" * 601)' fixbig)"
refused "a tool finding with no subject" "$(bad '.source = "tool"' toolsub)"
refused "a tool finding under a review rule" "$(bad '.source = "tool" | .subject = ".:a" | .rule_id = "review.check-not-run"' toolrev)"
refused "a candidate_id with no confirmed_by" "$(bad '.candidate_id = "C-001" | .subject = ".:a"' pair)"
refused "an llm finding confirmed by small" "$(bad '.candidate_id = "C-001" | .confirmed_by = "small" | .subject = ".:a"' llmsmall)"
refused "a host check-not-run with a plain subject" "$(bad '.source = "host" | .rule_id = "review.check-not-run" | .subject = ".:a"' hostsub)"
refused "a host fallback with no candidate_id" "$(bad '.source = "host" | .subject = ".:a"' hostcand)"
printf '%s\n%s\n' "$GOOD" "$GOOD" | jq -s . > "$TMP/dup.json"; refused "a duplicate id" "$TMP/dup.json"
G="$(printf '%s\n' "$GOOD" | list good)"
refused "host.json for another head" "$G" "$(host other '.head_sha = "89abcdef0123456789abcdef0123456789abcdef"')"
refused "host.json with an extra key" "$G" "$(host extra '.extra = 1')"
refused "a coverage class that does not match its list" "$G" "" "" "$(runf cov-bad1 '.coverage = {class: "complete", inert: false, unplanned: [{dir: "examples/a", reason: "budget"}]}')"
refused "an unplanned reason outside the list" "$G" "" "" "$(runf cov-bad2 '.coverage = {class: "none", inert: false, unplanned: [{dir: "examples/a", reason: "flaky"}]}')"
refused "a run file without coverage" "$G" "" "" "$(runf cov-bad3 'del(.coverage)')"
refused "a run file with an unknown reason" "$G" "" "" "$(runf badreason '.verify_gaps = [{dir: "examples/a", reason: "flaky"}]')"
refused "a run file with an extra key" "$G" "" "" "$(runf extra '.extra = true')"
refused "a run file with a negative count" "$G" "" "" "$(runf neg '.counts["conversation-claims-unread"] = -1')"
t_partial_counts() { render "$G" "" "" "$(runf partial 'del(.counts["conversation-claims-unread"])')"; [ "$ST" = 2 ] && empty_out; }
t_partial_counts; check "refused: a run file with a count missing" $?
refused "a run file with empty counts" "$G" "" "" "$(runf emptycounts '.counts = {}')"
printf 'Caf\303\251 change.\n' > "$TMP/a-utf8.txt"; refused "a non-ASCII assessment" "$G" "" "" "" "$TMP/a-utf8.txt"
printf '  \n' > "$TMP/a-blank.txt"; refused "a blank assessment" "$G" "" "" "" "$TMP/a-blank.txt"
head -c 5000 /dev/zero | tr '\0' a > "$TMP/a-big.txt"; refused "an assessment over the cap" "$G" "" "" "" "$TMP/a-big.txt"
assess() { printf "$2" > "$TMP/a-$1.txt"; echo "$TMP/a-$1.txt"; } # name, printf format
refused "an assessment line that is a heading" "$G" "" "" "" "$(assess head 'Fine.\n### Findings\n')"
refused "an assessment line that fakes the verdict line" "$G" "" "" "" "$(assess bold '**Good to merge.**\n')"
refused "an assessment line of HTML" "$G" "" "" "" "$(assess html 'Fine.\n<details>\n')"
refused "an assessment line that is a list item" "$G" "" "" "" "$(assess list 'Fine.\n- `structure.grouping` - `a.tf` - x\n')"
refused "an assessment line that underlines a setext heading" "$G" "" "" "" "$(assess setext 'Good to merge\n===\n')"
refused "an assessment line that is a quote" "$G" "" "" "" "$(assess quote 'Fine.\n> quoted\n')"
refused "an assessment line that is a table row" "$G" "" "" "" "$(assess table 'Fine.\n| a | b |\n')"
refused "an assessment of three paragraphs" "$G" "" "" "" "$(assess three 'One.\n\nTwo.\n\nThree.\n')"
{ head -c 701 /dev/zero | tr '\0' a; echo; } > "$TMP/a-long.txt"; refused "an assessment over 700 characters" "$G" "" "" "" "$TMP/a-long.txt"
{ head -c 400 /dev/zero | tr '\0' a; printf '\n\n'; head -c 301 /dev/zero | tr '\0' b; echo; } > "$TMP/a-long2.txt"; refused "an assessment of two paragraphs over 700 characters in all" "$G" "" "" "" "$TMP/a-long2.txt"
{ head -c 400 /dev/zero | tr '\0' a; printf '\n\n'; head -c 300 /dev/zero | tr '\0' b; echo; } > "$TMP/a-edge.txt"; render "$G" "" "" "" "$TMP/a-edge.txt"
check "assessment: 700 characters in two paragraphs are accepted" "$([ "$ST" = 0 ]; echo $?)"
render "$G" "" "" "" "$(assess two 'First paragraph.\nSame paragraph.\n\nSecond paragraph.\n')"
check "assessment: two paragraphs are accepted" "$([ "$ST" = 0 ]; echo $?)"
ln -s "$G" "$TMP/link.json"; refused "a findings symbolic link" "$TMP/link.json"
mkdir -p "$TMP/held"; touch "$TMP/held/result.json.tmp"
MSG="$(bash "$RCU" --head "$HEAD" --findings "$G" --host "$HOST" --checks "$CHK" --run "$RUNF" --assessment "$ASSESS" --run-dir "$TMP/rundir" --out "$TMP/held" 2>&1)"
check "refused: an output directory that holds a file already" "$([ $? = 2 ] && [ "$(ls -A "$TMP/held")" = result.json.tmp ]; echo $?)"
mkdir -p "$TMP/rundir/out"
MSG="$(bash "$RCU" --head "$HEAD" --findings "$G" --host "$HOST" --checks "$CHK" --run "$RUNF" --assessment "$ASSESS" --run-dir "$TMP/rundir" --out "$TMP/rundir/out" 2>&1)"
check "refused: an output directory in the run directory" "$([ $? = 2 ] && [ -z "$(ls -A "$TMP/rundir/out")" ]; echo $?)"
MSG="$(bash "$RCU" --head "$HEAD" --findings "$G" --host "$HOST" --checks "$CHK" --run "$RUNF" --assessment "$ASSESS" --run-dir "$TMP/rundir" --out "$TMP/missing" 2>&1)"
check "refused: a missing output directory" "$([ $? = 2 ] && [ ! -e "$TMP/missing" ]; echo $?)"
refused "an unknown argument" "$G" "" "" "" "" --extra
MSG="$(bash "$RCU" --head abc --findings "$G" 2>&1)"; check "refused: a head that is not a SHA" "$([ $? = 2 ]; echo $?)"

RUN150C="$(runf manycov '.coverage = {class: "none", inert: false, unplanned: [range(150) | {dir: "examples/e\(.)", reason: "budget"}]}')"
render "$G" "" "" "$RUN150C"
[ "$ST" = 0 ] && grep -qxF -- '- 150 examples were not planned: budget.' "$O/comment.md" && [ "$(grep -c -e '^  - `examples/e[0-9]*`$' "$O/comment.md")" = 100 ] &&
  grep -qxF -- '- 50 more examples that were not planned are not listed.' "$O/comment.md"
check "coverage: more than 100 unplanned examples render the first 100 and a count of the rest" $?

# --- More than 100 verification gaps: all count for the verdict, section 5 lists the first 100
# and one line with the count of the rest.
RUN150="$(runf many '.verify_gaps = [range(150) | {dir: "examples/e\(.)", reason: "init failed"}]')"
t_many_gaps() {
  render "$G" "" "" "$RUN150"
  [ "$ST" = 0 ] && [ "$(rule)" = 4 ] && [ "$(grep -c -e '^- Verification of `examples/e[0-9]*`: `init` failed\.$' "$O/comment.md")" = 100 ] &&
    grep -qxF -- '- Verification of `examples/e99`: `init` failed.' "$O/comment.md" && ! grep -qF 'examples/e100`' "$O/comment.md" &&
    grep -qxF -- '- 50 more example directories with a check that could not run are not listed.' "$O/comment.md"
}
t_many_gaps; check "more than 100 verification gaps render the first 100 and a count of the rest" "$?"

# --- What to do (comment-format.md, What to Do) and the Fix block of grouping rule 7.

# todo_is name, expected lines...: the What to do section of the last render, byte for byte.
todo_is() { local name="$1"; shift; check "what to do: $name" "$([ "$ST" = 0 ] && todo | cmp -s - <(printf '%s\n' "$@"); echo $?)"; }
LEAD_BLOCK='To make this mergeable, resolve each checklist item below and push.'
LEAD_4='This review is incomplete, so a later run may add items. The items below are known.'
LEAD_7='Nothing blocks merge. The items below are optional.'
LEAD_0='This change is breaking. Merge it in the next major release. To merge it sooner, restore compatibility with the fixes named below. Any checklist items below also block merge.'
GEN='Documentation tables are generated. After the edits above, run `pre-commit run -a` and commit the result. Do not edit them by hand.'

# Pull request 88 of terraform-aws-modules/terraform-aws-cloudwatch: six MEDIUM findings of one
# rule, rule 6, a Fix block, and five fixes that name generated content. The assessment is pinned.
pr88() { # example directory, old floor, "three times " or "", what goes stale
  f structure.version-floor-understated MEDIUM "examples/$1/versions.tf" 7 \
    "This example declares hashicorp/aws >= $2 while the modules/log-group it calls $3now declares >= 6.25, so the example states a lower floor than its callee; the two sets still intersect, so it initializes." \
    "In the terraform block of examples/$1/versions.tf, set required_providers.aws version to \">= 6.25\", the floor modules/log-group declares, per code-conventions.md \"A caller does not declare less than what it calls\". Generated content made stale: $4"
}
t_pr88() {
  { pr88 complete-log-metric-filter-and-alarm 5.81 "" "the terraform-docs region of examples/complete-log-metric-filter-and-alarm/README.md."
    pr88 log-account-policy 5.81 "three times " "the terraform-docs region of examples/log-account-policy/README.md."
    pr88 log-anomaly-detector 5.81 "" "the terraform-docs region of examples/log-anomaly-detector/README.md."
    pr88 log-group-with-data-protection-policy 5.0 "three times " "the terraform-docs region of examples/log-group-with-data-protection-policy/README.md."
    pr88 log-subscription-filter 5.81 "" "none, the directory has no README.md."
    pr88 query-definition 5.81 "" "the terraform-docs region of examples/query-definition/README.md."
  } | list pr88 > /dev/null
  printf '%s\n' 'The change adds `deletion_protection_enabled` to `modules/log-group` and `wrappers/log-group`, and the pass-through, the wrapper line and the generated docs match the code. The `>= 6.25` floor is declared as breaking and names the new floor. What is missing is the same floor in the six examples that call `modules/log-group`. `terraform validate` passed in `examples/log-group-with-log-stream` with the providers this change declares, and a `plan` of that example planned: 7 to add, 0 to change, 0 to destroy.' > "$TMP/assess-88.txt"
  render "$TMP/pr88.json" "" "" "" "$TMP/assess-88.txt"
  cat > "$TMP/pr88.md" <<'EOF'
The change adds `deletion_protection_enabled` to `modules/log-group` and `wrappers/log-group`, and the pass-through, the wrapper line and the generated docs match the code. The `>= 6.25` floor is declared as breaking and names the new floor. What is missing is the same floor in the six examples that call `modules/log-group`. `terraform validate` passed in `examples/log-group-with-log-stream` with the providers this change declares, and a `plan` of that example planned: 7 to add, 0 to change, 0 to destroy.

**Changes requested before merge.**

Six MEDIUM findings are open. Any MEDIUM finding blocks merge (ladder rule 6).

### What to do

To make this mergeable, resolve each checklist item below and push.

- [ ] `structure.version-floor-understated` (6): apply the Fix at `examples/complete-log-metric-filter-and-alarm/versions.tf:7`, `examples/log-account-policy/versions.tf:7`, `examples/log-anomaly-detector/versions.tf:7`, `examples/log-group-with-data-protection-policy/versions.tf:7`, `examples/log-subscription-filter/versions.tf:7`, `examples/query-definition/versions.tf:7`.
- [ ] Documentation tables are generated. After the edits above, run `pre-commit run -a` and commit the result. Do not edit them by hand.

### Findings

**MEDIUM**

- `structure.version-floor-understated` (6):
  - `examples/complete-log-metric-filter-and-alarm/versions.tf:7` - This example declares hashicorp/aws >= 5.81 while the modules/log-group it calls now declares >= 6.25, so the example states a lower floor than its callee; the two sets still intersect, so it initializes.
  - `examples/log-account-policy/versions.tf:7` - This example declares hashicorp/aws >= 5.81 while the modules/log-group it calls three times now declares >= 6.25, so the example states a lower floor than its callee; the two sets still intersect, so it initializes.
  - `examples/log-anomaly-detector/versions.tf:7` - This example declares hashicorp/aws >= 5.81 while the modules/log-group it calls now declares >= 6.25, so the example states a lower floor than its callee; the two sets still intersect, so it initializes.
  - `examples/log-group-with-data-protection-policy/versions.tf:7` - This example declares hashicorp/aws >= 5.0 while the modules/log-group it calls three times now declares >= 6.25, so the example states a lower floor than its callee; the two sets still intersect, so it initializes.
  - `examples/log-subscription-filter/versions.tf:7` - This example declares hashicorp/aws >= 5.81 while the modules/log-group it calls now declares >= 6.25, so the example states a lower floor than its callee; the two sets still intersect, so it initializes.
  - `examples/query-definition/versions.tf:7` - This example declares hashicorp/aws >= 5.81 while the modules/log-group it calls now declares >= 6.25, so the example states a lower floor than its callee; the two sets still intersect, so it initializes.

<details><summary>Fix for each location (6)</summary>

- `examples/complete-log-metric-filter-and-alarm/versions.tf:7` - Fix: In the terraform block of examples/complete-log-metric-filter-and-alarm/versions.tf, set required_providers.aws version to ">= 6.25", the floor modules/log-group declares, per code-conventions.md "A caller does not declare less than what it calls". Generated content made stale: the terraform-docs region of examples/complete-log-metric-filter-and-alarm/README.md.
- `examples/log-account-policy/versions.tf:7` - Fix: In the terraform block of examples/log-account-policy/versions.tf, set required_providers.aws version to ">= 6.25", the floor modules/log-group declares, per code-conventions.md "A caller does not declare less than what it calls". Generated content made stale: the terraform-docs region of examples/log-account-policy/README.md.
- `examples/log-anomaly-detector/versions.tf:7` - Fix: In the terraform block of examples/log-anomaly-detector/versions.tf, set required_providers.aws version to ">= 6.25", the floor modules/log-group declares, per code-conventions.md "A caller does not declare less than what it calls". Generated content made stale: the terraform-docs region of examples/log-anomaly-detector/README.md.
- `examples/log-group-with-data-protection-policy/versions.tf:7` - Fix: In the terraform block of examples/log-group-with-data-protection-policy/versions.tf, set required_providers.aws version to ">= 6.25", the floor modules/log-group declares, per code-conventions.md "A caller does not declare less than what it calls". Generated content made stale: the terraform-docs region of examples/log-group-with-data-protection-policy/README.md.
- `examples/log-subscription-filter/versions.tf:7` - Fix: In the terraform block of examples/log-subscription-filter/versions.tf, set required_providers.aws version to ">= 6.25", the floor modules/log-group declares, per code-conventions.md "A caller does not declare less than what it calls". Generated content made stale: none, the directory has no README.md.
- `examples/query-definition/versions.tf:7` - Fix: In the terraform block of examples/query-definition/versions.tf, set required_providers.aws version to ">= 6.25", the floor modules/log-group declares, per code-conventions.md "A caller does not declare less than what it calls". Generated content made stale: the terraform-docs region of examples/query-definition/README.md.

</details>
EOF
  [ "$ST" = 0 ] && [ "$(rule)" = 6 ] && cmp -s "$O/comment.md" "$TMP/pr88.md"
}
t_pr88; check "what to do: pull request 88, the whole body byte for byte" $?

HI="$(f structure.docs-contradict-code HIGH a.tf 1 "S." "F." | list wt-hi)"
render "$HI" "" "$(checks wt-fail fail)"
todo_is "rule 2 and a failing check" '### What to do' '' "$LEAD_BLOCK" '' '- [ ] Fix the failing checks.' \
  '- [ ] `structure.docs-contradict-code`: apply the Fix at `a.tf:1`.'
render "$HI" "$(host wt-conflict '.signals.mergeability = "fail" | .unresolved_threads = [{path: "a.tf", line: 1}, {path: "b.tf", line: null}]')"
todo_is "rule 2, a merge conflict and two open threads" '### What to do' '' "$LEAD_BLOCK" '' '- [ ] Resolve the merge conflict.' \
  '- [ ] Resolve the 2 open review threads.' '- [ ] `structure.docs-contradict-code`: apply the Fix at `a.tf:1`.'
render "$NONE" "$(host wt-r3 '.signals.mergeability = "fail" | .signals.review_decision = "fail"')" "$(checks wt-r3 fail)"
todo_is "rule 3 alone, every failing signal in order" '### What to do' '' "$LEAD_BLOCK" '' '- [ ] Fix the failing checks.' \
  '- [ ] Resolve the merge conflict.' '- [ ] Address the requested changes.'
t_r4() {
  { f review.check-not-run MEDIUM . null "Check B did not run." "no code change: none."
    f structure.grouping LOW a.tf 1 "S." "F. Generated content made stale: the terraform-docs region of README.md."
  } | list wt-r4 > /dev/null
  render "$TMP/wt-r4.json" "$(host wt-r4 '.signals = {threads: "unknown", review_decision: "unknown", mergeability: "unknown"}
      | .could_not_run = [{kind: "prose-truncated"}]')" "$(checks wt-r4 unknown)" \
    "$(runf wt-r4 '.triage = true | .verify_gaps = [{dir: "examples/a", reason: "init failed"}]')"
  [ "$(rule)" = 4 ]
}
t_r4; check "what to do: rule 4 setup" $?
# The review.* finding is no item of its own: the gaps line counts it, with the could_not_run
# entry and the example that did not verify.
todo_is "rule 4 with every unknown, triage and a check-not-run finding" '### What to do' '' "$LEAD_4" '' \
  '- Optional: `structure.grouping` at `a.tf:1`.' "- $GEN" \
  '- This was a triage run. The full review has not run.' '- Check results could not be read or are still running.' \
  '- Review thread resolution could not be read.' '- The reviews could not be read.' '- Mergeability could not be read.' \
  '- 3 checks could not run; see Checks that could not run.'
render "$(f review.check-not-run LOW . null "Check B did not run." "no code change: none." | list wt-r4c)" "" "$(checks wt-r4c unknown)"
todo_is "rule 4 with a LOW review finding, counted once and no Optional item" '### What to do' '' "$LEAD_4" '' \
  '- Check results could not be read or are still running.' '- 1 check could not run; see Checks that could not run.'
# Quiet items alone, Optional ones and the gaps line, give way to the action line; a cause
# outside the cause table, here a review.* finding, has no action clause, so no line renders.
t_quiet_other() {
  render "$({ f review.check-not-run LOW . null "Check B did not run." "no code change: none."; f structure.grouping LOW a.tf 1 "S." "F."; } | list wt-r4q)" "" "" \
    "$(runf wt-r4q '.coverage = {class: "none", inert: false, unplanned: [{dir: "examples/a", reason: "no AWS profile named"}]}')"
  [ "$(rule)" = 4 ] && [ -z "$(todo)" ] && ! grep -qF 'To get a conclusive review' "$O/comment.md" && grep -qxF '### Findings' "$O/comment.md"
}
t_quiet_other; check "what to do: rule 4 with Optional items and the gaps line alone renders none, and a cause outside the table no action line" $?
t_quiet_action() {
  render "$(f structure.grouping LOW a.tf 1 "S." "F." | list wt-r4qa)" "" "" \
    "$(runf wt-r4qa '.coverage = {class: "none", inert: false, unplanned: [{dir: "examples/a", reason: "no AWS profile named"}]}')"
  [ "$(rule)" = 4 ] && [ -z "$(todo)" ] && grep -qxF -- '- `structure.grouping` - `a.tf:1` - S.' "$O/comment.md" &&
    sed -n 3,7p "$O/comment.md" | cmp -s - <(printf '%s\n' '**Inconclusive.**' '' 'To get a conclusive review: name an AWS profile.' '' \
      'A check this review needs could not run, as listed below. Any unknown makes the review inconclusive (ladder rule 4).')
}
t_quiet_action; check "what to do: rule 4 with quiet items and table causes alone: the action line right under the verdict" $?
t_r4_threads() { render "$NONE" "$H2"; [ "$(rule)" = 4 ]; }
t_r4_threads
todo_is "rule 4, thread resolution unknown is not also counted as a gap" '### What to do' '' "$LEAD_4" '' \
  '- Review thread resolution could not be read.'
render "$({ f review.path-missing MEDIUM a.tf null "P." "no code change: none."; f structure.grouping MEDIUM b.tf 2 "S." "F."; } | list wt-rev6)"
todo_is "a blocking review group is no item" '### What to do' '' "$LEAD_BLOCK" '' '- [ ] `structure.grouping`: apply the Fix at `b.tf:2`.'
# A review.* finding alone at a blocking severity leaves no item: the lead stands alone. The
# ladder invariant does not hold here; comment-format.md, What to Do, names the exception.
render "$(f review.untrusted-instruction HIGH . null "U." "no code change: none." | list wt-rev2)"
todo_is "a HIGH review finding alone leaves the lead with no item" '### What to do' '' "$LEAD_BLOCK"
render "$(f structure.grouping LOW a.tf 1 "S." "F. Generated content made stale: README.md." | list wt-r4b)" "" "" "$(runf wt-r4b '.triage = true')"
todo_is "rule 4 with no checkbox above it leaves item e a bullet" '### What to do' '' "$LEAD_4" '' \
  '- Optional: `structure.grouping` at `a.tf:1`.' "- $GEN" '- This was a triage run. The full review has not run.'
render "$(f structure.grouping MEDIUM a.tf 1 "S." "F." | list wt-r5)" "$(host wt-r5 '.unresolved_threads = [{path: "z.tf", line: 2}]')"
todo_is "rule 5 with one thread and a MEDIUM finding" '### What to do' '' "$LEAD_BLOCK" '' '- [ ] Resolve the open review thread.' \
  '- [ ] `structure.grouping`: apply the Fix at `a.tf:1`.'
render "$({ f structure.grouping LOW a.tf 1 "S." "F."; f structure.argument-order LOW b.tf null "T." "G."
  f structure.argument-order LOW c.tf 3 "U." "H."; } | list wt-r7)"
todo_is "rule 7, LOW only, a null line and one and two findings" '### What to do' '' "$LEAD_7" '' \
  '- Optional: `structure.grouping` at `a.tf:1`.' '- Optional: `structure.argument-order` (2) at `b.tf`, `c.tf:3`.'
R0="$({ f compat.output-removed CRITICAL a.tf 1 "S." "F. Generated content made stale: the terraform-docs region of README.md."
  f compat.output-removed CRITICAL b.tf 2 "T." "G."; f compat.variable-removed HIGH c.tf null "U." "H."
  f structure.grouping LOW d.tf 4 "V." "I."; } | list wt-r0)"
render "$R0"
todo_is "rule 0, the groups as plain bullets and item e a bullet" '### What to do' '' "$LEAD_0" '' \
  '- `compat.output-removed` (2): the Fixes at `a.tf:1`, `b.tf:2` are one way to restore compatibility; see Findings.' \
  '- `compat.variable-removed`: the Fix at `c.tf` is one way to restore compatibility; see Findings.' '- Optional: `structure.grouping` at `d.tf:4`.' "- $GEN"
render "$R0" "" "$(checks wt-r0 fail)"
todo_is "rule 0 with a failing check, which makes item e a checkbox" '### What to do' '' "$LEAD_0" '' '- [ ] Fix the failing checks.' \
  '- `compat.output-removed` (2): the Fixes at `a.tf:1`, `b.tf:2` are one way to restore compatibility; see Findings.' \
  '- `compat.variable-removed`: the Fix at `c.tf` is one way to restore compatibility; see Findings.' '- Optional: `structure.grouping` at `d.tf:4`.' "- [ ] $GEN"
R0M="$(jq '. + [{id: "F-900", rule_id: "structure.flag-polarity", severity: "MEDIUM", file: "e.tf", line: 5, summary: "W.", suggested_fix: "J.", source: "llm"}]' "$TMP/wt-r0.json" > "$TMP/wt-r0m.json"; echo "$TMP/wt-r0m.json")"
render "$R0M"
todo_is "rule 0, a MEDIUM non-compat group is a checkbox and makes item e one" '### What to do' '' "$LEAD_0" '' \
  '- `compat.output-removed` (2): the Fixes at `a.tf:1`, `b.tf:2` are one way to restore compatibility; see Findings.' \
  '- `compat.variable-removed`: the Fix at `c.tf` is one way to restore compatibility; see Findings.' '- [ ] `structure.flag-polarity`: apply the Fix at `e.tf:5`.' \
  '- Optional: `structure.grouping` at `d.tf:4`.' "- [ ] $GEN"
render "$NONE"
check "what to do: rule 8 renders no section" "$([ "$(rule)" = 8 ] && ! grep -q 'What to do' "$O/comment.md"; echo $?)"
render "$(f review.tool-disputed LOW a.tf 1 "D." "F. Generated content made stale: README.md." | list wt-r8d)"
check "what to do: rule 8 with a disputed note renders no section" "$([ "$(rule)" = 8 ] && ! grep -q 'What to do' "$O/comment.md"; echo $?)"
render "$({ f structure.docs-contradict-code HIGH a.tf 1 "S." "F."; f structure.grouping MEDIUM b.tf 2 "T." "G."
  f structure.grouping MEDIUM c.tf 3 "U." "H."; f structure.argument-order LOW d.tf 4 "V." "I."; } | list wt-mixed)"
todo_is "mixed blocking and LOW groups under block" '### What to do' '' "$LEAD_BLOCK" '' \
  '- [ ] `structure.docs-contradict-code`: apply the Fix at `a.tf:1`.' '- [ ] `structure.grouping` (2): apply the Fix at `b.tf:2`, `c.tf:3`.' \
  '- Optional: `structure.argument-order` at `d.tf:4`.'
# A group whose every finding is at the module root, `.`, has no place to apply a Fix at: it
# takes the fixed todo-fix-root item. A group with a real location keeps its locations.
t_root_one() {
  render "$({ f scope.description-only MEDIUM . null "S." "F."; f structure.grouping MEDIUM b.tf 2 "T." "G."; } | list wt-root1)"
}
t_root_one
todo_is "a blocking finding at the module root takes the fixed item" '### What to do' '' "$LEAD_BLOCK" '' \
  '- [ ] Resolve `scope.description-only`: see its Fix under Findings.' '- [ ] `structure.grouping`: apply the Fix at `b.tf:2`.'
render "$({ f scope.description-only HIGH . null "S." "F."; f scope.description-only HIGH . null "T." "G."; } | list wt-root2)"
todo_is "two blocking findings at the module root take the fixed item with the count" '### What to do' '' "$LEAD_BLOCK" '' \
  '- [ ] Resolve `scope.description-only` (2): see its Fixes under Findings.'
render "$(f scope.description-only MEDIUM . null "S." "F." | list wt-root3)" "$(host wt-root3 '.prefix = "modules/x"')"
todo_is "a module root finding under a module root prefix takes the fixed item" '### What to do' '' "$LEAD_BLOCK" '' \
  '- [ ] Resolve `scope.description-only`: see its Fix under Findings.'
t_root_rule0() {
  render "$({ f compat.output-removed CRITICAL a.tf 1 "S." "F."; f compat.claim-contradicts-analysis HIGH . null "T." "no code change: G."; } | list wt-root0)"
}
t_root_rule0
todo_is "rule 0, a description finding at the module root takes the fixed item" '### What to do' '' "$LEAD_0" '' \
  '- `compat.output-removed`: the Fix at `a.tf:1` is one way to restore compatibility; see Findings.' '- [ ] Resolve `compat.claim-contradicts-analysis`: see its Fix under Findings.'
render "$({ f scope.description-only MEDIUM . null "S." "F."; f scope.description-only MEDIUM a.tf 1 "T." "G."; } | list wt-root4)"
todo_is "a group with a real location keeps its locations" '### What to do' '' "$LEAD_BLOCK" '' \
  '- [ ] `scope.description-only` (2): apply the Fix at `.`, `a.tf:1`.'

# Commit and repository targets: the host render takes a pull request only, so the rule that
# they carry no What to do section is held in comment-format.md, under each target's heading.
t_targets() {
  awk '/^## A Commit Target$/ { on = 1; next } on && /^## / { exit } on' "$CF" | grep -qF 'No What to do section renders, heading included: it is for a pull request only.' &&
    awk '/^## A Repository Target$/ { on = 1; next } on && /^## / { exit } on' "$CF" | grep -qF 'No What to do section renders either, as for a commit.'
}
t_targets; check "what to do: commit and repository targets render no section" $?

# Locations: eight are listed in full, past eight the count of the rest.
locs_case() { # count of findings -> renders one LOW group of that many locations
  local i; for i in $(seq 1 "$1"); do f structure.argument-order LOW "f$i.tf" 1 "S." "F."; done | list "wt-loc$1" > /dev/null
  render "$TMP/wt-loc$1.json"
}
L8='`f1.tf:1`, `f2.tf:1`, `f3.tf:1`, `f4.tf:1`, `f5.tf:1`, `f6.tf:1`, `f7.tf:1`, `f8.tf:1`'
locs_case 8; todo_is "eight locations, all listed" '### What to do' '' "$LEAD_7" '' "- Optional: \`structure.argument-order\` (8) at $L8."
locs_case 9; todo_is "nine locations, the ninth counted" '### What to do' '' "$LEAD_7" '' "- Optional: \`structure.argument-order\` (9) at $L8, and 1 more."
locs_case 10; todo_is "ten locations, two counted" '### What to do' '' "$LEAD_7" '' "- Optional: \`structure.argument-order\` (10) at $L8, and 2 more."

# Item e: which phrases add it.
stale_case() { # name, expected 0 (item) or 1 (none), fixes...
  local name="$1" want="$2" i=0 fx; shift 2
  for fx in "$@"; do i=$((i + 1)); f structure.grouping LOW "s$i.tf" 1 "S$i." "$fx"; done | list wt-stale > /dev/null
  render "$TMP/wt-stale.json"
  check "what to do: item e, $name" "$([ "$(rule)" = 7 ] && { todo | grep -qxF -- "- $GEN"; [ $? = "$want" ]; }; echo $?)"
}
stale_case "absent" 1 "Do it."
stale_case "none at the end" 1 "Do it. Generated content made stale: none"
stale_case "none." 1 "Do it. Generated content made stale: none."
stale_case "none, no README" 1 "Do it. Generated content made stale: none, no README.md."
stale_case "nonempty" 0 "Do it. Generated content made stale: nonempty."
stale_case "None" 0 "Do it. Generated content made stale: None."
stale_case "none of" 0 "Do it. Generated content made stale: none of the README.md regions."
stale_case "two findings, one with a qualifying marker" 0 "Do it. Generated content made stale: none." "Do it. Generated content made stale: the terraform-docs region of README.md."
stale_case "two findings, neither qualifying" 1 "Do it. Generated content made stale: none." "Do it."
render "$(f structure.grouping MEDIUM a.tf 1 "S." "F. Generated content made stale: README.md." | list wt-ebox)"
todo_is "item e as a checkbox under a blocking group" '### What to do' '' "$LEAD_BLOCK" '' '- [ ] `structure.grouping`: apply the Fix at `a.tf:1`.' "- [ ] $GEN"

# The Fix block: two entries keep their Fix lines nested, three move them under the group.
t_fold2() {
  render "$({ f structure.grouping MEDIUM a.tf 1 "A." "Fix A."; f structure.grouping MEDIUM b.tf null "B." "Fix B."; } | list wt-f2)"
  awk '/^### Findings$/ { on = 1; getline; next } on' "$O/comment.md" | cmp -s - <(printf '%s\n' '**MEDIUM**' '' \
    '- `structure.grouping` (2):' '  - `a.tf:1` - A.' '    - Fix: Fix A.' '  - `b.tf` - B.' '    - Fix: Fix B.')
}
t_fold2; check "fix block: a group of two entries keeps its Fix lines nested" $?
t_fold3() {
  render "$({ f structure.argument-order MEDIUM z.tf 9 "Z." "Fix Z."
    f structure.grouping MEDIUM a.tf 1 "A." "Fix A."; f structure.grouping MEDIUM b.tf null "B." "Fix B."
    f structure.grouping MEDIUM c.tf 3 "C." "Fix C."; f structure.grouping MEDIUM d.tf 4 "C." "Fix C."
    f structure.flag-polarity MEDIUM e.tf 5 "E." "Fix E."; } | list wt-f3)"
  cat > "$TMP/wt-f3.md" <<'EOF'
### What to do

To make this mergeable, resolve each checklist item below and push.

- [ ] `structure.argument-order`: apply the Fix at `z.tf:9`.
- [ ] `structure.grouping` (4): apply the Fix at `a.tf:1`, `b.tf`, `c.tf:3`, `d.tf:4`.
- [ ] `structure.flag-polarity`: apply the Fix at `e.tf:5`.

### Findings

**MEDIUM**

- `structure.argument-order` - `z.tf:9` - Z.
  - Fix: Fix Z.
- `structure.grouping` (4):
  - `a.tf:1` - A.
  - `b.tf` - B.
  - `c.tf:3`, `d.tf:4` - C.

<details><summary>Fix for each location (4)</summary>

- `a.tf:1` - Fix: Fix A.
- `b.tf` - Fix: Fix B.
- `c.tf:3`, `d.tf:4` - Fix: Fix C.

</details>

- `structure.flag-polarity` - `e.tf:5` - E.
  - Fix: Fix E.
EOF
  awk '/^### What to do$/ { on = 1 } on' "$O/comment.md" | cmp -s - "$TMP/wt-f3.md"
}
t_fold3; check "fix block: a group of three entries moves its Fix lines into one block, byte for byte" $?
unfolded() { # name, the third finding's file, summary, fix
  render "$({ f structure.grouping LOW a.tf 1 "A." "Fix A."; f structure.grouping LOW b.tf 2 "B." "Fix B."
    f structure.grouping LOW "$2" 3 "$3" "$4"; } | list wt-unf)"
  check "fix block: $1 renders unfolded" "$([ "$ST" = 0 ] && ! grep -q 'Fix for each location' "$O/comment.md" \
    && [ "$(grep -c '^    - Fix: ' "$O/comment.md")" = 3 ]; echo $?)"
}
unfolded "a fix holding </details>" c.tf "C." 'Close the </details> tag.'
unfolded "a summary holding <DETAILS" c.tf 'An open <DETAILS block.' "Fix C."
unfolded "a location holding </details" 'x/</details>.tf' "C." "Fix C."
t_newline() { # a newline cannot pass the input grammar, so the grouping is checked directly
  jq -n -L "$REF" --arg s "$(printf 'Two\nlines.')" 'include "render-comment";
    [{id: "F-001", rule_id: "structure.grouping", severity: "LOW", file: "a.tf", line: 1, summary: "A.", suggested_fix: "F."},
     {id: "F-002", rule_id: "structure.grouping", severity: "LOW", file: "b.tf", line: 1, summary: "B.", suggested_fix: "F."},
     {id: "F-003", rule_id: "structure.grouping", severity: "LOW", file: "c.tf", line: 1, summary: $s, suggested_fix: "F."}]
    | findings_md(7; 10; "") | (contains("Fix for each location") | not) and contains("    - Fix: F.")' > /dev/null
}
t_newline; check "fix block: a newline in a summary renders unfolded" $?

# The leak scan and the at-mention step reach the new section.
t_leak_todo() {
  render "$(f structure.grouping MEDIUM a.tf 1 "S." "F." | list wt-leak)" "$(host wt-leak '.prefix = "x/home/y"')"
  [ "$ST" = 1 ] && empty_out && printf '%s' "$MSG" | grep -qF 'leak scan: /home/ in the host records' &&
  jq -e -n -L "$REF" --slurpfile f "$TMP/wt-leak.json" --slurpfile h "$TMP/host-wt-leak.json" --slurpfile r "$RUNF" '
    include "render-comment";
    render({findings: $f[0], host: $h[0], run: $r[0], assessment: "A.",
            checks: {accepted: true, signal: "pass", own_check: null, own_check_dropped: 0, own_jobs_dropped: 0, own_jobs_unreadable: false}})
    | .parts[-1] | .src == "the host records" and (.text | contains("### What to do\n\n" + texts["todo-lead-block"]))' > /dev/null
}
t_leak_todo; check "what to do: the leak scan covers the section" $?
t_mention_todo() {
  render "$({ f structure.grouping MEDIUM a/@team.tf 1 "A." "Ask @alice."; f structure.grouping MEDIUM b.tf 2 "B." "Fix B."
    f structure.grouping MEDIUM c.tf 3 "C." "Fix C."; } | list wt-at)"
  [ "$ST" = 0 ] && todo | grep -qxF -- '- [ ] `structure.grouping` (3): apply the Fix at `a/@team.tf:1`, `b.tf:2`, `c.tf:3`.' &&
    grep -qxF -- '- `a/@team.tf:1` - Fix: Ask `@alice`.' "$O/comment.md"
}
t_mention_todo; check "what to do: at-mentions in the section and the Fix block" $?

# --- Negative self-check: each mutation of a temp copy must make its named case fail.

mutate() { # name, perl substitution, case function
  local d="$TMP/mut-$oc"; mkdir -p "$d"; cp "$REF/render-comment.sh" "$REF/render-comment.jq" "$REF/host-records.jq" "$REF/host-pass.sh" "$d/"
  perl -0pi -e "$2" "$d/render-comment.sh" "$d/render-comment.jq"
  if cmp -s "$d/render-comment.sh" "$REF/render-comment.sh" && cmp -s "$d/render-comment.jq" "$REF/render-comment.jq"; then
    check "self-check: $1 (the mutation changed nothing)" 1; return
  fi
  local keep="$RCU" before="$fails"; RCU="$d/render-comment.sh"
  "$3" > /dev/null 2>&1; local s=$?
  RCU="$keep"; fails="$before"
  check "self-check: $1 is caught" "$([ "$s" != 0 ]; echo $?)"
}
t_rule2() { render "$(one structure.docs-contradict-code HIGH a.tf 1 "S." "F.")"; [ "$(rule)" = 2 ]; }
t_cov_rule() { render "$NONE" "" "" "$TMP/run-cov-none.json"; [ "$(rule)" = 4 ] && grep -qxF -- '  - `examples/a`' "$O/comment.md"; }
mutate "unplanned examples left out of the ladder" 's/ or \.unplanned > 0//' t_cov_rule
mutate "unplanned example names left out of section 5" 's/\| tx\("unplanned-name"; \{dir\}\)\]/| empty]/' t_cov_rule
t_rule0() { render "$(pair compat.output-removed CRITICAL structure.docs-contradict-code HIGH)"; [ "$(rule)" = 1 ]; }
t_rule4() { render "$NONE" "$(host tu2 '.signals.threads = "unknown"')"; [ "$(rule)" = 4 ]; }
t_draft() { render "$(one structure.grouping MEDIUM a.tf 1 "S." "F.")" "$TMP/host-draft.json"; [ "$(verdict)" = "block COMMENT" ]; }
t_dup() { render "$TMP/dup.json"; [ "$ST" = 2 ] && empty_out; }
t_worked() { render "$WF" "$H2" "" "" "$TMP/assess-worked.txt"; cmp -s "$O/comment.md" <(fence 7); }
t_assess_head() { render "$G" "" "" "" "$TMP/a-head.txt"; [ "$ST" = 2 ] && empty_out; }
t_assess_setext() { render "$G" "" "" "" "$TMP/a-setext.txt"; [ "$ST" = 2 ] && empty_out; }
t_assess_three() { render "$G" "" "" "" "$TMP/a-three.txt"; [ "$ST" = 2 ] && empty_out; }
t_collapsed() { render "$TMP/pr410.json" "$H410" "" "" "$TMP/assess-410.txt"; run1 < "$O/comment.md" | cmp -s - <(fence 5); }
mutate "the leak scan ignored" 's/\[ -z "\$leak" \] \|\|/true ||/' t_leak_path
mutate "no at-mention wrap" 's/\| \.body \|= wrap_mentions//' t_mention
mutate "HIGH not read by the ladder" 's/elif has_sev\("HIGH"\)/elif false/' t_rule2
mutate "rule 0 armed by any CRITICAL compat finding" 's/and all\(\$f\[\] \| select\(\.severity == "CRITICAL" or \.severity == "HIGH"\); \.rule_id \| startswith\("compat\."\)\)//' t_rule0
mutate "unknown signals not read at rule 4" 's/or any\(\$g\[\]; \. == "unknown"\)//' t_rule4
mutate "the draft clamp dropped" 's/\$state\.draft or //' t_draft
mutate "duplicate ids accepted" 's/and \(map\(\.id\) \| length == \(unique \| length\)\)//' t_dup
mutate "the section 5 line reworded" 's/so review comments were grouped by reply instead/so review comments were grouped/' t_worked
mutate "collapsing never applies" 's/\(\(\$f \| length\) > \$limit\)/false/' t_collapsed
mutate "the Fix line dropped from a collapsed block" 's/ - \\\(\.\[0\]\.summary\)\\n  - Fix: \\\(\.\[0\]\.suggested_fix\)"\]/ - \\(.[0].summary)"]/' t_fold_medium
mutate "the highest severity collapsed too" 's/elif \$s == \$top then "full"/elif false then "full"/' t_fold_medium
mutate "the prefix added to a thread path" 's/\(\.file \| repo_path\(\$p\)\) == \$t\.path/(.file | repo_path(\$p)) == (\$t.path | repo_path(\$p))/' t_prefix
mutate "a section 5 string changed in the script only" 's/so part of the discussion was not read/so part of the discussion was skipped/' t_table
mutate "the threads-over-count line reworded" 's/review thread comments over the count did not reach/thread comments over the count did not reach/' t_sections
mutate "assessment headings accepted" 's/\(#\|/(<|/' t_assess_head
mutate "setext underlines accepted" 's/\|=\+\\\\s\*\$//' t_assess_setext
mutate "assessment paragraphs uncapped" 's/\(\$ps \| length\) <= 2/true/' t_assess_three
mutate "the null counts line dropped" 's/\+ \(if \$n == null then \["Counts: not reported by the review run\."\] else \[\] end\)//' t_null_alone
mutate "the counts line on zero counts too" 's/if \$n == null then \["Counts: not reported/if true then ["Counts: not reported/' t_zero_counts
mutate "null counts refused" 's/\.counts == null or //' t_null_counts
mutate "the 100 verification gap cap restored" 's/\(\.verify_gaps \| type == "array" and all/(.verify_gaps | type == "array" and length <= 100 and all/' t_many_gaps
mutate "every verification gap listed" 's/\$run\.verify_gaps\[:100\]\[\]/\$run.verify_gaps[]/' t_many_gaps
mutate "any counts accepted" 's/\(\.counts == null or \(/(true or (/' t_partial_counts
t_none_fires() { render "$(f structure.grouping LOW a.tf 1 "S." "Do it. Generated content made stale: None." | list wt-nf)"; todo | grep -qxF -- "- $GEN"; }
t_rule8_none() { render "$NONE"; [ "$ST" = 0 ] && ! grep -q 'What to do' "$O/comment.md"; }
t_loc9() { locs_case 9; todo | grep -qxF -- "- Optional: \`structure.argument-order\` (9) at $L8, and 1 more."; }
t_rule0_plain() { render "$R0"; todo | grep -qxF -- '- `compat.output-removed` (2): the Fixes at `a.tf:1`, `b.tf:2` are one way to restore compatibility; see Findings.'; }
t_unf_fix() {
  render "$({ f structure.grouping LOW a.tf 1 "A." "Fix A."; f structure.grouping LOW b.tf 2 "B." "Fix B."
    f structure.grouping LOW c.tf 3 "C." 'Close the </details> tag.'; } | list wt-unf2)"
  [ "$ST" = 0 ] && ! grep -q 'Fix for each location' "$O/comment.md"
}
mutate "a What to do lead reworded" 's/resolve each checklist item below and push/resolve every checklist item below and push/' t_pr88
mutate "a What to do lead changed in the script only" 's/The items below are optional\./The items below are nits./' t_table
mutate "item e never a checkbox" 's/\{box: any\(\$abc\[\]; \.box\), t: tx\("todo-generated"\)\}/{box: false, t: tx("todo-generated")}/' t_pr88
mutate "the none suppression made case-insensitive" 's/"\^ none\(/"^ (?i)none(/' t_none_fires
mutate "the Fix block from four entries" 's/\(\.entries \| length\) >= 3/(.entries | length) >= 4/' t_fold3
mutate "the Fix block guard dropped" 's/\n  and all\(\.items\[\]; all\(\.summary, \.suggested_fix, loc\(\$p\); test\("<\/\?details\|\\n"; "i"\) \| not\)\)//' t_unf_fix
mutate "What to do rendered at rule 8" 's/if \$v\.rule == 8 or \$quiet then \[\] else/if \$quiet then [] else/' t_rule8_none
mutate "a quiet What to do rendered at rule 4" 's/if \$v\.rule == 8 or \$quiet then \[\] else/if \$v.rule == 8 then [] else/' t_quiet_other
mutate "the STANDARD action line dropped" 's/\(if \$quiet then action_line\(\$c\) else \[\] end\)/[]/' t_quiet_action
mutate "the action line beside a cause outside the table" 's/if \$c\.other or \$c\.admitted == \[\] then/if \$c.admitted == [] then/' t_quiet_other
mutate "the Optional items not quiet" 's/\{box: false, quiet: true, t: grp\("todo-optional"\)\}/{box: false, t: grp("todo-optional")}/' t_quiet_action
t_rule7_todo() { render "$G"; [ "$(rule)" = 7 ] && todo | grep -qxF "$LEAD_7"; }
mutate "What to do quiet at a rule other than 4" 's/\(\$v\.rule == 4 and all\(\$items\[\]; \.quiet\)\)/all(\$items[]; .quiet)/' t_rule7_todo
mutate "nine locations listed" 's/\$l\[:8\]/\$l[:9]/' t_loc9
mutate "rule 0 groups as checkboxes" 's/if \$rule == 0 and/if false and/' t_rule0_plain
mutate "the compat item says its Fix restores compatibility" 's/the Fixes at \{locations\} are one way to restore compatibility; see Findings\./the Fix at {locations} restores compatibility./' t_rule0_plain
t_compat_one() { render "$TMP/wt-root0.json"; todo | grep -qxF -- '- `compat.output-removed`: the Fix at `a.tf:1` is one way to restore compatibility; see Findings.'; }
mutate "the single compat item says its Fix restores compatibility" 's/(compat-one": "`\{rule_id\}`: the Fix at \{locations\}) is one way to restore compatibility; see Findings\./$1 restores compatibility./' t_compat_one
t_rule0_mixed() { render "$R0M"; todo | grep -qxF -- '- [ ] `structure.flag-polarity`: apply the Fix at `e.tf:5`.'; }
mutate "every rule 0 group a compat bullet" 's/\$rule == 0 and compat_item/$rule == 0/' t_rule0_mixed
t_rev_noitem() { render "$TMP/wt-rev6.json"; [ "$ST" = 0 ] && ! todo | grep -qF 'review.path-missing'; }
mutate "review groups listed as items" 's/select\(\.rule \| startswith\("review\."\) \| not\)/select(true)/' t_rev_noitem
t_r4_once() { render "$NONE" "$H2"; [ "$(rule)" = 4 ] && ! todo | grep -qF 'could not run; see'; }
mutate "thread resolution counted as a gap too" 's/select\(\.kind != "thread-resolution-unknown"\)/select(true)/' t_r4_once

# --- Behaviour evidence (behaviour-pass.md, The run object): verified, covered and inert pass;
# an unverified trigger or claim, a trigger over the cap and a step that did not run are unknowns
# at rule 4, listed in section 5; a refuted state blocks at rule 2.
bt() { # id, category, state -> one trigger on main.tf
  jq -nc --arg i "$1" --arg c "$2" --arg s "$3" '{id: $i, file: "main.tf", line: 2, category: $c, state: $s}'
}
brun() { # name, triggers json, claims json [, capped] -> run file
  runf "b-$1" ".behaviour = {status: \"ran\", reason: null, triggers: $2, claims: $3, capped: ${4:-0}}"
}
LOWF="$(f structure.argument-order LOW main.tf 43 "S." "F." | list lowf)" # its own file: one() reuses a name
BOK="$(brun ok "[$(bt T-001 wrapper-change verified), $(bt T-002 unknown-propagation-candidate covered), $(bt T-003 literal-argument-change inert)]" '[{claim_id: "C-1", state: "verified"}]')"
ladder "behaviour verified, covered and inert with a LOW finding" "approve with nits COMMENT" 7 "$LOWF" "" "" "$BOK"
! grep -q 'Behaviour evidence' "$O/comment.md"; check "behaviour: every trigger and claim passed renders no evidence line" $?
BUV="$(brun uv "[$(bt T-001 wrapper-change unverifiable), $(bt T-002 unknown-propagation-candidate unverifiable)]" '[{claim_id: "C-1", state: "unverifiable"}]')"
render "$LOWF" "" "" "$BUV"
grep -qxF 'Behaviour evidence: 2 changes classified: 0 verified, 0 covered by a plan, 0 inert, 0 refuted, 2 not verified; 1 claims: 0 verified, 0 refuted, 1 not verified.' "$O/comment.md"
check "behaviour: the evidence line follows the rationale" $?
awk 'p == "A check this review needs could not run, as listed below. Any unknown makes the review inconclusive (ladder rule 4)." && /^$/ { getline; print; exit } { p = $0 }' "$O/comment.md" | grep -q '^Behaviour evidence: '
check "behaviour: the evidence line is the paragraph after the rationale" $?
render "$LOWF" "" "" "$(brun one-uv "[$(bt T-001 wrapper-change verified)]" '[{claim_id: "C-1", state: "verified"}, {claim_id: "C-2", state: "unverifiable"}]')"
grep -q '^Behaviour evidence: 1 changes classified: 1 verified' "$O/comment.md"; check "behaviour: one unverified claim beside passing triggers keeps the evidence line" $?
ladder "an inert change" "approve APPROVE" 8 "$NONE" "" "" "$(brun inert '[]' '[]')"
! grep -q 'Behaviour evidence' "$O/comment.md"; check "behaviour: nothing classified renders no evidence line" $?
ladder "an unverified trigger with a LOW finding" "inconclusive COMMENT" 4 "$LOWF" "" "" "$BUV"
grep -qxF 'A check this review needs could not run, as listed below. Any unknown makes the review inconclusive (ladder rule 4).' "$O/comment.md"
check "behaviour: rule 4 names the listed checks" $?
render "$LOWF" "" "$(checks bcount unknown)" "$BUV"
grep -qxF -- '- 3 checks could not run; see Checks that could not run.' "$O/comment.md"; check "behaviour: What to do counts each unverified trigger and claim" $?
ladder "an unverified claim alone" "inconclusive COMMENT" 4 "$NONE" "" "" "$(brun uc "[$(bt T-001 wrapper-change verified)]" '[{claim_id: "C-2", state: "unverifiable"}]')"
grep -qxF -- '- Claim C-2 from the description: not verified.' "$O/comment.md"; check "behaviour: the unverified claim is listed" $?
ladder "triggers over the cap" "inconclusive COMMENT" 4 "$NONE" "" "" "$(brun cap '[]' '[]' 2)"
grep -qxF -- '- 2 more behaviour changes over the classifier cap: not verified.' "$O/comment.md"; check "behaviour: the capped line" $?
ladder "the behaviour step not run" "inconclusive COMMENT" 4 "$NONE" "" "" \
  "$(runf bnr '.behaviour = {status: "not-run", reason: "mtf-facts not installed", triggers: [], claims: [], capped: 0}')"
grep -qxF -- '- Behaviour check: mtf-facts not installed, so no change was classified or verified.' "$O/comment.md"; check "behaviour: the not-run line" $?
ladder "a review.verification-incomplete finding" "inconclusive COMMENT" 4 "$(one review.verification-incomplete MEDIUM . null "S." "no code change: none.")"
grep -qxF 'The behaviour evidence handed to the review was incomplete, so a behaviour change may be unchecked. Any unknown makes the review inconclusive (ladder rule 4).' "$O/comment.md"
check "behaviour: the verification-incomplete rationale" $?
ladder "a refuted claim" "block REQUEST_CHANGES" 2 "$(one claim.refuted HIGH main.tf 2 "S." "F.")" "" "" "$(brun ref "[$(bt T-001 wrapper-change refuted)]" '[{claim_id: "C-1", state: "refuted"}]')"
ladder "a fix that does not take effect" "block REQUEST_CHANGES" 2 "$(one claim.fix-not-effective HIGH main.tf 2 "S." "F.")" "" "" "$(brun fne "[$(bt T-001 wrapper-change refuted), $(bt T-002 unknown-propagation-candidate unverifiable)]" '[{claim_id: "C-2", state: "refuted"}]')"
ladder "a CRITICAL behaviour break alone" "hold for the next major COMMENT" 0 "$(one compat.expression-behaviour-changed CRITICAL main.tf 2 "S." "F.")"
# Section 5 byte for byte, with a module root prefix on the trigger paths.
t_bgold() {
  render "$NONE" "$(host bpre '.prefix = "mod"')" "" "$BUV"
  cat > "$TMP/want-b5" <<'EOF'
### Checks that could not run

- Behaviour change at `mod/main.tf:2` (wrapper-change): not verified.
- Behaviour change at `mod/main.tf:2` (unknown-propagation-candidate): not verified.
- Claim C-1 from the description: not verified.
EOF
  awk '/^### Checks that could not run$/ { on = 1 } on && /^### / && !/could not run/ { exit } on' "$O/comment.md" \
    | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' | cmp -s "$TMP/want-b5" -
}
t_bgold; check "behaviour: section 5 byte for byte, paths repository-relative" $?
refused "a behaviour trigger state outside the five" "$G" "" "" "$(brun bs "[$(bt T-001 wrapper-change maybe)]" '[]')"
refused "a behaviour category outside the list" "$G" "" "" "$(brun bc "[$(bt T-001 cosmetic verified)]" '[]')"
refused "a claim state inert" "$G" "" "" "$(brun bk '[]' '[{claim_id: "C-1", state: "inert"}]')"
refused "41 behaviour triggers" "$G" "" "" "$(brun b41 "[$(for i in $(seq 1 41); do bt "$(printf 'T-%03d' "$i")" wrapper-change verified; done | paste -sd, -)]" '[]')"
refused "a ran behaviour with a reason" "$G" "" "" "$(runf br '.behaviour = {status: "ran", reason: "mtf-facts failed", triggers: [], claims: [], capped: 0}')"
refused "a not-run behaviour with triggers" "$G" "" "" "$(runf bt '.behaviour = {status: "not-run", reason: "mtf-facts failed", triggers: [{id: "T-001", file: "main.tf", line: 2, category: "wrapper-change", state: "unverifiable"}], claims: [], capped: 0}')"
refused "a not-run reason outside the list" "$G" "" "" "$(runf bx '.behaviour = {status: "not-run", reason: "tired", triggers: [], claims: [], capped: 0}')"
refused "a behaviour object with an extra key" "$G" "" "" "$(runf be '.behaviour = {status: "ran", reason: null, triggers: [], claims: [], capped: 0, levels: []}')"
refused "a trigger path out of the module" "$G" "" "" "$(brun bp '[{id: "T-001", file: "../main.tf", line: 2, category: "wrapper-change", state: "verified"}]' '[]')"
t_bgaps() { render "$LOWF" "" "" "$BUV"; [ "$(rule)" = 4 ]; }
t_bvi() { render "$(one review.verification-incomplete MEDIUM . null "S." "no code change: none.")"; [ "$(rule)" = 4 ]; }
t_bev() { render "$LOWF" "" "" "$BUV"; grep -q '^Behaviour evidence: 2 changes' "$O/comment.md"; }
t_bev_none() { render "$LOWF" "" "" "$BOK"; [ "$ST" = 0 ] && ! grep -q '^Behaviour evidence: ' "$O/comment.md"; }
t_bstate() { render "$G" "" "" "$TMP/run-b-bs.json"; [ "$ST" = 2 ]; }
mutate "behaviour gaps not counted" 's/ \+ \(\$b \| behaviour_gaps\)\),\n     unplanned:/),\n     unplanned:/' t_bgaps
mutate "unverified triggers not counted" 's/select\(\.state == "unverifiable"\)\] \| length\)/select(false)] | length)/' t_bgaps
mutate "review.verification-incomplete not an unknown" 's/, "review\.verification-incomplete"\)\)/))/' t_bvi
mutate "the evidence line dropped" 's/\+ evidence_lines\(\$b\)//' t_bev
mutate "the evidence line kept when every trigger and claim passed" 's/or \(\$b\.capped == 0 and all/or (false and all/' t_bev_none
mutate "any trigger state accepted" 's/\(\.state \| IN\("inert", "verified", "covered", "refuted", "unverifiable"\)\)/true/' t_bstate
# A run file without the behaviour key: outside a triage run the host did not run the step, an
# unknown with its line; in a triage run nothing more.
ladder "a run file with no behaviour key" "inconclusive COMMENT" 4 "$LOWF" "" "" "$(runf nob 'del(.behaviour)')"
grep -qxF -- '- Behaviour check: not run by the host, so no change was classified or verified.' "$O/comment.md"
check "behaviour: an absent key is the host's step not run" $?
ladder "a triage run file with no behaviour key" "inconclusive COMMENT" 4 "$NONE" "" "" "$(runf nobt 'del(.behaviour) | .triage = true')"
! grep -q 'Behaviour check' "$O/comment.md"; check "behaviour: an absent key in triage adds no line" $?
BREF="$(brun refu "[$(bt T-001 wrapper-change refuted)]" '[{claim_id: "C-1", state: "refuted"}]')"
# A refuted state blocks by itself at rule 2, whatever the review reported; a claim.* finding
# only words it, and one with no refuted state in the behaviour object is refused.
ladder "a refuted state with no claim finding" "block REQUEST_CHANGES" 2 "$LOWF" "" "" "$BREF"
grep -qxF 'The behaviour evidence refutes a change or a claim of the description. Refuted behaviour blocks merge (ladder rule 2).' "$O/comment.md"
check "behaviour: the rationale names the refuted evidence" $?
todo | grep -qxF -- '- [ ] Behaviour change at `main.tf:2` (wrapper-change): the evidence refutes it. Fix the change or correct the description.'
check "behaviour: an unreported refuted trigger is a checklist item" $?
ladder "a refuted state with only a LOW claim finding" "block REQUEST_CHANGES" 2 "$(one claim.refuted LOW main.tf 2 "S." "F.")" "" "" "$BREF"
ladder "a refuted state with its claim finding" "block REQUEST_CHANGES" 2 "$(one claim.refuted HIGH main.tf 2 "S." "F.")" "" "" "$BREF"
! todo | grep -qF 'the evidence refutes it'; check "behaviour: a reported refutation is worded by its finding alone" $?
ladder "a refuted state beside a CRITICAL compat break" "block REQUEST_CHANGES" 1 "$(one compat.expression-behaviour-changed CRITICAL main.tf 2 "S." "F.")" "" "" "$BREF"
# A CRITICAL finding keeps rule 1 and its rationale; the refuted state only adds its item.
ladder "a refuted state beside a CRITICAL non-compat finding" "block REQUEST_CHANGES" 1 "$(f structure.insecure-default CRITICAL main.tf 9 "S." "F." | list crit-ref)" "" "" "$BREF"
cat > "$TMP/want-crit-ref" <<'EOT'
A CRITICAL finding is open. Any CRITICAL finding blocks merge (ladder rule 1).

Behaviour evidence: 1 changes classified: 0 verified, 0 covered by a plan, 0 inert, 1 refuted, 0 not verified; 1 claims: 0 verified, 1 refuted, 0 not verified.

### What to do

To make this mergeable, resolve each checklist item below and push.

- [ ] `structure.insecure-default`: apply the Fix at `main.tf:9`.
- [ ] Behaviour change at `main.tf:2` (wrapper-change): the evidence refutes it. Fix the change or correct the description.
EOT
awk '/^A CRITICAL finding is open/ { on = 1 } on && /^### Findings$/ { exit } on' "$O/comment.md" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' | cmp -s "$TMP/want-crit-ref" -
check "behaviour: CRITICAL plus refuted, rationale and What to do byte for byte" $?
refused "a claim finding with no refuted state" "$(one claim.refuted HIGH main.tf 2 "S." "F.")" "" "" "$BUV"
refused "a claim finding with no behaviour object" "$(one claim.fix-not-effective HIGH main.tf 2 "S." "F.")" "" "" "$TMP/run-nob.json"
t_babsent() { render "$LOWF" "" "" "$TMP/run-nob.json"; [ "$(rule)" = 4 ]; }
t_bref() { render "$LOWF" "" "" "$BREF"; [ "$(rule)" = 2 ]; }
t_bclaim() { render "$(one claim.refuted HIGH main.tf 2 "S." "F.")" "" "" "$BUV"; [ "$ST" = 2 ] && empty_out; }
mutate "an absent behaviour key passes" 's/else \{status: "not-run", reason: "not run by the host"/else null | {status: "not-run", reason: "not run by the host"/; s/elif \$run\.triage then null/elif true then null/' t_babsent
mutate "refuted states do not block" 's/ or \.refuted > 0 then \{rule: 2/ then {rule: 2/' t_bref
mutate "a claim finding with no refuted state accepted" 's/\|\| die "a claim\.\* finding with no refuted state in the behaviour object"/|| true/' t_bclaim
mutate "a behaviour string changed in the script only" 's/so no change was classified or verified/so nothing was classified/' t_table

# --- Tiers (comment-format.md, Tiers): COMPACT when every condition holds, else STANDARD, and
# the reported state of a trigger (verdict.md, Behaviour evidence).
#
# The pull request 556 fixture: one merged trigger at main.tf:156, complete, with 12 outstanding
# differences that F-001 explains, 20 claims verified, 3 of 9 examples stopped at a safety gate,
# and the description cut. The cap is the body item cap, 8000 bytes, a constant of the strings
# table, so this fixture is a description of 8200 bytes: host.json's prose-truncated entry says
# item body, 200 bytes omitted. The golden is the design's literal with "8000 bytes (200 cut)" and
# "under 8000 bytes" in place of its 4000 and 180; every other byte is the literal.
DIG="$(printf 'pr556' | shasum -a 256 | cut -c1-64)"
DIG2="$(printf 'stale' | shasum -a 256 | cut -c1-64)"
IDS="$(jq -nc '[("empty", "one-known", "empty-string-element", "null-element", "unknown-element", "wholly-unknown") as $c
  | ("length", "value") as $a | "T-001|L1|\($c)|\($a)"] | sort')"
PRE='{"source": "tool", "subject": ".:aws_rds_cluster.this", "predates_change": true}'
F556() { # extra jq object for F-001 -> findings file
  n=0
  { f compat.expression-behaviour-changed LOW main.tf 156 'null and empty-string elements of `var.vpc_security_group_ids` now reach the provider, and a null fails the plan.' \
      'reject them with a `validation` block in `variables.tf`, or say in the description that they now fail.' \
      "$(jq -nc --argjson i "$IDS" --arg d "$DIG" '{explains: $i, evidence_digest: $d} + '"${1:-{\}}")"
    f structure.argument-order LOW main.tf 43 '`tags` is not the last argument.' 'Move `tags` last.' "$PRE"
  } | list "f556-$oc"
}
CUT='{kind: "prose-truncated", item: "body", omitted: 200}'
H556="$(host h556 '.repo = "example/terraform-aws-rds-aurora" | .number = 556 | .could_not_run = ['"$CUT"']')"
T556() { # jq update of the trigger -> trigger json
  jq -nc --argjson i "$IDS" --arg d "$DIG" '{id: "T-001", file: "main.tf", line: 156, category: "wrapper-change",
    state: "unverifiable", complete: true, outstanding: $i, evidence_digest: $d} | '"${1:-.}"
}
CL20="$(jq -nc '[range(1; 21) | {claim_id: "C-\(.)", state: "verified"}]')"
R556() { # name, jq update -> run file
  runf "r556-$1" '.plan_ran = true | .plan_mode = "laptop" | .examples = {count: 9, validated: 9}
    | .coverage = {class: "partial", inert: false, unplanned: [{dir: "examples/serverless", reason: "plan gate G1"},
        {dir: "examples/mysql", reason: "plan gate G3"}, {dir: "examples/s3-import", reason: "plan gate G1"}]}
    | .behaviour = {status: "ran", reason: null, triggers: ['"$(T556)"'], claims: '"$CL20"', capped: 0} | '"${2:-.}"
}
cat > "$TMP/assess-556.txt" <<'EOF'
Dropping `compact()` fixes the plan: with an unknown group id the base kept the old value and the head shows an update. It also keeps null and empty-string elements of `vpc_security_group_ids`, and a null element now fails the plan; the description mentions only empty strings.
EOF
cat > "$TMP/want-556.md" <<'EOF'
Dropping `compact()` fixes the plan: with an unknown group id the base kept the old value and the head shows an update. It also keeps null and empty-string elements of `vpc_security_group_ids`, and a null element now fails the plan; the description mentions only empty strings.

**Inconclusive.** `validate` passed in all 9 examples; 6 were planned. Not checked: the description past 8000 bytes (200 cut), 3 of 9 examples not planned (safety gate).

To get a conclusive review: shorten the description under 8000 bytes, and plan the 3 gated examples in runner mode.

- LOW `compat.expression-behaviour-changed` `main.tf:156` - null and empty-string elements of `var.vpc_security_group_ids` now reach the provider, and a null fails the plan.
  - Fix: reject them with a `validation` block in `variables.tf`, or say in the description that they now fail.

<details><summary>Evidence and notes</summary>

- Not planned: `examples/mysql`, `examples/s3-import`, `examples/serverless`.
- Behaviour change at `main.tf:156` reported: judged in F-001 (12 differences). 20 claims verified.
- Predates this change: `structure.argument-order` at `main.tf:43` - `tags` is not the last argument.
</details>
EOF
tier() { printf '%s' "$MSG" | sed -n 's/^rendered .*, tier \([A-Z]*\)$/\1/p'; }
# rc name, findings, run [, host] [, extra args]: one render with the 556 host and assessment.
rc() { local fi="$1" ru="$2" ho="${3:-$H556}"; shift 3 2> /dev/null || shift $#; render "$fi" "$ho" "" "$ru" "$TMP/assess-556.txt" "$@"; }
reported_in() { grep -qF 'reported: judged in' "$O/comment.md"; }

t_556() { rc "$(F556)" "$(R556 gold)"; [ "$ST" = 0 ] && [ "$(tier)" = COMPACT ] && [ "$(rule)" = 4 ] && cmp -s "$O/comment.md" "$TMP/want-556.md"; }
t_556; check "tiers: pull request 556 renders COMPACT, the literal byte for byte" $?
check "tiers: pull request 556 is inconclusive at rule 4, proposes COMMENT" "$([ "$(verdict)" = "inconclusive COMMENT" ]; echo $?)"
check "tiers: COMPACT findings.json lists the routed finding last" "$(jq -e 'map(.id) == ["F-001", "F-002"] and all(.[]; keys == ["file","id","line","rule_id","severity","suggested_fix","summary"])' "$O/findings.json" > /dev/null; echo $?)"
check "tiers: the COMPACT body of pull request 556 is at most 1240 bytes" "$([ "$(wc -c < "$O/comment.md")" -le 1240 ]; echo $?)"
# Pull request 556 with the description finding: the body states only the empty strings, the
# LOW compat.expression-behaviour-changed refutes it, so compat.claim-contradicts-analysis is LOW
# too (one band below, never above). No rule 2 block: the verdict stays at rule 4.
F556C() {
  jq --arg s 'The description says only empty strings now reach the provider; null elements of `var.vpc_security_group_ids` reach it too.' \
    --arg x 'no code change: add to the description: "Dropping `compact()` also keeps null elements, and a null element now fails the plan."' \
    '.[:1] + [{id: "F-002", rule_id: "compat.claim-contradicts-analysis", severity: "LOW", file: ".", line: null,
      summary: $s, suggested_fix: $x, source: "llm"}] + (.[1:] | map(.id = "F-003"))' "$(F556)" > "$TMP/f556c.json"
  echo "$TMP/f556c.json"
}
{ sed -n '1,8p' "$TMP/want-556.md"
  printf '%s\n' '- LOW `compat.claim-contradicts-analysis` `.` - The description says only empty strings now reach the provider; null elements of `var.vpc_security_group_ids` reach it too.' \
    '  - Fix: no code change: add to the description: "Dropping `compact()` also keeps null elements, and a null element now fails the plan."'
  sed -n '9,$p' "$TMP/want-556.md"; } > "$TMP/want-556c.md"
t_556c() { rc "$(F556C)" "$(R556 claimdesc)"; [ "$ST" = 0 ] && [ "$(tier)" = COMPACT ] && [ "$(rule)" = 4 ] && cmp -s "$O/comment.md" "$TMP/want-556c.md"; }
t_556c; check "tiers: pull request 556 with its LOW description finding renders COMPACT, byte for byte" $?
check "tiers: the LOW description finding blocks nothing, inconclusive at rule 4" "$([ "$(verdict)" = "inconclusive COMMENT" ]; echo $?)"
rc "$(F556)" "$(R556 gold-std)" "" --standard
# STANDARD at rule 4 with only Optional items and the gaps line: no What to do, the COMPACT
# action line under the verdict, and no evidence line, since every trigger and claim passed or
# was reported.
{ sed -n '1,4p' "$TMP/want-556.md"; sed -n '5,6p' "$TMP/want-556.md"
  printf '%s\n' 'A check this review needs could not run, as listed below. Any unknown makes the review inconclusive (ladder rule 4).' '' \
    '### Findings' '' '**LOW**' '' \
    '- `compat.expression-behaviour-changed` - `main.tf:156` - null and empty-string elements of `var.vpc_security_group_ids` now reach the provider, and a null fails the plan.' \
    '  - Fix: reject them with a `validation` block in `variables.tf`, or say in the description that they now fail.' \
    '- `structure.argument-order` - `main.tf:43` - `tags` is not the last argument.' '  - Fix: Move `tags` last.' '' \
    '### Checks that could not run' '' \
    '- Quoted prose was truncated, so part of the discussion was not read.' '- 2 examples were not planned: plan gate G1.' \
    '  - `examples/serverless`' '  - `examples/s3-import`' '- 1 example was not planned: plan gate G3.' '  - `examples/mysql`'
} > "$TMP/want-556s.md"
sed -i.bak '3s/ `validate` passed.*$//' "$TMP/want-556s.md"
check "tiers: --standard forces STANDARD on the same inputs, byte for byte" "$([ "$ST" = 0 ] && [ "$(tier)" = STANDARD ] && cmp -s "$O/comment.md" "$TMP/want-556s.md"; echo $?)"
awk '/^### Checks that could not run$/ { on = 1; next } on' "$O/comment.md" | cmp -s - <(printf '%s\n' '' \
  '- Quoted prose was truncated, so part of the discussion was not read.' '- 2 examples were not planned: plan gate G1.' \
  '  - `examples/serverless`' '  - `examples/s3-import`' '- 1 example was not planned: plan gate G3.' '  - `examples/mysql`')
check "tiers: STANDARD section 5 groups the not-planned examples by reason, golden, and lists no reported trigger" $?
rc "$(F556)" "$(R556 gold-std-uv '.behaviour.claims[0].state = "unverifiable"')" "" --standard
grep -qxF 'Behaviour evidence: 1 changes classified: 0 verified, 0 covered by a plan, 0 inert, 1 reported in a finding, 0 refuted, 0 not verified; 20 claims: 19 verified, 0 refuted, 1 not verified.' "$O/comment.md"
check "tiers: the STANDARD evidence line counts the reported trigger" $?
t_cut() { rc "$(F556)" "$(R556 cut)" "$(host cut1 '.could_not_run = [{kind: "prose-truncated", item: "body", omitted: 31}]')"; [ "$(tier)" = COMPACT ] &&
  grep -qF 'Not checked: the description past 8000 bytes (31 cut), 3 of 9 examples not planned (safety gate).' "$O/comment.md"; }
t_cut; check "tiers: the description cause takes the bytes omitted from host.json" $?
rc "$(F556)" "$(R556 cutt)" "$(host cutt '.could_not_run = [{kind: "prose-truncated", item: "thread", omitted: 40}]')"; std0() { [ "$ST" = 0 ] && [ "$(tier)" = STANDARD ]; }
check "tiers: a thread item cut forces STANDARD" "$(std0; echo $?)"
grep -qxF -- '- Quoted prose was truncated, so part of the discussion was not read.' "$O/comment.md"; check "tiers: STANDARD keeps its truncated prose line" $?
rc "$(F556)" "$(R556 cuto)" "$(host cuto '.could_not_run = [{kind: "prose-truncated"}]')"
check "tiers: a prose-truncated entry that names no item forces STANDARD" "$(std0; echo $?)"
t_prose_once() {
  rc "$NONE" "$(runf prose1)" "$(host prose3 '.signals.mergeability = "unknown" | .could_not_run = [{kind: "prose-truncated", item: "body", omitted: 9}, {kind: "prose-truncated", item: "thread", omitted: 4}, {kind: "prose-truncated", item: "title", omitted: 2}, {kind: "patch-unavailable", path: "a.tf"}]')"
  std0 && [ "$(grep -c -xF -- '- Quoted prose was truncated, so part of the discussion was not read.' "$O/comment.md")" = 1 ] &&
    grep -qxF -- '- 2 checks could not run; see Checks that could not run.' "$O/comment.md"
}
t_prose_once; check "tiers: STANDARD renders one truncated prose line for three cut item classes and counts it once" $?

# The reported computation. std_uv: the render is STANDARD at rule 4 with the trigger listed.
std_uv() { [ "$ST" = 0 ] && [ "$(tier)" = STANDARD ] && [ "$(rule)" = 4 ] && grep -qxF -- '- Behaviour change at `main.tf:156` (wrapper-change): not verified.' "$O/comment.md"; }
t_stale() { rc "$(F556 "{evidence_digest: \"$DIG2\"}")" "$(R556 stale)"; std_uv; }
t_stale; check "reported: a stale digest leaves the trigger unverifiable, STANDARD" $?
t_partial() { rc "$(F556 "{explains: $(jq -c '.[1:]' <<< "$IDS")}")" "$(R556 part)"; std_uv; }
t_partial; check "reported: a partial union leaves the trigger unverifiable" $?
t_joint() {
  n=0
  { f compat.expression-behaviour-changed LOW main.tf 156 'First half.' 'Fix one.' "$(jq -nc --argjson i "$IDS" --arg d "$DIG" '{explains: $i[:6], evidence_digest: $d}')"
    f claim.refuted LOW main.tf 156 'Second half.' 'Fix two.' "$(jq -nc --argjson i "$IDS" --arg d "$DIG" '{explains: $i[6:], evidence_digest: $d}')"
  } | list joint > /dev/null
  rc "$TMP/joint.json" "$(R556 joint '.behaviour.claims[0].state = "refuted"')"
  [ "$(rule)" = 2 ] && [ "$(tier)" = STANDARD ] && grep -qF ' 1 reported in a finding, ' "$O/comment.md"
}
t_joint; check "reported: two findings jointly cover the set, and a refuted claim still fires rule 2" $?
t_joint2() {
  n=0
  { f compat.expression-behaviour-changed LOW main.tf 156 'First half.' 'Fix one.' "$(jq -nc --argjson i "$IDS" --arg d "$DIG" '{explains: $i[:6], evidence_digest: $d}')"
    f compat.expression-behaviour-changed LOW main.tf 156 'Second half.' 'Fix two.' "$(jq -nc --argjson i "$IDS" --arg d "$DIG" '{explains: $i[6:], evidence_digest: $d}')"
  } | list joint2 > /dev/null
  rc "$TMP/joint2.json" "$(R556 joint2)"
  [ "$(tier)" = COMPACT ] && grep -qxF -- '- Behaviour change at `main.tf:156` reported: judged in F-001 and F-002 (12 differences). 20 claims verified.' "$O/comment.md"
}
t_joint2; check "reported: two findings jointly, both named" $?
t_super() { rc "$(F556 "{explains: ($(jq -c '. + ["T-001|L2|extra|value"]' <<< "$IDS"))}")" "$(R556 super)"; [ "$(tier)" = COMPACT ] && reported_in; }
t_super; check "reported: a superset of ids covers, the extra id ignored" $?
t_outset() {
  n=0
  { f compat.expression-behaviour-changed LOW main.tf 156 'All.' 'Fix.' "$(jq -nc --argjson i "$IDS" --arg d "$DIG" '{explains: $i, evidence_digest: $d}')"
    f compat.expression-behaviour-changed LOW main.tf 156 'Other.' 'Fix.' "$(jq -nc --arg d "$DIG" '{explains: ["T-001|L3|other|action"], evidence_digest: $d}')"
  } | list outset > /dev/null
  rc "$TMP/outset.json" "$(R556 outset)"
  [ "$(tier)" = COMPACT ] && grep -qF 'reported: judged in F-001 (12 differences).' "$O/comment.md"
}
t_outset; check "reported: a finding with only out-of-set ids is ignored" $?
t_mixed() { rc "$(F556 "{explains: ($(jq -c '. + ["T-002|L1|empty|value"]' <<< "$IDS"))}")" "$(R556 mixed)"; std_uv; }
t_mixed; check "reported: a finding mixing two triggers is ignored" $?
t_where() { rc "$(F556)" "$(R556 where ".behaviour.triggers[0].line = 157")"; [ "$(tier)" = STANDARD ] && ! reported_in && ! grep -qF ' reported in a finding' "$O/comment.md"; }
t_where; check "reported: a finding at another line is ignored" $?
t_rule() { rc "$(printf '%s\n' "$(f structure.argument-order LOW main.tf 156 'S.' 'F.')" | jq -c --argjson i "$IDS" --arg d "$DIG" '. + {explains: $i, evidence_digest: $d}' | list rulebad)" "$(R556 rulebad)"; [ "$ST" = 2 ] && empty_out; }
t_rule; check "refused: explains on a rule that cannot explain" $?
t_incomplete() { rc "$(F556)" "$(R556 inc '.behaviour.triggers[0].complete = false')"; std_uv; }
t_incomplete; check "reported: complete false with a covered set stays unverifiable" $?
t_verified() { rc "$(F556)" "$(R556 ver '.behaviour.triggers[0] |= (.state = "verified" | .outstanding = [] | del(.evidence_digest))')"; [ "$(tier)" = COMPACT ] && ! reported_in; }
t_verified; check "reported: complete with an empty outstanding set is verified" $?
t_floor() { rc "$(F556 '{severity: "INFO"}')" "$(R556 floor)"; [ "$ST" = 2 ] && empty_out && printf '%s' "$MSG" | grep -qF 'below LOW, the floor'; }
t_floor; check "refused: a covering finding rated below LOW" $?
refused "a digest with no outstanding difference" "$(F556)" "$H556" "" "$(R556 nodiff '.behaviour.triggers[0].outstanding = []')"
refused "an outstanding id of another trigger" "$(F556)" "$H556" "" "$(R556 othid '.behaviour.triggers[0].outstanding += ["T-002|L1|a|value"]')"
refused "outstanding ids out of order" "$(F556)" "$H556" "" "$(R556 order '.behaviour.triggers[0].outstanding |= reverse')"
refused "an outstanding id outside the grammar" "$(F556)" "$H556" "" "$(R556 badid '.behaviour.triggers[0].outstanding = ["T-001|L5|a|value"]')"
refused "a digest that is not 64 hex" "$(F556 '{evidence_digest: "abc"}')" "$H556" "" "$(R556 baddig)"
refused "predates_change on a model finding" "$(F556 '{predates_change: true}')" "$H556" "" "$(R556 llmpre)"
refused "a host.json item with no omitted count" "$(F556)" "$(host noom '.could_not_run = [{kind: "prose-truncated", item: "body"}]')" "" "$(R556 noom)"
refused "a host.json omitted count of 0" "$(F556)" "$(host om0 '.could_not_run = [{kind: "prose-truncated", item: "body", omitted: 0}]')" "" "$(R556 om0)"
refused "a host.json item outside the three" "$(F556)" "$(host omx '.could_not_run = [{kind: "prose-truncated", item: "readme", omitted: 3}]')" "" "$(R556 omx)"
refused "a host.json item on another kind" "$(F556)" "$(host omk '.could_not_run = [{kind: "patch-unavailable", path: "a.tf", item: "body", omitted: 3}]')" "" "$(R556 omk)"

# Every condition of the selector, one case each; the 556 fixture with one thing changed.
std() { check "tiers: $1 forces STANDARD" "$([ "$ST" = 0 ] && [ "$(tier)" = STANDARD ] && grep -qF '### ' "$O/comment.md"; echo $?)"; }
rc "$(F556 '{severity: "MEDIUM"}')" "$(R556 med)"; std "a MEDIUM finding with rule 4 outstanding"
check "tiers: the MEDIUM case stays at rule 4" "$([ "$(rule)" = 4 ]; echo $?)"
rc "$(F556)" "$(R556 uv '.behaviour.triggers += [{id: "T-002", file: "main.tf", line: 9, category: "default-change", state: "unverifiable"}]')"; std "an unverifiable trigger"
rc "$(F556)" "$(R556 nocls '.behaviour = {status: "not-run", reason: "mtf-facts failed", triggers: [], claims: [], capped: 0}')"; std "a classifier that did not run"
rc "$(F556)" "$(R556 floorcat '.behaviour.triggers += [{id: "T-002", file: "versions.tf", line: 5, category: "provider-version-floor-change", state: "verified"}]')"; std "a provider version floor change"
four() { n=0; { f compat.expression-behaviour-changed LOW main.tf 156 'S.' 'F.' "$(jq -nc --argjson i "$IDS" --arg d "$DIG" '{explains: $i, evidence_digest: $d}')"
  for i in 1 2 3; do f "structure.r$i" LOW "x$i.tf" "$i" "S$i." "F$i."; done; } | list "four-$1"; }
rc "$(four a)" "$(R556 four)"; std "four counted findings"
rc "$({ n=0; f compat.expression-behaviour-changed LOW main.tf 156 'S.' 'F.' "$(jq -nc --argjson i "$IDS" --arg d "$DIG" '{explains: $i, evidence_digest: $d}')"
  for i in 1 2; do f structure.r1 LOW "x$i.tf" "$i" "S$i." "F$i."; done; f structure.r1 LOW x3.tf 3 S1. F1.; } | list g3a)" "$(R556 g3)"
check "tiers: four findings with a group of three force STANDARD" "$([ "$(tier)" = STANDARD ]; echo $?)"
rc "$({ n=0; for i in 1 2 3; do f structure.r1 LOW "x$i.tf" "$i" "Same." "Same."; done; } | list g3b)" "$(R556 g3b '.behaviour.triggers[0] |= (.state = "verified" | .outstanding = [] | del(.evidence_digest))')"; std "a group of three"
t_routed() {
  n=0
  { for i in 1 2 3; do f "structure.r$i" LOW "x$i.tf" "$i" "S$i." "F$i."; done
    f structure.argument-order LOW main.tf 43 '`tags` is not the last argument.' 'Move `tags` last.' "$PRE"; } | list routed > /dev/null
  rc "$TMP/routed.json" "$(R556 routed '.behaviour.triggers[0] |= (.state = "verified" | .outstanding = [] | del(.evidence_digest))')"
  [ "$(tier)" = COMPACT ] && [ "$(grep -c '^- LOW ' "$O/comment.md")" = 3 ] &&
    grep -qxF -- '- Predates this change: `structure.argument-order` at `main.tf:43` - `tags` is not the last argument.' "$O/comment.md"
}
t_routed; check "tiers: a routed pre-existing LOW is uncounted and goes to the details block" $?
t_unrouted_med() {
  rc "$(printf '%s\n' "$(f structure.argument-order MEDIUM main.tf 43 'T.' 'M.' "$PRE")" | list premed)" "$(R556 premed)"
  [ "$(tier)" = STANDARD ] && grep -qF -- '- `structure.argument-order` - `main.tf:43` - T.' "$O/comment.md"
}
t_unrouted_med; check "tiers: a pre-existing finding above LOW renders as a finding" $?
rc "$(F556)" "$(R556 budget '.coverage.unplanned[0].reason = "budget"')"; std "an unlisted reason class"
rc "$(F556)" "$(R556 vgap '.verify_gaps = [{dir: "examples/a", reason: "init failed"}] | .examples.validated = 8')"; std "a cause outside the table (a verification gap)"
rc "$(F556)" "$(R556 patch)" "$(host patch '.could_not_run = ['"$CUT"', {kind: "patch-unavailable", path: "main.tf"}]')"; std "a cause outside the table (a patch unavailable)"
rc "$(F556)" "$(R556 thr)" "$(host thr '.could_not_run = ['"$CUT"'] | .unresolved_threads = [{path: "a.tf", line: 1}]')"; std "an unresolved thread"
rc "$(F556)" "$(R556 noex 'del(.examples)')"; std "a run file without example counts"
rc "$(printf '%s\n' "$(f review.tool-disputed LOW main.tf 43 'D.' 'no code change: decide.')" | list disp)" "$(R556 disp2 '.behaviour.triggers[0] |= (.state = "verified" | .outstanding = [] | del(.evidence_digest))')"; std "a disputed note"
t_g0() {
  rc "$(F556)" "$(R556 g0 '.coverage.unplanned = [{dir: "examples/a", reason: "plan gate G0"}, {dir: "examples/b", reason: "plan gate G2"}]')"
  [ "$(tier)" = COMPACT ] && grep -qF 'Not checked: the description past 8000 bytes (200 cut), 1 of 9 examples not planned (safety gate), 1 of 9 examples not planned (file gate).' "$O/comment.md" &&
    grep -qxF 'To get a conclusive review: shorten the description under 8000 bytes, plan the 1 gated example in runner mode, and remove what plan gate G0 refuses from the 1 example.' "$O/comment.md"
}
t_g0; check "tiers: a G0 example gets its own clause, never the runner clause" $?
t_noplan() {
  rc "$NONE" "$(runf noplan '.examples = {count: 2, validated: 2}
    | .coverage = {class: "none", inert: false, unplanned: [{dir: "examples/b", reason: "no AWS profile named"}, {dir: "examples/a", reason: "no AWS profile named"}]}')" "$HOST"
  [ "$(tier)" = COMPACT ] && cmp -s "$O/comment.md" <(printf '%s\n' "$(cat "$TMP/assess-556.txt")" '' \
    '**Inconclusive.** Not checked: no plan was run (no AWS profile named).' '' 'To get a conclusive review: name an AWS profile.' '' \
    '<details><summary>Evidence and notes</summary>' '' '- Not planned: `examples/a`, `examples/b`.' '</details>')
}
t_noplan; check "tiers: coverage none for want of a profile, byte for byte" $?
t_names() {
  rc "$(F556)" "$(R556 names '.coverage.unplanned = [{dir: "examples/z", reason: "plan gate G1"}, {dir: "examples/b c", reason: "plan gate G1"},
      {dir: "examples/a", reason: "plan gate G1"}, {dir: "examples/m", reason: "plan gate G1"}, {dir: "examples/k", reason: "plan gate G1"}]')"
  [ "$(tier)" = COMPACT ] && grep -qxF -- '- Not planned: `examples/a`, name withheld, `examples/k`, +2.' "$O/comment.md" &&
    ! grep -qF 'examples/z' "$O/comment.md" && ! grep -qF 'my mod' "$O/comment.md"
}
t_names; check "tiers: names allowlisted and sorted, at most three and the count, a name outside the charset withheld" $?
t_withheld_loc() {
  rc "$(F556 '{file: "my mod/main.tf"}')" "$(R556 wloc '.behaviour.triggers[0].file = "my mod/main.tf"')"
  [ "$(tier)" = COMPACT ] && grep -qF -- '- Behaviour change at name withheld reported: judged in F-001 (12 differences).' "$O/comment.md"
}
t_withheld_loc; check "tiers: a trigger location outside the charset is withheld in the details block" $?
over() { # name, findings, assessment file, want message
  render "$1" "$H556" "" "$(R556 "over-$oc")" "$2"
  check "refused: COMPACT $4" "$([ "$ST" = 2 ] && empty_out && printf '%s' "$MSG" | grep -qF "$3" && printf '%s' "$MSG" | grep -qF 'COMPACT limit'; echo $?)"
}
{ head -c 351 /dev/zero | tr '\0' a; echo; } > "$TMP/a-351.txt"
over "$(F556)" "$TMP/a-351.txt" 'the assessment is 351 characters, limit 350' "an assessment over 350 characters"
printf 'One.\n\nTwo.\n' > "$TMP/a-2p.txt"
over "$(F556)" "$TMP/a-2p.txt" 'the assessment is more than one paragraph, limit one' "an assessment of two paragraphs"
over "$(F556 "{summary: \"$(head -c 201 /dev/zero | tr '\0' s)\"}")" "$TMP/assess-556.txt" 'finding F-001 summary is 201 characters, limit 200' "a summary over 200 characters"
over "$(F556 "{suggested_fix: \"$(head -c 251 /dev/zero | tr '\0' s)\"}")" "$TMP/assess-556.txt" 'finding F-001 suggested_fix is 251 characters, limit 250' "a fix over 250 characters"
# A needs decision: fix keeps the 600 the length targets give it: one of 409 characters, the
# length that once forced STANDARD, renders COMPACT, and one of 600 still does.
ND409="needs decision: $(head -c 393 /dev/zero | tr '\0' d)"
t_nd409() { rc "$(F556 "{suggested_fix: \"$ND409\"}")" "$(R556 nd409)"; [ "$ST" = 0 ] && [ "$(tier)" = COMPACT ] && grep -qxF -- "  - Fix: $ND409" "$O/comment.md"; }
t_nd409; check "tiers: a needs decision fix of 409 characters renders COMPACT" $?
t_nd600() { rc "$(F556 "{suggested_fix: \"needs decision: $(head -c 584 /dev/zero | tr '\0' d)\"}")" "$(R556 nd600)"; [ "$ST" = 0 ] && [ "$(tier)" = COMPACT ]; }
t_nd600; check "tiers: a needs decision fix of 600 characters renders COMPACT" $?
over "$(F556 "{suggested_fix: \"Needs decision: $(head -c 393 /dev/zero | tr '\0' d)\"}")" "$TMP/assess-556.txt" 'finding F-001 suggested_fix is 409 characters, limit 250' "a fix of 409 characters without the exact needs decision prefix"
# Every offender in one message, in input order, each with its length and its limit.
t_over_all() {
  jq --arg s1 "$(head -c 201 /dev/zero | tr '\0' s)" --arg x1 "$(head -c 260 /dev/zero | tr '\0' x)" \
    --arg s2 "$(head -c 230 /dev/zero | tr '\0' t)" '.[0].summary = $s1 | .[0].suggested_fix = $x1 | .[1].summary = $s2' \
    "$(F556)" > "$TMP/over-all.json"
  render "$TMP/over-all.json" "$H556" "" "$(R556 overall)" "$TMP/a-351.txt"
  [ "$ST" = 2 ] && empty_out && [ "$MSG" = 'render-comment.sh: over the COMPACT limits: the assessment is 351 characters, limit 350; finding F-001 summary is 201 characters, limit 200; finding F-001 suggested_fix is 260 characters, limit 250; finding F-002 summary is 230 characters, limit 200; send it back to the reviewer once; if it keeps the finding because it is within the schema targets, render with --standard' ]
}
t_over_all; check "refused: COMPACT every offender named in one message with its length and limit" $?

# The band of compat.claim-contradicts-analysis (quoted-claims.md): one below the highest compat.*
# code finding, compat.break-unexplained aside, and never without one. Above it, refused.
BAND_MSG='render-comment.sh: a `compat.claim-contradicts-analysis` finding is rated above the band of the `compat.*` code finding that refutes it, or has none; send it back to the reviewer'
band_refused() { # name, findings
  render "$2"
  check "refused: $1" "$([ "$ST" = 2 ] && empty_out && [ "$MSG" = "$BAND_MSG" ]; echo $?)"
}
t_band_low() { render "$({ f compat.expression-behaviour-changed LOW main.tf 1 "S." "F."; f compat.claim-contradicts-analysis HIGH . null "T." "no code change: G."; } | list band-low)"; [ "$ST" = 2 ] && empty_out && [ "$MSG" = "$BAND_MSG" ]; }
t_band_low; check "refused: a HIGH description finding beside a LOW code finding" $?
band_refused "a description finding with no compat.* code finding" "$({ f compat.break-unexplained MEDIUM . null "S." "no code change: F."; f compat.claim-contradicts-analysis LOW . null "T." "no code change: G."; } | list band-none)"
render "$({ f compat.variable-removed HIGH a.tf 1 "S." "F."; f compat.expression-behaviour-changed LOW b.tf 2 "U." "H."
  f compat.claim-contradicts-analysis MEDIUM . null "T." "no code change: G."; } | list band-ok)"
check "band: a MEDIUM description finding below the highest code finding, HIGH, is accepted" "$([ "$ST" = 0 ] && [ "$(rule)" = 2 ]; echo $?)"
render "$(F556 "{summary: \"$(head -c 201 /dev/zero | tr '\0' s)\"}")" "$H556" "" "$(R556 over-std)" "$TMP/a-351.txt" --standard
check "tiers: the same text passes in STANDARD with --standard" "$([ "$ST" = 0 ] && [ "$(tier)" = STANDARD ]; echo $?)"
render "$(F556 "{summary: \"$(head -c 501 /dev/zero | tr '\0' s)\"}")" "$H556" "" "$(R556 over-501)" "" --standard
check "refused: STANDARD a summary over 500 characters, the message names the limit and the tier" "$([ "$ST" = 2 ] && printf '%s' "$MSG" | grep -qF 'at most 500 characters' && printf '%s' "$MSG" | grep -qF 'STANDARD limits'; echo $?)"
t_approve() {
  rc "$NONE" "$(runf appr '.plan_ran = true | .examples = {count: 9, validated: 9}')" "$HOST"
  [ "$(tier)" = COMPACT ] && [ "$(verdict)" = "approve APPROVE" ] &&
    cmp -s "$O/comment.md" <(printf '%s\n' "$(cat "$TMP/assess-556.txt")" '' '**Good to merge.** `validate` passed in all 9 examples; 9 were planned.')
}
t_approve; check "tiers: approve, K equals M, byte for byte" $?
t_nits() {
  rc "$(printf '%s\n' "$(f structure.grouping LOW a.tf 1 'S.' 'F.')" | list nits)" "$(runf nits '.plan_ran = true | .examples = {count: 9, validated: 8}')" "$HOST"
  [ "$(tier)" = COMPACT ] && [ "$(rule)" = 7 ] && cmp -s "$O/comment.md" <(printf '%s\n' "$(cat "$TMP/assess-556.txt")" '' \
    '**Good to merge, with nits.** `validate` passed in 8 of 9 examples; 9 were planned.' '' '- LOW `structure.grouping` `a.tf:1` - S.' '  - Fix: F.')
}
t_nits; check "tiers: approve with nits, K below M, byte for byte" $?
refused "example counts with more validated than verified" "$G" "" "" "$(runf exbad '.examples = {count: 2, validated: 2} | .verify_gaps = [{dir: "examples/a", reason: "init failed"}]')"
refused "example counts below the unplanned examples" "$G" "" "" "$(runf exbad2 '.examples = {count: 1, validated: 1} | .coverage = {class: "none", inert: false, unplanned: [{dir: "a", reason: "budget"}, {dir: "b", reason: "budget"}]}')"
refused "an unknown argument after --standard" "$G" "" "" "" "" --standard --compact

# The plan pass mode (plan-pass.md, Runner or laptop): runner mode still refuses what a gate hit
# there names, so the runner clause is advice only after a laptop-mode pass. A gate hit after a
# runner-mode pass, or with no mode, is a cause outside the table.
t_runner() {
  rc "$(F556)" "$(R556 runner '.plan_mode = "runner"')"
  std0 && [ "$(rule)" = 4 ] && ! grep -qF 'runner mode' "$O/comment.md" &&
    grep -qxF -- '- 2 examples were not planned: plan gate G1.' "$O/comment.md"
}
t_runner; check "tiers: a gate hit after a runner-mode pass forces STANDARD with no runner advice" $?
rc "$(F556)" "$(R556 nomode 'del(.plan_mode)')"
check "tiers: a gate hit with no plan mode forces STANDARD with no runner advice" "$(std0 && ! grep -qF 'runner mode' "$O/comment.md"; echo $?)"
rc "$(F556)" "$(R556 g0run '.plan_mode = "runner" | .coverage.unplanned = [{dir: "examples/a", reason: "plan gate G0"}]')"
check "tiers: a G0 hit after a runner-mode pass forces STANDARD" "$(std0; echo $?)"
refused "a plan mode outside the two" "$G" "" "" "$(runf badmode '.plan_mode = "cloud"')"
t_one() {
  rc "$(F556)" "$(R556 one1 '.coverage.unplanned = [{dir: "examples/a", reason: "plan gate G3"}]')"
  [ "$(tier)" = COMPACT ] && grep -qxF 'To get a conclusive review: shorten the description under 8000 bytes, and plan the 1 gated example in runner mode.' "$O/comment.md"
}
t_one; check "tiers: one gated example takes the one form" $?
# also_categories: the version floor condition reads every category of a merged trigger.
t_alsofloor() {
  rc "$(F556)" "$(R556 also '.behaviour.triggers += [{id: "T-002", file: "versions.tf", line: 5, category: "literal-argument-change", also_categories: ["provider-version-floor-change"], state: "verified"}]')"
  std0
}
t_alsofloor; check "tiers: a version floor change among also_categories forces STANDARD" $?
rc "$(F556)" "$(R556 also2 '.behaviour.triggers += [{id: "T-002", file: "x.tf", line: 5, category: "literal-argument-change", also_categories: ["default-change"], state: "verified"}]')"
check "tiers: another category among also_categories keeps COMPACT" "$([ "$(tier)" = COMPACT ]; echo $?)"
refused "an also_categories entry outside the list" "$(F556)" "$H556" "" "$(R556 alsobad '.behaviour.triggers[0].also_categories = ["cosmetic"]')"
refused "an also_categories entry twice" "$(F556)" "$H556" "" "$(R556 alsodup '.behaviour.triggers[0].also_categories = ["default-change", "default-change"]')"
refused "an empty also_categories" "$(F556)" "$H556" "" "$(R556 alsoempty '.behaviour.triggers[0].also_categories = []')"
# The grammar: differences and a digest belong to an unverifiable trigger, and explains to a digest.
t_passdiff() { rc "$(F556)" "$(R556 passd '.behaviour.triggers[0].state = "verified"')"; [ "$ST" = 2 ] && empty_out; }
t_passdiff; check "refused: a verified trigger with outstanding differences and a digest" $?
refused "a covered trigger with a digest" "$(F556)" "$H556" "" "$(R556 covd '.behaviour.triggers[0].state = "covered"')"
refused "an inert trigger with outstanding differences" "$(F556)" "$H556" "" "$(R556 inertd '.behaviour.triggers[0] |= (.state = "inert" | del(.evidence_digest))')"
t_nodig() { rc "$(printf '%s\n' "$(f compat.expression-behaviour-changed LOW main.tf 156 S. F. "$(jq -nc --argjson i "$IDS" '{explains: $i}')")" | list nodig)" "$(R556 nodig)"; [ "$ST" = 2 ] && empty_out; }
t_nodig; check "refused: a finding with explains and no evidence_digest" $?
refused "a finding with an evidence_digest and no explains" "$(printf '%s\n' "$(f compat.expression-behaviour-changed LOW main.tf 156 S. F. "{\"evidence_digest\": \"$DIG\"}")" | list digonly)" "$H556" "" "$(R556 digonly)"
# The predates line is in the details block, so its location is allowlisted too.
t_predloc() {
  rc "$(printf '%s\n' "$(f structure.argument-order LOW 'my mod/x.tf' 4 'T.' 'M.' "$PRE")" | list predloc)" \
    "$(R556 predloc '.behaviour.triggers[0] |= (.state = "verified" | .outstanding = [] | del(.evidence_digest))')"
  [ "$(tier)" = COMPACT ] && grep -qxF -- '- Predates this change: `structure.argument-order` at name withheld - T.' "$O/comment.md"
}
t_predloc; check "tiers: a predates location outside the charset is withheld" $?
# The examples jq of SKILL.md, Step 10, on verify-pass.sh output of the shape verify-pass.md gives:
# only verified directories count, and validated counts those whose head validate exited 0.
t_examples_jq() {
  local q; q="$(sed -n 's/.*`examples`, `{"count": M, "validated": K}`, from .*: `jq '"'"'\(.*\)'"'"'`\..*/\1/p' "$SRC/.agents/skills/terraform-module-pr-review/SKILL.md")"
  [ -n "$q" ] && jq -n '{head_sha: "h", base_sha: "b", terraform_version: null, selection: {}, dirs: [
      {dir: "examples/a", reason: "verified", affected: "touched", head: {init: 0, validate: 0, record: "code-result", line: null}, base: null, outside: false},
      {dir: "examples/b", reason: "verified", affected: "all", head: {init: 0, validate: 1, record: "code-result", line: "x"}, base: null, outside: false},
      {dir: "examples/c", reason: "skipped-version-bump", affected: "all", head: null, base: null, outside: false},
      {dir: "examples/d", reason: "skipped-symlink", affected: "all", head: null, base: null, outside: false}]}' |
    jq -c "$q" | grep -qxF '{"count":2,"validated":1}'
}
t_examples_jq; check "SKILL.md: the examples jq counts verified directories only, on the verify-pass output shape" $?

# Case functions for the self-check below.
t_floorcat() { rc "$(F556)" "$(R556 floorcat2 '.behaviour.triggers += [{id: "T-002", file: "versions.tf", line: 5, category: "provider-version-floor-change", state: "verified"}]')"; [ "$(tier)" = STANDARD ]; }
t_four() { rc "$(four b)" "$(R556 fourb)"; [ "$(tier)" = STANDARD ]; }
t_g3() { rc "$TMP/g3b.json" "$TMP/run-r556-g3b.json"; [ "$(tier)" = STANDARD ]; }
t_vgap() { rc "$(F556)" "$TMP/run-r556-vgap.json"; [ "$(tier)" = STANDARD ]; }
t_over() { render "$(F556)" "$H556" "" "$(R556 overm)" "$TMP/a-351.txt"; [ "$ST" = 2 ] && empty_out; }
t_force() { rc "$(F556)" "$(R556 force)" "" --standard; [ "$(tier)" = STANDARD ]; }
t_root_rule0_item() { t_root_rule0; [ "$ST" = 0 ] && todo | grep -qxF -- '- [ ] Resolve `compat.claim-contradicts-analysis`: see its Fix under Findings.'; }
t_root_one_item() { t_root_one; [ "$ST" = 0 ] && todo | grep -qxF -- '- [ ] Resolve `scope.description-only`: see its Fix under Findings.'; }

# Negative self-check for the tier rules.
mutate "the subset-of-union test dropped" 's/if \(\$t\.outstanding - \[\$e\[\]\.explains\[\]\]\) == \[\] then/if true then/' t_partial
mutate "the digest compare dropped" 's/\n  and \.evidence_digest == \$t\.evidence_digest;/;/' t_stale
mutate "the one-trigger rule dropped" 's/\(\[\.explains\[\] \| split\("\|"\)\[0\]\] \| unique\) == \[\$t\.id\]/true/' t_mixed
mutate "the file and line match dropped" 's/and \.file == \$t\.file and \.line == \$t\.line/and true/' t_where
mutate "complete not required" 's/and \.complete == true and/and/' t_incomplete
mutate "the floor not named" 's/&& die "a finding that explains differences is rated below LOW/\&\& true "/' t_floor
mutate "the version floor condition dropped" 's/and \(any\(\.category, \(\.also_categories \/\/ \[\]\)\[\]; \. == "provider-version-floor-change"\) \| not\)/and true/' t_floorcat
mutate "also_categories not read for the version floor" 's/any\(\.category, \(\.also_categories \/\/ \[\]\)\[\];/any(.category;/' t_alsofloor
mutate "prose-truncated entries each counted" 's/def cnr_count: .*/def cnr_count: length;/' t_prose_once
mutate "gate advice after a runner-mode pass" 's/or \(\$run\.plan_mode != "laptop" and/or (false and/' t_runner
mutate "the one form of an action clause dropped" 's/\(if \.count == 1 then "-one" else "-many" end\)/"-many"/' t_g0
mutate "a passing trigger with differences accepted" 's/\(\$pass and \(\(\.outstanding \/\/ \[\]\) != \[\] or has\("evidence_digest"\)\)\) \| not\)/true)/' t_passdiff
mutate "explains without a digest accepted" 's/and \(has\("explains"\) == has\("evidence_digest"\)\)//' t_nodig
mutate "the predates location not allowlisted" 's/tx\("evidence-predates"; \{rule_id, location: safe_loc\(\$p\)/tx("evidence-predates"; {rule_id, location: loc(\$p)/' t_predloc
mutate "the finding cap dropped" 's/and \(\$counted \| length\) <= 3/and true/' t_four
mutate "the group condition dropped" 's/and all\(\$counted \| groups\[\]; \(\.items \| length\) < 3\)/and true/' t_g3
mutate "routing ignores predates_change" 's/and \.predates_change == true;/and false;/' t_routed
mutate "causes outside the table admitted" 's/and \(\$c\.other \| not\)/and true/' t_vgap
mutate "G0 sent to the runner clause" 's/\{"plan gate G0": "file-gate"/{"plan gate G0": "safety-gate"/' t_g0
mutate "the name allowlist dropped" 's/def allowed: test\("\^\[A-Za-z0-9\._\/-\]\+\$"\);/def allowed: true;/' t_names
mutate "names not sorted" 's/def name_list: sort \|/def name_list:/' t_names
mutate "the COMPACT caps dropped" 's/refuse: \(if \$tier == "COMPACT" then compact_refusal\(\$in\) else null end\)/refuse: null/' t_over
mutate "the needs decision fix held to 250 in COMPACT" 's/then 600 else 250 end/then 250 else 250 end/' t_nd409
mutate "the refusal advice reworded in the script only" 's/send it back to the reviewer once; if it keeps the finding because it is within the schema targets, render with --standard/send it back to the reviewer, or render with --standard/' t_advice
mutate "only the first COMPACT offender named" 's/\(\$o \| join\("; "\)\)/$o[0]/' t_over_all
mutate "the description band not enforced" 's/def band_ok:/def band_ok: true; def band_ok_unused:/' t_band_low
mutate "the module root item dropped under rule 0" 's/def compat_item: [^\n]*/def compat_item: (.rule | startswith("compat."));/' t_root_rule0_item
mutate "the module root item dropped" 's/elif all\(\.items\[\]; \.file == "\."\)/elif false/' t_root_one_item
mutate "--standard ignored" 's/--standard\) standard=true; shift ;;/--standard) shift ;;/' t_force
mutate "a COMPACT string changed in the script only" 's/plan the \{count\} gated examples in runner mode/plan the {count} examples in runner mode/' t_table
mutate "the verdict line drops the validate sentence" 's/\(if \$run\.plan_ran then " " \+ tx/(if false then " " + tx/' t_556
mutate "every prose-truncated entry its own line" 's/select\(\.value\.kind != "prose-truncated" or \.key == \$first\)/select(true)/' t_prose_once
mutate "reported triggers counted as gaps" 's/\. \+ \{state: "reported", judged_by: \[\$e\[\]\.id\]\}/./' t_556

echo
if [ "$fails" -eq 0 ]; then echo "render comment: all checks hold"; else echo "render comment: $fails failed"; exit 1; fi
