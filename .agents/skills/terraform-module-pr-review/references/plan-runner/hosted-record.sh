#!/bin/bash
# Reduces a finished run-pass.sh record to plan-hosted.json, the one file a hosted plan job
# hands to the review: classes and counts only. Schema and rules: ../plan-pass.md, Hosted
# runner.
#
# Usage: hosted-record.sh --record DIR --head SHA --merge-base SHA --out FILE
#
# It reads plan-pass.txt and plan-refused-hosts.txt from the record, both regular files within
# 5 MiB. It keeps, per host example block, the example path the runner was given, which must
# be examples/<name> (the plan record needs an empty module root prefix), the class
# of its plan: line and, for planned, the three Plan: counts, and the class of its base: line,
# or null when the block has none. Of the refused hosts it keeps the count. No kept line, no
# free text and no host name enters the output. A class outside the fixed list, a path outside
# the safe pattern, a duplicate path, a block with no plan: line, or a record that did not end
# with the runner's summary line is refused: nothing is written, a fixed reason goes to
# standard error, and the exit status is 1. Exit 2 is a usage error.
set -euo pipefail

die() { echo "hosted-record: $1" >&2; exit 2; }
refuse() { echo "hosted-record: refused: $1" >&2; exit 1; }
record="" head="" mb="" out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --record) record="${2:-}"; shift 2 || die "--record needs a value" ;;
    --head) head="${2:-}"; shift 2 || die "--head needs a value" ;;
    --merge-base) mb="${2:-}"; shift 2 || die "--merge-base needs a value" ;;
    --out) out="${2:-}"; shift 2 || die "--out needs a value" ;;
    *) die "unexpected argument" ;;
  esac
done
sha_re='^[0-9a-f]{40}$'
[[ "$head" =~ $sha_re ]] || die "--head must be a 40 character SHA"
[[ "$mb" =~ $sha_re ]] || die "--merge-base must be a 40 character SHA"
[ -n "$record" ] && [ -d "$record" ] && [ ! -L "$record" ] || die "--record must name a directory"
[ -n "$out" ] || die "--out is required"
[ ! -e "$out" ] && [ ! -L "$out" ] || die "--out must not exist yet"
[ -d "$(dirname "$out")" ] || die "--out must be in an existing directory"

IN_CAP=5242880  # run-pass.sh caps every record file at 5 MiB
OUT_CAP=1048576 # host-pass.sh check caps plan-hosted.json at 1 MiB
for f in plan-pass.txt plan-refused-hosts.txt; do
  [ -f "$record/$f" ] && [ ! -L "$record/$f" ] || refuse "$f is not a regular file"
  [ "$(wc -c < "$record/$f")" -le "$IN_CAP" ] || refuse "$f is over the size cap"
done
refused="$(grep -c . "$record/plan-refused-hosts.txt" || true)"

# The fixed lists: what plan-pass.sh writes on a plan: line, with a gate hit reduced to its
# gate, and what it writes on a base: line.
# shellcheck disable=SC2016 # a jq program
REDUCE='
def classes: ["planned", "planned-no-changes", "code-error", "environment", "needs input",
  "output unrecognised", "budget", "plan pass ended: credentials", "plan gate G0", "plan gate G1",
  "plan gate G2", "plan gate G3", "exception: example assumes a role in another account",
  "exception: needs a Docker daemon"];
def base_results: ["reproduces at base", "new under this change",
  "new under this change (absent at base)", "not available"];
def gate: if test("^plan gate G[0-3]( |$)") then .[0:12] else . end;
def head_class: gate | if IN(classes[]) then . else error("refused: a class outside the list") end;
def base_class: gate | if IN(classes[]) or IN(base_results[]) then . else error("refused: a base result outside the list") end;
def counts:
  capture("^Plan: (?:[0-9]+ to import, )?(?<add>[0-9]{1,9}) to add, (?<change>[0-9]{1,9}) to change, (?<destroy>[0-9]{1,9}) to destroy\\.$")
  | map_values(tonumber);
def path_ok: test("^examples/[A-Za-z0-9_][A-Za-z0-9._-]{0,99}$");
def main:
  split("\n") as $l
  | if ($l[0] // "") != "plan pass mode: runner" then error("refused: not a runner record") else . end
  | if ([$l[] | select(length > 0)] | last // "" | test("^plan summary: [0-9]+ examples, ")) | not
    then error("refused: the record has no summary line") else . end
  | reduce $l[] as $x ({blocks: []};
      if $x | startswith("host example ") then
        ($x | capture("^host example (?<n>[1-9][0-9]*): (?<path>.*)$")
          // error("refused: a malformed host example line")) as $h
        | .blocks += [{n: ($h.n | tonumber), path: $h.path, plan: null, base: null}]
      elif (.blocks | length) == 0 then .
      elif ($x | startswith("plan: ")) and .blocks[-1].plan == null then .blocks[-1].plan = $x[6:]
      elif ($x | startswith("base: ")) and .blocks[-1].base == null then .blocks[-1].base = $x[6:]
      else . end)
  | .blocks
  | if [.[].n] != [range(1; length + 1)] then error("refused: host example lines out of order") else . end
  | if all(.[]; .path | path_ok) | not then error("refused: an example path outside the pattern") else . end
  | if (map(.path) | unique | length) != length then error("refused: a duplicate example path") else . end
  | map(
      if .plan == null then error("refused: a block with no plan line") else . end
      | (.plan | split(" | ")[0] | head_class) as $c
      | {path,
         head: {class: $c, plan: (if $c == "planned" then (.plan | split(" | ")[1:] | join(" | ") | counts) // null else null end)},
         base: (if .base == null then null else {class: (.base | base_class), plan: null} end)})
  | {schema_version: 1, head: $head, merge_base: $mb, refused_hosts: $refused, examples: .};
try main catch (if type == "string" and startswith("refused: ") then . else "refused: a malformed record" end)
'
result="$(jq -R -s -c --arg head "$head" --arg mb "$mb" --argjson refused "$refused" "$REDUCE" \
  "$record/plan-pass.txt")" || refuse "a malformed record"
case "$result" in
  '"refused: '*) refuse "$(jq -r '.[9:]' <<< "$result")" ;;
esac
[ "${#result}" -lt "$OUT_CAP" ] || refuse "the output is over the size cap"
tmp="$(mktemp "$(dirname "$out")/.plan-hosted.XXXXXX")"
printf '%s\n' "$result" > "$tmp"
mv "$tmp" "$out"
