# budget.jq: the review budget of review-run.sh prepare (review-run-details.md, Review Budget).
# Input: the records' files.json. budget($cap; $th; $fsize; $p; $fmin; $gcap) gives the skipped
# paths: none when files.json ($fsize bytes) and the patch text are both at most $th, else the files
# in budget order, each kept while its patch fits beside the patches kept before it in $cap bytes.
# $p is the module root prefix, $fmin the members a family needs and $gcap the bytes of generator
# sources ranked with the interface files.

def bytes: .patch // "" | utf8bytelength;
# The path under the module root, or null for a file outside it.
def rel($p): .filename | if $p == "" then . elif startswith($p + "/") then .[($p | length) + 1:] else null end;
def tf: test("\\.(tf|tofu|hcl|tfvars)(\\.json)?$");
# A generator source: a *.tftpl template, or a Terraform or template file of the generate/ directory
# at the top of the module root.
def generator($p): rel($p) as $r | $r != null
  and ($r | test("\\.tftpl$") or test("^generate/.*\\.(tf|tftpl|tofu|hcl|tfvars)(\\.json)?$"));
# A submodule under the module root: the directory modules/<name>, at any depth, relative to it.
def subdir($p): rel($p) as $r | if $r == null then null else ($r | capture("^(?<d>(.*/)?modules/[^/]+)/").d? // null) end;
# A patch with the submodule's own name, and its spelling with - or _, taken out, so two copies a
# generator wrote for two names compare equal. A name under 3 characters is left in: when unsure,
# no family.
def normalized($d): ($d | split("/") | last) as $n
  | .patch | if ($n | length) < 3 then . else
      reduce ([$n, ($n | gsub("-"; "_")), ($n | gsub("_"; "-"))] | unique)[] as $v (.; split($v) | join("\u0000")) end;

def budget($cap; $th; $fsize; $p; $fmin; $gcap):
  if $fsize <= $th and (map(bytes) | add // 0) <= $th then []
  else
    # The generator sources ranked with the interface files, by path, while their bytes fit in $gcap;
    # the rest keep the class of their file type, so padding under generate/ cannot starve the budget.
    ([.[] | select(.patch != null and generator($p))] | sort_by(.filename)
     | reduce .[] as $f ({b: 0, s: {}}; ($f | bytes) as $x
         | if .b + $x <= $gcap then .b += $x | .s[$f.filename] = true else . end) | .s) as $gen
    # A family: one path within $fmin or more submodules whose patches there are equal after
    # normalized. The first submodule by path keeps its class; the copy in each other submodule
    # gets its index among them, so the second submodule of each family comes before the third of
    # any. A file whose patch differs from every other is no copy and keeps its class.
    | ([.[] | select(.patch != null) | subdir($p) as $d | select($d != null)
        | {f: .filename, d: $d, k: [(rel($p) | ltrimstr($d + "/")), normalized($d)]}]
       | group_by(.k) | map(select((map(.d) | unique | length) >= $fmin) | sort_by(.d) | to_entries[] | {key: .value.f, value: .key})
       | from_entries) as $member
    # 0 the interface files of the root and of each submodule and the generator sources, 1 their
    # other Terraform files, 2 example Terraform, 3 README files and the rest of the examples, 4 the
    # rest, wrappers included.
    | def rank: .filename as $n
        | if $gen[$n] then 0
          elif ($n | test("(^|/)wrappers/")) then 4
          elif ($n | test("(^|/)examples/")) then (if ($n | tf) then 2 else 3 end)
          elif ($n | test("(^|/)(main|variables|outputs|versions)\\.tf$")) then 0
          elif ($n | tf) then 1
          elif ($n | test("(^|/)README\\.md$")) then 3 else 4 end;
    # The files directly in the module root first: with a prefix, the files of that directory.
    def key: ($member[.filename] // 0) as $i | ((rel($p) // .filename) | contains("/")) as $deep
      # A copy only moves back: one of a class past 3.5 keeps its class.
      | if $i > 0 then [([3.5, rank] | max), $i, rank, $deep, .filename] else [rank, 0, 0, $deep, .filename] end;
    sort_by(key)
    | reduce .[] as $f ({kept: 0, skipped: []};
        ($f | bytes) as $b
        | if $f.patch == null then . elif .kept + $b <= $cap then .kept += $b else .skipped += [$f.filename] end)
    | .skipped end;
