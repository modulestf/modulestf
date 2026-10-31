# render-comment.jq: the pure parts of render-comment.sh, as jq functions. Every rule here is
# stated in verdict.md (The Ladder, Clamps), comment-format.md (Section Order, What to Do,
# Grouping Findings, Collapsing Findings, Leak Scan, At-mentions), render-output.md and host-pass.md
# (Host Facts). The shell reads and writes; these functions decide.
# Loaded with: jq -L <references dir> 'include "render-comment"; ...'

def sev_order: ["CRITICAL", "HIGH", "MEDIUM", "LOW"];
def rule_pat: "(compat|coverage|structure|examples|profile|scope|review|claim)\\.[a-z0-9]+(-[a-z0-9]+)*";
def nat: type == "number" and . >= 0 and . == floor;
def clean_text: type == "string" and length > 0 and (test("[\\x00-\\x1f\\x7f]") | not);
def plain_path: type == "string" and length > 0 and length <= 1024
  and test("^(\\.|(?!/)(?!.*\\\\)(?!(.*/)?\\.\\.(/|$)).+)$")
  and (test("[\\x00-\\x1f\\x7f`]") | not);
def pos(f): [to_entries[] | select(.value | f) | .key][0];

# --- Input grammar: modulestf/facts schema/merged-findings.schema.json, plus what a render needs
# on top: unique ids, no control character in a rendered field, no backtick in a path, and a
# review.tool-disputed note at LOW, as the spec gives it.

def plain_subject: type == "string" and length > 0 and (test("^" + rule_pat + "@") | not);

def valid_finding:
  type == "object"
  and (keys - ["candidate_id", "confirmed_by", "file", "id", "line", "rule_id", "severity",
               "source", "subject", "suggested_fix", "summary"]) == []
  and (["file", "id", "line", "rule_id", "severity", "source", "suggested_fix", "summary"] - keys) == []
  and (.id | type == "string" and test("^F-[0-9]{3,}$"))
  and (.rule_id | type == "string" and test("^" + rule_pat + "$"))
  and (.severity | IN(sev_order[]))
  and ((.rule_id | startswith("review.")) as $r | ($r and .severity == "CRITICAL") | not)
  and (.rule_id != "review.tool-disputed" or .severity == "LOW")
  and (.file | plain_path)
  and (.line == null or (.line | nat and . > 0))
  and (.summary | clean_text) and (.suggested_fix | clean_text)
  and (.source | IN("tool", "llm", "host"))
  and (has("candidate_id") == has("confirmed_by"))
  and ((has("candidate_id") | not) or (.candidate_id | type == "string" and test("^C-[0-9]{3,}$")))
  and ((has("subject") | not) or (.subject | type == "string" and length > 0))
  and (if .source == "tool" then
         has("subject") and (.subject | plain_subject) and (.rule_id | startswith("review.") | not)
         and ((has("confirmed_by") | not) or (.confirmed_by | IN("small", "mid")))
       elif .source == "llm" then
         ((has("subject") | not) or (.subject | plain_subject))
         and ((has("confirmed_by") | not) or .confirmed_by == "lead")
         and ((has("candidate_id") | not) or has("subject"))
       elif .rule_id == "review.check-not-run" then
         has("subject") and (.subject | test("^" + rule_pat + "@.")) and (has("candidate_id") | not)
       else
         has("subject") and (.subject | plain_subject) and has("candidate_id")
         and (.confirmed_by | IN("small", "mid"))
       end);

def valid_findings: type == "array" and length <= 1000 and all(.[]; valid_finding)
  and (map(.id) | length == (unique | length));

def gap_reasons: ["terraform was not installed", "init failed", "not run: environment",
  "not run: symbolic link", "verification input refused", "host results rejected: not JSON",
  "host results rejected: shape", "host results rejected: head_sha", "host results rejected: base_sha",
  "host results rejected: example directories", "host verification did not run",
  "merge base not available", "merge base not run: environment", "not run: command limit", "not run: budget",
  "merge base not run: command limit", "merge base not run: budget"];

# The fixed reasons verify-pass.sh coverage gives an example that was not planned.
def unplanned_reasons: ["no example directory", "no AWS profile named", "not reached by the plan pass",
  "code-error, merge base not planned", "environment", "needs input", "output unrecognised", "budget",
  "plan pass ended: credentials", "plan gate G0", "plan gate G1", "plan gate G2", "plan gate G3",
  "exception: example assumes a role in another account", "exception: needs a Docker daemon"];

# The behaviour object behaviour-pass.sh eval writes (behaviour-pass.md, The run object).
def behaviour_reasons: ["mtf-facts not installed", "mtf-facts failed", "mtf-facts timed out", "output refused",
  "claims refused", "ladder refused"];
def behaviour_categories: ["wrapper-change", "default-change", "count-for_each-conditional-change",
  "type-validation-change", "dynamic-block-change", "locals-outputs-change", "moved-or-renamed-address",
  "provider-version-floor-change", "unknown-propagation-candidate", "literal-argument-change",
  "resource-added-or-removed", "lifecycle-change", "unclassified-change", "non-hcl-dependency"];
def valid_behaviour:
  type == "object" and keys == ["capped", "claims", "reason", "status", "triggers"]
  and (.capped | nat)
  and (.triggers | type == "array" and length <= 40 and all(.[]; type == "object"
        and keys == ["category", "file", "id", "line", "state"] and (.id | type == "string" and test("^T-[0-9]{3}$"))
        and (.file | plain_path) and (.line == null or (.line | nat and . > 0))
        and (.category | IN(behaviour_categories[]))
        and (.state | IN("inert", "verified", "covered", "refuted", "unverifiable")))
        and (map(.id) | length == (unique | length)))
  and (.claims | type == "array" and length <= 48 and all(.[]; type == "object"
        and keys == ["claim_id", "state"] and (.claim_id | type == "string" and test("^C-[0-9]+$"))
        and (.state | IN("verified", "refuted", "unverifiable")))
        and (map(.claim_id) | length == (unique | length)))
  and (if .status == "ran" then .reason == null
       else .status == "not-run" and (.reason | IN(behaviour_reasons[])) and .triggers == [] and .claims == [] and .capped == 0 end);

# The behaviour object the render reads: the run file's, or, outside a triage run, a step the
# host did not run, so a host that leaves the key out never approves on reading alone.
def behaviour_of($run):
  if $run | has("behaviour") then $run.behaviour
  elif $run.triage then null
  else {status: "not-run", reason: "not run by the host", triggers: [], claims: [], capped: 0} end;

# The behaviour gaps: each unverified trigger and claim, each trigger over the cap, and a
# behaviour step that did not run. A refuted state is no gap: it blocks at rule 2.
def behaviour_gaps: if . == null then 0 elif .status == "not-run" then 1
  else ([.triggers[], .claims[] | select(.state == "unverifiable")] | length) + .capped end;
def behaviour_refuted: if . == null then 0 else [.triggers[], .claims[] | select(.state == "refuted")] | length end;

# A claim.* finding words a refuted state; one with no refuted state in the behaviour object is
# refused.
def claims_consistent($findings; $run):
  (any($findings[]; .rule_id | startswith("claim.")) | not) or (behaviour_of($run) | behaviour_refuted > 0);

def valid_run:
  type == "object"
  and ((keys - ["behaviour"]) == ["counts", "coverage", "format", "plan_ran", "triage", "verify_gaps"])
  and ((has("behaviour") | not) or (.behaviour | valid_behaviour))
  and .format == 1
  and (.triage | type == "boolean") and (.plan_ran | type == "boolean")
  and (.verify_gaps | type == "array" and all(.[]; type == "object"
        and keys == ["dir", "reason"] and (.dir | plain_path) and (.reason | IN(gap_reasons[]))))
  and (.coverage | type == "object" and keys == ["class", "inert", "unplanned"]
        and (.class | IN("complete", "partial", "none")) and (.inert | type == "boolean")
        and (.unplanned | type == "array" and all(.[]; type == "object"
              and keys == ["dir", "reason"] and (.dir | plain_path) and (.reason | IN(unplanned_reasons[]))))
        and ((.class == "complete") == (.unplanned == [])))
  and (.counts == null or (.counts | type == "object"
        and keys == ["conversation-claims-unread", "instruction-like-text-from-others",
                     "review.quoted-claim-unverifiable"]
        and all(.[]; nat)));

# Model text, so it must not pass for another part of the body: printable ASCII and newlines,
# at most two paragraphs of at most 1000 characters each, and no line that starts like a
# heading (ATX or a setext underline), a bold verdict line, HTML, a list item, a quote or a
# table row.
def valid_assessment: type == "string" and length <= 4096
  and test("^[\\x20-\\x7e\\n]*$") and test("[\\x21-\\x7e]")
  and (sub("\n+$"; "") | split("\n\n") as $ps
       | ($ps | length) <= 2
       and all($ps[]; length > 0 and length <= 1000 and (test("^\\s|\\s$|\n\\s*\n") | not))
       and all(split("\n")[]; test("^\\s*(#|\\*\\*|<|[-*+] |[0-9]+[.)] |>|\\||=+\\s*$|-+\\s*$)") | not));

# --- Paths: Step 8 puts the module root prefix back in front of a module-root-relative path.

def repo_path($p): if $p == "" then . elif . == "." then $p else $p + "/" + . end;
def trigger_at($p): {category, location: ((.file | repo_path($p)) + (if .line == null then "" else ":\(.line)" end))};
def loc($p): "`" + (.file | repo_path($p)) + (if .line == null then "" else ":\(.line)" end) + "`";

# --- The ladder (verdict.md). Input: {findings, signals: {checks, threads, review_decision,
# mergeability}, unresolved, triage, gaps, refuted}. The disputed note is the one finding it does not read.

def ladder:
  (.findings | map(select(.rule_id != "review.tool-disputed"))) as $f
  | .signals as $g
  | def has_sev($s): any($f[]; .severity == $s);
  if has_sev("CRITICAL") and .refuted == 0
     and all($f[] | select(.severity == "CRITICAL" or .severity == "HIGH"); .rule_id | startswith("compat."))
    then {rule: 0, verdict: "hold for the next major"}
  elif has_sev("CRITICAL") then {rule: 1, verdict: "block"}
  elif has_sev("HIGH") or .refuted > 0 then {rule: 2, verdict: "block"}
  elif any($g.checks, $g.review_decision, $g.mergeability; . == "fail") then {rule: 3, verdict: "block"}
  elif .triage or any($g[]; . == "unknown")
       or any($f[]; .rule_id | IN("review.check-not-run", "review.no-change-identified", "review.verification-incomplete"))
       or .gaps > 0 or .unplanned > 0
    then {rule: 4, verdict: "inconclusive"}
  elif .unresolved > 0 then {rule: 5, verdict: "changes suggested"}
  elif has_sev("MEDIUM") then {rule: 6, verdict: "block"}
  elif has_sev("LOW") then {rule: 7, verdict: "approve with nits"}
  else {rule: 8, verdict: "approve"} end;

def verdict_line: {
  "hold for the next major": "Breaking. Hold for the next major release.",
  "block": "Changes requested before merge.", "inconclusive": "Inconclusive.",
  "changes suggested": "Changes suggested.", "approve with nits": "Good to merge, with nits.",
  "approve": "Good to merge."}[.];

# render-output.md: block proposes REQUEST_CHANGES, approve APPROVE, the rest COMMENT; of the
# clamps only draft and closed or merged apply, each turning the event into COMMENT.
def proposed_event($state):
  if $state.draft or $state.state == "closed" or $state.merged then "COMMENT"
  elif . == "block" then "REQUEST_CHANGES" elif . == "approve" then "APPROVE" else "COMMENT" end;

def count_word: if . == 1 then "A"
  else (["Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"][. - 2] // tostring) end;
def and_join: if length <= 1 then .[0] else (.[:-1] | join(", ")) + " and " + .[-1] end;

# --- The fixed strings. comment-format.md, Host Render Strings, is the source: its table holds
# these keys and texts exactly, and tests/render-comment-test.sh checks the two are equal.
# {name} is a placeholder, filled in one pass by tx.

def texts: {
  "rationale-0": "The only CRITICAL and HIGH findings carry a `compat.*` rule_id. When only breaking-change findings block, the change waits for the next major release (ladder rule 0).",
  "rationale-open-one": "A {severity} finding is open. Any {severity} finding blocks merge (ladder rule {rule}).",
  "rationale-open-many": "{count} {severity} findings are open. Any {severity} finding blocks merge (ladder rule {rule}).",
  "rationale-2-refuted": "The behaviour evidence refutes a change or a claim of the description. Refuted behaviour blocks merge (ladder rule 2).",
  "rationale-3-one": "Failing host signal: {signals}. A failing host signal blocks merge (ladder rule 3).",
  "rationale-3-many": "Failing host signals: {signals}. A failing host signal blocks merge (ladder rule 3).",
  "rationale-4-triage": "A triage run leaves its deferred checks unknown. Any unknown makes the review inconclusive (ladder rule 4).",
  "rationale-4-checks": "The check results could not be read, so a failing check may exist. Any unknown makes the review inconclusive (ladder rule 4).",
  "rationale-4-threads": "Review thread resolution could not be read, so an open objection may exist. Any unknown makes the review inconclusive (ladder rule 4).",
  "rationale-4-review-decision": "The reviews could not be read, so a request for changes may exist. Any unknown makes the review inconclusive (ladder rule 4).",
  "rationale-4-mergeability": "Mergeability could not be read, so a merge conflict may exist. Any unknown makes the review inconclusive (ladder rule 4).",
  "rationale-4-no-change": "The workspace did not hold the change. Any unknown makes the review inconclusive (ladder rule 4).",
  "rationale-4-check-not-run": "A check did not run, so a defect it covers may be open. Any unknown makes the review inconclusive (ladder rule 4).",
  "rationale-4-verification-incomplete": "The behaviour evidence handed to the review was incomplete, so a behaviour change may be unchecked. Any unknown makes the review inconclusive (ladder rule 4).",
  "rationale-4-listed":"A check this review needs could not run, as listed below. Any unknown makes the review inconclusive (ladder rule 4).",
  "rationale-5": "Review threads are still unresolved. Unresolved threads mean changes are suggested (ladder rule 5).",
  "rationale-7": "Only LOW findings remain. LOW findings alone mean approve with nits (ladder rule 7).",
  "rationale-8": "No finding is open. With nothing open, the change is approved (ladder rule 8).",
  "signal-name-checks": "checks",
  "signal-name-review-decision": "review decision",
  "signal-name-mergeability": "mergeability",
  "checks-pass": "Checks pass.",
  "checks-fail": "Checks fail.",
  "checks-unknown": "Checks: unknown.",
  "mergeability-pass": "Mergeable.",
  "mergeability-fail": "Not mergeable.",
  "mergeability-unknown": "Mergeability: unknown.",
  "review-decision-pass": "Approved.",
  "review-decision-fail": "Changes requested.",
  "review-decision-none": "No review yet.",
  "review-decision-unknown": "Review decision: unknown.",
  "threads-pass": "Threads resolved.",
  "threads-unresolved": "Unresolved threads: {count}.",
  "threads-unknown": "Thread resolution: unknown.",
  "patch-unavailable": "- The patch of `{path}` was unavailable, so its changes could not be read.",
  "thread-resolution-unknown": "- Review thread resolution: the thread query was unavailable, so review comments were grouped by reply instead. Whether the open threads are resolved is unknown.",
  "prose-truncated": "- Quoted prose was truncated, so part of the discussion was not read.",
  "threads-over-count": "- {count} review thread comments over the count did not reach the review.",
  "verification": "- Verification of `{dir}`: {reason}.",
  "verification-more": "- {count} more example directories with a check that could not run are not listed.",
  "unplanned": "- `{dir}` was not planned: {reason}.",
  "unplanned-more": "- {count} more examples that were not planned are not listed.",
  "unplanned-no-examples": "- The module has no example directory, so no example could be planned.",
  "unplanned-inert": "- The change reaches no Terraform configuration, so the examples below that were not planned leave nothing unknown.",
  "behaviour-not-run": "- Behaviour check: {reason}, so no change was classified or verified.",
  "behaviour-trigger": "- Behaviour change at `{location}` ({category}): not verified.",
  "behaviour-capped": "- {count} more behaviour changes over the classifier cap: not verified.",
  "behaviour-claim": "- Claim {claim_id} from the description: not verified.",
  "behaviour-evidence": "Behaviour evidence: {count} changes classified: {verified} verified, {covered} covered by a plan, {inert} inert, {refuted} refuted, {unverifiable} not verified; {claims} claims: {claims_verified} verified, {claims_refuted} refuted, {claims_unverifiable} not verified.",
  "thread-match": "- `{location}`: this review has a finding at the same path and line.",
  "thread-no-match": "- `{location}`: this review has no finding at the same path and line.",
  "todo-lead-block": "To make this mergeable, resolve each checklist item below and push.",
  "todo-lead-4": "This review is incomplete, so a later run may add items. The items below are known.",
  "todo-lead-7": "Nothing blocks merge. The items below are optional.",
  "todo-lead-0": "This change is breaking. Merge it in the next major release. To merge it sooner, restore compatibility with the fixes named below. Any checklist items below also block merge.",
  "todo-checks": "Fix the failing checks.",
  "todo-mergeability": "Resolve the merge conflict.",
  "todo-review-decision": "Address the requested changes.",
  "todo-threads-one": "Resolve the open review thread.",
  "todo-threads-many": "Resolve the {count} open review threads.",
  "todo-fix-one": "`{rule_id}`: apply the Fix at {locations}.",
  "todo-fix-many": "`{rule_id}` ({count}): apply the Fix at {locations}.",
  "todo-compat-one": "`{rule_id}`: the Fix at {locations} restores compatibility.",
  "todo-compat-many": "`{rule_id}` ({count}): the Fix at {locations} restores compatibility.",
  "todo-optional-one": "Optional: `{rule_id}` at {locations}.",
  "todo-optional-many": "Optional: `{rule_id}` ({count}) at {locations}.",
  "todo-more": ", and {count} more",
  "todo-refuted": "Behaviour change at `{location}` ({category}): the evidence refutes it. Fix the change or correct the description.",
  "todo-generated": "Documentation tables are generated. After the edits above, run `pre-commit run -a` and commit the result. Do not edit them by hand.",
  "todo-triage": "This was a triage run. The full review has not run.",
  "todo-checks-unknown": "Check results could not be read or are still running.",
  "todo-threads-unknown": "Review thread resolution could not be read.",
  "todo-review-decision-unknown": "The reviews could not be read.",
  "todo-mergeability-unknown": "Mergeability could not be read.",
  "todo-gaps-one": "1 check could not run; see Checks that could not run.",
  "todo-gaps-many": "{count} checks could not run; see Checks that could not run.",
  "fix-fold": "Fix for each location ({count})"
};

def tx($k; $v): texts[$k] | gsub("\\{(?<n>[a-z_]+)\\}"; $v[.n] | tostring);
def tx($k): texts[$k];

# The rationale states the fact and the rule that fired, in words and by number. Rule 4 names its first unknown in
# this order: triage, the host signals, the unknown findings, then the listed checks.
def rationale($in):
  .rule as $r
  | ($in.findings | map(select(.rule_id != "review.tool-disputed"))) as $f
  | def open($s): ($f | map(select(.severity == $s)) | length) as $n
      | if $n == 1 then tx("rationale-open-one"; {severity: $s, rule: $r})
        else tx("rationale-open-many"; {count: ($n | count_word), severity: $s, rule: $r}) end;
  $in.signals as $g
  | if $r == 0 then tx("rationale-0")
    elif $r == 1 then open("CRITICAL")
    elif $r == 2 then (if any($f[]; .severity == "HIGH") then open("HIGH") else tx("rationale-2-refuted") end) elif $r == 6 then open("MEDIUM")
    elif $r == 3 then
      [("checks", "review-decision", "mergeability") as $s
       | select($g[$s | gsub("-"; "_")] == "fail") | tx("signal-name-" + $s)] as $n
      | tx(if ($n | length) > 1 then "rationale-3-many" else "rationale-3-one" end; {signals: ($n | and_join)})
    elif $r == 4 then
      tx(if $in.triage then "rationale-4-triage"
         elif $g.checks == "unknown" then "rationale-4-checks"
         elif $g.threads == "unknown" then "rationale-4-threads"
         elif $g.review_decision == "unknown" then "rationale-4-review-decision"
         elif $g.mergeability == "unknown" then "rationale-4-mergeability"
         elif any($f[]; .rule_id == "review.no-change-identified") then "rationale-4-no-change"
         elif any($f[]; .rule_id == "review.check-not-run") then "rationale-4-check-not-run"
         elif any($f[]; .rule_id == "review.verification-incomplete") then "rationale-4-verification-incomplete"
         else "rationale-4-listed" end)
    else tx("rationale-\($r)") end;

# --- Grouping Findings. One severity's findings, in the reviewer's order -> groups by rule_id,
# each with entries of findings whose summary and suggested_fix are identical.

def groups:
  reduce .[] as $f ([];
    (pos(.rule == $f.rule_id)) as $i
    | if $i == null then . + [{rule: $f.rule_id, items: [$f]}] else .[$i].items += [$f] end)
  | map(.entries = (reduce .items[] as $f ([];
      (pos(.[0].summary == $f.summary and .[0].suggested_fix == $f.suggested_fix)) as $i
      | if $i == null then . + [[$f]] else .[$i] += [$f] end)));

def locs($p): map(loc($p)) | join(", ");

# A group of 3 or more entries moves its Fix lines into one block under it, unless a field
# could open or close an HTML block or break a line.
def folds($p): (.entries | length) >= 3
  and all(.items[]; all(.summary, .suggested_fix, loc($p); test("</?details|\n"; "i") | not));

def full_group($p):
  (.items | length) as $n
  | if $n == 1 or (.entries | length) == 1 then
      .entries[0] as $e
      | "- `\(.rule)`\(if $n == 1 then "" else " (\($n))" end) - \($e | locs($p)) - \($e[0].summary)\n"
        + "  - Fix: \($e[0].suggested_fix)"
    elif folds($p) then
      "- `\(.rule)` (\($n)):"
      + ([.entries[] | "\n  - \(locs($p)) - \(.[0].summary)"] | join(""))
      + "\n\n<details><summary>\(tx("fix-fold"; {count: $n}))</summary>\n\n"
      + ([.entries[] | "- \(locs($p)) - Fix: \(.[0].suggested_fix)"] | join("\n"))
      + "\n\n</details>"
    else
      "- `\(.rule)` (\($n)):"
      + ([.entries[] | "\n  - \(locs($p)) - \(.[0].summary)\n    - Fix: \(.[0].suggested_fix)"] | join(""))
    end;

def collapsed_group($p):
  "<details><summary><code>\(.rule)</code> (\(.items | length))</summary>\n\n"
  + ([.entries[] | "- \(locs($p)) - \(.[0].summary)\n  - Fix: \(.[0].suggested_fix)"] | join("\n"))
  + "\n\n</details>";

# Consecutive groups in full form one list; a collapsed block, and a group whose Fix block
# ends it, stand apart from what follows by a blank line.
def join_blocks:
  reduce .[] as $b ({s: null, k: null};
    if .s == null then {s: $b.t, k: $b.k}
    else {s: (.s + (if .k == "full" and ($b.k | IN("full", "fold")) then "\n" else "\n\n" end) + $b.t), k: $b.k} end)
  | .s;

def full_block($p): {k: (if folds($p) then "fold" else "full" end), t: full_group($p)};

# --- Collapsing Findings. $rule is the ladder rule, $limit the threshold (10).

def findings_md($rule; $limit; $p):
  map(select(.rule_id != "review.tool-disputed")) as $f
  | map(select(.rule_id == "review.tool-disputed")) as $d
  | (($f | length) > $limit) as $fold
  | ([sev_order[] as $s | select(any($f[]; .severity == $s)) | $s][0]) as $top
  | [ sev_order[] as $s
      | ($f | map(select(.severity == $s))) as $in
      | select($in != [])
      | "**\($s)**\n\n" + ($in | groups | map(
          (if ($fold | not) or $s == "CRITICAL" or $s == "HIGH" then "full"
           elif .rule == "review.check-not-run" then (if $rule == 4 then "full" else "collapsed" end)
           elif $s == $top then "full" else "collapsed" end) as $k
          | if $k == "full" then full_block($p) else {k: $k, t: collapsed_group($p)} end)
        | join_blocks) ]
  + (if $d == [] then [] else ["**Disputed tool findings**\n\n" + ($d | groups | map(full_block($p)) | join_blocks)] end)
  | join("\n\n");

# --- What to do (comment-format.md, What to Do). Built from the verdict, the host signals, the
# thread count and each finding's severity, rule_id, count and location; never from a summary or
# a fix, except that a fix is searched for the fixed phrase of item e.

def stale_live: # a "Generated content made stale:" whose rest does not start " none." / " none," / " none"
  "Generated content made stale:" as $m | split($m) as $s
  | any(range(1; $s | length); $s[.:] | join($m) | test("^ none(\\.|,|\\z)") | not);

def loc_list($p): # the first eight locations, then the count of the rest
  map(loc($p)) as $l
  | ($l[:8] | join(", ")) + (if ($l | length) > 8 then tx("todo-more"; {count: (($l | length) - 8)}) else "" end);

# $gaps: the section 5 entries less the thread resolution one, which has its own item.
def todo_md($l; $rule; $p; $gaps):
  ($l.findings | map(select(.rule_id != "review.tool-disputed"))) as $f
  | $l.signals as $g
  | def grp($k): (.items | length) as $n
      | tx($k + (if $n == 1 then "-one" else "-many" end); {rule_id: .rule, count: $n, locations: ([.entries[][]] | loc_list($p))});
  # review.* groups are no item: the author cannot act on them. Rule 4 counts them as gaps.
  [sev_order[] as $s | $f | map(select(.severity == $s)) | groups[] | select(.rule | startswith("review.") | not)
   | . + {sev: $s}] as $gs
  | ($gaps + ($f | map(select(.rule_id | startswith("review."))) | length)) as $gaps
  | ([ ("checks", "mergeability", "review-decision") as $s
       | select($g[$s | gsub("-"; "_")] == "fail") | {box: true, t: tx("todo-" + $s)} ]
     + (if $l.unresolved == 1 then [{box: true, t: tx("todo-threads-one")}]
        elif $l.unresolved > 1 then [{box: true, t: tx("todo-threads-many"; {count: $l.unresolved})}] else [] end)
     + [ $gs[] | select(.sev != "LOW")
         | if $rule == 0 and (.rule | startswith("compat.")) then {box: false, t: grp("todo-compat")}
           else {box: true, t: grp("todo-fix")} end ]
     + [ $l.refuted_todo[] | {box: true, t: tx("todo-refuted"; trigger_at($p))} ]) as $abc
  | ($abc
     + [ $gs[] | select(.sev == "LOW") | {box: false, t: grp("todo-optional")} ]
     + (if any($l.findings[]; .suggested_fix | stale_live) then [{box: any($abc[]; .box), t: tx("todo-generated")}] else [] end)
     + (if $rule != 4 then [] else
          [ (select($l.triage) | "todo-triage"),
            (select($g.checks == "unknown") | "todo-checks-unknown"),
            (select($g.threads == "unknown") | "todo-threads-unknown"),
            (select($g.review_decision == "unknown") | "todo-review-decision-unknown"),
            (select($g.mergeability == "unknown") | "todo-mergeability-unknown")
          | {box: false, t: tx(.)} ]
          + (if $gaps == 1 then [{box: false, t: tx("todo-gaps-one")}]
             elif $gaps > 1 then [{box: false, t: tx("todo-gaps-many"; {count: $gaps})}] else [] end)
        end)) as $items
  | tx(if $rule == 0 then "todo-lead-0" elif $rule == 4 then "todo-lead-4" elif $rule == 7 then "todo-lead-7"
       else "todo-lead-block" end)
    + (if $items == [] then "" else "\n\n" + ($items | map((if .box then "- [ ] " else "- " end) + .t) | join("\n")) end);

# findings.json: the order the body shows them, the seven fields, the path repository-relative.
def body_order($p):
  (map(select(.rule_id != "review.tool-disputed")) as $f
   | [sev_order[] as $s | $f | map(select(.severity == $s)) | groups[] | .entries[][]])
  + [map(select(.rule_id == "review.tool-disputed")) | groups[] | .entries[][]]
  | map({id, rule_id, severity, file: (.file | repo_path($p)), line, summary, suggested_fix});

# --- Sections 5 to 8, from host.json (host-pass.md, Host Facts), the checks file and the run file.

def gap_lines($h; $run; $b; $p):
  [ $h.could_not_run[]
    | tx(.kind; {path: ((.path // "") | repo_path($p)), count: (.count // 0)}) ]
  + [ $run.verify_gaps[:100][]
      | tx("verification"; {dir, reason: (if .reason == "init failed" then "`init` failed" else .reason end)}) ]
  + ($run.verify_gaps | length - 100 | if . > 0 then [tx("verification-more"; {count: .})] else [] end)
  + (if $run.coverage.inert and $run.coverage.unplanned != [] then [tx("unplanned-inert")] else [] end)
  + [ $run.coverage.unplanned[:100][]
      | if .reason == "no example directory" then tx("unplanned-no-examples") else tx("unplanned"; {dir, reason}) end ]
  + ($run.coverage.unplanned | length - 100 | if . > 0 then [tx("unplanned-more"; {count: .})] else [] end)
  + ($b | if . == null then []
     elif .status == "not-run" then [tx("behaviour-not-run"; {reason})]
     else [ (.triggers[] | select(.state == "unverifiable") | tx("behaviour-trigger"; trigger_at($p))),
            (.capped | select(. > 0) | tx("behaviour-capped"; {count: .})),
            (.claims[] | select(.state == "unverifiable") | tx("behaviour-claim"; {claim_id})) ] end);

# The one evidence line under the rationale, when the behaviour step ran and classified anything.
def evidence_lines($b):
  if $b == null or $b.status != "ran" or ($b.triggers == [] and $b.claims == [] and $b.capped == 0) then []
  else
    def n($xs; $s): [$xs[] | select(.state == $s)] | length;
    [tx("behaviour-evidence"; {count: (($b.triggers | length) + $b.capped),
       verified: n($b.triggers; "verified"), covered: n($b.triggers; "covered"), inert: n($b.triggers; "inert"),
       refuted: n($b.triggers; "refuted"), unverifiable: (n($b.triggers; "unverifiable") + $b.capped),
       claims: ($b.claims | length), claims_verified: n($b.claims; "verified"),
       claims_refuted: n($b.claims; "refuted"), claims_unverifiable: n($b.claims; "unverifiable")})]
  end;

def state_lines($h; $c):
  ($h.signals + {checks: $c.signal}) as $g
  | (if any($g[]; . == "fail" or . == "unknown") then
      [ [tx("checks-" + $g.checks), tx("mergeability-" + $g.mergeability),
         tx("review-decision-" + $g.review_decision),
         (if $g.threads == "unknown" then tx("threads-unknown")
          elif $h.unresolved_threads != [] then tx("threads-unresolved"; {count: ($h.unresolved_threads | length)})
          else tx("threads-pass") end)] | join(" ") ]
    else [] end)
  + (if $h.related.status == "ok" then
       [$h.related.open_unlinked[] | "Open issue \(.) is not set to close on merge. Add `Closes \(.)` to the description."]
       | if . != [] and $h.related.sidebar_not_read then . + ["Sidebar links not read."] else . end
     elif $h.related.status == "too-many" then ["Related issues exceed 10, so closing keywords were not checked."]
     elif $h.related.status == "failed" then ["Related issues could not be read, so closing keywords were not checked."]
     else [] end)
  + (if $c.accepted | not then ["Checks: the host's check runs file was rejected."]
     else
       (if $c.own_check_dropped > 0 then ["Checks: the host's own check `\($c.own_check)` excluded."] else [] end)
       + (if $c.own_jobs_dropped > 0 then ["Checks: the jobs of the host's own workflow runs excluded."] else [] end)
       + (if $c.own_jobs_unreadable then ["Checks: the host's own jobs could not be read."] else [] end)
     end);

# A thread's path comes from the host already repository-relative (GitHub's own path), so only
# the finding's path takes the prefix.
def thread_lines($h; $f; $p):
  [ $h.unresolved_threads[] as $t
    | tx(if any($f[]; (.file | repo_path($p)) == $t.path and .line == $t.line)
         then "thread-match" else "thread-no-match" end;
         {location: ($t.path + (if $t.line == null then "" else ":\($t.line)" end))}) ];

def omission_keys: ["over-size", "over-budget", "over-quota", "minimized-excluded", "bot-over-size",
  "bot-over-budget", "bot-over-quota", "bot-minimized-excluded"];

def conversation_lines($cv; $n):
  def counted($keys): [$keys[] as $k | select($cv.counts[$k] != null) | "\($k):\($cv.counts[$k])"];
  counted(omission_keys | map(select(startswith("bot-") | not))) as $own
  | counted(omission_keys | map(select(startswith("bot-")))) as $bot
  | ($cv.notes + [("instruction-like-text-from-others", "conversation-claims-unread") as $k
                  | select($n[$k] >= 1) | "\($k):\($n[$k])"]) as $notes
  | (if $cv.omitted != null then ["Conversation and bot comments not considered: \($cv.omitted)."]
     else
       (if $cv.considered > 0 or $own != [] or $notes != [] then
          ["Conversation comments considered: \($cv.considered)."
           + (if $own == [] then "" else " Not considered: \($own | join(", "))." end)
           + (if $notes == [] then "" else " Notes: \($notes | join(", "))." end)]
        else [] end)
       + (if $cv.bot_considered > 0 or $bot != [] then
            ["Bot comments considered: \($cv.bot_considered)."
             + (if $bot == [] then "" else " Not considered: \($bot | join(", "))." end)]
          else [] end)
     end)
  + (if $n["review.quoted-claim-unverifiable"] >= 1 then
       ["Claims quoted from the discussion and not confirmed from the code: \($n["review.quoted-claim-unverifiable"])."]
     else [] end)
  + (if $n == null then ["Counts: not reported by the review run."] else [] end);

def section($title; $lines; $sep): if $lines == [] then [] else ["### \($title)\n\n" + ($lines | join($sep))] end;

# --- At-mentions. Within a line, code spans pair backtick strings of equal length (CommonMark);
# an opener with no closer is literal. A span that crosses a line is not seen, which only wraps
# more. Every at-mention outside a span is wrapped in a code span.

def mention_re: "@[A-Za-z0-9_-]+(/[A-Za-z0-9_.-]+)?";

def spans:
  [match("`+"; "g") | {o: .offset, l: .length}] as $r
  | def walk($i):
      if $i >= ($r | length) then []
      else ([range($i + 1; $r | length) | select($r[.].l == $r[$i].l)][0]) as $j
        | if $j == null then walk($i + 1) else [[$r[$i].o, $r[$j].o + $r[$j].l]] + walk($j + 1) end
      end;
    walk(0);

def outside_parts: # line -> [{out, code}] alternating text outside spans and the span after it
  . as $s
  | ([0] + (spans | map(.[0], .[1])) + [$s | length]) as $b
  | [range(0; $b | length; 2) as $k
     | {out: $s[$b[$k]:$b[$k + 1]],
        code: (if $k + 2 < ($b | length) then $s[$b[$k + 1]:$b[$k + 2]] else "" end)}];

def wrap_mentions:
  split("\n") | map(outside_parts | map((.out | gsub("(?<m>" + mention_re + ")"; "`\(.m)`")) + .code) | join(""))
  | join("\n");

def bare_mention: split("\n") | any(.[]; outside_parts | any(.[]; .out | test(mention_re)));

# --- Leak Scan. Parts are scanned in order, so a match names where the text came from.

def leak_hit($parts; $lits; $res):
  first(($parts[] as $p
         | (($lits[] | select(.v as $v | $p.text | index($v) != null)),
            ($res[] | select(.v as $v | $p.text | test($v))))
         | {pattern: .name, src: $p.src}), null);

# --- The whole render. $in: {findings, host, checks, run, assessment, plan_ran}.

def render($in):
  $in.host as $h | $in.host.prefix as $p
  | behaviour_of($in.run) as $b
  | {findings: $in.findings, signals: ($h.signals + {checks: $in.checks.signal}),
     unresolved: ($h.unresolved_threads | length), triage: $in.run.triage, refuted: ($b | behaviour_refuted),
     # A refuted trigger no blocking claim.* finding words is its own checklist item.
     refuted_todo: (if any($in.findings[]; (.rule_id | startswith("claim.")) and (.severity | IN("CRITICAL", "HIGH"))) then []
                    else [($b // {triggers: []}).triggers[] | select(.state == "refuted")] end),
     gaps: (($h.could_not_run | length) + ($in.run.verify_gaps | length) + ($b | behaviour_gaps)),
     unplanned: (if $in.run.coverage.inert then 0 else $in.run.coverage.unplanned | length end)} as $l
  | ($l | ladder) as $v
  | ($v | rationale($l)) as $why
  | ([$in.assessment, "**\($v.verdict | verdict_line)**"]
     + (if $in.run.triage then ["Triage only: the full review of this change has not run yet."] else [] end)
     + [$why]
     + evidence_lines($b)
     + (if $v.rule == 8 then [] else ["### What to do\n\n" + todo_md($l; $v.rule; $p;
          ([$h.could_not_run[] | select(.kind != "thread-resolution-unknown")] | length) + ($in.run.verify_gaps | length)
          + $l.unplanned + ($b | behaviour_gaps))] end)
     + (if $in.findings == [] then [] else ["### Findings\n\n" + ($in.findings | findings_md($v.rule; 10; $p))] end)
     + section("Checks that could not run"; gap_lines($h; $in.run; $b; $p); "\n")
     + section("Pull request state"; state_lines($h; $in.checks); "\n\n")
     + section("Existing threads"; thread_lines($h; $in.findings; $p); "\n")
     + section("Conversation comments"; conversation_lines($h.conversation; $in.run.counts); "\n\n")
     | join("\n\n") + "\n") as $body
  | {rule: $v.rule, verdict: $v.verdict, event: ($v.verdict | proposed_event($h.state)),
     body: $body, findings: ($in.findings | body_order($p)),
     parts: ([{src: "the assessment", text: $in.assessment}]
             + [$in.findings[] | {src: "finding \(.id)", text: "\(.file) \(.summary) \(.suggested_fix)"}]
             + [{src: "the host records", text: $body}])};
