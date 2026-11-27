#!/bin/bash
# review-run.sh: the deterministic steps of terraform-module-pr-review as commands, on top of
# host-pass.sh and the pass scripts, so the model runs a command and reads a short summary
# instead of running each step by hand. Rules and the order per depth: review-run.md. Invoke it
# with bash by an absolute path in this skill's own checkout, never from the head or the run.
#
#   review-run.sh prepare --repo <owner/name> --pr <number> [--render-only] [--triage]
#       [--profile <name> --role-arn <arn>] [--owner-depth deep] [--owner-pid <pid>]
#       [--provider-cache <dir>] [--module-profile <id> | --module-profile-dir <absolute path>]
#       Steps 1 to 5, 7 and 7.5: identity, host-pass.sh run and checks and their check, the
#       clone, the merge base worktree, G0 and the plan pass mode when a profile is named, the
#       acquisition, the classifier, mtf-facts affected and depth.sh compute. Writes the run
#       directory and <run>/index.json, enumerated fields only, and prints "RUN=<dir>".
#   review-run.sh schema <run>          focused only: schema-pass.sh with depth.json
#   review-run.sh verify <run> [--outside]
#                                        the default pass; --outside re-runs, outside the sandbox
#                                        by the user's authorization, the not-run-environment ones
#   review-run.sh plan <run> [--not-run <token>]
#                                        the plan pass (deep, focused, with a profile), then the
#                                        plan coverage at every depth; --not-run records the pass
#                                        as not run for an environment reason (NOT_RUN_TOKENS)
#   review-run.sh skip-coverage <run>   skip-coverage.sh after a pass with gate skips, recorded
#                                        exceptions or design skips
#   review-run.sh ladder <run> [--not-run <token>]
#                                        ladder-pass.sh run (not at light), then behaviour-pass.sh eval;
#                                        --not-run records the whole step as not run, eval included
#   review-run.sh tests <run>           the test pass (test-pass.md) in the runner, with a
#                                        non-hcl-dependency trigger
#   review-run.sh evidence <run>        the commands above the depth needs, side by side at deep
#   review-run.sh handover <run>        <run>/handover/task.md and record.txt for the reviewer, after
#                                        the module profile snapshot (state/profile.json)
#                                        the README evidence (readme-regions.sh) and the vendored
#                                        policy evidence (vendored-policy.sh)
#   review-run.sh render <run> --findings <file> --assessment <file> --out <dir>
#       [--summary <file>] [--standard] [--event <EVENT>]
#                                        the run file, depth.sh verify, render-comment.sh, plan.json,
#                                        fix-plan.md
#   review-run.sh cleanup <run>         deletes the run directory
#   review-run.sh record --out <dir> --review-id <id>
#                                        after the confirmed write of Step 12: keeps the posted
#                                        review's plan.json and body digest in this user's record
#                                        store, which prepare reads back (github-io.md, The Post Record)
#
# Every subcommand prints at most 30 lines. Host strings never reach a command line or an
# eval: they travel in files and through jq --arg. Exit 0 done, 1 a refusal or a failed step
# with its fixed reason printed, 2 a usage error. There is no post command: posting stays the
# skill's confirmed step (SKILL.md, Rule 1); record only reads the posted review back.
set -uo pipefail
set -f
# SHA-256 with GNU coreutils or macOS sha256sum, else the slower Perl shasum.
if command -v sha256sum > /dev/null 2>&1; then sha256() { sha256sum "$@"; }; else sha256() { shasum -a 256 "$@"; }; fi

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
sha_re='^[0-9a-f]{40}$'
repo_re='^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$'
# Unbounded patterns with separate length checks: bash 3.2's regex refuses a bound over 255.
path_re='^[A-Za-z0-9._][A-Za-z0-9._/-]*$'
plain_ok() { [ "${#1}" -le 300 ] && [[ "$1" =~ $path_re ]]; } # a plain path of at most 300 characters
WRITE_SHORT='Write short: a `summary` of at most 200 characters and a `suggested_fix` of at most 250, or at most 600 for a `needs decision:` fix, one clause per option. The hard caps stay 500 and 600. A finding over the short targets is valid; the comment then renders in STANDARD.'

# A line of behaviour-pass.sh wrappers (behaviour-pass.md, Wrapper Versions).
WRAP_LINE_RE='^wrappers/([A-Za-z0-9_][A-Za-z0-9._-]{0,63}/)?versions\.tf (derived|copied|differs|unknown [a-z0-9 .-]{1,60})$'
# A provenance line of schema-pass.md, Focused Mode: mirror, release tag, schema file SHA-256.
LNM_RE='^schema pass: latest_not_mirrored [a-z0-9][a-z0-9-]{0,63}/[a-z0-9][a-z0-9-]{0,63} [0-9]{1,5}[.][0-9]{1,5}[.][0-9]{1,5}$'
SOURCE_RE='^schema pass: source [A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100} [a-z0-9][a-z0-9-]{0,63}_[a-z0-9][a-z0-9-]{0,63}-v[0-9]{1,5}\.[0-9]{1,5}\.[0-9]{1,5} [0-9a-f]{64}$'
# A line of readme-regions.sh (readme-regions.md): a module-relative README.md and its result.
REGION_LINE_RE='^([A-Za-z0-9_][A-Za-z0-9._-]{0,63}/){0,8}README\.md (generated|differs|unknown [a-z0-9 .-]{1,60})$'
# A line of vendored-policy.sh (vendored-policy.md, Output): a module-relative .tf file, a policy
# document's name and one fact of the comparison with its upstream source.
VP_LINE_RE='^([A-Za-z0-9_][A-Za-z0-9._-]{0,63}/){0,8}[A-Za-z0-9_][A-Za-z0-9._-]{0,63}\.tf [A-Za-z_][A-Za-z0-9_-]{0,63} (source [A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100} v[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4} [0-9a-f]{40} [A-Za-z0-9._/-]+|lines [0-9]{1,7} [0-9]{1,7}|upstream equal|upstream differs [0-9]{1,4} extra [0-9]{1,4} missing|base equal|base absent|base differs [0-9]{1,4} added [0-9]{1,4} removed|(extra|missing|added|removed|widened|carried) (Allow|Deny)( [a-z]+:[]A-Za-z0-9:/*?._=+,@|;"${}[-]+){2,5}|(extra|missing|added|removed|widened|carried) and [0-9]{1,4} more|unknown [a-z0-9 ]{1,60})$'
# The review budget (review-run-details.md, Review Budget). A change whose files list or patch text
# is over REVIEW_THRESHOLD, the size a full run refused before it had a budget (a triage run, which
# computes no depth, was handed such a change whole), hands the reviewer at
# most REVIEW_BUDGET bytes of patch text, about 65,000 tokens, so the diff and the skill files fit
# half of a 200,000 token window. Any smaller change is reviewed whole.
REVIEW_THRESHOLD=1048576
REVIEW_BUDGET=262144
# A family needs this many submodules with equal copies; generator sources rank first up to this many bytes.
FAMILY_MIN=3
GENERATOR_CAP=65536

# The environment reasons a plan or ladder step may be recorded as not run for (review-run.md,
# Steps Not Run); render-comment.jq holds the same list as not_run_tokens.
NOT_RUN_TOKENS="disk memory network sandbox terraform time"

die() { echo "review-run.sh: $1" >&2; exit 2; }
fail() { echo "review-run.sh: $1"; exit 1; }

limit() { # seconds, command... : the time limit of github-io.md, Allowed Commands
  local s="$1"; shift
  if command -v timeout > /dev/null; then timeout "$s" "$@"
  elif command -v gtimeout > /dev/null; then gtimeout "$s" "$@"
  else perl -e 'alarm shift; exec @ARGV' "$s" "$@"; fi
}

# mtf-facts as facts-resolve.sh finds it: from /, canonical, outside the run, its version report
# read once per command. No binary is /dev/null/mtf-facts, which each pass reads as not installed.
# shellcheck source=facts-resolve.sh
. "$HERE/facts-resolve.sh" || die "facts-resolve.sh cannot be read"
# Sets facts in the caller; never call it in a subshell, which would lose the report.
FACTS_DONE=false
facts_bin() {
  [ "$FACTS_DONE" = true ] || { facts_resolve "${RUN:-}"; FACTS_DONE=true; }
  facts="${FACTS_BIN:-/dev/null/mtf-facts}"
}

# facts_bin_line: the binary prepare resolved, as the reviewer's "mtf-facts binary:" line, so the
# reviewer runs the run's mtf-facts, not another one on its own PATH. Only one absolute,
# canonical path of plain characters outside the run directory that is still a regular executable
# file and no link.
facts_bin_line() {
  local b r c
  [ -f "$RUN/state/facts-bin" ] && [ ! -L "$RUN/state/facts-bin" ] && [ "$(wc -l < "$RUN/state/facts-bin")" -eq 1 ] || return 0
  b="$(cat "$RUN/state/facts-bin")"
  [ ${#b} -le 1024 ] && printf '%s\n' "$b" | grep -Eqx '/[A-Za-z0-9._+@/-]+' || return 0
  case "$b/" in */./*|*/../*|*//*) return 0 ;; esac
  # A binary inside the run directory is the run's own data, never the engine, as facts_resolve refuses it.
  r="$(CDPATH= cd -- "$RUN" 2> /dev/null && pwd -P)" || return 0
  # Only a canonical path: one through a link would name another file than the one checked.
  c="$(perl -MCwd=realpath -e 'my $p = realpath($ARGV[0]); print $p if defined $p' "$b" 2> /dev/null)"
  [ -n "$c" ] && [ "$c" = "$b" ] || return 0
  case "$c/" in "$r"/*) return 0 ;; esac
  [ -f "$b" ] && [ -x "$b" ] && [ ! -L "$b" ] || return 0
  printf 'mtf-facts binary: %s\n' "$b"
}

# The run directory a later subcommand names: "<root>/pr-review.XXXXXX", a real directory of
# this user holding the state prepare wrote.
open_run() {
  local d="${1-}"
  case "$d" in /*/pr-review.??????) ;; *) die "the run directory must be <root>/pr-review.XXXXXX" ;; esac
  [ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || die "the run directory is not a directory of this user"
  RUN="$(cd -- "$d" && pwd -P)" || die "the run directory cannot be read"
  [ "$RUN" = "$d" ] || die "the run directory must be given as its resolved path"
  ROOT="${RUN%/*}"
  # cleanup deletes any run prepare made, a refused or stopped one included, and reads nothing else.
  if [ "$CMD" = cleanup ]; then [ -f "$RUN/state/args.json" ] || die "no run prepare made in that directory"; return 0; fi
  [ -f "$RUN/state/args.json" ] && [ -f "$RUN/index.json" ] || die "no prepared run in that directory"
  jq -e '.status == "ok"' "$RUN/index.json" > /dev/null 2>&1 || fail "the run was refused at prepare"
  HEAD_SHA="$(jq -r '.head' "$RUN/index.json")"; MB="$(jq -r '.merge_base // ""' "$RUN/index.json")"
  PREFIX="$(jq -r '.prefix' "$RUN/host/host.json")"
  TRIAGE="$(jq -r '.triage' "$RUN/state/args.json")"
  [[ "$HEAD_SHA" =~ $sha_re ]] || die "the run's head is not a SHA"
  [ -z "$MB" ] || [[ "$MB" =~ $sha_re ]] || die "the run's merge base is not a SHA"
  MROOT="$RUN/clone"; [ -z "$PREFIX" ] || MROOT="$RUN/clone/$PREFIX"
  # A run a failed escalation stopped takes no later step but cleanup.
  [ ! -e "$RUN/state/stop" ] || fail "the run stopped: $(head -c 120 "$RUN/state/stop" | tr -cd 'a-z0-9 :-')"
  check_pin
}
arg() { jq -r --arg k "$1" '.[$k] // "" | tostring' "$RUN/state/args.json"; }
depth() { if [ -f "$RUN/depth.json" ]; then jq -r '.depth' "$RUN/depth.json"; else echo deep; fi; }
note() { printf '%s\n' "$2" > "$RUN/state/$1"; } # a step's own state line
stop() { # reason: the run stops for good; every later command but cleanup refuses
  printf '%s\n' "$1" > "$RUN/state/stop"
  fail "the run stops: $1"
}
# depth.json is written only by depth.sh compute and escalate; its hash is pinned after each, and
# every later command refuses a depth.json that differs from the pin, a lowered depth included.
pin_depth() { shasum -a 256 < "$RUN/depth.json" | cut -d' ' -f1 > "$RUN/state/depth.sha256"; }
check_pin() {
  if [ -f "$RUN/state/depth.sha256" ]; then
    [ -f "$RUN/depth.json" ] && [ ! -L "$RUN/depth.json" ] &&
      [ "$(shasum -a 256 < "$RUN/depth.json" | cut -d' ' -f1)" = "$(cat "$RUN/state/depth.sha256")" ] ||
      stop "depth.json differs from the depth this run computed"
  elif [ -e "$RUN/depth.json" ]; then stop "depth.json has no pin"
  fi
}
escalate() { # reason: depth.sh escalate, which rewrites depth.json to deep, before the handover only
  [ -f "$RUN/depth.json" ] || return 0
  [ ! -e "$RUN/handover" ] || stop "escalation after the handover"
  bash "$HERE/depth.sh" escalate "$RUN/depth.json" "$1" > /dev/null 2>&1 || stop "depth.sh escalate failed"
  pin_depth
  # A light plan coverage says the pass was skipped at light; at deep the plan step runs again.
  if [ -f "$RUN/coverage.json" ] && jq -e 'any(.unplanned[]; .reason == "plan pass skipped at light depth")' \
      "$RUN/coverage.json" > /dev/null 2>&1; then rm -f "$RUN/coverage.json" "$RUN/state/plan"; fi
  echo "depth: escalated to $(depth) ($1)"
  echo "next at deep: the steps not yet run of schema, verify, plan, skip-coverage, ladder; then handover"
}
# Before the handover or the render: every step the depth needs has its output.
ready() {
  [ "$TRIAGE" = false ] || return 0
  [ -f "$RUN/verify.json" ] || fail "$1 needs verify first"
  [ -f "$RUN/coverage.json" ] && [ -f "$RUN/behaviour/record.txt" ] || fail "$1 needs plan and ladder first"
  ! needs_tests || [ -f "$RUN/tests.json" ] || fail "$1 needs tests first"
  # A run with no depth.json is the pipeline of before, with no schema step.
  [ -f "$RUN/depth.json" ] || return 0
  case "$(depth)" in
    focused) case "$(cat "$RUN/state/schema" 2> /dev/null)" in ok | skipped) ;; *) fail "$1 at focused needs schema first" ;; esac ;;
    deep) [ -f "$RUN/state/schema" ] || fail "$1 at deep needs schema first" ;;
  esac
}
base_git() {
  GIT_LFS_SKIP_SMUDGE=1 git -C "$RUN/base" -c core.hooksPath=/dev/null \
    -c filter.lfs.smudge=cat -c filter.lfs.process= \
    -c filter.lfs.required=false "$@"
}
clone_git() {
  GIT_LFS_SKIP_SMUDGE=1 git -C "$RUN/clone" -c core.hooksPath=/dev/null \
    -c filter.lfs.smudge=cat -c filter.lfs.process= \
    -c filter.lfs.required=false "$@"
}

# The stats record of one mtf-facts call (review-run-details.md, Facts Stats): sets STATS to
# --stats-file <run>/state/stats/<name>.json, and SPASS to behaviour-pass.sh's --stats with that file,
# when the binary lists the flag for the command; else both to nothing. The record is a measurement
# only: no step reads it but facts_totals.
STATS=() SPASS=()
stats_for() { # command, name
  STATS=() SPASS=()
  facts_has "flag:$1:stats-file" && [[ "$2" =~ ^[a-z][a-z0-9.-]{0,63}$ ]] || return 0
  { [ -d "$RUN/state/stats" ] || mkdir "$RUN/state/stats"; } 2> /dev/null || return 0
  [ ! -L "$RUN/state/stats" ] && [ ! -e "$RUN/state/stats/$2.json" ] || return 0
  STATS=(--stats-file "$RUN/state/stats/$2.json") SPASS=(--stats "$RUN/state/stats/$2.json")
}

# A report of affected --base counts only when its changed list holds every path of the files list,
# relative to the same root, a rename at both paths, as behaviour-pass.sh's covers holds a classifier
# report: a change the tree comparison does not see, such as a gitlink, is no report of the change.
# Only a GitHub "unchanged" entry takes no path: a committed .terraform file is a change too.
AFF_COVERS='type == "object" and (.changed | type == "array" and all(.[]; type == "string"))
  and (([$f[0][] | select(.status != "unchanged") | .filename, (.previous_filename // empty)] - .changed) == [])'

# mtf-facts affected (verify-pass.md, Example selection): no file when it gave nothing. With a merge
# base tree, that tree first; the files list only when that run gave no report that covers it, as it
# would alone.
affected_to() { # mtf-facts, root, files list, out, name[, base tree]
  if [ -n "${6-}" ]; then
    stats_for affected "$5"
    (cd "$RUN/state" && limit 70 "$1" affected "$2" --base "$6" --json ${STATS[@]+"${STATS[@]}"}) > "$4" 2> /dev/null &&
      jq -e --slurpfile f "$3" "$AFF_COVERS" "$4" > /dev/null 2>&1 && return 0
    note "fallback-$5" "affected: diff after the merge base tree gave no report"
  fi
  stats_for affected "$5${6:+.diff}"
  if ! (cd "$RUN/state" && limit 70 "$1" affected "$2" --diff "$3" --json ${STATS[@]+"${STATS[@]}"}) > "$4" 2> /dev/null ||
      ! jq -e 'type == "object"' "$4" > /dev/null 2>&1; then
    rm -f "$4"
  fi
}

# The module root of the merge base worktree is a real directory at its own path: no link at it or
# at any directory above it inside <run>/base.
base_root_ok() { # prefix
  local d="$RUN/base${1:+/$1}" r
  [ -d "$d" ] && r="$(cd "$d" 2> /dev/null && pwd -P)" && [ "$r" = "$(cd "$RUN/base" && pwd -P)${1:+/$1}" ]
}

# The handover's Base tree: line, the merge base worktree at the module root for the reviewer's
# mtf-facts lint --base, with Diff: as its fallback (review-run-details.md, The Merge Base Tree):
# only a checkout of that merge base, not a link, holding the module root, never for a new module.
base_tree_line() { # new module, merge base
  [ "$1" = true ] || [ -z "$2" ] || [ ! -d "$RUN/base/.git" ] || [ -L "$RUN/base" ] ||
    ! base_root_ok "$PREFIX" || [ "$(git -C "$RUN/base" rev-parse HEAD 2> /dev/null)" != "$2" ] ||
    printf 'Base tree: %s\n' "$RUN/base${PREFIX:+/$PREFIX}"
}

# <run>/facts-stats.json: the totals of the stats records of this run's mtf-facts calls and the
# fallbacks its steps took (review-run-details.md, Facts Stats). Data for measurement only: no
# verdict input reads it, and a record that is missing, a link, over 1 MiB or outside its shape
# is counted as refused and adds nothing. Written again after each command that calls mtf-facts.
facts_totals() {
  local d="$RUN/state/stats" f recs=()
  if [ -d "$d" ] && [ ! -L "$d" ]; then
    while IFS= read -r f; do
      [ -f "$f" ] && [ ! -L "$f" ] && [ "$(wc -c < "$f")" -le 1048576 ] || { recs+=('null'); continue; }
      recs+=("$(jq -c -s 'if length == 1 and (.[0] | type == "object" and .schema_version == 1
          and (.command | type == "string" and test("^[a-z][a-z-]{0,31}$"))
          and (.outcome | IN("completed", "error", "timeout"))
          and (.wall_ns | type == "number" and . >= 0 and . == floor)
          and (.max_rss_bytes == null or (.max_rss_bytes | type == "number" and . >= 0)))
        then .[0] | {command, outcome, wall_ns, max_rss_bytes} else null end' "$f" 2> /dev/null || echo null)")
    done < <(find "$d" -mindepth 1 -maxdepth 1 -name '*.json' 2> /dev/null | LC_ALL=C sort)
  fi
  local fb=()
  while IFS= read -r f; do fb+=("${f##*/fallback-}"); done < <(find "$RUN/state" -mindepth 1 -maxdepth 1 -type f -name 'fallback-*' 2> /dev/null | LC_ALL=C sort)
  [ ! -f "$RUN/behaviour/input" ] || ! grep -q '^diff (base ' "$RUN/behaviour/input" || fb+=(behaviour)
  [ ! -f "$RUN/state/depth-behaviour/input" ] || ! grep -q '^diff (base ' "$RUN/state/depth-behaviour/input" || fb+=(depth-behaviour)
  printf '%s\n' ${recs[@]+"${recs[@]}"} | jq -s --args '
    ($ARGS.positional) as $fb
    | [.[] | select(. != null)] as $ok
    | {format: 1, records: ($ok | length), records_refused: (length - ($ok | length)),
       facts_seconds: (($ok | map(.wall_ns) | add // 0) / 1e9),
       max_rss_bytes: ([$ok[].max_rss_bytes | numbers] | max),
       by_command: ($ok | group_by(.command) | map({key: .[0].command, value: {calls: length,
         wall_ns: (map(.wall_ns) | add), errors: (map(select(.outcome == "error")) | length),
         timeouts: (map(select(.outcome == "timeout")) | length)}}) | from_entries),
       fallbacks: {base_to_diff: ($fb | unique)}}' ${fb[@]+"${fb[@]}"} > "$RUN/facts-stats.raw" 2> /dev/null || return 0
  # The fallback tokens the run's own outputs carry, read only from files in their checked shape.
  jq --slurpfile d "$( [ -f "$RUN/depth.json" ] && echo "$RUN/depth.json" || echo /dev/null)" \
    --slurpfile s "$( [ -f "$RUN/selection.json" ] && echo "$RUN/selection.json" || echo /dev/null)" \
    --slurpfile b "$( [ -f "$RUN/behaviour/run-behaviour.json" ] && echo "$RUN/behaviour/run-behaviour.json" || echo /dev/null)" \
    --arg cl "$(cat "$RUN/behaviour/status" 2> /dev/null)" '
    .fallbacks += {depth: [($d[0].reasons // [])[] | strings | select(IN("deep-classifier-unavailable", "deep-affected-fallback"))],
      examples_all: ([($s[0].dirs // [])[] | objects | select(.affected == "all")] | length),
      behaviour_not_run: ($cl != "" or ($b[0].status? == "not-run"))}' "$RUN/facts-stats.raw" > "$RUN/facts-stats.json" 2> /dev/null ||
    rm -f "$RUN/facts-stats.json"
  rm -f "$RUN/facts-stats.raw"
}

# --- the post record (github-io.md, The Post Record) ---------------------------------------

# This user's own store of the reviews this skill posted, outside every run directory: one
# directory per pull request, three files per review id. Fails, so nothing is read or kept, with no
# absolute XDG_STATE_HOME and no HOME, a base of / or with a . or .. segment, or a repository name of dots.
records_dir() { # owner/name, number
  local b="${XDG_STATE_HOME:-${HOME:+$HOME/.local/state}}"
  case "$b" in /?*) ;; *) return 1 ;; esac
  case "/$b/" in */./* | */../*) return 1 ;; esac
  [[ "$1" =~ $repo_re ]] && ! [[ "${1#*/}" =~ ^[.]+$ ]] && [[ "$2" =~ ^[1-9][0-9]{0,9}$ ]] || return 1
  printf '%s/modulestf/pr-review/records/%s/%s' "${b%/}" "$1" "$2"
}
# The store is this user's alone: every directory from records/ down to the pull request's, and each
# record file, owned by this user and writable by no one else.
store_private() { # pull request directory, file...
  local d="$1" top p; shift
  top="${d%/*/*/*}"
  for p in "$top" "${d%/*/*}" "${d%/*}" "$d" "$@"; do
    [ -O "$p" ] && [ ! -L "$p" ] || return 1
    [ -z "$(find "$p" -prune \( -perm -g+w -o -perm -o+w \) 2> /dev/null)" ] || return 1
  done
}
sha_file() { openssl dgst -sha256 -r < "$1" | cut -d' ' -f1; }
META_JQ='type == "object" and keys == ["body_sha256", "carried_sha256", "format", "plan_sha256", "review_id", "state", "target"]
  and .format == 1 and (.review_id | type == "number" and . >= 1 and . == floor)
  and (.body_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and (.plan_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
  and (.carried_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
  and (.state | IN("APPROVED", "CHANGES_REQUESTED", "COMMENTED")) and (.target | type == "string")'

# The path grammar of the render (render-comment.jq, plain_path), so a finding the render took and
# posted is read back, and the id of an earlier finding: its own id, and for one a later record
# carried, the id of the review that raised it after an @.
EARLIER_JQ='def plain: type == "string" and length > 0 and length <= 1024
    and test("^(\\.|(?!/)(?!.*\\\\)(?!(.*/)?\\.\\.(/|$)).+)$") and (test("[\\x00-\\x1f\\x7f`]") | not);
  def earlier_id: type == "string" and test("^F-[0-9]{3,4}(@[0-9]{1,16})?$");
  def seven: type == "object" and keys == ["file", "id", "line", "rule_id", "severity", "suggested_fix", "summary"];
  def chain_reasons: ["missing", "edited", "mismatch", "unreadable", "broken"];
  def carried_ok: (type == "array" and length <= 1000
      and all(.[]; seven and (.id | earlier_id) and (.severity | IN("CRITICAL", "HIGH", "MEDIUM"))))
    or (type == "object" and keys == ["broken_chain"] and (.broken_chain | IN(chain_reasons[])));'
# The form of the reviewer's git-safety.md, in the clone: ls-tree and cat-file read the head's
# objects only and run no driver, filter or textconv, with pathspecs taken literally.
safe_clone_git() {
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_LAZY_FETCH=1 \
  GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null GIT_LITERAL_PATHSPECS=1 \
  GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat \
  git -C "$RUN/clone" --no-pager -c core.fsmonitor=false -c core.hooksPath=/dev/null \
    -c protocol.allow=never -c diff.external= -c log.showSignature=false \
    -c advice.graftFileDeprecated=false "$@"
}

# Our earlier review: when host.json names an own CHANGES_REQUESTED, the record kept when this
# skill posted it, checked against the review as GitHub holds it now. earlier.json says ok with the
# record's blocking findings, module-relative, or why the block cannot be checked: the plan's
# findings at MEDIUM and above, and the earlier findings that review left not resolved, carried.
read_earlier() { # owner/name, number, token user id, prefix
  local h="$RUN/host/host.json" rid d m pl c rec=missing
  [ "$(jq -r '.own_review.state // ""' "$h")" = CHANGES_REQUESTED ] || return 0
  rid="$(jq -r '.own_review.id' "$h")"
  if d="$(records_dir "$1" "$2")"; then
    m="$d/$rid.json"; pl="$d/$rid.plan.json"; c="$d/$rid.carried.json"
    if [ -e "$m" ] || [ -L "$m" ] || [ -e "$pl" ] || [ -L "$pl" ]; then
      rec=unreadable
      if [ -f "$m" ] && [ ! -L "$m" ] && [ -f "$pl" ] && [ ! -L "$pl" ] && [ -f "$c" ] && [ ! -L "$c" ] &&
          store_private "$d" "$m" "$pl" "$c" && [ "$(wc -c < "$m")" -le 4096 ] &&
          [ "$(wc -c < "$pl")" -le 4194304 ] && [ "$(wc -c < "$c")" -le 4194304 ] && jq -e "$META_JQ" "$m" > /dev/null 2>&1 &&
          jq -e -L "$HERE" 'include "stage-contract"; stage_ok("review-plan")' "$pl" > /dev/null 2>&1 &&
          [ "$(sha_file "$pl")" = "$(jq -r '.plan_sha256' "$m")" ] &&
          [ "$(sha_file "$c")" = "$(jq -r '.carried_sha256' "$m")" ] &&
          jq -e -s "$EARLIER_JQ"' length == 1 and (.[0] | carried_ok)' "$c" > /dev/null 2>&1; then
        if [ "$(jq -r '.body_sha256' "$m")" != "$(jq -r '.own_review.body_sha256' "$h")" ]; then rec=edited
        elif ! jq -e -n --slurpfile m "$m" --slurpfile p "$pl" --slurpfile h "$h" --arg t "$1#$2" --arg u "$3" --arg pre "$4" '
            $m[0].review_id == $h[0].own_review.id and $m[0].state == "CHANGES_REQUESTED" and $m[0].target == $t
            and $p[0].pin.target == $t and $p[0].pin.head_sha == $h[0].own_review.commit_id
            and ($p[0].reviewer_id | tostring) == $u and $p[0].module_prefix == $pre' > /dev/null 2>&1; then rec=mismatch
        # The review replaced a block of ours whose record did not check out: its requests were never
        # judged, so ours stands until it is dismissed or a person confirms an APPROVE.
        elif jq -e 'type == "object"' "$c" > /dev/null 2>&1; then rec=broken
        else rec=ok
        fi
      fi
    fi
  fi
  jq -n --slurpfile h "$h" --arg rec "$rec" --arg pre "$4" --slurpfile p "$( [ "$rec" = ok ] && echo "$pl" || echo /dev/null)" \
    --slurpfile c "$( [ "$rec" = ok ] && echo "$c" || echo /dev/null)" "$EARLIER_JQ"'
    def rel: if $pre == "" then . elif . == $pre then "." elif startswith($pre + "/") then .[($pre | length) + 1:] else null end;
    ([($p[0].findings // [])[] | select(.severity | IN("CRITICAL", "HIGH", "MEDIUM"))] + ($c[0] // []) | map(.file |= (if type == "string" then rel else . end))) as $f
    # Each finding in the grammar the render holds the run file to, else the record is unreadable.
    | (all($f[]; (.id | earlier_id) and (.rule_id | type == "string" and test("^[a-z][a-z0-9_.-]{0,127}$"))
        and (.line == null or (.line | type == "number" and . >= 1 and . == floor))
        and (.file == null or (.file | plain)))
       and ($f | map(.id) | length == (unique | length))) as $g
    | (if $rec != "ok" then $rec elif $f == [] then "empty" elif ($g | not) then "unreadable"
       elif any($f[]; .file == null) then "mismatch" else "ok" end) as $r
    | {review_id: $h[0].own_review.id, commit_id: $h[0].own_review.commit_id, record: $r,
       findings: (if $r == "ok" then $f else [] end)}' > "$RUN/earlier.json" 2> /dev/null ||
    jq -n --slurpfile h "$h" '{review_id: $h[0].own_review.id, commit_id: $h[0].own_review.commit_id,
      record: "unreadable", findings: []}' > "$RUN/earlier.json"
}

# carried.json, beside plan.json: the earlier blocking findings this review left not resolved, each
# with its id and, when it has none yet, @ and the id of the review that raised it, paths
# repository-relative as in plan.json. A record of this review keeps it, so a block that replaces
# ours keeps every open item of ours; [] when there is no earlier block or every item is resolved.
# Over a block of ours whose record did not check out (missing, edited, mismatch, unreadable or an
# earlier broken chain), {"broken_chain": <reason>}, and over an ok record the run file's earlier does
# not match, {"broken_chain": "mismatch"}: its requests are unknown, so a later run reads
# the chain as broken and our block stands. An empty record came from a host signal or a refuted
# state, which every run reads again, and carries [].
write_carried() { # out directory, run file
  local o="$1"
  jq -n --slurpfile r "$2" --slurpfile e "$( [ -f "$RUN/earlier.json" ] && echo "$RUN/earlier.json" || echo /dev/null)" --arg p "$PREFIX" '
    def repo_path: if $p == "" then . elif . == "." then $p else $p + "/" + . end;
    ($e[0] // null) as $e | ($r[0].earlier // null) as $x
    | if $e == null or $e.record == "empty" then []
      elif $e.record != "ok" then {broken_chain: $e.record}
      # A run file whose earlier disagrees with earlier.json: not ok, another review, other items.
      elif $x == null or $x.record != "ok" or $x.review_id != $e.review_id
        or ($x.items | map(.id) | sort) != ($e.findings | map(.id) | sort) then {broken_chain: "mismatch"}
      else [$x.items[] | select(.judgment != "resolved") | .id as $id | $e.findings[] | select(.id == $id)
        | {id: (if $id | test("@") then $id else "\($id)@\($e.review_id)" end), rule_id, severity,
           file: (.file | repo_path), line, summary, suggested_fix}] end' > "$o/carried.json.tmp" 2> /dev/null &&
    jq -e "$EARLIER_JQ"' carried_ok' "$o/carried.json.tmp" > /dev/null 2>&1 &&
    mv -- "$o/carried.json.tmp" "$o/carried.json" ||
    { rm -f "$o/carried.json.tmp"; echo "carried: not written, the record of this review keeps no open earlier finding"; return 0; }
  jq -r '"carried: \(input_filename) " + (if type == "array" then "(\(length) open earlier findings)"
    else "(broken chain: \(.broken_chain), our block stands until dismissed)" end)' "$o/carried.json"
}

# --- prepare ---------------------------------------------------------------------------------

refuse() { # fixed reason, words: index.json says refused and nothing else
  jq -n --arg r "$1" '{format: 1, status: "refused", reason: $r}' > "$RUN/index.json"
  echo "RUN=$RUN"
  echo "prepare refused: $1 ($2). No review is rendered; the run is inconclusive."
  exit 1
}

cmd_prepare() {
  local repo="" pr="" render_only=false triage=false profile="" role="" owner_depth="" opid="" cache="" mp="" mpd=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="${2-}"; shift 2 || die "--repo needs a value" ;;
      --pr) pr="${2-}"; shift 2 || die "--pr needs a value" ;;
      --render-only) render_only=true; shift ;;
      --triage) triage=true; shift ;;
      --profile) profile="${2-}"; shift 2 || die "--profile needs a value" ;;
      --role-arn) role="${2-}"; shift 2 || die "--role-arn needs a value" ;;
      --owner-depth) owner_depth="${2-}"; shift 2 || die "--owner-depth needs a value" ;;
      --owner-pid) opid="${2-}"; shift 2 || die "--owner-pid needs a value" ;;
      --provider-cache) cache="${2-}"; shift 2 || die "--provider-cache needs a value" ;;
      --module-profile) mp="${2-}"; shift 2 || die "--module-profile needs a value" ;;
      --module-profile-dir) mpd="${2-}"; shift 2 || die "--module-profile-dir needs a value" ;;
      *) die "unexpected argument" ;;
    esac
  done
  [[ "$repo" =~ $repo_re ]] || die "--repo must be owner/name"
  [[ "$pr" =~ ^[1-9][0-9]{0,9}$ ]] || die "--pr must be a pull request number"
  [ -z "$profile$role" ] || {
    [[ "$profile" =~ ^[A-Za-z0-9][A-Za-z0-9_.+=,@-]{0,63}$ ]] || die "--profile must be a profile name"
    [[ "$role" =~ ^arn:aws[a-z-]*:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$ ]] && [ "${#role}" -le 600 ] &&
      { local rname="${role#*:role/}"; [ "${#rname}" -le 512 ]; } || die "--role-arn must be a role ARN"
  }
  [ -z "$owner_depth" ] || [ "$owner_depth" = deep ] || die "--owner-depth takes only deep"
  [ -z "$opid" ] || [[ "$opid" =~ ^[1-9][0-9]{0,9}$ ]] || die "--owner-pid must be a process id"
  # The module profile of the user's own message (profile-format.md, Selection), not the AWS profile.
  [ -z "$mp" ] || [ -z "$mpd" ] || die "profile refused: profile and profile-dir both given"
  [ -z "$mp" ] || [[ "$mp" =~ ^[a-z0-9-]{1,64}$ ]] || die "--module-profile must be a shipped profile id"
  case "$mpd" in "" | /?*) ;; *) die "profile refused: profile-dir is not absolute" ;; esac
  ! [[ "$mpd" =~ [[:cntrl:]] ]] || die "--module-profile-dir must not hold a control character"
  [ -n "$cache" ] || cache="${XDG_CACHE_HOME:-$HOME/.cache}/modulestf/provider-cache"
  case "$cache" in /?*) ;; *) die "--provider-cache must be an absolute path" ;; esac

  # Step 1, identity, before anything else (github-io.md, Identity).
  local id login="" type="" uid="" posting=enabled
  id="$(gh api user --jq '.login + " " + .type + " " + (.id // "" | tostring)' 2> /dev/null)" || id=""
  read -r login type uid <<< "$id"
  [[ "$uid" =~ ^[1-9][0-9]{0,12}$ ]] || uid=""
  [[ "$login" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] && [ "$type" = User ] || posting=disabled
  [ -z "${CI-}${GITHUB_ACTIONS-}${GITHUB_RUN_ID-}" ] || posting=disabled
  [[ "$login" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}(\[bot\])?$ ]] || login=""
  [ "$posting" = enabled ] || render_only=true

  # Workspace (github-io.md): the run directory under the resolved temporary root.
  ROOT="$(cd "${TMPDIR:-/tmp}" && pwd -P)" || die "no temporary directory"
  RUN="$(mktemp -d "$ROOT/pr-review.XXXXXX")" || die "no run directory"
  mkdir "$RUN/state" "$RUN/plugin-cache" || die "no run directory"
  jq -n --arg repo "$repo" --argjson pr "$pr" --argjson ro "$render_only" --argjson tr "$triage" \
    --arg profile "$profile" --arg role "$role" --arg od "$owner_depth" --arg opid "$opid" \
    --arg cache "$cache" --arg login "$login" --arg posting "$posting" \
    '{repo: $repo, pr: $pr, render_only: $ro, triage: $tr, profile: $profile, role_arn: $role,
      owner_depth: $od, owner_pid: $opid, cache: $cache, login: $login, posting: $posting}' > "$RUN/state/args.json"
  jq -n --arg id "$mp" --arg dir "$mpd" '{id: $id, dir: $dir}' > "$RUN/state/module-profile-args.json"

  # Steps 2, 4, 5 and 7.5, and the check runs of Step 7, by host-pass.sh.
  local hp=(bash "$HERE/host-pass.sh") ro=() tr=() err
  [ "$render_only" = false ] || ro=(--render-only)
  [ "$triage" = false ] || tr=(--triage)
  # The time the host reads start, for plan.json's read_at (host.json records none); the token user's id beside it.
  jq -n --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg u "$uid" \
    '{read_at: $t, reviewer_id: ($u | tonumber? // null)}' > "$RUN/state/stage.json" || refuse index-failed "stage.json could not be written"
  if ! "${hp[@]}" run --repo "$repo" --pr "$pr" --login "$login" --out "$RUN/host" ${ro[@]+"${ro[@]}"} \
      ${tr[@]+"${tr[@]}"} > /dev/null 2> "$RUN/state/host-pass.err"; then
    err="$(sed -n 's/^::error::host-pass.sh: //p' "$RUN/state/host-pass.err" | head -n 1)"
    case "$err" in
      "no single module root in the head tree") refuse several-module-roots "no single module root holds every changed path" ;;
      "a changed path outside the module root or not plain text") refuse path-outside-root "a changed path is outside the module root or not plain text" ;;
      *) refuse host-read-failed "the pull request could not be read" ;;
    esac
  fi
  [ "$("${hp[@]}" check "$RUN/host" --head "$(jq -r '.head_sha' "$RUN/host/host.json")" 2> /dev/null)" = "records accepted" ] ||
    refuse records-rejected "the host records failed their check"
  local head base mb prefix
  head="$(jq -r '.head_sha' "$RUN/host/host.json")"; base="$(jq -r '.base_sha' "$RUN/host/host.json")"
  mb="$(jq -r '.merge_base // ""' "$RUN/host/host.json")"; prefix="$(jq -r '.prefix' "$RUN/host/host.json")"
  read_earlier "$repo" "$pr" "$uid" "$prefix"
  "${hp[@]}" checks --repo "$repo" --head "$head" --out "$RUN/checks" --own-pairs "" > /dev/null 2>&1
  local checks_file=rejected
  [ "$("${hp[@]}" check "$RUN/checks" --head "$head" 2> /dev/null)" = "checks accepted" ] && checks_file=accepted
  # The count skip-coverage.md holds the files list to, from a metadata read at the same head.
  local changed=null meta=""
  gh api "repos/$repo/pulls/$pr" > "$RUN/state/pr.json" 2> /dev/null &&
    meta="$(jq -r '.head.sha + " " + (.changed_files | tostring)' "$RUN/state/pr.json" 2> /dev/null)" &&
    [ "${meta%% *}" = "$head" ] && [[ "${meta#* }" =~ ^[0-9]{1,6}$ ]] && changed="${meta#* }"
  # The pin of stage-contract.md from the same read, at the host's head: no valid pin, no plan.json later.
  jq -e -L "$HERE" --arg head "$head" --arg base "$base" --arg mb "$mb" 'include "stage-contract";
    {pr: ., merge_base: $mb} | live_pin | select(.head_sha == $head and .base_sha == $base and pin_ok)' "$RUN/state/pr.json" \
    > "$RUN/state/pin.json" 2> /dev/null || rm -f "$RUN/state/pin.json"

  # Step 3, the clone, pinned to the head; then the merge base with enough history for depth.sh.
  git init -q --template= "$RUN/clone" && git -C "$RUN/clone" remote add origin "https://github.com/$repo.git" ||
    refuse clone-failed "the clone could not be made"
  clone_git fetch -q --depth=1 origin "refs/pull/$pr/head" 2> /dev/null && clone_git checkout -q FETCH_HEAD 2> /dev/null ||
    refuse clone-failed "the head could not be fetched"
  [ "$(git -C "$RUN/clone" rev-parse HEAD)" = "$head" ] || refuse head-moved "the head moved after it was read"
  local base_tree=false ts
  if [ -n "$mb" ] && clone_git fetch -q --depth=1 origin "$mb" "$base" 2> /dev/null; then
    # History from a day before the older of the merge base and the base tip (review-run.md).
    ts="$(git -C "$RUN/clone" log --no-walk --format=%ct "$mb" "$base" 2> /dev/null | sort -n | head -n 1)"
    [[ "$ts" =~ ^[0-9]+$ ]] && clone_git fetch -q --shallow-since="$((ts - 86400)) +0000" origin \
      "refs/pull/$pr/head" "$base" "$mb" 2> /dev/null
    # A branch that merged the base into older work: the cutoff drops the branch side of that merge
    # and the clone shows no merge base. Start the history a day before the oldest pull request commit.
    # Only the first 100 commits are read; a longer branch that still shows no merge base ends in the refusal below.
    if [ "$(git -C "$RUN/clone" merge-base --all "$base" HEAD 2> /dev/null)" != "$mb" ]; then
      ts="$(gh api "repos/$repo/pulls/$pr/commits?per_page=100" \
        --jq '[.[].commit.committer.date | fromdateiso8601] | min' 2> /dev/null)"
      [[ "$ts" =~ ^[0-9]+$ ]] && clone_git fetch -q --shallow-since="$((ts - 86400)) +0000" origin \
        "refs/pull/$pr/head" "$base" "$mb" 2> /dev/null
    fi
    # The merge base tree as a checkout of its own, with a .git directory: a worktree's .git is a
    # file, which mtf-facts depth reads as a changed path of the tree.
    git init -q --template= "$RUN/base" && git -C "$RUN/base" remote add origin "https://github.com/$repo.git" &&
      base_git fetch -q --depth=1 origin "$mb" 2> /dev/null && base_git checkout -q --detach FETCH_HEAD 2> /dev/null &&
      [ "$(git -C "$RUN/base" rev-parse HEAD)" = "$mb" ] && base_tree=true
  fi
  [ "$(git -C "$RUN/clone" rev-parse HEAD)" = "$head" ] || refuse head-moved "the clone left the head"
  # A merge base with no file under the module root: the handover states the reviewer's new
  # module shape (github-io.md, Handover). A tree that cannot be read is no empty base.
  local new_module=false t
  if [ "$base_tree" = true ] && t="$(git -C "$RUN/base" ls-tree -r --name-only HEAD -- "${prefix:-.}" 2> /dev/null)" &&
    [ -z "$t" ]; then new_module=true; fi

  # G0 and the plan pass mode, only when the user named a profile (plan-pass.md).
  local mode=none
  if [ -n "$profile" ]; then
    bash "$HERE/plan-pass.sh" g0 "$RUN" > "$RUN/state/g0.out" 2>&1
    [ "$base_tree" = false ] || bash "$HERE/plan-pass.sh" g0 "$RUN" base > "$RUN/state/g0-base.out" 2>&1
    if limit 30 docker info > /dev/null 2>&1; then
      if aws --version 2>&1 | grep -q '^aws-cli/2\.'; then
        mode=runner; note runner "plan pass runner: available"
        cp -PR "$RUN/clone" "$RUN/runner-clone" || { mode=laptop; note runner "plan pass runner: not available (snapshot failed)"; }
      else mode=laptop; note runner "plan pass runner: not available (aws --version is not AWS CLI version 2)"; fi
    else mode=laptop; note runner "plan pass runner: not available (docker info failed)"; fi
  fi
  note mode "$mode"

  # Step 5.4's tool part and the depth, outside a triage run.
  local facts behaviour=skipped
  facts_bin
  # The binary and what it reports it can do, for the summary and the reviewer's task.
  facts_line > "$RUN/state/facts"
  [ -z "$FACTS_BIN" ] || printf '%s\n' "$FACTS_BIN" > "$RUN/state/facts-bin"
  [ "$FACTS_STATE" != ok ] || printf '%s\n' "$FACTS_REPORT" > "$RUN/state/facts-version.json"
  if [ "$triage" = false ]; then
    mkdir "$RUN/behaviour"
    local mroot="$RUN/clone"; [ -z "$prefix" ] || mroot="$RUN/clone/$prefix"
    local own=(); [ -z "$opid" ] || own=(--owner-pid "$opid")
    { [ -d "$cache" ] || (umask 077 && mkdir -p "$cache"); } 2> /dev/null
    bash "$HERE/ladder-pass.sh" acquire "$RUN" --pins "$HERE/ladder-pins.json" --cache "$cache" \
      --schema-out "$RUN/behaviour-schema.json" ${own[@]+"${own[@]}"} > "$RUN/state/acquire.out" 2>&1 ||
      rm -f "$RUN/behaviour-schema.json"
    local sch=(); [ ! -f "$RUN/behaviour-schema.json" ] || sch=(--schema "$RUN/behaviour-schema.json")
    # The merge base worktree, checked out above, for every mtf-facts call that takes --base; the
    # files list stays each call's fallback (review-run-details.md, The Merge Base Tree).
    local bt=() bmod=() broot=""
    if [ "$base_tree" = true ] && [ -d "$RUN/base/.git" ] && [ ! -L "$RUN/base" ]; then
      broot="$RUN/base"; bt=(--base "$RUN/base")
      [ "$new_module" = true ] || ! base_root_ok "$prefix" || bmod=(--base "$RUN/base${prefix:+/$prefix}")
    fi
    stats_for behaviour classify
    bash "$HERE/behaviour-pass.sh" classify --facts "$facts" --dir "$mroot" --diff "$RUN/host/files.json" \
      --prefix "$prefix" ${bmod[@]+"${bmod[@]}"} ${sch[@]+"${sch[@]}"} ${SPASS[@]+"${SPASS[@]}"} \
      --out "$RUN/behaviour" > "$RUN/state/classify.out" 2>&1
    if [ -f "$RUN/behaviour/behaviour.json" ]; then behaviour=classified
    else behaviour="not-run: $(head -c 64 "$RUN/behaviour/status" 2> /dev/null | tr -cd 'a-z -')"; fi
    # mtf-facts affected, as verify-pass.md Example selection runs it; no file when it gave nothing.
    # With a module root prefix and affected --module-root, one run on the clone root gives the
    # repository-relative report depth reads; else the module root run below and, for the depth,
    # a second run on the clone root.
    local mraff=false
    [ -z "$prefix" ] || ! facts_has flag:affected:module-root || mraff=true
    jq -L "$HERE" --arg p "${prefix:+$prefix/}" '
      include "module-files"; module_files($p)' "$RUN/host/files.json" > "$RUN/state/files-module.json"
    if [ "$mraff" = true ]; then
      local mrin=(--diff "$RUN/host/files.json") mrok=false
      if [ -n "$broot" ]; then
        stats_for affected affected-module-root
        (cd "$RUN/state" && limit 70 "$facts" affected "$RUN/clone" --module-root "$prefix" --base "$broot" --json ${STATS[@]+"${STATS[@]}"}) \
          > "$RUN/affected.json" 2> /dev/null && jq -e --arg p "$prefix" --slurpfile f "$RUN/host/files.json" \
          "$AFF_COVERS"' and .module_root == $p' "$RUN/affected.json" > /dev/null 2>&1 && mrok=true
        [ "$mrok" = true ] || note fallback-affected-module-root "affected: diff after the merge base tree gave no report"
      fi
      if [ "$mrok" = false ]; then
        stats_for affected "affected-module-root${broot:+.diff}"
        if ! (cd "$RUN/state" && limit 70 "$facts" affected "$RUN/clone" --module-root "$prefix" "${mrin[@]}" --json ${STATS[@]+"${STATS[@]}"}) \
            > "$RUN/affected.json" 2> /dev/null || ! jq -e --arg p "$prefix" 'type == "object" and .module_root == $p' "$RUN/affected.json" > /dev/null 2>&1; then
          # The engine refused the prefix or its report did not validate: the older path below.
          rm -f "$RUN/affected.json"; mraff=false
        fi
      fi
    fi
    [ "$mraff" = true ] || affected_to "$facts" "$mroot" "$RUN/state/files-module.json" "$RUN/affected.json" affected ${bmod[@]+"${bmod[1]}"}
    local od=(); [ -z "$owner_depth" ] || od=(--owner-depth deep)
    [ "$base_tree" = true ] || refuse merge-base-unavailable "the merge base could not be checked out for the depth binding"
    # mtf-facts depth reads the trees from the repository root, so its classifier and affected
    # reports must have repository-relative paths: with a module root prefix, a second classify run
    # on the clone root, and a second affected run there unless the module root run above gave one,
    # used for the depth alone.
    local dcl="$RUN/behaviour/behaviour.json" daf="$RUN/affected.json"
    if [ -n "$prefix" ]; then
      mkdir "$RUN/state/depth-behaviour"
      stats_for behaviour classify-depth
      bash "$HERE/behaviour-pass.sh" classify --facts "$facts" --dir "$RUN/clone" --diff "$RUN/host/files.json" \
        ${bt[@]+"${bt[@]}"} ${sch[@]+"${sch[@]}"} ${SPASS[@]+"${SPASS[@]}"} \
        --out "$RUN/state/depth-behaviour" > "$RUN/state/depth-classify.out" 2>&1
      dcl="$RUN/state/depth-behaviour/behaviour.json"
      if [ "$mraff" = false ]; then
        affected_to "$facts" "$RUN/clone" "$RUN/host/files.json" "$RUN/state/affected-depth.json" affected-depth ${bt[@]+"${bt[1]}"}
        daf="$RUN/state/affected-depth.json"
      fi
    fi
    local dargs=()
    [ ! -f "$dcl" ] || dargs+=(--classify "$dcl")
    [ ! -f "$daf" ] || dargs+=(--affected "$daf")
    bash "$HERE/depth.sh" compute --clone "$RUN/clone" --base-tree "$RUN/base" --base "$base" \
      --files "$RUN/host/files.json" ${dargs[@]+"${dargs[@]}"} \
      --out "$RUN/depth.json" ${od[@]+"${od[@]}"} > "$RUN/state/depth.out" 2>&1
    case $? in
      0) ;;
      1) refuse depth-aborted "depth.sh found the merge base not unique, missing or not in the clone" ;;
      *) refuse depth-refused "depth.sh refused its input" ;;
    esac
    # The merge base git found must be the one GitHub's compare gave; else uniqueness is unproven.
    jq -e --arg m "$mb" '.binding.merge_base == $m' "$RUN/depth.json" > /dev/null 2>&1 ||
      refuse depth-aborted "the clone's merge base is not the one the compare read gave"
    pin_depth
  fi

  # The review budget (budget.jq): over the threshold, the files in budget order, each kept while
  # its patch fits beside the patches kept before it, and every file with a patch that does not fit
  # named in skipped.json; under the threshold an empty list.
  local fsize; fsize="$(wc -c < "$RUN/host/files.json" | tr -d ' ')"
  jq -L "$HERE" --argjson cap "$REVIEW_BUDGET" --argjson th "$REVIEW_THRESHOLD" --argjson fsize "${fsize:-0}" --arg p "$prefix" \
    --argjson fmin "$FAMILY_MIN" --argjson gcap "$GENERATOR_CAP" \
    'include "budget"; budget($cap; $th; $fsize; $p; $fmin; $gcap)' "$RUN/host/files.json" > "$RUN/skipped.json" 2> /dev/null ||
    refuse index-failed "the review budget could not be computed"

  # The example selection, for the index (verify-pass.sh select, which runs no terraform).
  bash "$HERE/verify-pass.sh" select "$RUN" --files "$RUN/host/files.json" --prefix "$prefix" \
    > "$RUN/selection.json" 2> /dev/null || echo '{"selection": null, "dirs": []}' > "$RUN/selection.json"

  write_index "$checks_file" "$changed" "$behaviour" "$mode" "$new_module"
  [ "$triage" = true ] || facts_totals
  local login_shown="${login:-none}"
  echo "RUN=$RUN"
  echo "identity: $login_shown, posting $posting$( [ "$render_only" = false ] || echo ", render-only")"
  summary_lines
  [ ! -f "$RUN/earlier.json" ] || jq -r '"earlier review: changes requested on \(.commit_id[:12]), record \(.record)"
    + (if .record == "ok" then ", \(.findings | length) blocking findings for the reviewer to judge" else ", the block stands" end)' "$RUN/earlier.json"
}

# index.json: enumerated fields and validated paths only, never prose, a title or a branch.
write_index() { # checks file, changed files, behaviour, mode, new module
  jq -n --arg cf "$1" --arg changed "$2" --arg beh "$3" --arg mode "$4" --arg nm "$5" --arg pre "$path_re" \
    --slurpfile h "$RUN/host/host.json" --slurpfile a "$RUN/state/args.json" --slurpfile s "$RUN/selection.json" \
    --slurpfile f "$RUN/host/files.json" --slurpfile k "$RUN/skipped.json" --slurpfile d "$( [ -f "$RUN/depth.json" ] && echo "$RUN/depth.json" || echo /dev/null)" '
    def paths: [.[]? | select(type == "string" and length <= 300 and test($pre))];
    ($h[0]) as $h | ($a[0]) as $a | ($d[0] // null) as $d
    | {format: 1, status: "ok", head: $h.head_sha, base: $h.base_sha, merge_base: $h.merge_base,
       prefix: (if $h.prefix | test($pre) then $h.prefix else "" end),
       triage: $a.triage, render_only: $a.render_only, posting: $a.posting, new_module: ($nm == "true"),
       plan: (if $a.profile == "" then "no-profile" else $mode end),
       depth: (if $a.triage then "triage" else ($d.depth // "deep") end),
       reasons: ($d.reasons // [] | paths),
       checks_out_of_scope: ($d.checks_out_of_scope // [] | paths),
       examples_selected: ($d.examples_selected // ($s[0].dirs | map(.dir)) | paths),
       examples_out_of_scope: ($d.examples_out_of_scope // [] | paths),
       signals: ($h.signals + {checks: $cf}), state: $h.state,
       behaviour: (if $beh | test("^(classified|skipped|not-run: [a-z -]*)$") then $beh else "not-run" end),
       counts: {files: ($f[0] | length), changed_files: ($changed | tonumber? // null),
                could_not_run: ($h.could_not_run | length), unresolved_threads: ($h.unresolved_threads | length),
                examples: ($s[0].dirs | length), skipped_files: ($k[0] | length)}}' > "$RUN/index.json" 2> /dev/null ||
    refuse index-failed "index.json could not be written"
}

summary_lines() {
  [ ! -s "$RUN/state/facts" ] || head -n 1 "$RUN/state/facts"
  jq -r '"head \(.head[:12]), merge base \(.merge_base // "none" | .[:12]), \(.counts.files) files, \(.counts.examples) examples",
    "signals: threads \(.signals.threads), review decision \(.signals.review_decision), mergeability \(.signals.mergeability), checks file \(.signals.checks)",
    "depth: \(.depth)" + (if .reasons != [] then " (" + (.reasons[:6] | join(", ")) + ")" else "" end),
    "out of scope: checks \(.checks_out_of_scope | join(",") | if . == "" then "none" else . end), examples \(.examples_out_of_scope | length)",
    "behaviour: \(.behaviour), plan: \(.plan)",
    (if .counts.skipped_files > 0 then "review budget: \(.counts.skipped_files) of \(.counts.files) files over the budget, not reviewed (skipped.json)" else empty end),
    (if .new_module then "base: no file under the module root, reviewed as a new module" else empty end),
    (if .state.locked then "locked: yes (\(.state.lock_reason // "none")), posting needs an unlock first" else empty end),
    "next: " + (if .triage then "handover, reviewer, render"
      else "claims, evidence, handover, reviewer, render" end)' "$RUN/index.json"
}

# --- evidence passes -----------------------------------------------------------------------

need_full() { [ "$TRIAGE" = false ] || fail "a triage run has no $1 step"; }

# The schema handoff's inputs, as schema-pass.md, Schema Handoff, gives them: one
# <commit>:<SHA-256>:<path> per regular .tf blob of at most 2 MiB in each commit's tree,
# with a module root prefix only the blobs under it, the path relative to it, as the facts
# engine hashes the workspace it lints. Status 1, so no inputs and no handoff, when a tree
# or blob cannot be read, a path is outside the token charset, or the tokens pass 600 or
# 96000 bytes, which keeps them under the environment's string limit.
schema_inputs() {
  local c l m o s p h out="" n=0 r="${PREFIX:+$PREFIX/}"
  for c in "$@"; do
    clone_git ls-tree -r -l -z "$c" > "$RUN/state/schema-tree" 2> /dev/null || return 1
    while IFS= read -r -d '' l; do
      read -r m _ o s <<< "${l%%$'\t'*}"; p="${l#*$'\t'}"
      [[ "$m" =~ ^100(644|755)$ && "$p" == *.tf && "$s" =~ ^[0-9]+$ ]] && [ "$s" -le 2097152 ] || continue
      if [ -n "$r" ]; then [[ "$p" == "$r"* ]] || continue; p="${p#"$r"}"; fi
      [[ "$p" =~ ^[A-Za-z0-9._/-]+$ && "$o" =~ ^[0-9a-f]{40}$ ]] || return 1
      h="$(clone_git cat-file blob "$o" | sha256)" || return 1
      out+="$c:${h%% *}:$p"$'\n'; n=$((n + 1))
      [ "$n" -le 600 ] && [ "${#out}" -le 96000 ] || return 1
    done < "$RUN/state/schema-tree"
  done
  printf '%s' "$out"
}

cmd_schema() {
  need_full schema
  local d; d="$(depth)"
  [ "$d" != light ] || { echo "schema: not run at depth light"; return 0; }
  [ ! -e "$RUN/facts" ] || fail "schema already ran in this run"
  # No .tf, .tf.json or .hcl file changed, old path included: no provider facts to read. A list
  # that cannot be read runs the pass.
  if jq -e 'all(.[]; [.filename, (.previous_filename // empty)] | all(test("[.](tf|tf[.]json|hcl)$") | not))' \
      "$RUN/host/files.json" > /dev/null 2>&1; then
    note schema skipped; echo "schema: not run, no .tf, .tf.json or .hcl file changed"; return 0
  fi
  rm -rf "$RUN/schema-work" "$RUN/schema-handoff" "$RUN/state/schema-sources.txt" "$RUN/state/schema-lnm.txt"
  local line rc r="" mbs ins=""
  # The handoff's commits and inputs: the head and the merge base the depth was bound to.
  # Without both, schema-pass.sh gives no handoff and says why; inputs that could not be
  # read pass as "-", which it refuses as inputs.
  mbs="$(jq -r '.binding.merge_base // ""' "$RUN/depth.json" 2> /dev/null)"
  if [[ "$mbs" =~ $sha_re ]]; then ins="$(schema_inputs "$HEAD_SHA" "$mbs")" || ins=-; else mbs=""; fi
  # The mirror cache across runs (schema-pass.md, Mirror Cache): each cached asset is checked as a
  # download is. No cache directory to name, no cache.
  local sc=""
  if [ -n "${XDG_CACHE_HOME:-}" ]; then sc="$XDG_CACHE_HOME/modulestf/schema-mirror"
  elif [ -n "${HOME:-}" ]; then sc="$HOME/.cache/modulestf/schema-mirror"; fi
  SCHEMA_CACHE="$sc" \
  SCHEMA_DEPTH="$RUN/depth.json" SCHEMA_HEAD="$HEAD_SHA" SCHEMA_MERGE_BASE="$mbs" SCHEMA_INPUTS="$ins" SCHEMA_ROOT="$PREFIX" \
    bash "$HERE/schema-pass.sh" "$RUN/facts" "$RUN/schema-work" "$RUN/schema-handoff" > "$RUN/state/schema.out" 2>&1
  rc=$?
  line="$(grep -v '^schema pass: source ' "$RUN/state/schema.out" | tail -n 1)"
  if [ "$rc" = 0 ] && [ -d "$RUN/facts" ]; then
    # The provenance lines of schema-pass.md, Focused Mode, each checked against its grammar
    # before it is copied into the verification record; one that does not match fails the step.
    grep '^schema pass: source ' "$RUN/state/schema.out" > "$RUN/state/schema-sources.tmp"
    if grep -qvE "$SOURCE_RE" "$RUN/state/schema-sources.tmp"; then r=source-line
    else
      mv "$RUN/state/schema-sources.tmp" "$RUN/state/schema-sources.txt"
      # A latest the mirror lacked: each line names the provider and the version, in this grammar
      # alone, and reaches the record and the task as a fact line.
      grep -E "$LNM_RE" "$RUN/state/schema.out" | LC_ALL=C sort -u | head -n 32 > "$RUN/state/schema-lnm.txt"
      note schema ok
      grep -m 1 -E '^schema pass: (handoff written|no handoff)' "$RUN/state/schema.out" | sed 's/^schema pass: /schema: /'
      echo "schema: ${line:0:200}"
      echo "schema: $(grep -c . "$RUN/state/schema-sources.txt") source lines recorded"
      sed 's/^schema pass: /schema: /' "$RUN/state/schema-lnm.txt"
      return 0
    fi
  fi
  rm -f "$RUN/state/schema-sources.tmp"
  [ -n "$r" ] || r="$(printf '%s' "$line" | sed -n 's/^schema pass: escalate \([a-z0-9-]\{1,56\}\)$/\1/p')"
  [ -n "$r" ] || r=failed
  rm -rf "$RUN/facts" "$RUN/schema-handoff"
  if [ "$d" = deep ]; then
    # At deep there is nothing to raise: the reviewer reads pages as before.
    note schema "failed $r"
    echo "schema: no fact sheets at depth deep (reason $r); the reviewer reads provider pages"
    return 0
  fi
  note schema "escalated $r"
  echo "schema: escalated to deep (reason $r)"
  escalate "deep-schema-$r"
}

cmd_verify() {
  need_full verify
  local outside=false
  [ "${1-}" != --outside ] || outside=true
  if [ -z "$MB" ]; then note verify "no merge base"; echo "verify: not run, no merge base; every example is a gap"; return 0; fi
  local vp=(bash "$HERE/verify-pass.sh")
  if [ "$outside" = true ]; then
    [ -f "$RUN/verify.json" ] || fail "verify --outside needs a verify run first"
    local dirs=() d
    while IFS= read -r d; do plain_ok "$d" && dirs+=(--dir "$d"); done < <(
      jq -r '.dirs[] | select(.head.record == "not-run-environment") | .dir' "$RUN/verify.json")
    [ "${#dirs[@]}" -gt 0 ] || { echo "verify: nothing ended not run: environment"; return 0; }
    rm -f "$RUN/verify-outside.json" "$RUN/verify-merged.json"
    "${vp[@]}" run "$RUN" --files "$RUN/host/files.json" --base "$MB" --out "$RUN/verify-outside.json" \
      --prefix "$PREFIX" "${dirs[@]}" > "$RUN/state/verify-outside.out" 2>&1 || fail "verify-pass.sh run outside failed"
    "${vp[@]}" merge "$RUN" --results "$RUN/verify.json" --outside "$RUN/verify-outside.json" \
      --out "$RUN/verify-merged.json" > /dev/null 2>&1 && mv "$RUN/verify-merged.json" "$RUN/verify.json" ||
      fail "verify-pass.sh merge failed"
  else
    [ ! -e "$RUN/verify.json" ] || fail "verify already ran in this run"
    "${vp[@]}" run "$RUN" --files "$RUN/host/files.json" --base "$MB" --out "$RUN/verify.json" \
      --prefix "$PREFIX" > "$RUN/state/verify.out" 2>&1 || fail "verify-pass.sh run failed (state/verify.out)"
  fi
  note verify ran
  jq -r '"verify: " + ([.dirs[] | if .reason != "verified" then .reason
      elif .head.record == "code-result" then (if .head.validate == 0 then "validate passed" else "validate failed" end)
      else .head.record end] | group_by(.) | map("\(length) \(.[0])") | join(", ") | if . == "" then "no example" else . end)' "$RUN/verify.json"
  # Light rule 6: anything but a pass in every verified example escalates before the reviewer.
  if [ "$(depth)" = light ] && jq -e 'any(.dirs[]; .reason == "skipped-symlink"
      or (.reason == "verified" and (.head.record != "code-result" or .head.validate != 0)))' "$RUN/verify.json" > /dev/null; then
    escalate deep-validate-failed
  # Any depth: a validate failure new under this change, in any example, out of scope included.
  elif [ "$(depth)" != deep ] && jq -e 'any(.dirs[]; .reason == "verified" and .head.record == "code-result"
      and .head.validate != 0 and (.base.record == "absent-at-base"
        or (.base.record == "code-result" and .base.validate == 0)))' "$RUN/verify.json" > /dev/null; then
    escalate deep-validate-failed
  fi
}

not_run_arg() { # the step's arguments: sets NOT_RUN to the token of --not-run, or empty
  NOT_RUN=""
  [ $# -gt 0 ] || return 0
  [ "$1" = --not-run ] && [ $# = 2 ] || die "usage: review-run.sh $CMD <run> [--not-run <token>]"
  case " $NOT_RUN_TOKENS " in *" $2 "*) NOT_RUN="$2" ;; *) die "--not-run takes one of: $NOT_RUN_TOKENS" ;; esac
}

plan_dirs() { # the examples to plan, repository-relative, in selection order
  if [ "$(depth)" = focused ]; then
    # An example outside the module root, which the depth does not list, stays unless it is out of scope.
    jq -r --slurpfile d "$RUN/depth.json" --arg pre "${PREFIX:+$PREFIX/}" '.dirs[].dir | select(IN($d[0].examples_selected[])
      or ((startswith($pre) | not) and (IN($d[0].examples_out_of_scope[]) | not)))' "$RUN/selection.json"
  else jq -r '.dirs[].dir' "$RUN/selection.json"; fi
}

cmd_plan() {
  need_full plan
  not_run_arg "$@"
  [ ! -e "$RUN/coverage.json" ] || fail "plan already ran in this run"
  local profile role mode src=(--no-plan) d dirs=() base=() rc=0 missed="" pdd=()
  profile="$(arg profile)"; role="$(arg role_arn)"; mode="$(cat "$RUN/state/mode")"
  [ -z "$MB" ] || base=(--base "$MB")
  # Not run for an environment reason: no pass, and every example not planned says why, whether or
  # not a profile was named; the render reads it as a rule 4 unknown.
  if [ -n "$NOT_RUN" ]; then missed="plan pass not run: $NOT_RUN"; note plan-not-run "$NOT_RUN"
  elif [ -n "$profile" ] && [ "$(depth)" != light ]; then
    while IFS= read -r d; do plain_ok "$d" && dirs+=("$d"); done < <(plan_dirs)
    # The directories of the changes a plan diff can clear (plan-pass.md, Plan diff), from the
    # classifier; none when it did not run. One outside the pattern loses only its own plan diff.
    if [ -f "$RUN/behaviour/behaviour.json" ] && [ -n "$MB" ]; then
      while IFS= read -r d; do
        [[ "$d" =~ ^(\.|[A-Za-z0-9_][A-Za-z0-9._-]*(/[A-Za-z0-9_][A-Za-z0-9._-]*)*)$ ]] && pdd+=(--diff-dir "$d")
      done < <(bash "$HERE/behaviour-pass.sh" diff-dirs --out "$RUN/behaviour" --prefix "$PREFIX" 2> /dev/null)
    fi
    if [ "${#dirs[@]}" -gt 0 ] && [ "$mode" = runner ]; then
      bash "$HERE/plan-runner/run-pass.sh" --build --clone "$RUN/runner-clone" --record "$RUN/plan-record" \
        --tmp "$RUN" --profile "$profile" --role-arn "$role" ${base[@]+"${base[@]}"} ${pdd[@]+"${pdd[@]}"} "${dirs[@]}" \
        > "$RUN/state/plan.out" 2> "$RUN/state/plan.err" || rc=$?
      [ -f "$RUN/plan-record/plan-pass.txt" ] && src=(--plan "$RUN/plan-record/plan-pass.txt" --addresses "$RUN/plan-record")
    elif [ "${#dirs[@]}" -gt 0 ]; then
      bash "$HERE/plan-pass.sh" plan "$RUN" "$profile" --role-arn "$role" --mode laptop ${base[@]+"${base[@]}"} ${pdd[@]+"${pdd[@]}"} \
        "${dirs[@]}" > "$RUN/plan-out.txt" 2> "$RUN/state/plan.err" || rc=$?
      # A record is usable when the pass printed its mode line or a plan line for an example.
      if grep -qE '^(plan pass mode:|plan:)' "$RUN/plan-out.txt"; then
        src=(--plan "$RUN/plan-out.txt"); [ ! -d "$RUN/plan-addresses" ] || src+=(--addresses "$RUN/plan-addresses")
      fi
    fi
    # A profile was named and the pass left no record: the unplanned examples say why, never that
    # no profile was named (verify-pass.md, Plan coverage).
    if [ "${#dirs[@]}" -gt 0 ] && [ "${src[0]}" = --no-plan ]; then
      if [ "$rc" = 2 ]; then missed="plan pass did not run: refused"; else missed="plan pass did not run: failed"; fi
    fi
  fi
  [ "${src[0]}" = --no-plan ] || note plan ran
  bash "$HERE/verify-pass.sh" coverage "$RUN" --files "$RUN/host/files.json" --out "$RUN/coverage.json" \
    --prefix "$PREFIX" "${src[@]}" > /dev/null 2> "$RUN/state/coverage.err" || fail "verify-pass.sh coverage failed"
  # At light the plan pass is out of scope, whether or not a profile was named.
  [ "$(depth)" != light ] || missed="plan pass skipped at light depth"
  if [ -n "$missed" ]; then
    jq --arg r "$missed" '.unplanned |= map(if .reason == "no AWS profile named" then .reason = $r else . end)' \
      "$RUN/coverage.json" > "$RUN/coverage.tmp" && mv "$RUN/coverage.tmp" "$RUN/coverage.json" || fail "the coverage could not be rewritten"
    echo "plan: $missed"
  elif [ -f "$RUN/state/plan" ]; then echo "plan: $(grep -m1 '^plan summary:' "$(plan_record)" 2> /dev/null || echo 'no summary line')"
  elif [ -z "$profile" ]; then echo "plan: not run (no AWS profile named)"
  elif ! jq -e '.selection | type == "object"' "$RUN/selection.json" > /dev/null 2>&1; then echo "plan: not run (example selection failed)"
  elif jq -e '.dirs == []' "$RUN/selection.json" > /dev/null 2>&1; then
    if [ -d "$MROOT/examples" ] || { [ -n "$PREFIX" ] && [ -d "$RUN/clone/examples" ]; }; then
      echo "plan: not run (no example calls the module)"
    else echo "plan: not run (no example directory)"; fi
  else echo "plan: not run (no example in scope at depth $(depth))"; fi
  jq -r '"plan coverage: \(.class), \(.unplanned | length) not planned"' "$RUN/coverage.json"
}
plan_record() { if [ -f "$RUN/plan-record/plan-pass.txt" ]; then echo "$RUN/plan-record/plan-pass.txt"; else echo "$RUN/plan-out.txt"; fi; }
plan_mode() { # laptop or runner from the record's own line, as SKILL.md Step 10 says; empty when no pass ran
  [ -f "$RUN/state/plan" ] || return 0
  local m; m="$(sed -n -E 's/^plan pass mode: (laptop|runner)$/\1/p' "$(plan_record)" | head -n 1)"
  if [ -n "$m" ]; then echo "$m"; elif grep -q '^plan:' "$(plan_record)"; then echo runner; fi
}

cmd_skip_coverage() {
  need_full skip-coverage
  [ -f "$RUN/coverage.json" ] || fail "skip-coverage needs plan first"
  # Laptop gate skips, or a runner-mode pass's recorded exceptions, and in either mode the design
  # skips (skip-coverage.md)
  local mode; mode="$(plan_mode)"
  case "$mode" in
    laptop) jq -e 'any(.unplanned[]; .reason | IN("plan gate G1", "plan gate G2", "plan gate G3", "environment (access-denied)"))' "$RUN/coverage.json" > /dev/null ;;
    runner) jq -e 'any(.unplanned[]; .reason | startswith("exception: ") or IN("environment (access-denied)", "environment (refused-host)"))' "$RUN/coverage.json" > /dev/null ;;
    *) false ;;
  esac || { echo "skip-coverage: nothing to check"; return 0; }
  local changed; changed="$(jq -r '.counts.changed_files // ""' "$RUN/index.json")"
  [ -n "$changed" ] && [ -n "$MB" ] && [ -d "$RUN/base" ] ||
    { echo "skip-coverage: not run (no merge base or no changed files count); the skips stay unknowns"; return 0; }
  local sc=(bash "$HERE/skip-coverage.sh")
  rm -f "$RUN/base-gates.txt" "$RUN/skip-check.json"
  "${sc[@]}" gates "$RUN" --tree "$RUN/base" --base "$MB" --coverage "$RUN/coverage.json" --out "$RUN/base-gates.txt" \
    --mode "$mode" > /dev/null 2> "$RUN/state/skip-gates.err" || rm -f "$RUN/base-gates.txt"
  local bg=(); [ ! -f "$RUN/base-gates.txt" ] || bg=(--base-gates "$RUN/base-gates.txt")
  local ad=() adir="$RUN/plan-addresses"; [ "$mode" = laptop ] || adir="$RUN/plan-record"
  [ ! -d "$adir" ] || ad=(--addresses "$adir")
  if "${sc[@]}" check "$RUN" --files "$RUN/host/files.json" --coverage "$RUN/coverage.json" --plan "$(plan_record)" \
      --head "$HEAD_SHA" --base "$MB" --changed-files "$changed" ${ad[@]+"${ad[@]}"} ${bg[@]+"${bg[@]}"} \
      --prefix "$PREFIX" --mode "$mode" > "$RUN/skip-check.json" 2> "$RUN/state/skip-check.err" &&
      jq -e '(.covered | type == "array")' "$RUN/skip-check.json" > /dev/null 2>&1; then
    jq -r '"skip-coverage: \(.covered | length) covered, \(.uncovered | length? // 0) not covered"' "$RUN/skip-check.json"
  else rm -f "$RUN/skip-check.json"; echo "skip-coverage: failed; the skips stay unknowns"; fi
}

cmd_ladder() {
  need_full ladder
  not_run_arg "$@"
  local facts own=() opid
  # Not run for an environment reason: the behaviour object is a step that did not run, a rule 4
  # unknown, and nothing of the step runs. A ladder whose levels alone cannot run needs no token:
  # it gives no record and eval still runs.
  [ ! -e "$RUN/state/ladder-not-run" ] || fail "ladder already ran in this run"
  if [ -n "$NOT_RUN" ]; then
    [ ! -e "$RUN/behaviour/run-behaviour.json" ] && [ ! -e "$RUN/behaviour/record.txt" ] || fail "ladder already ran in this run"
    [ -d "$RUN/behaviour" ] || mkdir "$RUN/behaviour"
    note ladder-not-run "$NOT_RUN"
    jq -n --arg r "ladder not run: $NOT_RUN" '{status: "not-run", reason: $r, triggers: [], claims: [], capped: 0}' \
      > "$RUN/behaviour/run-behaviour.json" || fail "the behaviour object could not be written"
    printf 'behaviour: not run: ladder not run: %s\n' "$NOT_RUN" | tee "$RUN/behaviour/record.txt"
    facts_totals
    return 0
  fi
  facts_bin; opid="$(arg owner_pid)"; [ -z "$opid" ] || own=(--owner-pid "$opid")
  if [ "$(depth)" != light ] && [ -f "$RUN/behaviour/behaviour.json" ] && [ -n "$MB" ]; then
    [ -f "$RUN/coverage.json" ] || fail "ladder needs plan first"
    [ ! -e "$RUN/behaviour/ladder.json" ] || fail "ladder already ran in this run"
    local sch=(); [ ! -f "$RUN/behaviour-schema.json" ] || sch=(--schema "$RUN/behaviour-schema.json")
    bash "$HERE/ladder-pass.sh" run "$RUN" --behaviour "$RUN/behaviour/behaviour.json" --base "$MB" --head "$HEAD_SHA" \
      --out "$RUN/behaviour/ladder.json" --coverage "$RUN/coverage.json" ${sch[@]+"${sch[@]}"} ${own[@]+"${own[@]}"} \
      > "$RUN/state/ladder.out" 2>&1 || rm -f "$RUN/behaviour/ladder.json"
    [ -f "$RUN/behaviour/ladder.json" ] && echo "ladder: record written" || echo "ladder: no record"
  else
    echo "ladder: not run ($( [ "$(depth)" = light ] && echo 'light' || echo 'no classifier output or merge base'))"
  fi
  # The end of Step 5.5: the claims evaluation, at every depth outside a triage run.
  [ -d "$RUN/behaviour" ] || mkdir "$RUN/behaviour"
  local cl=() ld=() wr=()
  [ ! -f "$RUN/behaviour/claims.json" ] || cl=(--claims "$RUN/behaviour/claims.json")
  [ ! -f "$RUN/behaviour/ladder.json" ] || ld=(--ladder "$RUN/behaviour/ladder.json")
  # The generator result of each wrapper versions.tf the change touches (behaviour-pass.md,
  # Wrapper Versions), for eval and the handover; a failed step is no evidence.
  bash "$HERE/behaviour-pass.sh" wrappers --clone "$RUN/clone" --head "$HEAD_SHA" --diff "$RUN/host/files.json" \
    --prefix "$PREFIX" --out "$RUN/behaviour" > /dev/null 2>&1 || rm -f "$RUN/behaviour/wrappers.txt"
  [ ! -f "$RUN/behaviour/wrappers.txt" ] || wr=(--wrappers "$RUN/behaviour/wrappers.txt")
  # The plan diff of the coverage, for the identical mark (behaviour-pass.md, The Run Object)
  [ ! -f "$RUN/coverage.json" ] || wr+=(--plan-diff "$RUN/coverage.json")
  stats_for claims-eval claims-eval
  bash "$HERE/behaviour-pass.sh" eval --facts "$facts" --out "$RUN/behaviour" --head "$HEAD_SHA" \
    --base-sha "${MB:-$HEAD_SHA}" --prefix "$PREFIX" ${SPASS[@]+"${SPASS[@]}"} ${cl[@]+"${cl[@]}"} ${ld[@]+"${ld[@]}"} ${wr[@]+"${wr[@]}"} > /dev/null 2> "$RUN/state/eval.err" ||
    fail "behaviour-pass.sh eval failed"
  facts_totals
  head -n 1 "$RUN/behaviour/record.txt" 2> /dev/null | cut -c1-200
}

# --- the test pass (test-pass.md) ------------------------------------------------------------

needs_tests() { # a non-hcl-dependency trigger, outside a triage run
  [ "$TRIAGE" = false ] && jq -e 'any(.triggers[]?; .category == "non-hcl-dependency")' \
    "$RUN/behaviour/behaviour.json" > /dev/null 2>&1
}
# A merge base Pipfile on stdin: prints python3 or python3.12 when its test script is a plain
# pytest run and its Python is absent, 3.11 or 3.12; else status 1. Read as data, never run.
pipfile_shape() {
  awk '
    /^[[:space:]]*\[[^]]*\][[:space:]]*$/ { sec = $0; gsub(/[][:space:][]/, "", sec); next }
    sec == "scripts" && /^[[:space:]]*test[[:space:]]*=/ { v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); t = v }
    sec == "requires" && /^[[:space:]]*python_version[[:space:]]*=/ { v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); p = v }
    END {
      if (t !~ /^"(python3? -m )?pytest( [-A-Za-z0-9_=.\/:]+)*"[[:space:]]*$/) exit 1
      if (p == "" || p ~ /^"3\.11"[[:space:]]*$/) print "python3"
      else if (p ~ /^"3\.12"[[:space:]]*$/) print "python3.12"
      else exit 1
    }'
}
tests_done() { # dir or empty, result: tests.json and the status line
  jq -n --arg d "$1" --arg r "$2" '{dir: (if $d == "" then null else $d end), result: $r}' > "$RUN/tests.json"
  echo "tests: $2${1:+ in $1}"
}
cmd_tests() {
  need_full tests
  [ ! -e "$RUN/tests.json" ] || fail "tests already ran in this run"
  needs_tests || { tests_done "" "not run: no trigger"; return 0; }
  local py_files dirs dir rp pf py="" kind="" size
  py_files="$(jq -r '.triggers[] | select(.category == "non-hcl-dependency") | .file | select(endswith(".py"))' \
    "$RUN/behaviour/behaviour.json")"
  dirs="$(printf '%s\n' "$py_files" | awk 'NF { if (!sub(/\/[^\/]*$/, "")) $0 = "."; print }' | sort -u)"
  # One directory of changed Python files, a plain path; anything else is out of this pass's scope.
  [ "$(printf '%s\n' "$dirs" | grep -c .)" = 1 ] && plain_ok "$dirs" || { tests_done "" "not run: unsupported"; return 0; }
  dir="$dirs"
  [ -n "$MB" ] && [ -d "$RUN/base" ] || { tests_done "$dir" "not run: no merge base"; return 0; }
  # What to run comes from the merge base alone: its Pipfile, or its requirements-dev.txt naming pytest.
  if [ "$dir" = . ]; then rp="$PREFIX"; else rp="${PREFIX:+$PREFIX/}$dir"; fi
  if pf="$(base_git show "$MB:${rp:+$rp/}Pipfile" 2> /dev/null | head -c 65536)" && [ -n "$pf" ]; then
    py="$(printf '%s\n' "$pf" | pipfile_shape)" && kind=pipenv
  elif base_git show "$MB:${rp:+$rp/}requirements-dev.txt" 2> /dev/null | head -c 65536 |
      grep -Eq '^pytest([^A-Za-z0-9_.-]|$)'; then
    kind=requirements py=python3
  fi
  [ -n "$kind" ] || { tests_done "$dir" "not run: unsupported"; return 0; }
  limit 30 docker info > /dev/null 2>&1 || { tests_done "$dir" "not run: no runner"; return 0; }
  # The head's files of that directory as a tar from the clone's objects; no host path is mounted.
  clone_git archive --format=tar -o "$RUN/state/tests.tar" "HEAD:$rp" 2> /dev/null &&
    size="$(wc -c < "$RUN/state/tests.tar" | tr -d ' ')" && [ "$size" -le 67108864 ] ||
    { rm -f "$RUN/state/tests.tar"; tests_done "$dir" "error archive"; return 0; }
  bash "$HERE/plan-runner/run-tests.sh" --build --archive "$RUN/state/tests.tar" --kind "$kind" --python "$py" \
    --record "$RUN/tests-record" --tmp "$RUN" > "$RUN/state/tests.out" 2> "$RUN/state/tests.err"
  rm -f "$RUN/state/tests.tar"
  local r; r="$(head -n 1 "$RUN/tests-record/tests.txt" 2> /dev/null)"
  [[ "$r" =~ ^(passed|failed)\ [0-9]{1,6}$|^error\ [a-z-]{1,32}$ ]] || r="error runner"
  tests_done "$dir" "$r"
}

# The evidence commands of the depth, each a review-run.sh process of its own whose output goes to
# state/evidence-<step>.out; every step writes only its own state and output files. At deep, where
# no step escalates, schema, verify and the chain plan, skip-coverage, ladder run side by side; in
# laptop mode verify heads the chain, since the plan pass removes an untracked lock file
# verify leaves in the same clone. At light and focused one at a time, the depth read again after
# each step, since an escalation adds the deep steps not yet run.
EV_STEPS="schema verify plan skip-coverage ladder tests"
ev_step() { bash "$HERE/review-run.sh" "$1" "$RUN" > "$RUN/state/evidence-$1.out" 2>&1; }
ev_next() { # the steps this invocation ran: the next step the depth needs, or nothing
  local s
  for s in $EV_STEPS; do
    case " $1 " in *" $s "*) continue ;; esac
    [ "$s" != tests ] || needs_tests || continue
    [ "$(depth)" != light ] || [ "$s" = verify ] || [ "$s" = plan ] || [ "$s" = ladder ] || [ "$s" = tests ] || continue
    echo "$s"; return 0
  done
}
cmd_evidence() {
  need_full evidence
  local t0=$SECONDS rc=0 s ran="" p pids=() chain="plan skip-coverage ladder"
  for s in $EV_STEPS; do rm -f "$RUN/state/evidence-$s.out"; done
  if [ "$(depth)" = deep ]; then
    ev_step schema & pids+=($!)
    # verify first, alone: its init has a fixed time limit that the plan's and the test pass's
    # downloads would eat; in laptop mode the plan pass also removes what verify writes.
    ev_step verify || rc=1
    ! needs_tests || { ev_step tests & pids+=($!); }
    ( for s in $chain; do ev_step "$s" || exit 1; done ) & pids+=($!)
    for p in "${pids[@]}"; do wait "$p" || rc=1; done
  else
    while s="$(ev_next "$ran")" && [ -n "$s" ]; do
      ran="$ran $s"; ev_step "$s" || { rc=1; break; }
      [ ! -e "$RUN/state/stop" ] || { rc=1; break; }
    done
  fi
  { for s in $EV_STEPS; do [ ! -f "$RUN/state/evidence-$s.out" ] || cat "$RUN/state/evidence-$s.out"; done; } | head -n 29
  echo "evidence: depth $(depth), $( [ "$rc" = 0 ] && echo 'done' || echo 'a step failed') ($((SECONDS - t0))s)"
  return "$rc"
}

# --- handover --------------------------------------------------------------------------------

# The verification record, in github-io.md Handover order, from the pass outputs.
# shellcheck disable=SC2016 # jq programs
VERIFY_LINES_JQ='
def side_base: if . == null then ""
  elif .record == "code-result" then (if .validate == 0 then "new under this change" else "already failing at the base" end)
  elif .record == "init-failed" then "already failing at the base"
  elif .record == "absent-at-base" then "absent at base"
  elif .record == "base-unavailable" then "merge base not available"
  elif .record == "not-run-environment" then "merge base not run: environment"
  elif .record == "not-run-limit" then "merge base not run: command limit"
  elif .record == "not-run-budget" then "merge base not run: budget"
  else "merge base not available" end;
def ln: if .line then ": " + .line else "" end;
"example selection: \(.selection.tool)" + (if .selection.fallback then ", fallback \(.selection.fallback)" else "" end)
  + (if .selection.inert then ", inert: nothing to verify" else "" end),
(.dirs[] | "\(.dir) (\(.affected)): " + (
  if .reason == "skipped-version-bump" then "not run: version bump only"
  elif .reason == "skipped-symlink" then "not run: symbolic link"
  elif .head.record == "code-result" then "terraform init -backend=false exit \(.head.init), terraform validate exit \(.head.validate)"
    + (if .head.validate != 0 then (.head | ln) + "; at the merge base: " + (.base | side_base) else "" end)
  elif .head.record == "init-failed" then "terraform init -backend=false exit \(.head.init), init failed" + (.head | ln)
  elif .head.record == "not-run-environment" then "not run: environment" + (.head | ln)
  elif .head.record == "terraform-absent" then "terraform absent"
  elif .head.record == "not-run-limit" then "not run: command limit"
  elif .head.record == "not-run-budget" then "not run: budget"
  else "verification input refused" end)
  + (if .outside then ", outside the sandbox, by authorization" else "" end))'

# The run file's verify_gaps: every example whose check could not run (verify-pass.md, Records).
# shellcheck disable=SC2016
GAPS_JQ='[.dirs[] | {dir, reason: (
  if .reason == "skipped-version-bump" then null
  elif .reason == "skipped-symlink" then "not run: symbolic link"
  elif .head.record == "code-result" then
    (if .head.validate == 0 then null
     elif .base == null then "merge base not available"
     elif .base.record == "base-unavailable" then "merge base not available"
     elif .base.record == "not-run-environment" then "merge base not run: environment"
     elif .base.record == "not-run-limit" then "merge base not run: command limit"
     elif .base.record == "not-run-budget" then "merge base not run: budget"
     else null end)
  elif .head.record == "init-failed" then "init failed"
  elif .head.record == "not-run-environment" then "not run: environment"
  elif .head.record == "terraform-absent" then "terraform was not installed"
  elif .head.record == "not-run-limit" then "not run: command limit"
  elif .head.record == "not-run-budget" then "not run: budget"
  else "verification input refused" end)} | select(.reason != null)]'

record_lines() {
  if [ -f "$RUN/verify.json" ]; then jq -r "$VERIFY_LINES_JQ" "$RUN/verify.json"
  else jq -r '.dirs[] | "\(.dir) (\(.affected)): merge base not available"' "$RUN/selection.json"; fi
  [ ! -f "$RUN/state/runner" ] || cat "$RUN/state/runner"
  [ ! -f "$RUN/state/plan" ] || grep -E '^(plan pass mode:|example:|plan:|scope:|modules:|base:|plan summary:)' "$(plan_record)"
  jq -r '"plan coverage: \(.class)", (.unplanned[] | "not planned: \(.dir): \(.reason)")' "$RUN/coverage.json"
  [ ! -f "$RUN/state/schema-sources.txt" ] || cat "$RUN/state/schema-sources.txt"
  [ ! -s "$RUN/state/schema-lnm.txt" ] || cat "$RUN/state/schema-lnm.txt"
  cat "$RUN/behaviour/record.txt"
  [ ! -f "$RUN/tests.json" ] || jq -r '"tests: " + (if .dir then .dir + ": " else "" end) + .result' "$RUN/tests.json"
}

# The reviewer's reference bundle (github-io.md#reference-bundle): the sections its run reads
# whatever it finds, chosen by the depth and by whether a Terraform file changed.
BUNDLE_CAP=100000
bundle_entries() { # <depth> <checks out of scope, space separated> <hcl true|false> <sheets true|false>
  local d="$1" o=" $2 " hcl="$3" c l allow=""
  case "$d" in light) allow=" A B D G-ladder " ;; focused) allow=" B " ;; esac
  out_of() { case "$o" in *" $1 "*) case "$allow" in *" $1 "*) return 0 ;; esac ;; esac; return 1; }
  printf '%s\n' inputs.md#inputs workflow.md#step-1-establish-scope git-safety.md#the-form \
    large-changes.md#classify-every-changed-path large-changes.md#review-order run/output.md \
    workflow.md#final-step-assemble-the-findings
  for c in A B C D E F G; do out_of "$c" || echo "run/check-$(echo "$c" | tr A-G a-g).md"; done
  [ "$hcl" = false ] || echo run/facts.md
  [ "$4" = false ] || echo large-changes.md#budget
  for c in A B C D E F G; do
    out_of "$c" && continue
    [ "$c" != G ] || ! out_of G-ladder || continue
    case "$c$hcl" in Afalse | Bfalse | Dfalse | Gfalse) continue ;; esac
    case "$c" in
      A) l=check-a-compatibility.md#reads-fails-when-and-severity ;;
      B) l="check-b-coverage.md#reads check-b-coverage.md#which-blocks check-b-coverage.md#rules" ;;
      C) l=check-c-structure.md#reads-fails-when-and-severity ;;
      D) l=check-d-examples.md#reads-fails-when-and-severity ;;
      E) l=check-e-profile.md#reads-fails-when-and-severity ;;
      F) l="check-f-scope.md#reads-fails-when-and-severity check-f-scope.md#the-base-revision" ;;
      G) l=check-g-behaviour.md#reads-fails-when-and-severity ;;
    esac
    printf '%s\n' $l
  done
}

# Writes <file> from the entries on stdin, each as section.sh prints it or the whole file; an
# entry that would take it past BUNDLE_CAP, or that section.sh refuses, is left out and read as
# before. Prints the number of entries left out.
write_bundle() { # <file>
  local r="$HERE/../../terraform-module-reviewer/references" e n skip=0 size=0
  [ -f "$r/section.sh" ] || { echo 0; return; }
  : > "$1.body"; : > "$1.list"
  while IFS= read -r e; do
    { echo "BUNDLE-SECTION references/$e"
      case "$e" in
        *'#'*) bash "$r/section.sh" "$r/${e%%#*}" "${e#*#}" 2> /dev/null ;;
        *) [ ! -L "$r/$e" ] && cat "$r/$e" ;;
      esac; } > "$1.e" || { skip=$((skip + 1)); continue; }
    n=$(wc -c < "$1.e" | tr -d ' ')
    if [ $((size + n)) -gt "$BUNDLE_CAP" ]; then skip=$((skip + 1)); continue; fi
    size=$((size + n))
    cat "$1.e" >> "$1.body"
    echo "references/$e" >> "$1.list"
  done
  [ ! -s "$1.list" ] || {
    echo "Reference bundle of terraform-module-reviewer, written by the host from its own skills checkout. Each section below starts with a line BUNDLE-SECTION <file>#<anchor>, or BUNDLE-SECTION <file> for a whole file, followed by that section's text as section.sh prints it, or the whole file. Sections in this file:"
    cat "$1.list"
    cat "$1.body"
  } > "$1"
  [ -s "$1.list" ] || rm -f "$1"
  rm -f "$1.e" "$1.body" "$1.list"
  echo "$skip"
}

# The module profile (reviewer profile-selection.md): one snapshot with mtf-facts profile-snapshot,
# checked with profile-check --gates, into state/profile.json {label, tree, id, dir, gated}. The
# default profile without a snapshot-capable mtf-facts is read in place with tree "none"; any
# other selection then refuses. Refusals name no path.
MAINT="$(cd "$HERE/../../terraform-module-maintainer" 2> /dev/null && pwd -P)"
module_profile() {
  local id="" dir="" pid src label facts snap tree gated="[]" pc sdir=""
  [ ! -f "$RUN/state/module-profile-args.json" ] || {
    id="$(jq -r '.id' "$RUN/state/module-profile-args.json")"; dir="$(jq -r '.dir' "$RUN/state/module-profile-args.json")"; }
  if [ -n "$dir" ]; then
    [ ! -L "${dir%/}" ] || fail "profile refused: profile snapshot failed"
    src="$(cd -- "$dir" 2> /dev/null && pwd -P)" || fail "profile refused: profile snapshot failed"
    case "$src/" in "$RUN"/*) fail "profile refused: profile-dir lies inside the workspace or a checkout" ;; esac
    local up="$src"
    while [ -n "$up" ]; do
      [ ! -e "$up/.git" ] || fail "profile refused: profile-dir lies inside the workspace or a checkout"
      up="${up%/*}"
    done
    label=custom
  else
    pid="${id:-terraform-aws-modules}"
    if [ -z "$id" ] && [ ! -f "$MAINT/profiles/$pid/PROFILE.md" ]; then
      # The default, with no maintainer checkout beside this skill: nothing to snapshot.
      jq -n '{label: "shipped:terraform-aws-modules", tree: "none", id: "", dir: "", gated: []}' > "$RUN/state/profile.json"
      return 0
    fi
    src="$MAINT/profiles/$pid"
    [ -n "$MAINT" ] && [ -f "$src/PROFILE.md" ] && [ ! -L "$src" ] || fail "profile refused: unknown profile id"
    [ "$(head -n 1 "$src/PROFILE.md")" = "# Profile: $pid" ] || fail "profile refused: shipped profile name does not match its directory"
    label="shipped:$pid"
  fi
  facts_bin
  snap="$(limit 60 "$facts" profile-snapshot --profile-dir "$src" 2> /dev/null)" || snap=""
  tree="$(printf '%s' "$snap" | jq -r 'select(type == "object") | .tree_sha256 // empty' 2> /dev/null)"
  if [[ "$tree" =~ ^[0-9a-f]{64}$ ]]; then
    sdir="$(printf '%s' "$snap" | jq -r '.dir')"
    # The feature from the version report; a binary with none is asked for its help, under the
    # limit and the cap every other call has.
    if ! { facts_has flag:profile-check:profile-dir ||
        { [ "$FACTS_STATE" != ok ] && facts_run 60 1048576 "$facts" profile-check --help | grep -qF 'profile-check --profile-dir'; }; }; then
      rm -rf -- "$sdir"
      if relaxes_text "$src/PROFILE.md"; then fail "profile refused: profile relaxes, and mtf-facts has no profile-check or in_repo_downgrade"; fi
      fail "profile refused: profile-check failed"
    fi
    pc="$(limit 60 "$facts" profile-check --profile-dir "$sdir" --gates 2> /dev/null)" || pc=""
    rm -rf -- "$sdir"
    printf '%s' "$pc" | jq -e '.valid == true' > /dev/null 2>&1 || fail "profile refused: profile-check failed"
    gated="$(printf '%s' "$pc" | jq -c 'if .relaxing then [.gated_rules[]?] else [] end')"
  elif [ "$label" = shipped:terraform-aws-modules ] && [ -z "$dir" ]; then tree=none
  elif relaxes_text "$src/PROFILE.md"; then fail "profile refused: profile relaxes, and mtf-facts has no profile-check or in_repo_downgrade"
  else fail "profile refused: profile snapshot failed"
  fi
  jq -n --arg l "$label" --arg t "$tree" --arg id "$id" --arg d "$dir" --argjson g "$gated" \
    '{label: $l, tree: $t, id: $id, dir: $d, gated: $g}' > "$RUN/state/profile.json"
}
# A profile-options value other than its default, read only to refuse (profile-selection.md).
relaxes_text() {
  awk '/^```profile-constants$/ { b = 1; o = 0; next } b && /^```$/ { b = 0; next }
    b && $0 == "name: profile-options" { o = 1; next }
    o && /^(consumers: in-repo|partitions: fixed|examples: none|release: none)$/ { f = 1 }
    END { exit !f }' "$1" 2> /dev/null
}

# The host's README evidence (readme-regions.md): readme-regions.sh on the clone's objects at the
# head, which runs the maintainer's terraform-docs pass on a copy. A failed step is no evidence.
readme_regions() {
  rm -rf "$RUN/readme" && mkdir "$RUN/readme" || return 0
  bash "$HERE/readme-regions.sh" --clone "$RUN/clone" --head "$HEAD_SHA" --diff "$RUN/host/files.json" \
    --prefix "$PREFIX" --out "$RUN/readme" > /dev/null 2>&1 || rm -f "$RUN/readme/regions.txt"
}

# The host's vendored policy evidence (vendored-policy.md): the module profile's sources, the
# pull request body's tag, the clone's objects at the head and the bound merge base. A failed step,
# or no profile directory, is no evidence.
vendored_policy() { # task file, block id, merge base, new module (true or false)
  local pd="" id
  rm -rf "$RUN/vendored"
  # No evidence for a triage run, a new module or a change with no merge base, which has no base
  # to compare.
  [ "$TRIAGE" = false ] && [ "$4" = false ] && [ -n "$3" ] || return 0
  # Nor for a host that selects the judgment variant: its prefix leaves out the reviewer's evidence
  # section for the size cap, so such a run keeps the rules it had (vendored-policy.md).
  [ "${MODULESTF_FACTS_VARIANT:-full}" != judgment ] || return 0
  mkdir "$RUN/vendored" || return 0
  pd="$(jq -r '.dir' "$RUN/state/profile.json" 2> /dev/null)"
  if [ -z "$pd" ]; then
    id="$(jq -r '.id' "$RUN/state/profile.json" 2> /dev/null)"
    [ -n "$MAINT" ] || return 0
    pd="$MAINT/profiles/${id:-terraform-aws-modules}"
  fi
  [ -d "$pd" ] || return 0
  awk -v s="$2" 'index($0, "ITEM-" s " ") == 1 { p = ($0 ~ / kind=body( |$)/); next }
    $0 == "UNTRUSTED-" s " END" { p = 0 } p' "$1" > "$RUN/vendored/body.txt" 2> /dev/null || return 0
  local ba=(); [ -z "$3" ] || ba=(--base "$3")
  bash "$HERE/vendored-policy.sh" --clone "$RUN/clone" --head "$HEAD_SHA" ${ba[@]+"${ba[@]}"} --diff "$RUN/host/files.json" \
    --prefix "$PREFIX" --repo "$(jq -r '.repo' "$RUN/host/host.json")" --body "$RUN/vendored/body.txt" \
    --profile-dir "$pd" --out "$RUN/vendored" > /dev/null 2>&1 || rm -f "$RUN/vendored/vendored.txt"
}

# vendored_ok: the handover states the lines: outside a triage run, at most 400, each in the grammar.
vendored_ok() {
  [ "$TRIAGE" = false ] && [ -s "$RUN/vendored/vendored.txt" ] && [ "$(wc -l < "$RUN/vendored/vendored.txt")" -le 400 ] &&
    ! grep -qvE "$VP_LINE_RE" "$RUN/vendored/vendored.txt"
}
# vendored_equal: the documents the handover's Vendored policy lines found equal to upstream, as
# [{file, first, last}], from the lines the handover states, or [] when it stated none.
vendored_equal() {
  if vendored_ok; then
    jq -R -n '[inputs | split(" ") | {k: (.[0] + " " + .[1]), f: .[0], fact: .[2:]}] | group_by(.k)
      | map(select(any(.[]; .fact == ["upstream", "equal"])) | (map(select(.fact[0] == "lines"))[0].fact) as $l
        | select($l != null) | {file: .[0].f, first: ($l[1] | tonumber), last: ($l[2] | tonumber)})' "$RUN/vendored/vendored.txt"
  else echo '[]'; fi
}

# vendored_raise <equal documents>: the findings on stdin, each LOW compat.generated-policy-narrowed
# finding whose line is in no equal document of its file raised to HIGH (vendored-policy.md).
vendored_raise() {
  jq --slurpfile e "$1" '[.[] | if .rule_id == "compat.generated-policy-narrowed" and .severity == "LOW"
      and ((.file as $f | .line as $l | any($e[0][]; .file == $f and ($l | type == "number") and .first <= $l and $l <= .last)) | not)
    then .severity = "HIGH" else . end]'
}

cmd_handover() {
  ready handover
  module_profile
  if [ -f "$RUN/depth.json" ]; then
    bash "$HERE/depth.sh" verify "$RUN/depth.json" --clone "$RUN/clone" > /dev/null 2>&1 ||
      fail "depth.sh verify: the depth binding does not match the clone; the run stops"
  fi
  local t="$RUN/host/task.md" s n out="$RUN/handover" nk
  rm -rf "$out"; mkdir "$out"
  # Over the review budget: the task without the skipped files' diff. The task's diff has one part
  # per file with a patch, in files list order, each opened by a "diff --git " line, which no patch
  # line can be; the n-th part is dropped when the n-th such file is skipped. Only the lines before
  # the block preamble are cut, and the cut ends at the diff's closing fence: the untrusted block
  # stays as it was, whatever text it holds.
  nk="$(jq length "$RUN/skipped.json" 2> /dev/null)" || fail "skipped.json cannot be read"
  if [ "$nk" != 0 ]; then
    n="$(grep -n -m1 '^The block below holds text quoted' "$t" | cut -d: -f1)"
    [[ "$n" =~ ^[0-9]+$ ]] || fail "task.md has no block preamble"
    jq -r --slurpfile k "$RUN/skipped.json" '[.[] | select(.patch != null)] | to_entries[]
      | select(.value.filename | IN($k[0][])) | .key + 1' "$RUN/host/files.json" > "$RUN/state/skip-parts.txt" ||
      fail "the skipped files cannot be listed"
    { head -n $((n - 1)) "$t" | SF="$RUN/state/skip-parts.txt" awk 'BEGIN { while ((getline l < ENVIRON["SF"]) > 0) k[l] = 1 }
        p == 3 { print; next }
        p == 1 && $0 == f { p = 3; print; next }
        p == 1 && /^diff --git / { i++; drop = (i in k) }
        p == 1 && drop { next }
        p == 2 { f = $0; sub(/diff$/, "", f); p = 1; print; next }
        /^The diff:$/ { p = 2; i = 0 }
        { print }'
      tail -n +"$n" "$t"; } > "$RUN/state/task-budget.md" || fail "the task cannot be cut to the budget"
    t="$RUN/state/task-budget.md"
  fi
  s="$(sed -n 's/^UNTRUSTED-\([0-9a-f]\{12\}\) BEGIN$/\1/p' "$t")"
  [[ "$s" =~ ^[0-9a-f]{12}$ ]] && [ "$(grep -c "^UNTRUSTED-$s END\$" "$t")" = 1 ] && [ "$(tail -n 1 "$t")" = "UNTRUSTED-$s END" ] ||
    fail "task.md has no single untrusted block"
  n="$(grep -n -m1 '^The block below holds text quoted' "$t" | cut -d: -f1)"
  [[ "$n" =~ ^[0-9]+$ ]] || fail "task.md has no block preamble"
  if [ "$TRIAGE" = false ]; then record_lines > "$out/record.txt" || fail "the record could not be assembled"; fi
  [ "$TRIAGE" = true ] || readme_regions
  # The merge base the depth was bound to, for the reviewer's mtf-facts --merge-base-sha.
  local mbl="$MB" nm=false
  [ ! -f "$RUN/depth.json" ] || mbl="$(jq -r '.binding.merge_base' "$RUN/depth.json")"
  [[ "$mbl" =~ $sha_re ]] || mbl=""
  # An empty base: the task states the new module shape and names no diff, since the reviewer
  # ignores that statement beside a diff, and mtf-facts then runs without --base and --diff.
  jq -e '.new_module == true' "$RUN/index.json" > /dev/null 2>&1 && nm=true && mbl=""
  vendored_policy "$t" "$s" "$mbl" "$nm"
  vendored_equal > "$RUN/state/vendored-equal.json"
  rm -rf "$RUN/review"; mkdir "$RUN/review"
  # The reference bundle, outside a triage run: depth.json as the reviewer reads it, and
  # whether a Terraform file changed (a new module, or files.json that cannot be read, counts).
  local left="" dp=deep oos="" hcl=true sheets=false
  if [ "$TRIAGE" = false ]; then
    if [ -f "$RUN/depth.json" ]; then
      dp="$(jq -r 'if .format == 1 and (.depth == "light" or .depth == "focused") then .depth else "deep" end' "$RUN/depth.json")"
      oos="$(jq -r '[(.checks_out_of_scope // [])[] | strings] | join(" ")' "$RUN/depth.json")"
    fi
    if [ "$nm" = false ] && [ -f "$RUN/host/files.json" ]; then
      jq -e 'any(.[]; (.filename // "") | test("\\.(tf|tofu|hcl)(\\.json)?$"))' "$RUN/host/files.json" > /dev/null 2>&1
      [ $? != 1 ] || hcl=false
    fi
    [ "$(cat "$RUN/state/schema" 2> /dev/null)" != ok ] || [ ! -d "$RUN/facts" ] || sheets=true
    left="$(bundle_entries "$dp" "$oos" "$hcl" "$sheets" | write_bundle "$out/reviewer-references.md")"
  fi
  # The diff of the task, module-root-relative, as a file the reviewer's mtf-facts lint reads.
  awk 'p == 1 && $0 == f { exit } p == 1 { print; next } p == 2 { f = $0; sub(/diff$/, "", f); p = 1; next }
       /^The diff:$/ { p = 2 }' "$t" > "$out/change.diff"
  {
    printf 'Workspace: %s\n' "$MROOT"
    head -n $((n - 1)) "$t" | awk -v nm="$nm" '
      nm == "true" && p == 0 && $0 == "Changed paths:" {
        print "New module: the workspace holds a whole module with no base. Its merge base holds no file under the module root, so every file in the workspace, .git/ excluded, is added."
        p = 1; next }
      p == 1 && $0 == "The diff:" { p = 2; next }
      p == 2 { f = $0; sub(/diff$/, "", f); p = 3; next }
      p == 3 { if ($0 == f) p = 4; next }
      p == 1 { next }
      { print }'
    # The skipped files, a name shown only in the charset of the comment's names, the rest counted.
    if [ "$nk" != 0 ]; then
      if [ "$nm" = true ]; then
        printf 'Review budget: the new module is over %s bytes of added text, so the files below are not reviewed. Report no finding on them; the host lists them as not reviewed.\n' "$REVIEW_BUDGET"
      else
        printf 'Review budget: the change is over %s bytes of diff, so the diff above leaves out the changed files below. They are not reviewed: report no finding on them; the host lists them as not reviewed.\n' "$REVIEW_BUDGET"
      fi
      jq -r --arg p "$PREFIX" 'map(if $p == "" then . else ltrimstr($p + "/") end) as $l
        | ($l[] | select(test("^[A-Za-z0-9._/-]+$")) | "- \(.)"),
          ([$l[] | select(test("^[A-Za-z0-9._/-]+$") | not)] | length | select(. > 0) | "- and \(.) more whose names hold other characters")' "$RUN/skipped.json"
    fi
    grep -qxF "$WRITE_SHORT" "$t" || printf '%s\n' "$WRITE_SHORT"
    [ ! -f "$RUN/depth.json" ] || [ "$TRIAGE" = true ] || printf 'Depth: %s\n' "$RUN/depth.json"
    [ "$(cat "$RUN/state/schema" 2> /dev/null)" != ok ] || [ ! -d "$RUN/facts" ] || printf 'Provider fact sheets: %s\n' "$RUN/facts"
    [ "$(cat "$RUN/state/schema" 2> /dev/null)" != ok ] || [ ! -f "$RUN/schema-handoff/schema-handoff.json.gz" ] ||
      printf 'Schema handoff: %s\n' "$RUN/schema-handoff/schema-handoff.json.gz"
    # A latest the mirror lacked: the latest schema of these providers was not read.
    [ "$(cat "$RUN/state/schema" 2> /dev/null)" != ok ] || [ ! -s "$RUN/state/schema-lnm.txt" ] ||
      sed 's/^schema pass: latest_not_mirrored /Latest not mirrored: /' "$RUN/state/schema-lnm.txt"
    [ "$nm" = true ] || printf 'Diff: %s\n' "$out/change.diff"
    [ -z "$mbl" ] || printf 'Merge base: %s\n' "$mbl"
    base_tree_line "$nm" "$mbl"
    # The base repository as its own fact line, from host.json in the grammar valid_host holds it to,
    # with no name of dots: Check E reads the repository's own wrapper address from it.
    jq -r 'select(.repo | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$")
      and (test("/[.]+$") | not)) | "Base repository: \(.repo)"' "$RUN/host/host.json" 2> /dev/null || true
    # The host's mtf-facts as one fact line from facts-resolve.sh (review-run-details.md, section "The mtf-facts line").
    [ ! -s "$RUN/state/facts" ] || head -n 1 "$RUN/state/facts" | grep -E '^mtf-facts: [ -~]+$' || true
    facts_bin_line
    # The host's wrapper evidence as its own fact lines, read as eval reads it: every line in the
    # grammar of behaviour-pass.sh wrappers and at most 256 of them, or no line at all.
    if [ "$TRIAGE" = false ] && [ -f "$RUN/behaviour/wrappers.txt" ] && [ "$(wc -l < "$RUN/behaviour/wrappers.txt")" -le 256 ] &&
        ! grep -qvE "$WRAP_LINE_RE" "$RUN/behaviour/wrappers.txt"; then
      sed 's/^/Wrapper versions: /' "$RUN/behaviour/wrappers.txt"
    fi
    jq -r 'if .dir != "" then "profile-dir: \(.dir)" elif .id != "" then "profile: \(.id)" else empty end,
      (select(.tree != "none") | "Profile tree: \(.tree)"),
      (select(.gated != []) | "Gated rules: \(.gated | join(" "))")' "$RUN/state/profile.json"
    # The README evidence as host fact lines: every line in the grammar of readme-regions.sh and at
    # most 256 of them, or no line at all.
    if [ "$TRIAGE" = false ] && [ -s "$RUN/readme/regions.txt" ] && [ "$(wc -l < "$RUN/readme/regions.txt")" -le 256 ] &&
        ! grep -qvE "$REGION_LINE_RE" "$RUN/readme/regions.txt"; then
      sed 's/^/README regions: /' "$RUN/readme/regions.txt"
    fi
    # The vendored policy evidence as host fact lines: every line in the grammar of
    # vendored-policy.sh and at most 400 of them, or no line at all.
    ! vendored_ok || sed 's/^/Vendored policy: /' "$RUN/vendored/vendored.txt"
    # Our earlier review, only with a record that checked out: its blocking findings for the
    # reviewer to judge at the head (findings-schema.md, Earlier Review Task Line).
    # The findings are earlier review output that can quote the change: the file holds them inside an
    # untrusted block of its own suffix, as the task's block holds the pull request's text.
    local es=""
    es="$(openssl rand -hex 6 2> /dev/null)" || es=""
    if [[ "$es" =~ ^[0-9a-f]{12}$ ]] && jq -e '.record == "ok"' "$RUN/earlier.json" > /dev/null 2>&1 &&
        { printf 'UNTRUSTED-%s BEGIN\n' "$es"; jq '.findings' "$RUN/earlier.json" && printf 'UNTRUSTED-%s END\n' "$es"; } > "$out/earlier-task.txt"; then
      printf 'Earlier review: %s\n' "$out/earlier-task.txt"
      printf 'Output: write the findings list as JSON to %s, the summary line and the profile lines to %s, the facts comparison note to %s and the earlier review judgments as JSON to %s, and nothing else.\n' \
        "$RUN/review/findings.json" "$RUN/review/summary.txt" "$RUN/review/facts-comparison.txt" "$RUN/review/earlier.json"
    else
      printf 'Output: write the findings list as JSON to %s, the summary line and the profile lines to %s and the facts comparison note to %s, and nothing else.\n' \
        "$RUN/review/findings.json" "$RUN/review/summary.txt" "$RUN/review/facts-comparison.txt"
    fi
    [ ! -f "$out/reviewer-references.md" ] || printf 'References: %s\n' "$out/reviewer-references.md"
    sed -n "$n,\$p" "$t" | sed '$d'
    [ "$TRIAGE" = true ] || { printf 'RECORD-%s\n' "$s"; cat "$out/record.txt"; }
    printf 'UNTRUSTED-%s END\n' "$s"
  } > "$out/task.md"
  [ ! -f "$RUN/depth.json" ] || cp "$RUN/state/depth.sha256" "$RUN/state/handover.sha256"
  # The skipped files the reviewer was handed, pinned as the depth is: render refuses another list.
  shasum -a 256 < "$RUN/skipped.json" | cut -d' ' -f1 > "$RUN/state/skipped.sha256"
  # The earlier review the reviewer was handed, pinned the same way.
  [ ! -f "$RUN/earlier.json" ] || shasum -a 256 < "$RUN/earlier.json" | cut -d' ' -f1 > "$RUN/state/earlier.sha256"
  echo "handover: $out/task.md ($(wc -l < "$out/task.md" | tr -d ' ') lines, record $( [ -f "$out/record.txt" ] && wc -l < "$out/record.txt" | tr -d ' ' || echo 0) lines)"
  [ ! -f "$out/reviewer-references.md" ] ||
    echo "references: $out/reviewer-references.md ($(wc -c < "$out/reviewer-references.md" | tr -d ' ') bytes, ${left:-0} sections left out)"
  echo "reviewer: one read-only subagent, workspace $MROOT, task text $out/task.md, output in $RUN/review"
}

# --- render ----------------------------------------------------------------------------------

cmd_render() {
  local findings="" assessment="" summary="" out="" std=() ev=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --findings) findings="${2-}"; shift 2 || die "--findings needs a value" ;;
      --assessment) assessment="${2-}"; shift 2 || die "--assessment needs a value" ;;
      --summary) summary="${2-}"; shift 2 || die "--summary needs a value" ;;
      --out) out="${2-}"; shift 2 || die "--out needs a value" ;;
      --standard) std=(--standard); shift ;;
      --event) [[ "${2-}" =~ ^(COMMENT|APPROVE|REQUEST_CHANGES)$ ]] || die "--event takes COMMENT, APPROVE or REQUEST_CHANGES"
        ev=(--event "$2"); shift 2 ;;
      *) die "unexpected argument" ;;
    esac
  done
  # The reviewer's output files of the handover, unless named; facts-comparison.txt is not read.
  [ -n "$findings" ] || findings="$RUN/review/findings.json"
  [ -n "$summary" ] || [ ! -f "$RUN/review/summary.txt" ] || summary="$RUN/review/summary.txt"
  [ -f "$findings" ] && [ ! -L "$findings" ] || die "--findings must be a regular file (default <run>/review/findings.json)"
  [ -f "$assessment" ] || die "--assessment must be a file"
  ready render
  [ -f "$RUN/handover/task.md" ] || fail "render needs handover first"
  # The depth the reviewer was handed is the depth rendered.
  [ ! -f "$RUN/depth.json" ] || [ "$(cat "$RUN/state/handover.sha256" 2> /dev/null)" = "$(cat "$RUN/state/depth.sha256")" ] ||
    stop "depth.json changed after the handover"
  [ "$(shasum -a 256 < "$RUN/skipped.json" 2> /dev/null | cut -d' ' -f1)" = "$(cat "$RUN/state/skipped.sha256" 2> /dev/null)" ] ||
    stop "skipped.json changed after the handover"
  if [ -e "$RUN/earlier.json" ] || [ -e "$RUN/state/earlier.sha256" ]; then
    [ -f "$RUN/earlier.json" ] && [ ! -L "$RUN/earlier.json" ] &&
      [ "$(shasum -a 256 < "$RUN/earlier.json" | cut -d' ' -f1)" = "$(cat "$RUN/state/earlier.sha256" 2> /dev/null)" ] ||
      stop "earlier.json changed after the handover"
  fi
  case "$out" in /?*) ;; *) die "--out must be an absolute path" ;; esac
  [ -d "$out" ] || mkdir -p -- "$out" || die "--out cannot be made"
  local f; for f in plan.json plan.json.tmp fix-plan.md fix-plan.md.tmp carried.json carried.json.tmp; do
    [ ! -e "$out/$f" ] || fail "the output directory already holds $f"
  done
  if [ -f "$RUN/depth.json" ]; then
    bash "$HERE/depth.sh" verify "$RUN/depth.json" --clone "$RUN/clone" > /dev/null 2>&1 ||
      fail "depth.sh verify: the depth binding does not match the clone; nothing is rendered"
  fi
  local r="$RUN/render"; rm -rf "$r"; mkdir "$r"
  jq -e 'type == "array"' "$findings" > /dev/null 2>&1 || fail "the findings are not a JSON list"
  # A LOW compat.generated-policy-narrowed answer stands only inside a document the handover's
  # Vendored policy lines found equal to its upstream source (state/vendored-equal.json, which
  # handover writes); any other is raised to HIGH.
  jq -e 'type == "array"' "$RUN/state/vendored-equal.json" > /dev/null 2>&1 || echo '[]' > "$RUN/state/vendored-equal.json"
  vendored_raise "$RUN/state/vendored-equal.json" < "$findings" | jq '[.[] | . + {source: "llm"}]' > "$r/findings.json"
  # The three counts of the reviewer's summary line; absent means 0, a malformed one drops them all.
  local counts=null
  if [ -n "$summary" ] && [ -f "$summary" ]; then
    # The reviewer's summary line (findings-schema.md): the line that starts with "summary: ", else
    # the first line.
    counts="$( { grep -m1 '^summary: ' "$summary" || head -n 1 "$summary"; } | jq -R -c '
      def n($k): [scan("(?:^|[ ,;.])" + ($k | gsub("\\."; "\\.")) + ":([^ ,;]*)")[0]] | .[0] // "0";
      {"instruction-like-text-from-others": n("instruction-like-text-from-others"),
       "conversation-claims-unread": n("conversation-claims-unread"),
       "review.quoted-claim-unverifiable": n("review.quoted-claim-unverifiable")}
      | if all(.[]; test("^[0-9]{1,6}$")) then map_values(tonumber) else null end')" || counts=null
  fi
  # The reviewer's profile line must be the profile handed over (profile-selection.md, Output).
  local pl want
  pl="$( { [ -n "$summary" ] && [ -f "$summary" ] && grep -m1 '^profile: ' "$summary"; } || true)"
  if [ -f "$RUN/state/profile.json" ]; then
    want="$(jq -r '"profile: \(.label) profile_tree_sha256:\(.tree)"' "$RUN/state/profile.json")"
    if [ "$pl" = "profile: refused" ]; then
      local why
      why="$(jq -r '[.[] | select((.summary // "") | startswith("profile refused: ")) | .summary][0] // "profile refused"' "$findings" 2> /dev/null |
        head -n 1 | tr -cd 'a-z0-9 :_-' | cut -c1-120)"
      fail "the reviewer refused the profile (${why:-profile refused}); nothing is rendered"
    elif [ -n "$pl" ]; then [ "$pl" = "$want" ] || fail "the reviewer's profile line does not match the handover; nothing is rendered"
    else jq -e '.label == "shipped:terraform-aws-modules" and .tree == "none"' "$RUN/state/profile.json" > /dev/null ||
      fail "the reviewer reported no profile line; nothing is rendered"
    fi
  fi
  build_run_file "$counts" > "$r/run-file.json" || fail "the run file could not be built"
  local line rc
  line="$(bash "$HERE/render-comment.sh" --head "$HEAD_SHA" --findings "$r/findings.json" --host "$RUN/host/host.json" \
    --checks "$RUN/checks" --run "$r/run-file.json" --assessment "$assessment" --run-dir "$RUN" --out "$out" \
    --links ${std[@]+"${std[@]}"} ${ev[@]+"${ev[@]}"} 2>&1)"
  rc=$?
  printf '%s\n' "$line" | head -n 20
  [ "$rc" = 0 ] || exit 1
  # verdict.md, Clamps: the self-authored row is this run's own, so it is applied here and not in
  # result.json, whose proposed_event is data for an adapter (render-output.md).
  jq -r --slurpfile h "$RUN/host/host.json" --slurpfile a "$RUN/state/args.json" '
    select($h[0].state.self_authored and .proposed_event != "COMMENT" and ($a[0].render_only | not) and $a[0].posting == "enabled")
    | "clamp: own pull request, propose COMMENT in place of \(.proposed_event)"' "$out/result.json"
  echo "body: $out/comment.md"
  jq -r '"identity: \(.login | if . == "" then "none" else . end), posting \(.posting)" + (if .render_only then ", render-only" else "" end)' "$RUN/state/args.json"
  write_plan "$out"
  [ ! -f "$out/plan.json" ] || write_carried "$out" "$r/run-file.json"
}

# plan.json (stage-contract.md, review-plan): after result.json, the pull request read again once and
# compared with the pin prepare saved, then the file built by jq from files, written to plan.json.tmp,
# checked with stage_ok and renamed. The body and result.json stay; a plan that cannot be written,
# a moved pin included, is skipped and the render still exits 0.
write_plan() { # out directory
  local o="$1" t="$RUN/handover/task.md" s d
  skip() { echo "plan: not written, $1"; rm -f "$o/plan.json.tmp"; return 0; }
  [ -f "$RUN/state/pin.json" ] && [ -f "$RUN/state/stage.json" ] || { skip "prepare recorded no valid pin"; return 0; }
  gh api "repos/$(arg repo)/pulls/$(arg pr)" > "$RUN/state/pr-live.json" 2> /dev/null ||
    { skip "the pull request could not be read again"; return 0; }
  d="$(jq -r -L "$HERE" --slurpfile pin "$RUN/state/pin.json" --arg mb "$MB" 'include "stage-contract";
    ({pr: ., merge_base: $mb} | live_pin) as $l | $pin[0] | pin_diff($l) // ""' "$RUN/state/pr-live.json" 2> /dev/null)" ||
    { skip "the pull request could not be read again"; return 0; }
  [ -z "$d" ] || { skip "the pull request moved during the review: $d"; return 0; }
  s="$(sed -n 's/^UNTRUSTED-\([0-9a-f]\{12\}\) BEGIN$/\1/p' "$t")"
  [[ "$s" =~ ^[0-9a-f]{12}$ ]] || { skip "task.md has no single untrusted block"; return 0; }
  sed -n "/^UNTRUSTED-$s BEGIN\$/,/^UNTRUSTED-$s END\$/p" "$t" > "$RUN/state/block.txt"
  jq -n --slurpfile pin "$RUN/state/pin.json" --slurpfile res "$o/result.json" --slurpfile fnd "$o/findings.json" \
    --slurpfile st "$RUN/state/stage.json" --rawfile hb "$RUN/state/block.txt" --arg prefix "$PREFIX" \
    --arg mp "$(jq -r '.id // ""' "$RUN/state/profile.json" 2> /dev/null)" \
    '{kind: "review-plan", schema: 1, pin: $pin[0], verdict: $res[0].verdict, proposed_event: $res[0].proposed_event,
      findings: $fnd[0], read_at: $st[0].read_at, handover_block: ($hb | rtrimstr("\n")), module_prefix: $prefix,
      module_profile: (if $mp == "" then null else $mp end), reviewer_id: $st[0].reviewer_id}' > "$o/plan.json.tmp" 2> /dev/null &&
    jq -e -L "$HERE" 'include "stage-contract"; stage_ok("review-plan")' "$o/plan.json.tmp" > /dev/null 2>&1 &&
    mv -- "$o/plan.json.tmp" "$o/plan.json" || { skip "the plan could not be built"; return 0; }
  echo "plan: $o/plan.json"
  # fix-plan.md (render-output.md): the readable preview, from plan.json alone, whenever it exists.
  jq -j -L "$HERE" 'include "fix-plan"; fix_plan' "$o/plan.json" > "$o/fix-plan.md.tmp" 2> /dev/null &&
    mv -- "$o/fix-plan.md.tmp" "$o/fix-plan.md" ||
    { rm -f "$o/fix-plan.md.tmp"; echo "fix-plan: not written, the preview could not be built"; return 0; }
  echo "fix-plan: $o/fix-plan.md"
}

# The provider floors the schema pass read (verdict.md, Provider floor changes): one entry per
# directory and provider of versions.json with both a minimum and an old floor, read when both
# versions were published, each with its index.json, and missing.json lists no type of that
# provider at either. Bound to the head and the merge base the depth was bound to. Prints
# nothing and fails when the pass left no versions.json or no binding.
floors_of() {
  local mbs v="$RUN/facts/versions.json" miss='{"missing": []}'
  [ -f "$v" ] && [ ! -L "$v" ] || return 1
  mbs="$(jq -r '.binding.merge_base // ""' "$RUN/depth.json" 2> /dev/null)"
  [[ "$mbs" =~ $sha_re ]] || return 1
  [ ! -f "$RUN/facts/missing.json" ] || miss="$(cat "$RUN/facts/missing.json")"
  # A provider whose floor the pass could not resolve, an old floor unresolved, the pair
  # unresolved or a source outside the grammar, gives an entry with no versions that is never read.
  local list; list="$(jq -c '[.directories | to_entries[] | .key as $d | .value | to_entries[]
      | (.key | test("^[a-z0-9][a-z0-9-]{0,63}/[a-z0-9][a-z0-9-]{0,63}$")) as $ok
      | if $ok and .value.minimum? and .value.old_floor? then
          {dir: $d, provider: .key, old_floor: .value.old_floor, floor: .value.minimum}
        elif $ok and .value.minimum? and (.value.old_floor_none? | IN("no_entry", "no_lower_bound")) and (.value.old_floor_unresolved? | not) then
          {dir: $d, provider: .key, old_floor: null, floor: .value.minimum, old_floor_none: .value.old_floor_none}
        elif ($ok | not) or .value.unresolved? or .value.old_floor_unresolved? or .value.old_floor? then
          {dir: $d, provider: (if $ok then .key else null end), old_floor: null, floor: null, unresolved: true}
        else empty end] | unique_by([.dir, .provider])' "$v")" || return 1
  # Over the render's 256 entries no list is written, never a cut one: a cut list could leave a
  # directory with only its read entries, and without floors no trigger is cleared by them.
  [ "$(jq length <<< "$list")" -le 256 ] || return 1
  local out='[]' e dir prov of fv read
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    prov="$(jq -r .provider <<< "$e")"; of="$(jq -r .old_floor <<< "$e")"; fv="$(jq -r .floor <<< "$e")"
    read=false
    # An explicit none has no old floor to read: read is the head floor alone.
    [ "$of" != null ] || [ "$(jq -r '.old_floor_none // ""' <<< "$e")" = "" ] || of="$fv"
    if [ "$(jq -r '.unresolved // false' <<< "$e")" = false ] && [ "$of" != null ] && [ -f "$RUN/facts/$prov/$of/index.json" ] && [ -f "$RUN/facts/$prov/$fv/index.json" ] &&
      jq -e --arg p "$prov" --arg a "$of" --arg b "$fv" \
        'all(.missing[]?; .provider != $p or (any(.versions[]?; . == $a or . == $b) | not))' <<< "$miss" > /dev/null 2>&1; then
      read=true
    fi
    out="$(jq -c --argjson e "$e" --argjson r "$read" '. + [$e + {read: $r} | del(.unresolved)]' <<< "$out")" || return 1
  done < <(jq -c '.[]' <<< "$list")
  jq -c -n --arg h "$HEAD_SHA" --arg b "$mbs" --argjson d "$out" '{head_sha: $h, base_sha: $b, dirs: $d}'
}

# The run file's earlier (render-comment.sh): earlier.json with the reviewer's judgment of each
# blocking finding from review/earlier.json. A judgments file that is missing, a link, over its cap,
# not one JSON document or not one entry per finding in its shape leaves every finding not judged,
# so the block stands. A resolved judgment counts only when its file is a file of the head under the
# module root and its line is in it; else that finding is not judged.
earlier_of() {
  local j="$RUN/review/earlier.json" jud='null' heads='{}' e f l n
  if [ -f "$j" ] && [ ! -L "$j" ] && [ "$(wc -c < "$j")" -le 262144 ]; then
    jud="$(jq -c -s 'if length == 1 then .[0] else null end' "$j" 2> /dev/null)" || jud='null'
  fi
  # The line count at the head of each place a resolved judgment names, from the clone's objects in
  # the safe form: only a regular file, mode 100644 or 100755, counts; a link, a directory or a
  # submodule does not.
  local t sha
  while IFS= read -r e; do
    f="$(jq -r .file <<< "$e")"; l="$(jq -r .line <<< "$e")"
    t="$(safe_clone_git ls-tree HEAD -- "${PREFIX:+$PREFIX/}$f" 2> /dev/null)" || continue
    [[ "$t" =~ ^100(644|755)\ blob\ ([0-9a-f]{40,64})$'\t' ]] && [ "${t#*$'\t'}" = "${PREFIX:+$PREFIX/}$f" ] || continue
    sha="${BASH_REMATCH[2]}"
    n="$(safe_clone_git cat-file blob "$sha" 2> /dev/null | awk 'END { print NR }')"
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$l" -le "$n" ] 2> /dev/null || continue
    heads="$(jq -c --arg k "$f:$l" '. + {($k): true}' <<< "$heads")"
  done < <(jq -c "$EARLIER_JQ"' if type == "array" then .[] | objects | select(.judgment == "resolved" and (.file | plain)
      and (.line | type == "number" and . >= 1 and . == floor and . <= 10000000)) | {file, line} else empty end' <<< "${jud:-null}" 2> /dev/null)
  # The judgments reach jq on a descriptor: at the 262144 byte cap they are over one argument's limit.
  jq -c --slurpfile j <(printf '%s' "${jud:-null}") --argjson heads "$heads" "$EARLIER_JQ"'
    ($j[0]) as $j | .findings as $f
    | ($j | type == "array" and all(.[]; type == "object"
         and keys == ["file", "id", "judgment", "line"] and (.id | type == "string")
         and (.judgment | IN("resolved", "partly", "not resolved"))
         and (.file == null or (.file | plain)) and (.line == null or (.line | type == "number" and . >= 1 and . == floor))
         and (.judgment != "resolved" or (.file != null and .line != null)))
       and ((map(.id) | sort) == ($f | map(.id) | sort))) as $ok
    | {review_id, commit_id, record,
       items: [$f[] | .id as $id | ($j | if $ok then (map(select(.id == $id))[0]) else null end) as $x
         | (if $x != null and $x.judgment == "resolved" and ($heads["\($x.file):\($x.line)"] | not) then null else $x end) as $x
         | {id, rule_id, severity, file, line,
            judgment: (if $x == null then "not-judged" else ($x.judgment | sub(" "; "-")) end),
            at: (if $x != null and $x.judgment == "resolved" then {file: $x.file, line: $x.line} else null end)}]}' "$RUN/earlier.json"
}

# The evidence of a change outside Terraform (verdict.md, Changes outside Terraform): nonhcl-reach.sh
# on the clone's objects at the head and the merge base, with the reach file of the run's shipped
# module profile from this skill checkout, never from the workspace; a custom profile has none.
# Prints nothing and fails when there is no merge base or the script refuses.
nonhcl_of() {
  local pid reach=()
  [ -n "$MB" ] || return 1
  pid="$(jq -r '.label | if startswith("shipped:") then .[8:] else "" end' "$RUN/state/profile.json" 2> /dev/null)"
  [ -z "$pid" ] || [ -z "$MAINT" ] || reach=(--reach "$MAINT/profiles/$pid/nonhcl-reach.txt")
  bash "$HERE/nonhcl-reach.sh" --git "$RUN/clone" --head "$HEAD_SHA" --base "$MB" --repo "$(arg repo)" \
    --behaviour "$RUN/behaviour/behaviour.json" --files "$RUN/host/files.json" --prefix "$PREFIX" \
    ${reach[@]+"${reach[@]}"} 2> /dev/null
}

build_run_file() { # counts JSON -> the run file of render-comment.sh on stdout
  local triage beh='null' ver='null' cov='null' skip='null' dj='null' tj='null' mode
  triage="$TRIAGE"
  [ "$TRIAGE" = true ] || [ ! -f "$RUN/behaviour/run-behaviour.json" ] || beh="$(cat "$RUN/behaviour/run-behaviour.json")"
  [ ! -f "$RUN/verify.json" ] || ver="$(cat "$RUN/verify.json")"
  [ ! -f "$RUN/coverage.json" ] || cov="$(cat "$RUN/coverage.json")"
  [ ! -f "$RUN/skip-check.json" ] || skip="$(cat "$RUN/skip-check.json")"
  [ ! -f "$RUN/depth.json" ] || dj="$(cat "$RUN/depth.json")"
  [ "$TRIAGE" = true ] || [ ! -f "$RUN/tests.json" ] || tj="$(cat "$RUN/tests.json")"
  local sk; sk="$(cat "$RUN/skipped.json")" || return 1
  local prof=null fl=null ear=null nh=null
  [ ! -f "$RUN/state/profile.json" ] || prof="$(cat "$RUN/state/profile.json")"
  [ ! -f "$RUN/earlier.json" ] || ear="$(earlier_of)" || return 1
  [ "$TRIAGE" = true ] || fl="$(floors_of)" || fl=null
  [ "$TRIAGE" = true ] || ! needs_tests || nh="$(nonhcl_of)" || nh=null
  [ -n "$nh" ] || nh=null
  mode="$(plan_mode)"
  # The behaviour, verify, coverage, skip check, skipped files and earlier values have no size cap that
  # keeps them under one argument's limit (128 KiB on Linux), so they reach jq on a descriptor,
  # each held to exactly one JSON value as --argjson held it.
  jq -n --argjson triage "$triage" --argjson counts "$1" --slurpfile beh <(printf '%s' "$beh") --slurpfile ver <(printf '%s' "$ver") \
    --slurpfile cov <(printf '%s' "$cov") --slurpfile skip <(printf '%s' "$skip") --argjson depth "$dj" --argjson tests "$tj" --arg mode "$mode" --argjson prof "$prof" \
    --argjson floors "$fl" --argjson nonhcl "$nh" --slurpfile skipped <(printf '%s' "$sk") \
    --slurpfile earlier <(printf '%s' "$ear") \
    --argjson planned "$( [ -f "$RUN/state/plan" ] && echo true || echo false)" \
    --slurpfile sel "$RUN/selection.json" "
    def one: if length == 1 then .[0] else error(\"not one JSON value\") end;
    (\$beh | one) as \$beh | (\$ver | one) as \$ver | (\$cov | one) as \$cov | (\$skip | one) as \$skip
    | (\$skipped | one) as \$skipped | (\$earlier | one) as \$earlier |
    {format: 1, triage: \$triage, plan_ran: \$planned,
     verify_gaps: (if \$triage then []
       elif \$ver != null then (\$ver | $GAPS_JQ)
       else [\$sel[0].dirs[] | {dir, reason: \"merge base not available\"}] end),
     coverage: (if \$cov == null then {class: \"complete\", inert: true, unplanned: []}
       else {class: \$cov.class, inert: \$cov.inert, unplanned: \$cov.unplanned} end
       + (if \$skip != null and (\$skip.covered | length) > 0
          then {covered_skips: \$skip.covered, skip_head_sha: \$skip.head_sha, skip_base_sha: \$skip.base_sha}
          else {} end)),
     counts: \$counts}
    + (if \$triage then {} else {behaviour: \$beh} end | with_entries(select(.value != null)))
    + (if \$ver != null then {examples: (\$ver.dirs | {count: length,
         skipped: (map(select(.reason == \"skipped-version-bump\")) | length),
         validated: (map(select(.reason == \"verified\" and .head.validate == 0)) | length)})} else {} end)
    + (if \$mode != \"\" then {plan_mode: \$mode} else {} end)
    + (if \$depth != null then {depth: \$depth} else {} end)
    + (if \$tests != null then {tests: \$tests} else {} end)
    + (if \$floors != null then {floors: \$floors} else {} end)
    + (if \$nonhcl != null then {nonhcl: \$nonhcl} else {} end)
    + (if \$skipped != [] then {skipped_files: \$skipped} else {} end)
    + (if \$earlier != null then {earlier: \$earlier} else {} end)
    + (if \$prof != null and (\$prof.label != \"shipped:terraform-aws-modules\" or \$prof.tree != \"none\")
       then {profile: {label: \$prof.label, tree: \$prof.tree}} else {} end)"
}

# --- record ----------------------------------------------------------------------------------

# After the confirmed write of Step 12, with the review id the write returned: the review as GitHub
# holds it must be the token user's, of the plan's head, and carry the rendered body exactly as
# posted; then plan.json and the body's digest are kept under that id. It reads, never writes, the host.
cmd_record() {
  local out="" id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="${2-}"; shift 2 || die "--out needs a value" ;;
      --review-id) id="${2-}"; shift 2 || die "--review-id needs a value" ;;
      *) die "unexpected argument" ;;
    esac
  done
  case "$out" in /?*) ;; *) die "--out must be an absolute path" ;; esac
  [[ "$id" =~ ^[1-9][0-9]{0,15}$ ]] || die "--review-id must be a review id"
  local p="$out/plan.json" c="$out/comment.md" k="$out/carried.json" w repo pr uid d
  [ -f "$p" ] && [ ! -L "$p" ] && [ -f "$c" ] && [ ! -L "$c" ] || fail "record refused: the output directory holds no plan.json and comment.md"
  jq -e -L "$HERE" 'include "stage-contract"; stage_ok("review-plan") and (.reviewer_id | type == "number")' "$p" > /dev/null 2>&1 ||
    fail "record refused: plan.json is not a review plan with the token user's id"
  [ -f "$k" ] && [ ! -L "$k" ] && [ "$(wc -c < "$k")" -le 4194304 ] &&
    jq -e -s "$EARLIER_JQ"' length == 1 and (.[0] | carried_ok)' "$k" > /dev/null 2>&1 ||
    fail "record refused: the output directory holds no carried.json of earlier findings"
  repo="$(jq -r '.pin.base_repo' "$p")"; pr="$(jq -r '.pin.number' "$p")"
  [[ "$repo" =~ $repo_re ]] && [[ "$pr" =~ ^[1-9][0-9]{0,9}$ ]] && [ "$(jq -r '.pin.target' "$p")" = "$repo#$pr" ] ||
    fail "record refused: plan.json names no pull request"
  uid="$(gh api user --jq '.id' 2> /dev/null)" && [ "$uid" = "$(jq -r '.reviewer_id' "$p")" ] ||
    fail "record refused: the token user is not the one the plan was rendered for"
  w="$(mktemp -d "${TMPDIR:-/tmp}/pr-record.XXXXXX")" || fail "record refused: no temporary directory"
  gh api "repos/$repo/pulls/$pr/reviews/$id" > "$w/review.json" 2> /dev/null &&
    jq -e --argjson id "$id" --argjson u "$uid" --slurpfile p "$p" '.id == $id and .user.id == $u
      and .commit_id == $p[0].pin.head_sha and (.state | IN("APPROVED", "CHANGES_REQUESTED", "COMMENTED"))
      and (.body | type == "string")' "$w/review.json" > /dev/null 2>&1 ||
    { rm -rf "$w"; fail "record refused: review $id is not the token user's review of the plan's head"; }
  # The write sent "$(cat comment.md)", which drops the final newlines.
  jq -j '.body' "$w/review.json" > "$w/body"
  printf '%s' "$(cat "$c")" > "$w/sent"
  cmp -s "$w/body" "$w/sent" || { rm -rf "$w"; fail "record refused: review $id does not carry the rendered body"; }
  d="$(records_dir "$repo" "$pr")" || { rm -rf "$w"; fail "record refused: no absolute XDG_STATE_HOME or HOME"; }
  [ ! -e "$d/$id.json" ] && [ ! -L "$d/$id.json" ] && [ ! -e "$d/$id.plan.json" ] && [ ! -L "$d/$id.plan.json" ] &&
    [ ! -e "$d/$id.carried.json" ] && [ ! -L "$d/$id.carried.json" ] ||
    { rm -rf "$w"; fail "record refused: review $id is already recorded"; }
  (umask 077 && mkdir -p -- "$d") && [ -d "$d" ] && [ ! -L "$d" ] &&
    chmod 700 "${d%/*/*/*}" "${d%/*/*}" "${d%/*}" "$d" 2> /dev/null && store_private "$d" ||
    { rm -rf "$w"; fail "record refused: the record store is not this user's alone"; }
  ( umask 077 && cp -- "$p" "$d/$id.plan.json.tmp" && cp -- "$k" "$d/$id.carried.json.tmp" ) &&
    jq -n --argjson id "$id" --arg t "$repo#$pr" --arg st "$(jq -r '.state' "$w/review.json")" \
      --arg b "$(sha_file "$w/body")" --arg ps "$(sha_file "$d/$id.plan.json.tmp")" --arg cs "$(sha_file "$d/$id.carried.json.tmp")" \
      '{format: 1, review_id: $id, target: $t, state: $st, body_sha256: $b, plan_sha256: $ps, carried_sha256: $cs}' | ( umask 077 && cat > "$d/$id.json.tmp" ) &&
    jq -e "$META_JQ" "$d/$id.json.tmp" > /dev/null &&
    mv -- "$d/$id.plan.json.tmp" "$d/$id.plan.json" && mv -- "$d/$id.carried.json.tmp" "$d/$id.carried.json" &&
    mv -- "$d/$id.json.tmp" "$d/$id.json" ||
    { rm -f "$d/$id.json.tmp" "$d/$id.plan.json.tmp" "$d/$id.carried.json.tmp"; rm -rf "$w"; fail "record refused: the record could not be written"; }
  rm -rf "$w"
  echo "record: review $id ($(jq -r '.state' "$d/$id.json")) kept in $d"
}

# --- cleanup ---------------------------------------------------------------------------------

cmd_cleanup() { # github-io.md, Cleanup; the runner's Docker objects first when it ran
  local rid
  rid="$(cat "$RUN/plan-record/run-id.txt" 2> /dev/null)"
  case "$rid" in
    '' | *[!a-z0-9]*) ;;
    *) docker rm -f "plan-runner-$rid" "plan-proxy-init-$rid" "plan-proxy-plan-$rid" > /dev/null 2>&1
       docker volume rm "plan-work-$rid" "plan-saved-$rid" > /dev/null 2>&1
       docker network rm "plan-int-$rid" "plan-ext-$rid" > /dev/null 2>&1 ;;
  esac
  rid="$(cat "$RUN/tests-record/run-id.txt" 2> /dev/null)"
  case "$rid" in
    '' | *[!a-z0-9]*) ;;
    *) docker rm -f "test-runner-$rid" "test-proxy-$rid" > /dev/null 2>&1
       docker volume rm "test-work-$rid" > /dev/null 2>&1
       docker network rm "test-int-$rid" "test-ext-$rid" > /dev/null 2>&1 ;;
  esac
  case "$RUN" in
    "$ROOT"/pr-review.??????) find "$RUN" -type d -exec chmod u+w {} + ; rm -rf -- "$RUN" ;;
    *) fail "refusing to delete: $RUN" ;;
  esac
  echo "cleanup: run directory deleted"
}

timed() { # command...: its output with the seconds it took after the first line, its exit status
  local t=$SECONDS out rc
  out="$("$@")"; rc=$?
  [ -z "$out" ] || printf '%s\n' "$out" | awk -v s="$((SECONDS - t))" 'NR == 1 { $0 = $0 " (" s "s)" } { print }'
  return "$rc"
}

# --- main ------------------------------------------------------------------------------------

cmd="${1-}"; CMD="$cmd"; shift || die "usage: review-run.sh <prepare|schema|verify|plan|skip-coverage|ladder|tests|evidence|handover|render|cleanup|record> ..."
case "$cmd" in
  prepare) cmd_prepare "$@" ;;
  record) cmd_record "$@" ;;
  schema | verify | plan | skip-coverage | ladder | tests | evidence | handover | render | cleanup)
    run_dir="${1-}"; shift || die "$cmd needs the run directory"
    RUN=""; open_run "$run_dir"
    case "$cmd" in
      schema) timed cmd_schema ;;
      verify) timed cmd_verify "$@" ;;
      plan) timed cmd_plan "$@" ;;
      skip-coverage) timed cmd_skip_coverage ;;
      ladder) timed cmd_ladder "$@" ;;
      tests) timed cmd_tests ;;
      evidence) cmd_evidence ;;
      handover) cmd_handover ;;
      render) cmd_render "$@" ;;
      cleanup) cmd_cleanup ;;
    esac ;;
  *) die "unknown subcommand" ;;
esac
