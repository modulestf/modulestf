#!/bin/bash
# Offline direct package pin coverage. Archive availability needs authenticated builds.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
FILE="$SRC/.agents/skills/terraform-module-pr-review/references/plan-runner/Dockerfile.runner"
TMP="$(mktemp -d /tmp/plan-packages-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
fails=0
check() {
  if "$@"; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); fi
}
pins() {
  awk '
    /^[[:space:]]*#/ {next}
    /apt-get install/ {all_installs++}
    /^RUN apt-get update/ {blocks++; active=1; next}
    active && /apt-get install -y --no-install-recommends/ {install++; next}
    active && /rm -rf \/var\/lib\/apt\/lists\// {active=0; next}
    active {
      for (i=1; i<=NF; i++) {
        if ($i == "\\") continue
        if ($i !~ /^[a-z0-9][a-z0-9+.-]*=[0-9][A-Za-z0-9+.:~_-]*$/) bad=1
        split($i, pair, "="); seen[pair[1]]++
      }
    }
    END {
      n=split("bash ca-certificates curl git jq perl python3 unzip", wanted, " ")
      for (i=1; i<=n; i++) if (seen[wanted[i]] != 1) bad=1
      count=0; for (p in seen) count++
      exit !(blocks == 1 && install == 1 && all_installs == 1 && count == n && !bad && !active)
    }
  ' "$1"
}
authenticated() {
  ! rg -q -- '--allow-unauthenticated|--allow-insecure|AllowInsecure|AllowUnauthenticated|trusted=yes|Check-Valid-Until=false' "$1"
}
mutation() {
  local invariant="$1" before="$2" after="$3" content
  content="$(cat "$FILE")"
  [[ "$content" == *"$before"* ]] || return 1
  printf '%s\n' "${content/"$before"/"$after"}" > "$TMP/mutated"
  ! "$invariant" "$TMP/mutated"
}
check pins "$FILE"
check authenticated "$FILE"
package_token() { awk -v p="$1" '$1 ~ ("^" p "=") {print $1}' "$FILE"; }
check mutation pins "$(package_token bash)" bash
check mutation pins "$(package_token curl)" 'curl=$CURL_VERSION'
check mutation pins "$(package_token jq)" "$(package_token jq) openssl"
check mutation pins "$(package_token perl)" 'perl='
check mutation pins 'ARG TARGETARCH' $'ARG TARGETARCH\nRUN apt-get install -y tar'
check mutation authenticated 'apt-get update' 'apt-get --allow-unauthenticated update'
[ "$fails" -eq 0 ] || exit 1
echo 'runner direct package pin checks passed'
