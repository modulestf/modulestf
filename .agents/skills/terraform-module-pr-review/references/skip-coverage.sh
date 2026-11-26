#!/usr/bin/env bash
# shellcheck disable=SC2016 # the jq programs below are single-quoted on purpose
# The covered skip of terraform-module-pr-review: which examples skipped by a plan gate, kept
# by a recorded exception, or denied a data source read under the review role or refused a host
# by the runner's plan proxy by design (a design skip) are covered by the plan of other examples,
# as one file. Rules and reasons: skip-coverage.md.
# Runs the same under bash and zsh. Invoke it by an absolute path in the skill as installed,
# never from the head or the workspace:
#
#   <bash|zsh> /abs/path/skip-coverage.sh gates <run-dir> --tree <dir> --base <sha> \
#       --coverage <coverage.json> --out <file> [--mode laptop|runner]
#       The base gate record: for every unplanned example directory in <coverage.json>, the
#       clone scope plan-pass.sh gives in <dir>, a worktree at <sha>, and the per-file gates
#       plan-pass.sh runs over it. Writes <file> complete or not at all. Exit 3 when the
#       clone does not hold <sha>: the caller fetches the merge base first.
#   <bash|zsh> /abs/path/skip-coverage.sh check <run-dir> --files <files.json> \
#       --coverage <coverage.json> --plan <record> --head <sha> --base <sha|unresolved> \
#       --changed-files <n> [--addresses <dir>] [--base-gates <file>] [--prefix <module-root>]
#       [--mode laptop|runner]
#       Prints one JSON object: the covered and the uncovered unplanned directories
#       (skip-coverage.md, Output). Never runs terraform and never reads the network.
#   --mode runner covers the recorded exceptions of a runner-mode pass instead of the laptop gate
#   skips (skip-coverage.md, Recorded exceptions); laptop is the default. Both modes decide the
#   design skips (skip-coverage.md, Design skips).
#
# <run-dir> is the absolute run directory Workspace printed, "<root>/pr-review.XXXXXX", holding
# the clone at head at <run-dir>/clone. Exit 2 is a usage error or a refused input.

CMD=${1:-}
RUN=${2:-}
die() { echo "skip-coverage.sh: $1" >&2; exit 2; }
case "$CMD" in gates|check) ;; *) die "usage: skip-coverage.sh gates|check <run-dir> ..." ;; esac
ROOT="${RUN%/*}"
case "$ROOT" in /?*) ;; *) die "the run directory must be absolute" ;; esac
case "$RUN" in "$ROOT"/pr-review.??????) ;; *) die "not a run directory: $RUN" ;; esac
[ -d "$RUN/clone" ] || die "no clone in $RUN"
shift 2
HERE="$(cd "$(dirname "$0")" && pwd -P)"
PP="$HERE/plan-pass.sh"
[ -f "$PP" ] || die "no plan-pass.sh beside this script"

FILES=; COV=; PLANREC=; ADDRS=; BGATES=; HEADSHA=; BASESHA=; PREFIX=; TREE=; OUT=; NCHANGED=; MODE=laptop
while [ $# -gt 0 ]; do
  case "$1" in
    --files) FILES=${2:-} ;;
    --changed-files) NCHANGED=${2:-} ;;
    --coverage) COV=${2:-} ;;
    --plan) PLANREC=${2:-} ;;
    --addresses) ADDRS=${2:-} ;;
    --base-gates) BGATES=${2:-} ;;
    --head) HEADSHA=${2:-} ;;
    --base) BASESHA=${2:-} ;;
    --prefix) PREFIX=${2:-} ;;
    --tree) TREE=${2:-} ;;
    --out) OUT=${2:-} ;;
    --mode) MODE=${2:-} ;;
    *) die "unknown argument: $1" ;;
  esac
  [ $# -ge 2 ] || die "$1 needs a value"
  shift 2
done

case "$MODE" in laptop|runner) ;; *) die "--mode must be laptop or runner" ;; esac

sha_ok() { # a full lowercase commit SHA, one line, nothing else
  [ "${#1}" -eq 40 ] || return 1
  case "$1" in *[!0-9a-f]*) return 1 ;; esac
  return 0
}
regular() { # name, path: a regular file, not a link, at most 5 MiB
  [ -f "$2" ] && [ ! -L "$2" ] && [ "$(wc -c < "$2")" -le 5242880 ] || die "$1 must name a regular file of at most 5 MiB"
}

W="$(mktemp -d "${TMPDIR:-/tmp}/pr-review.XXXXXX")" || die "no temporary directory"
trap 'rm -rf -- "$W"' EXIT
trap 'rm -rf -- "$W"; exit 130' INT TERM

regular --coverage "$COV"
# The unplanned example directories, once each, in order: data only
jq -r 'if type == "object" and (.unplanned | type == "array") then
         [.unplanned[] | .dir | select(type == "string" and test("^[A-Za-z0-9._/-]{1,300}$"))] | unique[]
       else error("not a coverage object") end' "$COV" > "$W/dirs.txt" 2> /dev/null \
  || die "--coverage is not a plan coverage object"

# The gate record of one tree: per directory its clone scope and the per-file gate hits, both
# from plan-pass.sh, the same two functions the plan pass ran, paths relative to the tree and
# hits without their line, which a change elsewhere in a shared file moves. plan-pass.sh is
# pointed at the tree through a run directory of its own whose clone is a link to the tree.
# In runner mode the gates are the runner's, and its exception hits, Xrole and Xdocker, are kept
# beside the gate hits; the header names the mode, so a record of one mode never stands for the other.
record_gates() { # tree, sha: the record on standard output; non-zero when a step failed
  f="$(mktemp -d "$W/pr-review.XXXXXX")" || return 1
  ln -s "$1" "$f/clone" || return 1
  t="$(cd "$1" && pwd -P)" || return 1
  if [ "$MODE" = runner ]; then echo "skip-gates 1 $2 runner"; else echo "skip-gates 1 $2"; fi
  while IFS= read -r d; do
    echo "dir $d"
    if [ -d "$t/$d" ]; then
      r="$(cd "$t/$d" && pwd -P)" || return 1
      case "$r" in "$t") echo "real ." ;; "$t"/*) echo "real ${r#"$t"/}" ;; *) echo "real $r" ;; esac
      s="$(bash "$PP" scope "$f" "$t/$d")" || return 1
      printf '%s\n' "$s" | awk -v r="$t/" 'NF { if (index($0, r) == 1) print "file " substr($0, length(r) + 1); else print "file " $0 }'
      printf '%s\n' "$s" | bash "$PP" gates "$f" "$MODE" clone "$t/$d" | awk -v r="$t/" -v m="$MODE" '
        $1 ~ /^G[0-3]$/ || (m == "runner" && $1 ~ /^X(role|docker)$/) {
          g = $1; p = substr($0, length(g) + 2); sub(/:[^:]*$/, "", p); if (index(p, r) == 1) p = substr(p, length(r) + 1)
          print "hit " g " " p }' | sort
    else
      echo "file MISSING"
    fi
    echo "done $d"
  done < "$W/dirs.txt"
  echo end
}

if [ "$CMD" = gates ]; then
  sha_ok "$BASESHA" || die "--base must be a full commit SHA"
  case "$TREE" in /?*) ;; *) die "--tree must be an absolute path" ;; esac
  [ -d "$TREE" ] || die "--tree must name a directory"
  case "$OUT" in /?*) ;; *) die "--out must be an absolute path" ;; esac
  [ -d "${OUT%/*}/" ] || die "the directory of --out must exist"
  # The merge base must be in the clone: a worktree cannot be added for a commit never fetched
  git -C "$RUN/clone" cat-file -e "$BASESHA^{commit}" 2> /dev/null \
    || { echo "skip-coverage.sh: the base commit is not in the clone; fetch it first" >&2; exit 3; }
  [ "$(git -C "$TREE" rev-parse --verify 'HEAD^{commit}' 2> /dev/null)" = "$BASESHA" ] || die "--tree is not at --base"
  record_gates "$TREE" "$BASESHA" > "$OUT.tmp" || { rm -f -- "$OUT.tmp"; die "the gates did not run"; }
  mv -- "$OUT.tmp" "$OUT" || die "cannot write $OUT"
  exit 0
fi

# --- check
sha_ok "$HEADSHA" || die "--head must be a full commit SHA"
[ "$BASESHA" = unresolved ] || sha_ok "$BASESHA" || die "--base must be a full commit SHA or unresolved"
regular --files "$FILES"
regular --plan "$PLANREC"
printf '%s\n' "$NCHANGED" | grep -Eqx '[0-9]{1,6}' || die "--changed-files must be the pull request's changed file count"
PREFIX="${PREFIX%/}"
case "$PREFIX" in /*|*..*|.) die "--prefix must be repository-relative" ;; esac
[ -n "$PREFIX" ] && PREFIX="$PREFIX/"
jq -e 'type == "array" and all(.[]; type == "object" and (.filename | type == "string") and (.status | type == "string")
  and ([.filename, .previous_filename // ""][] | test("[\\x00-\\x1f\\x7f]") | not))' "$FILES" > /dev/null 2>&1 \
  || die "--files is not a JSON array of file objects"

CLONE="$(cd "$RUN/clone" && pwd -P)"
# A merge base the clone does not hold cannot be resolved here: --base unresolved, in effect
[ "$BASESHA" = unresolved ] || git -C "$CLONE" cat-file -e "$BASESHA^{commit}" 2> /dev/null || BASESHA=unresolved
HEADOK=false
[ "$(git -C "$CLONE" rev-parse --verify 'HEAD^{commit}' 2> /dev/null)" = "$HEADSHA" ] && HEADOK=true

# The facts engine's changes report (skip-coverage.md, The facts engine): the first mtf-facts on
# PATH from an absolute entry, every link resolved and outside the run directory, whose
# version --json lists the feature cmd:changes and changes report version 1. It rebuilds the base
# from --files and reads both sides with the HCL parser. A missing, old, failing, late or
# oversized engine leaves the report null: no .tf file is then allowed and no directory declares
# a data source type.
FACTS_TIMEOUT=${SKIP_COVERAGE_FACTS_TIMEOUT:-120}
FACTS_CAP=16777216
facts_bin() {
  local f d
  f="$(printf '%s\n' "$PATH" | tr ':' '\n' | while IFS= read -r d; do
         case "$d" in /?*) [ -f "$d/mtf-facts" ] && [ -x "$d/mtf-facts" ] && { printf '%s\n' "$d/mtf-facts"; break; } ;; esac
       done)"
  [ -n "$f" ] || return 0
  f="$(perl -MCwd=abs_path -e 'print abs_path(shift) // ""' "$f")"
  case "$f/" in "$RUN"/*|"$CLONE"/*|/) return 0 ;; esac
  printf '%s' "$f"
}
run_facts() { # output file, arguments: 0 when mtf-facts exited 0 within the deadline and the cap
  local o="$1"; shift
  { (cd "$W" && exec perl -e 'alarm shift; exec @ARGV or exit 127' "$FACTS_TIMEOUT" "$FACTS" "$@") 2> /dev/null
    echo "$?" > "$W/rc"; } | head -c $((FACTS_CAP + 1)) > "$o"
  [ "$(cat "$W/rc")" = 0 ] && [ "$(wc -c < "$o")" -le "$FACTS_CAP" ]
}
FACTS="$(facts_bin)"
echo null > "$W/changes.json"
if [ -n "$FACTS" ] && run_facts "$W/version.json" version --json \
  && jq -e '(.features | index("cmd:changes")) != null and .reports.changes == 1' "$W/version.json" > /dev/null 2>&1 \
  && run_facts "$W/changes.out" changes "$CLONE" --diff "$FILES" --json --timeout "${FACTS_TIMEOUT}s" \
  && jq -e 'type == "object" and .schema_version == 1 and (.files | type == "array") and (.data_sources | type == "array")' \
       "$W/changes.out" > /dev/null 2>&1; then
  mv -- "$W/changes.out" "$W/changes.json"
fi

# Per changed file one JSON line {file, dir, ok, attrs}: a modified *.md is allowed with no
# attribute; a modified .tf at the module root or under modules/ is allowed when the report gives
# it parsed and modified with no change outside attribute values, and every block it changed is
# an edited resource or data block with two labels, no structural edit and only changed attributes
# that are plain at both sides (skip-coverage.md, The allow-list); the report gives a change of
# count, for_each, provider or depends_on as a structural edit. Anything else is not allowed.
: > "$W/classes.jsonl"
jq -c --arg pre "$PREFIX" '.[] | {f: .filename, s: .status, prev: (.previous_filename // null),
    kind: (if .filename | test("\\.md$") then "md"
           elif (.filename | startswith($pre)) and (.filename[($pre | length):] | test("^([^/]+|modules/.+)\\.tf$"))
             and (.filename[($pre | length):] | test("(^|/)(examples|wrappers)/") | not) then "tf"
           else "other" end)}' "$FILES" > "$W/files.jsonl" || die "--files cannot be read"
while IFS= read -r row; do
  f="$(printf '%s\n' "$row" | jq -r .f)"
  kind="$(printf '%s\n' "$row" | jq -r 'if .s != "modified" or .prev != null then "other" else .kind end')"
  ok=false
  case "$kind" in
    md)
      # A document a .tf file names, by its file name, may be read by Terraform: not allowed
      grep -rqF --include='*.tf' --exclude-dir=.git -- "${f##*/}" "$CLONE" 2> /dev/null; [ $? = 1 ] && ok=true ;;
  esac
  jq -c --arg f "$f" --arg kind "$kind" --argjson mdok "$ok" '
    (if $kind == "tf" then first(.files[]? | select(.path == $f)) // null else null end) as $e
    | (if $kind == "md" then {ok: $mdok, attrs: []}
       elif $e != null and $e.status == "modified" and $e.parsed == true and $e.outside == false and ($e.blocks | length) > 0
         and all($e.blocks[]; .status == "edited" and .structural == false and (.attributes | length) > 0
           and ((.kind == "resource" and (.address | test("^[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$")))
             or (.kind == "data" and (.address | test("^data\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$"))))
           and all(.attributes[]; .plain.head == true and .plain.base == true))
       then {ok: true, attrs: [$e.blocks[] | .address as $a | .attributes[] | {address: $a, attribute: .name}]}
       else {ok: false, attrs: []} end)
    | {file: $f, dir: ($f | if test("/") then sub("/[^/]*$"; "") else "." end)} + .' "$W/changes.json" >> "$W/classes.jsonl"
done < "$W/files.jsonl"

# The changed attributes some expression of the module reads (skip-coverage.md, Design skips):
# each "<address> <attribute>" pair the report does not give as unread.
jq -r '.files[]?.blocks[]? | .address as $a | .attributes[] | select(.read != "unread") | "\($a) \(.name)"' \
  "$W/changes.json" | sort -u > "$W/refs.txt"

# The data source types of each refused-host example directory (skip-coverage.md, Design skips):
# one {dir: [type]} line per directory, the report's types when it read every file there, none
# otherwise; the report lists no directory reached through a link.
: > "$W/types.jsonl"
if [ "$MODE" = runner ]; then
  jq -r '.unplanned[] | select(.reason == "environment (refused-host)") | .dir
    | select(type == "string" and test("^[A-Za-z0-9._/-]{1,300}$") and (split("/") | index("..") == null))' "$COV" | sort -u |
  while IFS= read -r d; do
    jq -c --arg d "$d" '{($d): (first(.data_sources[]? | select(.dir == $d and .complete == true) | .types) // [])}' \
      "$W/changes.json" >> "$W/types.jsonl"
  done
fi

# The witness records: addresses-<n>.json from --addresses, data only, as the plan coverage reads them
: > "$W/addr.jsonl"
if [ -n "$ADDRS" ] && [ -d "$ADDRS" ] && [ ! -L "$ADDRS" ]; then
  for af in "$ADDRS"/addresses-*.json; do
    an="${af##*/addresses-}"; an="${an%.json}"
    printf '%s\n' "$an" | grep -Eqx '[1-9][0-9]{0,5}' || continue
    [ -f "$af" ] && [ ! -L "$af" ] && [ "$(wc -c < "$af")" -le 1048576 ] || continue
    jq -c --arg n "$an" '{($n): .}' "$af" >> "$W/addr.jsonl" 2> /dev/null || true
  done
fi

# The gate records: the head computed now over the clone, the base read from --base-gates
HEADGATES=; BASEGATES=
if [ "$HEADOK" = true ]; then HEADGATES="$(record_gates "$CLONE" "$HEADSHA")" || HEADGATES=; fi
if [ -n "$BGATES" ] && [ -f "$BGATES" ] && [ ! -L "$BGATES" ] && [ "$(wc -c < "$BGATES")" -le 5242880 ]; then
  BASEGATES="$(cat "$BGATES")"
fi

jq -n -L "$HERE" --slurpfile cov "$COV" --slurpfile cls "$W/classes.jsonl" --slurpfile a "$W/addr.jsonl" --slurpfile types "$W/types.jsonl" \
  --rawfile rec "$PLANREC" --rawfile refs "$W/refs.txt" --arg hg "$HEADGATES" --arg bg "$BASEGATES" --arg mode "$MODE" \
  --arg head "$HEADSHA" --arg base "$BASESHA" --argjson headok "$HEADOK" --argjson nchanged "$NCHANGED" \
  --slurpfile files "$FILES" '
  include "skip-coverage";
  ($refs | split("\n") | map(select(length > 0))) as $r
  | if $mode == "runner" then skip_coverage_runner($cov[0]; $files[0]; $cls; ($a | add // {}); $rec; $hg; $bg; $head; $base; $headok; $nchanged; $r; ($types | add // {}))
  else skip_coverage($cov[0]; $files[0]; $cls; ($a | add // {}); $rec; $hg; $bg; $head; $base; $headok; $nchanged; $r) end
' || die "cannot evaluate"
exit 0
