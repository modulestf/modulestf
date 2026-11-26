#!/bin/bash
# Self-check for the pull request review skill's references/nonhcl-reach.sh, the evidence of a change
# outside Terraform (verdict.md, Changes outside Terraform), on throwaway git repositories: the
# module profile's reach file (its grammar, a file and directory named twice, the repository it
# names, a link, the shipped file), the example guard at the head and the merge base (every module
# call has the module root as its source and sets the literal, at least one call, the same calls at
# both revisions, no other module, submodule, sibling example, registry or climbing source, no .tf
# file below the top, no file naming the changed file, no fileset call, no .tf.json, OpenTofu file,
# link or name outside the plain charset, a directory absent or holding a changed file), the root
# gate (every block naming the file has a count or for_each reading the variable, the same at both
# revisions, no edited root .tf file), the reader's refusals (a heredoc that does not end, a template
# sequence in a heredoc, a quote or a brace inside an interpolation or directive, a block comment, an
# interpolated source, a non-literal value), the module root prefix, a partial clone, and a negative
# self-check on mutated copies. No network. Needs bash, git, jq and perl.
# Run: tests/nonhcl-reach-test.sh
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
NR="$SRC/.agents/skills/terraform-module-pr-review/references/nonhcl-reach.sh"
SHIPPED="$SRC/.agents/skills/terraform-module-maintainer/profiles/terraform-aws-modules/nonhcl-reach.txt"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/nonhcl-reach-test.XXXXXX")" && pwd -P)" && [ -n "$TMP" ] || { echo "FAIL no temporary directory"; exit 1; }
[ -n "${KEEP:-}" ] || trap 'rm -rf "$TMP"' EXIT
fails=0
check() { if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

PKG_TF='locals {
  python = "python3"
}

data "external" "archive_prepare" {
  count = var.create && var.create_package ? 1 : 0

  program = [local.python, "${path.module}/package.py", "prepare"]
}

resource "null_resource" "archive" {
  count = var.create && var.create_package ? 1 : 0

  provisioner "local-exec" {
    command = "python3 ${path.module}/package.py build"
  }
}'
EX_TF='module "lambda_function" {
  source = "../../"

  function_name  = "x"
  create_package = false
  image_uri      = "${path.module}/x"
}

resource "aws_cloudwatch_event_rule" "r" {
  event_pattern = <<EOF
{ "source": ["module x {"] }
EOF
}'
BUILD_TF='module "package_dir" {
  source = "../../"
}'

# repo name [, base setup [, head setup]] -> a repository with a base and a head commit; the head
# edits package.py and runs its setup function. Sets R, B (base) and H (head).
repo() {
  R="$TMP/$1"; rm -rf "$R"; mkdir -p "$R/examples/ex" "$R/examples/build"
  git -C "$R" init -q -b master
  printf 'print("a")\n' > "$R/package.py"
  printf '%s\n' "$PKG_TF" > "$R/package.tf"
  printf '%s\n' "$EX_TF" > "$R/examples/ex/main.tf"
  printf '%s\n' "$BUILD_TF" > "$R/examples/build/main.tf"
  [ -z "${2-}" ] || (cd "$R" && "$2")
  git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@example.com commit -qm base
  B="$(git -C "$R" rev-parse HEAD)"
  printf 'print("b")\n' > "$R/package.py"
  [ -z "${3-}" ] || (cd "$R" && "$3")
  git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@example.com commit -qm head
  H="$(git -C "$R" rev-parse HEAD)"
}
LINE='not-run example/terraform-aws-lambda package.py examples/ex root-calls create_package=false gated-by var.create_package'
REACH="$TMP/nonhcl-reach.txt"
printf '# comment\n%s\nnot-run example/terraform-aws-lambda package.py examples/build root-calls create_package=false gated-by var.create_package\nnot-run other/repo package.py examples/build root-calls create_package=false gated-by var.create_package\n' "$LINE" > "$REACH"
jq -n '{schema_version: 1, capped: 0, triggers: [{id: "T-001", file: "package.py", line: 1, category: "non-hcl-dependency"}]}' > "$TMP/beh.json"
jq -n '[{filename: "package.py", status: "modified"}]' > "$TMP/files.json"
# run [extra args] -> OUT, ST
run() {
  OUT="$(bash "$NR" --git "$R" --head "$H" --base "$B" --repo "${REPO:-example/terraform-aws-lambda}" \
    --behaviour "$TMP/beh.json" --files "${FILES:-$TMP/files.json}" --reach "${RF-$REACH}" "$@" 2> /dev/null)"; ST=$?
}
un() { jq -c '.files[0].unreached' <<< "$OUT"; }
none() { run "$@"; [ "$ST" = 0 ] && [ "$(un)" = '[]' ]; }
ex() { printf '%s\n' "$1" >> examples/ex/main.tf; }

t_lambda() {
  repo lambda; run
  [ "$ST" = 0 ] && [ "$(un)" = '["examples/ex"]' ] \
    && [ "$(jq -r '.head_sha + " " + .base_sha + " " + .files[0].file' <<< "$OUT")" = "$H $B package.py" ]
}
t_lambda; check "both guards hold at both revisions: the example is unreached; a root call without the literal is not" $?
t_shipped() { repo shipped; RF="$SHIPPED" run; [ "$ST" = 0 ] && [ "$(un)" = '[]' ]; }
t_shipped; check "the shipped reach file passes the grammar" $?
t_noreach() { repo noreach; RF="$TMP/absent.txt" none; }
t_noreach; check "no reach file: nothing unreached" $?
bad_reach() { # name, line... -> holds when the reach file is refused whole
  local n="$1"; shift; repo "$n"; printf '%s\n' "$@" > "$TMP/$n.txt"; RF="$TMP/$n.txt" run; [ "$ST" = 1 ] && [ -z "$OUT" ]
}
t_badreach() { bad_reach badreach 'not-run example/terraform-aws-lambda package.py examples/ex root-calls create_package=false'; }
t_badreach; check "a reach line with no root gate refuses the whole file" $?
t_badguard() { bad_reach badguard "${LINE/create_package=false/create_package=var.x}"; }
t_badguard; check "a guard literal outside the grammar refuses the whole file" $?
t_badgate() { bad_reach badgate "${LINE/gated-by var.create_package/gated-by local.x}"; }
t_badgate; check "a root gate that is no variable refuses the whole file" $?
t_climb() { bad_reach climb "${LINE/examples\/ex/examples/../x}"; }
t_climb; check "a reach directory that climbs out refuses the whole file" $?
t_twice() { bad_reach twice "$LINE" "${LINE/create_package=false/create_package=true}"; }
t_twice; check "a file and directory named twice refuse the whole file" $?
t_link() { repo link; ln -sf "$REACH" "$TMP/link.txt"; RF="$TMP/link.txt" run; [ "$ST" = 1 ]; }
t_link; check "a reach file that is a link is refused" $?
t_other() { repo other; REPO=other/thing none; }
t_other; check "a reach line of another repository clears nothing" $?
chg_ex() { ex '# x'; }
t_changed() {
  repo changed "" chg_ex
  jq -n '[{filename: "package.py", status: "modified"}, {filename: "examples/ex/main.tf", status: "modified"}]' > "$TMP/f2.json"
  FILES="$TMP/f2.json" none
}
t_changed; check "an example that holds a changed file is not unreached" $?
rm_ex() { rm -rf examples/ex; }
t_gone() { repo gone "" rm_ex; none; }
t_gone; check "an example absent at the head is not unreached" $?
flip() { perl -pi -e 's/create_package = false/create_package = true/' examples/ex/main.tf; }
unflip() { perl -pi -e 's/create_package = true/create_package = false/' examples/ex/main.tf; }
t_headtrue() { repo headtrue "" flip; none; }
t_headtrue; check "an example guard that fails at the head clears nothing" $?
t_basetrue() { repo basetrue flip unflip; none; }
t_basetrue; check "an example guard that fails at the merge base clears nothing" $?
add_root() { ex 'module "again" {
  source         = "../../"
  create_package = false
}'; }
t_newcall() { repo newcall "" add_root; none; }
t_newcall; check "a module call the head adds makes the line stale" $?
call_case() { # name, source -> holds when a second call of that source makes the line stale
  SRCX="$2"; repo "$1" add_call; none
}
add_call() { ex "module \"other\" {
  source         = \"$SRCX\"
  create_package = false
}"; }
t_wrappers() { call_case wrappers ../../wrappers; }
t_wrappers; check "a call of the wrappers makes the line stale" $?
t_submod() { call_case submod ../../modules/sub; }
t_submod; check "a call of a submodule makes the line stale" $?
t_sibling() { call_case sibling ../build; }
t_sibling; check "a call of a sibling example makes the line stale" $?
t_registry() { call_case registry terraform-aws-modules/s3-bucket/aws; }
t_registry; check "a call of a registry module makes the line stale" $?
t_climbsrc() { call_case climbsrc ../../../outside; }
t_climbsrc; check "a source that climbs out of the repository makes the line stale" $?
no_calls() { printf 'locals {\n  x = 1\n}\n' > examples/ex/main.tf; }
t_nocall() { repo nocall no_calls; none; }
t_nocall; check "an example with no module call proves nothing" $?
subdir() { mkdir -p examples/ex/inner && printf 'module "i" {\n  source         = "../../"\n  create_package = false\n}\n' > examples/ex/inner/main.tf; }
t_subdir() { repo subdir subdir; none; }
t_subdir; check "a .tf file below the top of the example makes the line stale" $?
var_val() { perl -pi -e 's/create_package = false/create_package = var.create_package/' examples/ex/main.tf; }
t_var() { repo var "" var_val; none; }
t_var; check "a value that is no literal fails the guard" $?
interp() { perl -pi -e 's|source = "../../"$|source = "./\${path.module}/../../../"|' examples/ex/main.tf; }
t_interp() { repo interp interp; none; }
t_interp; check "a source that is no plain string makes the line stale" $?
blockc() { perl -0pi -e 's|  create_package = false\n|  /*\n  create_package = false\n  */\n|' examples/ex/main.tf; }
t_blockc() { repo blockc blockc; none; }
t_blockc; check "a block comment makes the line stale" $?
names_tf() { ex 'locals {
  p = "package.py"
}'; }
t_names() { repo names names_tf; none; }
t_names; check "an example .tf file that names the changed file is not unreached" $?
names_sh() { printf 'python3 ../../package.py build\n' > examples/ex/build.sh; }
t_namessh() { repo namessh names_sh; none; }
t_namessh; check "any example file that names the changed file is not unreached" $?
fset() { ex 'locals {
  srcs = fileset("../..", "*.py")
}'; }
t_fileset() { repo fileset fset; none; }
t_fileset; check "an example that calls fileset makes the line stale" $?
json() { printf '{}\n' > examples/ex/extra.tf.json; }
t_json() { repo json json; none; }
t_json; check "a .tf.json file in the example makes the line stale" $?
tofu() { printf 'locals {}\n' > examples/ex/extra.tofu; }
t_tofu() { repo tofu tofu; none; }
t_tofu; check "an OpenTofu file in the example makes the line stale" $?
lnk() { ln -sf main.tf examples/ex/alias.tf; }
t_lnk() { repo lnk lnk; none; }
t_lnk; check "a .tf file that is a link makes the line stale" $?
lnkany() { ln -sf ../build examples/ex/b; }
t_lnkany() { repo lnkany lnkany; none; }
t_lnkany; check "any link in the example makes the line stale" $?
oddname() { printf 'module "u" {\n  source         = "../../"\n  create_package = false\n}\n' > "examples/ex/$(printf 'e\303\251').tf"; }
t_oddname() { repo oddname oddname; none; }
t_oddname; check "a file name outside the plain charset makes the line stale" $?
openhd() { ex 'x = <<EOT
open'; }
t_openhd() { repo openhd openhd; none; }
t_openhd; check "a heredoc that does not end makes the line stale" $?
hdinterp() {
  printf '%s\n' 'module "lambda_function" {' '  source = "../../"' '  description = <<EOT' '${[for x in ["a"] : x' 'EOT' '][0]}{' '  create_package = false' 'EOT' '}' > examples/ex/main.tf
}
t_hdinterp() { repo hdinterp hdinterp; none; }
t_hdinterp; check "a template sequence in a heredoc body makes the line stale" $?
nestq() { printf '%s\n' 'locals {' '  a = "${lookup({}, "{", "x")}"' '}' 'module "hidden" {' '  source = "../../"' '}' 'locals {' '  c = "${lookup({}, "}", "x")}"' '}' > examples/ex/extra.tf; }
t_nestq() { repo nestq nestq; none; }
t_nestq; check "a quote inside an interpolation after a brace makes the line stale" $?
dirq() { printf '%s\n' 'locals {' '  a = "%{ if "x" == "{" }y%{ endif }"' '}' 'module "hidden" {' '  source = "../../"' '}' 'locals {' '  c = "%{ if "x" == "}" }y%{ endif }"' '}' > examples/ex/extra.tf; }
t_dirq() { repo dirq dirq; none; }
t_dirq; check "a quote inside a template directive makes the line stale" $?
ungate() { perl -0pi -e 's/  count = var.create && var.create_package \? 1 : 0\n\n  program/  program/' package.tf; }
t_ungated() { repo ungated ungate; none; }
t_ungated; check "a root block that names the file with no count makes the line stale" $?
othergate() { perl -pi -e 's/var.create && var.create_package/var.create/' package.tf; }
t_othergate() { repo othergate othergate; none; }
t_othergate; check "a root block whose count does not read the variable makes the line stale" $?
gate_base() { perl -pi -e 's/var.create && var.create_package \? 1 : 0/var.create_package ? 1 : 0/' package.tf; }
t_gatediff() { repo gatediff gate_base unbase; none; }
unbase() { printf '%s\n' "$PKG_TF" > package.tf; }
t_gatediff; check "a root gate that differs between the merge base and the head makes the line stale" $?
rootfs() { printf 'locals {\n  srcs = fileset(path.module, "*.py")\n}\n' > files.tf; }
t_rootfs() { repo rootfs rootfs; none; }
t_rootfs; check "a root block that calls fileset with no gate makes the line stale" $?
nopkg() { printf 'locals {}\n' > package.tf; }
t_nogate() { repo nogate nopkg; none; }
t_nogate; check "a module root with no block naming the file proves nothing" $?
t_rootchg() {
  repo rootchg
  jq -n '[{filename: "package.py", status: "modified"}, {filename: "package.tf", status: "modified"}]' > "$TMP/f3.json"
  FILES="$TMP/f3.json" none
}
t_rootchg; check "a change that edits a .tf file of the module root clears nothing" $?
# Files over the pipe buffer, the name on their first line: a check must read them whole.
pad() { awk 'BEGIN { for (i = 0; i < 2500; i++) printf "# filler line %04d of padding text for the pipe buffer\n", i }'; }
bigtxt() { { printf 'python3 ../../package.py\n'; pad; } > examples/ex/notes.txt; }
t_bigtxt() { repo bigtxt bigtxt; none; }
t_bigtxt; check "a file over the pipe buffer that names the changed file first is read whole" $?
bigfs() { { printf 'locals {\n  srcs = fileset("../..", "*.py")\n}\n'; pad; } > examples/ex/extra.tf; }
t_bigfileset() { repo bigfileset bigfs; none; }
t_bigfileset; check "a .tf file over the pipe buffer that calls fileset first is read whole" $?
bigroot() {
  { printf 'resource "null_resource" "zz" {\n  provisioner "local-exec" {\n    command = "python3 ${path.module}/package.py"\n  }\n}\n'; pad; } > zz.tf
}
t_bigroot() { repo bigroot bigroot; none; }
t_bigroot; check "an ungated root block in a .tf file over the pipe buffer is read whole" $?
t_bigrootchg() {
  repo bigrootchg
  jq -n '[{filename: "package.py", status: "modified"}, {filename: "package.tf", status: "modified"}]
    + [range(8000) | {filename: "docs/file-\(.).md", status: "modified"}]' > "$TMP/f4.json"
  FILES="$TMP/f4.json" none
}
t_bigrootchg; check "an edited root .tf file early in a files list over the pipe buffer clears nothing" $?
gate_cmt() { perl -0pi -e 's/  count = var.create && var.create_package \? 1 : 0\n\n  program/  count = 1 # was var.create_package ? 1 : 0\n\n  program/' package.tf; }
t_gatecmt() { repo gatecmt gate_cmt; none; }
t_gatecmt; check "a root gate whose variable is only in a comment makes the line stale" $?
gate_str() { perl -0pi -e 's/  count = var.create && var.create_package \? 1 : 0\n\n  program/  for_each = toset(["var.create_package"])\n\n  program/' package.tf; }
t_gatestr() { repo gatestr gate_str; none; }
t_gatestr; check "a root gate whose variable is only in a string makes the line stale" $?
bom() { printf '\357\273\277module "g" {\n  source = "../../"\n}\n' > examples/ex/bom.tf; }
t_bom() { repo bom bom; none; }
t_bom; check "a byte order mark in an example .tf file makes the line stale" $?
otherbyte() { printf '\342\200\250module "g" {\n  source = "../../"\n}\n' > examples/ex/sep.tf; }
t_otherbyte() { repo otherbyte otherbyte; none; }
t_otherbyte; check "any byte outside printable ASCII in an example .tf file makes the line stale" $?
bomtxt() { printf '\357\273\277notes\n' > examples/ex/notes.txt; }
t_bomtxt() { repo bomtxt bomtxt; none; }
t_bomtxt; check "a byte order mark in any example file makes the line stale" $?
nbsp() {
  printf 'locals {\n  y = <<EOT\ntext\nEOT\302\240\n}\nmodule "hid" {\n  source = "../../"\n}\nlocals {\n  z = <<EOT\nEOT\n}\n' > examples/ex/extra.tf
}
t_nbsp() { repo nbsp nbsp; none; }
t_nbsp; check "a non-ASCII space after a heredoc tag makes the line stale" $?
nbsptxt() { printf 'a\302\240b\n' > examples/ex/notes.txt; }
t_nbsptxt() { repo nbsptxt nbsptxt; none; }
t_nbsptxt; check "a non-ASCII space in any example file makes the line stale" $?
to_sub() {
  mkdir sub && mv package.py package.tf sub/
  perl -pi -e 's|source = "../../"$|source = "../../sub"|' examples/ex/main.tf
}
t_prefix() {
  repo prefix to_sub
  printf '%s\n' "${LINE/ package.py / sub/package.py }" > "$TMP/sub.txt"
  RF="$TMP/sub.txt" run --prefix sub; [ "$ST" = 0 ] && [ "$(un)" = '["examples/ex"]' ] && [ "$(jq -r '.files[0].file' <<< "$OUT")" = package.py ]
}
t_prefix; check "under a module root prefix the reach file names repository paths and the root is the prefix" $?
to_sub_root() { to_sub; perl -pi -e 's|source = "../../sub"$|source = "../../"|' examples/ex/main.tf; }
t_prefixroot() {
  repo prefixroot to_sub_root
  printf '%s\n' "${LINE/ package.py / sub/package.py }" > "$TMP/sub.txt"
  RF="$TMP/sub.txt" none --prefix sub
}
t_prefixroot; check "under a prefix a call of the repository root is no call of the module root" $?
t_partial() { repo partial; git -C "$R" config extensions.partialclone origin; run; [ "$ST" = 1 ] && [ -z "$OUT" ]; }
t_partial; check "a partial clone is refused" $?
t_badsha() { repo badsha; OUT="$(bash "$NR" --git "$R" --head HEAD --base "$B" --repo a/b --behaviour "$TMP/beh.json" --files "$TMP/files.json")"; [ $? = 1 ] && [ -z "$OUT" ]; }
t_badsha; check "a head that is not a SHA is refused" $?

# --- Test evidence: a tested-by line, the repository's own tests and their check runs at the head.
TLINE='tested-by example/terraform-aws-lambda package.py tests .github/workflows/test.yml checks Test with Python'
tsetup() {
  mkdir -p tests .github/workflows
  printf 'import os\n\nfrom package import BuildPlanManager\n\n\ndef test_x():\n    assert os\n' > tests/test_zip.py
  printf 'def test_y():\n    assert True\n' > tests/test_other.py
  printf 'jobs:\n  tests:\n    name: Test with Python ${{ matrix.v }}\n    steps:\n      - run: python -m pytest -vvv tests/\n' > .github/workflows/test.yml
}
# checks <conclusion of 3.11> [app [head]] -> TMP/checks.json: an older failed 3.10 run, then the
# latest 3.10 success, a 3.11 run, and a run of another job.
checks() {
  jq -n --arg c "$1" --arg a "${2:-github-actions}" --arg h "${3:-$H}" '[
    {id: 1, name: "Test with Python 3.10", app_slug: "github-actions", status: "completed", conclusion: "failure", head_sha: $h},
    {id: 5, name: "Test with Python 3.10", app_slug: "github-actions", status: "completed", conclusion: "success", head_sha: $h},
    {id: 3, name: "Test with Python 3.11", app_slug: $a, status: "completed", conclusion: $c, head_sha: $h},
    {id: 4, name: "Ruff Format check", app_slug: "github-actions", status: "completed", conclusion: "failure", head_sha: $h}]' > "$TMP/checks.json"
}
printf '%s\n%s\n' "$LINE" "$TLINE" > "$TMP/treach.txt"
tested() { jq -r '.files[0].tested' <<< "$OUT"; }
# trun [repo setup at base [, at head]] -> runs with the tested-by reach file and the checks file
tcase() { # name, base setup, head setup, conclusion [, app [, head]] -> holds when the file is tested
  repo "$1" "$2" "${3-}"; checks "${4:-success}" "${5-}" "${6-}"
  RF="$TMP/treach.txt" run --checks "$TMP/checks.json"; [ "$ST" = 0 ] && [ "$(tested)" = true ]
}
untested() { ! tcase "$@" && [ "$ST" = 0 ] && [ "$(tested)" = false ]; }
t_tested() { tcase tested tsetup "" success && [ "$(un)" = '["examples/ex"]' ]; }
t_tested; check "tests that import the file and green check runs at the head: the file is tested" $?
t_tnochecks() { repo tnochecks tsetup; RF="$TMP/treach.txt" run; [ "$ST" = 0 ] && [ "$(tested)" = false ]; }
t_tnochecks; check "no check runs file: nothing is tested" $?
t_tnoline() { repo tnoline tsetup; checks success; run --checks "$TMP/checks.json"; [ "$ST" = 0 ] && [ "$(tested)" = false ]; }
t_tnoline; check "no tested-by line: nothing is tested" $?
t_tred() { untested tred tsetup "" failure; }
t_tred; check "a matching check run that failed at the head: not tested" $?
t_tpending() { repo tpending tsetup; checks success; jq '.[2].status = "in_progress"' "$TMP/checks.json" > "$TMP/c2.json"
  RF="$TMP/treach.txt" run --checks "$TMP/c2.json"; [ "$ST" = 0 ] && [ "$(tested)" = false ]; }
t_tpending; check "a matching check run not completed: not tested" $?
t_tlatest() { repo tlatest tsetup; checks success; jq '.[0].id = 9' "$TMP/checks.json" > "$TMP/c2.json"
  RF="$TMP/treach.txt" run --checks "$TMP/c2.json"; [ "$ST" = 0 ] && [ "$(tested)" = false ]; }
t_tlatest; check "the latest run of a name failed while an older one passed: not tested" $?
t_tnomatch() { repo tnomatch tsetup; jq -n '[{id: 1, name: "Ruff", app_slug: "github-actions", status: "completed", conclusion: "success", head_sha: "x"}]' > "$TMP/c2.json"
  RF="$TMP/treach.txt" run --checks "$TMP/c2.json"; [ "$ST" = 0 ] && [ "$(tested)" = false ]; }
t_tnomatch; check "no check run whose name starts with the prefix: not tested" $?
t_tapp() { untested tapp tsetup "" success other-app; }
t_tapp; check "a matching check run of another app: not tested" $?
t_tsha() { untested tsha tsetup "" success github-actions 0000000000000000000000000000000000000000; }
t_tsha; check "a matching check run of another commit: not tested" $?
gh_other() { printf 'x: 1\n' > .github/workflows/other.yml; }
jq -n '[{filename: "package.py", status: "modified"}, {filename: ".github/workflows/other.yml", status: "added"}]' > "$TMP/fgh.json"
t_tgithub() { FILES="$TMP/fgh.json" untested tgithub tsetup gh_other success; }
t_tgithub; check "a change that edits a file under .github/: not tested" $?
wf_edit() { printf '# edited\n' >> .github/workflows/test.yml; }
t_twfdiff() { untested twfdiff tsetup wf_edit success; }
t_twfdiff; check "a workflow that differs between the merge base and the head, even unlisted: not tested" $?
wf_nopytest() { tsetup; perl -pi -e 's/python -m pytest -vvv tests\//make test/' .github/workflows/test.yml; }
t_twfnopy() { untested twfnopy wf_nopytest; }
t_twfnopy; check "a workflow that names no pytest run of the tests dir: not tested" $?
wf_link() { tsetup; mv .github/workflows/test.yml .github/workflows/pytest-tests.yml; ln -s pytest-tests.yml .github/workflows/test.yml; }
t_twflink() { untested twflink wf_link; }
t_twflink; check "a workflow that is a link: not tested" $?
jq -n '[{filename: "package.py", status: "modified"}, {filename: "tests/test_new.py", status: "added"}]' > "$TMP/ftests.json"
t_new() { printf 'def test_n():\n    pass\n' > tests/test_new.py; }
t_ttests() { FILES="$TMP/ftests.json" untested ttests tsetup "" success; }
t_ttests; check "a change that lists a file of the tests dir: not tested" $?
t_ttree() { untested ttree tsetup t_new success; }
t_ttree; check "a tests dir that differs between the merge base and the head, even unlisted: not tested" $?
jq -n '[{filename: "package.py", status: "modified"}, {filename: "examples/pyproject.toml", status: "added"}]' > "$TMP/fcfg.json"
t_cfg() { printf '[tool.pytest]\n' > examples/pyproject.toml; }
t_tcfg() { FILES="$TMP/fcfg.json" untested tcfg tsetup t_cfg success; }
t_tcfg; check "a change that edits a Python test or packaging config at any path: not tested" $?
noimport() { tsetup; perl -pi -e 's/^from package import BuildPlanManager$/from packaging import x/' tests/test_zip.py; }
t_tnoimport() { untested tnoimport noimport; }
t_tnoimport; check "no test file imports the changed file: not tested" $?
indented() { tsetup; perl -pi -e 's/^from package import/    from package import/' tests/test_zip.py; }
t_tindent() { untested tindent indented; }
t_tindent; check "an import that does not start its line: not tested" $?
shadow() { tsetup; printf 'x = 1\n' > tests/package.py; }
t_tshadow() { untested tshadow shadow; }
t_tshadow; check "a tests dir entry that shadows the module: not tested" $?
# listed <name> <path>... -> a files list of package.py and those paths, added
listed() { local n="$1"; shift; jq -n --args '[{filename: "package.py", status: "modified"}] + [$ARGS.positional[] | {filename: ., status: "modified"}]' "$@" > "$TMP/l-$n.json"; }
cfgcase() { # name, path -> holds when a change of that path tests nothing
  listed "$1" "$2"; FILES="$TMP/l-$1.json" untested "$1" tsetup "" success
}
t_tpytoml() { cfgcase tpytoml sub/pytest.toml && cfgcase tdpytoml sub/.pytest.toml && cfgcase tdpyini sub/.pytest.ini; }
t_tpytoml; check "a change of pytest.toml, .pytest.toml or .pytest.ini at any path: not tested" $?
t_tsite() { cfgcase tsite sub/sitecustomize.py && cfgcase tuser sub/usercustomize.py; }
t_tsite; check "a change of sitecustomize.py or usercustomize.py at any path: not tested" $?
t_tconftest() { cfgcase tconftest deep/er/conftest.py; }
t_tconftest; check "a change of conftest.py at any path: not tested" $?
t_trootext() { cfgcase trootext custom.toml && cfgcase trootini setup.ini && cfgcase trootcfg x.cfg; }
t_trootext; check "a change of a .toml, .ini or .cfg file at the repository root: not tested" $?
t_trootpth() { cfgcase trootpth local.pth; }
t_trootpth; check "a change of a .pth file at the repository root: not tested" $?
t_tdeepext() { listed tdeep sub/other.toml; FILES="$TMP/l-tdeep.json" tcase tdeep tsetup "" success; }
t_tdeepext; check "a .toml file outside the root and the tests dir's parents still tests the file" $?
nested() {
  mkdir -p a/tests .github/workflows
  printf 'from package import X\n' > a/tests/test_zip.py
  printf 'jobs:\n  t:\n    steps:\n      - run: python -m pytest a/tests/\n' > .github/workflows/test.yml
}
t_tparentext() {
  repo tparentext nested; checks success; listed tparentext a/x.cfg
  printf '%s\n' "${TLINE/ tests / a/tests }" > "$TMP/tnest.txt"
  FILES="$TMP/l-tparentext.json" RF="$TMP/tnest.txt" run --checks "$TMP/checks.json"; [ "$ST" = 0 ] && [ "$(tested)" = false ] || return 1
  RF="$TMP/tnest.txt" run --checks "$TMP/checks.json"; [ "$ST" = 0 ] && [ "$(tested)" = true ]
}
t_tparentext; check "a change of a .cfg file in a parent of the tests dir: not tested; none: tested" $?
# The shadowing entries sit at the merge base too, so the new-entry rule does not hide them.
pkgdir() { tsetup; mkdir -p package && printf '\n' > package/__init__.py; }
t_tshadowdir() { untested tshadowdir pkgdir "" success; }
t_tshadowdir; check "a package directory named like the module at the root: not tested" $?
pkgso() { tsetup; printf 'elf\n' > package.cpython-312-x86_64-linux-gnu.so; }
t_tshadowso() { untested tshadowso pkgso "" success; }
t_tshadowso; check "an extension module named like the module at the root: not tested" $?
pkgpyc() { tsetup; printf 'pyc\n' > package.pyc; git add -f package.pyc; } # forced past any global ignore
t_tshadowpyc() { untested tshadowpyc pkgpyc "" success; }
t_tshadowpyc; check "a bytecode file named like the module at the root: not tested" $?
pkgmd() { tsetup; printf 'notes\n' > package.md; }
t_tsiblingok() { tcase tsiblingok pkgmd "" success; }
t_tsiblingok; check "a root file named like the module with a suffix Python does not import still tests the file" $?
realpy() { tsetup; printf 'y\n' > real.py; }
pylink() { rm package.py; ln -s real.py package.py; }
t_tpylink() { untested tpylink realpy pylink success; }
t_tpylink; check "a changed file that is a link at the head: not tested" $?
# A new top-level entry of the head's tree, listed or not: python -m pytest puts the root first on
# sys.path, so a new package (a fake pytest), a plugin's metadata or a bytecode cache loads first.
fakepytest() { mkdir -p pytest && printf '\n' > pytest/__init__.py && printf 'raise SystemExit(0)\n' > pytest/__main__.py; }
t_tfakepytest() { untested tfakepytest tsetup fakepytest success; }
t_tfakepytest; check "a new top-level pytest package, unlisted: not tested" $?
newfile() { printf 'x\n' > notes.txt; }
t_tnewroot() { untested tnewroot tsetup newfile success; }
t_tnewroot; check "a new top-level file: not tested" $?
plugin() { mkdir -p evil.dist-info evilplug && printf 'Name: evil\n' > evil.dist-info/METADATA \
  && printf '[pytest11]\nevil = evilplug\n' > evil.dist-info/entry_points.txt && printf '\n' > evilplug/__init__.py; }
t_tplugin() { untested tplugin tsetup plugin success; }
t_tplugin; check "a new top-level plugin package with its dist-info: not tested" $?
newcache() { mkdir -p __pycache__ && printf 'pyc\n' > __pycache__/package.cpython-312.pyc && git add -f __pycache__; }
t_tnewcache() { untested tnewcache tsetup newcache success; }
t_tnewcache; check "a new top-level __pycache__: not tested" $?
belowfile() { printf 'x\n' > examples/new.txt; }
t_taddbelow() { tcase taddbelow tsetup belowfile success; }
t_taddbelow; check "a file added inside an existing top-level directory still tests the file" $?
# Import metadata and caches the merge base already holds, at the root or in a parent of the tests
# dir: refused at the head whatever the change.
basecache() { tsetup; mkdir -p __pycache__ && printf 'pyc\n' > __pycache__/package.cpython-312.pyc && git add -f __pycache__; }
t_tbasecache() { untested tbasecache basecache "" success; }
t_tbasecache; check "a __pycache__ at the repository root, already at the merge base: not tested" $?
baseegg() { tsetup; mkdir -p x.egg-info && printf 'Name: x\n' > x.egg-info/PKG-INFO; }
t_tbaseegg() { untested tbaseegg baseegg "" success; }
t_tbaseegg; check "an .egg-info at the repository root, already at the merge base: not tested" $?
nestdist() { mkdir -p a/evil.dist-info && printf '[pytest11]\nevil = evilplug\n' > a/evil.dist-info/entry_points.txt; }
t_tnestdist() {
  repo tnestdist nested nestdist; checks success
  printf '%s\n' "${TLINE/ tests / a/tests }" > "$TMP/tnest.txt"
  RF="$TMP/tnest.txt" run --checks "$TMP/checks.json"; [ "$ST" = 0 ] && [ "$(tested)" = false ]
}
t_tnestdist; check "a .dist-info in a parent of the tests dir: not tested" $?
t_tsubdir() {
  repo tsubdir tsetup; checks success
  printf 'tested-by example/terraform-aws-lambda sub/package.py tests .github/workflows/test.yml checks Test with Python\n' > "$TMP/tsub.txt"
  jq -n '{schema_version: 1, capped: 0, triggers: [{id: "T-001", file: "package.py", line: 1, category: "non-hcl-dependency"}]}' > "$TMP/beh2.json"
  OUT="$(bash "$NR" --git "$R" --head "$H" --base "$B" --repo example/terraform-aws-lambda --behaviour "$TMP/beh2.json" \
    --files "$TMP/files.json" --reach "$TMP/tsub.txt" --checks "$TMP/checks.json" --prefix sub 2> /dev/null)"
  [ $? = 0 ] && [ "$(tested)" = false ]
}
t_tsubdir; check "a changed file below the repository root: not tested" $?
t_tother() { repo tother tsetup; checks success; printf '%s\n' "${TLINE/example\/terraform-aws-lambda/other/repo}" > "$TMP/to.txt"
  RF="$TMP/to.txt" run --checks "$TMP/checks.json"; [ "$ST" = 0 ] && [ "$(tested)" = false ]; }
t_tother; check "a tested-by line of another repository tests nothing" $?
t_tbadpx() { bad_reach tbadpx "${TLINE/Test with Python/Test \$with}"; }
t_tbadpx; check "a tested-by prefix outside the grammar refuses the whole file" $?
t_tbadck() { bad_reach tbadck "${TLINE/ checks / runs }"; }
t_tbadck; check "a tested-by line without its checks keyword refuses the whole file" $?
t_ttwice() { bad_reach ttwice "$TLINE" "${TLINE/tests .github/test .github}"; }
t_ttwice; check "a file with two tested-by lines refuses the whole file" $?

# --- Negative self-check: each mutation of a temp copy must make its named case fail.
mutate() { # name, perl substitution, case function
  local d="$TMP/mut"; mkdir -p "$d"; cp "$NR" "$d/nonhcl-reach.sh"
  perl -0pi -e "$2" "$d/nonhcl-reach.sh"
  if cmp -s "$d/nonhcl-reach.sh" "$NR"; then check "self-check: $1 (the mutation changed nothing)" 1; return; fi
  local keep="$NR" before="$fails"; NR="$d/nonhcl-reach.sh"
  "$3" > /dev/null 2>&1; local s=$?
  NR="$keep"; fails="$before"
  check "self-check: $1 is caught" "$([ "$s" != 0 ]; echo $?)"
}
mutate "the example guard not read at the head" 's/hc="\$\(guard_at "\$head"/hc="\$(guard_at "\$base"/' t_headtrue
mutate "the example guard not read at the merge base" 's/bc="\$\(guard_at "\$base" "\$md" "\$r" "\$ma"\)" \|\| continue/bc="\$hc"/' t_basetrue
mutate "a new module call not compared" 's/\[ "\$hc" = "\$bc" \] \|\| continue/:/' t_newcall
mutate "the literal not compared" 's/ && \[ "\$val" = "\$want" \] \|\| return 1/ || return 1/' t_headtrue
mutate "a call of another module taken" 's/\[ "\$\(resolve "\$d" "\$src"\)" = "\$root" \] && //' t_wrappers
mutate "an example with no module call taken" 's/\[ -n "\$list" \] \|\| return 1\n  printf .%s. "\$list" \| sort\n\}\n# The root gate/printf "%s" "\$list" | sort\n}\n# The root gate/' t_nocall
mutate "a .tf file below the top taken" 's/ \*\/\*\.tf\) return 1 ;;//' t_subdir
mutate "a non-literal value taken" 's/val = \(v ~ \/\^\(false\|true\|null\|\[0-9\]\+\)\$\/\) \? v : "\?"/val = v; sub(\/^var\\..*\/, "false", val)/' t_var
mutate "the changed directory guard dropped" 's/index\(\$0, d\) == 1 \{ f = 1 \}/0 { f = 1 }/' t_changed
mutate "the repository of a reach line not compared" 's/\[ "\$r" != "\$repo" \] \|\| maps=/maps=/' t_other
mutate "a malformed reach line skipped" 's/\[\[ "\$\{bv-\}" =~ (\S+) \]\] \|\| die/[[ "\${bv-}" =~ $1 ]] || continue/' t_badreach
mutate "a file and directory named twice taken" 's/case "\$seen" in \*"\|\$r \$f \$d\|"\*\) die ;; esac//' t_twice
mutate "a reach link followed" 's/ && \[ ! -L "\$reach" \]//' t_link
mutate "a name of the changed file in another example file not read" 's/    ! grep -Fq -- "\$b" <<< "\$t" \|\| return 1\n    ! grep -Eq "\$wide"/    ! grep -Eq "\$wide"/' t_namessh
mutate "an example fileset taken" 's/    ! grep -Eq .fileset\[\[:space:\]\]\*\\\(. <<< "\$t" \|\| return 1\n//' t_fileset
mutate "a .tf.json file taken" 's/case "\$path" in \*\.tf\.json \| \*\.tofu \| \*\.tofu\.json\) return 1 ;; \*\/\*\.tf\) return 1 ;; esac/case "\$path" in *.tofu | *.tofu.json) return 1 ;; *\/*.tf) return 1 ;; esac/' t_json
mutate "an OpenTofu file taken" 's/case "\$path" in \*\.tf\.json \| \*\.tofu \| \*\.tofu\.json\) return 1 ;;/case "\$path" in *.tf.json) return 1 ;;/' t_tofu
mutate "a link taken" 's/\[ "\$mode" = 100644 \] \|\| \[ "\$mode" = 100755 \] \|\| return 1/:/' t_lnkany
mutate "a name outside the charset taken" 's/    plain "\$path" \|\| return 1\n//' t_oddname
mutate "a block comment taken" 's/if \(code ~ \/\\\/\\\*\/\) bad\(\)//' t_blockc
mutate "an interpolated source taken" 's/=\[\[:space:\]\]\*"\[\^"\$%\\\\\]\*"/=[[:space:]]*"[^"]*"/' t_interp
mutate "an open heredoc taken" 's/ \|\| inblk \|\| tag != ""\)\) print "stale"/ || inblk)) print "stale"/' t_openhd
mutate "a template sequence in a heredoc body taken" 's/      if \(line ~ \/\[\$%\]\\\{\/\) bad\(\)\n//' t_hdinterp
mutate "a quote inside a template sequence taken" 's/if \(c == "\\"" \|\| \(c == "<" && n2 == "<"\)\) bad\(\)/if (c == "\\"") { lvl = 0; q = 0; continue }/' t_nestq
mutate "a template directive read as text" 's/if \(\(c == "\$" \|\| c == "%"\) && n2 == "\{"\) \{ lvl = 1; i\+\+; continue \}/if (c == "\$" \&\& n2 == "{") { lvl = 1; i++; continue }/' t_dirq
mutate "the root gate not read at the head" 's/hg="\$\(gate_at "\$head"/hg="\$(gate_at "\$base"/' t_gatediff
mutate "the root gate not compared" 's/\[ "\$hg" = "\$bg" \] \|\| continue/:/' t_gatediff
mutate "an ungated root block taken" 's/<<< "\$gl" \|\| return 1/<<< "\$gl" || :/' t_ungated
mutate "a module root with no naming block taken" 's/\[ -n "\$list" \] \|\| return 1\n  printf .%s. "\$list" \| sort\n\}\n\n# The test evidence/printf "%s" "\$list" | sort\n}\n\n# The test evidence/' t_nogate
mutate "an edited root .tf file ignored" 's/\|\| root_changed=true/|| :/' t_rootchg
mutate "the module root taken as the repository root under a prefix" 's/root="\$\{prefix:-\.\}" ents mode type path t r name/root="." ents mode type path t r name/' t_prefixroot
mutate "an example file read through a pipe" 's/! grep -Fq -- "\$b" <<< "\$t" \|\| return 1/! printf "%s\\n" "\$t" | grep -Fq -- "\$b" || return 1/' t_bigtxt
mutate "an example fileset read through a pipe" 's/! grep -Eq .fileset\[\[:space:\]\]\*\\\(. <<< "\$t" \|\| return 1/! printf "%s\\n" "\$t" | grep -Eq "fileset" || return 1/' t_bigfileset
mutate "a root file read through a pipe" 's/grep -Fq -- "\$b" <<< "\$t" \|\| grep -Eq .fileset\[\[:space:\]\]\*\\\(. <<< "\$t" \|\| continue/printf "%s\\n" "\$t" | grep -Fq -- "\$b" || continue/' t_bigroot
mutate "the files list read through a pipe" 's/! grep -Eq "\$rootre" <<< "\$changed" \|\| root_changed=true/! printf "%s\\n" "\$changed" | grep -Eq "\$rootre" || root_changed=true/' t_bigrootchg
mutate "the root gate read from the raw line" 's/g = code; gsub/g = line; gsub/' t_gatecmt
mutate "the root gate read with its strings" 's/g = code; gsub/g = line; gsub/' t_gatestr
mutate "a byte outside printable ASCII taken in a .tf file" 's/    \{ line = \$0; sub\(\/\\r\$\/, "", line\); if \(line ~ \/\[\^\\t -~\]\/\) bad\(\) \}/    { line = \$0; sub(\/\\r\$\/, "", line) }/' t_otherbyte
mutate "a byte order mark taken in another file" 's/    ! grep -Eq "\$wide" <<< "\$t" \|\| return 1\n//' t_bomtxt
mutate "a partial clone read" 's/\[ -z "\$\(g config --get extensions\.partialclone 2> \/dev\/null\)" \] \|\| die/:/' t_partial

mutate "the check run conclusion not read" 's/\.status == "completed" and \.conclusion == "success"/.status == "completed"/' t_tred
mutate "the check run status not read" 's/\.status == "completed" and \.conclusion == "success"/.conclusion == "success"/' t_tpending
mutate "an older run of a name read for its latest" 's/max_by\(\.id\)/min_by(.id)/' t_tlatest
mutate "no matching check run taken" 's/\| \(\$m \| length\) > 0\n      and /| true\n      and /' t_tnomatch
mutate "the check run app not read" 's/\n            and \.app_slug == "github-actions"\)\)/))/' t_tapp
mutate "the check run commit not read" 's/ and \.head_sha == \$h\)/)/' t_tsha
mutate "a change under .github/ taken" 's/  ! grep -Eq .\^\\\.github\/. <<< "\$changed" \|\| return 1\n//' t_tgithub
mutate "a workflow that differs at the head taken" 's/  \[ "\$\(g rev-parse "\$head:\$wf" 2> \/dev\/null\)" = "\$\(g rev-parse "\$base:\$wf" 2> \/dev\/null\)" \] \|\| return 1\n//' t_twfdiff
mutate "a workflow with no pytest run taken" 's/grep -Fq pytest <<< "\$t" && //' t_twfnopy
mutate "a linked workflow taken" 's/\[ "\$\(g ls-tree "\$head" -- "\$wf" 2> \/dev\/null \| cut -d. . -f1-2\)" = "100644 blob" \] \|\| return 1/:/' t_twflink
mutate "a change in the tests dir taken" 's/  ! awk -v d="\$td\/" .index\(\$0, d\) == 1 \{ t = 1 \} END \{ exit !t \}. <<< "\$changed" \|\| return 1\n//' t_ttests
mutate "a tests dir that differs at the head taken" 's/  \[ "\$\(g rev-parse "\$head:\$td" 2> \/dev\/null\)" = "\$\(g rev-parse "\$base:\$td" 2> \/dev\/null\)" \] \|\| return 1\n//' t_ttree
mutate "a config change taken" 's/  ! grep -Eq "\$cfgre" <<< "\$changed" \|\| return 1\n//' t_tcfg
mutate "a test file with no import taken" 's/\[ -n "\$hit" \] \|\| return 1/:/' t_tnoimport
mutate "an import anywhere on a line taken" 's/grep -Eq "\^\(from \$mod/grep -Eq "(from \$mod/' t_tindent
mutate "a shadowing entry in the tests dir taken" 's/    case "\$path" in "\$mod" \| "\$mod"\.\*\) return 1 ;; esac\n//' t_tshadow
mutate "a changed file below the repository root read by its base name" 's/mod="\$\{f%\.py\}"/mod="\${f##*\/}"; mod="\${mod%.py}"/' t_tsubdir
mutate "the repository of a tested-by line not compared" 's/\[ "\$r" != "\$repo" \] \|\| tests=/tests=/' t_tother
mutate "a tested-by prefix outside the grammar taken" 's/\[\[ "\$\{px-\}" =~ .+? \]\] \|\| die/[[ -n "\${px-}" ]] || die/' t_tbadpx
mutate "a tested-by line without checks taken" 's/ && \[ "\$\{ck-\}" = checks \]//' t_tbadck
mutate "two tested-by lines of a file taken" 's/case "\$seen" in \*"\|tested \$r \$f\|"\*\) die ;; esac//' t_ttwice
mutate "the checks file not read" 's/ \|\| te=true/ || :/' t_tested
mutate "pytest.toml and the dotted pytest files taken" 's/\\\.\?pytest\\\.\(ini\|toml\)\|/pytest\\.ini|/' t_tpytoml
mutate "sitecustomize.py and usercustomize.py taken" 's/sitecustomize\\\.py\|usercustomize\\\.py\|//' t_tsite
mutate "conftest.py taken" 's/\|conftest\\\.py\|/|/' t_tconftest
mutate "a config file at the repository root taken" 's/if \(d == "" \|\| index/if (index/' t_trootext
mutate "a .pth file at the repository root taken" 's/\(toml\|ini\|cfg\|pth\)\$\//(toml|ini|cfg)\$\//' t_trootpth
mutate "a config file in a parent of the tests dir taken" 's/if \(d == "" \|\| index\(td "\/", d "\/"\) == 1\) x = 1/if (d == "") x = 1/' t_tparentext
mutate "a root entry named like the module taken" 's/sh\) ;; \*\) return 1 ;; esac ;;/sh) ;; *) ;; esac ;;/' t_tshadowso
mutate "a root package directory taken" 's/      "\$mod"\) return 1 ;;\n//' t_tshadowdir
mutate "a root bytecode file taken" 's/tf \| json \| md \| txt/pyc | tf | json | md | txt/' t_tshadowpyc
mutate "a linked changed file taken" 's/"\$mod\.py"\) \[ "\$mode" = 100644 \] && \[ "\$type" = blob \] \|\| return 1; own=1 ;;/"\$mod.py") own=1 ;;/' t_tpylink
mutate "a new top-level entry taken" 's/  ! awk .NR == FNR \{ b\[\$3\] = 1; next \} \$3 != "" && !\(\$3 in b\) \{ x = 1 \} END \{ exit !x \}. \\\n.*?\|\| return 1\n//s' t_tfakepytest
mutate "a new top-level file taken" 's/  ! awk .NR == FNR \{ b\[\$3\] = 1; next \} \$3 != "" && !\(\$3 in b\) \{ x = 1 \} END \{ exit !x \}. \\\n.*?\|\| return 1\n//s' t_tnewroot
mutate "a new top-level plugin taken" 's/  ! awk .NR == FNR \{ b\[\$3\] = 1; next \} \$3 != "" && !\(\$3 in b\) \{ x = 1 \} END \{ exit !x \}. \\\n.*?\|\| return 1\n//s; s/\\\.\(dist\|egg\)-info\$/\\.egg-info\$/' t_tplugin
mutate "a new top-level __pycache__ taken" 's/  ! awk .NR == FNR \{ b\[\$3\] = 1; next \} \$3 != "" && !\(\$3 in b\) \{ x = 1 \} END \{ exit !x \}. \\\n.*?\|\| return 1\n//s; s/\$3 == "__pycache__" \|\| //' t_tnewcache
mutate "a __pycache__ at the merge base taken" 's/\$3 == "__pycache__" \|\| //' t_tbasecache
mutate "an .egg-info taken" 's/\\\.\(dist\|egg\)-info\$/\\.dist-info\$/' t_tbaseegg
mutate "a .dist-info in a parent of the tests dir taken" 's/while \[\[ "\$pd" == \*\/\* \]\]; do pd="\$\{pd%\/\*\}"; dirs="\$dirs"\$.\\n."\$pd"; done/:/' t_tnestdist
echo
if [ "$fails" -eq 0 ]; then echo "nonhcl reach: all checks hold"; else echo "nonhcl reach: $fails failed"; exit 1; fi
