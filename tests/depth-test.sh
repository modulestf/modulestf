#!/bin/bash
# Self-check for references/depth.sh of terraform-module-pr-review: the binding (head, base, merge
# base, diff hash), verify on a moved head or a changed hash, escalate, the owner raise, hostile file
# names kept as data, the merge base ambiguity abort, and mtf-facts missing, failing, late, refused
# or on a path under the clone. mtf-facts is a stub that prints fixture JSON in the shape of
# `mtf-facts depth`. A negative self-check mutates temp copies and confirms each one is caught.
# No network. Needs bash, git, jq and perl.
# Run: tests/depth-test.sh (DEPTH_TEST_SHELL=zsh or /bin/bash to run the script under that shell)
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
REF="$SRC/.agents/skills/terraform-module-pr-review/references"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/depth-test.XXXXXX")" && pwd -P)" && [ -n "$TMP" ] || { echo "FAIL no temporary directory"; exit 1; }
[ -n "${KEEP:-}" ] || trap 'rm -rf "$TMP"' EXIT
fails=0
DS="$REF/depth.sh" # the script under test; the self-check swaps in mutated copies
SH="${DEPTH_TEST_SHELL:-bash}" # bash or zsh: the script runs the same under both
check() { if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
export GIT_CONFIG_NOSYSTEM=1 HOME="$TMP/home"; mkdir -p "$HOME"
G() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main -c commit.gpgsign=false "$@"; }

# --- Fixtures: a run directory whose name is hostile too, a clone with a base branch and a head
# branch from one merge base, the head adding files with hostile names, and the base worktree.
RUN="$TMP/run \$(touch pwned);x"
mkdir -p "$RUN" "$TMP/bin" "$TMP/cwd"
C="$RUN/clone"
G init -q "$C"
printf 'one\n' > "$C/README.md"; G -C "$C" add -A; G -C "$C" commit -qm base
MB="$(git -C "$C" rev-parse HEAD)"
printf 'two\n' > "$C/CHANGELOG.md"; G -C "$C" add -A; G -C "$C" commit -qm main
BASE="$(git -C "$C" rev-parse HEAD)"
G -C "$C" checkout -q -b pr "$MB"
printf 'doc\n' > "$C/README.md"
printf '\000\001\002' > "$C/blob.bin"; printf 'x\n' > "$C/a;b.md"; printf 'x\n' > "$C/\$(touch pwned).md"; printf 'x\n' > "$C/new
line.md"; printf 'x\n' > "$C/--output=pwned.md"
G -C "$C" add -A; G -C "$C" commit -qm head
HEADSHA="$(git -C "$C" rev-parse HEAD)"
G -C "$C" worktree add -q --detach "$RUN/base" "$MB"
WANT_HASH="$(git -C "$C" diff --no-ext-diff --no-textconv --binary "$MB" "$HEADSHA" | shasum -a 256 | cut -d' ' -f1)"

# The pull request files list, hostile names included, as data.
jq -n '[{filename: "README.md", status: "modified", additions: 1, deletions: 1},
  {filename: "a;b.md", status: "added", additions: 1, deletions: 0},
  {filename: "$(touch pwned).md", status: "added", additions: 1, deletions: 0},
  {filename: "new\nline.md", status: "added", additions: 1, deletions: 0},
  {filename: "--output=pwned.md", status: "added", additions: 1, deletions: 0}]' > "$RUN/files.json"
echo '{"schema_version": 1, "inert": true}' > "$RUN/classify.json"
echo '{"examples": []}' > "$RUN/affected.json"
echo '{}' > "$RUN/affected-empty.json"

cat > "$TMP/bin/mtf-facts" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$STUB_ARGS"
case "${STUB_MODE:-ok}" in fail) exit 1 ;; slow) sleep 5 ;; junk) echo nope; exit 0 ;; esac
cat "$STUB_OUT"
EOF
chmod +x "$TMP/bin/mtf-facts"
export STUB_ARGS="$TMP/args.txt"
# The caller's PATH less every entry holding an mtf-facts, so only the stub can be found.
PATH0="$(printf '%s\n' "$PATH" | tr ':' '\n' | while IFS= read -r d; do [ -x "$d/mtf-facts" ] || printf '%s:' "$d"; done)"
PATH0="${PATH0%:}"
export PATH="$TMP/bin:$PATH0"

LIGHT="$TMP/light.json"
jq -n '{format: 1, depth: "light", reasons: ["light-docs-only"], checks_out_of_scope: ["A", "B", "D", "G-ladder"],
  examples_selected: ["examples/complete"], examples_out_of_scope: [], touched_types: [],
  walk: {complete: true, unwalked: 0}, limits: {tf_files: 0, changed_lines: 8, changed_blocks: 0, selected_examples: 1},
  schema_providers: [], schema_types: [], schema_locks: []}' > "$LIGHT"
FOCUSED="$TMP/focused.json"
jq '.depth = "focused" | .reasons = ["focused-within-limits"] | .checks_out_of_scope = ["B"]
  | .examples_out_of_scope = ["examples/other"] | .touched_types = ["aws_rds_cluster"]
  | .limits = {tf_files: 2, changed_lines: 20, changed_blocks: 1, selected_examples: 1}
  | .schema_providers = ["head:.:aws=hashicorp/aws:>=5.0", "base:.:aws=hashicorp/aws:>=4.0", "head:examples/complete:!constraint_unparsable"]
  | .schema_types = [".:resource:aws_rds_cluster:hashicorp/aws"] | .schema_locks = ["examples/complete:hashicorp/aws=5.1.0"]' \
  "$LIGHT" > "$FOCUSED"
export STUB_OUT="$LIGHT"

oc=0
# compute [extra args...]: one run into a fresh out file. Sets OUT, ST and MSG.
compute() {
  oc=$((oc + 1)); OUT="$RUN/depth-$oc.json"; rm -f "$STUB_ARGS"
  MSG="$(cd "$TMP/cwd" && "$SH" "$DS" compute --clone "$C" --base-tree "$RUN/base" --base "$BASE" \
    --files "$RUN/files.json" --classify "$RUN/classify.json" --affected "$RUN/affected.json" --out "$OUT" "$@" 2>&1)"; ST=$?
}
dj() { jq -r "$1" "$OUT" 2> /dev/null; }

# --- Binding.
t_bind() {
  compute
  [ "$ST" = 0 ] && [ "$(dj .depth)" = light ] && [ "$(dj '.reasons | join(",")')" = light-docs-only ] &&
    [ "$(dj .binding.head_sha)" = "$HEADSHA" ] && [ "$(dj .binding.base_sha)" = "$BASE" ] &&
    [ "$(dj .binding.merge_base)" = "$MB" ] && [ "$(dj .binding.diff_sha256)" = "$WANT_HASH" ]
}
t_bind; check "binding: head, base, merge base and the diff hash of git diff --binary" $?
L1="$OUT"
check "binding: mtf-facts got both trees and the files list as single arguments" "$(printf '%s\n' depth --head "$(cd "$C" && pwd -P)" --base "$(cd "$RUN/base" && pwd -P)" --files "$RUN/files.json" --classify "$RUN/classify.json" --affected "$RUN/affected.json" | cmp -s - "$STUB_ARGS"; echo $?)"
check "binding: the result line" "$([ "$MSG" = "depth: light (light-docs-only)" ]; echo $?)"
MSG="$("$SH" "$DS" compute --clone "$C" --base-tree "$RUN/base" --base "$BASE" --files "$RUN/files.json" --out "$L1" 2>&1)"
check "binding: compute refuses to overwrite" "$([ $? = 2 ] && jq -e '.depth == "light"' "$L1" > /dev/null; echo $?)"
STUB_OUT="$FOCUSED" compute; F1="$OUT"
check "binding: a focused object with schema tokens is kept" "$([ "$ST" = 0 ] && [ "$(dj .depth)" = focused ] && [ "$(dj '.schema_locks[0]')" = examples/complete:hashicorp/aws=5.1.0 ]; echo $?)"

# --- Hostile names: nothing ran, nothing was written outside the out file.
check "hostile names: no command substitution ran anywhere" "$([ -z "$(find "$TMP" -name pwned)" ]; echo $?)"
check "hostile names: the run directory name is data" "$([ -f "$L1" ]; echo $?)"

# --- Verify.
verify() { MSG="$("$SH" "$DS" verify "$1" --clone "$C" 2>&1)"; ST=$?; }
verify "$L1"; check "verify: an unchanged binding passes" "$([ "$ST" = 0 ] && [ "$MSG" = "depth verified: light" ]; echo $?)"
jq '.binding.diff_sha256 = ("0" * 64)' "$L1" > "$RUN/v-hash.json"
t_vhash() { verify "$RUN/v-hash.json"; [ "$ST" = 1 ] && printf '%s' "$MSG" | grep -qF 'diff hash differs'; }
t_vhash; check "verify: a changed diff hash aborts" $?
jq '.binding.merge_base = "'"$BASE"'"' "$L1" > "$RUN/v-mb.json"
verify "$RUN/v-mb.json"; check "verify: a changed merge base aborts" "$([ "$ST" = 1 ]; echo $?)"
jq '.extra = 1' "$L1" > "$RUN/v-key.json"; verify "$RUN/v-key.json"
check "verify: an unknown key is refused" "$([ "$ST" = 2 ]; echo $?)"
jq '.depth = "shallow"' "$L1" > "$RUN/v-val.json"; verify "$RUN/v-val.json"
check "verify: an unknown value is refused" "$([ "$ST" = 2 ]; echo $?)"
printf 'later\n' > "$C/later.md"; G -C "$C" add -A; G -C "$C" commit -qm later
t_vhead() { verify "$L1"; [ "$ST" = 1 ] && printf '%s' "$MSG" | grep -qF 'the head moved'; }
t_vhead; check "verify: a moved head aborts" $?
G -C "$C" reset -q --hard "$HEADSHA"
verify "$L1"; check "verify: back at the head it passes again" "$([ "$ST" = 0 ]; echo $?)"

# --- Escalate.
esc() { cp "$1" "$RUN/e.json"; MSG="$("$SH" "$DS" escalate "$RUN/e.json" "$2" 2>&1)"; ST=$?; }
t_esc() {
  esc "$F1" deep-validate-failed
  [ "$ST" = 0 ] && jq -e '.depth == "deep" and .reasons == ["deep-validate-failed"] and .checks_out_of_scope == []
    and .examples_out_of_scope == [] and .examples_selected == ["examples/complete", "examples/other"]' "$RUN/e.json" > /dev/null &&
    jq -e --slurpfile o "$F1" '.binding == $o[0].binding' "$RUN/e.json" > /dev/null
}
t_esc; check "escalate: focused to deep, nothing out of scope, the binding kept" $?
verify "$RUN/e.json"; check "escalate: the escalated file still verifies" "$([ "$ST" = 0 ] && [ "$MSG" = "depth verified: deep" ]; echo $?)"
esc "$F1" deep-schema-overflow; check "escalate: a schema-pass reason" "$([ "$ST" = 0 ] && [ "$(jq -r '.reasons[0]' "$RUN/e.json")" = deep-schema-overflow ]; echo $?)"
MSG="$("$SH" "$DS" escalate "$RUN/e.json" deep-validate-failed 2>&1)"
check "escalate: a deep file keeps its reasons and adds one" "$([ $? = 0 ] && jq -e '.reasons == ["deep-schema-overflow", "deep-validate-failed"]' "$RUN/e.json" > /dev/null; echo $?)"
for r in light-docs-only deep-bogus deep-schema-Bad_X 'deep-schema-$(touch pwned)' ""; do
  esc "$F1" "$r"
  check "escalate: refused reason '$r', the file unchanged" "$([ "$ST" = 2 ] && cmp -s "$F1" "$RUN/e.json"; echo $?)"
done

# --- Owner raise.
t_owner() { compute --owner-depth deep; [ "$ST" = 0 ] && [ "$(dj .depth)" = deep ] && [ "$(dj '.reasons | join(",")')" = deep-owner-raise ] && [ "$(dj '.checks_out_of_scope | length')" = 0 ]; }
t_owner; check "owner raise: depth: deep raises light to deep" $?
compute --owner-depth light; check "owner raise: any other value is refused, nothing written" "$([ "$ST" = 2 ] && [ ! -e "$OUT" ]; echo $?)"

# --- mtf-facts missing, failing, late, refused, or under the clone.
unavailable() { [ "$ST" = 0 ] && [ "$(dj .depth)" = deep ] && dj '.reasons[]' | grep -qx deep-classifier-unavailable && [ "$(dj .binding.head_sha)" = "$HEADSHA" ]; }
t_missing() { PATH="$PATH0" compute; unavailable; }
t_missing; check "tool missing: deep with deep-classifier-unavailable" $?
STUB_MODE=fail compute; check "tool failing: deep with deep-classifier-unavailable" "$(unavailable; echo $?)"
STUB_MODE=junk compute; check "tool output not JSON: deep with deep-classifier-unavailable" "$(unavailable; echo $?)"
DEPTH_TIMEOUT=1 STUB_MODE=slow compute; check "tool late: deep with deep-classifier-unavailable" "$(unavailable; echo $?)"
jq '.checks_out_of_scope += ["C"]' "$LIGHT" > "$TMP/bad-c.json"
STUB_OUT="$TMP/bad-c.json" compute; check "tool output refused: Check C out of scope at light" "$(unavailable; echo $?)"
jq '.checks_out_of_scope = ["A", "B"]' "$FOCUSED" > "$TMP/bad-a.json"
t_refused() { STUB_OUT="$TMP/bad-a.json" compute; unavailable; }
t_refused; check "tool output refused: Check A out of scope at focused" $?
jq '.limits.tf_files = 7 | .depth = "focused" | .reasons = ["focused-within-limits"] | .checks_out_of_scope = []' "$LIGHT" > "$TMP/bad-lim.json"
STUB_OUT="$TMP/bad-lim.json" compute; check "tool output refused: focused past the limits" "$(unavailable; echo $?)"
jq '.examples_out_of_scope = ["examples/complete"]' "$LIGHT" > "$TMP/bad-both.json"
STUB_OUT="$TMP/bad-both.json" compute; check "tool output refused: an example both selected and out of scope" "$(unavailable; echo $?)"
jq '.schema_locks = ["../x:hashicorp/aws=5.1.0"]' "$LIGHT" > "$TMP/bad-lock.json"
STUB_OUT="$TMP/bad-lock.json" compute; check "tool output refused: a lock token outside its pattern" "$(unavailable; echo $?)"
jq '.reasons = ["deep-owner-raise"] | .depth = "deep" | .checks_out_of_scope = []' "$LIGHT" > "$TMP/bad-r.json"
STUB_OUT="$TMP/bad-r.json" compute; check "tool output: a deep host token from mtf-facts is still deep" "$([ "$(dj .depth)" = deep ]; echo $?)"
t_inclone() { mkdir -p "$C/.bin"; cp "$TMP/bin/mtf-facts" "$C/.bin/mtf-facts"; PATH="$C/.bin:$PATH0" compute; rm -rf "$C/.bin"; unavailable && [ ! -e "$STUB_ARGS" ]; }
t_inclone; check "tool under the clone: never run, deep" $?
mkdir -p "$TMP/lbin"; ln -s "$C/.bin/mtf-facts" "$TMP/lbin/mtf-facts"
mkdir -p "$C/.bin"; cp "$TMP/bin/mtf-facts" "$C/.bin/mtf-facts"; PATH="$TMP/lbin:$PATH0" compute; check "tool linked into the clone: never run, deep" "$(unavailable && [ ! -e "$STUB_ARGS" ]; echo $?)"
mkdir -p "$TMP/cwd/rel"; cp "$TMP/bin/mtf-facts" "$TMP/cwd/rel/"
PATH="rel:$PATH0" compute; check "tool on a relative PATH entry: never run, deep" "$(unavailable && [ ! -e "$STUB_ARGS" ]; echo $?)"
rm -rf "$C/.bin"

# --- Classifier and affected outputs the host checks itself.
t_noclass() {
  oc=$((oc + 1)); OUT="$RUN/depth-$oc.json"
  MSG="$("$SH" "$DS" compute --clone "$C" --base-tree "$RUN/base" --base "$BASE" --files "$RUN/files.json" \
    --classify "$RUN/no-such.json" --affected "$RUN/affected.json" --out "$OUT" 2>&1)"; ST=$?
  [ "$ST" = 0 ] && [ "$(dj .depth)" = deep ] && [ "$(dj '.reasons | join(",")')" = deep-classifier-unavailable ]
}
t_noclass; check "classifier output missing: deep with deep-classifier-unavailable" $?
t_affempty() {
  oc=$((oc + 1)); OUT="$RUN/depth-$oc.json"
  MSG="$("$SH" "$DS" compute --clone "$C" --base-tree "$RUN/base" --base "$BASE" --files "$RUN/files.json" \
    --classify "$RUN/classify.json" --affected "$RUN/affected-empty.json" --out "$OUT" 2>&1)"; ST=$?
  [ "$ST" = 0 ] && [ "$(dj .depth)" = deep ] && [ "$(dj '.reasons | join(",")')" = deep-affected-fallback ]
}
t_affempty; check "affected output {}: deep with deep-affected-fallback" $?

# --- The merge base: one result of git merge-base --all, or the run aborts.
X="$TMP/cross/clone"; G init -q "$X"
printf 'a\n' > "$X/f"; G -C "$X" add -A; G -C "$X" commit -qm a
G -C "$X" checkout -q -b x; printf 'b\n' > "$X/b"; G -C "$X" add -A; G -C "$X" commit -qm b; XB="$(git -C "$X" rev-parse HEAD)"
G -C "$X" checkout -q -b y main; printf 'c\n' > "$X/c"; G -C "$X" add -A; G -C "$X" commit -qm c; XC="$(git -C "$X" rev-parse HEAD)"
G -C "$X" checkout -q x; G -C "$X" merge -q --no-edit "$XC"; XM1="$(git -C "$X" rev-parse HEAD)"
G -C "$X" checkout -q y; G -C "$X" merge -q --no-edit "$XB"
G -C "$X" worktree add -q --detach "$TMP/cross/base" "$XB"
t_cross() {
  OUT="$TMP/cross/depth.json"
  MSG="$("$SH" "$DS" compute --clone "$X" --base-tree "$TMP/cross/base" --base "$XM1" --files "$RUN/files.json" \
    --classify "$RUN/classify.json" --affected "$RUN/affected.json" --out "$OUT" 2>&1)"; ST=$?
  [ "$ST" = 1 ] && [ ! -e "$OUT" ] && printf '%s' "$MSG" | grep -qF 'more than one result'
}
check "merge base: two results of git merge-base --all abort, nothing written" "$([ "$(git -C "$X" merge-base --all "$XM1" HEAD | wc -l | tr -d ' ')" = 2 ] && t_cross; echo $?)"
O="$TMP/orphan"; G init -q "$O"; printf 'z\n' > "$O/z"; G -C "$O" add -A; G -C "$O" commit -qm z
G -C "$C" fetch -q "$O" main 2> /dev/null; ORPH="$(git -C "$O" rev-parse HEAD)"
oc=$((oc + 1)); MSG="$("$SH" "$DS" compute --clone "$C" --base-tree "$RUN/base" --base "$ORPH" --files "$RUN/files.json" --out "$RUN/depth-$oc.json" 2>&1)"
check "merge base: none aborts, nothing written" "$([ $? = 1 ] && [ ! -e "$RUN/depth-$oc.json" ]; echo $?)"
oc=$((oc + 1)); MSG="$("$SH" "$DS" compute --clone "$C" --base-tree "$C" --base "$BASE" --files "$RUN/files.json" --out "$RUN/depth-$oc.json" 2>&1)"
check "merge base: a base tree not at the merge base aborts" "$([ $? = 1 ] && [ ! -e "$RUN/depth-$oc.json" ]; echo $?)"
oc=$((oc + 1)); MSG="$("$SH" "$DS" compute --clone "$C" --base-tree "$RUN/base" --base "$(printf 'f%.0s' $(seq 40))" --files "$RUN/files.json" --out "$RUN/depth-$oc.json" 2>&1)"
check "merge base: a base the clone does not hold aborts" "$([ $? = 1 ]; echo $?)"

# --- A git diff that fails aborts compute and verify, never hashing its error.
D="$TMP/broken/clone"; G init -q "$D"
printf 'a\n' > "$D/a"; G -C "$D" add -A; G -C "$D" commit -qm a; DMB="$(git -C "$D" rev-parse HEAD)"
G -C "$D" checkout -q -b pr; printf 'gone\n' > "$D/b"; G -C "$D" add -A; G -C "$D" commit -qm b
G -C "$D" worktree add -q --detach "$TMP/broken/base" "$DMB"
dcompute() { MSG="$("$SH" "$DS" compute --clone "$D" --base-tree "$TMP/broken/base" --base "$DMB" --files "$RUN/files.json" \
  --classify "$RUN/classify.json" --affected "$RUN/affected.json" --out "$1" 2>&1)"; ST=$?; }
dcompute "$TMP/broken/ok.json"; check "broken diff: compute on the intact clone" "$([ "$ST" = 0 ]; echo $?)"
BLOB="$(git -C "$D" rev-parse HEAD:b)"; rm -f "$D/.git/objects/${BLOB:0:2}/${BLOB:2}"
t_brokendiff() {
  dcompute "$TMP/broken/x.json"
  [ "$ST" = 1 ] && [ ! -e "$TMP/broken/x.json" ] && printf '%s' "$MSG" | grep -qF 'git diff failed' &&
    MSG="$("$SH" "$DS" verify "$TMP/broken/ok.json" --clone "$D" 2>&1)" ; [ $? = 1 ] && printf '%s' "$MSG" | grep -qF 'git diff failed'
}
check "broken diff: the blob is gone" "$( ! git -C "$D" cat-file -e "$BLOB" 2> /dev/null; echo $?)"
t_brokendiff; check "broken diff: a missing blob aborts compute and verify (exit 1), nothing written" $?

# --- Usage.
for a in "compute --clone rel" "verify" "escalate" "bogus"; do
  set -f; MSG="$("$SH" "$DS" $a 2>&1)"; s=$?; set +f
  check "usage: '$a' is exit 2" "$([ $s = 2 ]; echo $?)"
done
check "script: no eval, no bash -c, no sh -c" "$(! grep -nE '(^|[^a-z_])eval( |$)|bash -c|sh -c' "$REF/depth.sh" > /dev/null; echo $?)"

# --- The reason tokens: depth.md lists exactly the tokens of render-comment.jq.
t_tokens() {
  awk '/^## Reason Tokens$/ { on = 1; next } on && /^## / { exit } on && /^- `[a-z-]+`$/' "$REF/depth.md" |
    sed 's/^- `//; s/`$//' > "$TMP/doc-tokens.txt" &&
  jq -nr -L "$(dirname "$DS")" 'include "render-comment"; depth_reasons[], depth_host_reasons[]' | cmp -s - "$TMP/doc-tokens.txt" &&
  [ "$(wc -l < "$TMP/doc-tokens.txt")" -ge 30 ]
}
t_tokens; check "tokens: depth.md lists the tokens of render-comment.jq, in order" $?

# --- Negative self-check: each mutation of a temp copy must make its named case fail.
mutate() { # name, perl substitution, case function
  local d="$TMP/mut-$oc"; oc=$((oc + 1)); mkdir -p "$d"; cp "$REF/depth.sh" "$REF/render-comment.jq" "$d/"
  perl -0pi -e "$2" "$d/depth.sh" "$d/render-comment.jq"
  if cmp -s "$d/depth.sh" "$REF/depth.sh" && cmp -s "$d/render-comment.jq" "$REF/render-comment.jq"; then
    check "self-check: $1 (the mutation changed nothing)" 1; return
  fi
  local keep="$DS" before="$fails"; DS="$d/depth.sh"
  "$3" > /dev/null 2>&1; local s=$?
  DS="$keep"; fails="$before"
  check "self-check: $1 is caught" "$([ "$s" != 0 ]; echo $?)"
}
mutate "the diff hash without --binary" 's/ --binary "\$2"/ "\$2"/' t_bind
mutate "verify skips the hash" 's/\[ "\$hash" = "\$\(jq -r \.binding\.diff_sha256 "\$file"\)" \] \|\|/true ||/' t_vhash
mutate "verify skips the head" 's/\[ "\$head" = "\$\(jq -r \.binding\.head_sha "\$file"\)" \] \|\|/true ||/' t_vhead
mutate "several merge bases accepted" 's/\[ "\$\(printf .%s\\n. "\$all" \| grep -c \.\)" = 1 \] \|\|/true ||/' t_cross
mutate "escalate keeps examples out of scope" 's/\| \.examples_out_of_scope = \[\];/;/' t_esc
mutate "the owner raise ignored" 's/\[ -n "\$owner" \] && raise=/[ -n "" ] \&\& raise=/' t_owner
mutate "a failed tool kept its result" "s/\\[ \"\\\$st\" = ok \\] \\|\\| raise='\\[\"deep-classifier-unavailable\"\\]'//" t_missing
mutate "the fixed scope table not checked" 's/and \(\.depth as \$d \| \.checks_out_of_scope - depth_scope\[\$d\] == \[\]\)//' t_refused
mutate "a tool under the clone run" 's/for d in "\$@"; do case "\$f\/" in "\$d"\/\*\) return 0 ;; esac; done//' t_inclone
mutate "a missing classifier not raised" 's/\|\| raise="\$\(jq -c .\. \+ \["deep-classifier-unavailable"\]. <<< "\$raise"\)"\n//' t_noclass
mutate "an empty affected output accepted" 's/ and \. != \{\}//' t_affempty
mutate "a failed git diff hashed" 's/> "\$f" 2> \/dev\/null && h=/> "\$f" 2> \/dev\/null; h=/' t_brokendiff
mutate "a token dropped from the list" 's/"deep-policy", //' t_tokens

echo
if [ "$fails" -eq 0 ]; then echo "depth: all checks hold"; else echo "depth: $fails failed"; exit 1; fi
