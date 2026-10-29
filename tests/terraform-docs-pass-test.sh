#!/bin/bash
# Self-check for the maintainer's terraform-docs-pass.sh, with curl and terraform-docs
# stubbed. No network. One negative fixture per check of the procedure in
# quality-gates.md "The Documentation Region"; each must end stale with the workspace
# unchanged. Run: tests/terraform-docs-pass-test.sh
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
TP="$SRC/.agents/skills/terraform-module-maintainer/references/terraform-docs-pass.sh"
PROFILE_SRC="$SRC/.agents/skills/terraform-module-maintainer/profiles/terraform-aws-modules/PROFILE.md"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/tfdocs-pass-test.XXXXXX")" && pwd -P)" && [ -n "$TMP" ] || { echo "FAIL no temporary directory"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
fails=0

check() { # name, status (0 = holds)
  if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
has() { grep -qxF -- "$2" "$1"; echo $?; } # output file, exact line
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }

B='<!-- BEGIN_TF_DOCS -->'
E='<!-- END_TF_DOCS -->'
OB='<!-- BEGINNING OF PRE-COMMIT-TERRAFORM DOCS HOOK -->'
OE='<!-- END OF PRE-COMMIT-TERRAFORM DOCS HOOK -->'

# The stub tool keys its behaviour on a "# STUB:<mode>" line in the copied main.tf.
mkdir -p "$TMP/stub"
cat >"$TMP/stub/terraform-docs" <<'EOF'
#!/bin/sh
mode=$(sed -n 's/^# STUB:\([a-z]*\).*/\1/p' main.tf | head -n 1)
arg=$(sed -n 's/^# STUB:[a-z]*:\(.*\)/\1/p' main.tf | head -n 1)
fill=generated
case $mode in
  sleep) [ -n "$arg" ] && echo $$ >"$arg"; sleep 30 ;;
  empty) fill= ;;
  delete) rm -f other.tf ;;
  dirreadme) rm -f README.md && mkdir README.md && exit 0 ;;
  addws) : >"$arg" ;;
  killwd) # SIGKILL every other child of the script: the tool's watchdog.
    if command -v ps >/dev/null; then kids=$(ps -A -o pid= -o ppid= | awk -v m="$PPID" '$2 == m {print $1}')
    else kids=$(for f in /proc/[0-9]*/stat; do sed 's/.*) //' "$f" | awk -v m="$PPID" -v p="${f#/proc/}" '$2 == m {sub("/stat", "", p); print p}'; done 2>/dev/null); fi
    for k in $kids; do [ "$k" = $$ ] || kill -KILL "$k"; done ;;
  fail) exit 1 ;;
  extra) : >extra.tf ;;
  marker) fill='<!-- BEGIN_TF_DOCS -->' ;;
  touchws) echo '# changed' >>"$arg" ;;
esac
awk -v b='<!-- BEGIN_TF_DOCS -->' -v e='<!-- END_TF_DOCS -->' -v f="$fill" -v m="$mode" '
  m == "outside" && NR == 1 {print "changed outside"}
  m == "after" && $0 == "Outro" {print "changed after"; next}
  $0 == b && !done {print; print f; skip = 1; done = 1; next}
  $0 == e {skip = 0}
  !skip {print}' README.md >README.md.new && cat README.md.new >README.md && rm -f README.md.new
if [ "$mode" = corrupt ]; then printf x >>"$0"; exit 0; fi
EOF
chmod 755 "$TMP/stub/terraform-docs"
tar -czf "$TMP/stub.tgz" -C "$TMP/stub" terraform-docs
STUB_HASH=$(sha "$TMP/stub.tgz")

cat >"$TMP/curl" <<EOF
#!/bin/sh
echo "\$*" >>"$TMP/curl.log"
out=
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && out=\$2; shift; done
cp "$TMP/stub.tgz" "\$out"
EOF
chmod 755 "$TMP/curl"

# The real profile, with every platform's hash replaced by the stub archive's.
sed -E "s/^( *\| \`[a-z]+-[a-z0-9]+\` \| \`)[0-9a-f]{64}(\` \|)/\1$STUB_HASH\2/" "$PROFILE_SRC" >"$TMP/PROFILE.md"
sed -E "s/^( *\| \`[a-z]+-[a-z0-9]+\` \| \`)[0-9a-f]{64}(\` \|)/\1$(printf '0%.0s' $(seq 64))\2/" "$PROFILE_SRC" >"$TMP/PROFILE-bad.md"

mkdir -m 700 "$TMP/cache"
export TFDOCS_PASS_CURL="$TMP/curl" TFDOCS_PASS_CACHE_DIR="$TMP/cache" TFDOCS_PASS_TOOL_SECONDS=2
run() { # run WS PROFILE OUT ENTRY...
  local ws=$1 prof=$2 out=$3
  shift 3
  "$TP" --profile "$prof" --workspace "$ws" "$@" >"$out" 2>"$out.err"
}

readme() { printf 'Intro\n\n%s\n%s\nold\n%s\n\nOutro\n' "$1" "$2" "$3"; }
n=0
newws() { # a workspace with the root and modules/a, each with main.tf and README.md
  n=$((n + 1))
  W=$TMP/ws-$n
  mkdir -p "$W/modules/a"
  for d in "$W" "$W/modules/a"; do
    printf 'variable "x" {\n  description = "X"\n  type        = string\n}\n' >"$d/main.tf"
    printf 'Intro\n\n%s\nold\n%s\n\nOutro\n' "$B" "$E" >"$d/README.md"
  done
  chmod 640 "$W/README.md"
  snap
}
snap() { (cd "$W" && find . -type f -exec sh -c 'for f; do echo "$f $(cksum <"$f")"; done' _ {} + | LC_ALL=C sort) >"$TMP/snap-$n"; }
unchanged() { (cd "$W" && find . -type f -exec sh -c 'for f; do echo "$f $(cksum <"$f")"; done' _ {} + | LC_ALL=C sort) | cmp -s - "$TMP/snap-$n"; echo $?; }
stub() { printf '# STUB:%s\n' "$1" >>"$W/$2/main.tf"; }
stale_case() { # name, workspace prepared, expected line, entries...
  local name=$1 want=$2
  shift 2
  snap
  run "$W" "$TMP/PROFILE.md" "$TMP/out" "$@"
  check "$name: $want" "$(has "$TMP/out" "$want")"
  check "$name: workspace unchanged" "$(unchanged)"
}

before_runs=$(ls -d /tmp/tfdocs-pass.* 2>/dev/null | wc -l)

# Constants from the real profile.
"$TP" --profile "$PROFILE_SRC" --print-constants >"$TMP/const"
check "profile: version v0.24.0" "$(grep -qx 'version v0.24.0' "$TMP/const"; echo $?)"
check "profile: four platform hashes" "$([ "$(grep -cE '^ *\| `(darwin|linux)-(amd64|arm64)` \| `[0-9a-f]{64}` \|' "$PROFILE_SRC")" = 4 ]; echo $?)"
check "profile: configuration carries the template pair" "$(grep -qxF "    $B" "$TMP/const"; echo $?)"

# The good case: root and a submodule in one run, a repeat and the fix-text form.
newws
run "$W" "$TMP/PROFILE.md" "$TMP/out" README.md "the terraform-docs region of modules/a/README.md" modules/a/README.md
check "good: root regenerated" "$(has "$TMP/out" "regenerated .")"
check "good: submodule regenerated" "$(has "$TMP/out" "regenerated modules/a")"
check "good: repeat dropped" "$([ "$(grep -c '^regenerated modules/a$' "$TMP/out")" = 1 ]; echo $?)"
check "good: complete" "$(has "$TMP/out" complete)"
check "good: region rewritten" "$(grep -qx generated "$W/README.md"; echo $?)"
check "good: text outside kept" "$(grep -qx Intro "$W/README.md" && grep -qx Outro "$W/README.md"; echo $?)"
check "good: mode kept" "$([ "$(ls -l "$W/README.md" | cut -c1-10)" = -rw-r----- ]; echo $?)"
check "good: curl flags" "$(grep -q -- '^-q -L --proto =https --proto-redir =https --fail' "$TMP/curl.log"; echo $?)"
check "good: no pending file" "$([ -z "$(ls -A "$W" | grep '^\.README')" ]; echo $?)"

# A corrupt cache entry is installed again once.
calls=$(wc -l <"$TMP/curl.log" | tr -d ' ')
printf 'x' >>"$TMP/cache/$STUB_HASH/terraform-docs"
newws
run "$W" "$TMP/PROFILE.md" "$TMP/out" README.md
check "cache: corrupt entry reinstalled" "$(has "$TMP/out" "regenerated .")"
check "cache: one new download" "$([ "$(wc -l <"$TMP/curl.log" | tr -d ' ')" = $((calls + 1)) ]; echo $?)"

# Scope.
newws
run "$W" "$TMP/PROFILE.md" "$TMP/out" wrappers/a/main.tf ../x/README.md /etc/README.md modules/../README.md modules/A/README.md
check "scope: wrapper outside the safe set" "$(has "$TMP/out" "stale wrappers/a/main.tf outside the safe set in an untrusted workspace")"
for i in 2 3 4 5; do check "scope: entry $i not a region" "$(has "$TMP/out" "stale entry $i not a documentation region")"; done
check "scope: incomplete" "$(has "$TMP/out" incomplete)"
check "scope: workspace unchanged" "$(unchanged)"
newws
for i in 1 2 3 4 5 6 7 8 9 10 11; do mkdir -p "$W/examples/e$i"; cp "$W/modules/a/main.tf" "$W/modules/a/README.md" "$W/examples/e$i/"; done
run "$W" "$TMP/PROFILE.md" "$TMP/out" $(for i in 1 2 3 4 5 6 7 8 9 10 11; do echo "examples/e$i/README.md"; done)
check "scope: eleventh over the cap" "$(has "$TMP/out" "stale examples/e11 over the cap")"
check "scope: tenth regenerated" "$(has "$TMP/out" "regenerated examples/e10")"
newws
mv "$W/modules" "$W/real-modules" && ln -s real-modules "$W/modules"
stale_case "scope: symlinked directory component" "stale modules/a directory path" modules/a/README.md

# Gates by name and lstat.
newws; : >"$W/.terraform-docs.yml"
stale_case "gate: config in directory" "stale . terraform-docs configuration present" README.md
newws; : >"$W/.terraform-docs.yml"
stale_case "gate: config in ancestor" "stale modules/a terraform-docs configuration present" modules/a/README.md
newws; ln -s /nonexistent "$W/modules/a/.terraform-docs.yaml"
stale_case "gate: config as dangling symlink" "stale modules/a terraform-docs configuration present" modules/a/README.md
newws; mkfifo "$W/.tfdocs.d"
stale_case "gate: config name as fifo" "stale . terraform-docs configuration present" README.md
newws; mkdir "$W/.config"; : >"$W/.config/.terraform-docs.yml"
stale_case "gate: config under .config" "stale . terraform-docs configuration present" README.md
for f in x.tofu x.tofu.json x.tf.json override.tf a_override.tf; do
  newws; : >"$W/$f"
  stale_case "gate: $f" "stale . input file the copy would leave out" README.md
done
newws; mv "$W/README.md" "$W/R.md"; ln -s R.md "$W/README.md"
stale_case "gate: symlinked README" "stale . not a regular file" README.md
newws; ln -s main.tf "$W/link.tf"
stale_case "gate: symlinked .tf" "stale . not a regular file" README.md
newws; ln "$W/main.tf" "$W/other.tf"
stale_case "gate: hard link" "stale . link count" README.md
newws; mkfifo "$W/pipe.tf"
stale_case "gate: fifo .tf" "stale . not a regular file" README.md
newws; : >"$W/-x.tf"
stale_case "gate: name starting with a dash" "stale . file name" README.md
newws; head -c 1048577 /dev/zero >"$W/big.tf"
stale_case "gate: file over 1 MiB" "stale . file over 1 MiB" README.md
newws; for i in $(seq 1 200); do : >"$W/f$i.tf"; done
stale_case "gate: 201 files" "stale . over 200 files" README.md
newws; rm "$W/README.md"
stale_case "gate: no README" "stale . no README.md" README.md

# Markers, counted anywhere.
newws; readme "$B" "$B" "$E" >"$W/README.md"
stale_case "markers: two begin markers" "stale . marker test" README.md
newws; printf '%s\n%s\n%s\n%s\n' "$B" "$E" "$OB" "$OE" >"$W/README.md"
stale_case "markers: both pairs" "stale . marker test" README.md
newws; printf '%s\n%s\n%s\n' "$E" x "$B" >"$W/README.md"
stale_case "markers: end before begin" "stale . marker test" README.md
newws; printf '%s\nx\n%s\n```\n%s\n```\n' "$B" "$E" "$E" >"$W/README.md"
stale_case "markers: one in a code fence" "stale . marker test" README.md
newws; printf '%s\nx\n%s\n' "$OB" "$OE" >"$W/README.md"
stale_case "markers: older pair has no parity fixture" "stale . no parity fixture for this marker pair" README.md

# The tool and after the run.
newws
run "$W" "$TMP/PROFILE-bad.md" "$TMP/out" README.md
check "tool: hash mismatch" "$(has "$TMP/out" "stale . tool unavailable or hash mismatch")"
check "tool: hash mismatch: workspace unchanged" "$(unchanged)"
newws; stub sleep .
t0=$SECONDS
stale_case "tool: time-out" "stale . tool failed or timed out" README.md
check "tool: time-out within the bound" "$([ $((SECONDS - t0)) -lt 15 ]; echo $?)"
newws; stub fail .
stale_case "tool: failure" "stale . tool failed or timed out" README.md
newws; stub extra .
stale_case "after: file created" "stale . files created, deleted or changed by the run" README.md
newws; stub marker .
stale_case "after: marker injected into the region" "stale . marker test after the run" README.md
newws; stub outside .
stale_case "after: text outside the region changed" "stale . text before the region changed" README.md
newws; printf '# STUB:touchws:%s\n' "$W/main.tf" >>"$W/main.tf"; stub none .
run "$W" "$TMP/PROFILE.md" "$TMP/out" README.md
check "copy back: workspace changed during the run" "$(has "$TMP/out" "stale . workspace changed")"
check "copy back: README unchanged" "$(grep -qx old "$W/README.md"; echo $?)"

# More gates and after-run checks.
newws; for i in 1 2 3 4 5 6 7 8 9; do head -c 1048576 /dev/zero >"$W/z$i.tf"; done
stale_case "gate: over 8 MiB" "stale . over 8 MiB" README.md
newws; stub empty .
stale_case "after: empty region" "stale . region empty" README.md
newws; : >"$W/other.tf"; stub delete .
stale_case "after: file deleted by the run" "stale . files created, deleted or changed by the run" README.md
newws; stub dirreadme .
stale_case "after: README no longer a regular file" "stale . README.md no longer a regular file" README.md
newws; stub after .
stale_case "after: text after the region changed" "stale . text after the region changed" README.md
newws; printf '# STUB:addws:%s\n' "$W/added.tf" >>"$W/main.tf"
snap
run "$W" "$TMP/PROFILE.md" "$TMP/out" README.md
check "copy back: file added during the run" "$(has "$TMP/out" "stale . workspace changed")"
check "copy back: README unchanged after an added file" "$(grep -qx old "$W/README.md"; echo $?)"

# Profile, platform and invoker-only inputs.
newws
run "$W" "$TMP/none.md" "$TMP/out" README.md
check "profile: unreadable" "$(has "$TMP/out" "stale . profile constants unreadable")"
grep -vE '^ *\| `[a-z]+-[a-z0-9]+` \| `[0-9a-f]{64}` \|' "$TMP/PROFILE.md" >"$TMP/PROFILE-nohash.md"
run "$W" "$TMP/PROFILE-nohash.md" "$TMP/out" README.md
check "profile: no hash for this platform" "$(has "$TMP/out" "stale . no hash for this platform")"
newws; cp "$TMP/PROFILE.md" "$W/PROFILE.md"; snap
run "$W" "$W/PROFILE.md" "$TMP/out" README.md
check "invoker: profile inside the workspace refused" "$(has "$TMP/out" "stale . profile constants unreadable")"
check "invoker: profile inside: workspace unchanged" "$(unchanged)"
newws; cp "$TMP/curl" "$W/curl"; snap
TFDOCS_PASS_CURL="$W/curl" "$TP" --profile "$TMP/PROFILE.md" --workspace "$W" README.md >"$TMP/out" 2>&1
check "invoker: curl inside the workspace refused" "$(grep -q 'TFDOCS_PASS_CURL refused' "$TMP/out"; echo $?)"
check "invoker: curl inside: workspace unchanged" "$(unchanged)"
newws; mkdir -m 700 "$W/cache"; snap
TFDOCS_PASS_CACHE_DIR="$W/cache" run "$W" "$TMP/PROFILE.md" "$TMP/out" README.md
check "cache: inside the workspace" "$(has "$TMP/out" "stale . cache directory")"
newws; ln -s "$TMP/cache" "$TMP/cache-link"
TFDOCS_PASS_CACHE_DIR="$TMP/cache-link" run "$W" "$TMP/PROFILE.md" "$TMP/out" README.md
check "cache: symbolic link" "$(has "$TMP/out" "stale . cache directory")"
mkdir -m 755 "$TMP/cache-wide"
TFDOCS_PASS_CACHE_DIR="$TMP/cache-wide" run "$W" "$TMP/PROFILE.md" "$TMP/out" README.md
check "cache: wrong mode" "$(has "$TMP/out" "stale . cache directory")"
check "cache: workspace unchanged" "$(unchanged)"

# A second hash failure in one run sends the rest of the run to the fallback.
newws
for i in 1 2 3; do mkdir -p "$W/examples/c$i"; cp "$W/modules/a/README.md" "$W/examples/c$i/"; printf '# STUB:corrupt\n' >"$W/examples/c$i/main.tf"; done
mkdir -m 700 "$TMP/cache-corrupt"
TFDOCS_PASS_CACHE_DIR="$TMP/cache-corrupt" run "$W" "$TMP/PROFILE.md" "$TMP/out" examples/c1/README.md examples/c2/README.md examples/c3/README.md
check "cache: first use regenerates" "$(has "$TMP/out" "regenerated examples/c1")"
check "cache: one reinstall after a failure" "$(has "$TMP/out" "regenerated examples/c2")"
check "cache: second failure is the whole run's" "$(has "$TMP/out" "stale examples/c3 tool unavailable or hash mismatch")"

# The overall deadline.
newws
mkdir -p "$W/examples/d1" "$W/examples/d2"
for i in 1 2; do cp "$W/modules/a/README.md" "$W/examples/d$i/"; printf '# STUB:sleep\n' >"$W/examples/d$i/main.tf"; done
snap
t0=$SECONDS
TFDOCS_PASS_DEADLINE_SECONDS=3 TFDOCS_PASS_TOOL_SECONDS=59 run "$W" "$TMP/PROFILE.md" "$TMP/out" examples/d1/README.md examples/d2/README.md
check "deadline: first directory timed out" "$(has "$TMP/out" "stale examples/d1 tool failed or timed out")"
check "deadline: second directory past the deadline" "$(has "$TMP/out" "stale examples/d2 deadline")"
check "deadline: within the bound" "$([ $((SECONDS - t0)) -lt 15 ]; echo $?)"
check "deadline: workspace unchanged" "$(unchanged)"

# A bounded helper returns as soon as its command does.
newws; for i in $(seq 1 50); do printf '# %s\n' "$i" >"$W/f$i.tf"; done
t0=$SECONDS
run "$W" "$TMP/PROFILE.md" "$TMP/out" README.md
check "bounded: 51 files regenerated quickly" "$(grep -qx 'regenerated .' "$TMP/out" && [ $((SECONDS - t0)) -lt 10 ]; echo $?)"

# A watchdog killed from outside does not hang the run.
newws; stub killwd .
t0=$SECONDS
TFDOCS_PASS_TOOL_SECONDS=30 run "$W" "$TMP/PROFILE.md" "$TMP/out" README.md
check "watchdog killed: run still regenerates" "$(has "$TMP/out" "regenerated .")"
check "watchdog killed: run ends at once" "$([ $((SECONDS - t0)) -lt 15 ]; echo $?)"

# Clean up on INT and TERM while the tool runs.
for sig in INT TERM; do
  newws; printf '# STUB:sleep:%s\n' "$TMP/stub.pid" >>"$W/main.tf"; rm -f "$TMP/stub.pid"; snap
  n_before=$(ls -d /tmp/tfdocs-pass.* 2>/dev/null | wc -l)
  set -m
  TFDOCS_PASS_TOOL_SECONDS=59 "$TP" --profile "$TMP/PROFILE.md" --workspace "$W" README.md >"$TMP/out" 2>&1 &
  pid=$!
  set +m
  for _ in $(seq 1 100); do [ -s "$TMP/stub.pid" ] && break; sleep 0.1; done
  kill -s "$sig" "$pid"
  wait "$pid" 2>/dev/null
  sleep 0.5
  check "signal $sig: tool stopped" "$(! kill -0 "$(cat "$TMP/stub.pid" 2>/dev/null || echo 0)" 2>/dev/null; echo $?)"
  check "signal $sig: run directory removed" "$([ "$(ls -d /tmp/tfdocs-pass.* 2>/dev/null | wc -l)" -le "$n_before" ]; echo $?)"
  check "signal $sig: workspace unchanged" "$(unchanged)"
done

if [ "$(id -u)" = 0 ] && id nobody >/dev/null 2>&1; then
  newws; : >"$W/theirs.tf"; chown nobody "$W/theirs.tf"
  stale_case "gate: not owned by the invoking user" "stale . not owned by the invoking user" README.md
else
  echo "skip gate: not owned by the invoking user (needs root to create the fixture)"
fi

after_runs=$(ls -d /tmp/tfdocs-pass.* 2>/dev/null | wc -l)
check "clean up: no run directory left" "$([ "$after_runs" -le "$before_runs" ]; echo $?)"

if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"
