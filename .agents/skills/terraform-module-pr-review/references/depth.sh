#!/bin/bash
# depth.sh: the review depth of terraform-module-pr-review, light, focused or deep, bound to the
# trees it was computed from. Rules: depth.md. Invoke it by an absolute path in the host's own
# checkout of this skill, never from the head or the workspace.
#
#   depth.sh compute --clone <dir> --base-tree <dir> --base <sha> --files <files.json>
#       [--classify <file>] [--affected <file>] --out <run-dir>/depth.json [--owner-depth deep]
#       Runs `mtf-facts depth` from the host's PATH, never from the clone, the base tree or the
#       run directory, adds the binding (head, base, merge base, diff hash) and the owner raise,
#       and writes --out whole or not at all. A missing, failing, late or refused mtf-facts gives
#       deep with deep-classifier-unavailable; a missing classifier output deep with
#       deep-classifier-unavailable; a missing or empty affected output deep with
#       deep-affected-fallback.
#   depth.sh verify <depth.json> --clone <dir>
#       Recomputes the binding from the clone; exit 1 on any difference.
#   depth.sh escalate <depth.json> <reason>
#       Raises the depth to deep with <reason>, a deep reason token of depth.md, in place.
#
# Exit 0 is success. Exit 1 aborts the run: the merge base is not the one result of
# `git merge-base --all`, a tree is not at its commit, or the binding differs. Exit 2 is a usage
# error or a refused input, and nothing is written. Paths are data: they reach git and mtf-facts as
# single arguments and jq as files, never as shell words. Runs the same under bash and zsh.
# Each mtf-facts run has a deadline of DEPTH_TIMEOUT seconds, 120 unless set.
set -uo pipefail
set -f
export LC_ALL=C
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_DIFF_OPTS GIT_EXTERNAL_DIFF GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT

HERE="$(cd "$(dirname "$0")" && pwd -P)"
CAP=1048576
sha_re='^[0-9a-f]{40}$'
deadline="${DEPTH_TIMEOUT:-120}"
die() { echo "depth.sh: $1" >&2; exit 2; }
abort() { echo "depth.sh: $1; the run aborts" >&2; exit 1; }
[[ "$deadline" =~ ^[1-9][0-9]{0,3}$ ]] || die "DEPTH_TIMEOUT must be 1 to 9999 seconds"

RJ() { jq -L "$HERE" "$@"; }
abs() { case "$1" in /?*) ;; *) die "$2 must be an absolute path" ;; esac; }
canon() { (cd -- "$1" 2> /dev/null && pwd -P); }
regular() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(wc -c < "$1")" -le "$CAP" ]; }
# git with no hook, monitor, pager or colour, so the diff bytes depend on the trees alone
g() { git -C "$1" -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.pager=cat -c color.ui=never \
  -c diff.noprefix=false -c diff.mnemonicPrefix=false -c diff.relative=false -c diff.renames=true \
  -c core.quotePath=true "${@:2}"; }

head_of() { g "$1" rev-parse --verify --quiet 'HEAD^{commit}' 2> /dev/null; }
# The one merge base of base and head, or abort.
merge_base() { # clone, base, head
  local all
  all="$(g "$1" merge-base --all "$2" "$3" 2> /dev/null)" || abort "git merge-base --all found no merge base"
  [ "$(printf '%s\n' "$all" | grep -c .)" = 1 ] || abort "git merge-base --all gave more than one result"
  [[ "$all" =~ $sha_re ]] || abort "git merge-base --all gave no commit"
  printf '%s' "$all"
}
diff_hash() { # clone, merge base, head
  local h
  h="$( { g "$1" diff --no-ext-diff --no-textconv --binary "$2" "$3" || echo FAILED; } | shasum -a 256)" || return 1
  case "$h" in *FAILED*) return 1 ;; esac
  printf '%s' "${h%% *}"
}
# The first mtf-facts on PATH from an absolute entry, every link resolved; empty when there is
# none or it lies under one of the directories given.
find_facts() {
  local f d
  f="$(printf '%s\n' "$PATH" | tr ':' '\n' | while IFS= read -r d; do
         case "$d" in (/?*) [ -f "$d/mtf-facts" ] && [ -x "$d/mtf-facts" ] && { printf '%s\n' "$d/mtf-facts"; break; } ;; esac
       done)"
  [ -n "$f" ] || return 0
  f="$(perl -MCwd=abs_path -e 'print abs_path(shift) // ""' "$f")"
  for d in "$@"; do case "$f/" in "$d"/*) return 0 ;; esac; done
  printf '%s' "$f"
}

compute() {
  local clone="" btree="" base="" files="" classify="" affected="" out="" owner=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --clone) clone="${2-}" ;; --base-tree) btree="${2-}" ;; --base) base="${2-}" ;; --files) files="${2-}" ;;
      --classify) classify="${2-}" ;; --affected) affected="${2-}" ;; --out) out="${2-}" ;;
      --owner-depth) owner="${2-}" ;;
      *) die "unexpected argument" ;;
    esac
    [ $# -ge 2 ] || die "$1 needs a value"; shift 2
  done
  abs "$clone" --clone; abs "$btree" --base-tree; abs "$files" --files; abs "$out" --out
  [ -z "$classify" ] || abs "$classify" --classify
  [ -z "$affected" ] || abs "$affected" --affected
  [ -z "$owner" ] || [ "$owner" = deep ] || die "--owner-depth takes deep only"
  [[ "$base" =~ $sha_re ]] || die "--base must be a 40 character SHA"
  regular "$files" || die "--files must name a regular file of at most 1 MiB"
  local C B R
  C="$(canon "$clone")" && [ -n "$C" ] || die "--clone is not a directory"
  B="$(canon "$btree")" && [ -n "$B" ] || die "--base-tree is not a directory"
  R="$(canon "${out%/*}/")" && [ -n "$R" ] || die "the directory of --out must exist"
  [ ! -e "$out" ] && [ ! -L "$out" ] && [ ! -e "$out.tmp" ] || die "--out already exists"

  local head mb hash
  head="$(head_of "$C")" || abort "the clone has no head commit"
  g "$C" cat-file -e "${base}^{commit}" 2> /dev/null || abort "the clone does not hold --base"
  mb="$(merge_base "$C" "$base" "$head")" || exit 1
  [ "$(head_of "$B")" = "$mb" ] || abort "--base-tree is not at the merge base"
  hash="$(diff_hash "$C" "$mb" "$head")" || abort "git diff failed"

  local facts st=fail
  W="$(mktemp -d "${TMPDIR:-/tmp}/depth.XXXXXX")" || die "no temporary directory"
  trap 'rm -rf -- "$W"' EXIT
  facts="$(find_facts "$C" "$B" "$R")"
  set -- depth --head "$C" --base "$B" --files "$files"
  [ -n "$classify" ] && regular "$classify" && set -- "$@" --classify "$classify"
  [ -n "$affected" ] && regular "$affected" && set -- "$@" --affected "$affected"
  if [ -n "$facts" ]; then
    { (cd "$W" && exec perl -e 'alarm shift; exec @ARGV or exit 127' "$deadline" "$facts" "$@") 2> /dev/null
      echo "$?" > "$W/rc"; } | head -c $((CAP + 1)) > "$W/facts.json"
    [ "$(cat "$W/rc")" = 0 ] && [ "$(wc -c < "$W/facts.json")" -le "$CAP" ] \
      && RJ -e --slurp 'include "render-comment"; length == 1 and (.[0] | valid_depth_shape(false))' \
           "$W/facts.json" > /dev/null 2>&1 && st=ok
  fi
  # The raises, each from a fact this script checked itself.
  local raise='[]'
  [ "$st" = ok ] || raise='["deep-classifier-unavailable"]'
  { [ -n "$classify" ] && regular "$classify" && jq -e 'type == "object"' "$classify" > /dev/null 2>&1; } \
    || raise="$(jq -c '. + ["deep-classifier-unavailable"]' <<< "$raise")"
  { [ -n "$affected" ] && regular "$affected" && jq -e 'type == "object" and . != {}' "$affected" > /dev/null 2>&1; } \
    || raise="$(jq -c '. + ["deep-affected-fallback"]' <<< "$raise")"
  [ -n "$owner" ] && raise="$(jq -c '. + ["deep-owner-raise"]' <<< "$raise")"
  [ "$st" = ok ] || jq -n '{format: 1, depth: "deep", reasons: [], checks_out_of_scope: [], examples_selected: [],
      examples_out_of_scope: [], touched_types: [], walk: {complete: false, unwalked: 0},
      limits: {tf_files: 0, changed_lines: 0, changed_blocks: 0, selected_examples: 0},
      schema_providers: [], schema_types: [], schema_locks: []}' > "$W/facts.json"
  RJ --argjson r "$raise" --arg h "$head" --arg b "$base" --arg m "$mb" --arg d "$hash" '
    include "render-comment";
    (if $r == [] then . else depth_raise($r) end) + {binding: {head_sha: $h, base_sha: $b, merge_base: $m, diff_sha256: $d}}
    | if valid_depth then . else error("not a depth object") end' "$W/facts.json" > "$out.tmp" 2> /dev/null \
    && mv -- "$out.tmp" "$out" || { rm -f -- "$out.tmp"; die "the depth object cannot be written"; }
  jq -r '"depth: \(.depth) (\(.reasons | join(", ")))"' "$out"
}

loaded() { # file: a valid depth object, else refused
  abs "$1" "the depth file"
  regular "$1" && RJ -e --slurp 'include "render-comment"; length == 1 and (.[0] | valid_depth)' "$1" > /dev/null 2>&1 \
    || die "the depth file is not a depth object"
}

verify() {
  local file="${1-}"; shift 2> /dev/null
  [ "${1-}" = --clone ] && [ $# = 2 ] || die "usage: depth.sh verify <depth.json> --clone <dir>"
  abs "$2" --clone; loaded "$file"
  local C head base mb hash
  C="$(canon "$2")" && [ -n "$C" ] || die "--clone is not a directory"
  base="$(jq -r .binding.base_sha "$file")"
  head="$(head_of "$C")" || abort "the clone has no head commit"
  [ "$head" = "$(jq -r .binding.head_sha "$file")" ] || abort "depth binding: the head moved"
  g "$C" cat-file -e "${base}^{commit}" 2> /dev/null || abort "depth binding: the clone does not hold the base"
  mb="$(merge_base "$C" "$base" "$head")" || exit 1
  [ "$mb" = "$(jq -r .binding.merge_base "$file")" ] || abort "depth binding: the merge base moved"
  hash="$(diff_hash "$C" "$mb" "$head")" || abort "git diff failed"
  [ "$hash" = "$(jq -r .binding.diff_sha256 "$file")" ] || abort "depth binding: the diff hash differs"
  echo "depth verified: $(jq -r .depth "$file")"
}

escalate() {
  [ $# = 2 ] || die "usage: depth.sh escalate <depth.json> <reason>"
  local file="$1" r="$2"
  loaded "$file"
  RJ -e -n --arg r "$r" 'include "render-comment"; $r | depth_reason and startswith("deep-")' > /dev/null 2>&1 \
    || die "not a deep reason token: see depth.md"
  [ ! -e "$file.tmp" ] || die "$file.tmp exists"
  RJ --arg r "$r" 'include "render-comment"; depth_raise([$r]) | if valid_depth then . else error("x") end' \
    "$file" > "$file.tmp" 2> /dev/null && mv -- "$file.tmp" "$file" || { rm -f -- "$file.tmp"; die "the depth file cannot be rewritten"; }
  jq -r '"depth: \(.depth) (\(.reasons | join(", ")))"' "$file"
}

cmd="${1-}"; shift 2> /dev/null
case "$cmd" in
  compute) compute "$@" ;;
  verify) verify "$@" ;;
  escalate) escalate "$@" ;;
  *) die "usage: depth.sh compute|verify|escalate ..." ;;
esac
