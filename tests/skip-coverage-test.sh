#!/bin/bash
# shellcheck disable=SC2319 # "$(<test>; echo $?)" passes the test's own status to check
# Self-check for the covered skip script of terraform-module-pr-review, run under bash and
# under zsh, on a synthetic module in a git repository built here: the allow-list, the base and
# head gate records, the witnesses, each reason, the refused inputs, and a negative self-check
# that mutates temp copies of the script. No network, no terraform.
# Run: tests/skip-coverage-test.sh
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
REF="$SRC/.agents/skills/terraform-module-pr-review/references"
SC="$REF/skip-coverage.sh" # the script under test; the self-check swaps in mutated copies
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/skip-coverage-test.XXXXXX")" && pwd -P)" && [ -n "$TMP" ] || { echo "FAIL no temporary directory"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
fails=0
SH=bash

check() { # name, command status (0 = holds)
  if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

# --- The synthetic module: a root module, one submodule, a wrapper, six examples that plan and
# three that a G3 hit (a data source outside the gate list) keeps from planning.
RUN="$(mktemp -d "$TMP/pr-review.XXXXXX")"
C="$RUN/clone"
mkdir -p "$C/modules/sub" "$C/wrappers"
G() { git -C "$C" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"; }
cat > "$C/main.tf" <<'EOF'
resource "aws_security_group" "this" {
  count = var.create ? 1 : 0
  name  = var.name
}

resource "aws_lb" "this" {
  name            = var.name
  security_groups = compact(concat(aws_security_group.this[*].id, var.security_groups))
  subnets         = var.subnets
  tags            = var.tags

  access_logs {
    bucket  = var.log_bucket
    enabled = true
  }

  lifecycle {
    ignore_changes = [tags]
  }
}

data "aws_iam_policy_document" "this" {
  statement {
    actions = ["s3:GetObject"]
  }
}

module "listener" {
  source = "./modules/sub"
  port   = 80
}

locals {
  name = var.name
}

output "arn" {
  value = aws_lb.this.arn
}
EOF
cat > "$C/variables.tf" <<'EOF'
variable "name" {
  type    = string
  default = "x"
}
EOF
cat > "$C/versions.tf" <<'EOF'
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}
EOF
cat > "$C/modules/sub/main.tf" <<'EOF'
resource "aws_lb_listener" "this" {
  port     = var.port
  protocol = "HTTP"
}
EOF
printf 'module "wrapper" {\n  source = "../"\n}\n' > "$C/wrappers/main.tf"
printf '# Module\n\nText.\n' > "$C/README.md"
mkdir -p "$C/modules/other"
printf 'resource "aws_sns_topic" "this" {\n  name = var.name\n}\n' > "$C/modules/other/main.tf"
for e in e1 e2 e3 e4 e5 e6; do
  mkdir -p "$C/examples/$e"
  printf 'module "lb" {\n  source = "../../"\n}\n' > "$C/examples/$e/main.tf"
done
printf 'module "sub" {\n  source = "../../modules/sub"\n}\n' >> "$C/examples/e5/main.tf"
# examples/d1 is clean in the clone scope; the downloaded-hit cases record a hit in a downloaded module for it
mkdir -p "$C/examples/d1"
printf 'module "lb" {\n  source = "../../"\n}\n' > "$C/examples/d1/main.tf"
printf '# Example\n' > "$C/examples/d1/README.md"
for e in s1 s2 s3; do
  mkdir -p "$C/examples/$e"
  printf 'module "lb" {\n  source = "../../"\n}\n\ndata "aws_ssm_parameter" "p" {\n  name = "x"\n}\n' > "$C/examples/$e/main.tf"
  printf '# Example\n' > "$C/examples/$e/README.md"
done
printf 'module "other" {\n  source = "../../modules/other"\n}\n' >> "$C/examples/s2/main.tf"
G init -q && G add -A && G commit -qm base
BASE="$(G rev-parse HEAD)"
G worktree add -q --detach "$RUN/base" "$BASE"
G checkout -q --detach "$BASE"

fresh() { G checkout -q -f --detach "$BASE"; G clean -qfdx; }
commit() { G add -A; G commit -qm head; HEAD="$(G rev-parse HEAD)"; }
ed() { perl -0pi -e "$2" "$C/$1"; } # file, perl substitution

# files.json as the files endpoint gives it, from git: status, previous_filename, patch
filesjson() {
  G diff --name-status -M "$BASE" "$HEAD" | while IFS="$(printf '\t')" read -r st a b; do
    case "$st" in
      M) jq -n --arg f "$a" --arg p "$(G diff -U3 "$BASE" "$HEAD" -- "$a" | sed -n '/^@@/,$p')" '{filename: $f, status: "modified", patch: $p}' ;;
      A) jq -n --arg f "$a" '{filename: $f, status: "added", patch: "@@ -0,0 +1 @@\n+x"}' ;;
      D) jq -n --arg f "$a" '{filename: $f, status: "removed"}' ;;
      R*) jq -n --arg f "$b" --arg o "$a" '{filename: $f, previous_filename: $o, status: "renamed"}' ;;
    esac
  done | jq -s . > "$TMP/files.json"
}

# The plan record of a laptop pass, the coverage and the addresses files. Planned examples first,
# then the three skipped ones with the first hit the real gates print for them.
EX="examples/e1 examples/e2 examples/e3 examples/e4 examples/e5 examples/e6 examples/s1 examples/s2 examples/s3"
hits_of() { printf '%s\n' "$C/$1/main.tf" | bash "$REF/plan-pass.sh" gates "$RUN" laptop clone | sed -n "s|^\(G[0-3]\) $C/\(.*\)|\1 \2|p"; }
DLHITS="G3 downloaded/vpc/main.tf:11"; DLPLAN="plan gate G3 downloaded/vpc/main.tf:11 (1 hits)"
ADDRJQ=.
records() {
  rm -rf "$TMP/addr"; mkdir -p "$TMP/addr"
  { echo "plan pass mode: laptop"; i=0
    for e in $(printf '%s\n' $EX); do
      i=$((i + 1)); echo "example: $e"
      case "$e" in
        examples/s*) h="$(hits_of "$e")"; printf '%s\n' "$h" | sed 's/^/gate-hit /'
           echo "plan: plan gate $(printf '%s\n' "$h" | head -n 1) ($(printf '%s\n' "$h" | grep -c .) hits)" ;;
        examples/d*) printf '%s\n' "$DLHITS" | sed 's/^/gate-hit /'; echo "plan: $DLPLAN" ;;
        *) echo "plan: planned | Plan: 3 to add, 0 to change, 0 to destroy."
           jq -n --arg h "$HEAD" --arg e "$e" '
             {addresses: ["module.lb.aws_lb.this", "module.lb.aws_security_group.this", "module.lb.module.listener.aws_lb_listener.this"],
              attributes: {"module.lb.aws_lb.this": ["name", "security_groups", "subnets", "tags"],
                           "module.lb.aws_security_group.this": ["name"],
                           "module.lb.module.listener.aws_lb_listener.this": ["port", "protocol"]},
              module_calls: {lb: "../../"},
              sensitive: {"module.lb.aws_lb.this": [], "module.lb.aws_security_group.this": [],
                          "module.lb.module.listener.aws_lb_listener.this": []},
              head_sha: $h}
             | if $e == "examples/e5" then .addresses += ["module.sub.aws_lb_listener.this"]
                 | .attributes["module.sub.aws_lb_listener.this"] = ["port", "protocol"]
                 | .sensitive["module.sub.aws_lb_listener.this"] = []
                 | .module_calls.sub = "../../modules/sub" else . end
             | '"$ADDRJQ" > "$TMP/addr/addresses-$i.json" ;;
      esac
    done
    echo "plan summary: 9 examples, 6 planned, 0 exceptions, 3 other"; } > "$TMP/record.txt"
}
COVJQ=.
coverage() {
  jq -n '{schema_version: 1, class: "partial", inert: false,
          unplanned: [{dir: "examples/s1", reason: "plan gate G3"}, {dir: "examples/s2", reason: "plan gate G3"},
                      {dir: "examples/s3", reason: "plan gate G3"}]} | '"$COVJQ" > "$TMP/coverage.json"
}
# One case: the head committed, then the base gate record, then check.
GATES=1
run_case() {
  commit; filesjson; records; coverage
  rm -f "$TMP/base-gates.txt"
  [ "$GATES" = 1 ] && "$SH" "$SC" gates "$RUN" --tree "$RUN/base" --base "$BASE" --coverage "$TMP/coverage.json" --out "$TMP/base-gates.txt"
  [ -n "${BGEDIT:-}" ] && perl -0pi -e "$BGEDIT" "$TMP/base-gates.txt"
  "$SH" "$SC" check "$RUN" --files "$TMP/files.json" --coverage "$TMP/coverage.json" --plan "$TMP/record.txt" \
    --addresses "$TMP/addr" --base-gates "$TMP/base-gates.txt" --head "$HEAD" --base "$BASE" > "$TMP/out.json"
}
reset_knobs() { ADDRJQ=.; COVJQ=.; GATES=1; BGEDIT=; DLHITS="G3 downloaded/vpc/main.tf:11"; DLPLAN="plan gate G3 downloaded/vpc/main.tf:11 (1 hits)"; }
q() { jq -e "$1" "$TMP/out.json" > /dev/null 2>&1; echo $?; }
why() { jq -r --arg d "$1" '(.uncovered[] | select(.dir == $d) | .why) // (if any(.covered[]; .dir == $d) then "covered" else "absent" end)' "$TMP/out.json"; }
all_why() { [ "$(why examples/s1)" = "$1" ] && [ "$(why examples/s2)" = "$1" ] && [ "$(why examples/s3)" = "$1" ]; }
# The change the cases build on: one root attribute, concat/compact, as a plain expression change
plain_change() { ed main.tf 's/compact\(concat\((aws_security_group\.this\[\*\]\.id, var\.security_groups)\)\)/concat($1)/'; }

t_covered() {
  fresh; reset_knobs; plain_change; run_case || return 1
  all_why covered && jq -e --arg h "$HEAD" --arg b "$BASE" '.format == 1 and .head_sha == $h and .base_sha == $b
    and (.uncovered == []) and ([.covered[] | .gate] == ["G3", "G3", "G3"])
    and ([.covered[].path] == ["examples/s1/main.tf", "examples/s2/main.tf", "examples/s3/main.tf"])
    and all(.covered[]; .witnesses == [{attribute: "security_groups", example: "examples/e1", address: "module.lb.aws_lb.this"}])' "$TMP/out.json" > /dev/null
}

for sh in bash zsh; do
  SH=$sh
  t_covered; check "$sh: one root attribute, concat and compact, 6 planned 3 skipped for G3: all covered" $?
done
SH=bash

t_two_files() { # the second changed file is reached only by a skipped example
  fresh; reset_knobs; plain_change; ed modules/other/main.tf 's/var\.name/var.topic_name/'
  run_case && all_why no-witness
}
t_two_files; check "two changed files, one reached only by a skipped example: no-witness" $?

t_shared_exec() {
  fresh; reset_knobs
  ed main.tf 's/(  subnets         = var\.subnets\n)/$1\n  provisioner "local-exec" {\n    command = "true"\n  }\n/'
  run_case && all_why change-not-allowed
}
t_shared_exec; check "a local-exec added to a shared module: change-not-allowed" $?

t_gated_exec() {
  fresh; reset_knobs; plain_change
  printf 'resource "aws_eip" "e" {\n  provisioner "local-exec" {\n    command = "true"\n  }\n}\n' >> "$C/examples/s1/main.tf"
  run_case && all_why change-not-allowed
}
t_gated_exec; check "a local-exec added to a gated example: change-not-allowed" $?

t_new_hit() { # a plain literal the G3 patterns still match: the head hit set grows
  fresh; reset_knobs; ed main.tf 's/(var\.security_groups)\)\)/$1, ["provider::x"]))/'
  run_case && all_why hit-set-differs
}
t_new_hit; check "a new hit in a shared file at head: hit-set-differs" $?

t_relabel() {
  fresh; reset_knobs; plain_change; BGEDIT='s/^hit G3 examples\/s1\/main.tf$/hit G1 examples\/s1\/main.tf/m'
  run_case && [ "$(why examples/s1)" = hit-set-differs ] && [ "$(why examples/s2)" = covered ]
}
t_relabel; check "a relabeled hit at base: hit-set-differs for that directory only" $?

t_dir_md() {
  fresh; reset_knobs; plain_change; printf 'More.\n' >> "$C/examples/s1/README.md"
  run_case && [ "$(why examples/s1)" = dir-changed ] && [ "$(why examples/s2)" = covered ] && [ "$(why examples/s3)" = covered ]
}
t_dir_md; check "a document under a skipped directory changed: dir-changed for it alone" $?

dir_change() { # name, shell commands under the clone
  fresh; reset_knobs; plain_change; (cd "$C" && eval "$2")
  run_case && all_why change-not-allowed
}
dir_change "a file added under a skipped directory" 'printf "x\n" > examples/s1/notes.md'
check "a file added under a skipped directory: change-not-allowed" $?
dir_change "a file deleted under a skipped directory" 'rm examples/s1/README.md'
check "a file deleted under a skipped directory: change-not-allowed" $?
dir_change "a file renamed under a skipped directory" 'git mv examples/s1/README.md examples/s1/GUIDE.md'
check "a file renamed under a skipped directory: change-not-allowed" $?
dir_change "a .tf modified under a skipped directory" 'perl -pi -e "s/name = \"x\"/name = \"y\"/" examples/s1/main.tf'
check "a .tf modified under a skipped directory: change-not-allowed" $?

witness() { # name, jq over each addresses file, expected reason for all
  fresh; reset_knobs; plain_change; ADDRJQ=$2
  run_case && all_why "$3"
}
witness count0 'del(.addresses[] | select(. == "module.lb.aws_lb.this")) | del(.attributes["module.lb.aws_lb.this"])' no-witness
check "count = 0, no planned address: no-witness" $?
witness sensitive '.sensitive["module.lb.aws_lb.this"] = ["security_groups"]' witness-sensitive
check "the witness attribute marked sensitive: witness-sensitive" $?
witness nosens 'del(.sensitive)' witness-sensitive
check "no sensitive key in the record: witness-sensitive" $?
witness nosensaddr 'del(.sensitive["module.lb.aws_lb.this"])' witness-sensitive
check "the address missing from the sensitive map: witness-sensitive" $?
witness otherdir '.module_calls.lb = "../../modules/sub"' no-witness
check "the same full address through a different directory: no-witness" $?
witness registry '.module_calls = {}' no-witness
check "a registry-sourced witness module call: no-witness" $?
witness otherhead '.head_sha = "0000000000000000000000000000000000000000"' no-witness
check "a witness record for another head SHA: no-witness" $?
witness nohead 'del(.head_sha)' no-witness
check "a witness record with no head SHA: no-witness" $?

t_first_ok() { # the first example is sensitive, the second is not: the second is the witness
  fresh; reset_knobs; plain_change
  run_case || return 1
  jq '.sensitive["module.lb.aws_lb.this"] = ["security_groups"]' "$TMP/addr/addresses-1.json" > "$TMP/a1" && mv "$TMP/a1" "$TMP/addr/addresses-1.json"
  "$SH" "$SC" check "$RUN" --files "$TMP/files.json" --coverage "$TMP/coverage.json" --plan "$TMP/record.txt" \
    --addresses "$TMP/addr" --base-gates "$TMP/base-gates.txt" --head "$HEAD" --base "$BASE" > "$TMP/out.json" || return 1
  all_why covered && [ "$(q 'all(.covered[]; .witnesses[0].example == "examples/e2")')" = 0 ]
}
t_first_ok; check "the first qualifying example in path order is the witness" $?

t_deep() { # a change in modules/sub reached through the root module: two module levels
  fresh; reset_knobs; ed modules/sub/main.tf 's/protocol = "HTTP"/protocol = "HTTPS"/'
  EX="examples/e1 examples/e2 examples/e3 examples/e4 examples/e6 examples/s1 examples/s2 examples/s3"
  run_case; local s=$?; EX="examples/e1 examples/e2 examples/e3 examples/e4 examples/e5 examples/e6 examples/s1 examples/s2 examples/s3"
  [ "$s" = 0 ] && all_why no-witness
}
t_deep; check "a deeper module chain only (v1 limit): no-witness" $?

t_direct_sub() { # the same change, with an example that calls modules/sub directly
  fresh; reset_knobs; ed modules/sub/main.tf 's/protocol = "HTTP"/protocol = "HTTPS"/'
  run_case && all_why covered && [ "$(q 'all(.covered[]; .witnesses == [{attribute: "protocol", example: "examples/e5", address: "module.sub.aws_lb_listener.this"}])')" = 0 ]
}
t_direct_sub; check "a submodule called directly by an example: covered" $?

na() { # name, file, perl substitution: a change the allow-list refuses
  fresh; reset_knobs; ed "$2" "$3"
  run_case && all_why change-not-allowed
}
while IFS='|' read -r name file sub; do
  [ -n "$name" ] || continue
  na "$name" "$file" "$sub"; check "change-not-allowed: $name" $?
done <<'EOF'
wrapper only|wrappers/main.tf|s/source = "..\/"/source = "..\/\/"/
versions only|versions.tf|s/>= 5.0/>= 6.0/
a variable default|variables.tf|s/default = "x"/default = "y"/
a local|main.tf|s/name = var.name\n}\n\noutput/name = var.tags\n}\n\noutput/
an output|main.tf|s/value = aws_lb.this.arn/value = aws_lb.this.id/
a nested block attribute|main.tf|s/enabled = true/enabled = false/
a dynamic block|main.tf|s/  access_logs \{/  dynamic "access_logs" {\n    for_each = [1]\n    content {}\n  }\n  access_logs {/
count|main.tf|s/count = var.create \? 1 : 0/count = 1/
for_each|main.tf|s/count = var.create \? 1 : 0/for_each = var.groups/
lifecycle|main.tf|s/ignore_changes = \[tags\]/ignore_changes = [name]/
depends_on|main.tf|s/(  tags            = var.tags\n)/$1  depends_on      = [aws_security_group.this]\n/
an added attribute|main.tf|s/(  tags            = var.tags\n)/$1  idle_timeout    = 60\n/
an attribute added between two others|main.tf|s/(  security_groups = [^\n]*\n)/$1  idle_timeout    = 60\n/
a module source|main.tf|s/source = ".\/modules\/sub"/source = ".\/modules\/sub\/"/
a module argument|main.tf|s/port   = 80/port   = 81/
a deleted resource|main.tf|s/data "aws_iam_policy_document" "this" \{\n  statement \{\n    actions = \["s3:GetObject"\]\n  \}\n\}\n\n//
a renamed resource|main.tf|s/resource "aws_lb" "this"/resource "aws_lb" "main"/
lookup with a default|main.tf|s/subnets         = var.subnets/subnets         = lookup(var.cfg, "subnets", [])/
try with a fallback|main.tf|s/subnets         = var.subnets/subnets         = try(var.cfg.subnets, [])/
merge|main.tf|s/tags            = var.tags/tags            = merge(var.tags, {})/
a conditional|main.tf|s/subnets         = var.subnets/subnets         = var.on ? var.subnets : []/
a for expression|main.tf|s/subnets         = var.subnets/subnets         = [for s in var.subnets : s]/
file()|main.tf|s/subnets         = var.subnets/subnets         = file("x")/
templatefile()|main.tf|s/subnets         = var.subnets/subnets         = templatefile("x", {})/
jsondecode()|main.tf|s/subnets         = var.subnets/subnets         = jsondecode(var.s)/
a count. reference|main.tf|s/name            = var.name\n  security/name            = "x-\${count.index}"\n  security/
an each. reference|main.tf|s/name            = var.name\n  security/name            = each.key\n  security/
an operator|main.tf|s/subnets         = var.subnets/subnets         = var.subnets + 1/
a comment line changed|main.tf|s/(  subnets         = var.subnets\n)/$1  # note\n/
EOF

t_md_only() { fresh; reset_knobs; printf 'More.\n' >> "$C/README.md"; run_case && all_why change-not-allowed; }
t_md_only; check "a *.md only change and no .tf change: change-not-allowed (inert, the renderer handles it)" $?

t_md_with() { fresh; reset_knobs; plain_change; printf 'More.\n' >> "$C/README.md"; run_case && all_why covered; }
t_md_with; check "a document change alongside a covered change: still covered" $?

t_md_added() { fresh; reset_knobs; plain_change; printf 'New.\n' > "$C/CHANGES.md"; run_case && all_why change-not-allowed; }
t_md_added; check "a document added alongside a covered change: change-not-allowed" $?

t_g0_g3() {
  fresh; reset_knobs; plain_change; COVJQ='.unplanned += [{dir: "examples/s1", reason: "plan gate G0"}]'
  run_case && [ "$(why examples/s1)" = not-sole-reason ] && [ "$(why examples/s2)" = covered ]
}
t_g0_g3; check "a directory skipped for G3 and G0: not-sole-reason" $?

t_g0() {
  fresh; reset_knobs; plain_change
  COVJQ='.unplanned[0].reason = "plan gate G0" | .unplanned += [{dir: "examples/e9", reason: "code-error, merge base not planned"}]'
  run_case && [ "$(why examples/s1)" = wrong-gate-class ] && [ "$(why examples/e9)" = wrong-gate-class ] && [ "$(why examples/s2)" = covered ]
}
t_g0; check "a G0 skip and a failed plan: wrong-gate-class" $?

t_unresolved() {
  fresh; reset_knobs; plain_change; run_case || return 1
  "$SH" "$SC" check "$RUN" --files "$TMP/files.json" --coverage "$TMP/coverage.json" --plan "$TMP/record.txt" \
    --addresses "$TMP/addr" --base-gates "$TMP/base-gates.txt" --head "$HEAD" --base unresolved > "$TMP/out.json" || return 1
  all_why merge-base-unresolved && [ "$(q '.base_sha == null and .covered == []')" = 0 ]
}
t_unresolved; check "an unresolvable merge base: merge-base-unresolved" $?

t_base_missing() { fresh; reset_knobs; plain_change; GATES=0; run_case && all_why base-record-missing; }
t_base_missing; check "no base gate record: base-record-missing" $?
t_base_partial() {
  fresh; reset_knobs; plain_change; BGEDIT='s/^done examples\/s2\n//m'
  run_case && [ "$(why examples/s2)" = base-record-missing ] && [ "$(why examples/s1)" = covered ]
}
t_base_partial; check "a partial base gate record: base-record-missing for the directory it lacks" $?
t_base_cut() { fresh; reset_knobs; plain_change; BGEDIT='s/^end\n\z//m'; run_case && all_why base-record-missing; }
t_base_cut; check "a base gate record with no end line: base-record-missing" $?
t_base_stale() {
  fresh; reset_knobs; plain_change; BGEDIT='s/^skip-gates 1 [0-9a-f]{40}$/skip-gates 1 1111111111111111111111111111111111111111/m'
  run_case && all_why base-record-missing
}
t_base_stale; check "a stale base gate record: base-record-missing" $?

t_head_mismatch() {
  fresh; reset_knobs; plain_change; run_case || return 1
  "$SH" "$SC" check "$RUN" --files "$TMP/files.json" --coverage "$TMP/coverage.json" --plan "$TMP/record.txt" \
    --addresses "$TMP/addr" --base-gates "$TMP/base-gates.txt" --head "$BASE" --base "$BASE" > "$TMP/out.json" || return 1
  all_why head-mismatch
}
t_head_mismatch; check "the clone not at --head: head-mismatch" $?

t_runner_record() {
  fresh; reset_knobs; plain_change; run_case || return 1
  perl -pi -e 's/^plan pass mode: laptop$/plan pass mode: runner/' "$TMP/record.txt"
  "$SH" "$SC" check "$RUN" --files "$TMP/files.json" --coverage "$TMP/coverage.json" --plan "$TMP/record.txt" \
    --addresses "$TMP/addr" --base-gates "$TMP/base-gates.txt" --head "$HEAD" --base "$BASE" > "$TMP/out.json" || return 1
  all_why plan-record-unusable
}
t_runner_record; check "a runner record: plan-record-unusable" $?

t_downloaded_hit() { # a downloaded first hit while the clone scope has hits: the record and the clone disagree
  fresh; reset_knobs; plain_change; run_case || return 1
  # the s1 block reads as if every hit were downloaded, as a stale or forged record would
  perl -0pi -e 's/(example: examples\/s1\n)(gate-hit [^\n]*\n)*plan: [^\n]*/${1}gate-hit G3 downloaded\/x\/main.tf:11\nplan: plan gate G3 downloaded\/x\/main.tf:11 (1 hits)/' "$TMP/record.txt"
  "$SH" "$SC" check "$RUN" --files "$TMP/files.json" --coverage "$TMP/coverage.json" --plan "$TMP/record.txt" \
    --addresses "$TMP/addr" --base-gates "$TMP/base-gates.txt" --head "$HEAD" --base "$BASE" > "$TMP/out.json" || return 1
  [ "$(why examples/s1)" = hit-set-differs ] && [ "$(why examples/s2)" = covered ]
}
t_downloaded_hit; check "a downloaded first hit while the clone scope has hits: hit-set-differs" $?

EXD="$EX examples/d1"
DLCOV='.unplanned += [{dir: "examples/d1", reason: "plan gate G3"}]'
dl_case() { # extra shell commands under the clone, then the expected reason of examples/d1
  fresh; plain_change; (cd "$C" && eval "$1"); local keep="$EX"; EX="$EXD"; COVJQ="$DLCOV"
  run_case; local s=$?; EX="$keep"
  [ "$s" = 0 ] && [ "$(why examples/d1)" = "$2" ] && [ "$(why examples/s1)" = covered ]
}
t_dl() { reset_knobs; dl_case : covered && jq -e '.covered[] | select(.dir == "examples/d1") | .downloaded == true and .path == "downloaded/vpc/main.tf" and .gate == "G3"
    and (.witnesses | length) == 1' "$TMP/out.json" > /dev/null && jq -e 'all(.covered[] | select(.dir != "examples/d1"); has("downloaded") | not)' "$TMP/out.json" > /dev/null; }
t_dl; check "an unchanged directory with a G3 hit in a downloaded module and a clean clone scope: covered, downloaded" $?
t_dl_changed() { reset_knobs; dl_case 'printf "More.\n" >> examples/d1/README.md' dir-changed; }
t_dl_changed; check "the same directory changed: dir-changed" $?
t_dl_g0() { reset_knobs; DLHITS="G3 downloaded/vpc/main.tf:11
G0 downloaded/vpc/link.tf:0"; dl_case : wrong-gate-class; }
t_dl_g0; check "a G0 hit in a downloaded module: wrong-gate-class" $?
t_dl_noline() {
  reset_knobs; DLHITS="G3 downloaded/vpc/main.tf"; DLPLAN="plan gate G3 downloaded/vpc/main.tf (1 hits)"; dl_case : hit-set-differs
}
t_dl_noline; check "a downloaded hit with no line: hit-set-differs" $?
t_dl_json() {
  reset_knobs; DLHITS="G2 downloaded/modules.json:vpc"; DLPLAN="plan gate G2 downloaded/modules.json:vpc (1 hits)"
  fresh; plain_change; local keep="$EX"; EX="$EXD"; COVJQ='.unplanned += [{dir: "examples/d1", reason: "plan gate G2"}]'
  run_case; local s=$?; EX="$keep"; [ "$s" = 0 ] && [ "$(why examples/d1)" = hit-set-differs ]
}
t_dl_json; check "a downloaded hit that names no line, a modules.json entry: hit-set-differs" $?
t_dl_climb() { reset_knobs; DLHITS="G3 downloaded/../main.tf:1"; DLPLAN="plan gate G3 downloaded/../main.tf:1 (1 hits)"; dl_case : hit-set-differs; }
t_dl_climb; check "a downloaded hit path that climbs out: hit-set-differs" $?
t_dl_missing() { reset_knobs; DLHITS="G3 downloaded/vpc/main.tf:11
G3 bogus"; dl_case : hit-set-differs; }
t_dl_missing; check "a downloaded block with a malformed gate-hit line: hit-set-differs" $?

# --- Refused inputs: exit 2, nothing printed
fresh; reset_knobs; plain_change; run_case > /dev/null 2>&1
refused() { # name, arguments after check <run-dir>
  local o; o="$("$SH" "$SC" check "$RUN" "$@" 2> /dev/null)"; local s=$?
  check "refused: $1" "$([ "$s" = 2 ] && [ -z "$o" ]; echo $?)"
}
base_args() { echo --files "$TMP/files.json" --coverage "$TMP/coverage.json" --plan "$TMP/record.txt"; }
# shellcheck disable=SC2046 # the paths hold no space
refused "a short --head" $(base_args) --head abc --base "$BASE"
# shellcheck disable=SC2046
refused "a --base that is neither a SHA nor unresolved" $(base_args) --head "$HEAD" --base main
refused "no --coverage" --files "$TMP/files.json" --plan "$TMP/record.txt" --head "$HEAD" --base "$BASE"
refused "no --plan" --files "$TMP/files.json" --coverage "$TMP/coverage.json" --head "$HEAD" --base "$BASE"
echo '{"x": 1}' > "$TMP/bad.json"
refused "a files list that is not an array" --files "$TMP/bad.json" --coverage "$TMP/coverage.json" --plan "$TMP/record.txt" --head "$HEAD" --base "$BASE"
refused "a coverage that is not a coverage object" --files "$TMP/files.json" --coverage "$TMP/bad.json" --plan "$TMP/record.txt" --head "$HEAD" --base "$BASE"
# shellcheck disable=SC2046
refused "an unknown argument" $(base_args) --head "$HEAD" --base "$BASE" --bogus 1
# shellcheck disable=SC2046
o="$("$SH" "$SC" check "$TMP/not-a-run" $(base_args) --head "$HEAD" --base "$BASE" 2> /dev/null)"
check "refused: a run directory of another shape" "$([ $? = 2 ] && [ -z "$o" ]; echo $?)"
"$SH" "$SC" gates "$RUN" --tree "$RUN/base" --base "$HEAD" --coverage "$TMP/coverage.json" --out "$TMP/bg2.txt" 2> /dev/null
check "refused: a base tree not at --base, and no record written" "$([ $? = 2 ] && [ ! -e "$TMP/bg2.txt" ]; echo $?)"

# --- Negative self-check: each mutation of a temp copy must make its named case fail.
mutate() { # name, perl substitution, case function
  local d="$TMP/mut-$RANDOM"; mkdir -p "$d"; cp "$REF/skip-coverage.sh" "$REF/skip-coverage.jq" "$REF/plan-pass.sh" "$d/"
  perl -0pi -e "$2" "$d/skip-coverage.sh" "$d/skip-coverage.jq"
  if cmp -s "$d/skip-coverage.sh" "$REF/skip-coverage.sh" && cmp -s "$d/skip-coverage.jq" "$REF/skip-coverage.jq"; then
    check "self-check: $1 (the mutation changed nothing)" 1; return
  fi
  local keep="$SC" before="$fails"; SC="$d/skip-coverage.sh"
  "$3" > /dev/null 2>&1; local s=$?
  SC="$keep"; fails="$before"
  check "self-check: $1 is caught" "$([ "$s" != 0 ]; echo $?)"
}
t_merge() { na merge main.tf 's/tags            = var.tags/tags            = merge(var.tags, {})/'; }
t_count_ref() { na count main.tf 's/name            = var.name\n  security/name            = "x-\${count.index}"\n  security/'; }
t_added_attr() { na added main.tf 's/(  security_groups = [^\n]*\n)/$1  idle_timeout    = 60\n/'; }
t_sens() { witness sensitive '.sensitive["module.lb.aws_lb.this"] = ["security_groups"]' witness-sensitive; }
t_otherhead() { witness otherhead '.head_sha = "0000000000000000000000000000000000000000"' no-witness; }
t_otherdir() { witness otherdir '.module_calls.lb = "../../modules/sub"' no-witness; }
mutate "merge allowed" 's/qw\(concat /qw(merge concat /' t_merge
mutate "count. references allowed" 's/each\|count\|self\|//' t_count_ref
mutate "the structure and name checks dropped" 's/\$hs eq \$bs && \@\$ha == \@\$ba/1/; s/ && \$h->\{name\} eq \$b->\{name\}//' t_added_attr
mutate "the hit sets not compared" 's/ or \(\$h\.lines \| sort\) != \(\$b\.lines \| sort\)//' t_relabel
mutate "changes under the directory ignored" 's/any\(\$paths\[\]; startswith\(\$d \+ "\/"\)\)/false/' t_dir_md
mutate "the sensitive bit ignored" 's/and \(index\(\$c\.attribute\) == null\)//' t_sens
mutate "the witness head SHA ignored" 's/ and \.head_sha == \$head//' t_otherhead
mutate "the module call directory ignored" 's/\n            and \(\.value \| resolve\(\$b\.dir\)\) == \$c\.dir//' t_otherdir
mutate "an added file allowed" 's/if \.s != "modified" or \.prev != null then "other" else \.kind end/.kind/' t_md_added
mutate "a stale base record accepted" 's/\.\[0\] == "skip-gates 1 " \+ \$sha and //' t_base_stale
mutate "the merge base not required" 's/elif \(\$base \| sha \| not\) then "merge-base-unresolved"\n//' t_unresolved
mutate "a downloaded hit with no line accepted" 's/\(\.line \/\/ ""\) \| test\("\^:\[0-9\]\+\$"\)/true/' t_dl_noline
mutate "a downloaded hit taken while the clone scope has hits" 's/ and \(any\(\$h\.lines\[\]; startswith\("hit "\)\) \| not\)//' t_downloaded_hit
mutate "downloaded hits never covered" 's/elif \$dl and \(all/elif \$dl or (all/' t_dl

echo
if [ "$fails" -eq 0 ]; then echo "skip coverage: all checks hold"; else echo "skip coverage: $fails failed"; exit 1; fi
