# vendored-policy.jq: the normal form and the two diffs of vendored-policy.md. A statement, from
# policy-hcl.pl or from an upstream IAM JSON document, expands to one tuple per action and
# resource: effect, action, resource, then principals and conditions when set, each a field of
# plain text. Action names and condition keys compare in lower case, as IAM reads them.

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

def field_ok: test("^[A-Za-z0-9:/*?._=+,@|;-]{1,400}$");
def list_of($k; $nk; $none): if (.[$k] // []) != [] then .[$k][] | "\($k):\(.)"
  elif (.[$nk] // []) != [] then .[$nk][] | "\($nk | gsub("_"; "")):\(.)" else "\($k):\($none)" end;
def cond: map("\(.test):\(.variable | ascii_downcase)=\(.values | join(","))") | sort | join(";");
def tuples:
  [.statements[] | . as $s
    | ($s | .action |= (if . == null then null else map(ascii_downcase) end)
          | .not_action |= (if . == null then null else map(ascii_downcase) end)) as $l
    | ($l | list_of("action"; "not_action"; "none")) as $a
    | ($s | list_of("resource"; "not_resource"; "none")) as $r
    | [$s.effect, $a, $r]
      + (if ($s.principal // []) != [] then ["principal:" + ($s.principal | join(","))] else [] end)
      + (if ($s.not_principal // []) != [] then ["notprincipal:" + ($s.not_principal | join(","))] else [] end)
      + (if ($s.condition // []) != [] then ["condition:" + ($s.condition | cond)] else [] end)
    | if ((.[0] | IN("Allow", "Deny")) and all(.[1:][]; field_ok)) then join(" ") else error("unsafe text") end]
  | unique
  | if length > 4000 then error("too large") else . end;

# The lines of one block. Input: {head, base, up}, each a tuple list or null (base absent).
def capped($k; $l): ($l[:40][] | "\($k) \(.)"), (select(($l | length) > 40) | "\($k) and \(($l | length) - 40) more");
def diff_lines:
  (.head - .up) as $x | (.up - .head) as $m
  | (if $x == [] and $m == [] then "upstream equal" else "upstream differs \($x | length) extra \($m | length) missing" end),
    capped("extra"; $x), capped("missing"; $m),
    (if .base == null then "base absent"
     else (.head - .base) as $a | (.base - .head) as $r
       | (if $a == [] and $r == [] then "base equal" else "base differs \($a | length) added \($r | length) removed" end),
         capped("added"; $a), capped("removed"; $r) end);
