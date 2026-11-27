# vendored-policy.jq: the evidence of vendored-policy.md from the facts engine's iam-policy-docs
# report, the normal form and the two diffs. A statement, from that report or from an upstream IAM
# JSON document, expands to one tuple per action and resource. A tuple is a JSON array, compared as a value, never as joined text:
#   [effect, ["action", a] or ["notaction", [list]], ["resource", r] or ["notresource", [list]],
#    principal list or null, not_principal list or null, conditions or null]
# A NotAction, NotResource or NotPrincipal list stays whole, since it is one exclusion set. Action
# names compare in lower case, as IAM reads them; condition keys and values, resources and
# principals compare as written. Every list is sorted.

def arr: if type == "array" then . elif type == "string" then [.] else error("unsafe text") end;
def strs: arr | map(if type == "string" then . elif type == "boolean" or type == "number" then tostring
  else error("unsafe text") end);

# The shape both sides take before tuples: {statements: [{effect, action, not_action, resource,
# not_resource, principal, not_principal, condition}]}, each list sorted and null when absent, a
# principal "<type>=<identifier>" and a condition {test, variable, values}.

# One statement of an upstream document in that shape.
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
  elif .Version != null and .Version != "2012-10-17" then error("unsupported version")
  else {statements: [.Statement | if type == "array" then .[] else . end | up_statement]} end;

# A value of the report: plain text, or a template whose references are the profile's
# substitutions ($s, an object of expression to value). Any other reference evaluates nothing.
def facts_value($s): if type == "string" then .
  elif type == "object" and (.template | type) == "array" then [.template[]
    | if type == "string" then . elif type == "object" and (.ref | type) == "string" then (.ref as $k
        | if $s | has($k) then $s[$k] else error("unevaluated expression") end) else error("unsafe text") end] | join("")
  else error("unsafe text") end;
def facts_list($s): if . == null then null else map(facts_value($s)) | sort end;
def facts_principal($s): if . == null then null
  else [.[] | .type as $t | .identifiers[] | "\($t)=\(facts_value($s))"] | sort end;
# A policy language version other than 2012-10-17 reads policy variables as literal text, so
# only that version, or none (the provider's default), is compared.
def facts_doc($s): if (.version // "2012-10-17") != "2012-10-17" then error("unsupported version") else . end
  | {statements: [.statements[] | {effect,
  action: (.actions | facts_list($s)), not_action: (.not_actions | facts_list($s)),
  resource: (.resources | facts_list($s)), not_resource: (.not_resources | facts_list($s)),
  principal: (.principals | facts_principal($s)), not_principal: (.not_principals | facts_principal($s)),
  condition: (.conditions | if . == null then null
    else map({test, variable: (.variable | facts_value($s)), values: (.values | map(facts_value($s)) | sort)}) end)}]};

# The policies that take a document whole as their policy (vendored-policy.md, step 3).
def policy_use: .argument == "policy" and (.address | test("^aws_iam_(role_|user_|group_)?policy\\.[A-Za-z_][A-Za-z0-9_-]*$"));
def why: "\(.code | gsub("_"; " "))";
# vp_entry($dir; $file; $block; $s): one profile entry read from the report on input: {unknown:
# <reason>}, {skip: true} for a block both sides read alike, or {lines, head, base}, base null with
# no merge base and "absent" when the base has no such document.
def vp_entry($dir; $file; $block; $s):
  . as $r | "data.aws_iam_policy_document.\($block)" as $a
  | def side($t; $w): ($t.directories | map(select(.dir == $dir))[0].undecidable) as $u
      | [$t.documents[] | select(.dir == $dir and .address == $a)] as $d
      | if $u != null then {unknown: ($w + "directory " + ($u | why))}
        elif $d == [] then {absent: true}
        elif ($d | length) > 1 then {unknown: ($w + "block repeated")}
        elif $d[0].kind != "data_source" or $d[0].file != $file then {unknown: ($w + "block missing")}
        elif $d[0].content == null then {unknown: ($w + "content " + ($d[0].content_undecidable | why))}
        else {doc: $d[0]} end;
  side($r.head; "") as $h
  | (if $r.base == null then {none: true} else side($r.base; "base ") end) as $b
  | def conv($w): try {doc: (.content | facts_doc($s))}
      catch {unknown: ($w + (if type == "string" and test("^[a-z ]{1,40}$") then . else "unsafe text" end))};
  if $h.unknown then $h elif $h.absent then {unknown: "block missing"}
  elif $b.unknown then $b
  else $h.doc as $hd | ($b.doc // null) as $bd
  | ($hd | conv("")) as $hc | (if $bd != null then $bd | conv("base ") else {doc: null} end) as $bc
  | if $hc.unknown then $hc elif $bc.unknown then $bc
    elif $bd != null and $bd.content == $hd.content and $bd.gate == $hd.gate then {skip: true}
    elif $hd.uses == null then {unknown: ("uses " + ($hd.uses_undecidable | why))}
    else [$hd.uses[] | select(policy_use)] as $p
    | if $p == [] then {unknown: "not wired"}
      elif any($hd.content.statements[]; .sid != null) and any($p[].via[]; .role == "source" or .role == "override")
        then {unknown: "sid in merged document"}
      elif $bd != null then
        ([$r.compare[] | select(.dir == $dir and .address == $a)][0]) as $c
        | if $hd.gate != $bd.gate then {unknown: "gate changed"}
          elif $r.precondition != true or $c == null or $c.presence != "both" then {unknown: "precondition failed"}
          elif $c.uses == "differs" then {unknown: "wiring changed"}
          elif $c.uses != "equal" then {unknown: "wiring undecidable"}
          elif all($p[]; .instances == "none") then {unknown: "not wired"}
          else null end
      elif $hd.gate != null or $hd.instances != "always" then {unknown: "gate without base"}
      elif any($p[]; .via == [] and .gates == [] and .instances == "always") | not then {unknown: "wiring not comparable"}
      else null end
    | . // {lines: $hd.lines, head: $hc.doc, base: (if $bd != null then $bc.doc elif $b.none then null else "absent" end)} end end;

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
      elif any($s.action, $s.not_action, $s.resource, $s.not_resource; . == []) then error("empty list")
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
