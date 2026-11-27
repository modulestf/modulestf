#!/bin/bash
# vendored-policy.sh: the host's comparison of a vendored upstream IAM policy with its source, as
# vendored-policy.md sets out. For each policy document the module profile's vendored-policies.txt
# lists for this repository and the change touches, it reads the document at the head and the
# merge base from the facts engine's iam-policy-docs report on the module root's files, taken from
# the clone's git objects; resolves the upstream release tag the change names to a commit SHA,
# fetches the upstream file at that SHA and prints the two diffs. Nothing fetched or read runs.
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
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=facts-resolve.sh
. "$HERE/facts-resolve.sh" || die "facts-resolve.sh cannot be read"
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
  elif [[ "$l" =~ $SUBST_RE ]]; then printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}" >> "$W/subst"
  else finish
  fi
done < "$SRC"
jq -R -n '[inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries' "$W/subst" > "$W/subst.json" || finish

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

# A command with the time limit of github-io.md, Allowed Commands: gh, perl and jq alike.
limit() {
  if command -v timeout > /dev/null; then timeout 30 "$@"
  elif command -v gtimeout > /dev/null; then gtimeout 30 "$@"
  else perl -e 'alarm 30; exec @ARGV' "$@"; fi
}
TAG_RE='^v[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$'
# tags <upstream> <file>...: each release tag the files name in a GitHub address of the upstream,
# the address as GitHub writes it, followed by a delimiter or punctuation that ends a sentence.
tags() {
  local up="$1" x; shift
  grep -ohE "github\\.com/${up//./\\.}/(releases/tag|blob|tree)/v[0-9]{1,4}\\.[0-9]{1,4}\\.[0-9]{1,4}([/)\"'> .,;:]|$)" "$@" 2> /dev/null |
    sed -E 's#^.*/(releases/tag|blob|tree)/##; s#[/)"'"'"'> .,;:]$##' | sort -u |
    while IFS= read -r x; do [[ "$x" =~ $TAG_RE ]] && printf '%s\n' "$x"; done
}
# older <a> <b>: a is a lower version than b. Both match TAG_RE.
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
# latest <upstream>: the tag of the upstream's latest release now, or nothing.
latest() {
  local r
  r="$(limit gh api "repos/$1/releases/latest" 2> /dev/null | jq -r '.tag_name // empty' 2> /dev/null)"
  [[ "$r" =~ $TAG_RE ]] && printf '%s\n' "$r"
}
# TREE_PL: the entries of "ls-tree -r -l -z" on stdin, the module root prefix as its argument.
# Prints "<kind> <object> <path>" per entry the engine reads, kind blob, link or module, or one
# "refuse <reason>" line: a name that is not plain ASCII or holds a "." or ".." segment, two names
# alike in letter case, a name that is also a directory, an entry that is no regular file, over
# 4 MiB, over 4000 entries or 64 MiB in all (vendored-policy.md, step 2).
# shellcheck disable=SC2016 # a perl program
TREE_PL='
my $pfx = shift; local $/ = "\0"; my (%low, @out, $n, $total);
sub refuse { print "refuse $_[0]\n"; exit 0 }
while (my $e = <STDIN>) {
  chomp $e;
  $e =~ /\A([0-7]{6}) ([a-z]+) ([0-9a-f]{40,64}) +([0-9-]+)\t(.+)\z/s or refuse("read failed");
  my ($mode, $type, $obj, $size, $path) = ($1, $2, $3, $4, $5);
  substr($path, 0, length $pfx) eq $pfx or refuse("read failed");
  my $rel = substr($path, length $pfx);
  my $leaf = $rel =~ s{.*/}{}r;
  next unless $type eq "commit" || $leaf =~ /(\.tf|\.tf\.json|\.tofu|\.tofu\.json|\.tfvars|\.tfvars\.json)\z/ || $leaf eq ".terraform.lock.hcl";
  length($rel) <= 1024 && $rel =~ m{\A[ -~]+\z} && "/$rel/" !~ m{/\.\.?/} && "/$rel/" !~ m{//} or refuse("file name");
  my @seg = split m{/}, $rel; my $p = "";
  for my $i (0 .. $#seg) {
    $p .= ($i ? "/" : "") . $seg[$i];
    my $k = lc $p; my $what = $i == $#seg ? "leaf" : "dir";
    if (exists $low{$k}) { $low{$k} eq "$what $p" && $what eq "dir" or refuse("file name") }
    else { $low{$k} = "$what $p" }
  }
  ++$n <= 4000 or refuse("too many files");
  if ($type eq "commit") { push @out, "module\t-\t$rel"; next }
  if ($mode eq "120000") { push @out, "link\t-\t$rel"; next }
  $type eq "blob" && $mode =~ /\A100(644|755)\z/ && $size =~ /\A[0-9]+\z/ or refuse("not a regular file");
  $size <= 4194304 or refuse("file over 4 mib");
  ($total += $size) <= 67108864 or refuse("tree over 64 mib");
  push @out, "blob\t$obj\t$rel";
}
print "$_\n" for @out;
'
# tree <commit> <dir>: the module root's files the engine reads at the commit, from the clone's
# objects, into the directory; or prints why not. A link becomes a link to nowhere and a submodule an
# empty directory, so the engine sees each for what it is and refuses it.
tree() {
  local kind obj rel lst
  lst="$(mktemp "$W/list.XXXXXX")" && mkdir "$2" || { echo "read failed"; return 1; }
  local p=""; [ -z "$prefix" ] || p="$prefix/"
  local ps=(); [ -z "$p" ] || ps=("$p")
  safe_git ls-tree -r -l -z "$1" -- ${ps[@]+"${ps[@]}"} 2> /dev/null | perl -e "$TREE_PL" "$p" > "$lst" || { echo "read failed"; return 1; }
  [ "${PIPESTATUS[0]}" = 0 ] || { echo "read failed"; return 1; }
  if grep -q '^refuse ' "$lst"; then sed -n 's/^refuse //p' "$lst" | head -n 1; return 1; fi
  while IFS=$'\t' read -r kind obj rel; do
    mkdir -p "$2/$(dirname -- "$rel")" || { echo "read failed"; return 1; }
    case "$kind" in
      module) mkdir "$2/$rel" ;;
      link) ln -s /nonexistent "$2/$rel" ;;
      *) safe_git cat-file blob "$obj" > "$2/$rel" 2> /dev/null ;;
    esac || { echo "read failed"; return 1; }
  done < "$lst"
}

# The facts engine's report (vendored-policy.md, step 2), once for every entry: mtf-facts as
# facts-resolve.sh finds it, outside the clone and the run directory, whose version report lists
# cmd:iam-policy-docs; run on the module root's files at the head, and at the merge base with
# --base, under the time limit and a 16 MiB output cap. The whole report must be one document of
# schema version 1 before any of it is read. Sets FREASON when there is no report.
FREASON=""
facts() {
  [ ! -s "$W/facts.json" ] && [ -z "$FREASON" ] || return 0
  facts_resolve "$clone" "$(dirname "$out")"
  [ "$FACTS_STATE" = ok ] && facts_has cmd:iam-policy-docs || { FREASON="no facts engine"; return 0; }
  local why ba=()
  why="$(tree "$head" "$W/head-tree")" || { FREASON="head $why"; return 0; }
  if [ -n "$base" ]; then
    why="$(tree "$base" "$W/base-tree")" || { FREASON="base $why"; return 0; }
    ba=(--base "$W/base-tree")
  fi
  (cd "$W" && FACTS_RUN_NOERR=1 facts_run 30 16777216 "$FACTS_BIN" iam-policy-docs "$W/head-tree" ${ba[@]+"${ba[@]}"} --timeout 25s) \
    > "$W/facts.out" 2> /dev/null || { FREASON="facts engine failed"; return 0; }
  jq -e -s --arg hb "${base:+1}" 'length == 1 and (.[0] | type == "object" and .schema_version == 1
      and (.head | type == "object" and (.documents | type == "array") and (.directories | type == "array"))
      and (if $hb == "1" then (.base | type == "object" and (.documents | type == "array") and (.directories | type == "array"))
             and (.compare | type == "array") and (.precondition | type == "boolean")
           else .base == null end))' "$W/facts.out" > /dev/null 2>&1 || { FREASON="facts report refused"; return 0; }
  mv -- "$W/facts.out" "$W/facts.json"
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
  # The engine's reading of the block and its wiring (vendored-policy.md, steps 2 and 3). A block
  # both sides read alike, statements and gate, gets no line.
  facts
  [ -z "$FREASON" ] || { line "unknown $FREASON"; continue; }
  mdir="$(dirname -- "$mpath")"
  limit jq -n -c -L "$HERE" --slurpfile r "$W/facts.json" --slurpfile s "$W/subst.json" \
    --arg dir "$mdir" --arg file "${mpath##*/}" --arg block "$block" \
    'include "vendored-policy"; $r[0] | vp_entry($dir; $file; $block; $s[0])' > "$d/entry.json" 2> /dev/null ||
    { line "unknown facts report refused"; continue; }
  jq -e '.skip == true' "$d/entry.json" > /dev/null && continue
  r="$(jq -r '.unknown // empty' "$d/entry.json")"
  [ -z "$r" ] || { line "unknown $r"; continue; }
  bstate="$(jq -r '.base | if . == null then "null" elif . == "absent" then "absent" else "read" end' "$d/entry.json")"
  jq '.head' "$d/entry.json" > "$d/head.json" && jq '.base' "$d/entry.json" > "$d/base.json" || { line "unknown facts report refused"; continue; }
  # The tag: the one release tag the pull request body and the head file name for this upstream.
  # It is evidence only when it is newer than the newest tag the base file names, or, failing that,
  # when it is the upstream's latest release now. A tag older than the base's never is.
  t="$(tags "$up" "$body" "$d/head.tf")"
  [ -n "$t" ] || { line "unknown no tag"; continue; }
  [ "$(wc -l <<< "$t" | tr -d ' ')" = 1 ] || { line "unknown tag ambiguous"; continue; }
  bt=""
  if [ "$bstate" = read ]; then
    while IFS= read -r x; do [ -n "$x" ] && { [ -z "$bt" ] || older "$bt" "$x"; } && bt="$x"; done < <(tags "$up" "$basefile")
  fi
  if [ -n "$bt" ] && older "$t" "$bt"; then line "unknown tag older"; continue; fi
  if [ -z "$bt" ] || ! older "$bt" "$t"; then
    lt="$(latest "$up")" || { line "unknown latest unreadable"; continue; }
    [ "$t" = "$lt" ] || { line "unknown tag not newest"; continue; }
  fi
  sha="$(commit_of "$up" "$t")" || { line "unknown tag not found"; continue; }
  limit gh api "repos/$up/contents/$upath?ref=$sha" > "$d/up.raw" 2> /dev/null &&
    jq -er --arg p "$upath" 'select(.type == "file" and .path == $p and .encoding == "base64" and .size <= 1048576) | .content' \
      "$d/up.raw" 2> /dev/null | tr -d '\n' | base64 -d > "$d/up.json" 2> /dev/null && [ -s "$d/up.json" ] ||
    { line "unknown fetch failed"; continue; }
  if ! limit jq -r -n -L "$HERE" --slurpfile h "$d/head.json" --slurpfile b "$d/base.json" --slurpfile u "$d/up.json" --arg bs "$bstate" '
      include "vendored-policy";
      try ({head: ($h[0] | tuples), up: ($u[0] | upstream | tuples),
            base: (if $bs == "read" then ($b[0] | tuples) elif $bs == "absent" then "absent" else null end)}
        | diff_lines) catch ("unknown " + (if type == "string" and test("^[a-z ]{1,40}$") then . else "upstream unreadable" end))' \
      > "$d/lines" 2> /dev/null; then
    line "unknown upstream unreadable"; continue
  fi
  if grep -q '^unknown ' "$d/lines"; then line "$(grep -m1 '^unknown ' "$d/lines")"; continue; fi
  line "source $up $t $sha $upath"
  line "lines $(jq -r '.lines | map(tostring) | join(" ")' "$d/entry.json")"
  while IFS= read -r x; do line "$x"; done < "$d/lines"
done < "$W/entries"
finish
