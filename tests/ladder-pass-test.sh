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
for a in "\$@"; do case "\$a" in *LADDER-CANARY*)
  case "\$*" in *.ladder-sentinel*) [ -f "$ST/canary.prov" ] && { cat "$ST/canary.prov"; exit 0; } ;; esac
  cat "$ST/canary.txt"; exit 0 ;; esac; done
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
[ "\$1" = plan ] && echo "\$*" >> "\$S/plan-args.log"
env | grep -E '^(AWS_|GITHUB_TOKEN|GH_TOKEN|TF_CLI_ARGS)' >> "\$S/leak.log"
case "\$1" in
version) echo '{"terraform_version":"1.9.8"}' ;;
validate) [ -f "\$S/validate.fail" ] && { printf 'Error: Reference to undeclared input variable\n' >&2; exit 1; } ;;
init)
  case "\$(uname -m)" in arm64|aarch64) m=arm64 ;; *) m=amd64 ;; esac; os=linux; [ "\$(uname -s)" = Darwin ] && os=darwin
  sed -n 's/.*source = "\([^"]*\)", version = "= \([^"]*\)".*/\1 \2/p' main.tf | while read -r src ver; do
    d=".terraform/providers/\$src/\$ver/\${os}_\$m"; mkdir -p "\$d"; echo bin > "\$d/terraform-provider-\${src##*/}_v\${ver}_x5"; chmod 755 "\$d"/*
  done ;;
providers) cat "\$S/schema.json" ;;
test)
  # L2: the instances of terraform_data.subject from the case's first input, upper-cased
  # when the subject says upper(); a wholly unknown input is the unknown keys error.
  echo "\$*" >> "\$S/test-args.log"
  for a in "\$@"; do case "\$a" in -var-file=*) vf=\${a#-var-file=} ;; esac; done
  ls "\$PWD" > "\$S/test-dir.txt"
  jl() { jq -cn "\$@"; }
  jl '{type:"version", terraform:"1.9.8"}'
  [ -f "\$S/test.badjson" ] && { echo 'not json'; exit 1; }
  if [ "\$(jq -r .ladder_mode_0 "\$vf")" = unknown ] || [ -f "\$S/test.othererror" ] || jq -e '.ladder_val_0 | type == "array" and any(. == null)' "\$vf" > /dev/null; then
    f=subject.tf; s="Invalid for_each argument"; grep -q 'count = ' subject.tf && s="Invalid count argument"
    [ -f "\$S/test.othererror" ] && { f=main.tf; s="Unsupported argument"; }
    jq -e '.ladder_val_0 | type == "array" and any(. == null)' "\$vf" > /dev/null && s="Invalid for_each set argument"
    jl --arg f "\$f" --arg s "\$s" '{type:"diagnostic", diagnostic:{severity:"error", summary:\$s, range:{filename:\$f}}}'
    jl '{type:"test_run", test_run:{run:"ladder", progress:"complete", status:"error"}}'
    exit 1
  fi
  [ -f "\$S/test.noplan" ] || {
  cu=true; [ -f "\$S/canary.known" ] && cu=false
  up=false; grep -q 'upper(' subject.tf && up=true
  uv=false; [ -f "\$S/test.unknownvalue" ] && uv=true
  jq -c --argjson up "\$up" --argjson uv "\$uv" --argjson cu "\$cu" --arg names "\$(grep -Eo 'output "canary_ladder_ue?_[0-9]+"' main.tf | cut -d'"' -f2)" \
    --argjson cnt "\$(grep -q 'count = ' subject.tf && echo true || echo false)" '
    ([.ladder_val_0[] | if \$up then ascii_upcase else . end]) as \$k
    | {type:"test_plan", test_plan:{output_changes:({canary_known:{after:"known", after_unknown:false}}
        + ([\$names | split("\n")[] | select(. != "") | {(.): {after_unknown: \$cu}}] | add // {})),
       resource_changes:(if \$cnt then [range(\$k | length) as \$i | {address:"terraform_data.subject[\(\$i)]", mode:"managed", index:\$i,
           change:{actions:["create"], after:{input:null}, after_unknown:{id:true, output:true}, after_sensitive:{}}}]
         else [\$k[] | {address:"terraform_data.subject[\"\(.)\"]", mode:"managed", index:., change:{actions:["create"], after:{input:(if \$uv then null else . end)},
           after_unknown:{id:true, output:true, input:\$uv}, after_sensitive:{}}}] end)}}' "\$vf"; }
  jl '{type:"test_run", test_run:{run:"ladder", progress:"complete", status:"pass"}}'
  exit 0 ;;
plan)
  [ -f "\$S/plan.fail" ] && { printf 'Error: Invalid function argument\n\n  on main.tf line 9\n' >&2; exit 1; }
  [ -f "\$S/plan.subject" ] && { printf 'Error: Invalid function argument\n\n  on subject.tf line 2, in output "subject":\n' >&2; exit 1; }
  for a in "\$@"; do case "\$a" in -out=*) out=\${a#-out=} ;; -var-file=*) vf=\${a#-var-file=} ;; esac; done
  printf '%s\n%s\n' "\$PWD" "\$vf" > "\$out" ;;
show)
  dir=\$(sed -n 1p "\$3"); vf=\$(sed -n 2p "\$3"); c=\${vf##*/}; c=\${c%.tfvars.json}; cat "\$dir"/*.tf > "\$S/m.tf"; m="\$S/m.tf"
  cu=true; [ -f "\$S/canary.known" ] && cu=false
  typ=\$(grep -Eo '^resource "aws_(rds_cluster|db_instance)" "this"' "\$dir/subject.tf" | cut -d'"' -f2)
  if [ -n "\$typ" ]; then
    # L3: the control case "known" updates to a known value; compact() keeps the prior value;
    # anything else plans the target unknown.
    b="\$(cat "$REF/ladder-fixtures/\$typ/aws-6.70.0/baseline.json")"
    if [ "\$c" = known ]; then a='{"vpc_security_group_ids":["a"]}'; u='{}'; act='["update"]'
    elif grep -q 'compact(' "\$dir/subject.tf"; then a='{"vpc_security_group_ids":["sg-0old0000000000000"]}'; u='{}'; act='["no-op"]'
    else a='{"vpc_security_group_ids":null}'; u='{"vpc_security_group_ids":true}'; act='["update"]'; fi
    bad=false; [ -f "\$S/control.bad" ] && bad=true
    jq -n --argjson b "\$b" --argjson a "\$a" --argjson u "\$u" --argjson act "\$act" --argjson cu "\$cu" --argjson bad "\$bad" --arg typ "\$typ" \
      --arg names "\$(grep -Eo 'output "canary_ladder_ue?_[0-9]+"' "\$m" | cut -d'"' -f2)" '
      {errored:false, output_changes:({canary_known:{after:"known", after_unknown:false}}
        + ([\$names | split("\n")[] | select(. != "") | {(.): {after_unknown: \$cu}}] | add // {})),
       resource_changes:[{address:"\(\$typ).this", mode:"managed", change:{actions:\$act,
         before:(\$b.after + {vpc_security_group_ids:["sg-0old0000000000000"]}),
         after:(\$b.after + \$a + (if \$bad then {engine:"mysql"} else {} end)), after_unknown:\$u, after_sensitive:{}}}]}'
    exit 0
  fi
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
[ "\$1" = fixture-check ] || exit 2
shift 2; lvl=; res=; pins=; exp=; js=
while [ \$# -gt 0 ]; do case "\$1" in --level) lvl=\$2; shift 2 ;; --resource) res=\$2; shift 2 ;; --pins) pins=\$2; shift 2 ;;
  --expect) exp=\$2; shift 2 ;; --json) js=1; shift ;; *) exit 2 ;; esac; done
[ -n "\$js" ] && [ -f "\$exp" ] || exit 2
case "\$lvl" in L1|L2) [ -z "\$res\$pins" ] || exit 2 ;; L3) case "\$res" in aws_rds_cluster|aws_db_instance) ;; *) exit 2 ;; esac; jq -e '.providers | length > 0' "\$pins" > /dev/null || exit 2 ;; *) exit 2 ;; esac
jq -e '.schema_version == 1 and (.files["main.tf"].blocks | length) > 0 and (.files["main.tf"] | has("single_expressions") | not) and (.files["subject.tf"].single_expressions | length) == 1' "\$exp" > /dev/null || exit 2
rm -f "$ST/last-expect.json" "$ST/last-expect-\$lvl.json"; cp "\$exp" "$ST/last-expect.json"; cp "\$exp" "$ST/last-expect-\$lvl.json"
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
    echo "denied unix link EPERM"; echo "ok unix-pt"
    [ "$OS" = linux ] && printf 'ok netns net:[2]\nok interfaces lo\n'
    echo "end canary"
  } > "$ST/canary.txt"
}
reset() { rm -f "$ST"/{log,leak.log,sbx.log,plan-args.log,test-args.log,plan.fail,plan.subject,validate.fail,canary.known,canary.prov,sensitive,fc.violation,fc.error,control.bad,test.badjson,test.othererror,test.noplan,test.unknownvalue}; good_canary; }
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
check "a trigger that asks for L3 alone gets no L1 run, and no L3 run without a schema" "$(q "$TMP/l.json" '[.runs[] | [.level, .reason]] == [["L3", "no provider schema"]]')"
trig '' 'count.index' '[{"text":"count.index","kind":"count","type":null,"multi":null}]' wrapper-change '["L1"]' '[{"id":"i0","inputs":{"vpc_security_group_ids":{"value":["a"],"unknown":false,"null":false,"omitted":false},"count.index":{"value":0,"unknown":false,"null":false,"omitted":false}}}]'; run > /dev/null
check "count.index wraps the subject in a counted terraform_data" "$(grep -q "count = var.ladder_count_index + 1" "$RUND/ladder/fixtures/T-001/head/subject.tf" && q "$TMP/l.json" '.runs[0].state == "ran" and .runs[0].observations.base == [] and .runs[0].observations.head[0].value == 0' | grep -qx 0; echo $?)"
echo '{"class":"partial","examples":[{"dir":"examples/a","head":"plan-ok","base":null,"addresses":[]}]}' > "$TMP/cov.json"
trig 'x' 'y' '[]' wrapper-change '["L3"]'; run --coverage "$TMP/cov.json" > /dev/null
check "a coverage object passes into the record" "$(q "$TMP/l.json" '.coverage.class == "partial" and (.coverage.examples | length) == 1')"

# --- dynamic blocks: L1 on the for_each expression, never when only the content changed
reset; trig 'var.vpc_security_group_ids' 'var.vpc_security_group_ids' '[]' dynamic-block-change; jq '.triggers[0].for_each_only = true' "$TMP/b.json" > "$TMP/b2.json" && mv "$TMP/b2.json" "$TMP/b.json"; run > /dev/null
check "a dynamic block whose for_each is unchanged is unverifiable, no fixture" "$([ "$(r0 reason)" = 'the for_each is unchanged; the change is in the content' ] && ! grep -q '^facts' "$ST/log"; echo $?)"
reset; trig 'var.vpc_security_group_ids' 'compact(var.vpc_security_group_ids)' '[]' dynamic-block-change; run > /dev/null
check "a dynamic block the classifier does not mark for_each_only is unverifiable, no fixture" "$([ "$(r0 reason)" = 'the dynamic block changed beyond its for_each' ] && ! grep -q '^facts' "$ST/log"; echo $?)"
reset; trig 'var.vpc_security_group_ids' 'compact(var.vpc_security_group_ids)' '[]' dynamic-block-change; jq '.triggers[0].for_each_only = true' "$TMP/b.json" > "$TMP/b2.json" && mv "$TMP/b2.json" "$TMP/b.json"; run > /dev/null
check "a dynamic block's for_each change runs at L1" "$([ "$(r0 level)" = L1 ] && [ "$(r0 state)" = ran ]; echo $?)"

# --- L2: terraform test, plan only, on the instances of a count or for_each meta-argument
CASES2='[{"id":"typical","inputs":{"vpc_security_group_ids":{"value":["a","b"],"unknown":false,"null":false,"omitted":false}}},
  {"id":"empty","inputs":{"vpc_security_group_ids":{"value":[],"unknown":false,"null":false,"omitted":false}}},
  {"id":"unknown","inputs":{"vpc_security_group_ids":{"value":null,"unknown":true,"null":false,"omitted":false}}}]'
trig2() { # [attribute] [head expression] [cases]: a for_each key change, L1 and L2
  trig 'toset(var.vpc_security_group_ids)' "${2:-toset([for s in var.vpc_security_group_ids : upper(s)])}" '[]' \
    count-for_each-conditional-change '["L1","L2"]' "${3:-$CASES2}"
  jq --arg a "${1:-for_each}" '.triggers[0].address = "aws_security_group_rule.this" | .triggers[0].attribute = $a' "$TMP/b.json" > "$TMP/b2.json" && mv "$TMP/b2.json" "$TMP/b.json"
}
r2() { jq -r "[.runs[] | select(.level == \"L2\")][0].$1" "$TMP/l.json"; }
q2() { q "$TMP/l.json" "[.runs[] | select(.level == \"L2\")][0] | $1"; }
F2="$RUND/ladder/fixtures/T-001-L2"
reset; trig2
check "the L2 run exits 0 with an L1 and an L2 run" "$([ "$(run)" = 0 ] && q "$TMP/l.json" '[.runs[].level] == ["L1","L2"]' | grep -qx 0; echo $?)"
check "L2 ran with a valid control and its fixture hash" "$(q2 '.state == "ran" and .reason == null and .control == "valid" and (.fixture_sha256 | test("^[0-9a-f]{64}$")) and (.observations.fixture.head_tree_sha256 | test("^b{64}$"))')"
check "L2 observes the planned instance keys and values at each revision" "$(q2 '(.observations.base[0] | .case == "typical" and .known and .length == 2 and .value == {a:"a", b:"b"} and .error == false) and (.observations.head[0].value == {A:"A", B:"B"})')"
check "L2 observes no instance as an empty map" "$(q2 '[.observations.base[1], .observations.head[1]] | all(.case == "empty" and .known and .length == 0 and .value == {})')"
check "unknown keys are an error observation at both revisions" "$(q2 '[.observations.base[2], .observations.head[2]] | all(.case == "unknown" and .error and (.known | not) and (has("value") | not))')"
check "fixture-check is asked for level L2 with the manifest, no pins" "$(grep -q 'facts fixture-check .*-L2/base --level L2 --expect .*-L2/expect/base.json --json' "$ST/log" && ! grep -q 'level L2 .*--pins' "$ST/log"; echo $?)"
check "the L2 manifest binds the .tf files and the meta-argument as the single expression" "$(q "$ST/last-expect-L2.json" '(.files | keys) == ["main.tf","subject.tf"] and .files["subject.tf"].blocks == [{type:"resource",labels:["terraform_data","subject"]}] and .files["subject.tf"].single_expressions == [{block:"resource",labels:["terraform_data","subject"],attribute:"for_each"}]')"
check "the side holds the module and one test file whose only run plans" "$([ "$(ls "$F2/head" | tr '\n' ' ')" = "ladder.tftest.hcl main.tf subject.tf " ] && [ "$(cat "$F2/head/ladder.tftest.hcl")" = "$(printf 'run "ladder" {\n  command = plan\n}')" ]; echo $?)"
check "the expression is the for_each, last, with each.value as the input" "$([ "$(sed -n 2,3p "$F2/head/subject.tf")" = "$(printf '  input    = each.value\n  for_each = toset([for s in local.ladder_in_0 : upper(s)])')" ]; echo $?)"
check "terraform test runs per case and side with the case var file, verbose JSON, never plan" "$([ "$(grep -c -- '-json -verbose -no-color -var-file=.*-L2/vars/' "$ST/test-args.log")" = 6 ] && ! grep -q -- '-L2/' "$ST/plan-args.log"; echo $?)"
check "the L2 sandbox is the exec profile" "$(q2 '.observations.sandbox | .proven and (has("profile") | not)')"
reset; trig2 count 'length(var.vpc_security_group_ids) + 1'; run > /dev/null
check "a count change observes the number of instances" "$([ "$(q2 '.state == "ran" and .observations.base[0].value == 2 and .observations.base[1].value == 0 and .observations.base[2].error')" = 0 ] && grep -qx '  count = length(local.ladder_in_0) + 1' "$F2/head/subject.tf"; echo $?)"
reset; trig2 for_each '' "$(printf '%s' "$CASES2" | jq -c '.[:1] + [{id:"null-element", inputs:{vpc_security_group_ids:{value:[null], unknown:false, null:false, omitted:false}}}]')"; run > /dev/null
check "a null set element is the for_each set error observation at both revisions" "$(q2 '.state == "ran" and ([.observations.base[1], .observations.head[1]] | all(.case == "null-element" and .error))')"
reset; trig2; : > "$ST/test.unknownvalue"; run > /dev/null
check "an unknown planned value keeps the instance count as the length, and the value with null there" "$(q2 '.state == "ran" and (.observations.base[0] | (.known | not) and (.wholly_unknown | not) and .length == 2 and .unknown_mask == {a:true, b:true} and .value == {a:null, b:null})')"
reset; trig2; : > "$ST/validate.fail"; run > /dev/null
check "a validate error makes L2 unverifiable before any test" "$([ "$(r2 reason)" = 'validate base exited 1' ] && [ ! -s "$ST/test-args.log" ]; echo $?)"
reset; trig2; : > "$ST/test.othererror"; run > /dev/null
check "any other test error makes L2 unverifiable, with a fixed reason" "$([ "$(r2 reason)" = 'test base typical exited 1' ]; echo $?)"
reset; trig2; : > "$ST/test.noplan"; run > /dev/null
check "a passing test without a plan makes L2 unverifiable" "$([ "$(r2 reason)" = 'test base typical: no plan' ]; echo $?)"
reset; trig2; : > "$ST/test.badjson"; run > /dev/null
check "test output that is not JSON makes L2 unverifiable" "$([ "$(r2 state)" = unverifiable ] && r2 reason | grep -q '^test base typical'; echo $?)"
reset; trig2; : > "$ST/canary.known"; run > /dev/null
check "a stand-in that plans known makes the L2 control invalid" "$([ "$(r2 control)" = invalid ] && r2 reason | grep -q '^canary base'; echo $?)"
reset; trig2; : > "$ST/fc.violation"; run > /dev/null
check "a fixture-check violation stops L2 before any test" "$([ "$(r2 reason)" = 'fixture-check base: expr.reference-denied' ] && [ ! -s "$ST/test-args.log" ]; echo $?)"
reset; trig2 name; run > /dev/null
check "an attribute other than count or for_each has no L2 template" "$([ "$(r2 reason)" = 'no L2 template for attribute name' ]; echo $?)"
reset; trig2 for_each '' "$(printf '%s' "$CASES2" | jq -c '[range(17) as $i | {id:"k\($i)", inputs:.[0].inputs}]')"; run > /dev/null
check "L2 has its own cap of 32 cases: 17 cases at L1 and at L2 both run" "$(q2 '.state == "ran" and (.observations.base | length) == 17')"
reset; trig2 for_each '' "$(printf '%s' "$CASES2" | jq -c '[range(33) as $i | {id:"k\($i)", inputs:.[0].inputs}]')"; run > /dev/null
check "over 32 cases leaves L2 unverifiable" "$([ "$(r2 reason)" = 'over 32 cases' ]; echo $?)"
reset; sed -i.bak 's/^denied ipv6 .*/open ipv6 tcp:x:443 connected/' "$ST/canary.txt"; trig2; run > /dev/null
check "an unproven sandbox leaves L2 unverifiable" "$([ "$(r2 reason)" = 'sandbox unproven' ]; echo $?)"
# The plan-only guard, end to end on a copy whose template asks for apply: refused before any test.
mkdir -p "$TMP/apply"; cp -R "$REF"/. "$TMP/apply/"
perl -0pi -e 's/command = plan/command = apply/' "$TMP/apply/ladder-templates/l1.tf.tmpl"
reset; trig2; bash "$TMP/apply/ladder-pass.sh" run "$RUND" --behaviour "$TMP/b.json" --base "$BASE" --head "$HEAD" --out "$TMP/l.json" > /dev/null 2>&1
check "a test file with a run that does not plan is refused before terraform test" "$([ "$(r2 reason)" = 'test file base: not plan only' ] && [ ! -s "$ST/test-args.log" ]; echo $?)"
# The guard itself, taken from the script, on test directories of every refused shape.
perl -0777 -ne "print \$1 if /PLANONLY_PL='(.*?)\n'\n/s" "$LP" > "$TMP/planonly.pl"
po() { rm -rf "$TMP/po"; mkdir -p "$TMP/po"; printf '%b' "$1" > "$TMP/po/${2:-t.tftest.hcl}"; [ -n "${3:-}" ] && mkdir -p "$TMP/po/$3"; perl "$TMP/planonly.pl" "$TMP/po"; echo $?; }
check "the guard accepts run blocks that each plan" "$([ "$(po 'run "a" {\n  command = plan\n}\n\nrun "b" {\n  command = plan\n}\n')" = 0 ]; echo $?)"
check "the guard refuses apply, a missing command and a second command" "$([ "$(po 'run "a" {\n  command = apply\n}\n')" = 1 ] && [ "$(po 'run "a" {\n}\n')" = 1 ] && [ "$(po 'run "a" {\n  command = plan\n  command = apply\n}\n')" = 1 ]; echo $?)"
check "the guard refuses anything else in a run or at the top" "$([ "$(po 'run "a" {\n  command = plan\n  variables {\n  }\n}\n')" = 1 ] && [ "$(po 'mock_provider "aws" {\n  source = "x"\n}\nrun "a" {\n  command = plan\n}\n')" = 1 ] && [ "$(po 'run "a" { command = plan }\n')" = 1 ]; echo $?)"
check "the guard refuses a JSON test file, a mock file, a tests directory and no test file" "$([ "$(po '{}' t.tftest.json)" = 1 ] && [ "$(po 'x' m.tfmock.hcl)" = 1 ] && [ "$(po 'run "a" {\n  command = plan\n}\n' t.tftest.hcl tests)" = 1 ] && [ "$(po 'x' main.tf)" = 1 ]; echo $?)"

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
rp 10 1000 perl -MPOSIX -e 'my $p = fork; if ($p) { open my $f, ">", shift; print $f $p; close $f; sleep 1; exit 0 } POSIX::setsid(); sleep 30' "$TMP/ss.pid" > /dev/null
check "the runner kills a descendant that left the group with setsid" "$(sleep 0.3; ! ps -p "$(cat "$TMP/ss.pid")" > /dev/null 2>&1; echo $?)"
# The provider sweep: a process whose executable lies under LADDER_SWEEP dies, however it
# was started; here a double fork that leaves the tree before any poll can see it.
mkdir -p "$TMP/sw"
if [ "$OS" = linux ]; then cp /bin/sleep "$TMP/sw/sleep"
elif command -v cc > /dev/null 2>&1; then printf '#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n' > "$TMP/sw/s.c" && cc -o "$TMP/sw/sleep" "$TMP/sw/s.c" 2> /dev/null; fi
if [ -x "$TMP/sw/sleep" ]; then
  rc="$(LADDER_SWEEP="$TMP/sw" rp 10 1000 perl -MPOSIX -e 'fork and exit; POSIX::setsid(); fork and exit; exec $ARGV[0], 30' "$TMP/sw/sleep")"
  check "the runner kills a process run from the provider tree that left its tree" "$(sleep 0.3; [ "$rc" = 0 ] && ! ps -A -o comm= | grep -qF "$TMP/sw/sleep"; echo $?)"
else
  echo "skip the provider sweep check: no C compiler to build a test binary"
fi

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

# --- L3 with a stubbed aws provider: the curated aws_rds_cluster fixture
FX="$REF/ladder-fixtures/aws_rds_cluster/aws-6.70.0"
jq -n --arg p "$PLAT" --arg s "$SUM" '{schema_version:1, artifact_hosts:["releases.hashicorp.com"],
  providers:[{source:"registry.terraform.io/hashicorp/aws", version:"6.70.0",
    platforms:{($p):{url:"https://releases.hashicorp.com/terraform-provider-aws/6.70.0/a.zip", sha256:$s}}}]}' > "$TMP/pins.json"
FXD="$REF/ladder-fixtures/aws_db_instance/aws-6.70.0"
schema_aws() { jq -n --slurpfile r "$FX/resource-schema.json" --slurpfile d "$FXD/resource-schema.json" '{format_version:"1.0", provider_schemas:{"registry.terraform.io/hashicorp/aws":{resource_schemas:{aws_rds_cluster:$r[0], aws_db_instance:$d[0]}}}}' > "$ST/schema.json"; }
reset; schema_aws
check "acquisition of the aws pin succeeds" "$([ "$(acq)" = 0 ]; echo $?)"
PV="$RUND/ladder/providers"
check "the provider tree leaves scratch read-only, with a manifest of every entry" "$([ -f "$PV/.ladder-sentinel" ] && [ ! -w "$PV/.ladder-sentinel" ] && [ ! -e "$RUND/ladder/scratch" ] && grep -Eq "^file\+x [0-9a-f]{64} registry.terraform.io/hashicorp/aws/6.70.0/${PLAT}/terraform-provider-aws_v6.70.0_x5\$" "$RUND/ladder/providers.manifest"; echo $?)"
check "the provider configuration runs the pinned source from the tree, never direct" "$(grep -qF "\"registry.terraform.io/hashicorp/aws\" = \"$PV/registry.terraform.io/hashicorp/aws/6.70.0/$PLAT\"" "$RUND/ladder/etc/provider.tfrc" && grep -q filesystem_mirror "$RUND/ladder/etc/provider.tfrc" && ! grep -q direct "$RUND/ladder/etc/provider.tfrc"; echo $?)"
cp "$TMP/schema.json" "$TMP/aws-schema.json"
K='{"value":["a"],"unknown":false,"null":false,"omitted":false}'
CASES3="[{\"id\":\"typical\",\"inputs\":{\"vpc_security_group_ids\":$K,\"aws_security_group.this[*].id\":{\"value\":[null],\"unknown\":false,\"null\":false,\"omitted\":false,\"unknown_elements\":[0]}}},
  {\"id\":\"empty\",\"inputs\":{\"vpc_security_group_ids\":{\"value\":[],\"unknown\":false,\"null\":false,\"omitted\":false},\"aws_security_group.this[*].id\":{\"value\":[null],\"unknown\":false,\"null\":false,\"omitted\":false,\"unknown_elements\":[0]}}},
  {\"id\":\"known\",\"inputs\":{\"vpc_security_group_ids\":$K,\"aws_security_group.this[*].id\":$K}}]"
trig3() { # [cases-json] [base expression]: the pull request 556 unknown propagation trigger, L1 and L3
  trig "${2-compact(concat(aws_security_group.this[*].id, var.vpc_security_group_ids))}" 'concat(aws_security_group.this[*].id, var.vpc_security_group_ids)' \
    "${SG3:-$SG}" unknown-propagation-candidate '["L1","L3"]' "${1:-$CASES3}"
  jq '.triggers[0].address = "aws_rds_cluster.this" | .triggers[0].attribute = "vpc_security_group_ids"' "$TMP/b.json" > "$TMP/b2.json" && mv "$TMP/b2.json" "$TMP/b.json"
}
r3() { jq -r "[.runs[] | select(.level == \"L3\")][0].$1" "$TMP/l.json"; }
q3() { q "$TMP/l.json" "[.runs[] | select(.level == \"L3\")][0] | $1"; }
reset; trig3
check "the L3 run exits 0 with an L1 and an L3 run" "$([ "$(run --schema "$TMP/aws-schema.json")" = 0 ] && q "$TMP/l.json" '[.runs[].level] == ["L1","L3"]' | grep -qx 0; echo $?)"
check "L3 ran with a valid control and its fixture hash" "$(q3 '.state == "ran" and .reason == null and .control == "valid" and (.fixture_sha256 | test("^[0-9a-f]{64}$"))')"
check "L3 observes the cases with an unknown input, the control case apart" "$(q3 '[.observations.base[].case] == ["typical","empty"] and [.observations.head[].case] == ["typical","empty"]')"
check "base: no change planned, the prior value kept" "$(q3 '.observations.base[] | select(.case == "empty") | .action == "no-op" and .known and .unchanged_vs_prior == true and .value == ["sg-0old0000000000000"]')"
check "head: the attribute is known after apply" "$(q3 '.observations.head[] | select(.case == "empty") | .action == "update" and .known == false and .wholly_unknown and .unchanged_vs_prior == null and (has("value") | not)')"
check "the control case, its action and the library are recorded" "$(q3 '.observations.fixture | .control == {case:"known", action:"update", baseline:true} and .library == "aws_rds_cluster/aws-6.70.0" and (.prior_sha256 | test("^[0-9a-f]{64}$")) and (.base_tree_sha256 | test("^b{64}$"))')"
check "the L3 sandbox is the proven provider profile" "$(q3 '.observations.sandbox | .profile == "provider" and .proven')"
check "fixture-check runs at L3 for the curated type, with the pins" "$(grep -q 'facts fixture-check .*-L3/base --level L3 --resource aws_rds_cluster --pins .*/fc-pins.json --expect .*-L3/expect/base.json --json' "$ST/log" && q "$RUND/ladder/etc/fc-pins.json" '.providers == [{source:"registry.terraform.io/hashicorp/aws", version:"6.70.0"}]' | grep -qx 0; echo $?)"
check "the L3 manifest names the provider blocks and the target attribute as the single expression" "$(q "$ST/last-expect-L3.json" '(.files["main.tf"].blocks[:2] == [{type:"terraform",labels:[]},{type:"provider",labels:["aws"]}]) and .files["subject.tf"].blocks == [{type:"resource",labels:["aws_rds_cluster","this"]}] and .files["subject.tf"].single_expressions == [{block:"resource",labels:["aws_rds_cluster","this"],attribute:"vpc_security_group_ids"}]')"
check "the expression is the last argument of the resource under test" "$(tail -2 "$RUND/ladder/fixtures/T-001-L3/base/subject.tf" | head -1 | grep -qx '  vpc_security_group_ids = compact(concat(local.ladder_in_1, local.ladder_in_0))'; echo $?)"
check "every L3 plan reads the prior state copy in scratch, without refresh" "$([ "$(grep -c -- '-state=.*/ladder/scratch/prior.tfstate ' "$ST/plan-args.log")" = 5 ] && [ "$(grep -- '-state=' "$ST/plan-args.log" | grep -vc -- '-refresh=false')" = 0 ]; echo $?)"
if [ "$OS" = darwin ]; then
  check "the provider profile adds read and exec of the tree and unix sockets in its own directory only" "$(grep -qF "(allow process-exec (subpath \"$PV\"))" "$ST/last.sb" && grep -q '(allow network\* (local unix-socket (subpath "/private/tmp/ladder\.' "$ST/last.sb" && grep -q '(deny network\*)' "$ST/last.sb" && grep -qF "(deny file-write* (subpath \"$PV\"))" "$ST/last.sb"; echo $?)"
else
  check "bwrap binds the provider tree read-only and puts TMPDIR on its tmpfs" "$(grep -q -- "--ro-bind $PV $PV" "$ST/sbx.log" && grep -q -- '--setenv TMPDIR /ladder-tmp' "$ST/sbx.log"; echo $?)"
fi
reset; trig3; run > /dev/null
check "no schema: L3 is unverifiable and L1 still runs" "$([ "$(r3 reason)" = "no provider schema" ] && q "$TMP/l.json" '.runs[0].state == "ran"' | grep -qx 0; echo $?)"
reset; trig3; : > "$ST/control.bad"; run --schema "$TMP/aws-schema.json" > /dev/null
check "a control that does not match the baseline makes L3 unverifiable, control invalid" "$([ "$(r3 reason)" = "control does not match the baseline" ] && [ "$(r3 control)" = invalid ] && q3 '.observations.base == []' | grep -qx 0; echo $?)"
jq '.provider_schemas[].resource_schemas.aws_rds_cluster.block.attributes.vpc_security_group_ids.type = ["list","string"]' "$TMP/aws-schema.json" > "$TMP/bad-schema.json"
reset; trig3; run --schema "$TMP/bad-schema.json" > /dev/null
check "a schema whose attribute type differs refuses the fixture" "$([ "$(r3 reason)" = "the fixture does not match the provider schema" ]; echo $?)"
reset; trig3 "" ""; run --schema "$TMP/aws-schema.json" > /dev/null
check "an added attribute has no control at L3" "$([ "$(r3 reason)" = "an added attribute has no control" ]; echo $?)"
reset; trig3 "$(printf '%s' "$CASES3" | jq -c '.[:2]')"; run --schema "$TMP/aws-schema.json" > /dev/null
check "no all-known case leaves L3 without a control" "$([ "$(r3 reason)" = "no all-known case for the control" ]; echo $?)"
reset; trig3; jq '.triggers[0].attribute = "tags"' "$TMP/b.json" > "$TMP/b2.json" && mv "$TMP/b2.json" "$TMP/b.json"; run --schema "$TMP/aws-schema.json" > /dev/null
check "an attribute outside the fixture's targets is unverifiable" "$([ "$(r3 reason)" = "the attribute is not a target of the fixture" ]; echo $?)"
reset; trig3; jq '.triggers[0].address = "aws_instance.this"' "$TMP/b.json" > "$TMP/b2.json" && mv "$TMP/b2.json" "$TMP/b.json"; run --schema "$TMP/aws-schema.json" > /dev/null
check "a resource type without a curated fixture is unverifiable" "$([ "$(r3 reason)" = "no curated fixture for aws_instance at the pinned provider" ]; echo $?)"
reset; trig3; jq '.triggers[0].address = "aws_db_instance.this"' "$TMP/b.json" > "$TMP/b2.json" && mv "$TMP/b2.json" "$TMP/b.json"; run --schema "$TMP/aws-schema.json" > /dev/null
check "aws_db_instance plans from its own curated fixture, with its control" "$([ "$(q3 '.state == "ran" and .control == "valid" and .observations.fixture.library == "aws_db_instance/aws-6.70.0" and (.observations.base[] | select(.case == "empty") | .action == "no-op" and .unchanged_vs_prior) and (.observations.head[] | select(.case == "empty") | .action == "update" and (.known | not))')" = 0 ] && grep -q 'level L3 --resource aws_db_instance ' "$ST/log"; echo $?)"
reset; trig3 "$(printf '%s' "$CASES3" | jq -c '[range(28) as $i | {id:"k\($i)", inputs:.[2].inputs}] + .')"; run --schema "$TMP/aws-schema.json" > /dev/null
check "L3 takes its own cases, whatever the number of L1 cases" "$(q3 '[.observations.base[].case] == ["typical","empty"]')"
reset; trig3; grep -v 'unix-pt' "$ST/canary.txt" > "$ST/canary.prov"; run --schema "$TMP/aws-schema.json" > /dev/null
check "a provider canary without the plugin socket leaves L3 unverifiable, L1 runs" "$([ "$(r3 reason)" = "sandbox unproven" ] && q3 '.observations.sandbox.reason == "plugin-socket"' | grep -qx 0 && q "$TMP/l.json" '.runs[0].state == "ran"' | grep -qx 0; echo $?)"
reset; trig3; sed 's/^denied unix .*/open unix link connected/' "$ST/canary.txt" > "$ST/canary.prov"; run --schema "$TMP/aws-schema.json" > /dev/null
check "a provider canary that reaches a socket through a link leaves L3 unverifiable" "$([ "$(r3 reason)" = "sandbox unproven" ] && q3 '.observations.sandbox.reason == "canary-leak"' | grep -qx 0; echo $?)"
B3="$PV/registry.terraform.io/hashicorp/aws/6.70.0/$PLAT/terraform-provider-aws_v6.70.0_x5"
chmod u+w "$B3" && echo x >> "$B3" && chmod a-w "$B3"
reset; trig3; run --schema "$TMP/aws-schema.json" > /dev/null
check "a provider tree changed since acquisition leaves L3 unverifiable" "$([ "$(r3 reason)" = "provider tree changed" ] && ! grep -q -- '-state=' "$ST/plan-args.log"; echo $?)"
reset; acq > /dev/null; chmod u+w "$PV"; ln -s /etc "$PV/link"; chmod a-w "$PV"
trig3; run --schema "$TMP/aws-schema.json" > /dev/null
check "a link in the provider tree refuses it" "$([ "$(r3 reason)" = "provider tree changed" ]; echo $?)"
chmod u+w "$PV"; rm -f "$PV/link"; chmod a-w "$PV"; reset; acq > /dev/null

# --- the curated library: every fixture against its schema extract, prior state and template
eval "$(sed -n '/^fixture_schema_ok() {/,/^}/p' "$LP")"
for lib in "$REF"/ladder-fixtures/*/*/; do
  lib="${lib%/}"; name="${lib#"$REF"/ladder-fixtures/}"
  L="$TMP/libchk"; mkdir -p "$L"
  jq -c '.provider | {source, version}' "$lib/fixture.json" > "$L/pins.jsonl"
  SCHEMA="$TMP/libchk/schema.json"
  jq -n --slurpfile f "$lib/fixture.json" --slurpfile r "$lib/resource-schema.json" '{provider_schemas:{($f[0].provider.source):{resource_schemas:{($f[0].resource):$r[0]}}}}' > "$SCHEMA"
  check "$name: the arguments match the provider schema extract" "$(fixture_schema_ok "$lib"; echo $?)"
  check "$name: the prior state holds every attribute of the schema at its version" "$(jq -e --slurpfile f "$lib/fixture.json" --slurpfile r "$lib/resource-schema.json" '.version == 4 and (.resources | length) == 1 and .resources[0].type == $f[0].resource and .resources[0].name == "this" and (.resources[0].instances[0] | .schema_version == $r[0].version and (.attributes | keys) == ((($r[0].block.attributes // {}) + ($r[0].block.block_types // {})) | keys))' "$lib/prior.tfstate" > /dev/null; echo $?)"
  check "$name: the baseline is the prior state without the targets" "$(jq -e --slurpfile f "$lib/fixture.json" --slurpfile p "$lib/prior.tfstate" '.after == ($p[0].resources[0].instances[0].attributes | delpaths([$f[0].targets[] | [.]])) and (.actions | length) > 0' "$lib/baseline.json" > /dev/null; echo $?)"
  check "$name: the template sets the fixture's arguments, the target last" "$(got="$(awk '/^#-- subject/ { s = 1; next } /^#-- / { s = 0 } s && /^  [A-Za-z_]+ += / { print $1 }' "$lib/template.tf.tmpl" | tr '\n' ' ')"; want="$(jq -r '[.arguments | keys[] ] - .targets | join(" ")' "$lib/fixture.json") __ATTR__ "; [ "$got" = "$want" ]; echo $?)"
done
L=; SCHEMA=

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
    # L2: a for_each key change under terraform test, plan only: base keys against head keys.
    trig2
    lp run "$LR" --behaviour "$TMP/b.json" --base "$BASE" --head "$HEAD" --out "$TMP/l.json" > "$TMP/live2.out" 2>&1
    if [ "$(r2 reason)" = "fixture-check base exited 2" ]; then
      live_skip "this mtf-facts has no fixture-check --level L2"
    else
      check "live: L2 ran with a valid control" "$(q2 '.state == "ran" and .control == "valid"')"
      check "live: L2 base keys are the input, head keys upper-cased" "$(q2 '.observations.base[0].value == {a:"a", b:"b"} and .observations.head[0].value == {A:"A", B:"B"}')"
      check "live: L2 no instance for an empty input" "$(q2 '[.observations.base[1], .observations.head[1]] | all(.known and .value == {})')"
      check "live: L2 unknown keys are the for_each error at both revisions" "$(q2 '[.observations.base[2], .observations.head[2]] | all(.error)')"
      # End to end: the classifier selects L2 for a for_each change, the ladder runs it on the
      # classifier's own cases, and claims-eval reads the L2 runs.
      E2="$TMP/e2e"; mkdir -p "$E2/base" "$E2/head"
      for s in base head; do
        fe='toset(var.names)'; [ "$s" = head ] && fe='toset([for n in var.names : upper(n)])'
        printf 'variable "names" {\n  type = list(string)\n}\n\nresource "aws_iam_user" "this" {\n  for_each = %s\n  name     = each.key\n}\n' "$fe" > "$E2/$s/main.tf"
      done
      if ! PATH="$ORIGPATH" mtf-facts behaviour "$E2/head" --base "$E2/base" --json > "$E2/b.json" 2> /dev/null \
        || [ "$(jq -c '.triggers[0].levels' "$E2/b.json" 2> /dev/null)" != '["L1","L2"]' ]; then
        live_skip "this mtf-facts does not select L2 for a for_each change"
      else
        lp run "$LR" --behaviour "$E2/b.json" --base "$BASE" --head "$HEAD" --out "$TMP/l.json" > "$TMP/live-e2e.out" 2>&1
        check "live end to end: L2 ran on every case the classifier requires" "$(n=$(jq '.triggers[0].cases | length' "$E2/b.json"); q2 ".state == \"ran\" and .control == \"valid\" and (.observations.base | length) == $n and (.observations.head | length) == $n")"
        check "live end to end: base keys against head keys" "$(q2 '(.observations.base[] | select(.case == "typical") | .value == {a:"a"}) and (.observations.head[] | select(.case == "typical") | .value == {A:"A"})')"
        PATH="$ORIGPATH" mtf-facts claims-eval --behaviour "$E2/b.json" --ladder "$TMP/l.json" --head-sha "$HEAD" --base-sha "$BASE" --json > "$E2/ce.json" 2> /dev/null
        check "live end to end: claims-eval lists the L2 key changes, unexplained" "$(q "$E2/ce.json" '.triggers[0] | .state == "unverifiable" and ([.changes[] | select(.level == "L2" and .case == "typical" and .attribute == "value" and (.explained | not))] | length) == 1')"
      fi
    fi
    # L3: the real hashicorp/aws 6.70.0 from the pin file. Acquisition downloads it once
    # (outside the sandbox, to its pinned host, the hash checked) into LADDER_LIVE_CACHE.
    if [ -z "${LADDER_LIVE_CACHE:-}" ] && [ "${LADDER_LIVE_REQUIRED:-0}" != 1 ]; then
      echo "skip live L3: set LADDER_LIVE_CACHE to a provider cache directory to run it (it downloads hashicorp/aws 6.70.0)"
    else
      LC="${LADDER_LIVE_CACHE:-$TMP/live-cache}"; mkdir -m 700 -p "$LC"
      lp acquire "$LR" --pins "$REF/ladder-pins.json" --cache "$LC" --schema-out "$TMP/live-schema.json" > "$TMP/live-acq.out" 2>&1
      check "live: acquisition of hashicorp/aws 6.70.0 and its schema" "$(q "$TMP/live-schema.json" '.provider_schemas["registry.terraform.io/hashicorp/aws"].resource_schemas | has("aws_rds_cluster")')"
      check "live: the provider profile is proven" "$(lp probe "$LR" > "$TMP/live-probe3.out" 2>&1; grep -q "^provider sandbox proven $SBXNAME\$" "$TMP/live-probe3.out"; echo $?)"
      SG3='[{"text":"aws_security_group.this[*].id","kind":"resource","type":"string","multi":"count"}]' trig3
      lp run "$LR" --behaviour "$TMP/b.json" --base "$BASE" --head "$HEAD" --out "$TMP/l.json" --schema "$TMP/live-schema.json" > "$TMP/live3.out" 2>&1
      check "live: L3 ran with a valid control (pull request 556)" "$(q3 '.state == "ran" and .control == "valid" and .observations.fixture.control.baseline')"
      check "live: at the base no change is planned, the prior value kept" "$(q3 '.observations.base[] | select(.case == "empty") | .action == "no-op" and .known and .unchanged_vs_prior == true')"
      check "live: at the head the attribute is known after apply" "$(q3 '.observations.head[] | select(.case == "empty") | .action == "update" and .known == false')"
      SG3='[{"text":"aws_security_group.this[*].id","kind":"resource","type":"string","multi":"count"}]' trig3
      jq '.triggers[0].address = "aws_db_instance.this"' "$TMP/b.json" > "$TMP/b2.json" && mv "$TMP/b2.json" "$TMP/b.json"
      lp run "$LR" --behaviour "$TMP/b.json" --base "$BASE" --head "$HEAD" --out "$TMP/l.json" --schema "$TMP/live-schema.json" > "$TMP/live3d.out" 2>&1
      check "live: aws_db_instance L3 ran with a valid control" "$(q3 '.state == "ran" and .control == "valid" and .observations.fixture.library == "aws_db_instance/aws-6.70.0"')"
      check "live: aws_db_instance at the base plans no change, at the head known after apply" "$(q3 '(.observations.base[] | select(.case == "empty") | .action == "no-op" and .unchanged_vs_prior == true) and (.observations.head[] | select(.case == "empty") | .action == "update" and .known == false)')"
      check "live: no provider process is left" "$(! ps -A -o comm= | grep -qF "$LR/ladder/providers/"; echo $?)"
    fi
  fi
fi

echo
[ "$fails" = 0 ] && echo "all checks passed" || echo "$fails check(s) failed"
[ "$fails" = 0 ]
