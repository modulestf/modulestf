#!/bin/bash
# Assembles prefix.md, the judgment variant's static prefix, from the reviewer's own files:
#   bash assemble.sh > prefix.md
# It reads only files in this skill, writes only to stdout and makes no network call, so the
# same sources give the same bytes. tests/skills-test.sh runs it again and compares the
# result with the committed prefix.md.
#
# Only workflow.md is written for the prefix. Every other part is copied, never retyped.
# Each copy drops its file's front matter and top blockquote, shifts its headings one level
# down and prefixes them with its file's label so no two slugs collide, and rewrites its
# relative links to resolve from this directory. Anchor-only links point back at the source
# file. A heading or line the assembly drops must be there: a source that changed shape
# stops the run instead of leaking through.
set -euo pipefail
export LC_ALL=C

J="$(cd "$(dirname "$0")" && pwd)"
R="$(dirname "$J")"   # references/
S="$(dirname "$R")"   # the skill root

# copy FILE PREFIX LABEL DROPS: FILE with its links rewritten (PREFIX is the path from this
# directory to FILE's directory), its headings shifted and labelled with LABEL, and each
# entry of DROPS applied. LABEL "-" copies FILE as written. DROPS is a list of "kind:value"
# separated by "|":
#   h:<heading text>  drop the heading and its section, down to the next heading of its level or higher
#   k:<heading start> keep only the sections whose heading starts so, under a level-2 section
#                     whose Engine line is `candidate`, their level unshifted
#   l:<ERE>           drop every line that matches, outside fenced code; it must match once at least
copy() {
  awk -v src="$1" -v pre="$2" -v label="$3" -v drops="$4" '
    function norm(p,   q) {   # drop each "dir/../" pair
      while (match(p, /(^|\/)[^\/.][^\/]*\/\.\.\//)) {
        q = substr(p, RSTART, RLENGTH)
        p = substr(p, 1, RSTART - 1) (substr(q, 1, 1) == "/" ? "/" : "") substr(p, RSTART + RLENGTH)
      }
      return p
    }
    function relink(s,   o, t, i, j) {   # rewrite every ](target)
      o = ""
      while ((i = index(s, "](")) > 0) {
        j = index(substr(s, i + 2), ")"); if (j == 0) break
        t = substr(s, i + 2, j - 1)
        if (t ~ /^#/) t = self t
        else if (t !~ /^[a-z]+:/) { t = norm(pre t); sub(/^\.\.\/\.\.\/references\//, "../", t) }
        o = o substr(s, 1, i + 1) t ")"; s = substr(s, i + 2 + j)
      }
      return o s
    }
    function out(s) {   # blank runs squeezed to one, none leading or trailing
      if (s == "") { pend = printed; return }
      if (pend) print ""
      pend = 0; printed = 1; print s
    }
    BEGIN {
      n = split(src, a, "/"); self = norm(pre a[n]); shift = 1
      if (label == "-") { label = ""; shift = 0; self = "" }
      k = split(drops, d, "|")
      for (i = 1; i <= k; i++) {
        if (d[i] ~ /^h:/) dh[substr(d[i], 3)] = 0
        else if (d[i] ~ /^k:/) keep = substr(d[i], 3)
        else if (d[i] ~ /^l:/) dl[substr(d[i], 3)] = 0
      }
    }
    NR == 1 && /^---$/ { front = 1; next }
    front { if (/^---$/) front = 0; next }
    {
      isfence = ($0 ~ /^ ? ? ?(```|~~~)/)
      if (!fence && /^#+ /) {
        lvl = index($0, " ") - 1; text = substr($0, lvl + 2)
        if (keep != "") {
          if (lvl == 2) eng = ""
          if (index(text, keep) == 1 && eng == "candidate") { on = lvl; out(relink($0)); next }
          if (on && lvl <= on) on = 0
          next
        }
        if (skip && lvl <= skip) skip = 0
        if (!skip && (text in dh)) { dh[text]++; skip = lvl }
        if (skip) next
        if (label != "" && index(text, label) != 1) text = label ": " text
        out(substr("#######", 1, lvl + shift) " " relink(text)); next
      }
      if (keep != "" && /^Engine: `[a-z]+`$/) eng = substr($0, 10, length($0) - 10)
      if ((keep != "" && !on) || skip) { if (isfence) fence = !fence; next }
      if (isfence) { fence = !fence; out($0); next }
      if (fence) { out($0); next }
      if (!seen && /^>/) next
      if ($0 != "") seen = 1
      for (p in dl) if ($0 ~ p) { dl[p]++; next }
      out(relink($0))
    }
    END {
      for (p in dh) if (!dh[p]) { print "assemble: " src ": no heading " p > "/dev/stderr"; bad = 1 }
      for (p in dl) if (!dl[p]) { print "assemble: " src ": no line matches " p > "/dev/stderr"; bad = 1 }
      if (bad) exit 1
    }
  ' "$1"
}

# Each check keeps its Reads, Fails when and Severity text. Its other sections are the
# on-demand reads workflow.md names; Check B's Fails when sits in its Rules section.
drops_of() {
  case "$1" in
    a-compatibility) echo "h:Suggested Fixes|h:No base" ;;
    b-coverage) echo "h:Which blocks|h:Documented omissions|h:Suggested Fixes" ;;
    c-structure|e-profile) echo "h:Suggested Fixes" ;;
    d-examples) echo "h:Suggested Fixes|h:Plan evidence" ;;
    f-scope) echo "h:The suggested fix|h:Suggested Fixes|h:The base revision|h:A new module|h:Renamed files|h:Not evaluated|h:Where Check F yields|h:Decisions|h:Worked Cases" ;;
  esac
}

CHECKS="a-compatibility b-coverage c-structure d-examples e-profile f-scope"
copy "$J/workflow.md" "" "-" ""
echo
copy "$S/SKILL.md" "../../" "Skill" \
  "h:When to Use This Skill|h:Responsibility Boundaries|h:Output|h:Reference Files|h:Check A: Backwards Compatibility|h:Check B: Coverage Gaps Against the Provider Schema|h:Check C: Module Structure|h:Check D: Examples|h:Check E: Profile Conventions|h:Check F: Scope|l:^8[.] If .mtf-facts. is installed|l:^Classify the changed paths, order the areas|l:^Each check.s full [*][*]Reads|l:^The .rule_id. values named in the checks above"
for c in $CHECKS; do
  echo
  # Pointer lines to the engine files and the rule id lists say nothing a judgment run needs.
  copy "$R/check-$c.md" "../" "Check $(printf '%s' "${c%%-*}" | tr a-f A-F)" "l:moved to .*engine/|l:^.rule_id. prefix|$(drops_of "$c")"
done
echo
echo "## Candidate Criteria"
echo
echo "The Confirm when part of each \`candidate\` rule's section in \`references/engine/\`, in file order. The rest of a section is injected only when its rule is \`not_evaluated\`."
for c in $CHECKS; do
  echo
  copy "$R/engine/check-$c.md" "../engine/" "" "k:Confirm when: "
done
echo
copy "$R/findings-schema.md" "../" "Findings Schema" \
  "h:Suggested Fix Contract|h:\`rule_id\` Format|h:Recorded Exceptions|h:Ordering|h:Incremental Task Lines|h:Shape|h:Optional Fields"
