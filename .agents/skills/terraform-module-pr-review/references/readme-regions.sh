#!/bin/bash
# readme-regions.sh: the host's terraform-docs evidence for each README.md a change touches, as
# readme-regions.md sets out. It copies the head's files of that directory out of the clone's git
# objects into a workspace of its own, runs the maintainer's terraform-docs-pass.sh on the copy,
# never on the clone, and compares the regenerated README.md with the head's bytes. Nothing from
# the clone runs: the pass runs only the profile's pinned, hash-checked terraform-docs.
#
#   readme-regions.sh --clone <dir> --head <sha> --diff <files.json> [--prefix <p>] --out <dir>
#       [--profile <file>]
#
# Writes <out>/regions.txt, one line per touched README.md that holds a marker of the profile, in
# path order: its module-relative path and generated, differs or "unknown <reason>"; then prints
# it. --profile is the pass's own option, for tests. Exit 0 done, 2 a usage error or no evidence.
set -uo pipefail
set -f

die() { echo "readme-regions.sh: $1" >&2; exit 2; }
clone="" head="" diff="" prefix="" out="" profile=""
while [ $# -gt 0 ]; do
  case "$1" in
    --clone) clone="${2-}" ;; --head) head="${2-}" ;; --diff) diff="${2-}" ;; --prefix) prefix="${2-}" ;;
    --out) out="${2-}" ;; --profile) profile="${2-}" ;;
    *) die "unexpected argument" ;;
  esac
  [ $# -ge 2 ] || die "$1 needs a value"; shift 2
done
for v in clone diff out; do case "${!v}" in /?*) ;; *) die "--$v must be an absolute path" ;; esac; done
[[ "$head" =~ ^[0-9a-f]{40}$ ]] || die "--head must be a 40 character SHA"
seg='[A-Za-z0-9_][A-Za-z0-9._-]{0,63}'
[ -z "$prefix" ] || [[ "$prefix" =~ ^($seg/){0,8}$seg$ ]] || die "--prefix is not a module root"
[ -d "$clone" ] && [ -d "$out" ] && [ ! -L "$out" ] || die "--clone and --out must be directories"
[ ! -e "$out/regions.txt" ] && [ ! -e "$out/rr" ] || die "--out already holds the README evidence"
jq -e 'type == "array" and all(.[]; type == "object" and (.filename | type == "string"))' "$diff" > /dev/null 2>&1 ||
  die "--diff is not a GitHub files list"
PASS="$(cd "$(dirname "$0")/../../terraform-module-maintainer/references" 2> /dev/null && pwd -P)/terraform-docs-pass.sh"
[ -f "$PASS" ] || die "the maintainer's terraform-docs-pass.sh is missing"
pa=(); [ -z "$profile" ] || pa=(--profile "$profile")

# The version and the marker pairs the pass reads from the profile; without them, no evidence.
consts="$(bash "$PASS" ${pa[@]+"${pa[@]}"} --print-constants 2> /dev/null)" || die "profile constants unreadable"
version="$(sed -n 's/^version \(v[0-9.]*\)$/\1/p' <<< "$consts")"
mk=()
while IFS= read -r m; do mk+=(-e "$m"); done < <(sed -n 's/^markers //p' <<< "$consts" | awk -F' [|] ' '{for (i = 1; i <= NF; i++) print $i}')
[ -n "$version" ] && [ "${#mk[@]}" = 8 ] || die "profile constants unreadable"

# The form of the reviewer's git-safety.md, in the clone. Only ls-tree and cat-file run, on the
# head's objects: they read objects only and run no driver, filter or textconv.
safe_git() {
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_LAZY_FETCH=1 \
  GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null \
  GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat \
  git -C "$clone" --no-pager -c core.fsmonitor=false -c core.hooksPath=/dev/null \
    -c protocol.allow=never -c diff.external= -c log.showSignature=false \
    -c advice.graftFileDeprecated=false "$@"
}
safe_git_partial() {
  [ -n "$(safe_git config --get extensions.partialClone)" ] ||
    [ -n "$(safe_git config --get-regexp '^remote\..*\.promisor$')" ]
}
ENTRY_RE=$'^([0-7]{6}) [a-z]+ ([0-9a-f]{40,64}) +([0-9-]+)\t(.+)$'
REG_RE='^100(644|755)$'
MAX_FILE=1048576

# head_file <repository path> <file>: the head's blob into the file, or prints why not: absent,
# link, not a regular file, file over 1 mib, read failed.
head_file() {
  local e mode obj size
  e="$(safe_git ls-tree -l -z "$head" -- "$1" 2> /dev/null | tr '\0' '\n')" || { echo "read failed"; return 1; }
  [[ "$e" =~ $ENTRY_RE ]] && [ "${BASH_REMATCH[4]}" = "$1" ] || { echo absent; return 1; }
  mode="${BASH_REMATCH[1]}" obj="${BASH_REMATCH[2]}" size="${BASH_REMATCH[3]}"
  [ "$mode" != 120000 ] || { echo link; return 1; }
  [[ "$mode" =~ $REG_RE ]] || { echo "not a regular file"; return 1; }
  [ "$size" -le "$MAX_FILE" ] || { echo "file over 1 mib"; return 1; }
  safe_git cat-file blob "$obj" > "$2" 2> /dev/null || { echo "read failed"; return 1; }
}

# copy_dir <module-relative dir> <0|1>: the head's entries of the directory into the copy, each by
# name and type, so the pass sees what it would see in a checkout: a link as a dangling link, a tree
# or gitlink as an empty directory, any other blob as an empty file. With 1, each regular .tf file
# and README.md also gets its bytes, within the pass's own caps. A .config tree is copied the same
# way one level down; a .config of any other type gets a configuration file, since in a checkout it
# could reach one. An entry already copied is kept. Sets WHY on failure.
copy_dir() {
  local a="$1" rp t n=0 files=0 bytes=0 e mode obj size name f
  rp="${prefix:+$prefix/}$a"; [ "$a" != . ] || rp="$prefix"
  if [ -z "$rp" ]; then t="$head^{tree}"; else t="$head:$rp"; fi
  mkdir -p -- "$WS/$a" && safe_git ls-tree -l -z "$t" > "$RR/list" 2> /dev/null || { WHY="directory read failed"; return 1; }
  while IFS= read -r -d '' e; do
    [[ "$e" =~ $ENTRY_RE ]] || { WHY="directory read failed"; return 1; }
    mode="${BASH_REMATCH[1]}" obj="${BASH_REMATCH[2]}" size="${BASH_REMATCH[3]}" name="${BASH_REMATCH[4]}"
    f="$WS/$a/$name"
    n=$((n + 1)); [ "$n" -le 1000 ] || { WHY="over 1000 entries"; return 1; }
    if [ "$2" = 1 ] && [[ "$mode" =~ $REG_RE ]] && [[ "$name" == *.tf || "$name" == README.md ]]; then
      files=$((files + 1)); bytes=$((bytes + size))
      [ "$size" -le "$MAX_FILE" ] || { WHY="file over 1 mib"; return 1; }
      [ "$files" -le 200 ] || { WHY="over 200 files"; return 1; }
      [ "$bytes" -le 8388608 ] || { WHY="over 8 mib"; return 1; }
      safe_git cat-file blob "$obj" > "$f" 2> /dev/null || { WHY="read failed"; return 1; }
    elif [ -e "$f" ] || [ -L "$f" ]; then
      :
    elif [ "$name" = .config ]; then
      mkdir -- "$f" || { WHY="copy failed"; return 1; }
      if [ "$mode" = 040000 ]; then copy_config "$rp/.config" "$f" || return 1; else : > "$f/.terraform-docs.yml"; fi
    else
      case "$mode" in
        120000) ln -s nowhere "$f" ;;
        040000 | 160000) mkdir -- "$f" ;;
        *) : > "$f" ;;
      esac || { WHY="copy failed"; return 1; }
    fi
  done < "$RR/list"
}
copy_config() { # <repository path of a .config tree> <its copy>: the entry names, as empty files
  local e
  safe_git ls-tree -z "$head:${1#/}" > "$RR/config" 2> /dev/null || { WHY="directory read failed"; return 1; }
  while IFS= read -r -d '' e; do
    e="${e#*$'\t'}"
    [ -e "$2/$e" ] || : > "$2/$e" || { WHY="copy failed"; return 1; }
  done < "$RR/config"
}

# The quality-gate workflow's terraform-docs pin at the head: same, mismatch, none or unreadable.
wf_state() {
  local why
  why="$(head_file .github/workflows/pre-commit.yml "$RR/wf")" || { [ "$why" = absent ] && echo none || echo unreadable; return; }
  awk -v want="$version" -v q="'" '
    /^[ \t]*(TERRAFORM_DOCS_VERSION|terraform-docs-version)[ \t]*:/ {
      v = $0; sub(/^[^:]*:[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v)
      if (v ~ /^\$\{\{ *env\.TERRAFORM_DOCS_VERSION *\}\}$/) next
      gsub("^[\"" q "]|[\"" q "]$", "", v)
      if (v !~ /^v?[0-9]+\.[0-9]+\.[0-9]+$/) { bad = 1; next }
      if (v !~ /^v/) v = "v" v
      n++; if (v != want) mis = 1
    }
    END { print (bad ? "unreadable" : mis ? "mismatch" : n ? "same" : "none") }' "$RR/wf"
}

RR="$out/rr" WS="$out/rr/ws"
mkdir -p "$WS" || die "no work directory"
trap 'rm -rf -- "$RR"' EXIT
# The README.md files the change touches, module-relative, at most 256, in path order.
re="^($seg/){0,8}README\\.md\$"
paths=()
while IFS= read -r p; do [[ "$p" =~ $re ]] && paths+=("$p"); done < <(jq -r --arg p "${prefix:+$prefix/}" '.[] | .filename
  | select((contains("\n") | not) and ($p == "" or startswith($p))) | .[($p | length):]' "$diff" | LC_ALL=C sort -u | head -n 256)

all=""
if [ ${#paths[@]} -gt 0 ]; then
  if ! safe_git cat-file -e "$head^{tree}" 2> /dev/null; then all="unknown read failed"
  elif safe_git_partial; then all="unknown partial clone"; fi
fi
res=() entries=() i=0
for p in ${paths[@]+"${paths[@]}"}; do
  i=$((i + 1)); res[i]=""
  [ -z "$all" ] || { res[i]="$all"; continue; }
  # A README.md the head deletes, or with no marker of the profile, has no line.
  if ! why="$(head_file "${prefix:+$prefix/}$p" "$RR/orig-$i")"; then
    if [ "$why" = absent ]; then res[i]=skip; else res[i]="unknown $why"; fi
    continue
  fi
  grep -qF "${mk[@]}" "$RR/orig-$i" || { res[i]=skip; continue; }
  [[ "$p" =~ ^(README\.md|(modules|examples)/[a-z0-9-]+/README\.md)$ ]] || { res[i]="unknown not a documentation region"; continue; }
  # The directory with its inputs, and each directory above it up to the module root by name.
  d="$(dirname "$p")" WHY=""
  if [ "$d" = . ]; then copy_dir . 1; else copy_dir . 0 && copy_dir "${d%%/*}" 0 && copy_dir "$d" 1; fi ||
    { res[i]="unknown $WHY"; continue; }
  entries+=("$p")
done

# One pass over every copied directory; its line for the directory decides the result.
: > "$RR/pass.out"
[ ${#entries[@]} = 0 ] || bash "$PASS" ${pa[@]+"${pa[@]}"} --workspace "$WS" "${entries[@]}" > "$RR/pass.out" 2> /dev/null
wf="" i=0
for p in ${paths[@]+"${paths[@]}"}; do
  i=$((i + 1)); r="${res[i]}"
  [ "$r" != skip ] || continue
  if [ -z "$r" ]; then
    d="$(dirname "$p")"
    line="$(awk -v d="$d" '($1 == "regenerated" && $2 == d && NF == 2) || ($1 == "stale" && $2 == d) {print; exit}' "$RR/pass.out")"
    case "$line" in
      regenerated*)
        if cmp -s "$WS/$p" "$RR/orig-$i"; then r=generated
        else
          # The pinned version wrote other bytes. When the head's workflow pins another version,
          # the difference may be that version's output, which the host cannot run.
          [ -n "$wf" ] || wf="$(wf_state)"
          case "$wf" in mismatch) r="unknown version mismatch" ;; unreadable) r="unknown version unreadable" ;; *) r=differs ;; esac
        fi ;;
      stale*)
        r="$(printf '%s' "${line#stale "$d" }" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9 .-' | cut -c1-60)"
        r="unknown ${r:-pass refused}" ;;
      *) r="unknown pass failed" ;;
    esac
  fi
  printf '%s %s\n' "$p" "$r"
done > "$out/regions.txt"
cat "$out/regions.txt"
