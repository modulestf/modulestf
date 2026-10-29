# incremental.jq: the pure parts of host-pass.sh prior, record and accept, as jq functions.
# The rules are stated in host-pass.md, Incremental Review. The shell reads; these functions
# decide. Loaded with: jq -L <references dir> 'include "incremental"; ...'

def sha40: type == "string" and test("^[0-9a-f]{40}$");
def sha64: type == "string" and test("^[0-9a-f]{64}$");

# A repository-relative path: valid text, no control character, not absolute, no empty,
# "." or ".." component, no backslash. The module root itself is ".".
def safe_path:
  type == "string" and length > 0 and length <= 1024
  and (test("[\\x00-\\x1f\\x7f\\\\]") | not)
  and (. == "." or (startswith("/") | not) and (split("/") | all(.[]; . != "" and . != "." and . != "..")));

# A path the host may name outside the untrusted block: a safe path of plain characters
# only, so no file name can read as words of a sentence.
def plain_path: safe_path and test("^[A-Za-z0-9._/-]+$");

def rule_re: "^(compat|coverage|structure|examples|profile|scope|review)\\.[a-z0-9-]+$";

# One finding as the render contract writes it: exactly seven keys, or six with no id for
# a carried finding.
def finding($with_id):
  type == "object"
  and (keys == (if $with_id then ["file", "id", "line", "rule_id", "severity", "suggested_fix", "summary"]
                else ["file", "line", "rule_id", "severity", "suggested_fix", "summary"] end))
  and (if $with_id then (.id | type == "string" and test("^F-[0-9]{3,4}$")) else true end)
  and (.rule_id | type == "string" and test(rule_re))
  and (.severity | IN("CRITICAL", "HIGH", "MEDIUM", "LOW"))
  and (.file | safe_path)
  and (.line == null or (.line | type == "number" and . >= 1 and . == floor and . < 1000000))
  and (.summary | type == "string" and length > 0 and length <= 2000)
  and (.suggested_fix | type == "string" and length > 0 and length <= 4000);

def findings_list($with_id):
  type == "array" and length <= 500 and all(.[]; finding($with_id))
  and (if $with_id then ([.[].id] | length == (unique | length)) else true end);

# A finding with no id, its keys sorted, so two findings compare equal exactly when every
# other field does.
def canon: del(.id) | to_entries | sort_by(.key) | from_entries;

# The header line of a record, field by field in a fixed order, each with its own pattern.
def header_re:
  "^modulestf-record v=1 repo=(?<repo>[A-Za-z0-9._-]+/[A-Za-z0-9._-]+) pr=(?<pr>[1-9][0-9]{0,9})"
  + " head=(?<head>[0-9a-f]{40}) base_ref=(?<base_ref>[A-Za-z0-9._/-]{1,255})"
  + " merge_base=(?<merge_base>[0-9a-f]{40}) skills=(?<skills>[0-9a-f]{40})"
  + " facts=(?<facts>[0-9a-f]{64}|none) verify=(?<verify>[A-Za-z0-9._-]{1,64})"
  + " mode=(?<mode>full|incremental) depth=(?<depth>[0-9]) last_full=(?<last_full>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)"
  + " complete=(?<complete>true) sha256=(?<sha256>[0-9a-f]{64})$";

def header: capture(header_re);

# The verdict from the accepted findings and the model's verdict, a total function of both.
# Rules 0 to 2 and 6 to 8 of the ladder read only the findings, so the host decides them.
# Rules 3 to 5 read host signals the model rendered; the model's verdict stands for those,
# and only toward stricter. The model's verdict must equal the result.
def host_verdict($model):
  . as $f
  | [$f[] | select(.severity == "CRITICAL" or .severity == "HIGH")] as $ch
  | if any($f[]; .severity == "CRITICAL") and all($ch[]; .rule_id | startswith("compat."))
      then "hold for the next major"
    elif ($ch | length) > 0 then "block"
    elif $model == "block" then "block"
    elif $model == "inconclusive" or any($f[]; .rule_id | IN("review.check-not-run", "review.no-change-identified"))
      then "inconclusive"
    elif $model == "changes suggested" then "changes suggested"
    elif any($f[]; .severity == "MEDIUM") then "block"
    elif any($f[]; .severity == "LOW") then "approve with nits"
    else "approve" end;

# Paths relative to the module root, for the reviewer; null for a path outside it.
def rel($prefix):
  if $prefix == "" then . elif . == $prefix then "." elif startswith($prefix + "/") then .[($prefix | length) + 1:] else null end;

def dirname: if test("/") then sub("/[^/]*$"; "") else "" end;
