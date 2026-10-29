#!/bin/bash
# Mechanical checks over the repository's markdown and templates: relative links
# resolve, anchors match a real heading, no two headings in a file share a slug,
# text is plain ASCII, the profile's review guide still matches the profile
# sections it restates, the profile constants blocks parse and equal the rule
# text they restate, and the reviewer's rule facts table has a row, a carry
# value and valid registry columns for every rule, and the engine files hold one
# well-formed section for each tool and candidate rule, and the judgment prefix is what its
# assembler gives, every time, within its size cap. Run: tests/skills-test.sh
#
# Headings must be ATX (a leading #). A setext heading is reported rather than
# parsed, because reading it wrong is silent in both directions: the anchor that
# points at it looks broken and the slug it defines never enters the table.
#
# Three link constructs are not parsed, and none exists in the corpus today: a
# reference-style link ([text][ref] with its [ref]: definition elsewhere in the
# file), a link inside an HTML comment, and a link inside a four-space indented
# code block. All three fail open. An unparsed link is invisible rather than
# wrong, so a reference-style link with a dead target leaves the run green and
# the counts unmoved: a green run is only as broad as the syntax below. Model
# one when it first appears in the corpus, not before.
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SRC" || exit 1
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0

fail() { # check, file:line, detail
  echo "FAIL $1: $2 $3"; echo "$1" >> "$TMP/failed"; fails=$((fails + 1))
}
: > "$TMP/failed"

# Every path git knows about, tracked or newly added, plus each of their parent
# directories. A link target is checked against this and not against the disk:
# a gitignored or unadded file resolves locally and 404s on the forge.
git ls-files --cached --others --exclude-standard > "$TMP/all"
{ cat "$TMP/all"; awk '{ while (sub(/\/[^\/]*$/, "")) print }' "$TMP/all"; } |
  sort -u > "$TMP/paths"

# Corpus: every markdown file plus the templates they link to, and the shell
# scripts a skill ships, which get the ASCII check only.

files=()
while IFS= read -r f; do files+=("$f"); done < <(
  grep -E '\.(md|template)$|^\.agents/skills/.*\.sh$' "$TMP/all"
)
if [ "${#files[@]}" -eq 0 ]; then
  echo "FAIL corpus: no markdown or template files found; is this a git checkout?"
  exit 1
fi

# One pass over the corpus. Emits tab-separated records:
#   LINK  <file> <line> <resolved path> <raw target>   (shell tests membership)
#   BAD   <check> <file> <line> <detail>
#   COUNT <check> <label>
LC_ALL=C awk '
function slug(t) {                       # the repo slug rule
  gsub(/`/, "", t); t = tolower(t)
  gsub(/[^a-z0-9_ -]/, "", t); gsub(/ /, "-", t)
  return t
}
function norm(p,   n, part, i, k, out, r) {   # collapse . and .. in a path
  n = split(p, part, "/"); k = 0
  for (i = 1; i <= n; i++) {
    if (part[i] == "" || part[i] == ".") continue
    if (part[i] == "..") { if (k > 0) k--; else return ""; continue }
    out[++k] = part[i]
  }
  r = ""
  for (i = 1; i <= k; i++) r = (i > 1) ? r "/" out[i] : out[i]
  return r
}
function hex2dec(h,   i, d, v) {
  h = tolower(h); v = 0
  for (i = 1; i <= length(h); i++) {
    d = index("0123456789abcdef", substr(h, i, 1)) - 1
    if (d < 0) return -1
    v = v * 16 + d
  }
  return v
}
function points(s,   i, n, k, b, cnt, cp, out) {   # the U+ of every byte out of range
  out = ""; i = 1; n = length(s)
  while (i <= n) {
    b = ord[substr(s, i, 1)]
    if (b == 9 || (b >= 32 && b <= 126)) { i++; continue }
    if (b < 128)       { cnt = 1; cp = b }
    else if (b >= 240) { cnt = 4; cp = b - 240 }
    else if (b >= 224) { cnt = 3; cp = b - 224 }
    else if (b >= 192) { cnt = 2; cp = b - 192 }
    else               { cnt = 1; cp = b }
    for (k = 1; k < cnt; k++) cp = cp * 64 + (ord[substr(s, i + k, 1)] - 128)
    out = out sprintf("%sU+%04X", (out == "") ? "" : " ", cp)
    i += cnt
  }
  return out
}
BEGIN {
  # The byte class, written as octal escapes: a real tab, not a backslash and a
  # t, which in a bracket expression would match every tab (see AGENTS.md).
  NONASCII = "[^\040-\176\011]"
  TITLE = "[\040\011]+[\042\047(]"       # a link title after the destination
  for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i
  for (i = 1; i < ARGC; i++) corpus[ARGV[i]] = 1
}
FNR == 1 {
  fence = 0; prev = ""
  fm = ($0 == "---")                     # YAML frontmatter, closed by the next ---
  dir = FILENAME; if (!sub(/\/[^\/]*$/, "", dir)) dir = "."
  headings = (FILENAME !~ /\.(template|sh)$/) # neither holds an anchor target
  if (headings) seen[FILENAME] = 1
}
{
  if ($0 ~ NONASCII) nb[++nbad] = FILENAME "\t" FNR "\t" points($0)
  if (FILENAME ~ /\.sh$/) next          # a script: no headings, no links

  if (fm) { if (FNR > 1 && $0 == "---") fm = 0; prev = ""; next }

  # Fenced code: track the opening run length and close only on a run at least
  # that long, so a nested shorter fence does not end the block.
  f = $0; sub(/^ ? ? ?/, "", f)
  if (f ~ /^```/ || f ~ /^~~~/) {
    c = substr(f, 1, 1); n = 0
    while (substr(f, n + 1, 1) == c) n++
    if (fence == 0) { fence = n; fchar = c }
    else if (c == fchar && n >= fence && substr(f, n + 1) ~ /^ *$/) fence = 0
    prev = ""; next
  }
  if (fence > 0) { prev = ""; next }

  if (prev != "" && ($0 ~ /^=+[\040\011]*$/ || $0 ~ /^-+[\040\011]*$/))
    print "BAD\theadings are ATX\t" FILENAME "\t" FNR \
          "\tthis underlines the line above into a heading; write it with a leading #"

  if (match($0, /Typography exception: `[^`]+`/)) {   # the recorded exception
    rec = substr($0, RSTART, RLENGTH); sub(/^[^`]*`/, "", rec); sub(/`$/, "", rec)
    rest = substr($0, RSTART + RLENGTH); cps = ""
    while (match(rest, /[Uu]\+[0-9A-Fa-f]+/)) {
      cps = cps ((cps == "") ? "" : " ") "U+" substr(rest, RSTART + 2, RLENGTH - 2)
      rest = substr(rest, RSTART + RLENGTH)
    }
    xn++; xfile[xn] = FILENAME; xline[xn] = FNR
    xdir[xn] = dir; xname[xn] = rec; xcps[xn] = cps
  }

  if (headings && $0 ~ "^#+[\040\011]") {
    text = $0; sub(/^#+[\040\011]+/, "", text); sub(/[\040\011]+$/, "", text)
    s = slug(text); nslug++
    if ((FILENAME, s) in slugline)
      print "BAD\tno duplicate heading slugs\t" FILENAME "\t" FNR \
            "\tslug " s " already used at line " slugline[FILENAME, s]
    else slugline[FILENAME, s] = FNR
    got[FILENAME, s] = 1
  }

  t = $0
  gsub(/`[^`]*`/, " ", t)                # a link inside a code span is an example
  gsub(/!\[[^]]*\]\([^)]*\)/, " ", t)    # images: one may nest inside a link
  while (match(t, /\]\([^)]*\)/)) {
    target = substr(t, RSTART + 2, RLENGTH - 3)
    t = substr(t, RSTART + RLENGTH)
    sub(/^[\040\011]+/, "", target); sub(/[\040\011]+$/, "", target)
    if (match(target, TITLE)) target = substr(target, 1, RSTART - 1)
    if (target ~ /^</ && target ~ />$/) target = substr(target, 2, length(target) - 2)
    if (target ~ /^[a-zA-Z][a-zA-Z0-9+.-]*:/ || target == "") continue
    frag = ""
    if (match(target, /#/)) {
      frag = substr(target, RSTART + 1); target = substr(target, 1, RSTART - 1)
    }
    if (target == "") path = FILENAME
    else {
      nlink++
      path = norm(dir "/" target)
      if (path == "") {
        print "BAD\trelative links resolve\t" FILENAME "\t" FNR \
              "\t" target " climbs out of the repository root"
        continue
      }
      print "LINK\t" FILENAME "\t" FNR "\t" path "\t" target
    }
    if (frag != "") { na++; anc[na] = FILENAME "\t" FNR "\t" path "\t" frag }
  }
  prev = $0
}
END {
  # An exception record names a file inside the subtree that records it. A bare
  # name is taken as a path suffix and must match exactly one file, so the
  # record cannot licence a namesake elsewhere in the tree.
  for (i = 1; i <= xn; i++) {
    pre = (xdir[i] == ".") ? "" : xdir[i] "/"
    suf = "/" xname[i]; hits = 0; hit = ""
    for (p in corpus) {
      if (index(p, pre) != 1) continue
      if (p == (pre xname[i]) ||
          (length(p) > length(suf) && substr(p, length(p) - length(suf) + 1) == suf)) {
        hits++; hit = p
      }
    }
    where = (pre == "") ? "the repository" : pre
    if (xcps[i] == "")
      print "BAD\tplain ASCII\t" xfile[i] "\t" xline[i] \
            "\tthe exception record for " xname[i] " names no codepoint in U+XXXX form"
    else if (hits == 0)
      print "BAD\tplain ASCII\t" xfile[i] "\t" xline[i] \
            "\tthe exception record names " xname[i] ", which is no file in " where
    else if (hits > 1)
      print "BAD\tplain ASCII\t" xfile[i] "\t" xline[i] \
            "\tthe exception record for " xname[i] " matches " hits " files; name the path"
    else {
      n = split(xcps[i], cp, " ")
      for (k = 1; k <= n; k++) allow[hit, hex2dec(substr(cp[k], 3))] = 1
    }
  }

  for (i = 1; i <= na; i++) {
    split(anc[i], a, "\t")
    if (a[3] ~ /\.template$/) {
      nachk++
      print "BAD\tanchors match a heading\t" a[1] "\t" a[2] \
            "\t" a[3] " is a template and has no headings, so #" a[4] " cannot resolve"
      continue
    }
    if (!(a[3] in seen)) { naskip++; continue }   # outside the corpus: path only
    nachk++
    if (!((a[3], a[4]) in got))
      print "BAD\tanchors match a heading\t" a[1] "\t" a[2] \
            "\tno heading in " a[3] " has the slug " a[4]
  }

  for (i = 1; i <= nbad; i++) {
    split(nb[i], v, "\t"); n = split(v[3], cp, " "); left = ""; first = ""
    for (k = 1; k <= n; k++)
      if (!((v[1], hex2dec(substr(cp[k], 3))) in allow)) {
        if (left == "") { left = cp[k]; first = cp[k] } else left = left " " cp[k]
      }
    if (left != "")
      print "BAD\tplain ASCII\t" v[1] "\t" v[2] "\t" left \
            " is not ASCII; rewrite it, or add a typography exception line for" \
            " this file naming " first " (see AGENTS.md, Writing style)"
  }

  print "COUNT\trelative links resolve\t" (nlink + 0) " checked"
  print "COUNT\tanchors match a heading\t" (nachk + 0) " checked" \
        ((naskip + 0) ? ", " naskip " outside the corpus and unverifiable" : "")
  print "COUNT\tno duplicate heading slugs\t" (nslug + 0) " checked"
  print "COUNT\theadings are ATX\t" (nslug + 0) " checked"
  print "COUNT\tplain ASCII\t" NR " lines"
}
' "${files[@]}" > "$TMP/rec" || {
  echo "FAIL corpus: the checker did not run"
  exit 1
}

# A run that ended early can still exit 0, so the summaries are the receipt.
counts="$(grep -c '^COUNT' "$TMP/rec")"
if [ "$counts" != 5 ]; then
  echo "FAIL corpus: $counts of 5 summaries reported, so the checker stopped early"
  exit 1
fi

# Records are ordered: every LINK and BAD lands before the COUNT lines that
# decide which checks get to print "ok".
while IFS=$'\t' read -r kind a b c d; do
  case "$kind" in
    LINK)  grep -qxF "$c" "$TMP/paths" ||
             fail "relative links resolve" "$a:$b" "$d does not resolve to a path git knows ($c)" ;;
    BAD)   fail "$a" "$b:$c" "$d" ;;
    COUNT) grep -qxF "$a" "$TMP/failed" || echo "ok   $a ($b)" ;;
  esac
done < "$TMP/rec"

# The profile's review guide restates the profile for a reviewer that reads only
# the guide, so it must not drift from what it restates. The links above already
# prove each cited anchor exists. Three checks add to that:
# - every level-2 section of the profile files it draws on is linked from the
#   guide, as the source of a rule or as a Not covered row, so a new section
#   cannot land unseen;
# - each "Source:" line and each Not covered row records a git blob id prefix of
#   the section it names, from its heading to the next heading of the same or a
#   higher level, so an edit under an unchanged heading fails until the guide is
#   re-read and the hash updated;
# - every backticked token on an "ID:" or "IDs:" line is named in the reviewer
#   skill, whatever its prefix.
# Headings inside fenced code are skipped by a plain open/close toggle, which is
# enough for these files; the checker above handles nested fences in full.
GDIR=.agents/skills/terraform-module-maintainer/profiles/terraform-aws-modules
GUIDE="$GDIR/review-guide.md"
section() { # file, slug: the section's lines, or the slugs of its H2s for "##"
  LC_ALL=C awk -v want="$2" '
    function slug(t) {
      gsub(/`/, "", t); t = tolower(t)
      gsub(/[^a-z0-9_ -]/, "", t); gsub(/ /, "-", t)
      return t
    }
    /^ ? ? ?(```|~~~)/ { fence = !fence }
    !fence && /^#+[\040\011]/ {
      match($0, /^#+/); lvl = RLENGTH
      t = $0; sub(/^#+[\040\011]+/, "", t); sub(/[\040\011]+$/, "", t)
      if (want == "##") { if (lvl == 2) print slug(t); next }
      if (on && lvl <= on) exit
      if (!on && slug(t) == want) on = lvl
    }
    on { print }
  ' "$1"
}
if [ ! -f "$GUIDE" ]; then
  fail "review guide matches the profile" "$GUIDE" "is missing"
else
  nguide=0
  for f in PROFILE.md code-conventions.md scope.md templates-map.md pr-description.md; do
    while IFS= read -r s; do
      nguide=$((nguide + 1))
      grep -qF "]($f#$s)" "$GUIDE" ||
        fail "review guide matches the profile" "$GDIR/$f" \
          "section #$s is neither a source nor a Not covered row in review-guide.md"
    done < <(section "$GDIR/$f" "##")
  done
  src='^([0-9]+):Source: \[[^]]*\]\(([^)#]+)#([^)]+)\) `([0-9a-f]{12})`$'
  row='^([0-9]+):\| \[[^]]*\]\(([^)#]+)#([^)]+)\) \|.*\| `([0-9a-f]{12})` \|$'
  while IFS= read -r l; do
    nguide=$((nguide + 1))
    if [[ ! "$l" =~ $src && ! "$l" =~ $row ]]; then
      fail "review guide matches the profile" "$GUIDE:${l%%:*}" \
        "not Source: [text](file#slug) \`<12 hex>\`, nor a Not covered row ending | \`<12 hex>\` |"
      continue
    fi
    n="${BASH_REMATCH[1]}" f="${BASH_REMATCH[2]}" s="${BASH_REMATCH[3]}"
    want="${BASH_REMATCH[4]}"
    got="$(section "$GDIR/$f" "$s" | git hash-object --stdin | cut -c1-12)"
    [ "$got" = "$want" ] ||
      fail "review guide matches the profile" "$GUIDE:$n" \
        "$f#$s now hashes to $got; re-read that section, update the guide, then the hash"
  done < <(grep -nE '^(Source: |\| \[)' "$GUIDE")
  while IFS= read -r id; do
    nguide=$((nguide + 1))
    grep -rqF "$id" .agents/skills/terraform-module-reviewer ||
      fail "review guide matches the profile" "$GUIDE" \
        "$id is named nowhere in the reviewer skill"
  done < <(grep -E '^IDs?: ' "$GUIDE" | grep -oE '`[^`]+`' | sort -u)
  grep -qxF "review guide matches the profile" "$TMP/failed" ||
    echo "ok   review guide matches the profile ($nguide checked)"
fi

# The profile constants: every fenced block with the profile-constants info string in
# PROFILE.md parses, the blocks and their keys are exactly the expected ones, and each
# value equals the rule text it restates, read out of that text here. A negative
# self-check mutates temp copies of PROFILE.md and requires each mutation to be reported
# under the block it changed.
CONST_BLOCKS="required-files regions argument-order template-destinations profile-owned-files tooling banner adjunct-types"
const_keys() { # block: its fixed keys; template-destinations is keyed by template and checked by pairs
  case "$1" in
    required-files) echo "root submodule example example-dirs" ;;
    regions) echo "primary secondary" ;;
    argument-order) echo "first last" ;;
    profile-owned-files) echo "verbatim workflow-dir" ;;
    tooling) echo "files dirs" ;;
    banner) echo "line" ;;
    adjunct-types) echo "types" ;;
  esac
}
const_parse() { # file: C<TAB>block<TAB>key<TAB>value per value, E<TAB>block<TAB>detail per problem
  LC_ALL=C awk '
    function bad(d) { print "E\t" ((name == "") ? "?" : name) "\tline " FNR ": " d }
    /^```profile-constants$/ { if (on) bad("a block opens inside another"); on = 1; name = ""; nl = 0; next }
    on && /^```$/ { if (name == "") bad("a block with no name line"); on = 0; next }
    on {
      nl++
      if (!match($0, /^[A-Za-z0-9._-]+: /)) { bad("not <key>: <value>"); next }
      k = substr($0, 1, RLENGTH - 2); v = substr($0, RLENGTH + 1)
      if (nl == 1) {
        if (k != "name") { bad("the first line is not name:"); next }
        name = v
        if (name in names) bad("block name used twice")
        names[name] = 1; next
      }
      if (name == "") next
      if ((name, k) in keys) bad("key " k " used twice")
      keys[name, k] = 1
      if (v == "" || v ~ /  / || v ~ / $/) bad("key " k " has an empty value or a stray space")
      print "C\t" name "\t" k "\t" v
    }
    END { if (on) bad("a block is not closed") }' "$1"
}
cv() { awk -F'\t' -v n="$1" -v k="$2" '$1 == n && $2 == k {print $3}' "$TMP/const.tsv"; }
ticks() { grep -oE '`[^`]+`' | tr -d '`' | tr '\n' ' '; }
para() { # file, ERE: the paragraph that starts at the first matching line, on one line
  RE="$2" LC_ALL=C awk 'BEGIN {re = ENVIRON["RE"]} !on && $0 ~ re {on = 1} on && /^$/ {exit}
    on {printf "%s ", $0}' "$1"
}
joined() { section "$1" "$2" | tr '\n' ' '; }
same() { # block, key, value, the restated value: equal as sets of items
  local g w
  g="$(printf '%s\n' "$3" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ')"
  w="$(printf '%s\n' "$4" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ')"
  if [ -z "$w" ]; then
    printf '%s\tthe text that %s restates yields no value; fix the text or this check\n' "$1" "$2"
  elif [ "$g" != "$w" ]; then
    printf '%s\t%s is "%s", the text it restates says "%s"\n' "$1" "$2" "$3" "$4"
  fi
}
numword() { # a number written as a word, one to ten
  case "$1" in one) echo 1 ;; two) echo 2 ;; three) echo 3 ;; four) echo 4 ;; five) echo 5 ;;
    six) echo 6 ;; seven) echo 7 ;; eight) echo 8 ;; nine) echo 9 ;; ten) echo 10 ;; esac
}
constants_check() { # profile file: one line per problem, block<TAB>detail
  local p="$1" b k t prose wd want
  const_parse "$p" > "$TMP/const.raw"
  awk -F'\t' -v OFS='\t' '$1 == "E" {print $2, $3}' "$TMP/const.raw"
  awk -F'\t' -v OFS='\t' '$1 == "C" {print $2, $3, $4}' "$TMP/const.raw" > "$TMP/const.tsv"
  for b in $(cut -f1 "$TMP/const.tsv" | sort -u); do
    case " $CONST_BLOCKS " in *" $b "*) ;; *) printf '%s\tis no block this profile defines\n' "$b" ;; esac
  done
  for b in $CONST_BLOCKS; do
    grep -q "^$b"$'\t' "$TMP/const.tsv" || { printf '%s\tthe block is missing\n' "$b"; continue; }
    [ "$b" = template-destinations ] && continue
    for k in $(awk -F'\t' -v n="$b" '$1 == n {print $2}' "$TMP/const.tsv"); do
      case " $(const_keys "$b") " in *" $k "*) ;; *) printf '%s\thas the unknown key %s\n' "$b" "$k" ;; esac
    done
    for k in $(const_keys "$b"); do
      [ -n "$(cv "$b" "$k")" ] || printf '%s\tlacks the key %s\n' "$b" "$k"
    done
  done

  # Module layout in PROFILE.md: the root, submodule and example paragraphs.
  same required-files root "$(cv required-files root)" \
    "$(para "$p" '^\*\*Root\.\*\*' | sed 's/ Further .*//' | ticks)"
  same required-files submodule "$(cv required-files submodule)" \
    "$(para "$p" '^\*\*`modules/<name>/` for a submodule' | sed 's/, and an example.*//; s/.*its own //' | ticks)"
  same required-files example "$(cv required-files example)" \
    "$(para "$p" '^\*\*A module starts with' | sed 's/ of its own\..*//; s/.*Each holds //' | ticks)"
  same required-files example-dirs "$(cv required-files example-dirs)" \
    "$(para "$p" '^\*\*A module starts with' | sed 's/\.\*\* .*//' | ticks | sed 's#/ # #g')"

  same regions primary "$(cv regions primary)" \
    "$(section "$GDIR/code-conventions.md" regions | grep '^An example uses ' | ticks)"
  same regions secondary "$(cv regions secondary)" \
    "$(section "$GDIR/code-conventions.md" regions | grep 'is the one secondary region' | ticks)"

  t=.agents/skills/terraform-module-maintainer/references/module-structure.md
  same argument-order first "$(cv argument-order first)" \
    "$(section "$t" argument-order-in-a-resource-block | grep '^1\. ' | ticks)"
  same argument-order last "$(cv argument-order last)" \
    "$(section "$t" argument-order-in-a-resource-block | grep '^5\. ' | ticks)"

  # templates-map.md: the template and destination cells of the two whole-file tables.
  for t in static-files-copy-verbatim pre-commit-config-copy-then-update; do
    section "$GDIR/templates-map.md" "$t"
  done | grep '^| `' | awk -F'`' '{d = $4; sub(/^<module>\//, "", d); print $2 ": " d}' |
    sort > "$TMP/const-want"
  awk -F'\t' '$1 == "template-destinations" {print $2 ": " $3}' "$TMP/const.tsv" | sort > "$TMP/const-got"
  [ -s "$TMP/const-want" ] ||
    printf 'template-destinations\tthe templates-map.md tables yield no template\n'
  comm -23 "$TMP/const-got" "$TMP/const-want" | sed 's/^/template-destinations\tnot in templates-map.md: /'
  comm -13 "$TMP/const-got" "$TMP/const-want" | sed 's/^/template-destinations\tmissing from the block: /'
  for t in $(awk -F'\t' '$1 == "template-destinations" {print $2}' "$TMP/const.tsv"); do
    [ -f "$GDIR/templates/$t" ] || printf 'template-destinations\t%s is no file under templates/\n' "$t"
  done

  # scope.md: the verbatim class sentence, its count of workflows and the Static Files table.
  prose="$(joined "$GDIR/scope.md" profile-owned-files | sed 's/.*The verbatim class is//; s/\. The files mapped.*//')"
  wd="$(printf '%s' "$prose" | ticks | tr ' ' '\n' | grep '/$' | sed 's#/$##')"
  same profile-owned-files workflow-dir "$(cv profile-owned-files workflow-dir)" "$wd"
  want="$(section "$GDIR/templates-map.md" static-files-copy-verbatim | grep '^| `' |
    awk -F'`' '{d = $4; sub(/^<module>\//, "", d); print d}' | tr '\n' ' ')"
  same profile-owned-files verbatim "$(cv profile-owned-files verbatim)" "$want"
  same profile-owned-files verbatim "$(cv profile-owned-files verbatim | tr ' ' '\n' | grep -v "^$wd/" | tr '\n' ' ')" \
    "$(printf '%s' "$prose" | ticks | tr ' ' '\n' | grep -v '/$' | tr '\n' ' ')"
  t="$(numword "$(printf '%s' "$prose" | sed -n 's/.* the \([a-z]*\) workflows under .*/\1/p')")"
  [ "$(cv profile-owned-files verbatim | tr ' ' '\n' | grep -c "^$wd/")" = "${t:-none}" ] ||
    printf 'profile-owned-files\tverbatim does not hold the number of workflows scope.md states\n'

  prose="$(joined "$GDIR/scope.md" no-new-scanners-or-linters | sed 's/.*closed list: //; s/\. A new path matches.*//' | ticks)"
  same tooling files "$(cv tooling files)" "$(printf '%s' "$prose" | tr ' ' '\n' | grep -v '/$' | tr '\n' ' ')"
  same tooling dirs "$(cv tooling dirs)" "$(printf '%s' "$prose" | tr ' ' '\n' | grep '/$' | sed 's#/$##' | tr '\n' ' ')"

  t="$GDIR/templates/README.md.template"
  joined "$GDIR/scope.md" the-stand-with-ukraine-banner | grep -qF '`SWUbanner` line of' ||
    printf 'banner\tthe banner section of scope.md no longer names the SWUbanner line\n'
  if [ "$(grep -c SWUbanner "$t")" != 1 ]; then
    printf 'banner\t%s holds no single SWUbanner line\n' "$t"
  elif [ "$(cv banner line)" != "$(grep SWUbanner "$t")" ]; then
    printf 'banner\tline is not the SWUbanner line of %s, byte for byte\n' "$t"
  fi

  same adjunct-types types "$(cv adjunct-types types)" \
    "$(section "$GDIR/scope.md" adjunct-types | grep '^| `' | awk -F'`' '{print $2}' | tr '\n' ' ')"
}
const_mutate() { # file, block, kind, key, value: the file with one block changed
  LC_ALL=C awk -v b="$2" -v kind="$3" -v k="$4" -v v="$5" '
    /^```profile-constants$/ { on = 1; open = $0; next }
    on == 1 {
      on = 2; hit = ($0 == "name: " b)
      if (hit && kind == "info") sub(/profile-constants/, "text", open)
      print open
      if (hit && kind == "rename") print "name: " k; else print
      if (hit && kind == "add") print k ": " v
      next
    }
    on == 2 && /^```$/ { on = 0 }
    on == 2 && hit && index($0, k ": ") == 1 {
      if (kind == "set") { print k ": " v; next }
      if (kind == "append") { print $0 " " v; next }
      if (kind == "drop") next
    }
    { print }' "$1"
}
PROF="$GDIR/PROFILE.md"
while IFS=$'\t' read -r b d; do
  fail "profile constants" "$PROF" "$b: $d"
done < <(constants_check "$PROF")
nconst=$(grep -c '^C' "$TMP/const.raw")
nmut=0
while IFS='|' read -r name b kind k v; do
  nmut=$((nmut + 1))
  const_mutate "$PROF" "$b" "$kind" "$k" "$v" > "$TMP/prof-mut"
  if cmp -s "$TMP/prof-mut" "$PROF"; then
    fail "profile constants" "$PROF" "self-check: $name (the mutation changed nothing)"
  elif ! constants_check "$TMP/prof-mut" | cut -f1 | grep -qxF "$b"; then
    fail "profile constants" "$PROF" "self-check: $name is not reported under $b"
  fi
done <<'EOF'
the root loses LICENSE|required-files|set|root|main.tf variables.tf outputs.tf versions.tf README.md
a submodule loses README.md|required-files|set|submodule|main.tf variables.tf outputs.tf versions.tf
an example gains variables.tf|required-files|append|example|variables.tf
a third starting example|required-files|append|example-dirs|examples/simple
another primary region|regions|set|primary|eu-central-1
another secondary region|regions|set|secondary|us-west-2
depends_on in the first position|argument-order|append|first|depends_on
labels dropped from the last position|argument-order|set|last|tags
a destination moved|template-destinations|set|.gitignore.template|.github/.gitignore
a template the profile does not ship|template-destinations|add|renovate.json.template|renovate.json
a template dropped|template-destinations|drop|github-workflows-lock.yml.template|
the pre-commit config in the verbatim class|profile-owned-files|append|verbatim|.pre-commit-config.yaml
a sixth workflow|profile-owned-files|append|verbatim|.github/workflows/ci.yml
another workflow directory|profile-owned-files|set|workflow-dir|.github
a tool file name added|tooling|append|files|.tflint.hcl
a tool directory added|tooling|append|dirs|.kics
a changed banner line|banner|set|line|[![SWUbanner](https://example.com/banner.svg)](https://example.com/)
aws_kms_key as an adjunct|adjunct-types|append|types|aws_kms_key
an unknown key|regions|add|tertiary|ap-south-1
a missing key|regions|drop|secondary|
a key used twice|argument-order|add|first|count
an empty value|tooling|set|dirs|
a doubled space|adjunct-types|set|types|aws_iam_role  aws_iam_policy
a renamed block|banner|rename|banners|
another info string|tooling|info||
EOF
grep -qxF "profile constants" "$TMP/failed" ||
  echo "ok   profile constants ($nconst values; $nmut mutations caught)"

# The rule to provider fact table: one row for every rule_id the reviewer skill names in
# SKILL.md and its references (the fixtures excepted, which also record rejected names),
# and no other row.
RSK=.agents/skills/terraform-module-reviewer
RF="$RSK/references/rule-facts.md"
ID_RE='`(compat|coverage|structure|examples|profile|scope|review)\.[a-z0-9-]+`'
# Columns are found by their header, so a column added or moved changes no reader. Cells are
# trimmed and lose their backticks; a column the header lacks reads as MISSING.
REG_COLS="engine class scope cross_area area_kinds bundle_sections severities confirm_class proposed_confirm_class"
rf_cells() { # file: per rule row, tab-separated: rule_id, Carry, then the REG_COLS cells
  LC_ALL=C awk -v cols="Carry $REG_COLS" '
    function trim(s) { gsub(/`/, "", s); gsub(/^[\040\011]+|[\040\011]+$/, "", s); return s }
    /^\| `rule_id` \|/ { n = split($0, h, "|"); for (i = 2; i < n; i++) idx[trim(h[i])] = i; next }
    n && /^\| `[a-z]+\.[a-z0-9-]+` \|/ {
      split($0, c, "|"); k = split(cols, want, " "); out = trim(c[2])
      for (j = 1; j <= k; j++) out = out "\t" ((want[j] in idx) ? trim(c[idx[want[j]]]) : "MISSING")
      print out
    }' "$1"
}
# The registry columns. Prints one line per problem: invariant, rule_id, detail. The
# invariant is the column name, "critical small" for a small class on a rule that can
# be CRITICAL, or "confirm lead" for a candidate whose confirm_class is not yet lead. The bundle section names stand for the facts engine spec's Facts bundle list.
registry_check() { # file
  rf_cells "$1" | LC_ALL=C awk -F'\t' -v OFS='\t' '
    function inlist(v, allowed, noneok,   n, a, i, s, seen) {
      if (v == "none") return noneok
      n = split(v, a, ","); if (n == 0) return 0
      for (i = 1; i <= n; i++) {
        s = a[i]; gsub(/^ +| +$/, "", s)
        if (!((" " allowed " ") ~ (" " s " ")) || s == "" || (s in seen)) return 0
        seen[s] = 1
      }
      return 1
    }
    function one(v, allowed) { return v != "" && v !~ / / && (" " allowed " ") ~ (" " v " ") }
    {
      id = $1; eng = $3
      if (!one(eng, "tool candidate llm")) print "engine", id, "is " eng ", not tool, candidate or llm"
      if (!one($4, "config-semantic path")) print "class", id, "is " $4 ", not config-semantic or path"
      if (!one($5, "touched-block touched-expression newly-introduced any-file-in-area"))
        print "scope", id, "is " $5 ", not a scope the check files use"
      if (!one($6, "yes no")) print "cross_area", id, "is " $6 ", not yes or no"
      if (!inlist($7, "root submodule example", 0)) print "area_kinds", id, "is " $7 ", not a list of root, submodule and example"
      if (!inlist($8, "tool-findings candidates area-rules interface-diff schema-coverage file-index", 1))
        print "bundle_sections", id, "is " $8 ", not none or a list of the spec bundle sections"
      if (!inlist($9, "CRITICAL HIGH MEDIUM LOW", 1)) print "severities", id, "is " $9 ", not none or a list of the four severities"
      for (j = 10; j <= 11; j++) {
        col = (j == 10) ? "confirm_class" : "proposed_confirm_class"
        if (eng == "candidate" && !one($j, "small mid lead")) print col, id, "is " $j " on a candidate rule, not small, mid or lead"
        if (eng != "candidate" && $j != "-") print col, id, "is " $j " on a " eng " rule, which takes -"
        if ($j == "small" && ("," $9 ",") ~ /, *CRITICAL *,/) print "critical small", id, col " is small but the rule can be CRITICAL"
      }
      # Every candidate starts at lead; a cheaper class is set only after its evaluation.
      if (eng == "candidate" && one($10, "small mid") ) print "confirm lead", id, "confirm_class is " $10 ", but every candidate rule is lead until it passes its evaluation"
    }'
}
if [ ! -f "$RF" ]; then
  fail "rule facts table" "$RF" "is missing"
else
  grep -hoE "$ID_RE" "$RSK/SKILL.md" $(find "$RSK/references" -name '*.md' ! -name fixtures.md ! -name rule-facts.md | sort) |
    tr -d '`' | sort -u > "$TMP/rule-ids"
  grep -oE "^\| $ID_RE \|" "$RF" | grep -oE "$ID_RE" | tr -d '`' | sort > "$TMP/rule-rows"
  nrf=0
  while IFS= read -r id; do
    nrf=$((nrf + 1))
    [ "$(grep -cxF "$id" "$TMP/rule-rows")" = 1 ] || fail "rule facts table" "$RF" "$id has no row, or more than one"
  done < "$TMP/rule-ids"
  while IFS= read -r id; do
    grep -qxF "$id" "$TMP/rule-ids" || fail "rule facts table" "$RF" "$id has a row but the skill names no such rule"
  done < "$TMP/rule-rows"
  grep -qxF "rule facts table" "$TMP/failed" || echo "ok   rule facts table ($nrf rules)"

  # The carry column: exactly one value, file or never, in the Carry cell of each row, and
  # one audit line in the Carry Audit section for each file row and for no other rule.
  nfile=0
  while IFS=$'\t' read -r id carry _; do
    case "$carry" in
      file) nfile=$((nfile + 1)) ;;
      never) ;;
      *) fail "rule facts carry" "$RF" "$id has no carry value of file or never" ;;
    esac
    printf '%s %s\n' "$id" "$carry" >> "$TMP/rule-carry"
  done < <(rf_cells "$RF")
  awk '/^## Carry Audit$/ {f = 1; next} /^## / {f = 0} f' "$RF" |
    grep -oE "^- $ID_RE:" | grep -oE "$ID_RE" | tr -d '`' | sort > "$TMP/rule-audit"
  awk '$2 == "file" {print $1}' "$TMP/rule-carry" 2>/dev/null | sort > "$TMP/rule-file"
  while IFS= read -r id; do
    [ "$(grep -cxF "$id" "$TMP/rule-audit")" = 1 ] || fail "rule facts carry" "$RF" "$id is file but has no audit line, or more than one"
  done < "$TMP/rule-file"
  while IFS= read -r id; do
    grep -qxF "$id" "$TMP/rule-file" || fail "rule facts carry" "$RF" "$id has an audit line but its carry value is not file"
  done < "$TMP/rule-audit"
  grep -qxF "rule facts carry" "$TMP/failed" || echo "ok   rule facts carry ($nfile file)"

  # The registry columns, then a negative self-check: each mutation of a temp copy sets one
  # cell and must be reported under the invariant it breaks.
  while IFS=$'\t' read -r inv id detail; do
    fail "rule facts registry" "$RF" "$id $inv $detail"
  done < <(registry_check "$RF")
  setcell() { # file, rule_id, column, value: the file with that one cell replaced
    LC_ALL=C awk -F'|' -v OFS='|' -v id="$2" -v col="$3" -v val="$4" '
      /^\| `rule_id` \|/ { for (i = 2; i < NF; i++) { h = $i; gsub(/[`\040]/, "", h); if (h == col) ci = i } }
      ci && index($0, "| `" id "` |") == 1 { $ci = " " val " " }
      { print }' "$1"
  }
  nmut=0
  while IFS='|' read -r name inv id col val; do
    nmut=$((nmut + 1))
    setcell "$RF" "$id" "$col" "$val" > "$TMP/rf-mut"
    if cmp -s "$TMP/rf-mut" "$RF"; then
      fail "rule facts registry" "$RF" "self-check: $name (the mutation changed nothing)"
    elif ! registry_check "$TMP/rf-mut" | cut -f1 | grep -xF "$inv" >/dev/null; then
      fail "rule facts registry" "$RF" "self-check: $name is not reported as $inv"
    fi
  done <<'EOF'
an engine outside the tiers|engine|structure.missing-description|engine|tools
a class outside the two|class|examples.versions-missing|class|file
a scope no check file uses|scope|structure.argument-order|scope|whole-file
a cross_area that is not yes or no|cross_area|scope.provider|cross_area|maybe
a wrapper area kind|area_kinds|scope.tests|area_kinds|root, wrapper
a repeated area kind|area_kinds|compat.variable-removed|area_kinds|root, root
a bundle section the spec does not list|bundle_sections|coverage.unknown-argument|bundle_sections|candidates, provider-docs
a severity outside the four|severities|profile.title-misspelling|severities|SEVERE
no severity at all|severities|structure.grouping|severities|
a confirm_class on an llm rule|confirm_class|structure.grouping|confirm_class|lead
a candidate rule with no confirm_class|confirm_class|structure.wrong-file|confirm_class|-
a proposed class outside the three|proposed_confirm_class|structure.wrong-file|proposed_confirm_class|tiny
a proposed class on a tool rule|proposed_confirm_class|structure.missing-description|proposed_confirm_class|small
a candidate confirmed below lead before its evaluation|confirm lead|structure.argument-order|confirm_class|mid
a small confirm_class on a rule that can be CRITICAL|critical small|compat.variable-removed|confirm_class|small
a small proposed class on a rule that can be CRITICAL|critical small|coverage.unknown-argument|proposed_confirm_class|small
CRITICAL added to a rule proposed small|critical small|structure.argument-order|severities|CRITICAL, LOW
a registry column renamed in the header|engine|rule_id|engine|tier
EOF
  if ! grep -qxF "rule facts registry" "$TMP/failed"; then
    tiers="$(rf_cells "$RF" | cut -f3 | sort | uniq -c | awk '{printf "%s%s %s", (NR > 1) ? ", " : "", $1, $2}')"
    echo "ok   rule facts registry ($tiers; $nmut mutations caught)"
  fi

  # The engine files: every tool and candidate rule has exactly one level-2 section across
  # references/engine/, every level-2 section there is such a rule, and no llm rule has one.
  # A section's Engine line matches its row, it holds its own Rule text, Confirm when and
  # Host templates headings once each, and its summary and suggested_fix templates are one
  # code span each, hold {subject} and are at most 200 characters as written.
  ENG="$RSK/references/engine"
  engine_check() { # rule facts file, engine directory: one line per problem: invariant, where, detail
    rf_cells "$1" | cut -f1,3 > "$TMP/eng-tiers"
    LC_ALL=C awk -F'\t' -v OFS='\t' -v rf="$1" '
      BEGIN { need["Rule text"]; need["Confirm when"]; need["Host templates"]; tpl["summary"]; tpl["suggested_fix"] }
      FNR == NR { tier[$1] = $2; next }
      function close_sec(   h) {
        if (id == "") return
        if (eng != tier[id]) print "engine line", where, id " says engine " (eng == "" ? "nothing" : eng) ", its row says " tier[id]
        for (h in need) if (head[h] != 1) print "headings", where, id " has " head[h] + 0 " " h " headings, not one"
        for (h in tpl) if (got[h] != 1) print "templates", where, id " has " got[h] + 0 " " h " templates, not one"
        id = ""
      }
      FNR == 1 { close_sec(); fence = 0 }
      # Fenced code is skipped, so a fenced copy of a heading or template cannot stand in for the real one.
      /^ ? ? ?(```|~~~)/ { fence = !fence; next }
      fence { next }
      /^## / {
        close_sec(); where = FILENAME ":" FNR
        if ($0 !~ /^## `[a-z]+\.[a-z0-9-]+`$/) { print "not a rule", where, "the heading is not one rule id: " substr($0, 4); next }
        id = substr($0, 5, length($0) - 5)
        if (!(id in tier)) { print "not a rule", where, id " has no rule facts row"; id = ""; next }
        if (tier[id] == "llm") print "llm section", where, id " is an llm rule"
        seen[id]++; eng = ""; part = ""; split("", head); split("", got); next
      }
      id == "" { next }
      /^Engine: `[a-z]+`$/ { eng = substr($0, 10, length($0) - 10); next }
      /^### / { part = ""; for (h in need) if ($0 == "### " h ": `" id "`") { head[h]++; part = h }; next }
      # A template counts only under its own Host templates heading.
      part == "Host templates" && /^- `(summary|suggested_fix)`: / {
        t = ($0 ~ /^- `summary`/) ? "summary" : "suggested_fix"; got[t]++
        s = substr($0, index($0, ": ") + 2)
        if (s !~ /^`[^`]+`$/) { print "templates", FILENAME ":" FNR, id " " t " is not one code span"; next }
        s = substr(s, 2, length(s) - 2)
        if (index(s, "{subject}") == 0) print "subject", FILENAME ":" FNR, id " " t " has no {subject}"
        if (length(s) > 200) print "template length", FILENAME ":" FNR, id " " t " is " length(s) " characters, over 200"
      }
      END {
        close_sec()
        for (r in tier) if (tier[r] != "llm" && seen[r] != 1)
          print "section", rf, r " is " tier[r] " and has " seen[r] + 0 " engine sections, not one"
      }' "$TMP/eng-tiers" "$2"/*.md
  }
  while IFS=$'\t' read -r inv where detail; do
    fail "engine files" "$where" "$inv: $detail"
  done < <(engine_check "$RF" "$ENG")
  # Negative self-check: each sed script changes one temp copy, an engine file or the rule
  # facts table, and the result must be reported under the invariant it breaks.
  nmut=0
  while IFS='~' read -r name inv target script; do
    nmut=$((nmut + 1))
    rm -rf "$TMP/eng-mut"; cp -R "$ENG" "$TMP/eng-mut"; cp "$RF" "$TMP/rf-mut"
    if [ "$target" = rule-facts.md ]; then t="$TMP/rf-mut"; else t="$TMP/eng-mut/$target"; fi
    sed "$script" "$t" > "$TMP/eng-sed" && cat "$TMP/eng-sed" > "$t"
    if cmp -s "$TMP/rf-mut" "$RF" && diff -r "$TMP/eng-mut" "$ENG" >/dev/null; then
      fail "engine files" "$ENG" "self-check: $name (the mutation changed nothing)"
    elif ! engine_check "$TMP/rf-mut" "$TMP/eng-mut" | cut -f1 | grep -xF "$inv" >/dev/null; then
      fail "engine files" "$ENG" "self-check: $name is not reported as $inv"
    fi
  done <<'EOF'
a tool rule's section dropped~section~check-d-examples.md~/^## `examples.versions-missing`$/d
a section heading renamed to another rule~section~check-d-examples.md~s/^## `examples.submodule-missing`$/## `examples.versions-missing`/
an llm rule with no section turned tool~section~rule-facts.md~/^| `structure.grouping` /s/| llm |/| tool |/
a rule with a section turned llm~llm section~rule-facts.md~/^| `examples.versions-missing` /s/| tool |/| llm |/
a level-2 heading that is no rule id~not a rule~check-d-examples.md~s/^## `examples.submodule-missing`$/## Submodules/
a level-2 heading with no rule facts row~not a rule~check-d-examples.md~s/^## `examples.submodule-missing`$/## `examples.no-such-rule`/
an Engine line that disagrees with the row~engine line~check-d-examples.md~s/^Engine: `tool`$/Engine: `candidate`/
the Rule text heading dropped~headings~check-d-examples.md~/^### Rule text: `examples.versions-missing`$/d
a Confirm when heading naming another rule~headings~check-d-examples.md~s/^### Confirm when: `examples.versions-missing`$/### Confirm when: `examples.submodule-missing`/
the Host templates heading dropped~headings~check-d-examples.md~/^### Host templates: `examples.versions-missing`$/d
the Host templates heading inside a fence~headings~check-d-examples.md~s/^- The example directory has no `versions.tf`.*/```/
a template moved under Rule text~templates~check-d-examples.md~s/^- An example is missing its own `versions.tf`.*/- `summary`: `Example {subject} has no versions.tf.`/;/^- `summary`: `Example {subject} has no versions.tf, or names/d
a suggested_fix template dropped~templates~check-d-examples.md~/^- `suggested_fix`: `Add versions.tf to/d
a template split into two code spans~templates~check-d-examples.md~/has no versions.tf, or names/s/has no versions.tf,/has no `versions.tf`,/
a template without {subject}~subject~check-d-examples.md~/has no versions.tf, or names/s/{subject}/the example/
a template over 200 characters~template length~check-d-examples.md~/has no versions.tf, or names/s/sibling examples\./& & & & & & & & & & & & &/
EOF
  if ! grep -qxF "engine files" "$TMP/failed"; then
    echo "ok   engine files ($(grep -h '^## `' "$ENG"/*.md | wc -l | tr -d ' ') sections; $nmut mutations caught)"
  fi
fi

# The judgment prefix: references/judgment/assemble.sh runs, gives the same bytes twice,
# those bytes are the committed prefix.md, prefix.md is 90 KB (92160 bytes) or less, and
# the run changes no file of the skill, so the full variant stays as written. The links of
# its on-demand reads are checked with every other link above.
JUD=references/judgment
JCAP=92160
judgment_check() { # skill directory: one line per problem: invariant, detail
  local d="$1" before after size
  before="$(cd "$d" && find . -type f -exec cksum {} + | LC_ALL=C sort)"
  if ! bash "$d/$JUD/assemble.sh" > "$TMP/jud-a" 2> "$TMP/jud-err"; then
    printf 'assembles\t%s\n' "$(head -n 1 "$TMP/jud-err")"; return
  fi
  bash "$d/$JUD/assemble.sh" > "$TMP/jud-b" 2> /dev/null
  cmp -s "$TMP/jud-a" "$TMP/jud-b" || printf 'deterministic\ttwo runs of assemble.sh differ\n'
  cmp -s "$TMP/jud-a" "$d/$JUD/prefix.md" ||
    printf 'regenerated\tprefix.md is not what assemble.sh gives; run bash assemble.sh > prefix.md in %s\n' "$JUD"
  size="$(wc -c < "$d/$JUD/prefix.md" | tr -d ' ')"
  [ "$size" -le "$JCAP" ] ||
    printf 'size\tprefix.md is %s bytes, over %s; move a copied section to an on-demand read (On-Demand Reads in workflow.md and drops_of in assemble.sh), or raise the cap only with an owner decision\n' "$size" "$JCAP"
  after="$(cd "$d" && find . -type f -exec cksum {} + | LC_ALL=C sort)"
  [ "$before" = "$after" ] || printf 'sources\tassemble.sh changed a file of the skill\n'
}
while IFS=$'\t' read -r inv detail; do
  fail "judgment prefix" "$RSK/$JUD/prefix.md" "$inv: $detail"
done < <(judgment_check "$RSK")
# Negative self-check: each snippet changes a temp copy of the skill, run from inside it,
# and the result must be reported under the invariant it breaks.
nmut=0
while IFS='~' read -r name inv snippet; do
  nmut=$((nmut + 1))
  rm -rf "$TMP/jm"; cp -R "$RSK" "$TMP/jm"
  ( cd "$TMP/jm" && eval "$snippet" ) > /dev/null 2>&1
  if ! judgment_check "$TMP/jm" | cut -f1 | grep -xF "$inv" > /dev/null; then
    fail "judgment prefix" "$RSK/$JUD" "self-check: $name is not reported as $inv"
  fi
done <<'EOF'
a source edited without regenerating~regenerated~sed 's/^- Release or automation config the profile owns/- Release config the profile owns/' references/check-e-profile.md > s && cat s > references/check-e-profile.md && rm s
prefix.md edited by hand~regenerated~echo extra >> references/judgment/prefix.md
a prefix over the cap~size~printf '%4000s\n' pad >> references/judgment/workflow.md && bash references/judgment/assemble.sh > p && mv p references/judgment/prefix.md
a line the assembly drops reworded in its source~assembles~sed 's/^8[.] If `mtf-facts` is installed/8. When `mtf-facts` is installed/' SKILL.md > s && cat s > SKILL.md && rm s
a section the assembly drops renamed in its source~assembles~sed 's/^## Plan evidence$/## Plan records/' references/check-d-examples.md > s && cat s > references/check-d-examples.md && rm s
an assembler that writes into the skill~sources~sed 's/^export LC_ALL=C$/&; : > "$(dirname "$0")\/stray"/' references/judgment/assemble.sh > s && cat s > references/judgment/assemble.sh && rm s
an assembler whose output varies~deterministic~echo 'echo "$RANDOM$RANDOM"' >> references/judgment/assemble.sh
EOF
if ! grep -qxF "judgment prefix" "$TMP/failed"; then
  echo "ok   judgment prefix ($(wc -c < "$RSK/$JUD/prefix.md" | tr -d ' ') bytes; $nmut mutations caught)"
fi

if [ "$fails" != 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"
