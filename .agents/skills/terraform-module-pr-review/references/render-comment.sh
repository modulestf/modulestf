#!/bin/bash
# render-comment.sh: the host renders the review of a pull request from the merged findings,
# with no model: the verdict by the ladder in verdict.md, the body by comment-format.md, and
# the three files of render-output.md. The pure rules are in render-comment.jq. Invoke it by an
# absolute path in the host's own checkout of this repository pinned by commit; never from the
# head or the workspace.
#
#   render-comment.sh --head <sha> --findings <file> --host <host.json> --checks <dir>
#       --run <file> --assessment <file> --run-dir <dir> --out <dir>
#
#   --findings    the merged findings, modulestf/facts schema/merged-findings.schema.json, with
#                 paths relative to the module root
#   --host        host.json from host-pass.sh run, checked against --head
#   --checks      the directory host-pass.sh checks wrote, checked with host-pass.sh check; a
#                 rejected one makes the Checks signal unknown and says so
#   Compatibility: this version requires the run file's coverage key and checks plan-hosted.json
#   with addresses and attributes per example; a host that pins this repository must move its
#   render, its host records and its plan job to the same commit (host-pass.md, Compatibility).
#   --run         this run's own facts, one object with exactly these keys:
#                 {"format": 1, "triage": bool, "plan_ran": bool,
#                  "verify_gaps": [{"dir": "<repository-relative>", "reason": "<fixed reason>"}],
#                  "coverage": {"class": "complete|partial|none", "inert": bool,
#                               "unplanned": [{"dir": "<repository-relative>", "reason": "<fixed reason>"}]},
#                  "counts": {"instruction-like-text-from-others": n,
#                             "conversation-claims-unread": n, "review.quoted-claim-unverifiable": n}}
#                 counts is null when the reviewer gave none, never 0 in their place: section 8
#                 then says "Counts: not reported by the review run." (host-pass.md, Host Facts)
#                 Section 5 lists the first 100 verify_gaps and one line counting the rest, then
#                 the first 100 unplanned examples and one line counting the rest; the verdict
#                 counts them all. coverage comes from verify-pass.sh coverage; an unplanned
#                 example is an unknown at ladder rule 4. The file's size cap bounds how many
#                 there can be.
#   --assessment  section 1, the one part the model writes: printable ASCII, at most two short
#                 paragraphs, no line that starts like a heading, a bold line, HTML or a list item
#   --run-dir     the run directory, which the leak scan looks for and --out must lie outside
#   --out         an existing directory holding none of the files written
#
# Writes comment.md, findings.json and result.json, in that order, result.json last by a rename,
# and prints "rendered <verdict> (ladder rule <n>), proposed event <EVENT>". Exit 2 is a usage
# error or a refused input, and nothing is written. Exit 1 is a leak scan match or a bare
# at-mention left after the wrap, and nothing is written, or a failed write, which leaves what
# was written and no result.json.
# The leak scan's runner-mode search for code-error kept lines is not done here: the hosted plan
# record, plan-hosted.json, carries no kept lines.
set -uo pipefail
set -f

HERE="$(cd "$(dirname "$0")" && pwd -P)"
CAP=1048576
CAP_SMALL=65536
sha_re='^[0-9a-f]{40}$'

die() { echo "render-comment.sh: $1" >&2; exit 2; }
stop() { echo "render-comment.sh: $1" >&2; exit 1; }

head="" findings="" host="" checks="" run="" assessment="" rundir="" out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --head) head="${2-}"; shift 2 || die "--head needs a value" ;;
    --findings) findings="${2-}"; shift 2 || die "--findings needs a value" ;;
    --host) host="${2-}"; shift 2 || die "--host needs a value" ;;
    --checks) checks="${2-}"; shift 2 || die "--checks needs a value" ;;
    --run) run="${2-}"; shift 2 || die "--run needs a value" ;;
    --assessment) assessment="${2-}"; shift 2 || die "--assessment needs a value" ;;
    --run-dir) rundir="${2-}"; shift 2 || die "--run-dir needs a value" ;;
    --out) out="${2-}"; shift 2 || die "--out needs a value" ;;
    *) die "unexpected argument" ;;
  esac
done
[[ "$head" =~ $sha_re ]] || die "--head must be a 40 character SHA"

input() { # name, path, cap
  [ -n "$2" ] || die "$1 is required"
  [ -f "$2" ] && [ ! -L "$2" ] || die "$1 is not a regular file"
  [ "$(wc -c < "$2")" -le "$3" ] || die "$1 is over the size cap"
}
input --findings "$findings" "$CAP"
input --host "$host" "$CAP"
input --run "$run" "$CAP_SMALL"
input --assessment "$assessment" 4096
for v in "$checks" "$rundir" "$out"; do
  case "$v" in /?*) ;; *) die "--checks, --run-dir and --out must be absolute paths" ;; esac
done
[ -d "$rundir" ] || die "--run-dir is not a directory"
RUN="$(cd -- "$rundir" && pwd -P)" || die "--run-dir cannot be read"
OUT="$(cd -- "$out" && pwd -P)" || die "--out is not an existing directory"
[ -d "$out" ] && [ ! -L "$out" ] || die "--out is not an existing directory"
case "$OUT/" in "$RUN"/*) die "--out lies in the run directory" ;; esac
for f in comment.md findings.json result.json result.json.tmp; do
  [ ! -e "$OUT/$f" ] && [ ! -L "$OUT/$f" ] || die "--out already holds $f"
done

RJ() { jq -L "$HERE" "$@"; }
one() { RJ -e --slurp --arg head "$head" "include \"$2\"; length == 1 and (.[0] | $3)" "$1" > /dev/null 2>&1; }
one "$findings" render-comment valid_findings || die "the findings do not fit the merged findings schema"
one "$host" host-records 'valid_host($head)' || die "host.json is not valid for this head"
one "$run" render-comment valid_run || die "the run file does not fit its grammar"
RJ -e -R --slurp 'include "render-comment"; valid_assessment' "$assessment" > /dev/null 2>&1 \
  || die "the assessment is not printable ASCII text"

# The Checks signal: the checks file when host-pass.sh accepts it, else unknown (host-pass.md).
if [ "$(bash "$HERE/host-pass.sh" check "$checks" --head "$head" 2> /dev/null)" = "checks accepted" ]; then
  cj="$(jq -c '{accepted: true, signal, own_check, own_check_dropped, own_jobs_dropped, own_jobs_unreadable}' \
    "$checks/checks.json")" || die "the checks file cannot be read"
else
  cj='{"accepted": false, "signal": "unknown"}'
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/render-comment.XXXXXX")" || die "no temporary directory"
trap 'rm -rf "$TMP"' EXIT

# The named set of comment-format.md, Leak Scan. Values that are empty or the root would match
# everything, so they are left out.
lits="$(jq -n --arg run "$RUN" --arg home "${HOME-}" --arg pwd "${PWD-}" --arg tmp "${TMPDIR-}" '
  [ {name: "the run directory", v: $run}, {name: "HOME", v: $home}, {name: "PWD", v: $pwd},
    {name: "TMPDIR", v: $tmp} ] | map(select(.v != "" and .v != "/"))
  + [ "/home/", "/Users/", "/tmp/", "/var/folders/", "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_"
      | {name: ., v: .} ]
  + [ $ENV | to_entries[] | select((.key | test("TOKEN|KEY|SECRET|PASSWORD|PAT")) and (.value | length >= 12))
      | {name: "the value of \(.key)", v: .value} ]')" || die "the leak scan set cannot be built"

RJ -n --slurpfile f "$findings" --slurpfile h "$host" --slurpfile r "$run" --rawfile a "$assessment" \
  --argjson c "$cj" --argjson lits "$lits" '
  include "render-comment";
  ($a | sub("\n+$"; "")) as $text
  | render({findings: $f[0], host: $h[0], checks: $c, run: $r[0], assessment: $text}) as $o
  | (if $r[0].plan_ran then
       [ "(AKIA|ASIA)[A-Z0-9]{16}", "eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+", "-----BEGIN", "X-Amz-Signature",
         "Authorization:" ] | map({name: ., v: .})
     else [] end) as $res
  | $o + {leak: leak_hit($o.parts; $lits; $res)}
  | .body |= wrap_mentions
  | .mention_left = (.body | bare_mention)
  | del(.parts)' > "$TMP/render.json" || die "the render failed"

leak="$(jq -r 'if .leak then "\(.leak.pattern) in \(.leak.src)" else "" end' "$TMP/render.json")"
[ -z "$leak" ] || stop "leak scan: $leak; nothing written"
[ "$(jq -r '.mention_left' "$TMP/render.json")" = false ] || stop "an at-mention is left outside a code span; nothing written"

# render-output.md: comment.md, then findings.json checked, then result.json by a checked rename.
jq -j '.body' "$TMP/render.json" > "$OUT/comment.md" || stop "writing comment.md failed"
jq '.findings' "$TMP/render.json" > "$OUT/findings.json" \
  && jq -e 'type == "array" and all(.[]; keys == ["file","id","line","rule_id","severity","suggested_fix","summary"])' \
    "$OUT/findings.json" > /dev/null || stop "writing findings.json failed"
jq --slurpfile h "$host" '{target: "\($h[0].repo)#\($h[0].number)", number: $h[0].number,
    head_sha: $h[0].head_sha, base_sha: $h[0].base_sha, verdict, proposed_event: .event}' \
    "$TMP/render.json" > "$OUT/result.json.tmp" \
  && jq -e 'keys == ["base_sha","head_sha","number","proposed_event","target","verdict"]' \
    "$OUT/result.json.tmp" > /dev/null \
  && mv -- "$OUT/result.json.tmp" "$OUT/result.json" || stop "writing result.json failed"

jq -r '"rendered \(.verdict) (ladder rule \(.rule)), proposed event \(.event)"' "$TMP/render.json"
