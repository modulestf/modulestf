#!/bin/bash
# Self-check for the pull request review skill's references/nonhcl-reach.sh, the evidence of a change
# outside Terraform (verdict.md, Changes outside Terraform), on throwaway git repositories: the
# module profile's reach file (its grammar, the repository it names, a directory holding a changed
# file or absent at the head), the test files at the merge base that import or name the changed file,
# the workflow that runs them on a pull request and each shape that leaves no evidence, the module
# root prefix, and a negative self-check on mutated copies. No network. Needs bash, git, jq and perl.
# Run: tests/nonhcl-reach-test.sh
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
NR="$SRC/.agents/skills/terraform-module-pr-review/references/nonhcl-reach.sh"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/nonhcl-reach-test.XXXXXX")" && pwd -P)" && [ -n "$TMP" ] || { echo "FAIL no temporary directory"; exit 1; }
[ -n "${KEEP:-}" ] || trap 'rm -rf "$TMP"' EXIT
fails=0
check() { if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

WF='name: Tests
on:
  pull_request:
    branches: [master]
jobs:
  tests:
    name: Test with Python ${{ matrix.python_version }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Run pytest
        run: |
          python -m pytest -vvv tests/'
TEST='import os
from unittest.mock import Mock

from package import BuildPlanManager


def test_one():
    assert BuildPlanManager'

# repo name [, setup function run in the base tree] -> a repository with a base and a head commit;
# the head edits package.py. Sets R, B (base) and H (head).
repo() {
  R="$TMP/$1"; rm -rf "$R"; mkdir -p "$R/tests" "$R/.github/workflows" "$R/examples/container-image" "$R/examples/build-package"
  git -C "$R" init -q -b master
  printf 'print("a")\n' > "$R/package.py"
  printf '%s\n' "$TEST" > "$R/tests/test_zip_source.py"
  printf '%s\n' "$WF" > "$R/.github/workflows/test.yml"
  printf 'module "a" {}\n' > "$R/examples/container-image/main.tf"
  printf 'module "b" {}\n' > "$R/examples/build-package/main.tf"
  [ -z "${2-}" ] || (cd "$R" && "$2")
  git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@example.com commit -qm base
  B="$(git -C "$R" rev-parse HEAD)"
  printf 'print("b")\n' > "$R/package.py"
  [ -z "${3-}" ] || (cd "$R" && "$3")
  git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@example.com commit -qm head
  H="$(git -C "$R" rev-parse HEAD)"
}
REACH="$TMP/nonhcl-reach.txt"
printf '# comment\nnot-run example/terraform-aws-lambda package.py examples/container-image\nnot-run other/repo package.py examples/build-package\n' > "$REACH"
jq -n '{schema_version: 1, capped: 0, triggers: [{id: "T-001", file: "package.py", line: 1, category: "non-hcl-dependency"}]}' > "$TMP/beh.json"
jq -n '[{filename: "package.py", status: "modified"}]' > "$TMP/files.json"
# run [extra args] -> OUT, ST
run() {
  OUT="$(bash "$NR" --git "$R" --head "$H" --base "$B" --repo example/terraform-aws-lambda \
    --behaviour "${BEH:-$TMP/beh.json}" --files "${FILES:-$TMP/files.json}" --reach "${RF-$REACH}" --base-ref master "$@" 2> /dev/null)"; ST=$?
}
un() { jq -c '.files[0].unreached' <<< "$OUT"; }
tb() { jq -c '.files[0].tested_by' <<< "$OUT"; }

t_lambda() {
  repo lambda; run
  [ "$ST" = 0 ] && [ "$(un)" = '["examples/container-image"]' ] && [ "$(tb)" = '["tests/test_zip_source.py"]' ] \
    && [ "$(jq -r '.head_sha + " " + .base_sha + " " + .files[0].file' <<< "$OUT")" = "$H $B package.py" ]
}
t_lambda; check "a lambda-like change: the profile's example and the test file under the pytest workflow" $?
t_noreach() { repo noreach; RF="$TMP/absent.txt" run; [ "$ST" = 0 ] && [ "$(un)" = '[]' ] && [ "$(tb)" = '["tests/test_zip_source.py"]' ]; }
t_noreach; check "no reach file: nothing unreached, the tests still read" $?
t_badreach() {
  repo badreach; printf 'not-run example/terraform-aws-lambda package.py\n' > "$TMP/bad.txt"
  RF="$TMP/bad.txt" run; [ "$ST" = 1 ] && [ -z "$OUT" ]
}
t_badreach; check "a reach line outside the grammar refuses the whole file" $?
t_climb() {
  repo climb; printf 'not-run example/terraform-aws-lambda package.py examples/../x\n' > "$TMP/climb.txt"
  RF="$TMP/climb.txt" run; [ "$ST" = 1 ]
}
t_climb; check "a reach directory that climbs out refuses the whole file" $?
t_link() { repo link; ln -sf "$REACH" "$TMP/link.txt"; RF="$TMP/link.txt" run; [ "$ST" = 1 ]; }
t_link; check "a reach file that is a link is refused" $?
t_other() { repo other; OUT="$(bash "$NR" --git "$R" --head "$H" --base "$B" --repo other/thing --behaviour "$TMP/beh.json" --files "$TMP/files.json" --reach "$REACH" --base-ref master)"; [ "$(jq -c '.files[0].unreached' <<< "$OUT")" = '[]' ]; }
t_other; check "a reach line of another repository clears nothing" $?
chg_ex() { printf 'module "a" { x = 1 }\n' > examples/container-image/main.tf; }
t_changed() {
  repo changed "" chg_ex
  jq -n '[{filename: "package.py", status: "modified"}, {filename: "examples/container-image/main.tf", status: "modified"}]' > "$TMP/f2.json"
  FILES="$TMP/f2.json" run; [ "$ST" = 0 ] && [ "$(un)" = '[]' ]
}
t_changed; check "a profile directory that holds a changed file is not unreached" $?
rm_ex() { rm -rf examples/container-image; }
t_gone() { repo gone "" rm_ex; run; [ "$ST" = 0 ] && [ "$(un)" = '[]' ]; }
t_gone; check "a profile directory absent at the head is not unreached" $?
wf_set() { printf '%s\n' "$WFX" > .github/workflows/test.yml; }
wf_case() { # name, workflow text -> holds when no test file is evidence
  WFX="$2"; repo "$1" wf_set; run; [ "$ST" = 0 ] && [ "$(tb)" = '[]' ]
}
t_paths() { wf_case paths "${WF/    branches: \[master\]/    paths: [\"**.py\"]}"; }
t_paths; check "a workflow with a paths filter is no evidence" $?
t_if() { wf_case if "${WF/        run: |/        if: github.actor != 'x'
        run: |}"; }
t_if; check "a workflow with an if is no evidence" $?
t_coe() { wf_case coe "${WF/    runs-on: ubuntu-latest/    runs-on: ubuntu-latest
    continue-on-error: true}"; }
t_coe; check "a workflow that may fail green is no evidence" $?
t_wd() { wf_case wd "${WF/        run: |/        working-directory: sub
        run: |}"; }
t_wd; check "a workflow with a working directory is no evidence" $?
t_target() { wf_case target "${WF/  pull_request:/  pull_request_target:}"; }
t_target; check "a pull_request_target workflow is no evidence" $?
t_otherdir() { wf_case otherdir "${WF/pytest -vvv tests\//pytest -vvv other/}"; }
t_otherdir; check "a pytest run of another directory is no evidence" $?
t_branch() { wf_case branch "${WF/\[master\]/[main]}"; }
t_branch; check "a workflow for another base branch is no evidence" $?
t_nopy() { wf_case nopy "${WF/python -m pytest -vvv tests\//ruff format --check .}"; }
t_nopy; check "a lint job is no evidence" $?
t_comment() { wf_case comment "${WF/          python -m pytest -vvv tests\//          # python -m pytest -vvv tests\/
          echo none}"; }
t_comment; check "a pytest line in a comment is no evidence" $?
t_bare() { WFX="${WF/python -m pytest -vvv tests\//pytest -q}"; repo bare wf_set; run; [ "$(tb)" = '["tests/test_zip_source.py"]' ]; }
t_bare; check "pytest with no path covers every test file" $?
add_test() { printf 'from package import X\n' > tests/test_new.py; }
rm_test() { printf 'x = 1\n' > tests/test_zip_source.py; }
t_headonly() { repo headonly rm_test add_test; run; [ "$ST" = 0 ] && [ "$(tb)" = '[]' ]; }
t_headonly; check "a test file only at the head is no evidence" $?
cmt_test() { printf '# from package import X\nx = 1\n' > tests/test_zip_source.py; }
t_cmt() { repo cmt cmt_test; run; [ "$ST" = 0 ] && [ "$(tb)" = '[]' ]; }
t_cmt; check "an import in a comment is no evidence" $?
sub_test() { printf 'import subprocess\nsubprocess.run(["python3", "package.py"])\n' > tests/test_zip_source.py; }
t_runs() { repo runs sub_test; run; [ "$(tb)" = '["tests/test_zip_source.py"]' ]; }
t_runs; check "a test that runs the file by name is evidence" $?
near_test() { printf 'from test_package import X\nopen("my_package.py")\n' > tests/test_zip_source.py; }
t_near() { repo near near_test; run; [ "$(tb)" = '[]' ]; }
t_near; check "a longer name that contains the file's is no evidence" $?
new_file() { rm package.py; }
t_newfile() {
  repo newfile new_file; run; [ "$ST" = 0 ] && [ "$(tb)" = '[]' ]
}
t_newfile; check "a file absent at the merge base has no test evidence" $?
to_sub() { mkdir sub && mv package.py sub/; }
t_prefix() {
  repo prefix to_sub
  printf 'not-run example/terraform-aws-lambda sub/package.py examples/container-image\n' > "$TMP/sub.txt"
  RF="$TMP/sub.txt" run --prefix sub; [ "$ST" = 0 ] && [ "$(un)" = '["examples/container-image"]' ] && [ "$(jq -r '.files[0].file' <<< "$OUT")" = package.py ]
}
t_prefix; check "under a module root prefix the reach file names repository paths" $?
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
mutate "a paths filter allowed" 's/\(paths\|paths-ignore\|/(/' t_paths
mutate "an if allowed" 's/\|if\|working-directory/|working-directory/' t_if
mutate "continue-on-error allowed" 's/\|continue-on-error\)/)/' t_coe
mutate "pull_request_target read as pull_request" 's/pull_request\(\[\^A-Za-z0-9_-\]\|\$\)/pull_request/' t_target
mutate "the branch filter not read" 's/\[ -n "\$base_ref" \] && printf .*\|\| continue/:/' t_branch
mutate "the pytest target not read" 's/\[ "\$a" = \. \] \|\| /true || /' t_otherdir
mutate "test files read at the head" 's/blob "\$base" "\$t"/blob "\$head" "\$t"/; s/ls-tree -r --name-only "\$base" -- tests/ls-tree -r --name-only "\$head" -- tests/' t_headonly
mutate "comments not dropped from tests" "s/grep -v '\\^\\[\\[:space:\\]\\]\\*#' \\| //; s/\\^\\[\\[:space:\\]\\]\\*\\(from/(from/" t_cmt
mutate "the changed directory guard dropped" 's/index\(\$0, d\) == 1 \{ f = 1 \}/0 { f = 1 }/' t_changed
mutate "the repository of a reach line not compared" 's/\[ "\$r" != "\$repo" \] \|\| maps=/maps=/' t_other
mutate "a malformed reach line skipped" 's/plain "\$f" && plain "\$d" \|\| die/plain "\$f" \&\& plain "\$d" || continue/' t_badreach
mutate "a reach link followed" 's/ && \[ ! -L "\$reach" \]//' t_link
mutate "the base existence of the file not required" 's/\[ "\$\(g cat-file -t "\$base:\$r" 2> \/dev\/null\)" = blob \]/true/' t_newfile

echo
if [ "$fails" -eq 0 ]; then echo "nonhcl reach: all checks hold"; else echo "nonhcl reach: $fails failed"; exit 1; fi
