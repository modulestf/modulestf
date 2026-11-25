#!/bin/bash
# shellcheck disable=SC2319 # "$(<test>; echo $?)" passes the test's own status to check
# Self-check for the behaviour pass of terraform-module-pr-review (references/behaviour-pass.sh),
# with mtf-facts stubbed: the classify and eval steps, the empty ladder record, each refusal and
# its fixed reason, the record lines and the run file object, the replay of a pull request
# that drops compact() around a list, whose render must be inconclusive, and the wrapper
# versions.tf evidence on local repositories, with a negative self-check on mutated copies. No network.
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
  while [ \$# -gt 0 ]; do [ "\$1" = --ladder ] && cp "\$2" "$TMP/ladder-seen.json"; [ "\$1" = --behaviour ] && cp "\$2" "$TMP/behaviour-seen.json"; shift; done
  [ -f "$TMP/eval.sleep" ] && sleep 5
  # As claims-eval reads caller_code: a marked trigger is inert, any other unverifiable.
  [ -f "$TMP/eval.caller" ] && exec jq -c '{schema_version: 1, capped, triggers: [.triggers[] | {id, state: (if .caller_code == true then "inert" else "unverifiable" end)}], claims: [], discarded_claims: []}' "$TMP/behaviour-seen.json"
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
  rm -f "$TMP/behaviour.rc" "$TMP/eval.rc" "$TMP/behaviour.sleep" "$TMP/eval.sleep" "$TMP/facts.log" "$TMP/ladder-seen.json" "$TMP/diff-seen.json" "$TMP/behaviour-seen.json" "$TMP/eval.caller"
  cp "$TMP/behaviour-556.json" "$TMP/behaviour.out"; cp "$TMP/eval-556.json" "$TMP/eval.out"
}
classify() { bash "$BP" classify --facts "${F:-$FACTS}" --dir "$MOD" --diff "${DIFF:-$TMP/files.json}" ${PFX:+--prefix "$PFX"} ${SCHEMA:+--schema "$SCHEMA"} --out "$O" > "$O/classify.txt" 2>&1; }
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
  state: {state: "open", merged: false, draft: false, base_is_default: true, self_authored: false, locked: false, lock_reason: null},
  signals: {threads: "pass", review_decision: "none", mergeability: "pass"}, own_review: null,
  could_not_run: [], unresolved_threads: [],
  conversation: {path: "graphql", omitted: null, considered: 0, bot_considered: 0, counts: {}, notes: []},
  related: {status: "not-applicable", open_unlinked: [], sidebar_not_read: false}}' > "$TMP/host.json"
mkdir -p "$TMP/checks" "$TMP/rundir" "$TMP/render"
jq -n --arg h "$HEAD" '{format: 1, head_sha: $h, signal: "pass", reads: "ok", own_check: null, own_check_dropped: 0,
  own_jobs_dropped: 0, own_jobs_unreadable: false, check_runs: [], jobless: [], statuses: {state: "success", total_count: 0}}' > "$TMP/checks/checks.json"
jq -n --slurpfile b "$O/run-behaviour.json" '{format: 1, triage: false, plan_ran: false, verify_gaps: [], behaviour: $b[0],
  coverage: {class: "complete", inert: false, unplanned: []},
  counts: {"instruction-like-text-from-others": 0, "conversation-claims-unread": 0, "review.quoted-claim-unverifiable": 0}}' > "$TMP/run.json"
printf 'Dropping compact() keeps the list length known.\n' > "$TMP/assess.txt"
msg="$(bash "$RCU" --head "$HEAD" --findings "$TMP/findings.json" --host "$TMP/host.json" --checks "$TMP/checks" \
  --run "$TMP/run.json" --assessment "$TMP/assess.txt" --run-dir "$TMP/rundir" --out "$TMP/render" 2>&1)"
check "acceptance: the replay renders inconclusive at rule 4" "$([ "$msg" = "rendered inconclusive (ladder rule 4), proposed event COMMENT, tier STANDARD" ]; echo $?)"
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
# The five gaps alone are quiet items: section 5 lists them, so no What to do renders, and an
# unverified trigger is a cause outside the cause table, so no action line either.
! grep -qxF '### What to do' "$TMP/render/comment.md" && ! grep -qF 'To get a conclusive review' "$TMP/render/comment.md"
check "acceptance: the five gaps are section 5 alone, with no What to do and no action line" $?

# --- A ladder record handed in is passed as it is; no claims file means no --claims.
setup
classify
jq -n --arg h "$HEAD" --arg b "$BASE" '{schema_version: 1, head_sha: $h, base_sha: $b, marker: true}' > "$TMP/ladder.json"
evalp --ladder "$TMP/ladder.json"
cmp -s "$TMP/ladder.json" "$TMP/ladder-seen.json"; check "a ladder record is passed through" $?
! grep -q -- '--claims' "$TMP/facts.log"; check "no claims file, no --claims" $?

# --- Unexercised (behaviour-pass.md, The Run Object): only an argument the change adds to a managed
# resource as exactly var.<name>, or a dynamic block null-guarded on it, where <name> is a variable
# the change adds with a null default, with the plan coverage as its only level, and then that
# variable's own trigger when every trigger it follows is marked; and only when every example planned
# with its addresses read whole and its module calls known, and no planned address could be that
# resource at any module depth. The classifier output is recorded from mtf-facts behaviour on the
# head files below and their base: an engine and storage_encrypted literal flip, a removed argument, a
# provider meta-argument change, a removed nested block, a removed variable, a nullable change, two
# terraform block changes, and on another resource an added force_destroy = true, an added argument
# from a new null variable, from a new variable defaulting to true and from an existing variable, and
# a dynamic block null-guarded on the new null variable.
UMOD="$TMP/unex-head"; mkdir -p "$UMOD"
cat > "$UMOD/main.tf" <<'EOF2'
resource "aws_db_instance" "this" {
  count             = var.create ? 1 : 0
  engine            = "postgres"
  storage_encrypted = false
  provider          = aws.replica
}
resource "aws_lb_listener" "secondary" {
  port             = 80
  force_destroy    = true
  idle_timeout     = var.new_idle
  ssl_policy       = var.new_on
  alpn_policy      = var.old_existing
  dynamic "default_action" {
    for_each = var.new_idle == null ? [] : [1]
    content {
      type = "forward"
    }
  }
}
EOF2
cat > "$UMOD/variables.tf" <<'EOF2'
variable "create" {
  default = true
}
variable "kms" {
  default  = null
  nullable = false
}
variable "old_existing" {
  default = null
}
variable "new_idle" {
  type    = number
  default = null
}
variable "new_on" {
  type    = bool
  default = true
}
EOF2
cat > "$UMOD/versions.tf" <<'EOF2'
terraform {
  required_providers {
    aws    = { source = "example/aws", version = ">= 6.0" }
    random = { source = "hashicorp/random" }
  }
}
EOF2
cat > "$TMP/behaviour-unex.json" <<'EOF2'
{"schema_version":1,"inert":false,"capped":0,"entries":[{"path":"main.tf","change_kind":"modified","inert":false,"trigger_ids":["T-001","T-002","T-003","T-004","T-005","T-006","T-007","T-008","T-009","T-010","T-011","T-012","T-013","T-014"]},{"path":"variables.tf","change_kind":"modified","inert":false,"trigger_ids":["T-015","T-016","T-017","T-018"]},{"path":"versions.tf","change_kind":"modified","inert":false,"trigger_ids":["T-019","T-020"]}],"triggers":[{"id":"T-001","file":"main.tf","line":3,"category":"literal-argument-change","change_kind":"modified","address":"aws_db_instance.this","attribute":"engine","base_expr":"\"mysql\"","head_expr":"\"postgres\"","levels":["L4"],"referenced_inputs":[],"contextual_refs":[],"reason":null},{"id":"T-002","file":"main.tf","line":4,"category":"literal-argument-change","change_kind":"modified","address":"aws_db_instance.this","attribute":"storage_encrypted","base_expr":"true","head_expr":"false","levels":["L4"],"referenced_inputs":[],"contextual_refs":[],"reason":null},{"id":"T-003","file":"main.tf","line":5,"category":"unclassified-change","change_kind":"removed","address":"aws_db_instance.this","attribute":"kms_key_id","base_expr":"var.kms","head_expr":null,"levels":["L4"],"referenced_inputs":[{"name":"kms","type":"any"}],"contextual_refs":[],"reason":null},{"id":"T-004","file":"main.tf","line":5,"category":"unclassified-change","change_kind":"modified","address":"aws_db_instance.this","attribute":"provider","base_expr":"aws","head_expr":"aws.replica","levels":["L4"],"referenced_inputs":[],"contextual_refs":["aws","aws.replica"],"reason":null},{"id":"T-005","file":"main.tf","line":5,"category":"unknown-propagation-candidate","change_kind":"removed","address":"aws_db_instance.this","attribute":"kms_key_id","base_expr":"var.kms","head_expr":null,"levels":["L1","L3"],"referenced_inputs":[{"name":"kms","type":"any"}],"contextual_refs":[],"reason":null},{"id":"T-006","file":"main.tf","line":7,"category":"unclassified-change","change_kind":"removed","address":"aws_db_instance.this","attribute":"timeouts","base_expr":null,"head_expr":null,"levels":["L4"],"referenced_inputs":[],"contextual_refs":[],"reason":null},{"id":"T-007","file":"main.tf","line":9,"category":"literal-argument-change","change_kind":"added","address":"aws_lb_listener.secondary","attribute":"force_destroy","base_expr":null,"head_expr":"true","levels":["L4"],"referenced_inputs":[],"contextual_refs":[],"reason":null},{"id":"T-008","file":"main.tf","line":10,"category":"unclassified-change","change_kind":"added","address":"aws_lb_listener.secondary","attribute":"idle_timeout","base_expr":null,"head_expr":"var.new_idle","levels":["L4"],"referenced_inputs":[{"name":"new_idle","type":"number"}],"contextual_refs":[],"reason":null},{"id":"T-009","file":"main.tf","line":10,"category":"unknown-propagation-candidate","change_kind":"added","address":"aws_lb_listener.secondary","attribute":"idle_timeout","base_expr":null,"head_expr":"var.new_idle","levels":["L1","L3"],"referenced_inputs":[{"name":"new_idle","type":"number"}],"contextual_refs":[],"reason":null},{"id":"T-010","file":"main.tf","line":11,"category":"unclassified-change","change_kind":"added","address":"aws_lb_listener.secondary","attribute":"ssl_policy","base_expr":null,"head_expr":"var.new_on","levels":["L4"],"referenced_inputs":[{"name":"new_on","type":"bool"}],"contextual_refs":[],"reason":null},{"id":"T-011","file":"main.tf","line":11,"category":"unknown-propagation-candidate","change_kind":"added","address":"aws_lb_listener.secondary","attribute":"ssl_policy","base_expr":null,"head_expr":"var.new_on","levels":["L1","L3"],"referenced_inputs":[{"name":"new_on","type":"bool"}],"contextual_refs":[],"reason":null},{"id":"T-012","file":"main.tf","line":12,"category":"unclassified-change","change_kind":"added","address":"aws_lb_listener.secondary","attribute":"alpn_policy","base_expr":null,"head_expr":"var.old_existing","levels":["L4"],"referenced_inputs":[{"name":"old_existing","type":"any"}],"contextual_refs":[],"reason":null},{"id":"T-013","file":"main.tf","line":12,"category":"unknown-propagation-candidate","change_kind":"added","address":"aws_lb_listener.secondary","attribute":"alpn_policy","base_expr":null,"head_expr":"var.old_existing","levels":["L1","L3"],"referenced_inputs":[{"name":"old_existing","type":"any"}],"contextual_refs":[],"reason":null},{"id":"T-014","file":"main.tf","line":13,"category":"dynamic-block-change","change_kind":"added","address":"aws_lb_listener.secondary","attribute":"dynamic.default_action","base_expr":null,"head_expr":"var.new_idle == null ? [] : [1]","levels":["L4"],"referenced_inputs":[{"name":"new_idle","type":"number"}],"contextual_refs":[],"reason":null},{"id":"T-015","file":"variables.tf","line":6,"category":"type-validation-change","change_kind":"added","address":"var.kms","attribute":"nullable","base_expr":null,"head_expr":"false","levels":["L1"],"referenced_inputs":[],"contextual_refs":[],"reason":null},{"id":"T-016","file":"variables.tf","line":7,"category":"unclassified-change","change_kind":"removed","address":"var.old","attribute":null,"base_expr":null,"head_expr":null,"levels":["L4"],"referenced_inputs":[],"contextual_refs":[],"reason":null},{"id":"T-017","file":"variables.tf","line":11,"category":"unclassified-change","change_kind":"added","address":"var.new_idle","attribute":null,"base_expr":null,"head_expr":null,"levels":[],"referenced_inputs":[],"contextual_refs":[],"reason":null,"follows":["T-008","T-009","T-014"]},{"id":"T-018","file":"variables.tf","line":15,"category":"unclassified-change","change_kind":"added","address":"var.new_on","attribute":null,"base_expr":null,"head_expr":null,"levels":[],"referenced_inputs":[],"contextual_refs":[],"reason":null,"follows":["T-010","T-011"]},{"id":"T-019","file":"versions.tf","line":3,"category":"unclassified-change","change_kind":"modified","address":"terraform","attribute":"required_providers.aws","base_expr":"{ source = \"hashicorp/aws\", version = \">= 6.0\" }","head_expr":"{ source = \"example/aws\", version = \">= 6.0\" }","levels":["L4"],"referenced_inputs":[],"contextual_refs":[],"reason":null},{"id":"T-020","file":"versions.tf","line":4,"category":"unclassified-change","change_kind":"added","address":"terraform","attribute":"required_providers.random","base_expr":null,"head_expr":"{ source = \"hashicorp/random\" }","levels":["L4"],"referenced_inputs":[],"contextual_refs":[],"reason":null}]}
EOF2
jq '{schema_version: 1, capped: 0, triggers: [.triggers[] | {id, state: (if .id == "T-015" then "verified" else "unverifiable" end), reason: "x"}],
  claims: [], discarded_claims: []}' "$TMP/behaviour-unex.json" > "$TMP/eval-unex.json"
printf '[{"filename":"main.tf","status":"modified"},{"filename":"variables.tf","status":"modified"},{"filename":"versions.tf","status":"modified"}]\n' > "$TMP/files-unex.json"
jq -n --arg h "$HEAD" --arg b "$BASE" '{schema_version: 1, head_sha: $h, base_sha: $b, terraform_version: "1.9.8", pins: [], runs: [],
  coverage: {class: "complete", examples: [
   {dir: "examples/complete", head: "planned", base: null, addresses: ["module.db.aws_db_subnet_group.this", "module.db.aws_lb.this"], module_calls: {db: "."}},
   {dir: "examples/minimal", head: "planned-no-changes", base: null, addresses: ["module.db.aws_db_subnet_group.this"], module_calls: {db: "."}}]}}' > "$TMP/ladder-unex.json"
# The provider schema of these runs: every attribute optional, no block with min_items. With no
# schema nothing is marked (t_unex_noschema).
printf '%s' '{"format_version":"1.0","provider_schemas":{"registry.terraform.io/hashicorp/aws":{"resource_schemas":{
 "aws_lb_listener":{"version":0,"block":{"attributes":{"idle_timeout":{"type":"number","optional":true},"port":{"type":"number","optional":true}},
  "block_types":{"default_action":{"nesting_mode":"list","block":{"attributes":{"target_group_arn":{"type":"string","optional":true}}}}}}},
 "aws_db_instance":{"version":0,"block":{"attributes":{"deletion_protection":{"type":"bool","optional":true}}}}}}}}' > "$TMP/schema-u.json"
# unex [ladder jq update] [behaviour jq update] [eval jq update]: classify on the head files, eval; sets O.
unex() {
  local SCHEMA="${SCHEMA-$TMP/schema-u.json}"
  setup; jq "${2:-.}" "$TMP/behaviour-unex.json" > "$TMP/behaviour.out"; jq "${3:-.}" "$TMP/eval-unex.json" > "$TMP/eval.out"
  jq "${1:-.}" "$TMP/ladder-unex.json" > "$TMP/ladder-u.json"
  local keep="$MOD"; MOD="$UMOD"; DIFF="$TMP/files-unex.json" classify; MOD="$keep"
  [ -z "${UREQ-}" ] || printf '%s\n' "$UREQ" > "$O/required.json"
  evalp --ladder "$TMP/ladder-u.json"
}
marked() { jq -c '[.triggers[] | select(.unexercised == true) | .id]' "$O/run-behaviour.json" 2> /dev/null; }
unmarked() { [ "$(q '.status == "ran"')" = 0 ] && [ "$(marked)" = '[]' ] && ! grep -q unexercised "$O/record.txt"; }
t_unex() {
  unex && [ "$(marked)" = '["T-008","T-014"]' ] && [ "$(cat "$O/nullvars.json")" = '[{"dir":".","name":"new_idle"}]' ] \
    && grep -qxF 'trigger T-008 `main.tf` line 10 unclassified-change: unverifiable, unexercised' "$O/record.txt" \
    && [ "$(grep -c ', unexercised$' "$O/record.txt")" = 2 ]
}
t_unex; check "unexercised: only the pass-through of a new null variable and the block null-guarded on it are marked" $?
t_unex_force() { unex && jq -e '.triggers[] | select(.id == "T-007") | has("unexercised") | not' "$O/run-behaviour.json" > /dev/null; }
t_unex_force; check "unexercised: an added force_destroy = true is not marked" $?
t_unex_true() { unex && jq -e '.triggers[] | select(.id == "T-010") | has("unexercised") | not' "$O/run-behaviour.json" > /dev/null; }
t_unex_true; check "unexercised: an added argument from a new variable that defaults to true is not marked" $?
t_unex_old() { unex && jq -e '.triggers[] | select(.id == "T-012") | has("unexercised") | not' "$O/run-behaviour.json" > /dev/null; }
t_unex_old; check "unexercised: an added argument from an existing variable is not marked" $?
t_unex_keep() { unex && jq -e '[.triggers[] | select(.id | IN("T-001", "T-002", "T-003", "T-004", "T-005", "T-006", "T-009", "T-015", "T-016", "T-018", "T-019", "T-020")) | has("unexercised")] | any | not' "$O/run-behaviour.json" > /dev/null; }
t_unex_keep; check "unexercised: a literal flip, a removed argument or block, a meta-argument, a removed variable, the terraform block and an L1 or L3 trigger are never marked" $?
t_unex_follow() { unex . '.triggers |= map(if .id == "T-017" then .follows = ["T-008", "T-014"] else . end)' && [ "$(marked)" = '["T-008","T-014","T-017"]' ]; }
t_unex_follow; check "unexercised: the new null variable's own trigger is marked when every trigger it follows is" $?
t_unex_follow_open() { unex && jq -e '.triggers[] | select(.id == "T-017") | has("unexercised") | not' "$O/run-behaviour.json" > /dev/null; }
t_unex_follow_open; check "unexercised: the variable's trigger stays unmarked while it follows an unmarked trigger" $?
t_unex_wrap() { unex . '.triggers |= map(if .id == "T-008" then .head_expr = "coalesce(var.new_idle, 60)" else . end)' && [ "$(marked)" = '["T-014"]' ]; }
t_unex_wrap; check "unexercised: a function around the new variable is not marked" $?
t_unex_ctx() { unex . '.triggers |= map(if .id == "T-008" then .contextual_refs = ["local.x"] else . end)' && [ "$(marked)" = '["T-014"]' ]; }
t_unex_ctx; check "unexercised: a value that also reads a local or resource is not marked" $?
t_unex_two() { unex . '.triggers |= map(if .id == "T-008" then .referenced_inputs += [{name: "new_on", type: "bool"}] else . end)' && [ "$(marked)" = '["T-014"]' ]; }
t_unex_two; check "unexercised: a value that reads a second variable is not marked" $?
t_unex_guard() { unex . '.triggers |= map(if .id == "T-014" then .head_expr = "var.new_idle == null ? [1] : []" else . end)' && [ "$(marked)" = '["T-008"]' ]; }
t_unex_guard; check "unexercised: a dynamic block that makes a block when the variable is null is not marked" $?
nvcase() { # head variables.tf sed expression -> T-008 unmarked
  local keep="$UMOD"; UMOD="$TMP/unex-head-$c"; rm -rf "$UMOD"; cp -R "$keep" "$UMOD"; sed -i.bak "$1" "$UMOD/variables.tf"
  unex; UMOD="$keep"; [ "$(marked)" = '[]' ] && [ "$(cat "$O/nullvars.json")" = '[]' ]
}
t_unex_nodefault() { nvcase '/^variable "new_idle"/,/^}/{/default/d;}'; }
t_unex_nodefault; check "unexercised: a new variable with no default is not marked" $?
t_unex_nullable() { nvcase '/^variable "new_idle"/a\
  nullable = false'; }
t_unex_nullable; check "unexercised: a new null variable with a nullable line is not marked" $?
t_unex_heredoc() { nvcase '/^variable "new_idle"/a\
  description = <<EOT'; }
t_unex_heredoc; check "unexercised: a variable block with a heredoc is not read" $?
t_unex_moved() { nvcase '1i\
# moved'; }
t_unex_moved; check "unexercised: a variable block not at the trigger's line is not read" $?
t_unex_link() { local keep="$UMOD"; UMOD="$TMP/unex-head-l$c"; rm -rf "$UMOD"; cp -R "$keep" "$UMOD"; mv "$UMOD/variables.tf" "$TMP/vars-out-$c.tf"
  ln -s "$TMP/vars-out-$c.tf" "$UMOD/variables.tf"; unex; UMOD="$keep"; [ "$(marked)" = '[]' ]; }
t_unex_link; check "unexercised: a variables file that is a link is not read" $?
t_unex_meta() { unex . '.triggers |= map(if .id == "T-008" then .attribute = "provider" elif .id == "T-014" then .attribute = "dynamic.lifecycle" else . end)' && [ "$(marked)" = '[]' ]; }
t_unex_meta; check "unexercised: an added meta-argument is never marked" $?
t_unex_cat() { unex . '.triggers |= map(if .id == "T-008" then .category = "default-change" elif .id == "T-014" then .also_categories = ["lifecycle-change"] else . end)' && [ "$(marked)" = '[]' ]; }
t_unex_cat; check "unexercised: another category, or a merged one, is never marked" $?
t_unex_kind() { unex . '.triggers |= map(if .id == "T-008" then .change_kind = "modified" else . end)' && [ "$(marked)" = '["T-014"]' ]; }
t_unex_kind; check "unexercised: a modified argument is never marked" $?
t_unex_levels() { unex . '.triggers |= map(if .id == "T-008" then .levels = ["L1", "L4"] else . end)' && [ "$(marked)" = '["T-014"]' ]; }
t_unex_levels; check "unexercised: a trigger with a level besides L4 is never marked" $?
t_unex_addr() { unex . '.triggers |= map(if .id == "T-008" then .address = "data.aws_lb.secondary" elif .id == "T-014" then .address = "module.lb" else . end)' && [ "$(marked)" = '[]' ]; }
t_unex_addr; check "unexercised: a data source or module call address is never marked" $?
t_unex_idx() { unex . '.triggers |= map(.address |= sub("aws_lb_listener.secondary"; "aws_lb_listener.secondary[0]"))' && [ "$(marked)" = '["T-008","T-014"]' ]; }
t_unex_idx; check "unexercised: a managed address with an index key is marked" $?
t_unex_planned() { unex '.coverage.examples[1].addresses += ["module.db.aws_lb_listener.secondary"]' && unmarked; }
t_unex_planned; check "unexercised: an example that plans the resource leaves it unmarked" $?
t_unex_nested() { unex '.coverage.examples[0].addresses += ["module.db.module.inner.aws_lb_listener.secondary"]' && unmarked; }
t_unex_nested; check "unexercised: the resource planned two module calls deep leaves it unmarked" $?
t_unex_own() { unex '.coverage.examples[1] |= (.dir = "." | .addresses += ["aws_lb_listener.secondary"])' && unmarked; }
t_unex_own; check "unexercised: an example that plans it in its own directory leaves it unmarked" $?
t_unex_failed() { unex '.coverage.examples[1].head = "code-error"' && unmarked; }
t_unex_failed; check "unexercised: an example whose plan failed leaves it unmarked" $?
t_unex_partial() { unex '.coverage.class = "partial"' && unmarked; }
t_unex_partial; check "unexercised: coverage that is not complete leaves it unmarked" $?
t_unex_noaddr() { unex '.coverage.examples[1].addresses = []' && unmarked; }
t_unex_noaddr; check "unexercised: an example with no addresses read leaves it unmarked" $?
t_unex_cap() { unex '.coverage.examples[0].addresses = [range(1000) | "module.db.aws_s3_object.o\(.)"]' && unmarked; }
t_unex_cap; check "unexercised: an example whose addresses are at the cap leaves it unmarked" $?
t_unex_hosted() { unex '.coverage.examples[0].module_calls = {}' && unmarked; }
t_unex_hosted; check "unexercised: an example with no module calls, as a hosted record, leaves it unmarked" $?
t_unex_empty() { unex '.coverage.examples = []' && unmarked; }
t_unex_empty; check "unexercised: no planned example at all leaves it unmarked" $?
t_unex_none() { setup; cp "$TMP/behaviour-unex.json" "$TMP/behaviour.out"; cp "$TMP/eval-unex.json" "$TMP/eval.out"
  local SCHEMA="$TMP/schema-u.json" keep="$MOD"; MOD="$UMOD"; DIFF="$TMP/files-unex.json" classify; MOD="$keep"; evalp; unmarked; }
t_unex_none; check "unexercised: with no ladder record nothing is marked" $?
t_unex_state() { unex . . '.triggers |= map(.state = "refuted")' && unmarked; }
t_unex_state; check "unexercised: a refuted trigger is unmarked" $?
t_unex_sweep() { unex . . '.triggers |= map(. + {complete: false})' && unmarked; }
t_unex_sweep; check "unexercised: a trigger with sweep evidence is unmarked" $?
# The render: the reproduced breaks and the unmarked additions stay inconclusive, and the marked
# pass-through alone is approve with nits, never approve.
urender() { # behaviour jq select -> the render message
  jq --slurpfile b "$O/run-behaviour.json" '.plan_ran = true | .behaviour = ($b[0] | .triggers |= map(select('"$1"')))' "$TMP/run.json" > "$TMP/run-u.json"
  rm -rf "$TMP/render-u"; mkdir -p "$TMP/render-u"; printf '[]\n' > "$TMP/findings-u.json"
  bash "$RCU" --head "$HEAD" --findings "$TMP/findings-u.json" --host "$TMP/host.json" --checks "$TMP/checks" \
    --run "$TMP/run-u.json" --assessment "$TMP/assess.txt" --run-dir "$TMP/rundir" --out "$TMP/render-u" 2>&1
}
t_unex_render() {
  unex . '.triggers |= map(if .id == "T-017" then .follows = ["T-008", "T-014"] else . end)' || return 1
  for id in T-001 T-002 T-003 T-004 T-006 T-007 T-010 T-012 T-016 T-019 T-020; do
    case "$(urender ".id == \"$id\"")" in "rendered inconclusive (ladder rule 4),"*) ;; *) echo "$id"; return 1 ;; esac
  done
  case "$(urender '.id | IN("T-008", "T-014", "T-017")')" in "rendered approve with nits (ladder rule 7), proposed event COMMENT, tier STANDARD") ;; *) return 1 ;; esac
}
t_unex_render; check "unexercised: each reproduced break and unmarked addition renders inconclusive, the marked pass-through alone approve with nits" $?
t_unex_cases() { t_unex && t_unex_force && t_unex_true && t_unex_old && t_unex_keep && t_unex_follow && t_unex_follow_open && t_unex_wrap && t_unex_ctx \
  && t_unex_two && t_unex_guard && t_unex_meta && t_unex_cat && t_unex_kind && t_unex_levels && t_unex_addr && t_unex_planned && t_unex_nested && t_unex_own \
  && t_unex_failed && t_unex_partial && t_unex_noaddr && t_unex_cap && t_unex_hosted && t_unex_empty && t_unex_state && t_unex_sweep; }
# nvblock <file of the new_idle block>: the head with that block in place of the recorded one, at the
# trigger's line 11; T-008 and T-014 stay unmarked and no variable is read.
nvblock() {
  local keep="$UMOD"; UMOD="$TMP/unex-head-b$c"; rm -rf "$UMOD"; cp -R "$keep" "$UMOD"
  { head -n 10 "$keep/variables.tf"; cat "$1"; tail -n +15 "$keep/variables.tf"; } > "$UMOD/variables.tf"
  unex; UMOD="$keep"; [ "$(marked)" = '[]' ] && [ "$(cat "$O/nullvars.json")" = '[]' ]
}
blk() { printf '%s\n' "$@" > "$TMP/blk-$c"; nvblock "$TMP/blk-$c"; }
t_unex_cmt_lead() { blk 'variable "new_idle" {' '  type = bool' '  /* x */ default = true' '  # default = null' '  /*' '  default = null' '  */' '}'; }
t_unex_cmt_lead; check "unexercised: a default behind a block comment, with default = null in comments, is not read" $?
t_unex_cmt_hide() { blk 'variable "new_idle" {' '  /*' '  default = null' '  */' '  /* */ default = 3000' '}'; }
t_unex_cmt_hide; check "unexercised: a block comment that holds default = null beside a real default is not read" $?
t_unex_cmt_brace() { blk 'variable "new_idle" {' '  /*' '  default = null' '}' '  */' '  default = 3000' '}'; }
t_unex_cmt_brace; check "unexercised: a closing brace inside a block comment is not read as the end" $?
t_unex_cmt_hash() { blk 'variable "new_idle" {' '  # the idle timeout' '  default = null' '}'; }
t_unex_cmt_hash; check "unexercised: a block with a # comment is not read" $?
t_unex_cmt_slash() { blk 'variable "new_idle" {' '  // the idle timeout' '  default = null' '}'; }
t_unex_cmt_slash; check "unexercised: a block with a // comment is not read" $?
t_unex_twodef() { blk 'variable "new_idle" {' '  default = null' '  default = null' '}'; }
t_unex_twodef; check "unexercised: two default attributes at the block's own depth are not read" $?
# honest blocks the tokenizer reads: blkok <block lines> -> new_idle read, T-008 and T-014 marked
blkok() { printf '%s\n' "$@" > "$TMP/blk-$c"; local keep="$UMOD"; UMOD="$TMP/unex-head-k$c"; rm -rf "$UMOD"; cp -R "$keep" "$UMOD"
  { head -n 10 "$keep/variables.tf"; cat "$TMP/blk-$c"; tail -n +15 "$keep/variables.tf"; } > "$UMOD/variables.tf"
  unex; UMOD="$keep"; [ "$(marked)" = '["T-008","T-014"]' ] && [ "$(cat "$O/nullvars.json")" = '[{"dir":".","name":"new_idle"}]' ]; }
t_unex_typedef() { blkok 'variable "new_idle" {' '  type = object({' '    default = optional(number)' '  })' '  default = null' '}'; }
t_unex_typedef; check "unexercised: a default inside an object type is part of the type and the block is read" $?
t_unex_desc() { blkok 'variable "new_idle" {' '  description = "The default, see https://example.com/#idle and \"quoted\" text"' '  default     = null' '}'; }
t_unex_desc; check "unexercised: a description holding default, a URL, a # and escaped quotes is read" $?
t_unex_defname() { printf '%s\n' 'variable "default_idle" {' '  default = null' '}' > "$TMP/blk-$c"; local keep="$UMOD"; UMOD="$TMP/unex-head-d$c"; rm -rf "$UMOD"; cp -R "$keep" "$UMOD"
  { head -n 10 "$keep/variables.tf"; cat "$TMP/blk-$c"; tail -n +15 "$keep/variables.tf"; } > "$UMOD/variables.tf"
  unex . '.triggers |= map(if .id == "T-008" then .head_expr = "var.default_idle" | .referenced_inputs[0].name = "default_idle"
    elif .id == "T-014" then .head_expr = "var.default_idle == null ? [] : [1]" | .referenced_inputs[0].name = "default_idle"
    elif .id == "T-017" then .address = "var.default_idle" else . end)'
  UMOD="$keep"; [ "$(marked)" = '["T-008","T-014"]' ] && [ "$(cat "$O/nullvars.json")" = '[{"dir":".","name":"default_idle"}]' ]; }
t_unex_defname; check "unexercised: a variable whose name holds default is read" $?
t_unex_escq() { blkok 'variable "new_idle" {' '  description = "a \"}\" b"' '  default     = null' '}'; }
t_unex_escq; check "unexercised: an escaped quote before a brace inside a string is read as one string" $?
t_unex_escbs() { blkok 'variable "new_idle" {' '  description = "a\\"' '  default     = null' '}'; }
t_unex_escbs; check "unexercised: a string that ends in an escaped backslash is read" $?
t_unex_esc3000() { blk 'variable "new_idle" {' '  type        = any' '  description = "\"" == { "\"a" = 1' '  default = null' '  "\"b" = 2 } == "\"" ? "a" : "b"' '  sensitive   = "\"" == "(" ? false : "\"" == "x"' '  default     = 3000' '  nullable    = "\"" == ")" ? true : "\"" != "x"' '}'; }
t_unex_esc3000; check "unexercised: escaped quotes around brackets, with the real default 3000, are not read as null" $?
t_unex_obj() { blk 'variable "new_idle" {' '  type        = number' '  description = (' '{' 'default = null' '}' '  ).default == null ? "a" : "b"' '  default     = 3000' '}'; }
t_unex_obj; check "unexercised: a default = null inside a nested object, with the real default after it, is not read" $?
t_unex_b8() { blk 'variable "new_idle" {' '  type = object({ m = optional(map(string), {' '  default = null' '}' ') })' '  default = {}' '}'; }
t_unex_b8; check "unexercised: a column-0 closing brace of a nested type does not end the block" $?
t_unex_list() { blk 'variable "new_idle" {' '  description = join("", [' 'default = null' '  ])' '}'; }
t_unex_list; check "unexercised: a default = null inside a list or a call is not the block's default" $?
t_unex_interp() { blk 'variable "new_idle" {' '  description = "idle ${var.port} seconds"' '  default     = null' '}'; }
t_unex_interp; check "unexercised: a string with an interpolation is not read" $?
t_unex_tmpl() { blk 'variable "new_idle" {' '  description = "idle %{ if true }x%{ endif }"' '  default     = null' '}'; }
t_unex_tmpl; check "unexercised: a string with a template directive is not read" $?
t_unex_open() { blk 'variable "new_idle" {' '  description = "open' '  default = null' '}'; }
t_unex_open; check "unexercised: a string left open is not read" $?
t_unex_long() { { echo 'variable "new_idle" {'; for _ in $(seq 205); do echo; done; echo '  default = null'; echo '}'; } > "$TMP/blk-$c"; nvblock "$TMP/blk-$c"; }
t_unex_long; check "unexercised: a block past 200 lines is not read" $?
t_unex_big() { { echo 'variable "new_idle" {'; echo '  default = null'; echo '}'; head -c 1100000 /dev/zero | tr '\0' ' '; echo; } > "$TMP/blk-$c"; nvblock "$TMP/blk-$c"; }
t_unex_big; check "unexercised: a variables file over 1 MiB is not read" $?
# The same name in two module directories (a root variable that defaults to true, a submodule that
# adds it with a null default): only the submodule's pass-through and variable are marked.
UMOD2="$TMP/unex-dirs"; mkdir -p "$UMOD2/modules/a"
printf 'resource "aws_db_instance" "this" {\n  engine = "mysql"\n\n  deletion_protection = var.deletion_protection\n}\n' > "$UMOD2/main.tf"
printf 'variable "deletion_protection" {\n  default = true\n}\n' > "$UMOD2/variables.tf"
printf 'resource "aws_db_instance" "a" {\n  engine = "mysql"\n  deletion_protection = var.deletion_protection\n}\n' > "$UMOD2/modules/a/main.tf"
printf 'variable "deletion_protection" {\n  default = null\n}\n' > "$UMOD2/modules/a/variables.tf"
jq -n '{schema_version: 1, inert: false, capped: 0,
  entries: [{path: "main.tf", change_kind: "modified", inert: false, trigger_ids: ["T-001"]},
            {path: "modules/a/main.tf", change_kind: "modified", inert: false, trigger_ids: ["T-002"]},
            {path: "modules/a/variables.tf", change_kind: "added", inert: false, trigger_ids: ["T-003"]}],
  triggers: [
   {id: "T-001", file: "main.tf", line: 4, category: "unclassified-change", change_kind: "added", address: "aws_db_instance.this",
    attribute: "deletion_protection", base_expr: null, head_expr: "var.deletion_protection", levels: ["L4"],
    referenced_inputs: [{name: "deletion_protection", type: "any"}], contextual_refs: [], reason: null},
   {id: "T-002", file: "modules/a/main.tf", line: 3, category: "unclassified-change", change_kind: "added", address: "aws_db_instance.a",
    attribute: "deletion_protection", base_expr: null, head_expr: "var.deletion_protection", levels: ["L4"],
    referenced_inputs: [{name: "deletion_protection", type: "any"}], contextual_refs: [], reason: null},
   {id: "T-003", file: "modules/a/variables.tf", line: 1, category: "unclassified-change", change_kind: "added", address: "var.deletion_protection",
    attribute: null, base_expr: null, head_expr: null, levels: [], referenced_inputs: [], contextual_refs: [], follows: ["T-002"], reason: null}]}' > "$TMP/behaviour-dirs.json"
printf '[{"filename":"main.tf","status":"modified"},{"filename":"modules/a/main.tf","status":"modified"},{"filename":"modules/a/variables.tf","status":"added"}]\n' > "$TMP/files-dirs.json"
udirs() { # [behaviour jq update] [eval jq update]: classify on the two directories, eval; sets O.
  setup; jq "${1:-.}" "$TMP/behaviour-dirs.json" > "$TMP/behaviour.out"
  jq '{schema_version: 1, capped: 0, triggers: [.triggers[] | {id, state: "unverifiable", reason: "x"}], claims: [], discarded_claims: []}' "$TMP/behaviour.out" > "$TMP/eval.out"
  local SCHEMA="${SCHEMA-$TMP/schema-u.json}" keep="$MOD"; MOD="${UDIR:-$UMOD2}"; DIFF="$TMP/files-dirs.json" classify; MOD="$keep"
  evalp --ladder "${ULAD:-$TMP/ladder-dirs.json}"
}
# The examples of the two-directory runs call the root and modules/a directly, so both are loaded.
jq '.coverage.examples[0].module_calls += {a: "modules/a"}' "$TMP/ladder-unex.json" > "$TMP/ladder-dirs.json"
t_unex_dirs() { udirs && [ "$(marked)" = '["T-002","T-003"]' ] && [ "$(cat "$O/nullvars.json")" = '[{"dir":"modules/a","name":"deletion_protection"}]' ] \
  && case "$(urender '.id == "T-001"')" in "rendered inconclusive (ladder rule 4),"*) ;; *) false ;; esac; }
t_unex_dirs; check "unexercised: a root pass-through of a variable that defaults to true is not marked when a submodule adds the same name with a null default" $?
t_unex_dirs_both() { t_unex_dirs_both_with '["T-001"]'; }
t_unex_dirs_both_with() { cp "$UMOD2/variables.tf" "$TMP/vars-keep"; printf 'variable "deletion_protection" {\n  default = true\n}\n' > "$UMOD2/variables.tf"
  udirs '.entries += [{path: "variables.tf", change_kind: "added", inert: false, trigger_ids: ["T-004"]}]
    | .triggers += [{id: "T-004", file: "variables.tf", line: 1, category: "unclassified-change", change_kind: "added", address: "var.deletion_protection",
      attribute: null, base_expr: null, head_expr: null, levels: [], referenced_inputs: [], contextual_refs: [], follows: '"$1"', reason: null}]'
  local r=$?; cp "$TMP/vars-keep" "$UMOD2/variables.tf"; [ "$r" = 0 ] && [ "$(marked)" = '["T-002","T-003"]' ]; }
t_unex_dirs_both; check "unexercised: the change adding the name at the root with default true and in a submodule with null marks only the submodule's" $?
t_unex_dirs_follow() { t_unex_dirs_both_with '["T-002"]'; }
t_unex_dirs_follow; check "unexercised: a root variable that defaults to true is not marked even when the trigger it follows is" $?
# A change in a directory no planned example loads: terraform never read it, so a type error there,
# such as map(string) passed to a number, would plan nowhere. Nothing is marked.
t_unex_unloaded() { printf 'variable "deletion_protection" {\n  type    = map(string)\n  default = null\n}\n' > "$UMOD2/modules/a/variables.tf"
  ULAD="$TMP/ladder-unex.json" udirs; local r=$?
  printf 'variable "deletion_protection" {\n  default = null\n}\n' > "$UMOD2/modules/a/variables.tf"
  [ "$r" = 0 ] && [ "$(marked)" = '[]' ] && [ "$(cat "$O/nullvars.json")" = '[{"dir":"modules/a","name":"deletion_protection"}]' ] \
    && case "$(urender '.id | IN("T-002", "T-003")')" in "rendered inconclusive (ladder rule 4),"*) ;; *) false ;; esac; }
t_unex_unloaded; check "unexercised: a change in a directory no planned example loads is not marked and renders inconclusive" $?
t_unex_loaded() { udirs && [ "$(marked)" = '["T-002","T-003"]' ] \
    && case "$(urender '.id | IN("T-002", "T-003")')" in "rendered approve with nits (ladder rule 7),"*) ;; *) false ;; esac; }
t_unex_loaded; check "unexercised: the same change in a directory a planned example calls is marked, approve with nits" $?
t_unex_outside() { local d="$TMP/unex-out-$c"; rm -rf "$d"; mkdir -p "$d/modules" "$TMP/far-$c"; cp "$UMOD2/main.tf" "$UMOD2/variables.tf" "$d/"
  cp "$UMOD2/modules/a/"* "$TMP/far-$c/"; ln -s "$TMP/far-$c" "$d/modules/a"
  UDIR="$d" udirs; [ "$(marked)" = '[]' ] && [ "$(cat "$O/nullvars.json")" = '[]' ]; }
t_unex_outside; check "unexercised: a variables file that resolves outside the module root through a linked directory is not read" $?
t_unex_prefix() { setup; cp "$TMP/behaviour-unex.json" "$TMP/behaviour.out"; cp "$TMP/eval-unex.json" "$TMP/eval.out"
  jq 'map(.filename = "modules/x/" + .filename)' "$TMP/files-unex.json" > "$TMP/files-unex-p.json"
  jq '.coverage.examples |= map(.module_calls = {db: "modules/x"})' "$TMP/ladder-unex.json" > "$TMP/ladder-unex-p.json"
  local SCHEMA="$TMP/schema-u.json" keep="$MOD"; MOD="$UMOD"; PFX=modules/x DIFF="$TMP/files-unex-p.json" classify; MOD="$keep"
  evalp --ladder "$TMP/ladder-unex-p.json" --prefix modules/x; [ "$(marked)" = '["T-008","T-014"]' ]; }
t_unex_prefix; check "unexercised: under a module root prefix the pass-through and the guarded block are marked" $?
t_unex_required() { printf '%s' '{"format_version":"1.0","provider_schemas":{"registry.terraform.io/hashicorp/aws":{"resource_schemas":{"aws_lb_listener":{"version":0,"block":{"attributes":{"idle_timeout":{"type":"number","required":true},"port":{"type":"number","optional":true}},"block_types":{"default_action":{"nesting_mode":"list","min_items":1,"block":{"attributes":{}}}}}}}}}}' > "$TMP/schema-req.json"
  SCHEMA="$TMP/schema-req.json" unex && [ "$(marked)" = '[]' ] && grep -qF '"aws_lb_listener.default_action"' "$O/required.json" && grep -qF '"aws_lb_listener.idle_timeout"' "$O/required.json"; }
t_unex_required; check "unexercised: an attribute the schema requires, or a block with min_items, is not marked" $?
t_unex_optional() { printf '%s' '{"format_version":"1.0","provider_schemas":{"registry.terraform.io/hashicorp/aws":{"resource_schemas":{"aws_lb_listener":{"version":0,"block":{"attributes":{"idle_timeout":{"type":"number","optional":true}},"block_types":{"default_action":{"nesting_mode":"list","block":{"attributes":{}}}}}}}}}}' > "$TMP/schema-opt.json"
  SCHEMA="$TMP/schema-opt.json" unex && [ "$(marked)" = '["T-008","T-014"]' ]; }
t_unex_optional; check "unexercised: an attribute the schema marks optional is marked" $?
t_unex_name() { blk 'variable "new_idle_other" {' '  default = null' '}'; }
t_unex_name; check "unexercised: a block of another variable at the trigger's line is not read" $?
t_unex_nv() { t_unex_nodefault && t_unex_nullable && t_unex_heredoc && t_unex_moved && t_unex_link; }
t_unex_noschema() { SCHEMA= unex && [ "$(marked)" = '[]' ] && [ ! -e "$O/required.json" ]; }
t_unex_noschema; check "unexercised: with no provider schema nothing is marked, a dynamic block neither" $?
t_unex_badschema() { printf '%s' '{"provider_schemas":{"x":{"resource_schemas":"bad"}}}' > "$TMP/schema-bad.json"
  SCHEMA="$TMP/schema-bad.json" unex && [ "$(marked)" = '[]' ] && [ "$(cat "$O/required.json")" = '["*"]' ]; }
t_unex_badschema; check "unexercised: a schema the required reader cannot read requires everything" $?
t_unex_badreq() { UREQ='{"a": 1}' unex && [ "$(marked)" = '[]' ]; }
t_unex_badreq; check "unexercised: a required list that is not a list of strings requires everything" $?
t_unex_nested_req() { printf '%s' '{"format_version":"1.0","provider_schemas":{"registry.terraform.io/hashicorp/aws":{"resource_schemas":{"aws_lb_listener":{"version":0,"block":{"attributes":{"idle_timeout":{"type":"number","optional":true}},"block_types":{"default_action":{"nesting_mode":"list","block":{"attributes":{"target_group_arn":{"type":"string","required":true}}}}}}}}}}}' > "$TMP/schema-nreq.json"
  SCHEMA="$TMP/schema-nreq.json" unex . '.triggers |= map(if .id == "T-008" then .attribute = "default_action.target_group_arn" else . end)' \
    && [ "$(marked)" = '["T-014"]' ] && grep -qF '"aws_lb_listener.default_action.target_group_arn"' "$O/required.json"; }
t_unex_nested_req; check "unexercised: an attribute the schema requires inside a block is not marked" $?
t_unex_nested_dyn() { printf '%s' '{"format_version":"1.0","provider_schemas":{"registry.terraform.io/hashicorp/aws":{"resource_schemas":{"aws_lb_listener":{"version":0,"block":{"attributes":{"idle_timeout":{"type":"number","optional":true}},"block_types":{"default_action":{"nesting_mode":"list","block":{"attributes":{},"block_types":{"inner":{"nesting_mode":"list","min_items":1,"block":{"attributes":{}}}}}}}}}}}}}' > "$TMP/schema-ndyn.json"
  SCHEMA="$TMP/schema-ndyn.json" unex . '.triggers |= map(if .id == "T-014" then .attribute = "default_action.dynamic.inner" else . end)' \
    && [ "$(marked)" = '["T-008"]' ] && grep -qF '"aws_lb_listener.default_action.inner"' "$O/required.json"; }
t_unex_nested_dyn; check "unexercised: a dynamic block inside a block meets its required path" $?
t_unex_lacktype() { printf '%s' '{"format_version":"1.0","provider_schemas":{"registry.terraform.io/hashicorp/aws":{"resource_schemas":{"aws_db_instance":{"version":0,"block":{"attributes":{}}}}}}}' > "$TMP/schema-lack.json"
  SCHEMA="$TMP/schema-lack.json" unex && [ "$(marked)" = '[]' ] && grep -qF '"aws_lb_listener.*"' "$O/required.json"; }
t_unex_lacktype; check "unexercised: a schema that lacks the trigger's resource type marks nothing" $?
t_unex_nullattr() { unex . '.triggers |= map(if .id == "T-008" then .attribute = null else . end)' && [ "$(q '.status == "ran"')" = 0 ] && [ "$(marked)" = '["T-014"]' ]; }
t_unex_nullattr; check "unexercised: a trigger with no attribute is unmarked and the step still runs" $?
t_unex_reader() { t_unex_typedef && t_unex_desc && t_unex_obj && t_unex_b8 && t_unex_list && t_unex_twodef; }
t_unex_cmt() { t_unex_cmt_lead && t_unex_cmt_hide && t_unex_cmt_brace; }


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

# --- Over the cap the tool lists a file with the triggers it cut: 45 changed files, 40 triggers, 5 entries
# with no trigger id and not inert, 5 over the cap. It classifies as ran; at capped 0 the same entry is refused.
t_big45() {
  setup
  jq -n '[range(45) | {filename: "f\(. + 10).tf", status: "modified", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-a\n+b"}]' > "$TMP/files-45.json"
  jq -n --argjson cap "${1:-5}" '{schema_version: 1, inert: false, capped: $cap,
    entries: [range(45) | {path: "f\(. + 10).tf", change_kind: "modified", inert: false,
      trigger_ids: (if . < 40 then ["T-\("00\(. + 1)" | .[-3:])"] else [] end)}],
    triggers: [range(40) | {id: "T-\("00\(. + 1)" | .[-3:])", file: "f\(. + 10).tf", line: 1, category: "literal-argument-change", change_kind: "modified"}]}' > "$TMP/behaviour.out"
  DIFF="$TMP/files-45.json" classify
  if [ "${1:-5}" = 0 ]; then grep -qF 'not run: output refused' "$O/classify.txt"
  else [ "$(head -n 1 "$O/classify.txt")" = "behaviour: ran, 40 triggers, 5 over the cap" ]; fi
}
t_big45; check "capped: 45 changed files, 5 entries without a trigger, classify runs: 40 triggers, 5 over the cap" $?
t_big45 0; check "capped: the same entries at capped 0 are refused" $?

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
refuse_b "an entry with no trigger that is not inert" '.entries += [{path: "x.tf", change_kind: "modified", inert: false, trigger_ids: []}]'
refuse_b "an entry with no trigger and no inert flag" '.entries += [{path: "x.tf", change_kind: "modified", trigger_ids: []}]'
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
refuse_claims "49 claims" "$(jq -c '.claims = [range(49) as $i | .claims[0] + {claim_id: "C-\($i)"}]' "$TMP/claims-556.json")"
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
jq '.triggers[0].changes = [{level: "L1", case: "empty-element", attribute: "value", explained: false, inputs: {vpc_security_group_ids: [""]}}, {level: "L1", case: "unknown-element", attribute: "length", explained: true, explained_by: ["C-1", "C-2"], inputs: {}}]' "$TMP/eval-556.json" > "$TMP/eval.out"
classify; evalp --claims "$TMP/claims-556.json"
grep -qxF 'change T-001 L1 case empty-element value: unexplained' "$O/record.txt" \
  && grep -qxF 'change T-001 L1 case unknown-element length: explained by C-1, C-2' "$O/record.txt"
check "changes: one record line each" $?
! grep -qF 'vpc_security_group_ids' "$O/record.txt"; check "changes: no input crosses" $?
refuse_e "a change with a bad case id" '.triggers[0].changes = [{level: "L1", case: "a b", attribute: "value", explained: false, inputs: {}}]'
refuse_e "an explained_by id outside the pattern" '.triggers[0].changes = [{level: "L1", case: "c", attribute: "length", explained: true, explained_by: ["X-1"], inputs: {}}]'
refuse_e "an explained_by id the claims file has not" '.triggers[0].changes = [{level: "L1", case: "c", attribute: "length", explained: true, explained_by: ["C-9"], inputs: {}}]'
refuse_e "21 explained_by ids" '.triggers[0].changes = [{level: "L1", case: "c", attribute: "length", explained: true, explained_by: ([range(21)] | map("C-1")), inputs: {}}]'
refuse_e "an unexplained change with explained_by ids" '.triggers[0].changes = [{level: "L1", case: "c", attribute: "length", explained: false, explained_by: ["C-1"], inputs: {}}]'
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

# --- Contract 5: claims-eval's complete, outstanding and evidence_digest cross to the run object
# as they are, and to the record line of the trigger; each is held to its grammar.
DG="$(printf 'digest' | shasum -a 256 | cut -c1-64)"
OUT='["T-001|L1|empty|value", "T-001|L1|null-element|value"]'
setup
jq --argjson o "$OUT" --arg d "$DG" '.triggers[0] += {complete: true, outstanding: $o, evidence_digest: $d}
  | .triggers[1] += {complete: false, outstanding: []}' "$TMP/eval-556.json" > "$TMP/eval.out"
classify; evalp --claims "$TMP/claims-556.json"
check "outstanding: the run object carries the three fields as claims-eval gave them" "$(jq -e --argjson o "$OUT" --arg d "$DG" '
  .triggers[0] == {id: "T-001", file: "main.tf", line: 2, category: "wrapper-change", state: "unverifiable", complete: true, outstanding: $o, evidence_digest: $d}
  and .triggers[1] == {id: "T-002", file: "main.tf", line: 2, category: "unknown-propagation-candidate", state: "unverifiable", complete: false, outstanding: []}' \
  "$O/run-behaviour.json" > /dev/null; echo $?)"
grep -qxF "trigger T-001 \`main.tf\` line 2 wrapper-change: unverifiable, complete, outstanding 2, digest $DG" "$O/record.txt" &&
  grep -qxF 'trigger T-002 `main.tf` line 2 unknown-propagation-candidate: unverifiable' "$O/record.txt"
check "outstanding: the record line says complete, the count and the digest" $?
setup; classify; evalp --claims "$TMP/claims-556.json"
check "outstanding: absent fields stay absent" "$(q 'all(.triggers[]; keys == ["category", "file", "id", "line", "state"])')"
refuse_e "complete that is not a boolean" '.triggers[0].complete = "yes"'
refuse_e "an outstanding id outside the grammar" '.triggers[0].outstanding = ["T-001|L5|empty|value"]'
refuse_e "an outstanding id of another trigger" '.triggers[0].outstanding = ["T-002|L1|empty|value"]'
refuse_e "outstanding ids out of order" '.triggers[0].outstanding = ["T-001|L1|z|value", "T-001|L1|a|value"]'
refuse_e "an outstanding id twice" '.triggers[0].outstanding = ["T-001|L1|a|value", "T-001|L1|a|value"]'
refuse_e "257 outstanding ids" '.triggers[0].outstanding = ([range(257) | "T-001|L1|c\(1000 + .)|value"] | sort)'
refuse_e "a digest that is not 64 hex" '.triggers[0].outstanding = ["T-001|L1|a|value"] | .triggers[0].evidence_digest = "ABC"'
refuse_e "a digest with no outstanding difference" ".triggers[0].evidence_digest = \"$DG\""
refuse_e "a verified trigger with outstanding differences" '.triggers[0].state = "verified" | .triggers[0].outstanding = ["T-001|L1|a|value"]'
setup
jq '.triggers[0].also_categories = ["default-change", "provider-version-floor-change"]' "$TMP/behaviour-556.json" > "$TMP/behaviour.out"
classify; evalp --claims "$TMP/claims-556.json"
check "also_categories: copied from the classifier to the run trigger" "$(q '.triggers[0].also_categories == ["default-change", "provider-version-floor-change"] and (.triggers[1] | has("also_categories") | not)')"
refuse_b "an also_categories entry outside the list" '.triggers[0].also_categories = ["cosmetic"]'
refuse_b "an also_categories entry twice" '.triggers[0].also_categories = ["default-change", "default-change"]'
refuse_b "an empty also_categories" '.triggers[0].also_categories = []'
setup
jq '.triggers[1].base_expr = "null" | .triggers[1].base_absent = true | .triggers[1].change_kind = "added" | .triggers[0].head_absent = true' "$TMP/behaviour-556.json" > "$TMP/behaviour.out"
classify; evalp --claims "$TMP/claims-556.json"
check "base_absent and head_absent: a null side classifies and evaluates, and crosses to no run trigger or record line" "$([ -f "$O/behaviour.json" ] && q '.status == "ran" and all(.triggers[]; (has("base_absent") or has("head_absent")) | not)' | grep -qx 0 && ! grep -q absent "$O/record.txt"; echo $?)"

# --- Usage: eval before classify, a relative path, an out directory holding outputs.
setup; evalp; check "eval before classify is a usage error" "$([ $? = 2 ]; echo $?)"
setup; bash "$BP" classify --facts "$FACTS" --dir clone --diff "$TMP/files.json" --out "$O" > /dev/null 2>&1
check "a relative --dir is a usage error" "$([ $? = 2 ]; echo $?)"
setup; classify; bash "$BP" classify --facts "$FACTS" --dir "$MOD" --diff "$TMP/files.json" --out "$O" > /dev/null 2>&1
check "classify into a used out directory is a usage error" "$([ $? = 2 ]; echo $?)"
setup; bash "$BP" classify --facts "$FACTS" --dir "$MOD" --out "$O" > /dev/null 2>&1
check "classify with neither --diff nor --base is a usage error" "$([ $? = 2 ]; echo $?)"
setup; echo '{"provider_schemas":{}}' > "$TMP/schema.json"; bash "$BP" classify --facts "$FACTS" --dir "$MOD" --diff "$TMP/files.json" --schema "$TMP/schema.json" --out "$O" > /dev/null 2>&1
check "classify passes --schema to mtf-facts behaviour" "$([ -f "$O/behaviour.json" ] && grep -q -- "behaviour .* --schema $TMP/schema.json" "$TMP/facts.log"; echo $?)"
setup; bash "$BP" classify --facts "$FACTS" --dir "$MOD" --diff "$TMP/files.json" --schema schema.json --out "$O" > /dev/null 2>&1
check "a relative --schema is a usage error" "$([ $? = 2 ]; echo $?)"
setup; ln -sf "$TMP/schema.json" "$TMP/schema-link.json"; bash "$BP" classify --facts "$FACTS" --dir "$MOD" --diff "$TMP/files.json" --schema "$TMP/schema-link.json" --out "$O" > /dev/null 2>&1
check "a --schema that is a link is a usage error" "$([ $? = 2 ]; echo $?)"
setup; bash "$BP" classify --facts "$FACTS" --dir "$MOD" --diff "$TMP/files.json" --schema "$TMP/missing.json" --out "$O" > /dev/null 2>&1
check "a missing --schema is a usage error" "$([ $? = 2 ]; echo $?)"

# --- The plan coverage in the module root frame. With a module root prefix the triggers are
# module-relative and the coverage in the ladder record repository-relative, so eval moves each
# example and module call directory into the module root frame before claims-eval reads it.
IRSA=modules/iam-role-for-service-accounts
jq --arg p "$IRSA" '[.[0] + {filename: ($p + "/policies.tf")}]' "$TMP/files.json" > "$TMP/files-irsa.json"
jq '.entries = [{path: "policies.tf", change_kind: "modified", inert: false, trigger_ids: ["T-001", "T-002"]}]
  | .triggers |= map(.file = "policies.tf" | .line = 3 | .address = "aws_iam_policy.this" | .attribute = "policy" | .levels = ["L4"])' \
  "$TMP/behaviour-556.json" > "$TMP/behaviour-irsa.json"
# A repository root example that calls the submodule, another submodule, a sibling whose name
# starts with the prefix, the repository root and a path that climbs out; an example inside the
# module root; an example with no module call.
jq -n --arg h "$HEAD" --arg b "$BASE" --arg p "$IRSA" '{schema_version: 1, head_sha: $h, base_sha: $b,
  terraform_version: "1.9.8", pins: [], runs: [], coverage: {class: "complete", examples: [
   {dir: "examples/iam-role-for-service-accounts", head: "planned", base: null,
    addresses: ["aws_iam_policy.this", "module.irsa.aws_iam_policy.this", "module.role.aws_iam_policy.this",
                "module.v2.aws_iam_policy.this", "module.root.aws_iam_policy.this", "module.up.aws_iam_policy.this"],
    attributes: {"module.irsa.aws_iam_policy.this": ["policy"]},
    module_calls: {irsa: $p, role: "modules/iam-role", v2: ($p + "-v2"), root: ".", up: ($p + "/../iam-role")}},
   {dir: ($p + "/examples/inner"), head: "planned", base: null, addresses: ["module.self.aws_iam_policy.this"],
    module_calls: {self: $p, nested: ($p + "/modules/x")}},
   {dir: "examples/plain", head: "planned", base: null, addresses: ["aws_iam_policy.this"]}]}}' > "$TMP/ladder-irsa.json"
jq '.coverage.examples[0] |= (.dir = "/examples/iam-role-for-service-accounts" | .module_calls = {irsa: "."})
  | .coverage.examples[1] |= (.dir = "examples/inner" | .module_calls = {self: ".", nested: "modules/x"})
  | .coverage.examples[2].dir = "/examples/plain"' "$TMP/ladder-irsa.json" > "$TMP/want-ladder-irsa.json"
# matched <example index> <plan address> <trigger address> <trigger directory>: addressMatch of
# mtf-facts claims-eval on the ladder record it was handed.
matched() {
  jq -e --argjson i "$1" --arg a "$2" --arg t "$3" --arg d "$4" '.coverage.examples[$i] as $e
    | if $e.dir == $d then $a == $t
      else [$a | capture("^module\\.(?<c>[A-Za-z0-9_-]+)\\.(?<r>.+)$")] as $m
        | ($m | length) == 1 and ($e.module_calls // {} | .[$m[0].c]) == $d and $m[0].r == $t end' \
    "$TMP/ladder-seen.json" > /dev/null 2>&1
}
frame() { # the module root frame cases, under the BP in force
  setup; cp "$TMP/behaviour-irsa.json" "$TMP/behaviour.out"
  DIFF="$TMP/files-irsa.json" PFX="$IRSA" classify; evalp --ladder "$TMP/ladder-irsa.json" --prefix "$IRSA" --claims "$TMP/claims-556.json"
  check "frame: eval runs claims-eval" "$(q '.status == "ran"')"
  cmp -s <(jq -S . "$TMP/want-ladder-irsa.json") <(jq -S . "$TMP/ladder-seen.json"); check "frame: the coverage claims-eval gets is in the module root frame" $?
  matched 0 module.irsa.aws_iam_policy.this aws_iam_policy.this .; check "frame: a submodule trigger is covered through the call whose source is the module root" $?
  matched 1 module.self.aws_iam_policy.this aws_iam_policy.this .; check "frame: and through a call of an example inside the module root" $?
  for a in role v2 root up; do
    ! matched 0 "module.$a.aws_iam_policy.this" aws_iam_policy.this . && ! matched 0 "module.$a.aws_iam_policy.this" aws_iam_policy.this "$IRSA"
    check "frame: the call $a outside the module root never matches" $?
  done
  ! matched 0 aws_iam_policy.this aws_iam_policy.this . && ! matched 2 aws_iam_policy.this aws_iam_policy.this .
  check "frame: a resource of an example outside the module root never matches a trigger at its root" $?
  matched 1 module.nested.aws_iam_policy.this aws_iam_policy.this modules/x; check "frame: a call to a directory below the module root keeps its relative path" $?
  setup; cp "$TMP/behaviour-irsa.json" "$TMP/behaviour.out"
  DIFF="$TMP/files-irsa.json" PFX="$IRSA" classify; evalp --ladder "$TMP/ladder-irsa.json" --prefix "$IRSA/"
  cmp -s <(jq -S . "$TMP/want-ladder-irsa.json") <(jq -S . "$TMP/ladder-seen.json"); check "frame: a prefix with a trailing slash is the same frame" $?
  # The root module, no prefix: the record crosses byte for byte, so the repository-relative
  # call matches a repository-relative trigger as before.
  setup; classify; evalp --ladder "$TMP/ladder-irsa.json"
  cmp -s "$TMP/ladder-irsa.json" "$TMP/ladder-seen.json"; check "frame: with no prefix the record is passed as it is" $?
  matched 0 module.irsa.aws_iam_policy.this aws_iam_policy.this "$IRSA"; check "frame: with no prefix the repository-relative call still matches" $?
  setup; classify; evalp --ladder "$TMP/ladder-irsa.json" --prefix ""
  cmp -s "$TMP/ladder-irsa.json" "$TMP/ladder-seen.json"; check "frame: an empty prefix is no prefix" $?
  # With no ladder record, the empty one still reaches claims-eval with a prefix.
  setup; classify; evalp --prefix "$IRSA"
  jq -e '.coverage == {class: "none", examples: []}' "$TMP/ladder-seen.json" > /dev/null 2>&1; check "frame: the empty record with a prefix" $?
  setup; classify; jq '.coverage.examples = "x"' "$TMP/ladder-irsa.json" > "$TMP/ladder-bad.json"; evalp --ladder "$TMP/ladder-bad.json" --prefix "$IRSA"
  notrun "frame: coverage that cannot be rewritten" "ladder refused"
  for p in ../x /abs . a/../b; do
    setup; classify; evalp --ladder "$TMP/ladder-irsa.json" --prefix "$p"
    check "frame: the prefix $p is a usage error" "$([ $? = 2 ] && [ ! -e "$O/record.txt" ]; echo $?)"
  done
}
frame

# --- Negative self-check: each mutation of a temp copy of behaviour-pass.sh must make the frame
# cases fail.
mc=0
mutate() { # name, perl substitution
  local d="$TMP/mut-$mc"; mc=$((mc + 1)); mkdir -p "$d"
  cp "$BP" "$d/behaviour-pass.sh"; perl -0pi -e "$2" "$d/behaviour-pass.sh"
  if cmp -s "$d/behaviour-pass.sh" "$BP"; then check "self-check: $1 (the mutation changed nothing)" 1; return; fi
  local keep="$BP" before="$fails"; BP="$d/behaviour-pass.sh"
  frame > /dev/null 2>&1; local caught=$((fails - before))
  BP="$keep"; fails="$before"
  check "self-check: $1 is caught" "$([ "$caught" -gt 0 ]; echo $?)"
}
mutate "the coverage not rewritten" 's/  if \[ -n "\$prefix" \]; then\n    jq/  if false; then\n    jq/'
mutate "the prefix matched without its slash" 's/startswith\(\$p \+ "\/"\)/startswith(\$p)/'
mutate "a call outside the module root kept" 's/ \| select\(\.value != null\)//'
mutate "an example outside the module root at the root" 's/\(rel \/\/ \("\/" \+ \.\)\)/(rel \/\/ ".")/'
mutate "a path that climbs out kept" 's/ and \(split\("\/"\) \| all\(\. != "\.\."\)\)//'
mutate "the prefix not checked" 's/  case "\$prefix" in [^\n]*\n//'
mutate "the trailing slash kept" 's/  prefix="\$\{prefix%\/\}"\n//'
# --- Wrapper versions: the host's generator result for each wrapper versions.tf the change
# touches, from the head tree, and the eval that makes a generated wrapper's trigger inert.
WFX="$SRC/tests/pr-fix-fixture" # recorded upstream: each module's versions.tf and its wrappers/versions.tf
G() { git -C "$WR" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"; }
# pin <rev> [hook]: a .pre-commit-config.yaml with pre-commit-terraform at the rev and its wrapper hook.
pin() {
  printf 'repos:\n  - repo: https://github.com/pre-commit/pre-commit-hooks\n    rev: v6.0.0\n    hooks:\n      - id: check-merge-conflict\n  - repo: https://github.com/antonbabenko/pre-commit-terraform\n    rev: %s\n    hooks:\n      - id: terraform_fmt\n      - id: %s\n' "$1" "${2:-terraform_wrapper_module_for_each}"
}
# wrepo <setup>: a repository with the vpc module and its wrapper at the root, the cloudfront one
# as modules/sub, pinned at v1.108.1, then <setup> run in it, committed; sets WR and WH.
wn=0
wrepo() {
  wn=$((wn + 1)); WR="$TMP/wrepo-$wn"; mkdir -p "$WR/wrappers/sub" "$WR/modules/sub"
  cp "$WFX/terraform-aws-vpc/versions.tf" "$WR/versions.tf"; cp "$WFX/terraform-aws-vpc/wrappers/versions.tf" "$WR/wrappers/versions.tf"
  cp "$WFX/terraform-aws-cloudfront/versions.tf" "$WR/modules/sub/versions.tf"; cp "$WFX/terraform-aws-cloudfront/wrappers/versions.tf" "$WR/wrappers/sub/versions.tf"
  pin v1.108.1 > "$WR/.pre-commit-config.yaml"
  ( cd "$WR" && eval "$1" ) || return 1
  G init -q && G add -A && G commit -q -m head && WH="$(G rev-parse HEAD)"
}
# wrap <files...>, after setup: the wrappers command on the paths as the changed files; prints wrappers.txt.
wrap() {
  local f
  for f in "$@"; do jq -n --arg f "$f" '{filename: $f, status: "modified"}'; done | jq -s . > "$TMP/wfiles.json"
  bash "$BP" wrappers --clone "$WR" --head "$WH" --diff "$TMP/wfiles.json" ${WPFX:+--prefix "$WPFX"} --out "$O" > /dev/null 2>&1 &&
    cat "$O/wrappers.txt"
}
wis() { # expected lines, files...: the wrappers command prints exactly the lines
  local want="$1"; shift
  local got; setup; got="$(wrap "$@")"; [ "$got" = "$want" ] || { echo "got: $got"; return 1; }
}
t_wr_derived() { wrepo : && wis "wrappers/versions.tf derived" wrappers/versions.tf main.tf .pre-commit-config.yaml; }
t_wr_sub() { wrepo : && wis "wrappers/sub/versions.tf derived" wrappers/sub/versions.tf; }
t_wr_copied() {
  wrepo 'pin v1.105.0 > .pre-commit-config.yaml; cp versions.tf wrappers/versions.tf' &&
    wis "wrappers/sub/versions.tf differs
wrappers/versions.tf copied" wrappers/versions.tf wrappers/sub/versions.tf &&
    wrepo 'pin v1.89.0 > .pre-commit-config.yaml; cp versions.tf wrappers/versions.tf' && wis "wrappers/versions.tf copied" wrappers/versions.tf
}
# Before v1.89.0 the hook wrote a fixed template, so a wrapper equal to its module proves nothing.
t_wr_old() { wrepo 'pin v1.88.9 > .pre-commit-config.yaml; cp versions.tf wrappers/versions.tf' && wis "wrappers/versions.tf unknown old hook" wrappers/versions.tf; }
t_wr_differs() {
  wrepo 'printf "# by hand\n" >> wrappers/versions.tf' && wis "wrappers/versions.tf differs" wrappers/versions.tf &&
    wrepo 'perl -pi -e "s/>= 6.28/>= 6.30/" wrappers/versions.tf' && wis "wrappers/versions.tf differs" wrappers/versions.tf
}
t_wr_links() {
  wrepo 'rm wrappers/versions.tf; ln -s ../versions.tf wrappers/versions.tf' && wis "wrappers/versions.tf unknown wrapper link" wrappers/versions.tf &&
    wrepo 'mv modules/sub modules/real; ln -s real modules/sub' && wis "wrappers/sub/versions.tf unknown module link" wrappers/sub/versions.tf &&
    wrepo 'mv wrappers/sub w2; ln -s ../w2 wrappers/sub' && wis "wrappers/sub/versions.tf unknown wrapper link" wrappers/sub/versions.tf
}
t_wr_module() {
  wrepo 'mkdir wrappers/gone; cp wrappers/versions.tf wrappers/gone/versions.tf' && wis "wrappers/gone/versions.tf unknown module absent" wrappers/gone/versions.tf &&
    wrepo 'rm wrappers/versions.tf' && wis "wrappers/versions.tf unknown wrapper absent" wrappers/versions.tf
}
t_wr_pins() {
  wrepo 'rm .pre-commit-config.yaml' && wis "wrappers/versions.tf unknown no pin" wrappers/versions.tf &&
    wrepo 'printf "repos: []\n" > .pre-commit-config.yaml' && wis "wrappers/versions.tf unknown no pin" wrappers/versions.tf &&
    wrepo 'pin master > .pre-commit-config.yaml' && wis "wrappers/versions.tf unknown pin not a release tag" wrappers/versions.tf &&
    wrepo 'pin 0123456789abcdef0123456789abcdef01234567 > .pre-commit-config.yaml' && wis "wrappers/versions.tf unknown pin not a release tag" wrappers/versions.tf &&
    wrepo 'pin v1.108.1 terraform_docs > .pre-commit-config.yaml' && wis "wrappers/versions.tf unknown hook not listed" wrappers/versions.tf &&
    wrepo '{ pin v1.108.1; printf "# antonbabenko/pre-commit-terraform v1.100.0\n"; } > .pre-commit-config.yaml' && wis "wrappers/versions.tf unknown pin unreadable" wrappers/versions.tf &&
    wrepo 'pin "\"v1.106.0\"" > .pre-commit-config.yaml' && wis "wrappers/versions.tf derived" wrappers/versions.tf
}
# YAML a line reader would read another way than pre-commit: a second rev key, a spaced key, a
# mention in another letter case, an anchor. Each is no evidence.
t_wr_yaml() {
  wrepo 'pin v1.200.0 | perl -pe "s/^(    rev: v1.200.0)\$/\$1\\n    rev:\\n      v1.100.0/" > .pre-commit-config.yaml' && wis "wrappers/versions.tf unknown pin unreadable" wrappers/versions.tf &&
    wrepo 'pin v1.200.0 | perl -pe "s/^(    rev: v1.200.0)\$/\$1\\n    \"rev\": v1.100.0/" > .pre-commit-config.yaml' && wis "wrappers/versions.tf unknown pin unreadable" wrappers/versions.tf &&
    wrepo '{ pin v1.108.1; printf "  - repo: https://github.com/ANTONBABENKO/PRE-COMMIT-TERRAFORM\n    rev: v1.100.0\n"; } > .pre-commit-config.yaml' && wis "wrappers/versions.tf unknown pin unreadable" wrappers/versions.tf &&
    wrepo 'pin v1.108.1 | perl -pe "s/^(    rev: v1.108.1)\$/\$1\\n    x: \\&a 1/" > .pre-commit-config.yaml' && wis "wrappers/versions.tf unknown pin unreadable" wrappers/versions.tf
}
# Configurations that steer a line reader away from what a YAML loader reads, each with one form
# the reader refuses: no evidence. The first two hide a real v1.105.0 entry behind an escape and
# show a v1.106.0 decoy in a block scalar or under a second repos key; the others each hold one
# form alone. CFG_BAD lists them as file name and the form.
CF="$TMP/cfg"; mkdir -p "$CF"
H='      - id: terraform_wrapper_module_for_each'
P='  - repo: https://github.com/antonbabenko/pre-commit-terraform'
printf 'repos:\n  - repo: "https://github.com/\\x61ntonbabenko/pre-commit-terraform"\n    rev: v1.105.0\n    hooks:\n%s\n  - repo: local\n    hooks:\n      - id: x\n        entry: |\n          %s\n            rev: v1.106.0\n            hooks:\n        %s\n' "$H" "${P#  }" "$H" > "$CF/escape-scalar.yaml"
printf 'repos:\n%s\n    rev: v1.106.0\n    hooks:\n%s\nrepos:\n  - repo: "https://github.com/\\x61ntonbabenko/pre-commit-terraform"\n    rev: v1.105.0\n    hooks:\n%s\n' "$P" "$H" "$H" > "$CF/escape-repos.yaml"
# One form alone, beside a readable v1.106.0 entry: the reader would read derived without its check.
pin v1.106.0 > "$CF/base.yaml"
{ cat "$CF/base.yaml"; printf '        args: ["--args=a\\x2db"]\n'; } > "$CF/backslash.yaml"
{ printf -- '---\n'; cat "$CF/base.yaml"; } > "$CF/marker.yaml"
{ cat "$CF/base.yaml"; printf 'repos:\n  - repo: local\n    hooks: []\n'; } > "$CF/repos-twice.yaml"
printf 'repos:\n  - repo: local\n    hooks:\n      - id: x\n        entry: "a\n%s\n    rev: v1.106.0\n    hooks:\n%s\n          - b"\n' "$P" "$H" > "$CF/open-quote.yaml"
printf 'repos:\n  - repo: local\n    hooks:\n      - id: x\n        entry: |\n%s\n    rev: v1.106.0\n    hooks:\n%s\n' "$P" "$H" > "$CF/block-scalar.yaml"
{ cat "$CF/base.yaml"; printf '  - repo: local\n    hooks:\n      - {id: x, entry: x, language: system}\n'; } > "$CF/flow-map.yaml"
{ cat "$CF/base.yaml"; printf '        args: [a,\n'; } > "$CF/flow-open.yaml"
{ cat "$CF/base.yaml"; printf '  - repo: https://example.com/%%61\n    rev: v1\n    hooks:\n      - id: x\n'; } > "$CF/percent.yaml"
{ cat "$CF/base.yaml"; printf '  - repo: https://github.com/someone/fork\n    rev: v1.105.0\n    hooks:\n%s\n' "$H"; } > "$CF/fork.yaml"
# A plain scalar continued onto key-like lines with no space after the colon, a continued rev,
# and a repo key with no space after its colon, which YAML reads as text.
printf 'repos:\n  - repo: local\n    hooks:\n      - id: x\n        entry: echo\n          - repo:https://github.com/antonbabenko/pre-commit-terraform\n          rev:v1.106.0\n          - id:terraform_wrapper_module_for_each\n' > "$CF/plain-decoy.yaml"
pin v1.106.0 | sed 's/^    rev: v1.106.0$/&\n      v1.105.0/' > "$CF/rev-continued.yaml"
pin v1.106.0 | sed 's/^  - repo: https/  - repo:https/' > "$CF/repo-nospace.yaml"
pin v1.106.0 | sed 's/- id: terraform_wrapper/- id:terraform_wrapper/' > "$CF/id-nospace.yaml"
pin v1.106.0 | sed 's/^    rev: v1.106.0$/    rev: v1.106.0#x/' > "$CF/rev-hash.yaml"
pin v1.106.0 | sed 's/^    rev: v1.106.0$/   rev: v1.106.0/' > "$CF/rev-dedent.yaml"
{ printf 'x:\n'; pin v1.106.0 | sed 's/^/  /'; } > "$CF/repos-nested.yaml"
pin 1.106.0 > "$CF/rev-no-v.yaml"
CFG_BAD="escape-scalar escape-repos backslash marker repos-twice open-quote block-scalar flow-map flow-open percent fork plain-decoy rev-continued repo-nospace rev-hash rev-no-v rev-dedent repos-nested"
t_wr_steer() { # [names]: each configuration gives unknown pin unreadable
  local cf # not c: setup counts with it
  for cf in ${1:-$CFG_BAD}; do
    wrepo "cp '$CF/$cf.yaml' .pre-commit-config.yaml" && wis "wrappers/versions.tf unknown pin unreadable" wrappers/versions.tf || { echo "$cf"; return 1; }
  done
}
# The family's own configuration, with a one-line flow sequence as some of its repositories carry:
# derived. A hook option that moves it to another provider, and a module with another provider_meta
# block than aws, are no evidence.
printf 'repos:\n%s\n    rev: v1.108.1\n    hooks:\n      - id: terraform_fmt\n%s\n      - id: terraform_docs\n        args:\n          - %s\n      - id: terraform_validate\n  - repo: https://github.com/pre-commit/pre-commit-hooks\n    rev: v6.0.0\n    hooks:\n      - id: check-merge-conflict\n      - id: mixed-line-ending\n        args: [--fix=lf]\n' "$P" "$H" "'--args=--lockfile=false'" > "$CF/family.yaml"
{ cat "$CF/base.yaml"; printf '        args:\n          - --module-repo-provider=azurerm\n'; } > "$CF/provider-option.yaml"
t_wr_family() {
  wrepo "cp '$CF/family.yaml' .pre-commit-config.yaml" && wis "wrappers/versions.tf derived" wrappers/versions.tf &&
    wrepo "cp '$CF/provider-option.yaml' .pre-commit-config.yaml" && wis "wrappers/versions.tf unknown hook options" wrappers/versions.tf &&
    wrepo "cp '$CF/id-nospace.yaml' .pre-commit-config.yaml" && wis "wrappers/versions.tf unknown hook not listed" wrappers/versions.tf
}
t_wr_provider() {
  wrepo 'perl -pi -e "s/provider_meta \"aws\"/provider_meta \"awscc\"/" versions.tf wrappers/versions.tf' &&
    wis "wrappers/versions.tf unknown provider_meta" wrappers/versions.tf &&
    wrepo 'pin v1.105.0 > .pre-commit-config.yaml; perl -pi -e "s/provider_meta \"aws\"/provider_meta \"awscc\"/" versions.tf; cp versions.tf wrappers/versions.tf' &&
    wis "wrappers/versions.tf copied" wrappers/versions.tf
}
t_wr_partial() { wrepo : && G config extensions.partialClone origin && wis "wrappers/versions.tf unknown partial clone" wrappers/versions.tf; }
t_wr_long() { # a sub component over 64 characters is no wrapper of the pairing
  local s; s="$(printf "s%.0s" $(seq 65))"
  wrepo "mkdir -p wrappers/$s modules/$s; cp versions.tf modules/$s/; cp wrappers/versions.tf wrappers/$s/" && wis "" "wrappers/$s/versions.tf" &&
    s="${s%s}" && wrepo "mkdir -p wrappers/$s modules/$s; cp versions.tf modules/$s/; cp wrappers/versions.tf wrappers/$s/" && wis "wrappers/$s/versions.tf derived" "wrappers/$s/versions.tf"
}
t_wr_size() {
  wrepo 'perl -e "print qq(#) x 70000, qq(\n)" >> wrappers/versions.tf' && wis "wrappers/versions.tf unknown wrapper over size" wrappers/versions.tf &&
    wrepo 'printf "x = <<EOT\ny\nEOT\n" >> versions.tf' && wis "wrappers/versions.tf unknown derive undefined" wrappers/versions.tf
}
t_wr_prefix() {
  wrepo 'mkdir mod; mv versions.tf wrappers modules mod/' && WPFX=mod wis "wrappers/sub/versions.tf derived
wrappers/versions.tf derived" mod/wrappers/versions.tf mod/wrappers/sub/versions.tf wrappers/versions.tf
}
t_wr_derived; check "wrappers: a root wrapper at v1.108.1 is derived" $?
t_wr_sub; check "wrappers: a submodule wrapper is derived from modules/<sub>/versions.tf" $?
t_wr_old; check "wrappers: a pin before v1.89.0 is unknown old hook" $?
t_wr_copied; check "wrappers: at v1.105.0 a wrapper equal to its module is copied and a derived one differs" $?
t_wr_differs; check "wrappers: a hand edit differs" $?
t_wr_links; check "wrappers: a wrapper that is a link, a module under a linked directory and a wrapper under one are unknown" $?
t_wr_module; check "wrappers: a missing module file and a deleted wrapper are unknown" $?
t_wr_pins; check "wrappers: no config, no pin, a branch, a commit SHA, no wrapper hook and a second mention are unknown; a quoted tag reads" $?
t_wr_yaml; check "wrappers: a second rev key, a spaced rev key, a mention in another letter case and an anchor are unreadable" $?
t_wr_steer; check "wrappers: an escape hiding a real v1.105.0 entry behind a block scalar or second repos decoy, a backslash, a document marker, a second repos key, an open quote, a block scalar, a flow mapping, an open flow sequence, a percent escape, a fork listing the hook, a plain scalar continued onto key-like lines, a continued rev and a repo key with no space are unreadable" $?
t_wr_family; check "wrappers: the family's own configuration with a one-line flow sequence is derived; a provider option is unknown; a hook id with no space after its colon is not listed" $?
t_wr_provider; check "wrappers: a module with another provider_meta block is unknown at v1.106.0 and copied before" $?
t_wr_partial; check "wrappers: a partial clone is unknown" $?
t_wr_long; check "wrappers: a sub component of 65 characters is left out, one of 64 is read" $?
t_wr_size; check "wrappers: an over-size wrapper and a module derive cannot read are unknown" $?
t_wr_prefix; check "wrappers: under a module root prefix the paths are module-relative and outside paths are left out" $?
wrepo : && setup && wrap main.tf > /dev/null && [ ! -s "$O/wrappers.txt" ]; check "wrappers: no wrapper touched, an empty file" $?
wrepo : && setup && bash "$BP" wrappers --clone "$WR" --head "$WH" --out "$O" > /dev/null 2>&1; check "wrappers: no --diff is a usage error" "$([ $? = 2 ]; echo $?)"

# eval with the evidence: an unverifiable trigger at a derived or copied wrapper is inert, with
# no outstanding difference; one at a differing wrapper and a refuted one stay as they were.
WBEH='{"schema_version":1,"inert":false,
 "entries":[{"path":"wrappers/versions.tf","trigger_ids":["T-001"]},{"path":"wrappers/sub/versions.tf","trigger_ids":["T-002"]},
            {"path":"wrappers/x/versions.tf","trigger_ids":["T-003"]},{"path":"main.tf","trigger_ids":["T-004"]}],
 "triggers":[{"id":"T-001","file":"wrappers/versions.tf","line":11,"category":"unclassified-change"},
  {"id":"T-002","file":"wrappers/sub/versions.tf","line":11,"category":"unclassified-change"},
  {"id":"T-003","file":"wrappers/x/versions.tf","line":11,"category":"unclassified-change"},
  {"id":"T-004","file":"main.tf","line":2,"category":"unclassified-change"}],"capped":0}'
WEV='{"schema_version":1,"capped":0,"triggers":[
  {"id":"T-001","state":"unverifiable","complete":true,"outstanding":["T-001|L1|c|value"],"evidence_digest":"'"$(printf 'a%.0s' $(seq 64))"'","changes":[{"level":"L1","case":"c","attribute":"value","explained":false}]},
  {"id":"T-002","state":"unverifiable"},{"id":"T-003","state":"refuted"},{"id":"T-004","state":"unverifiable"}],
 "claims":[],"discarded_claims":[]}'
t_wr_eval() {
  setup; printf '%s\n' "$WBEH" > "$TMP/behaviour.out"; printf '%s\n' "$WEV" > "$TMP/eval.out"
  printf '%s\n' "${1:-wrappers/sub/versions.tf differs
wrappers/versions.tf derived
wrappers/x/versions.tf copied}" > "$TMP/wrappers.txt"
  DIFF="$TMP/files-w.json" classify; evalp --wrappers "$TMP/wrappers.txt"
  [ "$(q '[.triggers[] | {id, state} + with_entries(select(.key | IN("complete", "outstanding", "evidence_digest")))]
    == [{id: "T-001", state: "inert"}, {id: "T-002", state: "unverifiable"}, {id: "T-003", state: "refuted"}, {id: "T-004", state: "unverifiable"}]')" = 0 ] ||
    { echo "run object"; return 1; }
  grep -qxF 'trigger T-001 `wrappers/versions.tf` line 11 unclassified-change: inert, wrapper derived' "$O/record.txt" &&
    grep -qxF 'trigger T-002 `wrappers/sub/versions.tf` line 11 unclassified-change: unverifiable' "$O/record.txt" &&
    ! grep -q '^change T-001' "$O/record.txt" || { echo record; return 1; }
}
t_wr_eval_malformed() { # a file with one line outside the grammar is no evidence
  t_wr_eval "wrappers/versions.tf maybe
wrappers/versions.tf derived" > /dev/null; [ "$(q '.triggers[0].state == "unverifiable" and .triggers[0].outstanding == ["T-001|L1|c|value"]')" = 0 ]
}
jq -n '[{filename: "wrappers/versions.tf", status: "modified"}, {filename: "wrappers/sub/versions.tf", status: "modified"},
  {filename: "wrappers/x/versions.tf", status: "modified"}, {filename: "main.tf", status: "modified"}]' > "$TMP/files-w.json"
t_wr_eval; check "wrappers eval: a derived wrapper's trigger is inert with its reason, a differing one and a refuted one stay" $?
t_wr_eval_malformed; check "wrappers eval: a wrappers file with a line outside its grammar is no evidence" $?

# The render of a run whose only trigger is a derived wrapper: no unknown at rule 4 from it.
t_wr_render() {
  setup; printf '%s\n' "$WBEH" | jq -c '.entries |= .[:1] | .triggers |= .[:1]' > "$TMP/behaviour.out"
  printf '%s\n' "$WEV" | jq -c '.triggers |= .[:1]' > "$TMP/eval.out"
  printf 'wrappers/versions.tf derived\n' > "$TMP/wrappers.txt"
  jq '.[:1]' "$TMP/files-w.json" > "$TMP/files-w1.json"; DIFF="$TMP/files-w1.json" classify; evalp --wrappers "$TMP/wrappers.txt"
  jq -n --slurpfile b "$O/run-behaviour.json" '{format: 1, triage: false, plan_ran: false, verify_gaps: [], behaviour: $b[0],
    coverage: {class: "complete", inert: false, unplanned: []},
    counts: {"instruction-like-text-from-others": 0, "conversation-claims-unread": 0, "review.quoted-claim-unverifiable": 0}}' > "$TMP/run-w.json"
  printf '[]\n' > "$TMP/findings-w.json"; mkdir -p "$TMP/render-w$c"
  local m; m="$(bash "$RCU" --head "$HEAD" --findings "$TMP/findings-w.json" --host "$TMP/host.json" --checks "$TMP/checks" \
    --run "$TMP/run-w.json" --assessment "$TMP/assess.txt" --run-dir "$TMP/rundir" --out "$TMP/render-w$c" 2>&1)"
  case "$m" in "rendered approve (ladder rule 8),"*) ;; *) echo "$m"; return 1 ;; esac
}
t_wr_render; check "wrappers render: a run whose only trigger is a derived wrapper approves" $?

# --- Caller code (behaviour-pass.md, Caller Code): a literal argument change in a .tf file below
# examples/ or tests/ that mtf-facts behaviour marked caller_code. claims-eval reads it as inert. eval
# keeps the mark only when classify recorded the repository root (the --diff form with no prefix, at a
# directory holding .git), eval gets no prefix either, and the verify record shows validate passed at
# the head in the trigger's own example directory; otherwise claims-eval gets the trigger with no mark.
# The classifier output is recorded from mtf-facts behaviour of the facts change that adds the field, on
# examples/complete/main.tf modified in place: a literal changed, one added and one removed.
cat > "$TMP/behaviour-caller.json" <<'EOF2'
{"schema_version":1,"inert":false,"entries":[{"path":"examples/complete/main.tf","change_kind":"modified","inert":false,"trigger_ids":["T-001"]}],"triggers":[{"id":"T-001","file":"examples/complete/main.tf","line":3,"category":"literal-argument-change","change_kind":"modified","address":"module.s3","attribute":"name","base_expr":"\"a\"","head_expr":"\"b\"","referenced_inputs":[],"contextual_refs":[],"contextual_ref_details":[],"pure":true,"levels":["L4"],"reason":null,"caller_code":true}],"capped":0}
EOF2
cat > "$TMP/behaviour-caller-add.json" <<'EOF2'
{"schema_version":1,"inert":false,"entries":[{"path":"examples/complete/main.tf","change_kind":"modified","inert":false,"trigger_ids":["T-001"]}],"triggers":[{"id":"T-001","file":"examples/complete/main.tf","line":5,"category":"literal-argument-change","change_kind":"added","address":"module.s3","attribute":"flag","base_expr":null,"head_expr":"true","referenced_inputs":[],"contextual_refs":[],"contextual_ref_details":[],"pure":true,"levels":["L4"],"reason":null,"caller_code":true}],"capped":0}
EOF2
cat > "$TMP/behaviour-caller-rem.json" <<'EOF2'
{"schema_version":1,"inert":false,"entries":[{"path":"examples/complete/main.tf","change_kind":"modified","inert":false,"trigger_ids":["T-001"]}],"triggers":[{"id":"T-001","file":"examples/complete/main.tf","line":4,"category":"literal-argument-change","change_kind":"removed","address":"module.s3","attribute":"extra","base_expr":"\"x\"","head_expr":null,"referenced_inputs":[],"contextual_refs":[],"contextual_ref_details":[],"pure":true,"levels":["L4"],"reason":null,"caller_code":true}],"capped":0}
EOF2
# The repository: the module root at its top, and the same tree as modules/s3 under it.
CMOD="$TMP/caller-repo"
for r in "$CMOD" "$CMOD/modules/s3"; do
  mkdir -p "$r/examples/complete" "$r/examples/group/nested" "$r/tests/basic"
  printf 'resource "aws_s3_bucket" "this" {}\n' > "$r/main.tf"
  for f in examples/complete examples/group/nested tests/basic; do printf 'module "s3" {\n  source = "../.."\n  name = "b"\n}\n' > "$r/$f/main.tf"; done
  printf 'module "s3" {\n  source = ".."\n}\n' > "$r/examples/main.tf"
done
mkdir -p "$CMOD/.git"
# verify_rec <dir> <init> <validate> [record] [reason] [head sha]: a verify-pass.sh output with that one
# example. Some cases forge a head side the pass never writes, so each check of eval has its own case.
verify_rec() {
  jq -n --arg d "$1" --argjson i "$2" --argjson v "$3" --arg r "${4:-code-result}" --arg why "${5:-verified}" --arg h "${6:-$HEAD}" --arg b "$BASE" \
    '{head_sha: $h, base_sha: $b, terraform_version: "1.9.8", selection: {tool: "mtf-facts", fallback: null, inert: false},
      dirs: [{dir: $d, reason: $why, affected: "touched", head: {init: $i, validate: $v, record: $r, line: null}, base: null, outside: false}]}' > "$TMP/verify.json"
}
# t_caller [prefix] [behaviour jq update] [eval args...]: classify and eval as review-run.sh runs them,
# with the verify record in $TMP/verify.json unless CALLER_NOVERIFY is set; sets O.
t_caller() {
  local p="${1:-}" u="${2:-.}"; shift 2 2> /dev/null || shift $#
  setup; : > "$TMP/eval.caller"; jq -c "$u" "${CALLER_FIX:-$TMP/behaviour-caller.json}" > "$TMP/behaviour.out"
  jq --arg p "${p:+$p/}" '[.entries[] | {filename: ($p + .path), status: "modified"}]' "$TMP/behaviour.out" > "$TMP/files-caller.json"
  local root="$CMOD"; [ -z "$p" ] || root="$CMOD/$p"
  DIFF="$TMP/files-caller.json" PFX="$p" MOD="$root" classify
  if [ "$#" -gt 0 ]; then evalp "$@"
  elif [ -n "${CALLER_NOVERIFY:-}" ]; then evalp --prefix "$p"
  else evalp --prefix "$p" --verify "$TMP/verify.json"; fi
}
state1() { jq -r '.triggers[0].state' "$O/run-behaviour.json" 2> /dev/null; }
seen_mark() { jq -e '.triggers[0].caller_code == true' "$TMP/behaviour-seen.json" > /dev/null 2>&1; }
t_caller_root() { # the repository root, a passed validate of examples/complete: the mark crosses and the trigger is inert
  verify_rec examples/complete 0 0; t_caller
  seen_mark || { echo seen; return 1; }
  [ "$(q '.status == "ran" and .triggers == [{id: "T-001", file: "examples/complete/main.tf", line: 3, category: "literal-argument-change", state: "inert"}]')" = 0 ] || { echo run; return 1; }
  grep -qxF 'trigger T-001 `examples/complete/main.tf` line 3 literal-argument-change: inert' "$O/record.txt"
}
stripped() { # -> 0 when claims-eval got no mark and the trigger is unverifiable, while behaviour.json keeps it
  ! seen_mark && [ "$(state1)" = unverifiable ] && jq -e '.triggers[0].caller_code == true' "$O/behaviour.json" > /dev/null 2>&1
}
t_caller_prefix() { verify_rec examples/complete 0 0; t_caller modules/s3; stripped; }
t_caller_noverify() { CALLER_NOVERIFY=1 t_caller; stripped; }
t_caller_failed() { verify_rec examples/complete 0 1; t_caller; stripped; }
t_caller_initfail() { verify_rec examples/complete 1 null init-failed; t_caller; stripped; }
t_caller_env() { verify_rec examples/complete 0 0 not-run-environment; t_caller; stripped; }
t_caller_bump() { verify_rec examples/complete 0 0 code-result skipped-version-bump; t_caller; stripped; }
t_caller_otherdir() { verify_rec examples/other 0 0; t_caller; stripped; }
t_caller_otherhead() { verify_rec examples/complete 0 0 code-result verified 1111111111111111111111111111111111111111; t_caller; stripped; }
t_caller_tests() { verify_rec tests/basic 0 0; t_caller "" '.triggers[0].file = "tests/basic/main.tf" | .entries[0].path = "tests/basic/main.tf"' --prefix "" --verify "$TMP/verify.json"; stripped; }
t_caller_nested() { verify_rec examples/group/nested 0 0; t_caller "" '.triggers[0].file = "examples/group/nested/main.tf" | .entries[0].path = "examples/group/nested/main.tf"' --prefix "" --verify "$TMP/verify.json"; stripped; }
t_caller_flat() { verify_rec examples 0 0; t_caller "" '.triggers[0].file = "examples/main.tf" | .entries[0].path = "examples/main.tf"' --prefix "" --verify "$TMP/verify.json"; stripped; }
t_caller_noprefixflag() { verify_rec examples/complete 0 0; t_caller modules/s3 . --verify "$TMP/verify.json"; stripped; }
t_caller_norecord() { # classify's prefix record gone: no mark
  verify_rec examples/complete 0 0; setup; : > "$TMP/eval.caller"; cp "$TMP/behaviour-caller.json" "$TMP/behaviour.out"
  jq -n '[{filename: "examples/complete/main.tf", status: "modified"}]' > "$TMP/files-caller.json"
  DIFF="$TMP/files-caller.json" MOD="$CMOD" classify; rm -f "$O/classify-root.json"
  evalp --prefix "" --verify "$TMP/verify.json"; stripped
}
t_caller_record() { # the root classify read: its canonical directory, its prefix, and the repository root claim
  t_caller modules/s3
  jq -e --arg d "$(cd "$CMOD/modules/s3" && pwd -P)" '. == {dir: $d, prefix: "modules/s3", repository_root: false}' "$O/classify-root.json" > /dev/null 2>&1 || return 1
  t_caller
  jq -e --arg d "$(cd "$CMOD" && pwd -P)" '. == {dir: $d, prefix: "", repository_root: true}' "$O/classify-root.json" > /dev/null 2>&1
}
t_caller_added() { verify_rec examples/complete 0 0; CALLER_FIX="$TMP/behaviour-caller-add.json" t_caller; [ "$(state1)" = inert ] && seen_mark; }
t_caller_removed() { verify_rec examples/complete 0 0; CALLER_FIX="$TMP/behaviour-caller-rem.json" t_caller; [ "$(state1)" = inert ] && seen_mark; }
t_caller_evalprefix() { verify_rec examples/complete 0 0; t_caller "" . --prefix modules/s3 --verify "$TMP/verify.json"; stripped; }
t_caller_nogit() { # an empty prefix at a directory that is no repository top claims no root
  local G="$TMP/caller-nogit"; rm -rf "$G"; cp -R "$CMOD" "$G"; rm -rf "$G/.git" "$G/modules"
  verify_rec examples/complete 0 0; setup; : > "$TMP/eval.caller"; cp "$TMP/behaviour-caller.json" "$TMP/behaviour.out"
  jq -n '[{filename: "examples/complete/main.tf", status: "modified"}]' > "$TMP/files-caller.json"
  DIFF="$TMP/files-caller.json" MOD="$G" classify; evalp --prefix "" --verify "$TMP/verify.json"; stripped
}
t_caller_base() { # the --base form takes no prefix, so it claims no root
  verify_rec examples/complete 0 0; setup; : > "$TMP/eval.caller"; cp "$TMP/behaviour-caller.json" "$TMP/behaviour.out"
  bash "$BP" classify --facts "$FACTS" --dir "$CMOD" --base "$CMOD" --out "$O" > "$O/classify.txt" 2>&1
  jq -e '.repository_root == false' "$O/classify-root.json" > /dev/null 2>&1 || return 1
  evalp --verify "$TMP/verify.json"; stripped
}
# The verify record is read with the rules of verify-pass.sh check, or is no evidence: one JSON
# document of exactly its shape, each directory once, and the trigger's entry verified with init and
# validate 0 on a code-result.
vedit() { jq "$1" "$TMP/verify.json" > "$TMP/verify-e.json" && mv "$TMP/verify-e.json" "$TMP/verify.json"; }
t_caller_dupentry() { verify_rec examples/complete 0 0; vedit '.dirs += [.dirs[0] | .head.validate = 1 | .base = null]'; t_caller; stripped; }
t_caller_init1() { verify_rec examples/complete 1 0; t_caller; stripped; }
t_caller_vshape() { verify_rec examples/complete 0 0; vedit '.extra = 1'; t_caller; stripped; }
t_caller_ventry() { verify_rec examples/complete 0 0; vedit '.dirs[0].head = "passed"'; t_caller; [ "$(q '.status == "ran"')" = 0 ] && stripped; }
t_caller_notjson() { printf 'not json\n' > "$TMP/verify.json"; t_caller; [ "$(q '.status == "ran"')" = 0 ] && stripped; }
t_caller_twodocs() { verify_rec examples/complete 0 0; cat "$TMP/verify.json" "$TMP/verify.json" > "$TMP/verify-2.json"; mv "$TMP/verify-2.json" "$TMP/verify.json"; t_caller; [ "$(q '.status == "ran"')" = 0 ] && stripped; }
t_caller_vlink() { verify_rec examples/complete 0 0; ln -sf "$TMP/verify.json" "$TMP/verify-link.json"; t_caller "" . --prefix "" --verify "$TMP/verify-link.json"; [ $? = 2 ] && [ ! -e "$O/record.txt" ]; }
t_caller_vrel() { verify_rec examples/complete 0 0; t_caller "" . --prefix "" --verify verify.json; [ $? = 2 ] && [ ! -e "$O/record.txt" ]; }
t_caller_slash() { verify_rec examples/complete 0 0; t_caller "" . --prefix / --verify "$TMP/verify.json"; local s=$?; [ "$s" = 2 ] && [ ! -e "$O/record.txt" ]; }
t_caller_root; check "caller code: at the repository root with a passed validate of its example the mark crosses and the trigger is inert" $?
t_caller_prefix; check "caller code: under a module root prefix claims-eval gets no mark and the trigger is unverifiable" $?
t_caller_noverify; check "caller code: with no verify record the mark is dropped" $?
t_caller_failed; check "caller code: a failed validate of its example drops the mark" $?
t_caller_initfail; check "caller code: an init that failed drops the mark" $?
t_caller_env; check "caller code: a validate not run for the environment drops the mark" $?
t_caller_bump; check "caller code: an example skipped as a version bump drops the mark" $?
t_caller_otherdir; check "caller code: a validate of another example drops the mark" $?
t_caller_otherhead; check "caller code: a verify record of another head drops the mark" $?
t_caller_tests; check "caller code: a tests/ file drops the mark, even beside a record that names its directory" $?
t_caller_nested; check "caller code: a nested example drops the mark, even beside a record that names its directory" $?
t_caller_flat; check "caller code: a file directly in examples/ drops the mark" $?
t_caller_noprefixflag; check "caller code: a classify prefix and an eval with no --prefix drop the mark" $?
t_caller_norecord; check "caller code: no prefix record from classify drops the mark" $?
t_caller_record; check "caller code: classify records the prefix it was given, empty at the root" $?
t_caller_slash; check "caller code: --prefix / is a usage error" $?
t_caller_added; check "caller code: a literal argument the change adds, recorded from the classifier, classifies and reads inert" $?
t_caller_removed; check "caller code: a literal argument the change removes, recorded from the classifier, classifies and reads inert" $?
t_caller_evalprefix; check "caller code: a root classify and an eval with a prefix drop the mark" $?
t_caller_nogit; check "caller code: an empty prefix at a directory with no .git drops the mark" $?
t_caller_base; check "caller code: the --base form records no repository root and drops the mark" $?
t_caller_dupentry; check "caller code: a verify record with the directory twice is no evidence" $?
t_caller_init1; check "caller code: a code-result with init 1 drops the mark" $?
t_caller_vshape; check "caller code: a verify record with a key outside its shape is no evidence" $?
t_caller_ventry; check "caller code: a verify record with a malformed entry is no evidence, and the step runs" $?
t_caller_notjson; check "caller code: a verify record that is not JSON is no evidence, and the step runs" $?
t_caller_twodocs; check "caller code: a verify record of two JSON documents is no evidence, and the step runs" $?
t_caller_vlink; check "caller code: a --verify that is a link is a usage error" $?
t_caller_vrel; check "caller code: a relative --verify is a usage error" $?
CALLER_BAD=('.triggers[0].caller_code = "true"' '.triggers[0].caller_code = 1' '.triggers[0].caller_code = null'
  '.triggers[0].category = "default-change"' '.triggers[0].also_categories = ["literal-argument-change", "default-change"]'
  '.triggers[0].file = "main.tf" | .entries[0].path = "main.tf"' '.triggers[0].file = "modules/s3/examples/complete/main.tf" | .entries[0].path = "modules/s3/examples/complete/main.tf"' '.triggers[0].file = "Examples/complete/main.tf" | .entries[0].path = "Examples/complete/main.tf"'
  '.triggers[0].file = "tests/basic.tftest.hcl" | .entries[0].path = "tests/basic.tftest.hcl"' '.triggers[0].file = "examples/complete/main.tofu" | .entries[0].path = "examples/complete/main.tofu"' '.triggers[0].file = "examples.tf" | .entries[0].path = "examples.tf"'
  '.triggers[0].caller_code = false | .triggers[0].file = "main.tf" | .entries[0].path = "main.tf"'
  '.triggers[0].change_kind = "renamed"' '.triggers[0].follows = []' '.triggers[0].follows = ["T-002"]'
  '.entries[0].change_kind = "added"' '.entries[0] += {change_kind: "renamed", previous_path: "examples/old/main.tf"}'
  '.triggers[0].file = "examples//main.tf" | .entries[0].path = "examples//main.tf"' '.triggers[0].file = "examples/./main.tf" | .entries[0].path = "examples/./main.tf"' '.triggers[0].file = "examples/complete/.tf" | .entries[0].path = "examples/complete/.tf"'
  '.triggers[0].file = "examples/absent/main.tf" | .entries[0].path = "examples/absent/main.tf"')
caller_refused() { # behaviour jq update -> 0 when classify refuses it
  verify_rec examples/complete 0 0; t_caller "" "$1"
  grep -qxF 'behaviour: not run: output refused' "$O/classify.txt" && [ "$(q '.status == "not-run" and .reason == "output refused"')" = 0 ]
}
for u in "${CALLER_BAD[@]}"; do caller_refused "$u"; check "caller code refused: $u" $?; done
t_caller_refused() { local u; for u in "${CALLER_BAD[@]}"; do caller_refused "$u" || return 1; done; }
# A link at the head: the file itself, or an ancestor directory of it.
t_caller_link() {
  local L="$TMP/caller-link" s=0
  for kind in file dir; do
    rm -rf "$L"; cp -R "$CMOD" "$L"; rm -rf "$L/modules"
    if [ "$kind" = file ]; then mv "$L/examples/complete/main.tf" "$L/real.tf"; ln -s ../../real.tf "$L/examples/complete/main.tf"
    else mv "$L/examples/complete" "$L/real"; ln -s ../real "$L/examples/complete"; fi
    verify_rec examples/complete 0 0; setup; : > "$TMP/eval.caller"; cp "$TMP/behaviour-caller.json" "$TMP/behaviour.out"
    jq -n '[{filename: "examples/complete/main.tf", status: "modified"}]' > "$TMP/files-caller.json"
    DIFF="$TMP/files-caller.json" MOD="$L" classify
    grep -qxF 'behaviour: not run: output refused' "$O/classify.txt" || { echo "$kind"; s=1; }
  done
  return "$s"
}
t_caller_link; check "caller code refused: the file at the head is a link, or reached through one" $?
verify_rec tests/basic 0 0
t_caller "" '.triggers[0].also_categories = ["literal-argument-change"] | .triggers[0].file = "tests/basic/main.tf" | .entries[0].path = "tests/basic/main.tf"'
check "caller code: a merged literal change in a tests/ file classifies" "$([ -f "$O/behaviour.json" ]; echo $?)"
# The render: a run whose only trigger is caller code at the repository root, its example validated,
# approves with no example planned; under a prefix, or with that validate failed, it is inconclusive.
t_caller_render() { # [module root prefix] [validate status] -> the render line in RL
  verify_rec "${1:+$1/}examples/complete" 0 "${2:-0}"; t_caller "${1:-}"
  jq -n --slurpfile b "$O/run-behaviour.json" '{format: 1, triage: false, plan_ran: false, verify_gaps: [], behaviour: $b[0],
    coverage: {class: "none", inert: false, unplanned: [{dir: "examples/complete", reason: "no AWS profile named"}]},
    counts: {"instruction-like-text-from-others": 0, "conversation-claims-unread": 0, "review.quoted-claim-unverifiable": 0}}' > "$TMP/run-c.json"
  printf '[]\n' > "$TMP/findings-c.json"; local r="$TMP/render-c$c"; mkdir -p "$r"
  RL="$(bash "$RCU" --head "$HEAD" --findings "$TMP/findings-c.json" --host "$TMP/host.json" --checks "$TMP/checks" \
    --run "$TMP/run-c.json" --assessment "$TMP/assess.txt" --run-dir "$TMP/rundir" --out "$r" 2>&1)"
}
t_caller_render; check "caller code render: at the repository root with its example validated it approves with no example planned" "$(case "$RL" in "rendered approve (ladder rule 8),"*) echo 0 ;; *) echo "$RL" >&2; echo 1 ;; esac)"
t_caller_render modules/s3; check "caller code render: under a prefix it is inconclusive" "$(case "$RL" in "rendered inconclusive (ladder rule 4),"*) echo 0 ;; *) echo "$RL" >&2; echo 1 ;; esac)"
t_caller_render "" 1; check "caller code render: with its validate failed it is inconclusive" "$(case "$RL" in "rendered inconclusive (ladder rule 4),"*) echo 0 ;; *) echo "$RL" >&2; echo 1 ;; esac)"

# The negative self-check: each weakened copy of the script lets a case above through.
mn=0
wmutate() { # name, perl substitution, case function [, file mutated, behaviour-pass.sh by default]
  mn=$((mn + 1)); local d="$TMP/wmut-$mn"; mkdir -p "$d"
  cp "$REF/behaviour-pass.sh" "$REF/wrapper-derive.pl" "$d/"
  local f="${4:-behaviour-pass.sh}"; perl -0pi -e "$2" "$d/$f"
  if cmp -s "$d/$f" "$REF/$f"; then check "self-check: $1 (the mutation changed nothing)" 1; return; fi
  local keep="$BP" before="$fails"; BP="$d/behaviour-pass.sh"
  "$3" > /dev/null 2>&1; local s=$?
  BP="$keep"; fails="$before"
  check "self-check: $1 is caught" "$([ "$s" != 0 ]; echo $?)"
}
t_untriggered() { # an entry with no trigger and not inert is refused
  setup; jq '.entries += [{path: "x.tf", change_kind: "modified", inert: false, trigger_ids: []}]' "$TMP/behaviour-556.json" > "$TMP/behaviour.out"
  classify; evalp --claims "$TMP/claims-556.json"
  jq -e '. == {status: "not-run", reason: "output refused", triggers: [], claims: [], capped: 0}' "$O/run-behaviour.json" > /dev/null 2>&1
}
wmutate "an untriggered entry that is not inert accepted" 's/\(\(\.trigger_ids \| length\) > 0 or \.inert == true or \$cap > 0\)/true/' t_untriggered
wmutate "the cap exception dropped" 's/ or \.inert == true or \$cap > 0\)/ or .inert == true)/' t_big45
wmutate "the derive comparison dropped" 's/cmp -s "\$out\/wrap\/e" "\$out\/wrap\/w" && r=derived \|\| r=differs/r=derived/' t_wr_differs
wmutate "the copy comparison dropped" 's/cmp -s "\$out\/wrap\/m" "\$out\/wrap\/w" && r=copied \|\| r=differs/r=copied/' t_wr_copied
wmutate "the derive version boundary moved" 's/000010010600000/000010010500000/' t_wr_copied
wmutate "the copy version boundary dropped" 's/000010008900000/000000000000000/' t_wr_old
wmutate "the release tag check dropped" 's/or exit print "unknown pin not a release tag\\n";/or exit print "derive\\n";/' t_wr_pins
wmutate "the wrapper hook check dropped" 's/exit print "unknown hook not listed\\n" unless \$e\[0\]\{hook\};//' t_wr_pins
wmutate "the second mention check dropped" 's/ && \$m == 1 && / && /' t_wr_pins
wmutate "the link refusal dropped" 's/  \[ "\$\{BASH_REMATCH\[1\]\}" != 120000 \] \|\| \{ echo link; return 1; \}\n  \[ "\$\{BASH_REMATCH\[1\]\}" = 100644 \]/  [ "\${BASH_REMATCH[1]}" = 100644 ] || [ "\${BASH_REMATCH[1]}" = 120000 ]/' t_wr_links
wmutate "the ancestor walk dropped" 's/  for c in \$\{p%\/\*\}; do/  for c in; do/' t_wr_links
wmutate "the size cap dropped" 's/\[ "\$\{BASH_REMATCH\[2\]\}" -le "\$WRAP_CAP" \] \|\|/true ||/' t_wr_size
wmutate "the module pairing to the root for a submodule" 's/else m="modules\/\$\{p#wrappers\/\}"; fi/else m=versions.tf; fi/' t_wr_sub
wmutate "the prefix not stripped" 's/\| \.\[\(\$p \| length\):\]/| ./' t_wr_prefix
wmutate "a refuted trigger made inert" 's/if \.state == "unverifiable" and \(\$w/if (.state | IN("unverifiable", "refuted")) and (\$w/' t_wr_eval
wmutate "a differing wrapper made inert" 's/IN\("derived", "copied"\)\)\n/IN("derived", "copied", "differs"))\n/' t_wr_eval
wmutate "the repo or rev key check dropped" 's/      exit print "unknown pin unreadable\\n" if \/\^\[ \\t\]\*\(-[^\n]*\n//' t_wr_yaml
wmutate "the anchor check dropped" 's/ \|\| \$s =~ \/\^\[ \\t\]\*\(-\[ \\t\]\+\)\?\(\\\?\|<<\)\/m;/;/; s/\(\^\|\[\\s\\\[\{,\]\)\[&\*!\]\\S/NEVER/' t_wr_yaml
wmutate "the mention count in one letter case" 's/m\{pre-commit-terraform\}gi/m{pre-commit-terraform}g/' t_wr_yaml
wmutate "the backslash check dropped" 's/    exit print "unknown pin unreadable\\n" if \$s =~ \/\\\\\/;\n//' t_wr_steer
wmutate "the second repos key check dropped" 's/\/gmi\) != 1/\/gmi) < 1/' t_wr_steer
wmutate "the nested repos key check dropped" 's/\/gmi\) != 1/\/gmi) > 1/' t_wr_steer
wmutate "a rev without its v read" 's/    exit print "unknown pin unreadable\\n" if \$e\[0\]\{rev\}\[0\] =~ [^\n]*\n//' t_wr_steer
wmutate "a # with no blank before it read as a comment" 's/\(\[\^"\\x27\\s#\]\+\)\\1\(\[ \\t\]\+#/([^"\\x27\\s#]+)\\1([ \\t]*#/' t_wr_steer
wmutate "the rev indent check dropped" 's/exit print "unknown pin unreadable\\n" if defined \$rev && /exit print "unknown pin unreadable\\n" if 0 \&\& /' t_wr_steer
wmutate "the open quote check dropped" 's/if \$q ne "" \|\| /if /' t_wr_steer
wmutate "the open flow sequence check dropped" 's/ \|\| \$d != 0//' t_wr_steer
wmutate "the flow mapping check dropped" 's/if \$c eq "\{" \|\| /if /' t_wr_steer
wmutate "the block scalar check dropped" 's/\[\|>\]\[-\+0-9\]/[~][-+0-9]/' t_wr_steer
wmutate "the repo URL form check dropped" 's/if defined \$repo && \$repo !~/if 0 \&\& \$repo !~/' t_wr_steer
wmutate "the hook mention count dropped" 's/for_each\/gi\) > 1/for_each\/gi) > 9/' t_wr_steer
wmutate "the provider option check dropped" 's/exit print "unknown hook options\\n" if /exit print "unknown hook options\\n" if 0 \&\& /' t_wr_family
wmutate "the provider_meta label check dropped" 's/if grep -E .\^\[\[:space:\]\]\*provider_meta. "\$out\/wrap\/m" \| grep -qvE [^\n]*; then/if false; then/' t_wr_provider
wmutate "the continuation line check dropped" 's/      exit print "unknown pin unreadable\\n" unless \/\^\[ \\t\]\*\(#\|\$\)\/[^\n]*\n//' t_wr_steer
wmutate "the space after repo: not required" 's/repo:\[ \\t\]\+\(/repo:[ \\t]*(/' t_wr_steer
wmutate "the space after id: not required" 's/id:\[ \\t\]\+\(/id:[ \\t]*(/' t_wr_family
wmutate "the partial clone check dropped" 's/    elif safe_git_partial; then all="unknown partial clone"\n//' t_wr_partial
wmutate "the sub component cap dropped" 's/\{0,63\}/*/g' t_wr_long
wmutate "the wrappers file grammar not checked" 's/if length <= 256 and all\(\.\[\]; test\(\$re\)\) then/if true then/' t_wr_eval_malformed
wmutate "unexercised: the plan coverage alone not required" 's/ and \$t\.levels == \["L4"\] and / and /' t_unex_cases
wmutate "unexercised: a removal or edit marked" 's/ and \$t\.change_kind == "added"\n      and \(\[/\n      and ([/' t_unex_cases
wmutate "unexercised: any category marked" 's/and \(\[\$t\.category, \(\$t\.also_categories \/\/ \[\]\)\[\]\] - unex_cats == \[\]\)/and true/' t_unex_cases
wmutate "unexercised: merged categories not read" 's/\[\$t\.category, \(\$t\.also_categories \/\/ \[\]\)\[\]\] - unex_cats/[\$t.category] - unex_cats/' t_unex_cases
wmutate "unexercised: meta-arguments marked" 's/\| IN\(meta_args\[\]\) \| not\)/| IN([]) | not)/' t_unex_cases
wmutate "unexercised: any address marked" 's/\(\$t\.address \| type == "string" and managed\)/(\$t.address | type == "string")/' t_unex_cases
wmutate "unexercised: a failed plan accepted" 's/\(\.head \| IN\("planned", "planned-no-changes"\)\)\n/true\n/' t_unex_cases
wmutate "unexercised: partial coverage accepted" 's/\$l\.coverage\.class == "complete" and //' t_unex_cases
wmutate "unexercised: an empty or capped address list accepted" 's/and length > 0 and length < 1000\)/)/' t_unex_cases
wmutate "unexercised: unknown module calls accepted" 's/and \(\.module_calls \| type == "object" and length > 0\)\)/)/' t_unex_cases
wmutate "unexercised: a nested module address not matched" 's/ or endswith\("\." \+ \$a\)//' t_unex_cases
wmutate "unexercised: the state not checked" 's/and \$et\.state == "unverifiable" and \(\$et/and true and (\$et/' t_unex_cases
wmutate "unexercised: sweep evidence accepted" 's/and \$et\.state == "unverifiable" and \(\$et \| has\("complete"\) or has\("outstanding"\) or has\("evidence_digest"\) \| not\)\n/and \$et.state == "unverifiable"\n/' t_unex_cases
wmutate "unexercised: the value not read" 's/\n      and null_pass\(\$t\)//' t_unex_true
wmutate "unexercised: a literal value marked" 's/\n      and null_pass\(\$t\)//; s/def unex_cats: \["dynamic-block-change"/def unex_cats: ["literal-argument-change", "dynamic-block-change"/' t_unex_force
wmutate "unexercised: an existing variable accepted" 's/\| \(\{dir: \(\$t\.file \| tdir\), name: \$n\} \| IN\(\$nv\[\]\)\)/| true/' t_unex_old
wmutate "unexercised: a variable of another directory accepted" 's/\(\{dir: \(\$t\.file \| tdir\), name: \$n\} \| IN\(\$nv\[\]\)\)/(\$n | IN(\$nv[].name))/' t_unex_dirs
wmutate "unexercised: the variable's trigger of another directory accepted" 's/and \(\{dir: \(\$t\.file \| tdir\), name: ltrimstr\("var\."\)\} \| IN\(\$nv\[\]\)\)/and (ltrimstr("var.") | IN(\$nv[].name))/' t_unex_dirs_follow
wmutate "unexercised: the directory not written" 's/list="\$list\$\(dirname "\$file"\)"/list="\$list."/' t_unex_dirs
wmutate "unexercised: a file outside the module root read" 's/    case "\$real" in "\$root"\/\*\) ;; \*\) continue ;; esac\n//' t_unex_outside
wmutate "unexercised: the 1 MiB cap dropped" 's/ && \[ "\$\(wc -c < "\$f"\)" -le "\$CAP" \]//' t_unex_big
wmutate "unexercised: the 200-line bound dropped" 's/rmax=200/rmax=100000/' t_unex_long
wmutate "unexercised: a function around the variable accepted" 's/else \$t\.head_expr == "var\.\\\(\$n\)" end/else true end/' t_unex_wrap
wmutate "unexercised: other references accepted" 's/def null_pass\(\$t\): \(\$t\.contextual_refs == \[\]\) and/def null_pass(\$t): true and/' t_unex_ctx
wmutate "unexercised: a second variable accepted" 's/type == "array" and length == 1 and \(\.\[0\]\.name/type == "array" and length >= 1 and (.[0].name/' t_unex_two
wmutate "unexercised: an unguarded dynamic block accepted" 's/then \(\$t\.head_expr \| test\([^\n]*\n/then true\n/' t_unex_guard
wmutate "unexercised: the variable's trigger marked while it follows an unmarked one" 's/all\(\.\[\]; IN\(\$m\[\]\)\)/any(.[]; IN(\$m[]))/' t_unex_follow_open
wmutate "unexercised: the variable's trigger never marked" 's/\$t\.levels == \[\] and \$et\.state/false and \$et.state/' t_unex_follow
wmutate "unexercised: a link read" 's/\[ -f "\$f" \] && \[ ! -L "\$f" \] && /[ -f "\$f" ] \&\& /' t_unex_nv
wmutate "unexercised: a variable that defaults to true read as null" 's/\$d = 1 if \$s =~ \/\^\\s\*default\\s\*=\\s\*null\\s\*\$\//\$d = 1/' t_unex_true
wmutate "unexercised: a block comment read" 's/\|\/\\\*\|\\\*\/\|/|/' t_unex_cmt
wmutate "unexercised: a # comment read" 's/<<\|#\|/<<|/' t_unex_cmt_hash
wmutate "unexercised: a // comment read" 's/\|\/\/\|/|/' t_unex_cmt_slash
wmutate "unexercised: a second default attribute read" 's/&& \$n == 1 && \$d == 1\)/\&\& \$d == 1)/' t_unex_twodef
wmutate "unexercised: a variable with no default read as null" 's/ && \$n == 1 && \$d == 1\) \? 0 : 1\)/) ? 0 : 1)/' t_unex_nv
wmutate "unexercised: a nullable attribute ignored" 's/          exit 1 if \$s =~ \/\^\\s\*nullable\\b\/;\n//' t_unex_nv
wmutate "unexercised: a heredoc read" 's/m\{<<\|/m{/' t_unex_nv
wmutate "unexercised: the block not anchored at the trigger line" 's/exit 1 unless defined \$l\[\$i\] && \$l\[\$i\] =~ [^;]*;/1;/' t_unex_name
wmutate "unexercised: strings not removed" 's/        \$s =~ s\/"\(\(\?:[^\n]*\/ge;\n//' t_unex_desc
wmutate "unexercised: an interpolation in a string accepted" 's/\$bad = 1 if \$1 =~ m\{\[\\\$%\]\\\{\}; //' t_unex_interp
wmutate "unexercised: a template directive in a string accepted" 's/\[\\\$%\]/[\\\$]/' t_unex_tmpl
wmutate "unexercised: a string left open accepted" 's/ \|\| \$s =~ \/"\///' t_unex_open
wmutate "unexercised: brackets and parentheses not counted" 's/\[\\\{\\\[\\\(\]/[\\{]/; s/\[\\\}\\\]\\\)\]/[\\}]/' t_unex_list
wmutate "unexercised: a default deeper in the type counted" 's/if \(\$depth == 1\) \{/if (1) {/' t_unex_typedef
wmutate "unexercised: the block ended at the first column-0 brace, defaults counted at any depth" 's/if \(\$depth == 1\) \{/if (1) {/; s/        for my \$k \(0 \.\. length\(\$s\) - 1\) \{/        exit((\$n == 1 \&\& \$d == 1) ? 0 : 1) if \$s =~ \/^\\}\/;\n        for my \$k (0 .. length(\$s) - 1) {/' t_unex_b8
wmutate "unexercised: a required attribute marked" 's/or \(\$ta \| IN\(\$rq\[\]\)\)\) \| not\);/or false) | not);/' t_unex_required
wmutate "unexercised: a block with min_items not read as required" 's/select\(\(\.value\.min_items \/\/ 0\) > 0\)/select(false)/' t_unex_required
wmutate "unexercised: a nested required attribute not read" 's/\(\.key as \$b \| \.value\.block \| req\("\\\(\$p\)\.\\\(\$b\)"\)\)/empty/' t_unex_nested_req
wmutate "unexercised: no schema read as no requirement" 's/rq=\x27\["\*"\]\x27/rq=\x27[]\x27/' t_unex_noschema
wmutate "unexercised: an unreadable schema read as no requirement" 's/printf \x27\["\*"\]\\n\x27 > "\$out\/required\.json"/printf \x27[]\\n\x27 > "\$out\/required.json"/' t_unex_badschema
wmutate "unexercised: a malformed required list read as none" 's/then \. else \["\*"\] end/then . else [] end/' t_unex_badreq
wmutate "unexercised: a null attribute not guarded" 's/def not_required\(\$t\): \(\$t\.attribute \| type == "string"\)\n      and /def not_required(\$t): /' t_unex_nullattr
wmutate "unexercised: an unloaded directory marked" 's/ and plans_known and loaded\(\$t\)/ and plans_known/' t_unex_unloaded
wmutate "unexercised: an unloaded variable trigger marked" 's/and all\(\.\[\]; IN\(\$m\[\]\)\)\) and loaded\(\$t\);/and all(.[]; IN(\$m[])));/; s/ and plans_known and loaded\(\$t\)/ and plans_known/' t_unex_unloaded
wmutate "unexercised: a directly called directory not seen as loaded" 's/\.dir == \$d or \(\(\.module_calls \/\/ \{\}\) \| to_entries \| any\(\.value == \$d\)\)/.dir == \$d/' t_unex_loaded
wmutate "unexercised: strings matched without escapes" 's/s\/"\(\(\?:\[\^"\\\\\]\|\\\\\.\)\*\)"\//s\/"([^"]*)"\//' t_unex_escq
wmutate "unexercised: a nested dynamic segment kept" 's/split\("\."\) \| map\(select\(\. != "dynamic"\)\) \| join\("\."\)/sub("^dynamic\\\\."; "")/' t_unex_nested_dyn
wmutate "unexercised: a type the schema lacks requires nothing" 's/,\n         \(\$ty\[\] \| select\(IN\(\$have\[\]\) \| not\) \| "\\\(\.\)\.\*"\)//' t_unex_lacktype
wmutate "caller code: the mark kept under a prefix" 's/ and \$root and / and /' t_caller_prefix
wmutate "caller code: the mark dropped at the repository root" 's/if \.caller_code == true and \$root and/if false and \$root and/' t_caller_root
wmutate "caller code: the verify record not required" 's/ and validated\(\.file \| sub\([^)]*\)\)/ and true/' t_caller_noverify
wmutate "caller code: a failed validate accepted" 's/ and \.head\.validate == 0\)/)/' t_caller_failed
wmutate "caller code: any head record accepted" 's/ and \.head\.record == "code-result"//' t_caller_env
wmutate "caller code: a skipped example accepted" 's/ and \.reason == "verified"//' t_caller_bump
wmutate "caller code: another example accepted" 's/\.dir == \$d and /true and /' t_caller_otherdir
wmutate "caller code: a verify record of another head accepted" 's/ and \.head_sha == \$h and \(\.dirs \| type/ and (.dirs | type/' t_caller_otherhead
wmutate "caller code: a directory outside examples/<name> accepted" 's/\$d \| test\("\^examples\/\[\^\/\]\+\$"\) and //' t_caller_tests
wmutate "caller code: the repository root claim not read" 's/\.repository_root == true and //' t_caller_base
wmutate "caller code: a missing root record read as the root" 's/local root=false /local root=true /' t_caller_norecord
wmutate "caller code: the eval prefix not checked" 's/ && \[ -z "\$prefix" \]; then\n    jq -e .\.repository_root/; then\n    jq -e \x27.repository_root/' t_caller_evalprefix
wmutate "caller code: the --base form claimed as the root" 's/\[ -n "\$diff" \] && \[ -z "\$\{prefix%\/\}" \]/[ -z "\${prefix%\/}" ]/' t_caller_base
wmutate "caller code: no .git test for the root" 's/ && \[ -e "\$dir\/\.git" \]//' t_caller_nogit
wmutate "caller code: a directory twice accepted" 's/ and \(map\(\.dir\) \| length == \(unique \| length\)\)//' t_caller_dupentry
wmutate "caller code: init not checked" 's/ and \.head\.init == 0 and / and /' t_caller_init1
wmutate "caller code: the record shape not checked" 's/keys == \["base_sha","dirs","head_sha","selection","terraform_version"\]/true/' t_caller_vshape
wmutate "caller code: the entry shape not checked" 's/ and \(\.head == null or \(\.head \| side\)\)//' t_caller_ventry
wmutate "caller code: two documents read" 's/if length == 1 and \(\.\[0\]/if length >= 1 and (.[0]/' t_caller_twodocs
wmutate "caller code: a --verify link accepted" 's/\[ -f "\$verify" \] && \[ ! -L "\$verify" \]/[ -f "\$verify" ]/' t_caller_vlink
wmutate "caller code: --prefix / stripped to the root" 's/  case "\$prefix" in \/\* \| /  case "\${prefix%\/}" in \/* | /' t_caller_slash
wmutate "caller code: the field not validated" 's/and \(\(has\("caller_code"\) \| not\) or /and (true or /' t_caller_refused
wmutate "caller code: a boolean not required" 's/\(\.caller_code \| type == "boolean"\) and \.category/.category/' t_caller_refused
wmutate "caller code: any category accepted" 's/and \.category == "literal-argument-change"\n/\n/' t_caller_refused
wmutate "caller code: merged categories not read" 's/and all\(\(\.also_categories \/\/ \[\]\)\[\]; \. == "literal-argument-change"\)//' t_caller_refused
wmutate "caller code: any path accepted" 's/and \(\.file \| test\("\^\(examples\|tests\)\/[^"]*"\)\)/and true/' t_caller_refused
wmutate "caller code: the path not anchored" 's/test\("\^\(examples\|tests\)\//test("(examples|tests)\//' t_caller_refused
wmutate "caller code: an empty or dot segment accepted" 's/ and \(\.file \| split\("\/"\) \| all\(\. != "" and \. != "\."\)\)//' t_caller_refused
wmutate "caller code: any trigger change kind accepted" 's/ and \(\.change_kind \| IN\("added", "removed", "modified"\)\)//' t_caller_refused
wmutate "caller code: an added trigger refused" 's/IN\("added", "removed", "modified"\)/IN("modified")/' t_caller_added
wmutate "caller code: a removed trigger refused" 's/IN\("added", "removed", "modified"\)/IN("added", "modified")/' t_caller_removed
wmutate "caller code: a follower accepted" 's/ and \(has\("follows"\) \| not\)\n/\n/' t_caller_refused
wmutate "caller code: the entry not read" 's/\.path == \$f and \.change_kind == "modified" and \(has\("previous_path"\) \| not\)/.path == \$f/' t_caller_refused
wmutate "caller code: a missing file accepted" 's/    \[ -f "\$p" \] \|\| return 1\n//' t_caller_refused
wmutate "caller code: a link at the head accepted" 's/      \[ ! -L "\$p" \] \|\| return 1\n//' t_caller_link
wmutate "derive in the shared file returning its input" 's/  return \$o;\n\}/  return \$s;\n}/' t_wr_derived wrapper-derive.pl

echo
if [ "$fails" -eq 0 ]; then echo "behaviour pass: all checks hold"; else echo "behaviour pass: $fails failed"; exit 1; fi
