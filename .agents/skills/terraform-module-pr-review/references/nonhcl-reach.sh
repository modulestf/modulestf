#!/bin/bash
# The evidence of a change outside Terraform (verdict.md, Changes outside Terraform): for each file
# of a non-hcl-dependency trigger, the example directories the module profile says run no such
# file, and the test files at the merge base that import or run it under a workflow that runs
# them on a pull request. Read from git objects only; nothing of the head or the base is run.
#
#   nonhcl-reach.sh --git <clone> --head <sha> --base <merge base sha> --repo <owner/name>
#     --behaviour <behaviour.json> --files <files.json> [--prefix <module root prefix>]
#     [--reach <profile nonhcl-reach.txt>] [--base-ref <base branch>]
#
# Prints {head_sha, base_sha, files: [{file, unreached, tested_by}]} and exits 0, or prints nothing
# and exits 1 on any input it cannot read whole: a malformed reach file among them. File names are
# module-root-relative as the triggers are; example directories and test files repository-relative.
set -uo pipefail
export LC_ALL=C

die() { exit 1; }
git_dir="" head="" base="" repo="" beh="" files="" prefix="" reach="" base_ref=""
while [ $# -gt 0 ]; do
  case "$1" in
    --git) git_dir="${2-}" ;; --head) head="${2-}" ;; --base) base="${2-}" ;; --repo) repo="${2-}" ;;
    --behaviour) beh="${2-}" ;; --files) files="${2-}" ;; --prefix) prefix="${2-}" ;;
    --reach) reach="${2-}" ;; --base-ref) base_ref="${2-}" ;;
    *) die ;;
  esac
  shift 2 || die
done
sha_re='^[0-9a-f]{40}$'
path_re='^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$'
[[ "$head" =~ $sha_re ]] && [[ "$base" =~ $sha_re ]] || die
[[ "$repo" =~ ^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$ ]] || die
[ -d "$git_dir" ] && [ -f "$beh" ] && [ -f "$files" ] || die
[ -z "$prefix" ] || [[ "$prefix" =~ $path_re ]] || die
[ -z "$base_ref" ] || [[ "$base_ref" =~ ^[A-Za-z0-9._/-]{1,200}$ ]] || die
plain() { [ "${#1}" -le 300 ] && [[ "$1" =~ $path_re ]] && ! [[ "/$1/" =~ /\.\.?/ ]]; }

# Plumbing only, with no hook, no filter, no replace ref and no lazy fetch.
g() {
  GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1 git -C "$git_dir" -c core.hooksPath=/dev/null -c core.fsmonitor= "$@"
}
blob() { # rev, path -> the blob on stdout, at most 1 MiB; status 1 for anything else
  [ "$(g cat-file -t "$1:$2" 2> /dev/null)" = blob ] || return 1
  [ "$(g cat-file -s "$1:$2" 2> /dev/null)" -le 1048576 ] 2> /dev/null || return 1
  g cat-file blob "$1:$2" 2> /dev/null
}
g cat-file -e "$head^{commit}" 2> /dev/null && g cat-file -e "$base^{commit}" 2> /dev/null || die

rp() { if [ -z "$prefix" ]; then printf '%s' "$1"; else printf '%s/%s' "$prefix" "$1"; fi; }
trig="$(jq -r '[.triggers[]? | select(.category == "non-hcl-dependency") | .file] | unique | .[]' "$beh" 2> /dev/null)" || die
changed="$(jq -r '.[] | .filename, (.previous_filename // empty)' "$files" 2> /dev/null)" || die
[ "$(printf '%s\n' "$trig" | grep -c .)" -le 40 ] || die

# The module profile's reach file (profile-format.md, Reach of changes outside Terraform): lines
# "not-run <owner/name> <file> <example directory>", both repository-relative. A line outside the
# grammar refuses the whole file.
maps=""
if [ -n "$reach" ] && [ -e "$reach" ]; then
  [ -f "$reach" ] && [ ! -L "$reach" ] && [ "$(wc -c < "$reach" | tr -d ' ')" -le 65536 ] || die
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in '' | '#'*) continue ;; esac
    read -r k r f d x <<< "$l"
    [ "$k" = not-run ] && [ -z "${x-}" ] && [[ "$r" =~ ^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$ ]] && plain "$f" && plain "$d" || die
    [ "$r" != "$repo" ] || maps="$maps$f $d"$'\n'
  done < "$reach"
fi

# The workflows at the merge base that run pytest on a pull request with nothing to skip it: no
# paths filter, no if, no working-directory, no continue-on-error, branches naming the base branch.
# Prints, per such pytest line, its path arguments ("." for none).
pytest_targets() {
  local w t
  while IFS= read -r w; do
    case "$w" in .github/workflows/*.yml | .github/workflows/*.yaml) ;; *) continue ;; esac
    t="$(blob "$base" "$w")" || continue
    t="$(printf '%s\n' "$t" | sed 's/[[:space:]]#.*$//; /^[[:space:]]*#/d')"
    printf '%s\n' "$t" | grep -Eq '(^|[^A-Za-z0-9_-])pull_request([^A-Za-z0-9_-]|$)' || continue
    ! printf '%s\n' "$t" | grep -Eq '^[[:space:]-]*(paths|paths-ignore|branches-ignore|if|working-directory|continue-on-error)[[:space:]]*:' || continue
    if printf '%s\n' "$t" | grep -Eq '^[[:space:]-]*branches[[:space:]]*:'; then
      [ -n "$base_ref" ] && printf '%s\n' "$t" | grep -Fqw -- "$base_ref" || continue
    fi
    printf '%s\n' "$t" | awk '
      { line = $0; sub(/^[[:space:]]*(-[[:space:]]+)?(run:[[:space:]]*)?/, "", line) }
      line ~ /^(python3?[[:space:]]+-m[[:space:]]+)?pytest([[:space:]]|$)/ {
        sub(/^(python3?[[:space:]]+-m[[:space:]]+)?pytest[[:space:]]*/, "", line)
        n = split(line, a, /[[:space:]]+/); out = ""
        for (i = 1; i <= n; i++) if (a[i] != "" && a[i] !~ /^-/) { p = a[i]; sub(/\/+$/, "", p); out = out " " p }
        print (out == "" ? "." : substr(out, 2))
      }'
  done < <(g ls-tree -r --name-only "$base" -- .github/workflows 2> /dev/null | head -n 50)
}
targets="$(pytest_targets)"

# A test file a target covers: "." covers every test file, a path covers itself and what is under it.
covered() {
  local t a
  while IFS= read -r t; do
    for a in $t; do
      [ "$a" = . ] || [ "$1" = "$a" ] || [[ "$1" == "$a"/* ]] && return 0
    done
  done <<< "$targets"
  return 1
}

# The test files at the merge base, under the repository's or the module root's tests directory.
tests="$( { g ls-tree -r --name-only "$base" -- tests; [ -z "$prefix" ] || g ls-tree -r --name-only "$base" -- "$prefix/tests"; } 2> /dev/null |
  grep -E '(^|/)(test_[^/]*\.py|[^/]*_test\.py)$' | sort -u | head -n 200)"

out='[]'
while IFS= read -r f; do
  [ -n "$f" ] || continue
  plain "$f" || die
  r="$(rp "$f")"
  # unreached: the profile's directories for this file and repository, each a directory at the head
  # holding no changed file.
  un='[]'
  while read -r mf md; do
    [ "$mf" = "$r" ] || continue
    [ "$(g cat-file -t "$head:$md" 2> /dev/null)" = tree ] || continue
    printf '%s\n' "$changed" | awk -v d="$md/" 'index($0, d) == 1 { f = 1 } END { exit !f }' && continue
    un="$(jq -c --arg d "$md" '. + [$d] | unique' <<< "$un")"
  done <<< "$maps"
  # tested_by: test files at the merge base a pytest target covers that import or name the file,
  # when the file itself exists at the merge base.
  tb='[]'
  if [ -n "$targets" ] && [ "$(g cat-file -t "$base:$r" 2> /dev/null)" = blob ]; then
    b="${f##*/}"; m="${b%.py}"
    while IFS= read -r t; do
      [ -n "$t" ] && covered "$t" || continue
      body="$(blob "$base" "$t")" || continue
      if { [ "$m" != "$b" ] && [[ "$m" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && printf '%s\n' "$body" | grep -Eq "^[[:space:]]*(from[[:space:]]+$m[[:space:]]+import|import[[:space:]]+$m([[:space:],]|\$))"; } ||
         printf '%s\n' "$body" | grep -v '^[[:space:]]*#' | grep -Fqw -- "$b"; then
        tb="$(jq -c --arg t "$t" '. + [$t] | unique' <<< "$tb")"
      fi
    done <<< "$tests"
  fi
  out="$(jq -c --arg f "$f" --argjson u "$un" --argjson t "$tb" '. + [{file: $f, unreached: $u, tested_by: $t}]' <<< "$out")" || die
done <<< "$trig"
jq -c -n --arg h "$head" --arg b "$base" --argjson f "$out" '{head_sha: $h, base_sha: $b, files: $f}'
