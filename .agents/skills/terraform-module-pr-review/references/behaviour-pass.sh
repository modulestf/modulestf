#!/bin/bash
# behaviour-pass.sh: Steps 5.4 and 5.5 of terraform-module-pr-review, the behaviour classifier and
# the claims evaluation, both by mtf-facts. Rules: behaviour-pass.md. Invoke it by an absolute path
# in this skill's own checkout, never from the clone under review.
#
#   behaviour-pass.sh classify --facts <mtf-facts> --dir <module root>
#       (--diff <files.json> [--prefix <module root prefix>] | --base <dir>) [--schema <schema.json>] --out <dir>
#   behaviour-pass.sh eval --facts <mtf-facts> --out <dir> --head <sha> --base-sha <sha>
#       [--claims <claims.json>] [--ladder <ladder.json>]
#
# classify writes <out>/behaviour.json, the checked classifier output, or <out>/status, the reason
# nothing was classified, and prints one line. eval writes <out>/run-behaviour.json, the run file's
# behaviour object, and <out>/record.txt, the record lines for the handover, and prints the record.
# Every failure of mtf-facts or of its output fails closed to "not-run" with a fixed reason and
# exit 0. Exit 2 is a usage error, and nothing is written. Each mtf-facts run has a deadline of
# BEHAVIOUR_PASS_TIMEOUT seconds, 120 unless set.
set -uo pipefail
set -f
export LC_ALL=C

CAP=1048576
CLAIMS_CAP=65536
sha_re='^[0-9a-f]{40}$'
deadline="${BEHAVIOUR_PASS_TIMEOUT:-120}"
[[ "$deadline" =~ ^[1-9][0-9]{0,3}$ ]] || { echo "behaviour-pass.sh: BEHAVIOUR_PASS_TIMEOUT must be 1 to 9999 seconds" >&2; exit 2; }
die() { echo "behaviour-pass.sh: $1" >&2; exit 2; }

cmd="${1-}"; shift 2> /dev/null
facts="" dir="" diff="" prefix="" base="" schema="" out="" head="" bsha="" claims="" ladder=""
while [ $# -gt 0 ]; do
  case "$1" in
    --facts) facts="${2-}" ;; --dir) dir="${2-}" ;; --diff) diff="${2-}" ;; --prefix) prefix="${2-}" ;; --base) base="${2-}" ;; --schema) schema="${2-}" ;;
    --out) out="${2-}" ;; --head) head="${2-}" ;; --base-sha) bsha="${2-}" ;;
    --claims) claims="${2-}" ;; --ladder) ladder="${2-}" ;;
    *) die "unexpected argument" ;;
  esac
  [ $# -ge 2 ] || die "$1 needs a value"; shift 2
done
abs() { case "$1" in /?*) ;; *) die "$2 must be an absolute path" ;; esac; }
abs "$out" --out; [ -d "$out" ] && [ ! -L "$out" ] || die "--out is not a directory"
abs "$facts" --facts

# Shared checks, in jq: a clean module-relative path, and the classifier output of contract 2.
JQ_DEFS='
def plain_path: type == "string" and length > 0 and length <= 1024
  and test("^(?!/)(?!.*\\\\)(?!(.*/)?\\.\\.(/|$)).+$") and (test("[\\x00-\\x20\\x7f`:]") | not);
def nat: type == "number" and . >= 0 and . == floor;
def tid: type == "string" and test("^T-[0-9]{3}$");
def cid: type == "string" and test("^C-[0-9]+$");
def cats: ["wrapper-change", "default-change", "count-for_each-conditional-change", "type-validation-change",
  "dynamic-block-change", "locals-outputs-change", "moved-or-renamed-address", "provider-version-floor-change",
  "unknown-propagation-candidate", "literal-argument-change", "resource-added-or-removed", "lifecycle-change",
  "unclassified-change", "non-hcl-dependency"];
def preds: ["expression-output-unknown", "expression-output-length-known", "expression-output-equals-for-inputs",
  "plan-attribute-unknown", "plan-attribute-unchanged-vs-prior", "plan-action", "input-filtered"];
def valid_behaviour:
  type == "object" and .schema_version == 1 and (.inert | type == "boolean") and (.capped | nat)
  and (.triggers | type == "array" and length <= 40 and all(.[]; type == "object" and (.id | tid)
        and (.file | plain_path) and (.line == null or (.line | nat and . > 0)) and (.category | IN(cats[]))
        # The required case set, when present: at most 32 cases, each with its own id once.
        and ((has("cases") | not) or (.cases | type == "array" and length <= 32
              and all(.[]; type == "object" and (.id | type == "string" and test("^[A-Za-z0-9_.:-]{1,64}$"))
                           and (.inputs | type == "object"))
              and (map(.id) | length == (unique | length)))))
        and (map(.id) | length == (unique | length)))
  and (.entries | type == "array" and all(.[]; type == "object" and (.path | plain_path)
        and (.trigger_ids | type == "array" and all(.[]; tid))))
  and ([.entries[].trigger_ids[]] - [.triggers[].id] == []);
def attrs: ["known", "wholly_unknown", "unknown_mask", "length", "value", "sensitive", "redacted", "unknown_inputs",
  "action", "unchanged_vs_prior", "error"];
def valid_eval($b; $c):
  type == "object" and .schema_version == 1 and .capped == $b.capped
  and (.triggers | type == "array" and all(.[]; type == "object"
        and (.state | IN("inert", "verified", "covered", "refuted", "unverifiable"))
        # Contract 1: complete, the sorted unexplained difference ids of this trigger, at most 256,
        # and their digest, present only with a difference.
        and ((has("complete") | not) or (.complete | type == "boolean"))
        and (.id as $id | (has("outstanding") | not) or (.outstanding | type == "array" and length <= 256
              and all(.[]; type == "string" and test("^T-[0-9]{3}\\|L[1-4]\\|[A-Za-z0-9_.:-]{1,64}\\|[a-z_]{1,32}$")
                           and startswith($id + "|")) and . == unique))
        and ((has("evidence_digest") | not) or ((.evidence_digest | type == "string" and test("^[0-9a-f]{64}$"))
              and (.outstanding // []) != []))
        and ((has("changes") | not) or (.changes | type == "array" and length <= 256 and all(.[]; type == "object"
              and (.level | IN("L1", "L2", "L3", "L4")) and (.case | type == "string" and test("^[A-Za-z0-9_.:-]{1,64}$"))
              and (.attribute | IN(attrs[])) and (.explained | type == "boolean")
              # The claims that explain it, at most 20 ids of the claims file, on an explained change only.
              and ((has("explained_by") | not) or (.explained_by | type == "array" and length <= 20
                    and all(.[]; type == "string" and test("^C-[0-9]+$"))
                    and (. - ($c.claims | map(.claim_id)) == [])))
              and (.explained or ((.explained_by // []) == [])))))))
  and ((.triggers | map(.id) | sort) == ($b.triggers | map(.id) | sort))
  and (.claims | type == "array" and all(.[]; type == "object" and (.state | IN("verified", "refuted", "unverifiable"))))
  and (.discarded_claims | type == "array" and all(.[]; type == "object"))
  and (((.claims + .discarded_claims) | map(.claim_id) | sort) == ($c.claims | map(.claim_id) | sort));
# A files list, module-relative: every changed path, a rename at its old path too, has an entry.
# A GitHub "unchanged" status and paths under .git or .terraform take none.
def covers($files):
  . as $o
  | ([$files[] | select(.status != "unchanged") | .filename, (.previous_filename // empty)
      | select(test("(^|/)\\.(git|terraform)(/|$)") | not)]
     - [$o.entries[] | .path, (.previous_path // empty)]) == [];
def valid_claims: type == "object" and (.claims | type == "array" and length <= 48
  and all(.[]; type == "object" and (.claim_id | cid)) and (map(.claim_id) | length == (unique | length)));
'

# run_facts <outfile> <args...>: mtf-facts from outside the clone, output bounded, under the
# deadline. Prints the status: "ok", "big" over the cap, "late" past the deadline, or "fail".
run_facts() {
  local f="$1"; shift
  (cd "$out" && exec perl -e 'alarm shift; exec @ARGV or exit 127' "$deadline" "$facts" "$@") 2> /dev/null \
    | head -c $((CAP + 1)) > "$f"
  local rc="${PIPESTATUS[0]}"
  if [ "$rc" = 142 ]; then echo late   # SIGALRM: the deadline passed
  elif [ "$(wc -c < "$f")" -gt "$CAP" ]; then echo big; elif [ "$rc" != 0 ]; then echo fail; else echo ok; fi
}

classify() {
  abs "$dir" --dir; [ -d "$dir" ] || die "--dir is not a directory"
  [ ! -e "$out/behaviour.json" ] && [ ! -e "$out/status" ] || die "--out already holds a classification"
  local cover=/dev/null
  if [ -n "$diff" ] && [ -z "$base" ]; then
    abs "$diff" --diff
    # The GitHub files list, module-relative: the prefix stripped, paths outside it left out.
    jq -e --arg p "$prefix" 'type == "array" and all(.[]; type == "object" and (.filename | type == "string"))' \
      "$diff" > /dev/null 2>&1 || die "--diff is not a GitHub files list"
    jq --arg p "${prefix:+$prefix/}" '
      def rel: if $p == "" then . elif startswith($p) then .[($p | length):] else null end;
      [.[] | .filename |= rel | if has("previous_filename") then .previous_filename |= rel else . end
       | select(.filename != null)]' "$diff" > "$out/files-module.json" || die "--diff cannot be read"
    set -- --diff "$out/files-module.json"
    cover="$out/files-module.json"
  elif [ -n "$base" ] && [ -z "$diff" ] && [ -z "$prefix" ]; then abs "$base" --base; set -- --base "$base"
  else die "classify needs one of --diff and --base, and --prefix only with --diff"; fi
  # The provider schema acquisition wrote, when there is one: a regular file, not a link.
  if [ -n "$schema" ]; then
    abs "$schema" --schema; [ -f "$schema" ] && [ ! -L "$schema" ] || die "--schema is not a regular file"
    set -- "$@" --schema "$schema"
  fi
  if [ ! -f "$facts" ] || [ ! -x "$facts" ]; then
    echo "mtf-facts not installed" > "$out/status"
  else
    case "$(run_facts "$out/behaviour.raw" behaviour "$dir" "$@" --json)" in
      big) echo "output refused" > "$out/status" ;;
      late) echo "mtf-facts timed out" > "$out/status" ;;
      fail) echo "mtf-facts failed" > "$out/status" ;;
      ok) if jq -e --slurpfile d "$cover" "$JQ_DEFS"' valid_behaviour
             and ($d == [] or covers($d[0]))' "$out/behaviour.raw" > /dev/null 2>&1; then
            mv -- "$out/behaviour.raw" "$out/behaviour.json"
          else echo "output refused" > "$out/status"; fi ;;
    esac
    rm -f -- "$out/behaviour.raw"
  fi
  if [ -f "$out/status" ]; then echo "behaviour: not run: $(cat "$out/status")"
  else jq -r '"behaviour: ran, \(.triggers | length) triggers, \(.capped) over the cap"' "$out/behaviour.json"; fi
}

# not_run <reason>: the fail-closed outputs of eval.
not_run() {
  jq -n --arg r "$1" '{status: "not-run", reason: $r, triggers: [], claims: [], capped: 0}' > "$out/run-behaviour.json"
  printf 'behaviour: not run: %s\n' "$1" | tee "$out/record.txt"
  exit 0
}

evaluate() {
  [[ "$head" =~ $sha_re ]] && [[ "$bsha" =~ $sha_re ]] || die "--head and --base-sha must be 40 character SHAs"
  [ ! -e "$out/run-behaviour.json" ] && [ ! -e "$out/record.txt" ] || die "--out already holds an evaluation"
  [ -n "$ladder" ] && { abs "$ladder" --ladder; [ -f "$ladder" ] && [ ! -L "$ladder" ] || die "--ladder is not a regular file"; }
  [ -n "$claims" ] && { abs "$claims" --claims; [ -f "$claims" ] && [ ! -L "$claims" ] || die "--claims is not a regular file"; }
  if [ -f "$out/status" ]; then not_run "$(cat "$out/status")"; fi
  [ -f "$out/behaviour.json" ] || die "run classify first"
  [ -f "$facts" ] && [ -x "$facts" ] || not_run "mtf-facts not installed"
  local cf='{"claims": []}'
  if [ -n "$claims" ]; then
    [ "$(wc -c < "$claims")" -le "$CLAIMS_CAP" ] && jq -e "$JQ_DEFS valid_claims" "$claims" > /dev/null 2>&1 \
      || not_run "claims refused"
    cf="$(jq -c . "$claims")"
  fi
  if [ -n "$ladder" ]; then
    jq -e --arg h "$head" --arg b "$bsha" '.schema_version == 1 and .head_sha == $h and .base_sha == $b' \
      "$ladder" > /dev/null 2>&1 || not_run "ladder refused"
  else
    ladder="$out/ladder-empty.json"
    jq -n --arg h "$head" --arg b "$bsha" '{schema_version: 1, head_sha: $h, base_sha: $b, terraform_version: null,
      pins: [], runs: [], coverage: {class: "none", examples: []}}' > "$ladder"
  fi
  set -- claims-eval --behaviour "$out/behaviour.json" --ladder "$ladder" --head-sha "$head" --base-sha "$bsha"
  [ -n "$claims" ] && set -- "$@" --claims "$claims"
  case "$(run_facts "$out/eval.raw" "$@" --json)" in
    big) not_run "output refused" ;;
    late) not_run "mtf-facts timed out" ;;
    fail) not_run "mtf-facts failed" ;;
  esac
  # Contract 4, held to the behaviour and the claims file: every trigger once, every claim once,
  # kept or discarded, and nothing else.
  jq -e --slurpfile b "$out/behaviour.json" --argjson c "$cf" "$JQ_DEFS"' valid_eval($b[0]; $c)' \
    "$out/eval.raw" > /dev/null 2>&1 || not_run "output refused"
  jq -n --slurpfile b "$out/behaviour.json" --slurpfile e "$out/eval.raw" --argjson c "$cf" "$JQ_DEFS"'
    $b[0] as $b | $e[0] as $e
    | def kstate($id): first($e.claims[] | select(.claim_id == $id) | .state) // "discarded";
    {run: {status: "ran", reason: null,
       triggers: [$b.triggers[] as $t | first($e.triggers[] | select(.id == $t.id)) as $et
                  | {id: $t.id, file: $t.file, line: $t.line, category: $t.category, state: $et.state}
                    + ($et | with_entries(select(.key | IN("complete", "outstanding", "evidence_digest"))))],
       claims: [$c.claims[] | {claim_id, state: (kstate(.claim_id) | if . == "discarded" then "unverifiable" else . end)}],
       capped: $b.capped},
     record: (["behaviour: ran, \($b.triggers | length) triggers, \($b.capped) over the cap\(if $b.inert then ", inert" else "" end)"]
       + [$b.triggers[] as $t | first($e.triggers[] | select(.id == $t.id)) as $et
          | "trigger \($t.id) `\($t.file)`\(if $t.line == null then "" else " line \($t.line)" end) \($t.category): \($et.state)"
            + (if $et.complete == true then ", complete" else "" end)
            + (if ($et.outstanding // []) != [] and $et.evidence_digest != null
               then ", outstanding \($et.outstanding | length), digest \($et.evidence_digest)" else "" end)]
       # Each base and head difference claims-eval found, for the compatibility judgement; no input crosses.
       + [$e.triggers[] as $t | ($t.changes // [])[]
          | "change \($t.id) \(.level) case \(.case) \(.attribute): \(if .explained then "explained" + (if (.explained_by // []) == [] then "" else " by " + (.explained_by | join(", ")) end) else "unexplained" end)"]
       # Only strings that pass their closed pattern reach the record: the model wrote this file.
       + [$c.claims[] | "claim \(.claim_id)"
          + (if (.params | type == "object") and (.params.node | tid) and (.params.revision | IN("base", "head")) and (.predicate_type | IN(preds[]))
             then " on \(.params.node) at \(.params.revision), \(.predicate_type)" else "" end)
          + ": \(kstate(.claim_id))"])}' > "$out/eval.json" || not_run "output refused"
  jq '.run' "$out/eval.json" > "$out/run-behaviour.json"
  jq -r '.record[]' "$out/eval.json" | tee "$out/record.txt"
  rm -f -- "$out/eval.json"
}

case "$cmd" in
  classify) classify ;;
  eval) evaluate ;;
  *) die "the first argument is classify or eval" ;;
esac
