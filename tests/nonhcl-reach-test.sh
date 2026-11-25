#!/bin/bash
# Self-check for the pull request review skill's references/nonhcl-reach.sh, the evidence of a change
# outside Terraform (verdict.md, Changes outside Terraform), on throwaway git repositories: the
# module profile's reach file (its grammar, the repository it names, a link) and the guard of each
# line at the head and the merge base (every module call whose source is the module root sets the
# argument to the literal, the same module calls at both revisions, no .tf file naming the changed
# file, a tree of regular .tf files, a directory absent or holding a changed file), the module call
# reader (a heredoc skipped, a block comment, an interpolated source, a non-literal value), the module
# root prefix, a partial clone, and a negative self-check on mutated copies. No network. Needs bash,
# git, jq and perl.
# Run: tests/nonhcl-reach-test.sh
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
NR="$SRC/.agents/skills/terraform-module-pr-review/references/nonhcl-reach.sh"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/nonhcl-reach-test.XXXXXX")" && pwd -P)" && [ -n "$TMP" ] || { echo "FAIL no temporary directory"; exit 1; }
[ -n "${KEEP:-}" ] || trap 'rm -rf "$TMP"' EXIT
fails=0
check() { if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

CI_TF='module "lambda_function" {
  source = "../../"

  function_name  = "x"
  create_package = false
  image_uri      = "${path.module}/x"
}

module "docker_build" {
  source = "../../modules/docker-build"
}

resource "aws_cloudwatch_event_rule" "r" {
  event_pattern = <<EOF
{ "source": ["module \"x\" {"] }
EOF
}'
BP_TF='module "package_dir" {
  source = "../../"

  source_path = "${path.module}/src"
}'

# repo name [, base setup [, head setup]] -> a repository with a base and a head commit; the head
# edits package.py and runs its setup function. Sets R, B (base) and H (head).
repo() {
  R="$TMP/$1"; rm -rf "$R"; mkdir -p "$R/examples/container-image" "$R/examples/build-package"
  git -C "$R" init -q -b master
  printf 'print("a")\n' > "$R/package.py"
  printf '%s\n' "$CI_TF" > "$R/examples/container-image/main.tf"
  printf '%s\n' "$BP_TF" > "$R/examples/build-package/main.tf"
  [ -z "${2-}" ] || (cd "$R" && "$2")
  git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@example.com commit -qm base
  B="$(git -C "$R" rev-parse HEAD)"
  printf 'print("b")\n' > "$R/package.py"
  [ -z "${3-}" ] || (cd "$R" && "$3")
  git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@example.com commit -qm head
  H="$(git -C "$R" rev-parse HEAD)"
}
REACH="$TMP/nonhcl-reach.txt"
printf '# comment\nnot-run example/terraform-aws-lambda package.py examples/container-image root-calls create_package=false
not-run example/terraform-aws-lambda package.py examples/build-package root-calls create_package=false
not-run other/repo package.py examples/build-package root-calls create_package=false\n' > "$REACH"
jq -n '{schema_version: 1, capped: 0, triggers: [{id: "T-001", file: "package.py", line: 1, category: "non-hcl-dependency"}]}' > "$TMP/beh.json"
jq -n '[{filename: "package.py", status: "modified"}]' > "$TMP/files.json"
# run [extra args] -> OUT, ST
run() {
  OUT="$(bash "$NR" --git "$R" --head "$H" --base "$B" --repo "${REPO:-example/terraform-aws-lambda}" \
    --behaviour "$TMP/beh.json" --files "${FILES:-$TMP/files.json}" --reach "${RF-$REACH}" "$@" 2> /dev/null)"; ST=$?
}
un() { jq -c '.files[0].unreached' <<< "$OUT"; }
none() { run "$@"; [ "$ST" = 0 ] && [ "$(un)" = '[]' ]; }

t_lambda() {
  repo lambda; run
  [ "$ST" = 0 ] && [ "$(un)" = '["examples/container-image"]' ] \
    && [ "$(jq -r '.head_sha + " " + .base_sha + " " + .files[0].file' <<< "$OUT")" = "$H $B package.py" ]
}
t_lambda; check "the guard holds at both revisions: the example is unreached; a root call without the literal is not" $?
t_noreach() { repo noreach; RF="$TMP/absent.txt" none; }
t_noreach; check "no reach file: nothing unreached" $?
bad_reach() { # name, line -> holds when the reach file is refused whole
  repo "$1"; printf '%s\n' "$2" > "$TMP/$1.txt"; RF="$TMP/$1.txt" run; [ "$ST" = 1 ] && [ -z "$OUT" ]
}
t_badreach() { bad_reach badreach 'not-run example/terraform-aws-lambda package.py examples/container-image'; }
t_badreach; check "a reach line with no guard refuses the whole file" $?
t_badguard() { bad_reach badguard 'not-run example/terraform-aws-lambda package.py examples/container-image root-calls create_package=var.x'; }
t_badguard; check "a guard literal outside the grammar refuses the whole file" $?
t_climb() { bad_reach climb 'not-run example/terraform-aws-lambda package.py examples/../x root-calls create_package=false'; }
t_climb; check "a reach directory that climbs out refuses the whole file" $?
t_link() { repo link; ln -sf "$REACH" "$TMP/link.txt"; RF="$TMP/link.txt" run; [ "$ST" = 1 ]; }
t_link; check "a reach file that is a link is refused" $?
t_other() { repo other; REPO=other/thing none; }
t_other; check "a reach line of another repository clears nothing" $?
chg_ex() { printf '# x\n' >> examples/container-image/main.tf; }
t_changed() {
  repo changed "" chg_ex
  jq -n '[{filename: "package.py", status: "modified"}, {filename: "examples/container-image/main.tf", status: "modified"}]' > "$TMP/f2.json"
  FILES="$TMP/f2.json" none
}
t_changed; check "an example that holds a changed file is not unreached" $?
rm_ex() { rm -rf examples/container-image; }
t_gone() { repo gone "" rm_ex; none; }
t_gone; check "an example absent at the head is not unreached" $?
flip() { perl -pi -e 's/create_package = false/create_package = true/' examples/container-image/main.tf; }
t_headtrue() { repo headtrue "" flip; none; }
t_headtrue; check "a guard that fails at the head clears nothing" $?
unflip() { perl -pi -e 's/create_package = true/create_package = false/' examples/container-image/main.tf; }
t_basetrue() { repo basetrue flip unflip; none; }
t_basetrue; check "a guard that fails at the merge base clears nothing" $?
add_call() { printf 'module "extra" {\n  source = "../../modules/other"\n}\n' >> examples/container-image/main.tf; }
t_newcall() { repo newcall "" add_call; none; }
t_newcall; check "a module call the head adds makes the line stale" $?
var_val() { perl -pi -e 's/create_package = false/create_package = var.create_package/' examples/container-image/main.tf; }
t_var() { repo var "" var_val; none; }
t_var; check "a value that is no literal fails the guard" $?
interp() { perl -pi -e 's|source = "../../"$|source = "\${path.module}/../../"|' examples/container-image/main.tf; }
t_interp() { repo interp interp; none; }
t_interp; check "a source that is no plain string makes the line stale" $?
blockc() { perl -0pi -e 's|  create_package = false\n|  /*\n  create_package = false\n  */\n|' examples/container-image/main.tf; }
t_blockc() { repo blockc blockc; none; }
t_blockc; check "a block comment makes the line stale" $?
names() { printf 'locals {\n  p = "package.py"\n}\n' >> examples/container-image/main.tf; }
t_names() { repo names names; none; }
t_names; check "an example that names the changed file is not unreached" $?
json() { printf '{}\n' > examples/container-image/extra.tf.json; }
t_json() { repo json json; none; }
t_json; check "a .tf.json file in the example makes the line stale" $?
lnk() { ln -sf main.tf examples/container-image/alias.tf; }
t_lnk() { repo lnk lnk; none; }
t_lnk; check "a .tf file that is a link makes the line stale" $?
openhd() { printf 'x = <<EOT\nopen\n' >> examples/container-image/main.tf; }
t_openhd() { repo openhd openhd; none; }
t_openhd; check "a heredoc that does not end makes the line stale" $?
to_sub() {
  mkdir sub && mv package.py sub/
  perl -pi -e 's|source = "../../"$|source = "../../sub"|' examples/container-image/main.tf
}
t_prefix() {
  repo prefix to_sub
  printf 'not-run example/terraform-aws-lambda sub/package.py examples/container-image root-calls create_package=false\n' > "$TMP/sub.txt"
  RF="$TMP/sub.txt" run --prefix sub; [ "$ST" = 0 ] && [ "$(un)" = '["examples/container-image"]' ] && [ "$(jq -r '.files[0].file' <<< "$OUT")" = package.py ]
}
t_prefix; check "under a module root prefix the reach file names repository paths and the root is the prefix" $?
to_sub_bare() { to_sub; perl -pi -e 's/^  create_package = false\n//' examples/container-image/main.tf; }
t_prefixguard() {
  repo prefixguard to_sub_bare
  printf 'not-run example/terraform-aws-lambda sub/package.py examples/container-image root-calls create_package=false\n' > "$TMP/sub.txt"
  RF="$TMP/sub.txt" none --prefix sub
}
t_prefixguard; check "under a prefix a call of the module root without the literal fails the guard" $?
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
mutate "the guard not read at the head" 's/hc="\$\(guard_at "\$head"/hc="\$(guard_at "\$base"/' t_headtrue
mutate "the guard not read at the merge base" 's/bc="\$\(guard_at "\$base" "\$md" "\$r" "\$ma"\)" \|\| continue/bc="\$hc"/' t_basetrue
mutate "a new module call not compared" 's/\[ "\$hc" = "\$bc" \] \|\| continue/:/' t_newcall
mutate "the literal not compared" 's/ \|\| \[ "\$val" = "\$want" \] \|\| return 1/ || true/' t_headtrue
mutate "a non-literal value taken" 's/val = \(v ~ \/\^\(false\|true\|null\|\[0-9\]\+\)\$\/\) \? v : "\?"/val = v; sub(\/^var\\..*\/, "false", val)/' t_var
mutate "the changed directory guard dropped" 's/index\(\$0, d\) == 1 \{ f = 1 \}/0 { f = 1 }/' t_changed
mutate "the repository of a reach line not compared" 's/\[ "\$r" != "\$repo" \] \|\| maps=/maps=/' t_other
mutate "a malformed reach line skipped" 's/\[\[ "\$\{ga-\}" =~ (\S+) \]\] \|\| die/[[ "\${ga-}" =~ $1 ]] || continue/' t_badreach
mutate "a reach link followed" 's/ && \[ ! -L "\$reach" \]//' t_link
mutate "a name of the changed file not read" 's/! printf .%s\\n. "\$t" \| grep -Fq -- "\$\{f##\*\/\}" \|\| return 1/:/' t_names
mutate "a .tf.json file taken" 's/\*\.tf\.json\) return 1 ;; //' t_json
mutate "a linked .tf file taken" 's/\[ "\$mode" = 100644 \] && //' t_lnk
mutate "a block comment taken" 's/if \(code ~ \/\\\/\\\*\/\) bad\(\)//' t_blockc
mutate "an interpolated source taken" 's/=\[\[:space:\]\]\*"\[\^"\$\]\*"/=[[:space:]]*"[^"]*"/' t_interp
mutate "an open heredoc taken" 's/ \|\| tag != ""\)\) print "stale"/)) print "stale"/' t_openhd
mutate "a heredoc read as code" 's/tag != "" \{ t = line;/0 { t = line;/' t_lambda
mutate "the module root taken as the repository root under a prefix" 's/root="\$\{prefix:-\.\}"/root="."/' t_prefixguard
mutate "a partial clone read" 's/\[ -z "\$\(g config --get extensions\.partialclone 2> \/dev\/null\)" \] \|\| die/:/' t_partial

echo
if [ "$fails" -eq 0 ]; then echo "nonhcl reach: all checks hold"; else echo "nonhcl reach: $fails failed"; exit 1; fi
