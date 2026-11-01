# skip-coverage.jq: the decision of skip-coverage.sh check, as jq functions. Every rule here is
# stated in skip-coverage.md (Conditions, The allow-list, Output). The shell reads, runs the
# gates and the allow-list parser; these functions decide.
# Loaded with: jq -L <references dir> 'include "skip-coverage"; ...'

def sha: type == "string" and test("^[0-9a-f]{40}$");
def safe_path: type == "string" and test("^[A-Za-z0-9._/-]{1,300}$");
def safe_address: type == "string" and test("^[A-Za-z0-9_.-]{1,300}$");
def attr_name: type == "string" and test("^[a-z0-9_]{1,128}$");

# --- The plan record: a laptop record only, read by its "example:" lines in order, as
# verify-pass.sh coverage reads it. Blocks {n, dir, plan, hit}: plan is the class with the kept
# line cut, hit the first recorded gate hit {gate, path} with its line removed, or null.
def record_blocks:
  split("\n") as $l
  | if any($l[]; . == "plan pass mode: laptop") and (any($l[]; startswith("host example ")) | not) then
      reduce $l[] as $x ({b: [], n: 0};
        if ($x | startswith("example: ")) then .n += 1 | .b += [{n: .n, dir: $x[9:], plan: null, hit: null}]
        elif (.b | length) == 0 then .
        elif ($x | startswith("plan: ")) and .b[-1].plan == null then
          ($x[6:] | split(" | ")[0]) as $p
          | .b[-1].plan = $p
          | .b[-1].hit = ($p | capture("^plan gate (?<gate>G[0-3]) (?<path>[^ :]+)(:[^ ]*)? \\([0-9]+ hits\\)$") // null)
        else . end)
      | .b
    else null end;

# --- A gate record of skip-coverage.sh gates: {dir: {lines, done}} for the SHA it names, or
# null when it names another SHA or has no end line. A directory without its done line is partial.
def gate_record($sha):
  split("\n") | map(select(length > 0))
  | if length >= 2 and .[0] == "skip-gates 1 " + $sha and .[-1] == "end" then
      reduce .[1:-1][] as $x ({d: {}, cur: null};
        if ($x | startswith("dir ")) then .cur = $x[4:] | .d[.cur] = {lines: [], done: false}
        elif .cur == null then .
        elif $x == "done " + .cur then .d[.cur].done = true | .cur = null
        else .d[.cur].lines += [$x] end)
      | .d
    else null end;

# A local module source resolved against the example directory, repository-relative, or null
# when it climbs out of the repository: the same resolution as verify-pass.sh coverage.
def resolve($d): ($d + "/" + .) | split("/")
  | reduce .[] as $p ([]; if . == null then null elif $p == "" or $p == "." then .
      elif $p == ".." then (if length == 0 then null else .[:-1] end) else . + [$p] end)
  | if . == null then null elif length == 0 then "." else join("/") end;

# --- Condition 2: the witnesses of one changed attribute {dir, address, attribute}, in example
# path order. Each candidate is {example, address, ok}: ok when the record is for $head and its
# sensitive bit is known and clear; a candidate for another head is no candidate at all.
def candidates($c; $blocks; $addr; $head):
  [$blocks | sort_by(.dir)[] | select(.plan == "planned" and (.dir | safe_path)) as $b
   | ($addr[$b.n | tostring] // null) as $r
   | select($r | type == "object" and .head_sha == $head and (.addresses | type == "array"))
   | ($r.module_calls | if type == "object" then to_entries | sort_by(.key)[] else empty end)
   | select((.key | test("^[A-Za-z0-9_-]{1,64}$"))
            and (.value | type == "string" and test("^[.][.]?(/[A-Za-z0-9_.-]+)*/?$"))
            and (.value | resolve($b.dir)) == $c.dir)
   | ("module." + .key + "." + $c.address) as $full
   | select(($full | safe_address) and ($r.addresses | index($full)) != null
            and (($r.attributes[$full] // []) | type == "array" and index($c.attribute) != null))
   | ($r.sensitive | if type == "object" then .[$full] else null end) as $s
   | {example: $b.dir, address: $full,
      ok: ($s | type == "array" and length <= 500 and all(.[]; attr_name) and (index($c.attribute) == null))}];

# --- The decision. $cls: per changed file {file, dir, ok, attrs}; $addr: addresses-<n>.json by
# n; $rec: the plan record text; $hg, $bg: the head and base gate records; $headok: the clone is
# at $head.
def skip_coverage($cov; $files; $cls; $addr; $rec; $hg; $bg; $head; $base; $headok):
  ($rec | record_blocks) as $blocks
  | (($cls | length) > 0 and all($cls[]; .ok) and any($cls[]; .attrs | length > 0)) as $allowed
  | ([$cls[] | .dir as $d | .attrs[] | . + {dir: $d}] | unique) as $changed
  | (if $blocks == null then [] else [$changed[] | . as $c | {c: ., w: candidates($c; $blocks; $addr; $head)}] end) as $cand
  | (if all($cand[]; any(.w[]; .ok)) and all($changed[]; .attribute | attr_name) and ($cand | length) > 0 then null
     elif all($cand[]; any(.w[]; .ok) or (.w | length) > 0) and ($cand | length) > 0 then "witness-sensitive"
     else "no-witness" end) as $nowit
  | [$cand[] | .c.attribute as $at | first(.w[] | select(.ok)) | {attribute: $at, example, address}] as $wits
  | ($hg | gate_record($head)) as $H
  | (if $base | sha then $bg | gate_record($base) else null end) as $B
  | [$files[] | .filename, (.previous_filename // empty)] as $paths
  | reduce ($cov.unplanned[] | .dir) as $d ([]; if index($d) == null then . + [$d] else . end)
  | map(. as $d
      | [$cov.unplanned[] | select(.dir == $d) | .reason] as $rs
      | ($rs[0] | if type == "string" then (capture("^plan gate (?<g>G[1-3])$") // null) else null end) as $g
      | (if $blocks == null then null else first($blocks[] | select(.dir == $d)) // null end) as $blk
      | ($H[$d]? // null) as $h
      | ($B[$d]? // null) as $b
      | (if ($rs | length) > 1 then "not-sole-reason"
         elif $g == null then "wrong-gate-class"
         elif ($headok | not) then "head-mismatch"
         elif $blk == null or $blk.hit == null or $blk.hit.gate != $g.g or ($blk.hit.path | safe_path | not) or ($d | safe_path | not)
           then "plan-record-unusable"
         elif ($allowed | not) then "change-not-allowed"
         elif any($paths[]; startswith($d + "/")) then "dir-changed"
         elif ($base | sha | not) then "merge-base-unresolved"
         elif $b == null or $b.done != true then "base-record-missing"
         elif $h == null or $h.done != true or ($h.lines | sort) != ($b.lines | sort)
           or ($h.lines | index("hit " + $blk.hit.gate + " " + $blk.hit.path)) == null then "hit-set-differs"
         elif any($h.lines[]; startswith("hit G0 ")) then "wrong-gate-class"
         elif $nowit != null then $nowit
         else null end) as $why
      | if $why == null then {covered: {dir: $d, gate: $g.g, path: $blk.hit.path, witnesses: $wits}}
        else {uncovered: {dir: $d, why: $why}} end)
  | {format: 1, head_sha: $head, base_sha: (if $base | sha then $base else null end),
     covered: [.[] | .covered // empty], uncovered: [.[] | .uncovered // empty]};
