# vendored-policy.jq: the normal form and the two diffs of vendored-policy.md. A statement, from
# policy-hcl.pl or from an upstream IAM JSON document, expands to one tuple per action and
# resource. A tuple is a JSON array, compared as a value, never as joined text:
#   [effect, ["action", a] or ["notaction", [list]], ["resource", r] or ["notresource", [list]],
#    principal list or null, not_principal list or null, conditions or null]
# A NotAction, NotResource or NotPrincipal list stays whole, since it is one exclusion set. Action
# names compare in lower case, as IAM reads them; condition keys and values, resources and
# principals compare as written. Every list is sorted.

def arr: if type == "array" then . elif type == "string" then [.] else error("unsafe text") end;
def strs: arr | map(if type == "string" then . elif type == "boolean" or type == "number" then tostring
  else error("unsafe text") end);

# One statement of an upstream document in policy-hcl.pl's shape.
def up_principal: if . == null then null elif . == "*" then ["*=*"]
  elif type == "object" then [to_entries[] | .key as $t | (.value | strs)[] | "\($t)=\(.)"] | sort
  else error("unsafe text") end;
def up_statement:
  if type != "object" then error("unsafe text")
  elif (keys - ["Sid", "Effect", "Action", "NotAction", "Resource", "NotResource", "Principal", "NotPrincipal", "Condition"]) != []
    then error("unsupported attribute")
  else {effect: .Effect,
    action: (.Action | if . == null then null else strs | sort end),
    not_action: (.NotAction | if . == null then null else strs | sort end),
    resource: (.Resource | if . == null then null else strs | sort end),
    not_resource: (.NotResource | if . == null then null else strs | sort end),
    principal: (.Principal | up_principal), not_principal: (.NotPrincipal | up_principal),
    condition: (.Condition | if . == null then null elif type != "object" then error("unsafe text")
      else [to_entries[] | .key as $t | (.value | if type == "object" then to_entries[] else error("unsafe text") end)
        | {test: $t, variable: .key, values: (.value | strs | sort)}] end)} end;
def upstream:
  if type != "object" or ((keys - ["Version", "Id", "Statement"]) != []) or (.Statement == null)
  then error("upstream unreadable")
  else {statements: [.Statement | if type == "array" then .[] else . end | up_statement]} end;

# Each atom a tuple can quote: plain text of at most 256 characters, an action of IAM's shape.
def atom_ok: type == "string" and test("^[A-Za-z0-9:/*?._=+,@|;${}-]{1,256}$");
def action_ok: test("^([a-z0-9-]{1,64}:[a-z0-9*?]{1,128}|[*])$");
def cells: [.statements[] | (if .action == null then 1 else (.action | length) end) * (if .resource == null then 1 else (.resource | length) end)] | add // 0;
def low: map(ascii_downcase) | sort;
def tuples:
  if cells > 4000 then error("too large") else . end
  | [.statements[] | . as $s
    | if ($s.effect | IN("Allow", "Deny")) | not then error("unsupported effect")
      elif ((($s.action // []) + ($s.not_action // [])) | map(ascii_downcase) | all(.[]; action_ok)) | not then error("unsafe text")
      elif ([($s.resource // [])[], ($s.not_resource // [])[], ($s.principal // [])[], ($s.not_principal // [])[],
             (($s.condition // [])[] | .test, .variable, .values[])] | all(.[]; atom_ok)) | not then error("unsafe text")
      elif ($s.action == null) == ($s.not_action == null) or ($s.resource == null) == ($s.not_resource == null) then error("unsupported attribute")
      else . end
    | (if $s.action != null then ($s.action | low[] | ["action", .]) else ["notaction", ($s.not_action | low)] end) as $a
    | (if $s.resource != null then ($s.resource | sort[] | ["resource", .]) else ["notresource", ($s.not_resource | sort)] end) as $r
    | [$s.effect, $a, $r, ($s.principal // null | if . == null then null else sort end),
       ($s.not_principal // null | if . == null then null else sort end),
       ($s.condition | if . == null or . == [] then null else map([.test, .variable, (.values | sort)]) | sort end)]]
  | unique;

# The text of a tuple for the output lines only: effect, then one field per set part.
def text: [.[0], "\(.[1][0]):\(.[1][1] | if type == "string" then . else tojson end)",
  "\(.[2][0]):\(.[2][1] | if type == "string" then . else tojson end)",
  (.[3] | select(. != null) | "principal:\(tojson)"), (.[4] | select(. != null) | "notprincipal:\(tojson)"),
  (.[5] | select(. != null) | "condition:\(tojson)")] | join(" ");

# The lines of one block. Input: {head, base, up}, each a tuple list; base null when the run had no
# merge base, "absent" when the base has no such document. widened: an Allow tuple the change adds
# that upstream lacks, or a Deny tuple the change removes that upstream keeps; carried: an Allow
# tuple upstream lacks that the base already had.
def capped($k; $l): ($l[:40][] | "\($k) \(text)"), (select(($l | length) > 40) | "\($k) and \(($l | length) - 40) more");
def diff_lines:
  (.head - .up) as $x | (.up - .head) as $m
  | (if .base == "absent" then [] else .base end) as $b
  | (if $x == [] and $m == [] then "upstream equal" else "upstream differs \($x | length) extra \($m | length) missing" end),
    capped("extra"; $x), capped("missing"; $m),
    (if .base == null then empty
     elif .base == "absent" then "base absent"
     else (.head - $b) as $a | ($b - .head) as $r
       | (if $a == [] and $r == [] then "base equal" else "base differs \($a | length) added \($r | length) removed" end),
         capped("added"; $a), capped("removed"; $r) end),
    (if .base == null then empty else
      ([$x[] | select(.[0] == "Allow") | select(. as $t | $b | index([$t]) | not)]
       + [$m[] | select(.[0] == "Deny") | select(. as $t | $b | index([$t]))]) as $w
      | capped("widened"; $w),
        capped("carried"; [$x[] | select(.[0] == "Allow") | select(. as $t | $b | index([$t]))]) end);
