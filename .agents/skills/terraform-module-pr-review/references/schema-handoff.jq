# Filters one provider version's `terraform providers schema -json` output to the block
# schemas of the schema handoff. See schema-pass.md. Input: the schema. Arguments:
#   $key   the provider_schemas key, registry.terraform.io/<namespace>/<name>
#   $ver   the version, x.y.z
# Output: one provider_schemas entry, every resource and data source type with its
# attribute names, the required, optional, computed and deprecated flags when true,
# nested attribute types, nested block names, nesting modes and item limits. Every other
# field, descriptions included, is dropped. Any malformed part is an error, so the caller
# leaves the whole version out: a type dropped alone would read as absent from the schema.

def name_ok: if type == "string" and test("^[a-z_][a-z0-9_]{0,127}$") then . else error("name") end;
def obj: if . == null then {} elif type == "object" then . else error("shape") end;
def flags: . as $a | reduce ("required", "optional", "computed", "deprecated") as $k ({};
  ($a[$k] // false) as $v
  | if ($v | type) != "boolean" then error("flag") elif $v then .[$k] = true else . end);
def limits: . as $b | reduce ("min_items", "max_items") as $k ({};
  if $b | has($k) then ($b[$k] | if type == "number" and . >= 0 and . == floor and . < 100000 then . else error("count") end) as $n | .[$k] = $n else . end);
def req: if type == "object" then . else error("shape") end; # a part the schema requires
def mode($allowed): if type == "string" and IN($allowed[]) then . else error("mode") end;

def attrs($d):
  if $d > 32 then error("depth") else . end
  | obj | with_entries((.key | name_ok) as $n | .key = $n | .value |= (obj
    | flags + (if has("nested_type") then {nested_type: (.nested_type | obj
        | {nesting_mode: (.nesting_mode | mode(["single", "list", "set", "map"])),
           attributes: (.attributes | req | attrs($d + 1))} + limits)} else {} end)));

def block($d):
  if $d > 32 then error("depth") else . end
  | obj
  | (.attributes | attrs($d)) as $a
  | (.block_types | obj | with_entries((.key | name_ok) as $n | .key = $n | .value |= (obj
      | {nesting_mode: (.nesting_mode | mode(["single", "group", "list", "set", "map"])),
         block: (.block | req | block($d + 1))} + limits))) as $b
  | (if $a == {} then {} else {attributes: $a} end)
    + (if $b == {} then {} else {block_types: $b} end)
    + (if (.deprecated // false) == true then {deprecated: true}
       elif (.deprecated // false) == false then {} else error("flag") end);

def types: obj | with_entries(
  (.key | if test("^[a-z][a-z0-9_]{0,127}$") then . else error("type") end) as $t
  | .key = $t | .value = {block: (.value | obj | .block | if type == "object" then block(0) else error("shape") end)});

.provider_schemas[$key] as $s
| if ($s | type) != "object" then error("shape") else . end
| {source: $key, version: $ver,
   resource_schemas: ($s.resource_schemas | types),
   data_source_schemas: ($s.data_source_schemas | types)}
