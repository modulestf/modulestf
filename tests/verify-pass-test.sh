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
    "$(q "$O" "$(d bump '. == {dir:"examples/bump", reason:"skipped-version-bump", head:null, base:null, outside:false}')")"
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
    "$(q "$O" "$(d linked '. == {dir:"examples/linked", reason:"skipped-symlink", head:null, base:null, outside:false}')")"
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
done

[ "$fails" -eq 0 ] && echo "all passed" || echo "$fails failed"
[ "$fails" -eq 0 ]
