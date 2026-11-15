#!/bin/bash
# Runs the suites tests/*.sh in parallel, each in its own TMPDIR, and prints one line per job with
# its exit status and seconds. pr-fix-test.sh runs as PR_FIX_SHARDS jobs, one per mutation shard
# (PR_FIX_TEST_SHARD=i/N). Logs stay in the output directory. Exits 1 when any job fails.
# Usage: bash tests/run-all.sh [-j JOBS] [-o DIR] [SUITE.sh ...]
#        bash tests/run-all.sh --list    the jobs as a JSON array, the CI matrix
# JOBS defaults to the CPU count; DIR to a new directory under TMPDIR. Works under bash 3.2.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
PR_FIX_SHARDS=2 # the CI matrix takes the same number from --list

jobs_of() { # the job lines, "suite shard", for the named suites or every tests/*.sh
  local s i
  if [ "$#" = 0 ]; then set -- tests/*.sh; fi
  for s in "$@"; do
    s="${s##*/}"
    [ "$s" = run-all.sh ] && continue
    [ -f "tests/$s" ] || { echo "run-all: no suite tests/$s" >&2; return 1; }
    if [ "$s" = pr-fix-test.sh ]; then
      i=0; while [ "$i" -lt "$PR_FIX_SHARDS" ]; do echo "$s $i/$PR_FIX_SHARDS"; i=$((i + 1)); done
    else echo "$s -"; fi
  done
}

if [ "${1-}" = --one ]; then # one job: suite, shard ("-" for none), output directory
  s="$2"; shard="${3#-}"; out="$4"; tag="${s%.sh}${shard:+-${shard%/*}}"
  d="$(mktemp -d "$out/$tag.tmp.XXXXXX")" || exit 2
  t0="$(date +%s)"
  PR_FIX_TEST_SHARD="$shard" TMPDIR="$d" bash "tests/$s" > "$out/$tag.log" 2>&1; rc=$?
  chmod -R u+w "$d" 2> /dev/null; rm -rf "$d"
  printf '%-34s exit %3d %6ss\n' "$tag" "$rc" "$(($(date +%s) - t0))" | tee "$out/$tag.rc"
  exit 0
fi

if [ "${1-}" = --list ]; then
  jobs_of | jq -Rnc '[inputs | split(" ") | {suite: .[0], shard: (if .[1] == "-" then "" else .[1] end)}]'
  exit
fi

J="$(getconf _NPROCESSORS_ONLN 2> /dev/null || echo 4)"; OUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -j) J="${2-}"; shift 2 || exit 2 ;;
    -o) OUT="${2-}"; shift 2 || exit 2 ;;
    -*) echo "run-all: unknown option $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
case "$J" in '' | *[!0-9]* | 0) echo "run-all: -j needs a positive number" >&2; exit 2 ;; esac
if [ -z "$OUT" ]; then OUT="$(mktemp -d "${TMPDIR:-/tmp}/run-all.XXXXXX")" || exit 2; fi
mkdir -p "$OUT" && OUT="$(cd "$OUT" && pwd -P)" || exit 2
list="$(jobs_of "$@")" || exit 2
echo "run-all: $(printf '%s\n' "$list" | wc -l | tr -d ' ') jobs, $J at a time, logs in $OUT"
t0="$(date +%s)"
# pr-fix-test first: its shards are the longest jobs.
{ printf '%s\n' "$list" | grep '^pr-fix-test\.sh '; printf '%s\n' "$list" | grep -v '^pr-fix-test\.sh '; } |
  while read -r s shard; do printf '%s\0%s\0%s\0' "$s" "$shard" "$OUT"; done |
  xargs -0 -n 3 -P "$J" bash "$0" --one
bad=0
for f in "$OUT"/*.rc; do grep -q ' exit   0 ' "$f" || bad=$((bad + 1)); done
n="$(printf '%s\n' "$list" | wc -l | tr -d ' ')"; got="$(ls "$OUT"/*.rc 2> /dev/null | wc -l | tr -d ' ')"
[ "$got" = "$n" ] || { echo "run-all: $((n - got)) jobs did not report"; bad=$((bad + n - got)); }
echo "run-all: $((n - bad)) of $n jobs passed in $(($(date +%s) - t0))s; logs in $OUT"
[ "$bad" = 0 ]
