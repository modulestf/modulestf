#!/bin/bash
# merge-run.sh: the deterministic steps of terraform-module-pr-merge as commands. The order is in
# workflow.md; the shared decisions are the functions of pr-review's stage-contract.jq.
# Invoke it with bash by an absolute path in this skill's own checkout, never from the head.
#
#   merge-run.sh prepare --repo <owner/name> --pr <number> --out <dir>
#       identity, the run directory under <dir> and its empty review directory
#   merge-run.sh gate <run>        the plan, its pin, the live merge preconditions, the show
#   merge-run.sh merge <run> --target <owner/name#number> --confirm-head <40 hex>
#       the confirmed values, every gate read again, then one PUT of the merge
#   merge-run.sh cleanup <run>     deletes the run directory
#
# Every command prints at most 30 lines. Host strings travel in files and through jq, never through
# eval. Exit 0 done, 1 a refusal with its reason printed, 2 a usage error. No git call, and no write
# but the one merge, which is never retried.
set -uo pipefail
set -f
umask 077

HERE="$(cd "$(dirname "$0")" && pwd -P)"
PRR="$(cd "$HERE/../../terraform-module-pr-review/references" 2> /dev/null && pwd -P)" || PRR=/nonexistent
repo_re='^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$'
sha_re='^[0-9a-f]{40}$'

die() { echo "merge-run.sh: $1" >&2; exit 2; }
fail() { echo "merge-run.sh: $1"; exit 1; }
J() { jq -L "$PRR" "$@"; } # jq with stage-contract.jq; a filter that uses it starts with include "stage-contract";
oneline() { head -n 1 | tr -d '\000-\037\177' | cut -c1-200; }

# get <name> <endpoint> [pages|runs]: one REST read into $RAW/<name>.json; a failure writes null.
get() {
  local f="$RAW/$1.json" rc=0
  case "${3-}" in
    pages) gh api --paginate --slurp "$2" 2> /dev/null | jq -c 'add // []' > "$f" 2> /dev/null || rc=1 ;;
    runs) gh api --paginate --slurp "$2" 2> /dev/null | jq -c 'map(.check_runs) | add // []' > "$f" 2> /dev/null || rc=1 ;;
    *) gh api "$2" > "$f" 2> /dev/null || rc=1 ;;
  esac
  if [ "$rc" != 0 ] || ! jq -e 'type == "object" or type == "array"' "$f" > /dev/null 2>&1; then
    echo null > "$f"; return 1
  fi
}

# identity: a person's token, no CI, write access or more on the base repository.
identity() {
  [ -z "${CI+x}${GITHUB_ACTIONS+x}${GITHUB_RUN_ID+x}" ] || fail "identity refused: a CI variable is set"
  get user user || fail "identity refused: the token user cannot be read"
  jq -e '.type == "User" and (.login | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$"))' "$RAW/user.json" > /dev/null ||
    fail "identity refused: the token user is not a person"
  LOGIN="$(jq -r .login "$RAW/user.json")"
  [ -z "${BOUND-}" ] || [ "$LOGIN" = "$BOUND" ] || fail "identity refused: the token user is not the one that prepared this run"
  get perm "repos/$REPO/collaborators/$LOGIN/permission" || fail "identity refused: the permission of $LOGIN cannot be read"
  PERM="$(jq -r '.permission // ""' "$RAW/perm.json")"
  case "$PERM" in write | maintain | admin) ;; *) fail "identity refused: $LOGIN has no write access to $REPO" ;; esac
}

# The merge precondition of workflow.md, Step 3, as one function: the first refusal, or null, and
# the values the merge will use.
DECIDE='include "stage-contract";
def clean: explode | map(if . < 32 or . == 127 then 32 else . end) | implode | .[0:300];
def word: if type == "string" and test("^[a-z_ ]{1,40}$") then . else "unreadable" end;
def iso_time: if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") then (try fromdateiso8601 catch null) else null end;
$pr[0] as $p | $plan[0] as $pl | $repo[0] as $r
| ({pr: $p, merge_base: ($cmp[0].merge_base_commit.sha // null)} | live_pin) as $live
| ({ok: $cok, runs: ($runs[0] // []), statuses: ($st[0] // []), pinned_total: null} | checks_class) as $c
| ([($rv[0] // [])[] | select(.author_association | IN("OWNER", "MEMBER", "COLLABORATOR"))
    | select(.state | IN("APPROVED", "CHANGES_REQUESTED", "DISMISSED"))]
   | group_by(.user.id) | map(max_by(.id)) | map(select(.state == "CHANGES_REQUESTED") | .user.login | tostring | clean)) as $blocking
| ([if $rv[0] == null then "reviews" else empty end, if $r == null then "repository" else empty end]) as $failed
| {refusal:
    (if $p == null then "a read failed: pr"
     elif ($pl | stage_ok("review-plan")) | not then "the plan is not a review-plan stage file of schema 1"
     elif ($pl.read_at | iso_time) == null or ($started | iso_time) == null or ($pl.read_at | iso_time) < ($started | iso_time) then "the plan is not this run\u0027s review"
     elif $cmp[0] == null then "a read failed: compare"
     elif ($pl.pin | pin_diff($live)) != null then "the pull request moved since the review: \($pl.pin | pin_diff($live))"
     elif ($failed | length) > 0 then "a read failed: \($failed | join(", "))"
     elif ($pl.verdict | IN("approve", "approve with nits")) | not then "the verdict is \($pl.verdict | word), not approve or approve with nits"
     elif $c.class != "passing" then "the checks are not passing: \($c.reason | clean)"
     elif $p.state != "open" or $p.merged != false then "the pull request is not open"
     elif $p.draft != false then "the pull request is a draft"
     elif $p.locked != false then "the pull request is locked"
     elif $p.mergeable_state != "clean" then "mergeable_state is \($p.mergeable_state | word), not clean"
     elif ($blocking | length) > 0 then "a write-capable reviewer requests changes: \($blocking | .[0:5] | join(", "))"
     elif $r.allow_squash_merge != true then "the repository does not allow squash merges"
     elif ($p.title | type) != "string" then "the title cannot be read"
     else null end),
   merge: (if $p == null or $pl == null then null
           else ($p.title | if type == "string" then commit_title($p.number) else {title: null, cut: false} end) as $t
           | {pin: $pl.pin, verdict: $pl.verdict, checks: ($c.reason | clean), title: $t.title, cut: $t.cut, method: "squash"} end)}'

# live <dir>: identity, the plan and every live read into $RUN/<dir>, the decision into its decision.json.
live() {
  RAW="$RUN/$1"
  mkdir "$RAW" 2> /dev/null || fail "$1 ran already in this run; start a new run"
  identity
  local p="$RUN/review/plan.json" hsha bsha cok=false
  if [ -f "$p" ] && [ ! -L "$p" ] && [ "$(wc -c < "$p")" -le 4194304 ] && jq -e . "$p" > /dev/null 2>&1; then cp "$p" "$RAW/plan.json"
  else fail "the plan is not a regular file of at most 4 MiB at $p"; fi
  get pr "repos/$REPO/pulls/$NUM"
  hsha="$(jq -r '.head.sha // ""' "$RAW/pr.json")"; bsha="$(jq -r '.base.sha // ""' "$RAW/pr.json")"
  if [[ "$hsha" =~ $sha_re ]] && [[ "$bsha" =~ $sha_re ]]; then get compare "repos/$REPO/compare/$bsha...$hsha"
  else echo null > "$RAW/compare.json"; fi
  if [[ "$hsha" =~ $sha_re ]]; then
    get runs "repos/$REPO/commits/$hsha/check-runs?per_page=100" runs && cok=true
    get statuses "repos/$REPO/commits/$hsha/statuses?per_page=100" pages || cok=false
  else echo null > "$RAW/runs.json"; echo null > "$RAW/statuses.json"; fi
  get reviews "repos/$REPO/pulls/$NUM/reviews?per_page=100" pages
  get repo "repos/$REPO"
  J -n --argjson cok "$cok" --arg started "$STARTED" --slurpfile pr "$RAW/pr.json" --slurpfile plan "$RAW/plan.json" --slurpfile repo "$RAW/repo.json" \
    --slurpfile cmp "$RAW/compare.json" --slurpfile runs "$RAW/runs.json" --slurpfile st "$RAW/statuses.json" \
    --slurpfile rv "$RAW/reviews.json" "$DECIDE" > "$RAW/decision.json" || fail "the merge precondition could not be evaluated"
  local x; x="$(jq -r '.refusal // ""' "$RAW/decision.json")"
  [ -z "$x" ] || fail "refused: $x"
}

open_run() {
  local d="${1-}"
  case "$d" in /*/pr-merge.??????) ;; *) die "the run directory must be <dir>/pr-merge.XXXXXX" ;; esac
  [ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || die "the run directory is not a directory of this user"
  RUN="$(cd -- "$d" && pwd -P)" || die "the run directory cannot be read"
  [ "$RUN" = "$d" ] || die "the run directory must be given as its resolved path"
  [ -f "$RUN/run.json" ] || die "no prepared run in that directory"
  REPO="$(jq -r .repo "$RUN/run.json")"; NUM="$(jq -r .number "$RUN/run.json")"
  STARTED="$(jq -r .started_at "$RUN/run.json")"
  BOUND="$(jq -r .login "$RUN/run.json")"
  [[ "$REPO" =~ $repo_re ]] && [[ "$NUM" =~ ^[1-9][0-9]{0,8}$ ]] &&
    [[ "$STARTED" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] &&
    [[ "$BOUND" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || die "the run file is outside its grammar"
}

cmd_prepare() {
  local out=""
  REPO=""; NUM=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) REPO="${2-}"; shift 2 || die "--repo needs a value" ;;
      --pr) NUM="${2-}"; shift 2 || die "--pr needs a value" ;;
      --out) out="${2-}"; shift 2 || die "--out needs a value" ;;
      *) die "unexpected argument" ;;
    esac
  done
  [[ "$REPO" =~ $repo_re ]] || die "--repo must be owner/name"
  [[ "$NUM" =~ ^[1-9][0-9]{0,8}$ ]] || die "--pr must be a pull request number"
  case "$out" in /?*) ;; *) die "--out must be an absolute path" ;; esac
  [ -d "$out" ] && [ ! -L "$out" ] || fail "--out is not an existing directory"
  [ "$(cd -P -- "$out" && pwd -P)" = "${out%/}" ] || fail "--out must be given as its resolved path"
  RAW="$(mktemp -d "${TMPDIR:-/tmp}/pr-merge-id.XXXXXX")" || fail "no temporary directory"
  trap 'rm -rf -- "$RAW"' EXIT
  identity
  RUN="$(mktemp -d "${out%/}/pr-merge.XXXXXX")" && mkdir "$RUN/review" || fail "no run directory"
  # started_at: the fresh review this run reads must have started its reads at or after this time.
  jq -n --arg r "$REPO" --argjson n "$NUM" --arg l "$LOGIN" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{repo: $r, number: $n, login: $l, started_at: $t}' > "$RUN/run.json" && chmod a-w "$RUN/run.json" ||
    fail "the run file cannot be written"
  echo "RUN=$RUN"
  echo "identity: $LOGIN (User), permission $PERM on $REPO"
  echo "next: review the head with pr-review render-only --out $RUN/review, then: gate $RUN"
}

cmd_gate() {
  [ ! -e "$RUN/merge.json" ] || fail "gate ran already in this run; start a new run"
  live raw-gate
  jq '.merge' "$RAW/decision.json" > "$RUN/merge.json" && chmod a-w "$RUN/merge.json" || fail "merge.json cannot be written"
  jq -r --slurpfile pr "$RAW/pr.json" '$pr[0] as $p |
    "pull request: \(.pin.target), open, mergeable_state clean",
    "head: \(.pin.head_sha)",
    "base: \(.pin.base_ref) at \(.pin.base_sha)",
    "verdict: \(.verdict)",
    "checks: \(.checks)",
    "method: squash",
    "title: \(.title)",
    (select(.cut) | "title cut: yes, the pull request title is longer than 72 characters"),
    "message: empty"' "$RUN/merge.json"
  echo "confirm with: merge $RUN --target $(jq -r .pin.target "$RUN/merge.json") --confirm-head $(jq -r .pin.head_sha "$RUN/merge.json")"
}

cmd_merge() {
  local target="" head="" x resp err mc
  while [ $# -gt 0 ]; do
    case "$1" in
      --target) target="${2-}"; shift 2 || die "--target needs a value" ;;
      --confirm-head) head="${2-}"; shift 2 || die "--confirm-head needs a value" ;;
      *) die "unexpected argument" ;;
    esac
  done
  [[ "$target" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}#[1-9][0-9]{0,8}$ ]] || die "--target must be owner/name#number"
  [[ "$head" =~ $sha_re ]] || die "--confirm-head must be the full 40-character head SHA"
  [ -f "$RUN/merge.json" ] || fail "run gate first"
  [ "$target" = "$(jq -r .pin.target "$RUN/merge.json")" ] || fail "the target is not the pull request the gate showed"
  [ "$head" = "$(jq -r .pin.head_sha "$RUN/merge.json")" ] || fail "the head is not the one the gate showed"
  live raw-merge
  x="$(jq -r --slurpfile g "$RUN/merge.json" '.merge as $m | first((($g[0] + $m) | keys_unsorted[]) as $k | select(($g[0] | has($k)) != ($m | has($k)) or $g[0][$k] != $m[$k]) | $k) // ""' "$RAW/decision.json")"
  [ -z "$x" ] || fail "changed since the gate: $x; nothing merged"
  resp="$(jq -n --slurpfile m "$RUN/merge.json" '$m[0] | {sha: .pin.head_sha, merge_method: .method, commit_title: .title, commit_message: ""}' |
    gh api -X PUT "repos/$REPO/pulls/$NUM/merge" --input - 2> "$RAW/put.err")" || {
    err="$(oneline < "$RAW/put.err")"
    # Any failure, a timeout that landed included, is read once: a read, never a second PUT. A squash
    # commit has one parent, the base, so the merged pull request's own head is the binding.
    get after "repos/$REPO/pulls/$NUM" || fail "outcome unknown, check the pull request: $err"
    if jq -e --arg h "$head" '.merged == true and .head.sha == $h' "$RAW/after.json" > /dev/null; then
      mc="$(jq -r '.merge_commit_sha // "unknown"' "$RAW/after.json" | oneline)"
      echo "merged: $target, head $head, merge commit $mc (the merge had already landed)"; return 0
    fi
    jq -e '.merged == false' "$RAW/after.json" > /dev/null || fail "outcome unknown, check the pull request: $err"
    fail "the merge failed: $err; nothing retried"
  }
  printf '%s' "$resp" | jq -e '.merged == true' > /dev/null 2>&1 || fail "the merge answer is not merged: $(printf '%s' "$resp" | jq -r '.message // "unreadable"' 2> /dev/null | oneline); nothing retried"
  echo "merged: $target, head $head, merge commit $(printf '%s' "$resp" | jq -r '.sha // "unknown"' | oneline)"
}

cmd_cleanup() {
  chmod -R u+w "$RUN" 2> /dev/null; rm -rf -- "$RUN" || fail "the run directory cannot be deleted: $RUN"
  echo "cleanup: run directory deleted"
}

cmd="${1-}"; shift || die "usage: merge-run.sh <prepare|gate|merge|cleanup> ..."
case "$cmd" in
  prepare) cmd_prepare "$@" ;;
  gate | merge | cleanup)
    run_dir="${1-}"; shift || die "$cmd needs the run directory"
    open_run "$run_dir"
    case "$cmd" in
      gate) [ $# = 0 ] || die "unexpected argument"; cmd_gate ;;
      merge) cmd_merge "$@" ;;
      cleanup) cmd_cleanup ;;
    esac ;;
  *) die "unknown subcommand" ;;
esac
