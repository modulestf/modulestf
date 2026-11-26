#!/bin/bash
# behaviour-pass.sh: Steps 5.4 and 5.5 of terraform-module-pr-review, the behaviour classifier and
# the claims evaluation, both by mtf-facts. Rules: behaviour-pass.md. Invoke it by an absolute path
# in this skill's own checkout, never from the clone under review.
#
#   behaviour-pass.sh classify --facts <mtf-facts> --dir <module root>
#       (--diff <files.json> [--prefix <module root prefix>] | --base <dir>) [--schema <schema.json>] --out <dir>
#   behaviour-pass.sh eval --facts <mtf-facts> --out <dir> --head <sha> --base-sha <sha>
#       [--claims <claims.json>] [--ladder <ladder.json>] [--wrappers <wrappers.txt>] [--prefix <module root prefix>]
#       [--plan-diff <coverage.json>]
#   behaviour-pass.sh diff-dirs --out <dir> [--prefix <module root prefix>]
#   behaviour-pass.sh wrappers --clone <dir> --head <sha> --diff <files.json> [--prefix <p>] --out <dir>
#
# wrappers writes <out>/wrappers.txt, one line per wrapper versions.tf the change touches: its
# module-relative path and derived, copied, differs or "unknown <reason>" (behaviour-pass.md,
# Wrapper Versions). It reads the head tree with the git form of the reviewer's git-safety.md and
# runs nothing from the clone. eval with --wrappers makes an unverifiable trigger at a derived or
# copied wrapper inert.
#
# diff-dirs prints, one per line and repository-relative, the directory of each trigger in
# <out>/behaviour.json whose category is on the plan diff's closed list (behaviour-pass.md, The
# Run Object), for the plan pass's --diff-dir. eval with --plan-diff reads the coverage's
# plan_diff and marks such a trigger identical when every merge base example that reaches it
# planned the same against the base and the head module.
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
# shellcheck source=facts-resolve.sh
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
. "$HERE/facts-resolve.sh" || die "facts-resolve.sh cannot be read"

cmd="${1-}"; shift 2> /dev/null
facts="" dir="" diff="" prefix="" base="" schema="" out="" head="" bsha="" claims="" ladder="" wrappers="" clone="" pdiff=""
while [ $# -gt 0 ]; do
  case "$1" in
    --facts) facts="${2-}" ;; --dir) dir="${2-}" ;; --diff) diff="${2-}" ;; --prefix) prefix="${2-}" ;; --base) base="${2-}" ;; --schema) schema="${2-}" ;;
    --out) out="${2-}" ;; --head) head="${2-}" ;; --base-sha) bsha="${2-}" ;;
    --claims) claims="${2-}" ;; --ladder) ladder="${2-}" ;; --wrappers) wrappers="${2-}" ;; --clone) clone="${2-}" ;;
    --plan-diff) pdiff="${2-}" ;;
    *) die "unexpected argument" ;;
  esac
  [ $# -ge 2 ] || die "$1 needs a value"; shift 2
done
abs() { case "$1" in /?*) ;; *) die "$2 must be an absolute path" ;; esac; }
abs "$out" --out
# facts_features puts a directory under --out at the front of PATH; a colon would split that entry.
case "$out" in *:*) die "--out must not contain a colon" ;; esac
[ -d "$out" ] && [ ! -L "$out" ] || die "--out is not a directory"
case "$cmd" in wrappers | diff-dirs) ;; *) abs "$facts" --facts ;; esac

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
# A trigger no ladder level can verify, as mtf-facts counts it apart with behaviour.off-ladder-cap: a
# version floor that selects compat alone or a moved address that selects none, neither merged with
# another category nor following another trigger. Any other shape counts toward the evidence cap.
def off_ladder: (has("also_categories") | not) and (has("follows") | not)
  and ((.category == "provider-version-floor-change" and .levels == ["compat"])
       or (.category == "moved-or-renamed-address" and .levels == []));
# $split: the binary lists behaviour.off-ladder-cap, so at most 40 triggers that may need evidence and
# 40 off-ladder ones; otherwise at most 40 in all, the cap of a binary without it.
def valid_behaviour($split):
  (.capped // 0) as $cap
  | type == "object" and .schema_version == 1 and (.inert | type == "boolean") and (.capped | nat)
  and (.triggers | type == "array"
        and (if $split then ([.[] | select(type == "object" and off_ladder)] | length) as $off
               | $off <= 40 and length - $off <= 40
             else length <= 40 end)
        and all(.[]; type == "object" and (.id | tid)
        and (.file | plain_path) and (.line == null or (.line | nat and . > 0)) and (.category | IN(cats[]))
        # Contract 2: the categories of the triggers merged into this one, each a category once.
        and ((has("also_categories") | not) or (.also_categories | type == "array" and length > 0
              and all(.[]; IN(cats[])) and length == (unique | length)))
        # The caller code mark, when present, is a boolean: eval reads it as `== true`, so any other
        # value would leave the trigger inert under a module root prefix.
        and ((has("caller_code") | not) or (.caller_code | type == "boolean"))
        # The required case set, when present: at most 32 cases, each with its own id once.
        and ((has("cases") | not) or (.cases | type == "array" and length <= 32
              and all(.[]; type == "object" and (.id | type == "string" and test("^[A-Za-z0-9_.:-]{1,64}$"))
                           and (.inputs | type == "object"))
              and (map(.id) | length == (unique | length)))))
        and (map(.id) | length == (unique | length)))
  and (.entries | type == "array" and all(.[]; type == "object" and (.path | plain_path)
        and (.trigger_ids | type == "array" and all(.[]; tid))
        # An entry that names no trigger must be inert: the render reads a change whose triggers all
        # ended inert as inert for plan coverage, which holds only if no other entry is left unjudged.
        # Past the cap the tool lists the file with the triggers it cut, so an entry may name none then;
        # a capped run is a rule 4 unknown whatever its entries say.
        and ((.trigger_ids | length) > 0 or .inert == true or $cap > 0)))
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
        and ((.state | IN("verified", "covered", "inert")) as $pass | ($pass and ((.outstanding // []) != [] or has("evidence_digest"))) | not)
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
# The closed list of the plan diff (behaviour-pass.md, The Run Object): an added change whose claim is
# that existing callers are unaffected. An added variable with no level, so no validation block;
# an argument or block the change adds to a managed resource, at L4 alone, whose value has the
# shape the unexercised mark reads:
# exactly var.<name>, or a dynamic block null-guarded on it, where the change adds that variable
# with a null default in the same directory ($nv). Never a module call argument, which the plan
# shows only through the child, an output, which the engine takes to L1, nor a changed default or
# type of an existing variable.
def tdir: if test("/") then sub("/[^/]*$"; "") else "." end;
def meta_args: ["provider", "count", "for_each", "depends_on", "lifecycle", "provisioner", "connection"];
def diff_kind($t; $b; $nv): if $t.change_kind != "added" or ($t.address | type != "string") then null
  elif ($t.address | test("^var\\.[A-Za-z_][A-Za-z0-9_-]*$")) and $t.category == "unclassified-change"
    and (($t.also_categories // []) == []) and $t.levels == [] then "variable"
  elif ($t.address | test("^[a-z][a-z0-9]*_[a-z0-9_]+\\.[A-Za-z_][A-Za-z0-9_-]*$")) and $t.levels == ["L4"]
    and ([$t.category, ($t.also_categories // [])[]] - ["unclassified-change", "dynamic-block-change"] == [])
    and ($t.attribute | type == "string" and (sub("^dynamic\\."; "") | split(".")[0] | IN(meta_args[]) == false))
    and $t.contextual_refs == [] and ($t.head_expr | type == "string")
    and (($t.referenced_inputs | type) == "array" and ($t.referenced_inputs | length) == 1)
    and ($t.referenced_inputs[0] | .name | type == "string" and test("^[A-Za-z_][A-Za-z0-9_-]*$"))
    and ($t.referenced_inputs[0].name as $n | $t.head_expr as $h
      | ([{dir: ($t.file | tdir), name: $n}] - $nv == [])
      and (if $t.category == "dynamic-block-change"
           then ($h | test("^var\\.\($n) == null \\? \\[\\] : \\[[^?:]*\\]$") or test("^var\\.\($n) != null \\? \\[[^?:]*\\] : \\[\\]$"))
           else $h == ("var." + $n) end)) then "argument"
  else null end;
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

# null_vars, for a binary without behaviour.declarations and behaviour.schema-required (decl_vars
# reads those facts from the report instead): <out>/nullvars.json, {dir, name} of each variable the change adds whose head block, read
# from the clone as text at the classifier's line and never run, a small tokenizer accepts: each
# line has its quoted strings removed first (escape-aware; a string holding `${` or `%{`, or one
# left open, refuses), then refuses on `${`, `%{`, `<<`, `#`, `//`, `/*` or `*/`; depth is counted
# over {}, [] and (), the block ends where it returns to zero within 200 lines, and the block must
# hold exactly one `default` attribute at depth 1, whose value is exactly `null`, and no `nullable`
# attribute at depth 1. A `default` deeper in is part of the type and ignored. Anything else, a
# link, a file that resolves outside the module root or is over 1 MiB gives no entry. A variable is
# one of its module directory, so the directory is part of the key.
# <out>/required.json, "<type>.<path>" for each attribute the given provider schema requires and
# each block with min_items above 0, at every block depth, on a type a trigger names; a schema this
# cannot read gives ["*"], which requires everything.
null_vars() {
  local root list="" rmax=200
  root="$(cd "$dir" && pwd -P)" || return 0
  while IFS=$'\t' read -r name file line; do
    local f="$dir/$file" real
    [ -f "$f" ] && [ ! -L "$f" ] && [ "$(wc -c < "$f")" -le "$CAP" ] || continue
    real="$(cd "$(dirname "$f")" && pwd -P)/$(basename "$f")" || continue
    case "$real" in "$root"/*) ;; *) continue ;; esac
    perl -e '
      my ($name, $at, $max) = (shift, shift, shift); my @l = <STDIN>; my $i = $at - 1;
      exit 1 unless defined $l[$i] && $l[$i] =~ /^variable\s+"\Q$name\E"\s*\{\s*\r?$/;
      my ($depth, $n, $d) = (1, 0, 0);
      for my $j ($i + 1 .. $#l) {
        exit 1 if $j - $i > $max;
        my $s = $l[$j]; $s =~ s/\r?\n\z//;
        my $bad = 0;
        $s =~ s/"((?:[^"\\]|\\.)*)"/$bad = 1 if $1 =~ m{[\$%]\{}; "0"/ge;
        exit 1 if $bad || $s =~ /"/ || $s =~ m{<<|#|//|/\*|\*/|[\$%]\{};
        if ($depth == 1) {
          if ($s =~ /^\s*default\b/) { $n++; $d = 1 if $s =~ /^\s*default\s*=\s*null\s*$/ }
          exit 1 if $s =~ /^\s*nullable\b/;
        }
        for my $k (0 .. length($s) - 1) {
          my $c = substr($s, $k, 1);
          if ($c =~ /[\{\[\(]/) { $depth++ }
          elsif ($c =~ /[\}\]\)]/) {
            $depth--;
            if ($depth == 0) { exit(($c eq "}" && substr($s, $k + 1) =~ /^\s*$/ && $n == 1 && $d == 1) ? 0 : 1) }
          }
        }
      }
      exit 1' "$name" "$line" "$rmax" < "$f" \
      && list="$list$(dirname "$file")"$'\t'"$name"$'\n'
  done < <(jq -r '.triggers[] | select(.change_kind == "added" and (.address | type == "string" and test("^var\\.[A-Za-z_][A-Za-z0-9_-]*$"))
      and (.line | type == "number") and (.file | test("^[A-Za-z0-9_./-]+\\.tf$")) and (.file | split("/") | all(. != "..")))
      | [(.address | ltrimstr("var.")), .file, (.line | tostring)] | @tsv' "$out/behaviour.json")
  printf '%s' "$list" | jq -R -s -c 'split("\n") | map(select(. != "") | split("\t") | {dir: .[0], name: .[1]})' > "$out/nullvars.json"
  if [ -n "$schema" ]; then
    jq -c --slurpfile b "$out/behaviour.json" '
      ([$b[0].triggers[].address | strings | gsub("\\[[^\\]]*\\]"; "") | split(".") | select(length >= 2) | .[-2] | select(test("^[a-z][a-z0-9]*_[a-z0-9_]+$"))] | unique) as $ty
      | def req($p): ((.attributes // {}) | to_entries[] | select(.value.required == true) | "\($p).\(.key)"),
          ((.block_types // {}) | to_entries[] | ((select((.value.min_items // 0) > 0) | "\($p).\(.key)"), (.key as $b | .value.block | req("\($p).\($b)"))));
      ([.provider_schemas[]?.resource_schemas // {} | keys[]]) as $have
      # A type the schema does not hold requires everything of it.
      | [(.provider_schemas[]?.resource_schemas // {} | to_entries[] | select(.key | IN($ty[])) | .key as $k | .value.block | req($k)),
         ($ty[] | select(IN($have[]) | not) | "\(.).*")] | unique' \
      "$schema" > "$out/required.json" 2> /dev/null || printf '["*"]\n' > "$out/required.json"
  fi
}

# facts_features: the version report of the binary under --facts, read by the shared resolver
# (facts-resolve.sh, under its 10 second and 64 KiB limits) from a directory of our own that holds
# only a link named mtf-facts to it. facts_has then answers for it. A report that fails, as from a
# binary older than the command, lists nothing, so the step keeps the path of a binary without
# features.
facts_features() {
  local d="$out/facts-bin" p="$PATH"
  FACTS_FEATURES=''
  mkdir -p -- "$d" && ln -s -- "$facts" "$d/mtf-facts" || { rm -rf -- "$d"; return 0; }
  PATH="$d:$p"; facts_resolve; PATH="$p"
  rm -rf -- "$d"
}

# decl_vars: nullvars.json and required.json in the shapes null_vars writes, from the facts the binary
# reports with behaviour.declarations and behaviour.schema-required. A variable trigger the change adds
# is a null variable only when its declaration says added, a null default and no nullable argument,
# each field read on its own; no declaration is no entry. Nothing is read from the clone here, and
# valid_behaviour has already refused any file path with a `..` segment. With a schema, each resource or data source
# trigger whose schema_required is not exactly not_required puts its own path on the required list, so
# unknown and an absent field require it, and a trigger can never miss its own path there.
decl_vars() {
  jq -c '[.triggers[] | select(.change_kind == "added" and (.address | type == "string" and test("^var\\.[A-Za-z_][A-Za-z0-9_-]*$"))
      and (.line | type == "number") and (.file | test("^[A-Za-z0-9_./-]+\\.tf$"))
      and (.declaration | type == "object" and .added == true and .default == "null" and .nullable == "unset"))
    | {dir: (.file | if test("/") then sub("/[^/]*$"; "") else "." end), name: (.address | ltrimstr("var."))}]' \
    "$out/behaviour.json" > "$out/nullvars.json" 2> /dev/null || printf '[]\n' > "$out/nullvars.json"
  if [ -n "$schema" ]; then
    jq -c '[.triggers[] | select((.address | type == "string") and (.attribute | type == "string") and .schema_required != "not_required")
        | (.address | gsub("\\[[^\\]]*\\]"; "") | split(".")) as $s | select($s | length >= 2 and (.[-2] | test("^[a-z][a-z0-9]*_[a-z0-9_]+$")))
        | $s[-2] + "." + ((.attribute | split(".")) - ["dynamic"] | join("."))] | unique' \
      "$out/behaviour.json" > "$out/required.json" 2> /dev/null || printf '["*"]\n' > "$out/required.json"
  fi
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
    local split=false decl=false
    facts_features
    facts_has behaviour.off-ladder-cap && split=true
    facts_has behaviour.declarations && facts_has behaviour.schema-required && decl=true
    case "$(run_facts "$out/behaviour.raw" behaviour "$dir" "$@" --json)" in
      big) echo "output refused" > "$out/status" ;;
      late) echo "mtf-facts timed out" > "$out/status" ;;
      fail) echo "mtf-facts failed" > "$out/status" ;;
      ok) if jq -e --slurpfile d "$cover" --argjson split "$split" "$JQ_DEFS"' valid_behaviour($split)
             and ($d == [] or covers($d[0]))' "$out/behaviour.raw" > /dev/null 2>&1; then
            mv -- "$out/behaviour.raw" "$out/behaviour.json"
            if [ "$decl" = true ]; then decl_vars; else null_vars; fi
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
  prefix="${prefix%/}"
  case "$prefix" in /* | *..* | .) die "--prefix must be repository-relative" ;; esac
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
  # The wrapper evidence of the wrappers command: only a file whose every line is in its grammar
  # counts; any other is no evidence, as with no file.
  local wj='{}'
  if [ -n "$wrappers" ]; then
    abs "$wrappers" --wrappers; [ -f "$wrappers" ] && [ ! -L "$wrappers" ] || die "--wrappers is not a regular file"
    wj="$(jq -R -s -c --arg re "$WRAP_LINE_RE" 'split("\n") | map(select(. != ""))
      | if length <= 256 and all(.[]; test($re)) then map(capture("^(?<p>[^ ]+) (?<r>.+)$") | {(.p): .r}) | add // {} else {} end' \
      "$wrappers" 2> /dev/null)" || wj='{}'
  fi
  # The triggers are module-relative and the plan coverage is repository-relative: with a module
  # root prefix, each example directory and module call directory moves into the module root's
  # frame, "." for the root itself. A module call outside the module root is dropped and an example
  # directory outside it takes a leading slash, so neither can equal a trigger's directory.
  if [ -n "$prefix" ]; then
    jq --arg p "$prefix" '
      def rel: if . == $p then "." elif startswith($p + "/") and (split("/") | all(. != "..")) then .[($p | length) + 1:]
        else null end;
      .coverage.examples |= map((.dir |= (rel // ("/" + .)))
        | if has("module_calls") then .module_calls |= with_entries((.value |= rel) | select(.value != null)) else . end)' \
      "$ladder" > "$out/ladder-module.json" 2> /dev/null || not_run "ladder refused"
    ladder="$out/ladder-module.json"
  fi
  # The plan diff of the coverage (plan-pass.md, Plan diff), each dir moved into the module root's
  # frame as the coverage is. A file that is not a coverage object with a plan_diff list in its
  # shape is no evidence, as with no file.
  local pd='[]'
  if [ -n "$pdiff" ]; then
    abs "$pdiff" --plan-diff; [ -f "$pdiff" ] && [ ! -L "$pdiff" ] || die "--plan-diff is not a regular file"
    pd="$(jq -c --arg p "$prefix" '
      def rel: if $p == "" then . elif . == $p then "." elif startswith($p + "/") and (split("/") | all(. != "..")) then .[($p | length) + 1:]
        else "/" + . end;
      def relm: if $p == "" then . elif . == $p then "." elif startswith($p + "/") and (split("/") | all(. != "..")) then .[($p | length) + 1:]
        else null end;
      if (.plan_diff | type == "array" and all(.[]; type == "object" and (.dir | type == "string")
            and (.result | IN("equal", "differs", "unknown", "not-run")) and (.reason == null or (.reason | type == "string"))
            and (.addresses | type == "array" and length <= 1000 and all(.[]; type == "string"))
            and (.module_calls | type == "object" and all(.[]; type == "string"))))
      then .plan_diff | map((.dir |= rel) | .module_calls |= with_entries((.value |= relm) | select(.value != null))) else [] end' "$pdiff" 2> /dev/null)" || pd='[]'
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
  # No provider schema, or none classify could read, requires everything: nothing is marked.
  local nv='[]' rq='["*"]'
  if [ -f "$out/nullvars.json" ]; then
    nv="$(jq -c 'if type == "array" and all(.[]; type == "object" and (.dir | type == "string") and (.name | type == "string")) then . else [] end' "$out/nullvars.json" 2> /dev/null)" || nv='[]'
  fi
  # A required list that cannot be read, or a file of more than one JSON value, requires
  # everything, so nothing is marked.
  if [ -f "$out/required.json" ]; then
    rq="$(jq -c -s 'if length == 1 and (.[0] | type == "array" and all(.[]; type == "string")) then .[0] else ["*"] end' "$out/required.json" 2> /dev/null)" || rq='["*"]'
  fi
  # The required list can hold thousands of paths (a deeply nested schema gives megabytes), past
  # the argument size limit, so it reaches jq on a descriptor, not in argv; so does the plan diff.
  jq -n --slurpfile b "$out/behaviour.json" --slurpfile e "$out/eval.raw" --slurpfile l "$ladder" --argjson c "$cf" --argjson w "$wj" --argjson nv "${nv:-[]}" --slurpfile rq <(printf '%s\n' "${rq:-[\"*\"]}") --slurpfile pd <(printf '%s\n' "${pd:-[]}") --arg pre "$prefix" "$JQ_DEFS"'
    $b[0] as $b | $l[0] as $l | $rq[0] as $rq | $pd[0] as $pd
    # An unverifiable trigger at a wrapper versions.tf the host found equal to its generator output
    # is inert, with no outstanding difference: the wrapper is the module file, as the hook writes it.
    # A caller_code trigger (a literal of an example or tests file) is inert only for a tree that is the
    # whole repository: the classifier seals the tree it was given, and under a module root prefix a
    # root configuration outside it may load the example. With a prefix that inert reading is dropped
    # and the trigger is unverifiable; a refuted one stays refuted.
    | ($e[0] | .triggers |= map(.id as $id
        | if $pre != "" and .state == "inert" and (first($b.triggers[] | select(.id == $id)) | .caller_code == true)
          then {id, state: "unverifiable"} else . end)
      | .triggers |= map(.id as $id | (first($b.triggers[] | select(.id == $id)) | .file) as $f
        | if .state == "unverifiable" and ($w[$f] // "" | IN("derived", "copied"))
          then {id, state: "inert", wrapper: $w[$f]} else . end)) as $e
    | def kstate($id): first($e.claims[] | select(.claim_id == $id) | .state) // "discarded";
    # Contract 6, unexercised (behaviour-pass.md, The Run Object): an argument or dynamic block the
    # change adds to a managed resource that no planned example can create. When in doubt, no mark.
    # The categories: an added argument or block of a managed resource, never a removal or a type,
    # default, address, lifecycle or wrapper change, which take their own categories or kinds.
    def unex_cats: ["dynamic-block-change", "unclassified-change"];
    # The value reads one variable the change adds with a null default ($nv), and nothing else: an
    # argument is exactly var.<name>; a dynamic block is null-guarded to no block. A literal, another
    # variable, a local, a resource or any function changes what existing callers get: never marked.
    def null_pass($t): ($t.contextual_refs == []) and ($t.head_expr | type == "string")
      and ($t.referenced_inputs | type == "array" and length == 1 and (.[0].name | type == "string" and test("^[A-Za-z_][A-Za-z0-9_-]*$")))
      and ($t.referenced_inputs[0].name as $n | ({dir: ($t.file | tdir), name: $n} | IN($nv[]))
        and (if $t.category == "dynamic-block-change"
             then ($t.head_expr | test("^var\\.\($n) == null \\? \\[\\] : \\[[^?:]*\\]$") or test("^var\\.\($n) != null \\? \\[[^?:]*\\] : \\[\\]$"))
             else $t.head_expr == "var.\($n)" end));
    # Meta-arguments (meta_args) change how a resource is created, not what it sets: never marked.
    # A managed resource address, [module.<call>[<key>].]...<type>.<name>[<key>], with no keyword root.
    def managed: test("^(module\\.[A-Za-z0-9_-]+(\\[[^\\]]*\\])?\\.)*[a-z][a-z0-9]*_[a-z0-9_]+\\.[A-Za-z_][A-Za-z0-9_-]*(\\[[^\\]]*\\])?$");
    def bare: gsub("\\[[^\\]]*\\]"; "");
    # A required attribute or block takes no null: the schema says so when there is one.
    # The path drops every dynamic segment, so a dynamic block at any depth meets its schema path.
    def not_required($t): ($t.attribute | type == "string")
      and (($t.address | bare | split(".") | .[-2]) as $ty
           | ($ty + "." + ($t.attribute | split(".") | map(select(. != "dynamic")) | join("."))) as $ta
           | (("*" | IN($rq[])) or (($ty + ".*") | IN($rq[])) or ($ta | IN($rq[]))) | not);
    # The plan side: every example planned, with its addresses read whole (none empty, none at the
    # 1000 cap) and its module calls known, and no planned address that could be the resource at any
    # module depth: equal, or ending in "." and the address, whatever module calls lead to it.
    # Terraform read the directory of the trigger at the head: a planned example is that directory, or calls
    # it directly. A directory loaded only through another module is not seen, so it is not marked.
    def loaded($t): ($t.file | tdir) as $d
      | any($l.coverage.examples[]; .dir == $d or ((.module_calls // {}) | to_entries | any(.value == $d)));
    def plans_known: $l.coverage.class == "complete" and ($l.coverage.examples | type == "array")
      and all($l.coverage.examples[]; (.head | IN("planned", "planned-no-changes"))
            and (.addresses | type == "array" and length > 0 and length < 1000)
            and (.module_calls | type == "object" and length > 0));
    def unexercised($t; $et): ($t.address | if type == "string" then bare else "" end) as $a
      | ($t.address | type == "string" and managed) and $et.state == "unverifiable" and ($et | has("complete") or has("outstanding") or has("evidence_digest") | not)
      and $t.levels == ["L4"] and $t.change_kind == "added"
      and ([$t.category, ($t.also_categories // [])[]] - unex_cats == [])
      and null_pass($t) and not_required($t)
      and ($t.attribute | type == "string" and (sub("^dynamic\\."; "") | split(".")[0] | IN(meta_args[]) | not))
      and plans_known and loaded($t)
      and (any($l.coverage.examples[].addresses[]; bare | . == $a or endswith("." + $a)) | not);
    def etof($id): first($e.triggers[] | select(.id == $id));
    # The ids marked above, then the added variable they pass through: its own trigger takes no
    # level and follows them, so it is marked only when it is a null-default variable the change
    # adds and every trigger it follows is marked.
    ([$b.triggers[] as $t | select(unexercised($t; etof($t.id))) | $t.id]) as $m
    | def unex($t; $et): unexercised($t; $et)
        or ($t.address | type == "string" and test("^var\\.[A-Za-z_][A-Za-z0-9_-]*$")
            and ({dir: ($t.file | tdir), name: ltrimstr("var.")} | IN($nv[])))
           and $t.change_kind == "added" and $t.category == "unclassified-change" and (($t.also_categories // []) == [])
           and $t.levels == [] and $et.state == "unverifiable" and ($et | has("complete") or has("outstanding") or has("evidence_digest") | not)
           and ($t.follows | type == "array" and length > 0 and all(.[]; IN($m[]))) and loaded($t);
    # Identical (behaviour-pass.md, The Run Object): a trigger on the closed list whose merge base
    # examples planned the same against the base and the head module. Every example planned with
    # its addresses read whole, and the trigger sits in no example directory. An example counts by
    # the HCL that was compared: one whose plan diff is equal and whose merge base module calls
    # call the directory of the trigger is eligible; one absent at the base, or equal and not
    # calling it, is not; any other example that calls it at the head, or whose files the change
    # touches, leaves the trigger as it was. At least one is eligible, and one of them plans the
    # address the change sits in under its call: the resource, or for a variable any address of
    # that module instance. The examples are listed sorted, at most 20.
    def pd_of($d): first($pd[] | select(.dir == $d)) // null;
    def repo_dir: if startswith("/") then .[1:] elif $pre == "" then . elif . == "." then $pre else $pre + "/" + . end;
    def calls($mc; $d): [($mc // {}) | to_entries[] | select(.value == $d) | "module.\(.key)."];
    def under($x): . == $x or startswith($x + "/");
    def identical($t; $et): ($t.file | tdir) as $d | diff_kind($t; $b; $nv) as $k
      | if $k == null or $et.state != "unverifiable" or ($et | has("complete") or has("outstanding") or has("evidence_digest"))
           or ($l.coverage.class != "complete")
           or (all($l.coverage.examples[]; (.head | IN("planned", "planned-no-changes"))
                 and (.addresses | type == "array" and length > 0 and length < 1000)) | not)
           or any($l.coverage.examples[]; .dir as $x | $d | under($x))
           # The direct-caller check reads the head module calls: coverage with none, as a
           # hosted record gives, is no evidence.
           or (any($l.coverage.examples[]; (.module_calls | type) == "object" and .module_calls != {}) | not)
        then [] else
          [$l.coverage.examples[] | . as $e | pd_of($e.dir) as $p
           | (calls($e.module_calls; $d) != []) as $head
           | any($b.entries[]; .path | startswith($e.dir + "/")) as $edited
           | if $p.reason == "absent-at-base" then empty
             elif $p.result == "equal" then (if calls($p.module_calls; $d) != [] then {e: $e, p: $p} else empty end)
             elif $head or $edited then {block: true}
             else empty end] as $el
          | ($t.address | gsub("\\[[^\\]]*\\]"; "")) as $a
          | if $el != [] and all($el[]; has("block") | not)
               and any($el[]; .p.addresses as $pa | calls(.p.module_calls; $d)[] as $x
                     | if $k == "argument" then any($pa[]; . == $x + $a) else any($pa[]; startswith($x)) end)
            then [$el[].e.dir | repo_dir] | unique | .[:20] else [] end end;
    {run: {status: "ran", reason: null,
       triggers: [$b.triggers[] as $t | first($e.triggers[] | select(.id == $t.id)) as $et
                  | {id: $t.id, file: $t.file, line: $t.line, category: $t.category, state: $et.state}
                    + ($t | with_entries(select(.key == "also_categories")))
                    + ($et | with_entries(select(.key | IN("complete", "outstanding", "evidence_digest"))))
                    + (if unex($t; $et) then {unexercised: true} else {} end)
                    + (identical($t; $et) as $i | if $i != [] and (unex($t; $et) | not) then {identical: $i} else {} end)],
       claims: [$c.claims[] | {claim_id, state: (kstate(.claim_id) | if . == "discarded" then "unverifiable" else . end)}],
       capped: $b.capped},
     record: (["behaviour: ran, \($b.triggers | length) triggers, \($b.capped) over the cap\(if $b.inert then ", inert" else "" end)"]
       + [$b.triggers[] as $t | first($e.triggers[] | select(.id == $t.id)) as $et
          | "trigger \($t.id) `\($t.file)`\(if $t.line == null then "" else " line \($t.line)" end) \($t.category): \($et.state)"
            + (if $et.wrapper != null then ", wrapper \($et.wrapper)" else "" end)
            + (if $et.complete == true then ", complete" else "" end)
            + (if unex($t; $et) then ", unexercised" else "" end)
            + (identical($t; $et) as $i | if $i != [] and (unex($t; $et) | not) then ", identical" else "" end)
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

# --- Wrapper versions (behaviour-pass.md, Wrapper Versions) ---------------------------------------

WRAP_RE='^wrappers/([A-Za-z0-9_][A-Za-z0-9._-]{0,63}/)?versions\.tf$'
WRAP_LINE_RE='^wrappers/([A-Za-z0-9_][A-Za-z0-9._-]{0,63}/)?versions\.tf (derived|copied|differs|unknown [a-z0-9 .-]{1,60})$'
WRAP_CAP=65536
DERIVE="$HERE/wrapper-derive.pl"
# The environment and -c options of the form in the reviewer's git-safety.md, in the clone. Its
# table lists no ls-tree or cat-file: only those two run here, on the head, and like facts-engine.md's
# base extraction they read objects only, run no driver, filter or textconv and need no history, so
# the depth-1 clone serves.
safe_git() {
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_LAZY_FETCH=1 \
  GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null \
  GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat \
  git -C "$clone" --no-pager -c core.fsmonitor=false -c core.hooksPath=/dev/null \
    -c protocol.allow=never -c diff.external= -c log.showSignature=false \
    -c advice.graftFileDeprecated=false "$@"
}
safe_git_partial() {
  [ -n "$(safe_git config --get extensions.partialClone)" ] ||
    [ -n "$(safe_git config --get-regexp '^remote\..*\.promisor$')" ]
}
# head_blob <repository path> <file>: the blob at the head into the file, or prints why not: link
# (the path or an ancestor), not a regular file, absent, over size, read failed.
head_blob() {
  local p="$1" a="" c e re=$'^([0-7]{6}) [a-z]+ [0-9a-f]{40,64} +([0-9-]+)\t(.*)$'
  local IFS=/; set -f
  for c in ${p%/*}; do
    [ "$p" != "${p%/*}" ] || break
    a="${a:+$a/}$c"
    e="$(safe_git ls-tree -l -z "$head" -- "$a" 2> /dev/null | tr '\0' '\n')" || { echo "read failed"; return 1; }
    [[ "$e" =~ $re ]] && [ "${BASH_REMATCH[3]}" = "$a" ] || { echo absent; return 1; }
    [ "${BASH_REMATCH[1]}" != 120000 ] || { echo link; return 1; }
    [ "${BASH_REMATCH[1]}" = 040000 ] || { echo "not a regular file"; return 1; }
  done
  unset IFS
  e="$(safe_git ls-tree -l -z "$head" -- "$p" 2> /dev/null | tr '\0' '\n')" || { echo "read failed"; return 1; }
  [[ "$e" =~ $re ]] && [ "${BASH_REMATCH[3]}" = "$p" ] || { echo absent; return 1; }
  [ "${BASH_REMATCH[1]}" != 120000 ] || { echo link; return 1; }
  [ "${BASH_REMATCH[1]}" = 100644 ] || { echo "not a regular file"; return 1; }
  [ "${BASH_REMATCH[2]}" -le "$WRAP_CAP" ] || { echo "over size"; return 1; }
  safe_git cat-file blob "$head:$p" > "$2" 2> /dev/null && [ "$(wc -c < "$2")" -le "$WRAP_CAP" ] || { echo "read failed"; return 1; }
}
# The pre-commit-terraform pin of the head .pre-commit-config.yaml, read as data: prints derive (a
# release tag at v1.106.0 or later), copy (an earlier tag) or "unknown <reason>".
pin_mode() {
  local why
  why="$(head_blob .pre-commit-config.yaml "$out/wrap/pin")" || { [ "$why" = absent ] && echo "unknown no pin" || echo "unknown pin unreadable"; return; }
  perl -e '
    open(my $h, "<:raw", $ARGV[0]) or exit print "unknown pin unreadable\n";
    local $/; my $s = <$h>; $s = "" unless defined $s;
    exit print "unknown pin unreadable\n" if $s =~ /[^\x20-\x7e\t\n]/;
    # The reader fails closed rather than out-parse YAML: a form a loader could read another pin
    # from is no evidence. A backslash (an escape in a quoted scalar) or more than one top-level
    # repos key; an option that moves the hook to another provider. The line form below refuses
    # a document marker.
    exit print "unknown pin unreadable\n" if $s =~ /\\/;
    # Exactly one repos key, at column 0: a nested or second one is another document shape.
    exit print "unknown pin unreadable\n" if (() = $s =~ /^["\x27]?repos["\x27]?[ \t]*:/gmi) != 1;
    exit print "unknown hook options\n" if $s =~ /module-repo-provider/i;
    # Per line, outside quoted text and comments: no quote left open (a multi-line scalar), no flow
    # mapping, a flow sequence closed on its own line, and no block scalar indicator.
    for my $l (split /\n/, $s) {
      my ($b, $q, $d) = ("", "", 0);
      for my $c (split //, $l) {
        if ($q ne "") { $q = "" if $c eq $q; next }
        if ($c eq "\x27" || $c eq "\"") { $q = $c; $b .= "Q"; next }
        last if $c eq "#" && ($b eq "" || $b =~ /[ \t]\z/);
        $b .= $c;
        $d++ if $c eq "[";
        exit print "unknown pin unreadable\n" if $c eq "{" || ($c eq "]" && --$d < 0);
      }
      exit print "unknown pin unreadable\n" if $q ne "" || $d != 0 || $b =~ /(^|[ \t:-])[|>][-+0-9]*[ \t]*$/;
    }
    # YAML this line reader does not follow, so pre-commit could read another pin: an anchor, an
    # alias, a tag, a merge key or a complex key.
    exit print "unknown pin unreadable\n" if $s =~ /(^|[\s\[{,])[&*!]\S/m || $s =~ /^[ \t]*(-[ \t]+)?(\?|<<)/m;
    my $url = qr{https://github\.com/antonbabenko/pre-commit-terraform(?:\.git)?};
    my ($in, @e) = (0);
    for (split /\n/, $s) {
      # Each line is a comment, a blank, a list item or a key with a space after its colon, so no
      # plain scalar continues onto a line the reader would take for a key or a value.
      exit print "unknown pin unreadable\n" unless /^[ \t]*(#|$)/ || /^[ \t]*-([ \t]|$)/ || /^[ \t]*["\x27]?[A-Za-z_][A-Za-z0-9_.-]*["\x27]?:([ \t]|$)/;
      my ($repo, $rev);
      $repo = $2 if /^[ \t]*-[ \t]+repo:[ \t]+(["\x27]?)(\S+?)\1([ \t]+#.*)?[ \t]*$/;
      # A comment needs a blank before its #, as in YAML, so v1.106.0#x is no rev.
      $rev = $2 if /^[ \t]+rev:[ \t]+(["\x27]?)([^"\x27\s#]+)\1([ \t]+#.*)?[ \t]*$/;
      # A repo or rev key in any other spelling, a duplicate a YAML loader would keep last included.
      exit print "unknown pin unreadable\n" if /^[ \t]*(-[ \t]+)?["\x27]?(repo|rev)["\x27]?[ \t]*:/i && !defined $repo && !defined $rev;
      # A repo URL outside a plain https form, a percent escape for one, could name the repository
      # where the reader does not see it.
      exit print "unknown pin unreadable\n" if defined $repo && $repo !~ m{^(https://[A-Za-z0-9._/-]+|local|meta)$};
      if (defined $repo) { $in = $repo =~ /^$url$/; push @e, {rev => [], hook => 0, ind => length($1) + 1 + length($2)} if $in && /^([ \t]*)-([ \t]+)repo/; next }
      if (/^\S/) { $in = 0; next }
      next unless $in;
      # A rev indented otherwise than the keys of its entry belongs to no entry or another one.
      exit print "unknown pin unreadable\n" if defined $rev && !/^[ \t]{$e[-1]{ind}}rev:/;
      push @{$e[-1]{rev}}, $rev if defined $rev;
      $e[-1]{hook} = 1 if /^[ \t]*-[ \t]+id:[ \t]+(["\x27]?)terraform_wrapper_module_for_each\1[ \t]*(#.*)?$/;
    }
    # Every mention of the repository name, in any letter case and under any owner or host, is the
    # one entry read, and so is every mention of the hook, so no other entry, a fork included, hides
    # a second pin.
    my $m = () = $s =~ m{pre-commit-terraform}gi;
    exit print "unknown pin unreadable\n" if (() = $s =~ /terraform_wrapper_module_for_each/gi) > 1;
    exit print "unknown no pin\n" if $m == 0;
    exit print "unknown pin unreadable\n" unless @e == 1 && $m == 1 && @{$e[0]{rev}} == 1;
    exit print "unknown hook not listed\n" unless $e[0]{hook};
    # A version with no v names no tag of the repository.
    exit print "unknown pin unreadable\n" if $e[0]{rev}[0] =~ /^[0-9]+\.[0-9]+\.[0-9]+$/;
    my ($maj, $min, $pat) = $e[0]{rev}[0] =~ /^v([0-9]{1,5})\.([0-9]{1,5})\.([0-9]{1,5})$/
      or exit print "unknown pin not a release tag\n";
    # The hook copies the module file from v1.89.0 and strips the user agent from v1.106.0; before
    # v1.89.0 it wrote a fixed template.
    my $v = sprintf("%05d%05d%05d", $maj, $min, $pat);
    print $v ge "000010010600000" ? "derive\n" : $v ge "000010008900000" ? "copy\n" : "unknown old hook\n";' "$out/wrap/pin"
}
wrapper_pairs() {
  [ -n "$clone" ] && [ -n "$diff" ] || die "wrappers needs --clone, --head, --diff and --out"
  abs "$clone" --clone; abs "$diff" --diff; [ -d "$clone" ] || die "--clone is not a directory"
  [[ "$head" =~ $sha_re ]] || die "--head must be a 40 character SHA"
  [ ! -e "$out/wrappers.txt" ] && [ ! -e "$out/wrap" ] || die "--out already holds the wrapper evidence"
  jq -e 'type == "array" and all(.[]; type == "object" and (.filename | type == "string"))' "$diff" > /dev/null 2>&1 ||
    die "--diff is not a GitHub files list"
  mkdir "$out/wrap"
  local p r m mode why w=() all=""
  # The wrappers the change touches, module-relative, in path order.
  while IFS= read -r p; do [[ "$p" =~ $WRAP_RE ]] && w+=("$p"); done < <(jq -r --arg p "${prefix:+$prefix/}" \
    '.[] | .filename | select($p == "" or startswith($p)) | .[($p | length):]' "$diff" | LC_ALL=C sort -u)
  if [ ${#w[@]} -gt 0 ]; then
    if ! safe_git cat-file -e "$head^{tree}" 2> /dev/null; then all="unknown read failed"
    elif safe_git_partial; then all="unknown partial clone"
    else mode="$(pin_mode)"; fi
  fi
  for p in ${w[@]+"${w[@]}"}; do
    if [ "$p" = wrappers/versions.tf ]; then m=versions.tf; else m="modules/${p#wrappers/}"; fi
    if [ -n "$all" ]; then r="$all"
    elif ! why="$(head_blob "${prefix:+$prefix/}$p" "$out/wrap/w")"; then r="unknown wrapper $why"
    elif ! why="$(head_blob "${prefix:+$prefix/}$m" "$out/wrap/m")"; then r="unknown module $why"
    else
      case "$mode" in
        # The hook strips only its own provider's block, aws by default, and derive strips every
        # block: a module with any other provider_meta line is no evidence.
        derive) if grep -E '^[[:space:]]*provider_meta' "$out/wrap/m" | grep -qvE '^[[:space:]]*provider_meta "aws" \{$'; then
                  r="unknown provider_meta"
                elif perl "$DERIVE" derive "$out/wrap/m" > "$out/wrap/e"; then
                  cmp -s "$out/wrap/e" "$out/wrap/w" && r=derived || r=differs
                else r="unknown derive undefined"; fi ;;
        copy) cmp -s "$out/wrap/m" "$out/wrap/w" && r=copied || r=differs ;;
        *) r="$mode" ;;
      esac
    fi
    printf '%s %s\n' "$p" "$r"
  done > "$out/wrappers.txt"
  rm -rf -- "$out/wrap"
  cat "$out/wrappers.txt"
}

# diff_dirs: the directories of the closed list's triggers, repository-relative, for --diff-dir.
diff_dirs() {
  [ -f "$out/behaviour.json" ] || die "run classify first"
  prefix="${prefix%/}"
  case "$prefix" in /* | *..* | .) die "--prefix must be repository-relative" ;; esac
  # The null-default variables classify read; none when it wrote none
  local nv='[]'
  [ ! -f "$out/nullvars.json" ] || nv="$(jq -c 'if type == "array" then . else [] end' "$out/nullvars.json" 2> /dev/null)" || nv='[]'
  jq -r --arg pre "$prefix" --argjson nv "${nv:-[]}" "$JQ_DEFS"' . as $b
    | [.triggers[] | select(diff_kind(.; $b; $nv) != null) | .file | tdir
       | if $pre == "" then . elif . == "." then $pre else $pre + "/" + . end] | unique[]' "$out/behaviour.json"
}

case "$cmd" in
  classify) classify ;;
  diff-dirs) diff_dirs ;;
  eval) evaluate ;;
  wrappers) wrapper_pairs ;;
  *) die "the first argument is classify, eval, wrappers or diff-dirs" ;;
esac
