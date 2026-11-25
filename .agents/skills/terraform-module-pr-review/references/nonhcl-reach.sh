#!/bin/bash
# The evidence of a change outside Terraform (verdict.md, Changes outside Terraform): for each file
# of a non-hcl-dependency trigger, the example directories the module profile proves run no such
# file, each by a guard checked at the head and at the merge base. Read from git objects only;
# nothing of the head or the base is run.
#
#   nonhcl-reach.sh --git <clone> --head <sha> --base <merge base sha> --repo <owner/name>
#     --behaviour <behaviour.json> --files <files.json> [--prefix <module root prefix>]
#     [--reach <profile nonhcl-reach.txt>]
#
# Prints {head_sha, base_sha, files: [{file, unreached}]} and exits 0, or prints nothing and exits 1
# on any input it cannot read whole: a malformed reach file among them. File names are
# module-root-relative as the triggers are; example directories repository-relative.
set -uo pipefail
set -f
export LC_ALL=C

die() { exit 1; }
git_dir="" head="" base="" repo="" beh="" files="" prefix="" reach=""
while [ $# -gt 0 ]; do
  case "$1" in
    --git) git_dir="${2-}" ;; --head) head="${2-}" ;; --base) base="${2-}" ;; --repo) repo="${2-}" ;;
    --behaviour) beh="${2-}" ;; --files) files="${2-}" ;; --prefix) prefix="${2-}" ;;
    --reach) reach="${2-}" ;;
    *) die ;;
  esac
  shift 2 || die
done
sha_re='^[0-9a-f]{40}$'
path_re='^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$'
repo_re='^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$'
[[ "$head" =~ $sha_re ]] && [[ "$base" =~ $sha_re ]] || die
[[ "$repo" =~ $repo_re ]] || die
[ -d "$git_dir" ] && [ -f "$beh" ] && [ -f "$files" ] || die
[ -z "$prefix" ] || [[ "$prefix" =~ $path_re ]] || die
plain() { [ "${#1}" -le 300 ] && [[ "$1" =~ $path_re ]] && ! [[ "/$1/" =~ /\.\.?/ ]]; }

# Plumbing only, in the form of the sibling scripts: no system or global config, no hook, no
# filter, no pager, no replace ref or graft, no protocol and no lazy fetch.
g() {
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_GRAFT_FILE=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_NO_LAZY_FETCH=1 git --no-pager -C "$git_dir" -c core.hooksPath=/dev/null -c core.fsmonitor= \
    -c protocol.allow=never "$@"
}
# A partial clone could fetch a missing object on read: refused.
[ -z "$(g config --get extensions.partialclone 2> /dev/null)" ] || die
! g config --get-regexp '^remote\..*\.(promisor|partialclonefilter)$' > /dev/null 2>&1 || die
g cat-file -e "$head^{commit}" 2> /dev/null && g cat-file -e "$base^{commit}" 2> /dev/null || die

rp() { if [ -z "$prefix" ]; then printf '%s' "$1"; else printf '%s/%s' "$prefix" "$1"; fi; }
trig="$(jq -r '[.triggers[]? | select(.category == "non-hcl-dependency") | .file] | unique | .[]' "$beh" 2> /dev/null)" || die
changed="$(jq -r '.[] | .filename, (.previous_filename // empty)' "$files" 2> /dev/null)" || die
[ "$(grep -c . <<< "$trig")" -le 40 ] || die
# A check reads its input whole: a here-string, never "printf | grep -q", whose early exit under
# pipefail could read as "not found". A byte order mark or a non-ASCII space in any file read, where
# the reader and Terraform could disagree, makes a line stale.
wide=$'\xef\xbb\xbf|\xc2\xa0|\xe2\x80[\x80-\x8b]|\xe2\x80\xaf|\xe2\x81\x9f|\xe3\x80\x80'


# The module profile's reach file (profile-format.md, Reach of changes outside Terraform): lines
# "not-run <owner/name> <file> <example directory> root-calls <argument>=<literal> gated-by var.<name>".
# A line outside the grammar, or a file and directory named twice, refuses the whole file.
maps=""
if [ -n "$reach" ] && [ -e "$reach" ]; then
  [ -f "$reach" ] && [ ! -L "$reach" ] && [ "$(wc -c < "$reach" | tr -d ' ')" -le 65536 ] || die
  seen=""
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in '' | '#'*) continue ;; esac
    read -r k r f d gk ga bk bv x <<< "$l"
    [ "$k" = not-run ] && [ -z "${x-}" ] && [[ "$r" =~ $repo_re ]] && plain "$f" && plain "$d" &&
      [ "$gk" = root-calls ] && [[ "${ga-}" =~ ^[a-z_][a-z0-9_]{0,63}=(false|true|null|[0-9]{1,9})$ ]] &&
      [ "${bk-}" = gated-by ] && [[ "${bv-}" =~ ^var\.[a-z_][a-z0-9_]{0,63}$ ]] || die
    case "$seen" in *"|$r $f $d|"*) die ;; esac
    seen="$seen|$r $f $d|"
    [ "$r" != "$repo" ] || maps="$maps$f $d $ga ${bv#var.}"$'\n'
  done < "$reach"
fi

# The reader of one .tf file on stdin. In "calls" mode it prints "<name> <source> <value>" per module
# block, <value> the literal the argument -v arg has at the block's own depth, "-" for none or "?"
# for any other value. In "blocks" mode it prints, per top-level block whose text names -v name or
# calls fileset, "<header>\t<count or for_each line at the block's own depth, or empty>". Either mode
# prints the one line "stale" for any text it does not take whole: a block comment, a quote or a
# heredoc inside a template interpolation or directive, a line that ends inside a string, a template
# sequence in a heredoc body, a heredoc that does not end, an unbalanced brace, a module block that
# does not start a line, a source that is no plain string, or (blocks mode) a name outside a block.
reader() { # mode, arg, name
  awk -v mode="$1" -v arg="$2" -v name="$3" '
    function bad() { print "stale"; failed = 1; exit }
    function names(s) { return (name != "" && index(s, name) > 0) || s ~ /fileset[[:space:]]*\(/ }
    { line = $0; sub(/\r$/, "", line); if (line ~ /[^\t -~]/) bad() }
    tag != "" {
      t = line; gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
      if (t == tag) { tag = ""; next }
      if (line ~ /[$%]\{/) bad()
      if (inblk && names(line)) hit = 1
      if (depth == 0 && names(line)) bad()
      next
    }
    {
      # Code only: comments dropped, string bodies emptied; inside a template sequence of a string
      # ("${" or "%{") braces nest and a quote is refused.
      out = ""; q = 0; lvl = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1); n2 = substr(line, i + 1, 1)
        if (q && lvl == 0) {
          if (c == "\\") { i++; continue }
          if ((c == "$" || c == "%") && n2 == c) { i++; continue }
          if ((c == "$" || c == "%") && n2 == "{") { lvl = 1; i++; continue }
          if (c == "\"") { q = 0; out = out "\"" }
          continue
        }
        if (q) {
          if (c == "\"" || (c == "<" && n2 == "<")) bad()
          if (c == "{") lvl++
          else if (c == "}") lvl--
          continue
        }
        if (c == "\"") { q = 1; out = out "\""; continue }
        if (c == "#" || (c == "/" && n2 == "/")) break
        out = out c
      }
      if (q) bad()
      code = out
      if (code ~ /\/\*/) bad()
      if (match(code, /<<-?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/)) {
        tag = substr(code, RSTART, RLENGTH); sub(/^<<-?/, "", tag); sub(/[[:space:]]+$/, "", tag)
        code = substr(code, 1, RSTART - 1)
      } else if (code ~ /<</) bad()
      if (depth == 0 && mode == "calls" && code ~ /^[[:space:]]*module([[:space:]"]|$)/) {
        if (line !~ /^module "[A-Za-z0-9_-]+" \{[[:space:]]*(#.*)?$/) bad()
        bname = line; sub(/^module "/, "", bname); sub(/".*/, "", bname)
        inmod = 1; src = ""; val = "-"
      } else if (depth == 0 && mode == "blocks" && code ~ /\{/) {
        if (line !~ /^[a-z_]+( "[A-Za-z0-9_.-]+")* \{[[:space:]]*$/) bad()
        header = line; sub(/[[:space:]]*\{[[:space:]]*$/, "", header)
        inblk = 1; hit = 0; gate = ""
      } else if (depth == 0 && mode == "blocks" && names(line)) bad()
      if (inmod && depth == 1) {
        if (line ~ /^[[:space:]]*source[[:space:]]*=/) {
          if (line !~ /^[[:space:]]*source[[:space:]]*=[[:space:]]*"[^"$%\\]*"[[:space:]]*(#.*)?$/) bad()
          src = line; sub(/^[^"]*"/, "", src); sub(/".*/, "", src)
        }
        a = "^[[:space:]]*" arg "[[:space:]]*="
        if (line ~ a) {
          v = line; sub(a "[[:space:]]*", "", v); sub(/[[:space:]]*(#.*)?$/, "", v)
          val = (v ~ /^(false|true|null|[0-9]+)$/) ? v : "?"
        }
      }
      if (inblk && depth == 1 && line ~ /^[[:space:]]*(count|for_each)[[:space:]]*=/) {
        g = code; gsub(/^[[:space:]]+|[[:space:]]+$/, "", g); gate = g
      }
      if (inblk && names(line)) hit = 1
      n = gsub(/\{/, "{", code); m = gsub(/\}/, "}", code)
      depth += n - m
      if (depth < 0) bad()
      if (inmod && depth == 0) { if (src == "") bad(); print bname " " src " " val; inmod = 0 }
      if (inblk && depth == 0) { if (hit) print header "\t" gate; inblk = 0 }
    }
    END { if (!failed && (depth != 0 || inmod || inblk || tag != "")) print "stale" }'
}
# Normalize <directory>/<relative source> to a repository path; empty for a source that is no
# relative path or climbs out of the repository.
resolve() {
  local d="$1" s="$2" p part out=()
  case "$s" in ./* | ../*) ;; *) return 0 ;; esac
  p="$d/$s"
  local IFS=/
  for part in $p; do
    case "$part" in '' | .) ;; ..) [ "${#out[@]}" -gt 0 ] || return 0; unset 'out[${#out[@]}-1]' ;; *) out+=("$part") ;; esac
  done
  [ "${#out[@]}" -gt 0 ] && printf '%s' "${out[*]}" || printf '.'
}
# The entries of a tree, NUL-separated and never quoted: "<mode> <type> <path>" per line, every path
# segment in the plain charset; status 1 for any other name. -r for the whole tree.
entries() { # rev, dir [, -r]
  local e meta path t="$2"
  [ "$t" != . ] || t=""
  while IFS= read -r -d '' e; do
    meta="${e%%$'\t'*}"; path="${e#*$'\t'}"
    plain "$path" || return 1
    printf '%s %s %s\n' "${meta%% *}" "$(printf '%s' "$meta" | cut -d' ' -f2)" "$path"
  done < <(g ls-tree -z ${3:-} "$1:$t" 2> /dev/null)
}
# The example guard at one revision: prints the sorted module calls "<name> <source>" when the
# example is a tree of regular files of at most 1 MiB with no link or gitlink, every .tf file at its
# top, no .tf.json or OpenTofu file, no file naming the changed file, no fileset call, at least one
# module call, and every module call has the module root as its source and sets the argument to the
# literal. Status 1 otherwise.
guard_at() { # rev, dir, file, argument=literal
  local rev="$1" d="$2" b="${3##*/}" arg="${4%%=*}" want="${4#*=}" root="${prefix:-.}" ents mode type path t r name src val list=""
  [ "$(g cat-file -t "$rev:$d" 2> /dev/null)" = tree ] || return 1
  ents="$(entries "$rev" "$d" -r)" || return 1
  while read -r mode type path; do
    [ -n "$path" ] || continue
    [ "$mode" = 100644 ] || [ "$mode" = 100755 ] || return 1
    [ "$type" = blob ] || return 1
    case "$path" in *.tf.json | *.tofu | *.tofu.json) return 1 ;; */*.tf) return 1 ;; esac
    [ "$(g cat-file -s "$rev:$d/$path" 2> /dev/null)" -le 1048576 ] 2> /dev/null || return 1
    t="$(g cat-file blob "$rev:$d/$path" 2> /dev/null)" || return 1
    ! grep -Fq -- "$b" <<< "$t" || return 1
    ! grep -Eq "$wide" <<< "$t" || return 1
    case "$path" in *.tf) ;; *) continue ;; esac
    [ "$mode" = 100644 ] || return 1
    ! grep -Eq 'fileset[[:space:]]*\(' <<< "$t" || return 1
    r="$(reader calls "$arg" "" <<< "$t")" || return 1
    case "$r" in *stale*) return 1 ;; esac
    while read -r name src val; do
      [ -n "$name" ] || continue
      [ "$(resolve "$d" "$src")" = "$root" ] && [ "$val" = "$want" ] || return 1
      list="$list$name $src"$'\n'
    done <<< "$r"
  done <<< "$ents"
  [ -n "$list" ] || return 1
  printf '%s' "$list" | sort
}
# The root gate at one revision: prints the sorted "<file>\t<header>\t<gate>" of every top-level block
# of the module root's .tf files that names the changed file or calls fileset, when each such block
# has a count or for_each at its own depth that reads var.<name>, and at least one does. Status 1
# otherwise: a link, a .tf.json or OpenTofu file that names it, or text the reader does not take.
gate_at() { # rev, file, var name
  local rev="$1" b="${2##*/}" v="$3" root="${prefix:-.}" ents mode type path t r h gl list=""
  ents="$(entries "$rev" "$root")" || return 1
  while read -r mode type path; do
    case "$path" in *.tf | *.tf.json | *.tofu | *.tofu.json) ;; *) continue ;; esac
    t="$(g cat-file blob "$rev:${prefix:+$prefix/}$path" 2> /dev/null)" || return 1
    grep -Fq -- "$b" <<< "$t" || grep -Eq 'fileset[[:space:]]*\(' <<< "$t" || continue
    [ "$mode" = 100644 ] && [ "$type" = blob ] || return 1
    case "$path" in *.tf) ;; *) return 1 ;; esac
    r="$(reader blocks "" "$b" <<< "$t")" || return 1
    case "$r" in *stale*) return 1 ;; esac
    while IFS=$'\t' read -r h gl; do
      [ -n "$h" ] || continue
      grep -Eq "^(count|for_each)[[:space:]]*=.*(^|[^A-Za-z0-9_.])var\.$v([^A-Za-z0-9_]|\$)" <<< "$gl" || return 1
      list="$list$path"$'\t'"$h"$'\t'"$gl"$'\n'
    done <<< "$r"
  done <<< "$ents"
  [ -n "$list" ] || return 1
  printf '%s' "$list" | sort
}

# A change that edits a .tf file of the module root changes what the gate means: nothing is cleared.
rootre="^${prefix:+$prefix/}[^/]+\.(tf|tf\.json|tofu|tofu\.json)$"
root_changed=false
! grep -Eq "$rootre" <<< "$changed" || root_changed=true

out='[]'
while IFS= read -r f; do
  [ -n "$f" ] || continue
  plain "$f" || die
  r="$(rp "$f")"
  un='[]'
  while read -r mf md ma mv; do
    [ "$mf" = "$r" ] && [ "$root_changed" = false ] || continue
    # A directory that holds a changed file is the change's own business, never cleared.
    awk -v d="$md/" 'index($0, d) == 1 { f = 1 } END { exit !f }' <<< "$changed" && continue
    # Both guards at both revisions, and the same module calls and gates at both.
    hc="$(guard_at "$head" "$md" "$r" "$ma")" || continue
    bc="$(guard_at "$base" "$md" "$r" "$ma")" || continue
    [ "$hc" = "$bc" ] || continue
    hg="$(gate_at "$head" "$r" "$mv")" || continue
    bg="$(gate_at "$base" "$r" "$mv")" || continue
    [ "$hg" = "$bg" ] || continue
    un="$(jq -c --arg d "$md" '. + [$d] | unique' <<< "$un")"
  done <<< "$maps"
  out="$(jq -c --arg f "$f" --argjson u "$un" '. + [{file: $f, unreached: $u}]' <<< "$out")" || die
done <<< "$trig"
jq -c -n --arg h "$head" --arg b "$base" --argjson f "$out" '{head_sha: $h, base_sha: $b, files: $f}'
