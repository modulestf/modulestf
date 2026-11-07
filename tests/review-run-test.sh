#!/bin/bash
# shellcheck disable=SC2319 # "$(<test>; echo $?)" passes the test's own status to check
# Self-check for the pull request review skill's references/review-run.sh, the run script on
# top of host-pass.sh and the pass scripts. No network: gh, terraform and mtf-facts are stubbed,
# the clone comes from a local bare repository through a test-only git url rewrite, and the
# depth, schema, ladder and behaviour scripts are stubbed in a copy of the skill (each has its
# own test). It checks:
#   - acceptance: from the synthetic fixture in tests/review-run-fixture (archived inputs of a
#     real run with every name replaced), handover reproduces the hand-assembled task and
#     record, and render reproduces the current renderer's comment byte for byte;
#   - prepare, verify, plan, ladder, handover and render end to end on a light change, with a
#     title holding $(touch x), a branch name holding a newline and files named a;b and $(touch x);
#   - each subcommand prints at most 30 lines, index.json holds no host prose;
#   - the baseline defects: the Write short line, mergeability not-applicable on a merged
#     pull request, the posting login's own review left out of a render-only run, several
#     module roots resolved by the prefix rule or refused with a fixed reason;
#   - the closing issues' text: kind=issue items by origin, the 4000 byte cut and its entry, one issue
#     named twice read once, and a cross-repository reference, a third issue or a failed read adding nothing;
#   - a failed validate at light escalates, a schema escalation at focused escalates;
#   - the pr-review SKILL.md workflow move: the sentence multiset of SKILL.md and
#     references/workflow.md and references/inputs.md is the pinned one, navigation excluded,
#     and SKILL.md and the run guide stay within their size targets.
# Run: tests/review-run-test.sh
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
SKILL="$SRC/.agents/skills/terraform-module-pr-review"
FX="$SRC/tests/review-run-fixture"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/review-run-test.XXXXXX")" && pwd -P)" && [ -n "$TMP" ] || { echo "FAIL no temporary directory"; exit 1; }
trap 'chmod -R u+w "$TMP" 2> /dev/null; rm -rf "$TMP"' EXIT
fails=0
check() { # name, status (0 = holds)
  if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
q() { jq -e "$2" "$1" > /dev/null 2>&1; echo $?; }
lines_ok() { [ "$(wc -l < "$1" | tr -d ' ')" -le 30 ]; echo $?; }

# A copy of the skill with the scripts other parts own, or that need the network, stubbed.
SK="$TMP/skill/references"
mkdir -p "$TMP/skill"
cp -R "$SKILL/references" "$SK"
cp -R "$SRC/.agents/skills/terraform-module-reviewer" "$TMP/terraform-module-reviewer" # the bundle's sections
cat > "$SK/schema-pass.sh" <<'EOF'
#!/bin/bash
echo "schema $SCHEMA_DEPTH $*" >> "${STUB_LOG:?}"
echo "schema-env $SCHEMA_HEAD $SCHEMA_MERGE_BASE $(tr "\n" " " <<< "$SCHEMA_INPUTS")" >> "$STUB_LOG"
echo "schema-root $SCHEMA_ROOT" >> "$STUB_LOG"
src="schema pass: source modulestf/terraform-schema-mirror hashicorp_aws-v6.1.0 $(printf 'ab%.0s' $(seq 32))"
case "${SCHEMA_STUB:-overflow}" in
  ok) mkdir -p "$1"; echo "$src"; [ -z "${3-}" ] || { mkdir -p "$3"; echo '{}' | gzip -n > "$3/schema-handoff.json.gz"
      echo "schema pass: handoff written, 1 directories, 1 provider schemas"; }
    echo "schema pass: focused, mirror stub, 1 sheets, 10 bytes"; exit 0 ;;
  deeppartial) mkdir -p "$1"; echo '{"format": 1, "reasons": ["page"], "missing": []}' > "$1/missing.json"; echo "$src"
    echo "schema pass: deep partial page, 1 sheets, 10 bytes, 1 types without a sheet"; exit 0 ;;
  badsource) mkdir -p "$1"; echo "$src"; echo "schema pass: source modulestf/m x \$(touch x)"; echo "schema pass: focused"; exit 0 ;;
esac
[ -z "${3-}" ] || { mkdir -p "$3"; echo '{}' | gzip -n > "$3/schema-handoff.json.gz"; }
echo "schema pass: escalate overflow"; exit 3
EOF
cat > "$SK/plan-pass.sh" <<'EOF'
#!/bin/bash
# stub: g0 passes; plan leaves no record and exits PLAN_STUB_RC
echo "plan-pass $*" >> "${STUB_LOG:?}"
[ "$1" = g0 ] && exit 0
exit "${PLAN_STUB_RC:-1}"
EOF
cat > "$SK/ladder-pass.sh" <<'EOF'
#!/bin/bash
echo "ladder $*" >> "${STUB_LOG:?}"
[ "$1" = acquire ] && { echo "acquisition failed: stub"; exit 1; }
[ "$1" != run ] || [ -z "${EV_MARK:-}" ] || touch "$EV_MARK"
exit 0
EOF
cat > "$SK/behaviour-pass.sh" <<'EOF'
#!/bin/bash
echo "behaviour $*" >> "${STUB_LOG:?}"
while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
if [ -f "$out/behaviour.json" ] || [ -n "${EVAL:-}" ]; then
  echo '{"status": "ran", "reason": null, "triggers": [], "claims": [], "capped": 0}' > "$out/run-behaviour.json"
  echo 'behaviour: ran, 0 triggers, 0 over the cap' > "$out/record.txt"
else
  echo '{"schema_version": 1, "triggers": [], "capped": 0}' > "$out/behaviour.json"
fi
EOF

# The fake host: gh answers from files, terraform validates unless a marker says otherwise.
mkdir -p "$TMP/bin" "$TMP/gh"
export STUB_LOG="$TMP/stub.log" GHD="$TMP/gh"
: > "$STUB_LOG"
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/bash
# gh api stub: [-i] [--paginate] <endpoint|graphql> [-f/-F k=v]... [--jq expr]
shift # api
inc=false jqx="" ep="" query=""
while [ $# -gt 0 ]; do
  case "$1" in
    -i) inc=true ;; --paginate | --slurp) ;;
    --jq) jqx="$2"; shift ;;
    -f | -F) case "$2" in query=*) query="$2" ;; esac; shift ;;
    *) [ -n "$ep" ] || ep="$1" ;;
  esac
  shift
done
ep="${ep%%\?*}"
case "$ep" in
  user) f=user ;;
  graphql) case "$query" in *reviewThreads*) f=threads ;; *closingIssuesReferences*) f=closing ;; *) f=comments ;; esac ;;
  repos/*/pulls/*/files) f=files ;;
  repos/*/pulls/*/reviews) f=reviews ;;
  repos/*/pulls/*/comments) f=empty ;;
  repos/*/pulls/*/commits) f=prcommits ;;
  repos/*/pulls/*) f=meta ;;
  repos/*/compare/*) f=compare ;;
  repos/*/git/trees/*) f="tree-${ep##*/}" ;;
  repos/*/issues/*/timeline) f=empty ;;
  repos/*/issues/*) f="issue-${ep##*/}" ;;
  repos/*/commits/*/check-runs) f=runs ;;
  repos/*/commits/*/status) f=status ;;
  repos/*/actions/runs) f=wfruns ;;
  *) exit 1 ;;
esac
[ -f "$GHD/$f" ] || exit 1
$inc && printf 'HTTP/2.0 200 OK\n\n'
if [ -n "$jqx" ]; then jq -r "$jqx" "$GHD/$f"; else cat "$GHD/$f"; fi
EOF
cat > "$TMP/bin/terraform" <<'EOF'
#!/bin/sh
case "$1" in
  version) echo '{"terraform_version":"1.9.8","platform":"darwin_arm64"}' ;;
  init) exit 0 ;;
  validate)
    # EV_MARK: wait up to EV_TRIES tenths of a second for the ladder stub's marker, and record seeing it
    if [ -n "${EV_MARK:-}" ]; then
      i=0; while [ ! -e "$EV_MARK" ] && [ "$i" -lt "${EV_TRIES:-100}" ]; do sleep 0.1; i=$((i + 1)); done
      [ ! -e "$EV_MARK" ] || touch "$EV_MARK.seen"
    fi
    [ ! -f validate.fail ] || { echo "Error: stub failure"; exit 1; } ;;
esac
EOF
# mtf-facts: `depth` prints the depth DEPTH_STUB names for the real depth.sh, `affected` a document
# depth.sh accepts (verify-pass.sh finds it invalid and selects every example), anything else fails.
cat > "$TMP/bin/mtf-facts" <<'EOF'
#!/bin/bash
case "$1" in
  depth) jq -n --arg d "${DEPTH_STUB:-light}" '{format: 1, depth: $d,
      reasons: (if $d == "light" then ["light-docs-only"] elif $d == "focused" then ["focused-within-limits"] else ["deep-limits"] end),
      checks_out_of_scope: ({"light": ["A", "B", "D", "G-ladder"], "focused": ["B"], "deep": []}[$d]),
      examples_selected: ["examples/one"], examples_out_of_scope: (if $d == "focused" then ["examples/two"] else [] end),
      touched_types: (if $d == "focused" then ["aws_s3_bucket"] else [] end), walk: {complete: true, unwalked: 0},
      limits: {tf_files: (if $d == "light" then 0 else 1 end), changed_lines: 3, changed_blocks: 0, selected_examples: 1},
      schema_providers: [], schema_types: [], schema_locks: []}' ;;
  affected) echo '{"schema_version": 1, "inert": false, "fallback": null, "changed": [], "examples": []}' ;;
  # With PROFILE_STUB set: a snapshot copy and a valid, relaxing profile-check.
  profile-snapshot) [ -n "${PROFILE_STUB-}" ] || exit 1
    d="$(mktemp -d "${TMPDIR:-/tmp}/snap.XXXXXX")"; cp -R "$3/." "$d/"
    jq -n --arg d "$d" '{dir: $d, tree_sha256: "'"$(printf 'stub' | shasum -a 256 | cut -c1-64)"'", profile_sha256: null}' ;;
  profile-check) [ -n "${PROFILE_STUB-}" ] || exit 1
    [ "$2" != --help ] || { echo 'Usage: mtf-facts profile-check --profile-dir <dir> [flags]'; exit 0; }
    if grep -qx 'release: none' "$3/PROFILE.md"; then
      echo '{"valid": true, "problems": [], "relaxing": true, "gated_rules": ["examples.versions-missing", "profile.template-drift"]}'
    else echo '{"valid": true, "problems": [], "relaxing": false, "gated_rules": []}'; fi ;;
  *) exit 1 ;;
esac
EOF
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/docker"
chmod +x "$TMP/bin/"*

# The remote: a bare repository the clone reaches through a url rewrite set in the environment.
mkrepo() { # name [, directory copied into the base] -> bare repo with base and head commits; sets HEADC BASEC
  local w="$TMP/work-$1" b="$TMP/remote/example-org/$1.git"
  rm -rf "$w" "$b"; mkdir -p "$w"; git init -q "$w"
  (cd "$w" && mkdir -p examples/one examples/two && printf 'resource "x" "y" {}\n' > main.tf &&
    printf 'module "m" { source = "../.." }\n' > examples/two/main.tf &&
    : > variables.tf && printf 'terraform {}\n' > versions.tf && printf 'module "m" { source = "../.." }\n' > examples/one/main.tf &&
    printf '# w\n' > README.md && { [ -z "${2-}" ] || cp -R "$2/." .; } && git add -A && git -c user.name=t -c user.email=t@t commit -q -m base)
  BASEC="$(git -C "$w" rev-parse HEAD)"
  (cd "$w" && printf '# w\nmore\n' > README.md && mkdir -p docs && printf 'x\n' > 'docs/a;b.md' && printf 'y\n' > '$(touch x).md' &&
    git add -A && git -c user.name=t -c user.email=t@t commit -q -m head)
  HEADC="$(git -C "$w" rev-parse HEAD)"
  git clone -q --bare "$w" "$b"; git -C "$b" update-ref refs/pull/7/head "$HEADC"
  git -C "$b" config uploadpack.allowAnySHA1InWant true
  tree() { git -C "$w" ls-tree -r -l "$1" | awk -v OFS='\t' '{print $1, $2, $3, $4, substr($0, index($0, "\t") + 1)}' |
    jq -R -s '{truncated: false, tree: [split("\n")[] | select(. != "") | split("\t") | {mode: .[0], type: .[1], sha: .[2], size: (.[3] | tonumber), path: .[4]}]}'; }
  tree "$HEADC" > "$GHD/tree-$HEADC"; tree "$BASEC" > "$GHD/tree-$BASEC"
}
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$TMP/remote/.insteadOf" GIT_CONFIG_VALUE_0="https://github.com/"
ghfiles() { # state, merged, own review state
  jq -n --arg h "$HEADC" --arg b "$BASEC" --arg st "$1" --argjson mg "$2" '{number: 7, title: "$(touch x) title `x`",
    body: "body $(touch y)", user: {login: "author1", id: 11, type: "User"}, state: $st, merged: $mg, draft: false,
    mergeable: (if $st == "open" then true else null end), changed_files: 3,
    head: {sha: $h, ref: "feat\n$(touch b)", repo: {owner: {login: "example-org"}}},
    base: {ref: "main", sha: $b, repo: {default_branch: "main"}}}' > "$GHD/meta"
  jq -n --arg b "$BASEC" '{merge_base_commit: {sha: $b}}' > "$GHD/compare"
  jq -n '[{filename: "README.md", status: "modified", additions: 1, deletions: 0, patch: "@@ -1 +1,2 @@\n # w\n+more"},
    {filename: "docs/a;b.md", status: "added", additions: 1, deletions: 0, patch: "@@ -0,0 +1 @@\n+x"},
    {filename: "$(touch x).md", status: "added", additions: 1, deletions: 0, patch: "@@ -0,0 +1 @@\n+y"}]' > "$GHD/files"
  jq -n --arg b "$BASEC" --arg s "$3" '[{user: {login: "octo-reviewer", id: 5}, state: $s, commit_id: $b},
    {user: {login: "other", id: 6}, state: "COMMENTED", commit_id: $b}]' > "$GHD/reviews"
  echo '{"login": "octo-reviewer", "type": "User"}' > "$GHD/user"
  echo '{"data": {"repository": {"pullRequest": {"reviewThreads": {"pageInfo": {"hasNextPage": false}, "nodes": []}}}}}' > "$GHD/threads"
  echo '{"data": {"repository": {"pullRequest": {"comments": {"pageInfo": {"hasNextPage": false}, "nodes": []}}}}}' > "$GHD/comments"
  echo '{"data": {"repository": {"pullRequest": {"closingIssuesReferences": {"pageInfo": {"hasNextPage": false}, "nodes": []}}}}}' > "$GHD/closing"
  echo '[]' > "$GHD/empty"
  echo '{"check_runs": [{"id": 1, "check_suite": {"id": 2}, "name": "ci", "app": {"id": 3, "slug": "github-actions"}, "status": "completed", "conclusion": "success"}]}' > "$GHD/runs"
  echo '{"workflow_runs": []}' > "$GHD/wfruns"
  echo '{"total_count": 1, "state": "success"}' > "$GHD/status"
}

RR="$SK/review-run.sh"
export PATH="$TMP/bin:$PATH" TMPDIR="$TMP/root" HOST_PASS_WAIT=0 XDG_CACHE_HOME="$TMP/cache"
mkdir -p "$TMPDIR"
unset CI GITHUB_ACTIONS GITHUB_RUN_ID
SH=bash; [ ! -x /bin/bash ] || SH=/bin/bash # the system bash: 3.2 on macOS, whose regex refuses a bound over 255
run_rr() { (cd "$TMP/cwd" && "$SH" "$RR" "$@"); } # every run from a scratch cwd, to catch a stray file
mkdir -p "$TMP/cwd"
no_stray() { [ -z "$(find "$TMP/cwd" "$TMP/root" -maxdepth 4 \( -name x -o -name y -o -name b \) -print 2> /dev/null | grep -v '/clone/\|/base/')" ]; echo $?; }

# --- 1. Acceptance from the synthetic fixture ---------------------------------------------------
ROOTD="$(cd "$TMPDIR" && pwd -P)"
FR="$(mktemp -d "$ROOTD/pr-review.XXXXXX")"
cp -R "$FX/." "$FR/"; rm -rf "$FR/expected" "$FR/reviewer"; mkdir "$FR/clone"
run_rr handover "$FR" > "$TMP/h.out"
sed -e "s#$FR/#RUN/#g" "$FR/handover/task.md" > "$TMP/task.norm"
check "acceptance: handover reproduces the hand-assembled task byte for byte" "$(cmp -s "$TMP/task.norm" "$FX/expected/task.md"; echo $?)"
check "acceptance: handover reproduces the hand-assembled verification record" "$(cmp -s "$FR/handover/record.txt" "$FX/expected/record.txt"; echo $?)"
check "acceptance: handover prints at most 30 lines" "$(lines_ok "$TMP/h.out")"
B="$FR/handover/reviewer-references.md"
blist() { sed -n '2,/^BUNDLE-SECTION /p' "$1" | grep -v '^BUNDLE-SECTION ' | tr '\n' ' '; }
check "bundle: a .tf change at deep carries every run summary, run/facts.md and Check A's Read First" \
  "$(l="$(blist "$B")"; for e in run/check-a.md run/check-b.md run/check-d.md run/check-g.md run/facts.md check-a-compatibility.md#reads-fails-when-and-severity; do
     case "$l" in (*"references/$e "*) ;; (*) exit 1 ;; esac; done; echo 0)"
check "bundle: the cap holds, and a section is section.sh's bytes" \
  "$([ "$(sed -n '/^BUNDLE-SECTION /,$p' "$B" | wc -c)" -le 100000 ] &&
     awk '/^BUNDLE-SECTION references\/inputs.md#inputs$/{p=1; next} /^BUNDLE-SECTION /{p=0} p' "$B" |
     cmp -s - <(bash "$SRC/.agents/skills/terraform-module-reviewer/references/section.sh" references/inputs.md inputs); echo $?)"
check "bundle: handover names the bundle and what the cap left out" "$(grep -q '^references: .* sections left out)$' "$TMP/h.out"; echo $?)"
check "acceptance: the Diff file is the task's diff, module-root-relative" \
  "$(awk '/^```diff$/{p=1; next} p && /^```$/{exit} p' "$FX/expected/task.md" | cmp -s - "$FR/handover/change.diff"; echo $?)"
run_rr render "$FR" --findings "$FX/reviewer/findings.json" --assessment "$FX/reviewer/assessment.txt" \
  --summary "$FX/reviewer/summary.txt" --out "$TMP/render1" > "$TMP/r.out"
check "acceptance: render reproduces the current renderer's comment byte for byte" "$(cmp -s "$TMP/render1/comment.md" "$FX/expected/comment.md"; echo $?)"
check "acceptance: render prints the render line" "$(grep -q '^rendered approve with nits (ladder rule 7), proposed event COMMENT, tier COMPACT$' "$TMP/r.out"; echo $?)"
check "acceptance: the run file carries the counts of the summary line" \
  "$(q "$FR/render/run-file.json" '.counts == {"instruction-like-text-from-others": 0, "conversation-claims-unread": 0, "review.quoted-claim-unverifiable": 1} and (has("depth") | not)')"
printf '%s\n' '- F-001 ...' 'summary: critical:0 high:0 medium:0 low:3 mode:full checks:A,C,D,E,F,G instruction-like-text-from-others:2 conversation-claims-unread:0 review.quoted-claim-unverifiable:1' 'Facts comparison: ...' > "$TMP/summary2.txt"
run_rr render "$FR" --findings "$FX/reviewer/findings.json" --assessment "$FX/reviewer/assessment.txt" \
  --summary "$TMP/summary2.txt" --out "$TMP/render1b" > /dev/null 2>&1
check "render reads the counts from the reviewer's summary: line, wherever it stands" \
  "$(q "$FR/render/run-file.json" '.counts == {"instruction-like-text-from-others": 2, "conversation-claims-unread": 0, "review.quoted-claim-unverifiable": 1}')"
check "acceptance: render refuses an output directory inside the run" \
  "$(run_rr render "$FR" --findings "$FX/reviewer/findings.json" --assessment "$FX/reviewer/assessment.txt" --out "$FR/o" > /dev/null 2>&1; [ $? != 0 ]; echo $?)"
echo 'not json' > "$TMP/bad.json"
check "acceptance: render refuses findings that are not a list" \
  "$(run_rr render "$FR" --findings "$TMP/bad.json" --assessment "$FX/reviewer/assessment.txt" --out "$TMP/render2" > /dev/null 2>&1; [ $? = 1 ]; echo $?)"

# --- 2. prepare to render on a light change with hostile names, through the real depth.sh ---------
mkrepo widget; ghfiles open false CHANGES_REQUESTED
prep() { # extra env as words before; sets RUN
  run_rr prepare --repo example-org/widget --pr 7 "$@" > "$TMP/p.out" 2> "$TMP/p.err"
  RUN="$(sed -n 's/^RUN=//p' "$TMP/p.out")"
}
full() { run_rr verify "$RUN" > "$TMP/v.out"; run_rr plan "$RUN" > "$TMP/pl.out"; run_rr ladder "$RUN" > "$TMP/l.out"; }
with_tf() { # command...: run with a .tf file in the run's files list, then the list put back; schema skips a change with none
  local f="$RUN/host/files.json" rc
  cp "$f" "$TMP/files-keep.json"
  jq '. + [{filename: "main.tf", status: "modified", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-a\n+b"}]' "$TMP/files-keep.json" > "$f"
  "$@"; rc=$?
  cp "$TMP/files-keep.json" "$f"; return "$rc"
}
echo '[]' > "$TMP/f0.json"; echo 'Docs only.' > "$TMP/a0.txt"
render_to() { run_rr render "$RUN" --findings "$TMP/f0.json" --assessment "$TMP/a0.txt" --out "$1" > "$TMP/re.out" 2>&1; }
prep --render-only
check "prepare: prints the run directory and exits 0" "$([ -d "$RUN" ] && grep -q '^next: ' "$TMP/p.out"; echo $?)"
check "prepare: prints at most 30 lines" "$(lines_ok "$TMP/p.out")"
check "prepare: the clone holds the head and the base worktree the merge base" \
  "$([ "$(git -C "$RUN/clone" rev-parse HEAD)" = "$HEADC" ] && [ "$(git -C "$RUN/base" rev-parse HEAD)" = "$BASEC" ]; echo $?)"
check "prepare: git merge-base --all of the base and the head is the merge base alone" \
  "$([ "$(git -C "$RUN/clone" merge-base --all "$BASEC" HEAD)" = "$BASEC" ]; echo $?)"
check "prepare: the real depth.sh bound depth.json to the head, the base and the merge base" \
  "$(jq -e --arg h "$HEADC" --arg b "$BASEC" '.depth == "light"
    and .binding.head_sha == $h and .binding.base_sha == $b and .binding.merge_base == $b' "$RUN/depth.json" > /dev/null; echo $?)"
check "prepare: the depth pin is recorded" "$([ "$(cat "$RUN/state/depth.sha256")" = "$(shasum -a 256 < "$RUN/depth.json" | cut -d' ' -f1)" ]; echo $?)"
check "prepare: index.json holds the enumerated fields" \
  "$(jq -e --arg h "$HEADC" '.status == "ok" and .head == $h and .depth == "light"
    and .reasons == ["light-docs-only"] and .checks_out_of_scope == ["A", "B", "D", "G-ladder"]
    and .signals.checks == "accepted" and .counts.files == 3 and .counts.changed_files == 3 and .plan == "no-profile"' "$RUN/index.json" > /dev/null; echo $?)"
check "prepare: index.json carries no title, body or branch text" "$(! grep -q 'touch\|author1\|feat' "$RUN/index.json"; echo $?)"
check "prepare: nothing in a title, branch or file name ran" "$(no_stray)"
check "defect: task.md carries the Write short line word for word" \
  "$(grep -qxF 'Write short: a `summary` of at most 200 characters and a `suggested_fix` of at most 250, or at most 600 for a `needs decision:` fix, one clause per option. The hard caps stay 500 and 600. A finding over the short targets is valid; the COMPACT render refuses it, and the comment renders in STANDARD only with `--standard`.' "$RUN/host/task.md"; echo $?)"
check "defect: the posting login's own CHANGES_REQUESTED is left out of a render-only run" \
  "$(q "$RUN/host/host.json" '.signals.review_decision == "none" and .own_review.state == "CHANGES_REQUESTED"')"
# The review decision counts only reviewers with write access, as GitHub's own does: the replay of
# a pull request whose one approval came from an author with association NONE, before and after
# the maintainer, who is the posting login, requested changes.
dec() { jq -r -L "$SKILL/references" --arg l "$1" 'include "host-records"; decision($l; false) | .review_decision' <<< "$2"; }
r() { printf '{"user": {"login": "%s", "id": %s}, "author_association": "%s", "state": "%s", "commit_id": "c"}' "$@"; }
check "defect: an approval by an author without write access is no approval" \
  "$([ "$(dec me "[$(r drive-by 9 NONE APPROVED)]")" = none ]; echo $?)"
check "defect: the posting login's change request leaves a drive-by approval deciding nothing" \
  "$([ "$(dec me "[$(r drive-by 9 NONE APPROVED), $(r me 1 MEMBER CHANGES_REQUESTED)]")" = none ]; echo $?)"
check "review decision: a member's or collaborator's approval passes" \
  "$([ "$(dec me "[$(r m 2 MEMBER APPROVED)]")" = pass ] && [ "$(dec me "[$(r c 3 COLLABORATOR APPROVED)]")" = pass ]; echo $?)"
check "review decision: a contributor's change request fails nothing, an owner's fails" \
  "$([ "$(dec me "[$(r m 2 MEMBER APPROVED), $(r x 4 CONTRIBUTOR CHANGES_REQUESTED)]")" = pass ] &&
    [ "$(dec me "[$(r m 2 MEMBER APPROVED), $(r o 5 OWNER CHANGES_REQUESTED)]")" = fail ]; echo $?)"
check "records files.json keeps additions and deletions" "$(q "$RUN/host/files.json" 'all(.[]; .additions == 1 and .deletions == 0)')"
run_rr handover "$RUN" > /dev/null 2>&1
check "handover: refused before verify" "$([ $? = 1 ] && [ ! -e "$RUN/handover" ]; echo $?)"
full
check "verify: a light run with every example passing stays light" "$([ "$(jq -r .depth "$RUN/depth.json")" = light ]; echo $?)"
check "plan: at light every example is unplanned as skipped at light depth" \
  "$(q "$RUN/coverage.json" '.class == "none" and (.unplanned | map(.reason) | unique) == ["plan pass skipped at light depth"]')"
check "ladder: the claims evaluation ran" "$([ -f "$RUN/behaviour/run-behaviour.json" ]; echo $?)"
run_rr render "$RUN" --findings "$TMP/f0.json" --assessment "$TMP/a0.txt" --out "$TMP/render0" > /dev/null 2>&1
check "render: refused before handover" "$([ $? = 1 ] && [ ! -e "$TMP/render0/comment.md" ]; echo $?)"
run_rr handover "$RUN" > "$TMP/ho.out"
T="$RUN/handover/task.md"
check "handover: Workspace first, Depth line before the block, record inside it" \
  "$([ "$(head -n 1 "$T")" = "Workspace: $RUN/clone" ] && grep -qx "Depth: $RUN/depth.json" "$T" &&
     awk '/^Depth: /{d=NR} /^UNTRUSTED-[0-9a-f]{12} BEGIN$/{b=NR} /^RECORD-[0-9a-f]{12}$/{r=NR} END{exit !(d < b && b < r)}' "$T"; echo $?)"
check "handover: the merge base line names the bound merge base, the output line the review directory" \
  "$(grep -qx "Merge base: $(jq -r .binding.merge_base "$RUN/depth.json")" "$T" &&
     grep -qx "Output: write the findings list as JSON to $RUN/review/findings.json, the summary line and the profile lines to $RUN/review/summary.txt and the facts comparison note to $RUN/review/facts-comparison.txt, and nothing else." "$T" &&
     [ -d "$RUN/review" ]; echo $?)"
check "bundle: a docs-only change at light carries C, E, F and G's summaries and C, E, F's Read First only" \
  "$(grep -qx "References: $RUN/handover/reviewer-references.md" "$T" &&
     [ "$(blist "$RUN/handover/reviewer-references.md")" = "$(printf 'references/%s ' inputs.md#inputs workflow.md#step-1-establish-scope \
       git-safety.md#the-form large-changes.md#classify-every-changed-path large-changes.md#review-order run/output.md \
       workflow.md#final-step-assemble-the-findings run/check-c.md run/check-e.md run/check-f.md run/check-g.md \
       check-c-structure.md#reads-fails-when-and-severity check-e-profile.md#reads-fails-when-and-severity \
       check-f-scope.md#reads-fails-when-and-severity check-f-scope.md#the-base-revision)" ]; echo $?)"
check "handover: the title's text stays inside the block" \
  "$(awk '/^UNTRUSTED-[0-9a-f]{12} BEGIN$/{exit} /title|body/{f=1} END{exit f}' "$T"; echo $?)"
render_to "$TMP/render-light"
check "render light: the real render-comment.sh states the depth, its reasons and what is out of scope" \
  "$(grep -qF 'Review depth: light. Reasons: `light-docs-only`.' "$TMP/render-light/comment.md" &&
     grep -qF 'Out of scope at this depth, so not unknowns: Check A, Check B, Check D, Check G beyond its claim reading, the plan pass' "$TMP/render-light/comment.md"; echo $?)"
check "render light: the run file carries depth, no gaps and the example counts" \
  "$(q "$RUN/render/run-file.json" '.depth.depth == "light" and .counts == null and .verify_gaps == [] and .examples == {count: 2, validated: 2}')"
check "render: prints at most 30 lines" "$(lines_ok "$TMP/re.out")"
# The module profile (github-io.md, Handover): the snapshot's tree and gate list go into the task,
# and the reviewer's profile line must match them or nothing is rendered.
STREE="$(printf 'stub' | shasum -a 256 | cut -c1-64)"
cp -R "$SRC/.agents/skills/terraform-module-maintainer" "$TMP/terraform-module-maintainer"
printf '{"id": "in-repo-modules", "dir": ""}\n' > "$RUN/state/module-profile-args.json"
PROFILE_STUB=1 run_rr handover "$RUN" > /dev/null 2>&1
check "handover: a selected profile travels with its tree and gate list" \
  "$(grep -qx 'profile: in-repo-modules' "$T" && grep -qx "Profile tree: $STREE" "$T" &&
     grep -qx 'Gated rules: examples.versions-missing profile.template-drift' "$T" &&
     [ "$(q "$RUN/state/profile.json" '.label == "shipped:in-repo-modules" and .tree == "'"$STREE"'"')" = 0 ]; echo $?)"
printf 'summary: critical:0 high:0 medium:0 low:0\nprofile: shipped:terraform-aws-modules profile_tree_sha256:none\n' > "$TMP/sum-bad.txt"
run_rr render "$RUN" --findings "$TMP/f0.json" --assessment "$TMP/a0.txt" --summary "$TMP/sum-bad.txt" --out "$TMP/render-pbad" > "$TMP/rp.out" 2>&1
check "render: a profile line that differs from the handover is refused" \
  "$([ $? = 1 ] && grep -qF 'does not match the handover' "$TMP/rp.out" && [ ! -e "$TMP/render-pbad/comment.md" ]; echo $?)"
printf 'summary: critical:0 high:0 medium:0 low:0\n' > "$TMP/sum-none.txt"
run_rr render "$RUN" --findings "$TMP/f0.json" --assessment "$TMP/a0.txt" --summary "$TMP/sum-none.txt" --out "$TMP/render-pnone" > "$TMP/rp.out" 2>&1
check "render: no profile line for a selected profile is refused" "$([ $? = 1 ] && [ ! -e "$TMP/render-pnone/comment.md" ]; echo $?)"
printf 'summary: critical:0 high:0 medium:0 low:0\nprofile: shipped:in-repo-modules profile_tree_sha256:%s\n' "$STREE" > "$TMP/sum-ok.txt"
run_rr render "$RUN" --findings "$TMP/f0.json" --assessment "$TMP/a0.txt" --summary "$TMP/sum-ok.txt" --out "$TMP/render-pok" > "$TMP/rp.out" 2>&1
check "render: the matching profile line renders, and the run file carries it" \
  "$([ $? = 0 ] && grep -qF "Profile: \`shipped:in-repo-modules\`, profile_tree_sha256 \`$STREE\`." "$TMP/render-pok/comment.md" &&
     [ "$(q "$RUN/render/run-file.json" '.profile == {label: "shipped:in-repo-modules", tree: "'"$STREE"'"}')" = 0 ]; echo $?)"
printf '{"id": "no-such-profile", "dir": ""}\n' > "$RUN/state/module-profile-args.json"
PROFILE_STUB=1 run_rr handover "$RUN" > "$TMP/rp.out" 2>&1
check "handover: an unknown profile id is refused, path-free" "$([ $? = 1 ] && grep -qx 'review-run.sh: profile refused: unknown profile id' "$TMP/rp.out"; echo $?)"
printf '{"id": "in-repo-modules", "dir": ""}\n' > "$RUN/state/module-profile-args.json"
run_rr handover "$RUN" > "$TMP/rp.out" 2>&1
check "handover: a non-default profile with no snapshot is refused" "$([ $? = 1 ] && grep -qF 'profile refused:' "$TMP/rp.out"; echo $?)"
# The default, snapshotted: no profile line, its tree, and the reviewer's line is required.
printf '{"id": "", "dir": ""}\n' > "$RUN/state/module-profile-args.json"
PROFILE_STUB=1 run_rr handover "$RUN" > /dev/null 2>&1
check "handover: the default profile is snapshotted, with no profile line and no gate list" \
  "$(! grep -q '^profile' "$T" && grep -qx "Profile tree: $STREE" "$T" && ! grep -q '^Gated rules:' "$T" &&
     [ "$(q "$RUN/state/profile.json" '.id == "" and .label == "shipped:terraform-aws-modules" and .gated == []')" = 0 ]; echo $?)"
run_rr render "$RUN" --findings "$TMP/f0.json" --assessment "$TMP/a0.txt" --summary "$TMP/sum-none.txt" --out "$TMP/render-dnone" > "$TMP/rp.out" 2>&1
check "render: a snapshotted default with no reviewer profile line is refused" "$([ $? = 1 ] && [ ! -e "$TMP/render-dnone/comment.md" ]; echo $?)"
printf 'summary: critical:0 high:0 medium:0 low:0\nprofile: shipped:terraform-aws-modules profile_tree_sha256:%s\n' "$STREE" > "$TMP/sum-dok.txt"
run_rr render "$RUN" --findings "$TMP/f0.json" --assessment "$TMP/a0.txt" --summary "$TMP/sum-dok.txt" --out "$TMP/render-dok" > "$TMP/rp.out" 2>&1
check "render: a snapshotted default renders its profile line" \
  "$([ $? = 0 ] && grep -qF "Profile: \`shipped:terraform-aws-modules\`, profile_tree_sha256 \`$STREE\`." "$TMP/render-dok/comment.md"; echo $?)"
printf 'summary: critical:0 high:0 medium:1 low:0\nprofile: refused\n' > "$TMP/sum-ref.txt"
printf '[{"id": "F-001", "rule_id": "review.check-not-run", "severity": "MEDIUM", "file": ".", "line": null, "summary": "profile refused: profile tree changed", "suggested_fix": "Run the review again."}]\n' > "$TMP/f-ref.json"
run_rr render "$RUN" --findings "$TMP/f-ref.json" --assessment "$TMP/a0.txt" --summary "$TMP/sum-ref.txt" --out "$TMP/render-ref" > "$TMP/rp.out" 2>&1
check "render: a reviewer that refused the profile shows the refusal, not a mismatch" \
  "$([ $? = 1 ] && grep -qF 'the reviewer refused the profile (profile refused: profile tree changed)' "$TMP/rp.out" && [ ! -e "$TMP/render-ref/comment.md" ]; echo $?)"
# --module-profile-dir: a custom profile outside every checkout, and each refusal.
RT="$(cd "$TMP" && pwd -P)"
mkdir -p "$RT/custom" && cp -R "$SRC/.agents/skills/terraform-module-maintainer/profiles/in-repo-modules/." "$RT/custom/"
pdir() { jq -n --arg d "$1" '{id: "", dir: $d}' > "$RUN/state/module-profile-args.json"; PROFILE_STUB=1 run_rr handover "$RUN" > "$TMP/rp.out" 2>&1; }
pdir "$RT/custom"
check "handover: a custom profile is labelled custom, with its profile-dir line and tree" \
  "$(grep -qx "profile-dir: $RT/custom" "$T" && grep -qx "Profile tree: $STREE" "$T" &&
     [ "$(q "$RUN/state/profile.json" '.label == "custom" and .tree == "'"$STREE"'"')" = 0 ]; echo $?)"
mkdir -p "$RUN/inside"; cp -R "$RT/custom/." "$RUN/inside/"
pdir "$RUN/inside"
check "handover: a profile-dir inside the run is refused" "$([ $? = 1 ] && grep -qF 'profile-dir lies inside the workspace or a checkout' "$TMP/rp.out"; echo $?)"
mkdir -p "$RT/co/.git" "$RT/co/prof"; cp -R "$RT/custom/." "$RT/co/prof/"
pdir "$RT/co/prof"
check "handover: a profile-dir under a git checkout is refused" "$([ $? = 1 ] && grep -qF 'profile-dir lies inside the workspace or a checkout' "$TMP/rp.out"; echo $?)"
mkdir -p "$RT/locked"; chmod 000 "$RT/locked"
pdir "$RT/locked/prof"
check "handover: a profile-dir that cannot be entered is refused" "$([ $? = 1 ] && grep -qx 'review-run.sh: profile refused: profile snapshot failed' "$TMP/rp.out"; echo $?)"
chmod 700 "$RT/locked"
ln -s "$RT/custom" "$RT/linked"
pdir "$RT/linked"
check "handover: a profile-dir that is a symbolic link is refused" "$([ $? = 1 ] && grep -qx 'review-run.sh: profile refused: profile snapshot failed' "$TMP/rp.out"; echo $?)"
check "handover: no refusal names a path" "$(! grep -qF "$RT" "$TMP/rp.out"; echo $?)"
printf '{"id": "in-repo-modules", "dir": ""}\n' > "$RUN/state/module-profile-args.json"
run_rr handover "$RUN" > "$TMP/rp.out" 2>&1
check "handover: a relaxing profile with no snapshot gets the relaxing refusal" \
  "$([ $? = 1 ] && grep -qx 'review-run.sh: profile refused: profile relaxes, and mtf-facts has no profile-check or in_repo_downgrade' "$TMP/rp.out"; echo $?)"
check "prepare: a profile-dir with a newline is a usage error" \
  "$(run_rr prepare --repo a/b --pr 1 --module-profile-dir "$(printf '/a\nb')" > /dev/null 2>&1; [ $? = 2 ]; echo $?)"
printf '{"id": "", "dir": ""}\n' > "$RUN/state/module-profile-args.json"
rm -rf "$TMP/terraform-module-maintainer"
run_rr handover "$RUN" > "$TMP/ho.out"
# Any edit of depth.json after prepare, raising it included, stops the run.
jq '.depth = "deep"' "$RUN/depth.json" > "$TMP/d.json"; cp "$RUN/depth.json" "$TMP/depth-keep.json"
cp "$TMP/d.json" "$RUN/depth.json"
run_rr render "$RUN" --findings "$TMP/f0.json" --assessment "$TMP/a0.txt" --out "$TMP/render5" > "$TMP/re5.out" 2>&1
check "depth.json edited after prepare is refused and stops the run" \
  "$([ $? = 1 ] && [ ! -e "$TMP/render5/comment.md" ] && grep -q 'differs from the depth this run computed' "$RUN/state/stop"; echo $?)"
cp "$TMP/depth-keep.json" "$RUN/depth.json"
check "a stopped run stays stopped, even with depth.json put back" "$(run_rr handover "$RUN" > /dev/null 2>&1; [ $? = 1 ]; echo $?)"
check "after every subcommand nothing in a host string ran" "$(no_stray)"
run_rr cleanup "$RUN" > /dev/null
check "cleanup: the run directory is gone, a stopped run included" "$([ ! -e "$RUN" ]; echo $?)"

# Lowering the depth: a deep run whose depth.json is edited to light is refused.
DEPTH_STUB=deep prep
jq '.depth = "light" | .reasons = ["light-docs-only"]' "$RUN/depth.json" > "$TMP/d.json" && cp "$TMP/d.json" "$RUN/depth.json"
run_rr verify "$RUN" > "$TMP/v.out" 2>&1
check "depth.json lowered to light is refused before any step" "$([ $? = 1 ] && [ ! -e "$RUN/verify.json" ]; echo $?)"
run_rr cleanup "$RUN" > /dev/null

# A failed validate at light escalates; a failed escalation stops the run.
prep
touch "$RUN/clone/examples/one/validate.fail"
run_rr verify "$RUN" > "$TMP/v.out"
check "verify: a failed validate at light escalates to deep and re-pins depth.json" \
  "$(grep -q '^depth: escalated to deep (deep-validate-failed)$' "$TMP/v.out" && [ "$(jq -r .depth "$RUN/depth.json")" = deep ] &&
     [ "$(cat "$RUN/state/depth.sha256")" = "$(shasum -a 256 < "$RUN/depth.json" | cut -d' ' -f1)" ]; echo $?)"
check "verify: prints at most 30 lines" "$(lines_ok "$TMP/v.out")"
run_rr plan "$RUN" > /dev/null; run_rr ladder "$RUN" > /dev/null
run_rr handover "$RUN" > "$TMP/ho.out" 2>&1
check "handover at deep without schema is refused" "$([ $? = 1 ] && grep -q 'at deep needs schema first' "$TMP/ho.out"; echo $?)"
with_tf run_rr schema "$RUN" > "$TMP/s.out"
check "schema at deep: a failure leaves no sheets and no escalation" \
  "$(grep -q '^schema: no fact sheets at depth deep (reason overflow)' "$TMP/s.out" && ! grep -q escalated "$TMP/s.out"; echo $?)"
run_rr handover "$RUN" > /dev/null
check "handover at deep with no sheets names none" "$(! grep -q '^Provider fact sheets:' "$RUN/handover/task.md"; echo $?)"
check "handover: the failed validate crosses with its decisive line" \
  "$(grep -q '^examples/one (all): terraform init -backend=false exit 0, terraform validate exit 1: Error: stub failure; at the merge base: new under this change$' "$RUN/handover/record.txt"; echo $?)"
render_to "$TMP/render3"
check "render: an escalated run renders depth deep with its reason" \
  "$(grep -qF 'Review depth: deep. Reasons: `deep-validate-failed`.' "$TMP/render3/comment.md"; echo $?)"
run_rr cleanup "$RUN" > /dev/null
prep
touch "$RUN/clone/examples/one/validate.fail" "$RUN/depth.json.tmp"
run_rr verify "$RUN" > "$TMP/v.out" 2>&1
check "a failed escalation stops the run" "$([ $? = 1 ] && grep -q 'depth.sh escalate failed' "$RUN/state/stop"; echo $?)"
rm -f "$RUN/depth.json.tmp"
check "a stopped run refuses plan, handover and render" \
  "$(run_rr plan "$RUN" > /dev/null 2>&1; a=$?; run_rr handover "$RUN" > /dev/null 2>&1; b=$?; render_to "$TMP/render6"; c=$?
     [ "$a$b$c" = 111 ] && [ ! -e "$TMP/render6/comment.md" ]; echo $?)"
run_rr cleanup "$RUN" > /dev/null

# --- 3. focused: schema first, out-of-scope validate failures, the handover's depth.sh verify --------
DEPTH_STUB=focused prep
full
run_rr handover "$RUN" > "$TMP/ho.out" 2>&1
check "handover at focused without schema is refused" "$([ $? = 1 ] && grep -q 'needs schema first' "$TMP/ho.out" && [ ! -e "$RUN/handover" ]; echo $?)"
check "render at focused without schema is refused" "$(render_to "$TMP/render7"; [ $? = 1 ] && [ ! -e "$TMP/render7/comment.md" ]; echo $?)"
SCHEMA_STUB=ok with_tf run_rr schema "$RUN" > "$TMP/s.out"
run_rr handover "$RUN" > /dev/null
check "handover at focused after schema names the fact sheets" "$(grep -qx "Provider fact sheets: $RUN/facts" "$RUN/handover/task.md"; echo $?)"
check "handover at focused after schema names the schema handoff" \
  "$(grep -qx "Schema handoff: $RUN/schema-handoff/schema-handoff.json.gz" "$RUN/handover/task.md" && grep -qE '^schema: handoff written, 1 directories, 1 provider schemas \([0-9]+s\)$' "$TMP/s.out"; echo $?)"
check "schema: the handoff gets the head, the bound merge base and one token per .tf blob of each" \
  "$(mb="$(jq -r .binding.merge_base "$RUN/depth.json")"; l="$(grep '^schema-env ' "$STUB_LOG" | tail -n 1)"
     n=0; for c in "$(git -C "$RUN/clone" rev-parse HEAD)" "$mb"; do n=$((n + $(git -C "$RUN/clone" ls-tree -r --name-only "$c" | grep -c '\.tf$'))); done
     set -- $l; [ "$2" = "$(git -C "$RUN/clone" rev-parse HEAD)" ] && [ "$3" = "$mb" ] && [ $(($# - 3)) = "$n" ] && [ "$n" -gt 0 ] &&
     t="$4" && f="${t#*:*:}" && [ "${t%%:*}" = "$2" ] &&
     [ "$(cut -d: -f2 <<< "$t")" = "$(git -C "$RUN/clone" cat-file blob "$2:$f" | shasum -a 256 | cut -d' ' -f1)" ]; echo $?)"
check "schema: its source lines cross in the verification record, checked against their grammar" \
  "$(grep -qx "schema pass: source modulestf/terraform-schema-mirror hashicorp_aws-v6.1.0 $(printf 'ab%.0s' $(seq 32))" "$RUN/handover/record.txt" &&
     [ "$(grep -c '^schema pass: source ' "$RUN/handover/record.txt")" = 1 ]; echo $?)"
render_to "$TMP/render-focused"
check "render focused: the real render-comment.sh states the depth and the out-of-scope checks and example" \
  "$(grep -qF 'Review depth: focused. Reasons: `focused-within-limits`.' "$TMP/render-focused/comment.md" &&
     grep -qF 'Out of scope at this depth, so not unknowns: Check B, ' "$TMP/render-focused/comment.md" &&
     grep -q 'examples/two' "$TMP/render-focused/comment.md"; echo $?)"
rm -rf "$RUN/facts"
SCHEMA_STUB=overflow with_tf run_rr schema "$RUN" > "$TMP/s.out" 2>&1
check "an escalation after the handover is refused and stops the run" \
  "$([ $? = 1 ] && grep -q 'escalation after the handover' "$RUN/state/stop" && [ "$(jq -r .depth "$RUN/depth.json")" = focused ]; echo $?)"
run_rr cleanup "$RUN" > /dev/null

DEPTH_STUB=focused prep
with_tf run_rr schema "$RUN" > "$TMP/s.out"
check "schema: an escalation at focused sets depth deep with its reason" \
  "$(grep -q '^depth: escalated to deep (deep-schema-overflow)$' "$TMP/s.out" && grep -qE '^schema: escalated to deep \(reason overflow\) \([0-9]+s\)$' "$TMP/s.out" && grep -q "^schema $RUN/depth.json $RUN/facts $RUN/schema-work $RUN/schema-handoff\$" "$STUB_LOG"; echo $?)"
check "schema: an escalation removes the handoff with the fact sheets" "$([ ! -e "$RUN/schema-handoff" ] && [ ! -e "$RUN/facts" ]; echo $?)"
run_rr cleanup "$RUN" > /dev/null

DEPTH_STUB=focused prep
SCHEMA_STUB=ok with_tf run_rr schema "$RUN" > /dev/null
touch "$RUN/clone/examples/two/validate.fail"
run_rr verify "$RUN" > "$TMP/v.out"
check "verify: a new validate failure in an out-of-scope example escalates a focused run" \
  "$(grep -q '^depth: escalated to deep (deep-validate-failed)$' "$TMP/v.out" && [ "$(q "$RUN/depth.json" '.examples_out_of_scope == []')" = 0 ]; echo $?)"
run_rr cleanup "$RUN" > /dev/null

DEPTH_STUB=deep prep
SCHEMA_STUB=deeppartial with_tf run_rr schema "$RUN" > "$TMP/s.out"
check "schema at deep: a deep partial line is a success, its source lines recorded" \
  "$(grep -q '^schema: schema pass: deep partial page' "$TMP/s.out" && [ "$(cat "$RUN/state/schema")" = ok ] && [ -f "$RUN/facts/missing.json" ] &&
     [ "$(grep -c . "$RUN/state/schema-sources.txt")" = 1 ]; echo $?)"
full; run_rr handover "$RUN" > /dev/null
check "schema at deep: partial sheets are named in the handover" "$(grep -qx "Provider fact sheets: $RUN/facts" "$RUN/handover/task.md"; echo $?)"
run_rr cleanup "$RUN" > /dev/null

DEPTH_STUB=focused prep
SCHEMA_STUB=badsource with_tf run_rr schema "$RUN" > "$TMP/s.out"
check "schema: a source line outside its grammar escalates and nothing of it is recorded" \
  "$(grep -q '^depth: escalated to deep (deep-schema-source-line)$' "$TMP/s.out" && [ ! -e "$RUN/state/schema-sources.txt" ] && [ ! -e "$RUN/facts" ]; echo $?)"
run_rr cleanup "$RUN" > /dev/null

# A module root below the repository root: schema passes it as SCHEMA_ROOT and the inputs
# relative to it, and a copy that does not pass it is caught.
DEPTH_STUB=focused prep
jq '.prefix = "examples"' "$RUN/host/host.json" > "$TMP/host-prefix.json" && cat "$TMP/host-prefix.json" > "$RUN/host/host.json"
root_ok() { # the last schema call had root examples and one token per .tf blob under examples/, relative to it
  local l mb n=0 c t; l="$(grep '^schema-env ' "$STUB_LOG" | tail -n 1)"; mb="$(jq -r .binding.merge_base "$RUN/depth.json")"
  [ "$(grep '^schema-root ' "$STUB_LOG" | tail -n 1)" = 'schema-root examples' ] || return 1
  for c in "$(git -C "$RUN/clone" rev-parse HEAD)" "$mb"; do n=$((n + $(git -C "$RUN/clone" ls-tree -r --name-only "$c" | grep -c '^examples/.*\.tf$'))); done
  set -- $l; shift 3; [ "$#" = "$n" ] && [ "$n" -gt 0 ] || return 1
  for t; do c="${t%%:*}"; f="${t#*:*:}"; [ "$(cut -d: -f2 <<< "$t")" = "$(git -C "$RUN/clone" cat-file blob "$c:examples/$f" | shasum -a 256 | cut -d' ' -f1)" ] || return 1; done
}
SCHEMA_STUB=ok with_tf run_rr schema "$RUN" > /dev/null
check "schema: with module root examples, SCHEMA_ROOT names it and each input is relative to it" "$(root_ok; echo $?)"
sed 's/ SCHEMA_ROOT="\$PREFIX" / /' "$RR" > "$SK/review-run-noroot.sh"
check "self-check: the mutant passes no SCHEMA_ROOT" "$(cmp -s "$RR" "$SK/review-run-noroot.sh"; [ $? = 1 ]; echo $?)"
rm -rf "$RUN/facts" "$RUN/state/schema"
(cd "$TMP/cwd" && SCHEMA_STUB=ok with_tf "$SH" "$SK/review-run-noroot.sh" schema "$RUN") > /dev/null 2>&1
check "self-check: without SCHEMA_ROOT the module root check fails" "$(root_ok; [ $? = 1 ]; echo $?)"
rm -f "$SK/review-run-noroot.sh"
run_rr cleanup "$RUN" > /dev/null

# schema_inputs, taken from the script, on a tree with each case of the handoff's file set.
SI="$TMP/si"; mkdir -p "$SI/state" "$SI/clone/a"
(cd "$SI/clone" && git init -q && printf 'x\n' > a/main.tf && printf 'y\n' > run.tf && chmod 755 run.tf &&
  ln -s a/main.tf link.tf && head -c 1048577 /dev/zero > big.tf && head -c 1048576 /dev/zero > max.tf &&
  printf 'z\n' > notes.md && git add . && git -c user.name=t -c user.email=t@t commit -qm i)
SIC="$(git -C "$SI/clone" rev-parse HEAD)"
si_fn() { sed -n '/^clone_git() {/,/^}/p; /^schema_inputs() {/,/^}/p' "${1:-$RR}"; }
si() { # [script] commit...: the tokens, then "status <n>"
  local f="$RR"; [ -f "${1-}" ] && { f="$1"; shift; }
  bash -c "set -uo pipefail; set -f; $(si_fn "$f")"'; RUN="$1"; shift; schema_inputs "$@"; echo "status $?"' _ "$SI" "$@"
}
sha_of() { git -C "$SI/clone" cat-file blob "$SIC:$1" | shasum -a 256 | cut -d' ' -f1; }
check "schema_inputs: regular .tf blobs of at most 1 MiB, 100644 and 100755, no link, no larger blob, no other file" \
  "$([ "$(si "$SIC")" = "$(printf '%s\n' "$SIC:$(sha_of a/main.tf):a/main.tf" "$SIC:$(sha_of max.tf):max.tf" "$SIC:$(sha_of run.tf):run.tf" 'status 0')" ]; echo $?)"
(cd "$SI/clone" && printf 'h\n' > "$(printf 'x.tf\n%s:%s:y' "$SIC" "$(printf 'cd%.0s' $(seq 32))").tf" && git add -A && git -c user.name=t -c user.email=t@t commit -qm n)
SIN="$(git -C "$SI/clone" rev-parse HEAD)"
check "schema_inputs: a path with a newline forges no token and gives no inputs" "$([ "$(si "$SIN")" = 'status 1' ]; echo $?)"
(cd "$SI/clone" && git reset -q --hard "$SIC" && printf 'h\n' > 'my file.tf' && git add -A && git -c user.name=t -c user.email=t@t commit -qm s)
check "schema_inputs: a path with a space gives no inputs" "$([ "$(si "$(git -C "$SI/clone" rev-parse HEAD)")" = 'status 1' ]; echo $?)"
(cd "$SI/clone" && git reset -q --hard "$SIC" && mkdir m && for i in $(seq 597); do printf '%s\n' "$i" > "m/f$i.tf"; done &&
  git add -A && git -c user.name=t -c user.email=t@t commit -qm c)
SIM="$(git -C "$SI/clone" rev-parse HEAD)"
check "schema_inputs: 600 inputs pass, 603 across two commits give none" \
  "$([ "$(si "$SIM" | tail -n 1)" = 'status 0' ] && [ "$(si "$SIM" | wc -l | tr -d ' ')" = 601 ] && [ "$(si "$SIM" "$SIC")" = 'status 1' ]; echo $?)"
check "schema_inputs: a commit that is not in the clone gives no inputs" "$([ "$(si "$(printf 'ef%.0s' $(seq 20))")" = 'status 1' ]; echo $?)"
# A module root below the repository root: only the blobs under it, each path relative to it,
# as the facts engine hashes the workspace it lints; ab/ shares the root's first letter only.
(cd "$SI/clone" && git reset -q --hard "$SIC" && mkdir -p a/b ab && printf 'b\n' > a/b/y.tf && printf 'c\n' > ab/x.tf &&
  git add -A && git -c user.name=t -c user.email=t@t commit -qm r)
SIR="$(git -C "$SI/clone" rev-parse HEAD)"
sha_r() { git -C "$SI/clone" cat-file blob "$SIR:$1" | shasum -a 256 | cut -d' ' -f1; }
check "schema_inputs: with module root a, the blobs under a/ only, relative to it" \
  "$([ "$(PREFIX=a si "$SIR")" = "$(printf '%s\n' "$SIR:$(sha_r a/b/y.tf):b/y.tf" "$SIR:$(sha_r a/main.tf):main.tf" 'status 0')" ]; echo $?)"
check "schema_inputs: with module root a/b, its one blob as y.tf" \
  "$([ "$(PREFIX=a/b si "$SIR")" = "$(printf '%s\n' "$SIR:$(sha_r a/b/y.tf):y.tf" 'status 0')" ]; echo $?)"
check "schema_inputs: a module root absent from a commit gives no token for it and status 0" \
  "$([ "$(PREFIX=c si "$SIR")" = 'status 0' ]; echo $?)"
check "schema_inputs: a bad path outside the module root is no input; one inside it gives none" \
  "$([ "$(PREFIX=a si "$SIN")" = "$(printf '%s\n' "$SIN:$(sha_of a/main.tf):main.tf" 'status 0')" ] && [ "$(si "$SIN")" = 'status 1' ] &&
     (cd "$SI/clone" && git reset -q --hard "$SIC" && printf 'h\n' > 'a/my file.tf' && git add -A && git -c user.name=t -c user.email=t@t commit -qm s) &&
     [ "$(PREFIX=a si "$(git -C "$SI/clone" rev-parse HEAD)")" = 'status 1' ]; echo $?)"
# Negative self-check: each weakened copy must fail the case it weakens.
si_mut() { # name, perl expression, commits as one word, expected output of the original
  local m="$TMP/si-$1.sh"; perl -pe "$2" "$RR" > "$m"
  if cmp -s "$RR" "$m"; then check "self-check: schema_inputs mutation $1 changes the script" 1; return; fi
  check "self-check: schema_inputs mutation $1 is caught" "$([ "$(si "$m" $3)" != "$4" ]; echo $?)"
}
si_mut no-size 's/\]\] && \[ "\$s" -le 1048576 \] \|\| continue$/]] || continue/' "$SIC" "$(si "$SIC")"
si_mut no-mode 's/\^100\(644\|755\)\$/^[0-9]+\$/' "$SIC" "$(si "$SIC")"
si_mut no-charset 's/\[\[ "\$p" =~ \^\[A-Za-z0-9\._\/-\]\+\$ && /[[ /' "$SIN" 'status 1'
si_root_mut() { # name, perl expression: a weakened copy must change the module root a tokens
  local m="$TMP/si-$1.sh"; perl -pe "$2" "$RR" > "$m"
  if cmp -s "$RR" "$m"; then check "self-check: schema_inputs mutation $1 changes the script" 1; return; fi
  check "self-check: schema_inputs mutation $1 is caught" "$([ "$(PREFIX=a si "$m" "$SIR")" != "$(PREFIX=a si "$SIR")" ]; echo $?)"
}
si_root_mut no-root-filter 's/\[\[ "\$p" == "\$r"\* \]\] \|\| continue; //'
si_root_mut no-root-strip 's/; p="\$\{p#"\$r"\}"; fi$/; fi/'
si_root_mut no-root-slash 's/r="\$\{PREFIX:\+\$PREFIX\/\}"/r="\${PREFIX:+\$PREFIX}"/'
si_mut no-cap 's/\[ "\$n" -le 600 \] && //' "$SIM $SIC" 'status 1'

# The handover's depth.sh verify, and a mutation without it: a head moved after prepare is caught.
DEPTH_STUB=focused prep
SCHEMA_STUB=ok with_tf run_rr schema "$RUN" > /dev/null; full
git -C "$RUN/clone" -c user.name=t -c user.email=t@t commit -q --allow-empty -m moved
run_rr handover "$RUN" > "$TMP/ho.out" 2>&1
check "handover: depth.sh verify refuses a head that moved after prepare" "$([ $? = 1 ] && [ ! -e "$RUN/handover/task.md" ]; echo $?)"
sed '/^cmd_handover() {/,/^}/{/depth.sh" verify/,/fail "depth.sh verify/c\
    :
}' "$RR" > "$SK/review-run-mutant.sh"
check "self-check: the mutant has no depth.sh verify in handover" \
  "$(sed -n '/^cmd_handover() {/,/^}/p' "$SK/review-run-mutant.sh" | grep -q 'depth.sh" verify'; [ $? = 1 ]; echo $?)"
(cd "$TMP/cwd" && bash "$SK/review-run-mutant.sh" handover "$RUN") > /dev/null 2>&1
check "self-check: without the call the moved head would reach the reviewer" "$([ -f "$RUN/handover/task.md" ]; echo $?)"
run_rr cleanup "$RUN" > /dev/null

# A named profile whose plan pass leaves no record never reads as "no AWS profile named".
for rc in 2 1; do
  DEPTH_STUB=deep prep --profile p1 --role-arn arn:aws:iam::000000000000:role/review
  run_rr verify "$RUN" > /dev/null; PLAN_STUB_RC=$rc run_rr plan "$RUN" > "$TMP/pl.out"
  want="plan pass did not run: $([ "$rc" = 2 ] && echo refused || echo failed)"
  check "plan: a plan pass that exits $rc with no record gives '$want'" \
    "$([ "$(jq -r '[.unplanned[].reason] | unique | join(",")' "$RUN/coverage.json")" = "$want" ] && grep -qE "^plan: $want \([0-9]+s\)\$" "$TMP/pl.out"; echo $?)"
  run_rr cleanup "$RUN" > /dev/null
done

# --- 3b. evidence: the depth's commands in one, side by side at deep; no .tf change skips schema ---------
prep
run_rr evidence "$RUN" > "$TMP/e.out"
check "evidence at light: verify, plan and ladder, no schema, each status line timed, at most 30 lines" \
  "$([ $? = 0 ] && [ -f "$RUN/verify.json" ] && [ -f "$RUN/coverage.json" ] && [ -f "$RUN/behaviour/record.txt" ] &&
     [ ! -e "$RUN/state/schema" ] && grep -qE '^verify: .* \([0-9]+s\)$' "$TMP/e.out" && grep -qE '^plan: .* \([0-9]+s\)$' "$TMP/e.out" &&
     grep -qE '^evidence: depth light, done \([0-9]+s\)$' "$TMP/e.out" && [ "$(lines_ok "$TMP/e.out")" = 0 ]; echo $?)"
run_rr handover "$RUN" > /dev/null 2>&1
check "evidence at light: handover accepts the run" "$([ $? = 0 ]; echo $?)"
run_rr cleanup "$RUN" > /dev/null

prep
touch "$RUN/clone/examples/one/validate.fail"
n0="$(grep -c '^schema ' "$STUB_LOG")"
run_rr evidence "$RUN" > "$TMP/e.out"
check "evidence: an escalation at light runs the deep steps not yet run, schema and skip-coverage included" \
  "$(grep -q '^depth: escalated to deep (deep-validate-failed)$' "$TMP/e.out" && [ "$(cat "$RUN/state/schema")" = skipped ] &&
     [ -f "$RUN/state/evidence-skip-coverage.out" ] && grep -qE '^evidence: depth deep, done \([0-9]+s\)$' "$TMP/e.out"; echo $?)"
check "schema: a change with no .tf, .tf.json or .hcl file skips the pass with a status line" \
  "$(grep -qE '^schema: not run, no .tf, .tf.json or .hcl file changed \([0-9]+s\)$' "$TMP/e.out" && [ "$(grep -c '^schema ' "$STUB_LOG")" = "$n0" ]; echo $?)"
run_rr handover "$RUN" > /dev/null 2>&1
check "handover at deep accepts a skipped schema and names no fact sheets" "$([ $? = 0 ] && ! grep -q '^Provider fact sheets:' "$RUN/handover/task.md"; echo $?)"
render_to "$TMP/render-ev"
check "render accepts a skipped schema" "$([ $? = 0 ] && [ -f "$TMP/render-ev/comment.md" ]; echo $?)"
run_rr cleanup "$RUN" > /dev/null

DEPTH_STUB=focused prep
run_rr schema "$RUN" > /dev/null 2>&1; full
run_rr handover "$RUN" > /dev/null 2>&1
check "handover at focused accepts a skipped schema" "$([ $? = 0 ] && [ "$(cat "$RUN/state/schema")" = skipped ]; echo $?)"
run_rr cleanup "$RUN" > /dev/null

DEPTH_STUB=deep prep
rm -f "$TMP/ev-mark" "$TMP/ev-mark.seen"
EV_MARK="$TMP/ev-mark" EV_TRIES=5 run_rr evidence "$RUN" > "$TMP/e.out"
check "evidence at deep: verify runs first, alone, and ends before the plan chain reaches ladder" \
  "$([ $? = 0 ] && [ -e "$TMP/ev-mark" ] && [ ! -e "$TMP/ev-mark.seen" ] && [ -f "$RUN/verify.json" ] && [ -f "$RUN/behaviour/record.txt" ] &&
     grep -qE '^evidence: depth deep, done \([0-9]+s\)$' "$TMP/e.out"; echo $?)"
check "evidence at deep: the outputs print in step order, at most 30 lines" \
  "$([ "$(sed -n -E 's/^(schema|verify|plan|skip-coverage|ladder): .*/\1/p' "$TMP/e.out" | uniq | tr '\n' ' ')" = 'schema verify plan skip-coverage ladder ' ] &&
     [ "$(lines_ok "$TMP/e.out")" = 0 ]; echo $?)"
run_rr handover "$RUN" > /dev/null 2>&1
check "evidence at deep: handover accepts the run" "$([ $? = 0 ]; echo $?)"
run_rr cleanup "$RUN" > /dev/null

DEPTH_STUB=deep prep
rm -f "$TMP/ev-mark" "$TMP/ev-mark.seen"; echo laptop > "$RUN/state/mode"
EV_MARK="$TMP/ev-mark" EV_TRIES=5 run_rr evidence "$RUN" > "$TMP/e.out"
check "evidence at deep in laptop mode: verify heads the plan chain and ends before ladder starts" \
  "$([ $? = 0 ] && [ -e "$TMP/ev-mark" ] && [ ! -e "$TMP/ev-mark.seen" ] && [ -f "$RUN/behaviour/record.txt" ]; echo $?)"
run_rr cleanup "$RUN" > /dev/null
rm -f "$TMP/ev-mark" "$TMP/ev-mark.seen"

# --- 3c. tests: the test pass, only with a non-hcl-dependency trigger; what runs comes from the merge base --------
cat > "$SK/plan-runner/run-tests.sh" <<'STUB'
#!/bin/bash
# stub: logs its arguments and the archive's listing, writes TESTS_STUB as the result
echo "run-tests $*" >> "${STUB_LOG:?}"
while [ $# -gt 0 ]; do case "$1" in --record) rec="$2" ;; --archive) ar="$2" ;; esac; shift; done
tar -tf "$ar" | LC_ALL=C sort > "$STUB_LOG.tar"
mkdir -m 700 "$rec" && echo "${TESTS_STUB:-passed 3}" > "$rec/tests.txt"
STUB
mkdir -p "$TMP/dockerok"; printf '#!/bin/sh\nexit 0\n' > "$TMP/dockerok/docker"; chmod +x "$TMP/dockerok/docker"
FB="$TMP/fnbase"; mkdir -p "$FB/functions"
printf '[scripts]\ntest = "python3 -m pytest --cov --cov-report=term"\n\n[requires]\npython_version = "3.11"\n' > "$FB/functions/Pipfile"
printf 'x = 1\n' > "$FB/functions/app.py"
mkrepo fnwidget "$FB"; ghfiles open false APPROVED
pytrigger() { # file: behaviour.json with one non-hcl-dependency trigger at it
  jq -n --arg f "$1" '{schema_version: 1, capped: 0, triggers: [{id: "T-001", file: $f, line: 1, category: "non-hcl-dependency"}]}' \
    > "$RUN/behaviour/behaviour.json"
}
prep_fn() { run_rr prepare --repo example-org/fnwidget --pr 7 "$@" > "$TMP/pf.out" 2>&1; RUN="$(sed -n 's/^RUN=//p' "$TMP/pf.out")"; pytrigger functions/app.py; }
prep_fn; full
run_rr handover "$RUN" > "$TMP/ho.out" 2>&1
check "tests: with a non-hcl-dependency trigger, handover refuses before the test pass" \
  "$([ $? = 1 ] && grep -q 'handover needs tests first' "$TMP/ho.out"; echo $?)"
run_rr tests "$RUN" > "$TMP/t.out"
check "tests: no container runtime is not run: no runner, and nothing runs" \
  "$(grep -qE '^tests: not run: no runner in functions \([0-9]+s\)$' "$TMP/t.out" && ! grep -q '^run-tests ' "$STUB_LOG" &&
     [ "$(jq -r .result "$RUN/tests.json")" = "not run: no runner" ]; echo $?)"
rm -f "$RUN/tests.json"
PATH="$TMP/dockerok:$PATH" run_rr tests "$RUN" > "$TMP/t.out"
check "tests: the merge base Pipfile decides pipenv and Python 3.11; the head's directory goes as an archive" \
  "$(grep -qE '^tests: passed 3 in functions \([0-9]+s\)$' "$TMP/t.out" &&
     grep -qF -- "--kind pipenv --python python3 --record $RUN/tests-record" "$STUB_LOG" &&
     [ "$(tr '\n' ' ' < "$STUB_LOG.tar")" = 'Pipfile app.py ' ] && [ ! -e "$RUN/state/tests.tar" ]; echo $?)"
run_rr tests "$RUN" > "$TMP/t.out"
check "tests: a second run is refused" "$([ $? = 1 ] && grep -q 'tests already ran' "$TMP/t.out"; echo $?)"
run_rr handover "$RUN" > /dev/null 2>&1
check "tests: handover takes the result into the record" \
  "$([ $? = 0 ] && grep -qx 'tests: functions: passed 3' "$RUN/handover/record.txt"; echo $?)"
render_to "$TMP/render-tests"
check "tests: render carries the result into the run file" "$(q "$RUN/render/run-file.json" '.tests == {dir: "functions", result: "passed 3"}')"
run_rr cleanup "$RUN" > /dev/null
: > "$STUB_LOG"
prep_fn
TESTS_STUB='passed 3; rm -rf /' PATH="$TMP/dockerok:$PATH" run_rr evidence "$RUN" > "$TMP/e.out"
check "tests: evidence at light runs the test pass; a result outside the grammar is error runner" \
  "$([ $? = 0 ] && grep -qE '^tests: error runner in functions \([0-9]+s\)$' "$TMP/e.out" &&
     grep -qE '^evidence: depth light, done \([0-9]+s\)$' "$TMP/e.out"; echo $?)"
run_rr handover "$RUN" > /dev/null 2>&1
check "tests: evidence at light: handover accepts the run" "$([ $? = 0 ]; echo $?)"
run_rr cleanup "$RUN" > /dev/null
DEPTH_STUB=deep prep_fn
PATH="$TMP/dockerok:$PATH" run_rr evidence "$RUN" > "$TMP/e.out"
check "tests: evidence at deep runs the test pass beside the others" \
  "$([ $? = 0 ] && [ "$(jq -r .result "$RUN/tests.json")" = "passed 3" ] && grep -q '^tests: passed 3' "$TMP/e.out"; echo $?)"
run_rr cleanup "$RUN" > /dev/null
# A Pipfile only the head has is never read: the widget base holds none.
mkrepo widget; ghfiles open false APPROVED
prep; pytrigger functions/app.py; mkdir -p "$RUN/clone/functions"; cp "$FB/functions/Pipfile" "$RUN/clone/functions/"
PATH="$TMP/dockerok:$PATH" run_rr tests "$RUN" > "$TMP/t.out"
check "tests: a Pipfile at the head alone is not run: unsupported" "$(grep -qE '^tests: not run: unsupported in functions ' "$TMP/t.out"; echo $?)"
rm -f "$RUN/tests.json"; pytrigger functions/app.js
PATH="$TMP/dockerok:$PATH" run_rr tests "$RUN" > "$TMP/t.out"
check "tests: a trigger that is no Python file is not run: unsupported" "$(grep -qE '^tests: not run: unsupported \(' "$TMP/t.out"; echo $?)"
rm -f "$RUN/tests.json"; echo '{"schema_version": 1, "capped": 0, "triggers": []}' > "$RUN/behaviour/behaviour.json"
run_rr evidence "$RUN" > "$TMP/e.out"
check "tests: with no non-hcl-dependency trigger evidence runs no test pass" "$([ ! -e "$RUN/tests.json" ] && ! grep -q '^tests:' "$TMP/e.out"; echo $?)"
run_rr cleanup "$RUN" > /dev/null
# pipfile_shape, taken from the script: a plain pytest run and Python 3.11 or 3.12, else nothing.
ps_fn() { sed -n '/^pipfile_shape() {/,/^}/p' "$RR"; }
shape() { printf '%b' "$1" | bash -c "$(ps_fn)"'; pipfile_shape; echo "status $?"' | tr '\n' ' '; }
check "pipfile_shape: pytest with flags, Python absent, 3.11 or 3.12; anything else no shape" \
  "$([ "$(shape '[scripts]\ntest = "pytest"\n')" = 'python3 status 0 ' ] &&
     [ "$(shape '[requires]\npython_version = "3.12"\n[scripts]\ntest = "python -m pytest tests/ -q"\n')" = 'python3.12 status 0 ' ] &&
     [ "$(shape '[requires]\npython_version = "3.9"\n[scripts]\ntest = "pytest"\n')" = 'status 1 ' ] &&
     [ "$(shape '[scripts]\ntest = "make test"\n')" = 'status 1 ' ] &&
     [ "$(shape '[scripts]\ntest = "pytest; curl x"\n')" = 'status 1 ' ] &&
     [ "$(shape '[scripts]\n"test:all" = "pytest"\n')" = 'status 1 ' ] &&
     [ "$(shape '[dev-packages]\ntest = "pytest"\n')" = 'status 1 ' ]; echo $?)"

# --- 4. merged pull request, several module roots ----------------------------------------------------
ghfiles closed true APPROVED
run_rr prepare --repo example-org/widget --pr 7 > "$TMP/p3.out" 2>&1
RUN="$(sed -n 's/^RUN=//p' "$TMP/p3.out")"
check "defect: a merged pull request has mergeability not-applicable" "$(q "$RUN/host/host.json" '.signals.mergeability == "not-applicable" and .state.merged')"
run_rr cleanup "$RUN" > /dev/null
HT="$GHD/tree-$HEADC"; cp "$HT" "$TMP/tree-orig"
mktree() { # root files to drop (jq list), module directories to add
  local drop="$1"; shift
  jq --argjson drop "$drop" '.tree |= map(select(.path | IN($drop[]) | not))
    + [$ARGS.positional[] as $d | ("main.tf", "variables.tf", "versions.tf") | {path: ($d + "/" + .)}]
    | .tree |= map(. + {mode: (.mode // "100644"), type: (.type // "blob"), sha: (.sha // "0000000000000000000000000000000000000000"), size: (.size // 1)})' \
    "$TMP/tree-orig" --args "$@" > "$HT"
}
# A root holding a Terraform file but not a whole module, two module roots, a change in neither.
mktree '["variables.tf", "versions.tf"]' modules/a modules/b
ghfiles open false APPROVED
run_rr prepare --repo example-org/widget --pr 7 > "$TMP/p4.out" 2>&1
RUN="$(sed -n 's/^RUN=//p' "$TMP/p4.out")"
check "defect: a root module file and changed paths in no single module root are refused with a fixed reason" \
  "$([ "$(q "$RUN/index.json" '. == {format: 1, status: "refused", reason: "several-module-roots"}')" = 0 ] && grep -q 'the run is inconclusive' "$TMP/p4.out"; echo $?)"
check "a refused run takes no later subcommand" "$(run_rr handover "$RUN" > /dev/null 2>&1; [ $? = 1 ]; echo $?)"
run_rr cleanup "$RUN" > /dev/null 2>&1
check "cleanup deletes a run prepare refused" "$([ $? = 0 ] && [ ! -e "$RUN" ]; echo $?)"
# No Terraform file at the top, a change across modules/<m>, wrappers/<m> and examples: the
# repository root is the workspace.
mktree '["main.tf", "variables.tf", "versions.tf"]' modules/a modules/b wrappers/a wrappers/b
jq -n '[{filename: "modules/a/main.tf", status: "modified", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-a\n+b"},
  {filename: "wrappers/a/main.tf", status: "modified", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-a\n+b"},
  {filename: "examples/one/main.tf", status: "modified", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-a\n+b"}]' > "$GHD/files"
run_rr prepare --repo example-org/widget --pr 7 > "$TMP/p5.out" 2>&1
RUN="$(sed -n 's/^RUN=//p' "$TMP/p5.out")"
check "defect: no root Terraform file and a change across module roots reviews the repository root" \
  "$([ "$(q "$RUN/index.json" '.status == "ok" and .prefix == ""')" = 0 ] && [ "$(q "$RUN/host/host.json" '.prefix == ""')" = 0 ] &&
     grep -qx "Workspace: $RUN/clone" <(run_rr verify "$RUN" > /dev/null; run_rr plan "$RUN" > /dev/null; run_rr ladder "$RUN" > /dev/null
       run_rr handover "$RUN" > /dev/null; head -n 1 "$RUN/handover/task.md"); echo $?)"
run_rr cleanup "$RUN" > /dev/null
mktree '["variables.tf", "versions.tf"]' modules/a modules/b
jq '[{filename: "modules/a/main.tf", status: "modified", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-a\n+b"}]' -n > "$GHD/files"
HP="$SK/host-pass.sh"
GH_TOKEN=x bash "$HP" run --repo example-org/widget --pr 7 --login octo-reviewer --out "$TMP/hp1" > /dev/null 2>&1
check "defect: several module roots resolve to the one holding every changed path" "$(q "$TMP/hp1/host.json" '.prefix == "modules/a"')"
check "host-pass: an empty login is refused without --render-only" \
  "$(GH_TOKEN=x bash "$HP" run --repo example-org/widget --pr 7 --login "" --out "$TMP/hp2" > /dev/null 2>&1; [ $? = 2 ]; echo $?)"
# The closing issues' text (github-io.md, Issue Text): the first two in this repository, as
# kind=issue items after the body, origin by numeric id, 4000 bytes each; a reference to another
# repository, a third issue and a failed read add nothing and fail nothing.
closing() { jq -n '{data: {repository: {pullRequest: {closingIssuesReferences: {pageInfo: {hasNextPage: false},
  nodes: [$ARGS.positional[] | split("#") | {number: (.[1] | tonumber), repository: {nameWithOwner: .[0]}}]}}}}}' \
  --args "$@" > "$GHD/closing"; }
issue() { jq -n --argjson n "$1" --argjson id "$2" --arg body "$3" '{number: $n, title: "Issue \($n) $(touch z)",
  body: $body, user: {login: "u\($id)", id: $id, type: "User"}}' > "$GHD/issue-$1"; }
issue 1303 11 'Repro: apply twice. Workaround: aws_ec2_tag.'
issue 1304 12 "$(printf 'line %04d\n' $(seq 600))"
issue 1305 12 'third'
closing example-org/widget#1303 other-org/widget#1303 Example-Org/Widget#1304 example-org/widget#1305
GH_TOKEN=x bash "$HP" run --repo example-org/widget --pr 7 --login octo-reviewer --out "$TMP/hp3" > /dev/null 2>&1
T3="$TMP/hp3/task.md"; S3="$(sed -n 's/^UNTRUSTED-\([0-9a-f]\{12\}\) BEGIN$/\1/p' "$T3")"
check "issues: two items after the body and before the record, same author change-author, other author other" \
  "$([ "$(grep "^ITEM-$S3 \|^RECORD-$S3\|^UNTRUSTED-$S3 END" "$T3" | sed "s/-$S3//" | tr '\n' '|')" = \
     'ITEM kind=title origin=change-author|ITEM kind=body origin=change-author|ITEM kind=issue origin=change-author|ITEM kind=issue origin=other|UNTRUSTED END|' ]; echo $?)"
check "issues: an item starts with the number and title, then the body" \
  "$(awk -v s="ITEM-$S3 kind=issue origin=change-author" '$0 == s {getline a; getline b; getline c; exit !(a ~ /^#1303 Issue 1303 / && b == "" && c ~ /^Repro: /)}' "$T3"; echo $?)"
check "issues: a cross-repository reference and the third issue add nothing" \
  "$([ "$(grep -c '^#1303 \|^#1304 \|^#1305 ' "$T3")" = 2 ] && ! grep -q '^#1305 \|^third$' "$T3"; echo $?)"
check "issues: an issue over 4000 bytes is cut and recorded" \
  "$(grep -qx "\[truncated-$S3: 2030 bytes omitted\]" "$T3" &&
     [ "$(q "$TMP/hp3/host.json" '[.could_not_run[] | select(.kind == "prose-truncated")] == [{kind: "prose-truncated", item: "issue", omitted: 2030}]')" = 0 ]; echo $?)"
check "issues: the records pass their own check" "$(GH_TOKEN=x bash "$HP" check "$TMP/hp3" --head "$HEADC" | grep -qx 'records accepted'; echo $?)"
rm -f "$GHD/issue-1304"
closing example-org/widget#1304 example-org/widget#1303
GH_TOKEN=x bash "$HP" run --repo example-org/widget --pr 7 --login octo-reviewer --out "$TMP/hp4" > /dev/null 2>&1
check "issues: a failed read adds no item and fails nothing" \
  "$([ -f "$TMP/hp4/host.json" ] && [ "$(grep -c ' kind=issue ' "$TMP/hp4/task.md")" = 1 ] && grep -q '^#1303 ' "$TMP/hp4/task.md" &&
     [ "$(q "$TMP/hp4/host.json" '.could_not_run == [] and .related.status == "ok"')" = 0 ]; echo $?)"
check "issues: nothing in an issue title ran" "$([ ! -e z ] && [ ! -e "$TMP/cwd/z" ]; echo $?)"
# A closed pull request takes no related issues, and still its closing issues' text.
cp "$GHD/meta" "$TMP/meta.keep"
jq '.state = "closed" | .merged = false' "$TMP/meta.keep" > "$GHD/meta"
GH_TOKEN=x bash "$HP" run --repo example-org/widget --pr 7 --login octo-reviewer --out "$TMP/hp6" > /dev/null 2>&1
check "issues: a closed pull request still reads its closing issue" \
  "$([ "$(q "$TMP/hp6/host.json" '.related == {status: "not-applicable", open_unlinked: [], sidebar_not_read: false}')" = 0 ] &&
     [ "$(grep -c ' kind=issue ' "$TMP/hp6/task.md")" = 1 ] && grep -q '^#1303 ' "$TMP/hp6/task.md"; echo $?)"
cp "$TMP/meta.keep" "$GHD/meta"
# Without GraphQL the linked set comes from the body's keywords; one issue named twice is read once.
mv "$GHD/threads" "$TMP/threads.keep"; cp "$GHD/meta" "$TMP/meta.keep"
jq '.body = "Fixes #1303. Closes #1303."' "$TMP/meta.keep" > "$GHD/meta"
GH_TOKEN=x bash "$HP" run --repo example-org/widget --pr 7 --login octo-reviewer --out "$TMP/hp5" > /dev/null 2>&1
check "issues: without GraphQL, an issue the body names twice is one item" \
  "$([ "$(q "$TMP/hp5/host.json" '.conversation.path == "rest"' 2> /dev/null)" = 0 ] &&
     [ "$(grep -c ' kind=issue ' "$TMP/hp5/task.md")" = 1 ]; echo $?)"
jq '.body = "Fixes #1303." | .state = "closed" | .merged = false' "$TMP/meta.keep" > "$GHD/meta"
GH_TOKEN=x bash "$HP" run --repo example-org/widget --pr 7 --login octo-reviewer --out "$TMP/hp7" > /dev/null 2>&1
check "issues: without GraphQL, a closed pull request still reads its closing issue" \
  "$([ "$(q "$TMP/hp7/host.json" '.conversation.path == "rest" and .related == {status: "not-applicable", open_unlinked: [], sidebar_not_read: false}')" = 0 ] &&
     [ "$(grep -c ' kind=issue ' "$TMP/hp7/task.md")" = 1 ]; echo $?)"
mv "$TMP/threads.keep" "$GHD/threads"; cp "$TMP/meta.keep" "$GHD/meta"
closing

# --- 5. usage and run directory refusals --------------------------------------------------------------
check "usage: a run directory outside the pattern is refused" "$(run_rr verify /tmp > /dev/null 2>&1; [ $? = 2 ]; echo $?)"
check "usage: a repository with a shell word is refused" "$(run_rr prepare --repo 'a/$(touch x)' --pr 1 > /dev/null 2>&1; [ $? = 2 ]; echo $?)"
check "usage: a profile name that starts like an option is refused" \
  "$(run_rr prepare --repo a/b --pr 1 --profile -x --role-arn arn:aws:iam::000000000000:role/r > /dev/null 2>&1; [ $? = 2 ]; echo $?)"
check "prepare: profile and profile-dir both given is a usage error" \
  "$(run_rr prepare --repo a/b --pr 1 --module-profile in-repo-modules --module-profile-dir /x > /dev/null 2>&1; [ $? = 2 ]; echo $?)"
check "prepare: a relative profile-dir is a usage error" \
  "$(run_rr prepare --repo a/b --pr 1 --module-profile-dir rel/x > /dev/null 2>&1; [ $? = 2 ]; echo $?)"
# Long values under the system bash: a role name of 512 characters and a 300 character path pass.
LONGARN="arn:aws:iam::000000000000:role/$(printf 'r%.0s' $(seq 512))"
run_rr prepare --repo example-org/nothing --pr 7 --profile p1 --role-arn "$LONGARN" > "$TMP/p6.out" 2>&1
check "regex: a role ARN with a 512 character name is accepted by $SH" "$([ $? = 1 ] && grep -q '^prepare refused: ' "$TMP/p6.out"; echo $?)"
RUN="$(sed -n 's/^RUN=//p' "$TMP/p6.out")"; [ -z "$RUN" ] || run_rr cleanup "$RUN" > /dev/null
check "regex: a role ARN with a 513 character name is refused" \
  "$(run_rr prepare --repo a/b --pr 1 --profile p1 --role-arn "${LONGARN}r" > /dev/null 2>&1; [ $? = 2 ]; echo $?)"
sed -n '/^path_re=/p; /^plain_ok()/p' "$RR" > "$TMP/plain.sh"
printf '%s\n' '. "$1"; plain_ok "$2"' > "$TMP/plain-check.sh"
P300="examples/$(printf 'a%.0s' $(seq 291))"
check "regex: a 300 character path passes plain_ok under $SH" "$("$SH" "$TMP/plain-check.sh" "$TMP/plain.sh" "$P300"; echo $?)"
check "regex: a 301 character path does not" "$("$SH" "$TMP/plain-check.sh" "$TMP/plain.sh" "${P300}a"; [ $? = 1 ]; echo $?)"
# A shell-side pattern (=~, grep -E, sed -E or a *_re/*RE variable) with a bound over 255.
check "regex: no shell-side repetition bound over 255 in the skill's scripts" \
  "$(find "$SKILL/references" -name '*.sh' -exec perl -ne 'next if /^\s*#/; next unless /=~|_re=|RE=|grep -[a-zA-Z]*E|sed -[a-zA-Z]*E/;
     while (/\{(\d+)(?:,(\d*))?\}/g) { if ($1 > 255 or ($2 // 0) > 255) { print "$ARGV:$.: $_"; } }' {} + | grep . > /dev/null; [ $? = 1 ]; echo $?)"
check "usage: --owner-depth takes only deep" "$(run_rr prepare --repo a/b --pr 1 --owner-depth light > /dev/null 2>&1; [ $? = 2 ]; echo $?)"
check "the script has no eval and no bash -c" "$(! grep -nE '(^|[;&|(])[[:space:]]*eval[[:space:]]|bash -c' "$SKILL/references/review-run.sh"; echo $?)"
check "nothing in a host string ran, end of run" "$(no_stray)"

# --- 5b. End to end with the real mtf-facts: depth from prepare, the handover diff for lint ------------
# The binary is built from the facts repository named by MTF_FACTS_SRC (default: a sibling checkout
# ../facts); without Go or that checkout the section is skipped with a note.
# MTF_FACTS_BIN names a built binary to use instead.
FACTS_SRC="${MTF_FACTS_SRC:-$SRC/../facts}"
mkdir -p "$TMP/real"
if { [ -n "${MTF_FACTS_BIN:-}" ] && [ -x "$MTF_FACTS_BIN" ] && cp "$MTF_FACTS_BIN" "$TMP/real/mtf-facts"; } ||
    { command -v go > /dev/null && [ -d "$FACTS_SRC/cmd/mtf-facts" ] &&
      (cd "$FACTS_SRC" && go build -o "$TMP/real/mtf-facts" ./cmd/mtf-facts) > /dev/null 2>&1; }; then
  SK2="$TMP/skill2/references"; mkdir -p "$TMP/skill2"; cp -R "$SKILL/references" "$SK2"
  cp "$SK/ladder-pass.sh" "$SK2/ladder-pass.sh" # acquisition needs the network; the classifier runs without its schema
  mkrepo2() { # case -> a module with one example, the change of the case, and its gh answers
    local w="$TMP/work-e2e" b="$TMP/remote/example-org/e2e.git"
    rm -rf "$w" "$b"; mkdir -p "$w/examples/one"; git init -q "$w"
    printf 'resource "aws_s3_bucket" "this" {\n  bucket = var.name\n\n  force_destroy = false\n}\n' > "$w/main.tf"
    printf 'variable "name" {\n  type = string\n}\n' > "$w/variables.tf"
    printf 'output "id" {\n  value = aws_s3_bucket.this.id\n}\n' > "$w/outputs.tf"
    printf 'terraform {\n  required_providers {\n    aws = {\n      source  = "hashicorp/aws"\n      version = ">= 5.0"\n    }\n  }\n}\n' > "$w/versions.tf"
    printf 'module "m" {\n  source = "../.."\n  name   = "x"\n}\n' > "$w/examples/one/main.tf"
    printf '# m\n\nA module.\n' > "$w/README.md"
    (cd "$w" && git add -A && git -c user.name=t -c user.email=t@t commit -q -m base)
    BASEC="$(git -C "$w" rev-parse HEAD)"
    case "$1" in
      readme) printf '# m\n\nA module, better described.\n' > "$w/README.md" ;;
      arg) sed -i.bak 's/force_destroy = false/force_destroy = true/' "$w/main.tf" && rm "$w/main.tf.bak" ;;
      floor) sed -i.bak 's/>= 5.0/>= 6.0/' "$w/versions.tf" && rm "$w/versions.tf.bak" ;;
    esac
    (cd "$w" && git add -A && git -c user.name=t -c user.email=t@t commit -q -m head)
    HEADC="$(git -C "$w" rev-parse HEAD)"
    git clone -q --bare "$w" "$b"; git -C "$b" update-ref refs/pull/7/head "$HEADC"
    git -C "$b" config uploadpack.allowAnySHA1InWant true
    tree() { git -C "$w" ls-tree -r -l "$1" | awk -v OFS='\t' '{print $1, $2, $3, $4, substr($0, index($0, "\t") + 1)}' |
      jq -R -s '{truncated: false, tree: [split("\n")[] | select(. != "") | split("\t") | {mode: .[0], type: .[1], sha: .[2], size: (.[3] | tonumber), path: .[4]}]}'; }
    tree "$HEADC" > "$GHD/tree-$HEADC"; tree "$BASEC" > "$GHD/tree-$BASEC"
    ghfiles open false APPROVED
    # The files list as GitHub gives it, a blank context line written as an empty line.
    git -C "$w" diff --numstat "$BASEC" "$HEADC" | while IFS="$(printf '\t')" read -r a d f; do
      git -C "$w" diff "$BASEC" "$HEADC" -- "$f" | sed -n '/^@@/,$p' | sed 's/^ $//' |
        jq -R -s --arg f "$f" --argjson a "$a" --argjson d "$d" '{filename: $f, status: "modified", additions: $a, deletions: $d, patch: rtrimstr("\n")}'
    done | jq -s '.' > "$GHD/files"
    jq '.changed_files = 1' "$GHD/meta" > "$GHD/meta.t" && mv "$GHD/meta.t" "$GHD/meta"
  }
  e2e() { # case -> RUN
    mkrepo2 "$1"
    (cd "$TMP/cwd" && PATH="$TMP/real:$PATH" "$SH" "$SK2/review-run.sh" prepare --repo example-org/e2e --pr 7) > "$TMP/e2e.out" 2>&1
    RUN="$(sed -n 's/^RUN=//p' "$TMP/e2e.out")"
  }
  e2e readme
  check "e2e: a README-only change is light through prepare and the real mtf-facts" \
    "$([ "$(jq -r '.depth + " " + (.reasons | join(","))' "$RUN/index.json")" = "light light-docs-only" ]; echo $?)"
  (cd "$TMP/cwd" && "$SH" "$SK2/review-run.sh" cleanup "$RUN") > /dev/null
  e2e arg
  check "e2e: a one-line resource argument change is focused" \
    "$([ "$(jq -r '.depth' "$RUN/index.json")" = focused ]; echo $?)"
  for c in verify plan ladder; do (cd "$TMP/cwd" && PATH="$TMP/real:$PATH" "$SH" "$SK2/review-run.sh" "$c" "$RUN") > /dev/null 2>&1; done
  echo ok > "$RUN/state/schema" # the schema pass needs the mirror; its own test covers it
  (cd "$TMP/cwd" && PATH="$TMP/real:$PATH" "$SH" "$SK2/review-run.sh" handover "$RUN") > /dev/null 2>&1
  check "e2e: the handover diff writes a blank context line with its leading space" \
    "$(grep -qx ' ' "$RUN/handover/change.diff" && ! grep -qx '' "$RUN/handover/change.diff"; echo $?)"
  "$TMP/real/mtf-facts" lint "$RUN/clone" --diff "$RUN/handover/change.diff" --json > /dev/null 2> "$TMP/lint.err"
  lrc=$?
  check "e2e: mtf-facts lint --diff accepts the handover diff (exit $lrc)" "$([ "$lrc" != 2 ] && ! grep -q 'hunk line' "$TMP/lint.err"; echo $?)"
  (cd "$TMP/cwd" && "$SH" "$SK2/review-run.sh" cleanup "$RUN") > /dev/null
  e2e floor
  check "e2e: a provider floor bump is deep" \
    "$([ "$(jq -r '.depth' "$RUN/index.json")" = deep ]; echo $?)"
  (cd "$TMP/cwd" && "$SH" "$SK2/review-run.sh" cleanup "$RUN") > /dev/null
else
  echo "skip end to end: no MTF_FACTS_BIN, and no Go toolchain or no facts checkout at $FACTS_SRC (set MTF_FACTS_SRC)"
fi

# --- 5c. A branch that merged the base into work older than the merge base ----------------------------
# The history cutoff a day before the merge base drops the branch side of the merge, so the clone shows
# no merge base until prepare starts the history at the oldest pull request commit.
mkmerge() { # name -> a bare repository whose head merges main into a branch forked months before; sets HEADC BASEC
  local w="$TMP/work-$1" b="$TMP/remote/example-org/$1.git" d
  rm -rf "$w" "$b"; mkdir -p "$w"; git init -q -b main "$w"
  cm() { GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" git -C "$w" -c user.name=t -c user.email=t@t commit -q -m "$2"; }
  (cd "$w" && mkdir -p examples/one examples/two && printf 'resource "x" "y" {}\n' > main.tf &&
    printf 'module "m" { source = "../.." }\n' > examples/two/main.tf && : > variables.tf && printf 'terraform {}\n' > versions.tf &&
    printf 'module "m" { source = "../.." }\n' > examples/one/main.tf && printf '# w\n' > README.md && git add -A)
  cm 2026-01-01T00:00:00Z base
  git -C "$w" checkout -q -b feat; printf '# w\nmore\n' > "$w/README.md"; git -C "$w" add -A; cm 2026-01-02T00:00:00Z early
  git -C "$w" checkout -q main; printf 'l\n' > "$w/LICENSE"; git -C "$w" add -A; cm 2026-06-01T00:00:00Z tip
  BASEC="$(git -C "$w" rev-parse HEAD)"
  git -C "$w" checkout -q feat
  GIT_AUTHOR_DATE=2026-06-10T00:00:00Z GIT_COMMITTER_DATE=2026-06-10T00:00:00Z git -C "$w" -c user.name=t -c user.email=t@t merge -q --no-ff -m merge main
  mkdir -p "$w/docs"; printf 'x\n' > "$w/docs/a;b.md"; printf 'y\n' > "$w/\$(touch x).md"; git -C "$w" add -A; cm 2026-06-11T00:00:00Z head
  HEADC="$(git -C "$w" rev-parse HEAD)"
  git clone -q --bare "$w" "$b"; git -C "$b" update-ref refs/pull/7/head "$HEADC"
  git -C "$b" config uploadpack.allowAnySHA1InWant true
  tree "$HEADC" > "$GHD/tree-$HEADC"; tree "$BASEC" > "$GHD/tree-$BASEC"
  jq -n '[{commit: {committer: {date: "2026-01-02T00:00:00Z"}}}, {commit: {committer: {date: "2026-06-11T00:00:00Z"}}}]' > "$GHD/prcommits"
}
mkmerge oldfeat; ghfiles open false APPROVED
run_rr prepare --repo example-org/oldfeat --pr 7 > "$TMP/p7.out" 2>&1
RUN="$(sed -n 's/^RUN=//p' "$TMP/p7.out")"
check "history: a branch that merged the base into older work is prepared, not refused" \
  "$([ -d "$RUN" ] && grep -q '^next: ' "$TMP/p7.out" && ! grep -q 'prepare refused' "$TMP/p7.out"; echo $?)"
check "history: git merge-base --all of the base and the head is the merge base alone" \
  "$([ "$(git -C "$RUN/clone" merge-base --all "$BASEC" HEAD)" = "$BASEC" ]; echo $?)"
run_rr cleanup "$RUN" > /dev/null 2>&1
rm -f "$GHD/prcommits"
run_rr prepare --repo example-org/oldfeat --pr 7 > "$TMP/p8.out" 2>&1
check "history: with no pull request commit list the run is refused, never prepared on a short history" \
  "$(grep -q '^prepare refused: depth-aborted' "$TMP/p8.out"; echo $?)"
run_rr cleanup "$(sed -n 's/^RUN=//p' "$TMP/p8.out")" > /dev/null 2>&1

# --- 5b. An empty base: the new module handover; the self-authored clamp ---------------------------
# The base commit holds no file, the head adds a whole module: the task states the reviewer's new
# module shape and names no diff. The posting login is the author, so a block is clamped to COMMENT.
mkempty() { # name -> bare repo whose base commit has an empty tree; sets HEADC BASEC
  local w="$TMP/work-$1" b="$TMP/remote/example-org/$1.git"
  rm -rf "$w" "$b"; mkdir -p "$w"; git init -q "$w"
  git -C "$w" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
  BASEC="$(git -C "$w" rev-parse HEAD)"
  (cd "$w" && mkdir -p examples/one && printf 'resource "x" "y" {}\n' > main.tf && : > variables.tf &&
    printf 'terraform {}\n' > versions.tf && printf 'module "m" { source = "../.." }\n' > examples/one/main.tf &&
    printf '# w\n' > README.md && git add -A && git -c user.name=t -c user.email=t@t commit -q -m head)
  HEADC="$(git -C "$w" rev-parse HEAD)"
  git clone -q --bare "$w" "$b"; git -C "$b" update-ref refs/pull/7/head "$HEADC"
  git -C "$b" config uploadpack.allowAnySHA1InWant true
  git -C "$w" ls-tree -r -l "$HEADC" | awk -v OFS='\t' '{print $1, $2, $3, $4, substr($0, index($0, "\t") + 1)}' |
    jq -R -s '{truncated: false, tree: [split("\n")[] | select(. != "") | split("\t") | {mode: .[0], type: .[1], sha: .[2], size: (.[3] | tonumber), path: .[4]}]}' \
    > "$GHD/tree-$HEADC"
  echo '{"truncated": false, "tree": []}' > "$GHD/tree-$BASEC"
}
mkempty fresh; ghfiles open false APPROVED
jq '.changed_files = 5' "$GHD/meta" > "$TMP/meta" && cp "$TMP/meta" "$GHD/meta"
jq -n '[("main.tf", "variables.tf", "versions.tf", "examples/one/main.tf", "README.md")
  | {filename: ., status: "added", additions: 1, deletions: 0, patch: "@@ -0,0 +1 @@\n+x"}]' > "$GHD/files"
echo '{"login": "author1", "type": "User"}' > "$GHD/user"
run_rr prepare --repo example-org/fresh --pr 7 > "$TMP/p9.out" 2>&1
RUN="$(sed -n 's/^RUN=//p' "$TMP/p9.out")"
check "empty base: prepare records a new module and says so" \
  "$(q "$RUN/index.json" '.status == "ok" and .new_module == true' | grep -qx 0 &&
     grep -qx 'base: no file under the module root, reviewed as a new module' "$TMP/p9.out" && lines_ok "$TMP/p9.out" | grep -qx 0; echo $?)"
full; run_rr handover "$RUN" > /dev/null
T="$RUN/handover/task.md"
check "empty base: the task states the new module shape and names no diff, changed paths or merge base" \
  "$(grep -qx 'New module: the workspace holds a whole module with no base. Its merge base holds no file under the module root, so every file in the workspace, .git/ excluded, is added.' "$T" &&
     ! grep -q '^Changed paths:$\|^The diff:$\|^```diff$\|^Diff: \|^Merge base: \|^+++ b/' "$T" &&
     grep -qx "Head revision: $HEADC" "$T" && grep -q '^Write short: ' "$T" &&
     awk '/^New module: /{m=NR} /^Write short: /{w=NR} /^UNTRUSTED-[0-9a-f]{12} BEGIN$/{b=NR} END{exit !(m && m < w && w < b)}' "$T"; echo $?)"
printf '[{"id": "F-001", "rule_id": "profile.owner-identifier", "severity": "MEDIUM", "file": "versions.tf", "line": null, "summary": "The owner is not the family organization.", "suggested_fix": "Name terraform-aws-modules as the owner."}]\n' > "$TMP/f9.json"
run_rr render "$RUN" --findings "$TMP/f9.json" --assessment "$TMP/a0.txt" --out "$TMP/render9" > "$TMP/re9.out" 2>&1
check "own pull request: a block is clamped to COMMENT beside the render line, result.json keeps the event" \
  "$(grep -q '^rendered block (ladder rule 6), proposed event REQUEST_CHANGES, ' "$TMP/re9.out" &&
     grep -qx 'clamp: own pull request, propose COMMENT in place of REQUEST_CHANGES' "$TMP/re9.out" &&
     q "$TMP/render9/result.json" '.proposed_event == "REQUEST_CHANGES"' | grep -qx 0; echo $?)"
run_rr cleanup "$RUN" > /dev/null
# The same pull request with another login: no clamp line; a base holding a file: no new module.
echo '{"login": "octo-reviewer", "type": "User"}' > "$GHD/user"
prep_fresh() { run_rr prepare --repo example-org/fresh --pr 7 > "$TMP/p9.out" 2>&1; RUN="$(sed -n 's/^RUN=//p' "$TMP/p9.out")"; }
prep_fresh; full; run_rr handover "$RUN" > /dev/null
run_rr render "$RUN" --findings "$TMP/f9.json" --assessment "$TMP/a0.txt" --out "$TMP/render10" > "$TMP/re10.out" 2>&1
check "another login: no clamp line" "$(grep -q 'proposed event REQUEST_CHANGES' "$TMP/re10.out" && ! grep -q '^clamp:' "$TMP/re10.out"; echo $?)"
run_rr cleanup "$RUN" > /dev/null
mkrepo widget; ghfiles open false APPROVED
prep; full; run_rr handover "$RUN" > /dev/null
check "a base holding the module: no new module, the diff and the merge base cross" \
  "$(q "$RUN/index.json" '.new_module == false' | grep -qx 0 && ! grep -q '^New module: ' "$RUN/handover/task.md" &&
     grep -q '^Diff: ' "$RUN/handover/task.md" && grep -q '^Merge base: ' "$RUN/handover/task.md" && ! grep -q '^base: ' "$TMP/p.out"; echo $?)"
run_rr cleanup "$RUN" > /dev/null

# --- 6. The SKILL.md move: SKILL.md, references/workflow.md and references/inputs.md hold the pinned
# sentence multiset; the router's own text is headings, tables and block quotes only.
# Sentences: the text of both files with fenced blocks, headings, table rows and block quotes
# removed (the navigation the move added is only those), link targets dropped (the move changes
# relative paths, never link text), list markers and emphasis stripped, split after ". ",
# trimmed, empty ones dropped, sorted. The pin is SKILL.md's multiset at the commit before the
# move, 224 sentences, with the one deliberate rule change of that commit applied (Step 9: the
# posting login's own reviews are left out of a render-only run too; review-run.md, Workflow
# move). A later edit of a step's text updates the pin on purpose; on a mismatch, set
# REVIEW_RUN_SENTENCES=<file> to write the list and compare it with the previous one.
# Updated for Rule 3's second exception, the test pass, and its Rule 5 paragraph (test-pass.md);
# the plan pass's measured packaging-script sentence moved to plan-pass.md, Limits.
# Updated for the closing issues that now cross in Step 6 (github-io.md, Issue Text), and their origin in Rule 2.
# Updated for Rule 2's origin sentence, shortened to keep SKILL.md under 16384 bytes.
# Updated for the Don't activate line that points a fix and push to terraform-module-pr-fix, with two
# sentences of Rules 2 and 3 shortened to keep SKILL.md under 16384 bytes.
sentences() {
  cat "$@" | awk '/^```/{f=!f; next} f{next} /^#/{next} /^\|/{next} /^>/{next} {print}' |
    perl -pe 's/\]\([^)]*\)/]/g; s/^\s*-\s+//; s/\*\*//g; s/\. (?=[A-Z`\[*(])/.\n/g' |
    sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$' | LC_ALL=C sort
}
sentences "$SKILL/SKILL.md" "$SKILL/references/workflow.md" "$SKILL/references/inputs.md" > "$TMP/sentences"
[ -z "${REVIEW_RUN_SENTENCES:-}" ] || cp "$TMP/sentences" "$REVIEW_RUN_SENTENCES"
got="$(git hash-object "$TMP/sentences" | cut -c1-12)"
want=b87149b5c3e2
check "SKILL.md is at most 16384 bytes, the run guide review-run.md at most 10240" \
  "$([ "$(wc -c < "$SKILL/SKILL.md")" -le 16384 ] && [ "$(wc -c < "$SKILL/references/review-run.md")" -le 10240 ]; echo $?)"
check "the workflow move keeps the sentence multiset ($got)" "$([ "$got" = "$want" ]; echo $?)"

echo
[ "$fails" -eq 0 ] && echo "all checks passed" || echo "$fails check(s) failed"
[ "$fails" -eq 0 ]
