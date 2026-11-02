#!/bin/bash
# Prints one section of a markdown file of this skill: the heading whose slug is ANCHOR,
# down to the line before the next heading of the same or a higher level.
#   bash section.sh <file> <anchor>
# FILE is relative to the skill root, as references/check-a-compatibility.md, or an
# absolute path inside it. A link in a run summary, ../x.md#y, is references/x.md and y.
# ANCHOR is the slug of the heading, with or without its leading #, by the rule
# tests/skills-test.sh checks links with. Headings inside fenced code and front matter are
# not headings. The script reads that one file and writes only to stdout.
# Exit status: 0 printed; 1 no heading or more than one has that slug; 2 usage, or a
# file that is not a regular .md file inside the skill, a symbolic link included.
set -eu
unset CDPATH
export LC_ALL=C

refuse() { echo "section.sh: $1" >&2; exit 2; }
[ "$#" -eq 2 ] || refuse "usage: section.sh <file> <anchor>"

case "$0" in */*) h="${0%/*}" ;; *) h=. ;; esac
S="$(cd "$h/.." && pwd -P)"
f="$1"
a="${2#\#}"
case "$a" in '' | *[!a-z0-9_-]*) refuse "not an anchor: $2" ;; esac
case "$f" in /*) ;; *) f="$S/$f" ;; esac
d="${f%/*}"
b="${f##*/}"
[ -n "$d" ] || d=/
case "$b" in *.md) ;; *) refuse "not a markdown file: $1" ;; esac
r="$(cd "$d" 2> /dev/null && pwd -P)" || refuse "no such directory: $1"
case "$r/" in "$S"/*) ;; *) refuse "outside the skill: $1" ;; esac
[ -f "$r/$b" ] && [ ! -L "$r/$b" ] || refuse "not a regular file: $1"

awk -v want="$a" '
  function slug(t) {
    gsub(/`/, "", t); t = tolower(t)
    gsub(/[^a-z0-9_ -]/, "", t); gsub(/ /, "-", t)
    return t
  }
  FNR == 1 && $0 == "---" { fm = 1; next }
  fm { if ($0 == "---") fm = 0; next }
  {
    s = $0; sub(/^ ? ? ?/, "", s)
    if (s ~ /^```/ || s ~ /^~~~/) {
      c = substr(s, 1, 1); n = 0
      while (substr(s, n + 1, 1) == c) n++
      if (fence == 0) { fence = n; fc = c }
      else if (c == fc && n >= fence && substr(s, n + 1) ~ /^ *$/) fence = 0
    } else if (fence == 0 && $0 ~ "^#+[\040\011]") {
      lvl = match($0, /[^#]/) - 1
      t = $0; sub(/^#+[\040\011]+/, "", t); sub(/[\040\011]+$/, "", t)
      if (on && lvl <= on) on = 0
      if (slug(t) == want && ++hits == 1) on = lvl
    }
    if (on) out[++k] = $0
  }
  END {
    if (hits == 0) { print "section.sh: no heading has the slug " want > "/dev/stderr"; exit 1 }
    if (hits > 1) { print "section.sh: " hits " headings have the slug " want > "/dev/stderr"; exit 1 }
    for (i = 1; i <= k; i++) print out[i]
  }
' "$r/$b"
