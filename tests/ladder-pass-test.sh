#!/bin/bash
# shellcheck disable=SC2319 # "$(<test>; echo $?)" passes the test's own status to check
# Self-check for the ladder pass script of terraform-module-pr-review, with terraform,
# mtf-facts, curl and the sandbox tool (sandbox-exec on macOS, bwrap on Linux) stubbed.
# The canary never runs: the sandbox stub prints the canary lines a test sets. No network.
# Run: tests/ladder-pass-test.sh
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
REF="$SRC/.agents/skills/terraform-module-pr-review/references"
LP="$REF/ladder-pass.sh"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ladder-pass-test.XXXXXX")" && pwd -P)" && [ -n "$TMP" ] || { echo "FAIL no temporary directory"; exit 1; }
trap 'chmod -R u+w "$TMP" 2> /dev/null; rm -rf "$TMP"' EXIT
fails=0
check() { # name, command status (0 = holds)
  if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
q() { jq -e "$2" "$1" > /dev/null 2>&1; echo $?; } # file, jq test
case "$(uname -s)" in Darwin) OS=darwin; SBXNAME=sandbox-exec ;; *) OS=linux; SBXNAME=bwrap ;; esac
ST="$TMP/state"; B="$TMP/bin"
mkdir -p "$ST" "$B"

# The sandbox stub: prints the canary lines for the canary, otherwise runs the command
# (after "-f <profile>" for sandbox-exec, after "--" for bwrap, in --chdir).
cat > "$B/$SBXNAME" <<EOF
#!/bin/bash
printf '%s\n' "\$*" | cut -c1-2000 >> "$ST/sbx.log"
for a in "\$@"; do case "\$a" in *LADDER-CANARY*) cat "$ST/canary.txt"; exit 0 ;; esac; done
if [ "\$1" = -f ]; then cp "\$2" "$ST/last.sb"; shift 2; exec "\$@"; fi
dir=
while [ \$# -gt 0 ]; do case "\$1" in --chdir) dir=\$2; shift 2 ;; --) shift; break ;; *) shift ;; esac; done
cd "\$dir" && exec "\$@"
EOF
# terraform: plan writes its directory and var file into the plan file; show renders a plan
# JSON from them: compact() makes the subject wholly unknown, otherwise a known-length list.
cat > "$B/terraform" <<EOF
#!/bin/bash
S="$ST"
echo "terraform \$1 \${PWD##*/}" >> "\$S/log"
env | grep -E '^(AWS_|GITHUB_TOKEN|GH_TOKEN|TF_CLI_ARGS)' >> "\$S/leak.log"
case "\$1" in
version) echo '{"terraform_version":"1.9.8"}' ;;
validate) [ -f "\$S/validate.fail" ] && { printf 'Error: Reference to undeclared input variable\n' >&2; exit 1; } ;;
init) mkdir -p .terraform/providers/x && echo bin > .terraform/providers/x/p ;;
providers) cat "\$S/schema.json" ;;
plan)
  [ -f "\$S/plan.fail" ] && { printf 'Error: Invalid function argument\n\n  on main.tf line 9\n' >&2; exit 1; }
  [ -f "\$S/plan.subject" ] && { printf 'Error: Invalid function argument\n\n  on subject.tf line 2, in output "subject":\n' >&2; exit 1; }
  for a in "\$@"; do case "\$a" in -out=*) out=\${a#-out=} ;; -var-file=*) vf=\${a#-var-file=} ;; esac; done
  printf '%s\n%s\n' "\$PWD" "\$vf" > "\$out" ;;
show)
  dir=\$(sed -n 1p "\$3"); vf=\$(sed -n 2p "\$3"); c=\${vf##*/}; c=\${c%.tfvars.json}; cat "\$dir"/*.tf > "\$S/m.tf"; m="\$S/m.tf"
  cu=true; [ -f "\$S/canary.known" ] && cu=false
  sens=false; [ -f "\$S/sensitive" ] && sens=true
  if grep -q 'compact(' "\$m"; then subj='{"after_unknown":true}'
  elif grep -q 'count.index' "\$m"; then subj='{"after":0,"after_unknown":false}'
  elif [ "\$c" = empty ]; then subj='{"after":[null],"after_unknown":[true]}'
  else subj='{"after":[null,"a"],"after_unknown":[true,false]}'; fi
  jq -n --argjson s "\$subj" --argjson cu "\$cu" --argjson sens "\$sens" --arg names "\$(grep -Eo 'output "canary_ladder_ue?_[0-9]+"' "\$m" | cut -d'"' -f2)" \
    --argjson res "\$(grep -q 'resource "terraform_data" "subject"' "\$m" && echo true || echo false)" '
    ({canary_known: {after: "known", after_unknown: false}}
     + ([\$names | split("\n")[] | select(. != "") | {(.): {after_unknown: \$cu}}] | add // {})) as \$o
    | if \$res then {errored:false, output_changes:\$o, resource_changes:[{address:"terraform_data.subject[0]",
        change:{after:{input:\$s.after}, after_unknown:{input:\$s.after_unknown}, after_sensitive:{input:\$sens}}}]}
      else {errored:false, output_changes:(\$o + {subject:(\$s + {after_sensitive:\$sens})})} end' ;;
esac
exit 0
EOF
cat > "$B/mtf-facts" <<EOF
#!/bin/bash
echo "facts \$*" >> "$ST/log"
[ "\$1 \$3 \$4 \$5 \$7" = "fixture-check --level L1 --expect --json" ] || exit 2
jq -e '.schema_version == 1 and (.files["main.tf"].blocks | length) > 0 and (.files["main.tf"] | has("single_expressions") | not) and (.files["subject.tf"].single_expressions | length) == 1' "\$6" > /dev/null || exit 2
rm -f "$ST/last-expect.json"; cp "\$6" "$ST/last-expect.json"
[ -f "$ST/fc.violation" ] && { echo '{"schema_version":1,"ok":false,"tree_sha256":"'\$(printf 'a%.0s' {1..64})'","violations":[{"file":"main.tf","line":3,"rule":"expr.reference-denied"}]}'; exit 1; }
[ -f "$ST/fc.error" ] && exit 2
echo '{"schema_version":1,"ok":true,"tree_sha256":"'\$(printf 'b%.0s' {1..64})'","violations":[]}'
EOF
cat > "$B/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$ST/curl.log"
for a in "\$@"; do [ "\$prev" = --output ] && out=\$a; prev=\$a; done
cat "$ST/zip" > "\$out"
EOF
chmod +x "$B"/*
ORIGPATH="$PATH"
export PATH="$B:$PATH"

good_canary() {
  {
    for c in ipv4 ipv6 link-local loopback dns read write exec; do echo "denied $c x EPERM"; done
    echo "ok scratch-read"
    [ "$OS" = linux ] && printf 'ok netns net:[2]\nok interfaces lo\n'
    echo "end canary"
  } > "$ST/canary.txt"
}
reset() { rm -f "$ST"/{log,leak.log,sbx.log,plan.fail,plan.subject,validate.fail,canary.known,sensitive,fc.violation,fc.error}; good_canary; }
BASE=d72cba285514b5e2e83bea7dd1272c1c206a4f64
HEAD=3b19adcd09b08528221d3286b30338b1e0cf6f16
RUND="$TMP/runs/pr-review.abcdef"; mkdir -p "$RUND/clone"
trig() { # base_expr head_expr refs-json [category] [levels] [cases-json]: a behaviour file with one trigger
  # The default cases: "typical" (the variable ["a"]) and "empty" (the variable []), each
  # resource reference one unknown instance (a splat) or wholly unknown.
  jq -n --arg b "$1" --arg h "$2" --argjson r "$3" --arg c "${4:-wrapper-change}" --argjson l "${5:-[\"L1\"]}" --argjson cs "${6:-null}" '
    def k($v): {value:$v, unknown:false, null:false, omitted:false};
    def refs: [$r[] | select(.kind == "resource" or .kind == "data") | {(.text): (if (.text | contains("[*]"))
      then k([null]) + {unknown_elements:[0]} else {value:null, unknown:true, null:false, omitted:false} end)}] | add // {};
    {schema_version:1, inert:false, entries:[], capped:0, triggers:[{id:"T-001", file:"main.tf", line:1,
     category:$c, change_kind:"modified", address:null, attribute:null,
     base_expr:(if $b == "" then null else $b end), head_expr:$h,
     referenced_inputs:[{name:"vpc_security_group_ids", type:"list(string)"}],
     contextual_refs:[$r[] | .text], contextual_ref_details:$r, pure:true, levels:$l, reason:null,
     cases:($cs // [{id:"typical", inputs:({vpc_security_group_ids:k(["a"])} + refs)},
                    {id:"empty", inputs:({vpc_security_group_ids:k([])} + refs)}])}]}' > "$TMP/b.json"
}
SG='[{"text":"aws_security_group.this[*].id","kind":"resource","type":null,"multi":"count"}]'
run() { bash "$LP" run "$RUND" --behaviour "$TMP/b.json" --base "$BASE" --head "$HEAD" --out "$TMP/l.json" "$@" > "$TMP/run.out" 2>&1; echo $?; }
r0() { jq -r ".runs[0].$1" "$TMP/l.json"; }

# --- usage and refused input
check "a path that is not a run directory is refused" "$([ "$(bash "$LP" run "$TMP" --behaviour x 2> /dev/null; echo $?)" = 2 ]; echo $?)"
trig 'compact(concat(aws_security_group.this[*].id, var.vpc_security_group_ids))' 'concat(aws_security_group.this[*].id, var.vpc_security_group_ids)' "$SG"
check "a short base SHA is refused" "$([ "$(bash "$LP" run "$RUND" --behaviour "$TMP/b.json" --base abc --head "$HEAD" --out "$TMP/l.json" 2> /dev/null; echo $?)" = 2 ]; echo $?)"
echo '{"schema_version":1,"triggers":[{"id":"x"}]}' > "$TMP/bad.json"
check "a behaviour file of another shape is refused" "$([ "$(bash "$LP" run "$RUND" --behaviour "$TMP/bad.json" --base "$BASE" --head "$HEAD" --out "$TMP/l.json" 2> /dev/null; echo $?)" = 2 ]; echo $?)"

# --- pull request 556: compact() wholly unknown at the base, concat() known length 1 at the head
reset
check "the 556 run exits 0" "$([ "$(run)" = 0 ]; echo $?)"
check "the record has the contract's top-level shape" "$(q "$TMP/l.json" '.schema_version == 1 and .head_sha == "'"$HEAD"'" and .base_sha == "'"$BASE"'" and .terraform_version == "1.9.8" and .pins == [] and .coverage == {class:"none", examples:[]} and (.runs | length) == 1')"
check "the run ran with a valid control" "$(q "$TMP/l.json" '.runs[0] | .trigger_id == "T-001" and .level == "L1" and .state == "ran" and .reason == null and .control == "valid" and (.fixture_sha256 | test("^[0-9a-f]{64}$"))')"
check "base output is wholly unknown in both cases" "$(q "$TMP/l.json" '[.runs[0].observations.base[] | .wholly_unknown and (.known | not) and .length == null and (has("value") | not)] == [true, true]')"
check "head output in the empty case has known length 1" "$(q "$TMP/l.json" '.runs[0].observations.head[] | select(.case == "empty") | .wholly_unknown == false and .known == false and .length == 1 and .unknown_mask == [true] and .error == false')"
check "observations name the typed unknown and the case inputs" "$(q "$TMP/l.json" '.runs[0].observations.head[] | select(.case == "typical") | .unknown_inputs == ["aws_security_group.this[*].id"] and .inputs.vpc_security_group_ids.value == ["a"] and .action == null and .unchanged_vs_prior == null')"
check "one observation per case id at each revision, in the classifier's order" "$(q "$TMP/l.json" '[.runs[0].observations.base[].case] == ["typical","empty"] and [.runs[0].observations.head[].case] == ["typical","empty"]')"
check "the fixture tree hashes are recorded" "$(q "$TMP/l.json" '.runs[0].observations.fixture | (.base_tree_sha256 | test("^b{64}$")) and (.vars_sha256.empty | test("^[0-9a-f]{64}$"))')"
check "fixture-check runs on both sides before the first plan" "$([ "$(grep -n . "$ST/log" | grep -E 'facts|plan' | head -3 | grep -c facts)" = 2 ]; echo $?)"
check "fixture-check is asked for level L1 with the expected block set" "$(grep -q 'facts fixture-check .*/base --level L1 --expect .*/expect/base.json --json' "$ST/log"; echo $?)"
check "the manifest names exactly the template's blocks and the spliced subject" "$(q "$ST/last-expect.json" '[.files["main.tf"].blocks[] | .type + ":" + (.labels | join("."))] == ["variable:ladder_esample_0","variable:ladder_esample_1","variable:ladder_mode_0","variable:ladder_mode_1","variable:ladder_sample_0","variable:ladder_sample_1","variable:ladder_unk_0","variable:ladder_unk_1","variable:ladder_val_0","variable:ladder_val_1","resource:terraform_data.ladder_u_0","resource:terraform_data.ladder_ue_0","resource:terraform_data.ladder_u_1","resource:terraform_data.ladder_ue_1","locals:","output:canary_ladder_u_0","output:canary_ladder_ue_0","output:canary_ladder_u_1","output:canary_ladder_ue_1","output:canary_known"] and .files["subject.tf"].blocks == [{type:"output",labels:["subject"]}] and .files["subject.tf"].single_expressions == [{block:"output",labels:["subject"],attribute:"value"}]')"
check "the record holds no host path and no canary line" "$(! grep -qF -e "$TMP" -e 'denied ' "$TMP/l.json"; echo $?)"
check "four plans and four shows" "$([ "$(grep -c '^terraform plan' "$ST/log")" = 4 ] && [ "$(grep -c '^terraform show' "$ST/log")" = 4 ]; echo $?)"
check "the expression reads the case locals, and the locals pick each input's state" "$(F="$RUND/ladder/fixtures/T-001/head"; grep -qx '  value = concat(local.ladder_in_1, local.ladder_in_0)' "$F/subject.tf" && grep -q 'ladder_in_1 = var.ladder_mode_1 == "unknown" ? terraform_data.ladder_u_1.output : var.ladder_mode_1 == "known" ? tolist(\[for k, v in var.ladder_val_1 : contains(var.ladder_unk_1, tostring(k)) ? terraform_data.ladder_ue_1.output : v\]) : null' "$F/main.tf" && ! grep -q 'var.vpc_security_group_ids' "$F/subject.tf"; echo $?)"
check "a case var file holds the state of every input" "$(q "$RUND/ladder/fixtures/T-001/vars/typical.tfvars.json" '.ladder_mode_0 == "known" and .ladder_val_0 == ["a"] and .ladder_mode_1 == "known" and .ladder_val_1 == [null] and .ladder_unk_1 == ["0"] and .ladder_sample_1 == ["a"] and .ladder_esample_1 == "a"')"
check "the var files sit outside the side directories" "$([ -f "$RUND/ladder/fixtures/T-001/vars/empty.tfvars.json" ] && [ "$(ls "$RUND/ladder/fixtures/T-001/head" | tr "\n" " ")" = "main.tf subject.tf " ]; echo $?)"
check "the fixture is read-only" "$([ ! -w "$RUND/ladder/fixtures/T-001/head/main.tf" ] && [ ! -w "$RUND/ladder/fixtures/T-001/head" ]; echo $?)"
check "raw plans are kept in a 0700 directory" "$([ "$(ls "$RUND/ladder/plans" | wc -l | tr -d ' ')" = 4 ] && [ "$(perl -e 'printf "%o", (stat shift)[2] & 07777' "$RUND/ladder/plans")" = 700 ]; echo $?)"
check "the scratch directory is removed" "$([ ! -e "$RUND/ladder/scratch" ]; echo $?)"
check "a lease with no owner names 0, no start time and a day ahead" "$(grep -Eq '^0 - [0-9]+ [0-9a-f]{16}$' "$RUND/ladder/lease"; echo $?)"
check "an owner pid that is not running is refused" "$(dead=99999; while ps -p "$dead" > /dev/null 2>&1; do dead=$((dead - 1)); done; [ "$(run --owner-pid "$dead")" = 2 ]; echo $?)"
run --owner-pid "$$" > /dev/null
check "the lease names the owning process and its start time" "$(grep -Eq "^$$ [^ ]+ [0-9]+ [0-9a-f]{16}\$" "$RUND/ladder/lease" && [ "$(cut -d' ' -f2 "$RUND/ladder/lease")" != - ]; echo $?)"
check "no credential reaches terraform" "$([ ! -s "$ST/leak.log" ]; echo $?)"
if [ "$OS" = darwin ]; then
  check "the profile denies network, mach-lookup, reads, writes and exec" "$(for r in '(deny network\*)' '(deny mach-lookup)' '(deny file-read\*)' '(deny file-write\*)' '(deny process-exec\*)' '(deny signal)'; do grep -q "$r" "$ST/last.sb" || exit 1; done; ! grep -q 'unix-socket' "$ST/last.sb"; echo $?)"
else
  check "bwrap unshares everything, dies with its parent, keeps /tmp off and the root read-only" "$(grep -q -- '--unshare-all --die-with-parent --new-session --clearenv' "$ST/sbx.log" && grep -q -- '--tmpfs /ladder-tmp' "$ST/sbx.log" && ! grep -q -- '--tmpfs /tmp' "$ST/sbx.log" && grep -q -- '--remount-ro / ' "$ST/sbx.log"; echo $?)"
fi

# --- fail closed: the sandbox is not proven
reset; sed -i.bak 's/^denied ipv6 .*/open ipv6 tcp:x:443 connected/' "$ST/canary.txt"
run > /dev/null
check "a canary leak makes the run unverifiable" "$([ "$(r0 state)" = unverifiable ] && [ "$(r0 reason)" = "sandbox unproven" ] && q "$TMP/l.json" '.runs[0].observations.sandbox.reason == "canary-leak"' | grep -qx 0; echo $?)"
check "probe prints the leaking line on the host" "$(bash "$LP" probe "$RUND" > "$TMP/p.out" 2>&1; grep -q "^sandbox unproven: leak or fault: open ipv6" "$TMP/p.out"; echo $?)"
check "no terraform plan runs after a leak" "$(! grep -q '^terraform plan' "$ST/log" 2> /dev/null; echo $?)"
reset; grep -v '^denied dns' "$ST/canary.txt" > "$ST/c2" && mv "$ST/c2" "$ST/canary.txt"
run > /dev/null
check "a missing class makes the run unverifiable" "$(q "$TMP/l.json" '.runs[0].observations.sandbox.reason == "canary-class-missing" and .runs[0].state == "unverifiable"')"
reset; grep -v '^end canary' "$ST/canary.txt" > "$ST/c2" && mv "$ST/c2" "$ST/canary.txt"
run > /dev/null
check "a canary that did not finish makes the run unverifiable" "$(q "$TMP/l.json" '.runs[0].observations.sandbox.reason == "canary-incomplete" and .runs[0].state == "unverifiable"')"
check "the record says the sandbox is unproven" "$(q "$TMP/l.json" '.runs[0].observations.sandbox.proven == false and (has("sandbox") | not) and .terraform_version == null')"
if [ "$OS" = linux ]; then
  reset; grep -v '^ok netns' "$ST/canary.txt" > "$ST/c2" && mv "$ST/c2" "$ST/canary.txt"
  run > /dev/null
  check "on Linux, no network namespace check makes the run unverifiable" "$(q "$TMP/l.json" '.runs[0].observations.sandbox.reason == "no-network-namespace"')"
fi

# --- fail closed: fixture-check, plan, canaries, sensitive values
reset; : > "$ST/fc.violation"; run > /dev/null
check "a fixture-check violation makes the run unverifiable, no plan" "$([ "$(r0 reason)" = 'fixture-check base: expr.reference-denied' ] && ! grep -q '^terraform plan' "$ST/log"; echo $?)"
reset; : > "$ST/fc.error"; run > /dev/null
check "a fixture-check error makes the run unverifiable" "$(r0 reason | grep -q 'fixture-check base exited 2'; echo $?)"
reset; : > "$ST/plan.fail"; run > /dev/null
check "a plan error outside subject.tf makes the run unverifiable, with a fixed reason" "$([ "$(r0 reason)" = 'plan base typical exited 1' ]; echo $?)"
reset; : > "$ST/plan.subject"; run > /dev/null
check "a plan error in subject.tf is an error observation of that case" "$(q "$TMP/l.json" '.runs[0].state == "ran" and ([.runs[0].observations.base[] | .error] | all) and (.runs[0].observations.base[0] | has("value") | not)')"
reset; : > "$ST/validate.fail"; run > /dev/null
check "a validate error makes the run unverifiable before any plan" "$([ "$(r0 reason)" = 'validate base exited 1' ] && ! grep -q '^terraform plan' "$ST/log"; echo $?)"
reset; jq '.triggers[0].cases = []' "$TMP/b.json" > "$TMP/b2.json" && mv "$TMP/b2.json" "$TMP/b.json"; run > /dev/null
check "a trigger without cases is unverifiable at L1" "$([ "$(r0 reason)" = 'no cases' ]; echo $?)"
reset
trig 'compact(concat(aws_security_group.this[*].id, var.vpc_security_group_ids))' 'concat(aws_security_group.this[*].id, var.vpc_security_group_ids)' "$SG"
jq '.triggers[0].cases[0].inputs |= del(.vpc_security_group_ids)' "$TMP/b.json" > "$TMP/b2.json" && mv "$TMP/b2.json" "$TMP/b.json"; run > /dev/null
check "a case that does not name every input is unverifiable" "$([ "$(r0 reason)" = 'a case does not name exactly the inputs' ]; echo $?)"
trig '[]' '["sg-1"]' '[]' default-change '["L1"]' '[{"id":"typical","inputs":{"vpc_security_group_ids":{"value":["a"],"unknown":false,"null":false,"omitted":false}}},{"id":"omitted","inputs":{"vpc_security_group_ids":{"value":null,"unknown":false,"null":false,"omitted":true}}}]'
jq '.triggers[0].address = "var.vpc_security_group_ids"' "$TMP/b.json" > "$TMP/b2.json" && mv "$TMP/b2.json" "$TMP/b.json"; run > /dev/null
check "a default change evaluates the default only in the omitted case" "$(grep -qx '  value = var.ladder_omit ? (\["sg-1"\]) : local.ladder_in_0' "$RUND/ladder/fixtures/T-001/head/subject.tf" && q "$RUND/ladder/fixtures/T-001/vars/omitted.tfvars.json" '.ladder_omit == true and .ladder_mode_0 == "omitted"' | grep -qx 0 && [ "$(r0 state)" = ran ]; echo $?)"
jq '.triggers[0].address = null' "$TMP/b.json" > "$TMP/b2.json" && mv "$TMP/b2.json" "$TMP/b.json"; run > /dev/null
check "an omitted input that is not the default being changed is unverifiable" "$([ "$(r0 reason)" = 'an omitted input that is not the default being changed' ]; echo $?)"
trig 'compact(concat(aws_security_group.this[*].id, var.vpc_security_group_ids))' 'concat(aws_security_group.this[*].id, var.vpc_security_group_ids)' "$SG"
reset; : > "$ST/canary.known"; run > /dev/null
check "a stand-in that plans known makes the control invalid" "$([ "$(r0 state)" = unverifiable ] && [ "$(r0 control)" = invalid ]; echo $?)"
reset; : > "$ST/sensitive"; run > /dev/null
check "a sensitive subject makes the run unverifiable" "$(r0 reason | grep -q '^sensitive subject'; echo $?)"

# --- what the fixture builder refuses
reset
trig 'local.a' 'local.b' '[{"text":"local.a","kind":"local","type":null,"multi":null}]'; run > /dev/null
check "a local reference is unverifiable at L1, before fixture-check" "$([ "$(r0 reason)" = 'local, module, self and other references are unverifiable at L1' ] && ! grep -q '^facts' "$ST/log"; echo $?)"
trig 'path.module' 'path.root' '[{"text":"path.module","kind":"path","type":null,"multi":null}]'; run > /dev/null
check "a path reference is unverifiable at L1" "$([ "$(r0 reason)" = 'path and terraform references are unverifiable at L1' ]; echo $?)"
trig 'aws_x.this.arn' 'aws_x.this.arn' '[{"text":"aws_x.this.arn","kind":"resource","type":null,"multi":null}]'; run > /dev/null
check "a reference with no attribute type is unverifiable" "$([ "$(r0 reason)" = 'a resource reference with no attribute type' ]; echo $?)"
trig 'x' '1 }
output "extra" {
  value = 2' '[]'; run > /dev/null
check "an expression that closes its block reaches fixture-check with the manifest" "$(grep -q '^output "extra"' "$RUND/ladder/fixtures/T-001/head/subject.tf" && q "$ST/last-expect.json" '[.files["main.tf"].blocks[] | select(.type == "output") | .labels[0]] == ["canary_ladder_u_0","canary_ladder_ue_0","canary_known"] and .files["subject.tf"].blocks == [{type:"output",labels:["subject"]}]' | grep -qx 0; echo $?)"
trig 'a' 'b' '[]'
jq '.triggers[0].referenced_inputs[0].type = "list(string)) }\nresource \"x\" \"y\" {"' "$TMP/b.json" > "$TMP/b2.json" && mv "$TMP/b2.json" "$TMP/b.json"
run > /dev/null
check "a type outside the type grammar is unverifiable" "$([ "$(r0 reason)" = 'an input type is outside the L1 type grammar' ]; echo $?)"
jq '.triggers[0].category = "x\ny z"' "$TMP/b.json" > "$TMP/b2.json" && mv "$TMP/b2.json" "$TMP/b.json"; run > /dev/null
check "a category outside the word set is reported as other" "$([ "$(r0 reason)" = 'no L1 template for category other' ]; echo $?)"
trig 'x' 'y' '[]' resource-added-or-removed; run > /dev/null
check "a category without an L1 template is unverifiable" "$(r0 reason | grep -q 'no L1 template for category resource-added-or-removed'; echo $?)"
trig 'x' 'y' '[]' wrapper-change '["L3"]'; run > /dev/null
check "a trigger that does not ask for L1 gets no run" "$(q "$TMP/l.json" '.runs == []')"
trig '' 'count.index' '[{"text":"count.index","kind":"count","type":null,"multi":null}]'; run > /dev/null
check "count.index wraps the subject in a counted terraform_data" "$(grep -q 'count = 1' "$RUND/ladder/fixtures/T-001/head/subject.tf" && q "$TMP/l.json" '.runs[0].state == "ran" and .runs[0].observations.base == [] and .runs[0].observations.head[0].value == 0' | grep -qx 0; echo $?)"
echo '{"class":"partial","examples":[{"dir":"examples/a","head":"plan-ok","base":null,"addresses":[]}]}' > "$TMP/cov.json"
trig 'x' 'y' '[]' wrapper-change '["L3"]'; run --coverage "$TMP/cov.json" > /dev/null
check "a coverage object passes into the record" "$(q "$TMP/l.json" '.coverage.class == "partial" and (.coverage.examples | length) == 1')"

# --- the lease sweep: only runs whose owner is gone, or ownerless leases past their day
now=$(date +%s)
for x in dead1x alive1 reuse1 noown1 noown2; do mkdir -p "$TMP/runs/pr-review.$x/ladder"; done
dead=99999; while ps -p "$dead" > /dev/null 2>&1; do dead=$((dead - 1)); done
me="$(ps -o lstart= -p $$ | tr -s ' \t' '__' | sed 's/^_//; s/_$//')"
echo "$dead Mon_Jan_1_00:00:00_2024 $((now + 999)) aa" > "$TMP/runs/pr-review.dead1x/ladder/lease"
echo "$$ $me $((now - 999)) aa" > "$TMP/runs/pr-review.alive1/ladder/lease"
echo "$$ Mon_Jan_1_00:00:00_2024 $((now + 999)) aa" > "$TMP/runs/pr-review.reuse1/ladder/lease"
echo "0 - $((now - 10)) aa" > "$TMP/runs/pr-review.noown1/ladder/lease"
echo "0 - $((now + 999)) aa" > "$TMP/runs/pr-review.noown2/ladder/lease"
reset; trig 'x' 'y' '[]' wrapper-change '["L3"]'; run > /dev/null
check "the sweep removes a run whose owner is gone, even before expiry" "$([ ! -e "$TMP/runs/pr-review.dead1x/ladder" ]; echo $?)"
check "the sweep keeps a run whose owner runs, even past expiry" "$([ -d "$TMP/runs/pr-review.alive1/ladder" ]; echo $?)"
check "the sweep removes a run whose owner pid now names another process" "$([ ! -e "$TMP/runs/pr-review.reuse1/ladder" ]; echo $?)"
check "an ownerless lease goes only after its day" "$([ ! -e "$TMP/runs/pr-review.noown1/ladder" ] && [ -d "$TMP/runs/pr-review.noown2/ladder" ]; echo $?)"

# --- the budget, taken from the script: each timeout is clipped to what is left
eval "$(sed -n '/^left() {/,/^}/p' "$LP")"
L1_BUDGET=600; START=$(( $(date +%s) - 590 ))
check "a timeout is clipped to the budget left" "$(t=$(left 120) && [ "$t" -le 10 ] && [ "$t" -ge 9 ]; echo $?)"
START=$(( $(date +%s) - 600 ))
check "no budget left refuses the command" "$(! left 60 > /dev/null; echo $?)"

# --- the runner, taken from the script: timeout, cap, process group, closed descriptors
perl -0777 -ne "print \$1 if /RUN_PL='(.*?)\n'\n/s" "$LP" > "$TMP/run.pl"
rp() { perl "$TMP/run.pl" "$TMP" "$1" "$2" 2097152 "$TMP/r.out" 131072 "${@:3}"; echo $?; }
check "the runner passes the exit status" "$([ "$(rp 10 1000 sh -c 'exit 3')" = 3 ]; echo $?)"
check "the runner stops a command at its timeout" "$([ "$(rp 1 1000 sleep 30)" = 124 ]; echo $?)"
check "the runner stops a command at its output cap" "$([ "$(rp 10 1000 sh -c 'while :; do echo xxxxxxxxxxxxxxxx; done')" = 125 ] && [ "$(wc -c < "$TMP/r.out" | tr -d ' ')" -le 1000 ]; echo $?)"
rp 10 1000 sh -c "sleep 30 & echo \$! > '$TMP/gc.pid'; exit 0" > /dev/null
check "the runner kills what the command left in its group" "$(sleep 0.3; ! ps -p "$(cat "$TMP/gc.pid")" > /dev/null 2>&1; echo $?)"
exec 7> "$TMP/fd7"
rp 10 1000 sh -c 'ls /dev/fd/ 2> /dev/null; [ -e /proc/self/fd/7 ] || [ -e /dev/fd/7 ] && echo has7' > /dev/null
exec 7>&-
check "the runner closes inherited descriptors" "$(! grep -q has7 "$TMP/r.out"; echo $?)"
rfs() { perl "$TMP/run.pl" "$TMP" 10 100000 2097152 "$TMP/r.out" 2 sh -c "head -c $1 /dev/zero > '$TMP/big'" > /dev/null; echo $?; }
check "the file size limit counts 1024-byte blocks" "$([ "$(rfs 2048)" = 0 ] && [ "$(rfs 2049)" != 0 ] && [ "$(wc -c < "$TMP/big" | tr -d ' ')" -le 2048 ]; echo $?)"

# --- acquisition with a stubbed curl
case "$(uname -m)" in arm64|aarch64) M=arm64 ;; *) M=amd64 ;; esac
PLAT="${OS}_$M"
printf 'zip bytes\n' > "$ST/zip"
SUM="$(perl -MDigest::SHA -e 'print Digest::SHA->new(256)->addfile(shift)->hexdigest' "$ST/zip")"
pins() { # sha256 [host]
  jq -n --arg p "$PLAT" --arg s "$1" --arg h "${2:-releases.hashicorp.com}" '{schema_version:1, artifact_hosts:["releases.hashicorp.com"],
    providers:[{source:"registry.terraform.io/hashicorp/random", version:"3.7.2",
      platforms:{($p):{url:"https://\($h)/terraform-provider-random/3.7.2/r.zip", sha256:$s}}}]}' > "$TMP/pins.json"
}
echo '{"format_version":"1.0","provider_schemas":{"registry.terraform.io/hashicorp/random":{}}}' > "$ST/schema.json"
mkdir -m 700 "$TMP/cache"
acq() { bash "$LP" acquire "$RUND" --pins "$TMP/pins.json" --cache "$TMP/cache" --schema-out "$TMP/schema.json" > "$TMP/acq.out" 2>&1; echo $?; }
reset; pins "$SUM"
check "acquisition succeeds with a matching pin" "$([ "$(acq)" = 0 ] && q "$TMP/schema.json" '.provider_schemas | has("registry.terraform.io/hashicorp/random")' | grep -qx 0; echo $?)"
check "curl reads no configuration, refuses redirects and other protocols" "$(grep -q '^-q --proto =https --max-redirs 0 ' "$ST/curl.log"; echo $?)"
check "the mirror holds the verified zip, read-only" "$(f="$RUND/ladder/mirror/registry.terraform.io/hashicorp/random/terraform-provider-random_3.7.2_$PLAT.zip"; [ -f "$f" ] && [ ! -w "$f" ]; echo $?)"
check "the pins land in the next record" "$(trig 'x' 'y' '[]' wrapper-change '["L3"]'; run > /dev/null; q "$TMP/l.json" '.pins == [{source:"registry.terraform.io/hashicorp/random", version:"3.7.2", sha256:"'"$SUM"'"}]')"
rm -f "$TMP/cache"/*.zip; reset; pins "$(printf '0%.0s' {1..64})"
check "a hash mismatch fails acquisition and keeps nothing" "$([ "$(acq)" = 1 ] && grep -q 'sha256 mismatch' "$TMP/acq.out" && ! compgen -G "$TMP/cache/*.zip*" > /dev/null; echo $?)"
pins "$SUM" evil.example.com
check "a URL on a host outside the pin list is refused" "$([ "$(acq)" = 2 ]; echo $?)"
pins "$SUM"; chmod 755 "$TMP/cache"
check "a cache that is not mode 0700 is refused" "$([ "$(acq)" = 1 ]; echo $?)"
chmod 700 "$TMP/cache"; echo '{"format_version":"1.0","provider_schemas":{"registry.terraform.io/hashicorp/other":{}}}' > "$ST/schema.json"
check "a schema that does not name exactly the pinned providers fails" "$([ "$(acq)" = 1 ] && grep -q 'exactly the pinned' "$TMP/acq.out"; echo $?)"

# --- probe
reset
check "probe reports a proven sandbox" "$(bash "$LP" probe "$RUND" > "$TMP/p.out" 2>&1 && grep -q "^sandbox proven $SBXNAME" "$TMP/p.out" && grep -q '^terraform 1.9.8' "$TMP/p.out"; echo $?)"
sed -i.bak 's/^denied loopback .*/open loopback tcp:127.0.0.1:9 ECONNREFUSED/' "$ST/canary.txt"
check "probe exits 1 on a leak" "$(bash "$LP" probe "$RUND" > "$TMP/p.out" 2>&1; [ $? = 1 ] && grep -q '^sandbox unproven: leak or fault' "$TMP/p.out"; echo $?)"

# --- the shipped pin file is valid
check "the shipped pin file names pinned https URLs on its hosts" "$(jq -e '.schema_version == 1 and (.artifact_hosts | length) > 0 and all(.providers[].platforms[]; (.url | startswith("https://releases.hashicorp.com/")) and (.sha256 | test("^[0-9a-f]{64}$")))' "$REF/ladder-pins.json" > /dev/null; echo $?)"

# --- live: pull request 556 with the real terraform, mtf-facts and sandbox, when they exist.
# The only connections are the canary's, made inside the sandbox it is proving. With
# LADDER_LIVE_REQUIRED=1 (the live CI job) a missing tool or an unproven sandbox fails.
live_skip() {
  if [ "${LADDER_LIVE_REQUIRED:-0}" = 1 ]; then check "live: $1" 1; else echo "skip live: $1"; fi
}
LR="$TMP/live/pr-review.live01"; mkdir -p "$LR/clone"
lp() { PATH="$ORIGPATH" bash "$LP" "$@"; }
if ! PATH="$ORIGPATH" command -v terraform > /dev/null || ! PATH="$ORIGPATH" command -v "$SBXNAME" > /dev/null \
  || ! PATH="$ORIGPATH" command -v mtf-facts > /dev/null; then
  live_skip "terraform, mtf-facts or $SBXNAME is not installed"
elif ! lp probe "$LR" > "$TMP/live-probe.out" 2>&1; then
  live_skip "the sandbox is not proven here: $(tail -1 "$TMP/live-probe.out")"
else
  check "live: probe proves the sandbox" "$(grep -q "^sandbox proven $SBXNAME\$" "$TMP/live-probe.out"; echo $?)"
  trig 'compact(concat(aws_security_group.this[*].id, var.vpc_security_group_ids))' 'concat(aws_security_group.this[*].id, var.vpc_security_group_ids)' \
    '[{"text":"aws_security_group.this[*].id","kind":"resource","type":"string","multi":"count"}]'
  lp run "$LR" --behaviour "$TMP/b.json" --base "$BASE" --head "$HEAD" --out "$TMP/live.json" > "$TMP/live.out" 2>&1
  if [ "$(jq -r '.runs[0].reason' "$TMP/live.json" 2> /dev/null)" = "fixture-check base exited 2" ]; then
    live_skip "this mtf-facts has no fixture-check --expect"
  else
    check "live: the 556 run ran with a valid control" "$(q "$TMP/live.json" '.runs[0].state == "ran" and .runs[0].control == "valid"')"
    check "live: base compact() is wholly unknown" "$(q "$TMP/live.json" '[.runs[0].observations.base[] | .wholly_unknown] == [true, true]')"
    check "live: head concat() has known length 1 with one unknown element" "$(q "$TMP/live.json" '.runs[0].observations.head[] | select(.case == "empty") | .length == 1 and .unknown_mask == [true]')"
    trig 'concat(var.vpc_security_group_ids)' '1 }
output "extra" {
  value = 2' '[]'
    lp run "$LR" --behaviour "$TMP/b.json" --base "$BASE" --head "$HEAD" --out "$TMP/live.json" > "$TMP/live.out" 2>&1
    check "live: an expression that closes its block fails the manifest, no plan" "$(q "$TMP/live.json" '.runs[0].state == "unverifiable" and (.runs[0].reason | test("^fixture-check head: .*manifest.block-set"))')"
  fi
fi

echo
[ "$fails" = 0 ] && echo "all checks passed" || echo "$fails check(s) failed"
[ "$fails" = 0 ]
