#!/bin/bash
# shellcheck disable=SC2319 # "$(<test>; echo $?)" passes the test's own status to check
# Self-check for references/mtf-facts-install.sh of terraform-module-pr-review, the checked
# install of the pinned mtf-facts release, with curl and uname stubbed: the install for each
# platform, the curl flags, and each failure and refusal, which keeps an existing binary and
# leaves no file in TMPDIR or the target directory (a wrong pin hash and a corrupted download,
# neither of which runs the download, a failed download, a binary that reports another
# version, a pin of another schema, a bad version or hash, a URL that is not the release
# asset, an unknown platform, a target that is a directory); then the shipped pin file
# itself; then a negative self-check on mutated copies of the script. No network.
# Run: tests/mtf-facts-install-test.sh
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
REF="$SRC/.agents/skills/terraform-module-pr-review/references"
INST="$REF/mtf-facts-install.sh" # the script under test; the self-check swaps in a mutated copy
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/mtf-facts-install-test.XXXXXX")" && pwd -P)" && [ -n "$TMP" ] || { echo "FAIL no temporary directory"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
fails=0
check() { if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
[ -f "$INST" ] || { echo "FAIL no $INST"; exit 1; }

# Stubs: curl copies $STUB_PAYLOAD to its -o file (or fails with $STUB_CURL_RC) and logs its
# arguments; uname answers $STUB_OS and $STUB_ARCH.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" << 'EOF'
#!/bin/bash
printf '%s\n' "$*" > "$STUB_LOG"
[ "${STUB_CURL_RC:-0}" = 0 ] || exit "$STUB_CURL_RC"
out=""; while [ "$#" -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done
cp "$STUB_PAYLOAD" "$out"
EOF
printf '#!/bin/sh\ncase "$1" in -s) echo "$STUB_OS" ;; -m) echo "$STUB_ARCH" ;; esac\n' > "$TMP/bin/uname"
chmod 755 "$TMP/bin/curl" "$TMP/bin/uname"

sha() { if command -v sha256sum > /dev/null; then sha256sum "$1" | cut -d ' ' -f 1; else shasum -a 256 "$1" | cut -d ' ' -f 1; fi; }
V=v9.9.9
payload() { printf '#!/bin/sh\ntouch "$STUB_MARK"\necho %s\n' "$1" > "$TMP/payload"; } # a stand-in binary reporting $1; running it leaves $TMP/ran
payload "$V"
GOOD="$(sha "$TMP/payload")"
mkpin() { # sha -> $TMP/pin.json for $V, every platform pointing at its release asset
  jq -n --arg v "$V" --arg s "$1" '{schema_version: 1, version: $v, platforms: ([
    "darwin_amd64", "darwin_arm64", "linux_amd64", "linux_arm64"] | map({key: ., value:
    {url: "https://github.com/modulestf/facts/releases/download/\($v)/mtf-facts_\($v)_\(.)", sha256: $s}}) | from_entries)}' > "$TMP/pin.json"
}
LEAKS=0 # runs that left a file in TMPDIR or a partial file in the target directory
run() { # [pin edit filter] -> runs the installer into a fresh $TMP/dest holding an old binary,
  # with TMPDIR an empty $TMP/tmpd; status in $RC, output in $TMP/out
  rm -rf "$TMP/dest" "$TMP/tmpd" "$TMP/ran"; mkdir "$TMP/dest" "$TMP/tmpd"; printf 'old\n' > "$TMP/dest/mtf-facts"
  if [ -n "${1-}" ]; then jq "$1" "$TMP/pin.json" > "$TMP/pin.edit"; else cp "$TMP/pin.json" "$TMP/pin.edit"; fi
  PATH="$TMP/bin:$PATH" TMPDIR="$TMP/tmpd" STUB_LOG="$TMP/curl.log" STUB_PAYLOAD="$TMP/payload" STUB_MARK="$TMP/ran" \
    STUB_OS="${OS:-Linux}" STUB_ARCH="${ARCH:-x86_64}" bash "$INST" "$TMP/dest" --pin "$TMP/pin.edit" > "$TMP/out" 2>&1
  RC=$?
  [ -z "$(ls -A "$TMP/tmpd")" ] && [ "$(ls -A "$TMP/dest")" = mtf-facts ] || LEAKS=$((LEAKS + 1))
}
none() { [ "$(cat "$TMP/dest/mtf-facts")" = old ]; } # the old binary kept, nothing installed
notrun() { [ ! -e "$TMP/ran" ]; } # the downloaded file never ran
mkpin "$GOOD"

for p in Linux:x86_64:linux_amd64 Linux:aarch64:linux_arm64 Darwin:x86_64:darwin_amd64 Darwin:arm64:darwin_arm64; do
  OS="${p%%:*}" ARCH="$(echo "$p" | cut -d : -f 2)" run
  check "installs for ${p##*:}" "$([ "$RC" = 0 ] && [ -x "$TMP/dest/mtf-facts" ] && [ "$(STUB_MARK=/dev/null "$TMP/dest/mtf-facts")" = "$V" ] &&
    grep -qF "/mtf-facts_${V}_${p##*:}" "$TMP/curl.log"; echo $?)"
done
run
check "curl runs https only with TLS 1.2 or later, follows redirects, fails on HTTP errors and has a time limit" \
  "$(grep -qF -- "--proto =https" "$TMP/curl.log" && grep -qF -- "--tlsv1.2" "$TMP/curl.log" &&
    grep -qE -- '(^| )-[a-zA-Z]*f' "$TMP/curl.log" && grep -qE -- '(^| )-[a-zA-Z]*L' "$TMP/curl.log" && grep -qF -- "--max-time" "$TMP/curl.log"; echo $?)"

mkpin 0000000000000000000000000000000000000000000000000000000000000000
run
check "a wrong hash in the pin fails with status 1, never runs the download and installs nothing" "$([ "$RC" = 1 ] && none && notrun && grep -q 'sha256 mismatch' "$TMP/out"; echo $?)"
mkpin "$GOOD"
printf 'tampered\n' >> "$TMP/payload"; run; payload "$V"
check "a corrupted download fails with status 1, never runs and installs nothing" "$([ "$RC" = 1 ] && none && notrun && grep -q 'sha256 mismatch' "$TMP/out"; echo $?)"
STUB_CURL_RC=22 run
check "a failed download fails with status 1 and installs nothing" "$([ "$RC" = 1 ] && none; echo $?)"
payload v9.9.8; mkpin "$(sha "$TMP/payload")"; run; payload "$V"; mkpin "$GOOD"
check "a binary that reports another version is not installed" "$([ "$RC" = 1 ] && none && grep -q "reports 'v9.9.8'" "$TMP/out"; echo $?)"
rm -rf "$TMP/dest"; mkdir -p "$TMP/dest/mtf-facts"
PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/curl.log" STUB_PAYLOAD="$TMP/payload" STUB_OS=Linux STUB_ARCH=x86_64 \
  bash "$INST" "$TMP/dest" --pin "$TMP/pin.json" > /dev/null 2>&1; RC=$?
check "refuses a target whose mtf-facts is a directory" "$([ "$RC" = 2 ] && [ -d "$TMP/dest/mtf-facts" ] && [ -z "$(ls -A "$TMP/dest/mtf-facts")" ]; echo $?)"

refused() { # label, pin edit filter: status 2, nothing installed, no download
  rm -f "$TMP/curl.log"; run "$2"
  check "refuses $1" "$([ "$RC" = 2 ] && none && [ ! -e "$TMP/curl.log" ]; echo $?)"
}
refused "a pin of another schema" '.schema_version = 2'
refused "a version that is no release tag" '.version = "latest"'
refused "a pin with no entry for the platform" 'del(.platforms.linux_amd64)'
refused "an upper-case hash" '.platforms.linux_amd64.sha256 |= ascii_upcase'
refused "a short hash" '.platforms.linux_amd64.sha256 |= .[0:63]'
refused "an http URL" '.platforms.linux_amd64.url |= sub("^https"; "http")'
refused "a URL on another host" '.platforms.linux_amd64.url |= sub("github.com"; "example.com")'
refused "a URL of another release" '.platforms.linux_amd64.url |= sub("/v9.9.9/"; "/v9.9.8/")'
refused "a URL of another platform's asset" '.platforms.linux_amd64.url |= sub("linux_amd64$"; "linux_arm64")'
OS=FreeBSD refused "an unknown system" '.'
ARCH=riscv64 refused "an unknown machine" '.'
check "every run left TMPDIR empty and no partial file in the target directory ($LEAKS did not)" "$LEAKS"

# The shipped pin: schema 1, a release tag, the four platforms, each the release asset URL and
# a 64 hex digit hash, and the installer accepts its form (the download stubbed to fail).
PIN="$REF/mtf-facts-pin.json"
check "the shipped pin has the four platforms, each the release asset and a sha256" "$(jq -e '
  .schema_version == 1 and (.version | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) and
  (.platforms | keys) == ["darwin_amd64", "darwin_arm64", "linux_amd64", "linux_arm64"] and
  (.version as $v | .platforms | to_entries | all(.value.sha256 | test("^[0-9a-f]{64}$")) and
    all(.value.url == "https://github.com/modulestf/facts/releases/download/\($v)/mtf-facts_\($v)_\(.key)"))' "$PIN" > /dev/null; echo $?)"
rm -rf "$TMP/dest"; mkdir "$TMP/dest"
PATH="$TMP/bin:$PATH" STUB_CURL_RC=22 STUB_LOG="$TMP/curl.log" STUB_PAYLOAD="$TMP/payload" STUB_OS=Linux STUB_ARCH=x86_64 \
  bash "$INST" "$TMP/dest" > /dev/null 2>&1; RC=$?
check "the installer reads the shipped pin by default and gets to the download" "$([ "$RC" = 1 ] &&
  grep -qF "/releases/download/$(jq -r .version "$PIN")/" "$TMP/curl.log"; echo $?)"

# Negative self-check: each weakened copy of the installer must fail the check it guards.
mutate() { # label, perl substitution, test that must now fail
  local d; d="$(mktemp -d "$TMP/mut.XXXXXX")"; cp "$REF/mtf-facts-pin.json" "$d/"
  cp "$INST" "$d/mtf-facts-install.sh"; perl -0pi -e "$2" "$d/mtf-facts-install.sh"
  if cmp -s "$d/mtf-facts-install.sh" "$INST"; then check "self-check: $1 (the mutation changed nothing)" 1; return; fi
  local keep="$INST" before="$fails"; INST="$d/mtf-facts-install.sh"
  ( eval "$3" ) > /dev/null 2>&1; local s=$?
  INST="$keep"; fails="$before"
  check "self-check: $1 is caught" "$([ "$s" != 0 ]; echo $?)"
}
mutate "the hash comparison dropped" 's/\[ "\$got" = "\$want" \] \|\|/true ||/' \
  'mkpin 0000000000000000000000000000000000000000000000000000000000000000; run; mkpin "$GOOD"; [ "$RC" = 1 ] && none'
mutate "the hash format check dropped" 's/\[0-9a-f\]\{64\}/.*/' \
  'run ".platforms.linux_amd64.sha256 |= .[0:63]"; [ "$RC" = 2 ]'
mutate "the version check dropped" 's/\[ "\$v" = "\$version" \] \|\|/true ||/' \
  'payload v9.9.8; mkpin "$(sha "$TMP/payload")"; run; payload "$V"; mkpin "$GOOD"; [ "$RC" = 1 ] && none'
mutate "the URL check dropped" 's/  \*\) echo "mtf-facts-install: the pin.s URL.*\n//' \
  'rm -f "$TMP/curl.log"; run ".platforms.linux_amd64.url |= sub(\"github.com\"; \"example.com\")"; [ "$RC" = 2 ] && [ ! -e "$TMP/curl.log" ]'
mutate "the download run before the hash check" 's/(\|\|\n  \{ echo "mtf-facts-install: download of)/|| true; chmod 755 "\$tmp\/mtf-facts"; "\$tmp\/mtf-facts" --version > \/dev\/null 2>&1 ||\n  { echo "mtf-facts-install: download of/' \
  'printf "tampered\n" >> "$TMP/payload"; run; payload "$V"; notrun'
mutate "the EXIT trap dropped" "s/^trap .*\\n//m" \
  'LEAKS=0; run; mkpin 0000000000000000000000000000000000000000000000000000000000000000; run; mkpin "$GOOD"; [ "$LEAKS" = 0 ]'
mutate "the directory target check dropped" 's/\[ ! -d "\$DIR\/mtf-facts" \] \|\|/true ||/' \
  'rm -rf "$TMP/dest"; mkdir -p "$TMP/dest/mtf-facts"; PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/curl.log" STUB_PAYLOAD="$TMP/payload" STUB_MARK="$TMP/ran" STUB_OS=Linux STUB_ARCH=x86_64 bash "$INST" "$TMP/dest" --pin "$TMP/pin.json"; [ $? = 2 ]'
mutate "https-only dropped from curl" "s/--proto '=https' //" \
  'run; grep -qF -- "--proto =https" "$TMP/curl.log"'
mutate "the binary moved before the check" 's/(curl [^\n]*\n[^\n]*\n)/$1mv -f "\$tmp\/mtf-facts" "\$DIR\/mtf-facts"; cp "\$DIR\/mtf-facts" "\$tmp\/mtf-facts"\n/' \
  'mkpin 0000000000000000000000000000000000000000000000000000000000000000; run; mkpin "$GOOD"; [ "$RC" = 1 ] && none'

if [ "$fails" = 0 ]; then echo "all mtf-facts-install checks passed"; else echo "$fails mtf-facts-install check(s) FAILED"; exit 1; fi
