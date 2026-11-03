#!/bin/bash
# review-run.sh: the deterministic steps of terraform-module-pr-review as commands, on top of
# host-pass.sh and the pass scripts, so the model runs a command and reads a short summary
# instead of running each step by hand. Rules and the order per depth: review-run.md. Invoke it
# with bash by an absolute path in this skill's own checkout, never from the head or the run.
#
#   review-run.sh prepare --repo <owner/name> --pr <number> [--render-only] [--triage]
#       [--profile <name> --role-arn <arn>] [--owner-depth deep] [--owner-pid <pid>]
#       [--provider-cache <dir>]
#       Steps 1 to 5, 7 and 7.5: identity, host-pass.sh run and checks and their check, the
#       clone, the merge base worktree, G0 and the plan pass mode when a profile is named, the
#       acquisition, the classifier, mtf-facts affected and depth.sh compute. Writes the run
#       directory and <run>/index.json, enumerated fields only, and prints "RUN=<dir>".
#   review-run.sh schema <run>          focused only: schema-pass.sh with depth.json
#   review-run.sh verify <run> [--outside]
#                                        the default pass; --outside re-runs, outside the sandbox
#                                        by the user's authorization, the not-run-environment ones
#   review-run.sh plan <run>            the plan pass (deep, focused, with a profile), then the
#                                        plan coverage at every depth
#   review-run.sh skip-coverage <run>   skip-coverage.sh after a laptop pass with gate skips
#   review-run.sh ladder <run>          ladder-pass.sh run (not at light), then behaviour-pass.sh eval
#   review-run.sh handover <run>        <run>/handover/task.md and record.txt for the reviewer
#   review-run.sh render <run> --findings <file> --assessment <file> --out <dir>
#       [--summary <file>] [--standard]
#                                        the run file, depth.sh verify, render-comment.sh
#   review-run.sh cleanup <run>         deletes the run directory
#
# Every subcommand prints at most 30 lines. Host strings never reach a command line or an
# eval: they travel in files and through jq --arg. Exit 0 done, 1 a refusal or a failed step
# with its fixed reason printed, 2 a usage error. There is no post command: posting stays the
# skill's confirmed step (SKILL.md, Rule 1).
set -uo pipefail
set -f

HERE="$(cd "$(dirname "$0")" && pwd -P)"
sha_re='^[0-9a-f]{40}$'
repo_re='^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$'
# Unbounded patterns with separate length checks: bash 3.2's regex refuses a bound over 255.
path_re='^[A-Za-z0-9._][A-Za-z0-9._/-]*$'
plain_ok() { [ "${#1}" -le 300 ] && [[ "$1" =~ $path_re ]]; } # a plain path of at most 300 characters
WRITE_SHORT='Write short: a `summary` of at most 200 characters and a `suggested_fix` of at most 250, or at most 600 for a `needs decision:` fix, one clause per option. The hard caps stay 500 and 600. A finding over the short targets is valid; the COMPACT render refuses it, and the comment renders in STANDARD only with `--standard`.'

# A provenance line of schema-pass.md, Focused Mode: mirror, release tag, schema file SHA-256.
SOURCE_RE='^schema pass: source [A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100} [a-z0-9][a-z0-9-]{0,63}_[a-z0-9][a-z0-9-]{0,63}-v[0-9]{1,5}\.[0-9]{1,5}\.[0-9]{1,5} [0-9a-f]{64}$'

die() { echo "review-run.sh: $1" >&2; exit 2; }
fail() { echo "review-run.sh: $1"; exit 1; }

limit() { # seconds, command... : the time limit of github-io.md, Allowed Commands
  local s="$1"; shift
  if command -v timeout > /dev/null; then timeout "$s" "$@"
  elif command -v gtimeout > /dev/null; then gtimeout "$s" "$@"
  else perl -e 'alarm shift; exec @ARGV' "$s" "$@"; fi
}

# mtf-facts as facts-engine.md resolves it: from /, absolute, canonical, outside the run.
facts_bin() {
  local f
  f="$(cd / && command -v mtf-facts 2> /dev/null)" || { echo /dev/null/mtf-facts; return; }
  case "$f" in /*) ;; *) echo /dev/null/mtf-facts; return ;; esac
  f="$(cd "$(dirname "$f")" 2> /dev/null && pwd -P)/$(basename "$f")" || { echo /dev/null/mtf-facts; return; }
  case "$f" in "${RUN:-/nonexistent}"/*) echo /dev/null/mtf-facts ;; *) echo "$f" ;; esac
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
  # A run with no depth.json is the pipeline of before, with no schema step.
  [ -f "$RUN/depth.json" ] || return 0
  case "$(depth)" in
    focused) [ "$(cat "$RUN/state/schema" 2> /dev/null)" = ok ] || fail "$1 at focused needs schema first" ;;
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

affected_to() { # mtf-facts, root, files list, out: the affected report, or no file when it gave none
  if ! (cd "$RUN/state" && limit 70 "$1" affected "$2" --diff "$3" --json) > "$4" 2> /dev/null ||
      ! jq -e 'type == "object"' "$4" > /dev/null 2>&1; then
    rm -f "$4"
  fi
}

# --- prepare ---------------------------------------------------------------------------------

refuse() { # fixed reason, words: index.json says refused and nothing else
  jq -n --arg r "$1" '{format: 1, status: "refused", reason: $r}' > "$RUN/index.json"
  echo "RUN=$RUN"
  echo "prepare refused: $1 ($2). No review is rendered; the run is inconclusive."
  exit 1
}

cmd_prepare() {
  local repo="" pr="" render_only=false triage=false profile="" role="" owner_depth="" opid="" cache=""
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
  [ -n "$cache" ] || cache="${XDG_CACHE_HOME:-$HOME/.cache}/modulestf/provider-cache"
  case "$cache" in /?*) ;; *) die "--provider-cache must be an absolute path" ;; esac

  # Step 1, identity, before anything else (github-io.md, Identity).
  local id login="" type="" posting=enabled
  id="$(gh api user --jq '.login + " " + .type' 2> /dev/null)" || id=""
  login="${id% *}"; type="${id##* }"
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

  # Steps 2, 4, 5 and 7.5, and the check runs of Step 7, by host-pass.sh.
  local hp=(bash "$HERE/host-pass.sh") ro=() tr=() err
  [ "$render_only" = false ] || ro=(--render-only)
  [ "$triage" = false ] || tr=(--triage)
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
  "${hp[@]}" checks --repo "$repo" --head "$head" --out "$RUN/checks" --own-pairs "" > /dev/null 2>&1
  local checks_file=rejected
  [ "$("${hp[@]}" check "$RUN/checks" --head "$head" 2> /dev/null)" = "checks accepted" ] && checks_file=accepted
  # The count skip-coverage.md holds the files list to, from a metadata read at the same head.
  local changed=null meta
  meta="$(gh api "repos/$repo/pulls/$pr" --jq '.head.sha + " " + (.changed_files | tostring)' 2> /dev/null)" &&
    [ "${meta%% *}" = "$head" ] && [[ "${meta#* }" =~ ^[0-9]{1,6}$ ]] && changed="${meta#* }"

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
  facts="$(facts_bin)"
  if [ "$triage" = false ]; then
    mkdir "$RUN/behaviour"
    local mroot="$RUN/clone"; [ -z "$prefix" ] || mroot="$RUN/clone/$prefix"
    local own=(); [ -z "$opid" ] || own=(--owner-pid "$opid")
    { [ -d "$cache" ] || (umask 077 && mkdir -p "$cache"); } 2> /dev/null
    bash "$HERE/ladder-pass.sh" acquire "$RUN" --pins "$HERE/ladder-pins.json" --cache "$cache" \
      --schema-out "$RUN/behaviour-schema.json" ${own[@]+"${own[@]}"} > "$RUN/state/acquire.out" 2>&1 ||
      rm -f "$RUN/behaviour-schema.json"
    local sch=(); [ ! -f "$RUN/behaviour-schema.json" ] || sch=(--schema "$RUN/behaviour-schema.json")
    bash "$HERE/behaviour-pass.sh" classify --facts "$facts" --dir "$mroot" --diff "$RUN/host/files.json" \
      --prefix "$prefix" ${sch[@]+"${sch[@]}"} --out "$RUN/behaviour" > "$RUN/state/classify.out" 2>&1
    if [ -f "$RUN/behaviour/behaviour.json" ]; then behaviour=classified
    else behaviour="not-run: $(head -c 64 "$RUN/behaviour/status" 2> /dev/null | tr -cd 'a-z -')"; fi
    # mtf-facts affected, as verify-pass.md Example selection runs it; no file when it gave nothing.
    jq --arg p "$prefix" '[.[] | select($p == "" or (.filename | startswith($p + "/")))
      | .filename |= (if $p == "" then . else .[($p | length) + 1:] end)
      | if .previous_filename then .previous_filename |= (if $p == "" then . else ltrimstr($p + "/") end) else . end]' \
      "$RUN/host/files.json" > "$RUN/state/files-module.json"
    affected_to "$facts" "$mroot" "$RUN/state/files-module.json" "$RUN/affected.json"
    local od=(); [ -z "$owner_depth" ] || od=(--owner-depth deep)
    [ "$base_tree" = true ] || refuse merge-base-unavailable "the merge base could not be checked out for the depth binding"
    # mtf-facts depth reads the trees from the repository root, so its classifier and affected
    # reports must have repository-relative paths: with a module root prefix, a second classify and
    # affected run on the clone root, used for the depth alone.
    local dcl="$RUN/behaviour/behaviour.json" daf="$RUN/affected.json"
    if [ -n "$prefix" ]; then
      mkdir "$RUN/state/depth-behaviour"
      bash "$HERE/behaviour-pass.sh" classify --facts "$facts" --dir "$RUN/clone" --diff "$RUN/host/files.json" \
        ${sch[@]+"${sch[@]}"} --out "$RUN/state/depth-behaviour" > "$RUN/state/depth-classify.out" 2>&1
      dcl="$RUN/state/depth-behaviour/behaviour.json"
      affected_to "$facts" "$RUN/clone" "$RUN/host/files.json" "$RUN/state/affected-depth.json"
      daf="$RUN/state/affected-depth.json"
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

  # The example selection, for the index (verify-pass.sh select, which runs no terraform).
  bash "$HERE/verify-pass.sh" select "$RUN" --files "$RUN/host/files.json" --prefix "$prefix" \
    > "$RUN/selection.json" 2> /dev/null || echo '{"selection": null, "dirs": []}' > "$RUN/selection.json"

  write_index "$checks_file" "$changed" "$behaviour" "$mode"
  local login_shown="${login:-none}"
  echo "RUN=$RUN"
  echo "identity: $login_shown, posting $posting$( [ "$render_only" = false ] || echo ", render-only")"
  summary_lines
}

# index.json: enumerated fields and validated paths only, never prose, a title or a branch.
write_index() { # checks file, changed files, behaviour, mode
  jq -n --arg cf "$1" --arg changed "$2" --arg beh "$3" --arg mode "$4" --arg pre "$path_re" \
    --slurpfile h "$RUN/host/host.json" --slurpfile a "$RUN/state/args.json" --slurpfile s "$RUN/selection.json" \
    --slurpfile f "$RUN/host/files.json" --slurpfile d "$( [ -f "$RUN/depth.json" ] && echo "$RUN/depth.json" || echo /dev/null)" '
    def paths: [.[]? | select(type == "string" and length <= 300 and test($pre))];
    ($h[0]) as $h | ($a[0]) as $a | ($d[0] // null) as $d
    | {format: 1, status: "ok", head: $h.head_sha, base: $h.base_sha, merge_base: $h.merge_base,
       prefix: (if $h.prefix | test($pre) then $h.prefix else "" end),
       triage: $a.triage, render_only: $a.render_only, posting: $a.posting,
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
                examples: ($s[0].dirs | length)}}' > "$RUN/index.json" 2> /dev/null ||
    refuse index-failed "index.json could not be written"
}

summary_lines() {
  jq -r '"head \(.head[:12]), merge base \(.merge_base // "none" | .[:12]), \(.counts.files) files, \(.counts.examples) examples",
    "signals: threads \(.signals.threads), review decision \(.signals.review_decision), mergeability \(.signals.mergeability), checks file \(.signals.checks)",
    "depth: \(.depth)" + (if .reasons != [] then " (" + (.reasons[:6] | join(", ")) + ")" else "" end),
    "out of scope: checks \(.checks_out_of_scope | join(",") | if . == "" then "none" else . end), examples \(.examples_out_of_scope | length)",
    "behaviour: \(.behaviour), plan: \(.plan)",
    "next: " + (if .triage then "handover, reviewer, render"
      elif .depth == "light" then "claims, verify, plan, ladder, handover, reviewer, render"
      elif .depth == "focused" then "claims, schema, verify, plan, skip-coverage, ladder, handover, reviewer, render"
      else "claims, schema, verify, plan, skip-coverage, ladder, handover, reviewer, render" end)' "$RUN/index.json"
}

# --- evidence passes -----------------------------------------------------------------------

need_full() { [ "$TRIAGE" = false ] || fail "a triage run has no $1 step"; }

# The schema handoff's inputs, as schema-pass.md, Schema Handoff, gives them: one
# <commit>:<SHA-256>:<path> per regular .tf blob of at most 1 MiB in each commit's tree,
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
      [[ "$m" =~ ^100(644|755)$ && "$p" == *.tf && "$s" =~ ^[0-9]+$ ]] && [ "$s" -le 1048576 ] || continue
      if [ -n "$r" ]; then [[ "$p" == "$r"* ]] || continue; p="${p#"$r"}"; fi
      [[ "$p" =~ ^[A-Za-z0-9._/-]+$ && "$o" =~ ^[0-9a-f]{40}$ ]] || return 1
      h="$(clone_git cat-file blob "$o" | shasum -a 256)" || return 1
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
  rm -rf "$RUN/schema-work" "$RUN/schema-handoff" "$RUN/state/schema-sources.txt"
  local line rc r="" mbs ins=""
  # The handoff's commits and inputs: the head and the merge base the depth was bound to.
  # Without both, schema-pass.sh gives no handoff and says why; inputs that could not be
  # read pass as "-", which it refuses as inputs.
  mbs="$(jq -r '.binding.merge_base // ""' "$RUN/depth.json" 2> /dev/null)"
  if [[ "$mbs" =~ $sha_re ]]; then ins="$(schema_inputs "$HEAD_SHA" "$mbs")" || ins=-; else mbs=""; fi
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
      note schema ok
      grep -m 1 -E '^schema pass: (handoff written|no handoff)' "$RUN/state/schema.out" | sed 's/^schema pass: /schema: /'
      echo "schema: ${line:0:200}"
      echo "schema: $(grep -c . "$RUN/state/schema-sources.txt") source lines recorded"
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

plan_dirs() { # the examples to plan, repository-relative, in selection order
  if [ "$(depth)" = focused ]; then
    jq -r --slurpfile d "$RUN/depth.json" '.dirs[].dir | select(IN($d[0].examples_selected[]))' "$RUN/selection.json"
  else jq -r '.dirs[].dir' "$RUN/selection.json"; fi
}

cmd_plan() {
  need_full plan
  [ ! -e "$RUN/coverage.json" ] || fail "plan already ran in this run"
  local profile role mode src=(--no-plan) d dirs=() base=() rc=0 missed=""
  profile="$(arg profile)"; role="$(arg role_arn)"; mode="$(cat "$RUN/state/mode")"
  [ -z "$MB" ] || base=(--base "$MB")
  if [ -n "$profile" ] && [ "$(depth)" != light ]; then
    while IFS= read -r d; do plain_ok "$d" && dirs+=("$d"); done < <(plan_dirs)
    if [ "${#dirs[@]}" -gt 0 ] && [ "$mode" = runner ]; then
      bash "$HERE/plan-runner/run-pass.sh" --build --clone "$RUN/runner-clone" --record "$RUN/plan-record" \
        --tmp "$RUN" --profile "$profile" --role-arn "$role" ${base[@]+"${base[@]}"} "${dirs[@]}" \
        > "$RUN/state/plan.out" 2> "$RUN/state/plan.err" || rc=$?
      [ -f "$RUN/plan-record/plan-pass.txt" ] && src=(--plan "$RUN/plan-record/plan-pass.txt" --addresses "$RUN/plan-record")
    elif [ "${#dirs[@]}" -gt 0 ]; then
      bash "$HERE/plan-pass.sh" plan "$RUN" "$profile" --role-arn "$role" --mode laptop ${base[@]+"${base[@]}"} \
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
  else echo "plan: not run ($( [ -n "$profile" ] && echo "depth $(depth)" || echo 'no AWS profile named'))"; fi
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
  [ "$(plan_mode)" = laptop ] && jq -e 'any(.unplanned[]; .reason | IN("plan gate G1", "plan gate G2", "plan gate G3"))' \
    "$RUN/coverage.json" > /dev/null || { echo "skip-coverage: nothing to check"; return 0; }
  local changed; changed="$(jq -r '.counts.changed_files // ""' "$RUN/index.json")"
  [ -n "$changed" ] && [ -n "$MB" ] && [ -d "$RUN/base" ] ||
    { echo "skip-coverage: not run (no merge base or no changed files count); the skips stay unknowns"; return 0; }
  local sc=(bash "$HERE/skip-coverage.sh")
  rm -f "$RUN/base-gates.txt" "$RUN/skip-check.json"
  "${sc[@]}" gates "$RUN" --tree "$RUN/base" --base "$MB" --coverage "$RUN/coverage.json" --out "$RUN/base-gates.txt" \
    > /dev/null 2> "$RUN/state/skip-gates.err" || rm -f "$RUN/base-gates.txt"
  local bg=(); [ ! -f "$RUN/base-gates.txt" ] || bg=(--base-gates "$RUN/base-gates.txt")
  local ad=(); [ ! -d "$RUN/plan-addresses" ] || ad=(--addresses "$RUN/plan-addresses")
  if "${sc[@]}" check "$RUN" --files "$RUN/host/files.json" --coverage "$RUN/coverage.json" --plan "$(plan_record)" \
      --head "$HEAD_SHA" --base "$MB" --changed-files "$changed" ${ad[@]+"${ad[@]}"} ${bg[@]+"${bg[@]}"} \
      --prefix "$PREFIX" > "$RUN/skip-check.json" 2> "$RUN/state/skip-check.err" &&
      jq -e '(.covered | type == "array")' "$RUN/skip-check.json" > /dev/null 2>&1; then
    jq -r '"skip-coverage: \(.covered | length) covered, \(.uncovered | length? // 0) not covered"' "$RUN/skip-check.json"
  else rm -f "$RUN/skip-check.json"; echo "skip-coverage: failed; the skips stay unknowns"; fi
}

cmd_ladder() {
  need_full ladder
  local facts own=() opid
  facts="$(facts_bin)"; opid="$(arg owner_pid)"; [ -z "$opid" ] || own=(--owner-pid "$opid")
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
  local cl=() ld=()
  [ ! -f "$RUN/behaviour/claims.json" ] || cl=(--claims "$RUN/behaviour/claims.json")
  [ ! -f "$RUN/behaviour/ladder.json" ] || ld=(--ladder "$RUN/behaviour/ladder.json")
  bash "$HERE/behaviour-pass.sh" eval --facts "$facts" --out "$RUN/behaviour" --head "$HEAD_SHA" \
    --base-sha "${MB:-$HEAD_SHA}" ${cl[@]+"${cl[@]}"} ${ld[@]+"${ld[@]}"} > /dev/null 2> "$RUN/state/eval.err" ||
    fail "behaviour-pass.sh eval failed"
  head -n 1 "$RUN/behaviour/record.txt" 2> /dev/null | cut -c1-200
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
  cat "$RUN/behaviour/record.txt"
}

cmd_handover() {
  ready handover
  if [ -f "$RUN/depth.json" ]; then
    bash "$HERE/depth.sh" verify "$RUN/depth.json" --clone "$RUN/clone" > /dev/null 2>&1 ||
      fail "depth.sh verify: the depth binding does not match the clone; the run stops"
  fi
  local t="$RUN/host/task.md" s n out="$RUN/handover"
  rm -rf "$out"; mkdir "$out"
  s="$(sed -n 's/^UNTRUSTED-\([0-9a-f]\{12\}\) BEGIN$/\1/p' "$t")"
  [[ "$s" =~ ^[0-9a-f]{12}$ ]] && [ "$(grep -c "^UNTRUSTED-$s END\$" "$t")" = 1 ] && [ "$(tail -n 1 "$t")" = "UNTRUSTED-$s END" ] ||
    fail "task.md has no single untrusted block"
  n="$(grep -n -m1 '^The block below holds text quoted' "$t" | cut -d: -f1)"
  [[ "$n" =~ ^[0-9]+$ ]] || fail "task.md has no block preamble"
  if [ "$TRIAGE" = false ]; then record_lines > "$out/record.txt" || fail "the record could not be assembled"; fi
  # The merge base the depth was bound to, for the reviewer's mtf-facts --merge-base-sha.
  local mbl="$MB"
  [ ! -f "$RUN/depth.json" ] || mbl="$(jq -r '.binding.merge_base' "$RUN/depth.json")"
  [[ "$mbl" =~ $sha_re ]] || mbl=""
  rm -rf "$RUN/review"; mkdir "$RUN/review"
  # The diff of the task, module-root-relative, as a file the reviewer's mtf-facts lint reads.
  awk 'p == 1 && $0 == f { exit } p == 1 { print; next } p == 2 { f = $0; sub(/diff$/, "", f); p = 1; next }
       /^The diff:$/ { p = 2 }' "$t" > "$out/change.diff"
  {
    printf 'Workspace: %s\n' "$MROOT"
    head -n $((n - 1)) "$t"
    grep -qxF "$WRITE_SHORT" "$t" || printf '%s\n' "$WRITE_SHORT"
    [ ! -f "$RUN/depth.json" ] || [ "$TRIAGE" = true ] || printf 'Depth: %s\n' "$RUN/depth.json"
    [ "$(cat "$RUN/state/schema" 2> /dev/null)" != ok ] || [ ! -d "$RUN/facts" ] || printf 'Provider fact sheets: %s\n' "$RUN/facts"
    [ "$(cat "$RUN/state/schema" 2> /dev/null)" != ok ] || [ ! -f "$RUN/schema-handoff/schema-handoff.json.gz" ] ||
      printf 'Schema handoff: %s\n' "$RUN/schema-handoff/schema-handoff.json.gz"
    printf 'Diff: %s\n' "$out/change.diff"
    [ -z "$mbl" ] || printf 'Merge base: %s\n' "$mbl"
    printf 'Output: write the findings list as JSON to %s, the summary line to %s and the facts comparison note to %s, and nothing else.\n' \
      "$RUN/review/findings.json" "$RUN/review/summary.txt" "$RUN/review/facts-comparison.txt"
    sed -n "$n,\$p" "$t" | sed '$d'
    [ "$TRIAGE" = true ] || { printf 'RECORD-%s\n' "$s"; cat "$out/record.txt"; }
    printf 'UNTRUSTED-%s END\n' "$s"
  } > "$out/task.md"
  [ ! -f "$RUN/depth.json" ] || cp "$RUN/state/depth.sha256" "$RUN/state/handover.sha256"
  echo "handover: $out/task.md ($(wc -l < "$out/task.md" | tr -d ' ') lines, record $( [ -f "$out/record.txt" ] && wc -l < "$out/record.txt" | tr -d ' ' || echo 0) lines)"
  echo "reviewer: one read-only subagent, workspace $MROOT, task text $out/task.md, output in $RUN/review"
}

# --- render ----------------------------------------------------------------------------------

cmd_render() {
  local findings="" assessment="" summary="" out="" std=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --findings) findings="${2-}"; shift 2 || die "--findings needs a value" ;;
      --assessment) assessment="${2-}"; shift 2 || die "--assessment needs a value" ;;
      --summary) summary="${2-}"; shift 2 || die "--summary needs a value" ;;
      --out) out="${2-}"; shift 2 || die "--out needs a value" ;;
      --standard) std=(--standard); shift ;;
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
  case "$out" in /?*) ;; *) die "--out must be an absolute path" ;; esac
  [ -d "$out" ] || mkdir -p -- "$out" || die "--out cannot be made"
  if [ -f "$RUN/depth.json" ]; then
    bash "$HERE/depth.sh" verify "$RUN/depth.json" --clone "$RUN/clone" > /dev/null 2>&1 ||
      fail "depth.sh verify: the depth binding does not match the clone; nothing is rendered"
  fi
  local r="$RUN/render"; rm -rf "$r"; mkdir "$r"
  jq -e 'type == "array"' "$findings" > /dev/null 2>&1 || fail "the findings are not a JSON list"
  jq '[.[] | . + {source: "llm"}]' "$findings" > "$r/findings.json"
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
  build_run_file "$counts" > "$r/run-file.json" || fail "the run file could not be built"
  local line rc
  line="$(bash "$HERE/render-comment.sh" --head "$HEAD_SHA" --findings "$r/findings.json" --host "$RUN/host/host.json" \
    --checks "$RUN/checks" --run "$r/run-file.json" --assessment "$assessment" --run-dir "$RUN" --out "$out" \
    --links ${std[@]+"${std[@]}"} 2>&1)"
  rc=$?
  printf '%s\n' "$line" | head -n 20
  [ "$rc" = 0 ] || exit 1
  echo "body: $out/comment.md"
  jq -r '"identity: \(.login | if . == "" then "none" else . end), posting \(.posting)" + (if .render_only then ", render-only" else "" end)' "$RUN/state/args.json"
}

build_run_file() { # counts JSON -> the run file of render-comment.sh on stdout
  local triage beh='null' ver='null' cov='null' skip='null' dj='null' mode
  triage="$TRIAGE"
  [ "$TRIAGE" = true ] || [ ! -f "$RUN/behaviour/run-behaviour.json" ] || beh="$(cat "$RUN/behaviour/run-behaviour.json")"
  [ ! -f "$RUN/verify.json" ] || ver="$(cat "$RUN/verify.json")"
  [ ! -f "$RUN/coverage.json" ] || cov="$(cat "$RUN/coverage.json")"
  [ ! -f "$RUN/skip-check.json" ] || skip="$(cat "$RUN/skip-check.json")"
  [ ! -f "$RUN/depth.json" ] || dj="$(cat "$RUN/depth.json")"
  mode="$(plan_mode)"
  jq -n --argjson triage "$triage" --argjson counts "$1" --argjson beh "$beh" --argjson ver "$ver" \
    --argjson cov "$cov" --argjson skip "$skip" --argjson depth "$dj" --arg mode "$mode" \
    --argjson planned "$( [ -f "$RUN/state/plan" ] && echo true || echo false)" \
    --slurpfile sel "$RUN/selection.json" "
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
    + (if \$ver != null then {examples: (\$ver | [.dirs[] | select(.reason == \"verified\")]
         | {count: length, validated: (map(select(.head.validate == 0)) | length)})} else {} end)
    + (if \$mode != \"\" then {plan_mode: \$mode} else {} end)
    + (if \$depth != null then {depth: \$depth} else {} end)"
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
  case "$RUN" in
    "$ROOT"/pr-review.??????) find "$RUN" -type d -exec chmod u+w {} + ; rm -rf -- "$RUN" ;;
    *) fail "refusing to delete: $RUN" ;;
  esac
  echo "cleanup: run directory deleted"
}

# --- main ------------------------------------------------------------------------------------

cmd="${1-}"; CMD="$cmd"; shift || die "usage: review-run.sh <prepare|schema|verify|plan|skip-coverage|ladder|handover|render|cleanup> ..."
case "$cmd" in
  prepare) cmd_prepare "$@" ;;
  schema | verify | plan | skip-coverage | ladder | handover | render | cleanup)
    run_dir="${1-}"; shift || die "$cmd needs the run directory"
    RUN=""; open_run "$run_dir"
    case "$cmd" in
      schema) cmd_schema ;;
      verify) cmd_verify "$@" ;;
      plan) cmd_plan ;;
      skip-coverage) cmd_skip_coverage ;;
      ladder) cmd_ladder ;;
      handover) cmd_handover ;;
      render) cmd_render "$@" ;;
      cleanup) cmd_cleanup ;;
    esac ;;
  *) die "unknown subcommand" ;;
esac
