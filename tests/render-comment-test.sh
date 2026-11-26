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
# The step text of SKILL.md, Step 10 included: references/workflow.md once it moved there.
STEPS="$REF/workflow.md"; [ -f "$STEPS" ] || STEPS="$SRC/.agents/skills/terraform-module-pr-review/SKILL.md"
CF="$REF/comment-format.md"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/render-comment-test.XXXXXX")" && pwd -P)" && [ -n "$TMP" ] || { echo "FAIL no temporary directory"; exit 1; }
[ -z "${KEEP:-}" ] || echo "kept: $TMP" >&2
[ -n "${KEEP:-}" ] || trap 'rm -rf "$TMP"' EXIT
fails=0
HEAD=0123456789abcdef0123456789abcdef01234567
BASE=89abcdef0123456789abcdef0123456789abcdef
RCU="$REF/render-comment.sh" # the script under test; the self-check swaps in mutated copies
RF="$SRC/.agents/skills/terraform-module-reviewer/references/rule-facts.md" # the rule registry the script reads
REGISTRY="$(jq -c -R -s -L "$REF" 'include "render-comment"; registry_ids' "$RF")"
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
# Three distinct registry rules, for fixtures that need several rule groups.
rid() { case "$1" in 1) echo structure.wrong-file ;; 2) echo structure.missing-description ;; *) echo structure.variable-untyped ;; esac; }
# stdin findings -> file, numbered F-001 on in order, since f runs in subshells
list() {
  jq -s 'to_entries | map(.value + {id: ("F-" + ("00\(.key + 1)" | .[-3:]))})' > "$TMP/$1.json"
  echo "$TMP/$1.json"
}

host() { # name [, jq update] -> host.json path
  jq -n --arg h "$HEAD" --arg b "$BASE" '{format: 1, repo: "example/terraform-aws-thing", number: 7,
    head_sha: $h, base_sha: $b, merge_base: $b, prefix: "",
    state: {state: "open", merged: false, draft: false, base_is_default: true, self_authored: false, locked: false, lock_reason: null},
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
    own_check: null, own_check_dropped: 0, own_jobs_dropped: 0, own_jobs_unreadable: false, jobless: [],
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
nofix() { grep -v -e '^ *- Fix: ' -e '^ *- Fix for each location above: '; }
# Run 1 of pull request 410 predates the Fix lines, the Fix blocks of grouping rule 7, the shared
# Fix line of rule 8 and the What to do section, so all are removed from a render before it is
# compared with run 1.
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
# The known MEDIUM outranks the unknown thread resolution, which section 5 still lists.
check "worked example 2: block at rule 6 over the unknown, proposes REQUEST_CHANGES" "$([ "$(verdict)" = "block REQUEST_CHANGES" ] && [ "$(rule)" = 6 ]; echo $?)"

fence 8 | sed -n 1,2p > "$TMP/assess-worked3.txt"
render "$(printf '%s\n' "$WL" | list worked3)" "" "" "" "$TMP/assess-worked3.txt"
awk '/^### Findings$/ { exit } { print }' "$O/comment.md" | sed '$d' > "$TMP/worked3-head.md"
check "worked example 3: the body up to its findings byte for byte" "$(cmp -s "$TMP/worked3-head.md" <(fence 8); echo $?)"
check "worked example 3: approve with nits at rule 7" "$([ "$(verdict)" = "approve with nits COMMENT" ] && [ "$(rule)" = 7 ]; echo $?)"

# --- Example: Fix lines.

n=0
{ f scope.profile-file HIGH .github/workflows/security.yml null "New workflow file running Trivy, Checkov and Gitleaks; the profile's workflow set is exactly the five templates." "Remove the workflow."
  f scope.profile-file HIGH .github/workflows/test.yml null "New workflow file running Terraform native tests; the profile's workflow set is exactly the five templates." "Remove the workflow."
  f structure.comment-redundant LOW main.tf 7 "The comment at line 7 restates the conditional on the next line." "Remove the comment."
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
    # Rule 7 boxes only the maintainer's item for a workflow that never started a job.
    7) jq -e 'all(.[]; .severity == "LOW")' "$O/findings.json" > /dev/null && ! todo | grep '^- \[ \] ' | grep -qv '^- \[ \] Maintainer: approve or re-run ' ;;
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
ladder "a CRITICAL compat break alone" "hold for the next major COMMENT" 0 "$(pair compat.type-narrowed CRITICAL structure.grouping MEDIUM)"
ladder "a CRITICAL compat break and a HIGH non-compat finding" "block REQUEST_CHANGES" 1 "$(pair compat.type-narrowed CRITICAL structure.docs-contradict-code HIGH)"
ladder "a HIGH compat break alone" "block REQUEST_CHANGES" 2 "$(one compat.variable-removed HIGH a.tf 1 "S." "F.")"
# compat.claim-contradicts-analysis sits one band below the compat.* code finding that refutes its
# claim: HIGH only beside a CRITICAL one, which arms rule 0 itself.
ladder "a CRITICAL compat break and the HIGH description finding it refutes" "hold for the next major COMMENT" 0 "$(pair compat.type-narrowed CRITICAL compat.claim-contradicts-analysis HIGH)"
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
# A rule that is no row of the reviewer's rule-facts.md is an unknown at rule 4 at any severity
# (verdict.md): kept in section 4 and findings.json, named in section 5, never read at rules 0 to 2, 6 or 7.
UNREG='- `structure.third-party-promotion` at `a.tf:3`: rule not in the registry, so this MEDIUM finding does not decide the verdict.'
ladder "an unregistered rule at MEDIUM" "inconclusive COMMENT" 4 "$(one structure.third-party-promotion MEDIUM a.tf 3 "S." "F.")"
t_unreg_lines() {
  grep -qxF -- "$UNREG" "$O/comment.md" &&
    grep -qxF -- "$(jq -nr -L "$REF" 'include "render-comment"; texts["rationale-4-unregistered"]')" "$O/comment.md" &&
    grep -qxF -- '- `structure.third-party-promotion` - `a.tf:3` - S.' "$O/comment.md" &&
    jq -e 'map(.rule_id) == ["structure.third-party-promotion"]' "$O/findings.json" > /dev/null
}
t_unreg_lines; check "unregistered rule: section 5 names it, the rationale says why, section 4 and findings.json keep it" $?
ladder "an unregistered rule at HIGH" "inconclusive COMMENT" 4 "$(one structure.third-party-promotion HIGH a.tf 3 "S." "F.")"
grep -qxF -- "${UNREG/MEDIUM/HIGH}" "$O/comment.md"; check "unregistered rule: the HIGH line names the rule" $?
ladder "an unregistered compat rule at CRITICAL" "inconclusive COMMENT" 4 "$(one compat.made-up-break CRITICAL a.tf 3 "S." "F.")"
ladder "a registry HIGH beside an unregistered MEDIUM" "block REQUEST_CHANGES" 2 "$(pair structure.docs-contradict-code HIGH structure.third-party-promotion MEDIUM)"
ladder "a registry MEDIUM" "block REQUEST_CHANGES" 6 "$(one structure.grouping MEDIUM a.tf 3 "S." "F.")"
t_no_registry() {
  local d="$TMP/lone" keep="$RCU"; mkdir -p "$d"
  cp "$REF/render-comment.sh" "$REF/render-comment.jq" "$REF/host-records.jq" "$REF/host-pass.sh" "$d/"
  RCU="$d/render-comment.sh"; render "$NONE"; RCU="$keep"
  [ "$ST" = 2 ] && empty_out && printf '%s' "$MSG" | grep -qF "the rule registry, the reviewer's rule-facts.md"
}
t_no_registry; check "unregistered rule: a render with no rule registry beside it is refused" $?
# At LOW an unregistered rule counts as any LOW finding: approve with nits, listed in section 5.
UNREG_L='- `structure.third-party-promotion` at `a.tf:3`: rule not in the registry; this LOW finding counts as any LOW finding.'
t_unreg_low() { render "$(one structure.third-party-promotion LOW a.tf 3 "S." "F.")"; [ "$(rule)" = 7 ] && grep -qxF -- "$UNREG_L" "$O/comment.md"; }
ladder "an unregistered rule at LOW" "approve with nits COMMENT" 7 "$(one structure.third-party-promotion LOW a.tf 3 "S." "F.")"
grep -qxF -- "$UNREG_L" "$O/comment.md"; check "unregistered rule: the LOW line names the rule and counts it as a LOW" $?
grep -qF 'Optional: `structure.third-party-promotion`' "$O/comment.md"; check "unregistered rule: a LOW is an optional item of What to do" $?
ladder "an unregistered LOW beside a registry MEDIUM" "block REQUEST_CHANGES" 6 "$(pair structure.grouping MEDIUM structure.third-party-promotion LOW)"
# A registry MEDIUM beside an unregistered one: the ladder reads only the registry finding, a known
# MEDIUM blocker, so rule 6 stands above the rule 4 unknown; the unregistered rule is never a
# blocking item of What to do.
ladder "a registry MEDIUM beside an unregistered MEDIUM" "block REQUEST_CHANGES" 6 "$(pair structure.grouping MEDIUM structure.third-party-promotion MEDIUM)"
UNREG_B='- `structure.third-party-promotion` at `b.tf:2`: rule not in the registry, so this MEDIUM finding does not decide the verdict.'
t_unreg_todo() { ! grep -qF -- '- [ ] `structure.third-party-promotion`' "$O/comment.md" && grep -qxF -- "$UNREG_B" "$O/comment.md"; }
t_unreg_todo; check "unregistered rule: beside a registry MEDIUM it is no blocking item, and section 5 names it" $?
t_bad_registry() { # how: link | empty | fenced
  local m="$TMP/badreg-$1-$oc" keep="$RCU"; local d="$m/terraform-module-pr-review/references" rr="$m/terraform-module-reviewer/references"
  mkdir -p "$d" "$rr"; cp "$RCU" "$(dirname "$RCU")/render-comment.jq" "$REF/host-records.jq" "$REF/host-pass.sh" "$d/"
  case "$1" in
    link) cp "$RF" "$m/rf.md"; ln -s "$m/rf.md" "$rr/rule-facts.md" ;;
    empty) : > "$rr/rule-facts.md" ;;
    # rule rows outside the registry table: in a fence and in another table, no registry header
    fenced) printf '%s\n' '```' '| `structure.grouping` | none |' '```' '' '| Pair | Kept |' '| `structure.grouping` | x |' > "$rr/rule-facts.md" ;;
  esac
  RCU="$d/render-comment.sh"; render "$(one structure.grouping MEDIUM a.tf 1 "S." "F.")"; RCU="$keep"
  [ "$ST" = 2 ] && empty_out && printf '%s' "$MSG" | grep -qF "the rule registry, the reviewer's rule-facts.md"
}
t_bad_link() { t_bad_registry link; }
t_bad_empty() { t_bad_registry empty; }
t_bad_fenced() { t_bad_registry fenced; }
t_bad_link; check "unregistered rule: a registry that is a symbolic link is refused" $?
t_bad_empty; check "unregistered rule: an empty registry is refused" $?
t_bad_fenced; check "unregistered rule: rows outside the registry table register nothing, so the render is refused" $?
# host-pass.sh accept checks the rendered verdict with host_verdict after any prior: the same
# registry rule, read from the same rule-facts.md, so an unregistered HIGH or CRITICAL passes.
PRIOR="$TMP/prior-full"; mkdir -p "$PRIOR"
jq -n --arg h "$HEAD" '{format: 1, mode: "full", reason: "no-record", head: $h, previous_head: null,
  previous_merge_base: null, depth: 0, last_full: "2026-11-14T00:00:00Z", scope: [],
  metrics: {changed_since: 0, changed_total: 0, commits: 0, pages: 0}}' > "$PRIOR/meta.json"
for x in carried carried-task scope-task; do echo '[]' > "$PRIOR/$x.json"; done
HPA="$REF/host-pass.sh"
accept() { bash "$HPA" accept --prior "$PRIOR" --findings "$O/findings.json" --result "$1" --rules "${2:-$RF}"; }
t_accept() { # severity [rule] -> the render accepted by host-pass.sh accept
  render "$(one "${2:-structure.third-party-promotion}" "$1" a.tf 3 "S." "F.")"
  [ "$ST" = 0 ] && [ "$(accept "$O/result.json")" = "findings accepted: full" ]
}
t_accept_high() { t_accept HIGH; }
t_accept_crit() { t_accept CRITICAL compat.made-up-break; }
t_accept_high; check "accept: a render with an unregistered HIGH is accepted after a prior" $?
t_accept_crit; check "accept: a render with an unregistered compat CRITICAL is accepted after a prior" $?
t_accept MEDIUM structure.grouping; check "accept: a render with a registry MEDIUM is still accepted" $?
t_accept_low() { t_accept LOW && [ "$(jq -r .verdict "$O/result.json")" = "approve with nits" ]; }
t_accept_low; check "accept: a render with an unregistered LOW, approve with nits, is accepted after a prior" $?
t_accept_forged() { # an approval beside an unregistered HIGH does not follow from the findings
  render "$(one structure.third-party-promotion HIGH a.tf 3 "S." "F.")"
  jq '.verdict = "approve"' "$O/result.json" > "$TMP/forged.json" &&
    [ "$(accept "$TMP/forged.json")" = "findings rejected: the verdict does not follow from the findings" ]
}
t_accept_forged; check "accept: approve beside an unregistered HIGH is rejected" $?
t_accept_norules() {
  render "$NONE"; printf 'no table\n' > "$TMP/norules.md"
  [ "$(accept "$O/result.json" "$TMP/norules.md")" = "findings rejected: the rule facts file holds no rule" ]
}
t_accept_norules; check "accept: a rules file with no registry row is rejected" $?
# After an incremental prior accept checks the verdict first (host-pass.md, Incremental Review).
IPRIOR="$TMP/prior-inc"; mkdir -p "$IPRIOR"
jq -n --arg h "$HEAD" --arg b "$BASE" '{format: 1, mode: "incremental", reason: "ok", head: $h,
  previous_head: $b, previous_merge_base: $b, depth: 1, last_full: "2026-11-14T00:00:00Z", scope: ["main.tf"],
  metrics: {changed_since: 1, changed_total: 1, commits: 1, pages: 1}}' > "$IPRIOR/meta.json"
CARRIED='{"file": "outside.tf", "line": 1, "rule_id": "structure.missing-description", "severity": "LOW", "summary": "S.", "suggested_fix": "F."}'
printf '[%s]\n' "$CARRIED" > "$IPRIOR/carried.json"; cp "$IPRIOR/carried.json" "$IPRIOR/carried-task.json"
echo '["main.tf"]' > "$IPRIOR/scope-task.json"
inc() { # verdict, findings as JSON objects without id -> the accept line
  printf '%s\n' "${@:2}" | jq -s 'to_entries | map(.value + {id: ("F-00\(.key + 1)")})' > "$TMP/inc-f.json"
  jq -n --arg h "$HEAD" --arg v "$1" '{head_sha: $h, verdict: $v}' > "$TMP/inc-r.json"
  bash "$HPA" accept --prior "$IPRIOR" --findings "$TMP/inc-f.json" --result "$TMP/inc-r.json" --rules "$RF"
}
INSCOPE='{"file": "main.tf", "line": 2, "rule_id": "structure.missing-description", "severity": "LOW", "summary": "T.", "suggested_fix": "G."}'
t_inc_verdict() { [ "$(inc approve "$CARRIED" "$INSCOPE")" = "findings rejected: the verdict does not follow from the findings" ]; }
t_inc_verdict; check "accept incremental: an approval beside LOW findings is rejected" $?
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
ladder "an example ended by the environment" "inconclusive COMMENT" 4 "$NONE" "" "" \
  "$(runf cov-env '.coverage = {class: "partial", inert: false, unplanned: [{dir: "examples/d", reason: "environment (access-denied)"}]}')"
grep -A3 -xF '### Checks that could not run' "$O/comment.md" | tail -n 2 | cmp -s - <(printf '%s\n' '- 1 example was not planned: environment (access-denied).' '  - `examples/d`')
check "coverage: an environment class renders with its fixed reason token" $?
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
{ f review.verification-incomplete MEDIUM a.tf 1 "M." "F."
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
LT='Write short: a `summary` of at most 200 characters and a `suggested_fix` of at most 250, or at most 600 for a `needs decision:` fix, one clause per option. The hard caps stay 500 and 600. A finding over the short targets is valid; the comment then renders in STANDARD.'
t_targets_stated() {
  awk '/^## Length Targets$/ { on = 1; next } on && /^## / { exit } on' \
    "$SRC/.agents/skills/terraform-module-reviewer/references/findings-schema.md" | grep -qF -- "$LT" &&
    awk '/^## Handover$/ { on = 1; next } on && /^## / { exit } on' "$REF/github-io.md" | grep -F -- "$LT" > /dev/null
}
t_targets_stated; check "strings: the length targets are stated in the findings schema and the handover" $?
# Text over a COMPACT cap renders STANDARD, never a refusal: the script prints the fallback line,
# and SKILL.md Step 10, the handover and Tiers state it.
FALLBACK='rendered STANDARD, over the COMPACT limits:'
t_fallback_stated() {
  grep -qF -- '"rendered STANDARD, \(.)"' "$RCU" &&
    grep -F -- '- **Step 10 - Render.**' "$STEPS" | grep -qF -- "\`$FALLBACK" &&
    awk '/^## Handover$/ { on = 1; next } on && /^## / { exit } on' "$REF/github-io.md" | grep -F -- "\`$FALLBACK" > /dev/null &&
    awk '/^## Tiers$/ { on = 1; next } on && /^## / { exit } on' "$CF" | grep -qF -- "\`$FALLBACK"
}
t_fallback_stated; check "strings: the COMPACT fallback line is stated in SKILL.md Step 10, the handover and Tiers" $?

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

# --- Location links (comment-format.md, Location links): --links turns each location into a link to
# the file at the head; without it the location stays a plain code span.

LINKF="$(one structure.grouping LOW sub/a.tf 12 'Summary.' 'Fix.')"
render "$LINKF"
check "links: off by default, the location is a plain code span" "$(grep -qF -- '- `structure.grouping` - `sub/a.tf:12` - Summary.' "$O/comment.md"; echo $?)"
render "$LINKF" "" "" "" "" --links
check "links: --links links a location to the file and line at the head" "$([ "$ST" = 0 ] && grep -qF -- "[\`sub/a.tf:12\`](https://github.com/example/terraform-aws-thing/blob/$HEAD/sub/a.tf#L12)" "$O/comment.md"; echo $?)"
render "$(one structure.grouping LOW sub/a.tf null 'Summary.' 'Fix.')" "" "" "" "" --links
check "links: a finding with no line links to the file without a fragment" "$(grep -qF -- "[\`sub/a.tf\`](https://github.com/example/terraform-aws-thing/blob/$HEAD/sub/a.tf)" "$O/comment.md"; echo $?)"
render "$(one structure.grouping LOW 'sub/a b.tf' 3 'Summary.' 'Fix.')" "" "" "" "" --links
check "links: a path outside the allowed set stays a plain code span" "$(grep -qF -- '`sub/a b.tf:3`' "$O/comment.md" && ! grep -qF -- 'blob/' "$O/comment.md"; echo $?)"
render "$(one structure.grouping LOW . null 'Summary.' 'Fix.')" "" "" "" "" --links
check "links: the module root stays a plain code span" "$(grep -qF -- '- `structure.grouping` - `.` - Summary.' "$O/comment.md" && ! grep -qF -- 'blob/' "$O/comment.md"; echo $?)"
render "$LINKF" "$(host badrepo '.repo = "a b/c"')" "" "" "" --links
check "links: a repository outside owner/name is refused by the host.json check" "$([ "$ST" = 2 ] && printf "%s" "$MSG" | grep -qF "host.json is not valid"; echo $?)"

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
refused "a bare environment reason" "$G" "" "" "$(runf cov-bad4 '.coverage = {class: "none", inert: false, unplanned: [{dir: "examples/a", reason: "environment"}]}')"
refused "an environment reason with text of its own" "$G" "" "" "$(runf cov-bad5 '.coverage = {class: "none", inert: false, unplanned: [{dir: "examples/a", reason: "environment (AccessDenied for x)"}]}')"
refused "a run file without coverage" "$G" "" "" "$(runf cov-bad3 'del(.coverage)')"
refused "a run file with an unknown reason" "$G" "" "" "$(runf badreason '.verify_gaps = [{dir: "examples/a", reason: "flaky"}]')"
refused "a run file with an extra key" "$G" "" "" "$(runf extra '.extra = true')"
refused "a run file with a negative count" "$G" "" "" "$(runf neg '.counts["conversation-claims-unread"] = -1')"
t_partial_counts() { render "$G" "" "" "$(runf partial 'del(.counts["conversation-claims-unread"])')"; [ "$ST" = 2 ] && empty_out; }
t_partial_counts; check "refused: a run file with a count missing" $?
refused "a run file with empty counts" "$G" "" "" "$(runf emptycounts '.counts = {}')"

# --- The review budget (review-run-details.md, Review Budget): the changed files the reviewer was not
# handed are a rule 4 unknown, never an approval, listed in section 5 as data, the first 100 by name.
SKIPPED='["modules/a/main.tf", "wrappers/a/main.tf"]'
t_skipped() {
  render "$(one structure.grouping LOW a.tf 1 "S." "F.")" "" "" "$(runf skipped ".skipped_files = $SKIPPED")"
  [ "$ST" = 0 ] && [ "$(verdict)" = "inconclusive COMMENT" ] && [ "$(rule)" = 4 ] &&
    grep -qxF -- "$(jq -nr -L "$(dirname "$RCU")" 'include "render-comment"; texts["rationale-4-skipped"]')" "$O/comment.md" &&
    awk '/^### Checks that could not run$/ { on = 1; next } on && /^### / { exit } on' "$O/comment.md" |
      cmp -s - <(printf '%s\n' '' '- 2 changed files were over the review budget and were not reviewed:' '  - `modules/`: 1 file' '    - `modules/a/main.tf`' '  - `wrappers/`: 1 file' '    - `wrappers/a/main.tf`')
}
t_skipped; check "budget: skipped files with a LOW finding are inconclusive at rule 4, section 5 golden" $?
# Beside an unread thread resolution, the What to do section counts the list as one gap.
render "$(one structure.grouping LOW a.tf 1 "S." "F.")" "$(host skipped-tu '.signals.threads = "unknown"')" "" "$TMP/run-skipped.json"
check "budget: the skipped list counts once among the gaps of What to do" "$([ "$ST" = 0 ] && grep -qxF -- '- 1 check could not run; see Checks that could not run.' "$O/comment.md"; echo $?)"
# Beside a cause of the COMPACT table, no AWS profile named, the skipped files are a cause outside it:
# the body is STANDARD and section 5 lists them. Without them the same run is COMPACT.
NOPLAN='.examples = {count: 1, skipped: 0, validated: 1} | .coverage = {class: "none", inert: false, unplanned: [{dir: "examples/a", reason: "no AWS profile named"}]}'
t_skipped_clean() { render "$NONE" "" "" "$(runf skipped-clean "$NOPLAN | .skipped_files = $SKIPPED")"
  [ "$ST" = 0 ] && [ "$(rule)" = 4 ] && printf '%s' "$MSG" | grep -q ', tier STANDARD$' && grep -qxF '    - `wrappers/a/main.tf`' "$O/comment.md"; }
render "$NONE" "" "" "$(runf noplan-compact "$NOPLAN")"
check "budget: the control run without skipped files is COMPACT" "$([ "$ST" = 0 ] && printf '%s' "$MSG" | grep -q ', tier COMPACT$'; echo $?)"
t_skipped_clean; check "budget: skipped files beside a COMPACT cause are inconclusive and STANDARD" $?
render "$NONE" "" "" "$(runf skipped-hostile '.skipped_files = ["a b.tf", "$(touch x).tf", "@user.tf", "c\\d.tf", "ok.tf"]')"
check "budget: a skipped name outside the allowlist, a backslash included, is withheld, never a bare mention" "$([ "$ST" = 0 ] && [ "$(grep -cxF '    - name withheld' "$O/comment.md")" = 4 ] && grep -qxF '    - `ok.tf`' "$O/comment.md" && grep -qxF '  - the module root: 5 files' "$O/comment.md" && ! grep -qF '@user' "$O/comment.md"; echo $?)"
render "$NONE" "" "" "$(runf skipped-many '.skipped_files = [range(130) | "f\(.).tf"]')"
check "budget: 130 skipped files list the first 100 and the count of the rest" "$([ "$ST" = 0 ] && [ "$(grep -c '^    - `f[0-9]*\.tf`$' "$O/comment.md")" = 100 ] && grep -qxF -- '- 130 changed files were over the review budget and were not reviewed:' "$O/comment.md" && grep -qxF -- '    - and 30 more.' "$O/comment.md"; echo $?)"
# By top-level directory: 22 directories of 6 files; 20 shown, the 100 names going round them, so
# each shows 5 and the count of its last; the files of the other two are counted.
t_skipped_groups() {
  render "$NONE" "" "" "$(runf skipped-groups '.skipped_files = [range(22) as $d | range(6) as $i | "d\($d + 10)/f\($i).tf"]')"
  [ "$ST" = 0 ] && [ "$(grep -c '^  - `d[0-9]*/`: 6 files$' "$O/comment.md")" = 20 ] &&
    [ "$(grep -c '^    - `d[0-9]*/f[0-9]\.tf`$' "$O/comment.md")" = 100 ] && [ "$(grep -cxF '    - and 1 more.' "$O/comment.md")" = 20 ] &&
    grep -qxF '    - `d29/f4.tf`' "$O/comment.md" && ! grep -qF 'd30/' "$O/comment.md" &&
    grep -qxF -- '  - 12 more files in other top-level directories.' "$O/comment.md"
}
# At most 100 files: every directory and every file named, past 20 directories too.
render "$NONE" "" "" "$(runf skipped-dirs '.skipped_files = [range(25) | "d\(. + 10)/f.tf"]')"
check "budget: 25 skipped files in 25 directories are all named" \
  "$([ "$ST" = 0 ] && [ "$(grep -c '^  - `d[0-9]*/`: 1 file$' "$O/comment.md")" = 25 ] && [ "$(grep -c '^    - `d[0-9]*/f\.tf`$' "$O/comment.md")" = 25 ] &&
     ! grep -qF 'other top-level directories' "$O/comment.md"; echo $?)"
t_skipped_groups; check "budget: the skipped list by top-level directory, 20 shown with a count each, the 100 names going round them" $?
# Past 20 directories the files outside the module root keep their own line, after the count of the rest.
t_skipped_outside_cap() {
  render "$NONE" "$(host skipped-ocap '.prefix = "m/x"')" "" "$(runf skipped-ocap '.skipped_files = ([range(25) as $d | range(5) as $i | "m/x/d\($d + 10)/f\($i).tf"] + ["m/x/main.tf", ".github/workflows/release.yml", "m/y/main.tf"])')"
  [ "$ST" = 0 ] && awk '/^### Checks that could not run$/ { on = 1; next } on && /^### / { exit } on' "$O/comment.md" | grep -v '^$' | tail -n 4 |
    cmp -s - <(printf '%s\n' '  - 30 more files in other top-level directories.' '  - outside the module root: 2 files' '    - `.github/workflows/release.yml`' '    - `m/y/main.tf`')
}
t_skipped_outside_cap; check "budget: past 20 directories the files outside the module root keep their own line" $?
render "$NONE" "$(host skipped-prefix '.prefix = "modules/x"')" "" "$(runf skipped-prefix '.skipped_files = ["sub/b.tf", "modules/x/sub/a.tf", "modules/x/main.tf"]')"
t_skipped_prefix() { render "$NONE" "$(host skipped-prefix '.prefix = "modules/x"')" "" "$TMP/run-skipped-prefix.json"
  awk '/^### Checks that could not run$/ { on = 1; next } on && /^### / { exit } on' "$O/comment.md" |
    cmp -s - <(printf '%s\n' '' '- 3 changed files were over the review budget and were not reviewed:' '  - the module root: 1 file' '    - `modules/x/main.tf`' '  - `sub/`: 1 file' '    - `modules/x/sub/a.tf`' '  - outside the module root: 1 file' '    - `sub/b.tf`'); }
check "budget: with a module root prefix the directories are under the module root, its own files first, a file outside it in its own group last" \
  "$([ "$ST" = 0 ] && awk '/^### Checks that could not run$/ { on = 1; next } on && /^### / { exit } on' "$O/comment.md" |
     cmp -s - <(printf '%s\n' '' '- 3 changed files were over the review budget and were not reviewed:' '  - the module root: 1 file' '    - `modules/x/main.tf`' '  - `sub/`: 1 file' '    - `modules/x/sub/a.tf`' '  - outside the module root: 1 file' '    - `sub/b.tf`'); echo $?)"
ladder "a known MEDIUM beside skipped files still blocks" "block REQUEST_CHANGES" 6 "$(one structure.grouping MEDIUM a.tf 1 "S." "F.")" "" "" "$TMP/run-skipped.json"
refused "a run file with an empty skipped list" "$G" "" "" "$(runf skipped-empty '.skipped_files = []')"
refused "a run file with a skipped path that is not plain" "$G" "" "" "$(runf skipped-ctl '.skipped_files = ["a\nb.tf"]')"
refused "a run file with a skipped path twice" "$G" "" "" "$(runf skipped-dup '.skipped_files = ["a.tf", "a.tf"]')"
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
render "$({ f structure.grouping LOW a.tf 4 "S." "F."; f structure.grouping LOW a.tf 4 "T." "G."; } | list wt-r7d)"
todo_is "rule 7, two findings at one location name it once" '### What to do' '' "$LEAD_7" '' \
  '- Optional: `structure.grouping` (2) at `a.tf:4`.'
R0="$({ f compat.type-narrowed CRITICAL a.tf 1 "S." "F. Generated content made stale: the terraform-docs region of README.md."
  f compat.type-narrowed CRITICAL b.tf 2 "T." "G."; f compat.variable-removed HIGH c.tf null "U." "H."
  f structure.grouping LOW d.tf 4 "V." "I."; } | list wt-r0)"
render "$R0"
todo_is "rule 0, the groups as plain bullets and item e a bullet" '### What to do' '' "$LEAD_0" '' \
  '- `compat.type-narrowed` (2): the Fixes at `a.tf:1`, `b.tf:2` are one way to restore compatibility; see Findings.' \
  '- `compat.variable-removed`: the Fix at `c.tf` is one way to restore compatibility; see Findings.' '- Optional: `structure.grouping` at `d.tf:4`.' "- $GEN"
render "$R0" "" "$(checks wt-r0 fail)"
todo_is "rule 0 with a failing check, which makes item e a checkbox" '### What to do' '' "$LEAD_0" '' '- [ ] Fix the failing checks.' \
  '- `compat.type-narrowed` (2): the Fixes at `a.tf:1`, `b.tf:2` are one way to restore compatibility; see Findings.' \
  '- `compat.variable-removed`: the Fix at `c.tf` is one way to restore compatibility; see Findings.' '- Optional: `structure.grouping` at `d.tf:4`.' "- [ ] $GEN"
R0M="$(jq '. + [{id: "F-900", rule_id: "structure.flag-polarity", severity: "MEDIUM", file: "e.tf", line: 5, summary: "W.", suggested_fix: "J.", source: "llm"}]' "$TMP/wt-r0.json" > "$TMP/wt-r0m.json"; echo "$TMP/wt-r0m.json")"
render "$R0M"
todo_is "rule 0, a MEDIUM non-compat group is a checkbox and makes item e one" '### What to do' '' "$LEAD_0" '' \
  '- `compat.type-narrowed` (2): the Fixes at `a.tf:1`, `b.tf:2` are one way to restore compatibility; see Findings.' \
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
  render "$({ f scope.boundary MEDIUM . null "S." "F."; f structure.grouping MEDIUM b.tf 2 "T." "G."; } | list wt-root1)"
}
t_root_one
todo_is "a blocking finding at the module root takes the fixed item" '### What to do' '' "$LEAD_BLOCK" '' \
  '- [ ] Resolve `scope.boundary`: see its Fix under Findings.' '- [ ] `structure.grouping`: apply the Fix at `b.tf:2`.'
render "$({ f scope.boundary HIGH . null "S." "F."; f scope.boundary HIGH . null "T." "G."; } | list wt-root2)"
todo_is "two blocking findings at the module root take the fixed item with the count" '### What to do' '' "$LEAD_BLOCK" '' \
  '- [ ] Resolve `scope.boundary` (2): see its Fixes under Findings.'
render "$(f scope.boundary MEDIUM . null "S." "F." | list wt-root3)" "$(host wt-root3 '.prefix = "modules/x"')"
todo_is "a module root finding under a module root prefix takes the fixed item" '### What to do' '' "$LEAD_BLOCK" '' \
  '- [ ] Resolve `scope.boundary`: see its Fix under Findings.'
t_root_rule0() {
  render "$({ f compat.type-narrowed CRITICAL a.tf 1 "S." "F."; f compat.claim-contradicts-analysis HIGH . null "T." "no code change: G."; } | list wt-root0)"
}
t_root_rule0
todo_is "rule 0, a description finding at the module root takes the fixed item" '### What to do' '' "$LEAD_0" '' \
  '- `compat.type-narrowed`: the Fix at `a.tf:1` is one way to restore compatibility; see Findings.' '- [ ] Resolve `compat.claim-contradicts-analysis`: see its Fix under Findings.'
render "$({ f scope.boundary MEDIUM . null "S." "F."; f scope.boundary MEDIUM a.tf 1 "T." "G."; } | list wt-root4)"
todo_is "a group with a real location keeps its locations" '### What to do' '' "$LEAD_BLOCK" '' \
  '- [ ] `scope.boundary` (2): apply the Fix at `.`, `a.tf:1`.'

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
  jq -e -n -L "$REF" --arg s "$(printf 'Two\nlines.')" 'include "render-comment";
    [{id: "F-001", rule_id: "structure.grouping", severity: "LOW", file: "a.tf", line: 1, summary: "A.", suggested_fix: "F1."},
     {id: "F-002", rule_id: "structure.grouping", severity: "LOW", file: "b.tf", line: 1, summary: "B.", suggested_fix: "F2."},
     {id: "F-003", rule_id: "structure.grouping", severity: "LOW", file: "c.tf", line: 1, summary: $s, suggested_fix: "F3."}]
    | findings_md(7; 10; "") | (contains("Fix for each location") | not) and contains("    - Fix: F3.")' > /dev/null
}
t_newline; check "fix block: a newline in a summary renders unfolded" $?

# The leak scan and the at-mention step reach the new section.
t_leak_todo() {
  render "$(f structure.grouping MEDIUM a.tf 1 "S." "F." | list wt-leak)" "$(host wt-leak '.prefix = "x/home/y"')"
  [ "$ST" = 1 ] && empty_out && printf '%s' "$MSG" | grep -qF 'leak scan: /home/ in the host records' &&
  jq -e -n -L "$REF" --slurpfile f "$TMP/wt-leak.json" --slurpfile h "$TMP/host-wt-leak.json" --slurpfile r "$RUNF" \
    --argjson reg "$REGISTRY" '
    include "render-comment";
    render({findings: $f[0], host: $h[0], run: $r[0], assessment: "A.", registry: $reg,
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
  # The copies sit as the skill does, with the reviewer's rule registry beside them.
  local d="$TMP/mut-$oc/terraform-module-pr-review/references" rr="$TMP/mut-$oc/terraform-module-reviewer/references"
  mkdir -p "$d" "$rr"; cp "$REF/render-comment.sh" "$REF/render-comment.jq" "$REF/host-records.jq" "$REF/host-pass.sh" "$d/"
  cp "$RF" "$rr/"
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
t_unreg() { render "$(one structure.third-party-promotion HIGH a.tf 3 "S." "F.")"; [ "$(rule)" = 4 ] && grep -qxF -- "${UNREG/MEDIUM/HIGH}" "$O/comment.md"; }
mutate "unregistered rules read by the ladder" 's/\(\$in\.findings \| map\(select\(ladder_read\(\$in\.registry\)\)\)\) as \$known/\$in.findings as \$known/' t_unreg
mutate "an unregistered LOW held as an unknown" 's/def ladder_read\(\$reg\): registered\(\$reg\) or \.severity == "LOW";/def ladder_read(\$reg): registered(\$reg);/' t_unreg_low
mutate "the unregistered line dropped from section 5" 's/\[\$unreg_all\[\] \| tx\(/[empty | tx(/' t_unreg
mutate "skipped files not counted as gaps" 's/\(\$in\.run \| skipped_gap\) \+ //' t_skipped
mutate "skipped files dropped from section 5" 's/\+ skipped_lines\(\$in\.run; \$p\); /; /' t_skipped
mutate "the skipped names not taken round the directories" 's/sort_by\(\.i, \.gi\)/sort_by(.gi, .i)/' t_skipped_groups
mutate "the 20 directory cap moved" 's/else \$inner\[:20\] end/else \$inner[:21] end/' t_skipped_groups
mutate "the files of the directories past the cap not counted" 's/if \. > 0 then \[tx\("skipped-groups-more"/if false then [tx("skipped-groups-more"/' t_skipped_groups
mutate "the module root not first" 's/else \[0, null\] end end/else [3, null] end end/' t_skipped_prefix
mutate "the files outside the module root cut with the directories past 20" 's/\| \(\$kept \+ \[\$groups\[\] \| select\(\.\[0\]\.g\[0\] == 2\)\]\) as \$shown/| \$kept as \$shown/' t_skipped_outside_cap
mutate "a file outside the module root grouped by its own first directory" 's/then \[2, null\]/then [1, (split("\/")[0])]/' t_skipped_prefix
mutate "the classifier cap not counted" 's/\+ \(if \.capped > 0 then 1 else 0 end\) end;/+ 0 end;/' t_capped_alone
mutate "the classifier cap counted per change" 's/\+ \(if \.capped > 0 then 1 else 0 end\) end;/+ .capped end;/' t_capped
mutate "the classifier cap counted among the changes not verified" 's/unverifiable: n\(\$b\.triggers; "unverifiable"\),/unverifiable: (n(\$b.triggers; "unverifiable") + \$b.capped),/' t_capped
mutate "skipped files no cause outside the COMPACT table" 's/ or \$l\.skipped > 0\)\}/)}/' t_skipped_clean
mutate "unregistered rules not counted as gaps" 's/ \+ \(\$unreg \| length\) \+ \(\$in\.run/ + (\$in.run/' t_unreg
mutate "the registry read from every table row" 's/\| if \$h == null then \[\] else/| if true then [\$l[] | capture("^\\\\| `(?<id>" + rule_pat + ")` \\\\|") | .id] else/' t_bad_fenced
mutate_hp() { # name, perl substitution on host-pass.sh and incremental.jq, case function
  local d="$TMP/muthp-$oc/terraform-module-pr-review/references" keep="$HPA" before="$fails"; mkdir -p "$d"
  cp "$REF/host-pass.sh" "$REF/incremental.jq" "$REF/render-comment.jq" "$REF/host-records.jq" "$d/"
  perl -0pi -e "$2" "$d/host-pass.sh" "$d/incremental.jq"
  if cmp -s "$d/host-pass.sh" "$REF/host-pass.sh" && cmp -s "$d/incremental.jq" "$REF/incremental.jq"; then
    check "self-check: $1 (the mutation changed nothing)" 1; return
  fi
  HPA="$d/host-pass.sh"; "$3" > /dev/null 2>&1; local s=$?; HPA="$keep"; fails="$before"
  check "self-check: $1 is caught" "$([ "$s" != 0 ]; echo $?)"
}
mutate_hp "accept without the registry" 's/host_verdict\(\$v; \$reg\)/host_verdict(\$v)/' t_accept_high
mutate_hp "host_verdict reading unregistered rules" 's/map\(select\(\(\.rule_id \| IN\(\$reg\[\]\)\) or \.severity == "LOW"\)\) as \$k/. as \$k/' t_accept_crit
mutate_hp "host_verdict holding an unregistered LOW as an unknown" 's/ or \.severity == "LOW"\)\) as \$k/)) as \$k/' t_accept_low
mutate_hp "the verdict check skipped" 's/\|\|\n    reject "the verdict does not follow from the findings"/|| true/' t_inc_verdict
mutate_hp "the prior check run in the same shell" 's/\( check_prior "\$prior" "\$head" \)/check_prior "\$prior" "\$head"/' t_accept_forged
mutate "unplanned examples left out of the ladder" 's/ or \.unplanned_open > 0//' t_cov_rule
mutate "unplanned example names left out of section 5" 's/\| tx\("unplanned-name"; \{dir\}\)\]/| empty]/' t_cov_rule
t_rule0() { render "$(pair compat.type-narrowed CRITICAL structure.docs-contradict-code HIGH)"; [ "$(rule)" = 1 ]; }
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
t_rule0_plain() { render "$R0"; todo | grep -qxF -- '- `compat.type-narrowed` (2): the Fixes at `a.tf:1`, `b.tf:2` are one way to restore compatibility; see Findings.'; }
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
mutate "What to do rendered at rule 8" 's/if \$v\.rule == 8 or \$quiet or/if \$quiet or/' t_rule8_none
mutate "a quiet What to do rendered at rule 4" 's/if \$v\.rule == 8 or \$quiet or/if \$v.rule == 8 or/' t_quiet_other
mutate "the STANDARD action line dropped" 's/\(if \$quiet then action_line\(\$c\) else \[\] end\)/[]/' t_quiet_action
mutate "the action line beside a cause outside the table" 's/if \$c\.other or \$c\.admitted == \[\] then/if \$c.admitted == [] then/' t_quiet_other
mutate "the Optional items not quiet" 's/\{box: false, quiet: true, t: grp\("todo-optional"\)\}/{box: false, t: grp("todo-optional")}/' t_quiet_action
t_rule7_todo() { render "$G"; [ "$(rule)" = 7 ] && todo | grep -qxF "$LEAD_7"; }
mutate "What to do quiet at a rule other than 4" 's/\(\$v\.rule == 4 and all\(\$items\[\]; \.quiet\)\)/all(\$items[]; .quiet)/' t_rule7_todo
mutate "nine locations listed" 's/\$l\[:8\]/\$l[:9]/' t_loc9
mutate "rule 0 groups as checkboxes" 's/if \$rule == 0 and/if false and/' t_rule0_plain
mutate "the compat item says its Fix restores compatibility" 's/the Fixes at \{locations\} are one way to restore compatibility; see Findings\./the Fix at {locations} restores compatibility./' t_rule0_plain
t_compat_one() { render "$TMP/wt-root0.json"; todo | grep -qxF -- '- `compat.type-narrowed`: the Fix at `a.tf:1` is one way to restore compatibility; see Findings.'; }
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
grep -qxF 'Behaviour evidence: 2 changes classified: 0 verified, 0 covered by a plan, 0 inert, 0 refuted, 2 not verified; 1 claim: 0 verified, 0 refuted, 1 not verified.' "$O/comment.md"
check "behaviour: the evidence line follows the rationale" $?
awk 'p == "A check this review needs could not run, as listed below. Any unknown makes the review inconclusive (ladder rule 4)." && /^$/ { getline; print; exit } { p = $0 }' "$O/comment.md" | grep -q '^Behaviour evidence: '
check "behaviour: the evidence line is the paragraph after the rationale" $?
render "$LOWF" "" "" "$(brun one-uv "[$(bt T-001 wrapper-change verified)]" '[{claim_id: "C-1", state: "verified"}, {claim_id: "C-2", state: "unverifiable"}]')"
t_one_change() { render "$LOWF" "" "" "$(brun one-uv "[$(bt T-001 wrapper-change verified)]" '[{claim_id: "C-1", state: "verified"}, {claim_id: "C-2", state: "unverifiable"}]')"
  grep -qxF 'Behaviour evidence: 1 change classified: 1 verified, 0 covered by a plan, 0 inert, 0 refuted, 0 not verified; 2 claims: 1 verified, 0 refuted, 1 not verified.' "$O/comment.md"; }
t_one_change; check "behaviour: one unverified claim beside passing triggers keeps the evidence line, 1 change in the one form" $?
# The classifier cap: one cause, so one gap and one clause of the evidence line, however many changes.
t_capped() {
  render "$NONE" "$(host capped-tu '.signals.threads = "unknown"')" "" "$(brun capped "[$(bt T-001 wrapper-change covered)]" '[]' 10019)"
  [ "$ST" = 0 ] && [ "$(rule)" = 4 ] &&
    grep -qxF 'Behaviour evidence: 1 change classified: 0 verified, 1 covered by a plan, 0 inert, 0 refuted, 0 not verified; 0 claims: 0 verified, 0 refuted, 0 not verified. 10019 changes are over the classifier cap and were not classified, one unknown listed below.' "$O/comment.md" &&
    grep -qxF -- '- 10019 more behaviour changes over the classifier cap: not verified.' "$O/comment.md" &&
    grep -qxF -- '- 1 check could not run; see Checks that could not run.' "$O/comment.md"
}
t_capped; check "behaviour: the changes over the classifier cap reported once and counted as one gap" $?
# The cap alone holds rule 4, and every trigger capped reads with no "more" and the one forms.
t_capped_alone() { render "$NONE" "" "" "$(brun cap-alone "[$(bt T-001 wrapper-change covered)]" '[]' 3)"; [ "$ST" = 0 ] && [ "$(rule)" = 4 ]; }
t_capped_alone; check "behaviour: the classifier cap alone keeps the review inconclusive (rule 4)" $?
render "$NONE" "" "" "$(brun cap-one '[]' '[]' 1)"
check "behaviour: one change over the cap and nothing classified, in the one forms" \
  "$([ "$ST" = 0 ] && [ "$(rule)" = 4 ] && grep -qxF 'Behaviour evidence: 0 changes classified: 0 verified, 0 covered by a plan, 0 inert, 0 refuted, 0 not verified; 0 claims: 0 verified, 0 refuted, 0 not verified. 1 change is over the classifier cap and was not classified, one unknown listed below.' "$O/comment.md" &&
     grep -qxF -- '- 1 more behaviour change over the classifier cap: not verified.' "$O/comment.md"; echo $?)"
ladder "an inert change" "approve APPROVE" 8 "$NONE" "" "" "$(brun inert '[]' '[]')"
! grep -q 'Behaviour evidence' "$O/comment.md"; check "behaviour: nothing classified renders no evidence line" $?
# Triggers that all ended inert (a derived wrapper's among them) make the change inert for plan
# coverage (verdict.md, rule 4); any trigger or claim that is not, a cap, or a step that did not run
# keeps the coverage unknown. The one example here was not planned.
ci_run() { # name, triggers json, claims json [, capped] -> run file with one example not planned
  runf "ci-$1" ".plan_ran = true | .behaviour = {status: \"ran\", reason: null, triggers: $2, claims: $3, capped: ${4:-0}}
    | .coverage = {class: \"partial\", inert: false, unplanned: [{dir: \"examples/complete\", reason: \"environment (timeout)\"}]}"
}
CI_LINE='- 1 example was not planned: environment (timeout).'
TI2="[$(bt T-001 unclassified-change inert), $(bt T-002 unclassified-change inert)]"
t_ti_ok() {
  render "$NONE" "" "" "$(ci_run ok "$TI2" '[]')"
  [ "$ST" = 0 ] && [ "$(verdict)" = "approve APPROVE" ] && [ "$(rule)" = 8 ] &&
    awk '/^### Checks that could not run$/ { on = 1; next } on' "$O/comment.md" |
    cmp -s - <(printf '%s\n' '' "$(jq -nr -L "$(dirname "$RCU")" 'include "render-comment"; texts["unplanned-triggers-inert"]')" "$CI_LINE" '  - `examples/complete`')
}
t_ti_ok; check "inert triggers: every trigger inert leaves the unplanned example information, approve at rule 8" $?
t_ti_stays() { # name, triggers, claims, capped, expected rule
  render "$NONE" "" "" "$(ci_run "$1" "$2" "$3" "$4")"
  [ "$ST" = 0 ] && [ "$(rule)" = "$5" ] && grep -qxF -- "$CI_LINE" "$O/comment.md" && ! grep -qF 'Every behaviour change is inert' "$O/comment.md"
}
t_ti_mixed() { t_ti_stays mixed "[$(bt T-001 unclassified-change inert), $(bt T-002 wrapper-change verified)]" '[]' 0 4; }
t_ti_unver() { t_ti_stays unver "[$(bt T-001 unclassified-change inert), $(bt T-002 wrapper-change unverifiable)]" '[]' 0 4; }
t_ti_capped() { t_ti_stays capped "$TI2" '[]' 1 4; }
t_ti_claim() { t_ti_stays claim "$TI2" '[{claim_id: "C-1", state: "unverifiable"}]' 0 4; }
t_ti_none() { t_ti_stays none '[]' '[]' 0 4; }
t_ti_notrun() {
  render "$NONE" "" "" "$(runf ci-notrun '.plan_ran = true | .behaviour = {status: "not-run", reason: "mtf-facts failed", triggers: [], claims: [], capped: 0}
    | .coverage = {class: "partial", inert: false, unplanned: [{dir: "examples/complete", reason: "environment (timeout)"}]}')"
  [ "$ST" = 0 ] && [ "$(rule)" = 4 ] && grep -qxF -- "$CI_LINE" "$O/comment.md" && ! grep -qF 'Every behaviour change is inert' "$O/comment.md"
}
t_ti_nobeh() {
  render "$NONE" "" "" "$(runf ci-nobeh '.plan_ran = true | del(.behaviour)
    | .coverage = {class: "partial", inert: false, unplanned: [{dir: "examples/complete", reason: "environment (timeout)"}]}')"
  [ "$ST" = 0 ] && [ "$(rule)" = 4 ] && grep -qxF -- "$CI_LINE" "$O/comment.md" && ! grep -qF 'Every behaviour change is inert' "$O/comment.md"
}
t_ti_refuted() { render "$NONE" "" "" "$(ci_run refuted "[$(bt T-001 unclassified-change inert), $(bt T-002 wrapper-change refuted)]" '[]')"; [ "$ST" = 0 ] && [ "$(rule)" = 2 ]; }
t_ti_gap() { # another unknown keeps the coverage required: the example is listed as any unplanned example
  render "$NONE" "$(host tigap '.could_not_run = [{kind: "patch-unavailable", path: "main.tf"}]')" "" "$(ci_run gap "$TI2" '[]')"
  [ "$ST" = 0 ] && [ "$(rule)" = 4 ] && grep -qxF -- "$CI_LINE" "$O/comment.md" && ! grep -qF 'Every behaviour change is inert' "$O/comment.md"
}
t_ti_vgap() {
  local r; r="$(ci_run vgap "$TI2" '[]')"; jq '.verify_gaps = [{dir: "examples/other", reason: "init failed"}]' "$r" > "$r.2"
  render "$NONE" "" "" "$r.2"
  [ "$ST" = 0 ] && [ "$(rule)" = 4 ] && grep -qxF -- "$CI_LINE" "$O/comment.md" && ! grep -qF 'Every behaviour change is inert' "$O/comment.md"
}
t_ti_signal() {
  render "$NONE" "$(host tisig '.signals.mergeability = "unknown"')" "" "$(ci_run sig "$TI2" '[]')"
  [ "$ST" = 0 ] && [ "$(rule)" = 4 ] && grep -qxF -- "$CI_LINE" "$O/comment.md" && ! grep -qF 'Every behaviour change is inert' "$O/comment.md"
}
t_ti_precedence() { # a change the classifier calls inert keeps its own line
  render "$NONE" "" "" "$(runf ci-prec ".plan_ran = true | .behaviour = {status: \"ran\", reason: null, triggers: $TI2, claims: [], capped: 0}
    | .coverage = {class: \"none\", inert: true, unplanned: [{dir: \"examples/complete\", reason: \"no AWS profile named\"}]}")"
  [ "$ST" = 0 ] && [ "$(rule)" = 8 ] && grep -qF 'reaches no Terraform configuration' "$O/comment.md" && ! grep -qF 'Every behaviour change is inert' "$O/comment.md"
}
t_ti_compact() { # COMPACT: the evidence line names the example, its reason and the inert reading
  render "$NONE" "" "" "$(ci_run cmp "$TI2" '[]' | xargs -I{} jq '.plan_mode = "laptop" | .examples = {count: 3, skipped: 0, validated: 3}' {} > "$TMP/run-ci-cmp2.json"; echo "$TMP/run-ci-cmp2.json")"
  [ "$ST" = 0 ] && [ "$(rule)" = 8 ] && [ "$(printf '%s' "$MSG" | sed -n 's/^rendered .*, tier \([A-Z]*\)$/\1/p')" = COMPACT ] &&
    cmp -s "$O/comment.md" <(printf '%s\n' 'The change looks right.' '' '**Good to merge.** `validate` passed in all 3 examples; 2 were planned.' '' \
      '<details><summary>Evidence and notes</summary>' '' '- Not planned: `examples/complete` (environment (timeout)). Every behaviour change is inert, so no plan was needed.' '</details>')
}
t_ti_covered() { # a gate skip covered by a witness is not needed beside inert triggers: rule 8, no covered line
  local r; r="$(ci_run cov "$TI2" '[]')"
  jq --arg h "$HEAD" --arg b "$BASE" '.plan_mode = "laptop" | .examples = {count: 3, skipped: 0, validated: 3}
    | .coverage = {class: "partial", inert: false, unplanned: [{dir: "examples/mysql", reason: "plan gate G3"}],
        covered_skips: [{dir: "examples/mysql", gate: "G3", path: "main.tf",
          witnesses: [{attribute: "x", example: "examples/autoscaling", address: "aws_x.this"}]}], skip_head_sha: $h, skip_base_sha: $b}' "$r" > "$r.2"
  render "$NONE" "" "" "$r.2"
  [ "$ST" = 0 ] && [ "$(rule)" = 8 ] && [ "$(verdict)" = "approve APPROVE" ] && ! grep -qF 'Covered by' "$O/comment.md" && ! grep -qF 'plan gate G3 hit' "$O/comment.md"
}
t_ti_noexdir() { # no example directory: no line saying the examples below leave nothing unknown
  render "$NONE" "" "" "$(runf ci-noex ".plan_ran = true | .behaviour = {status: \"ran\", reason: null, triggers: $TI2, claims: [], capped: 0}
    | .coverage = {class: \"none\", inert: false, unplanned: [{dir: \"examples\", reason: \"no example directory\"}]}")"
  [ "$ST" = 0 ] && [ "$(rule)" = 8 ] && ! grep -qF 'Every behaviour change is inert' "$O/comment.md" &&
    ! grep -qF 'no example directory' "$O/comment.md" && ! grep -qF 'Checks that could not run' "$O/comment.md"
}
t_ti_mixed; check "inert triggers: one verified trigger beside an inert one keeps the coverage unknown" $?
t_ti_unver; check "inert triggers: one unverifiable trigger keeps the coverage unknown" $?
t_ti_capped; check "inert triggers: a trigger over the cap keeps the coverage unknown" $?
t_ti_claim; check "inert triggers: an unverifiable claim keeps the coverage unknown" $?
t_ti_none; check "inert triggers: no trigger keeps the coverage unknown" $?
t_ti_notrun; check "inert triggers: a behaviour step that did not run keeps the coverage unknown" $?
t_ti_nobeh; check "inert triggers: no behaviour object keeps the coverage unknown" $?
t_ti_refuted; check "inert triggers: a refuted trigger still blocks at rule 2" $?
t_ti_gap; check "inert triggers: another unknown (a patch unavailable) keeps the coverage required, no inert line" $?
t_ti_vgap; check "inert triggers: a verification gap keeps the coverage required, no inert line" $?
t_ti_signal; check "inert triggers: an unknown host signal keeps the coverage required, no inert line" $?
t_ti_precedence; check "inert triggers: a classifier-inert change keeps its own line" $?
t_ti_noexdir; check "inert triggers: no example directory renders no inert line" $?
t_ti_compact; check "inert triggers: COMPACT names the example, its reason and the inert reading, byte for byte" $?
t_ti_covered; check "inert triggers: a covered safety-gate skip beside inert triggers reaches rule 8 with no covered line" $?
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
# More than five unverified triggers: one line counting them per category, most first, no locations.
t_bgroups() {
  render "$NONE" "" "" "$(brun grp "[$(bt T-001 lifecycle-change unverifiable), $(bt T-002 wrapper-change unverifiable), \
$(bt T-003 lifecycle-change unverifiable), $(bt T-004 literal-argument-change unverifiable), \
$(bt T-005 lifecycle-change unverifiable), $(bt T-006 literal-argument-change unverifiable)]" '[]' 3)"
  grep -qxF -- '- 6 behaviour changes not verified: 3 lifecycle-change, 2 literal-argument-change, 1 wrapper-change.' "$O/comment.md" \
    && grep -qxF -- '- 3 more behaviour changes over the classifier cap: not verified.' "$O/comment.md" \
    && ! grep -q '^- Behaviour change at ' "$O/comment.md"
}
t_bgroups; check "behaviour: over five unverified triggers render one line per category count" $?
# A file outside HCL that no level verifies is left to the repository's tests: no section 5 row,
# no rule 4 gap, one note line after the evidence paragraph.
RUN1='.check_runs = [{app_slug: "ci", check_suite_id: 2, conclusion: "success", id: 1, status: "completed"}]'
t_cigated() {
  render "$NONE" "" "$(checks cig pass "$RUN1")" "$(brun cig "[$(bt T-001 non-hcl-dependency unverifiable), $(bt T-002 non-hcl-dependency unverifiable)]" '[]')"
  grep -qxF "Changes outside Terraform the Checks signal gates, with no test run of them read: 2." "$O/comment.md" \
    && ! grep -q '^- Behaviour change at ' "$O/comment.md" && ! grep -q 'ladder rule 4' "$O/comment.md"
}
t_cigated; check "behaviour: non-hcl-dependency triggers are left to the repository's tests" $?
# With no check run and no status on the head there is no test evidence: the trigger stays a gap.
t_cinone() {
  render "$NONE" "" "$(checks cin pass)" "$(brun cin "[$(bt T-001 non-hcl-dependency unverifiable)]" '[]')"
  grep -q '^- Behaviour change at ' "$O/comment.md" && grep -q 'ladder rule 4' "$O/comment.md" \
    && ! grep -q "the Checks signal gates" "$O/comment.md"
}
t_cinone; check "behaviour: with no check on the head, non-hcl-dependency triggers stay gaps" $?
# The test pass (test-pass.md): its result marks the Python non-hcl-dependency triggers of the tested
# directory; a trigger elsewhere keeps its state.
pyt() { jq -nc --arg i "$1" --arg f "$2" '{id: $i, file: $f, line: 1, category: "non-hcl-dependency", state: "unverifiable"}'; }
trun() { # name, tests json -> run file with two Python triggers in functions/ and one in other/
  runf "t-$1" ".behaviour = {status: \"ran\", reason: null, claims: [], capped: 0,
    triggers: [$(pyt T-001 functions/app.py), $(pyt T-002 functions/util.py), $(pyt T-003 other/x.py)]} | .tests = $2
    | if .tests == null then del(.tests) else . end"
}
t_tests_pass() {
  render "$NONE" "" "$(checks tp pass)" "$(trun pass '{dir: "functions", result: "passed 10"}')"
  grep -qxF 'Unit tests of `functions` in the isolated runner: passed 10; changes outside Terraform they cover: 2.' "$O/comment.md" \
    && grep -qF 'other/x.py' "$O/comment.md" && ! grep -qF 'functions/app.py' "$O/comment.md" && [ "$(rule)" = 4 ]
}
t_tests_pass; check "tests: passed marks the tested directory's triggers, no gap; another directory stays a gap" $?
grep -qF ', 2 tested by the unit tests, 0 reported in a finding, ' "$O/comment.md"
check "tests: the evidence line counts the tested triggers" $?
t_tests_all() {
  render "$NONE" "" "$(checks ta pass)" "$(runf t-all '.behaviour = {status: "ran", reason: null, claims: [], capped: 0,
    triggers: ['"$(pyt T-001 app.py)"']} | .tests = {dir: ".", result: "passed 3"}')"
  [ "$(verdict)" = "approve with nits COMMENT" ] && grep -qxF 'Unit tests of `.` in the isolated runner: passed 3; changes outside Terraform they cover: 1.' "$O/comment.md"
}
t_tests_all; check "tests: passed at the module root with no other gap is approve with nits, the cap of a change outside Terraform" $?
t_tests_fail() {
  render "$NONE" "" "$(checks tf pass)" "$(trun fail '{dir: "functions", result: "failed 2"}')"
  [ "$(rule)" = 2 ] && [ "$(verdict)" = "block REQUEST_CHANGES" ] \
    && grep -qxF 'Unit tests of `functions` in the isolated runner: failed 2; changes outside Terraform they refute: 2.' "$O/comment.md" \
    && grep -qF -- '- [ ] Behaviour change at `functions/app.py:1` (non-hcl-dependency): the evidence refutes it.' "$O/comment.md"
}
t_tests_fail; check "tests: failed refutes the tested directory's triggers, a block at rule 2" $?
t_tests_error() {
  render "$NONE" "" "$(checks te pass)" "$(trun err '{dir: "functions", result: "error install"}')"
  cp "$O/comment.md" "$TMP/te.md"
  render "$NONE" "" "$(checks te pass)" "$(trun none null)"
  [ "$(rule)" = 4 ] && cmp -s "$TMP/te.md" "$O/comment.md" && ! grep -q 'Unit tests of' "$O/comment.md"
}
t_tests_error; check "tests: an error result renders as no test pass at all" $?
t_tests_ci() {
  render "$NONE" "" "$(checks tc pass "$RUN1")" "$(trun ci '{dir: "functions", result: "passed 4"}')"
  grep -qxF "Changes outside Terraform the Checks signal gates, with no test run of them read: 1." "$O/comment.md" \
    && grep -qF 'they cover: 2.' "$O/comment.md"
}
t_tests_ci; check "tests: beside a check run, the untested trigger is left to the Checks signal" $?
refused "a tests result outside the grammar" "$NONE" "" "" "$(trun bad '{dir: "functions", result: "passed: all"}')"
refused "a tests key with another field" "$NONE" "" "" "$(trun badk '{dir: "functions", result: "passed 1", log: "x"}')"
refused "a tests directory that is not a plain path" "$NONE" "" "" "$(trun badd '{dir: "a b\nc", result: "passed 1"}')"
# Changes outside Terraform (verdict.md): a change with any behaviour trigger outside HCL is capped
# at approve with nits, every example planned or not; an example not planned leaves rule 4
# only when the module profile proves it runs none of the changed files, whatever its reason, and
# every other example not planned stays an unknown.
NHU='[{dir: "examples/container-image", reason: "exception: needs a Docker daemon"}, {dir: "examples/build-package", reason: "exception: needs a Docker daemon"}]'
nhrun() { # name, unreached json [, jq update] -> run file: package.py changed, 2 of 5 examples not planned
  runf "nh-$1" ".plan_ran = true | .plan_mode = \"runner\" | .examples = {count: 5, skipped: 0, validated: 5}
    | .coverage = {class: \"partial\", inert: false, unplanned: $NHU}
    | .behaviour = {status: \"ran\", reason: null, claims: [], capped: 0,
        triggers: [{id: \"T-001\", file: \"package.py\", line: 3, category: \"non-hcl-dependency\", state: \"unverifiable\"}]}
    | .nonhcl = {head_sha: \"$HEAD\", base_sha: \"$BASE\", files: [{file: \"package.py\", unreached: $2}]} | ${3-.}"
}
NHC="$(checks nh pass "$RUN1")"
NHR7="$(jq -nr -L "$REF" 'include "render-comment"; texts["rationale-7-nonhcl"]')"
t_nh_reach() {
  render "$NONE" "" "$NHC" "$(nhrun reach '["examples/build-package", "examples/container-image"]')"
  [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && [ "$(verdict)" = "approve with nits COMMENT" ] && grep -qxF "$NHR7" "$O/comment.md" \
    && grep -qxF '### Examples not planned' "$O/comment.md" && ! grep -q '^### What to do' "$O/comment.md" \
    && grep -qxF -- '- By the module profile, 2 examples above run no changed file outside Terraform, so they leave nothing unknown.' "$O/comment.md"
}
t_nh_reach; check "outside Terraform: the profile clears every example not planned, approve with nits" $?
t_nh_partial() {
  render "$NONE" "" "$NHC" "$(nhrun partial '["examples/container-image"]')"
  [ "$ST" = 0 ] && [ "$(rule)" = 4 ] && grep -qxF '### Checks that could not run' "$O/comment.md" \
    && grep -qxF -- '- By the module profile, 1 example above runs no changed file outside Terraform, so it leaves nothing unknown.' "$O/comment.md"
}
t_nh_partial; check "outside Terraform: an example the profile does not prove stays an unknown beside a cleared one" $?
t_nh_reason() {
  render "$NONE" "" "$NHC" "$(nhrun reason '["examples/build-package", "examples/container-image"]' \
    '.coverage.unplanned = [{dir: "examples/container-image", reason: "plan gate G1"}, {dir: "examples/build-package", reason: "code-error, merge base not planned"}]')"
  [ "$(rule)" = 7 ]
}
t_nh_reason; check "outside Terraform: an example the profile proves is cleared whatever its reason" $?
t_nh_all() {
  render "$NONE" "" "$NHC" "$(nhrun all '[]' '.coverage = {class: "complete", inert: false, unplanned: []} | del(.nonhcl)')"
  [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && [ "$(verdict)" = "approve with nits COMMENT" ] && grep -qxF "$NHR7" "$O/comment.md"
}
t_nh_all; check "outside Terraform: every example planned is still approve with nits, never approve" $?
t_nh_low() {
  render "$LOWF" "" "$NHC" "$(nhrun low '["examples/build-package", "examples/container-image"]')"
  [ "$(rule)" = 7 ] && grep -qxF "$(jq -nr -L "$REF" 'include "render-comment"; texts["rationale-7"]')" "$O/comment.md"
}
t_nh_low; check "outside Terraform: beside a LOW finding the rationale is the LOW one" $?
nh_rule4() { # name, unreached [, jq update [, checks]] -> holds when the render stays at rule 4 and clears nothing
  render "$NONE" "" "${4:-$NHC}" "$(nhrun "$1" "$2" "${3-.}")"
  [ "$ST" = 0 ] && [ "$(rule)" = 4 ] && ! grep -qF 'By the module profile' "$O/comment.md"
}
NHB='["examples/build-package", "examples/container-image"]'
t_nh_bind() { nh_rule4 bind "$NHB" ".nonhcl.base_sha = \"$HEAD\""; }
t_nh_bind; check "outside Terraform: evidence bound to another merge base clears nothing" $?
t_nh_hcl() { nh_rule4 hcl "$NHB" ".behaviour.triggers += [$(bt T-002 literal-argument-change verified)]"; }
t_nh_hcl; check "outside Terraform: a behaviour change in Terraform beside it keeps the coverage required" $?
t_nh_merged() { nh_rule4 merged "$NHB" '.behaviour.triggers[0].also_categories = ["literal-argument-change"]'; }
t_nh_merged; check "outside Terraform: a trigger that merges a Terraform category keeps the coverage required" $?
t_nh_nofile() { nh_rule4 nofile "$NHB" '.nonhcl.files[0].file = "other.py"'; }
t_nh_nofile; check "outside Terraform: a changed file with no evidence entry clears nothing" $?
t_nh_twofiles() {
  nh_rule4 twofiles "$NHB" '.behaviour.triggers += [{id: "T-002", file: "tests/test_x.py", line: 1, category: "non-hcl-dependency", state: "unverifiable"}]
    | .nonhcl.files += [{file: "tests/test_x.py", unreached: []}]'
}
t_nh_twofiles; check "outside Terraform: an example cleared for one changed file but not the other stays an unknown" $?
t_nh_hclcap() {
  render "$NONE" "" "$NHC" "$(nhrun hclcap '[]' '.coverage = {class: "complete", inert: false, unplanned: []} | del(.nonhcl)
    | .behaviour.triggers += [{id: "T-002", file: "main.tf", line: 2, category: "literal-argument-change", state: "verified"}]')"
  [ "$(rule)" = 7 ] && [ "$(verdict)" = "approve with nits COMMENT" ] && grep -qxF "$NHR7" "$O/comment.md"
}
t_nh_hclcap; check "outside Terraform: a verified Terraform trigger beside it keeps the cap" $?
# Test evidence (verdict.md, Changes outside Terraform): every changed file tested clears an example
# not planned for a runner or design reason, while at least one example was planned.
NHT='The repository'"'"'s own tests import every changed file outside Terraform and passed at the head'
nhtest() { nhrun "$1" "${2:-[]}" ".nonhcl.files[0].tested = true | ${3-.}"; }
t_nh_tested() {
  render "$NONE" "" "$NHC" "$(nhtest tested)"
  [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && [ "$(verdict)" = "approve with nits COMMENT" ] && grep -qxF "$NHR7" "$O/comment.md" \
    && grep -qxF '### Examples not planned' "$O/comment.md" \
    && grep -qxF -- "- $NHT, so 2 examples above, not planned for a runner or design reason, leave nothing unknown." "$O/comment.md" \
    && ! grep -qF 'By the module profile' "$O/comment.md"
}
t_nh_tested; check "outside Terraform: tested files clear every example not planned for a Docker daemon, approve with nits" $?
t_nh_tested_mix() {
  render "$NONE" "" "$NHC" "$(nhtest mix '["examples/build-package"]' '.coverage.unplanned[0].reason = "environment (access-denied)"')"
  [ "$ST" = 0 ] && [ "$(rule)" = 7 ] \
    && grep -qxF -- '- By the module profile, 1 example above runs no changed file outside Terraform, so it leaves nothing unknown.' "$O/comment.md" \
    && grep -qxF -- "- $NHT, so 1 example above, not planned for a runner or design reason, leaves nothing unknown." "$O/comment.md"
}
t_nh_tested_mix; check "outside Terraform: a profile line and test evidence each clear their example, one line each" $?
t_nh_tested_reason() { nh_rule4 treason '[]' '.nonhcl.files[0].tested = true | .coverage.unplanned[0].reason = "environment (timeout)"'; }
t_nh_tested_reason; check "outside Terraform: test evidence clears no example not planned for a timeout" $?
t_nh_tested_gate() { nh_rule4 tgate '[]' '.nonhcl.files[0].tested = true | .coverage.unplanned[1].reason = "plan gate G1"'; }
t_nh_tested_gate; check "outside Terraform: test evidence clears no example skipped by a gate" $?
t_nh_tested_false() { nh_rule4 tfalse '[]' '.nonhcl.files[0].tested = false'; }
t_nh_tested_false; check "outside Terraform: a file not tested clears nothing" $?
t_nh_tested_two() {
  nh_rule4 ttwo '[]' '.nonhcl.files[0].tested = true
    | .behaviour.triggers += [{id: "T-002", file: "other.py", line: 1, category: "non-hcl-dependency", state: "unverifiable"}]
    | .nonhcl.files += [{file: "other.py", unreached: [], tested: false}]'
}
t_nh_tested_two; check "outside Terraform: one changed file tested and another not clears nothing" $?
t_nh_tested_none() { nh_rule4 tnone '[]' '.nonhcl.files[0].tested = true | .examples = {count: 2, skipped: 0, validated: 2}'; }
t_nh_tested_none; check "outside Terraform: test evidence clears nothing when no example was planned" $?
t_nh_tested_hcl() { nh_rule4 thcl '[]' ".nonhcl.files[0].tested = true | .behaviour.triggers += [$(bt T-002 literal-argument-change verified)]"; }
t_nh_tested_hcl; check "outside Terraform: test evidence beside a Terraform trigger clears nothing" $?
t_nh_badtv() { render "$NONE" "" "" "$(nhrun badtv '[]' '.nonhcl.files[0].tested = "yes"')"; [ "$ST" = 2 ] && empty_out; }
t_nh_badtv; check "refused: a nonhcl tested value that is no boolean" $?
mutate "test evidence read for any reason" 's/ and IN\(\.reason; nonhcl_test_reasons\[\]\)//' t_nh_tested_reason
mutate "a timeout read as a design reason" 's/"environment \(access-denied\)", "environment \(refused-host\)"\]/"environment (access-denied)", "environment (refused-host)", "environment (timeout)"]/' t_nh_tested_reason
mutate "test evidence taken from a file not tested" 's/elif all\(\$e\[\]; \.tested == true\)/elif true/' t_nh_tested_false
mutate "test evidence read for one changed file only" 's/elif all\(\$e\[\]; \.tested == true\)/elif any(\$e[]; .tested == true)/' t_nh_tested_two
mutate "test evidence taken with no example planned" 's/\n                     and \(\$u \| length\) < \(\$run\.examples\.count \/\/ 0\)//' t_nh_tested_none
mutate "the test evidence line not rendered" 's/\+ \(if \$q == 0 then \[\]/+ (if true then []/' t_nh_tested
mutate "a tested value of another type taken" 's/ and \(\.tested \| type == "boolean"\)//' t_nh_badtv
refused "a nonhcl key with another field" "$NONE" "" "" "$(nhrun badk '[]' '.nonhcl.note = "x"')"
refused "a nonhcl entry with test evidence" "$NONE" "" "" "$(nhrun badt '[]' '.nonhcl.files[0].tested_by = ["tests/test_x.py"]')"
refused "a nonhcl example that climbs out" "$NONE" "" "" "$(nhrun badp '["../x"]')"
refused "a nonhcl head that is not a SHA" "$NONE" "" "" "$(nhrun bads '[]' '.nonhcl.head_sha = "HEAD"')"
mutate "the outside-Terraform cap dropped" 's/ or \.nonhcl_cap then \{rule: 7/ then {rule: 7/' t_nh_all
mutate "an example the profile does not prove cleared" 's/if all\(\$e\[\]; any\(\.unreached\[\]; \. == \$d\)\) then/if true then/' t_nh_partial
mutate "the outside-Terraform evidence not bound to the merge base" 's/ and \$n\.base_sha == \$in\.host\.merge_base//' t_nh_bind
mutate "the outside-Terraform clearing beside a Terraform trigger" 's/all\(\$t\[\]; nonhcl_only\)/true/' t_nh_merged
mutate "a changed file with no evidence entry ignored" 's/if \(\$e \| length\) != \(\$fs \| length\) then \[\]/if false then []/' t_nh_nofile
mutate "the profile read for one changed file only" 's/if all\(\$e\[\]; any\(\.unreached/if any(\$e[]; any(.unreached/' t_nh_twofiles
mutate "the cap read only when every trigger is outside Terraform" 's/and any\(nonhcl_triggers\(\$b\)\[\];/and all(nonhcl_triggers(\$b)[];/' t_nh_hclcap
mutate "the outside-Terraform rationale not used" 's/and \$in\.nonhcl_cap then tx\("rationale-7-nonhcl"\)/and false then tx("rationale-7-nonhcl")/' t_nh_all
# Job-less workflow runs: CI that never ran. Ended action_required or failure with every read
# complete and nothing else open, the signal is jobless: approve with nits at best, one line each,
# named by file or unnamed, and a maintainer item in place of the author's "Fix the failing checks."
JL='.jobless = [{workflow: "unit-test.yml", conclusion: "failure"}, {workflow: null, conclusion: "action_required"}]'
t_jobless() {
  render "$NONE" "" "$(checks jl unknown "$JL"' | .check_runs = []')"
  [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && [ "$(verdict)" = "approve with nits COMMENT" ] && printf '%s' "$MSG" | grep -q ', tier STANDARD$' \
    && grep -qxF "$(jq -nr -L "$(dirname "$RCU")" 'include "render-comment"; texts["rationale-7-jobless"]')" "$O/comment.md" \
    && grep -qxF "$(jq -nr -L "$(dirname "$RCU")" 'include "render-comment"; texts["todo-lead-7-jobless"]')" "$O/comment.md" \
    && grep -qxF 'Checks: not run, as a workflow ended without starting a job. Mergeable. No review yet. Threads resolved.' "$O/comment.md" \
    && grep -qxF 'Checks: workflow `unit-test.yml` ended `failure` without starting a job, so its tests never ran and say nothing about this change.' "$O/comment.md" \
    && grep -qxF 'Checks: workflow (unnamed) ended `action_required` without starting a job, so its tests never ran and say nothing about this change.' "$O/comment.md" \
    && grep -qxF -- '- [ ] Maintainer: approve or re-run the workflows that never started a job: `unit-test.yml`, (unnamed).' "$O/comment.md" \
    && ! grep -qF 'Fix the failing checks.' "$O/comment.md" && ! grep -qF 'Check results could not be read' "$O/comment.md"
}
t_jobless; check "checks: job-less runs alone are approve with nits at best, with a maintainer item" $?
t_jobless_one() {
  render "$NONE" "" "$(checks jl1 unknown '.jobless = [{workflow: "pre-commit.yml", conclusion: "failure"}] | .check_runs = []')"
  [ "$(rule)" = 7 ] && grep -qxF -- '- [ ] Maintainer: approve or re-run the workflow that never started a job: `pre-commit.yml`.' "$O/comment.md"
}
t_jobless_one; check "checks: one job-less run names one workflow" $?
JL1='.jobless = [{workflow: "pre-commit.yml", conclusion: "failure"}] | .check_runs = []'
t_jobless_low() {
  render "$LOWF" "" "$(checks jllow unknown "$JL1")"
  [ "$(rule)" = 7 ] && [ "$(verdict)" = "approve with nits COMMENT" ] && printf '%s' "$MSG" | grep -q ', tier STANDARD$' \
    && grep -qxF "$(jq -nr -L "$(dirname "$RCU")" 'include "render-comment"; texts["rationale-7"]')" "$O/comment.md" \
    && grep -qxF "$(jq -nr -L "$(dirname "$RCU")" 'include "render-comment"; texts["todo-lead-7-jobless"]')" "$O/comment.md" \
    && grep -qxF -- '- [ ] Maintainer: approve or re-run the workflow that never started a job: `pre-commit.yml`.' "$O/comment.md"
}
t_jobless_low; check "checks: job-less with a LOW finding stays approve with nits, the maintainer item kept" $?
t_jobless_medium() {
  render "$(one structure.grouping MEDIUM a.tf 1 "S." "F.")" "" "$(checks jlmed unknown "$JL1")"
  [ "$(rule)" = 6 ] && [ "$(verdict)" = "block REQUEST_CHANGES" ]
}
t_jobless_medium; check "checks: job-less with a MEDIUM finding blocks at rule 6" $?
# Ambiguous reads stay unknown: another conclusion, a queued check, a pending status, a failed read.
t_jobless_amb() { # name, checks update -> rule 4 with the job-less rationale
  render "$NONE" "" "$(checks "jla-$1" unknown "$2")"
  [ "$ST" = 0 ] && [ "$(rule)" = 4 ] && [ "$(verdict)" = "inconclusive COMMENT" ] \
    && grep -qxF "$(jq -nr -L "$(dirname "$RCU")" 'include "render-comment"; texts["rationale-4-checks-jobless"]')" "$O/comment.md" \
    && grep -qF 'Checks: unknown, as a workflow ended without starting a job.' "$O/comment.md" \
    && grep -qF -- '- [ ] Maintainer: approve or re-run the workflow' "$O/comment.md"
}
t_jobless_amb cancelled '.jobless = [{workflow: "pre-commit.yml", conclusion: "cancelled"}] | .check_runs = []'; check "checks: a job-less run that ended cancelled stays unknown at rule 4" $?
t_jobless_amb queued '.jobless = [{workflow: "pre-commit.yml", conclusion: "failure"}]'; check "checks: a job-less run beside a queued check stays unknown at rule 4" $?
t_jobless_amb pending '.jobless = [{workflow: "pre-commit.yml", conclusion: "failure"}] | .check_runs = [] | .statuses = {state: "pending", total_count: 1}'; check "checks: a job-less run beside a pending status stays unknown at rule 4" $?
t_jobless_amb reads '.jobless = [{workflow: "pre-commit.yml", conclusion: "failure"}] | .check_runs = [] | .reads = "failed"'; check "checks: a job-less run with a failed read stays unknown at rule 4" $?
t_jobless_amb ownjobs '.jobless = [{workflow: "pre-commit.yml", conclusion: "failure"}] | .check_runs = [] | .own_jobs_unreadable = true'; check "checks: a job-less run with unreadable own jobs stays unknown at rule 4" $?
# The missing jobs are no test evidence: a non-hcl-dependency trigger stays a gap beside a job-less run.
t_jobless_ci() {
  render "$NONE" "" "$(checks jlci unknown "$JL1"' | .check_runs = [{app_slug: "ci", check_suite_id: 2, conclusion: "success", id: 1, status: "completed"}]')" \
    "$(runf jlci '.behaviour.triggers = [{id: "T-001", file: "functions/app.py", line: null, category: "non-hcl-dependency", state: "unverifiable"}]')"
  [ "$(rule)" = 4 ] && ! grep -qF "the Checks signal gates" "$O/comment.md" \
    && grep -qF -- '- Behaviour change at `functions/app.py` (non-hcl-dependency): not verified.' "$O/comment.md"
}
t_jobless_ci; check "checks: a job-less run is no test evidence for a change outside Terraform" $?
t_jobless_fail() {
  render "$NONE" "" "$(checks jlf fail "$JL")"
  [ "$(rule)" = 3 ] && grep -qxF -- '- [ ] Fix the failing checks.' "$O/comment.md" \
    && grep -qF 'Maintainer: approve or re-run the workflows' "$O/comment.md"
}
t_jobless_fail; check "checks: a real failing check run still blocks at rule 3, beside the maintainer item" $?
render "$NONE" "" "$(checks jlbad fail "$JL"' | .check_runs = []')"
check "checks: a checks file calling job-less runs a failure is rejected, not a block" "$([ "$(rule)" = 4 ] && grep -qxF "Checks: the host's check runs file was rejected." "$O/comment.md"; echo $?)"
refused "a behaviour trigger state outside the five" "$G" "" "" "$(brun bs "[$(bt T-001 wrapper-change maybe)]" '[]')"
refused "a behaviour category outside the list" "$G" "" "" "$(brun bc "[$(bt T-001 cosmetic verified)]" '[]')"
refused "a claim state inert" "$G" "" "" "$(brun bk '[]' '[{claim_id: "C-1", state: "inert"}]')"
refused "41 behaviour triggers" "$G" "" "" "$(brun b41 "[$(for i in $(seq 1 41); do bt "$(printf 'T-%03d' "$i")" wrapper-change verified; done | paste -sd, -)]" '[]')"
# The split cap: 40 triggers that may need evidence and 40 version floors or moved addresses beside them.
bts() { # count, category, first index -> that many triggers, comma separated
  for i in $(seq "$3" $(($3 + $1 - 1))); do bt "$(printf 'T-%03d' "$i")" "$2" verified; done | paste -sd, -
}
t_b80() { render "$G" "" "" "$(brun b80 "[$(bts 40 wrapper-change 1), $(bts 30 provider-version-floor-change 41), $(bts 10 moved-or-renamed-address 71)]" '[]')"; [ "$ST" = 0 ]; }
t_b80; check "behaviour: 40 triggers that need evidence beside 40 version floors and moved addresses render" $?
refused "81 behaviour triggers" "$G" "" "" "$(brun b81 "[$(bts 40 wrapper-change 1), $(bts 41 provider-version-floor-change 41)]" '[]')"
refused "41 behaviour triggers that need evidence beside version floors" "$G" "" "" "$(brun b41f "[$(bts 41 wrapper-change 1), $(bts 10 provider-version-floor-change 42)]" '[]')"
t_b41m() { render "$G" "" "" "$(brun b41m "[$(bts 40 wrapper-change 1), $(bt T-041 provider-version-floor-change verified | jq -c '.also_categories = ["literal-argument-change"]')]" '[]')"; [ "$ST" = 2 ] && empty_out; }
t_b41m; check "refused: a merged version floor counts toward the evidence cap" $?
t_b41f() { render "$G" "" "" "$(brun b41f2 "[$(bts 41 wrapper-change 1), $(bts 10 provider-version-floor-change 42)]" '[]')"; [ "$ST" = 2 ]; }
t_b81() { render "$G" "" "" "$(brun b81m "[$(bts 40 wrapper-change 1), $(bts 41 provider-version-floor-change 41)]" '[]')"; [ "$ST" = 2 ]; }
mutate "the old total cap of 40 kept" 's/length <= 80\n/length <= 40\n/' t_b80
mutate "the total cap of 80 dropped" 's/type == "array" and length <= 80\n/type == "array"\n/' t_b81
mutate "the evidence cap dropped" 's/\n        and \(\[\.\[\] \| select\(type == "object" and \(\(\(\.category \| IN\("provider-version-floor-change", "moved-or-renamed-address"\)\)\n               and \(has\("also_categories"\) \| not\)\) \| not\)\)\] \| length\) <= 40//' t_b41f
mutate "a merged version floor read as off-ladder" 's/\n               and \(has\("also_categories"\) \| not\)\) \| not/) | not/' t_b41m
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
mutate "review.verification-incomplete not an unknown" 's/, "review\.verification-incomplete"\];/];/' t_bvi
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
# --links also links the behaviour change, refuted and thread locations, which are not findings.
LB="https://github.com/example/terraform-aws-thing/blob/$HEAD"
render "$LOWF" "" "" "$BUV" "" --links
grep -qxF -- "- Behaviour change at [\`main.tf:2\`]($LB/main.tf#L2) (wrapper-change): not verified." "$O/comment.md"
check "links: a behaviour change location links to the file and line at the head" $?
render "$LOWF" "" "" "$BREF" "" --links
todo | grep -qxF -- "- [ ] Behaviour change at [\`main.tf:2\`]($LB/main.tf#L2) (wrapper-change): the evidence refutes it. Fix the change or correct the description."
check "links: a refuted behaviour change in What to do links to the file and line" $?
render "$(one structure.grouping LOW a.tf 1 "S." "F.")" "$(host utl '.unresolved_threads = [{path: "a.tf", line: 1}, {path: "b.tf", line: null}]')" "" "" "" --links
grep -qxF -- "- [\`a.tf:1\`]($LB/a.tf#L1): this review has a finding at the same path and line." "$O/comment.md" \
  && grep -qxF -- "- [\`b.tf\`]($LB/b.tf): this review has no finding at the same path and line." "$O/comment.md"
check "links: an unresolved thread location links to the file, with a fragment only for a line" $?

ladder "a refuted state with only a LOW claim finding" "block REQUEST_CHANGES" 2 "$(one claim.refuted LOW main.tf 2 "S." "F.")" "" "" "$BREF"
ladder "a refuted state with its claim finding" "block REQUEST_CHANGES" 2 "$(one claim.refuted HIGH main.tf 2 "S." "F.")" "" "" "$BREF"
! todo | grep -qF 'the evidence refutes it'; check "behaviour: a reported refutation is worded by its finding alone" $?
ladder "a refuted state beside a CRITICAL compat break" "block REQUEST_CHANGES" 1 "$(one compat.expression-behaviour-changed CRITICAL main.tf 2 "S." "F.")" "" "" "$BREF"
# A CRITICAL finding keeps rule 1 and its rationale; the refuted state only adds its item.
ladder "a refuted state beside a CRITICAL non-compat finding" "block REQUEST_CHANGES" 1 "$(f structure.insecure-default CRITICAL main.tf 9 "S." "F." | list crit-ref)" "" "" "$BREF"
cat > "$TMP/want-crit-ref" <<'EOT'
A CRITICAL finding is open. Any CRITICAL finding blocks merge (ladder rule 1).

Behaviour evidence: 1 change classified: 0 verified, 0 covered by a plan, 0 inert, 1 refuted, 0 not verified; 1 claim: 0 verified, 1 refuted, 0 not verified.

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
  runf "r556-$1" '.plan_ran = true | .plan_mode = "laptop" | .examples = {count: 9, skipped: 0, validated: 9}
    | .coverage = {class: "partial", inert: false, unplanned: [{dir: "examples/serverless", reason: "plan gate G1"},
        {dir: "examples/mysql", reason: "plan gate G3"}, {dir: "examples/s3-import", reason: "plan gate G1"}]}
    | .behaviour = {status: "ran", reason: null, triggers: ['"$(T556)"'], claims: '"$CL20"', capped: 0} | '"${2:-.}"
}
cat > "$TMP/assess-556.txt" <<'EOF'
Dropping `compact()` fixes the plan: with an unknown group id the base kept the old value and the head shows an update. It also keeps null and empty-string elements of `vpc_security_group_ids`, and a null element now fails the plan; the description mentions only empty strings.
EOF
cat > "$TMP/want-556.md" <<'EOF'
Dropping `compact()` fixes the plan: with an unknown group id the base kept the old value and the head shows an update. It also keeps null and empty-string elements of `vpc_security_group_ids`, and a null element now fails the plan; the description mentions only empty strings.

**Inconclusive.** `validate` passed in all 9 examples; 6 were planned. Not checked: the description past 8000 bytes (200 cut), 3 of 9 examples not planned (example code is not run with credentials outside an isolated runner; a limit of the review, not a finding).

To get a conclusive review: shorten the description under 8000 bytes, and plan the 3 skipped examples in runner mode, an isolated container.

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
check "tiers: the COMPACT body of pull request 556 is at most 1400 bytes" "$([ "$(wc -c < "$O/comment.md")" -le 1400 ]; echo $?)"
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
grep -qxF 'Behaviour evidence: 1 change classified: 0 verified, 0 covered by a plan, 0 inert, 1 reported in a finding, 0 refuted, 0 not verified; 20 claims: 19 verified, 0 refuted, 1 not verified.' "$O/comment.md"
check "tiers: the STANDARD evidence line counts the reported trigger" $?
t_cut() { rc "$(F556)" "$(R556 cut)" "$(host cut1 '.could_not_run = [{kind: "prose-truncated", item: "body", omitted: 31}]')"; [ "$(tier)" = COMPACT ] &&
  grep -qF 'Not checked: the description past 8000 bytes (31 cut), 3 of 9 examples not planned (example code is not run with credentials outside an isolated runner; a limit of the review, not a finding).' "$O/comment.md"; }
t_cut; check "tiers: the description cause takes the bytes omitted from host.json" $?
rc "$(F556)" "$(R556 cutt)" "$(host cutt '.could_not_run = [{kind: "prose-truncated", item: "thread", omitted: 40}]')"; std0() { [ "$ST" = 0 ] && [ "$(tier)" = STANDARD ]; }
check "tiers: a thread item cut forces STANDARD" "$(std0; echo $?)"
grep -qxF -- '- Quoted prose was truncated, so part of the discussion was not read.' "$O/comment.md"; check "tiers: STANDARD keeps its truncated prose line" $?
rc "$(F556)" "$(R556 cuti)" "$(host cuti '.could_not_run = [{kind: "prose-truncated", item: "issue", omitted: 50}]')"
check "tiers: a closing issue item cut forces STANDARD" "$(std0; echo $?)"
grep -qxF -- '- Quoted prose was truncated, so part of the discussion was not read.' "$O/comment.md"; check "tiers: an issue cut renders the truncated prose line" $?
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
check "tiers: the MEDIUM case blocks at rule 6 over its unknowns" "$([ "$(rule)" = 6 ]; echo $?)"
rc "$(F556)" "$(R556 uv '.behaviour.triggers += [{id: "T-002", file: "main.tf", line: 9, category: "default-change", state: "unverifiable"}]')"; std "an unverifiable trigger"
rc "$(F556)" "$(R556 nocls '.behaviour = {status: "not-run", reason: "mtf-facts failed", triggers: [], claims: [], capped: 0}')"; std "a classifier that did not run"
rc "$(F556)" "$(R556 floorcat '.behaviour.triggers += [{id: "T-002", file: "versions.tf", line: 5, category: "provider-version-floor-change", state: "verified"}]')"; std "a provider version floor change"
four() { n=0; { f compat.expression-behaviour-changed LOW main.tf 156 'S.' 'F.' "$(jq -nc --argjson i "$IDS" --arg d "$DIG" '{explains: $i, evidence_digest: $d}')"
  for i in 1 2 3; do f "$(rid $i)" LOW "x$i.tf" "$i" "S$i." "F$i."; done; } | list "four-$1"; }
rc "$(four a)" "$(R556 four)"; std "four counted findings"
rc "$({ n=0; f compat.expression-behaviour-changed LOW main.tf 156 'S.' 'F.' "$(jq -nc --argjson i "$IDS" --arg d "$DIG" '{explains: $i, evidence_digest: $d}')"
  for i in 1 2; do f structure.wrong-file LOW "x$i.tf" "$i" "S$i." "F$i."; done; f structure.wrong-file LOW x3.tf 3 S1. F1.; } | list g3a)" "$(R556 g3)"
check "tiers: four findings with a group of three force STANDARD" "$([ "$(tier)" = STANDARD ]; echo $?)"
rc "$({ n=0; for i in 1 2 3; do f structure.wrong-file LOW "x$i.tf" "$i" "Same." "Same."; done; } | list g3b)" "$(R556 g3b '.behaviour.triggers[0] |= (.state = "verified" | .outstanding = [] | del(.evidence_digest))')"; std "a group of three"
t_routed() {
  n=0
  { for i in 1 2 3; do f "$(rid $i)" LOW "x$i.tf" "$i" "S$i." "F$i."; done
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
  [ "$(tier)" = COMPACT ] && grep -qF 'Not checked: the description past 8000 bytes (200 cut), 1 of 9 examples not planned (example code is not run with credentials outside an isolated runner; a limit of the review, not a finding), 1 of 9 examples not planned (they hold files the safety checks refuse, such as state, override or variable files).' "$O/comment.md" &&
    grep -qxF 'To get a conclusive review: shorten the description under 8000 bytes, plan the 1 skipped example in runner mode, an isolated container, and remove the refused files from the 1 example.' "$O/comment.md"
}
t_g0; check "tiers: a G0 example gets its own clause, never the runner clause" $?
t_noplan() {
  rc "$NONE" "$(runf noplan '.examples = {count: 2, skipped: 0, validated: 2}
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
# Text over a COMPACT cap renders STANDARD in place of a COMPACT-eligible body, with one line
# that names every offender; nothing is cut.
over() { # name, findings, assessment file, want message
  render "$1" "$H556" "" "$(R556 "over-$oc")" "$2"
  check "fallback: COMPACT $4 renders STANDARD" "$([ "$ST" = 0 ] && [ "$(tier)" = STANDARD ] &&
    printf '%s\n' "$MSG" | grep -F "$FALLBACK" | grep -qF "$3" && [ -s "$O/result.json" ]; echo $?)"
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
  [ "$ST" = 0 ] && [ "$(tier)" = STANDARD ] && [ "$(printf '%s\n' "$MSG" | sed -n '1p')" = 'rendered STANDARD, over the COMPACT limits: the assessment is 351 characters, limit 350; finding F-001 summary is 201 characters, limit 200; finding F-001 suggested_fix is 260 characters, limit 250; finding F-002 summary is 230 characters, limit 200' ] &&
    [ "$(printf '%s\n' "$MSG" | wc -l | tr -d ' ')" = 2 ] && grep -qxF -- "$(head -c 201 /dev/zero | tr '\0' s)" <(jq -r '.[0].summary' "$O/findings.json")
}
t_over_all; check "fallback: COMPACT every offender named in one line with its length and limit, the text kept whole" $?
# The live case: one summary of 227 characters in a COMPACT-eligible run renders the STANDARD body
# the same inputs render with --standard, plus the fallback line.
t_227() {
  local s227; s227="$(head -c 227 /dev/zero | tr '\0' s)"
  rc "$(F556 "{summary: \"$s227\"}")" "$(R556 s227s)" "" --standard; cp "$O/comment.md" "$TMP/want-227.md"
  printf '%s\n' "$MSG" | grep -qF "$FALLBACK" && return 1
  rc "$(F556 "{summary: \"$s227\"}")" "$(R556 s227)"
  [ "$ST" = 0 ] && [ "$(tier)" = STANDARD ] && cmp -s "$O/comment.md" "$TMP/want-227.md" &&
    [ "$(printf '%s\n' "$MSG" | sed -n '1p')" = 'rendered STANDARD, over the COMPACT limits: finding F-001 summary is 227 characters, limit 200' ]
}
t_227; check "fallback: a COMPACT-eligible run with a summary of 227 characters renders STANDARD with the note" $?
# Over a STANDARD cap the input is still refused: the message names the finding, field, length and limit.
t_std_fix() {
  render "$(F556 "{suggested_fix: \"needs decision: $(head -c 589 /dev/zero | tr '\0' d)\"}")" "$H556" "" "$(R556 std605)" "$TMP/assess-556.txt"
  [ "$ST" = 2 ] && empty_out && [ "$MSG" = 'render-comment.sh: over the STANDARD limits: finding F-001 suggested_fix is 605 characters, limit 600; send the finding back to the reviewer' ]
}
t_std_fix; check "refused: STANDARD a fix of 605 characters, the message names the finding, field, length and limit" $?

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
check "refused: STANDARD a summary over 500 characters, the message names the finding, the limit and the tier" "$([ "$ST" = 2 ] && empty_out && [ "$MSG" = 'render-comment.sh: over the STANDARD limits: finding F-001 summary is 501 characters, limit 500; send the finding back to the reviewer' ]; echo $?)"
t_approve() {
  rc "$NONE" "$(runf appr '.plan_ran = true | .examples = {count: 9, skipped: 0, validated: 9}')" "$HOST"
  [ "$(tier)" = COMPACT ] && [ "$(verdict)" = "approve APPROVE" ] &&
    cmp -s "$O/comment.md" <(printf '%s\n' "$(cat "$TMP/assess-556.txt")" '' '**Good to merge.** `validate` passed in all 9 examples; 9 were planned.')
}
t_approve; check "tiers: approve, K equals M, byte for byte" $?
t_nits() {
  rc "$(printf '%s\n' "$(f structure.grouping LOW a.tf 1 'S.' 'F.')" | list nits)" "$(runf nits '.plan_ran = true | .examples = {count: 9, skipped: 0, validated: 8}')" "$HOST"
  [ "$(tier)" = COMPACT ] && [ "$(rule)" = 7 ] && cmp -s "$O/comment.md" <(printf '%s\n' "$(cat "$TMP/assess-556.txt")" '' \
    '**Good to merge, with nits.** `validate` passed in 8 of 9 examples; 9 were planned.' '' '- LOW `structure.grouping` `a.tf:1` - S.' '  - Fix: F.')
}
t_nits; check "tiers: approve with nits, K below M, byte for byte" $?
refused "example counts with more validated than verified" "$G" "" "" "$(runf exbad '.examples = {count: 2, skipped: 0, validated: 2} | .verify_gaps = [{dir: "examples/a", reason: "init failed"}]')"
refused "example counts below the unplanned examples" "$G" "" "" "$(runf exbad2 '.examples = {count: 1, skipped: 0, validated: 1} | .coverage = {class: "none", inert: false, unplanned: [{dir: "a", reason: "budget"}, {dir: "b", reason: "budget"}]}')"
refused "an unknown argument after --standard" "$G" "" "" "" "" --standard --compact
# Examples skipped as a version bump only count among the selected examples: 6 selected, 5 of
# them skipped, 1 verified that passed validate, 3 not planned renders, each count stated once.
t_vbump() {
  rc "$(F556)" "$(R556 vbump '.examples = {count: 6, skipped: 5, validated: 1}')"
  [ "$ST" = 0 ] && [ "$(tier)" = COMPACT ] && [ "$(rule)" = 4 ] &&
    cmp -s "$O/comment.md" <(sed -e 's/`validate` passed in all 9 examples; 6 were planned\./`validate` passed in 1 of 6 examples and 5 were skipped as a version bump only; 3 were planned./' \
      -e 's/3 of 9 examples not planned/3 of 6 examples not planned/' "$TMP/want-556.md")
}
t_vbump; check "examples: 5 of 6 skipped as a version bump only and 3 not planned render, byte for byte" $?
refused "example counts of the verified examples only, below the unplanned examples" "$(F556)" "$H556" "" "$(R556 vbump1 '.examples = {count: 1, skipped: 0, validated: 1}')"
t_exbad3() { render "$G" "" "" "$(runf exbad3 '.examples = {count: 6, skipped: 5, validated: 2}')"; [ "$ST" = 2 ] && empty_out; }
t_exbad3; check "refused: example counts with more validated and skipped than selected" $?
refused "example counts without the skipped count" "$G" "" "" "$(runf exbad4 '.examples = {count: 2, validated: 2}')"

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
  [ "$(tier)" = COMPACT ] && grep -qxF 'To get a conclusive review: shorten the description under 8000 bytes, and plan the 1 skipped example in runner mode, an isolated container.' "$O/comment.md"
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
  local q; q="$(sed -n 's/.*`examples`, `{"count": M, "validated": K}`, from .*: `jq '"'"'\(.*\)'"'"'`\..*/\1/p' "$STEPS")"
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
t_over() { render "$(F556)" "$H556" "" "$(R556 overm)" "$TMP/a-351.txt"; [ "$ST" = 0 ] && [ "$(tier)" = STANDARD ] && printf '%s\n' "$MSG" | grep -qF "$FALLBACK"; }
t_force() { rc "$(F556)" "$(R556 force)" "" --standard; [ "$(tier)" = STANDARD ]; }
t_root_rule0_item() { t_root_rule0; [ "$ST" = 0 ] && todo | grep -qxF -- '- [ ] Resolve `compat.claim-contradicts-analysis`: see its Fix under Findings.'; }
t_root_one_item() { t_root_one; [ "$ST" = 0 ] && todo | grep -qxF -- '- [ ] Resolve `scope.boundary`: see its Fix under Findings.'; }

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
mutate "the COMPACT caps dropped" 's/then compact_refusal\(\$in\) else null end/then null else null end/' t_over
mutate "the STANDARD fallback removed" 's/if \$fit and \$over == null then "COMPACT"/if $fit then "COMPACT"/' t_227
mutate "the fallback line not printed" 's/jq -r \x27\.fallback \/\/ empty[^\n]*\n//' t_over_all
mutate "the STANDARD caps named only by the schema check" 's/\[ -z "\$over" \] \|\| die/true ||/' t_std_fix
mutate "the needs decision fix held to 250 in COMPACT" 's/then 600 else 250 end/then 250 else 250 end/' t_nd409
mutate "the fallback line reworded in the script only" 's/"rendered STANDARD, \\\(\.\)"/"tier STANDARD, \\(.)"/' t_fallback_stated
mutate "only the first COMPACT offender named" 's/\(\$o \| join\("; "\)\)/$o[0]/' t_over_all
mutate "the description band not enforced" 's/def band_ok:/def band_ok: true; def band_ok_unused:/' t_band_low
mutate "the module root item dropped under rule 0" 's/def compat_item: [^\n]*/def compat_item: (.rule | startswith("compat."));/' t_root_rule0_item
mutate "the module root item dropped" 's/elif all\(\.items\[\]; \.file == "\."\)/elif false/' t_root_one_item
mutate "--standard ignored" 's/--standard\) standard=true; shift ;;/--standard) shift ;;/' t_force
mutate "a COMPACT string changed in the script only" 's/plan the \{count\} skipped examples in runner mode, an isolated container/plan the {count} examples in runner mode/' t_table
mutate "the verdict line drops the validate sentence" 's/\(if \$run\.plan_ran then " " \+ tx/(if false then " " + tx/' t_556
mutate "every prose-truncated entry its own line" 's/select\(\.value\.kind != "prose-truncated" or \.key == \$first\)/select(true)/' t_prose_once
mutate "reported triggers counted as gaps" 's/\. \+ \{state: "reported", judged_by: \[\$e\[\]\.id\]\}/./' t_556

# --- Covered safety-gate skips (verdict.md, Covered safety-gate skips): the run file's
# coverage.covered_skips, from skip-coverage.sh, takes the skipped examples off rule 4 only when
# every condition holds for every one of them, all or nothing; else the body is the one the run
# file without the key renders. The 556 fixture with its description whole and a witness for each
# of its three skips.
H556N="$(host h556n '.repo = "example/terraform-aws-rds-aurora" | .number = 556')"
W1='{attribute: "vpc_security_group_ids", example: "examples/autoscaling", address: "module.aurora.aws_rds_cluster.this"}'
COVJ='[{dir: "examples/mysql", gate: "G3", path: "main.tf", witnesses: ['"$W1"']},
  {dir: "examples/s3-import", gate: "G1", path: "main.tf", witnesses: ['"$W1"']},
  {dir: "examples/serverless", gate: "G1", path: "main.tf", witnesses: ['"$W1"']}]'
R556K() { # name [, jq update] -> the 556 run file with covered skips
  R556 "$1" '.coverage += {covered_skips: '"$COVJ"', skip_head_sha: "'"$HEAD"'", skip_base_sha: "'"$BASE"'"} | '"${2:-.}"
}
VER='.behaviour.triggers[0] |= (.state = "verified" | .outstanding = [] | del(.evidence_digest))'
cat > "$TMP/want-556k.md" <<'EOF'
Dropping `compact()` fixes the plan: with an unknown group id the base kept the old value and the head shows an update. It also keeps null and empty-string elements of `vpc_security_group_ids`, and a null element now fails the plan; the description mentions only empty strings.

**Good to merge, with nits.** `validate` passed in all 9 examples; 6 were planned. 3 of 9 examples were not planned because of the review safety checks; the changed code was planned in `examples/autoscaling` (see notes).

- LOW `compat.expression-behaviour-changed` `main.tf:156` - null and empty-string elements of `var.vpc_security_group_ids` now reach the provider, and a null fails the plan.
  - Fix: reject them with a `validation` block in `variables.tf`, or say in the description that they now fail.
- LOW `compat.claim-contradicts-analysis` `.` - The description says only empty strings now reach the provider; null elements of `var.vpc_security_group_ids` reach it too.
  - Fix: no code change: add to the description: "Dropping `compact()` also keeps null elements, and a null element now fails the plan."

<details><summary>Evidence and notes</summary>

- Not planned: `examples/mysql` (G3 hit in `main.tf`, same at base 89abcde).
- Not planned: `examples/s3-import` (G1 hit in `main.tf`, same at base 89abcde).
- Not planned: `examples/serverless` (G1 hit in `main.tf`, same at base 89abcde).
- Covered by: `vpc_security_group_ids` planned in `examples/autoscaling` as `module.aurora.aws_rds_cluster.this` at 0123456.
- Behaviour change at `main.tf:156` reported: judged in F-001 (12 differences). 20 claims verified.
- Predates this change: `structure.argument-order` at `main.tf:43` - `tags` is not the last argument.
</details>
EOF
t_cov_gold() { rc "$(F556C)" "$(R556K kgold)" "$H556N"; [ "$ST" = 0 ] && [ "$(tier)" = COMPACT ] && [ "$(rule)" = 7 ] && cmp -s "$O/comment.md" "$TMP/want-556k.md"; }
t_cov_gold; check "covered: pull request 556 with its skips covered renders COMPACT at rule 7, byte for byte" $?
# Two examples skipped as a version bump only are a decision, no unknown: the skips stay covered.
t_cov_vbump() {
  rc "$(F556C)" "$(R556K kvbump '.examples = {count: 9, skipped: 2, validated: 7}')" "$H556N"
  [ "$ST" = 0 ] && [ "$(tier)" = COMPACT ] && [ "$(rule)" = 7 ] &&
    cmp -s "$O/comment.md" <(sed 's/`validate` passed in all 9 examples; 6 were planned\./`validate` passed in 7 of 9 examples and 2 were skipped as a version bump only; 6 were planned./' "$TMP/want-556k.md")
}
t_cov_vbump; check "covered: version bump skips keep the covered skips at rule 7, byte for byte" $?
check "covered: approve with nits proposes COMMENT" "$([ "$(verdict)" = "approve with nits COMMENT" ]; echo $?)"
check "covered: findings.json lists the routed finding last" "$(jq -e 'map(.id) == ["F-001", "F-002", "F-003"]' "$O/findings.json" > /dev/null; echo $?)"

# The covered lines sit in the collapsed details block, about 80 bytes per skipped example and
# one witness line of about 130 for all three; the part a reader sees first, above it, takes one
# sentence and loses the action line, so it stays near the 556 body's own (1723 and 1097 bytes). The 1400 bound of the inconclusive 556 body above is unchanged.
check "covered: the COMPACT body is at most 2000 bytes, at most 1150 above its details block" \
  "$([ "$(wc -c < "$TMP/want-556k.md")" -le 2000 ] && [ "$(awk '/^<details>/ { exit } { print }' "$TMP/want-556k.md" | wc -c)" -le 1150 ]; echo $?)"

# unch name, findings, run [, host] [, checks]: the covered run file renders the body, verdict and
# tier of the same run file without the covered keys.
unch() {
  local fi="$2" ru="$3" ho="${4:-$H556N}" ch="${5:-$CHK}" b1
  jq 'del(.coverage.covered_skips, .coverage.skip_head_sha, .coverage.skip_base_sha)' "$ru" > "$ru.plain"
  render "$fi" "$ho" "$ch" "$ru" "$TMP/assess-556.txt"; b1="$O"
  [ "$ST" = 0 ] && ! grep -qE 'Covered by: |review safety checks' "$O/comment.md" || return 1
  render "$fi" "$ho" "$ch" "$ru.plain" "$TMP/assess-556.txt"
  [ "$ST" = 0 ] && cmp -s "$b1/comment.md" "$O/comment.md" && cmp -s "$b1/result.json" "$O/result.json"
}
t_cov_partial() { unch x "$(F556C)" "$(R556K kpart '.coverage.covered_skips |= .[:2]')"; }
t_cov_runner() { unch x "$(F556C)" "$(R556K krun '.plan_mode = "runner"')"; }
t_cov_nomode() { unch x "$(F556C)" "$(R556K knomode 'del(.plan_mode)')"; }
t_cov_g0() { unch x "$(F556C)" "$(R556K kg0 '.coverage.unplanned += [{dir: "examples/a", reason: "plan gate G0"}]')"; }
t_cov_noprof() { unch x "$(F556C)" "$(R556K knoprof '.coverage.unplanned += [{dir: "examples/a", reason: "no AWS profile named"}]')"; }
t_cov_refuted() { unch x "$(F556C)" "$(R556K kref '.behaviour.claims[0].state = "refuted"')"; }
t_cov_reftrig() { unch x "$(F556C)" "$(R556K kreft '.behaviour.triggers += [{id: "T-002", file: "main.tf", line: 9, category: "default-change", state: "refuted"}]')"; }
t_cov_uvclaim() { unch x "$(F556C)" "$(R556K kuvc '.behaviour.claims[0].state = "unverifiable"')"; }
t_cov_uvtrig() { unch x "$(F556C)" "$(R556K kuvt '.behaviour.triggers += [{id: "T-002", file: "main.tf", line: 9, category: "default-change", state: "unverifiable"}]')"; }
t_cov_notrun() { unch x "$(F556C)" "$(R556K knr '.behaviour = {status: "not-run", reason: "mtf-facts failed", triggers: [], claims: [], capped: 0}')"; }
t_cov_nobeh() { unch x "$(F556C)" "$(R556K knob 'del(.behaviour)')"; }
t_cov_capped() { unch x "$(F556C)" "$(R556K kcap '.behaviour.capped = 1')"; }
t_cov_zero() { unch x "$(F556C)" "$(R556K kzero '.behaviour.triggers = [] | .behaviour.claims = []')"; }
t_cov_validated() { unch x "$(F556C)" "$(R556K kval '.examples.validated = 8')"; }
t_cov_vgap() { unch x "$(F556C)" "$(R556K kvgap '.verify_gaps = [{dir: "examples/b", reason: "init failed"}] | .examples.validated = 8')"; }
t_cov_triage() { unch x "$(F556C)" "$(R556K ktri '.triage = true')"; }
t_cov_inert() { unch x "$(F556C)" "$(R556K kinert '.coverage.inert = true')"; }
t_cov_head() { unch x "$(F556C)" "$(R556K khead '.coverage.skip_head_sha = "'"$BASE"'"')"; }
t_cov_witself() { unch x "$(F556C)" "$(R556K kwit '.coverage.covered_skips[1].witnesses[0].example = "examples/mysql"')"; }
t_cov_gate() { unch x "$(F556C)" "$(R556K kgate '.coverage.covered_skips[0].gate = "G1"')"; }
t_cov_extra() { unch x "$(F556C)" "$(R556K kextra '.coverage.covered_skips += [{dir: "examples/other", gate: "G1", path: "main.tf", witnesses: ['"$W1"']}]')"; }
t_cov_dup() { unch x "$(F556C)" "$(R556K kdup '.coverage.unplanned += [{dir: "examples/mysql", reason: "plan gate G3"}]')"; }
t_cov_cut() { unch x "$(F556C)" "$(R556K kcut)" "$H556"; }
t_cov_patch() { unch x "$(F556C)" "$(R556K kpatch)" "$(host kpatch '.could_not_run = [{kind: "patch-unavailable", path: "main.tf"}]')"; }
t_cov_signal() { unch x "$(F556C)" "$(R556K ksig)" "$(host ksig '.signals.mergeability = "unknown"')"; }
t_cov_checks() { unch x "$(F556C)" "$(R556K kchk)" "$H556N" "$(checks kunk unknown)"; }
t_cov_review() {
  jq '. + [{id: "F-004", rule_id: "review.verification-incomplete", severity: "LOW", file: "main.tf", line: null,
    summary: "S.", suggested_fix: "F.", source: "llm"}]' "$(F556C)" > "$TMP/f556r.json"
  unch x "$TMP/f556r.json" "$(R556K krev)"
}
for c in "one skipped example not covered:partial" "a runner-mode plan pass:runner" "no plan mode:nomode" \
  "a G0 example among the skips:g0" "an example not planned for want of a profile:noprof" \
  "a refuted claim:refuted" "a refuted trigger:reftrig" "an unverifiable claim:uvclaim" "an unverifiable trigger:uvtrig" \
  "a behaviour step that did not run:notrun" "no behaviour object:nobeh" "triggers over the cap:capped" \
  "no trigger and no claim:zero" "validate passed in fewer examples than selected:validated" "a verification gap:vgap" \
  "a triage run:triage" "an inert change:inert" "skip_head_sha of another head:head" \
  "a witness that is one of the skipped examples:witself" "a covered entry under another gate:gate" \
  "a covered entry that is no skip:extra" "an example listed twice as not planned:dup" "the description cut:cut" \
  "a patch unavailable:patch" "a host signal unknown:signal" "the checks unknown:checks" "a review.* finding:review"; do
  "t_cov_${c##*:}"; check "covered: ${c%:*} leaves the body as without covered_skips" $?
done
t_cov_refuted; check "covered: a refuted claim still blocks at rule 2" "$([ "$(rule)" = 2 ]; echo $?)"

# A malformed covered_skips is refused: exit 2, nothing written.
kref() { refused "covered_skips $1" "$(F556C)" "$H556N" "" "$(R556K "kbad-$oc" "$2")"; }
kref "that is not a list" '.coverage.covered_skips = {}'
kref "with an extra key" '.coverage.covered_skips[0].extra = 1'
kref "with no witness" '.coverage.covered_skips[0].witnesses = []'
kref "with a witness missing its address" 'del(.coverage.covered_skips[0].witnesses[0].address)'
kref "with an attribute outside the name grammar" '.coverage.covered_skips[0].witnesses[0].attribute = "Vpc-Ids"'
kref "with a G0 gate" '.coverage.covered_skips[0].gate = "G0"'
kref "with an absolute directory" '.coverage.covered_skips[0].dir = "/examples/mysql"'
kref "with a path out of the directory" '.coverage.covered_skips[0].path = "../main.tf"'
kref "with a backtick in an address" '.coverage.covered_skips[0].witnesses[0].address = "module.a`b"'
kref "with an address over 300 characters" '.coverage.covered_skips[0].witnesses[0].address = ("a" * 301)'
kref "with no skip_head_sha" 'del(.coverage.skip_head_sha)'
kref "with an upper-case skip_base_sha" '.coverage.skip_base_sha |= ascii_upcase'
kref "with a short skip_head_sha" '.coverage.skip_head_sha |= .[:7]'
t_cov_shaonly() { render "$(F556C)" "$H556N" "" "$(R556K kshaonly 'del(.coverage.covered_skips)')" "$TMP/assess-556.txt"; [ "$ST" = 2 ] && empty_out; }
t_cov_shaonly; check "refused: the skip SHAs without covered_skips" $?
t_cov_badshape() { render "$(F556C)" "$H556N" "" "$(R556K kshape '.coverage.covered_skips[0].extra = 1')" "$TMP/assess-556.txt"; [ "$ST" = 2 ] && empty_out; }
# A gate hit in a downloaded module is no base measurement: its line names neither a path nor a
# base, in either tier.
DLLINE='- Not planned: `examples/mysql` (G3 hit in a downloaded module; the pull request cannot change it).'
t_cov_dl() {
  rc "$(F556C)" "$(R556K kdl '.coverage.covered_skips[0].downloaded = true')" "$H556N"
  [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && cmp -s "$O/comment.md" <(sed "s|^- Not planned: \`examples/mysql\` .*|$DLLINE|" "$TMP/want-556k.md") || return 1
  rc "$(F556C)" "$(R556K kdls '.coverage.covered_skips[0].downloaded = true')" "$H556N" --standard
  [ "$ST" = 0 ] && grep -qxF -- "$DLLINE" "$O/comment.md" &&
    grep -qxF -- '- Not planned: `examples/s3-import` (G1 hit in `main.tf`, same at base 89abcde).' "$O/comment.md"
}
t_cov_dl; check "covered: a downloaded hit names no path and no base, a measured one both, in both tiers" $?
# One line per distinct witness: three skips with one witness give one line (the golden); two
# distinct witnesses give two, in first-seen order, and the sentence says other examples.
W2='{attribute: "vpc_security_group_ids", example: "examples/postgresql", address: "module.aurora.aws_rds_cluster.this"}'
t_cov_two() {
  rc "$(F556C)" "$(R556K ktwo '.coverage.covered_skips[1].witnesses = ['"$W2"']')" "$H556N"
  [ "$ST" = 0 ] && [ "$(grep -c '^- Covered by: ' "$O/comment.md")" = 2 ] &&
    [ "$(sed -n 's/^- Covered by: `vpc_security_group_ids` planned in `\(examples\/[a-z]*\)` .*/\1/p' "$O/comment.md" | tr '\n' ' ')" = "examples/autoscaling examples/postgresql " ] &&
    grep -qF '3 of 9 examples were not planned because of the review safety checks; the changed code was planned in other examples (see notes).' "$O/comment.md"
}
t_cov_two; check "covered: two distinct witnesses give two lines and say other examples" $?
t_cov_gold; check "covered: three skips with one witness give one witness line" "$([ "$(grep -c '^- Covered by: ' "$O/comment.md")" = 1 ]; echo $?)"
t_cov_dlfalse() { render "$(F556C)" "$H556N" "" "$(R556K kdlf '.coverage.covered_skips[0].downloaded = false')" "$TMP/assess-556.txt"; [ "$ST" = 2 ] && empty_out; }
t_cov_dlfalse; check "covered: a downloaded false flag is refused" $?

# Names the pull request controls: allowlisted, else withheld, and an at-sign never reaches the body.
t_cov_names() {
  rc "$NONE" "$(R556K knames "$VER"' | .coverage.unplanned = [{dir: "examples/b c", reason: "plan gate G1"}]
    | .coverage.covered_skips = [{dir: "examples/b c", gate: "G1", path: "ma in.tf", witnesses: [{attribute: "tags",
        example: "examples/x y", address: "module.a@org/team.this"}]}]')" "$H556N"
  [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && ! grep -qF '@' "$O/comment.md" && grep -qxF -- '- Not planned: name withheld (G1 hit in name withheld, same at base 89abcde).' "$O/comment.md" &&
    grep -qxF -- '- Covered by: `tags` planned in name withheld as name withheld at 0123456.' "$O/comment.md" &&
    grep -qF 'the changed code was planned in other examples (see notes).' "$O/comment.md"
}
t_cov_names; check "covered: names outside the charset are withheld" $?
t_cov_leak() {
  rc "$NONE" "$(R556K kleak "$VER"' | .coverage.covered_skips[0].witnesses[0].address = "module.ghp_abc.aws_db_instance.this"')" "$H556N"
  [ "$ST" = 1 ] && empty_out && printf '%s' "$MSG" | grep -qF 'leak scan: ghp_ in the host records'
}
t_cov_leak; check "covered: the leak scan runs over the witness lines" $?

# Rule 8 is out of reach while a covered skip exists: rule 7, COMMENT, never APPROVE.
t_cov_rule8() {
  rc "$NONE" "$(R556K k8 "$VER")" "$H556N"
  [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && [ "$(verdict)" = "approve with nits COMMENT" ] && [ "$(tier)" = COMPACT ] &&
    cmp -s "$O/comment.md" <(printf '%s\n' "$(cat "$TMP/assess-556.txt")" '' \
      '**Good to merge, with nits.** `validate` passed in all 9 examples; 6 were planned. 3 of 9 examples were not planned because of the review safety checks; the changed code was planned in `examples/autoscaling` (see notes).' '' \
      '<details><summary>Evidence and notes</summary>' '' "$(sed -nE '/^- (Not planned: |Covered by: )/p' "$TMP/want-556k.md")" '- 20 claims verified.' '</details>')
}
t_cov_rule8; check "covered: no finding lands at rule 7, proposes COMMENT, COMPACT byte for byte" $?
t_cov_rule8_std() {
  rc "$NONE" "$(R556K k8s "$VER")" "$H556N" --standard
  [ "$ST" = 0 ] && [ "$(verdict)" = "approve with nits COMMENT" ] &&
    cmp -s "$O/comment.md" <(printf '%s\n' "$(cat "$TMP/assess-556.txt")" '' '**Good to merge, with nits.**' '' \
      'No finding is open, and some examples were not planned. With examples not planned, approve with nits is the best verdict (ladder rule 7). 3 of 9 examples were not planned because of the review safety checks; the changed code was planned in `examples/autoscaling`, as listed below.' '' \
      '### Examples not planned' '' "$(sed -nE '/^- (Not planned: |Covered by: )/p' "$TMP/want-556k.md")")
}
t_cov_rule8_std; check "covered: STANDARD with no finding, no What to do, byte for byte" $?

# STANDARD: the witness lines take the place of the reason clauses in section 5, and the rationale
# gains the sentence; the rest is the STANDARD body of rule 7.
t_cov_std() {
  rc "$(F556C)" "$(R556K kstd)" "$H556N" --standard
  [ "$ST" = 0 ] && [ "$(tier)" = STANDARD ] && cmp -s "$O/comment.md" <(printf '%s\n' "$(cat "$TMP/assess-556.txt")" '' '**Good to merge, with nits.**' '' \
    'Only LOW findings remain. LOW findings alone mean approve with nits (ladder rule 7). 3 of 9 examples were not planned because of the review safety checks; the changed code was planned in `examples/autoscaling`, as listed below.' '' \
    '### What to do' '' 'Nothing blocks merge. The items below are optional.' '' \
    '- Optional: `compat.expression-behaviour-changed` at `main.tf:156`.' \
    '- Optional: `compat.claim-contradicts-analysis` at `.`.' \
    '- Optional: `structure.argument-order` at `main.tf:43`.' '' \
    '### Findings' '' '**LOW**' '' \
    '- `compat.expression-behaviour-changed` - `main.tf:156` - null and empty-string elements of `var.vpc_security_group_ids` now reach the provider, and a null fails the plan.' \
    '  - Fix: reject them with a `validation` block in `variables.tf`, or say in the description that they now fail.' \
    '- `compat.claim-contradicts-analysis` - `.` - The description says only empty strings now reach the provider; null elements of `var.vpc_security_group_ids` reach it too.' \
    '  - Fix: no code change: add to the description: "Dropping `compact()` also keeps null elements, and a null element now fails the plan."' \
    '- `structure.argument-order` - `main.tf:43` - `tags` is not the last argument.' '  - Fix: Move `tags` last.' '' \
    '### Examples not planned' '' "$(sed -nE '/^- (Not planned: |Covered by: )/p' "$TMP/want-556k.md")")
}
t_cov_std; check "covered: STANDARD lists the witness lines in section 5, byte for byte" $?

# Rules 0 to 6 run unchanged.
rc "$(F556 '{severity: "MEDIUM"}')" "$(R556K kmed)" "$H556N"
check "covered: a MEDIUM finding still blocks at rule 6" "$([ "$(rule)" = 6 ] && [ "$(verdict)" = "block REQUEST_CHANGES" ]; echo $?)"
rc "$(F556 '{severity: "HIGH"}')" "$(R556K khigh)" "$H556N"
check "covered: a HIGH finding still blocks at rule 2" "$([ "$(rule)" = 2 ] && [ "$(verdict)" = "block REQUEST_CHANGES" ]; echo $?)"
rc "$(F556C)" "$(R556K kthr)" "$(host kthr '.unresolved_threads = [{path: "a.tf", line: 1}]')"
check "covered: unresolved threads still land at rule 5" "$([ "$(rule)" = 5 ] && [ "$(verdict)" = "changes suggested COMMENT" ]; echo $?)"

# The base, the plan pass and the bounds of a covered run.
t_cov_base() { unch x "$(F556C)" "$(R556K kbase '.coverage.skip_base_sha = "'"$HEAD"'"')"; }
t_cov_nomb() { unch x "$(F556C)" "$(R556K knomb)" "$(host knomb '.repo = "example/terraform-aws-rds-aurora" | .number = 556 | .merge_base = null')"; }
t_cov_noplan() { unch x "$(F556C)" "$(R556K knoplan '.plan_ran = false')"; }
t_cov_allskip() { unch x "$(F556C)" "$(R556K kall '.examples = {count: 3, skipped: 0, validated: 3}')"; }
# 100 witnesses in all cover; 101 do not.
wits() { printf '[range(%s) | %s + {attribute: "a\\(.)"}]' "$1" "$W1"; } # a jq expression of $1 witnesses
t_cov_w100() {
  rc "$(F556C)" "$(R556K kw100 '.coverage.covered_skips[0].witnesses += '"$(wits 99)")" "$H556N"
  [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && [ "$(grep -c '^- Covered by: ' "$O/comment.md")" = 100 ]
}
t_cov_w101() { unch x "$(F556C)" "$(R556K kw101 '.coverage.covered_skips[0].witnesses += '"$(wits 100)")"; }
for c in "skip_base_sha other than the merge base:base" "a null merge base:nomb" "a plan pass that did not run:noplan" \
  "every selected example skipped:allskip" "101 distinct witnesses:w101"; do
  "t_cov_${c##*:}"; check "covered: ${c%:*} leaves the body as without covered_skips" $?
done
t_cov_w100; check "covered: 100 distinct witnesses cover, one line each" $?

# One spelling per path, and each directory once.
kref "with a trailing slash on dir" '.coverage.covered_skips[0].dir = "examples/mysql/"'
kref "with a dot segment in a witness example" '.coverage.covered_skips[1].witnesses[0].example = "./examples/mysql"'
kref "with an empty segment in a witness example" '.coverage.covered_skips[1].witnesses[0].example = "examples//mysql"'
kref "with a dot segment in path" '.coverage.covered_skips[0].path = "./main.tf"'
kref "with a dir listed twice" '.coverage.covered_skips[1].dir = "examples/mysql"'
t_cov_canon() { render "$(F556C)" "$H556N" "" "$(R556K kcanon '.coverage.covered_skips[1].witnesses[0].example = "examples/mysql/"')" "$TMP/assess-556.txt"; [ "$ST" = 2 ] && empty_out; }
t_cov_canon; check "refused: covered_skips with a witness example that spells a skipped directory another way" $?
t_cov_dupdir() { render "$(F556C)" "$H556N" "" "$(R556K kdupdir '.coverage.covered_skips[1].dir = "examples/mysql" | .coverage.covered_skips[1].gate = "G3"')" "$TMP/assess-556.txt"; [ "$ST" = 2 ] && empty_out; }
t_cov_dupdir; check "refused: covered_skips with a dir listed twice under the same gate" $?

# One skip: the one form, the same count in both tiers.
ONE='.coverage.unplanned = [{dir: "examples/mysql", reason: "plan gate G3"}] | .coverage.covered_skips |= .[:1]'
t_cov_one() {
  rc "$(F556C)" "$(R556K kone "$ONE")" "$H556N"
  [ "$ST" = 0 ] && [ "$(tier)" = COMPACT ] && grep -qF '`validate` passed in all 9 examples; 8 were planned. 1 of 9 examples was not planned because of the review safety checks; the changed code was planned in `examples/autoscaling` (see notes).' "$O/comment.md" || return 1
  rc "$(F556C)" "$(R556K kones "$ONE")" "$H556N" --standard
  [ "$ST" = 0 ] && grep -qF '(ladder rule 7). 1 of 9 examples was not planned because of the review safety checks; the changed code was planned in `examples/autoscaling`, as listed below.' "$O/comment.md" &&
    ! grep -qF 'see notes' "$O/comment.md" && ! grep -qF 'Checks that could not run' "$O/comment.md"
}
t_cov_one; check "covered: one skip takes the one form in both tiers, with the same count, and STANDARD names no notes" $?

# Negative self-check for covered skips.
mutate "version bump skips turn the covered skips off" 's/\$run\.examples\.validated \+ \$run\.examples\.skipped == \$run\.examples\.count/\$run.examples.validated == \$run.examples.count/' t_cov_vbump
mutate "the version bump skips left out of the COMPACT verdict line" 's/if \$x\.skipped > 0 then "compact-validate-skipped" elif/if false then "" elif/' t_vbump
mutate "covered skips still counted at rule 4" 's/ or \.unplanned_open > 0/ or .unplanned > 0/' t_cov_gold
mutate "rule 8 reachable with covered skips" 's/elif has_sev\("LOW"\) or \.covered > 0 or/elif has_sev("LOW") or/' t_cov_rule8
mutate "all or nothing dropped" 's/and all\(\$u\[\]; \. as \$x \| any\(\$cs\[\];/and all(\$u[]; true or any(\$cs[];/' t_cov_partial
mutate "a covered entry that is no skip accepted" 's/and all\(\$cs\[\]; \. as \$x \| any\(\$u\[\];/and all(\$cs[]; true or any(\$u[];/' t_cov_extra
mutate "the plan mode not checked" 's/and all\(\$cs\[\]; \.gate == "design" or \(\.gate \| skip_mode == \$run\.plan_mode\)\)//' t_cov_runner
mutate "the head not checked" 's/\$cs != \[\] and \$cv\.skip_head_sha == \$in\.host\.head_sha/\$cs != []/' t_cov_head
mutate "inert not checked" 's/and \(\$cv\.inert \| not\)//' t_cov_inert
mutate "duplicate skips accepted" 's/and \(\$u \| map\(\.dir\) \| length == \(unique \| length\)\)//' t_cov_dup
mutate "a skipped example accepted as a witness" 's/and all\(\$cs\[\]\.witnesses\[\]; \.example as \$e \| all\(\$u\[\]; \.dir != \$e\)\)//' t_cov_witself
mutate "trigger states not checked" 's/\n\s+and all\(\$b\.triggers\[\]; \(\.state \| IN\("verified", "covered", "inert", "reported"\)\) or floor_ok\)\n/\n/' t_cov_reftrig
mutate "claim states not checked" 's/\n\s+and all\(\$b\.claims\[\]; \.state == "verified"\)\n/\n/' t_cov_refuted
mutate "no trigger and no claim accepted" 's/ and \(\$b\.triggers \+ \$b\.claims\) != \[\]//' t_cov_zero
mutate "validated below count accepted" 's/and \$run\.examples\.validated \+ \$run\.examples\.skipped == \$run\.examples\.count//' t_cov_validated
mutate "other gaps not checked" 's/and \$l\.gaps == 0 and/and/' t_cov_cut
mutate "a triage run accepted" 's/and \(\$l\.triage \| not\)//' t_cov_triage
mutate "unknown signals not checked" 's/and \(any\(\$l\.signals\[\]; \. == "unknown"\) \| not\)//' t_cov_signal
mutate "review findings not checked" 's/and \(any\(\$l\.findings\[\]; \.rule_id \| startswith\("review\."\) and \. != "review\.tool-disputed"\) \| not\)\n//' t_cov_review
mutate "the covered_skips shape not checked" 's/\(\(\.covered_skips \| valid_covered\) and /((true) and /' t_cov_badshape
mutate "the skip SHAs accepted alone" 's/and \(\[has\("covered_skips", "skip_base_sha", "skip_head_sha"\)\] \| unique \| length == 1\)//' t_cov_shaonly
mutate "covered names not allowlisted" 's/dir: \(\$c\.dir \| nm\(allowed\)\)/dir: (\$c.dir | nm(true))/' t_cov_names
mutate "the witness lines left out of section 5" 's/if \$cov != \[\] then covered_lines\("unplanned-covered"; \$cov; \$run\) else/if false then [] else/' t_cov_std
mutate "the COMPACT sentence dropped" 's/\+ \(if \$cov != \[\] then " " \+ covered_sentence\("compact-covered"; \$run; \$cov\)/+ (if false then " " + covered_sentence("compact-covered"; \$run; \$cov)/' t_cov_gold
mutate "What to do with no item rendered" 's/ or \(\(\$cov != \[\] or \$l\.undemonstrated > 0 or \$l\.identical > 0 or \$l\.nonhcl_cap\) and \$items == \[\]\)//' t_cov_rule8_std
mutate "What to do with no item rendered beside undemonstrated coverage" 's/\(\$cov != \[\] or \$l\.undemonstrated > 0 or \$l\.identical > 0 or \$l\.nonhcl_cap\) and \$items == \[\]/(\$cov != [] or \$l.identical > 0 or \$l.nonhcl_cap) and \$items == []/' t_ux
mutate "What to do with no item rendered beside identical plans" 's/ or \$l\.identical > 0 or \$l\.nonhcl_cap\) and \$items == \[\]/ or \$l.nonhcl_cap) and \$items == []/' t_id
mutate "the rule 7 rationale for covered skips alone dropped" 's/elif \$r == 7 and \(any\(\$f\[\]; \.severity == "LOW"\) \| not\) and \$in\.covered > 0 then tx\("rationale-7-covered"\)\n//' t_cov_rule8_std
mutate "the base not checked" 's/ and \$cv\.skip_base_sha == \$in\.host\.merge_base//' t_cov_base
mutate "a plan pass that did not run accepted" 's/and \$run\.plan_ran and \(\$cv\.inert/and (\$cv.inert/' t_cov_noplan
mutate "inert triggers: one inert trigger enough" 's/all\(\.triggers\[\]; \.state == "inert"\)/any(.triggers[]; .state == "inert")/' t_ti_mixed
mutate "inert triggers: no trigger counts" 's/ and \(\.triggers \| length\) > 0\n//' t_ti_none
mutate "inert triggers: a cap with no other unknown ignored" 's/ or \(\$l0 \| has_unknown\)//; s/\.status == "ran" and \.capped == 0 and \(\.triggers/.status == "ran" and (.triggers/' t_ti_capped
mutate "inert triggers: an unverified claim with no other unknown ignored" 's/ or \(\$l0 \| has_unknown\)//; s/\n  and all\(\.triggers\[\]; \.state == "inert"\) and all\(\.claims\[\]; \.state == "verified"\);/\n  and all(.triggers[]; .state == "inert");/' t_ti_claim
mutate "inert triggers: the no example directory line shown" 's/\(if \$run\.coverage\.by_triggers then empty else tx\("unplanned-no-examples"\) end\)/tx("unplanned-no-examples")/' t_ti_noexdir
mutate "inert triggers: another unknown ignored" 's/ or \(\$l0 \| has_unknown\)//' t_ti_gap
mutate "inert triggers: the inert line shown for no example directory" 's/any\(\$run\.coverage\.unplanned\[\]; \.reason != "no example directory"\)/(\$run.coverage.unplanned != [])/' t_ti_noexdir
mutate "inert triggers: the COMPACT line without the inert reading" 's/elif \$run\.coverage\.by_triggers then/elif false then/' t_ti_compact
mutate "inert triggers: the coverage never read as inert" 's/if \$in\.run\.coverage\.inert or \(\$b \| triggers_inert \| not\)/if true/' t_ti_ok
mutate "every example skipped accepted" 's/ and \(\$u \| length\) < \(\$run\.examples\.count \/\/ 0\)//' t_cov_allskip
mutate "the witness cap dropped" 's/and \(witnesses\(\$cs\) \| length\) <= 100/and true/' t_cov_w101
mutate "non-canonical paths accepted" 's/def canon_path: plain_path and [^\n]*/def canon_path: plain_path;/' t_cov_canon
mutate "a dir listed twice accepted" 's/type == "array" and \(map\(\.dir\?\) \| length == \(unique \| length\)\)/type == "array"/' t_cov_dupdir
mutate "the one form of the covered sentence dropped" 's/\+ \(if \$n == 1 then "-one" else "-many" end\); \{count: \$n, total/+ "-many"; {count: \$n, total/' t_cov_one
mutate "STANDARD section 5 keeps its gap heading" 's/section\(if \$cov != \[\] or \(\$nh != \[\] and \$l\.unplanned_open == 0\) then "Examples not planned" else/section(if false then "Examples not planned" else/' t_cov_one
mutate "witnesses not deduplicated" 's/if any\(\.\[\]; \. == \$w\) then \. else \. \+ \[\$w\] end/. + [\$w]/' t_cov_gold
mutate "the downloaded flag ignored" 's/if \$c\.downloaded then "-downloaded" else/if false then "-downloaded" else/' t_cov_dl
mutate "the one witness example not allowlisted" 's/ and \(\$e\[0\] \| allowed\)//' t_cov_names
mutate "one example named for several witness examples" 's/if \(\$e \| length\) == 1 and/if true and/' t_cov_two

# --- Depth (depth.md, verdict.md Rule 4 per depth): the run file's optional depth key, bound to
# the head and host.json's merge base, known keys and values only; an example out of scope is no
# unknown; the comment states the depth, its reasons and what is out of scope.
DIGEST="$(printf 'diff' | shasum -a 256 | cut -c1-64)"
dep() { # depth, jq update -> one depth object, bound to the fixtures' head and merge base
  jq -nc --arg d "$1" --arg h "$HEAD" --arg b "$BASE" --arg x "$DIGEST" '{format: 1, depth: $d,
    reasons: ({"light": ["light-docs-only"], "focused": ["focused-within-limits"], "deep": ["deep-policy"]}[$d]),
    checks_out_of_scope: ({"light": ["A", "B", "D", "G-ladder"], "focused": ["B"], "deep": []}[$d]),
    examples_selected: ["examples/complete"], examples_out_of_scope: (if $d == "focused" then ["examples/other"] else [] end),
    touched_types: [], walk: {complete: ($d != "deep"), unwalked: 0},
    limits: {tf_files: (if $d == "light" then 0 else 2 end), changed_lines: 10, changed_blocks: 1, selected_examples: 1},
    schema_providers: ["head:.:aws=hashicorp/aws:>=5.0"], schema_types: [".:resource:aws_s3_bucket:hashicorp/aws"],
    schema_locks: ["examples/complete:hashicorp/aws=5.1.0"],
    binding: {head_sha: $h, base_sha: $b, merge_base: $b, diff_sha256: $x}} | '"${2:-.}"
}
rund() { runf "$1" ".depth = $(dep "$2" "${3:-.}") | ${4:-.}"; } # name, depth, depth update, run update
# The Review depth section of the last render, without its heading line; empty when absent.
dsec() { awk '/^### Review depth$/ { on = 1; getline; next } on && /^### / { exit } on' "$O/comment.md" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'; }

ladder "light, nothing open" "approve APPROVE" 8 "$NONE" "" "" "$(rund d-light light)"
t_dlight() {
  dsec | cmp -s - <(printf '%s\n' 'Review depth: light. Reasons: `light-docs-only`.' '' \
    'Out of scope at this depth, so not unknowns: Check A, Check B, Check D, Check G beyond its claim reading, the plan pass, the ladder, the provider facts.')
}
t_dlight; check "depth: light states its depth, reason and the checks out of scope, golden" $?
# At light no plan pass runs: verify-pass.sh coverage --no-plan lists every example not planned.
NOPLAN='.coverage = {class: "none", inert: false, unplanned: [{dir: "examples/complete", reason: "no AWS profile named"}]}'
t_dlight_noplan() { render "$NONE" "" "" "$(rund d-lnp light . "$NOPLAN")"; [ "$ST" = 0 ] && [ "$(rule)" = 8 ] && ! grep -qF 'not planned' "$O/comment.md"; }
t_dlight_noplan; check "depth: light, the plan pass out of scope, an example not planned is no unknown (rule 8)" $?
ladder "focused, an example in scope not planned" "inconclusive COMMENT" 4 "$NONE" "" "" "$(rund d-fnp focused . "$NOPLAN")"
ladder "light, an example that did not validate" "inconclusive COMMENT" 4 "$NONE" "" "" "$(rund d-lgap light . '.verify_gaps = [{dir: "examples/complete", reason: "init failed"}]')"
GAPS='.verify_gaps = [{dir: "examples/other", reason: "not run: budget"}] | .coverage = {class: "none", inert: false, unplanned: [{dir: "examples/other", reason: "no AWS profile named"}]}'
t_dfocused() {
  render "$NONE" "" "" "$(rund d-foc focused . "$GAPS")"
  [ "$ST" = 0 ] && [ "$(rule)" = 8 ] && [ "$(verdict)" = "approve APPROVE" ] && ! grep -qF 'Checks that could not run' "$O/comment.md" &&
    dsec | cmp -s - <(printf '%s\n' 'Review depth: focused. Reasons: `focused-within-limits`.' '' \
      'Out of scope at this depth, so not unknowns: Check B, `examples/other`.')
}
t_dfocused; check "depth: focused, an example out of scope that did not verify or plan is no unknown (rule 8)" $?

# --- Profile: the run file's optional profile key renders the reviewer's profile line, in a
# Profile section in STANDARD and as an evidence note in COMPACT; a malformed one is refused.
TREE="$(printf 'tree' | shasum -a 256 | cut -c1-64)"
t_profile() {
  render "$NONE" "" "" "$(runf p-std ".profile = {label: \"shipped:in-repo-modules\", tree: \"$TREE\"}")" "" --standard
  [ "$ST" = 0 ] && awk '/^### Profile$/ { on = 1; getline; next } on && /^### / { exit } on' "$O/comment.md" | sed '/^$/d' |
    cmp -s - <(printf 'Profile: `shipped:in-repo-modules`, profile_tree_sha256 `%s`.\n' "$TREE")
}
t_profile; check "profile: the run file's profile renders the Profile section, golden" $?
t_profile_none() { render "$NONE"; [ "$ST" = 0 ] && ! grep -qF 'Profile' "$O/comment.md"; }
t_profile_none; check "profile: a run file without the key renders no profile line" $?
for bad in '{label: "shipped:../x", tree: "none"}' '{label: "custom", tree: "abc"}' '{label: "custom"}' '{label: "custom", tree: "none", dir: "/x"}'; do
  render "$NONE" "" "" "$(runf p-bad ".profile = $bad")"
  [ "$ST" != 0 ] && empty_out; check "profile: a malformed profile is refused ($bad)" $?
done
ladder "focused, the same gaps in an example in scope" "inconclusive COMMENT" 4 "$NONE" "" "" \
  "$(rund d-foc-in focused . "$(printf '%s' "$GAPS" | sed 's/examples\/other/examples\/complete/g')")"
grep -qxF -- '- Verification of `examples/complete`: not run: budget.' "$O/comment.md"; check "depth: an example in scope that did not verify is still listed in section 5" $?
ladder "deep, an unverified example" "inconclusive COMMENT" 4 "$NONE" "" "" "$(rund d-deep deep . '.verify_gaps = [{dir: "examples/complete", reason: "init failed"}]')"
check "depth: deep states its depth and reasons, nothing out of scope" "$(dsec | cmp -s - <(printf '%s\n' 'Review depth: deep. Reasons: `deep-policy`.'); echo $?)"
ladder "deep, a MEDIUM finding" "block REQUEST_CHANGES" 6 "$(one structure.grouping MEDIUM a.tf 1 "S." "F.")" "" "" "$(rund d-deep6 deep)"
t_dtriage() { render "$NONE" "" "" "$(rund d-tri light . '.triage = true')"; [ "$ST" = 0 ] && [ "$(rule)" = 4 ] && [ "$(verdict)" = "inconclusive COMMENT" ]; }
t_dtriage; check "depth: a triage run at light never approves" $?
render "$NONE" "" "" "$(rund d-tri-f focused . '.triage = true')"
check "depth: a triage run at focused never approves" "$([ "$(rule)" = 4 ]; echo $?)"
# The first 20 out-of-scope items and a count of the rest; a name outside the charset withheld.
t_d20() {
  render "$NONE" "" "" "$(rund d-20 focused '.examples_out_of_scope = ["examples/a b"] + [range(24) | "examples/e\(.)"]')"
  [ "$ST" = 0 ] && dsec | grep -qxF -- "Out of scope at this depth, so not unknowns: Check B, name withheld, $(seq 0 17 | sed 's/.*/`examples\/e&`/' | paste -sd, - | sed 's/,/, /g'), and 6 more."
}
t_d20; check "depth: the first 20 out-of-scope items and the count of the rest, a name outside the charset withheld" $?
# COMPACT puts the depth lines in its details block.
t_dcompact() {
  rc "$(F556)" "$(R556 d556 ".depth = $(dep focused '.examples_out_of_scope = []')")"
  [ "$ST" = 0 ] && [ "$(tier)" = COMPACT ] && [ "$(rule)" = 4 ] &&
    awk '/^<details><summary>Evidence and notes<\/summary>$/ { on = 1 } on' "$O/comment.md" | grep -qxF -- '- Review depth: focused. Reasons: `focused-within-limits`.' &&
    ! grep -q '^### ' "$O/comment.md"
}
t_dcompact; check "depth: COMPACT states the depth in its details block" $?
t_profile_compact() {
  rc "$(F556)" "$(R556 p556 '.profile = {label: "custom", tree: "none"}')"
  [ "$ST" = 0 ] && [ "$(tier)" = COMPACT ] &&
    awk '/^<details><summary>Evidence and notes<\/summary>$/ { on = 1 } on' "$O/comment.md" | grep -qxF -- '- Profile: `custom`, profile_tree_sha256 `none`.'
}
t_profile_compact; check "profile: COMPACT carries the profile line as an evidence note" $?

# Refused: exit 2 and nothing written.
refused "depth: an unknown key" "$NONE" "" "" "$(rund dr-key light '.extra = 1')"
# mtf-facts writes schema_version next to format from the release that adds it; depth.sh drops it,
# so the bound object of the run file never holds it, while the raw report check takes it at 1.
t_dsv() { render "$NONE" "" "" "$(rund dr-sv light '.schema_version = 1')"; [ "$ST" = 2 ] && empty_out; }
t_dsv; check "refused: depth: a bound depth object with schema_version" $?
t_draw() { # the raw report check: no binding, schema_version 1 or none taken, any other value refused
  local o; o="$(dep light 'del(.binding)')"
  raw() { jq -n -L "$REF" --argjson o "$o" "include \"render-comment\"; \$o | $1 | valid_depth_shape(false)"; }
  [ "$(raw .)" = true ] && [ "$(raw '.schema_version = 1')" = true ] && [ "$(raw '.schema_version = 2')" = false ] &&
    [ "$(raw '.schema_version = "1"')" = false ] && [ "$(raw '.schema_version = null')" = false ]
}
t_draw; check "depth: the raw report takes schema_version 1 or none, and refuses any other" $?
refused "depth: an unknown depth" "$NONE" "" "" "$(rund dr-val light '.depth = "shallow"')"
refused "depth: an unknown reason token" "$NONE" "" "" "$(rund dr-tok light '.reasons = ["light-everything"]')"
refused "depth: a reason of another depth" "$NONE" "" "" "$(rund dr-mix light '.reasons = ["focused-within-limits"]')"
refused "depth: Check C out of scope at light" "$NONE" "" "" "$(rund dr-c light '.checks_out_of_scope += ["C"]')"
refused "depth: Check A out of scope at focused" "$NONE" "" "" "$(rund dr-a focused '.checks_out_of_scope = ["A"]')"
refused "depth: Check D out of scope at focused" "$NONE" "" "" "$(rund dr-d focused '.checks_out_of_scope = ["B", "D"]')"
refused "depth: an example out of scope at light" "$NONE" "" "" "$(rund dr-lx light '.examples_out_of_scope = ["examples/other"]')"
ladder "focused with no example" "approve APPROVE" 8 "$NONE" "" "" "$(rund d-noex focused '.reasons = ["focused-within-limits", "focused-no-example"] | .checks_out_of_scope = [] | .examples_selected = [] | .examples_out_of_scope = []')"
refused "depth: a check out of scope at deep" "$NONE" "" "" "$(rund dr-deepc deep '.checks_out_of_scope = ["B"]')"
refused "depth: an example out of scope at deep" "$NONE" "" "" "$(rund dr-deepx deep '.examples_out_of_scope = ["examples/other"]')"
refused "depth: an example both selected and out of scope" "$NONE" "" "" "$(rund dr-both focused '.examples_out_of_scope = ["examples/complete"]')"
refused "depth: an example path with a dot segment" "$NONE" "" "" "$(rund dr-dot focused '.examples_out_of_scope = ["./examples/other"]')"
refused "depth: focused past the limits" "$NONE" "" "" "$(rund dr-lim focused '.limits.changed_lines = 201')"
refused "depth: a schema token outside its pattern" "$NONE" "" "" "$(rund dr-sp light '.schema_types = [".:module:x:hashicorp/aws"]')"
refused "depth: no binding" "$NONE" "" "" "$(rund dr-nob light 'del(.binding)')"
t_dhead() { render "$NONE" "" "" "$(rund dr-head light '.binding.head_sha = "'"$BASE"'"')"; [ "$ST" = 2 ] && empty_out && printf '%s' "$MSG" | grep -qF 'not bound'; }
t_dhead; check "refused: depth: bound to another head" $?
refused "depth: bound to another merge base" "$NONE" "" "" "$(rund dr-mb light '.binding.merge_base = "'"$HEAD"'"')"
t_dnomb() { render "$NONE" "$(host dr-nomb '.merge_base = null')" "" "$(rund dr-nomb light)"; [ "$ST" = 2 ] && empty_out; }
t_dnomb; check "refused: depth: host.json with no merge base" $?

# Byte for byte: without the key, the body is the one the scripts of b3f74cf rendered.
OLD="$TMP/old"; mkdir -p "$OLD"
if git -C "$SRC" cat-file -e b3f74cf^{commit} 2> /dev/null; then
  for x in render-comment.sh render-comment.jq host-records.jq host-pass.sh; do
    git -C "$SRC" show "b3f74cf:.agents/skills/terraform-module-pr-review/references/$x" > "$OLD/$x"
  done
  # The checks file grew a jobless key later; the depth property does not depend on the host pass.
  cp "$REF/host-pass.sh" "$OLD/host-pass.sh"
  # The lock in host.json's state came later and is no render input; the old scripts read the host
  # file without it. The skipped example count came later too, and the old scripts read none.
  t_same() { # render args: the same body from the old scripts and the new
    local keep="$RCU" oh="$TMP/old-host-$oc.json" orun="$TMP/old-run-$oc.json"
    jq 'del(.state.locked, .state.lock_reason)' "${2:-$HOST}" > "$oh"
    jq 'del(.examples.skipped)' "${4:-$RUNF}" > "$orun"
    RCU="$OLD/render-comment.sh"; render "$1" "$oh" "${3:-}" "$orun" "${@:5}"; local a="$O/comment.md" s1="$ST"
    RCU="$keep"; render "$@"; [ "$s1" = 0 ] && [ "$ST" = 0 ] && cmp -s "$a" "$O/comment.md"
  }
  t_same "$NONE"; check "depth absent: nothing open renders as before, byte for byte" $?
  # Worked example 2 now blocks at rule 6 (a known MEDIUM outranks unknowns); its LOW alone is unchanged.
  t_same "$(printf '%s\n' "$WL" | list worked2low)" "$H2" "" "" "$TMP/assess-worked.txt"; check "depth absent: worked example 2 with its LOW alone renders as before, byte for byte" $?
  # A fix per finding: grouping rule 8, later than b3f74cf, prints a fix that every entry shares once.
  jq 'map(.suggested_fix = "Fix \(.id).")' "$TMP/pr410.json" > "$TMP/pr410-fixes.json"
  t_same "$TMP/pr410-fixes.json" "$H410" "" "" "$TMP/assess-410.txt"; check "depth absent: pull request 410 with a fix per finding renders as before, byte for byte" $?
  t_same "$(F556)" "$H556" "" "$(R556 same)" "$TMP/assess-556.txt"; check "depth absent: the COMPACT pull request 556 renders as before, byte for byte" $?
  t_same "$NONE" "" "" "$TMP/run-cov-none.json"; check "depth absent: unplanned examples render as before, byte for byte" $?
else
  echo "skip depth absent: commit b3f74cf is not in this clone"
fi

# --- Closed and merged pull requests: host.json's mergeability not-applicable is no unknown, and
# the body says the verdict describes a pull request that is no longer open. host-records.jq is
# the host pass's; a copy that takes not-applicable on every state stands in for it here, so the
# open case reaches the render.
na() { # render args: the script under test, beside a host-records.jq that takes not-applicable
  # on every state: the host pass refuses it on an open pull request, and the render must still
  # read it as unknown there, so the copy drops that guard (or adds the value to an older grammar).
  local keep="$RCU" d="$TMP/na-$oc/terraform-module-pr-review/references" rr="$TMP/na-$oc/terraform-module-reviewer/references"
  mkdir -p "$d" "$rr"; cp "$RF" "$rr/"
  cp "$(dirname "$RCU")/render-comment.sh" "$(dirname "$RCU")/render-comment.jq" "$REF/host-records.jq" "$REF/host-pass.sh" "$d/"
  perl -0pi -e 's/\n[^\n]*\n  and \(\.signals\.mergeability != "not-applicable" or \.state\.state == "closed"\)//;
    s/\(\.mergeability \| IN\(("pass", "fail", "unknown")\)\)/(.mergeability | IN($1, "not-applicable"))/' "$d/host-records.jq"
  RCU="$d/render-comment.sh"; render "$@"; RCU="$keep"
}
CLAMP='Comment only: this verdict describes a pull request that is no longer open.'
HMERGED="$(host na-merged '.state.state = "closed" | .state.merged = true | .signals.mergeability = "not-applicable"')"
t_merged() {
  na "$NONE" "$HMERGED"
  [ "$ST" = 0 ] && [ "$(rule)" = 8 ] && [ "$(verdict)" = "approve COMMENT" ] &&
    sed -n 3,6p "$O/comment.md" | cmp -s - <(printf '%s\n' '**Good to merge.**' '' "$CLAMP" '') &&
    grep -qxF 'Checks pass. Mergeability: not applicable. No review yet. Threads resolved.' "$O/comment.md"
}
t_merged; check "merged: not-applicable is no unknown, the no longer open line under the verdict, the signal line shows it" $?
na "$(one structure.grouping MEDIUM a.tf 1 "S." "F.")" "$(host na-closed '.state.state = "closed" | .signals.mergeability = "not-applicable"')"
check "closed: a MEDIUM finding blocks, proposes COMMENT, says no longer open" "$([ "$(verdict)" = "block COMMENT" ] && grep -qxF "$CLAMP" "$O/comment.md"; echo $?)"
t_naopen() { na "$NONE" "$(host na-open '.signals.mergeability = "not-applicable"')"; [ "$ST" = 0 ] && [ "$(rule)" = 4 ] && grep -qF 'Mergeability: unknown.' "$O/comment.md" && ! grep -qxF "$CLAMP" "$O/comment.md"; }
t_naopen; check "open: not-applicable reads as unknown, rule 4, no no-longer-open line" $?
render "$NONE" "$(host na-open-real '.signals.mergeability = "not-applicable"')"
check "open: the host records themselves refuse not-applicable on an open pull request" "$([ "$ST" = 2 ] && empty_out; echo $?)"
t_naclosed_line() { render "$NONE" "$(host cl2 '.state.state = "closed"')"; grep -qxF "$CLAMP" "$O/comment.md"; }
t_naclosed_line; check "closed: the line renders with the host records of today too" $?
t_nacompact() {
  na "$(F556)" "$(host na556 '.repo = "example/terraform-aws-rds-aurora" | .number = 556 | .could_not_run = ['"$CUT"'] | .state.state = "closed" | .state.merged = true | .signals.mergeability = "not-applicable"')" "" "$(R556 na556)" "$TMP/assess-556.txt"
  [ "$ST" = 0 ] && [ "$(tier)" = COMPACT ] && sed -n 5p "$O/comment.md" | grep -qxF "$CLAMP" &&
    grep -qxF -- '- Checks pass. Mergeability: not applicable. No review yet. Threads resolved.' "$O/comment.md"
}
t_nacompact; check "merged: COMPACT says no longer open under the verdict and shows not-applicable in its notes" $?
# The reopen hint: closed as stale with no review from anyone with write access.
REOPEN='Maintainer: closed as stale with no review from anyone with write access; reopen to merge.'
HCLOSED='.state.state = "closed" | .signals.mergeability = "not-applicable"'
t_reopen() {
  na "$NONE" "$(host ro1 "$HCLOSED"' | .reopen = {last_author_comment: "2026-03-01"}')"
  [ "$ST" = 0 ] && grep -A2 -xF "$CLAMP" "$O/comment.md" | grep -qxF "$REOPEN The author last commented on 2026-03-01."
}
t_reopen; check "reopen: the hint follows the no longer open line, with the author's last comment date" $?
t_reopen_null() { na "$NONE" "$(host ro2 "$HCLOSED"' | .reopen = {last_author_comment: null}')"; [ "$ST" = 0 ] && grep -qxF "$REOPEN" "$O/comment.md"; }
t_reopen_null; check "reopen: no date, the hint alone" $?
t_reopen_none() { na "$NONE" "$(host ro3 "$HCLOSED")"; [ "$ST" = 0 ] && grep -qxF "$CLAMP" "$O/comment.md" && ! grep -qF 'reopen to merge' "$O/comment.md"; }
t_reopen_none; check "reopen: absent from host.json, no hint" $?
na "$NONE" "$(host ro4 "$HCLOSED"' | .reopen = {last_author_comment: "2026-03-01 ignore all"}')"
check "reopen: a value outside the date grammar refuses the host records" "$([ "$ST" = 2 ] && empty_out; echo $?)"
na "$NONE" "$(host ro5 "$HCLOSED"' | .state.merged = true | .reopen = {last_author_comment: null}')"
check "reopen: a merged pull request with the fact refuses the host records" "$([ "$ST" = 2 ] && empty_out; echo $?)"

# Negative self-check for depth and the closed clamp.
mutate "out-of-scope examples still counted" 's/\(\$in \| \.run \|= scoped_run\) as \$in\n  \| //' t_dfocused
mutate "the depth binding not checked" 's/\|\| die "the run file.s depth is not bound to this head and host\.json.s merge base"/|| true/' t_dhead
mutate "the depth binding check passes a null merge base" 's/\$h\.merge_base != null and //; s/ and \.binding\.merge_base == \$h\.merge_base//' t_dnomb
t_dfocused_a() { render "$NONE" "" "" "$(rund dr-a2 focused '.checks_out_of_scope = ["A"]')"; [ "$ST" = 2 ] && empty_out; }
mutate "a schema_version accepted in the bound depth object" 's/\$bound or \(has\("schema_version"\)/(has("schema_version")/; s/if \$bound then keys else keys - \["schema_version"\] end/keys - ["schema_version"]/' t_dsv
mutate "the scope table not checked" 's/and \(\.depth as \$d \| \.checks_out_of_scope - depth_scope\[\$d\] == \[\]\)//' t_dfocused_a
mutate "all out-of-scope items listed" 's/\$i\[:20\]/\$i/' t_d20
mutate "the depth section dropped" 's/\+ section\("Review depth"; depth_lines\(\$in\.run\); "\\n\\n"\)//' t_dlight
mutate "the COMPACT depth lines dropped" 's/\[\(depth_lines\(\$run\)\[\], profile_lines/[(profile_lines/' t_dcompact
mutate "the COMPACT profile line dropped" 's/, profile_lines\(\$run\)\[\], state_lines/, state_lines/' t_profile_compact
mutate "the Profile section dropped" 's/\+ section\("Profile"; profile_lines\(\$in\.run\); "\\n\\n"\)//' t_profile
mutate "depth example names not allowlisted" 's/\[\$d\.examples_out_of_scope\[\] \| nm\(allowed\)\]/[\$d.examples_out_of_scope[] | nm(true)]/' t_d20
mutate "not-applicable trusted on an open pull request" 's/if \.mergeability == "not-applicable" and \(is_closed\(\$h\) \| not\)/if false/' t_naopen
mutate "the no longer open line dropped" 's/\+ \(if is_closed\(\$h\) then \[tx\("clamp-closed"\)\] else \[\] end\)\n//' t_merged
mutate "the COMPACT no longer open line dropped" 's/\+ \(if is_closed\(\$h\) then \[tx\("clamp-closed"\)\] else \[\] end\) \+ reopen_line/+ reopen_line/' t_nacompact
mutate "the plan pass in scope at light" 's/\| if \.depth\.depth == "light" then \.coverage\.unplanned = \[\] else \. end//' t_dlight_noplan
mutate "triage approves at a depth" 's/\| \.triage or any\(\$g/| any(\$g/' t_dtriage

# --- A profile was named and the plan pass gave no record: its own reason, never "no AWS profile
# named", an unknown at rule 4 in STANDARD with no advice to name a profile.
t_plan_failed() {
  render "$NONE" "" "" "$(runf pnr '.plan_ran = false | .examples = {count: 2, skipped: 0, validated: 2}
    | .coverage = {class: "none", inert: false, unplanned: [{dir: "examples/a", reason: "plan pass did not run: failed"}, {dir: "examples/b", reason: "plan pass did not run: failed"}]}')"
  [ "$ST" = 0 ] && [ "$(rule)" = 4 ] && [ "$(tier)" = STANDARD ] &&
    grep -qxF -- '- 2 examples were not planned: plan pass did not run: failed.' "$O/comment.md" &&
    ! grep -qF 'AWS profile' "$O/comment.md"
}
t_plan_failed; check "coverage: a plan pass that did not run though a profile was named says so, STANDARD, rule 4, no profile advice" $?
render "$NONE" "" "" "$(runf pnr2 '.coverage = {class: "none", inert: false, unplanned: [{dir: "examples/a", reason: "plan pass did not run: refused"}]}')"
check "coverage: a refused plan pass is its own reason" "$([ "$(rule)" = 4 ] && grep -qxF -- '- 1 example was not planned: plan pass did not run: refused.' "$O/comment.md"; echo $?)"
refused "coverage: a plan pass reason outside the list" "$NONE" "" "" "$(runf pnr3 '.coverage = {class: "none", inert: false, unplanned: [{dir: "examples/a", reason: "plan pass did not run: oops"}]}')"
mutate "a plan pass that did not run read as no profile" 's/"plan pass did not run: failed", "plan pass skipped/"no AWS profile named", "plan pass skipped/' t_plan_failed
mutate "the behaviour line one form dropped" 's/\(if \$n == 1 then "-one" else "-many" end\); \{count: \$n\}\);/"-many"; {count: \$n});/' t_one_change

# --- At light the host writes "plan pass skipped at light depth": no unknown, no advice; at any
# other depth, or with no depth, a refused input.
SKIPL='.coverage = {class: "none", inert: false, unplanned: [{dir: "examples/complete", reason: "plan pass skipped at light depth"}]}'
t_skiplight() {
  render "$NONE" "" "" "$(rund d-skl light . "$SKIPL")"
  [ "$ST" = 0 ] && [ "$(rule)" = 8 ] && [ "$(verdict)" = "approve APPROVE" ] && ! grep -qF 'not planned' "$O/comment.md" &&
    ! grep -qF 'AWS profile' "$O/comment.md" && ! grep -qF 'To get a conclusive review' "$O/comment.md"
}
t_skiplight; check "light: plan pass skipped at light depth is no unknown and gives no advice (rule 8)" $?
t_skipfoc() { render "$NONE" "" "" "$(rund d-skf focused . "$SKIPL")"; [ "$ST" = 2 ] && empty_out; }
t_skipfoc; check "refused: plan pass skipped at light depth at focused" $?
refused "plan pass skipped at light depth at deep" "$NONE" "" "" "$(rund d-skd deep . "$SKIPL")"
refused "plan pass skipped at light depth with no depth" "$NONE" "" "" "$(runf d-skn "$SKIPL")"
mutate "the light skip reason accepted at any depth" 's/\n  and \(\(any\(\.coverage\.unplanned\[\]\?; \.reason == "plan pass skipped at light depth"\) \| not\) or \.depth\.depth\? == "light"\)//' t_skipfoc

# --- A gate in the body: section 5 names the gate class, a host token, and never the file; the
# assessment rules say so, and give the words for a pass that planned some examples only.
t_gate_words() {
  awk '/^## Section Order$/ { on = 1; next } on && /^## / { exit } on' "$CF" > "$TMP/so.md"
  grep -qF 'the other examples were not planned: the plan pass stopped at a gate' "$TMP/so.md" &&
    grep -qF 'such as `plan gate G3`, which names the gate class, a host token, and never the file' "$TMP/so.md" &&
    ! grep -qF 'Section 5 lists neither.' "$TMP/so.md"
}
t_gate_words; check "strings: section 1 gives the mixed plan pass words and lets section 5 name the gate class" $?
t_gate_body() {
  render "$NONE" "" "" "$(runf gb '.plan_ran = true | .plan_mode = "laptop" | .coverage = {class: "partial", inert: false, unplanned: [{dir: "examples/s3-import", reason: "plan gate G3"}]}')"
  [ "$ST" = 0 ] && grep -qxF -- '- 1 example was not planned: plan gate G3.' "$O/comment.md" && ! grep -qE '\.tf(:|`)' "$O/comment.md"
}
t_gate_body; check "section 5: a gate stop names the gate class and no file" $?

# --- A closed, unmerged pull request: the block lead says what applies on a reopen, and the
# Checks phrase of the signal line agrees with the job-less line under it.
LEAD_CLOSED="$(jq -nr -L "$REF" 'include "render-comment"; texts["todo-lead-closed"]')"
JL1='.jobless = [{workflow: "pre-commit.yml", conclusion: "failure"}] | .check_runs = []'
t_closed_lead() {
  na "$(one structure.docs-contradict-code HIGH a.tf 1 "S." "F.")" "$(host cl-lead "$HCLOSED"' | .reopen = {last_author_comment: null}')" \
    "$(checks cl-lead unknown "$JL1")"
  [ "$ST" = 0 ] && [ "$(rule)" = 2 ] && [ "$(verdict)" = "block COMMENT" ] &&
    todo | cmp -s - <(printf '%s\n' '### What to do' '' "$LEAD_CLOSED" '' \
      '- [ ] Maintainer: approve or re-run the workflow that never started a job: `pre-commit.yml`.' \
      '- [ ] `structure.docs-contradict-code`: apply the Fix at `a.tf:1`.') &&
    ! grep -qF "$LEAD_BLOCK" "$O/comment.md" && grep -qxF "$REOPEN" "$O/comment.md" &&
    grep -qxF 'Checks: not run, as a workflow ended without starting a job. Mergeability: not applicable. No review yet. Threads resolved.' "$O/comment.md" &&
    grep -qxF 'Checks: workflow `pre-commit.yml` ended `failure` without starting a job, so its tests never ran and say nothing about this change.' "$O/comment.md"
}
t_closed_lead; check "closed: the block lead names the reopen, and the Checks phrase names the job-less run" $?
t_merged_lead() { na "$(one structure.docs-contradict-code HIGH a.tf 1 "S." "F.")" "$HMERGED"; [ "$ST" = 0 ] && todo | grep -qxF "$LEAD_BLOCK"; }
t_merged_lead; check "merged: the block lead is unchanged" $?
t_open_jobless_line() {
  render "$NONE" "" "$(checks jl-open unknown "$JL1")"
  grep -qxF 'Checks: not run, as a workflow ended without starting a job. Mergeable. No review yet. Threads resolved.' "$O/comment.md" || return 1
  render "$NONE" "" "$(checks jl-open-q unknown '.jobless = [{workflow: "pre-commit.yml", conclusion: "failure"}]')"
  grep -qxF 'Checks: unknown, as a workflow ended without starting a job. Mergeable. No review yet. Threads resolved.' "$O/comment.md"
}
t_open_jobless_line; check "checks: a job-less run gives the Checks phrase its reason" $?
render "$NONE" "" "$(checks queued unknown)"
check "checks: a queued check keeps the plain unknown phrase" "$(grep -qxF 'Checks: unknown. Mergeable. No review yet. Threads resolved.' "$O/comment.md"; echo $?)"

# --- Grouping rule 8: entries that share a fix byte for byte print it once, with every location
# listed, and keep one What to do item. One differing fix restores the Fix block of rule 7.
DFIX='In the `terraform` block of `versions.tf`, raise `hashicorp/aws` to the first 6.x version whose schema lists `global_secondary_index.key_schema`. Generated content made stale: the terraform-docs region of `README.md`.'
shared_list() { # name, the last finding's fix
  local l k=0; n=0
  for l in 72 77 266 271 456 461; do
    k=$((k + 1)); f coverage.argument-above-min-version HIGH main.tf "$l" "Line $l sets \`key_schema\`, which the declared floor does not list." "$([ "$k" = 6 ] && printf '%s' "$2" || printf '%s' "$DFIX")"
  done | list "$1"
}
SHLOCS='`main.tf:72`, `main.tf:77`, `main.tf:266`, `main.tf:271`, `main.tf:456`, `main.tf:461`'
t_shared() {
  render "$(shared_list shared "$DFIX")"
  { printf '%s\n' '### What to do' '' "$LEAD_BLOCK" '' "- [ ] \`coverage.argument-above-min-version\` (6): apply the Fix at $SHLOCS." "- [ ] $GEN" '' \
      '### Findings' '' '**HIGH**' '' '- `coverage.argument-above-min-version` (6):'
    for l in 72 77 266 271 456 461; do printf '  - `main.tf:%s` - Line %s sets `key_schema`, which the declared floor does not list.\n' "$l" "$l"; done
    printf '%s\n' "  - Fix for each location above: $DFIX"
  } > "$TMP/shared.md"
  [ "$ST" = 0 ] && [ "$(rule)" = 2 ] && awk '/^### What to do$/ { on = 1 } on' "$O/comment.md" | cmp -s - "$TMP/shared.md"
}
t_shared; check "fix block: six entries sharing one fix print it once, byte for byte" $?
t_shared_differs() {
  render "$(shared_list shared2 "$DFIX Also bump the lock file.")"
  [ "$ST" = 0 ] && grep -qxF '<details><summary>Fix for each location (6)</summary>' "$O/comment.md" &&
    ! grep -qF 'Fix for each location above' "$O/comment.md" && [ "$(grep -c '^- `main.tf:[0-9]*` - Fix: ' "$O/comment.md")" = 6 ] &&
    todo | grep -qxF -- "- [ ] \`coverage.argument-above-min-version\` (6): apply the Fix at $SHLOCS."
}
t_shared_differs; check "fix block: one differing fix keeps the Fix block, one fix per entry" $?
t_shared_two() {
  render "$({ f structure.grouping MEDIUM a.tf 1 "A." "Same."; f structure.grouping MEDIUM b.tf null "B." "Same."; } | list sh2)"
  awk '/^### Findings$/ { on = 1; getline; next } on' "$O/comment.md" | cmp -s - <(printf '%s\n' '**MEDIUM**' '' \
    '- `structure.grouping` (2):' '  - `a.tf:1` - A.' '  - `b.tf` - B.' '  - Fix for each location above: Same.')
}
t_shared_two; check "fix block: two entries sharing one fix print it once" $?
t_shared_collapsed() {
  n=0
  { f structure.grouping MEDIUM a.tf 1 "M." "Fix M."
    for i in 1 2 3 4 5 6 7 8 9 10; do f structure.argument-order LOW "f$i.tf" 2 "Order $i." "Reorder."; done
  } | list shc > /dev/null
  render "$TMP/shc.json"
  { printf '%s\n' '**MEDIUM**' '' '- `structure.grouping` - `a.tf:1` - M.' '  - Fix: Fix M.' '' '**LOW**' '' \
      '<details><summary><code>structure.argument-order</code> (10)</summary>' ''
    for i in 1 2 3 4 5 6 7 8 9 10; do printf -- '- `f%s.tf:2` - Order %s.\n' "$i" "$i"; done
    printf '%s\n' '- Fix for each location above: Reorder.' '' '</details>'
  } > "$TMP/shc.md"
  [ "$(rule)" = 6 ] && awk '/^### Findings$/ { on = 1; getline; next } on' "$O/comment.md" | cmp -s - "$TMP/shc.md"
}
t_shared_collapsed; check "collapse: a collapsed group sharing one fix prints it once, byte for byte" $?

# --- Behaviour evidence when no selected example passes validate at the head: the trigger lines
# say so, from the run file's example counts.
TR6="[$(bt T-001 lifecycle-change unverifiable), $(bt T-002 wrapper-change unverifiable), $(bt T-003 lifecycle-change unverifiable), \
$(bt T-004 literal-argument-change unverifiable), $(bt T-005 lifecycle-change unverifiable), $(bt T-006 literal-argument-change unverifiable)]"
binv() { # name, triggers, validated [, verify_gaps [, count [, skipped]]]
  runf "binv-$1" ".behaviour = {status: \"ran\", reason: null, triggers: $2, claims: [], capped: 0} | .examples = {count: ${5:-3}, skipped: ${6:-0}, validated: $3} | .verify_gaps = ${4:-[]}"
}
NOTF='- 6 behaviour changes not verified: 3 lifecycle-change, 2 literal-argument-change, 1 wrapper-change.'
NOTF_INV='- 6 behaviour changes not verified (the head does not validate in any example): 3 lifecycle-change, 2 literal-argument-change, 1 wrapper-change.'
# Validate never ran where terraform was absent: no clause, though no example validated.
t_binv_absent() {
  render "$NONE" "" "" "$(binv absent "$TR6" 0 '[{dir: "examples/a", reason: "terraform was not installed"}, {dir: "examples/b", reason: "terraform was not installed"}]' 2)"
  [ "$ST" = 0 ] && grep -qxF -- "$NOTF" "$O/comment.md" && ! grep -qF 'does not validate' "$O/comment.md"
}
# A merge base re-run that did not run follows a head that ran validate and failed: the clause holds.
t_binv_mb() {
  render "$NONE" "" "" "$(binv mb "$TR6" 0 '[{dir: "examples/a", reason: "merge base not available"}, {dir: "examples/b", reason: "merge base not run: budget"}]' 2)"
  [ "$ST" = 0 ] && grep -qxF -- "$NOTF_INV" "$O/comment.md"
}
t_binv_zero() {
  render "$NONE" "" "" "$(binv zero "$TR6" 0 '[]' 0)"
  [ "$ST" = 0 ] && grep -qxF -- "$NOTF" "$O/comment.md" && ! grep -qF 'does not validate' "$O/comment.md"
}
t_binvalid() {
  render "$NONE" "" "" "$(binv six "$TR6" 0)"
  [ "$ST" = 0 ] && grep -qxF -- '- 6 behaviour changes not verified (the head does not validate in any example): 3 lifecycle-change, 2 literal-argument-change, 1 wrapper-change.' "$O/comment.md"
}
t_binvalid; check "behaviour: a head that validates in no example is named on the grouped line" $?
render "$NONE" "" "" "$(binv one "[$(bt T-001 wrapper-change unverifiable)]" 0)"
check "behaviour: a head that validates in no example is named on a trigger line" "$(grep -qxF -- '- Behaviour change at `main.tf:2` (wrapper-change): not verified (the head does not validate in any example).' "$O/comment.md"; echo $?)"
render "$NONE" "" "" "$(binv some "$TR6" 1)"
check "behaviour: a head that validates in one example keeps the plain line" "$(grep -qxF -- "$NOTF" "$O/comment.md"; echo $?)"
t_binv_absent; check "behaviour: examples where terraform was not installed get no validate clause" $?
t_binv_mb; check "behaviour: merge base re-runs that did not run keep the validate clause" $?
t_binv_zero; check "behaviour: no example counted gives no validate clause" $?
# Validate never ran in an example skipped as a version bump only: no clause, though none validated.
t_binv_vbump() {
  render "$NONE" "" "" "$(binv vbump "$TR6" 0 '[]' 3 3)"
  [ "$ST" = 0 ] && grep -qxF -- "$NOTF" "$O/comment.md" && ! grep -qF 'does not validate' "$O/comment.md"
}
t_binv_vbump; check "behaviour: examples skipped as a version bump only get no validate clause" $?

mutate "the closed lead dropped" 's/elif \$closed then "todo-lead-closed" //' t_closed_lead
mutate "the job-less Checks phrase dropped" 's/then "-jobless" else "" end/then "" else "" end/' t_open_jobless_line
mutate "a shared fix printed per entry" 's/elif shared_fix then/elif false then/' t_shared
mutate "a shared fix printed per entry in a collapsed block" 's/\(if shared_fix then \[/(if false then [/' t_shared_collapsed
mutate "a fix shared by entries that differ" 's/\| unique \| length\) == 1;/| unique | length) >= 1;/' t_shared_differs
mutate "the validate clause dropped" 's/\(if \$invalid then "-invalid" else "" end\)/""/' t_binvalid
mutate "the validate clause over head-side gaps" 's/\n      and all\(\$run\.verify_gaps\[\]; \.reason \| startswith\("merge base "\)\)//' t_binv_absent
mutate "the validate clause with no example counted" 's/\.count > 0 and \.validated == 0/.validated == 0/' t_binv_zero
mutate "the validate clause over version bump skips" 's/ and \.skipped == 0\)/)/' t_binv_vbump
mutate "skipped examples left out of the example count bound" 's/\.examples\.validated \+ \.examples\.skipped <=/.examples.validated <=/' t_exbad3

# --- A known MEDIUM blocker outranks unknowns (verdict.md, The Ladder, rule 6): block at rule 6,
# REQUEST_CHANGES, with section 5 listing every unknown; a MEDIUM that is a verification gap stays
# an unknown at rule 4.
KM="$(f structure.grouping MEDIUM a.tf 1 "S." "F." | list km)"
RKM="$(runf km '.coverage = {class: "partial", inert: false, unplanned: [{dir: "examples/a", reason: "no AWS profile named"}]}
  | .verify_gaps = [{dir: "examples/b", reason: "not run: environment"}]
  | .behaviour.triggers = [{id: "T-001", file: "main.tf", line: 3, category: "default-change", state: "unverifiable"}]
  | .behaviour.claims = [{claim_id: "C-1", state: "unverifiable"}]')"
HKM="$(host km '.signals.threads = "unknown" | .could_not_run = [{kind: "thread-resolution-unknown"}, {kind: "patch-unavailable", path: "b.tf"}]')"
cat > "$TMP/want-km5.md" <<'WANT'
### Checks that could not run

- Review thread resolution: the thread query was unavailable, so review comments were grouped by reply instead. Whether the open threads are resolved is unknown.
- The patch of `b.tf` was unavailable, so its changes could not be read.
- Verification of `examples/b`: not run: environment.
- 1 example was not planned: no AWS profile named.
  - `examples/a`
- Behaviour change at `main.tf:3` (default-change): not verified.
- Claim C-1 from the description: not verified.
WANT
t_km() {
  render "$KM" "$HKM" "$(checks km unknown)" "$RKM"
  [ "$ST" = 0 ] && [ "$(rule)" = 6 ] && [ "$(verdict)" = "block REQUEST_CHANGES" ] \
    && grep -qxF 'A MEDIUM finding is open. Any MEDIUM finding blocks merge (ladder rule 6).' "$O/comment.md" \
    && awk '/^### Checks that could not run$/ { on = 1 } on && /^### Pull request state$/ { exit } on' "$O/comment.md" | sed '$d' | cmp -s - "$TMP/want-km5.md" \
    && grep -qxF 'Checks: unknown. Mergeable. No review yet. Thread resolution: unknown.' "$O/comment.md" \
    && todo | cmp -s - <(printf '%s\n' '### What to do' '' "$(jq -nr -L "$REF" 'include "render-comment"; texts["todo-lead-block"]')" '' \
         '- [ ] `structure.grouping`: apply the Fix at `a.tf:1`.')
}
t_km; check "known MEDIUM: blocks at rule 6 over every unknown, section 5 byte for byte" $?
t_km_threads() { render "$KM" "$(host kmt '.unresolved_threads = [{path: "a.tf", line: 1}]')"; [ "$(rule)" = 6 ] && [ "$(verdict)" = "block REQUEST_CHANGES" ]; }
t_km_threads; check "known MEDIUM: blocks at rule 6 over unresolved threads" $?
t_km_triage() { render "$KM" "" "" "$(runf kmtr '.triage = true | del(.behaviour)')"; [ "$(rule)" = 6 ] && grep -qxF 'Triage only: the full review of this change has not run yet.' "$O/comment.md"; }
t_km_triage; check "known MEDIUM: a triage run blocks at rule 6, still never approves" $?
t_km_gap() { render "$(one review.check-not-run MEDIUM . null "Check B did not run." "no code change: none." '{"source": "host", "subject": "coverage.argument-unexposed@."}')"; [ "$(rule)" = 4 ] && [ "$(verdict)" = "inconclusive COMMENT" ]; }
t_km_gap; check "known MEDIUM: a MEDIUM review.check-not-run stays an unknown at rule 4" $?
t_bvi; check "known MEDIUM: a MEDIUM review.verification-incomplete stays an unknown at rule 4" $?
t_km_gap_and() { render "$(pair review.verification-incomplete MEDIUM structure.grouping MEDIUM)" "$HKM"; [ "$(rule)" = 6 ]; }
t_km_gap_and; check "known MEDIUM: a gap MEDIUM beside a known one blocks at rule 6" $?
mutate "rule 4 above the known MEDIUM" 's/elif \(\$m \| not\) and \(has_unknown or/elif (has_unknown or/' t_km
mutate "rule 5 above the known MEDIUM" 's/elif \(\$m \| not\) and \.unresolved > 0/elif .unresolved > 0/' t_km_threads
mutate "a gap MEDIUM counted as a known blocker" 's/and \(\.rule_id \| startswith\("review\."\) \| not\)\);/);/' t_km_gap

# Job-less: the COMPACT tier is not taken, so the maintainer item stays; the mutations.
t_jobless_compact() {
  rc "$(F556C)" "$(R556K jlc)" "$H556N"; [ "$(tier)" = COMPACT ] || return 1
  render "$(F556C)" "$H556N" "$(checks jlc unknown "$JL1")" "$(R556K jlc2)" "$TMP/assess-556.txt"
  [ "$ST" = 0 ] && [ "$(tier)" = STANDARD ] && [ "$(rule)" = 7 ] \
    && grep -qxF -- '- [ ] Maintainer: approve or re-run the workflow that never started a job: `pre-commit.yml`.' "$O/comment.md"
}
t_jobless_compact; check "checks: a job-less run forces STANDARD, covered skips beside it" $?
t_jobless_cancelled() { t_jobless_amb mc '.jobless = [{workflow: "pre-commit.yml", conclusion: "cancelled"}] | .check_runs = []'; }
t_jobless_queued() { t_jobless_amb mq '.jobless = [{workflow: "pre-commit.yml", conclusion: "failure"}]'; }
t_jobless_pending() { t_jobless_amb mp '.jobless = [{workflow: "pre-commit.yml", conclusion: "failure"}] | .check_runs = [] | .statuses = {state: "pending", total_count: 1}'; }
t_jobless_reads() { t_jobless_amb mr '.jobless = [{workflow: "pre-commit.yml", conclusion: "failure"}] | .check_runs = [] | .reads = "failed"'; }
mutate "jobless never computed" 's/jobless_only: \(\.jobless != \[\]/jobless_only: (false/' t_jobless
mutate "jobless reaches rule 8" 's/ or \$g\.checks == "jobless" or / or /' t_jobless
mutate "jobless for any conclusion" 's/\n      and all\(\.jobless\[\]; \.conclusion \| IN\("action_required", "failure"\)\)//' t_jobless_cancelled
mutate "jobless beside an open check run" 's/\n      and all\(\.check_runs\[\]; \.status == "completed" and \(\.conclusion \| IN\("success", "neutral", "skipped"\)\)\)//' t_jobless_queued
mutate "jobless with a pending status" 's/\n      and \(\.statuses == null or \.statuses\.total_count == 0 or \.statuses\.state == "success"\)\)/)/' t_jobless_pending
mutate "jobless with a failed read" 's/ and \.reads == "ok" and/ and/' t_jobless_reads
mutate "jobless in COMPACT" 's/\(\$v\.rule \| IN\(4, 7, 8\)\) and \$l\.signals\.checks != "jobless"/($v.rule | IN(4, 7, 8))/' t_jobless_compact
mutate "missing jobs taken as test evidence" 's/ or \(\(\$checks\.jobless \/\/ \[\]\) != \[\]\) then \./ then ./' t_jobless_ci
mutate "the jobless rule 7 rationale dropped" 's/\n    elif \$r == 7 and \(any\(\$f\[\]; \.severity == "LOW"\) \| not\) then tx\("rationale-7-jobless"\)//' t_jobless
mutate "the jobless lead dropped" 's/elif \$rule == 7 and any\(\$items\[\]; \.jobless\) then "todo-lead-7-jobless" //' t_jobless

# --- Provider floor changes (verdict.md, Provider floor changes): a provider-version-floor-change
# trigger leaves rule 4 when a compat.provider-floor-raised finding names its file, or when Check A
# ran and the run file's floors, bound to the head and the merge base, read both floors in its
# directory; otherwise it stays an unknown.
FT='{id: "T-001", file: "versions.tf", line: 7, category: "provider-version-floor-change", state: "unverifiable"}'
RFL() { runf "fl-$1" '.behaviour.triggers = ['"$FT"'] | '"${2:-.}"; }
FLR='{head_sha: "'"$HEAD"'", base_sha: "'"$BASE"'", dirs: [{dir: ".", provider: "hashicorp/aws", old_floor: "6.42.0", floor: "6.44.0", read: true}]}'
FLF="$(f compat.provider-floor-raised LOW versions.tf 7 "The AWS provider floor moves from 6.42 to 6.44." "no code change: state the new floor in the description." | list flf)"
FLX="$(f compat.provider-floor-raised LOW modules/a/versions.tf 7 "The AWS provider floor moves from 6.42 to 6.44." "no code change: state the new floor in the description." | list flx)"
JUDGED='Provider floor changes judged by Check A, which no behaviour level verifies: 1.'
t_fl_finding() {
  render "$FLF" "" "" "$(RFL f)"
  [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && [ "$(verdict)" = "approve with nits COMMENT" ] && grep -qxF "$JUDGED" "$O/comment.md" \
    && grep -qxF 'Behaviour evidence: 1 change classified: 0 verified, 0 covered by a plan, 0 inert, 0 refuted, 1 not verified; 0 claims: 0 verified, 0 refuted, 0 not verified.' "$O/comment.md" \
    && ! grep -qF '### Checks that could not run' "$O/comment.md"
}
t_fl_finding; check "floor: a compat.provider-floor-raised finding naming the file clears the trigger, approve with nits" $?
t_fl_other() { render "$FLX" "" "" "$(RFL o)"; [ "$(rule)" = 4 ] && grep -qxF -- '- Behaviour change at `versions.tf:7` (provider-version-floor-change): not verified.' "$O/comment.md" && ! grep -qF "$JUDGED" "$O/comment.md"; }
t_fl_other; check "floor: a finding at another file leaves the trigger an unknown at rule 4" $?
t_fl_read() { render "$NONE" "" "" "$(RFL r ".floors = $FLR")"; [ "$ST" = 0 ] && [ "$(rule)" = 8 ] && [ "$(verdict)" = "approve APPROVE" ] && grep -qxF "$JUDGED" "$O/comment.md"; }
t_fl_read; check "floor: Check A ran and both floors read clears the trigger" $?
t_fl_unread() { render "$NONE" "" "" "$(RFL "u$oc" "$1")"; [ "$ST" = 0 ] && [ "$(rule)" = 4 ] && ! grep -qF "$JUDGED" "$O/comment.md"; }
t_fl_unread_one() { t_fl_unread ".floors = $FLR | .floors.dirs[0].read = false"; }
t_fl_head() { t_fl_unread ".floors = $FLR | .floors.head_sha = \"$BASE\""; }
t_fl_also() { t_fl_unread ".floors = $FLR | .behaviour.triggers[0].also_categories = [\"default-change\"]"; }
t_fl_unread_one; check "floor: a floor not read leaves the trigger an unknown" $?
t_fl_unread ".floors = $FLR | .floors.dirs += [{dir: \".\", provider: \"hashicorp/random\", old_floor: \"3.1.0\", floor: \"3.6.0\", read: false}]"; check "floor: one provider of the directory not read leaves the trigger an unknown" $?
t_fl_unread ".floors = $FLR | .floors.dirs[0].dir = \"modules/a\""; check "floor: floors of another directory leave the trigger an unknown" $?
t_fl_head; check "floor: floors of another head leave the trigger an unknown" $?
t_fl_unread ".floors = $FLR | .floors.base_sha = \"$HEAD\""; check "floor: floors of another merge base leave the trigger an unknown" $?
t_fl_also; check "floor: a trigger with another category stays an unknown" $?
t_fl_unread "."; check "floor: no floors and no finding leave the trigger an unknown" $?
t_fl_cnr() { render "$(one review.check-not-run LOW . null "Check A did not run." "no code change: none." '{"source": "host", "subject": "compat.provider-floor-raised@."}')" "" "" "$(RFL c ".floors = $FLR")"
  [ "$(rule)" = 4 ] && grep -qxF -- '- Behaviour change at `versions.tf:7` (provider-version-floor-change): not verified.' "$O/comment.md"; }
t_fl_cnr; check "floor: Check A not run keeps the floors from clearing the trigger" $?
t_fl_cnr_lead() { render "$(one review.check-not-run MEDIUM . null "Check A did not run: the base reference is missing, so compat.* was not evaluated." "no code change: none.")" "" "" "$(RFL cl ".floors = $FLR")"
  [ "$(rule)" = 4 ] && grep -qxF -- '- Behaviour change at `versions.tf:7` (provider-version-floor-change): not verified.' "$O/comment.md" && ! grep -qF "$JUDGED" "$O/comment.md"; }
t_fl_cnr_lead; check "floor: a reviewer-written check-not-run with no subject keeps the floors from clearing the trigger, with its section 5 row" $?
mutate "a check-not-run with no subject ignored for Check A" 's/\(\.subject \/\/ null\) == null or //' t_fl_cnr_lead
t_fl_prefix() { render "$NONE" "$(host flp '.prefix = "modules/x"')" "" "$(RFL p ".floors = $FLR | .floors.dirs[0].dir = \"modules/x\"")"; [ "$(rule)" = 8 ]; }
t_fl_prefix; check "floor: the trigger's directory is read under the module root prefix" $?
t_fl_ca() { jq -n -L "$REF" --argjson d '{"depth": "light", "checks_out_of_scope": ["A", "B"]}' 'include "render-comment";
  check_a_ran([]; {triage: false}) and (check_a_ran([]; {triage: true}) | not) and (check_a_ran([]; {triage: false, depth: $d}) | not)' | grep -qx true; }
t_fl_ca; check "floor: Check A out of scope or a triage run is Check A not run" $?
refused "a floors key with another field" "$NONE" "" "" "$(RFL b1 ".floors = $FLR | .floors.extra = 1")"
refused "a floors SHA that is not 40 hex" "$NONE" "" "" "$(RFL b2 ".floors = $FLR | .floors.head_sha = \"abc\"")"
refused "a floors provider outside its grammar" "$NONE" "" "" "$(RFL b3 ".floors = $FLR | .floors.dirs[0].provider = \"aws\"")"
refused "a floors version outside its grammar" "$NONE" "" "" "$(RFL b4 ".floors = $FLR | .floors.dirs[0].floor = \"6.44\"")"
refused "a floors directory that climbs" "$NONE" "" "" "$(RFL b5 ".floors = $FLR | .floors.dirs[0].dir = \"../x\"")"
refused "a floors read that is not a boolean" "$NONE" "" "" "$(RFL b6 ".floors = $FLR | .floors.dirs[0].read = \"yes\"")"
refused "a floors directory and provider listed twice" "$NONE" "" "" "$(RFL b7 ".floors = $FLR | .floors.dirs += .floors.dirs")"
mutate "the finding that names the file ignored" 's/any\(\$findings\[\]; \.rule_id == "compat\.provider-floor-raised" and \.file == \$t\.file\)/false/' t_fl_finding
mutate "the floors read ignored" 's/\$e != \[\] and all\(\$e\[\]; \.read\)/false/' t_fl_read
mutate "an unread floor accepted" 's/\$e != \[\] and all\(\$e\[\]; \.read\)/\$e != []/' t_fl_unread_one
mutate "floors of another head accepted" 's/\$fl\.head_sha == \$h\.head_sha\n       and/true and/' t_fl_head
mutate "another category cleared" 's/\n             and \(\(\(\.also_categories \/\/ \[\]\) - \["provider-version-floor-change"\]\) == \[\]\)//' t_fl_also
mutate "Check A not run ignored" 's/check_a_ran\(\$findings; \$run\) and \$fl != null/\$fl != null/' t_fl_cnr
mutate "judged triggers counted as gaps" 's/select\(\(ci_gated or floor_ok or demo_ok or same_ok\) \| not\)\), \.claims/select((ci_gated or demo_ok or same_ok) | not)), .claims/' t_fl_read

# --- Undemonstrated features (verdict.md, Undemonstrated features): a trigger behaviour-pass.sh
# marked unexercised is undemonstrated coverage, as a covered skip is: approve with nits at best,
# listed as information, with no finding needed. Anything else keeps it an unknown.
UT='{id: "T-001", file: "main.tf", line: 266, category: "unclassified-change", state: "unverifiable", unexercised: true}'
RUX() { runf "ux-$1" '.plan_ran = true | .behaviour.triggers = ['"$UT"', ('"$UT"' | .id = "T-002" | .line = 267 | .category = "dynamic-block-change")] | '"${2:-.}"; }
UXL="$(f examples.feature-undemonstrated LOW examples/complete/main.tf 3 "No example sets idle_timeout." "In examples/complete/main.tf, in module \"lb\", set idle_timeout = 60." | list uxl)"
cmpx() { f "$1" "$2" "$3" 266 "The change alters what callers of the secondary listener get." "needs decision: (a) keep (b) revert." | list "uxc$oc"; }
UNDEMO='Changes to a resource no planned example creates, which no plan can show: 2.'
UXRAT='No finding is open, and a change sets a resource no planned example creates, so no plan shows it. With such a change, approve with nits is the best verdict (ladder rule 7).'
cat > "$TMP/want-ux.txt" <<'WANT'
### Changes no example creates

- Not demonstrated: `main.tf:266` (unclassified-change): no planned example creates this resource, so no plan shows the change.
- Not demonstrated: `main.tf:267` (dynamic-block-change): no planned example creates this resource, so no plan shows the change.
WANT
uxsec() { awk '/^### Changes no example creates$/ { on = 1 } on && /^### / && !/no example creates/ { exit } on' "$O/comment.md" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'; }
t_ux() {
  render "$NONE" "" "" "$(RUX f)"
  [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && [ "$(verdict)" = "approve with nits COMMENT" ] && [ "$(tier)" = STANDARD ] \
    && grep -qxF "$UNDEMO" "$O/comment.md" && grep -qxF "$UXRAT" "$O/comment.md" && uxsec | cmp -s - "$TMP/want-ux.txt" \
    && ! grep -qF '### Checks that could not run' "$O/comment.md" && ! grep -qxF '### What to do' "$O/comment.md" \
    && [ "$(accept "$O/result.json")" = "findings accepted: full" ]
}
t_ux; check "undemonstrated: unexercised triggers alone are approve with nits, STANDARD, listed as information byte for byte, accepted by host-pass.sh" $?
t_ux_low() { render "$UXL" "" "" "$(RUX l)"; [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && uxsec | cmp -s - "$TMP/want-ux.txt" && [ "$(accept "$O/result.json")" = "findings accepted: full" ]; }
t_ux_low; check "undemonstrated: an examples.feature-undemonstrated LOW anywhere is an ordinary LOW beside them" $?
t_ux_keep() { # run update [findings] -> rule 4, the triggers in section 5, nothing cleared
  render "${2:-$NONE}" "" "" "$(RUX "k$oc" "$1")"
  [ "$ST" = 0 ] && [ "$(rule)" = 4 ] && grep -qE '^- Behaviour change at `main\.tf:266` \([a-z-]+\): not verified\.$' "$O/comment.md" \
    && ! grep -qF 'no planned example creates' "$O/comment.md"
}
t_ux_mark() { t_ux_keep '.behaviour.triggers |= map(del(.unexercised))'; }
t_ux_mark; check "undemonstrated: a trigger not marked unexercised stays an unknown" $?
t_ux_noplan() { t_ux_keep '.plan_ran = false'; }
t_ux_noplan; check "undemonstrated: no plan pass leaves the triggers unknowns" $?
t_ux_partial() { t_ux_keep '.coverage = {class: "partial", inert: false, unplanned: [{dir: "examples/x", reason: "plan gate G1"}]}'; }
t_ux_partial; check "undemonstrated: an example not planned leaves the triggers unknowns" $?
t_ux_scope() { t_ux_keep ".depth = $(dep focused)"; }
t_ux_scope; check "undemonstrated: an example out of scope leaves the triggers unknowns" $?
t_ux_cat() { t_ux_keep '.behaviour.triggers |= map(.category = "default-change")'; }
t_ux_cat; check "undemonstrated: a category off the list stays an unknown" $?
t_ux_lit() { t_ux_keep '.behaviour.triggers |= map(.category = "literal-argument-change")'; }
t_ux_lit; check "undemonstrated: a literal argument change stays an unknown" $?
t_ux_also() { t_ux_keep '.behaviour.triggers |= map(.also_categories = ["type-validation-change"])'; }
t_ux_also; check "undemonstrated: a merged category off the list stays an unknown" $?
t_ux_triage() { render "$NONE" "" "" "$(RUX t '.triage = true')"; [ "$(rule)" = 4 ] && ! grep -qF 'no planned example creates' "$O/comment.md"; }
t_ux_triage; check "undemonstrated: a triage run does not clear the triggers" $?
t_ux_compat_low() { t_ux_keep . "$(cmpx compat.expression-behaviour-changed LOW variables.tf)"; }
t_ux_compat_low; check "undemonstrated: a compat LOW in another file of the directory keeps the triggers unknowns" $?
t_ux_compat_med() { render "$(cmpx compat.default-changed MEDIUM main.tf)" "" "" "$(RUX cm)"; [ "$ST" = 0 ] && [ "$(rule)" = 6 ] && grep -qE '^- Behaviour change at `main\.tf:266`' "$O/comment.md"; }
t_ux_compat_med; check "undemonstrated: a compat MEDIUM keeps the triggers in section 5" $?
t_ux_compat_far() { render "$(cmpx compat.expression-behaviour-changed LOW modules/a/main.tf)" "" "" "$(RUX cf)"; [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && uxsec | cmp -s - "$TMP/want-ux.txt"; }
t_ux_compat_far; check "undemonstrated: a compat finding in another module directory does not stop the clearing" $?
t_ux_one() { render "$NONE" "" "" "$(RUX o '.behaviour.triggers[1] |= del(.unexercised)')"; [ "$(rule)" = 4 ] && grep -qF 'Not demonstrated: `main.tf:266`' "$O/comment.md" && grep -qE '^- Behaviour change at `main\.tf:267`' "$O/comment.md"; }
t_ux_one; check "undemonstrated: each trigger is read alone; an unmarked one beside a marked one stays an unknown" $?
refused "an unexercised trigger that is not unverifiable" "$NONE" "" "" "$(RUX r1 '.behaviour.triggers[0].state = "covered"')"
refused "an unexercised mark that is not true" "$NONE" "" "" "$(RUX r2 '.behaviour.triggers[0].unexercised = false')"
refused "an unexercised trigger with sweep evidence" "$NONE" "" "" "$(RUX r3 '.behaviour.triggers[0].complete = false')"
t_ux_grammar() { render "$NONE" "" "" "$(RUX r4 '.behaviour.triggers[0].outstanding = []')"; [ "$ST" != 0 ]; }
t_ux_grammar; check "refused: an unexercised trigger with an outstanding list" $?
mutate "an unmarked trigger cleared" 's/ and \.unexercised == true\n/\n/' t_ux_mark
mutate "the plan pass not required" 's/ and \$run\.plan_ran and / and /' t_ux_noplan
mutate "partial coverage accepted" 's/ and \$run\.coverage\.class == "complete"\n/\n/' t_ux_partial
mutate "an example out of scope accepted" 's/\n     and \(\(\$run\.depth\.examples_out_of_scope \/\/ \[\]\) == \[\]\)\) as \$whole/) as \$whole/' t_ux_scope
mutate "any category cleared" 's/and \(\[\.category, \(\.also_categories \/\/ \[\]\)\[\]\] - demo_categories == \[\]\)/and true/' t_ux_cat
mutate "a literal argument change cleared" 's/def demo_categories: \["dynamic-block-change"/def demo_categories: ["literal-argument-change", "dynamic-block-change"/' t_ux_lit
mutate "the merged categories not read" 's/\[\.category, \(\.also_categories \/\/ \[\]\)\[\]\] - demo_categories/[.category] - demo_categories/' t_ux_also
mutate "a triage run accepted" 's/\(\(\$run\.triage \| not\) and \$run\.plan_ran/(\$run.plan_ran/' t_ux_triage
mutate "a compat finding at LOW ignored" 's/\(\.rule_id \| startswith\("compat\."\)\) and \(\.file \| file_dir\)/(.rule_id | startswith("compat.")) and .severity != "LOW" and (.file | file_dir)/' t_ux_compat_low
mutate "only a compat finding at the same file read" 's/and \(\.file \| file_dir\) == \(\$t\.file \| file_dir\)/and .file == \$t.file/' t_ux_compat_low
mutate "cleared triggers counted as gaps" 's/select\(\(ci_gated or floor_ok or demo_ok or same_ok\) \| not\)\), \.claims/select((ci_gated or floor_ok or same_ok) | not)), .claims/' t_ux
mutate "cleared triggers listed as not verified" 's/select\(\.state == "unverifiable" and \(\(ci_gated or floor_ok or demo_ok or same_ok\) \| not\)\)/select(.state == "unverifiable" and ((ci_gated or floor_ok or same_ok) | not))/' t_ux
mutate "rule 7 not reached by undemonstrated coverage" 's/ or \.undemonstrated > 0 or / or /' t_ux
mutate "the count line dropped" 's/    \+ \(\[\$b\.triggers\[\] \| select\(demo_ok\)\][^\n]*\n//' t_ux
mutate "the information section dropped" 's/     \+ section\("Changes no example creates"[^\n]*\n//' t_ux
mutate "the rule 7 rationale dropped" 's/\n    elif \$r == 7 and \(any\(\$f\[\]; \.severity == "LOW"\) \| not\) and \$in\.undemonstrated > 0 then tx\("rationale-7-undemonstrated"\)//' t_ux
mutate "sweep evidence beside the mark accepted" 's/\n              and \(has\("complete"\) or has\("outstanding"\) or has\("evidence_digest"\) \| not\)\)\)\n/))\n/' t_ux_grammar
t_ux_state() { render "$NONE" "" "" "$(RUX r5 '.behaviour.triggers[0].state = "covered"')"; [ "$ST" != 0 ]; }
mutate "the mark on a trigger that passed accepted" 's/\(\.unexercised == true and \.state == "unverifiable"\n/(.unexercised == true\n/' t_ux_state

# --- Identical plans (verdict.md, Identical plans): a trigger behaviour-pass.sh marked identical
# reads as an undemonstrated one does, under the same conditions: approve with nits at best,
# listed with its examples as information. Anything else keeps it an unknown.
IT='{id: "T-001", file: "variables.tf", line: 40, category: "unclassified-change", state: "unverifiable", identical: ["examples/complete", "examples/minimal"]}'
RID() { runf "id-$1" '.plan_ran = true | .behaviour.triggers = ['"$IT"', ('"$IT"' | .id = "T-002" | .file = "main.tf" | .line = 9 | .category = "dynamic-block-change" | .identical = ["examples/complete"])] | '"${2:-.}"; }
IDL='Added inputs the existing examples plan the same as before, on their default only: 2.'
IDRAT='No finding is open, and an added input planned the same as before in the existing examples, which shows only its default. With such a change, approve with nits is the best verdict (ladder rule 7).'
cat > "$TMP/want-id.txt" <<'WANT'
### Changes the examples plan the same

- Same plan: `variables.tf:40` (unclassified-change): `examples/complete`, `examples/minimal`, as at the merge base, planned the same with the base and the head module, from empty state; the new path is not shown.
- Same plan: `main.tf:9` (dynamic-block-change): `examples/complete`, as at the merge base, planned the same with the base and the head module, from empty state; the new path is not shown.
WANT
idsec() { awk '/^### Changes the examples plan the same$/ { on = 1 } on && /^### / && !/plan the same/ { exit } on' "$O/comment.md" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'; }
t_id() {
  render "$NONE" "" "" "$(RID f)"
  [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && [ "$(verdict)" = "approve with nits COMMENT" ] && [ "$(tier)" = STANDARD ] \
    && grep -qxF "$IDL" "$O/comment.md" && grep -qxF "$IDRAT" "$O/comment.md" && idsec | cmp -s - "$TMP/want-id.txt" \
    && ! grep -qF '### Checks that could not run' "$O/comment.md" && ! grep -qxF '### What to do' "$O/comment.md" \
    && [ "$(accept "$O/result.json")" = "findings accepted: full" ]
}
t_id; check "identical: identical triggers alone are approve with nits, STANDARD, listed with their examples byte for byte, accepted by host-pass.sh" $?
t_id_keep() { # run update [findings] -> rule 4, the trigger in section 5, nothing cleared
  render "${2:-$NONE}" "" "" "$(RID "k$oc" "$1")"
  [ "$ST" = 0 ] && [ "$(rule)" = 4 ] && grep -qE '^- Behaviour change at `variables\.tf:40` \([a-z-]+\): not verified\.$' "$O/comment.md" \
    && ! grep -qF 'Same plan:' "$O/comment.md"
}
IDNRAT="$(jq -nr -L "$REF" 'include "render-comment"; texts["rationale-7-identical-nonhcl"]')"
t_id_nonhcl() {
  render "$NONE" "" "$NHC" "$(RID nh '.behaviour.triggers += [{id: "T-003", file: "package.py", line: 3, category: "non-hcl-dependency", state: "unverifiable"}]')"
  [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && grep -qxF "$IDNRAT" "$O/comment.md" && ! grep -qxF "$IDRAT" "$O/comment.md" && grep -qxF "$IDL" "$O/comment.md"
}
t_id_nonhcl; check "identical: beside a change outside Terraform the rationale gives both reasons" $?
t_id_mark() { t_id_keep '.behaviour.triggers |= map(del(.identical))'; }
t_id_mark; check "identical: a trigger not marked identical stays an unknown" $?
t_id_partial() { t_id_keep '.coverage = {class: "partial", inert: false, unplanned: [{dir: "examples/x", reason: "plan gate G1"}]}'; }
t_id_partial; check "identical: an example not planned leaves the triggers unknowns" $?
t_id_noplan() { t_id_keep '.plan_ran = false'; }
t_id_noplan; check "identical: no plan pass leaves the triggers unknowns" $?
t_id_cat() { t_id_keep '.behaviour.triggers |= map(.category = "default-change")'; }
t_id_cat; check "identical: a category off the list stays an unknown" $?
t_id_compat() { t_id_keep . "$(f compat.default-changed LOW main.tf 3 "The change alters a default." "needs decision: (a) keep (b) revert." | list idc)"; }
t_id_compat; check "identical: a compat finding in the directory keeps the triggers unknowns" $?
t_id_low() { render "$UXL" "" "" "$(RID l)"; [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && idsec | cmp -s - "$TMP/want-id.txt"; }
t_id_low; check "identical: a LOW finding elsewhere is an ordinary LOW beside them" $?
refused "an identical trigger that is not unverifiable" "$NONE" "" "" "$(RID r1 '.behaviour.triggers[0].state = "covered"')"
refused "an identical mark that is no list" "$NONE" "" "" "$(RID r2 '.behaviour.triggers[0].identical = true')"
refused "an identical mark beside unexercised" "$NONE" "" "" "$(RID r3 '.behaviour.triggers[0].unexercised = true')"
refused "an identical example outside the path grammar" "$NONE" "" "" "$(RID r4 '.behaviour.triggers[0].identical = ["../x"]')"
t_id_state() { render "$NONE" "" "" "$(RID r5 '.behaviour.triggers[0].state = "covered"')"; [ "$ST" != 0 ]; }
t_id_beside() { render "$NONE" "" "" "$(RID r6 '.behaviour.triggers[0].unexercised = true')"; [ "$ST" != 0 ]; }
mutate "an unmarked identical trigger cleared" 's/and \(\.identical \| type == "array"\)/and true/' t_id_mark
mutate "any category read as identical" 's/and \(\[\.category, \(\.also_categories \/\/ \[\]\)\[\]\] - same_categories == \[\]\)/and true/' t_id_cat
mutate "identical triggers counted as gaps" 's/select\(\(ci_gated or floor_ok or demo_ok or same_ok\) \| not\)\), \.claims/select((ci_gated or floor_ok or demo_ok) | not)), .claims/' t_id
mutate "rule 7 not reached by identical plans" 's/ or \.identical > 0 or / or /' t_id
mutate "the identical section dropped" 's/     \+ section\("Changes the examples plan the same"/     + [] + section("dropped"/' t_id
mutate "the identical and outside-Terraform rationale dropped" 's/\n    elif \$r == 7 and \(any\(\$f\[\]; \.severity == "LOW"\) \| not\) and \$in\.identical > 0 and \$in\.nonhcl_cap then tx\("rationale-7-identical-nonhcl"\)//' t_id_nonhcl
mutate "the identical rationale dropped" 's/\n    elif \$r == 7 and \(any\(\$f\[\]; \.severity == "LOW"\) \| not\) and \$in\.identical > 0 then tx\("rationale-7-identical"\)//' t_id
mutate "an identical mark on a trigger that passed accepted" 's/and \. == unique\) and \.state == "unverifiable"/and . == unique)/' t_id_state
mutate "an identical mark beside unexercised accepted" 's/ or has\("evidence_digest"\) or has\("unexercised"\) \| not\)/ or has("evidence_digest") | not)/' t_id_beside

# --- Recorded exceptions join the covered skips (verdict.md, Covered safety-gate skips): a
# runner-mode run whose every unplanned example is a recorded exception witnessed by a planned
# example lands at rule 7 at best, all or nothing.
COVX='[{dir: "examples/outpost", gate: "role", path: "main.tf", witnesses: ['"$W1"']}]'
R556X() { R556 "$1" '.plan_mode = "runner" | .coverage.unplanned = [{dir: "examples/outpost", reason: "exception: example assumes a role in another account"}]
  | .coverage += {covered_skips: '"$COVX"', skip_head_sha: "'"$HEAD"'", skip_base_sha: "'"$BASE"'"} | '"${2:-.}"; }
cat > "$TMP/want-556x.txt" <<'WANT'
**Good to merge, with nits.** `validate` passed in all 9 examples; 8 were planned. 1 of 9 examples was not planned because of a recorded exception of the plan pass; the changed code was planned in `examples/autoscaling` (see notes).
- Not planned: `examples/outpost` (recorded exception, it needs a role in another account, in `main.tf`, same at base 89abcde).
- Covered by: `vpc_security_group_ids` planned in `examples/autoscaling` as `module.aurora.aws_rds_cluster.this` at 0123456.
WANT
t_cov_exc() {
  rc "$(F556C)" "$(R556X xgold)" "$H556N"
  [ "$ST" = 0 ] && [ "$(tier)" = COMPACT ] && [ "$(rule)" = 7 ] && [ "$(verdict)" = "approve with nits COMMENT" ] \
    && grep -E '^\*\*Good|^- (Not planned|Covered by): ' "$O/comment.md" | cmp -s - "$TMP/want-556x.txt" || return 1
  rc "$(F556C)" "$(R556X xstd)" "$H556N" --standard
  [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && grep -qxF -- '- Not planned: `examples/outpost` (recorded exception, it needs a role in another account, in `main.tf`, same at base 89abcde).' "$O/comment.md" \
    && grep -qF '1 of 9 examples was not planned because of a recorded exception of the plan pass; the changed code was planned in `examples/autoscaling`, as listed below.' "$O/comment.md" \
    && grep -qxF '### Examples not planned' "$O/comment.md"
}
t_cov_exc; check "covered: a recorded exception with a witness is approve with nits at rule 7, byte for byte" $?
t_cov_exc_docker() { rc "$(F556C)" "$(R556X xd '.coverage.unplanned[0].reason = "exception: needs a Docker daemon" | .coverage.covered_skips[0].gate = "docker"')" "$H556N"
  [ "$(rule)" = 7 ] && grep -qF '(recorded exception, it needs a Docker daemon, in `main.tf`' "$O/comment.md"; }
t_cov_exc_docker; check "covered: a Docker daemon exception with a witness is approve with nits" $?
t_cov_exc_laptop() { unch x "$(F556C)" "$(R556X xl '.plan_mode = "laptop"')"; }
t_cov_exc_laptop; check "covered: an exception entry after a laptop pass is ignored" $?
t_cov_exc_mixed() { unch x "$(F556C)" "$(R556X xm '.coverage.unplanned += [{dir: "examples/mysql", reason: "plan gate G3"}] | .coverage.covered_skips += [{dir: "examples/mysql", gate: "G3", path: "main.tf", witnesses: ['"$W1"']}]')"; }
t_cov_exc_mixed; check "covered: exceptions and gate skips in one run are ignored" $?
t_cov_exc_reason() { unch x "$(F556C)" "$(R556X xr '.coverage.covered_skips[0].gate = "docker"')"; }
t_cov_exc_reason; check "covered: an exception entry under another exception is ignored" $?
t_cov_exc_part() { unch x "$(F556C)" "$(R556X xp '.coverage.unplanned += [{dir: "examples/b", reason: "exception: example assumes a role in another account"}]')"; }
t_cov_exc_part; check "covered: one exception not covered leaves every exception an unknown" $?
t_cov_exc_floor() { rc "$(F556C)" "$(R556X xf '.behaviour.triggers += [{id: "T-002", file: "versions.tf", line: 7, category: "provider-version-floor-change", state: "unverifiable"}] | .floors = '"$FLR")" "$H556N"; [ "$(rule)" = 7 ] && grep -qF 'recorded exception' "$O/comment.md"; }
t_cov_exc_floor; check "covered: a floor trigger judged by Check A does not stop the covered skip" $?
refused "a covered gate outside the list" "$(F556C)" "$H556N" "" "$(R556X xbad '.coverage.covered_skips[0].gate = "G4"')" "$TMP/assess-556.txt"
mutate "exceptions never covered" 's/"role": "exception: example assumes a role in another account", //' t_cov_exc
mutate "the exception mode not checked" 's/if IN\("role", "docker"\) then "runner" else "laptop" end/"laptop"/' t_cov_exc
mutate "the exception lines dropped" 's/\$c \| covered_kind end/"" end/' t_cov_exc
mutate "the exception sentence dropped" 's/\[\$cov\[\] \| covered_kind\]/[\$cov[] | ""]/' t_cov_exc
mutate "a laptop run takes exception entries" 's/and all\(\$cs\[\]; \.gate == "design" or \(\.gate \| skip_mode == \$run\.plan_mode\)\)//' t_cov_exc_laptop

# --- Design skips join the covered skips (verdict.md, Covered safety-gate skips): an example whose
# plan class is an environment reason of the closed list, witnessed by a planned example, in either
# mode; a transient reason or a reason the entry does not match leaves the body as without the key.
COVD='[{dir: "examples/vpc-endpoint", gate: "design", reason: "access-denied", witnesses: ['"$W1"']}]'
R556D() { R556 "$1" '.plan_mode = "laptop" | .coverage.unplanned = [{dir: "examples/vpc-endpoint", reason: "environment (access-denied)"}]
  | .coverage += {covered_skips: '"$COVD"', skip_head_sha: "'"$HEAD"'", skip_base_sha: "'"$BASE"'"} | '"${2:-.}"; }
cat > "$TMP/want-556d.txt" <<'WANT'
**Good to merge, with nits.** `validate` passed in all 9 examples; 8 were planned. 1 of 9 examples was not planned because the review role was denied a data source read there, at head and at base; the changed code was planned in `examples/autoscaling` (see notes).
- Not planned: `examples/vpc-endpoint` (the review role was denied a data source read, `environment (access-denied)`, at head 0123456 and at base 89abcde).
- Covered by: `vpc_security_group_ids` planned in `examples/autoscaling` as `module.aurora.aws_rds_cluster.this` at 0123456.
WANT
t_cov_des() {
  rc "$(F556C)" "$(R556D dgold)" "$H556N"
  [ "$ST" = 0 ] && [ "$(tier)" = COMPACT ] && [ "$(rule)" = 7 ] && [ "$(verdict)" = "approve with nits COMMENT" ] \
    && grep -E '^\*\*Good|^- (Not planned|Covered by): ' "$O/comment.md" | cmp -s - "$TMP/want-556d.txt" || return 1
  rc "$(F556C)" "$(R556D dstd)" "$H556N" --standard
  [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && grep -qxF -- '- Not planned: `examples/vpc-endpoint` (the review role was denied a data source read, `environment (access-denied)`, at head 0123456 and at base 89abcde).' "$O/comment.md" \
    && grep -qF '1 of 9 examples was not planned because the review role was denied a data source read there, at head and at base; the changed code was planned in `examples/autoscaling`, as listed below.' "$O/comment.md" \
    && grep -qxF '### Examples not planned' "$O/comment.md" && ! grep -qF 'could not run' "$O/comment.md"
}
t_cov_des; check "covered: a design skip with a witness is approve with nits at rule 7, named with its reason token" $?
t_cov_des_runner() { rc "$(F556C)" "$(R556D dr '.plan_mode = "runner"')" "$H556N"; [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && grep -qF '`environment (access-denied)`' "$O/comment.md"; }
t_cov_des_runner; check "covered: a design skip after a runner pass is approve with nits" $?
t_cov_des_mixed() {
  rc "$(F556C)" "$(R556D dm '.coverage.unplanned += [{dir: "examples/mysql", reason: "plan gate G3"}] | .coverage.covered_skips += [{dir: "examples/mysql", gate: "G3", path: "main.tf", witnesses: ['"$W1"']}]')" "$H556N"
  [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && grep -qF '2 of 9 examples were not planned, for the reasons in the notes;' "$O/comment.md" \
    && grep -qF -- '- Not planned: `examples/mysql` (G3 hit in `main.tf`' "$O/comment.md" && grep -qF '`environment (access-denied)`' "$O/comment.md"
}
t_cov_des_mixed; check "covered: a design skip beside a covered gate skip is approve with nits, one mixed sentence" $?
t_cov_des_trans() { unch x "$(F556C)" "$(R556D dt '.coverage.unplanned[0].reason = "environment (timeout)"')"; }
t_cov_des_trans; check "covered: a design entry for an example that timed out is ignored" $?
t_cov_des_gate() { unch x "$(F556C)" "$(R556D dg '.coverage.unplanned[0].reason = "plan gate G3"')"; }
t_cov_des_gate; check "covered: a design entry for a gate skip is ignored" $?
t_cov_des_part() { unch x "$(F556C)" "$(R556D dp '.coverage.unplanned += [{dir: "examples/b", reason: "environment (access-denied)"}]')"; }
t_cov_des_part; check "covered: one design skip not covered leaves every skip an unknown" $?
t_cov_des_wit() { unch x "$(F556C)" "$(R556D dw '.coverage.covered_skips[0].witnesses[0].example = "examples/vpc-endpoint"')"; }
t_cov_des_wit; check "covered: a design skip witnessed by itself is ignored" $?
t_cov_des_tok() { render "$(F556C)" "$H556N" "" "$(R556D dbad '.coverage.unplanned[0].reason = "environment (timeout)" | .coverage.covered_skips[0].reason = "timeout"')" "$TMP/assess-556.txt"; [ "$ST" = 2 ] && empty_out; }
t_cov_des_tok; check "refused: a design entry with a transient reason" $?
t_cov_des_nomode() { unch x "$(F556C)" "$(R556D dnm 'del(.plan_mode)')"; }
t_cov_des_nomode; check "covered: a design entry in a run file with no plan mode is ignored" $?
t_cov_des_exc() { # runner mode: a design skip beside a covered recorded exception
  rc "$(F556C)" "$(R556D dx '.plan_mode = "runner" | .coverage.unplanned += [{dir: "examples/outpost", reason: "exception: example assumes a role in another account"}]
    | .coverage.covered_skips += [{dir: "examples/outpost", gate: "role", path: "main.tf", witnesses: ['"$W1"']}]')" "$H556N"
  [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && grep -qF '2 of 9 examples were not planned, for the reasons in the notes;' "$O/comment.md" \
    && grep -qF '(recorded exception, it needs a role in another account' "$O/comment.md" && grep -qF '`environment (access-denied)`' "$O/comment.md"
}
t_cov_des_exc; check "covered: a design skip beside a covered recorded exception after a runner pass is approve with nits" $?
refused "a design entry with a path" "$(F556C)" "$H556N" "" "$(R556D dbadp '.coverage.covered_skips[0].path = "main.tf"')" "$TMP/assess-556.txt"
refused "a gate entry with a reason" "$(F556C)" "$H556N" "" "$(R556K kbadr '.coverage.covered_skips[0].reason = "access-denied"')" "$TMP/assess-556.txt"
mutate "design skips never covered" 's/def entry_reason: if \.gate == "design" then "environment \(\\\(\.reason\)\)" else/def entry_reason: if false then "" else/' t_cov_des
mutate "a transient reason accepted for a design entry" 's/def design_reasons: \["access-denied", "refused-host"\];/def design_reasons: ["access-denied", "refused-host", "timeout"];/' t_cov_des_tok
mutate "a design entry taken for another reason" 's/and \.reason == \(\$x \| entry_reason\)/and true/; s/any\(\$cs\[\]; \.dir == \$x\.dir and entry_reason == \$x\.reason\)/any(\$cs[]; .dir == \$x.dir)/' t_cov_des_trans
mutate "the design lines dropped" 's/\$c \| covered_kind end/"" end/' t_cov_des
mutate "the design sentence dropped" 's/\[\$cov\[\] \| covered_kind\]/[\$cov[] | ""]/' t_cov_des
mutate "a design skip taken with no plan mode" 's/       and \(\$run\.plan_mode \| IN\("laptop", "runner"\)\)\n//' t_cov_des_nomode
mutate "a design skip held to the plan mode" 's/and all\(\$cs\[\]; \.gate == "design" or \(/and all(\$cs[]; (/' t_cov_des_runner

# A design skip of reason refused-host: the runner's plan proxy refused, by design, a host the
# example's data sources read, at head and at base. Only after a runner pass.
COVR='[{dir: "examples/eks-capabilities", gate: "design", reason: "refused-host", witnesses: ['"$W1"']}]'
R556R() { R556 "$1" '.plan_mode = "runner" | .coverage.unplanned = [{dir: "examples/eks-capabilities", reason: "environment (refused-host)"}]
  | .coverage += {covered_skips: '"$COVR"', skip_head_sha: "'"$HEAD"'", skip_base_sha: "'"$BASE"'"} | '"${2:-.}"; }
cat > "$TMP/want-556r.txt" <<'WANT'
**Good to merge, with nits.** `validate` passed in all 9 examples; 8 were planned. 1 of 9 examples was not planned because the plan proxy refuses, by design, a host its data sources read, at head and at base; the changed code was planned in `examples/autoscaling` (see notes).
- Not planned: `examples/eks-capabilities` (the plan proxy refused a host its data sources read, by design, `environment (refused-host)`, at head 0123456 and at base 89abcde).
- Covered by: `vpc_security_group_ids` planned in `examples/autoscaling` as `module.aurora.aws_rds_cluster.this` at 0123456.
WANT
t_cov_ref() {
  rc "$(F556C)" "$(R556R rgold)" "$H556N"
  [ "$ST" = 0 ] && [ "$(tier)" = COMPACT ] && [ "$(rule)" = 7 ] && [ "$(verdict)" = "approve with nits COMMENT" ] \
    && grep -E '^\*\*Good|^- (Not planned|Covered by): ' "$O/comment.md" | cmp -s - "$TMP/want-556r.txt" || return 1
  rc "$(F556C)" "$(R556R rstd)" "$H556N" --standard
  [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && grep -qxF -- '- Not planned: `examples/eks-capabilities` (the plan proxy refused a host its data sources read, by design, `environment (refused-host)`, at head 0123456 and at base 89abcde).' "$O/comment.md" \
    && grep -qF '1 of 9 examples was not planned because the plan proxy refuses, by design, a host its data sources read, at head and at base; the changed code was planned in `examples/autoscaling`, as listed below.' "$O/comment.md"
}
t_cov_ref; check "covered: a refused-host design skip after a runner pass is approve with nits at rule 7, named with its reason token" $?
t_cov_ref_laptop() { unch x "$(F556C)" "$(R556R rl '.plan_mode = "laptop"')"; }
t_cov_ref_laptop; check "covered: a refused-host design entry after a laptop pass is ignored" $?
t_cov_ref_mixed() { # a refused-host and an access-denied design skip: one mixed sentence
  rc "$(F556C)" "$(R556R rm '.coverage.unplanned += [{dir: "examples/vpc-endpoint", reason: "environment (access-denied)"}]
    | .coverage.covered_skips += [{dir: "examples/vpc-endpoint", gate: "design", reason: "access-denied", witnesses: ['"$W1"']}]')" "$H556N"
  [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && grep -qF '2 of 9 examples were not planned, for the reasons in the notes;' "$O/comment.md" \
    && grep -qF '`environment (refused-host)`' "$O/comment.md" && grep -qF '`environment (access-denied)`' "$O/comment.md"
}
t_cov_ref_mixed; check "covered: a refused-host design skip beside an access-denied one is approve with nits, one mixed sentence" $?
t_cov_ref_net() { unch x "$(F556C)" "$(R556R rn '.coverage.unplanned[0].reason = "environment (network)"')"; }
t_cov_ref_net; check "covered: a refused-host entry for an example recorded environment (network) is ignored" $?
mutate "a refused-host design skip taken after a laptop pass" 's/\n       and all\(\$cs\[\]; \.gate != "design" or \.reason != "refused-host" or \$run\.plan_mode == "runner"\)//' t_cov_ref_laptop
mutate "refused-host never a design reason" 's/def design_reasons: \["access-denied", "refused-host"\];/def design_reasons: ["access-denied"];/' t_cov_ref
mutate "refused-host lines worded as a denial" 's/then \(if \.reason == "refused-host" then "-refused" else "-design" end\)/then "-design"/' t_cov_ref

# --- Review follow-ups: a job-less list at host-pass.sh's cap may have lost an entry, so it stays
# unknown; an unresolved provider keeps its directory's floor triggers unknown; review.path-missing
# is no known blocker; the floors merge base is checked.
t_jobless_cap() {
  t_jobless_amb cap "$(jq -nc '[range(0; 10) | {workflow: "w\(.).yml", conclusion: "failure"}]' | sed 's/^/.jobless = /') | .check_runs = []"
}
t_jobless_cap; check "checks: a job-less list at the cap of 10 stays unknown at rule 4" $?
t_jobless_nine() { render "$NONE" "" "$(checks jl9 unknown "$(jq -nc '[range(0; 9) | {workflow: "w\(.).yml", conclusion: "failure"}]' | sed 's/^/.jobless = /') | .check_runs = []")"; [ "$(rule)" = 7 ]; }
t_jobless_nine; check "checks: nine job-less entries are jobless, approve with nits" $?
mutate "a job-less list at the cap taken as whole" 's/ and \(\.jobless \| length\) < 10//' t_jobless_cap
FLU='{head_sha: "'"$HEAD"'", base_sha: "'"$BASE"'", dirs: [{dir: ".", provider: "hashicorp/aws", old_floor: null, floor: null, read: false},
  {dir: ".", provider: "hashicorp/random", old_floor: "3.5.0", floor: "3.6.0", read: true}]}'
t_fl_unresolved() { t_fl_unread ".floors = $FLU"; }
t_fl_unresolved; check "floor: a provider not resolved beside one read leaves the trigger an unknown" $?
t_fl_unread ".floors = $FLU | .floors.dirs[0].provider = null"; check "floor: a source outside the grammar beside one read leaves the trigger an unknown" $?
refused "a floors entry read with no versions" "$NONE" "" "" "$(RFL b8 ".floors = $FLU | .floors.dirs[0].read = true")"
refused "a floors entry read with no provider" "$NONE" "" "" "$(RFL b9 ".floors = $FLR | .floors.dirs[0].provider = null")"
t_fl_base() { t_fl_unread ".floors = $FLR | .floors.base_sha = \"$HEAD\""; }
mutate "floors of another merge base accepted" 's/\n       and \$h\.merge_base != null and \$fl\.base_sha == \$h\.merge_base\)/)/' t_fl_base
t_fl_read_noversion() { render "$NONE" "" "" "$(RFL b10 ".floors = $FLU | .floors.dirs[0].read = true")"; [ "$ST" = 2 ]; }
mutate "a floors entry read with no versions accepted" 's/and \(\(\.read \| not\) or \(\.provider != null and \.floor != null and \(\.old_floor != null or has\("old_floor_none"\)\)\)\)/and true/' t_fl_read_noversion
# A provider the base did not bound, by no entry or no lower bound, is an explicit none: read at its
# head floor it clears beside a read one, unread it keeps the trigger an unknown.
FLN='{head_sha: "'"$HEAD"'", base_sha: "'"$BASE"'", dirs: [{dir: ".", provider: "hashicorp/aws", old_floor: "6.42.0", floor: "6.44.0", read: true},
  {dir: ".", provider: "hashicorp/random", old_floor: null, floor: "3.5.0", old_floor_none: "no_lower_bound", read: true}]}'
t_fl_none() { render "$NONE" "" "" "$(RFL n ".floors = $FLN")"; [ "$ST" = 0 ] && [ "$(rule)" = 8 ] && grep -qxF "$JUDGED" "$O/comment.md"; }
t_fl_none; check "floor: an explicit none read at its head floor beside a read provider clears the trigger" $?
t_fl_unread ".floors = $FLN | .floors.dirs[1].read = false"; check "floor: an explicit none not read keeps the trigger an unknown" $?
t_fl_unread ".floors = $FLN | .floors.dirs[1].old_floor_none = \"no_entry\" | .floors.dirs[1].read = false"; check "floor: a provider with no base entry not read keeps the trigger an unknown" $?
refused "a floors none of another kind" "$NONE" "" "" "$(RFL b11 ".floors = $FLN | .floors.dirs[1].old_floor_none = \"unknown\"")"
refused "a floors none beside an old floor" "$NONE" "" "" "$(RFL b12 ".floors = $FLN | .floors.dirs[1].old_floor = \"3.1.0\"")"
t_fl_none_bad() { render "$NONE" "" "" "$(RFL b13 ".floors = $FLN | .floors.dirs[1].old_floor_none = \"unknown\"")"; [ "$ST" = 2 ]; }
mutate "a floors none of any kind accepted" 's/\(\.old_floor_none \| IN\("no_entry", "no_lower_bound"\)\) and //' t_fl_none_bad
PM="$(f review.path-missing MEDIUM main.tf null "The change names a path the workspace does not have." "no code change: none." | list pm)"
t_pm_unknown() { render "$PM" "$HKM"; [ "$(rule)" = 4 ] && [ "$(verdict)" = "inconclusive COMMENT" ]; }
t_pm_unknown; check "known MEDIUM: review.path-missing with an unknown stays inconclusive at rule 4" $?
t_pm_alone() { render "$PM"; [ "$(rule)" = 6 ] && [ "$(verdict)" = "block REQUEST_CHANGES" ]; }
t_pm_alone; check "known MEDIUM: review.path-missing alone still blocks at rule 6" $?
# Only a registry rule is a known MEDIUM blocker: an unregistered MEDIUM alone is an unknown at rule
# 4, named in section 5; beside a registered MEDIUM and an unknown the registered one blocks at rule 6.
t_unreg_alone() { render "$(one structure.third-party-promotion MEDIUM a.tf 3 "S." "F.")"
  [ "$ST" = 0 ] && [ "$(rule)" = 4 ] && [ "$(verdict)" = "inconclusive COMMENT" ] && grep -qxF -- "$UNREG" "$O/comment.md" &&
    grep -qxF -- "$(jq -nr -L "$REF" 'include "render-comment"; texts["rationale-4-unregistered"]')" "$O/comment.md"; }
t_unreg_alone; check "known MEDIUM: an unregistered MEDIUM alone is inconclusive at rule 4, named in section 5 with its rationale" $?
t_unreg_beside() { render "$(pair structure.grouping MEDIUM structure.third-party-promotion MEDIUM)" "$HKM"
  [ "$ST" = 0 ] && [ "$(rule)" = 6 ] && [ "$(verdict)" = "block REQUEST_CHANGES" ]; }
t_unreg_beside; check "known MEDIUM: an unregistered MEDIUM beside a registered MEDIUM and an unknown blocks at rule 6" $?
mutate "an unregistered MEDIUM counted as a known blocker" 's/def ladder_read\(\$reg\): registered\(\$reg\) or \.severity == "LOW";/def ladder_read(\$reg): true;/' t_unreg_alone
mutate "an unregistered MEDIUM not counted as an unknown" 's/ \+ \(\$unreg \| length\) \+ \(\$in\.run\.verify_gaps/ + (\$in.run.verify_gaps/' t_unreg_alone
mutate "a review.* MEDIUM counted as a known blocker" 's/and \(\.rule_id \| startswith\("review\."\) \| not\)\);/);/' t_pm_unknown

# --- host-pass.sh accept after a prior review: its host_verdict (incremental.jq) must agree with
# the render's ladder on every new rung, or the rendered review is rejected and never posted.
# The prior is a full one, so accept reaches the verdict check and stops there.
ACCP="$TMP/prior-full"; mkdir -p "$ACCP"
for x in carried carried-task scope-task; do echo '[]' > "$ACCP/$x.json"; done
jq -n --arg h "$HEAD" '{format: 1, mode: "full", reason: "first-review", head: $h, previous_head: null,
  previous_merge_base: null, depth: 0, last_full: "2026-01-01T00:00:00Z", scope: [],
  metrics: {changed_since: 0, changed_total: 0, commits: 0, pages: 0}}' > "$ACCP/meta.json"
RULESF="$SRC/.agents/skills/terraform-module-reviewer/references/rule-facts.md"
HPA="$REF/host-pass.sh" # swapped for a mutated copy by acc_mutate
acc() { # the last render's findings and verdict -> accept's status
  bash "$HPA" accept --prior "$ACCP" --findings "$O/findings.json" --result "$O/result.json" --rules "$RULESF" 2>&1 | grep -qx 'findings accepted: full'
}
acc_case() { # name, case function: the case renders, then accept takes its verdict
  "$2" > /dev/null 2>&1; local s=$?
  check "accept: $1" "$([ "$s" = 0 ] && acc; echo $?)"
}
acc_case "a known MEDIUM over unknowns, block at rule 6" t_km
acc_case "a known MEDIUM over unresolved threads, block at rule 6" t_km_threads
acc_case "a jobless Checks signal alone, approve with nits" t_jobless
acc_case "a jobless Checks signal with a LOW, approve with nits" t_jobless_low
acc_case "a floor trigger cleared by its finding, approve with nits" t_fl_finding
acc_case "a floor trigger cleared by the floors read, approve" t_fl_read
acc_case "covered gate skips with no finding, approve with nits" t_cov_rule8
acc_case "a covered recorded exception, approve with nits" t_cov_exc
acc_case "a covered design skip, approve with nits" t_cov_des
acc_case "a covered design skip beside a covered gate skip, approve with nits" t_cov_des_mixed
acc_case "a covered design skip beside a covered recorded exception, approve with nits" t_cov_des_exc
acc_case "a covered refused-host design skip, approve with nits" t_cov_ref
acc_case "a MEDIUM review.path-missing beside an unknown, inconclusive" t_pm_unknown
acc_case "a MEDIUM review.verification-incomplete, inconclusive" t_bvi
acc_case "an unregistered MEDIUM alone, inconclusive" t_unreg_alone
acc_case "an unregistered MEDIUM beside a registered MEDIUM, block at rule 6" t_unreg_beside
t_acc_disputed() { render "$(f review.tool-disputed LOW a.tf 1 "S." "F." | list accdisp)"; [ "$(verdict)" = "approve APPROVE" ]; }
acc_case "a disputed note alone, approve" t_acc_disputed
t_acc_low_disputed() { render "$(pair structure.grouping LOW review.tool-disputed LOW)"; [ "$(rule)" = 7 ]; }
acc_case "a LOW and a note disputing it, approve with nits" t_acc_low_disputed
t_acc_crit_ref() { render "$(f compat.expression-behaviour-changed CRITICAL main.tf 2 "S." "F." | list acccr)" "" "" "$BREF"; [ "$(rule)" = 1 ] && [ "$(verdict)" = "block REQUEST_CHANGES" ]; }
acc_case "a CRITICAL compat finding beside a refuted state, block at rule 1" t_acc_crit_ref
t_acc_hold() { render "$(f compat.type-narrowed CRITICAL a.tf 1 "S." "F." | list acchold)"; [ "$(rule)" = 0 ]; }
acc_case "a CRITICAL compat finding alone, hold for the next major" t_acc_hold
t_acc_vi() { # a verification-incomplete finding alone: inconclusive, and a forged changes suggested refused
  t_bvi > /dev/null 2>&1 && acc || return 1
  jq '.verdict = "changes suggested"' "$O/result.json" > "$O/r2.json" && mv "$O/r2.json" "$O/result.json"; ! acc
}
t_acc_vi; check "accept: a forged changes suggested over review.verification-incomplete is refused" $?
t_acc_hold_forged() { t_acc_hold > /dev/null 2>&1 || return 1; jq '.verdict = "approve"' "$O/result.json" > "$O/r2.json" && mv "$O/r2.json" "$O/result.json"; ! acc; }
t_acc_hold_forged; check "accept: a forged approve over a CRITICAL compat finding is refused" $?
# Toward stricter only: a forged lenient verdict over a known MEDIUM is refused.
t_acc_forged() { t_km > /dev/null 2>&1 || return 1; jq '.verdict = "inconclusive"' "$O/result.json" > "$O/r2.json" && mv "$O/r2.json" "$O/result.json"; ! acc; }
t_acc_forged; check "accept: an inconclusive verdict over a known MEDIUM is refused" $?
t_acc_approve() { t_jobless > /dev/null 2>&1 || return 1; jq '.verdict = "approve"' "$O/result.json" > "$O/r2.json" && mv "$O/r2.json" "$O/result.json"; acc; }
t_acc_approve; check "accept: approve with no finding still follows from the findings" $?
# A prior that fails its check, and a verdict that does not follow, end accept with status 1.
t_acc_badprior() {
  local p="$TMP/prior-bad"; rm -rf "$p"; cp -R "$ACCP" "$p"; echo x > "$p/extra"
  t_km > /dev/null 2>&1 || return 1
  local out; out="$(bash "$HPA" accept --prior "$p" --findings "$O/findings.json" --result "$O/result.json" --rules "$RULESF" 2>&1)"
  [ $? = 1 ] && [ "$out" = "findings rejected: the prior directory did not pass its check" ]
}
t_acc_badprior; check "accept: a prior that fails its check ends accept with status 1" $?
t_acc_exit() {
  t_km > /dev/null 2>&1 || return 1; jq '.verdict = "approve"' "$O/result.json" > "$O/r2.json" && mv "$O/r2.json" "$O/result.json"
  local out; out="$(bash "$HPA" accept --prior "$ACCP" --findings "$O/findings.json" --result "$O/result.json" --rules "$RULESF" 2>&1)"
  [ $? = 1 ] && [ "$out" = "findings rejected: the verdict does not follow from the findings" ]
}
t_acc_exit; check "accept: a verdict that does not follow ends accept with status 1" $?
t_acc_pm() { t_pm_unknown > /dev/null 2>&1 && acc; }
t_acc_jl() { t_jobless > /dev/null 2>&1 && acc; }
acc_mutate() { # name, perl substitution on incremental.jq, case function that holds -> caught when it fails
  local d="$TMP/hp-mut-$oc"; mkdir -p "$d"; cp "$REF/host-pass.sh" "$REF/incremental.jq" "$REF/render-comment.jq" "$d/"
  perl -0pi -e "$2" "$d/incremental.jq"
  if cmp -s "$d/incremental.jq" "$REF/incremental.jq"; then check "self-check: $1 (the mutation changed nothing)" 1; return; fi
  HPA="$d/host-pass.sh"; "$3" > /dev/null 2>&1; local s=$?; HPA="$REF/host-pass.sh"
  check "self-check: $1 is caught" "$([ "$s" != 0 ]; echo $?)"
}
acc_mutate "accept without the known MEDIUM rung" 's/\n    elif \$m then "block"//' t_acc_forged
acc_mutate "accept counting a review.* MEDIUM as a known blocker" 's/ and \(\.rule_id \| startswith\("review\."\) \| not\)\) as \$m/) as \$m/' t_acc_pm
t_acc_unreg() { t_unreg_alone > /dev/null 2>&1 && acc; }
acc_mutate "accept counting an unregistered MEDIUM as a known blocker" 's/map\(select\(\(\.rule_id \| IN\(\$reg\[\]\)\) or \.severity == "LOW"\)\) as \$k/. as \$k/' t_acc_unreg
acc_mutate "accept refusing approve with nits with no LOW" 's/ or \$model == "approve with nits" then/ then/' t_acc_jl
t_acc_d() { t_acc_disputed > /dev/null 2>&1 && acc; }
t_acc_cr() { t_acc_crit_ref > /dev/null 2>&1 && acc; }
acc_mutate "accept reading the disputed note" 's/map\(select\(\.rule_id != "review\.tool-disputed"\)\) as \$f/. as \$f/' t_acc_d
acc_mutate "accept holding over a model's block" 's/then \(if \$model == "block" then "block" else "hold for the next major" end\)/then "hold for the next major"/' t_acc_cr
acc_mutate "accept without review.verification-incomplete" 's/, "review\.verification-incomplete"\)\)/))/' t_acc_vi

# --- Our earlier review (verdict.md, Our Earlier Block; comment-format.md, section 6): the posting
# login's own CHANGES_REQUESTED, the record of it the run read back and the reviewer's judgment of
# each of its blocking findings at the head. APPROVE replaces the block only when every one is
# resolved; COMMENT over it always says it stands; a record that is missing, edited or not bound to
# the review fails closed.
OWNC='{id: 41, state: "CHANGES_REQUESTED", commit_id: "'"$BASE"'", body_sha256: "'"$(printf '%064d' 0)"'"}'
HOWN="$(host own ".own_review = $OWNC")"
eitem() { # id, judgment [, at file, at line]
  jq -nc --arg id "$1" --arg j "$2" --arg af "${3-}" --arg al "${4-}" '{id: $id, rule_id: "structure.wrong-file", severity: "HIGH",
    file: "main.tf", line: 3, judgment: $j, at: (if $af == "" then null else {file: $af, line: ($al | tonumber)} end)}'
}
erun() { # name, record, items JSON [, review id]
  runf "$1" ".earlier = {review_id: ${4:-41}, commit_id: \"$BASE\", record: \"$2\", items: $3}"
}
EOK="$(erun eok ok "[$(eitem F-001 resolved main.tf 9), $(eitem F-002 resolved outputs.tf 2)]")"
EPART="$(erun epart ok "[$(eitem F-001 resolved main.tf 9), $(eitem F-002 partly)]")"
ONELOW="$(one structure.grouping LOW variables.tf 8 "S." "F.")"
cat > "$TMP/earlier-ok.md" <<WANT
### Earlier review

This account requested changes on \`${BASE:0:7}\`. Its blocking findings, judged at this head:

| Earlier finding | Severity | Location | At this head |
|---|---|---|---|
| F-001 \`structure.wrong-file\` | HIGH | \`main.tf:3\` | resolved at \`main.tf:9\` |
| F-002 \`structure.wrong-file\` | HIGH | \`main.tf:3\` | resolved at \`outputs.tf:2\` |

Every blocking finding of that review is resolved at this head.

### Pull request state

Earlier review from this account: changes requested on ${BASE:0:7}; this review replaces it.
WANT
t_own_ok() { render "$NONE" "$HOWN" "" "$EOK"; [ "$ST" = 0 ] && [ "$(verdict)" = "approve APPROVE" ] &&
  awk '/^### Earlier review$/ { on = 1 } on' "$O/comment.md" | cmp -s - "$TMP/earlier-ok.md"; }
t_own_ok; check "earlier review: every blocking finding resolved, approve proposes APPROVE, the table and the replace line byte for byte" $?
t_own_nits() { render "$ONELOW" "$HOWN" "" "$EOK"; [ "$ST" = 0 ] && [ "$(verdict)" = "approve with nits APPROVE" ]; }
t_own_nits; check "earlier review: every blocking finding resolved, approve with nits proposes APPROVE to replace the block" $?
t_own_part() { render "$NONE" "$HOWN" "" "$EPART"; [ "$ST" = 0 ] && [ "$(verdict)" = "approve COMMENT" ] &&
  grep -qxF '| F-002 `structure.wrong-file` | HIGH | `main.tf:3` | partly resolved |' "$O/comment.md" &&
  grep -qxF 'That request for changes stands until this account replaces it or it is dismissed.' "$O/comment.md" &&
  grep -qxF "Earlier review from this account: changes requested on ${BASE:0:7}; it stays in effect until this account replaces it or it is dismissed." "$O/comment.md"; }
t_own_part; check "earlier review: a partly resolved finding keeps the block, approve proposes COMMENT and says the block stands" $?
t_own_missing() { render "$NONE" "$HOWN"; [ "$ST" = 0 ] && [ "$(verdict)" = "approve COMMENT" ] &&
  grep -qxF "This account requested changes on \`${BASE:0:7}\`, and that review cannot be checked against this head: no record of it was kept where it was posted." "$O/comment.md" &&
  grep -qxF 'That request for changes stands until this account replaces it or it is dismissed.' "$O/comment.md"; }
t_own_missing; check "earlier review: no record of the block, approve proposes COMMENT and says why and that it stands" $?
t_own_edited() { render "$NONE" "$HOWN" "" "$(erun eedit edited '[]')"; [ "$ST" = 0 ] && [ "$(verdict)" = "approve COMMENT" ] &&
  grep -qF 'cannot be checked against this head: its body was edited after it was posted.' "$O/comment.md"; }
t_own_edited; check "earlier review: a block whose body was edited since it was posted proposes COMMENT" $?
t_own_unbound() { render "$NONE" "$HOWN" "" "$(erun eother ok "[$(eitem F-001 resolved main.tf 9)]" 40)"; [ "$ST" = 0 ] && [ "$(verdict)" = "approve COMMENT" ] &&
  grep -qF 'cannot be checked against this head: the record kept of it does not match it.' "$O/comment.md"; }
t_own_unbound; check "earlier review: a record of another review id is not read, approve proposes COMMENT" $?
t_own_nojudge() { render "$NONE" "$HOWN" "" "$(erun enoj ok "[$(eitem F-001 not-judged)]")"; [ "$ST" = 0 ] && [ "$(verdict)" = "approve COMMENT" ] &&
  grep -qxF '| F-001 `structure.wrong-file` | HIGH | `main.tf:3` | not judged |' "$O/comment.md"; }
t_own_nojudge; check "earlier review: a finding the reviewer did not judge keeps the block" $?
t_own_block() { render "$(one structure.wrong-file HIGH main.tf 3 "S." "F.")" "$HOWN" "" "$EPART"; [ "$ST" = 0 ] && [ "$(verdict)" = "block REQUEST_CHANGES" ] &&
  grep -qxF "Earlier review from this account: changes requested on ${BASE:0:7}; this review replaces it." "$O/comment.md" &&
  ! grep -qF 'stands until' "$O/comment.md"; }
t_own_block; check "earlier review: a fresh block proposes REQUEST_CHANGES, which replaces the earlier one" $?
t_own_draft() { render "$NONE" "$(host owndraft ".own_review = $OWNC | .state.draft = true")" "" "$EOK"; [ "$ST" = 0 ] && [ "$(verdict)" = "approve COMMENT" ]; }
t_own_draft; check "earlier review: the draft clamp still turns APPROVE into COMMENT" $?
t_own_appr() { render "$NONE" "$(host ownappr ".own_review = ($OWNC | .state = \"APPROVED\")")"; [ "$ST" = 0 ] && [ "$(verdict)" = "approve APPROVE" ] &&
  grep -qxF "Earlier review from this account: approved on ${BASE:0:7}; this review replaces it." "$O/comment.md" && ! grep -q '^### Earlier review$' "$O/comment.md"; }
t_own_appr; check "earlier review: an earlier approval is no block, approve proposes APPROVE and names it in section 6" $?
t_own_compact() { jq ".own_review = $OWNC" "$H556" > "$TMP/h556own.json"; rc "$(F556)" "$(R556 own)" "$TMP/h556own.json"; [ "$ST" = 0 ] && [ "$(tier)" = STANDARD ]; }
t_own_compact; check "earlier review: an earlier block forces STANDARD where COMPACT would fit" $?
t_own_refused() {
  local r
  for r in "$(erun ebad1 ok '[]')" "$(erun ebad2 edited "[$(eitem F-001 resolved main.tf 9)]")" \
      "$(erun ebad3 ok "[$(eitem F-001 resolved)]")" "$(erun ebad4 ok "[$(eitem F-001 partly main.tf 9)]")" \
      "$(erun ebad5 ok "[$(eitem F-001 fixed)]")" "$(erun ebad6 ok "[$(eitem F-001 partly), $(eitem F-001 partly)]")" \
      "$(erun ebad7 kept '[]')"; do
    render "$NONE" "$HOWN" "" "$r"; [ "$ST" = 2 ] && empty_out || return 1
  done
}
t_own_refused; check "earlier review: a run file earlier outside its grammar is refused, nothing written" $?
mutate "APPROVE over an earlier block with a finding not resolved" 's/all\(\$e\.items\[\]; \.judgment == "resolved"\)/true/' t_own_part
mutate "an earlier block left out of the event" 's/elif \$own then \(if \$replace/elif false then (if \$replace/' t_own_missing
mutate "approve with nits never replacing the block" 's/\n       or \(\$v\.verdict == "approve with nits" and \(\(\$l \| \.findings = \[\] \| ladder\)\.rule == 8\)\)//' t_own_nits
mutate "a record of another review read" 's/\$e\.review_id == \$h\.own_review\.id and //' t_own_unbound
mutate "COMPACT over an earlier block" 's/ and \(\$l\.own_block \| not\)//' t_own_compact
mutate "the stands line dropped" 's/\[tx\("earlier-stands"\)\]/[]/' t_own_missing
# Over a cleared earlier block, APPROVE only where the ladder itself would approve: approve with nits
# that also rests on a jobless Checks signal, a covered skip or an undemonstrated trigger proposes
# COMMENT with the stands line, LOW findings with a covered skip included.
STANDS='That request for changes stands until this account replaces it or it is dismissed.'
EOKX='.earlier = {review_id: 41, commit_id: "'"$BASE"'", record: "ok", items: ['"$(eitem F-001 resolved main.tf 9)"']}'
t_own_jobless() { render "$NONE" "$HOWN" "$(checks ojl unknown "$JL"' | .check_runs = []')" "$(runf ojl "$EOKX")"
  [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && [ "$(verdict)" = "approve with nits COMMENT" ] && grep -qxF "$STANDS" "$O/comment.md"; }
t_own_jobless; check "earlier review: a jobless Checks signal over a cleared block proposes COMMENT and says the block stands" $?
t_own_covered() { jq ".own_review = $OWNC" "$H556N" > "$TMP/own-cov.json"; rc "$(F556C)" "$(R556K ocov "$EOKX")" "$TMP/own-cov.json"
  [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && [ "$(verdict)" = "approve with nits COMMENT" ] && grep -qxF "$STANDS" "$O/comment.md"; }
t_own_covered; check "earlier review: LOW findings beside a covered skip over a cleared block propose COMMENT and say the block stands" $?
t_own_undemo() { render "$NONE" "$HOWN" "" "$(RUX own "$EOKX")"
  [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && [ "$(verdict)" = "approve with nits COMMENT" ] && grep -qxF "$STANDS" "$O/comment.md"; }
t_own_undemo; check "earlier review: an undemonstrated trigger over a cleared block proposes COMMENT and says the block stands" $?
EPARTX='.earlier = {review_id: 41, commit_id: "'"$BASE"'", record: "ok", items: ['"$(eitem F-001 partly)"']}'
t_own_identical_stands() { render "$NONE" "$HOWN" "" "$(RID ownst "$EPARTX")"
  [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && [ "$(verdict)" = "approve with nits COMMENT" ] && grep -qxF "$STANDS" "$O/comment.md" \
    && grep -qxF '| F-001 `structure.wrong-file` | HIGH | `main.tf:3` | partly resolved |' "$O/comment.md" && grep -qF 'Same plan:' "$O/comment.md"; }
t_own_identical_stands; check "earlier review: identical triggers beside a standing block propose COMMENT and say the block stands" $?
t_own_identical() { render "$NONE" "$HOWN" "" "$(RID own "$EOKX")"
  [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && [ "$(verdict)" = "approve with nits COMMENT" ] && grep -qxF "$STANDS" "$O/comment.md"; }
t_own_identical; check "earlier review: identical triggers over a cleared block propose COMMENT and say the block stands" $?
mutate "APPROVE over a block with identical triggers" 's/\(\(\$l \| \.findings = \[\] \| ladder\)\.rule == 8\)/true/' t_own_identical
mutate "the stands line dropped beside identical triggers" 's/\[tx\("earlier-stands"\)\]/[]/' t_own_identical_stands
mutate "APPROVE over a block with a jobless Checks signal" 's/\(\(\$l \| \.findings = \[\] \| ladder\)\.rule == 8\)/true/' t_own_jobless
mutate "APPROVE over a block with a covered skip" 's/\(\(\$l \| \.findings = \[\] \| ladder\)\.rule == 8\)/true/' t_own_covered
mutate "APPROVE over a block with an undemonstrated trigger" 's/\(\(\$l \| \.findings = \[\] \| ladder\)\.rule == 8\)/true/' t_own_undemo
mutate "an ok record with no item accepted" 's/\n  and \(\(\.record == "ok"\) == \(\.items != \[\]\)\);/\n  and true;/' t_own_refused
mutate "a partly item with a place accepted" 's/             else \.at == null end\)\)/             else true end))/' t_own_refused
# The record is bound to the earlier review's commit as well as its id; a carried finding keeps its
# id with @ and the review that raised it; and the body follows the event the user confirmed.
t_own_commit() { render "$NONE" "$HOWN" "" "$(runf ecommit '.earlier = {review_id: 41, commit_id: "'"$HEAD"'", record: "ok", items: ['"$(eitem F-001 resolved main.tf 9)"']}')"
  [ "$ST" = 0 ] && [ "$(verdict)" = "approve COMMENT" ] && grep -qF 'cannot be checked against this head: the record kept of it does not match it.' "$O/comment.md"; }
t_own_commit; check "earlier review: a record of another commit is not read, approve proposes COMMENT" $?
t_own_carried() { render "$NONE" "$HOWN" "" "$(erun ecar ok "[$(eitem F-001 resolved main.tf 9), $(eitem F-002@40 not-resolved)]")"
  [ "$ST" = 0 ] && [ "$(verdict)" = "approve COMMENT" ] && grep -qxF '| `F-002@40` `structure.wrong-file` | HIGH | `main.tf:3` | not resolved |' "$O/comment.md"; }
t_own_carried; check "earlier review: a carried finding renders with its id and origin and keeps the block" $?
t_own_confirmed() { render "$NONE" "$HOWN" "" "$EOK" "" --event COMMENT
  [ "$ST" = 0 ] && [ "$(verdict)" = "approve APPROVE" ] && grep -qxF "$STANDS" "$O/comment.md" &&
  grep -qxF "Earlier review from this account: changes requested on ${BASE:0:7}; it stays in effect until this account replaces it or it is dismissed." "$O/comment.md" &&
  ! grep -qF 'this review replaces it' "$O/comment.md"; }
t_own_confirmed; check "earlier review: a confirmed COMMENT carries the stands lines and no replace line, result.json keeps APPROVE" $?
t_own_confirmed_ap() { render "$NONE" "$HOWN" "" "$EPART" "" --event APPROVE
  [ "$ST" = 0 ] && [ "$(verdict)" = "approve COMMENT" ] && grep -qF 'this review replaces it.' "$O/comment.md" && ! grep -qxF "$STANDS" "$O/comment.md"; }
t_own_confirmed_ap; check "earlier review: a confirmed APPROVE over the block says it replaces it and drops the stands line" $?
t_own_badevent() { render "$NONE" "$HOWN" "" "$EOK" "" --event DISMISS; [ "$ST" = 2 ] && empty_out; }
t_own_badevent; check "earlier review: an --event outside the three events is refused" $?
mutate "a record of another commit read" 's/ and \$e\.commit_id == \$h\.own_review\.commit_id//' t_own_commit
mutate "a carried id refused" 's/\(@\[0-9\]\{1,16\}\)\?\$"\)\)/\$"))/' t_own_carried
mutate "the confirmed event ignored" 's/\(\$in\.confirmed \/\/ \$proposed\) as \$event/\$proposed as \$event/' t_own_confirmed
mutate "result.json taking the confirmed event" 's/event: \$proposed, tier: \$tier,/event: \$event, tier: \$tier,/' t_own_confirmed

# A record whose chain is broken: a fresh block replaced a block of ours that could not be checked.
t_own_broken() { render "$NONE" "$HOWN" "" "$(erun ebroken broken '[]')"
  [ "$ST" = 0 ] && [ "$(verdict)" = "approve COMMENT" ] && grep -qxF "$STANDS" "$O/comment.md" &&
  grep -qxF "This account requested changes on \`${BASE:0:7}\`, and that review cannot be checked against this head: it replaced an earlier block of this account that could not be checked, whose requests were never judged." "$O/comment.md"; }
t_own_broken; check "earlier review: a broken chain keeps the block, approve proposes COMMENT and says why" $?
mutate "a broken chain refused as a record state" 's/, "empty", "broken"\]/, "empty"]/' t_own_broken
t_own_broken_identical() { render "$NONE" "$HOWN" "" "$(RID ownbr '.earlier = {review_id: 41, commit_id: "'"$BASE"'", record: "broken", items: []}')"
  [ "$ST" = 0 ] && [ "$(rule)" = 7 ] && [ "$(verdict)" = "approve with nits COMMENT" ] && grep -qxF "$STANDS" "$O/comment.md" && grep -qF 'Same plan:' "$O/comment.md"; }
t_own_broken_identical; check "earlier review: identical triggers beside a broken chain propose COMMENT and say the block stands" $?
mutate "the stands line dropped beside a broken chain and identical triggers" 's/\[tx\("earlier-stands"\)\]/[]/' t_own_broken_identical

echo
if [ "$fails" -eq 0 ]; then echo "render comment: all checks hold"; else echo "render comment: $fails failed"; exit 1; fi
