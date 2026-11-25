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
mutate "a module root with no naming block taken" 's/\[ -n "\$list" \] \|\| return 1\n  printf .%s. "\$list" \| sort\n\}\n\n# A change/printf "%s" "\$list" | sort\n}\n\n# A change/' t_nogate
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

echo
if [ "$fails" -eq 0 ]; then echo "nonhcl reach: all checks hold"; else echo "nonhcl reach: $fails failed"; exit 1; fi
