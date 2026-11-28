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
  b=""
  while [ \$# -gt 0 ]; do
    [ "\$1" = --diff ] && cp "\$2" "$TMP/diff-seen.json"
    [ "\$1" = --base ] && b=1
    [ "\$1" = --stats-file ] && echo '{"schema_version":1}' > "\$2"
    shift
  done
  [ -f "$TMP/behaviour.sleep" ] && sleep 5
  # A run with --base takes base.rc and base.out when the case set them.
  [ -n "\$b" ] && [ -f "$TMP/base.rc" ] && exit "\$(cat "$TMP/base.rc")"
  [ -n "\$b" ] && [ -f "$TMP/base.out" ] && { cat "$TMP/base.out"; exit 0; }
  [ -f "$TMP/behaviour.rc" ] && exit "\$(cat "$TMP/behaviour.rc")"; cat "$TMP/behaviour.out" ;;
version)
  [ -f "$TMP/features" ] || exit 2; cat "$TMP/features" ;;
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
  rm -f "$TMP/behaviour.rc" "$TMP/eval.rc" "$TMP/behaviour.sleep" "$TMP/eval.sleep" "$TMP/facts.log" "$TMP/ladder-seen.json" "$TMP/diff-seen.json" "$TMP/features" \
    "$TMP/base.rc" "$TMP/base.out"
  # FEATS: the feature names the stub's version --json lists; with none set it exits 2, as a binary
  # older than the command does.
  [ -z "${FEATS-}" ] || jq -n --arg f "$FEATS" '{schema_version: 1, version: "v0.0.0", features: ($f | split(" "))}' > "$TMP/features"
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
check "acceptance: the replay renders inconclusive at rule 4" "$([ "$msg" = "rendered not approved (ladder rule 4), proposed event COMMENT, tier STANDARD" ]; echo $?)"
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
  [ -z "${UREQF-}" ] || cp "$UREQF" "$O/required.json"
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
    case "$(urender ".id == \"$id\"")" in "rendered not approved (ladder rule 4),"*) ;; *) echo "$id"; return 1 ;; esac
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
t_unex_big() { { echo 'variable "new_idle" {'; echo '  default = null'; echo '}'; head -c 2200000 /dev/zero | tr '\0' ' '; echo; } > "$TMP/blk-$c"; nvblock "$TMP/blk-$c"; }
t_unex_big; check "unexercised: a variables file over 2 MiB, the facts engine's file size cap, is not read" $?
# A variables file of 1.5 MiB, under that cap, is read and its variable marked.
t_unex_mid() {
  local keep="$UMOD"; UMOD="$TMP/unex-head-mid"; rm -rf "$UMOD"; cp -R "$keep" "$UMOD"
  { cat "$keep/variables.tf"; head -c 1572864 /dev/zero | tr '\0' ' '; echo; } > "$UMOD/variables.tf"
  unex; UMOD="$keep"; [ "$(marked)" != '[]' ] && [ "$(cat "$O/nullvars.json")" != '[]' ]
}
t_unex_mid; check "unexercised: a variables file of 1.5 MiB is read and its variable marked" $?
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
  && case "$(urender '.id == "T-001"')" in "rendered not approved (ladder rule 4),"*) ;; *) false ;; esac; }
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
    && case "$(urender '.id | IN("T-002", "T-003")')" in "rendered not approved (ladder rule 4),"*) ;; *) false ;; esac; }
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
# A required list over the argument size limit: the classifier output and claims-eval output
# recorded from a pull request that adds nested dynamic blocks to aws_wafv2_rule_group and
# aws_wafv2_web_acl_rule, whose provider schema nests statements so deep that the list holds about
# 21000 paths, 3.7 MB. A schema of the same shape stands in for it; eval must still run.
cat > "$TMP/behaviour-waf.json" <<'EOF2'
{"schema_version":1,"inert":false,"entries":[{"path":"examples/complete/main.tf","change_kind":"modified","inert":false,"trigger_ids":["T-001"]},{"path":"main.tf","change_kind":"modified","inert":false,"trigger_ids":["T-002"]},{"path":"modules/rule-group/main.tf","change_kind":"modified","inert":false,"trigger_ids":["T-003"]},{"path":"modules/web-acl-rule/main.tf","change_kind":"modified","inert":false,"trigger_ids":["T-004"]}],"triggers":[{"id":"T-001","file":"examples/complete/main.tf","line":43,"category":"unclassified-change","change_kind":"modified","address":"module.wafv2","attribute":"rules","base_expr":null,"head_expr":null,"referenced_inputs":[],"contextual_refs":["module.ip_set"],"contextual_ref_details":[{"text":"module.ip_set.arn","kind":"module","type":null,"multi":null}],"pure":true,"levels":["L4"],"reason":"an expression is over 4096 bytes and is left out"},{"id":"T-002","file":"main.tf","line":null,"category":"unclassified-change","change_kind":"modified","address":null,"attribute":null,"base_expr":null,"head_expr":null,"referenced_inputs":[],"contextual_refs":[],"contextual_ref_details":[],"pure":false,"levels":["L4"],"reason":"main.tf is not a regular file with known content"},{"id":"T-003","file":"modules/rule-group/main.tf","line":142,"category":"dynamic-block-change","change_kind":"modified","address":"aws_wafv2_rule_group.this","attribute":"dynamic.rule.dynamic.statement","base_expr":"[rule.value.statement]","head_expr":"[rule.value.statement]","referenced_inputs":[],"contextual_refs":["rule.value"],"contextual_ref_details":[{"text":"rule.value.statement","kind":"resource","type":null,"multi":null}],"pure":true,"levels":["L4"],"reason":null},{"id":"T-004","file":"modules/web-acl-rule/main.tf","line":149,"category":"dynamic-block-change","change_kind":"modified","address":"aws_wafv2_web_acl_rule.this","attribute":"dynamic.statement","base_expr":"[local.rule.statement]","head_expr":"[local.rule.statement]","referenced_inputs":[],"contextual_refs":["local.rule"],"contextual_ref_details":[{"text":"local.rule.statement","kind":"local","type":null,"multi":null}],"pure":true,"levels":["L4"],"reason":null}],"capped":0}
EOF2
cat > "$TMP/eval-waf.json" <<'EOF2'
{"schema_version":1,"triggers":[{"id":"T-001","state":"unverifiable","reason":"the address and changed attribute are in no planned example"},{"id":"T-002","state":"unverifiable","reason":"the trigger has no address a plan can show"},{"id":"T-003","state":"unverifiable","reason":"the address and changed attribute are in no planned example"},{"id":"T-004","state":"unverifiable","reason":"the address and changed attribute are in no planned example"}],"capped":0,"claims":[],"discarded_claims":[]}
EOF2
jq -n 'def chain($n): reduce ("ip_set_reference_statement", "statement", "or_statement", "statement", "and_statement", "statement", "rule") as $k
    ({attributes: ([range($n)] | map({key: "required_attribute_\(.)", value: {type: "string", required: true}}) | from_entries)};
     {block_types: {($k): {nesting_mode: "list", block: .}}});
  {format_version: "1.0", provider_schemas: {"registry.terraform.io/hashicorp/aws": {resource_schemas: {
    aws_wafv2_rule_group: {version: 0, block: chain(7000)}, aws_wafv2_web_acl_rule: {version: 0, block: chain(14000)}}}}}' > "$TMP/schema-waf.json"
printf '[{"filename":"examples/complete/main.tf","status":"modified"},{"filename":"main.tf","status":"modified"},{"filename":"modules/rule-group/main.tf","status":"modified"},{"filename":"modules/web-acl-rule/main.tf","status":"modified"}]\n' > "$TMP/files-waf.json"
t_req_big() {
  setup; cp "$TMP/behaviour-waf.json" "$TMP/behaviour.out"; cp "$TMP/eval-waf.json" "$TMP/eval.out"
  SCHEMA="$TMP/schema-waf.json" DIFF="$TMP/files-waf.json" classify && evalp \
    && [ "$(wc -c < "$O/required.json")" -gt 2097152 ] \
    && jq -e '.status == "ran" and ([.triggers[].state] == ["unverifiable", "unverifiable", "unverifiable", "unverifiable"])
      and ([.triggers[] | select(has("unexercised"))] == [])' "$O/run-behaviour.json" > /dev/null \
    && [ "$(head -n 1 "$O/record.txt")" = "behaviour: ran, 4 triggers, 0 over the cap" ] || return 1
  # The same list is read, not dropped to the require-everything value: with it the null
  # pass-through and the guarded block are marked, and with idle_timeout added only the block.
  # A file, not a variable: a variable this size in the environment stops every exec.
  # The added path sits last, so honouring it shows the whole list arrived.
  cp "$O/required.json" "$TMP/req-big.json"; jq -c '. + ["aws_lb_listener.idle_timeout"]' "$TMP/req-big.json" > "$TMP/req-big-end.json"
  UREQF="$TMP/req-big.json" unex && [ "$(marked)" = '["T-008","T-014"]' ] \
    && UREQF="$TMP/req-big-end.json" unex && [ "$(marked)" = '["T-014"]' ]
}
t_req_big; check "unexercised: a required list over the argument size limit still evaluates" $?
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
t_unex_tworeq() { UREQ="$(printf '[]\n["*"]')" unex && [ "$(marked)" = '[]' ]; }
t_unex_tworeq; check "unexercised: a required file of two JSON values requires everything" $?
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


# --- Identical (behaviour-pass.md, The Run Object): a trigger on the plan diff's closed list whose
# merge base examples all planned the same against the base and the head module, with one of
# them planning the address the change sits in.
LST=module.db.aws_lb_listener.secondary
jq --arg l "$LST" '.coverage.examples[0].addresses += [$l]' "$TMP/ladder-unex.json" > "$TMP/ladder-pd.json"
jq -n --arg l "$LST" '{schema_version: 1, class: "complete", examples: [], plan_diff: [
  {dir: "examples/complete", result: "equal", reason: null, addresses: ["module.db.aws_db_subnet_group.this", $l], module_calls: {db: "."}},
  {dir: "examples/minimal", result: "equal", reason: null, addresses: ["module.db.aws_db_subnet_group.this"], module_calls: {db: "."}}]}' > "$TMP/cov-pd.json"
# pdx [coverage jq update] [ladder jq update] [behaviour jq update] [eval jq update]: sets O.
pdx() {
  local SCHEMA="$TMP/schema-u.json"
  setup; jq "${3:-.}" "$TMP/behaviour-unex.json" > "$TMP/behaviour.out"; jq "${4:-.}" "$TMP/eval-unex.json" > "$TMP/eval.out"
  jq "${2:-.}" "$TMP/ladder-pd.json" > "$TMP/ladder-p.json"; jq "${1:-.}" "$TMP/cov-pd.json" > "$TMP/cov-p.json"
  local keep="$MOD"; MOD="$UMOD"; DIFF="$TMP/files-unex.json" classify; MOD="$keep"
  evalp --ladder "$TMP/ladder-p.json" --plan-diff "$TMP/cov-p.json"
}
same() { jq -c '[.triggers[] | select(has("identical")) | .id]' "$O/run-behaviour.json" 2> /dev/null; }
nosame() { [ "$(q '.status == "ran"')" = 0 ] && [ "$(same)" = '[]' ] && ! grep -q ', identical' "$O/record.txt"; }
t_pd() { pdx && [ "$(same)" = '["T-008","T-014","T-017","T-018"]' ] \
  && q '.triggers[] | select(.id == "T-008") | .identical == ["examples/complete", "examples/minimal"]' | grep -qx 0 \
  && [ "$(grep -c ', identical$' "$O/record.txt")" = 4 ] \
  && grep -qxF 'trigger T-008 `main.tf` line 10 unclassified-change: unverifiable, identical' "$O/record.txt"; }
t_pd; check "identical: arguments and variables the change adds, every merge base example equal, are marked" $?
t_pd_old() { pdx && q '[.triggers[] | select(.id | IN("T-012", "T-009", "T-007", "T-019", "T-020", "T-001")) | has("identical")] | any | not' | grep -qx 0; }
t_pd_old; check "identical: an argument from an existing variable, a propagation candidate, a literal and the terraform block are not marked" $?
t_pd_shape() { pdx && q '.triggers[] | select(.id == "T-010") | has("identical") | not' | grep -qx 0; }
t_pd_shape; check "identical: an argument from a new variable whose default is not null is not marked" $?
# A dynamic block whose for_each is exactly a variable the change adds with no level.
DYN='.triggers |= map(if .id == "T-014" then .head_expr = "var.new_on" | .referenced_inputs = [{name: "new_on", type: "map(string)"}]
  elif .id == "T-018" then .declaration = {added: true, default: "literal", nullable: "unset"} else . end)'
t_pd_dyn() { pdx . . "$DYN" && q '.triggers[] | select(.id == "T-014") | .identical == ["examples/complete", "examples/minimal"]' | grep -qx 0 \
  && grep -qxF 'trigger T-014 `main.tf` line 13 dynamic-block-change: unverifiable, identical' "$O/record.txt"; }
t_pd_dyn; check "identical: a dynamic block whose for_each is a new variable with no level is marked" $?
t_pd_dynold() { pdx . . "$DYN"' | .triggers |= map(if .id == "T-014" then .head_expr = "var.old_existing" | .referenced_inputs = [{name: "old_existing", type: "map(string)"}] else . end)' \
  && q '.triggers[] | select(.id == "T-014") | has("identical") | not' | grep -qx 0; }
t_pd_dynold; check "identical: a dynamic block over an existing variable is not marked" $?
t_pd_dyndir() { pdx . . "$DYN"' | .triggers |= map(if .id == "T-018" then .file = "modules/other/variables.tf" else . end)' \
  && q '.triggers[] | select(.id == "T-014") | has("identical") | not' | grep -qx 0; }
t_pd_dyndir; check "identical: a dynamic block over a variable added in another directory is not marked" $?
t_pd_dynnest() { pdx . . "$DYN"' | .triggers |= map(if .id == "T-014" then .attribute = "default_action.dynamic.inner" else . end)' \
  && q '.triggers[] | select(.id == "T-014") | has("identical") | not' | grep -qx 0; }
t_pd_dynnest; check "identical: a nested dynamic block is not marked" $?
t_pd_dynwrap() { pdx . . "$DYN"' | .triggers |= map(if .id == "T-014" then .head_expr = "merge(var.new_on, {})" else . end)' \
  && q '.triggers[] | select(.id == "T-014") | has("identical") | not' | grep -qx 0; }
t_pd_dynwrap; check "identical: a dynamic block whose for_each wraps the new variable is not marked" $?
t_pd_dyndiff() { pdx '.plan_diff[1].result = "differs"' . "$DYN" && q '.triggers[] | select(.id == "T-014") | has("identical") | not' | grep -qx 0; }
t_pd_dyndiff; check "identical: a dynamic block whose example plans differ is not marked" $?
# A static block made dynamic: the engine reads only the for_each, while the content may read an
# existing input, so a removed or edited block of the same type keeps the new one off the list.
t_pd_dynstatic() { pdx . . "$DYN"' | .triggers += [{id: "T-021", file: "main.tf", line: 13, category: "unclassified-change", change_kind: "removed",
    address: "aws_lb_listener.secondary", attribute: "default_action", base_expr: null, head_expr: null, levels: ["L4"],
    referenced_inputs: [], contextual_refs: [], contextual_ref_details: []}] | .entries[0].trigger_ids += ["T-021"]' \
    '.triggers += [{id: "T-021", state: "unverifiable", reason: "x"}]' \
  && q '.triggers[] | select(.id == "T-014") | has("identical") | not' | grep -qx 0; }
t_pd_dynstatic; check "identical: a static block made dynamic is not marked" $?
t_pd_dynedit() { pdx . . "$DYN"' | .triggers += [{id: "T-021", file: "main.tf", line: 14, category: "unclassified-change", change_kind: "modified",
    address: "aws_lb_listener.secondary", attribute: "dynamic.default_action.content.type", base_expr: "\"a\"", head_expr: "\"b\"", levels: ["L4"],
    referenced_inputs: [], contextual_refs: [], contextual_ref_details: []}] | .entries[0].trigger_ids += ["T-021"]' \
    '.triggers += [{id: "T-021", state: "unverifiable", reason: "x"}]' \
  && q '.triggers[] | select(.id == "T-014") | has("identical") | not' | grep -qx 0; }
t_pd_dynedit; check "identical: a dynamic block beside an edit inside a block of its type is not marked" $?
t_pd_dynfull() { pdx . . "$DYN"' | .triggers |= map(if .id == "T-018" then .levels = ["L4"] else . end)' \
  && q '.triggers[] | select(.id == "T-014") | has("identical") | not' | grep -qx 0; }
t_pd_dynfull; check "identical: a dynamic block over a new variable with a level, a non-empty default or a validation block, is not marked" $?
t_pd_dyndecl() { pdx . . "$DYN"' | .triggers |= map(if .id == "T-018" then .declaration = {added: true, default: "other", nullable: "unset"} else . end)' \
  && q '.triggers[] | select(.id == "T-014") | has("identical") | not' | grep -qx 0; }
t_pd_dyndecl; check "identical: a dynamic block over a new variable whose default is not a literal is not marked" $?
t_pd_dynlit() { pdx . . "$DYN"' | .triggers |= map(if .id == "T-018" then .declaration = {added: true, default: "literal", nullable: "unset"} else . end)' \
  && q '.triggers[] | select(.id == "T-014") | .identical == ["examples/complete", "examples/minimal"]' | grep -qx 0; }
t_pd_dynlit; check "identical: a dynamic block over a new variable with a literal default and no level is marked" $?
# {} converts to an object whose optional attributes take their defaults, and for_each iterates
# the object's attributes: an object type makes a block at the default.
t_pd_dynobj() { pdx . . "$DYN"' | .triggers |= map(if .id == "T-014" then .referenced_inputs[0].type = "object({a = optional(string, \"10.0.0.0/8\")})" else . end)' \
  && q '.triggers[] | select(.id == "T-014") | has("identical") | not' | grep -qx 0; }
t_pd_dynobj; check "identical: a dynamic block over a new variable of an object type is not marked" $?
t_pd_dynlist() { pdx . . "$DYN"' | .triggers |= map(if .id == "T-014" then .referenced_inputs[0].type = "list(object({ port = number }))" else . end)' \
  && q '.triggers[] | select(.id == "T-014") | .identical == ["examples/complete", "examples/minimal"]' | grep -qx 0; }
t_pd_dynlist; check "identical: a dynamic block over a new variable of a list type is marked" $?
t_pd_dynnodecl() { pdx . . "$DYN"' | .triggers |= map(if .id == "T-018" then .declaration = null else . end)' \
  && q '.triggers[] | select(.id == "T-014") | has("identical") | not' | grep -qx 0; }
t_pd_dynnodecl; check "identical: a dynamic block over a new variable with no reported declaration is not marked" $?
t_pd_dynnoattr() { pdx . . "$DYN"' | .triggers += [{id: "T-021", file: "main.tf", line: 13, category: "unclassified-change", change_kind: "modified",
    address: "aws_lb_listener.secondary", attribute: null, base_expr: null, head_expr: null, levels: ["L4"],
    referenced_inputs: [], contextual_refs: [], contextual_ref_details: []}] | .entries[0].trigger_ids += ["T-021"]' \
    '.triggers += [{id: "T-021", state: "unverifiable", reason: "x"}]' \
  && q '.triggers[] | select(.id == "T-014") | has("identical") | not' | grep -qx 0; }
t_pd_dynnoattr; check "identical: a dynamic block beside a change at its address that names no attribute is not marked" $?
t_pd_dyncap() { pdx . . "$DYN"' | .capped = 1' '.capped = 1' \
  && [ "$(q '.status == "ran"')" = 0 ] && q '.triggers[] | select(.id == "T-014") | has("identical") | not' | grep -qx 0; }
t_pd_dyncap; check "identical: a dynamic block is not marked when triggers went over the classifier cap" $?
t_pd_dynmeta() { pdx . . "$DYN"' | .triggers |= map(if .id == "T-014" then .attribute = "dynamic.lifecycle" else . end)' \
  && q '.triggers[] | select(.id == "T-014") | has("identical") | not' | grep -qx 0; }
t_pd_dynmeta; check "identical: a dynamic block named like a meta-argument is not marked" $?
t_pd_dynlvl() { pdx . . "$DYN"' | .triggers |= map(if .id == "T-014" then .levels = ["L1", "L4"] else . end)' \
  && q '.triggers[] | select(.id == "T-014") | has("identical") | not' | grep -qx 0; }
t_pd_dynlvl; check "identical: a dynamic block with a level besides L4 is not marked" $?
t_pd_dynalso() { pdx . . "$DYN"' | .triggers |= map(if .id == "T-014" then .also_categories = ["unclassified-change"] else . end)' \
  && q '.triggers[] | select(.id == "T-014") | has("identical") | not' | grep -qx 0; }
t_pd_dynalso; check "identical: a dynamic block with a merged category is not marked" $?
t_pd_dynnotadded() { pdx . . "$DYN"' | .triggers |= map(if .id == "T-018" then .declaration.added = false else . end)' \
  && q '.triggers[] | select(.id == "T-014") | has("identical") | not' | grep -qx 0; }
t_pd_dynnotadded; check "identical: a dynamic block over a variable whose declaration is not added is not marked" $?
t_pd_dynnumattr() { pdx . . "$DYN"' | .triggers += [{id: "T-021", file: "main.tf", line: 13, category: "unclassified-change", change_kind: "modified",
    address: "aws_lb_listener.secondary", attribute: 1, base_expr: null, head_expr: null, levels: ["L4"],
    referenced_inputs: [], contextual_refs: [], contextual_ref_details: []}] | .entries[0].trigger_ids += ["T-021"]' \
    '.triggers += [{id: "T-021", state: "unverifiable", reason: "x"}]' \
  && [ "$(q '.status == "ran"')" = 0 ] && q '.triggers[] | select(.id == "T-014") | has("identical") | not' | grep -qx 0; }
t_pd_dynnumattr; check "identical: a dynamic block beside a change at its address whose attribute is no string is not marked" $?
# A managed resource the change adds whose gate (behaviour.resource-gate) reads only variables the
# change adds in its directory with no level and a null or literal default: at the defaults no
# existing caller makes an instance of it, and an equal plan diff of every eligible example shows
# it makes none, as the recorded additive-gate-off plan does (tests/plan-pass-test.sh).
RES='.triggers |= map(if .id == "T-018" then .declaration = {added: true, default: "literal", nullable: "unset"} else . end)
  | .triggers += [{id: "T-021", file: "main.tf", line: 20, category: "resource-added-or-removed", change_kind: "added",
    address: "aws_lb_listener.gated", attribute: null, base_expr: null, head_expr: null, levels: ["L4"],
    referenced_inputs: [], contextual_refs: [], contextual_ref_details: [], pure: false, reason: null,
    gate: {attribute: "count", expr: "var.new_on ? 1 : 0", contextual_refs: [], pure: true,
      referenced_inputs: [{name: "new_on", type: "bool", declaration: {added: true, default: "literal", nullable: "unset"}}]}}]
  | .entries[0].trigger_ids += ["T-021"]'
RESE='.triggers += [{id: "T-021", state: "unverifiable", reason: "x"}]'
# res [behaviour jq update after RES] [coverage jq update]: the resource case; sets rv to 0 when the
# step ran and T-021 is identical, 1 when it ran and T-021 is not, and empty otherwise.
res() { rv=""; pdx "${2:-.}" . "$RES | ${1:-.}" "$RESE" > /dev/null 2>&1 && [ "$(q '.status == "ran"')" = 0 ] \
  && rv="$(q '.triggers[] | select(.id == "T-021") | .identical == ["examples/complete", "examples/minimal"]')"; }
t_pd_res() { { res; [ "$rv" = 0 ]; } && grep -qxF 'trigger T-021 `main.tf` line 20 resource-added-or-removed: unverifiable, identical' "$O/record.txt"; }
t_pd_res; check "identical: a new resource whose gate reads only new variables with no level is marked" $?
t_pd_resfe() { { res '.triggers |= map(if .id == "T-021" then .gate |= (.attribute = "for_each" | .expr = "var.new_idle") else . end)'; [ "$rv" = 0 ]; }; }
t_pd_resfe; check "identical: a new resource whose for_each reads a new variable is marked" $?
t_pd_resnull() { { res '.triggers |= map(if .id == "T-018" then .declaration.default = "null" else . end)'; [ "$rv" = 0 ]; }; }
t_pd_resnull; check "identical: a new resource gated on a new variable with a null default is marked" $?
t_pd_resnogate() { { res '.triggers |= map(if .id == "T-021" then del(.gate) else . end)'; [ "$rv" = 1 ]; }; }
t_pd_resnogate; check "identical: a new resource with no gate, as a binary without behaviour.resource-gate gives, is not marked" $?
t_pd_resold() { { res '.triggers |= map(if .id == "T-021" then .gate.referenced_inputs = [{name: "old_existing", type: "any"}] else . end)'; [ "$rv" = 1 ]; }; }
t_pd_resold; check "identical: a new resource gated on an existing variable is not marked" $?
t_pd_resmix() { { res '.triggers |= map(if .id == "T-021" then .gate.referenced_inputs += [{name: "old_existing", type: "any"}] else . end)'; [ "$rv" = 1 ]; }; }
t_pd_resmix; check "identical: a new resource gated on a new and an existing variable is not marked" $?
t_pd_resctx() { { res '.triggers |= map(if .id == "T-021" then .gate.contextual_refs = ["local.on"] else . end)'; [ "$rv" = 1 ]; }; }
t_pd_resctx; check "identical: a new resource whose gate reads a local is not marked" $?
t_pd_respure() { { res '.triggers |= map(if .id == "T-021" then .gate.pure = false else . end)'; [ "$rv" = 1 ]; }; }
t_pd_respure; check "identical: a new resource whose gate calls an impure function is not marked" $?
t_pd_reslvl() { { res '.triggers |= map(if .id == "T-018" then .levels = ["L4"] else . end)'; [ "$rv" = 1 ]; }; }
t_pd_reslvl; check "identical: a new resource gated on a new variable with a level is not marked" $?
t_pd_resdef() { { res '.triggers |= map(if .id == "T-018" then .declaration.default = "other" else . end)'; [ "$rv" = 1 ]; }; }
t_pd_resdef; check "identical: a new resource gated on a new variable whose default is no literal is not marked" $?
t_pd_resadded() { { res '.triggers |= map(if .id == "T-018" then .declaration.added = false else . end)'; [ "$rv" = 1 ]; }; }
t_pd_resadded; check "identical: a new resource gated on a variable whose declaration is not added is not marked" $?
t_pd_resdir() { { res '.triggers |= map(if .id == "T-018" then .file = "modules/other/variables.tf" else . end)'; [ "$rv" = 1 ]; }; }
t_pd_resdir; check "identical: a new resource gated on a variable added in another directory is not marked" $?
t_pd_resdata() { { res '.triggers |= map(if .id == "T-021" then .address = "data.aws_lb_listener.gated" else . end)'; [ "$rv" = 1 ]; }; }
t_pd_resdata; check "identical: a new data source is not marked" $?
t_pd_resmod() { { res '.triggers |= map(if .id == "T-021" then .address = "module.gated" else . end)'; [ "$rv" = 1 ]; }; }
t_pd_resmod; check "identical: a new module call is not marked" $?
t_pd_resattr() { { res '.triggers |= map(if .id == "T-021" then .gate.attribute = "depends_on" else . end)'; [ "$rv" = 1 ]; }; }
t_pd_resattr; check "identical: a gate that is neither count nor for_each is not marked" $?
t_pd_resalso() { { res '.triggers |= map(if .id == "T-021" then .also_categories = ["unclassified-change"] else . end)'; [ "$rv" = 1 ]; }; }
t_pd_resalso; check "identical: a new resource with a merged category is not marked" $?
t_pd_rescap() { pdx . . "$RES | .capped = 1" "$RESE | .capped = 1" && [ "$(q '.status == "ran"')" = 0 ] \
  && q '.triggers[] | select(.id == "T-021") | has("identical") | not' | grep -qx 0; }
t_pd_rescap; check "identical: a new resource is not marked when triggers went over the classifier cap" $?
t_pd_resl1() { { res '.triggers |= map(if .id == "T-021" then .levels = ["L1", "L4"] else . end)'; [ "$rv" = 1 ]; }; }
t_pd_resl1; check "identical: a new resource with a level besides L4 is not marked" $?
t_pd_rescat() { { res '.triggers |= map(if .id == "T-021" then .category = "lifecycle-change" else . end)'; [ "$rv" = 1 ]; }; }
t_pd_rescat; check "identical: a gate on a trigger of another category is not marked" $?
t_pd_resdiff() { { res . '.plan_diff[1] |= (.result = "differs" | .addresses = [])'; [ "$rv" = 1 ]; }; }
t_pd_resdiff; check "identical: a new resource an example plans, a plan that differs, is not marked" $?
t_pd_resinst() { { res . '.plan_diff |= map(.addresses = ["aws_s3_bucket.other"])'; [ "$rv" = 1 ]; }; }
t_pd_resinst; check "identical: a new resource with no address of its module instance planned is not marked" $?
t_pd_resvar() { { res '.triggers |= map(if .id == "T-021" then .gate.referenced_inputs = [{name: 1, type: "bool"}] else . end)'; [ "$rv" = 1 ]; }; }
t_pd_resvar; check "identical: a gate input whose name is no string is not marked" $?
t_pd_resnullin() { { res '.triggers |= map(if .id == "T-021" then .gate.referenced_inputs = null else . end)'; [ "$rv" = 1 ]; }; }
t_pd_resnullin; check "identical: a gate whose inputs are no list is not marked" $?
t_pd_resnoin() { { res '.triggers |= map(if .id == "T-021" then .gate |= (.referenced_inputs = [] | .expr = "0") else . end)'; [ "$rv" = 1 ]; }; }
t_pd_resnoin; check "identical: a new resource whose gate reads no variable is not marked" $?
t_pd_resnoindiff() { { res '.triggers |= map(if .id == "T-021" then .gate |= (.referenced_inputs = [] | .expr = "1") else . end)' \
    '.plan_diff[1] |= (.result = "differs" | .addresses = [])'; [ "$rv" = 1 ]; }; }
t_pd_resnoindiff; check "identical: a new resource whose gate reads no variable, a plan that differs, is not marked" $?
t_pd_reskind() { { res '.triggers |= map(if .id == "T-018" then .change_kind = "modified" else . end)'; [ "$rv" = 1 ]; }; }
t_pd_reskind; check "identical: a new resource gated on a variable the change modifies is not marked" $?
t_pd_resvcat() { { res '.triggers |= map(if .id == "T-018" then .category = "default-change" else . end)'; [ "$rv" = 1 ]; }; }
t_pd_resvcat; check "identical: a new resource gated on a variable trigger of another category is not marked" $?
t_pd_resvalso() { { res '.triggers |= map(if .id == "T-018" then .also_categories = ["type-validation-change"] else . end)'; [ "$rv" = 1 ]; }; }
t_pd_resvalso; check "identical: a new resource gated on a variable trigger with a merged category is not marked" $?
t_pd_wrap() { pdx . . '.triggers |= map(if .id == "T-008" then .head_expr = "coalesce(var.new_idle, 60)" else . end)' \
  && q '.triggers[] | select(.id == "T-008") | has("identical") | not' | grep -qx 0; }
t_pd_wrap; check "identical: a function around the new variable is not marked" $?
t_pd_call() { pdx '.plan_diff[0].addresses += ["module.db.module.sub"]' . '.triggers += [{id: "T-021", file: "main.tf", line: 20, category: "unclassified-change", change_kind: "added",
    address: "module.sub", attribute: "idle", base_expr: null, head_expr: "var.new_idle", levels: ["L4"],
    referenced_inputs: [{name: "new_idle", type: "number"}], contextual_refs: [], reason: null}]
  | .entries[0].trigger_ids += ["T-021"]' '.triggers += [{id: "T-021", state: "unverifiable", reason: "x"}]' \
  && q '.triggers[] | select(.id == "T-021") | has("identical") | not' | grep -qx 0; }
t_pd_call; check "identical: a module call argument is never marked" $?
t_pd_base() { pdx '.plan_diff[1].module_calls = {db: "../other"}' && [ "$(same)" = '["T-008","T-014","T-017","T-018"]' ] \
  && q '.triggers[] | select(.id == "T-008") | .identical == ["examples/complete"]' | grep -qx 0; }
t_pd_base; check "identical: an example whose merge base HCL does not call the directory is not eligible" $?
t_pd_basecall() { pdx '.plan_diff[0].module_calls = {db: "../other"} | .plan_diff[1].module_calls = {db: "../other"}' && nosame; }
t_pd_basecall; check "identical: no example whose merge base HCL calls the directory marks nothing" $?
t_pd_edited() { pdx '.plan_diff |= .[:1]' '.coverage.examples[1].module_calls = {}' \
  '.entries += [{path: "examples/minimal/main.tf", change_kind: "modified", inert: true, trigger_ids: []}]' && nosame; }
t_pd_edited; check "identical: an example the change edits with no plan diff marks nothing" $?
t_pd_inex() { pdx '.plan_diff[0].dir = "."' '.coverage.examples[0].dir = "."' && nosame; }
t_pd_inex; check "identical: a trigger in an example directory is never marked" $?
# A variable the change adds with a validation block, which can fail a caller that never sets
# it (the classifier gives it a level), is never marked; the level is set here by hand, and the
# classifier's own reading of a validation block is held in the facts repository.
t_pd_valid() { pdx . . '.triggers |= map(if .id == "T-017" then .levels = ["L4"] else . end)' \
  && q '.triggers[] | select(.id == "T-017") | has("identical") | not' | grep -qx 0; }
t_pd_valid; check "identical: an added variable with a validation block is not marked" $?
t_pd_output() { pdx . . '.triggers += [{id: "T-021", file: "outputs.tf", line: 1, category: "locals-outputs-change", change_kind: "added",
    address: "output.arn", attribute: "value", base_expr: null, head_expr: "aws_lb_listener.secondary.arn", levels: [],
    referenced_inputs: [], contextual_refs: ["aws_lb_listener.secondary"], reason: null}]
  | .entries += [{path: "outputs.tf", change_kind: "modified", inert: false, trigger_ids: ["T-021"]}]' '.triggers += [{id: "T-021", state: "unverifiable", reason: "x"}]' \
  && q '.triggers[] | select(.id == "T-021") | has("identical") | not' | grep -qx 0; }
t_pd_output; check "identical: an added output is not marked" $?
t_pd_nocalls() { pdx . '.coverage.examples |= map(.module_calls = {})' && nosame; }
t_pd_nocalls; check "identical: coverage with no head module calls, as a hosted record gives, marks nothing" $?
t_pd_l1() { pdx . . '.triggers |= map(if .id == "T-008" then .levels = ["L1", "L4"] else . end)' \
  && q '.triggers[] | select(.id == "T-008") | has("identical") | not' | grep -qx 0; }
t_pd_l1; check "identical: an argument with a level besides L4 is not marked" $?
t_pd_sort() { pdx '.plan_diff |= reverse' '.coverage.examples |= reverse' \
  && q '.triggers[] | select(.id == "T-017") | .identical == ["examples/complete", "examples/minimal"]' | grep -qx 0; }
t_pd_sort; check "identical: the examples are listed sorted" $?
t_pd_cap() { pdx '.plan_diff += [range(25) as $i | .plan_diff[1] | .dir = "examples/x\($i)"]' \
  '.coverage.examples += [range(25) as $i | .coverage.examples[1] | .dir = "examples/x\($i)"]' \
  && q '.triggers[] | select(.id == "T-017") | (.identical | length) == 20' | grep -qx 0 \
  && q '.triggers[] | select(.id == "T-017") | .identical == (.identical | sort)' | grep -qx 0; }
t_pd_cap; check "identical: at most 20 examples are listed" $?
t_pd_type() { pdx . . '.triggers |= map(if .id == "T-015" then .levels = [] else . end)' '.triggers |= map(if .id == "T-015" then .state = "unverifiable" else . end)' \
  && q '.triggers[] | select(.id == "T-015") | has("identical") | not' | grep -qx 0; }
t_pd_type; check "identical: a type or validation change of a variable is not marked" $?
t_pd_differs() { pdx '.plan_diff[1].result = "differs"' && nosame; }
t_pd_differs; check "identical: one eligible example that differs marks nothing" $?
t_pd_notrun() { pdx '.plan_diff[1] |= (.result = "not-run" | .reason = "base-plan" | .addresses = [])' && nosame; }
t_pd_notrun; check "identical: one eligible example whose base plan did not run marks nothing" $?
t_pd_missing() { pdx '.plan_diff |= .[:1]' && nosame; }
t_pd_missing; check "identical: an eligible example with no plan diff marks nothing" $?
t_pd_absent() { pdx '.plan_diff[1] |= (.result = "not-run" | .reason = "absent-at-base" | .addresses = [])' \
  && [ "$(same)" = '["T-008","T-014","T-017","T-018"]' ] \
  && q '.triggers[] | select(.id == "T-008") | .identical == ["examples/complete"]' | grep -qx 0; }
t_pd_absent; check "identical: an example absent at the merge base is not eligible" $?
t_pd_consume() { pdx '.plan_diff[0].addresses = ["module.db.aws_db_subnet_group.this"]' \
  && [ "$(same)" = '["T-017","T-018"]' ]; }
t_pd_consume; check "identical: an argument whose resource no merge base example plans is not marked, its variable is" $?
t_pd_noinst() { pdx '.plan_diff |= map(.addresses = ["aws_s3_bucket.other"])' && nosame; }
t_pd_noinst; check "identical: no address of the module instance marks nothing" $?
t_pd_partial() { pdx . '.coverage.class = "partial"' && nosame; }
t_pd_partial; check "identical: coverage that is not complete marks nothing" $?
t_pd_headfail() { pdx . '.coverage.examples[1].head = "code-error"' && nosame; }
t_pd_headfail; check "identical: an example whose head did not plan marks nothing" $?
t_pd_noaddr() { pdx . '.coverage.examples[1].addresses = []' && nosame; }
t_pd_noaddr; check "identical: an example with no addresses read marks nothing" $?
t_pd_none() { local SCHEMA="$TMP/schema-u.json"; setup; cp "$TMP/behaviour-unex.json" "$TMP/behaviour.out"; cp "$TMP/eval-unex.json" "$TMP/eval.out"
  local keep="$MOD"; MOD="$UMOD"; DIFF="$TMP/files-unex.json" classify; MOD="$keep"; evalp --ladder "$TMP/ladder-pd.json" && nosame; }
t_pd_none; check "identical: no plan diff file marks nothing" $?
t_pd_bad() { pdx '.plan_diff = "x"' && nosame; }
t_pd_bad; check "identical: a plan diff outside its shape is no evidence and the step still runs" $?
t_pd_unex() { pdx . '.coverage.examples[0].addresses -= ["module.db.aws_lb_listener.secondary"]' '.' '.' \
  && q '.triggers[] | select(.id == "T-008") | (.unexercised == true) and (has("identical") | not)' | grep -qx 0; }
t_pd_unex; check "identical: an unexercised trigger is not also identical" $?
# The directories of the closed list, for the plan pass's --diff-dir.
t_pd_dirs() { local SCHEMA="$TMP/schema-u.json"; setup
  jq '.triggers += [{id: "T-021", file: "modules/a/main.tf", line: 2, category: "literal-argument-change", change_kind: "modified",
        address: "aws_s3_bucket.a", attribute: "acl", base_expr: "\"a\"", head_expr: "\"b\"", levels: ["L4"], referenced_inputs: [], contextual_refs: [], reason: null},
      {id: "T-022", file: "modules/b/variables.tf", line: 1, category: "unclassified-change", change_kind: "added",
        address: "var.arn", attribute: null, base_expr: null, head_expr: null, levels: [], referenced_inputs: [], contextual_refs: [], reason: null},
      {id: "T-023", file: "modules/c/variables.tf", line: 1, category: "unclassified-change", change_kind: "added",
        address: "var.rules", attribute: null, base_expr: null, head_expr: null, levels: ["L4"], referenced_inputs: [], contextual_refs: [], reason: null},
      {id: "T-024", file: "modules/d/variables.tf", line: 1, category: "unclassified-change", change_kind: "removed",
        address: "var.gone", attribute: null, base_expr: null, head_expr: null, levels: ["L4"], referenced_inputs: [], contextual_refs: [], reason: null}]
    | .entries += [{path: "modules/a/main.tf", change_kind: "modified", inert: false, trigger_ids: ["T-021"]},
                   {path: "modules/b/variables.tf", change_kind: "modified", inert: false, trigger_ids: ["T-022"]},
                   {path: "modules/c/variables.tf", change_kind: "modified", inert: false, trigger_ids: ["T-023"]},
                   {path: "modules/d/variables.tf", change_kind: "modified", inert: false, trigger_ids: ["T-024"]}]' "$TMP/behaviour-unex.json" > "$TMP/behaviour.out"
  jq '. + [{filename: "modules/a/main.tf", status: "modified"}, {filename: "modules/b/variables.tf", status: "modified"},
    {filename: "modules/c/variables.tf", status: "modified"}, {filename: "modules/d/variables.tf", status: "modified"}]' "$TMP/files-unex.json" > "$TMP/files-dirs.json"
  local keep="$MOD"; MOD="$UMOD"; DIFF="$TMP/files-dirs.json" classify; MOD="$keep"
  [ "$(bash "$BP" diff-dirs --out "$O")" = "$(printf '.\nmodules/b\nmodules/c')" ] \
    && [ "$(bash "$BP" diff-dirs --out "$O" --prefix mods/x/)" = "$(printf 'mods/x\nmods/x/modules/b\nmods/x/modules/c')" ]; }
t_pd_dirs; check "identical: diff-dirs prints the directories of the closed list and of the variables the change adds, repository-relative" $?
# End to end with a real mtf-facts that reports behaviour.resource-gate (MTF_FACTS_BIN): the module
# the recorded additive plans of tests/plan-diff-fixture/ were made from, classified and evaluated
# with a plan diff that plan-pass.sh's PDIFF_JQ computes from those plans. A new security group
# whose count reads a new bool defaulting to false, and its variable, are identical; at true the
# plan diff ends unknown and neither is. Skipped with a note without such a binary.
e2e_gate() { # head variant (gate-off or gate-on): prints the identical trigger categories, sorted
  local m="$TMP/e2e-gate" o pd res addrs h b
  h="$(printf 'a%.0s' $(seq 40))"; b="$(printf 'b%.0s' $(seq 40))"
  rm -rf "$m"; mkdir -p "$m/base/examples/complete" "$m/head/examples/complete"
  printf 'resource "aws_security_group" "this" {\n  name = "sg"\n}\n' > "$m/base/main.tf"
  cp "$m/base/main.tf" "$m/head/main.tf"
  printf 'resource "aws_security_group" "extra" {\n  count = var.create_extra ? 1 : 0\n  name  = "extra"\n}\nvariable "create_extra" {\n  type    = bool\n  default = %s\n}\n' \
    "$([ "$1" = gate-off ] && echo false || echo true)" >> "$m/head/main.tf"
  for d in base head; do
    printf 'terraform {\n  required_providers {\n    aws = { source = "hashicorp/aws", version = "6.74.0" }\n  }\n}\n' > "$m/$d/versions.tf"
    printf 'module "this" {\n  source = "../../"\n}\n' > "$m/$d/examples/complete/main.tf"
  done
  o="$TMP/e2e-gate-out-$1"; rm -rf "$o"; mkdir -p "$o"
  bash "$BP" classify --facts "$MTF_FACTS_BIN" --dir "$m/head" --base "$m/base" --out "$o" > /dev/null 2>&1 || return 1
  pd="$(sed -n "/^PDIFF_JQ='\$/,/^'\$/p" "$REF/plan-pass.sh" | sed '1d;$d')"
  res="$(jq -n -c --slurpfile a "$PDFX/additive-base.json" --slurpfile b "$PDFX/additive-$1.json" --slurpfile s "$PDFX/additive-schema.json" "$pd")" || return 1
  addrs="$(jq -c '[.resource_changes[].address | gsub("\\[[^\\]]*\\]"; "")] | unique' "$PDFX/additive-$1.json")"
  jq -n --argjson r "$res" --argjson a "$addrs" '{schema_version: 1, class: "complete", examples: [], plan_diff: [{dir: "examples/complete",
    result: $r.result, reason: $r.reason, addresses: (if $r.result == "equal" then $a else [] end),
    module_calls: (if $r.result == "equal" then {this: "."} else {} end)}]}' > "$o/cov.json"
  jq -n --arg h "$h" --arg b "$b" --argjson a "$addrs" '{schema_version: 1, head_sha: $h, base_sha: $b, terraform_version: "1.17.0", pins: [], runs: [],
    coverage: {class: "complete", examples: [{dir: "examples/complete", head: "planned", base: null, addresses: $a, module_calls: {this: "."}}]}}' > "$o/ladder.json"
  bash "$BP" eval --facts "$MTF_FACTS_BIN" --out "$o" --head "$h" --base-sha "$b" --ladder "$o/ladder.json" --plan-diff "$o/cov.json" > /dev/null 2>&1 || return 1
  jq -e '.status == "ran"' "$o/run-behaviour.json" > /dev/null || return 1
  jq -c '[.triggers[] | select(has("identical")) | .category] | sort' "$o/run-behaviour.json"
}
PDFX="$SRC/tests/plan-diff-fixture"
if [ -n "${MTF_FACTS_BIN:-}" ] && [ -x "$MTF_FACTS_BIN" ] \
   && "$MTF_FACTS_BIN" version --json 2> /dev/null | jq -e '.features | index("behaviour.resource-gate") != null' > /dev/null 2>&1; then
  t_e2e_gate() { [ "$(e2e_gate gate-off)" = '["resource-added-or-removed","unclassified-change"]' ] && [ "$(e2e_gate gate-on)" = '[]' ]; }
  t_e2e_gate; check "identical: live, a new resource gated on a new bool and its variable are identical at false and not at true" $?
else
  echo "skip identical live: MTF_FACTS_BIN names no mtf-facts that lists behaviour.resource-gate"
fi

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
# rename is checked at its old path too, and an unchanged path needs no entry, while a committed
# .terraform file needs one like any other change.
setup
jq '[.[0] + {filename: "mod/main.tf"}, {filename: "other/x.tf", status: "modified"}, {filename: "mod/.terraform/x", status: "added"}, {filename: "mod/README.md", status: "unchanged"}]' "$TMP/files.json" > "$TMP/files-pfx.json"
jq '.entries += [{path: ".terraform/x", change_kind: "added", inert: true, trigger_ids: []}]' "$TMP/behaviour-556.json" > "$TMP/behaviour.out"
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
# --- Contract 8: claims-eval's limit token crosses to the run object and the record line of an
# unverifiable trigger; a token off the closed list or on another state is refused.
t_limit() {
  setup; jq '.triggers[0].limit = "module-call-argument"' "$TMP/eval-556.json" > "$TMP/eval.out"
  classify; evalp --claims "$TMP/claims-556.json"
  [ "$(q '.triggers[0].limit == "module-call-argument" and (.triggers[1] | has("limit") | not)')" = 0 ] &&
    grep -qxF 'trigger T-001 `main.tf` line 2 wrapper-change: unverifiable, limit module-call-argument' "$O/record.txt"
}
t_limit; check "limit: the token crosses to the run trigger and its record line" $?
for tok in file-size parser-limit no-input-states; do
  setup; jq --arg t "$tok" '.triggers[0].limit = $t' "$TMP/eval-556.json" > "$TMP/eval.out"
  classify; evalp --claims "$TMP/claims-556.json"
  check "limit: $tok crosses" "$(q '.triggers[0].limit == "'"$tok"'"')"
done
refuse_e "a limit off the closed list" '.triggers[0].limit = "expression-size"'
refuse_e "a limit on a covered trigger" '.triggers[0].state = "covered" | .triggers[0].limit = "file-size"'
refuse_e "a limit that is no string" '.triggers[0].limit = 1'
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
  cp "$BP" "$d/behaviour-pass.sh"; cp "$REF/facts-resolve.sh" "$REF/module-files.jq" "$d/"; perl -0pi -e "$2" "$d/behaviour-pass.sh"
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

# The negative self-check: each weakened copy of the script lets a case above through.
mn=0
wmutate() { # name, perl substitution, case function [, file mutated, behaviour-pass.sh by default]
  mn=$((mn + 1)); local d="$TMP/wmut-$mn"; mkdir -p "$d"
  cp "$REF/behaviour-pass.sh" "$REF/wrapper-derive.pl" "$REF/facts-resolve.sh" "$REF/module-files.jq" "$d/"
  local f="${4:-behaviour-pass.sh}"; perl -0pi -e "$2" "$d/$f"
  if cmp -s "$d/$f" "$REF/$f"; then check "self-check: $1 (the mutation changed nothing)" 1; return; fi
  local keep="$BP" before="$fails"; BP="$d/behaviour-pass.sh"
  "$3" > /dev/null 2>&1; local s=$?
  BP="$keep"; fails="$before"
  check "self-check: $1 is caught" "$([ "$s" != 0 ]; echo $?)"
}
t_limit_refused() { # a token off the list is refused
  setup; jq '.triggers[0].limit = "expression-size"' "$TMP/eval-556.json" > "$TMP/eval.out"
  classify; evalp --claims "$TMP/claims-556.json"
  jq -e '.status == "not-run" and .reason == "output refused"' "$O/run-behaviour.json" > /dev/null
}
t_limit_state() { # a token on a covered trigger is refused
  setup; jq '.triggers[0].state = "covered" | .triggers[0].limit = "file-size"' "$TMP/eval-556.json" > "$TMP/eval.out"
  classify; evalp --claims "$TMP/claims-556.json"
  jq -e '.status == "not-run" and .reason == "output refused"' "$O/run-behaviour.json" > /dev/null
}
wmutate "limit: any token taken" 's/\(\.limit \| IN\([^)]*\)\)/true/' t_limit_refused
wmutate "limit: a token on any state taken" 's/ and \.state == "unverifiable"\)\)\n        and \(\.id as/))\n        and (.id as/' t_limit_state
wmutate "limit: not copied to the run trigger" 's/"evidence_digest", "limit"\)/"evidence_digest")/' t_limit
wmutate "limit: left out of the record line" 's/ \+ \(if \$et\.limit != null then ", limit \\\(\$et\.limit\)" else "" end\)//' t_limit
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
wmutate "unexercised: the 2 MiB cap dropped" 's/ && \[ "\$\(wc -c < "\$f"\)" -le "\$TF_CAP" \]//' t_unex_big
wmutate "unexercised: the 1 MiB cap kept" 's/^TF_CAP=2097152/TF_CAP=1048576/m' t_unex_mid
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
wmutate "unexercised: a malformed required list read as none" 's/then \.\[0\] else \["\*"\] end/then .[0] else [] end/' t_unex_badreq
wmutate "unexercised: a required file of two values read as its first" 's/if length == 1 and \(\.\[0\] \| /if (.[0] | /' t_unex_tworeq
wmutate "unexercised: the large required list dropped to require everything" 's/ \| \$rq\[0\] as \$rq/ | ["*"] as \$rq/' t_req_big
wmutate "unexercised: the required list passed in argv" 's/--slurpfile rq <\(printf \x27%s\\n\x27 "\$\{rq:-\[\\"\*\\"\]\}"\)/--argjson rq "\${rq:-[\\"*\\"]}"/; s/ \| \$rq\[0\] as \$rq//' t_req_big
wmutate "unexercised: a null attribute not guarded" 's/def not_required\(\$t\): \(\$t\.attribute \| type == "string"\)\n      and /def not_required(\$t): /' t_unex_nullattr
wmutate "unexercised: an unloaded directory marked" 's/ and plans_known and loaded\(\$t\)/ and plans_known/' t_unex_unloaded
wmutate "unexercised: an unloaded variable trigger marked" 's/and all\(\.\[\]; IN\(\$m\[\]\)\)\) and loaded\(\$t\);/and all(.[]; IN(\$m[])));/; s/ and plans_known and loaded\(\$t\)/ and plans_known/' t_unex_unloaded
wmutate "unexercised: a directly called directory not seen as loaded" 's/\.dir == \$d or \(\(\.module_calls \/\/ \{\}\) \| to_entries \| any\(\.value == \$d\)\)/.dir == \$d/' t_unex_loaded
wmutate "unexercised: strings matched without escapes" 's/s\/"\(\(\?:\[\^"\\\\\]\|\\\\\.\)\*\)"\//s\/"([^"]*)"\//' t_unex_escq
wmutate "unexercised: a nested dynamic segment kept" 's/split\("\."\) \| map\(select\(\. != "dynamic"\)\) \| join\("\."\)/sub("^dynamic\\\\."; "")/' t_unex_nested_dyn
wmutate "unexercised: a type the schema lacks requires nothing" 's/,\n         \(\$ty\[\] \| select\(IN\(\$have\[\]\) \| not\) \| "\\\(\.\)\.\*"\)//' t_unex_lacktype
wmutate "identical: an example that differs not blocking" 's/ and all\(\$el\[\]; has\("block"\) \| not\)//' t_pd_differs
wmutate "identical: the resource not consumed" 's/then any\(\$pa\[\]; \. == \$x \+ \$a\)/then true/' t_pd_consume
wmutate "identical: an example absent at the base kept" 's/if \$p\.reason == "absent-at-base" then empty/if false then empty/' t_pd_absent
wmutate "identical: partial coverage accepted" 's/\n           or \(\$l\.coverage\.class != "complete"\)//' t_pd_partial
wmutate "identical: an example with no addresses accepted" 's/and \(\.addresses \| type == "array" and length > 0 and length < 1000\)\) \| not\)/) | not)/' t_pd_noaddr
wmutate "identical: a variable not null by default read as one" 's/\(\[\{dir: \(\$t\.file \| tdir\), name: \$n\}\] - \$nv == \[\]\)/true/' t_pd_shape
wmutate "identical: any value shape" 's/else \$h == \("var\." \+ \$n\) end/else true end/' t_pd_wrap
wmutate "identical: any address for an argument" 's/  elif \(\$t\.address \| test\("\^\[a-z\][^\n]*\n/  elif true\n/' t_pd_call
wmutate "identical: a variable of any category" 's/ and \$t\.category == "unclassified-change"\n    and \(\(\$t\.also_categories \/\/ \[\]\) == \[\]\) and \$t\.levels == \[\] then "variable"/ and \$t.levels == [] then "variable"/' t_pd_type
wmutate "identical: the head module calls read for the base" 's/elif \$p\.result == "equal" then \(if calls\(\$p\.module_calls; \$d\) != \[\] then/elif \$p.result == "equal" then (if true then/' t_pd_base
wmutate "identical: an edited example with no plan diff ignored" 's/elif \$head or \$edited then/elif \$head then/' t_pd_edited
wmutate "identical: a trigger in an example directory marked" 's/\n           or any\(\$l\.coverage\.examples\[\]; \.dir as \$x \| \$d \| under\(\$x\)\)//' t_pd_inex
wmutate "identical: a variable with a level marked" 's/ and \$t\.levels == \[\] then "variable"/ then "variable"/' t_pd_valid
wmutate "identical: an argument at any level marked" 's/-\]\*\$"\)\) and \$t\.levels == \["L4"\]\n/-]*\$"))\n/' t_pd_l1
wmutate "identical: coverage with no head calls read" 's/\n           or \(any\(\$l\.coverage\.examples\[\]; \(\.module_calls \| type\) == "object" and \.module_calls != \{\}\) \| not\)//' t_pd_nocalls
wmutate "identical: a dynamic block over any variable" 's/any\(\$b\.triggers\[\]; \.address == \("var\." \+ \$n\).*?\(\.file \| tdir\) == \$d\)/true/s' t_pd_dynold
wmutate "identical: a dynamic block over a variable of another directory" 's/ and \(\.file \| tdir\) == \$d\)/)/' t_pd_dyndir
wmutate "identical: a nested dynamic block" 's/test\("\^dynamic\\\\\.\[A-Za-z_\]\[A-Za-z0-9_-\]\*\$"\)/true/' t_pd_dynnest
wmutate "identical: any for_each over the new variable" 's/      \| \$t\.head_expr == \("var\." \+ \$n\)\n/      | true\n/' t_pd_dynwrap
wmutate "identical: a dynamic block beside a removed block of its type" 's/\n      and \(any\(\$b\.triggers\[\]; \.address == \$t\.address and \.change_kind != "added".*?\| not\)\)/)/s' t_pd_dynstatic
wmutate "identical: a dynamic block beside an edited block of its type" 's/ and \.change_kind != "added"\n/ and .change_kind == "removed"\n/' t_pd_dynedit
wmutate "identical: a dynamic block over a new variable with a level" 's/ and \.levels == \[\] and \.declaration\.added == true/ and .declaration.added == true/' t_pd_dynfull
wmutate "identical: a dynamic block over a default that is not a literal" 's/ and \.declaration\.default == "literal"\n/\n/' t_pd_dyndecl
wmutate "identical: a dynamic block over a variable with no declaration" 's/ and \.declaration\.added == true and \.declaration\.default == "literal"/ and (.declaration == null or .declaration.default == "literal")/' t_pd_dynnodecl
wmutate "identical: a dynamic block over an object type" 's/\n    and \(\$t\.referenced_inputs\[0\] \| \.type \| type == "string" and test\("\^\[ \\\\t\]\*\(map\|list\|set\)\[ \\\\t\]\*\\\\\("\)\)//' t_pd_dynobj
wmutate "identical: a dynamic block beside a change with no attribute" 's/\(\.attribute \| type\) != "string" or /false or /' t_pd_dynnoattr
wmutate "identical: a dynamic block beside a change whose attribute is no string" 's/\(\.attribute \| type\) != "string" or /.attribute == null or /' t_pd_dynnumattr
wmutate "identical: a dynamic block at any level" 's/ and \$t\.levels == \["L4"\]\n    and \$t\.category == "dynamic-block-change"/\n    and \$t.category == "dynamic-block-change"/' t_pd_dynlvl
wmutate "identical: a dynamic block with merged categories" 's/ and \(\(\$t\.also_categories \/\/ \[\]\) == \[\]\) and \(\(\$b\.capped/ and ((\$b.capped/' t_pd_dynalso
wmutate "identical: a dynamic block over a declaration not added" 's/ and \.declaration\.added == true//' t_pd_dynnotadded
wmutate "identical: a dynamic block marked over the classifier cap" 's/ and \(\(\$b\.capped \/\/ 0\) == 0\)//' t_pd_dyncap
wmutate "identical: a dynamic block named like a meta-argument" 's/\n      and \(ltrimstr\("dynamic\."\) as \$m \| meta_args \| index\(\$m\) == null\)\)/)/' t_pd_dynmeta
wmutate "identical: diff-dirs without the variables the change adds" 's/\n  or \(\$t\.change_kind == "added" and \(\$t\.address \| type == "string" and test\("\^var[^\n]*\)\)\);/;/' t_pd_dirs
wmutate "identical: diff-dirs with a removed variable" 's/  or \(\$t\.change_kind == "added" and \(\$t\.address/  or ((true) and (\$t.address/' t_pd_dirs
wmutate "identical: a new resource read by its exact address" 's/then any\(\$pa\[\]; \. == \$x \+ \$a\)/then any(\$pa[]; . == \$x + \$a) elif \$k == "resource" then any(\$pa[]; . == \$x + \$a)/' t_pd_res
wmutate "identical: a gate that is neither count nor for_each" 's/ and \(\$t\.gate\.attribute \| IN\("count", "for_each"\)\)//' t_pd_resattr
wmutate "identical: a gate that reads a local" 's/    and \$t\.gate\.contextual_refs == \[\] and \$t\.gate\.pure == true/    and \$t.gate.pure == true/' t_pd_resctx
wmutate "identical: an impure gate" 's/ and \$t\.gate\.pure == true//' t_pd_respure
wmutate "identical: gate inputs that are no list" 's/\n    and \(\$t\.gate\.referenced_inputs \| type == "array" and length > 0\)//' t_pd_resnullin
wmutate "identical: a gate over any variable" 's/\(\.name as \$n\n        \| any\(\$b\.triggers\[\]; \.address == \("var\." \+ \$n\).*?\(\.file \| tdir\) == \$d\)\)/true/s' t_pd_resold
wmutate "identical: a gate over a variable with a level" 's/ and \.levels == \[\] and \.declaration\.added == true\n          and \(\.declaration\.default/ and .declaration.added == true\n          and (.declaration.default/' t_pd_reslvl
wmutate "identical: a gate over a default that is no literal" 's/\n          and \(\.declaration\.default \| IN\("null", "literal"\)\)/\n          and true/' t_pd_resdef
wmutate "identical: a gate over a declaration not added" 's/ and \.declaration\.added == true\n          and \(\.declaration\.default/\n          and (.declaration.default/' t_pd_resadded
wmutate "identical: a gate over a variable of another directory" 's/ and \(\.file \| type == "string"\) and \(\.file \| tdir\) == \$d\)\)\)\)/))))/' t_pd_resdir
wmutate "identical: a new resource at any address" 's/(  elif \(\$t\.address \| test\("\^\[a-z\]\[a-z0-9\]\*_\[a-z0-9_\]\+\\\\\.\[A-Za-z_\]\[A-Za-z0-9_-\]\*\$"\)\) and \$t\.levels == \["L4"\]\n    and \$t\.category == "resource-added-or-removed")/  elif \$t.levels == ["L4"]\n    and \$t.category == "resource-added-or-removed"/' t_pd_resdata
wmutate "identical: a new resource at any level" 's/\$t\.levels == \["L4"\]\n    and \$t\.category == "resource-added-or-removed"/true\n    and \$t.category == "resource-added-or-removed"/' t_pd_resl1
wmutate "identical: a gate on any category" 's/    and \$t\.category == "resource-added-or-removed" and/    and/' t_pd_rescat
wmutate "identical: a new resource with merged categories" 's/ and \$t\.category == "resource-added-or-removed" and \(\(\$t\.also_categories \/\/ \[\]\) == \[\]\)/ and \$t.category == "resource-added-or-removed"/' t_pd_resalso
wmutate "identical: a new resource marked over the classifier cap" 's/(\$t\.category == "resource-added-or-removed" and \(\(\$t\.also_categories \/\/ \[\]\) == \[\]\)) and \(\(\$b\.capped \/\/ 0\) == 0\)/$1/' t_pd_rescap
wmutate "identical: a gate that reads no variable" 's/\(\$t\.gate\.referenced_inputs \| type == "array" and length > 0\)/(\$t.gate.referenced_inputs | type == "array")/' t_pd_resnoin
wmutate "identical: a gate over a variable the change does not add" 's/\| any\(\$b\.triggers\[\]; \.address == \("var\." \+ \$n\) and \.change_kind == "added" and \.category/| any(\$b.triggers[]; .address == ("var." + \$n) and .category/' t_pd_reskind
wmutate "identical: a gate over a variable trigger of any category" 's/ and \.change_kind == "added" and \.category == "unclassified-change"\n          and \(\(\.also_categories/ and .change_kind == "added"\n          and ((.also_categories/' t_pd_resvcat
wmutate "identical: a gate over a variable trigger with merged categories" 's/\n          and \(\(\.also_categories \/\/ \[\]\) == \[\]\) and \.levels == \[\] and \.declaration\.added == true\n          and \(\.declaration\.default \| IN/\n          and .levels == [] and .declaration.added == true\n          and (.declaration.default | IN/' t_pd_resvalso
wmutate "identical: the list not sorted" 's/\| unique \| \.\[:20\]/| .[:20]/' t_pd_sort
wmutate "identical: the list not capped" 's/\| unique \| \.\[:20\]/| unique/' t_pd_cap
wmutate "identical: beside unexercised" 's/if \$i != \[\] and \(unex\(\$t; \$et\) \| not\) then \{identical/if \$i != [] then {identical/' t_pd_unex
wmutate "derive in the shared file returning its input" 's/  return \$o;\n\}/  return \$s;\n}/' t_wr_derived wrapper-derive.pl

# --- The split cap (behaviour.off-ladder-cap): with the feature, at most 40 triggers that may need
# evidence and 40 that no ladder level can verify; without it, at most 40 in all.
OFFC="provider-version-floor-change"
capcase() { # evidence count, off-ladder count [, jq update of each off-ladder trigger]; classify and eval; sets O
  setup
  jq -n --argjson e "$1" --argjson o "$2" '
    def tid: "T-\("00\(. + 1)" | .[-3:])";
    [range($e) | {file: "e\(.).tf", category: "literal-argument-change", levels: ["L4"]}]
    + [range($o) | {file: "o\(.).tf", category: "provider-version-floor-change", levels: ["compat"]}]
    | to_entries | map(.value + {id: (.key | tid), line: 1, change_kind: "modified"}) as $t
    | {schema_version: 1, inert: false, capped: 0, triggers: $t,
       entries: [$t[] | {path: .file, change_kind: "modified", inert: false, trigger_ids: [.id]}]}' > "$TMP/cap-b.json"
  jq ".triggers |= map(if .category == \"$OFFC\" then ${3:-.} else . end)" "$TMP/cap-b.json" > "$TMP/behaviour.out"
  [ -z "${RAWVER-}" ] || printf '%s\n' "$RAWVER" > "$TMP/features"
  jq '[.entries[] | {filename: .path, status: "modified"}]' "$TMP/behaviour.out" > "$TMP/files-cap.json"
  jq '{schema_version: 1, capped: 0, triggers: [.triggers[] | {id, state: "unverifiable"}], claims: [], discarded_claims: []}' "$TMP/behaviour.out" > "$TMP/eval.out"
  DIFF="$TMP/files-cap.json" classify; evalp
}
SPLIT="behaviour.off-ladder-cap"
t_cap80() { FEATS="$SPLIT" capcase 40 40; [ "$(head -n 1 "$O/classify.txt")" = "behaviour: ran, 80 triggers, 0 over the cap" ] && [ "$(q '.status == "ran" and (.triggers | length) == 80')" = 0 ]; }
t_cap80; check "split cap: 40 triggers that need evidence and 40 version floors classify and evaluate" $?
t_cap41e() { FEATS="$SPLIT" capcase 41 10; grep -qxF 'behaviour: not run: output refused' "$O/classify.txt"; }
t_cap41e; check "split cap: 41 triggers that need evidence are refused" $?
t_cap41o() { FEATS="$SPLIT" capcase 10 41; grep -qxF 'behaviour: not run: output refused' "$O/classify.txt"; }
t_cap41o; check "split cap: 41 version floors are refused" $?
for u in '.also_categories = ["literal-argument-change"]' '.follows = []' '.levels = ["compat", "L4"]' '.levels = []' '.category = "moved-or-renamed-address"'; do
  FEATS="$SPLIT" capcase 40 1 "$u"; grep -qxF 'behaviour: not run: output refused' "$O/classify.txt"
  check "split cap: a floor with $u counts toward the evidence cap" $?
done
t_cap_moved() { FEATS="$SPLIT" capcase 40 40 'if .id == "T-080" then .category = "moved-or-renamed-address" | .levels = [] else . end'; grep -qF 'behaviour: ran, 80 triggers' "$O/classify.txt"; }
t_cap_moved; check "split cap: a moved address that selects no level is off-ladder" $?
t_cap_nofeat() { capcase 40 1; grep -qxF 'behaviour: not run: output refused' "$O/classify.txt"; }
t_cap_nofeat; check "split cap: a binary without the feature keeps the cap of 40" $?
FEATS="behaviour.declarations" capcase 40 1; grep -qxF 'behaviour: not run: output refused' "$O/classify.txt"; check "split cap: features without off-ladder-cap keep the cap of 40" $?
grep -qxF 'version --json' "$TMP/facts.log"; check "split cap: classify reads the features with version --json" $?
t_cap_raw() { RAWVER="$1" capcase 40 1; grep -qxF 'behaviour: not run: output refused' "$O/classify.txt"; }
t_cap_raw 'not json'; check "split cap: version --json that is not JSON keeps the cap of 40" $?
t_cap_raw '{"features": "behaviour.off-ladder-cap"}'; check "split cap: features that are not a list keep the cap of 40" $?
t_cap_f() { FEATS="$SPLIT" capcase 40 1 '.follows = []'; grep -qxF 'behaviour: not run: output refused' "$O/classify.txt"; }
t_cap_a() { FEATS="$SPLIT" capcase 40 1 '.also_categories = ["literal-argument-change"]'; grep -qxF 'behaviour: not run: output refused' "$O/classify.txt"; }
t_cap_l() { FEATS="$SPLIT" capcase 40 1 '.levels = ["compat", "L4"]'; grep -qxF 'behaviour: not run: output refused' "$O/classify.txt"; }
t_cap_m() { FEATS="$SPLIT" capcase 40 1 '.category = "moved-or-renamed-address"'; grep -qxF 'behaviour: not run: output refused' "$O/classify.txt"; }
wmutate "split cap: a moved address at any level read as off-ladder" 's/\(\.category == "moved-or-renamed-address" and \.levels == \[\]\)/(.category == "moved-or-renamed-address")/' t_cap_m
wmutate "split cap: a follower read as off-ladder" 's/ and \(has\("follows"\) \| not\)\n/\n/' t_cap_f
wmutate "split cap: a merged floor read as off-ladder" 's/def off_ladder: \(has\("also_categories"\) \| not\) and /def off_ladder: /' t_cap_a
wmutate "split cap: a floor at any level read as off-ladder" 's/\.levels == \["compat"\]\)/true)/' t_cap_l
wmutate "split cap: the evidence cap dropped" 's/ and length - \$off <= 40//' t_cap41e
wmutate "split cap: the off-ladder cap dropped" 's/\$off <= 40 and //' t_cap41o
wmutate "split cap: the feature ignored" 's/ && split=true/ \&\& split=false/' t_cap80
wmutate "split cap: the split taken without the feature" 's/split=false decl=false/split=true decl=false/' t_cap_nofeat

# --- Variable facts from the report (behaviour.declarations and behaviour.schema-required): no
# tokenizer and no schema walk. The recorded classifier output gains the facts a binary with both
# features reports for these files: each variable trigger and referenced input its declaration, each
# resource trigger with an attribute its schema_required. On it the run object, the record and
# nullvars.json are byte for byte those of the tokenizer path.
DECL="behaviour.declarations behaviour.schema-required"
ENR='def d($n): {new_idle: {added: true, default: "null", nullable: "unset"}, new_on: {added: true, default: "literal", nullable: "unset"},
    old_existing: {added: false, default: "null", nullable: "unset"}, kms: {added: false, default: "null", nullable: "false"},
    create: {added: false, default: "literal", nullable: "unset"}}[$n];
  .triggers |= map(.referenced_inputs |= map(if d(.name) then .declaration = d(.name) else . end)
    | if (.address | test("^var\\.")) and d(.address | ltrimstr("var.")) then .declaration = d(.address | ltrimstr("var.")) else . end
    | if (.address | test("^aws_")) and (.attribute | type == "string")
      then .schema_required = (if .attribute | IN("idle_timeout", "dynamic.default_action", "port") then "not_required" else "unknown" end) else . end)'
# unexd [behaviour jq update after ENR]: unex with both features and the enriched output.
unexd() { FEATS="$DECL" unex . "$ENR | ${1:-.}" "${2:-.}"; }
t_decl_same() {
  unex; cp "$O/run-behaviour.json" "$TMP/decl-old-run.json"; cp "$O/record.txt" "$TMP/decl-old-record.txt"; cp "$O/nullvars.json" "$TMP/decl-old-nv.json"
  unexd && cmp -s "$O/run-behaviour.json" "$TMP/decl-old-run.json" && cmp -s "$O/record.txt" "$TMP/decl-old-record.txt" \
    && cmp -s "$O/nullvars.json" "$TMP/decl-old-nv.json" && [ "$(marked)" = '["T-008","T-014"]' ]
}
t_decl_same; check "declarations: the run object, the record and nullvars.json equal the tokenizer path's" $?
t_decl_path() { # the report path ran: the required list holds the trigger paths not reported not_required
  unexd && [ "$(cat "$O/required.json")" = "$(jq -c '[.[] | select(. != "aws_lb_listener.idle_timeout" and . != "aws_lb_listener.default_action" and . != "aws_lb_listener.port")]' <<< '["aws_db_instance.engine","aws_db_instance.kms_key_id","aws_db_instance.provider","aws_db_instance.storage_encrypted","aws_db_instance.timeouts","aws_lb_listener.alpn_policy","aws_lb_listener.force_destroy","aws_lb_listener.ssl_policy"]')" ]
}
t_decl_path; check "declarations: the required list is the trigger paths not reported not_required" $?
wmutate "declarations: a path of any block on the required list" 's/ and \(\.\[-2\] \| test\("\^\[a-z\]\[a-z0-9\]\*_\[a-z0-9_\]\+\$"\)\)\)/)/' t_decl_path
# The tokenizer is not run: a variables file it refuses (a comment in the block) still gives the entry.
t_decl_notok() {
  local keep="$UMOD"; UMOD="$TMP/unex-decl-head"; rm -rf "$UMOD"; cp -R "$keep" "$UMOD"
  perl -0pi -e 's/  type    = number\n  default = null/  type    = number # seconds\n  default = null/' "$UMOD/variables.tf"
  unex; local old; old="$(marked)"; unexd; UMOD="$keep"
  [ "$old" = '[]' ] && [ "$(marked)" = '["T-008","T-014"]' ]
}
t_decl_notok; check "declarations: the report decides, a block the tokenizer refuses is still read" $?
t_decl_follow() { unexd '.triggers |= map(if .id == "T-017" then .follows = ["T-008", "T-014"] else . end)' && [ "$(marked)" = '["T-008","T-014","T-017"]' ]; }
t_decl_follow; check "declarations: the variable's own trigger is marked when every trigger it follows is" $?
declno() { # jq update after ENR -> neither T-008 nor T-014 nor T-017 is marked
  unexd "$1 | .triggers |= map(if .id == \"T-017\" then .follows = [\"T-008\", \"T-014\"] else . end)" && [ "$(marked)" = '[]' ]
}
vt='.triggers |= map(if .id == "T-017" then'
declno "$vt del(.declaration) else . end)"; check "declarations: a variable with no declaration is not null" $?
declno "$vt .declaration.default = \"literal\" else . end)"; check "declarations: a literal default is not null" $?
declno "$vt .declaration.default = \"other\" else . end)"; check "declarations: another default expression is not null" $?
declno "$vt .declaration.default = null else . end)"; check "declarations: a JSON null default field is not the null default" $?
declno "$vt .declaration.nullable = \"true\" else . end)"; check "declarations: a nullable argument, even true, is not marked" $?
declno "$vt .declaration.added = false else . end)"; check "declarations: a variable the base has is not marked" $?
declno "$vt .declaration = \"null\" else . end)"; check "declarations: a declaration that is not an object is not marked" $?
t_decl_extra() { unexd "$vt .declaration.sensitive = false else . end)" && [ "$(marked)" = '["T-008","T-014"]' ]; }
t_decl_extra; check "declarations: an additive field in the declaration is ignored" $?
t_decl_req() { unexd '.triggers |= map(if .id == "T-008" then .schema_required = "required" else . end)' && [ "$(marked)" = '["T-014"]' ]; }
t_decl_req; check "declarations: a required attribute is not marked" $?
t_decl_unk() { unexd '.triggers |= map(if .id == "T-014" then .schema_required = "unknown" else . end)' && [ "$(marked)" = '["T-008"]' ]; }
t_decl_unk; check "declarations: schema_required unknown requires it" $?
t_decl_abs() { unexd '.triggers |= map(if .id == "T-008" then del(.schema_required) else . end)' && [ "$(marked)" = '["T-014"]' ]; }
t_decl_abs; check "declarations: no schema_required requires it" $?
t_decl_nos() { SCHEMA= FEATS="$DECL" unex . "$ENR" && [ "$(marked)" = '[]' ] && [ ! -e "$O/required.json" ]; }
t_decl_nos; check "declarations: with no schema nothing is marked" $?
t_decl_one() { FEATS="behaviour.declarations" unex . "$ENR" && [ "$(marked)" = '["T-008","T-014"]' ] && [ "$(cat "$O/required.json")" = '[]' ]; }
t_decl_one; check "declarations: declarations alone keep the tokenizer and the schema walk" $?
t_decl_dirs() { # a variable of a submodule keys its own directory
  unexd '.triggers |= map(if .id == "T-017" then .file = "modules/a/variables.tf" else . end)' && [ "$(cat "$O/nullvars.json")" = '[{"dir":"modules/a","name":"new_idle"}]' ] && [ "$(marked)" = '[]' ]
}
t_decl_dirs; check "declarations: a submodule's null variable keys its directory, so the root's arguments stay unmarked" $?
# A variable trigger the report describes as added with a null default, hostile in one input each:
# no entry in nullvars.json, so nothing is marked.
declhost() { # jq update of T-017 -> nullvars.json is empty
  unexd "$vt $1 else . end)" && [ "$(cat "$O/nullvars.json")" = '[]' ] && [ "$(marked)" = '[]' ]
}
t_decl_kind() { declhost '.change_kind = "modified"'; }
t_decl_addr() { declhost '.address = "var.9bad"'; }
t_decl_line() { declhost '.line = null'; }
t_decl_file() { declhost '.file = "v$.tf"'; }
t_decl_kind; check "declarations: a variable trigger the change did not add gives no entry" $?
t_decl_addr; check "declarations: an address that is no variable name gives no entry" $?
t_decl_line; check "declarations: a trigger with no line gives no entry" $?
t_decl_file; check "declarations: a file outside the plain .tf pattern gives no entry" $?
# Resource triggers of the enriched fixture the required list reads: one with no attribute, one with
# no address, and one at an indexed address whose key holds a dot.
XB='.triggers += [{id: "T-021", file: "main.tf", line: 9, category: "unclassified-change", change_kind: "modified", address: "aws_lb_listener.secondary", attribute: null,
    base_expr: null, head_expr: null, levels: ["L4"], referenced_inputs: [], contextual_refs: [], reason: null},
  {id: "T-022", file: "main.tf", line: 9, category: "unclassified-change", change_kind: "modified", address: null, attribute: "tcp_idle",
    base_expr: null, head_expr: null, levels: ["L4"], referenced_inputs: [], contextual_refs: [], reason: null},
  {id: "T-023", file: "main.tf", line: 9, category: "literal-argument-change", change_kind: "modified", address: "aws_lb_listener.keyed[\"a.b\"]", attribute: "zeta_attr",
    base_expr: null, head_expr: "1", levels: ["L4"], referenced_inputs: [], contextual_refs: [], reason: null, schema_required: "unknown"}]'
XE='.triggers += [range(21; 24) as $i | {id: "T-0\($i)", state: "unverifiable", reason: "x"}]'
t_decl_xreq() {
  unexd "$XB" "$XE" && [ "$(marked)" = '["T-008","T-014"]' ] \
    && [ "$(cat "$O/required.json")" = "$(jq -c '. + ["aws_lb_listener.zeta_attr"] | unique' <<< '["aws_db_instance.engine","aws_db_instance.kms_key_id","aws_db_instance.provider","aws_db_instance.storage_encrypted","aws_db_instance.timeouts","aws_lb_listener.alpn_policy","aws_lb_listener.force_destroy","aws_lb_listener.ssl_policy"]')" ]
}
t_decl_xreq; check "declarations: no attribute, no address and an indexed address are read from the report" $?
# A jq that fails on the required list leaves the list at everything.
t_decl_fb() {
  local real; real="$(command -v jq)"; mkdir -p "$TMP/jqfail"
  cat > "$TMP/jqfail/jq" <<EOF2
#!/bin/sh
case "\$*" in *'!= "not_required"'*) exit 5 ;; esac
exec "$real" "\$@"
EOF2
  chmod +x "$TMP/jqfail/jq"
  PATH="$TMP/jqfail:$PATH" unexd && [ "$(cat "$O/required.json")" = '["*"]' ] && [ "$(marked)" = '[]' ]
}
t_decl_fb; check "declarations: a required list that cannot be read requires everything" $?
t_decl_lit() { declno "$vt .declaration.default = \"literal\" else . end)"; }
t_decl_nul() { declno "$vt .declaration.nullable = \"true\" else . end)"; }
t_decl_add() { declno "$vt .declaration.added = false else . end)"; }
wmutate "declarations: the default not checked" 's/ and \.default == "null" and \.nullable == "unset"\)/ and .nullable == "unset")/' t_decl_lit
wmutate "declarations: nullable not checked" 's/ and \.default == "null" and \.nullable == "unset"\)/ and .default == "null")/' t_decl_nul
wmutate "declarations: added not checked" 's/\.declaration \| type == "object" and \.added == true and /.declaration | type == "object" and /' t_decl_add
wmutate "declarations: a variable the change did not add" 's/(decl_vars\(\) \{\n  jq -c .\[\.triggers\[\] \| select\()\.change_kind == "added" and /$1/' t_decl_kind
wmutate "declarations: the variable address pattern dropped" 's/(decl_vars\(\) \{\n  jq -c .\[\.triggers\[\] \| select\(\.change_kind == "added" and )\(\.address \| type == "string" and test\("[^"]*"\)\)\n      and /$1/' t_decl_addr
wmutate "declarations: the line check dropped" 's#\(\.line \| type == "number"\) and (\(\.file[^\n]*\n      and \(\.declaration)#$1#' t_decl_line
wmutate "declarations: the file pattern dropped" 's#(\(\.line \| type == "number"\)) and \(\.file[^\n]*(\n      and \(\.declaration)#$1$2#' t_decl_file
wmutate "declarations: a trigger with no attribute read" 's/ and \(\.attribute \| type == "string"\) and \.schema_required/ and .schema_required/' t_decl_xreq
wmutate "declarations: a trigger with no address read" 's/select\(\(\.address \| type == "string"\) and \(\.attribute/select((.attribute/' t_decl_xreq
wmutate "declarations: the index keys kept in the address" 's/\(\.address \| gsub\([^;]*; ""\) \| split/(.address | split/' t_decl_xreq
wmutate "declarations: an unreadable required list requires nothing" 's/("\$out\/behaviour\.json" > "\$out\/required\.json" 2> \/dev\/null \|\| printf )\x27\["\*"\]\\n\x27/$1\x27[]\\n\x27/' t_decl_fb
wmutate "declarations: unknown read as not required" 's/ and \.schema_required != "not_required"\)/ and .schema_required == "required")/' t_decl_unk
wmutate "declarations: the report path not taken" 's/if \[ "\$decl" = true \]; then decl_vars; else null_vars; fi/null_vars/' t_decl_notok
wmutate "declarations: one feature enough" 's/ && facts_has behaviour\.schema-required && decl=true/ \&\& decl=true/' t_decl_one

# --- Where the script runs from and where --out is.
# A colon in --out would split the PATH entry facts_features builds under it and could put another
# mtf-facts first: refused before anything runs.
t_colon() {
  local o="$TMP/colon:x"; rm -rf "$TMP/colon" "$o" "$TMP/decoy-ran"; mkdir -p "$TMP/colon" "$o"
  printf '#!/bin/sh\n: > "%s/decoy-ran"\nexit 2\n' "$TMP" > "$TMP/colon/mtf-facts"; chmod +x "$TMP/colon/mtf-facts"
  setup
  bash "$BP" classify --facts "$FACTS" --dir "$MOD" --diff "$TMP/files.json" --out "$o" > "$TMP/colon.txt" 2>&1; local st=$?
  [ "$st" = 2 ] && grep -q 'must not contain a colon' "$TMP/colon.txt" && [ ! -e "$TMP/decoy-ran" ]
}
t_colon; check "an --out path holding a colon is refused and no other mtf-facts runs" $?
wmutate "the colon in --out accepted" 's/case "\$out" in \*:\*\) die "--out must not contain a colon" ;; esac\n//' t_colon
# Started by a bare name, or with CDPATH naming a directory that holds a same-named subdirectory,
# the script reads facts-resolve.sh from its own directory.
bnsetup() { local d="$TMP/bn"; rm -rf "$d" "$TMP/cdp-decoy"; mkdir -p "$d" "$TMP/cdp-decoy/bn"; cp "$BP" "${BP%/*}/facts-resolve.sh" "${BP%/*}/wrapper-derive.pl" "${BP%/*}/module-files.jq" "$d/"; setup; }
t_bare() {
  bnsetup
  (cd "$TMP/bn" && bash behaviour-pass.sh classify --facts "$FACTS" --dir "$MOD" --diff "$TMP/files.json" --out "$O" 2>&1) | grep -qxF 'behaviour: ran, 2 triggers, 0 over the cap'
}
t_cdpath() {
  bnsetup
  (cd "$TMP" && CDPATH="$TMP/cdp-decoy" bash bn/behaviour-pass.sh classify --facts "$FACTS" --dir "$MOD" --diff "$TMP/files.json" --out "$O" 2>&1) | grep -qxF 'behaviour: ran, 2 triggers, 0 over the cap'
}
t_bare; check "started by a bare name the script reads facts-resolve.sh from its own directory" $?
t_cdpath; check "with CDPATH set the script reads facts-resolve.sh from its own directory" $?
wmutate "the script directory read through the script name" 's/HERE="\$\(CDPATH= cd -- "\$\(dirname -- "\$0"\)" && pwd -P\)"/HERE="\${0%\/*}"/' t_bare
wmutate "the script directory looked up through CDPATH" 's/CDPATH= cd -- /cd /' t_cdpath

# --- Caller code (behaviour-pass.md, Caller Code): the classifier marks a literal of an examples/ or
# tests/ file `caller_code` and claims-eval reads it as inert, after a refuted check. That reading
# holds only for a tree that is the whole repository: under a module root prefix a root configuration
# outside the tree may load the example, so the pass drops it and the trigger is unverifiable. A
# refuted trigger, an inert one the tool did not mark and a prefix of "" are as before.
CBEH='{"schema_version":1,"inert":false,
 "entries":[{"path":"examples/complete/main.tf","change_kind":"modified","inert":false,"trigger_ids":["T-001"]},
            {"path":"main.tf","change_kind":"modified","inert":false,"trigger_ids":["T-002"]},
            {"path":"tests/basic/main.tf","change_kind":"modified","inert":false,"trigger_ids":["T-003"]}],
 "triggers":[{"id":"T-001","file":"examples/complete/main.tf","line":3,"category":"literal-argument-change","caller_code":true},
  {"id":"T-002","file":"main.tf","line":2,"category":"literal-argument-change"},
  {"id":"T-003","file":"tests/basic/main.tf","line":4,"category":"literal-argument-change","caller_code":true}],"capped":0}'
CEV='{"schema_version":1,"capped":0,"triggers":[{"id":"T-001","state":"inert"},{"id":"T-002","state":"inert"},{"id":"T-003","state":"refuted"}],
 "claims":[],"discarded_claims":[]}'
CPFX=modules/sub
jq -n --arg p "$CPFX/" '[{filename: ($p + "examples/complete/main.tf"), status: "modified"}, {filename: ($p + "main.tf"), status: "modified"},
  {filename: ($p + "tests/basic/main.tf"), status: "modified"}]' > "$TMP/files-c-pfx.json"
jq 'map(.filename |= ltrimstr("modules/sub/"))' "$TMP/files-c-pfx.json" > "$TMP/files-c.json"
caller() { # prefix ("" for none) -> the eval of the caller code fixture, run object in $O
  setup; printf '%s\n' "$CBEH" > "$TMP/behaviour.out"; printf '%s\n' "$CEV" > "$TMP/eval.out"
  if [ -n "$1" ]; then DIFF="$TMP/files-c-pfx.json" PFX="$1" classify; evalp --prefix "$1"; else DIFF="$TMP/files-c.json" classify; evalp; fi
}
t_caller_none() { # no prefix: the tool's reading stands
  caller "" && [ "$(q '[.triggers[] | {id, state}] == [{id: "T-001", state: "inert"}, {id: "T-002", state: "inert"}, {id: "T-003", state: "refuted"}]')" = 0 ] \
    && grep -qxF 'trigger T-001 `examples/complete/main.tf` line 3 literal-argument-change: inert' "$O/record.txt"
}
t_caller_pfx() { # a prefix: the marked trigger is unverifiable, the unmarked inert one and the refuted one stay
  caller "$CPFX" && [ "$(q '[.triggers[] | {id, state}] == [{id: "T-001", state: "unverifiable"}, {id: "T-002", state: "inert"}, {id: "T-003", state: "refuted"}]')" = 0 ] \
    && grep -qxF 'trigger T-001 `examples/complete/main.tf` line 3 literal-argument-change: unverifiable' "$O/record.txt" \
    && ! grep -q '^change T-001' "$O/record.txt"
}
t_caller_empty() { # an empty prefix is no prefix
  setup; printf '%s\n' "$CBEH" > "$TMP/behaviour.out"; printf '%s\n' "$CEV" > "$TMP/eval.out"
  DIFF="$TMP/files-c.json" classify; evalp --prefix ""; [ "$(q '.triggers[0].state == "inert"')" = 0 ]
}
# The render of a change whose only trigger is caller code, with its example not planned: every
# trigger inert makes the change inert for plan coverage, so with no prefix it approves; under a
# prefix the trigger is unverifiable, the change is no longer inert, and the unplanned example is
# an unknown at rule 4.
t_caller_render() { # prefix -> the render message in RMSG; called directly, so the case counter moves on
  setup; jq -c '.entries |= .[:1] | .triggers |= .[:1]' <<< "$CBEH" > "$TMP/behaviour.out"; jq -c '.triggers |= .[:1]' <<< "$CEV" > "$TMP/eval.out"
  jq '.[:1]' "$TMP/files-c-pfx.json" > "$TMP/files-c-pfx1.json"; jq '.[:1]' "$TMP/files-c.json" > "$TMP/files-c1.json"
  if [ -n "$1" ]; then DIFF="$TMP/files-c-pfx1.json" PFX="$1" classify; evalp --prefix "$1"; else DIFF="$TMP/files-c1.json" classify; evalp; fi
  jq -e '.status == "ran"' "$O/run-behaviour.json" > /dev/null || return 1
  jq -n --slurpfile b "$O/run-behaviour.json" '{format: 1, triage: false, plan_ran: false, verify_gaps: [], behaviour: $b[0],
    coverage: {class: "partial", inert: false, unplanned: [{dir: "examples/complete", reason: "plan gate G1"}]},
    counts: {"instruction-like-text-from-others": 0, "conversation-claims-unread": 0, "review.quoted-claim-unverifiable": 0}}' > "$TMP/run-c.json"
  printf '[]\n' > "$TMP/findings-c.json"; local rd; rd="$(mktemp -d "$TMP/render-c.XXXXXX")"
  RMSG="$(bash "$RCU" --head "$HEAD" --findings "$TMP/findings-c.json" --host "$TMP/host.json" --checks "$TMP/checks" \
    --run "$TMP/run-c.json" --assessment "$TMP/assess.txt" --run-dir "$TMP/rundir" --out "$rd" 2>&1)"
}
t_caller_render_none() { t_caller_render "" && case "$RMSG" in "rendered approve (ladder rule 8),"*) ;; *) return 1 ;; esac; }
t_caller_render_pfx() { t_caller_render "$CPFX" && case "$RMSG" in "rendered not approved (ladder rule 4),"*) ;; *) return 1 ;; esac; }
# A caller_code that is not a boolean is refused, so a string or a number never leaves a trigger inert
# under a prefix.
t_caller_type() { # value of caller_code as JSON -> refused with a prefix
  setup; printf '%s\n' "$CBEH" | jq -c --argjson v "$1" '.triggers[0].caller_code = $v' > "$TMP/behaviour.out"; printf '%s\n' "$CEV" > "$TMP/eval.out"
  DIFF="$TMP/files-c-pfx.json" PFX="$CPFX" classify; evalp --prefix "$CPFX"
  jq -e '. == {status: "not-run", reason: "output refused", triggers: [], claims: [], capped: 0}' "$O/run-behaviour.json" > /dev/null 2>&1
}
t_caller_type_str() { t_caller_type '"true"'; }
t_caller_type_num() { t_caller_type '1'; }
t_caller_type_ok() { setup; printf '%s\n' "$CBEH" | jq -c '.triggers[0].caller_code = false' > "$TMP/behaviour.out"; printf '%s\n' "$CEV" > "$TMP/eval.out"
  DIFF="$TMP/files-c-pfx.json" PFX="$CPFX" classify; evalp --prefix "$CPFX"; [ "$(q '.status == "ran"')" = 0 ]; }
t_caller_type_str; check "caller code: a string caller_code is refused" $?
t_caller_type_num; check "caller code: a number caller_code is refused" $?
t_caller_type_ok; check "caller code: a boolean caller_code is accepted" $?
t_caller_none; check "caller code: with no prefix the tool's inert reading stands and a refuted trigger stays refuted" $?
t_caller_pfx; check "caller code: under a module root prefix the marked trigger is unverifiable, an unmarked inert one stays inert and a refuted one stays refuted" $?
t_caller_empty; check "caller code: an empty prefix is no prefix" $?
t_caller_render_none; check "caller code render: a change of caller code literals alone approves with no prefix" $?
t_caller_render_pfx; check "caller code render: the same change under a module root prefix is inconclusive at rule 4" $?
wmutate "caller code: the prefix not required" 's/if \$pre != "" and \.state == "inert" and \(first/if .state == "inert" and (first/' t_caller_none
wmutate "caller code: the inert state not required" 's/if \$pre != "" and \.state == "inert" and \(first/if \$pre != "" and (first/' t_caller_pfx
wmutate "caller code: every inert trigger dropped" 's/ and \(first\(\$b\.triggers\[\] \| select\(\.id == \$id\)\) \| \.caller_code == true\)\n/\n/' t_caller_pfx
wmutate "caller code: the type of the mark not checked" 's/\n        and \(\(has\("caller_code"\) \| not\) or \(\.caller_code \| type == "boolean"\)\)//' t_caller_type_str
wmutate "caller code: the drop never made" 's/if \$pre != "" and \.state == "inert" and/if false and \.state == "inert" and/' t_caller_render_pfx

# --- The merge base tree: classify with --diff and --base runs mtf-facts on the base tree first,
# and on the files list only when that run fails or its output is refused, as a classify given
# --diff alone would. --stats reaches mtf-facts as --stats-file only when the binary lists the flag.
BT="$TMP/basetree"; mkdir -p "$BT"
bclassify() { # extra arguments
  bash "$BP" classify --facts "$FACTS" --dir "$MOD" --diff "$TMP/files.json" --base "$BT" "$@" --out "$O" > "$O/classify.txt" 2>&1
}
t_base_ok() {
  FEATS="flag:behaviour:stats-file" setup; bclassify --stats "$O/st.json"
  [ -f "$O/behaviour.json" ] && [ "$(cat "$O/input")" = base ] &&
    grep -qxF "behaviour $MOD --base $BT --stats-file $O/st.json --json" "$TMP/facts.log" &&
    ! grep -q -- "--diff" "$TMP/facts.log" && [ -f "$O/st.json" ]
}
t_base_fail() {
  FEATS="flag:behaviour:stats-file" setup; echo 2 > "$TMP/base.rc"; bclassify --stats "$O/st.json"
  [ -f "$O/behaviour.json" ] && [ ! -e "$O/status" ] && [ "$(cat "$O/input")" = "diff (base mtf-facts failed)" ] &&
    grep -qxF "behaviour $MOD --diff $O/files-module.json --stats-file $O/st.diff.json --json" "$TMP/facts.log" &&
    cmp -s <(jq -S . "$O/behaviour.json") <(jq -S . "$TMP/behaviour-556.json")
}
t_base_refused() { # a base report that leaves a changed file out is refused, and the files list runs
  setup; jq '.entries = [] | .triggers = []' "$TMP/behaviour-556.json" > "$TMP/base.out"; bclassify
  [ "$(cat "$O/input")" = "diff (base output refused)" ] && [ "$(jq '.triggers | length' "$O/behaviour.json")" = 2 ]
}
t_base_both() {
  setup; echo 2 > "$TMP/base.rc"; echo 2 > "$TMP/behaviour.rc"; bclassify
  [ "$(cat "$O/status")" = "mtf-facts failed" ] && [ ! -e "$O/behaviour.json" ] && [ "$(cat "$O/input")" = "diff (base mtf-facts failed)" ]
}
t_base_alone() { # --base alone keeps its fixed reason, with no fallback
  setup; echo 2 > "$TMP/base.rc"; bash "$BP" classify --facts "$FACTS" --dir "$MOD" --base "$BT" --out "$O" > /dev/null 2>&1
  [ "$(cat "$O/status")" = "mtf-facts failed" ] && [ "$(grep -c '^behaviour' "$TMP/facts.log")" = 1 ]
}
t_stats_nofeat() { setup; bclassify --stats "$O/st.json"; [ -f "$O/behaviour.json" ] && ! grep -q -- "--stats-file" "$TMP/facts.log"; }
t_eval_stats() {
  FEATS="flag:claims-eval:stats-file" setup; classify; evalp --claims "$TMP/claims-556.json" --stats "$O/ev.json"
  [ "$(q '.status == "ran"')" = 0 ] && grep -q -- "^claims-eval .* --stats-file $O/ev.json --json$" "$TMP/facts.log"
}
t_eval_nofeat() { setup; classify; evalp --claims "$TMP/claims-556.json" --stats "$O/ev.json"; [ "$(q '.status == "ran"')" = 0 ] && ! grep -q -- "--stats-file" "$TMP/facts.log"; }
t_base_ok; check "base tree: classify runs on the merge base tree first, with the stats file, and not on the files list" $?
t_base_fail; check "base tree: a failed base run falls back to the files list, with its own stats file, as with --diff alone" $?
t_base_refused; check "base tree: a base report that leaves a changed file out falls back to the files list" $?
t_base_both; check "base tree: both runs failed keep the files list run's fixed reason" $?
t_base_alone; check "base tree: --base alone has no fallback" $?
t_stats_nofeat; check "stats: no --stats-file for a binary that does not list the flag" $?
t_eval_stats; check "stats: eval passes --stats-file to claims-eval when the binary lists the flag" $?
t_eval_nofeat; check "stats: eval passes no --stats-file without the flag" $?
setup; bash "$BP" classify --facts "$FACTS" --dir "$MOD" --diff "$TMP/files.json" --stats st.json --out "$O" > /dev/null 2>&1
check "stats: a relative --stats is a usage error" "$([ $? = 2 ] && [ ! -e "$O/input" ]; echo $?)"
# A committed .terraform file is a change: a report that leaves it out is refused, one that lists it kept.
jq '. + [{filename: ".terraform/modules/m/main.tf", status: "modified", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-a\n+b"}]' "$TMP/files.json" > "$TMP/files-tf.json"
t_tf_cover() {
  setup; DIFF="$TMP/files-tf.json" classify; [ "$(cat "$O/status" 2> /dev/null)" = "output refused" ] || return 1
  setup; jq '.entries += [{path: ".terraform/modules/m/main.tf", change_kind: "modified", inert: true, trigger_ids: []}]' "$TMP/behaviour-556.json" > "$TMP/behaviour.out"
  DIFF="$TMP/files-tf.json" classify; [ -f "$O/behaviour.json" ]
}
t_tf_cover; check "covers: a committed .terraform file left out of the report is refused, and kept when listed" $?
wmutate "covers: the skip of .git and .terraform paths restored" 's/\| \.filename, \(\.previous_filename \/\/ empty\)\]\n     - \[\$o\.entries/| .filename, (.previous_filename \/\/ empty) | select(test("(^|\/)\\\\.(git|terraform)(\/|\$)") | not)]\n     - [\$o.entries/' t_tf_cover
# The old path of a rename alone: the triggers name only new.tf, so covers is the one check that can
# refuse a report with no entry at main.tf.
t_ren_old() {
  setup; jq '[.[0] + {filename: "new.tf", previous_filename: "main.tf", status: "renamed"}]' "$TMP/files.json" > "$TMP/files-ren.json"
  jq '.entries = [{path: "new.tf", change_kind: "renamed", inert: false, trigger_ids: ["T-001", "T-002"]}] | .triggers |= map(.file = "new.tf")' \
    "$TMP/behaviour-556.json" > "$TMP/behaviour.out"
  DIFF="$TMP/files-ren.json" classify; [ "$(cat "$O/status" 2> /dev/null)" = "output refused" ]
}
t_ren_old; check "covers: a report with no entry at the old path of a rename is refused" $?
wmutate "covers: the old path of a rename dropped" 's/\| \.filename, \(\.previous_filename \/\/ empty\)\]\n     - \[\$o\.entries/| .filename]\n     - [\$o.entries/' t_ren_old
# A rename across the module root (module-files.jq): out of it, the module loses the file, a removed
# file at its old path that classify must cover; into it, an added file; neither keeps the patch or the
# line counts of the rename. A copy out of the module root changes nothing and is left out, and an
# explicit null previous_filename is no rename.
jq -n '[{filename: "mod/main.tf", status: "modified", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-a\n+b"},
  {filename: "other/vars.tf", previous_filename: "mod/vars.tf", status: "renamed", additions: 0, deletions: 0},
  {filename: "mod/in.tf", previous_filename: "other/in.tf", status: "renamed", additions: 0, deletions: 0, patch: "@@ -1 +1 @@\n-a\n+b"},
  {filename: "other/cp.tf", previous_filename: "mod/cp.tf", status: "copied", additions: 0, deletions: 0},
  {filename: "mod/nul.tf", previous_filename: null, status: "modified", additions: 1, deletions: 0, patch: "@@ -0,0 +1 @@\n+a"}]' > "$TMP/files-cross.json"
CROSS_WANT='[{filename: "main.tf", status: "modified", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-a\n+b"},
  {filename: "vars.tf", status: "removed"}, {filename: "in.tf", status: "added"},
  {filename: "nul.tf", status: "modified", additions: 1, deletions: 0, patch: "@@ -0,0 +1 @@\n+a"}]'
cross_report() { # extra entries JSON -> the stub report: the triggers of the replay plus the entries
  jq '.entries += [{path: "in.tf", change_kind: "added", inert: true, trigger_ids: []},
    {path: "nul.tf", change_kind: "modified", inert: true, trigger_ids: []}] + '"$1" "$TMP/behaviour-556.json" > "$TMP/behaviour.out"
}
t_ren_list() { setup; cross_report '[]'; DIFF="$TMP/files-cross.json" PFX=mod classify; jq -e ". == $CROSS_WANT" "$TMP/diff-seen.json" > /dev/null; }
t_ren_out() {
  # A report with no entry for the removed file is refused: the loss can never pass as inert.
  setup; cross_report '[]'; DIFF="$TMP/files-cross.json" PFX=mod classify
  [ "$(cat "$O/status" 2> /dev/null)" = "output refused" ] || return 1
  setup; cross_report '[{path: "vars.tf", change_kind: "removed", inert: false, trigger_ids: ["T-002"]}]'
  DIFF="$TMP/files-cross.json" PFX=mod classify; [ -f "$O/behaviour.json" ] && jq -e '.inert == false' "$O/behaviour.json" > /dev/null
}
# An inert report from the files list beside a removed Terraform file with no patch is refused, as a
# pure move out of the module root gives; the same report from the merge base tree is kept.
t_rm_inert() {
  setup; cross_report '[{path: "vars.tf", change_kind: "removed", inert: true, trigger_ids: []}]'
  jq '.inert = true | .triggers = [] | .entries |= map(.trigger_ids = [] | .inert = true)' "$TMP/behaviour.out" > "$TMP/b.t" && mv "$TMP/b.t" "$TMP/behaviour.out"
  DIFF="$TMP/files-cross.json" PFX=mod classify; [ "$(cat "$O/status" 2> /dev/null)" = "output refused" ]
}
t_rm_base() {
  setup; cross_report '[{path: "vars.tf", change_kind: "removed", inert: true, trigger_ids: []}]'
  jq '.inert = true | .triggers = [] | .entries |= map(.trigger_ids = [] | .inert = true)' "$TMP/behaviour.out" > "$TMP/base.out"
  mkdir -p "$TMP/basetree-mod"
  bash "$BP" classify --facts "$FACTS" --dir "$MOD" --diff "$TMP/files-cross.json" --prefix mod --base "$TMP/basetree-mod" --out "$O" > /dev/null 2>&1
  [ "$(cat "$O/input" 2> /dev/null)" = base ] && jq -e '.inert == true' "$O/behaviour.json" > /dev/null 2>&1
}
t_ren_list; check "prefix: a rename across the module root reads as a removal or an addition, a copy out is left out and a null previous_filename is no rename" $?
t_ren_out; check "prefix: a rename out of the module root is a removed file classify must cover" $?
t_rm_inert; check "prefix: an inert report from the files list beside a removed file with no patch is refused" $?
t_rm_base; check "prefix: the same inert report from the merge base tree is kept" $?
wmutate "prefix: a rename out of the module root dropped" 's/elif \$o != null and \.status == "renamed" then/elif false then/' t_ren_out module-files.jq
wmutate "prefix: a rename into the module root kept as a rename" 's/elif \$n != null then del\(\.previous_filename, \.patch, \.additions, \.deletions, \.changes\) \| \.filename = \$n \| \.status = "added"/elif \$n != null then .filename = \$n/' t_ren_list module-files.jq
wmutate "prefix: the line counts of a removal kept" 's/del\(\.previous_filename, \.patch, \.additions, \.deletions, \.changes\) \| \.filename = \$o/del(.previous_filename, .patch) | .filename = \$o/' t_ren_list module-files.jq
wmutate "prefix: a copy out of the module root read as a removal" 's/elif \$o != null and \.status == "renamed" then/elif \$o != null then/' t_ren_list module-files.jq
wmutate "prefix: a null previous_filename read as a rename" 's/if \$n != null and \(\$mv \| not\) then/if \$n != null and (has("previous_filename") | not) then/' t_ren_list module-files.jq
wmutate "prefix: the inert guard for a removed file with no patch dropped" 's/\(\$in != "diff" or \$d == \[\] or \(\[/(true or ([/' t_rm_inert
wmutate "prefix: the inert guard applied to the merge base tree too" 's/\(\$in != "diff" or \$d == \[\] or \(\[/(\$d == [] or ([/' t_rm_base
# The guard reads the removed file's own entry: a sibling trigger that makes the report not inert
# leaves an inert entry for the removed file refused, and an empty patch is no patch.
t_rm_sib() {
  setup; cross_report '[{path: "vars.tf", change_kind: "removed", inert: true, trigger_ids: []}]'
  DIFF="$TMP/files-cross.json" PFX=mod classify
  jq -e '.inert == false' "$TMP/behaviour.out" > /dev/null && [ "$(cat "$O/status" 2> /dev/null)" = "output refused" ]
}
t_rm_empty() {
  # A file GitHub lists as removed with an empty patch, as it does for a file too large to diff.
  jq 'map(if .filename == "other/vars.tf" then {filename: "mod/vars.tf", status: "removed", additions: 0, deletions: 0, patch: ""} else . end)' \
    "$TMP/files-cross.json" > "$TMP/files-cross-e.json"
  setup; cross_report '[{path: "vars.tf", change_kind: "removed", inert: true, trigger_ids: []}]'
  DIFF="$TMP/files-cross-e.json" PFX=mod classify; [ "$(cat "$O/status" 2> /dev/null)" = "output refused" ]
}
t_rm_sib; check "prefix: a removed file with no patch whose own entry is inert is refused beside a sibling trigger" $?
t_rm_empty; check "prefix: an empty patch on a removed file is no patch" $?
wmutate "prefix: the guard back to the top-level inert only" 's/\| \[\.entries\[\] \| select\(\[\.path, \(\.previous_path \/\/ empty\)\] - \$rm != \[\.path, \(\.previous_path \/\/ empty\)\]\) \| select\(\.inert == true or \(\.trigger_ids \| length\) == 0\)\] == \[\]\)\)/| (.inert != true or \$rm == [])))/' t_rm_sib
# The guard also finds the removed file by an entry's previous_path, reads a patch that is no string
# as no patch, and a prefix with an empty segment or a second trailing slash is refused.
t_rm_prev() {
  setup; cross_report '[{path: "kept.tf", previous_path: "vars.tf", change_kind: "renamed", inert: true, trigger_ids: []}]'
  DIFF="$TMP/files-cross.json" PFX=mod classify; [ "$(cat "$O/status" 2> /dev/null)" = "output refused" ]
}
t_rm_nonstr() {
  jq 'map(if .filename == "other/vars.tf" then {filename: "mod/vars.tf", status: "removed", additions: 0, deletions: 0, patch: {}} else . end)' \
    "$TMP/files-cross.json" > "$TMP/files-cross-n.json"
  setup; cross_report '[{path: "vars.tf", change_kind: "removed", inert: true, trigger_ids: []}]'
  DIFF="$TMP/files-cross-n.json" PFX=mod classify; [ "$(cat "$O/status" 2> /dev/null)" = "output refused" ]
}
t_pfx_dslash() { local p; for p in mod// a//b; do setup; DIFF="$TMP/files-cross.json" PFX="$p" classify
  [ $? = 2 ] && [ ! -e "$O/input" ] || return 1; done; }
t_rm_prev; check "prefix: the guard finds a removed file by an entry's previous_path" $?
t_rm_nonstr; check "prefix: a patch that is no string is no patch" $?
t_pfx_dslash; check "prefix: a prefix with an empty segment or two trailing slashes is a usage error" $?
wmutate "prefix: the guard reads only an entry's path" 's/select\(\[\.path, \(\.previous_path \/\/ empty\)\] - \$rm != \[\.path, \(\.previous_path \/\/ empty\)\]\)/select([.path] - \$rm != [.path])/' t_rm_prev
wmutate "prefix: a patch that is no string read as a patch" 's/\(\(\.patch \/\/ ""\) \| type != "string" or \. == ""\)/((.patch \/\/ "") == "")/' t_rm_nonstr
wmutate "prefix: an empty prefix segment taken" 's/ \| \*\/\/\* \| \*\/\) die "--prefix/) die "--prefix/' t_pfx_dslash

wmutate "prefix: an empty patch read as a patch" 's/\(\(\.patch \/\/ ""\) \| type != "string" or \. == ""\)/((.patch \/\/ "") | type != "string")/' t_rm_empty
# A trailing slash on the prefix is the same module root; an empty or a non-rename previous_filename
# is no rename.
t_pfx_slash() { setup; cross_report '[{path: "vars.tf", change_kind: "removed", inert: false, trigger_ids: ["T-002"]}]'
  DIFF="$TMP/files-cross.json" PFX=mod/ classify; jq -e ". == $CROSS_WANT" "$TMP/diff-seen.json" > /dev/null; }
t_prev_odd() {
  jq -n '[{filename: "mod/main.tf", status: "modified", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-a\n+b"},
    {filename: "mod/e.tf", previous_filename: "", status: "renamed", additions: 0, deletions: 0},
    {filename: "mod/m.tf", previous_filename: "other/m.tf", status: "modified", additions: 0, deletions: 0}]' > "$TMP/files-odd.json"
  setup; jq '.entries += [{path: "e.tf", change_kind: "renamed", inert: true, trigger_ids: []}, {path: "m.tf", change_kind: "modified", inert: true, trigger_ids: []}]' \
    "$TMP/behaviour-556.json" > "$TMP/behaviour.out"
  DIFF="$TMP/files-odd.json" PFX=mod classify
  jq -e '. == [{filename: "main.tf", status: "modified", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-a\n+b"},
    {filename: "e.tf", status: "renamed", additions: 0, deletions: 0}, {filename: "m.tf", status: "modified", additions: 0, deletions: 0}]' "$TMP/diff-seen.json" > /dev/null
}
t_pfx_slash; check "prefix: a trailing slash on the prefix gives the same module files list" $?
t_prev_odd; check "prefix: an empty previous_filename or one on a status that is no rename is no rename" $?
wmutate "prefix: the trailing slash kept in classify" 's/  prefix="\$\{prefix%\/\}" # a trailing slash names the same module root\n//' t_pfx_slash
wmutate "prefix: any previous_filename read as a rename" 's/\(\(\.status \| IN\("renamed", "copied"\)\) and \(\(\.previous_filename \/\/ ""\) \| type == "string" and \. != ""\)\)/((.previous_filename \/\/ null) != null)/' t_prev_odd module-files.jq
wmutate "base tree: the base never run" 's/    if \[ -n "\$base" \]; then\n      why=/    if false; then\n      why=/' t_base_ok
wmutate "base tree: no fallback after a failed base run" 's/if \[ -n "\$diff" \] && \[ "\$why" != ok \]; then/if [ -n "\$diff" ] && [ -z "\$base" ]; then/' t_base_fail
wmutate "base tree: the base report not checked" 's/ok\) if jq -e --slurpfile d "\$cover"/ok) if true || jq -e --slurpfile d "\$cover"/' t_base_refused
wmutate "stats: passed without the feature" 's/\[ -z "\$stats" \] \|\| ! facts_has flag:behaviour:stats-file \|\| st=/[ -z "\$stats" ] || st=/' t_stats_nofeat
wmutate "stats: eval passed without the feature" 's/! facts_has flag:claims-eval:stats-file \|\| set --/set --/' t_eval_nofeat

echo
if [ "$fails" -eq 0 ]; then echo "behaviour pass: all checks hold"; else echo "behaviour pass: $fails failed"; exit 1; fi
