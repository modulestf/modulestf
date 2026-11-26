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
# The mutated copies of the script below source the resolver from their own directory.
cp "${VP%/*}/facts-resolve.sh" "$TMP/facts-resolve.sh"

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
echo "\${TMPDIR:-}" >> "$TMP/tmpdir.log"
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
  # A provider plugin socket at $TMPDIR/plugin<10 digits> over macOS's 103 bytes fails as
  # terraform 1.17 fails it
  if [ \${#TMPDIR} -gt 86 ]; then
    printf 'Error: Failed to load plugin schemas\n\nError while loading schemas for plugin components: Failed to obtain provider schema: Could not load the schema for provider registry.terraform.io/hashicorp/aws: failed to instantiate provider "registry.terraform.io/hashicorp/aws" to obtain schema: Unrecognized remote plugin message:\n'; exit 1
  fi
  if [ -f validate.fail ]; then
    printf 'Error: Missing required argument\n\n  on main.tf line 1:\n   1: dial tcp\n'; exit 1
  fi ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/terraform"

# mtf-facts affected, stubbed: logs its arguments and prints facts.out, or fails.
mkdir -p "$TMP/facts"
# version --json prints facts.version when that file exists; else it fails as a release before
# the version report does.
cat > "$TMP/facts/mtf-facts" <<EOF
#!/bin/sh
if [ "\$1" = version ]; then
  [ "\${2:-}" = --json ] || { echo v0.8.0; exit 0; }
  [ -f "$TMP/facts.version" ] || { echo 'mtf-facts: unknown flag: --json' >&2; exit 2; }
  cat "$TMP/facts.version"; exit 0
fi
echo "\$*" >> "$TMP/facts.log"
while [ \$# -gt 0 ]; do [ "\$1" = --diff ] && cp "\$2" "$TMP/facts-diff.json"; shift; done
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
  # facts-resolve.sh, sourced: one line per binary state, the bounds of the version report,
  # and a binary inside a refused directory never run.
  FR="${VP%/*}/facts-resolve.sh"
  mkdir -p "$TMP/fr/bin" "$TMP/fr/refused"
  frstub() { printf '#!/bin/sh\n%s\n' "$1" > "$2/mtf-facts"; chmod +x "$2/mtf-facts"; }
  frline() { PATH="${1:-$TMP/fr/bin}:/usr/bin:/bin" "$sh" -c '. "$1"; facts_resolve "$2"; printf "%s|" "$FACTS_STATE"; facts_line' sh "$FR" "$TMP/fr/refused"; }
  frstub 'echo "{\"schema_version\":1,\"version\":\"v0.13.0\",\"features\":[\"flag:affected:module-root\",\"flag:profile-check:profile-dir\"]}"' "$TMP/fr/bin"
  check "$sh: resolver: a binary with every feature is one plain line" "$([ "$(frline)" = "ok|mtf-facts: v0.13.0" ]; echo $?)"
  frstub 'echo "{\"schema_version\":1,\"version\":\"v0.11.1\",\"features\":[\"flag:profile-check:profile-dir\"]}"' "$TMP/fr/bin"
  check "$sh: resolver: a binary one release too old names the feature and the release it needs" \
    "$([ "$(frline)" = "ok|mtf-facts: v0.11.1, missing flag:affected:module-root (v0.12.0 or later reports it); the steps that need it use their older path" ]; echo $?)"
  frstub '[ "$2" = --json ] && exit 2; echo v0.8.0' "$TMP/fr/bin"
  check "$sh: resolver: a release before the version report names its version and the one it needs" \
    "$([ "$(frline)" = "old|mtf-facts: v0.8.0, no feature report (v0.12.0 or later reports every feature this skill reads); every step uses its older path" ]; echo $?)"
  frstub 'echo "{\"schema_version\":2,\"version\":\"v9.0.0\",\"features\":[]}"' "$TMP/fr/bin"
  check "$sh: resolver: a report of another schema is refused, not read as old" "$(case "$(frline)" in "refused|mtf-facts: version unknown, its version report was refused;"*) echo 0 ;; *) echo 1 ;; esac)"
  frstub 'head -c 70000 /dev/zero | tr "\0" x' "$TMP/fr/bin"
  check "$sh: resolver: a report over 64 KiB is refused" "$(case "$(frline)" in refused*) echo 0 ;; *) echo 1 ;; esac)"
  frstub 'sleep 30' "$TMP/fr/bin"
  t0=$SECONDS
  check "$sh: resolver: a report past 10 seconds times out and leaves no process" \
    "$(case "$(frline)" in timeout*) [ $((SECONDS - t0)) -le 15 ] && ! pgrep -f "$TMP/fr/bin/mtf-facts" > /dev/null; echo $? ;; *) echo 1 ;; esac)"
  frstub 'echo "{\"schema_version\":1,\"version\":\"v0.13.0\",\"features\":[]}"' "$TMP/fr/refused"
  check "$sh: resolver: a binary inside a refused directory is never run" "$([ "$(frline "$TMP/fr/refused")" = "absent|mtf-facts: not installed" ]; echo $?)"
  check "$sh: resolver: facts_has matches a whole feature name only" \
    "$(PATH="$TMP/fr/bin:/usr/bin:/bin" "$sh" -c '. "$1"; FACTS_FEATURES="flag:affected:module-root"; facts_has flag:affected:module-root && ! facts_has flag:affected && ! facts_has module-root' sh "$FR"; echo $?)"
  # An empty name or one with a line break matches nothing, and neither does a name over 128 bytes.
  FHT='. "$1"; L=$(printf "%0129d" 0); NL="
"
    FACTS_FEATURES=""; ! facts_has "" && FACTS_FEATURES="flag:a${NL}flag:b" && ! facts_has "flag:a${NL}flag:b" \
      && facts_has flag:a && facts_has flag:b && FACTS_FEATURES=$L && ! facts_has "$L"'
  check "$sh: resolver: facts_has refuses an empty name, a name with a line break and one over 128 bytes" \
    "$("$sh" -c "$FHT" sh "$FR"; echo $?)"
  perl -0pe 's/  case "\$1" in .*?\n  \[ "\$\{#1\}" -le 128 \] \|\| return 1\n//s' "$FR" > "$TMP/fr-has.sh"
  check "$sh: resolver: the mutation without the facts_has name check is caught" \
    "$( ! cmp -s "$FR" "$TMP/fr-has.sh" && ! "$sh" -c "$FHT" sh "$TMP/fr-has.sh" 2> /dev/null; echo $?)"
  # The negative self-check: a copy that reads any exit of version --json as old, and one with
  # no output cap.
  perl -0pe 's/    125\) FACTS_STATE=refused ;;\n//' "$FR" > "$TMP/fr-cap.sh"
  frstub 'head -c 70000 /dev/zero | tr "\0" x; exit 0' "$TMP/fr/bin"
  check "$sh: resolver: the mutation that reads an over-cap report as old is caught" \
    "$( ! cmp -s "$FR" "$TMP/fr-cap.sh" && [ "$(PATH="$TMP/fr/bin:/usr/bin:/bin" "$sh" -c '. "$1"; facts_resolve; echo "$FACTS_STATE"' sh "$TMP/fr-cap.sh")" != refused ]; echo $?)"
  perl -0pe 's/\$n \+= \$k; \$stop->\(125\) if \$n > \$cap;/\$n += \$k;/' "$FR" > "$TMP/fr-nocap.sh"
  jq -nc '{schema_version:1, version:"v0.13.0", features:[range(700) | "flag:x:" + ("y" * 100) + tostring]}' > "$TMP/fr/big.json"
  frstub "cat '$TMP/fr/big.json'" "$TMP/fr/bin"
  check "$sh: resolver: the mutation without the output cap is caught" \
    "$( ! cmp -s "$FR" "$TMP/fr-nocap.sh" && [ "$(PATH="$TMP/fr/bin:/usr/bin:/bin" "$sh" -c '. "$1"; facts_resolve; echo "$FACTS_STATE"' sh "$TMP/fr-nocap.sh")" != refused ]; echo $?)"
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

  # A submodule whose examples sit at the repository root: those whose local source resolves to
  # it are selected after its own, touched before caller; the rest, a source that climbs out of
  # the repository, a link and a module root reached through a link are not.
  R9="$(mktemp -d "$TMP/pr-review.XXXXXX")"; C9="$R9/clone"
  mkdir -p "$C9/modules/a/examples/own" "$C9/modules/b" "$C9/examples/calls" "$C9/examples/touched" \
    "$C9/examples/other" "$C9/examples/escape" "$C9/examples/vialink" "$C9/outside"
  echo 'variable "v" {}' > "$C9/modules/a/main.tf"; cp "$C9/modules/a/main.tf" "$C9/modules/b/main.tf"
  echo 'module "a" { source = "../../" }' > "$C9/modules/a/examples/own/main.tf"
  printf 'module "a" {\n  source  = "../../modules/a"\n}\n' > "$C9/examples/calls/main.tf"
  echo 'module "a" { source = "./../../modules/a/" }' > "$C9/examples/touched/main.tf"
  echo 'module "b" { source = "../../modules/b" }' > "$C9/examples/other/main.tf"
  echo 'module "a" { source = "../../../clone/modules/a" }' > "$C9/examples/escape/main.tf"
  ln -s modules/a "$C9/alink"; echo 'module "a" { source = "../../alink" }' > "$C9/examples/vialink/main.tf"
  ln -s calls "$C9/examples/linked"
  # A source that is no module call: commented out, in a block comment, in a heredoc, a file source.
  mkdir -p "$C9/examples/commented" "$C9/examples/blockcomment" "$C9/examples/heredoc" "$C9/examples/filesource"
  printf 'module "b" { source = "../../modules/b" }\n# module "a" { source = "../../modules/a" }\n' > "$C9/examples/commented/main.tf"
  printf '/* module "a" {\n  source = "../../modules/a"\n} */\n' > "$C9/examples/blockcomment/main.tf"
  printf 'locals {\n  x = <<-EOT\n    module "a" {\n      source = "../../modules/a"\n    }\n    EOT\n}\n' > "$C9/examples/heredoc/main.tf"
  printf 'resource "aws_s3_object" "o" {\n  source = "../../modules/a/main.tf"\n}\nresource "aws_s3_object" "p" {\n  source = "../../modules/a"\n}\n' > "$C9/examples/filesource/main.tf"
  ln -s ../examples/calls/main.tf "$C9/outside/x.tf"; mkdir "$C9/examples/tflink"; ln -s ../../outside/x.tf "$C9/examples/tflink/main.tf"
  git -C "$C9" init -q && git -C "$C9" add -A && git -C "$C9" -c user.name=t -c user.email=t@example.invalid commit -qm head
  { f modules/a/main.tf modified; f examples/touched/main.tf modified; } | jq -s . > "$TMP/files9.json"
  sel9() { PATH="${2:-$TMP/none}:$TMP/bin:/usr/bin:/bin" "$sh" "$VP" select "$R9" --files "$TMP/files9.json" --prefix "$1" 2>&1; }
  sel9 modules/a > "$TMP/sel9.json"
  check "$sh: a submodule change selects the repository root examples that call it, touched first, after its own" \
    "$(q "$TMP/sel9.json" '[.dirs[] | "\(.affected) \(.dir)"] == ["all modules/a/examples/own", "touched examples/touched", "caller examples/calls"]')"
  check "$sh: a root example calling another submodule, a source out of the repository, a link or a .tf link is not selected" \
    "$(q "$TMP/sel9.json" '[.dirs[].dir] | all(.[]; IN("examples/other", "examples/escape", "examples/vialink", "examples/linked", "examples/tflink") | not)')"
  check "$sh: a source in a comment, a block comment, a heredoc or a resource is no module call" \
    "$(q "$TMP/sel9.json" '[.dirs[].dir] | all(.[]; IN("examples/commented", "examples/blockcomment", "examples/heredoc", "examples/filesource") | not)')"
  check "$sh: the other submodule is called from beside a commented-out call" \
    "$(q <(sel9 modules/b) '[.dirs[].dir] == ["examples/commented", "examples/other"]')"
  jq -n '{schema_version:1, inert:false, fallback:null, changed:["main.tf"], examples:[{dir:"examples/own", reason:"touched"}]}' > "$TMP/facts.out"; : > "$TMP/facts.mode"
  check "$sh: with mtf-facts, the root examples follow the tool's own list" \
    "$(q <(sel9 modules/a "$TMP/facts") '.selection.tool == "mtf-facts" and [.dirs[] | "\(.affected) \(.dir)"] == ["touched modules/a/examples/own", "touched examples/touched", "caller examples/calls"]')"
  # An mtf-facts whose version report lists affected --module-root: one run on the repository
  # root gives the module root's examples and the root examples that call it; the selection is
  # the one the scan gives. A report that does not fit falls back to the scan.
  feat() { jq -n --argjson f "$1" '{schema_version:1, name:"mtf-facts", version:"v0.13.0", reports:{affected:1}, features:$f}' > "$TMP/facts.version"; }
  feat '["cmd:affected","flag:affected:module-root"]'
  rootrep() { jq -n "$1" > "$TMP/facts.out"; : > "$TMP/facts.mode"; }
  rootrep '{schema_version:1, module_root:"modules/a", inert:false, fallback:null, changed:["modules/a/main.tf","examples/touched/main.tf"],
    examples:[{dir:"examples/touched", reason:"touched"}, {dir:"modules/a/examples/own", reason:"touched"}, {dir:"examples/calls", reason:"caller"}]}'
  : > "$TMP/facts.log"
  check "$sh: with affected --module-root, the selection is the scan's order, own examples first" \
    "$(q <(sel9 modules/a "$TMP/facts") '.selection == {tool:"mtf-facts", fallback:null, inert:false} and [.dirs[] | "\(.affected) \(.dir)"] == ["touched modules/a/examples/own", "touched examples/touched", "caller examples/calls"]')"
  check "$sh: affected --module-root runs once, on the repository root with the whole files list as an absolute copy" \
    "$([ "$(cat "$TMP/facts.log")" = "affected $C9 --module-root modules/a --diff $R9/verify-select/affected-files.json --json" ] && cmp -s "$TMP/files9.json" "$TMP/facts-diff.json"; echo $?)"
  rootrep '{schema_version:1, module_root:"modules/a", inert:false, fallback:null, changed:["modules/a/main.tf"],
    examples:[{dir:"modules/a/examples/own", reason:"caller"}, {dir:"examples/zz", reason:"all", unresolved:true}, {dir:"examples/touched", reason:"all"}, {dir:"examples/calls", reason:"caller"}]}'
  check "$sh: a root example that calls the module root is a caller, one the tool could not resolve comes last with reason all" \
    "$(q <(sel9 modules/a "$TMP/facts") '[.dirs[] | "\(.affected) \(.dir)"] == ["caller modules/a/examples/own", "caller examples/calls", "caller examples/touched"]')"
  for bad in '.module_root = "modules/b"' '.examples += [{dir:"examples/a b", reason:"all"}]' '.examples |= map(select(.dir != "modules/a/examples/own"))' \
      '.examples += [{dir:"modules/a/examples/nope", reason:"all"}]' '.examples[0].unresolved = true' \
      '.examples += [{dir:"examples/calls", reason:"caller"}]' '.examples += [{dir:"modules/a/examples/own", reason:"all"}]'; do
    jq "$bad" "$TMP/facts.out" > "$TMP/facts.bad" && cp "$TMP/facts.out" "$TMP/facts.good" && cp "$TMP/facts.bad" "$TMP/facts.out"
    check "$sh: a module root report that does not fit ($bad) is invalid, the scan selects" \
      "$(q <(sel9 modules/a "$TMP/facts") '.selection.tool == "invalid" and [.dirs[] | "\(.affected) \(.dir)"] == ["all modules/a/examples/own", "touched examples/touched", "caller examples/calls"]')"
    cp "$TMP/facts.good" "$TMP/facts.out"
  done
  feat '["cmd:affected"]'; : > "$TMP/facts.log"
  check "$sh: a version report without the feature keeps the run on the module root and the scan" \
    "$([ "$(q <(sel9 modules/a "$TMP/facts") '[.dirs[1:][] | "\(.affected) \(.dir)"] == ["touched examples/touched", "caller examples/calls"]')" = 0 ] && grep -q "^affected $C9/modules/a --diff" "$TMP/facts.log"; echo $?)"
  # The negative self-check: a copy that takes the module root path with no feature check, and
  # one that does not check the report's module root.
  feat '["cmd:affected","flag:affected:module-root"]'
  rootrep '{schema_version:1, module_root:"modules/b", inert:false, fallback:null, changed:[], examples:[{dir:"modules/a/examples/own", reason:"all"}]}'
  perl -0pe 's/ and \.module_root == \(\$pre \| rtrimstr\("\/"\)\)//' "$VP" > "$TMP/vp-mr.sh"
  check "$sh: the mutation without the module root check is caught" \
    "$( ! cmp -s "$VP" "$TMP/vp-mr.sh" && PATH="$TMP/facts:$TMP/bin:/usr/bin:/bin" "$sh" "$TMP/vp-mr.sh" select "$R9" --files "$TMP/files9.json" --prefix modules/a 2>&1 | jq -e '.selection.tool == "mtf-facts"' > /dev/null; echo $?)"
  rm -f "$TMP/facts.version"; : > "$TMP/facts.log"
  perl -0pe 's/\[ -n "\$PREFIX" \] && facts_has flag:affected:module-root/[ -n "\$PREFIX" ]/' "$VP" > "$TMP/vp-gate.sh"
  PATH="$TMP/facts:$TMP/bin:/usr/bin:/bin" "$sh" "$TMP/vp-gate.sh" select "$R9" --files "$TMP/files9.json" --prefix modules/a > /dev/null 2>&1
  check "$sh: the mutation without the feature check is caught" \
    "$( ! cmp -s "$VP" "$TMP/vp-gate.sh" && grep -q -- '--module-root' "$TMP/facts.log"; echo $?)"
  # mutsel: 0 when the script's select output is JSON that does not satisfy the jq test.
  mutsel() { # script, files, prefix, jq test
    PATH="$TMP/facts:$TMP/bin:/usr/bin:/bin" "$sh" "$1" select "$R9" --files "$2" --prefix "$3" > "$TMP/mut.json" 2>&1
    jq -e . "$TMP/mut.json" > /dev/null 2>&1 && ! jq -e "$4" "$TMP/mut.json" > /dev/null 2>&1
  }
  feat '["cmd:affected","flag:affected:module-root"]'
  # A directory listed twice in a module root report makes it invalid; the scan selects.
  rootrep '{schema_version:1, module_root:"modules/a", inert:false, fallback:null, changed:["modules/a/main.tf"],
    examples:[{dir:"modules/a/examples/own", reason:"caller"}, {dir:"examples/calls", reason:"caller"}, {dir:"examples/calls", reason:"caller"}]}'
  DUPOK='.selection.tool == "invalid"'
  check "$sh: a module root report that lists a directory twice is invalid" \
    "$(q <(sel9 modules/a "$TMP/facts") "$DUPOK")"
  perl -0pe 's/(AFFECTED_ROOT_JQ=.*?)\n  and \(\[\.examples\[\]\.dir\] \| length == \(unique \| length\)\)/$1/s' "$VP" > "$TMP/vp-dup.sh"
  check "$sh: the mutation without the no-duplicate check of the module root report is caught" \
    "$( ! cmp -s "$VP" "$TMP/vp-dup.sh" && mutsel "$TMP/vp-dup.sh" "$TMP/files9.json" modules/a "$DUPOK"; echo $?)"
  # Under a fallback every root example stays reason all; only a report with none says caller.
  rootrep '{schema_version:1, module_root:"modules/a", inert:false, fallback:"dynamic-source", changed:["modules/a/main.tf"],
    examples:[{dir:"modules/a/examples/own", reason:"all"}, {dir:"examples/calls", reason:"all"}, {dir:"examples/touched", reason:"all"}]}'
  FBOK='.selection.fallback == "dynamic-source" and [.dirs[] | "\(.affected) \(.dir)"] == ["all modules/a/examples/own", "all examples/calls", "all examples/touched"]'
  check "$sh: under a fallback the root examples keep reason all, none is a caller" \
    "$(q <(sel9 modules/a "$TMP/facts") "$FBOK")"
  perl -0pe 's/\\\(\$cl\)/caller/' "$VP" > "$TMP/vp-fb.sh"
  check "$sh: the mutation that labels every root example a caller under a fallback is caught" \
    "$( ! cmp -s "$VP" "$TMP/vp-fb.sh" && mutsel "$TMP/vp-fb.sh" "$TMP/files9.json" modules/a "$FBOK"; echo $?)"
  # A relative --files reaches an engine that runs from /: it gets an absolute copy.
  rootrep '{schema_version:1, module_root:"modules/a", inert:false, fallback:null, changed:["modules/a/main.tf"],
    examples:[{dir:"modules/a/examples/own", reason:"caller"}]}'
  : > "$TMP/facts.log"; rm -f "$TMP/facts-diff.json"
  (cd "$TMP" && PATH="$TMP/facts:$TMP/bin:/usr/bin:/bin" "$sh" "$VP" select "$R9" --files files9.json --prefix modules/a > "$TMP/selrel.json" 2>&1)
  check "$sh: a relative --files reaches the module root run as an absolute copy" \
    "$([ "$(cat "$TMP/facts.log")" = "affected $C9 --module-root modules/a --diff $R9/verify-select/affected-files.json --json" ] && cmp -s "$TMP/files9.json" "$TMP/facts-diff.json" && [ "$(q "$TMP/selrel.json" '.selection.tool == "mtf-facts"')" = 0 ]; echo $?)"
  perl -0pe 's/(--module-root "\$\{PREFIX%\/\}" \\\n\s+--diff )"\$W\/affected-files\.json"/$1"\$FILES"/' "$VP" > "$TMP/vp-rel.sh"
  : > "$TMP/facts.log"
  (cd "$TMP" && PATH="$TMP/facts:$TMP/bin:/usr/bin:/bin" "$sh" "$TMP/vp-rel.sh" select "$R9" --files files9.json --prefix modules/a > /dev/null 2>&1)
  check "$sh: the mutation that passes --files as given to the module root run is caught" \
    "$( ! cmp -s "$VP" "$TMP/vp-rel.sh" && grep -q -- '--diff files9.json ' "$TMP/facts.log"; echo $?)"
  # Started by a bare relative name, the script still finds facts-resolve.sh beside it.
  cp "$VP" "$TMP/vp-bare.sh"
  sed 's|^HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"$|HERE="${0%/*}"|' "$VP" > "$TMP/vp-bare-mut.sh"
  bare() { (cd "$TMP" && PATH="$TMP/facts:$TMP/bin:/usr/bin:/bin" "$sh" "$1" select "$R9" --files files9.json --prefix modules/a 2> /dev/null | jq -e '.selection.tool == "mtf-facts"' > /dev/null 2>&1); }
  check "$sh: started by a bare relative name the script reads facts-resolve.sh from its own directory" "$(bare vp-bare.sh; echo $?)"
  check "$sh: the mutation that reads the resolver through the script name is caught" \
    "$( ! cmp -s "$VP" "$TMP/vp-bare-mut.sh" && ! bare vp-bare-mut.sh; echo $?)"
  # An exported CDPATH naming a directory with a subdirectory of the script's own directory name
  # must not redirect the lookup (cd would use that subdirectory and print its path).
  mkdir -p "$TMP/vpd" "$TMP/decoy/vpd"
  cp "$VP" "$TMP/vpd/verify-pass.sh"; cp "$TMP/facts-resolve.sh" "$TMP/vpd/facts-resolve.sh"
  sed 's|^HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"$|HERE="$(cd "$(dirname "$0")" \&\& pwd -P)"|' "$VP" > "$TMP/vpd/vp-cdpath-mut.sh"
  cdp() { (cd "$TMP" && CDPATH="$TMP/decoy" PATH="$TMP/facts:$TMP/bin:/usr/bin:/bin" "$sh" "vpd/$1" select "$R9" --files files9.json --prefix modules/a 2> /dev/null | jq -e '.selection.tool == "mtf-facts"' > /dev/null 2>&1); }
  check "$sh: with CDPATH set to a directory holding a same-named subdirectory the script reads facts-resolve.sh from its own directory" \
    "$(cdp verify-pass.sh; echo $?)"
  # zsh tries the current directory before cdpath, so only bash is misled by the unguarded cd.
  if [ "$sh" = bash ]; then
    check "$sh: the mutation that lets CDPATH redirect the directory lookup is caught" \
      "$( ! cmp -s "$VP" "$TMP/vpd/vp-cdpath-mut.sh" && ! cdp vp-cdpath-mut.sh; echo $?)"
  fi
  rm -f "$TMP/facts.version"; : > "$TMP/facts.log"
  # Live, with MTF_FACTS_BIN naming an mtf-facts that has the feature: the module root path and
  # the scan, the same binary with its version report hidden, give the same selection.
  if [ -n "${MTF_FACTS_BIN:-}" ] && [ -x "$MTF_FACTS_BIN" ] && "$MTF_FACTS_BIN" version --json 2> /dev/null | jq -e '.features | index("flag:affected:module-root")' > /dev/null; then
    mkdir -p "$TMP/live" "$TMP/liveold"; ln -sf "$MTF_FACTS_BIN" "$TMP/live/mtf-facts"
    printf '#!/bin/sh\n[ "$1 ${2:-}" = "version --json" ] && exit 2\nexec %s "$@"\n' "$MTF_FACTS_BIN" > "$TMP/liveold/mtf-facts"; chmod +x "$TMP/liveold/mtf-facts"
    # The engine also lists, with reason all, a root example it cannot resolve, such as one
    # whose .tf file is a link, which the scan leaves out: the one difference.
    for p in modules/a modules/b; do
      sel9 "$p" "$TMP/live" > "$TMP/live-new.json"; sel9 "$p" "$TMP/liveold" > "$TMP/live-old.json"
      check "$sh: live, $p: the module root path and the scan select the same examples, the unresolved one added" \
        "$(cmp -s <(jq -c '[.dirs[] | select(. != {dir:"examples/tflink", reason:"verified", affected:"all"})]' "$TMP/live-new.json") \
          <(jq -c .dirs "$TMP/live-old.json") && [ "$(q "$TMP/live-new.json" '.dirs[-1] == {dir:"examples/tflink", reason:"verified", affected:"all"}')" = 0 ]; echo $?)"
    done
  else
    if [ -z "${MTF_FACTS_BIN:-}" ]; then why="MTF_FACTS_BIN is not set"
    elif [ ! -x "$MTF_FACTS_BIN" ]; then why="MTF_FACTS_BIN is not an executable file"
    else why="MTF_FACTS_BIN has no version --json listing flag:affected:module-root"; fi
    if [ "${MTF_FACTS_REQUIRED:-}" = 1 ]; then
      check "$sh: live module root comparison ($why, and MTF_FACTS_REQUIRED=1)" 1
    else
      echo "skip $sh: live module root comparison ($why)"
    fi
  fi
  EXPECT_CACHE="$R9/plugin-cache" run run "$R9" --files "$TMP/files9.json" --base "$BASE" --out "$R9/v.json" --prefix modules/b > /dev/null
  check "$sh: the pass verifies a root example that calls the submodule" \
    "$(q "$R9/v.json" '[.dirs[] | {dir, reason}] == [{dir:"examples/commented", reason:"verified"}, {dir:"examples/other", reason:"verified"}] and .dirs[1].head.record == "code-result"')"
  mv "$C9/modules/a" "$C9/outside/a"; ln -s ../outside/a "$C9/modules/a"
  check "$sh: a module root reached through a link selects no root example" \
    "$(q <(sel9 modules/a) 'all(.dirs[]; .dir | startswith("modules/a/"))')"
  check "$sh: with no module root prefix the root examples are the module's own, as before" \
    "$(q <(sel9 "") '[.dirs[].dir] == ["examples/blockcomment", "examples/calls", "examples/commented", "examples/escape", "examples/filesource", "examples/heredoc", "examples/linked", "examples/other", "examples/tflink", "examples/touched", "examples/vialink"]')"
  run coverage "$R9" --files "$TMP/files9.json" --out "$TMP/cov9.json" --prefix modules/b --no-plan > /dev/null
  check "$sh: coverage lists a root example that calls the submodule" \
    "$(q "$TMP/cov9.json" '[.examples[].dir] == ["examples/commented", "examples/other"] and .unplanned[-1] == {dir:"examples/other", reason:"no AWS profile named"}')"

  # The source scan is linear: a .tf file just under 1 MiB, plain blocks, a run of "<" or one
  # long line of strings, is read within a few seconds. Past 1000 .tf files or 8 MiB read, every
  # root example is selected with reason all.
  R10="$(mktemp -d "$TMP/pr-review.XXXXXX")"; C10="$R10/clone"
  mkdir -p "$C10/modules/a" "$C10/examples/big" "$C10/examples/lt" "$C10/examples/strs"
  echo 'variable "v" {}' > "$C10/modules/a/main.tf"
  perl -e 'my $s = ""; $s .= "variable \"v" . length($s) . "\" {\n  type = string\n}\n" while length $s < 1040000; print $s' > "$C10/examples/big/main.tf"
  printf 'module "a" {\n  source = "../../modules/a"\n}\n' >> "$C10/examples/big/main.tf"
  perl -e 'print "<" x 1048000' > "$C10/examples/lt/main.tf"
  perl -e 'print "x = ", "\"a\" " x 250000, "\n"' > "$C10/examples/strs/main.tf"
  git -C "$C10" init -q && git -C "$C10" add -A && git -C "$C10" -c user.name=t -c user.email=t@example.invalid commit -qm head
  f modules/a/main.tf modified | jq -s . > "$TMP/files10.json"
  sel10() { PATH="$TMP/none:$TMP/bin:/usr/bin:/bin" "$sh" "$VP" select "$R10" --files "$TMP/files10.json" --prefix modules/a 2>&1; }
  t0=$SECONDS; sel10 > "$TMP/sel10.json"; t1=$SECONDS
  check "$sh: three .tf files of about 1 MiB each are scanned within 20 seconds (the quadratic scan took about 9 s each), the call found" \
    "$([ $((t1 - t0)) -le 20 ] && [ "$(q "$TMP/sel10.json" '[.dirs[] | "\(.affected) \(.dir)"] == ["caller examples/big"]')" = 0 ]; echo $?)"
  mkdir "$C10/examples/many"; for i in $(seq 1001); do : > "$C10/examples/many/f$i.tf"; done
  check "$sh: past 1000 .tf files read, every root example is selected with reason all" \
    "$(q <(sel10) '[.dirs[] | "\(.affected) \(.dir)"] == ["all examples/big", "all examples/lt", "all examples/many", "all examples/strs"]')"
  rm -r "$C10/examples/many"
  for i in 1 2 3 4 5 6; do mkdir "$C10/examples/copy$i"; cp "$C10/examples/big/main.tf" "$C10/examples/copy$i/"; done
  check "$sh: past 8 MiB read, every root example is selected with reason all" \
    "$(q <(sel10) '[.dirs[].affected] | length == 9 and all(. == "all")')"

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

  # A long caller TMPDIR: terraform gets a short directory of the run under /tmp, removed at
  # the end and on an interrupt.
  LONGT="$TMP/$(printf 't%.0s' $(seq 1 $((119 - ${#TMP}))))"; mkdir -p "$LONGT"
  R6="$(newrun)"; : > "$TMP/tmpdir.log"
  TMPDIR="$LONGT" EXPECT_CACHE="$R6/plugin-cache" run run "$R6" --files "$TMP/files.json" --base "$BASE" --out "$R6/v.json" --dir examples/codeok > /dev/null
  check "$sh: a caller TMPDIR of ${#LONGT} characters still validates" \
    "$(q "$R6/v.json" "$(d codeok '.head == {init:0, validate:0, record:"code-result", line:null}')")"
  check "$sh: terraform saw a TMPDIR of at most 86 characters under /tmp, the same for every command" \
    "$(sort -u "$TMP/tmpdir.log" | { read -r t && ! read -r _ && case "$t" in /tmp/vp.??????) [ ${#t} -le 86 ] ;; *) false ;; esac; }; echo $?)"
  check "$sh: the short TMPDIR is gone after the run" "$(t="$(head -n 1 "$TMP/tmpdir.log")"; [ -n "$t" ] && [ ! -e "$t" ]; echo $?)"
  : > "$TMP/tmpdir.log"; : > "$R6/clone/examples/codeok/init.slow"
  # perl restores the default INT disposition a background job would otherwise ignore
  TMPDIR="$LONGT" EXPECT_CACHE="$R6/plugin-cache" PATH="$TMP/bin:/usr/bin:/bin" perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' \
    "$sh" "$VP" run "$R6" --files "$TMP/files.json" --base "$BASE" --out "$R6/i.json" --dir examples/codeok --budget 3 > /dev/null 2>&1 &
  ipid=$!; n=0
  while [ ! -s "$TMP/tmpdir.log" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
  t="$(head -n 1 "$TMP/tmpdir.log")"
  kill -INT "$ipid" 2> /dev/null; wait "$ipid"; ist=$?
  check "$sh: an interrupt ends the pass with 130 and removes the short TMPDIR" \
    "$([ "$ist" = 130 ] && case "$t" in /tmp/vp.??????) [ ! -e "$t" ] ;; *) false ;; esac; echo $?)"
  rm -f "$R6/clone/examples/codeok/init.slow"
  # The negative self-check: a copy that leaves terraform the caller's TMPDIR.
  perl -0pe 's/ TMPDIR="\$VPT"//' "$VP" > "$TMP/vp-tmp.sh"
  TMPDIR="$LONGT" EXPECT_CACHE="$R6/plugin-cache" PATH="$TMP/bin:/usr/bin:/bin" "$sh" "$TMP/vp-tmp.sh" run "$R6" --files "$TMP/files.json" --base "$BASE" --out "$R6/m.json" --dir examples/codeok > /dev/null 2>&1
  check "$sh: the mutation without TMPDIR in the terraform environment is caught" \
    "$( ! cmp -s "$VP" "$TMP/vp-tmp.sh" && [ "$(q "$R6/m.json" "$(d codeok '.head.record == "not-run-environment"')")" = 0 ]; echo $?)"

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
  echo '{"addresses":["module.b.aws_s3_bucket.this","aws_x.y[\"secret\"]",7,"module.b.data.aws_iam_policy_document.p","data.aws_bad","module.b.data.x","module.b"],"attributes":{"module.b.aws_s3_bucket.this":["bucket","Bad",1],"other":["x"]},"sensitive":{"module.b.aws_s3_bucket.this":["bucket"]},"head_sha":"0123456789abcdef0123456789abcdef01234567","module_calls":{"b":"../../","out":"../../../x","reg":"terraform-aws-modules/x/aws"}}' > "$TMP/addr/addresses-1.json"
  echo '{"addresses":["aws_y.z"]}' > "$TMP/addr/addresses-2.json"
  cov --plan "$TMP/rec.txt" --addresses "$TMP/addr"
  check "$sh: a laptop record: partial coverage" "$(q "$TMP/cov.json" '.class == "partial"')"
  check "$sh: a planned example carries its cleaned addresses (a data source kept, a malformed data address dropped), attributes and local module calls resolved inside the repository" \
    "$(q "$TMP/cov.json" '.examples[] | select(.dir == "examples/codeok") | .head == "planned" and .addresses == ["module.b.aws_s3_bucket.this","module.b.data.aws_iam_policy_document.p"] and .attributes == {"module.b.aws_s3_bucket.this":["bucket"]}
      and .module_calls == {"b":"."}')"
  # The ladder record takes these examples as they are, and its schema has no sensitive key
  check "$sh: the sensitive names and head commit of an addresses file stay out of coverage; a file without them is read alike" \
    "$(q "$TMP/cov.json" 'all(.examples[]; keys == ["addresses","attributes","base","dir","head","module_calls"])')"
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
    "$(q "$TMP/cov.json" '(.examples[] | select(.dir == "examples/codeok") | .head == "planned" and .addresses == ["module.b.aws_s3_bucket.this","module.b.data.aws_iam_policy_document.p"])
      and (.examples[] | select(.dir == "examples/regress") | .head == "not run")
      and (.examples[] | select(.dir == "examples/net") | .head == "planned" and .addresses == ["aws_y.z"])
      and (.examples[] | select(.dir == "examples/env") | .head == "not run")')"
  printf '%s\n' 'plan pass mode: laptop' 'example: examples/env' 'plan: environment (access-denied)' \
    'example: examples/net' 'plan: environment' 'example: examples/net2' 'plan: environment (dial tcp 10.0.0.1)' \
    'example: examples/linked' 'plan: environment (refused-host)' > "$TMP/rec.txt"
  cov --plan "$TMP/rec.txt"
  check "$sh: an environment class keeps its reason token, refused-host too; a bare or free-text one is output unrecognised" \
    "$(q "$TMP/cov.json" '[.unplanned[] | select(.dir | IN("examples/env","examples/net","examples/net2","examples/linked")) | .reason] ==
      ["environment (access-denied)", "environment (refused-host)", "output unrecognised", "output unrecognised"]')"
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
  # The plan diff of each planned example (plan-pass.md, Plan diff), kept beside the examples:
  # an equal one with its addresses file, the others with none, a line outside the grammar or a
  # second line unknown, an equal one with no addresses file not-run show, and nothing for an
  # example whose head did not plan.
  printf '%s\n' 'plan pass mode: laptop' 'example: examples/codeok' 'plan: planned' 'plan-diff: equal' \
    'example: examples/env' 'plan: planned-no-changes' 'plan-diff: differs aws_a.b' \
    'example: examples/net' 'plan: planned' 'plan-diff: same' \
    'example: examples/net2' 'plan: planned' 'plan-diff: equal' \
    'example: examples/linked' 'plan: planned' 'plan-diff: not-run budget' 'plan-diff: equal' \
    'example: examples/regress' 'plan: code-error' 'plan-diff: equal' > "$TMP/rec.txt"
  rm -rf "$TMP/addrpd"; mkdir -p "$TMP/addrpd"
  echo '{"addresses":["module.b.aws_s3_bucket.this","x y"],"module_calls":{"b":"../../","out":"../../../x","reg":"terraform-aws-modules/x/aws"}}' > "$TMP/addrpd/plan-diff-1.json"
  cov --plan "$TMP/rec.txt" --addresses "$TMP/addrpd"
  check "$sh: coverage carries each plan diff, fail closed, outside the examples" \
    "$(q "$TMP/cov.json" '.plan_diff == [
      {dir: "examples/codeok", result: "equal", reason: null, addresses: ["module.b.aws_s3_bucket.this"], module_calls: {b: "."}},
      {dir: "examples/env", result: "differs", reason: null, addresses: [], module_calls: {}},
      {dir: "examples/linked", result: "unknown", reason: null, addresses: [], module_calls: {}},
      {dir: "examples/net", result: "unknown", reason: null, addresses: [], module_calls: {}},
      {dir: "examples/net2", result: "not-run", reason: "show", addresses: [], module_calls: {}}]
      and all(.examples[]; has("plan_diff") | not)')"
  # The files are told apart by their base name: a directory whose path holds plan-diff- routes
  # nothing wrong, and a copy that routes by the whole path is caught.
  rm -rf "$TMP/plan-diff-x"; mkdir -p "$TMP/plan-diff-x/a"; cp "$TMP/addr/addresses-1.json" "$TMP/addrpd/plan-diff-1.json" "$TMP/plan-diff-x/a/"
  pdroute() { # script -> 0 when the head addresses and the plan diff addresses each reach their place
    PATH="$TMP/facts:$TMP/bin:/usr/bin:/bin" "$sh" "$1" coverage "$R4" --files "$TMP/files.json" --out "$TMP/cov-r.json" --plan "$TMP/rec.txt" --addresses "$TMP/plan-diff-x/a" > /dev/null 2>&1
    jq -e '(.examples[] | select(.dir == "examples/codeok") | .addresses | length > 1) and .plan_diff[0].addresses == ["module.b.aws_s3_bucket.this"]' "$TMP/cov-r.json" > /dev/null 2>&1
  }
  check "$sh: addresses files are routed by their base name" "$(pdroute "$VP"; echo $?)"
  perl -0pe 's/case "\$\{af##\*\/\}" in plan-diff-\*\)/case "\$af" in *\/plan-diff-*)/' "$VP" > "$TMP/vp-route.sh"
  check "$sh: the mutation that routes by the whole path is caught" "$( ! cmp -s "$VP" "$TMP/vp-route.sh" && ! pdroute "$TMP/vp-route.sh"; echo $?)"
  jq -n '{schema_version:1, head:"x", merge_base:"y", refused_hosts:0, examples:[
    {path:"examples/codeok", head:{class:"planned", plan:null}, base:null, addresses:["aws_a.b"], attributes:{},
     plan_diff:{result:"equal", reason:null, addresses:["aws_a.b"], module_calls:{m:"../../"}}}]}' > "$TMP/hosted.json"
  cov --hosted "$TMP/hosted.json"
  check "$sh: a hosted plan record gives its plan diffs" \
    "$(q "$TMP/cov.json" '.plan_diff == [{dir: "examples/codeok", result: "equal", reason: null, addresses: ["aws_a.b"], module_calls: {m: "."}}]')"
  # Negative self-check: a copy that reads the head's calls for the plan diff, and one that keeps
  # an equal line with no addresses, are caught.
  for m in 's/\(\$pc\.module_calls \| with_entries/(\$ad.module_calls | with_entries/' 's/elif \(\$pa \| type\) != "object" or \(\$pa\.addresses \| type\) != "array" then/elif false then/'; do
    perl -0pe "$m" "$VP" > "$TMP/vp-pd.sh"
    PATH="$TMP/facts:$TMP/bin:/usr/bin:/bin" "$sh" "$TMP/vp-pd.sh" coverage "$R4" --files "$TMP/files.json" --out "$TMP/cov-m.json" --plan "$TMP/rec.txt" --addresses "$TMP/addrpd" > /dev/null 2>&1
    check "$sh: plan diff mutation is caught ($m)" "$( ! cmp -s "$VP" "$TMP/vp-pd.sh" && ! jq -e '.plan_diff == [
      {dir: "examples/codeok", result: "equal", reason: null, addresses: ["module.b.aws_s3_bucket.this"], module_calls: {b: "."}},
      {dir: "examples/env", result: "differs", reason: null, addresses: [], module_calls: {}},
      {dir: "examples/linked", result: "unknown", reason: null, addresses: [], module_calls: {}},
      {dir: "examples/net", result: "unknown", reason: null, addresses: [], module_calls: {}},
      {dir: "examples/net2", result: "not-run", reason: "show", addresses: [], module_calls: {}}]' "$TMP/cov-m.json" > /dev/null 2>&1; echo $?)"
  done
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
