#!/bin/bash
# Checks the shape of every work in progress skill. A SKILL.md under .agents/skills/
# is one when its description says "Work in progress" in any case, or its body holds
# the head of the Status template below. It must then have a frontmatter description
# that opens, unquoted, with "Work in progress, not usable yet.", so a drifted or
# quoted prefix fails instead of escaping the checks. Such a skill is a skeleton that
# refuses every request. Its frontmatter name is its directory, its body opens with one
# level-1 title and then the Status section, and that section is the one fixed
# paragraph below, where only the skill name slot varies and names an existing skill
# directory that is not itself work in progress. Its other headings, at column 0 or
# indented up to three spaces, are level-2 sections from the allow-list, in that order,
# and no line is an HTML heading tag. It holds no backtick and no fenced code. At least
# one such skill must exist. A negative self-check mutates temp copies and confirms
# each check catches its breakage. No network. Run: tests/wip-skills-test.sh
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$SRC/.agents/skills"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0

PREFIX='Work in progress, not usable yet.'
TPL_HEAD='Work in progress. This skill does nothing yet: refuse the request, read and write nothing, and use '
TPL_TAIL=' instead.'
ALLOWED=('Status' 'Use cases' 'Responsibilities' 'Non-goals' 'Open questions')

# The value of one frontmatter key, from the block between the first two --- lines.
field() { # file key
  awk -v k="$2" '
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    index($0, k ": ") == 1 { print substr($0, length(k) + 3); exit }
  ' "$1"
}

# The lines after the frontmatter.
body() {
  awk 'NR == 1 && $0 == "---" { fm = 1; next } fm && $0 == "---" { fm = 0; next } !fm' "$1"
}

# A file that claims or looks like a work in progress skill, by either sign.
is_wip() { # file
  local d
  d="$(field "$1" description | tr '[:upper:]' '[:lower:]')"
  [[ "$d" == *'work in progress'* ]] && return 0
  body "$1" | grep -qF "$TPL_HEAD"
}

# Every work in progress SKILL.md under a skills root, one path per line.
discover() { # root
  local f
  for f in "$1"/*/SKILL.md; do
    [ -f "$f" ] && is_wip "$f" && printf '%s\n' "$f"
  done
}

check_prefix() { # file root
  [[ "$(field "$1" description)" == "$PREFIX"* ]]
}

check_name() { # file root
  [ "$(field "$1" name)" = "$(basename "$(dirname "$1")")" ]
}

check_status() { # file root
  local text slot own
  # The Status section without its leading and trailing blank lines: exactly one line.
  text="$(body "$1" | awk '
    $0 == "## Status" { on = 1; next }
    on && /^ ? ? ?#/ { exit }
    on { a[++n] = $0 }
    END {
      s = 1; while (s <= n && a[s] == "") s++
      e = n; while (e >= s && a[e] == "") e--
      for (i = s; i <= e; i++) print a[i]
    }')"
  [[ "$text" == "$TPL_HEAD"*"$TPL_TAIL" ]] || return 1
  [[ "$text" != *$'\n'* ]] || return 1
  slot="${text#"$TPL_HEAD"}"; slot="${slot%"$TPL_TAIL"}"
  [[ "$slot" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
  own="$(basename "$(dirname "$1")")"
  [ "$slot" != "$own" ] || return 1
  [ -d "$2/$slot" ] && [ -f "$2/$slot/SKILL.md" ] || return 1
  ! is_wip "$2/$slot/SKILL.md"
}

check_headings() { # file root
  local first second heads h i next=0 found
  first="$(body "$1" | awk 'NF { print; exit }')"
  second="$(body "$1" | awk 'NF && ++n == 2 { print; exit }')"
  [[ "$first" == '# '?* ]] || return 1
  [ "$second" = '## Status' ] || return 1
  ! body "$1" | grep -qiE '^[[:space:]]*<h[1-6]([[:space:]>]|$)' || return 1
  [ "$(body "$1" | grep -cE '^ {0,3}# ')" -eq 1 ] || return 1
  heads="$(body "$1" | grep -E '^ {0,3}#' | tail -n +2)"
  while IFS= read -r h; do
    found=0
    for ((i = next; i < ${#ALLOWED[@]}; i++)); do
      if [ "$h" = "## ${ALLOWED[$i]}" ]; then found=1; next=$((i + 1)); break; fi
    done
    [ "$found" -eq 1 ] || return 1
  done <<< "$heads"
}

check_backticks() { ! grep -q '`' "$1"; }

check_fences() { ! grep -qE '^ {0,3}(```|~~~)' "$1"; }

CHECKS=(check_prefix check_name check_status check_headings check_backticks check_fences)

# The real tree.
wip=()
while IFS= read -r f; do wip+=("$f"); done < <(discover "$ROOT")
if [ "${#wip[@]}" -eq 0 ]; then
  echo "FAIL discover: no work in progress skill under .agents/skills/"; fails=$((fails + 1))
else
  echo "ok   discover (${#wip[@]} work in progress skills)"
fi
for f in "${wip[@]}"; do
  rel="${f#"$SRC/"}"
  for c in "${CHECKS[@]}"; do
    if "$c" "$f" "$ROOT"; then echo "ok   ${c#check_}: $rel"
    else echo "FAIL ${c#check_}: $rel"; fails=$((fails + 1)); fi
  done
done

# Negative self-check: each mutation of a temp copy must fail the named check. A
# prefix mutation must also still be discovered, or it would escape every check.
caught=0
n_mut=0
mutate() { # check, description, before, after
  local c="$1" what="$2" before="$3" after="$4" base="${wip[0]}" content copy dir
  n_mut=$((n_mut + 1))
  dir="$TMP/m$n_mut"
  copy="$dir/$(basename "$(dirname "$base")")/SKILL.md"
  mkdir -p "$(dirname "$copy")"
  content="$(cat "$base")"
  if [[ "$content" != *"$before"* ]]; then
    echo "FAIL self-check: '$what' found no text to mutate"; fails=$((fails + 1)); return
  fi
  printf '%s\n' "${content/"$before"/"$after"}" > "$copy"
  if [ "$c" = check_prefix ] && [ "$(discover "$dir")" != "$copy" ]; then
    echo "FAIL self-check: discover missed '$what'"; fails=$((fails + 1)); return
  fi
  if "$c" "$copy" "$ROOT"; then
    echo "FAIL self-check: ${c#check_} missed '$what'"; fails=$((fails + 1))
  else
    caught=$((caught + 1))
  fi
}

if [ "${#wip[@]}" -gt 0 ]; then
  self="$(basename "$(dirname "${wip[0]}")")"
  other_wip=""
  for f in "${wip[@]}"; do
    d="$(basename "$(dirname "$f")")"; [ "$d" != "$self" ] && { other_wip="$d"; break; }
  done
  slot="$(body "${wip[0]}" | grep -F "$TPL_HEAD" | head -n 1)"
  slot="${slot#"$TPL_HEAD"}"; slot="${slot%"$TPL_TAIL"}"

  mutate check_prefix 'a changed prefix' "$PREFIX" 'Work in progress, not ready yet.'
  mutate check_prefix 'a quoted description' "description: $PREFIX" "description: \"$PREFIX"
  mutate check_prefix 'a description with no work in progress words' "description: $PREFIX" 'description: A module skill.'
  mutate check_name 'a name that is not the directory' "name: $self" "name: $self-x"
  mutate check_status 'a changed Status sentence' 'read and write nothing' 'read nothing'
  mutate check_status 'a second Status line' "$TPL_TAIL" "$TPL_TAIL"$'\nMore text.'
  mutate check_status 'a slot with no directory' "use $slot instead" 'use no-such-skill instead'
  mutate check_status 'a slot that names the skill itself' "use $slot instead" "use $self instead"
  [ -n "$other_wip" ] &&
    mutate check_status 'a slot that names a work in progress skill' "use $slot instead" "use $other_wip instead"
  mutate check_status 'no Status section' '## Status' '## Use cases'
  mutate check_headings 'a heading outside the allow-list' '## Status' $'## Usage\n\nText.\n\n## Status'
  mutate check_headings 'a section out of order' '## Status' $'## Status\n\nText.\n\n## Open questions\n\nText.\n\n## Use cases'
  mutate check_headings 'a section before Status' '## Status' $'## Use cases\n\nText.\n\n## Status'
  mutate check_headings 'a level-3 heading' '## Status' $'## Status\n\n### Detail'
  mutate check_headings 'a second title' '## Status' $'# Another title\n\n## Status'
  mutate check_headings 'no title' "# " "Title: "
  mutate check_headings 'a paragraph between the title and Status' '## Status' $'Some text.\n\n## Status'
  mutate check_headings 'an indented heading outside the allow-list' '## Use cases' $'   ## Usage\n\nText.\n\n## Use cases'
  mutate check_headings 'an HTML heading tag' '## Use cases' $'<h2>Usage</h2>\n\n## Use cases'
  mutate check_backticks 'a backtick' 'nothing yet' 'nothing `yet`'
  mutate check_fences 'a tilde fence' '## Status' $'~~~\ncode\n~~~\n\n## Status'

  # Discovery must report zero for a tree with no work in progress skill.
  mkdir -p "$TMP/empty/plain"
  printf -- '---\nname: plain\ndescription: A shipped skill.\n---\n\n# Plain\n' > "$TMP/empty/plain/SKILL.md"
  if [ -n "$(discover "$TMP/empty")" ]; then
    echo "FAIL self-check: discover found a skill with no sign of work in progress"
    fails=$((fails + 1))
  else
    caught=$((caught + 1))
  fi
  echo "ok   self-check ($caught mutations caught)"
fi

[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
