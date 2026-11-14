#!/bin/bash
# behaviour-pass.sh: Steps 5.4 and 5.5 of terraform-module-pr-review, the behaviour classifier and
# the claims evaluation, both by mtf-facts. Rules: behaviour-pass.md. Invoke it by an absolute path
# in this skill's own checkout, never from the clone under review.
#
#   behaviour-pass.sh classify --facts <mtf-facts> --dir <module root>
#       (--diff <files.json> [--prefix <module root prefix>] | --base <dir>) [--schema <schema.json>] --out <dir>
#   behaviour-pass.sh eval --facts <mtf-facts> --out <dir> --head <sha> --base-sha <sha>
#       [--claims <claims.json>] [--ladder <ladder.json>] [--wrappers <wrappers.txt>]
#   behaviour-pass.sh wrappers --clone <dir> --head <sha> --diff <files.json> [--prefix <p>] --out <dir>
#
# wrappers writes <out>/wrappers.txt, one line per wrapper versions.tf the change touches: its
# module-relative path and derived, copied, differs or "unknown <reason>" (behaviour-pass.md,
# Wrapper Versions). It reads the head tree with the git form of the reviewer's git-safety.md and
# runs nothing from the clone. eval with --wrappers makes an unverifiable trigger at a derived or
# copied wrapper inert.
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
facts="" dir="" diff="" prefix="" base="" schema="" out="" head="" bsha="" claims="" ladder="" wrappers="" clone=""
while [ $# -gt 0 ]; do
  case "$1" in
    --facts) facts="${2-}" ;; --dir) dir="${2-}" ;; --diff) diff="${2-}" ;; --prefix) prefix="${2-}" ;; --base) base="${2-}" ;; --schema) schema="${2-}" ;;
    --out) out="${2-}" ;; --head) head="${2-}" ;; --base-sha) bsha="${2-}" ;;
    --claims) claims="${2-}" ;; --ladder) ladder="${2-}" ;; --wrappers) wrappers="${2-}" ;; --clone) clone="${2-}" ;;
    *) die "unexpected argument" ;;
  esac
  [ $# -ge 2 ] || die "$1 needs a value"; shift 2
done
abs() { case "$1" in /?*) ;; *) die "$2 must be an absolute path" ;; esac; }
abs "$out" --out; [ -d "$out" ] && [ ! -L "$out" ] || die "--out is not a directory"
[ "$cmd" = wrappers ] || abs "$facts" --facts

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
        # Contract 2: the categories of the triggers merged into this one, each a category once.
        and ((has("also_categories") | not) or (.also_categories | type == "array" and length > 0
              and all(.[]; IN(cats[])) and length == (unique | length)))
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
  # The wrapper evidence of the wrappers command: only a file whose every line is in its grammar
  # counts; any other is no evidence, as with no file.
  local wj='{}'
  if [ -n "$wrappers" ]; then
    abs "$wrappers" --wrappers; [ -f "$wrappers" ] && [ ! -L "$wrappers" ] || die "--wrappers is not a regular file"
    wj="$(jq -R -s -c --arg re "$WRAP_LINE_RE" 'split("\n") | map(select(. != ""))
      | if length <= 256 and all(.[]; test($re)) then map(capture("^(?<p>[^ ]+) (?<r>.+)$") | {(.p): .r}) | add // {} else {} end' \
      "$wrappers" 2> /dev/null)" || wj='{}'
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
  jq -n --slurpfile b "$out/behaviour.json" --slurpfile e "$out/eval.raw" --argjson c "$cf" --argjson w "$wj" "$JQ_DEFS"'
    $b[0] as $b
    # An unverifiable trigger at a wrapper versions.tf the host found equal to its generator output
    # is inert, with no outstanding difference: the wrapper is the module file, as the hook writes it.
    | ($e[0] | .triggers |= map(.id as $id | (first($b.triggers[] | select(.id == $id)) | .file) as $f
        | if .state == "unverifiable" and ($w[$f] // "" | IN("derived", "copied"))
          then {id, state: "inert", wrapper: $w[$f]} else . end)) as $e
    | def kstate($id): first($e.claims[] | select(.claim_id == $id) | .state) // "discarded";
    {run: {status: "ran", reason: null,
       triggers: [$b.triggers[] as $t | first($e.triggers[] | select(.id == $t.id)) as $et
                  | {id: $t.id, file: $t.file, line: $t.line, category: $t.category, state: $et.state}
                    + ($t | with_entries(select(.key == "also_categories")))
                    + ($et | with_entries(select(.key | IN("complete", "outstanding", "evidence_digest"))))],
       claims: [$c.claims[] | {claim_id, state: (kstate(.claim_id) | if . == "discarded" then "unverifiable" else . end)}],
       capped: $b.capped},
     record: (["behaviour: ran, \($b.triggers | length) triggers, \($b.capped) over the cap\(if $b.inert then ", inert" else "" end)"]
       + [$b.triggers[] as $t | first($e.triggers[] | select(.id == $t.id)) as $et
          | "trigger \($t.id) `\($t.file)`\(if $t.line == null then "" else " line \($t.line)" end) \($t.category): \($et.state)"
            + (if $et.wrapper != null then ", wrapper \($et.wrapper)" else "" end)
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

# --- Wrapper versions (behaviour-pass.md, Wrapper Versions) ---------------------------------------

WRAP_RE='^wrappers/([A-Za-z0-9_][A-Za-z0-9._-]{0,63}/)?versions\.tf$'
WRAP_LINE_RE='^wrappers/([A-Za-z0-9_][A-Za-z0-9._-]{0,63}/)?versions\.tf (derived|copied|differs|unknown [a-z0-9 .-]{1,60})$'
WRAP_CAP=65536
DERIVE="$(cd "$(dirname "$0")" && pwd -P)/wrapper-derive.pl"
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
    exit print "unknown pin unreadable\n" if (() = $s =~ /^["\x27]?repos["\x27]?[ \t]*:/gmi) > 1;
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
      $repo = $2 if /^[ \t]*-[ \t]+repo:[ \t]+(["\x27]?)(\S+?)\1[ \t]*(#.*)?$/;
      $rev = $2 if /^[ \t]+rev:[ \t]+(["\x27]?)([^"\x27\s#]+)\1[ \t]*(#.*)?$/;
      # A repo or rev key in any other spelling, a duplicate a YAML loader would keep last included.
      exit print "unknown pin unreadable\n" if /^[ \t]*(-[ \t]+)?["\x27]?(repo|rev)["\x27]?[ \t]*:/i && !defined $repo && !defined $rev;
      # A repo URL outside a plain https form, a percent escape for one, could name the repository
      # where the reader does not see it.
      exit print "unknown pin unreadable\n" if defined $repo && $repo !~ m{^(https://[A-Za-z0-9._/-]+|local|meta)$};
      if (defined $repo) { $in = $repo =~ /^$url$/; push @e, {rev => [], hook => 0} if $in; next }
      if (/^\S/) { $in = 0; next }
      next unless $in;
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
    my ($maj, $min, $pat) = $e[0]{rev}[0] =~ /^v?([0-9]{1,5})\.([0-9]{1,5})\.([0-9]{1,5})$/
      or exit print "unknown pin not a release tag\n";
    print +($maj <=> 1 || $min <=> 106 || $pat <=> 0) >= 0 ? "derive\n" : "copy\n";' "$out/wrap/pin"
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

case "$cmd" in
  classify) classify ;;
  eval) evaluate ;;
  wrappers) wrapper_pairs ;;
  *) die "the first argument is classify, eval or wrappers" ;;
esac
