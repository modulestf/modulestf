#!/bin/bash
# The reviewer's run summaries and its section helper. For each of Checks A to H:
# - references/run/check-<x>.md has one row for every rule_id the check owns, each with a
#   non-empty Applies when, the Provider facts and Page entry when of rule-facts.md, and at
#   least one section link; no row for a rule_id the check does not own. A check owns the
#   rule_ids of its prefix, Check G claim.*, compat.expression-behaviour-changed and
#   review.verification-incomplete, that its check file or engine file names or rule-facts.md
#   lists;
# - every link of a summary resolves to a file of the skill and, with an anchor, to a heading;
# - the sections a row links, as section.sh prints them, name its rule_id;
# - every level-2 section of the check file and the engine file is linked from the summary;
# - references/workflow.md links every summary, and each summary's Read First links its check
#   file's first section;
# - SKILL.md's Reading by Depth makes a row hold when the mtf-facts report gives its rule a
#   finding or candidate, and facts-engine.md pairs `row not applied` only with clean or
#   not_applicable;
# - the Budget's host fact sheets and run/facts.md's Fact Sheets name the deduplicated sheet
#   (`same_as`, the `versions:` line) and the deep run's `missing.json`, and the index links the
#   Budget;
# - headings aside, SKILL.md with the references its text moved to (inputs.md, output.md,
#   workflow.md), and each check file and engine file, hold the multiset of sentences of the
#   base commit tests/reviewer-index-sentences.txt names, changed only by the "+" and "-"
#   lines it lists, so spec text is moved, never rewritten. When that commit is not an
#   ancestor of HEAD, the comparison is skipped with a note.
# references/section.sh prints, for every heading of every markdown file of the skill,
# exactly the lines from the heading to the next heading of the same or a higher level; it
# prints the section of every relative link with an anchor from a run summary, check file or
# engine file to a markdown file, in this skill or a sibling skill; and it refuses a path
# outside the skills directory, a symbolic link, a file that is not markdown, a value that
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

CHECKS="a:check-a-compatibility b:check-b-coverage c:check-c-structure d:check-d-examples e:check-e-profile f:check-f-scope g:check-g-behaviour h:check-h-non-hcl"
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

# sentences FILE...: the files' sentences, one per line, sorted: headings left out, link
# targets emptied, so a moved sentence may point its links anew, and every other line outside
# fenced code trimmed and split after a full stop, question or exclamation mark.
sentences() {
  cat "$@" | awk '
    { s = $0; sub(/^ ? ? ?/, "", s) }
    s ~ /^(```|~~~)/ { fence = !fence; print; next }
    fence { print; next }
    /^#+[ \t]/ { next }
    { t = $0; gsub(/[ \t]+/, " ", t); sub(/^ /, "", t); sub(/ $/, "", t); gsub(/\]\([^)]*\)/, "]()", t)
      while (match(t, /[.!?] /)) { print substr(t, 1, RSTART); t = substr(t, RSTART + 2) }
      if (t != "") print t }' | sort
}

# The spec groups: a name, then the files whose sentences it holds. SKILL.md's text lives in
# SKILL.md and the references it moved to; each check and engine file is its own group.
groups() {
  echo "SKILL.md SKILL.md references/inputs.md references/output.md references/workflow.md"
  for pair in $CHECKS; do
    for f in "references/${pair#*:}.md" "references/engine/${pair#*:}.md"; do echo "$f $f"; done
  done
}

# The base sentences of each group, once, from the commit the first line of
# tests/reviewer-index-sentences.txt names, with the changes the record lists since then
# applied: each "+" line adds one sentence, each "-" line removes one. The commit must be an
# ancestor of HEAD; when it is missing, as in a shallow clone, the comparison is skipped.
REC="$SRC/tests/reviewer-index-sentences.txt"
BASE="$(awk -F'\t' 'NR == 1 && $1 == "base" { print $2 }' "$REC")"
{ [ -n "$BASE" ] && git cat-file -e "$BASE^{commit}" 2> /dev/null && git merge-base --is-ancestor "$BASE" HEAD; } || BASE=""
mkdir "$TMP/base"
if [ -n "$BASE" ]; then
  groups | while read -r g members; do
    k="$(printf '%s' "$g" | tr '/' '_')"; : > "$TMP/base/$k.raw"; got=0
    for f in $members; do
      git show "$BASE:$RSK/$f" >> "$TMP/base/$k.raw" 2> /dev/null && got=1 && echo >> "$TMP/base/$k.raw"
    done
    # A file the base lacks starts empty only when the record lists its sentences.
    [ "$got" = 1 ] || awk -F'\t' -v g="$g" '$2 == g { f = 1 } END { exit !f }' "$REC" || continue
    sentences "$TMP/base/$k.raw" |
      awk -F'\t' -v g="$g" '
        FILENAME == ARGV[1] { if ($2 == g) { op[++n] = $1; t[n] = $3 }; next }
        { c[$0]++ }
        END {
          for (i = 1; i <= n; i++) c[t[i]] += (op[i] == "+") ? 1 : -1
          for (x in c) for (j = 0; j < c[x]; j++) print x
        }' "$REC" - | sort > "$TMP/base/$k"
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
  bash "$d/references/section.sh" SKILL.md reading-by-depth 2> /dev/null |
    grep -F -q 'gives a finding or candidate for, in any area, holds whatever its condition says' ||
    printf 'facts rows\tSKILL.md#reading-by-depth\ta facts-engine finding or candidate does not make its row hold\n'
  bash "$d/references/section.sh" references/facts-engine.md facts-comparison 2> /dev/null |
    grep -F -q '`row not applied` pairs only with a tool `clean` or `not_applicable`' ||
    printf 'facts rows\treferences/facts-engine.md#facts-comparison\t`row not applied` is not limited to clean and not_applicable\n'
  bash "$d/references/section.sh" references/large-changes.md budget 2> /dev/null > "$TMP/ix-budget"
  bash "$d/references/section.sh" references/run/facts.md fact-sheets 2> /dev/null > "$TMP/ix-sheets"
  for w in '`same_as`' '`versions: <list>`' '`missing.json`'; do
    grep -F -q "$w" "$TMP/ix-budget" || printf 'fact sheets\treferences/large-changes.md#budget\tthe host fact sheets do not name %s\n' "$w"
  done
  for w in '`same_as`' '`versions:`' '`missing.json`' '](../large-changes.md#budget)'; do
    grep -F -q "$w" "$TMP/ix-sheets" || printf 'fact sheets\treferences/run/facts.md#fact-sheets\tdoes not hold %s\n' "$w"
  done
  for pair in $CHECKS; do
    x="${pair%%:*}"; spec="${pair#*:}"; sum="references/run/check-$x.md"
    if [ ! -f "$d/$sum" ]; then printf 'summary\t%s\tmissing\n' "$sum"; continue; fi
    grep -F -q "](run/check-$x.md)" "$d/references/workflow.md" ||
      printf 'skill links\treferences/workflow.md\tno link to %s\n' "$sum"
    # The rule_ids the check owns.
    { cat "$d/references/$spec.md" "$d/references/engine/$spec.md" 2> /dev/null | grep -oE "$ID_RE" | tr -d '`'
      cut -f1 "$TMP/ix-facts"; } | sort -u |
      awk -v x="$x" '
        function owner(id) {
          if (id ~ /^claim\./ || id == "compat.expression-behaviour-changed" || id == "review.verification-incomplete") return "g"
          if (id ~ /^structure\.non-hcl-/) return "h"
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
    : # The spec groups are compared once per run, after the checks.
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
  # Headings aside, each spec group holds the base's sentences, with the recorded changes.
  if [ -n "$BASE" ]; then
    groups | while read -r g members; do
      k="$(printf '%s' "$g" | tr '/' '_')"
      if [ ! -f "$TMP/base/$k" ]; then
        (cd "$d" && ls $members > /dev/null 2>&1) && printf 'sentences\t%s\tnot at the recorded base\n' "$g"
        continue
      fi
      (cd "$d" && sentences $members 2> /dev/null) | diff "$TMP/base/$k" - > "$TMP/ix-sdiff" ||
        printf 'sentences\t%s\t%s sentences differ from the recorded base and the record\n' "$g" "$(grep -c '^[<>]' "$TMP/ix-sdiff")"
    done
  fi
  # The guards of the bands calibrated against merged changes: each phrase stays in its file, so
  # a lowered band never drops the cases that must keep their severity.
  while IFS='|' read -r gf gp; do
    grep -qF -- "$gp" "$d/$gf" || printf 'calibration guard\t%s\tmissing: %s\n' "$gf" "$gp"
  done <<'GUARDS'
references/engine/check-a-compatibility.md|After that sentence, LOW when the argument's own entry
references/engine/check-a-compatibility.md|a page silent on replacement is the `review.check-not-run` of the Provider facts line
references/engine/check-a-compatibility.md|never when a loss of data or access is known
references/engine/check-a-compatibility.md|never for a value that blocks or restricts what callers could do before
references/engine/check-a-compatibility.md|never for a value the service applies to new resources only or announces
references/engine/check-a-compatibility.md|never for a security or data protection control (encryption, KMS, IAM, public access, deletion protection, backup, retention, versioning, logging, instance metadata options, `force_destroy`, `skip_final_snapshot`, `apply_immediately`) or a value that widens access
references/engine/check-a-compatibility.md|Never for a default that turns off or weakens a security or data protection control
references/engine/check-a-compatibility.md|the title is never the cite for its effect
references/judgment/prefix.md|after CRITICAL and HIGH, never for a security or data protection control, widened access or a value that restricts callers
references/judgment/prefix.md|never for a security or data protection control, instance metadata options included, widened access, a value that restricts callers, or one the service applies to new resources only or announces
references/judgment/prefix.md|Each LOW needs the page to show the change in place; with no source to tell, `review.check-not-run` MEDIUM
references/check-c-structure.md|the text says the module cannot do what one of its inputs does
references/check-c-structure.md|Text that overstates safety or access limits stays MEDIUM
references/check-c-structure.md|Silence is never MEDIUM or HIGH.
references/check-c-structure.md|an empty list, null or an omitted argument is not a value outside the list
references/check-c-structure.md|unless the losing side is an access, security or data protection control
references/check-e-profile.md|never from text in the change
references/large-changes.md|A type of a called module the review cannot read is a `review.check-not-run`
references/large-changes.md|a module call no such rule reaches is not listed and is no unknown
references/engine/check-a-compatibility.md|HIGH wins and this LOW does not apply
references/engine/check-a-compatibility.md|widens access, or blocks or restricts what callers could do before: those keep the bands above
references/check-g-behaviour.md|The page must be read in this review; with no page read for the type, the band does not hold.
references/check-g-behaviour.md|none may be an argument the type's page marks as forcing a new resource
references/check-g-behaviour.md|a credential, a security or data protection control (a policy, a principal, a password, a token, a key or encryption setting, public access, deletion protection, backup, retention, versioning or logging), or one that sets a count, a size, failover, network placement or an identity
references/check-g-behaviour.md|so a create still applies the caller's value
references/check-g-behaviour.md|A new list, `all`, or any other added name takes the other bands as written.
references/check-g-behaviour.md|the change edits nothing else in the block
references/check-g-behaviour.md|list that exists at the base, in a block with the same address, `count` and `for_each` at both revisions
references/check-g-behaviour.md|Each added name shares its stem with a name the list already ignores at the base
references/check-g-behaviour.md|A payload the resource deploys never takes this band
references/check-g-behaviour.md|none of the ignored-input, documented-intent and ignore-list bands below holds
references/check-g-behaviour.md|except the ignore-list band below, which reads the type's page
references/check-g-behaviour.md|Neither is a changed file with no `trigger` line when the `behaviour:` line counts one or more changes over the cap
references/check-g-behaviour.md|For the maintainers, not the author
references/check-b-coverage.md|takes the caller's value unchanged, with no default but null and no fallback
references/check-b-coverage.md|and none grants or restricts access or is a security control
references/check-b-coverage.md|or one argument required or not allowed when another is set or unset
references/check-b-coverage.md|A conflicting pair in any wording, exactly one of and at least one of included, stays HIGH
references/check-b-coverage.md|and so does a conditional rule where the module supplies a side
references/check-b-coverage.md|The summary names the rule as the page states it and that the provider or the service rejects such a call.
references/check-c-structure.md|an argument of a block planned on every path where the module tests it
references/check-c-structure.md|a page this review read shows the provider checks that argument at plan
references/check-c-structure.md|that holds every value the module tests
references/check-c-structure.md|Examples, common values, a list in prose outside the entry or a check the page places at apply do not count.
references/check-c-structure.md|With no page read for the type, or for a commented-out block, it stays MEDIUM.
references/check-c-structure.md|a commented-out block stays MEDIUM
references/check-d-examples.md|when the change adds the example
references/check-d-examples.md|counts as one the base had and stays HIGH
references/engine/check-e-profile.md|when the literal is in a file under `examples/` that is not a `terraform test` file (`*.tftest.hcl`), in an example no `*.tftest.hcl` file uses as a module source
references/engine/check-e-profile.md|The root module, submodules, `tests/` and every `*.tftest.hcl` file keep HIGH
references/judgment/prefix.md|a conflicting pair in any wording stays HIGH
references/judgment/prefix.md|LOW for `structure.validation-missing` only as
references/judgment/prefix.md|counts as one the base had and stays HIGH
references/judgment/prefix.md|LOW under `examples/` outside a `*.tftest.hcl` file, in an example no such file sources, HIGH elsewhere.
references/check-g-behaviour.md|one is the other followed by `_` and more
references/check-g-behaviour.md|a task or container definition, an image, user data, a secret or parameter value, a policy or a configuration document
references/check-g-behaviour.md|No version attribute (`version`, or a name ending `_version`), `name` or `name_prefix` takes this band, whatever stem it shares.
references/judgment/prefix.md|LOW for a conditional rule only as
references/check-c-structure.md|The page or sheet states the block single, at most one per resource.
references/check-c-structure.md|not only the arguments the input chose to expose
references/check-c-structure.md|The change renames no key the base had and drops no field the base fed, and every field of the input reaches an argument.
references/check-c-structure.md|No flattened argument is itself a control that grants or restricts access or protects data
references/check-c-structure.md|An ARN argument is such a control, and keeps HIGH, unless the page or sheet shows it only names where data the resource emits goes
references/check-c-structure.md|that data is neither audit or access logs nor failure or dead-letter handling
references/check-c-structure.md|the ARN does not protect it as a key, role, policy, certificate, secret or access point does
references/check-c-structure.md|When the page does not settle it, HIGH.
references/check-c-structure.md|A page or sheet that does not state the block single, no page read for the type, or any other condition failing keeps HIGH.
references/check-c-structure.md|it is evidence, never a condition, and change or task text never names one
references/check-c-structure.md|LOW for a flattened provider block only as
references/check-a-compatibility.md|A submodule directory that itself uses nothing absent at the old floor and whose new floor equals the new floor the root `versions.tf` declares for that provider, both moved in the change
references/check-a-compatibility.md|When the root takes case (1), its fix and the directory's are the same decision
references/check-a-compatibility.md|so it is never restored alone
references/check-a-compatibility.md|the root's fix restores the root and each such submodule together
references/engine/check-a-compatibility.md|the root's own two options when the root's fix is a decision
references/engine/check-a-compatibility.md|It is never restored alone.
references/judgment/prefix.md|`structure.validation-missing` or a flattening:
references/check-c-structure.md|a nested block left out of the input that is an access or data protection control keeps HIGH
references/check-c-structure.md|Every argument and nested block the block has at that version
references/check-a-compatibility.md|(b) restore the root and each such submodule together, each named
references/check-c-structure.md|a `before` or `after` token of its name says it is not to wait for the target
references/check-c-structure.md|A target that exists on some paths only still fires for the paths where both exist
references/check-c-structure.md|A sibling's `depends_on` alone is no need.
references/check-c-structure.md|a `concat` of candidates one of which an input feeds
references/check-c-structure.md|and `""` or `null` is no such fallback
references/check-c-structure.md|an index error is no such check
references/check-c-structure.md|when the index is the position in the list the `count` or `for_each` itself enumerates
references/check-c-structure.md|when the module builds the list with a count that bounds the index on every path
references/check-c-structure.md|when the index is a value the caller gives per element
references/check-c-structure.md|for `element()`, whose wrap is the family idiom
references/check-c-structure.md|the direct read is the value the block needs
references/check-c-structure.md|A comment about other blocks keeps LOW:
references/check-c-structure.md|the direct read fails or gives another value, and the local does not
references/check-c-structure.md|without which the resource still does its job, on the target the module intends
references/check-c-structure.md|makes the provider pick a default target
references/check-c-structure.md|on every supported path where the new block exists and the two differ
references/check-c-structure.md|or a page this review read shows the block uses it
references/check-c-structure.md|a fallback the comment states is taken
references/check-c-structure.md|and so is a new gateway there when neither its code nor a page read shows it uses that range
references/check-c-structure.md|whenever the need rests only on the siblings' `depends_on` and a page that names the block; never LOW
references/check-c-structure.md|A page that only recommends it, or shows it in an example, keeps MEDIUM.
references/check-c-structure.md|gated on the branch that reads the caller's list
references/judgment/prefix.md|- A new block beside its siblings, or a new list index:
GUARDS
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

# link_check DIR: every relative link with an anchor from a run summary, check file or engine
# file of the skill at DIR to a markdown file, resolved from the linking file's directory,
# prints through section.sh. DIR's sibling skills are the link targets outside it.
link_check() {
  local d="$1" n=0
  (cd "$d" && for f in references/run/*.md references/check-*.md references/engine/*.md; do
    awk -v f="$f" '{ t = $0; gsub(/`[^`]*`/, " ", t)
      while (match(t, /\]\([^)]*\)/)) { l = substr(t, RSTART + 2, RLENGTH - 3); t = substr(t, RSTART + RLENGTH)
        if (l !~ /^[a-z]+:/ && l ~ /^[^#]+\.md#./) print f "\t" l } }' "$f"
  done) | awk -F'\t' '
    function norm(p,   n, part, i, k, out, r) {   # relative to the skill root, .. kept above it
      n = split(p, part, "/"); k = 0; up = ""
      for (i = 1; i <= n; i++) {
        if (part[i] == "" || part[i] == ".") continue
        if (part[i] == "..") { if (k > 0) k--; else up = up "../"; continue }
        out[++k] = part[i]
      }
      r = up; for (i = 1; i <= k; i++) r = r (i > 1 ? "/" : "") out[i]
      return r
    }
    { dir = $1; sub(/\/[^\/]*$/, "", dir); l = $2; a = substr(l, index(l, "#") + 1)
      print norm(dir "/" substr(l, 1, index(l, "#") - 1)) "\t" a }' | sort -u > "$TMP/lc-targets"
  while IFS=$'\t' read -r f a; do
    n=$((n + 1))
    bash "$d/references/section.sh" "$f" "$a" > /dev/null 2>&1 ||
      printf 'cross link\t%s#%s\tsection.sh does not print it\n' "$f" "$a"
  done < "$TMP/lc-targets"
  echo "$n" > "$TMP/lc-count"
}

# refusal_check DIR: section.sh's refusals and fixtures, on a temp copy of the skill at DIR.
refusal_check() {
  local c="$TMP/rc/skills/reviewer" h out rc
  rm -rf "$TMP/rc" "$TMP/out"; mkdir -p "$TMP/rc/skills"; cp -R "$1" "$c"; mkdir "$TMP/out"
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
  printf '# Sibling\n\n## Part\n\ns\n' > "$TMP/rc/skills/sibling.md"
  expect 2 "an absolute path outside the skills directory" "$TMP/out/x.md" outside
  expect 0 "a file of a sibling skill" ../sibling.md part
  out="$(cd "$TMP/rc/skills" && bash "$h" reviewer/references/fixture.md two 2> /dev/null)" ||
    printf 'refusal\ta path relative to the skills directory\texits non-zero\n'
  [ "$out" = "$(printf '## Two\n\ny\n')" ] || printf 'refusal\ta path relative to the skills directory\tprinted the wrong section\n'
  out="$(cd "$c/references" && bash "$h" fixture.md two 2> /dev/null)" ||
    printf 'refusal\ta bare name from references/\texits non-zero\n'
  out="$(cd "$TMP/out" && bash "$h" x.md outside 2> /dev/null)" &&
    printf 'refusal\ta current-directory path outside the skills directory\texits 0\n'
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

[ -n "$BASE" ] || echo "note sentence multiset skipped: the recorded base commit is not an ancestor here"
report "run summaries" < <(index_check "$RSK") && echo "ok   run summaries ($(cat "$RSK"/references/run/check-*.md | grep -cE '^\| `[a-z]+\.') rows)"
report "section helper" < <(section_check "$RSK") && echo "ok   section helper ($(wc -l < "$TMP/sc/list" | tr -d ' ') sections)"
report "section refusals" < <(refusal_check "$RSK") && echo "ok   section refusals"
report "cross links" < <(link_check "$RSK") && echo "ok   cross links ($(cat "$TMP/lc-count") targets)"

# Negative self-check: each sed script changes one file of a temp copy of the skill, and the
# result must be reported under the invariant it breaks.
nmut=0
while IFS='~' read -r name inv target script; do
  [ -n "$BASE" ] || [ "$inv" != sentences ] || continue # no base commit, no sentence comparison
  nmut=$((nmut + 1))
  # The copy keeps the sibling skills, the targets of cross-skill links.
  rm -rf "$TMP/mut"; cp -R "${RSK%/*}" "$TMP/mut"; m="$TMP/mut/${RSK##*/}"
  sed "$script" "$m/$target" > "$TMP/mut-sed" && cat "$TMP/mut-sed" > "$m/$target"
  if cmp -s "$m/$target" "$RSK/$target"; then fail "self-check" "$target" "$name (the mutation changed nothing)"; continue; fi
  case "$inv" in
    "cross link") link_check "$m" > "$TMP/mut-out" ;;
    *) case "$target" in
         references/section.sh)
           { section_check "$m" references/check-f-scope.md references/verification-ladder.md
             refusal_check "$m"; } > "$TMP/mut-out" ;;
         *) index_check "$m" > "$TMP/mut-out" ;;
       esac ;;
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
a summary the workflow does not link~skill links~references/workflow.md~s/(run\/check-e\.md)/(run\/check-e.md#rules)/
the ignored-input band without its null default~sentences~references/check-g-behaviour.md~s/, and its default is `null`\.$/./
the classifier cap read as a missing trigger line~calibration guard~references/check-g-behaviour.md~s/ Neither is a changed file with no `trigger` line when the `behaviour:` line counts one or more changes over the cap: [^.]*\.//
the verification gap handed to the author~calibration guard~references/check-g-behaviour.md~s/For the maintainers, not the author: review this head again once/Rerun the caller's behaviour step so/
a sentence of the spec rewritten~sentences~references/check-g-behaviour.md~s/^- `claim.refuted`: a `claim` line has state `refuted`/- `claim.refuted`: a `claim` line says `refuted`/
a sentence of an engine file rewritten~sentences~references/engine/check-d-examples.md~s/^- A submodule added by the change has no example of its own\./- A submodule added by the change has no example./
a sentence moved out of SKILL.md rewritten~sentences~references/inputs.md~s/^- The workspace is the only source of file content\./- The workspace is the sole source of file content./
a sentence of a check file the base lacks rewritten~sentences~references/check-h-non-hcl.md~s/^Naming, formatting and the idiom/Names, formatting and the idiom/
a row of Check H deleted~missing row~references/run/check-h.md~/^| `structure.non-hcl-test-missing` /d
a navigation line added to SKILL.md unrecorded~sentences~SKILL.md~s/ These headings keep their links\./ These headings keep their links. They hold no text./
Read First dropped~read first~references/run/check-a.md~/^When any row below applies: /d
a facts-engine candidate no longer forcing its row~facts rows~SKILL.md~s/ A row whose rule the `mtf-facts` report of Step 1 gives a finding or candidate for, in any area, holds whatever its condition says: its sections are opened and the rule is judged\.//
row not applied paired with a candidate again~facts rows~references/facts-engine.md~s/ so `row not applied` pairs only with a tool `clean` or `not_applicable`\./ so `row not applied` pairs with any tool result./
the fact sheet index without same_as~fact sheets~references/run/facts.md~s/A `sheet` with `same_as` naming/A `sheet` naming/
the Budget without missing.json~fact sheets~references/large-changes.md~s/also writes `missing.json` beside/also writes a list beside/
section.sh past the next heading~section.sh~references/section.sh~s/if (on \&\& lvl <= on) on = 0/if (on \&\& lvl < on) on = 0/
section.sh stopping at a deeper heading~section.sh~references/section.sh~s/if (on \&\& lvl <= on) on = 0/if (on) on = 0/
section.sh reading fenced headings~section.sh fixture~references/section.sh~s/} else if (fence == 0 \&\& /} if (/
section.sh bounded by its own skill~cross link~references/section.sh~s/case "\$r\/" in "\$K"\/\*)/case "$r\/" in "$S"\/*)/
section.sh without the skill boundary~refusal~references/section.sh~/outside the skill/d
section.sh following a symbolic link~refusal~references/section.sh~s/ \&\& \[ ! -L "\$r\/\$b" \]//
section.sh taking any anchor~refusal~references/section.sh~/not an anchor/d
section.sh taking any file~refusal~references/section.sh~/not a markdown file/d
section.sh printing the first of two headings~refusal~references/section.sh~/headings have the slug/d
calibration guard 1 dropped~calibration guard~references/engine/check-a-compatibility.md~s#After that sentence, LOW when the argument's own entry#dropped#g
calibration guard 2 dropped~calibration guard~references/engine/check-a-compatibility.md~s#a page silent on replacement is the `review\.check-not-run` of the Provider facts line#dropped#g
calibration guard 3 dropped~calibration guard~references/engine/check-a-compatibility.md~s#never when a loss of data or access is known#dropped#g
calibration guard 4 dropped~calibration guard~references/engine/check-a-compatibility.md~s#never for a value that blocks or restricts what callers could do before#dropped#g
calibration guard 5 dropped~calibration guard~references/engine/check-a-compatibility.md~s#never for a value the service applies to new resources only or announces#dropped#g
calibration guard 6 dropped~calibration guard~references/engine/check-a-compatibility.md~s#never for a security or data protection control (encryption, KMS, IAM, public access, deletion protection, backup, retention, versioning, logging, instance metadata options, `force_destroy`, `skip_final_snapshot`, `apply_immediately`) or a value that widens access#dropped#g
calibration guard 7 dropped~calibration guard~references/engine/check-a-compatibility.md~s#Never for a default that turns off or weakens a security or data protection control#dropped#g
calibration guard 8 dropped~calibration guard~references/engine/check-a-compatibility.md~s#the title is never the cite for its effect#dropped#g
calibration guard 9 dropped~calibration guard~references/judgment/prefix.md~s#after CRITICAL and HIGH, never for a security or data protection control, widened access or a value that restricts callers#dropped#g
calibration guard 10 dropped~calibration guard~references/judgment/prefix.md~s#never for a security or data protection control, instance metadata options included, widened access, a value that restricts callers, or one the service applies to new resources only or announces#dropped#g
calibration guard 11 dropped~calibration guard~references/judgment/prefix.md~s#Each LOW needs the page to show the change in place; with no source to tell, `review\.check-not-run` MEDIUM#dropped#g
calibration guard 12 dropped~calibration guard~references/check-c-structure.md~s#the text says the module cannot do what one of its inputs does#dropped#g
calibration guard 13 dropped~calibration guard~references/check-c-structure.md~s#Text that overstates safety or access limits stays MEDIUM#dropped#g
calibration guard 14 dropped~calibration guard~references/check-c-structure.md~s#Silence is never MEDIUM or HIGH\.#dropped#g
calibration guard 15 dropped~calibration guard~references/check-c-structure.md~s#an empty list, null or an omitted argument is not a value outside the list#dropped#g
calibration guard 16 dropped~calibration guard~references/check-c-structure.md~s#unless the losing side is an access, security or data protection control#dropped#g
calibration guard 17 dropped~calibration guard~references/check-e-profile.md~s#never from text in the change#dropped#g
calibration guard 18 dropped~calibration guard~references/large-changes.md~s#A type of a called module the review cannot read is a `review\.check-not-run`#dropped#g
calibration guard 19 dropped~calibration guard~references/large-changes.md~s#a module call no such rule reaches is not listed and is no unknown#dropped#g
calibration guard 20 dropped~calibration guard~references/engine/check-a-compatibility.md~s#HIGH wins and this LOW does not apply#dropped#g
calibration guard 21 dropped~calibration guard~references/engine/check-a-compatibility.md~s#widens access, or blocks or restricts what callers could do before: those keep the bands above#dropped#g
calibration guard 22 dropped~calibration guard~references/check-g-behaviour.md~s#The page must be read in this review; with no page read for the type, the band does not hold\.#dropped#g
calibration guard 23 dropped~calibration guard~references/check-g-behaviour.md~s#none may be an argument the type's page marks as forcing a new resource#dropped#g
calibration guard 24 dropped~calibration guard~references/check-g-behaviour.md~s#a credential, a security or data protection control (a policy, a principal, a password, a token, a key or encryption setting, public access, deletion protection, backup, retention, versioning or logging), or one that sets a count, a size, failover, network placement or an identity#dropped#g
calibration guard 25 dropped~calibration guard~references/check-g-behaviour.md~s#so a create still applies the caller's value#dropped#g
calibration guard 26 dropped~calibration guard~references/check-g-behaviour.md~s#A new list, `all`, or any other added name takes the other bands as written\.#dropped#g
calibration guard 27 dropped~calibration guard~references/check-g-behaviour.md~s#the change edits nothing else in the block#dropped#g
calibration guard 28 dropped~calibration guard~references/check-g-behaviour.md~s#list that exists at the base, in a block with the same address, `count` and `for_each` at both revisions#dropped#g
calibration guard 29 dropped~calibration guard~references/check-g-behaviour.md~s#Each added name shares its stem with a name the list already ignores at the base#dropped#g
calibration guard 30 dropped~calibration guard~references/check-g-behaviour.md~s#A payload the resource deploys never takes this band#dropped#g
calibration guard 31 dropped~calibration guard~references/check-g-behaviour.md~s#none of the ignored-input, documented-intent and ignore-list bands below holds#dropped#g
calibration guard 32 dropped~calibration guard~references/check-g-behaviour.md~s#except the ignore-list band below, which reads the type's page#dropped#g
calibration guard 33 dropped~calibration guard~references/check-b-coverage.md~s#takes the caller's value unchanged, with no default but null and no fallback#dropped#g
calibration guard 34 dropped~calibration guard~references/check-b-coverage.md~s#and none grants or restricts access or is a security control#dropped#g
calibration guard 35 dropped~calibration guard~references/check-b-coverage.md~s#or one argument required or not allowed when another is set or unset#dropped#g
calibration guard 36 dropped~calibration guard~references/check-b-coverage.md~s#A conflicting pair in any wording, exactly one of and at least one of included, stays HIGH#dropped#g
calibration guard 37 dropped~calibration guard~references/check-b-coverage.md~s#and so does a conditional rule where the module supplies a side#dropped#g
calibration guard 38 dropped~calibration guard~references/check-b-coverage.md~s#The summary names the rule as the page states it and that the provider or the service rejects such a call\.#dropped#g
calibration guard 39 dropped~calibration guard~references/check-c-structure.md~s#an argument of a block planned on every path where the module tests it#dropped#g
calibration guard 40 dropped~calibration guard~references/check-c-structure.md~s#a page this review read shows the provider checks that argument at plan#dropped#g
calibration guard 41 dropped~calibration guard~references/check-c-structure.md~s#that holds every value the module tests#dropped#g
calibration guard 42 dropped~calibration guard~references/check-c-structure.md~s#Examples, common values, a list in prose outside the entry or a check the page places at apply do not count\.#dropped#g
calibration guard 43 dropped~calibration guard~references/check-c-structure.md~s#With no page read for the type, or for a commented-out block, it stays MEDIUM\.#dropped#g
calibration guard 44 dropped~calibration guard~references/check-c-structure.md~s#a commented-out block stays MEDIUM#dropped#g
calibration guard 45 dropped~calibration guard~references/check-d-examples.md~s#when the change adds the example#dropped#g
calibration guard 46 dropped~calibration guard~references/check-d-examples.md~s#counts as one the base had and stays HIGH#dropped#g
calibration guard 47 dropped~calibration guard~references/engine/check-e-profile.md~s#when the literal is in a file under `examples/` that is not a `terraform test` file (`\*\.tftest\.hcl`), in an example no `\*\.tftest\.hcl` file uses as a module source#dropped#g
calibration guard 48 dropped~calibration guard~references/engine/check-e-profile.md~s#The root module, submodules, `tests/` and every `\*\.tftest\.hcl` file keep HIGH#dropped#g
calibration guard 49 dropped~calibration guard~references/judgment/prefix.md~s#a conflicting pair in any wording stays HIGH#dropped#g
calibration guard 50 dropped~calibration guard~references/judgment/prefix.md~s#LOW for `structure\.validation-missing` only as#dropped#g
calibration guard 51 dropped~calibration guard~references/judgment/prefix.md~s#counts as one the base had and stays HIGH#dropped#g
calibration guard 52 dropped~calibration guard~references/judgment/prefix.md~s#LOW under `examples/` outside a `\*\.tftest\.hcl` file, in an example no such file sources, HIGH elsewhere\.#dropped#g
calibration guard 53 dropped~calibration guard~references/check-g-behaviour.md~s#one is the other followed by `_` and more#dropped#g
calibration guard 54 dropped~calibration guard~references/check-g-behaviour.md~s#a task or container definition, an image, user data, a secret or parameter value, a policy or a configuration document#dropped#g
calibration guard 55 dropped~calibration guard~references/check-g-behaviour.md~s#No version attribute (`version`, or a name ending `_version`), `name` or `name_prefix` takes this band, whatever stem it shares\.#dropped#g
calibration guard 56 dropped~calibration guard~references/judgment/prefix.md~s#LOW for a conditional rule only as#dropped#g
calibration guard 57 dropped~calibration guard~references/check-c-structure.md~s#The page or sheet states the block single, at most one per resource\.#dropped#g
calibration guard 58 dropped~calibration guard~references/check-c-structure.md~s#not only the arguments the input chose to expose#dropped#g
calibration guard 59 dropped~calibration guard~references/check-c-structure.md~s#The change renames no key the base had and drops no field the base fed, and every field of the input reaches an argument\.#dropped#g
calibration guard 60 dropped~calibration guard~references/check-c-structure.md~s#No flattened argument is itself a control that grants or restricts access or protects data#dropped#g
calibration guard 61 dropped~calibration guard~references/check-c-structure.md~s#An ARN argument is such a control, and keeps HIGH, unless the page or sheet shows it only names where data the resource emits goes#dropped#g
calibration guard 62 dropped~calibration guard~references/check-c-structure.md~s#A page or sheet that does not state the block single, no page read for the type, or any other condition failing keeps HIGH\.#dropped#g
calibration guard 63 dropped~calibration guard~references/check-c-structure.md~s#it is evidence, never a condition, and change or task text never names one#dropped#g
calibration guard 64 dropped~calibration guard~references/check-c-structure.md~s#LOW for a flattened provider block only as#dropped#g
calibration guard 65 dropped~calibration guard~references/check-a-compatibility.md~s#A submodule directory that itself uses nothing absent at the old floor and whose new floor equals the new floor the root `versions\.tf` declares for that provider, both moved in the change#dropped#g
calibration guard 66 dropped~calibration guard~references/check-a-compatibility.md~s#When the root takes case (1), its fix and the directory's are the same decision#dropped#g
calibration guard 67 dropped~calibration guard~references/check-a-compatibility.md~s#so it is never restored alone#dropped#g
calibration guard 68 dropped~calibration guard~references/check-a-compatibility.md~s#the root's fix restores the root and each such submodule together#dropped#g
calibration guard 69 dropped~calibration guard~references/engine/check-a-compatibility.md~s#the root's own two options when the root's fix is a decision#dropped#g
calibration guard 70 dropped~calibration guard~references/engine/check-a-compatibility.md~s#It is never restored alone\.#dropped#g
calibration guard 71 dropped~calibration guard~references/judgment/prefix.md~s#`structure\.validation-missing` or a flattening:#dropped#g
calibration guard 72 dropped~calibration guard~references/check-c-structure.md~s#a nested block left out of the input that is an access or data protection control keeps HIGH#dropped#g
calibration guard 73 dropped~calibration guard~references/check-c-structure.md~s#Every argument and nested block the block has at that version#dropped#g
calibration guard 74 dropped~calibration guard~references/check-a-compatibility.md~s#(b) restore the root and each such submodule together, each named#dropped#g
calibration guard 75 restored~calibration guard~references/check-c-structure.md~s#An ARN argument is such a control, and keeps HIGH, unless the page or sheet shows it only names where data the resource emits goes, that data is neither audit or access logs nor failure or dead-letter handling, and the ARN does not protect it as a key, role, policy, certificate, secret or access point does\. When the page does not settle it, HIGH\.#A destination or resource ARN that is not a KMS key, an IAM role or policy, or a log destination that turns logging on is no such control.#g
calibration guard 76 restored~calibration guard~references/check-c-structure.md~s#An ARN argument is such a control, and keeps HIGH, unless the page or sheet shows it only names where data the resource emits goes, that data is neither audit or access logs nor failure or dead-letter handling, and the ARN does not protect it as a key, role, policy, certificate, secret or access point does\. When the page does not settle it, HIGH\.#A destination or resource ARN is no such control.#g
calibration guard 77 restored~calibration guard~references/check-c-structure.md~s#An ARN argument is such a control, and keeps HIGH, unless the page or sheet shows it only names where data the resource emits goes, that data is neither audit or access logs nor failure or dead-letter handling, and the ARN does not protect it as a key, role, policy, certificate, secret or access point does\. When the page does not settle it, HIGH\.#A destination ARN, or a resource ARN that is not a KMS key, an IAM role or policy, or a log destination that turns logging on, is no such control.#g
calibration guard 78 dropped~calibration guard~references/check-c-structure.md~s#audit or access logs nor ##g
calibration guard 79 dropped~calibration guard~references/check-c-structure.md~s# nor failure or dead-letter handling##g
calibration guard 80 dropped~calibration guard~references/check-c-structure.md~s#certificate, ##g
calibration guard 81 dropped~calibration guard~references/check-c-structure.md~s#secret or ##g
calibration guard 82 dropped~calibration guard~references/check-c-structure.md~s# or access point##g
calibration guard 83 dropped~calibration guard~references/check-c-structure.md~s#role, policy, ##g
calibration guard 84 dropped~calibration guard~references/check-c-structure.md~s# When the page does not settle it, HIGH\.##g
calibration guard 85 dropped~calibration guard~references/check-c-structure.md~s#a `before` or `after` token of its name says it is not to wait for the target#dropped#g
calibration guard 86 dropped~calibration guard~references/check-c-structure.md~s#A target that exists on some paths only still fires for the paths where both exist#dropped#g
calibration guard 87 dropped~calibration guard~references/check-c-structure.md~s#A sibling's `depends_on` alone is no need\.#dropped#g
calibration guard 88 dropped~calibration guard~references/check-c-structure.md~s#a `concat` of candidates one of which an input feeds#dropped#g
calibration guard 89 dropped~calibration guard~references/check-c-structure.md~s#and `""` or `null` is no such fallback#dropped#g
calibration guard 90 dropped~calibration guard~references/check-c-structure.md~s#an index error is no such check#dropped#g
calibration guard 91 dropped~calibration guard~references/check-c-structure.md~s#when the index is the position in the list the `count` or `for_each` itself enumerates#dropped#g
calibration guard 92 dropped~calibration guard~references/check-c-structure.md~s#when the module builds the list with a count that bounds the index on every path#dropped#g
calibration guard 93 dropped~calibration guard~references/check-c-structure.md~s#when the index is a value the caller gives per element#dropped#g
calibration guard 94 dropped~calibration guard~references/check-c-structure.md~s#for `element()`, whose wrap is the family idiom#dropped#g
calibration guard 95 dropped~calibration guard~references/check-c-structure.md~s#the direct read is the value the block needs#dropped#g
calibration guard 96 dropped~calibration guard~references/check-c-structure.md~s#whenever the need rests only on the siblings' `depends_on` and a page that names the block; never LOW#dropped#g
calibration guard 97 dropped~calibration guard~references/check-c-structure.md~s#A page that only recommends it, or shows it in an example, keeps MEDIUM\.#dropped#g
calibration guard 98 dropped~calibration guard~references/check-c-structure.md~s#gated on the branch that reads the caller's list#dropped#g
calibration guard 99 dropped~calibration guard~references/judgment/prefix.md~s#- A new block beside its siblings, or a new list index:#dropped#g
calibration guard 100 dropped~calibration guard~references/check-c-structure.md~s#A comment about other blocks keeps LOW:#dropped#g
calibration guard 101 dropped~calibration guard~references/check-c-structure.md~s#the direct read fails or gives another value, and the local does not#dropped#g
calibration guard 102 dropped~calibration guard~references/check-c-structure.md~s#without which the resource still does its job, on the target the module intends#dropped#g
calibration guard 103 dropped~calibration guard~references/check-c-structure.md~s#makes the provider pick a default target#dropped#g
calibration guard 104 dropped~calibration guard~references/check-c-structure.md~s#on every supported path where the new block exists and the two differ#dropped#g
calibration guard 105 dropped~calibration guard~references/check-c-structure.md~s#or a page this review read shows the block uses it#dropped#g
calibration guard 106 dropped~calibration guard~references/check-c-structure.md~s#a fallback the comment states is taken#dropped#g
calibration guard 107 dropped~calibration guard~references/check-c-structure.md~s#and so is a new gateway there when neither its code nor a page read shows it uses that range#dropped#g
EOF

echo
if [ "$fails" -eq 0 ]; then echo "all passed ($nmut mutations caught)"; else echo "$fails failed"; exit 1; fi
