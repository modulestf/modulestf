#!/bin/bash
# shellcheck disable=SC2319 # "$(<test>; echo $?)" passes the test's own status to check
# Self-check for the behaviour pass of terraform-module-pr-review (references/behaviour-pass.sh),
# with mtf-facts stubbed: the classify and eval steps, the empty ladder record, each refusal and
# its fixed reason, the record lines and the run file object, and the replay of a pull request
# that drops compact() around a list, whose render must be inconclusive. No network.
# Run: tests/behaviour-pass-test.sh
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
REF="$SRC/.agents/skills/terraform-module-pr-review/references"
BP="$REF/behaviour-pass.sh"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/behaviour-pass-test.XXXXXX")" && pwd -P)" && [ -n "$TMP" ] || { echo "FAIL no temporary directory"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
fails=0
HEAD=0123456789abcdef0123456789abcdef01234567
BASE=89abcdef0123456789abcdef0123456789abcdef

check() { # name, status (0 = holds)
  if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

# The module under review: one changed main.tf, as in the replayed pull request.
MOD="$TMP/clone"
mkdir -p "$MOD"
printf 'resource "aws_rds_cluster" "this" {\n  vpc_security_group_ids = concat(aws_security_group.this[*].id, var.vpc_security_group_ids)\n}\n' > "$MOD/main.tf"
printf '[{"filename":"main.tf","status":"modified","additions":1,"deletions":1,"patch":"@@ -1,3 +1,3 @@\\n resource \\"aws_rds_cluster\\" \\"this\\" {\\n-  vpc_security_group_ids = compact(concat(aws_security_group.this[*].id, var.vpc_security_group_ids))\\n+  vpc_security_group_ids = concat(aws_security_group.this[*].id, var.vpc_security_group_ids)\\n }"}]\n' > "$TMP/files.json"

# Contract 2 output of mtf-facts behaviour for that diff: one wrapper change and one unknown
# propagation candidate on the same line.
cat > "$TMP/behaviour-556.json" <<'EOF'
{"schema_version":1,"inert":false,
 "entries":[{"path":"main.tf","change_kind":"modified","inert":false,"trigger_ids":["T-001","T-002"]}],
 "triggers":[
  {"id":"T-001","file":"main.tf","line":2,"category":"wrapper-change","change_kind":"modified",
   "address":"aws_rds_cluster.this","attribute":"vpc_security_group_ids",
   "base_expr":"compact(concat(aws_security_group.this[*].id, var.vpc_security_group_ids))",
   "head_expr":"concat(aws_security_group.this[*].id, var.vpc_security_group_ids)",
   "referenced_inputs":[{"name":"vpc_security_group_ids","type":"list(string)"}],"contextual_refs":["aws_security_group.this"],
   "pure":true,"levels":["L1"],"reason":null,
   "cases":[{"id":"empty","inputs":{"vpc_security_group_ids":{"value":[]}}},{"id":"one-known","inputs":{"vpc_security_group_ids":{"value":["sg-1"]}}},
            {"id":"empty-string-element","inputs":{"vpc_security_group_ids":{"value":[""]}}},{"id":"null-element","inputs":{"vpc_security_group_ids":{"value":[null]}}},
            {"id":"unknown-element","inputs":{"vpc_security_group_ids":{"unknown_elements":[0]}}},{"id":"wholly-unknown","inputs":{"vpc_security_group_ids":{"unknown":true}}}]},
  {"id":"T-002","file":"main.tf","line":2,"category":"unknown-propagation-candidate","change_kind":"modified",
   "address":"aws_rds_cluster.this","attribute":"vpc_security_group_ids",
   "base_expr":"compact(concat(aws_security_group.this[*].id, var.vpc_security_group_ids))",
   "head_expr":"concat(aws_security_group.this[*].id, var.vpc_security_group_ids)",
   "referenced_inputs":[{"name":"vpc_security_group_ids","type":"list(string)"}],"contextual_refs":["aws_security_group.this"],
   "pure":true,"levels":["L1","L3"],"reason":null}],
 "capped":0}
EOF
# Contract 3: the claims the model wrote from the description.
cat > "$TMP/claims-556.json" <<'EOF'
{"schema_version":1,"claims":[
 {"claim_id":"C-1","text":"compact() returns a wholly unknown list when any element is unknown","predicate_type":"expression-output-unknown","params":{"node":"T-001","revision":"base"},"trigger_id":"T-001","file":"main.tf","line":2},
 {"claim_id":"C-2","text":"concat() keeps the length known","predicate_type":"expression-output-length-known","params":{"node":"T-001","revision":"head","length":1},"trigger_id":"T-001","file":"main.tf","line":2},
 {"claim_id":"C-3","text":"the plan shows the change as known after apply","predicate_type":"plan-attribute-unknown","params":{"node":"T-002","revision":"head"},"trigger_id":"T-002","file":"main.tf","line":2}]}
EOF
# Contract 4, with no ladder run: every trigger and claim unverifiable.
cat > "$TMP/eval-556.json" <<'EOF'
{"schema_version":1,"capped":0,
 "triggers":[{"id":"T-001","state":"unverifiable","reason":"no L1 run"},{"id":"T-002","state":"unverifiable","reason":"no L1 or L3 run, no coverage"}],
 "claims":[{"claim_id":"C-1","state":"unverifiable","reason":"no L1 run"},{"claim_id":"C-2","state":"unverifiable","reason":"no L1 run"}],
 "discarded_claims":[{"claim_id":"C-3","reason":"plan predicates need L3 or L4"}]}
EOF

# The stub: subcommand and arguments logged, the output taken from files the case names, the
# ladder record it is handed copied for the test to read.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/mtf-facts" <<EOF
#!/bin/sh
echo "\$*" >> "$TMP/facts.log"
echo "cwd \$PWD" >> "$TMP/facts.log"
case "\$1" in
behaviour)
  while [ \$# -gt 0 ]; do [ "\$1" = --diff ] && cp "\$2" "$TMP/diff-seen.json"; shift; done
  [ -f "$TMP/behaviour.sleep" ] && sleep 5
  [ -f "$TMP/behaviour.rc" ] && exit "\$(cat "$TMP/behaviour.rc")"; cat "$TMP/behaviour.out" ;;
claims-eval)
  while [ \$# -gt 0 ]; do [ "\$1" = --ladder ] && cp "\$2" "$TMP/ladder-seen.json"; shift; done
  [ -f "$TMP/eval.sleep" ] && sleep 5
  [ -f "$TMP/eval.rc" ] && exit "\$(cat "$TMP/eval.rc")"; cat "$TMP/eval.out" ;;
*) exit 2 ;;
esac
EOF
chmod +x "$TMP/bin/mtf-facts"
FACTS="$TMP/bin/mtf-facts"

# setup <case>: fresh out directory and stub state. Sets O.
c=0
setup() {
  c=$((c + 1)); O="$TMP/out-$c"; mkdir -p "$O"
  rm -f "$TMP/behaviour.rc" "$TMP/eval.rc" "$TMP/behaviour.sleep" "$TMP/eval.sleep" "$TMP/facts.log" "$TMP/ladder-seen.json" "$TMP/diff-seen.json"
  cp "$TMP/behaviour-556.json" "$TMP/behaviour.out"; cp "$TMP/eval-556.json" "$TMP/eval.out"
}
classify() { bash "$BP" classify --facts "${F:-$FACTS}" --dir "$MOD" --diff "${DIFF:-$TMP/files.json}" ${PFX:+--prefix "$PFX"} --out "$O" > "$O/classify.txt" 2>&1; }
evalp() { bash "$BP" eval --facts "${F:-$FACTS}" --out "$O" --head "$HEAD" --base-sha "$BASE" "$@" > "$O/eval.txt" 2>&1; }
q() { jq -e "$1" "$O/run-behaviour.json" > /dev/null 2>&1; echo $?; }
notrun() { # name, reason
  check "$1: the run object is not-run with \"$2\"" "$(jq -e --arg r "$2" '. == {status: "not-run", reason: $r, triggers: [], claims: [], capped: 0}' "$O/run-behaviour.json" > /dev/null 2>&1; echo $?)"
  check "$1: the record says not run" "$([ "$(cat "$O/record.txt")" = "behaviour: not run: $2" ]; echo $?)"
}

# --- The replay: classify, then eval with the claims and no ladder record.
setup
classify; st=$?
check "replay: classify exits 0" "$st"
check "replay: classify reports two triggers" "$([ "$(cat "$O/classify.txt")" = "behaviour: ran, 2 triggers, 0 over the cap" ]; echo $?)"
grep -qxF "behaviour $MOD --diff $O/files-module.json --json" "$TMP/facts.log"; check "replay: behaviour runs on the module root with the module-relative files list" $?
cmp -s <(jq -S . "$TMP/files.json") <(jq -S . "$TMP/diff-seen.json"); check "replay: with no prefix the files list is passed as it is" $?
grep -q "^cwd $MOD" "$TMP/facts.log"; check "replay: mtf-facts never runs inside the clone" "$([ $? != 0 ]; echo $?)"
evalp --claims "$TMP/claims-556.json"; st=$?
check "replay: eval exits 0" "$st"
jq -e --arg h "$HEAD" --arg b "$BASE" '. == {schema_version: 1, head_sha: $h, base_sha: $b, terraform_version: null,
  pins: [], runs: [], coverage: {class: "none", examples: []}}' "$TMP/ladder-seen.json" > /dev/null 2>&1
check "replay: with no ladder record, claims-eval gets the empty one" $?
grep -q -- "--claims $TMP/claims-556.json" "$TMP/facts.log"; check "replay: the claims file is passed" $?
grep -q -- "--head-sha $HEAD --base-sha $BASE" "$TMP/facts.log"; check "replay: claims-eval gets the head and base SHAs" $?
cat > "$TMP/want-record" <<'EOF'
behaviour: ran, 2 triggers, 0 over the cap
trigger T-001 `main.tf` line 2 wrapper-change: unverifiable
trigger T-002 `main.tf` line 2 unknown-propagation-candidate: unverifiable
claim C-1 on T-001 at base, expression-output-unknown: unverifiable
claim C-2 on T-001 at head, expression-output-length-known: unverifiable
claim C-3 on T-002 at head, plan-attribute-unknown: discarded
EOF
cmp -s "$TMP/want-record" "$O/record.txt"; check "replay: the record lines" $?
cmp -s "$O/record.txt" "$O/eval.txt"; check "replay: eval prints the record" $?
check "replay: the run object" "$(q '. == {status: "ran", reason: null, capped: 0,
  triggers: [{id: "T-001", file: "main.tf", line: 2, category: "wrapper-change", state: "unverifiable"},
             {id: "T-002", file: "main.tf", line: 2, category: "unknown-propagation-candidate", state: "unverifiable"}],
  claims: [{claim_id: "C-1", state: "unverifiable"}, {claim_id: "C-2", state: "unverifiable"}, {claim_id: "C-3", state: "unverifiable"}]}')"

# The acceptance: the replay rendered with the findings the review returned is inconclusive,
# never approve with nits, and lists every unverified trigger and claim.
RCU="$REF/render-comment.sh"
jq -n '[{id: "F-001", rule_id: "structure.argument-order", severity: "LOW", file: "main.tf", line: 43,
  summary: "`tags` is not the last argument of `aws_rds_cluster.this`.", suggested_fix: "Move `tags` last.", source: "llm"},
  {id: "F-002", rule_id: "compat.expression-behaviour-changed", severity: "LOW", file: "main.tf", line: 2,
  summary: "Empty strings in `var.vpc_security_group_ids` now reach the provider.", suggested_fix: "no code change: none.", source: "llm"}]' > "$TMP/findings.json"
jq -n --arg h "$HEAD" --arg b "$BASE" '{format: 1, repo: "example/terraform-aws-rds-aurora", number: 556,
  head_sha: $h, base_sha: $b, merge_base: $b, prefix: "",
  state: {state: "open", merged: false, draft: false, base_is_default: true, self_authored: false},
  signals: {threads: "pass", review_decision: "none", mergeability: "pass"}, own_review: null,
  could_not_run: [], unresolved_threads: [],
  conversation: {path: "graphql", omitted: null, considered: 0, bot_considered: 0, counts: {}, notes: []},
  related: {status: "not-applicable", open_unlinked: [], sidebar_not_read: false}}' > "$TMP/host.json"
mkdir -p "$TMP/checks" "$TMP/rundir" "$TMP/render"
jq -n --arg h "$HEAD" '{format: 1, head_sha: $h, signal: "pass", reads: "ok", own_check: null, own_check_dropped: 0,
  own_jobs_dropped: 0, own_jobs_unreadable: false, check_runs: [], statuses: {state: "success", total_count: 0}}' > "$TMP/checks/checks.json"
jq -n --slurpfile b "$O/run-behaviour.json" '{format: 1, triage: false, plan_ran: false, verify_gaps: [], behaviour: $b[0],
  coverage: {class: "complete", inert: false, unplanned: []},
  counts: {"instruction-like-text-from-others": 0, "conversation-claims-unread": 0, "review.quoted-claim-unverifiable": 0}}' > "$TMP/run.json"
printf 'Dropping compact() keeps the list length known.\n' > "$TMP/assess.txt"
msg="$(bash "$RCU" --head "$HEAD" --findings "$TMP/findings.json" --host "$TMP/host.json" --checks "$TMP/checks" \
  --run "$TMP/run.json" --assessment "$TMP/assess.txt" --run-dir "$TMP/rundir" --out "$TMP/render" 2>&1)"
check "acceptance: the replay renders inconclusive at rule 4" "$([ "$msg" = "rendered inconclusive (ladder rule 4), proposed event COMMENT" ]; echo $?)"
[ -f "$TMP/render/comment.md" ] && ! grep -qF 'with nits' "$TMP/render/comment.md"; check "acceptance: never approve with nits" $?
cat > "$TMP/want-gaps" <<'EOF'
### Checks that could not run

- Behaviour change at `main.tf:2` (wrapper-change): not verified.
- Behaviour change at `main.tf:2` (unknown-propagation-candidate): not verified.
- Claim C-1 from the description: not verified.
- Claim C-2 from the description: not verified.
- Claim C-3 from the description: not verified.
EOF
awk '/^### Checks that could not run$/ { on = 1 } on && /^### / && !/could not run/ { exit } on' "$TMP/render/comment.md" \
  | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > "$TMP/got-gaps"
cmp -s "$TMP/want-gaps" "$TMP/got-gaps"; check "acceptance: section 5 lists the unverified triggers and claims" $?
grep -qxF 'Behaviour evidence: 2 changes classified: 0 verified, 0 covered by a plan, 0 inert, 0 refuted, 2 not verified; 3 claims: 0 verified, 0 refuted, 3 not verified.' "$TMP/render/comment.md"
check "acceptance: the evidence line" $?
grep -qxF -- '- 5 checks could not run; see Checks that could not run.' "$TMP/render/comment.md"
check "acceptance: What to do counts the five gaps" $?

# --- A ladder record handed in is passed as it is; no claims file means no --claims.
setup
classify
jq -n --arg h "$HEAD" --arg b "$BASE" '{schema_version: 1, head_sha: $h, base_sha: $b, marker: true}' > "$TMP/ladder.json"
evalp --ladder "$TMP/ladder.json"
cmp -s "$TMP/ladder.json" "$TMP/ladder-seen.json"; check "a ladder record is passed through" $?
! grep -q -- '--claims' "$TMP/facts.log"; check "no claims file, no --claims" $?

# --- Inert: no trigger, the record says so and the run object is empty.
setup
printf '{"schema_version":1,"inert":true,"entries":[{"path":"README.md","change_kind":"modified","inert":true,"trigger_ids":[]}],"triggers":[],"capped":0}\n' > "$TMP/behaviour.out"
printf '{"schema_version":1,"capped":0,"triggers":[],"claims":[],"discarded_claims":[]}\n' > "$TMP/eval.out"
printf '[{"filename":"README.md","status":"modified","additions":1,"deletions":1,"patch":"@@ -1 +1 @@\\n-a\\n+b"}]\n' > "$TMP/files-readme.json"
DIFF="$TMP/files-readme.json" classify; evalp
check "inert: the record" "$([ "$(cat "$O/record.txt")" = "behaviour: ran, 0 triggers, 0 over the cap, inert" ]; echo $?)"
check "inert: the run object" "$(q '. == {status: "ran", reason: null, triggers: [], claims: [], capped: 0}')"

# --- Capped triggers are carried.
setup
jq '.capped = 3' "$TMP/behaviour-556.json" > "$TMP/behaviour.out"
jq '.capped = 3' "$TMP/eval-556.json" > "$TMP/eval.out"
classify; evalp --claims "$TMP/claims-556.json"
check "capped: the run object carries the count" "$(q '.capped == 3 and .status == "ran"')"
check "capped: the record head line" "$([ "$(head -n 1 "$O/record.txt")" = "behaviour: ran, 2 triggers, 3 over the cap" ]; echo $?)"

# --- Refusals, each failing closed to not-run with its fixed reason.
setup; F="$TMP/bin/absent" classify; F="$TMP/bin/absent" evalp
notrun "no mtf-facts" "mtf-facts not installed"
setup; echo 2 > "$TMP/behaviour.rc"; classify; evalp
notrun "behaviour exits 2" "mtf-facts failed"
setup; echo 2 > "$TMP/eval.rc"; classify; evalp --claims "$TMP/claims-556.json"
notrun "claims-eval exits 2" "mtf-facts failed"
refuse_b() { # name, jq update of the behaviour output
  setup; jq "$2" "$TMP/behaviour-556.json" > "$TMP/behaviour.out"; classify; evalp --claims "$TMP/claims-556.json"
  notrun "behaviour refused: $1" "output refused"
}
refuse_b "not schema 1" '.schema_version = 2'
refuse_b "an unknown category" '.triggers[0].category = "cosmetic"'
refuse_b "a bad trigger id" '.triggers[0].id = "T-1"'
refuse_b "a duplicate trigger id" '.triggers[1].id = "T-001"'
refuse_b "a path out of the module" '.triggers[0].file = "../x.tf"'
refuse_b "a path with a backtick" '.triggers[0].file = "a`b.tf"'
refuse_b "a line of 0" '.triggers[0].line = 0'
refuse_b "41 triggers" '.triggers = [range(41) as $i | .triggers[0] + {id: ("T-" + ("00\($i)" | .[-3:]))}]'
refuse_b "no capped count" 'del(.capped)'
refuse_b "a required case id outside the pattern" '.triggers[0].cases = [{id: "a b", inputs: {}}]'
refuse_b "a required case that is not an object" '.triggers[0].cases = ["empty"]'
refuse_b "33 required cases" '.triggers[0].cases = [range(33) | {id: "c\(.)", inputs: {}}]'
refuse_b "a required case twice" '.triggers[0].cases = [{id: "empty", inputs: {}}, {id: "empty", inputs: {}}]'
refuse_b "an entry naming a trigger that does not exist" '.entries[0].trigger_ids += ["T-009"]'
refuse_b "a changed file of the diff with no entry" '.entries = []'
setup; printf 'not json' > "$TMP/behaviour.out"; classify; evalp
notrun "behaviour refused: not JSON" "output refused"
setup; head -c 1048577 /dev/zero | tr '\0' ' ' > "$TMP/behaviour.out"; classify; evalp
notrun "behaviour refused: over 1 MiB" "output refused"
refuse_e() { # name, jq update of the claims-eval output
  setup; jq "$2" "$TMP/eval-556.json" > "$TMP/eval.out"; classify; evalp --claims "$TMP/claims-556.json"
  notrun "eval refused: $1" "output refused"
}
refuse_e "a trigger missing" '.triggers |= .[:1]'
refuse_e "a trigger twice" '.triggers += [.triggers[0]]'
refuse_e "a trigger the behaviour has not" '.triggers[0].id = "T-009"'
refuse_e "an unknown trigger state" '.triggers[0].state = "maybe"'
refuse_e "a claim state inert" '.claims[0].state = "inert"'
refuse_e "a claim missing" '.claims |= .[:1]'
refuse_e "a claim both kept and discarded" '.discarded_claims += [{claim_id: "C-1", reason: "x"}]'
refuse_e "a claim the file has not" '.claims[0].claim_id = "C-9"'
refuse_claims() { # name, claims file content
  setup; printf '%s' "$2" > "$TMP/claims-bad.json"; classify; evalp --claims "$TMP/claims-bad.json"
  notrun "claims refused: $1" "claims refused"
  check "claims refused: $1: claims-eval not run" "$([ ! -f "$TMP/ladder-seen.json" ]; echo $?)"
}
refuse_claims "not JSON" 'nope'
refuse_claims "21 claims" "$(jq -c '.claims = [range(21) as $i | .claims[0] + {claim_id: "C-\($i)"}]' "$TMP/claims-556.json")"
refuse_claims "a duplicate claim id" "$(jq -c '.claims[1].claim_id = "C-1"' "$TMP/claims-556.json")"
refuse_claims "a bad claim id" "$(jq -c '.claims[0].claim_id = "X-1"' "$TMP/claims-556.json")"

# --- A ladder record for another head, another base or another schema is refused before
# claims-eval runs.
refuse_l() { # name, jq update of a matching ladder record
  setup; classify
  jq -n --arg h "$HEAD" --arg b "$BASE" '{schema_version: 1, head_sha: $h, base_sha: $b, terraform_version: null, pins: [], runs: [], coverage: {class: "none", examples: []}} | '"$2" > "$TMP/ladder-bad.json"
  evalp --ladder "$TMP/ladder-bad.json"
  notrun "ladder refused: $1" "ladder refused"
  check "ladder refused: $1: claims-eval not run" "$([ ! -f "$TMP/ladder-seen.json" ]; echo $?)"
}
refuse_l "schema 2" '.schema_version = 2'
refuse_l "another head" '.head_sha = "1111111111111111111111111111111111111111"'
refuse_l "another base" '.base_sha = "2222222222222222222222222222222222222222"'
refuse_l "a null head" '.head_sha = null'
setup; printf 'nope' > "$TMP/ladder-bad.json"; classify; evalp --ladder "$TMP/ladder-bad.json"
notrun "ladder refused: not JSON" "ladder refused"

# --- A deadline on every mtf-facts run.
setup; : > "$TMP/behaviour.sleep"; BEHAVIOUR_PASS_TIMEOUT=1 classify; evalp
notrun "behaviour over the deadline" "mtf-facts timed out"
setup; : > "$TMP/eval.sleep"; classify; BEHAVIOUR_PASS_TIMEOUT=1 evalp --claims "$TMP/claims-556.json"
notrun "claims-eval over the deadline" "mtf-facts timed out"

# --- The files list: the module root prefix is stripped, files outside it are left out, a
# rename is checked at its old path too, and unchanged or tool-owned paths need no entry.
setup
jq '[.[0] + {filename: "mod/main.tf"}, {filename: "other/x.tf", status: "modified"}, {filename: "mod/.terraform/x", status: "added"}, {filename: "mod/README.md", status: "unchanged"}]' "$TMP/files.json" > "$TMP/files-pfx.json"
DIFF="$TMP/files-pfx.json" PFX=mod classify
check "prefix: classify accepts" "$([ -f "$O/behaviour.json" ]; echo $?)"
jq -e '[.[].filename] == ["main.tf", ".terraform/x", "README.md"]' "$TMP/diff-seen.json" > /dev/null; check "prefix: mtf-facts gets the module-relative list" $?
setup
jq '[.[0] + {filename: "new.tf", previous_filename: "main.tf", status: "renamed"}]' "$TMP/files.json" > "$TMP/files-ren.json"
jq '.entries = [{path: "new.tf", previous_path: "main.tf", change_kind: "renamed", inert: false, trigger_ids: ["T-001", "T-002"]}]' "$TMP/behaviour-556.json" > "$TMP/behaviour.out"
DIFF="$TMP/files-ren.json" classify; check "rename: covered at both paths" "$([ -f "$O/behaviour.json" ]; echo $?)"
setup
jq '.entries = [{path: "new.tf", change_kind: "renamed", inert: false, trigger_ids: ["T-001", "T-002"]}]' "$TMP/behaviour-556.json" > "$TMP/behaviour.out"
DIFF="$TMP/files-ren.json" classify; evalp
notrun "rename: the old path with no entry" "output refused"
setup; printf 'diff --git a/main.tf b/main.tf\n' > "$TMP/files.diff"; DIFF="$TMP/files.diff" classify
check "a unified diff is a usage error" "$([ $? = 2 ]; echo $?)"

# --- Changes claims-eval reports cross as record lines, without their inputs.
setup
jq '.triggers[0].changes = [{level: "L1", case: "empty-element", attribute: "value", explained: false, inputs: {vpc_security_group_ids: [""]}}, {level: "L1", case: "unknown-element", attribute: "length", explained: true, inputs: {}}]' "$TMP/eval-556.json" > "$TMP/eval.out"
classify; evalp --claims "$TMP/claims-556.json"
grep -qxF 'change T-001 L1 case empty-element value: unexplained' "$O/record.txt" \
  && grep -qxF 'change T-001 L1 case unknown-element length: explained' "$O/record.txt"
check "changes: one record line each" $?
! grep -qF 'vpc_security_group_ids' "$O/record.txt"; check "changes: no input crosses" $?
refuse_e "a change with a bad case id" '.triggers[0].changes = [{level: "L1", case: "a b", attribute: "value", explained: false, inputs: {}}]'
refuse_e "a change with an unknown attribute" '.triggers[0].changes = [{level: "L1", case: "c", attribute: "colour", explained: false, inputs: {}}]'
setup
jq '.capped = 0 | .triggers[0].changes = [{level: "L1", case: "c1", attribute: "wholly_unknown", explained: false, inputs: {}}, {level: "L1", case: "c2", attribute: "unknown_mask", explained: false, inputs: {}}, {level: "L3", case: "c3", attribute: "error", explained: false, inputs: {}}]' "$TMP/eval-556.json" > "$TMP/eval.out"
classify; evalp --claims "$TMP/claims-556.json"
grep -qxF 'change T-001 L1 case c1 wholly_unknown: unexplained' "$O/record.txt" && grep -qxF 'change T-001 L3 case c3 error: unexplained' "$O/record.txt"
check "changes: the wholly_unknown, unknown_mask and error attributes cross" $?
refuse_e "a capped count other than the behaviour's" '.capped = 3'
refuse_e "a capped count that is not a number" '.capped = "0"'

# --- A path the record cannot carry unambiguously is refused.
refuse_b "a path with a space" '.triggers[0].file = "a b.tf"'
refuse_b "a path with a colon" '.triggers[0].file = "a:b.tf"'

# --- Usage: eval before classify, a relative path, an out directory holding outputs.
setup; evalp; check "eval before classify is a usage error" "$([ $? = 2 ]; echo $?)"
setup; bash "$BP" classify --facts "$FACTS" --dir clone --diff "$TMP/files.json" --out "$O" > /dev/null 2>&1
check "a relative --dir is a usage error" "$([ $? = 2 ]; echo $?)"
setup; classify; bash "$BP" classify --facts "$FACTS" --dir "$MOD" --diff "$TMP/files.json" --out "$O" > /dev/null 2>&1
check "classify into a used out directory is a usage error" "$([ $? = 2 ]; echo $?)"
setup; bash "$BP" classify --facts "$FACTS" --dir "$MOD" --out "$O" > /dev/null 2>&1
check "classify with neither --diff nor --base is a usage error" "$([ $? = 2 ]; echo $?)"

echo
if [ "$fails" -eq 0 ]; then echo "behaviour pass: all checks hold"; else echo "behaviour pass: $fails failed"; exit 1; fi
