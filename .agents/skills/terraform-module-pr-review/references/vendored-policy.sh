#!/bin/bash
# vendored-policy.sh: the host's comparison of a vendored upstream IAM policy with its source, as
# vendored-policy.md sets out. For each policy document the module profile's vendored-policies.txt
# lists for this repository and the change touches, it reads the document at the head and the
# merge base from the clone's git objects, resolves the upstream release tag the change names to a
# commit SHA, fetches the upstream file at that SHA, reads both statically and prints the two
# diffs. Nothing fetched or read runs.
#
#   vendored-policy.sh --clone <dir> --head <sha> [--base <sha>] --diff <files.json> [--prefix <p>]
#       --repo <owner/name> --body <file> --profile-dir <dir> --out <dir>
#
# Writes <out>/vendored.txt, the lines of vendored-policy.md, Output, in profile order, and prints
# it. A document with no evidence gets one "unknown <reason>" line. Exit 0 done, 2 a usage error.
set -uo pipefail
set -f

die() { echo "vendored-policy.sh: $1" >&2; exit 2; }
clone="" head="" base="" diff="" prefix="" repo="" body="" pdir="" out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --clone) clone="${2-}" ;; --head) head="${2-}" ;; --base) base="${2-}" ;; --diff) diff="${2-}" ;;
    --prefix) prefix="${2-}" ;; --repo) repo="${2-}" ;; --body) body="${2-}" ;; --profile-dir) pdir="${2-}" ;;
    --out) out="${2-}" ;;
    *) die "unexpected argument" ;;
  esac
  [ $# -ge 2 ] || die "$1 needs a value"; shift 2
done
for v in clone diff body pdir out; do case "${!v}" in /?*) ;; *) die "--${v/pdir/profile-dir} must be an absolute path" ;; esac; done
sha_re='^[0-9a-f]{40}$'
[[ "$head" =~ $sha_re ]] || die "--head must be a 40 character SHA"
[ -z "$base" ] || [[ "$base" =~ $sha_re ]] || die "--base must be a 40 character SHA"
repo_pat='[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}'
[[ "$repo" =~ ^$repo_pat$ ]] || die "--repo must be owner/name"
seg='[A-Za-z0-9_][A-Za-z0-9._-]{0,63}'
[ -z "$prefix" ] || [[ "$prefix" =~ ^($seg/){0,8}$seg$ ]] || die "--prefix is not a module root"
[ -d "$clone" ] && [ -d "$out" ] && [ ! -L "$out" ] && [ -f "$body" ] || die "--clone and --out must be directories, --body a file"
[ ! -e "$out/vendored.txt" ] && [ ! -e "$out/vp" ] || die "--out already holds the evidence"
jq -e 'type == "array" and all(.[]; type == "object" and (.filename | type == "string"))' "$diff" > /dev/null 2>&1 ||
  die "--diff is not a GitHub files list"
HERE="$(cd "$(dirname "$0")" && pwd -P)"
W="$out/vp"; mkdir "$W" || die "no work directory"
: > "$out/vendored.txt"
finish() { rm -rf "$W"; cat "$out/vendored.txt"; exit 0; }

# The profile's list (vendored-policy.md, Profile Entries). No file, a link, or any line outside the
# grammar: no evidence at all.
SRC="$pdir/vendored-policies.txt"
[ -f "$SRC" ] && [ ! -L "$SRC" ] && [ "$(wc -c < "$SRC")" -le 65536 ] || finish
ENTRY_RE="^entry ($repo_pat) (($seg/){0,8}$seg\\.tf) ([A-Za-z_][A-Za-z0-9_-]{0,63}) ($repo_pat) (($seg/){0,8}$seg\\.json)$"
SUBST_RE='^subst ([A-Za-z_][A-Za-z0-9_.]{0,127}(\[[0-9]{1,3}\][A-Za-z0-9_.]{0,63})?) ([A-Za-z0-9._:/-]{1,128})$'
: > "$W/subst" && : > "$W/entries"
while IFS= read -r l || [ -n "$l" ]; do
  case "$l" in '' | '#'*) continue ;; esac
  if [[ "$l" =~ $ENTRY_RE ]]; then
    [ "${BASH_REMATCH[1]}" != "$repo" ] || printf '%s %s %s %s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]}" \
      "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}" >> "$W/entries"
  elif [[ "$l" =~ $SUBST_RE ]]; then printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}" >> "$W/subst"
  else finish
  fi
done < "$SRC"

# The form of the reviewer's git-safety.md, in the clone: ls-tree and cat-file only.
safe_git() {
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_LAZY_FETCH=1 \
  GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null \
  GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat \
  git -C "$clone" --no-pager -c core.fsmonitor=false -c core.hooksPath=/dev/null \
    -c protocol.allow=never -c diff.external= -c log.showSignature=false \
    -c advice.graftFileDeprecated=false "$@"
}
partial=false
{ [ -n "$(safe_git config --get extensions.partialClone)" ] ||
  [ -n "$(safe_git config --get-regexp '^remote\..*\.promisor$')" ]; } && partial=true
ENTRY_LS=$'^([0-7]{6}) [a-z]+ ([0-9a-f]{40,64}) +([0-9-]+)\t(.+)$'
# blob <commit> <path> <file>: the blob into the file, or prints why not.
blob() {
  local e
  e="$(safe_git ls-tree -l -z "$1" -- "$2" 2> /dev/null | tr '\0' '\n')" || { echo "read failed"; return 1; }
  [ -n "$e" ] || { echo absent; return 1; }
  [[ "$e" =~ $ENTRY_LS ]] && [ "${BASH_REMATCH[4]}" = "$2" ] || { echo "read failed"; return 1; }
  local mode="${BASH_REMATCH[1]}" obj="${BASH_REMATCH[2]}" size="${BASH_REMATCH[3]}"
  [ "$mode" != 120000 ] || { echo link; return 1; }
  [[ "$mode" =~ ^100(644|755)$ ]] || { echo "not a regular file"; return 1; }
  [ "$size" -le 1048576 ] || { echo "file over 1 mib"; return 1; }
  safe_git cat-file blob "$obj" > "$3" 2> /dev/null || { echo "read failed"; return 1; }
}

# gh with the time limit of github-io.md, Allowed Commands.
limit() {
  if command -v timeout > /dev/null; then timeout 30 "$@"
  elif command -v gtimeout > /dev/null; then gtimeout 30 "$@"
  else perl -e 'alarm 30; exec @ARGV' "$@"; fi
}
TAG_RE='^v[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$'
# tags <upstream> <file>...: each release tag the files name in a GitHub address of the upstream.
tags() {
  local up="$1"; shift
  grep -ohiE "github\\.com/${up//./\\.}/(releases/tag|blob|tree)/v[0-9]{1,4}\\.[0-9]{1,4}\\.[0-9]{1,4}([/)\"'> ]|$)" "$@" 2> /dev/null |
    sed -E 's#^.*/(releases/tag|blob|tree)/##; s#[/)"'"'"'> ]$##' | sort -u
}
# older <a> <b>: a is a lower version than b.
older() {
  local IFS=. a b i; read -r -a a <<< "${1#v}"; read -r -a b <<< "${2#v}"
  for i in 0 1 2; do
    [ "$((10#${a[i]}))" -lt "$((10#${b[i]}))" ] && return 0
    [ "$((10#${a[i]}))" -gt "$((10#${b[i]}))" ] && return 1
  done
  return 1
}
# commit_of <upstream> <tag>: the tag's commit SHA, annotated or not, or nothing.
commit_of() {
  local r t s
  r="$(limit gh api "repos/$1/git/ref/tags/$2" 2> /dev/null)" || return 1
  t="$(jq -r 'select(.ref == $r) | .object.type' --arg r "refs/tags/$2" <<< "$r" 2> /dev/null)"
  s="$(jq -r '.object.sha' <<< "$r" 2> /dev/null)"
  [[ "$s" =~ $sha_re ]] || return 1
  if [ "$t" = tag ]; then
    r="$(limit gh api "repos/$1/git/tags/$s" 2> /dev/null)" || return 1
    t="$(jq -r '.object.type' <<< "$r" 2> /dev/null)"; s="$(jq -r '.object.sha' <<< "$r" 2> /dev/null)"
  fi
  [ "$t" = commit ] && [[ "$s" =~ $sha_re ]] && printf '%s\n' "$s"
}

n=0
while read -r path block up upath; do
  n=$((n + 1)); d="$W/$n"; mkdir "$d"
  # The entry's path is repository-relative; the line names it module-relative.
  case "$path" in
    "$prefix"/*) mpath="${path#"$prefix"/}" ;;
    *) [ -z "$prefix" ] && mpath="$path" || continue ;;
  esac
  st="$(jq -r --arg p "$path" '[.[] | select(.filename == $p) | .status][0] // ""' "$diff")"
  [ -n "$st" ] || continue
  line() { printf '%s %s %s\n' "$mpath" "$block" "$1" >> "$out/vendored.txt"; }
  if [ "$partial" = true ]; then line "unknown partial clone"; continue; fi
  if [ "$st" = removed ]; then line "unknown removed"; continue; fi
  why="$(blob "$head" "$path" "$d/head.tf")" || { line "unknown head $why"; continue; }
  basefile=""
  if [ -n "$base" ]; then
    if why="$(blob "$base" "$path" "$d/base.tf")"; then basefile="$d/base.tf"
    elif [ "$why" != absent ]; then line "unknown base $why"; continue
    fi
  fi
  # The static reads of head and base. A block the change leaves as it was gets no line.
  perl "$HERE/policy-hcl.pl" "$d/head.tf" "$block" "$W/subst" > "$d/head.json" 2> /dev/null || { line "unknown head unreadable"; continue; }
  if [ -n "$basefile" ]; then
    perl "$HERE/policy-hcl.pl" "$basefile" "$block" "$W/subst" > "$d/base.json" 2> /dev/null || { line "unknown base unreadable"; continue; }
    jq -e -s '(.[0] | del(.lines)) == (.[1] | del(.lines))' "$d/head.json" "$d/base.json" > /dev/null 2>&1 && continue
  fi
  r="$(sed -n 's/^unknown \([a-z0-9 ]*\)$/\1/p' "$d/head.json")"
  [ -z "$r" ] || { line "unknown $r"; continue; }
  if [ -n "$basefile" ]; then
    r="$(sed -n 's/^unknown \([a-z0-9 ]*\)$/\1/p' "$d/base.json")"
    if [ "$r" = "block missing" ]; then : > "$d/base.json"
    elif [ -n "$r" ]; then line "unknown base $r"; continue
    elif ! jq -e -s '.[0].dynamic == .[1].dynamic' "$d/head.json" "$d/base.json" > /dev/null 2>&1; then
      line "unknown dynamic statements changed"; continue
    elif ! jq -e -s '.[0].merges == .[1].merges' "$d/head.json" "$d/base.json" > /dev/null 2>&1; then
      line "unknown merged documents changed"; continue
    fi
  fi
  [ -s "$d/base.json" ] || echo null > "$d/base.json"
  # The tag: the one release tag the pull request body and the head file name for this upstream,
  # never older than the newest one the base file names.
  t="$(tags "$up" "$body" "$d/head.tf")"
  [ -n "$t" ] || { line "unknown no tag"; continue; }
  [ "$(wc -l <<< "$t" | tr -d ' ')" = 1 ] || { line "unknown tag ambiguous"; continue; }
  if [ -n "$basefile" ]; then
    bt=""
    while IFS= read -r x; do [ -n "$x" ] && { [ -z "$bt" ] || older "$bt" "$x"; } && bt="$x"; done < <(tags "$up" "$basefile")
    if [ -n "$bt" ] && older "$t" "$bt"; then line "unknown tag older"; continue; fi
  fi
  sha="$(commit_of "$up" "$t")" || { line "unknown tag not found"; continue; }
  limit gh api "repos/$up/contents/$upath?ref=$sha" > "$d/up.raw" 2> /dev/null &&
    jq -er --arg p "$upath" 'select(.type == "file" and .path == $p and .encoding == "base64" and .size <= 1048576) | .content' \
      "$d/up.raw" 2> /dev/null | tr -d '\n' | base64 -d > "$d/up.json" 2> /dev/null && [ -s "$d/up.json" ] ||
    { line "unknown fetch failed"; continue; }
  if ! jq -r -n -L "$HERE" --slurpfile h "$d/head.json" --slurpfile b "$d/base.json" --slurpfile u "$d/up.json" '
      include "vendored-policy";
      try ({head: ($h[0] | tuples), base: ($b[0] | if . == null then null else tuples end), up: ($u[0] | upstream | tuples)}
        | diff_lines) catch ("unknown " + (if type == "string" and test("^[a-z ]{1,40}$") then . else "upstream unreadable" end)),
      ($h[0].dynamic | length | select(. > 0) | "not compared \(.) dynamic statements"),
      ($h[0].merges | select(. != "") | "not compared merged documents")' > "$d/lines" 2> /dev/null; then
    line "unknown upstream unreadable"; continue
  fi
  if grep -q '^unknown ' "$d/lines"; then line "$(grep -m1 '^unknown ' "$d/lines")"; continue; fi
  line "source $up $t $sha $upath"
  line "lines $(jq -r '.lines | map(tostring) | join(" ")' "$d/head.json")"
  while IFS= read -r x; do line "$x"; done < "$d/lines"
done < "$W/entries"
finish
