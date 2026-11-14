# fix-plan.jq: fix-plan.md, the readable preview of a review-plan stage file, as render-output.md
# states it. Pure and model-free: the input is plan.json alone, the output the markdown text.
# Text from the pull request or the reviewer is data: one line in a code span, or verbatim in a
# fenced block. No heading holds any of it.
# Loaded with: jq -j -L <references dir> 'include "fix-plan"; fix_plan' plan.json

include "host-records"; # linecut and bytecut: the UTF-8 safe cuts of the handover caps

# The bytes of each feedback item's excerpt.
def excerpt_cap: 300;
# host-records.jq's cut($n) with the cap fixed: jq 1.8 aborts on that call from an including module.
def excerpt: if utf8bytelength <= excerpt_cap then . else (linecut(excerpt_cap) // bytecut(excerpt_cap)) end;

def longest_ticks: [scan("`+") | length] | max // 0;

# One line in a code span: control characters shown as spaces, a delimiter longer than any backtick run.
def span:
  (tostring | explode | map(if . < 32 or . == 127 then 32 else . end) | implode) as $t
  | ($t | longest_ticks) as $n
  | if $n == 0 then "`\($t)`" else ("`" * ($n + 1)) as $d | "\($d) \($t) \($d)" end;

# Text as a fenced block, verbatim: the fence is longer than any backtick run in the text.
def fence:
  ("`" * ([3, longest_ticks + 1] | max)) as $f
  | "\($f)text\n" + . + (if endswith("\n") or . == "" then "" else "\n" end) + "\($f)\n";

# The handover block -> [{kind, origin, text, omitted}] in block order: the lines between its
# BEGIN line and its RECORD line, in host-records.jq's block form. Any other shape is an error.
def plan_items:
  split("\n") as $l
  | ($l[0] | capture("^UNTRUSTED-(?<s>[0-9a-f]{12}) BEGIN$").s // error("no BEGIN line")) as $s
  | ([$l | indices("RECORD-\($s)")[]] | if length == 1 then .[0] else error("not one RECORD line") end) as $r
  | reduce $l[1:$r][] as $x ([];
      if ($x | test("^ITEM-\($s) kind=[a-z]+ origin=[a-z-]+$")) then
        . + [$x | capture(" kind=(?<kind>[a-z]+) origin=(?<origin>[a-z-]+)$") + {lines: [], omitted: 0}]
      elif length == 0 then error("text before the first item")
      elif ($x | test("^\\[truncated-\($s): [0-9]+ bytes omitted\\]$")) then
        .[-1].omitted = ($x | capture(": (?<n>[0-9]+) bytes").n | tonumber)
      else .[-1].lines += [$x] end)
  | map({kind, origin, text: (.lines | join("\n")), omitted});

# The opening of a suggested_fix that makes it no code change to apply as written, or null.
def not_applicable: .suggested_fix | tostring | (if startswith("needs decision:") then "needs decision:"
  elif startswith("no code change:") then "no code change:" else null end);

# Every "Generated content made stale:" sentence of a fix: from the marker to its first period
# followed by white space, or to the next marker or the end, so option (b) after it is not repeated.
def stale_sentences:
  "Generated content made stale:" as $m | .suggested_fix | tostring | split($m) | .[1:]
  | map($m + (sub("\\.\\s[\\s\\S]*$"; ".") | sub("\\s+$"; "")));

def scope_line:
  if .severity | IN("CRITICAL", "HIGH", "MEDIUM") then
    "a reviewer finding, applied by default; MEDIUM or higher, so it stays in the loop's open set until a round fixes it"
  elif .severity == "LOW" then "a reviewer finding, applied by default; below MEDIUM, so it does not hold the loop open"
  else "a severity outside CRITICAL, HIGH, MEDIUM and LOW, which pr-fix refuses" end;

def finding_section($i; $n):
  not_applicable as $na
  | "## Finding \($i + 1) of \($n)\n\n"
  + "- ID: \(.id | span)\n- Rule: \(.rule_id | span)\n- Severity: \(.severity | span)\n"
  + "- Location: \(.file | span)" + (if .line == null then ", no line" elif .line | type == "number" then " line \(.line)" else " line \(.line | span)" end) + "\n"
  + "- In scope for pr-fix: \(scope_line)\n"
  + "- Linked feedback items: none, plan.json links no finding to an item\n"
  + "- Fix: " + (if $na == null then "a proposed code change" else "not directly applicable, it opens with `\($na)`" end) + "\n\n"
  + "Problem:\n\n" + (.summary | tostring | fence) + "\nSuggested fix, verbatim:\n\n" + (.suggested_fix | tostring | fence) + "\n"
  + ([stale_sentences[] | "Generated content made stale, repeated from the fix:\n\n" + fence + "\n"] | join(""));

def item_section($i; $n):
  (.text | excerpt) as $e
  | "### Item \($i + 1) of \($n)\n\n- Kind: \(.kind)\n- Origin: \(.origin)\n"
  + "- Excerpt: " + (if .text == "" then "none, the item has no text"
      elif $e == .text then "the whole text, \(.text | utf8bytelength) bytes"
      else "the first \($e | utf8bytelength) of \(.text | utf8bytelength) bytes" end)
  + (if .omitted > 0 then "; the handover had already cut \(.omitted) bytes" else "" end) + "\n\n"
  + (if .text == "" then "" else ($e | fence) + "\n" end);

# Input: a review-plan stage file. Output: the text of fix-plan.md.
def fix_plan:
  # The hard caps of the findings schema, held here too, so a plan over them builds no preview.
  if any(.findings[]; (.summary | tostring | length) > 500 or (.suggested_fix | tostring | length) > 600)
  then error("a finding is over the summary cap of 500 or the suggested_fix cap of 600 characters") else . end
  | (.findings | length) as $nf
  | (.handover_block | plan_items) as $items
  | "# Fix plan preview\n\n"
  + "**Proposed fixes - not applied and not verified.**\n\n"
  + "What pr-fix would take from plan.json in this directory. The review changed nothing, and no fix below was run or tested.\n\n"
  + "- Target: \(.pin.target | span)\n- Head SHA: \(.pin.head_sha | span)\n"
  + "- Base ref: \(.pin.base_ref | span)\n- Base SHA: \(.pin.base_sha | span)\n"
  + "- Verdict: \(.verdict | span)\n- Proposed event: \(.proposed_event | span)\n"
  + "- Findings: \($nf)\n- Feedback items: \($items | length)\n\n"
  + "pr-fix decides which comment items it edits against its own token user when it builds its item set; this preview does not.\n\n"
  + ([.findings | to_entries[] | .key as $i | .value | finding_section($i; $nf)] | join(""))
  + "## Feedback items\n\n"
  + (if $items == [] then "The handover held no feedback item.\n\n"
     else "Text from the pull request, kept as untrusted data: each excerpt is fenced and cut to \(excerpt_cap) bytes. The block carries no comment ids; pr-fix gives each comment item its id.\n\n"
       + ([$items | to_entries[] | .key as $i | .value | item_section($i; $items | length)] | join("")) end)
  + "## No proposed code change\n\n"
  + ([.findings | to_entries[] | .key as $i | .value | not_applicable as $na | select($na != null)
      | "- Finding \($i + 1), \(.id | span): its fix opens with `\($na)`\n"]
     + [$items | to_entries[] | "- Item \(.key + 1), \(.value.kind): a feedback item, for which plan.json carries no fix\n"]
     | if . == [] then "Every finding proposes a code change, and the handover held no feedback item.\n" else join("") end) + "\n"
  + "## Apply\n\n"
  + "Nothing was applied. pr-fix would apply this plan with `fix-run.sh prepare --repo \(.pin.base_repo) --pr \(.pin.number)`, "
  + "then `fix-run.sh clone <run>`, then `fix-run.sh items <run> --plan <dir>`, `<dir>` being this directory.\n";
