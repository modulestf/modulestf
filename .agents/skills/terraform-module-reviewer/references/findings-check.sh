#!/bin/bash
# findings-check.sh: checks a findings list against the limits the pull request review's host
# render enforces, so a reviewer finds a violation before it returns the list, not after the
# render refuses the whole run.
#   bash findings-check.sh [--refuted <n>] <findings.json>   the findings list, a regular file
#   bash findings-check.sh [--refuted <n>] -                 the findings list on standard input
# <n> is the number of `claim` and `trigger` lines of the verification record whose state is
# refuted, 0 when the task carries no record. The render refuses any claim.* finding when it is 0.
# Prints one line per violation, "<finding id> <field>: <what is wrong>", and exits 1 when there
# is any. A line that starts with "note " is advice, not a violation. Prints "findings-check: ok"
# and exits 0 when there is no violation. Exits 2 only when the checker itself cannot run: a
# bad argument, an input that is not a readable regular file, no jq, a jq that fails on input
# that parses, or no rule table in rule-facts.md beside this script. No input can cause it.
# It reads the one input and rule-facts.md, writes only to its output, runs nothing else and
# makes no network call. findings-schema.md#checking-the-findings says what it checks and why.
# The jq definitions of rule_pat, nat, clean_text, plain_path, diff_id, digest, explaining_rule,
# sev_rank and band_ok, the caps and the field lists are copies of render-comment.jq of the pull
# request review skill, held equal by tests/findings-check-test.sh: change both or neither.
set -u
export LC_ALL=C

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
RULES="$HERE/rule-facts.md"
CAP=1048576

die() { echo "findings-check: $*" >&2; exit 2; }
refuted=0
if [ "${1-}" = --refuted ]; then
  refuted="${2-}"; shift 2 2> /dev/null || die "usage: findings-check.sh [--refuted <n>] <findings.json> | -"
  case "$refuted" in '' | *[!0-9]* | ???????*) die "--refuted needs a number of at most 6 digits" ;; esac
fi
[ "$#" = 1 ] || die "usage: findings-check.sh [--refuted <n>] <findings.json> | -"
command -v jq > /dev/null 2>&1 || die "jq is not installed"
[ -f "$RULES" ] && [ ! -L "$RULES" ] || die "rule-facts.md is not beside this script"
if [ "$1" != - ]; then
  [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ] || die "$1 is not a readable regular file"
fi

read -r -d '' LIB <<'JQ' || true
def sev_order: ["CRITICAL", "HIGH", "MEDIUM", "LOW"];
def rule_pat: "(compat|coverage|structure|examples|profile|scope|review|claim)\\.[a-z0-9]+(-[a-z0-9]+)*";
def nat: type == "number" and . >= 0 and . == floor;
def clean_text: type == "string" and length > 0 and (test("[\\x00-\\x1f\\x7f]") | not);
def plain_path: type == "string" and length > 0 and length <= 1024
  and test("^(\\.|(?!/)(?!.*\\\\)(?!(.*/)?\\.\\.(/|$)).+)$")
  and (test("[\\x00-\\x1f\\x7f`]") | not);
def diff_id: type == "string" and test("^T-[0-9]{3}\\|L[1-4]\\|[A-Za-z0-9_.:-]{1,64}\\|[a-z_]{1,32}$");
def digest: type == "string" and test("^[0-9a-f]{64}$");
def explaining_rule: . == "compat.expression-behaviour-changed" or startswith("claim.");
def sev_rank: {"CRITICAL": 3, "HIGH": 2, "MEDIUM": 1, "LOW": 0}[.];
def band_ok:
  ([.[] | select((.rule_id | startswith("compat.")) and (.rule_id | IN("compat.claim-contradicts-analysis", "compat.break-unexplained") | not))
    | .severity | sev_rank] | max) as $c
  | all(.[] | select(.rule_id == "compat.claim-contradicts-analysis"); $c != null and (.severity | sev_rank) <= ([$c - 1, 0] | max));
def summary_cap: 500;
def fix_cap: 600;
def list_cap: 1000;
def allowed_keys: ["evidence_digest", "explains", "file", "id", "line", "rule_id", "severity", "suggested_fix", "summary"];
def host_keys: ["candidate_id", "confirmed_by", "predates_change", "source", "subject"];
def required_keys: ["file", "id", "line", "rule_id", "severity", "suggested_fix", "summary"];
def new_rule_opener: "New rule_id, not in the registry:";
# The one severity outside a rule's registry row that the skill itself gives: the in-repo downgrade
# of profile-selection.md makes a confirmed break of these five rules MEDIUM. The five names equal
# the Downgrade list of the maintainer's profile-format.md, held equal by tests/findings-check-test.sh.
def documented_bands: [["compat.variable-removed", "MEDIUM"], ["compat.variable-now-required", "MEDIUM"],
  ["compat.type-narrowed", "MEDIUM"], ["compat.default-changed", "MEDIUM"],
  ["compat.generated-policy-narrowed", "MEDIUM"]];

# The registry: rule_id -> allowed severities, from the rule table of rule-facts.md, read as the
# render reads it: the table under the header "| `rule_id` | Provider facts |", up to its first
# line that is not a table row. "none" in the severities column is an empty list.
def cells: split("|") | map(gsub("^ +| +$"; ""));
def registry:
  [$rules | splits("\n")] as $l
  | (first(range($l | length) | select($l[.] | startswith("| `rule_id` | Provider facts |"))) // null) as $h
  | if $h == null then {} else
      ($l[$h] | cells | to_entries | map(select(.value == "`severities`")) | .[0].key) as $c
      | reduce ($l[$h + 2:] | label $out | .[] | if startswith("|") then . else break $out end) as $row ({};
          ($row | cells) as $x
          | ($x[1] | capture("^`(?<id>" + rule_pat + ")`$")? // null) as $m
          | if $m == null or $c == null then . else .[$m.id] = ($x[$c] | if . == "none" then [] else split(", ") end) end)
    end;

# A finding is named by its id only when the id has the form F-001; any other id is the
# reviewer's own text, possibly quoted from the change, and is never echoed.
def fid($i): if type == "object" and (.id | type == "string") and (.id | test("^F-[0-9]{3,}$")) then .id else "#\($i + 1)" end;
def viol($id; $field; $msg): "\($id) \($field): \($msg)";
def note($id; $field; $msg): "note \($id) \($field): \($msg)";
def bad($cond; $id; $field; $msg): if $cond then viol($id; $field; $msg) else empty end;
def text_check($id; $field; $cap):
  if has($field) then
    (.[$field]) as $t
    | bad(($t | clean_text | not); $id; $field; "empty, not a string or holds a control character"),
      bad(($t | type == "string" and length > $cap); $id; $field; "\($t | if type == "string" then length else 0 end) characters, limit \($cap)")
  else empty end;

def check_one($id; $reg; $refuted):
  if type != "object" then viol($id; "finding"; "not an object") else
    ( (keys - allowed_keys - host_keys)[] | viol($id; (.[0:40] | @json); "not a field of a finding") ),
    ( (keys | map(select(IN(host_keys[]))))[] | viol($id; .; "set by the host, never by a review run; remove it") ),
    ( (required_keys - keys)[] | viol($id; .; "missing") ),
    ( if has("id") then bad((.id | type == "string" and test("^F-[0-9]{3,}$") | not); $id; "id"; "not of the form F-001") else empty end ),
    ( if has("file") then bad((.file | plain_path | not); $id; "file"; "not a path relative to the module root, or `.`, with no backtick or control character") else empty end ),
    ( if has("line") then bad((.line == null or (.line | nat and . > 0) | not); $id; "line"; "neither null nor a 1-based line number") else empty end ),
    text_check($id; "summary"; summary_cap),
    text_check($id; "suggested_fix"; fix_cap),
    ( if has("rule_id") then
        (.rule_id) as $r
        | if ($r | type == "string" and test("^" + rule_pat + "$")) | not then
            viol($id; "rule_id"; "not of the form <check>.<slug> with a check prefix of the findings schema")
          elif $r | startswith("claim.") then
            if ($reg | has($r) | not) then
              viol($id; "rule_id"; "\($r) is not a registry rule; the claim. prefix is reserved for the refuted behaviour claims of Check G, so use "
                + (if $refuted > 0 then "claim.refuted or claim.fix-not-effective for a refuted claim, and otherwise " else "" end)
                + "the registry rule outside claim. that names the defect")
            elif $refuted == 0 then
              viol($id; "rule_id"; "\($r) needs a claim or trigger line with state refuted in the verification record, and none is counted (--refuted 0); the render refuses the whole list. Report the defect under a rule outside claim., or pass the count with --refuted <n>")
            else empty end
          elif ($reg | has($r) | not) then
            if (.summary | type == "string" and startswith(new_rule_opener)) then empty
            else viol($id; "rule_id"; "\($r) is not in the registry, so the host reads it as an unknown and never at its severity; use the registry rule that names the defect, or open the summary with `\(new_rule_opener)`")
            end
          elif ($reg[$r] | length) == 0 then
            note($id; "rule_id"; "\($r) is a registry name that is never emitted as a finding; use the rule that names the defect")
          else empty end
      else empty end ),
    ( if has("severity") then
        (.severity) as $s
        | if ($s | IN(sev_order[])) | not then
            viol($id; "severity"; "not one of CRITICAL, HIGH, MEDIUM or LOW")
          else
            (.rule_id // null) as $r
            | bad(($r | type == "string" and startswith("review.") and $s == "CRITICAL"); $id; "severity"; "a review.* finding is never CRITICAL; a defect of the module filed under review.* has the wrong rule name, so use the rule that names the defect"),
              bad($r == "review.tool-disputed" and $s != "LOW"; $id; "severity"; "a review.tool-disputed finding is LOW; a defect of the module filed under it has the wrong rule name, so use the rule that names the defect"),
              # The render reads no severity band of a rule, so a severity outside the registry row is advice:
              # a wrong rule name is a possible cause, and lowering the severity is never the fix.
              ( if ($r | type == "string") and ($reg | has($r)) and ($reg[$r] | length) > 0 and ($s | IN($reg[$r][]) | not) and ([$r, $s] | IN(documented_bands[]) | not) then
                  note($id; "severity"; "\($s) is outside the registry band of \($r), \($reg[$r] | join(", ")); check the rule name: if the rule is right, keep the severity and the render decides; if the reading fits another rule, use the rule whose Severity text gives \($s), or report a new name with the opener; never lower a severity to pass this check")
                else empty end )
          end
      else empty end ),
    ( if has("explains") or has("evidence_digest") then
        bad((.rule_id | type == "string" and explaining_rule | not); $id; "explains"; "only a compat.expression-behaviour-changed or claim.* finding carries explains and evidence_digest"),
        bad((has("explains") != has("evidence_digest")); $id; "evidence_digest"; "explains and evidence_digest are set together"),
        ( if has("explains") then bad((.explains | type == "array" and length > 0 and length <= 256 and all(.[]; diff_id) | not); $id; "explains"; "not a list of 1 to 256 difference ids") else empty end ),
        ( if has("evidence_digest") then bad((.evidence_digest | digest | not); $id; "evidence_digest"; "not 64 lowercase hex characters") else empty end )
      else empty end )
  end;
JQ

MAIN='
registry as $reg
| . as $in
| if length != 1 then "findings: the input is not one JSON list"
  elif ($in[0] | type) != "array" then "findings: not a JSON list"
  else
    $in[0] as $l
    | ([$l[] | select(type == "object" and (.rule_id | type == "string") and (.severity | type == "string") and (.severity | IN(sev_order[])))]) as $banded
    | bad(($l | length) > list_cap; "findings"; "list"; "\($l | length) findings, limit \(list_cap)"),
      ( $l | to_entries[] | .key as $i | .value | check_one(fid($i); $reg; $refuted) ),
      ( [$l[] | select(type == "object" and (.id | type == "string") and (.id | test("^F-[0-9]{3,}$"))) | .id] | group_by(.) | map(select(length > 1) | .[0])[]
        | viol(.; "id"; "used by more than one finding") ),
      ( $l | to_entries[] | .key as $i | .value | select(type == "object" and .rule_id == "compat.claim-contradicts-analysis"
              and (.severity | type == "string") and (.severity | IN(sev_order[]))) as $f
        | select(([$banded[] | select(.rule_id != "compat.claim-contradicts-analysis")] + [$f]) | band_ok | not)
        | ($f | fid($i)) as $fi
        | viol($fi; "severity"; "a compat.claim-contradicts-analysis finding sits one band below the highest compat.* code finding that refutes its claim, and needs one") )
  end'

# The setup: the rule table must read. A failure here is the checker's, never the input's.
jq -n -e --rawfile rules "$RULES" "$LIB registry | length > 0" > /dev/null 2>&1
case $? in
  0) ;;
  1) die "rule-facts.md holds no rule table" ;;
  *) die "jq cannot run the checker" ;;
esac

# The input: at most CAP + 1 bytes are read. A NUL byte ends read -d '' with status 0, a stream
# with none ends it at the end of input with status 1.
slurp() { if [ "$1" = - ]; then head -c $((CAP + 1)); else head -c $((CAP + 1)) < "$1"; fi; }
data=""
IFS= read -r -d '' data < <(slurp "$1")
if [ $? = 0 ]; then echo "findings: not valid JSON, the input holds a NUL byte"; exit 1; fi
[ "${#data}" -le "$CAP" ] || { echo "findings: over the 1 MiB size cap"; exit 1; }
printf '%s' "$data" | jq empty > /dev/null 2>&1 || { echo "findings: not valid JSON"; exit 1; }
out="$(printf '%s' "$data" | jq -s -r --argjson refuted "$refuted" --rawfile rules "$RULES" "$LIB $MAIN" 2> /dev/null)" \
  || die "jq failed on input that parses; this is a fault of the checker"

nviol="$(printf '%s\n' "$out" | awk 'NF && !/^note / { n++ } END { print n + 0 }')"
nnote="$(printf '%s\n' "$out" | awk '/^note / { n++ } END { print n + 0 }')"
[ -z "$out" ] || printf '%s\n' "$out"
if [ "$nviol" != 0 ]; then exit 1; fi
if [ "$nnote" != 0 ]; then echo "findings-check: ok, $nnote note(s) to read"; else echo "findings-check: ok"; fi
