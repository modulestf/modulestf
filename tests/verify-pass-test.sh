#!/bin/bash
# shellcheck disable=SC2319 # "$(<test>; echo $?)" passes the test's own status to check
# Self-check for the verification pass script of terraform-module-pr-review, run under bash
# and under zsh, with terraform stubbed. No network.
# Run: tests/verify-pass-test.sh
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
VP="$SRC/.agents/skills/terraform-module-pr-review/references/verify-pass.sh"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/verify-pass-test.XXXXXX")" && pwd -P)" && [ -n "$TMP" ] || { echo "FAIL no temporary directory"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
fails=0

check() { # name, command status (0 = holds)
  if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
q() { jq -e "$2" "$1" > /dev/null 2>&1; echo $?; } # results file, jq test

# The stub keys its behaviour on marker files in the example directory, logs each call, and
# logs any credential or inherited terraform setting it can see.
mkdir -p "$TMP/bin" "$TMP/none"
cat > "$TMP/bin/terraform" <<EOF
#!/bin/sh
echo "\${PWD##*/} \$*" >> "$TMP/tf.log"
env | grep -E '^(AWS_PROFILE|AWS_ACCESS_KEY_ID|GITHUB_TOKEN|GH_TOKEN|TF_CLI_ARGS|TF_CLI_ARGS_init)=' >> "$TMP/leak.log"
[ "\$TF_PLUGIN_CACHE_DIR" = "\$EXPECT_CACHE" ] || echo "cache \$TF_PLUGIN_CACHE_DIR" >> "$TMP/leak.log"
[ -z "\${SSH_AUTH_SOCK:-}" ] || echo ssh-agent >> "$TMP/leak.log"
env | grep '^TF_TOKEN_' > /dev/null && echo tf-token >> "$TMP/leak.log"
[ "\$TF_CLI_CONFIG_FILE" = /dev/null ] || echo "cli config \$TF_CLI_CONFIG_FILE" >> "$TMP/leak.log"
[ "\$NETRC" = /dev/null ] || echo "netrc \$NETRC" >> "$TMP/leak.log"
[ "\$HOME" = "\${EXPECT_CACHE%/plugin-cache}/verify/home" ] || echo "home \$HOME" >> "$TMP/leak.log"
h="\$(git config --get credential.helper)"; [ -z "\$h" ] || echo "credential helper \$h" >> "$TMP/leak.log"
case "\$1" in
version) echo '{"terraform_version":"1.9.8","platform":"darwin_arm64"}' ;;
init)
  if [ -f init.slow ]; then
    (sleep 3; : > "$TMP/survivor") &
    sleep 30
  fi
  if [ -f init.big ]; then head -c 1100000 /dev/zero | tr '\0' x; sleep 30; fi
  if [ -f init.env ]; then
    printf 'Error: Failed to install provider\n\nfailed to instantiate provider "aws": operation not permitted\n'; exit 1
  fi
  if [ -f init.net ]; then
    h="\$(cat init.net)"
    printf 'Error: Failed to download module\n\nGet "https://%s/x": dial tcp: lookup %s: no such host\n' "\$h" "\$h"; exit 1
  fi
  if [ -f init.fail ]; then
    printf 'Error: Unsupported argument\n\n  on main.tf line 1, in module "b":\n   1: module "b" { bogus = 1 }\n'; exit 1
  fi ;;
validate)
  if [ -f validate.fail ]; then
    printf 'Error: Missing required argument\n\n  on main.tf line 1:\n   1: dial tcp\n'; exit 1
  fi ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/terraform"

# mtf-facts affected, stubbed: logs its arguments and prints facts.out, or fails.
mkdir -p "$TMP/facts"
cat > "$TMP/facts/mtf-facts" <<EOF
#!/bin/sh
echo "\$*" >> "$TMP/facts.log"
cp "\$4" "$TMP/facts-diff.json"
case "\$(cat "$TMP/facts.mode" 2> /dev/null)" in
fail) echo boom >&2; exit 2 ;;
garbage) echo 'not json' ;;
*) cat "$TMP/facts.out" ;;
esac
EOF
chmod +x "$TMP/facts/mtf-facts"
REAL='["brokenbase","bump","bumpmajor","codeok","env","initfail","net","net2","newfail","regress"]'
facts() { # jq program over the real example names -> facts.out; mode
  jq -n --argjson r "$REAL" "$1" > "$TMP/facts.out"; printf '%s' "${2:-}" > "$TMP/facts.mode"
}

# The upstream repository: a base commit and a head commit.
up="$TMP/upstream"
mkdir -p "$up"
git -C "$up" init -q
commit() { git -C "$up" add -A && git -C "$up" -c user.name=t -c user.email=t@example.invalid commit -qm "$1"; }
mk() { mkdir -p "$(dirname "$up/$1")" && printf '%s\n' "$2" > "$up/$1"; }
mk main.tf 'resource "aws_s3_bucket" "this" {}'
for d in regress brokenbase bump bumpmajor; do mk "examples/$d/main.tf" 'module "b" { source = "../../" }'; done
: > "$up/examples/brokenbase/validate.fail"
mk examples/bump/versions.tf 'terraform {
  required_version = ">= 1.5.7"
}'
mk examples/bumpmajor/versions.tf 'terraform {
  required_version = ">= 1.5.7"
}'
commit base
BASE="$(git -C "$up" rev-parse HEAD)"
for d in codeok newfail initfail env net net2; do mk "examples/$d/main.tf" 'module "b" { source = "../../" }'; done
: > "$up/examples/regress/validate.fail"
: > "$up/examples/newfail/validate.fail"
: > "$up/examples/initfail/init.fail"
: > "$up/examples/env/init.env"
mk examples/net/main.tf 'module "x" { source = "git::https://evil.example.invalid/x.git" }'
echo evil.example.invalid > "$up/examples/net/init.net"
echo other.example.invalid > "$up/examples/net2/init.net"
ln -s codeok "$up/examples/linked"
mk examples/brokenbase/main.tf 'module "b" { source = "../../" } # touched'
mk examples/bump/versions.tf 'terraform {
  required_version = ">= 1.9.0"
}'
mk examples/bumpmajor/versions.tf 'terraform {
  required_version = ">= 2.0"
}'
commit head
HEAD="$(git -C "$up" rev-parse HEAD)"

# The changed files list, as the REST files endpoint returns it.
f() { jq -cn --arg f "$1" --arg s "$2" --arg p "${3:-}" '{filename:$f, status:$s} + (if $p == "" then {} else {patch:$p} end)'; }
{
  f examples/codeok/main.tf added '@@ -0,0 +1 @@
+module "b" { source = "../../" }'
  f examples/regress/validate.fail added
  f examples/brokenbase/main.tf modified '@@ -1 +1 @@
-module "b" { source = "../../" }
+module "b" { source = "../../" } # touched'
  f examples/newfail/main.tf added
  f examples/initfail/main.tf added
  f examples/env/main.tf added
  f examples/net/main.tf added '@@ -0,0 +1 @@
+module "x" { source = "git::https://evil.example.invalid/x.git" }'
  f examples/net2/main.tf added
  f examples/linked added
  f examples/bump/versions.tf modified '@@ -1,3 +1,3 @@
 terraform {
-  required_version = ">= 1.5.7"
+  required_version   = ">= 1.9.0"
 }'
  f examples/bumpmajor/versions.tf modified '@@ -1,3 +1,3 @@
 terraform {
-  required_version = ">= 1.5.7"
+  required_version = ">= 2.0"
 }'
  f examples/README.md modified '@@ -1 +1 @@
-x
+y'
} | jq -s . > "$TMP/files.json"

newrun() { # a run directory holding a clone of upstream at the head
  R="$(mktemp -d "$TMP/pr-review.XXXXXX")"
  git clone -q "$up" "$R/clone"
  echo "$R"
}
d() { printf '.dirs[] | select(.dir == "examples/%s") | %s' "$1" "$2"; }

for sh in bash zsh; do
  command -v "$sh" > /dev/null 2>&1 || { echo "FAIL $sh: not installed"; fails=$((fails + 1)); continue; }
  run() { PATH="$TMP/bin:/usr/bin:/bin" "$sh" "$VP" "$@" 2>&1; }

  R="$(newrun)"; O="$R/verify.json"
  : > "$TMP/tf.log"; : > "$TMP/leak.log"
  out="$(EXPECT_CACHE="$R/plugin-cache" AWS_PROFILE=demo AWS_ACCESS_KEY_ID=AKIAFIXTURE GITHUB_TOKEN=x \
    TF_CLI_ARGS_init=-backend=true SSH_AUTH_SOCK=/nonexistent TF_TOKEN_app_terraform_io=fixture \
    TF_CLI_CONFIG_FILE=/nonexistent NETRC=/nonexistent \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=store run run "$R" --files "$TMP/files.json" --base "$BASE" --out "$O")"
  check "$sh: the pass writes its results" "$([ -z "$out" ] && [ -f "$O" ]; echo $?)"
  check "$sh: bound to the head and the merge base" \
    "$(q "$O" ".head_sha == \"$HEAD\" and .base_sha == \"$BASE\"")"
  check "$sh: the terraform version is recorded" "$(q "$O" '.terraform_version == "1.9.8"')"
  check "$sh: example directories in path order, README and non-directories left out" \
    "$(q "$O" '[.dirs[].dir] == ["examples/brokenbase","examples/bump","examples/bumpmajor","examples/codeok","examples/env","examples/initfail","examples/linked","examples/net","examples/net2","examples/newfail","examples/regress"]')"
  check "$sh: a passing example is a code result with no line" \
    "$(q "$O" "$(d codeok '.head == {init:0, validate:0, record:"code-result", line:null} and .base == null')")"
  check "$sh: a failure new under the change is re-run at the merge base" \
    "$(q "$O" "$(d regress '.head.record == "code-result" and .head.validate == 1 and .head.line == "Error: Missing required argument" and .base == {init:0, validate:0, record:"code-result", line:null}')")"
  check "$sh: a failure already at the base reproduces there" \
    "$(q "$O" "$(d brokenbase '.head.validate == 1 and .base.record == "code-result" and .base.validate == 1')")"
  check "$sh: an example the change adds is absent at the base" \
    "$(q "$O" "$(d newfail '.head.validate == 1 and .base == {init:null, validate:null, record:"absent-at-base", line:null}')")"
  check "$sh: a located init error is init-failed, not re-run" \
    "$(q "$O" "$(d initfail '.head == {init:1, validate:null, record:"init-failed", line:"Error: Unsupported argument"} and .base == null')")"
  check "$sh: an unlocated environment marker is not-run-environment, not re-run" \
    "$(q "$O" "$(d env '.head.record == "not-run-environment" and .head.init == 1 and .base == null')")"
  check "$sh: a network marker on a host the change adds is init-failed" \
    "$(q "$O" "$(d net '.head.record == "init-failed"')")"
  check "$sh: a network marker on any other host is not-run-environment" \
    "$(q "$O" "$(d net2 '.head.record == "not-run-environment"')")"
  check "$sh: a version bump within the major is skipped" \
    "$(q "$O" "$(d bump '. == {dir:"examples/bump", reason:"skipped-version-bump", affected:"all", head:null, base:null, outside:false}')")"
  check "$sh: a version bump across a major is verified" \
    "$(q "$O" "$(d bumpmajor '.reason == "verified" and .head.record == "code-result"')")"
  check "$sh: terraform runs only init -backend=false, validate and version" \
    "$(grep -vE '^[^ ]+ (init -backend=false -input=false -no-color|validate -no-color)$|^empty version -json$' "$TMP/tf.log" | grep . > /dev/null; [ $? = 1 ]; echo $?)"
  check "$sh: a skipped example runs nothing" "$(grep -q '^bump ' "$TMP/tf.log"; [ $? = 1 ]; echo $?)"
  check "$sh: no credential or inherited terraform setting reaches terraform, the cache is the run's" \
    "$([ ! -s "$TMP/leak.log" ]; echo $?)"
  check "$sh: the merge base worktree is the pass's own" "$([ -d "$R/verify-base" ] && [ ! -e "$R/base" ]; echo $?)"
  check "$sh: the work directory is removed" "$([ ! -e "$R/verify" ]; echo $?)"

  # A host's results: accepted as produced, rejected on any change of binding or shape.
  chk() { run check "$R" --files "$TMP/files.json" --base "$BASE" --head "${2:-$HEAD}" --results "$1"; }
  out="$(chk "$O")"
  check "$sh: the check accepts the pass's own results" "$([ "$out" = "results accepted" ]; echo $?)"
  out="$(chk "$O" "$BASE")"
  check "$sh: another head SHA is rejected" "$([ "$out" = "results rejected: head_sha" ]; echo $?)"
  jq '.base_sha = "'"$HEAD"'"' "$O" > "$TMP/r1.json"
  check "$sh: another base SHA is rejected" "$([ "$(chk "$TMP/r1.json")" = "results rejected: base_sha" ]; echo $?)"
  jq '.extra = 1' "$O" > "$TMP/r2.json"
  check "$sh: an extra key is rejected" "$([ "$(chk "$TMP/r2.json")" = "results rejected: shape" ]; echo $?)"
  jq '(.dirs[] | select(.dir == "examples/env") | .head.record) = "ok"' "$O" > "$TMP/r3.json"
  check "$sh: an unknown record is rejected" "$([ "$(chk "$TMP/r3.json")" = "results rejected: shape" ]; echo $?)"
  jq '(.dirs[] | select(.dir == "examples/codeok") | .base) = {init:0, validate:0, record:"code-result", line:null}' "$O" > "$TMP/r4.json"
  check "$sh: a base result without a failure is rejected" "$([ "$(chk "$TMP/r4.json")" = "results rejected: shape" ]; echo $?)"
  jq 'del(.dirs[0])' "$O" > "$TMP/r5.json"
  check "$sh: a missing example directory is rejected" \
    "$([ "$(chk "$TMP/r5.json")" = "results rejected: example directories" ]; echo $?)"
  echo 'not json' > "$TMP/r6.json"
  check "$sh: text that is not JSON is rejected" "$([ "$(chk "$TMP/r6.json")" = "results rejected: not JSON" ]; echo $?)"

  # A marker in the tree's own files: the same output is no longer the environment.
  echo 'operation not permitted' > "$R/clone/examples/env/notes.txt"
  O2="$R/only.json"
  out="$(EXPECT_CACHE="$R/plugin-cache" run run "$R" --files "$TMP/files.json" --base "$BASE" --out "$O2" --dir examples/env)"
  check "$sh: --dir limits the pass to the named directory" "$(q "$O2" '[.dirs[].dir] == ["examples/env"]')"
  check "$sh: a marker in the head's own files makes it init-failed" "$(q "$O2" "$(d env '.head.record == "init-failed"')")"
  out="$(run run "$R" --files "$TMP/files.json" --base "$BASE" --out "$O2" --dir examples/other)"
  check "$sh: a --dir outside the change is refused" "$(printf '%s' "$out" | grep 'not an example directory of this change' > /dev/null; echo $?)"

  check "$sh: a symbolic link example directory is recorded, never entered" \
    "$(q "$O" "$(d linked '. == {dir:"examples/linked", reason:"skipped-symlink", affected:"all", head:null, base:null, outside:false}')")"
  check "$sh: nothing ran through the link" "$(grep -q '^linked ' "$TMP/tf.log"; [ $? = 1 ]; echo $?)"
  jq '.dirs[0].outside = true' "$O" > "$TMP/r7.json"
  check "$sh: a host result marked outside is rejected" "$([ "$(chk "$TMP/r7.json")" = "results rejected: shape" ]; echo $?)"

  # The run outside the sandbox, merged: only an entry that ended not-run-environment inside.
  rm -f "$R/clone/examples/env/init.env" "$R/clone/examples/env/notes.txt"
  EXPECT_CACHE="$R/plugin-cache" run run "$R" --files "$TMP/files.json" --base "$BASE" --out "$R/outside.json" --dir examples/env > /dev/null
  out="$(run merge "$R" --results "$O" --outside "$R/outside.json" --out "$R/merged.json")"
  check "$sh: merge replaces the entry and marks it outside" \
    "$(q "$R/merged.json" "$(d env '.outside == true and .head.record == "code-result"')")"
  check "$sh: merge leaves every other entry as it was" \
    "$(jq -e --slurpfile a "$O" '[.dirs[] | select(.dir != "examples/env")] == [$a[0].dirs[] | select(.dir != "examples/env")]' "$R/merged.json" > /dev/null; echo $?)"
  EXPECT_CACHE="$R/plugin-cache" run run "$R" --files "$TMP/files.json" --base "$BASE" --out "$R/other.json" --dir examples/codeok > /dev/null
  out="$(run merge "$R" --results "$O" --outside "$R/other.json" --out "$R/bad.json")"
  check "$sh: merge refuses an entry that did not end not-run-environment inside" \
    "$([ ! -e "$R/bad.json" ] && printf '%s' "$out" | grep 'do not pair' > /dev/null; echo $?)"

  # A merge base the clone cannot fetch.
  R2="$(newrun)"; X="$(printf 'f%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)"
  EXPECT_CACHE="$R2/plugin-cache" run run "$R2" --files "$TMP/files.json" --base "$X" --out "$R2/v.json" --dir examples/regress > /dev/null
  check "$sh: a merge base that cannot be fetched is base-unavailable" \
    "$(q "$R2/v.json" "$(d regress '.base == {init:null, validate:null, record:"base-unavailable", line:null}')")"

  # No terraform at all.
  R3="$(newrun)"
  PATH="$TMP/none:/usr/bin:/bin" "$sh" "$VP" run "$R3" --files "$TMP/files.json" --base "$BASE" --out "$R3/v.json" > /dev/null 2>&1
  check "$sh: without terraform the version is null" "$(q "$R3/v.json" '.terraform_version == null')"
  check "$sh: without terraform every verified example is terraform-absent" \
    "$(q "$R3/v.json" 'all(.dirs[] | select(.reason == "verified"); .head == {init:null, validate:null, record:"terraform-absent", line:null} and .base == null)')"
  check "$sh: without terraform the version bump skip still holds" "$(q "$R3/v.json" "$(d bump '.reason == "skipped-version-bump"')")"

  # Refused inputs write nothing.
  out="$(run run "$TMP/notarun" --files "$TMP/files.json" --base "$BASE" --out "$TMP/x.json")"
  check "$sh: a path that is not a run directory is refused" "$(printf '%s' "$out" | grep 'not a run directory' > /dev/null; echo $?)"
  out="$(run run "$R3" --files "$TMP/files.json" --base main --out "$R3/x.json")"
  out="$(run run "$R3" --files "$TMP/files.json" --base "$BASE
$BASE" --out "$R3/x.json")"
  check "$sh: a base of two lines is refused" "$([ ! -e "$R3/x.json" ] && printf '%s' "$out" | grep 'full commit SHA' > /dev/null; echo $?)"
  check "$sh: a base that is not a full SHA is refused" "$([ ! -e "$R3/x.json" ] && printf '%s' "$out" | grep 'full commit SHA' > /dev/null; echo $?)"
  echo '{"filename":"x"}' > "$TMP/bad.json"
  out="$(run run "$R3" --files "$TMP/bad.json" --base "$BASE" --out "$R3/x.json")"
  check "$sh: a files list that is not an array of file objects is refused" "$([ ! -e "$R3/x.json" ]; echo $?)"

  # Example selection: mtf-facts affected, resolved outside the workspace, or every example.
  R4="$(newrun)"
  sel() { PATH="${2:-$TMP/facts}:$TMP/bin:/usr/bin:/bin" "$sh" "$VP" select "$R4" --files "$TMP/files.json" > "$TMP/sel.json" 2>&1; q "$TMP/sel.json" "$1"; }
  ALLSEL='[.dirs[].dir] == ["examples/brokenbase","examples/bump","examples/bumpmajor","examples/codeok","examples/env","examples/initfail","examples/linked","examples/net","examples/net2","examples/newfail","examples/regress"] and all(.dirs[]; .affected == "all")'
  check "$sh: without mtf-facts every example is selected, reason all" \
    "$(sel ".selection == {tool:\"absent\", fallback:null, inert:false} and $ALLSEL" "$TMP/none")"
  facts '{schema_version:1, inert:false, fallback:null, changed:["main.tf"],
    examples:([{dir:"examples/regress", reason:"touched"}, {dir:"examples/codeok", reason:"caller"}]
      + [$r[] | select(. != "regress" and . != "codeok") | {dir:"examples/\(.)", reason:"all"}])}'
  : > "$TMP/facts.log"
  check "$sh: mtf-facts orders the selection: touched, caller, then the rest" \
    "$(sel '.selection == {tool:"mtf-facts", fallback:null, inert:false}
      and [.dirs[] | "\(.affected) \(.dir)"][:3] == ["touched examples/regress","caller examples/codeok","all examples/brokenbase"]
      and (.dirs | length) == 11 and .dirs[-1].dir == "examples/linked"')"
  check "$sh: mtf-facts runs on the module root with the changed files list" \
    "$(grep -qE "^affected $R4/clone --diff $R4/verify-select/affected-files.json --json\$" "$TMP/facts.log"; echo $?)"
  facts '{schema_version:1, inert:true, fallback:null, changed:["README.md"], examples:[$r[] | {dir:"examples/\(.)", reason:"all"}]}'
  check "$sh: an inert change keeps every example in the tool's order, recorded" \
    "$(sel '.selection == {tool:"mtf-facts", fallback:null, inert:true} and (.dirs | length) == 11 and .dirs[0].dir == "examples/brokenbase"')"
  facts '{schema_version:1, inert:false, fallback:"unparsed", changed:["main.tf"], examples:[$r[] | {dir:"examples/\(.)", reason:"all"}]}'
  check "$sh: the tool's own fallback is recorded, every example selected" \
    "$(sel '.selection == {tool:"mtf-facts", fallback:"unparsed", inert:false} and (.dirs | length) == 11')"
  facts '{}' fail
  check "$sh: a failing mtf-facts selects every example, recorded" \
    "$(sel ".selection == {tool:\"failed\", fallback:null, inert:false} and $ALLSEL")"
  facts '{}' garbage
  check "$sh: output that is not JSON is a failure" "$(sel '.selection.tool == "failed"')"
  facts '{schema_version:1, inert:false, fallback:null, changed:[], examples:[$r[1:][] | {dir:"examples/\(.)", reason:"all"}]}'
  check "$sh: a document missing an example is invalid, every example selected" \
    "$(sel ".selection == {tool:\"invalid\", fallback:null, inert:false} and $ALLSEL")"
  facts '{schema_version:1, inert:false, fallback:null, changed:[], examples:([$r[] | {dir:"examples/\(.)", reason:"all"}] + [{dir:"examples/../x", reason:"all"}])}'
  check "$sh: a path outside the pattern is invalid" "$(sel '.selection.tool == "invalid"')"
  facts '{schema_version:1, inert:true, fallback:"unparsed", changed:[], examples:[$r[] | {dir:"examples/\(.)", reason:"all"}]}'
  check "$sh: inert with a fallback is invalid" "$(sel '.selection.tool == "invalid" and (.dirs | length) == 11')"
  mkdir -p "$R4/clone/bin" && cp "$TMP/facts/mtf-facts" "$R4/clone/bin/" && facts '{schema_version:1, inert:true, fallback:null, changed:[], examples:[]}'
  check "$sh: an mtf-facts inside the workspace is never run" \
    "$(sel '.selection.tool == "absent"' "$R4/clone/bin")"
  rm -rf "$R4/clone/bin"

  # A module under a prefix: mtf-facts gets the module root and the files list cut to it.
  R6="$(mktemp -d "$TMP/pr-review.XXXXXX")"; mkdir -p "$R6/clone/mod/examples/a" "$R6/clone/mod/examples/b"
  echo 'module "m" { source = "../../" }' > "$R6/clone/mod/examples/a/main.tf"; cp "$R6/clone/mod/examples/a/main.tf" "$R6/clone/mod/examples/b/main.tf"
  { f mod/main.tf modified; f other/x.tf modified; f mod/examples/b/main.tf added; } | jq -s . > "$TMP/files6.json"
  jq -n '{schema_version:1, inert:false, fallback:null, changed:["main.tf"], examples:[{dir:"examples/b", reason:"touched"}, {dir:"examples/a", reason:"caller"}]}' > "$TMP/facts.out"; : > "$TMP/facts.mode"
  PATH="$TMP/facts:$TMP/bin:/usr/bin:/bin" "$sh" "$VP" select "$R6" --files "$TMP/files6.json" --prefix mod > "$TMP/sel6.json" 2>&1
  check "$sh: under a prefix, the selection is repository-relative in the tool's order" \
    "$(q "$TMP/sel6.json" '[.dirs[] | "\(.affected) \(.dir)"] == ["touched mod/examples/b", "caller mod/examples/a"]')"
  check "$sh: under a prefix, mtf-facts reads the files list cut to the module root" \
    "$(jq -e '[.[].filename] == ["main.tf", "examples/b/main.tf"]' "$TMP/facts-diff.json" > /dev/null 2>&1; echo $?)"

  # The selection reaches the results and the check binds it.
  facts '{schema_version:1, inert:false, fallback:null, changed:["main.tf"],
    examples:([{dir:"examples/regress", reason:"touched"}] + [$r[] | select(. != "regress") | {dir:"examples/\(.)", reason:"all"}])}'
  PATH="$TMP/facts:$TMP/bin:/usr/bin:/bin" EXPECT_CACHE="$R4/plugin-cache" "$sh" "$VP" run "$R4" --files "$TMP/files.json" --base "$BASE" --out "$R4/v.json" > /dev/null 2>&1
  check "$sh: the results carry the selection and each example's reason" \
    "$(q "$R4/v.json" '.selection.tool == "mtf-facts" and .dirs[0].dir == "examples/regress" and .dirs[0].affected == "touched"')"
  out="$(PATH="$TMP/facts:$TMP/bin:/usr/bin:/bin" "$sh" "$VP" check "$R4" --files "$TMP/files.json" --base "$BASE" --head "$HEAD" --results "$R4/v.json" 2>&1)"
  check "$sh: the check accepts results with the same selection" "$([ "$out" = "results accepted" ]; echo $?)"
  out="$(PATH="$TMP/none:/usr/bin:/bin" "$sh" "$VP" check "$R4" --files "$TMP/files.json" --base "$BASE" --head "$HEAD" --results "$R4/v.json" 2>&1)"
  check "$sh: a check that selects otherwise rejects them" "$([ "$out" = "results rejected: example directories" ]; echo $?)"

  # The budget, the command limits and the process groups.
  R5="$(newrun)"; rm -f "$TMP/survivor"
  : > "$R5/clone/examples/brokenbase/init.slow"
  EXPECT_CACHE="$R5/plugin-cache" run run "$R5" --files "$TMP/files.json" --base "$BASE" --out "$R5/v.json" --budget 2 > /dev/null
  check "$sh: a command the budget stops is not-run-budget" \
    "$(q "$R5/v.json" "$(d brokenbase '.head.record == "not-run-budget" and .head.validate == null and .base == null')")"
  check "$sh: an example the budget does not reach is not-run-budget, nothing run" \
    "$(q "$R5/v.json" "$(d codeok '.head == {init:null, validate:null, record:"not-run-budget", line:null}')")"
  check "$sh: the check accepts not-run-budget" "$([ "$(run check "$R5" --files "$TMP/files.json" --base "$BASE" --head "$HEAD" --results "$R5/v.json")" = "results accepted" ]; echo $?)"
  sleep 3
  check "$sh: the stopped command's process group is gone" "$([ ! -e "$TMP/survivor" ]; echo $?)"
  rm -f "$R5/clone/examples/brokenbase/init.slow"; : > "$R5/clone/examples/codeok/init.big"
  EXPECT_CACHE="$R5/plugin-cache" run run "$R5" --files "$TMP/files.json" --base "$BASE" --out "$R5/c.json" --dir examples/codeok > /dev/null
  check "$sh: a command over the 1 MiB output cap is not-run-limit" \
    "$(q "$R5/c.json" "$(d codeok '.head == {init:124, validate:null, record:"not-run-limit", line:null}')")"
  out="$(run run "$R5" --files "$TMP/files.json" --base "$BASE" --out "$R5/x.json" --budget 0)"
  check "$sh: a budget that is not a number of seconds is refused" "$([ ! -e "$R5/x.json" ]; echo $?)"

  # Plan coverage of the selection.
  cov() { run coverage "$R4" --files "$TMP/files.json" --out "$TMP/cov.json" "$@" > /dev/null; }
  cov --no-plan
  check "$sh: no plan: coverage none, every example unplanned for want of a profile" \
    "$(q "$TMP/cov.json" '.class == "none" and .inert == false and (.unplanned | length) == 11
      and all(.unplanned[]; .reason == "no AWS profile named") and all(.examples[]; .head == "not run" and .base == null)')"
  printf '%s\n' 'plan pass mode: laptop' 'example: examples/codeok' 'plan: planned | Plan: 1 to add, 0 to change, 0 to destroy.' \
    'example: examples/regress' 'plan: code-error | Error: x | y' 'base: reproduces at base' \
    'example: examples/env' 'plan: plan gate G3 examples/env/main.tf:1 (1 hits)' \
    'example: examples/newfail' 'plan: code-error' 'base: not available' 'example: examples/net' 'plan: forged class' \
    'plan summary: 5 examples, 1 planned, 0 exceptions, 4 other' > "$TMP/rec.txt"
  mkdir -p "$TMP/addr"
  echo '{"addresses":["module.b.aws_s3_bucket.this","aws_x.y[\"secret\"]",7],"attributes":{"module.b.aws_s3_bucket.this":["bucket","Bad",1],"other":["x"]},"module_calls":{"b":"../../","out":"../../../x","reg":"terraform-aws-modules/x/aws"}}' > "$TMP/addr/addresses-1.json"
  echo '{"addresses":["aws_y.z"]}' > "$TMP/addr/addresses-2.json"
  cov --plan "$TMP/rec.txt" --addresses "$TMP/addr"
  check "$sh: a laptop record: partial coverage" "$(q "$TMP/cov.json" '.class == "partial"')"
  check "$sh: a planned example carries its cleaned addresses, attributes and local module calls resolved inside the repository" \
    "$(q "$TMP/cov.json" '.examples[] | select(.dir == "examples/codeok") | .head == "planned" and .addresses == ["module.b.aws_s3_bucket.this"] and .attributes == {"module.b.aws_s3_bucket.this":["bucket"]}
      and .module_calls == {"b":"."}')"
  check "$sh: a code error classified at the base is covered, with no addresses" \
    "$(q "$TMP/cov.json" '(.examples[] | select(.dir == "examples/regress") | .head == "code-error" and .base == "reproduces at base" and .addresses == [])
      and ([.unplanned[].dir] | index("examples/regress") == null)')"
  check "$sh: unplanned examples carry fixed reasons" \
    "$(q "$TMP/cov.json" '[.unplanned[] | select(.dir | IN("examples/env","examples/newfail","examples/net","examples/bump"))] ==
      [{dir:"examples/bump", reason:"not reached by the plan pass"}, {dir:"examples/env", reason:"plan gate G3"},
       {dir:"examples/net", reason:"output unrecognised"}, {dir:"examples/newfail", reason:"code-error, merge base not planned"}]')"
  printf '%s\n' 'plan pass mode: runner' 'host example 1: examples/codeok' 'example: examples/regress' 'plan: planned' \
    'host example 2: examples/net' 'plan pass mode: laptop' 'example: examples/env' 'plan: planned' 'plan summary: 2 examples' > "$TMP/rec.txt"
  cov --plan "$TMP/rec.txt" --addresses "$TMP/addr"
  check "$sh: a runner record is keyed by the host's lines, a forged example line claims nothing" \
    "$(q "$TMP/cov.json" '(.examples[] | select(.dir == "examples/codeok") | .head == "planned" and .addresses == ["module.b.aws_s3_bucket.this"])
      and (.examples[] | select(.dir == "examples/regress") | .head == "not run")
      and (.examples[] | select(.dir == "examples/net") | .head == "planned" and .addresses == ["aws_y.z"])
      and (.examples[] | select(.dir == "examples/env") | .head == "not run")')"
  { echo 'plan pass mode: laptop'; for e in brokenbase bump bumpmajor codeok env initfail linked net net2 newfail regress; do
      printf 'example: examples/%s\nplan: planned-no-changes\n' "$e"; done; } > "$TMP/rec.txt"
  cov --plan "$TMP/rec.txt"
  check "$sh: every example planned: coverage complete, nothing unplanned" "$(q "$TMP/cov.json" '.class == "complete" and .unplanned == []')"
  jq -n '{schema_version:1, head:"x", merge_base:"y", refused_hosts:0, examples:[
    {path:"examples/codeok", head:{class:"planned", plan:{add:1, change:0, destroy:0}}, base:null, addresses:["aws_a.b"], attributes:{"aws_a.b":["name"]}},
    {path:"examples/regress", head:{class:"code-error", plan:null}, base:{class:"new under this change", plan:null}},
    {path:"examples/env", head:{class:"plan gate G1", plan:null}, base:null}]}' > "$TMP/hosted.json"
  cov --hosted "$TMP/hosted.json"
  check "$sh: a hosted plan record gives classes and addresses" \
    "$(q "$TMP/cov.json" '.class == "partial" and (.examples[] | select(.dir == "examples/codeok") | .addresses == ["aws_a.b"] and .attributes == {"aws_a.b":["name"]})
      and (.unplanned[] | select(.dir == "examples/env") | .reason == "plan gate G1")
      and ([.unplanned[].dir] | index("examples/regress") == null)')"
  facts '{schema_version:1, inert:true, fallback:null, changed:["README.md"], examples:[$r[] | {dir:"examples/\(.)", reason:"all"}]}'
  PATH="$TMP/facts:$TMP/bin:/usr/bin:/bin" "$sh" "$VP" coverage "$R4" --files "$TMP/files.json" --out "$TMP/cov.json" --no-plan > /dev/null 2>&1
  check "$sh: an inert change still lists its unplanned examples, recorded as inert" \
    "$(q "$TMP/cov.json" '.inert == true and .class == "none" and (.examples | length) == 11 and (.unplanned | length) == 11')"
  # No example directory at all: coverage none with a fixed reason, unless the change is inert.
  R7="$(mktemp -d "$TMP/pr-review.XXXXXX")"; mkdir -p "$R7/clone"
  run coverage "$R7" --files "$TMP/files.json" --out "$TMP/cov7.json" --no-plan > /dev/null
  check "$sh: no example directory: coverage none, one fixed line" \
    "$(q "$TMP/cov7.json" '.class == "none" and .examples == [] and .unplanned == [{dir:"examples", reason:"no example directory"}]')"
  facts '{schema_version:1, inert:true, fallback:null, changed:["README.md"], examples:[]}'
  PATH="$TMP/facts:$TMP/bin:/usr/bin:/bin" "$sh" "$VP" coverage "$R7" --files "$TMP/files.json" --out "$TMP/cov7.json" --no-plan > /dev/null 2>&1
  check "$sh: no example directory and an inert change: complete" "$(q "$TMP/cov7.json" '.class == "complete" and .unplanned == []')"

  # The merge base fetch runs under the budget: a fetch that hangs is base-unavailable.
  mkdir -p "$TMP/slowgit"
  printf '#!/bin/sh\ncase " $* " in *" fetch "*) sleep 30 ;; esac\nexec %s "$@"\n' "$(command -v git)" > "$TMP/slowgit/git"; chmod +x "$TMP/slowgit/git"
  R8="$(newrun)"; t8=$SECONDS
  PATH="$TMP/slowgit:$TMP/bin:/usr/bin:/bin" EXPECT_CACHE="$R8/plugin-cache" "$sh" "$VP" run "$R8" --files "$TMP/files.json" --base "$X" --out "$R8/v.json" --dir examples/regress --budget 3 > /dev/null 2>&1
  check "$sh: a merge base fetch over the budget is base-unavailable, the pass ends in time" \
    "$([ $((SECONDS - t8)) -lt 15 ] && [ "$(q "$R8/v.json" "$(d regress '.base.record == "base-unavailable"')")" = 0 ]; echo $?)"
  out="$(run coverage "$R4" --files "$TMP/files.json" --out "$TMP/cov2.json" --no-plan --plan "$TMP/rec.txt")"
  check "$sh: coverage takes exactly one plan source" "$([ ! -e "$TMP/cov2.json" ]; echo $?)"
done

[ "$fails" -eq 0 ] && echo "all passed" || echo "$fails failed"
[ "$fails" -eq 0 ]
