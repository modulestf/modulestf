# Renders fact sheets from one provider version's `terraform providers schema -json`
# output. See schema-pass.md. Input: the schema. Arguments:
#   $key    the provider_schemas key, registry.terraform.io/<namespace>/<name>
#   $want   JSON array of [kind, type], kind resource or data, each checked by the caller
#   $head   JSON object: provider, version, schema_sha256
# Output: one line per wanted type, "<kind> <type> <status> <sheet in base64 or ->",
# status sheet, absent or miss. A sheet over 256 KiB is a miss. Only allowlisted fields are read; every description
# and other free text is dropped. A malformed part makes that type a miss.

def name_ok: if type == "string" and test("^[a-z_][a-z0-9_]{0,127}$") then . else error("name") end;
def flag($k): (.[$k] // false) | if type == "boolean" then . else error("flag") end;
def obj: if . == null then {} elif type == "object" then . else error("shape") end;
def count($k): (.[$k] // 0) | if type == "number" and . >= 0 and . == floor and . < 100000 then . else error("count") end;

# cty type JSON, decoded into the closed grammar.
def cty($d):
  if $d > 32 then error("depth")
  elif type == "string" then
    if IN("string", "number", "bool", "dynamic") then . else error("type") end
  elif type == "array" and length == 2 and (.[0] | type) == "string" then
    if IN(.[0]; "list", "set", "map") then "\(.[0])(\(.[1] | cty($d + 1)))"
    elif .[0] == "object" and (.[1] | type) == "object" then
      "object({" + ([.[1] | to_entries | sort_by(.key)[] | "\(.key | name_ok)=\(.value | cty($d + 1))"] | join(", ")) + "})"
    elif .[0] == "tuple" and (.[1] | type) == "array" then
      "tuple([" + ([.[1][] | cty($d + 1)] | join(", ")) + "])"
    else error("type") end
  else error("type") end;

def flags:
  [ (if flag("required") then "required" else empty end),
    (if flag("optional") then "optional" else empty end),
    (if flag("computed") then "computed" else empty end),
    (if flag("sensitive") then "sensitive" else empty end),
    (if flag("write_only") then "write_only" else empty end),
    (if flag("deprecated") then "deprecated" else empty end) ]
  | map("; " + .) | join("");

# A $name parameter also defines a filter name, so no parameter here is called type.
# Limits of a block or a nested attribute type, by nesting mode.
def limits($mode):
  if $mode == "group" then "(group)"
  elif $mode == "single" then "(single, min \(count("min_items")), max 1)"
  elif IN($mode; "list", "set", "map") then
    "(\($mode), min \(count("min_items")), max \(count("max_items") | if . == 0 then "unlimited" else tostring end))"
  else error("mode") end;

def attrs($ind; $d):
  if $d > 32 then error("depth") else . end
  | obj | to_entries | sort_by(.key)[]
  | (.key | name_ok) as $n | .value | obj
  | if has("nested_type") then
      (.nested_type | obj) as $nt
      | ($nt.nesting_mode // "") as $m
      | if $m == "group" then error("mode") else . end
      | "\($ind)attr \($n) \($nt | limits($m))\(flags)",
        ($nt.attributes | attrs($ind + "  "; $d + 1))
    elif has("type") then "\($ind)\($n): \(.type | cty(0))\(flags)"
    else error("type") end;

def block($ind; $d):
  if $d > 32 then error("depth") else . end
  | obj
  | (.attributes | attrs($ind; $d)),
    (.block_types | obj | to_entries | sort_by(.key)[]
      | (.key | name_ok) as $n | .value | obj
      | "\($ind)block \($n) \(limits(.nesting_mode // ""))\(if (.block | obj | flag("deprecated")) then "; deprecated" else "" end)",
        (.block | block($ind + "  "; $d + 1)));

def sheet($k; $t):
  ([ "provider: \($head.provider)",
     "version: \($head.version)",
     "category: \(if $k == "resource" then "resource" else "data source" end)",
     "type: \($t)",
     "source: mirror schema",
     "schema_sha256: \($head.schema_sha256)" ]
    + (if (.block | obj | flag("deprecated")) then ["deprecated: true"] else [] end)
    + [ "" ] + [ .block | if type == "object" then block(""; 0) else error("shape") end ])
  | join("\n") + "\n";

.provider_schemas[$key] as $s
| $want[] as [$kind, $type]
| ($s[if $kind == "resource" then "resource_schemas" else "data_source_schemas" end]) as $c
| if ($c | type) != "object" then "\($kind) \($type) miss -"
  elif ($c | has($type)) | not then "\($kind) \($type) absent -"
  else (try ($c[$type] | sheet($kind; $type)
      | if length > 262144 then error("size") else "\($kind) \($type) sheet \(@base64)" end) catch "\($kind) \($type) miss -")
  end
