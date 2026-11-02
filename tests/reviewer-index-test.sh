#!/bin/bash
# The reviewer's run summaries and its section helper. For each of Checks A to G:
# - references/run/check-<x>.md has one row for every rule_id the check owns, each with a
#   non-empty Applies when, the Provider facts and Page entry when of rule-facts.md, and at
#   least one section link; no row for a rule_id the check does not own. A check owns the
#   rule_ids of its prefix, Check G claim.*, compat.expression-behaviour-changed and
#   review.verification-incomplete, that its check file or engine file names or rule-facts.md
#   lists;
# - every link of a summary resolves to a file of the skill and, with an anchor, to a heading;
# - the sections a row links, as section.sh prints them, name its rule_id;
# - every level-2 section of the check file and the engine file is linked from the summary;
# - SKILL.md links every summary, and each summary's Read First links its check file's first
#   section;
# - every check file and engine file holds, headings aside, the same multiset of sentences as
#   at the merge base with master, so spec text is moved, never rewritten. Without a master
#   ref the comparison is skipped with a note.
# references/section.sh prints, for every heading of every markdown file of the skill,
# exactly the lines from the heading to the next heading of the same or a higher level, and
# refuses a path outside the skill, a symbolic link, a file that is not markdown, a value that
# is not an anchor and a slug two headings share. A negative self-check mutates temp copies
# of the skill and requires each mutation to be reported under the invariant it breaks.
# Run: tests/reviewer-index-test.sh
set -uo pipefail
export LC_ALL=C

SRC="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SRC" || exit 1
RSK=.agents/skills/terraform-module-reviewer
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
fail() { echo "FAIL $1: $2 $3"; fails=$((fails + 1)); }

CHECKS="a:check-a-compatibility b:check-b-coverage c:check-c-structure d:check-d-examples e:check-e-profile f:check-f-scope g:check-g-behaviour"
ID_RE='`(compat|coverage|structure|examples|profile|scope|review|claim)\.[a-z0-9-]+`'

# heads DIR: one line per heading of every markdown file under DIR: file (relative to DIR),
# line, level, slug. Fenced code and front matter hold no heading. With IDS=1 in the
# environment it prints instead, for each section, every rule_id written in it: file, slug, id.
heads() {
  (cd "$1" && find . -name '*.md' -type f | sed 's|^\./||' | sort | tr '\n' '\0' | xargs -0 awk -v ids="${IDS:-0}" '
    FNR == 1 { fm = ($0 == "---"); fence = 0; top = 0; if (fm) next }
    fm { if ($0 == "---") fm = 0; next }
    {
      s = $0; sub(/^ ? ? ?/, "", s)
      if (s ~ /^(```|~~~)/) {
        c = substr(s, 1, 1); n = 0
        while (substr(s, n + 1, 1) == c) n++
        if (!fence) { fence = n; fc = c } else if (c == fc && n >= fence && substr(s, n + 1) ~ /^ *$/) fence = 0
      } else if (!fence && $0 ~ /^#+[ \t]/) {
        t = $0; lvl = 0; while (substr(t, lvl + 1, 1) == "#") lvl++
        sub(/^#+[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
        gsub(/`/, "", t); t = tolower(t); gsub(/[^a-z0-9_ -]/, "", t); gsub(/ /, "-", t)
        if (!ids) print FILENAME "\t" FNR "\t" lvl "\t" t
        while (top > 0 && sl[top] >= lvl) top--
        top++; sl[top] = lvl; ss[top] = t
      }
      if (!ids) next
      r = $0
      while (match(r, /`(compat|coverage|structure|examples|profile|scope|review|claim)\.[a-z0-9-]+`/)) {
        id = substr(r, RSTART + 1, RLENGTH - 2); r = substr(r, RSTART + RLENGTH)
        for (i = 1; i <= top; i++) print FILENAME "\t" ss[i] "\t" id
      }
    }' | if [ "${IDS:-0}" = 1 ]; then sort -u; else cat; fi)
}

# sentences FILE: the file's sentences, one per line, sorted: headings left out, every other
# line outside fenced code trimmed and split after a full stop, question or exclamation mark.
sentences() {
  awk '
    { s = $0; sub(/^ ? ? ?/, "", s) }
    s ~ /^(```|~~~)/ { fence = !fence; print; next }
    fence { print; next }
    /^#+[ \t]/ { next }
    { t = $0; gsub(/[ \t]+/, " ", t); sub(/^ /, "", t); sub(/ $/, "", t)
      while (match(t, /[.!?] /)) { print substr(t, 1, RSTART); t = substr(t, RSTART + 2) }
      if (t != "") print t }' "$1" | sort
}

# The base sentences, once: from the merge base with master, or none.
BASE="$(git merge-base HEAD master 2> /dev/null || git merge-base HEAD origin/master 2> /dev/null || true)"
mkdir "$TMP/base"
if [ -n "$BASE" ]; then
  for pair in $CHECKS; do
    for f in "references/${pair#*:}.md" "references/engine/${pair#*:}.md"; do
      git show "$BASE:$RSK/$f" > "$TMP/base/f" 2> /dev/null || continue
      mkdir -p "$TMP/base/$(dirname "$f")"; sentences "$TMP/base/f" > "$TMP/base/$f"
    done
  done
fi

# index_check DIR: one line per problem with the summaries of the skill at DIR:
# invariant, where, detail.
index_check() {
  local d="$1" x spec sum rf="$1/references/rule-facts.md"
  heads "$d" > "$TMP/ix-heads"
  IDS=1 heads "$d" > "$TMP/ix-named"
  (cd "$d" && find . -type f | sed 's|^\./||') > "$TMP/ix-files"
  awk -F'|' '
    /^\| `rule_id` \|/ { for (i = 2; i < NF; i++) { h = $i; gsub(/^ +| +$/, "", h); col[h] = i }; next }
    /^\| `[a-z]+\.[a-z0-9-]+` \|/ {
      id = $2; gsub(/[ `]/, "", id); f = $(col["Provider facts"]); p = $(col["Page entry when"])
      gsub(/^ +| +$/, "", f); gsub(/^ +| +$/, "", p)
      print id "\t" f (p == "-" ? "" : "; page entry when: " p)
    }' "$rf" > "$TMP/ix-facts"
  for pair in $CHECKS; do
    x="${pair%%:*}"; spec="${pair#*:}"; sum="references/run/check-$x.md"
    if [ ! -f "$d/$sum" ]; then printf 'summary\t%s\tmissing\n' "$sum"; continue; fi
    grep -F -q "](references/run/check-$x.md)" "$d/SKILL.md" ||
      printf 'skill links\tSKILL.md\tno link to %s\n' "$sum"
    # The rule_ids the check owns.
    { cat "$d/references/$spec.md" "$d/references/engine/$spec.md" 2> /dev/null | grep -oE "$ID_RE" | tr -d '`'
      cut -f1 "$TMP/ix-facts"; } | sort -u |
      awk -v x="$x" '
        function owner(id) {
          if (id ~ /^claim\./ || id == "compat.expression-behaviour-changed" || id == "review.verification-incomplete") return "g"
          if (id ~ /^compat\./) return "a"; if (id ~ /^coverage\./) return "b"; if (id ~ /^structure\./) return "c"
          if (id ~ /^examples\./) return "d"; if (id ~ /^profile\./) return "e"; if (id ~ /^scope\./) return "f"
          return ""
        }
        owner($0) == x' > "$TMP/ix-owned"
    # The rows: id, condition, facts, sections.
    awk -F'|' '/^\| `[a-z]+\.[a-z0-9-]+` \|/ {
        for (i = 2; i <= 5; i++) gsub(/^ +| +$/, "", $i); id = $2; gsub(/`/, "", id)
        print id "\t" $3 "\t" $4 "\t" $5 "\t" FNR }' "$d/$sum" > "$TMP/ix-rows"
    awk -F'\t' -v sum="$sum" '
      FILENAME == ARGV[1] { own[$1] = 1; next }
      FILENAME == ARGV[2] { facts[$1] = $2; next }
      {
        n[$1]++; where = sum ":" $5
        if (!($1 in own)) print "extra row\t" where "\t" $1 " is not a rule_id this check owns"
        if ($2 == "") print "condition\t" where "\t" $1 " has an empty Applies when"
        if ($3 != facts[$1]) print "facts\t" where "\t" $1 " says \"" $3 "\", rule-facts.md says \"" facts[$1] "\""
        if ($4 !~ /\]\([^)]+\)/) print "sections\t" where "\t" $1 " links no section"
      }
      END { for (id in own) if (n[id] != 1) print "missing row\t" sum "\t" id " has " n[id] + 0 " rows, not one" }
    ' "$TMP/ix-owned" "$TMP/ix-facts" "$TMP/ix-rows"
    # Read First links the check file's first section.
    first="$(awk -F'\t' -v f="references/$spec.md" '$1 == f && $3 == 2 { print $4; exit }' "$TMP/ix-heads")"
    awk '/^## /{ on = ($0 == "## Read First") } on' "$d/$sum" | grep -F -q "](../$spec.md#$first)" ||
      printf 'read first\t%s\tRead First does not link %s#%s\n' "$sum" "$spec.md" "$first"
    # Headings aside, the spec text is the base's, sentence for sentence.
    if [ -n "$BASE" ]; then
      for f in "references/$spec.md" "references/engine/$spec.md"; do
        [ -f "$d/$f" ] || [ -f "$TMP/base/$f" ] || continue
        if [ ! -f "$TMP/base/$f" ]; then printf 'sentences\t%s\tnot at the merge base with master\n' "$f"; continue; fi
        if [ ! -f "$d/$f" ]; then printf 'sentences\t%s\tmissing, while the merge base has it\n' "$f"; continue; fi
        sentences "$d/$f" | diff "$TMP/base/$f" - > /dev/null ||
          printf 'sentences\t%s\tits sentences differ from the merge base with master\n' "$f"
      done
    fi
    # Every link resolves; the sections a row links name its rule_id; every level-2 section of
    # the check file and the engine file is linked. Link paths are relative to references/run.
    awk -F'\t' -v sum="$sum" -v spec="$spec" '
      function norm(p,   n, part, i, k, out, r) {
        n = split("references/run/" p, part, "/"); k = 0
        for (i = 1; i <= n; i++) {
          if (part[i] == "" || part[i] == ".") continue
          if (part[i] == "..") { if (k == 0) return ""; k--; continue }
          out[++k] = part[i]
        }
        r = out[1]; for (i = 2; i <= k; i++) r = r "/" out[i]
        return r
      }
      FILENAME == ARGV[1] { file[$1] = 1; next }
      FILENAME == ARGV[2] { slug[$1, $4] = 1; if ($3 == 2 && ($1 == "references/" spec ".md" || $1 == "references/engine/" spec ".md")) h2[$1 "#" $4] = 1; next }
      FILENAME == ARGV[3] { named[$1, $2, $3] = 1; next }
      {
        t = $0; gsub(/`[^`]*`/, " ", t); id = ""
        if ($0 ~ /^\| `[a-z]+\.[a-z0-9-]+` \|/) { id = $0; sub(/^\| `/, "", id); sub(/`.*/, "", id); hit = 0; nl = 0 }
        while (match(t, /\]\([^)]*\)/)) {
          l = substr(t, RSTART + 2, RLENGTH - 3); t = substr(t, RSTART + RLENGTH)
          if (l ~ /^[a-z]+:/) continue
          p = l; a = ""; if (index(l, "#")) { p = substr(l, 1, index(l, "#") - 1); a = substr(l, index(l, "#") + 1) }
          f = norm(p)
          if (f == "" || !(f in file)) { print "link\t" sum ":" FNR "\t" l ": no such file in the skill"; continue }
          if (a != "" && !((f, a) in slug)) { print "link\t" sum ":" FNR "\t" l ": no heading has that slug"; continue }
          linked[f "#" a] = 1
          if (id != "" && a != "") { nl++; if ((f, a, id) in named) hit = 1 }
        }
        if (id != "" && nl > 0 && !hit) print "not in section\t" sum ":" FNR "\t" id " is not named in the sections it links"
      }
      END { for (k in h2) if (!(k in linked)) print "unlinked section\t" sum "\t" k " is linked from no row or section line" }
    ' "$TMP/ix-files" "$TMP/ix-heads" "$TMP/ix-named" "$d/$sum"
  done
}

# section_check DIR [FILE...]: section.sh against an independent cut for every heading of
# the skill's markdown files, or of the FILEs given. judgment/prefix.md is generated from the
# other files and left out.
section_check() {
  local d="$1" i=0 f s
  shift
  heads "$d" | awk -F'\t' -v only="$*" '
    BEGIN { n = split(only, o, " "); for (i = 1; i <= n; i++) keep[o[i]] = 1 }
    $1 != "references/judgment/prefix.md" && (n == 0 || ($1 in keep))' > "$TMP/sc-heads"
  rm -rf "$TMP/sc"; mkdir "$TMP/sc"
  # One cut per heading: the lines from it to the next heading of its level or higher. A slug
  # two headings of one file share is left to refusal_check.
  awk -F'\t' -v d="$d" -v out="$TMP/sc" '
    FILENAME == ARGV[1] { f[NR] = $1; l[NR] = $2; v[NR] = $3; s[NR] = $4; c[$1, $4]++; n = NR; next }
    FNR == 1 { file = substr(FILENAME, length(d) + 2); k = 0 }
    { line[file, FNR] = $0; len[file] = FNR }
    END {
      for (i = 1; i <= n; i++) {
        if (c[f[i], s[i]] > 1) continue
        e = len[f[i]]
        for (j = i + 1; j <= n && f[j] == f[i]; j++) if (v[j] <= v[i]) { e = l[j] - 1; break }
        w = out "/" ++m ".want"; print f[i] "\t" s[i] > (out "/list")
        for (k = l[i]; k <= e; k++) print line[f[i], k] > w
        close(w)
      }
    }' "$TMP/sc-heads" $(cut -f1 "$TMP/sc-heads" | sort -u | sed "s|^|$d/|")
  [ -f "$TMP/sc/list" ] || return 0
  while IFS=$'\t' read -r f s; do
    i=$((i + 1))
    bash "$d/references/section.sh" "$f" "$s" > "$TMP/sc/$i.got" 2> /dev/null
    cmp -s "$TMP/sc/$i.want" "$TMP/sc/$i.got" || printf 'section.sh\t%s#%s\tprints other lines than the section\n' "$f" "$s"
  done < "$TMP/sc/list"
}

# refusal_check DIR: section.sh's refusals and fixtures, on a temp copy of the skill at DIR.
refusal_check() {
  local c="$TMP/rc" h out rc
  rm -rf "$c" "$TMP/out"; cp -R "$1" "$c"; mkdir "$TMP/out"
  h="$c/references/section.sh"
  printf '# Outside\n\ntext\n' > "$TMP/out/x.md"
  ln -s "$TMP/out/x.md" "$c/references/link.md"
  ln -s "$TMP/out" "$c/references/linkdir"
  printf '# Fixture\n\n## Same\n\na\n\n## Same\n\nb\n' > "$c/references/dup.md"
  printf -- '---\n# not: a heading\n---\n# Top\n\n## One\n\n```\n# fenced\n```\n\n### Deeper\n\nx\n\n## Two\n\ny\n' > "$c/references/fixture.md"
  expect() { # want-status, description, args...
    local want="$1" what="$2"; shift 2
    out="$(cd "$TMP/out" && bash "$h" "$@" 2> /dev/null)"; rc=$?
    [ "$rc" = "$want" ] || printf 'refusal\t%s\texits %s, not %s\n' "$what" "$rc" "$want"
    [ "$want" = 0 ] || [ -z "$out" ] || printf 'refusal\t%s\tprinted output\n' "$what"
  }
  expect 2 "an absolute path outside the skill" "$TMP/out/x.md" outside
  expect 2 "a relative path that climbs out" "references/../../../../../../../../$TMP/out/x.md" outside
  expect 2 "a symbolic link to a file outside" references/link.md outside
  expect 2 "a file under a linked directory" references/linkdir/x.md outside
  expect 2 "a file that is not markdown" references/section.sh x
  expect 2 "an anchor with a command substitution" references/fixture.md '$(touch pwned)'
  expect 2 "an anchor with a space" references/fixture.md 'one two'
  expect 2 "one argument" references/fixture.md
  expect 1 "a slug two headings share" references/dup.md same
  expect 1 "an anchor no heading has" references/fixture.md three
  expect 1 "a heading inside front matter" references/fixture.md not-a-heading
  expect 1 "a heading inside fenced code" references/fixture.md fenced
  [ ! -e "$TMP/out/pwned" ] || printf 'refusal\tan anchor with a command substitution\tran it\n'
  out="$(bash "$h" references/fixture.md '#one')"
  [ "$out" = "$(printf '## One\n\n```\n# fenced\n```\n\n### Deeper\n\nx\n')" ] ||
    printf 'section.sh fixture\treferences/fixture.md#one\tprints the wrong lines\n'
  out="$(bash "$h" "$c/references/fixture.md" two)"
  [ "$out" = "$(printf '## Two\n\ny')" ] || printf 'section.sh fixture\treferences/fixture.md#two\tprints the wrong lines\n'
}

report() { # label: lines on stdin, each reported as a failure
  local n=0
  while IFS=$'\t' read -r inv where detail; do fail "$1" "$where" "$inv: $detail"; n=$((n + 1)); done
  return "$n"
}

[ -n "$BASE" ] || echo "note sentence multiset skipped: no master or origin/master ref"
report "run summaries" < <(index_check "$RSK") && echo "ok   run summaries ($(cat "$RSK"/references/run/check-*.md | grep -cE '^\| `[a-z]+\.') rows)"
report "section helper" < <(section_check "$RSK") && echo "ok   section helper ($(wc -l < "$TMP/sc/list" | tr -d ' ') sections)"
report "section refusals" < <(refusal_check "$RSK") && echo "ok   section refusals"

# Negative self-check: each sed script changes one file of a temp copy of the skill, and the
# result must be reported under the invariant it breaks.
nmut=0
while IFS='~' read -r name inv target script; do
  nmut=$((nmut + 1))
  rm -rf "$TMP/mut"; cp -R "$RSK" "$TMP/mut"
  sed "$script" "$TMP/mut/$target" > "$TMP/mut-sed" && cat "$TMP/mut-sed" > "$TMP/mut/$target"
  if cmp -s "$TMP/mut/$target" "$RSK/$target"; then fail "self-check" "$target" "$name (the mutation changed nothing)"; continue; fi
  case "$target" in
    references/section.sh)
      { section_check "$TMP/mut" references/check-f-scope.md references/verification-ladder.md
        refusal_check "$TMP/mut"; } > "$TMP/mut-out" ;;
    *) index_check "$TMP/mut" > "$TMP/mut-out" ;;
  esac
  cut -f1 "$TMP/mut-out" | grep -F -x -q "$inv" || fail "self-check" "$target" "$name is not reported as $inv"
done <<'EOF'
a row deleted~missing row~references/run/check-c.md~/^| `structure.grouping` /d
a row duplicated~missing row~references/run/check-g.md~/^| `claim.refuted` /p
an empty condition~condition~references/run/check-e.md~s/^\(| `profile.changelog-handwritten` |\)[^|]*|/\1 |/
a broken anchor~link~references/run/check-a.md~s/#compatvariable-removed)/#compatvariable-gone)/
a link to a missing file~link~references/run/check-b.md~s/(\.\.\/check-b-coverage\.md#reads)/(..\/check-b-coverag.md#reads)/
facts that differ from rule-facts.md~facts~references/run/check-b.md~/^| `coverage.unknown-argument` /s/| schema; page entry when:/| page; page entry when:/
a row for a rule another check owns~extra row~references/run/check-d.md~s/^| `examples.real-domain-zone` /| `profile.real-domain-zone` /
a row with no section link~sections~references/run/check-f.md~/^| `scope.tests` /s/| \[Check F\]([^)]*) |$/| none |/
a row linking a section that does not name it~not in section~references/run/check-a.md~/^| `compat.type-narrowed` /s/#compattype-narrowed/#compatvariable-removed/
an other section unlinked~unlinked section~references/run/check-f.md~/^| \[Decisions\]/d
a rule named in a check file with no row~missing row~references/check-g-behaviour.md~s/^`rule_id` prefixes: /`claim.new-rule`; &/
a summary SKILL.md does not link~skill links~SKILL.md~s/(references\/run\/check-e\.md)/(references\/run\/check-e.md#rules)/
a sentence of the spec rewritten~sentences~references/check-g-behaviour.md~s/^- `claim.refuted`: a `claim` line has state `refuted`/- `claim.refuted`: a `claim` line says `refuted`/
a sentence of an engine file rewritten~sentences~references/engine/check-d-examples.md~s/^- A submodule added by the change has no example of its own\./- A submodule added by the change has no example./
Read First dropped~read first~references/run/check-a.md~/^When any row below applies: /d
section.sh past the next heading~section.sh~references/section.sh~s/if (on \&\& lvl <= on) on = 0/if (on \&\& lvl < on) on = 0/
section.sh stopping at a deeper heading~section.sh~references/section.sh~s/if (on \&\& lvl <= on) on = 0/if (on) on = 0/
section.sh reading fenced headings~section.sh fixture~references/section.sh~s/} else if (fence == 0 \&\& /} if (/
section.sh without the skill boundary~refusal~references/section.sh~/outside the skill/d
section.sh following a symbolic link~refusal~references/section.sh~s/ \&\& \[ ! -L "\$r\/\$b" \]//
section.sh taking any anchor~refusal~references/section.sh~/not an anchor/d
section.sh taking any file~refusal~references/section.sh~/not a markdown file/d
section.sh printing the first of two headings~refusal~references/section.sh~/headings have the slug/d
EOF

echo
if [ "$fails" -eq 0 ]; then echo "all passed ($nmut mutations caught)"; else echo "$fails failed"; exit 1; fi
