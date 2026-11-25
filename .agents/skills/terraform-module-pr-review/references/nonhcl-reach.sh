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
[ "$(printf '%s\n' "$trig" | grep -c .)" -le 40 ] || die

# The module profile's reach file (profile-format.md, Reach of changes outside Terraform): lines
# "not-run <owner/name> <file> <example directory> root-calls <argument>=<literal>". A line outside
# the grammar refuses the whole file.
maps=""
if [ -n "$reach" ] && [ -e "$reach" ]; then
  [ -f "$reach" ] && [ ! -L "$reach" ] && [ "$(wc -c < "$reach" | tr -d ' ')" -le 65536 ] || die
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in '' | '#'*) continue ;; esac
    read -r k r f d gk ga x <<< "$l"
    [ "$k" = not-run ] && [ -z "${x-}" ] && [[ "$r" =~ $repo_re ]] && plain "$f" && plain "$d" &&
      [ "$gk" = root-calls ] && [[ "${ga-}" =~ ^[a-z_][a-z0-9_]{0,63}=(false|true|null|[0-9]{1,9})$ ]] || die
    [ "$r" != "$repo" ] || maps="$maps$f $d $ga"$'\n'
  done < "$reach"
fi

# The module calls of one .tf file on stdin: "<name> <source> <value>" per module block, <value> the
# literal the argument has at the block's own depth or "-" for none, or one line "stale" for any text
# this reader does not take whole: a block comment, a nested quote in an interpolation, a heredoc
# that does not end, a source that is no plain string, an unbalanced brace or a module block that
# does not start a line. A heredoc's lines are a string and are skipped to their closing tag.
calls() {
  awk -v arg="$1" '
    function bad() { print "stale"; failed = 1; exit }
    { line = $0 }
    tag != "" { t = line; gsub(/^[[:space:]]+|[[:space:]]+$/, "", t); if (t == tag) tag = ""; next }
    line ~ /\$\{[^}]*"/ { bad() }
    {
      # Drop a comment outside a string, and every string body, so braces count as code only.
      out = ""; q = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (q) { if (c == "\\") { i++; continue } if (c == "\"") { q = 0; out = out "\"" } continue }
        if (c == "\"") { q = 1; out = out "\""; continue }
        if (c == "#" || (c == "/" && substr(line, i + 1, 1) == "/")) break
        out = out c
      }
      if (q) bad()
      code = out
      if (code ~ /\/\*/) bad()
      if (match(code, /<<-?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/)) {
        tag = substr(code, RSTART, RLENGTH); sub(/^<<-?/, "", tag); sub(/[[:space:]]+$/, "", tag)
        code = substr(code, 1, RSTART - 1)
      } else if (code ~ /<</) bad()
      if (depth == 0 && code ~ /^[[:space:]]*module([[:space:]"]|$)/) {
        if (line !~ /^module "[A-Za-z0-9_-]+" \{[[:space:]]*(#.*)?$/) bad()
        name = line; sub(/^module "/, "", name); sub(/".*/, "", name)
        inmod = 1; src = ""; val = "-"
      } else if (inmod && depth == 1) {
        if (line ~ /^[[:space:]]*source[[:space:]]*=/) {
          if (line !~ /^[[:space:]]*source[[:space:]]*=[[:space:]]*"[^"$]*"[[:space:]]*(#.*)?$/) bad()
          src = line; sub(/^[^"]*"/, "", src); sub(/".*/, "", src)
        }
        a = "^[[:space:]]*" arg "[[:space:]]*="
        if (line ~ a) {
          v = line; sub(a "[[:space:]]*", "", v); sub(/[[:space:]]*(#.*)?$/, "", v)
          val = (v ~ /^(false|true|null|[0-9]+)$/) ? v : "?"
        }
      }
      n = gsub(/\{/, "{", code); m = gsub(/\}/, "}", code)
      depth += n - m
      if (depth < 0) bad()
      if (inmod && depth == 0) { if (src == "") bad(); print name " " src " " val; inmod = 0 }
    }
    END { if (!failed && (depth != 0 || inmod || tag != "")) print "stale" }'
}
# Normalize <example dir>/<relative source> to a repository path; empty for a source that is no
# relative path or climbs out.
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
# The guard of one line at one revision: prints the sorted module calls "<name> <source>" when every
# call whose source is the module root sets the argument to the literal, no .tf file of the example
# names the changed file, and the example is a tree of regular files. Status 1 otherwise.
guard_at() { # rev, dir, file, argument=literal
  local rev="$1" d="$2" f="$3" arg="${4%%=*}" want="${4#*=}" root="${prefix:-.}" mode type name src val r t list=""
  [ "$(g cat-file -t "$rev:$d" 2> /dev/null)" = tree ] || return 1
  while read -r mode type _ name; do
    case "$name" in *.tf.json) return 1 ;; *.tf) ;; *) continue ;; esac
    [ "$mode" = 100644 ] && [ "$type" = blob ] || return 1
    [ "$(g cat-file -s "$rev:$d/$name" 2> /dev/null)" -le 1048576 ] 2> /dev/null || return 1
    t="$(g cat-file blob "$rev:$d/$name" 2> /dev/null)" || return 1
    ! printf '%s\n' "$t" | grep -Fq -- "${f##*/}" || return 1
    r="$(printf '%s\n' "$t" | calls "$arg")" || return 1
    case "$r" in *stale*) return 1 ;; esac
    while read -r name src val; do
      [ -n "$name" ] || continue
      [ "$(resolve "$d" "$src")" != "$root" ] || [ "$val" = "$want" ] || return 1
      list="$list$name $src"$'\n'
    done <<< "$r"
  done < <(g ls-tree "$rev:$d" 2> /dev/null)
  printf '%s' "$list" | sort
}

out='[]'
while IFS= read -r f; do
  [ -n "$f" ] || continue
  plain "$f" || die
  r="$(rp "$f")"
  un='[]'
  while read -r mf md ma; do
    [ "$mf" = "$r" ] || continue
    # A directory that holds a changed file is the change's own business, never cleared.
    printf '%s\n' "$changed" | awk -v d="$md/" 'index($0, d) == 1 { f = 1 } END { exit !f }' && continue
    # The guard at both revisions, and the same module calls at both: a new call makes the line stale.
    hc="$(guard_at "$head" "$md" "$r" "$ma")" || continue
    bc="$(guard_at "$base" "$md" "$r" "$ma")" || continue
    [ "$hc" = "$bc" ] || continue
    un="$(jq -c --arg d "$md" '. + [$d] | unique' <<< "$un")"
  done <<< "$maps"
  out="$(jq -c --arg f "$f" --argjson u "$un" '. + [{file: $f, unreached: $u}]' <<< "$out")" || die
done <<< "$trig"
jq -c -n --arg h "$head" --arg b "$base" --argjson f "$out" '{head_sha: $h, base_sha: $b, files: $f}'
