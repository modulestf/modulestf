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
#   - a failed validate at light escalates, a schema escalation at focused escalates;
#   - the pr-review SKILL.md workflow move: the sentence multiset of SKILL.md and
#     references/workflow.md is the pinned one, navigation lines excluded.
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
cat > "$SK/depth.sh" <<'EOF'
#!/bin/bash
# stub: compute writes depth.json at $DEPTH_STUB; verify passes unless $DEPTH_VERIFY_FAIL; escalate logs
echo "$*" >> "${STUB_LOG:?}"
case "$1" in
  compute)
    while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
    jq -n --arg d "${DEPTH_STUB:-light}" '{format: 1, depth: $d, reasons: (if $d == "light" then ["light-docs-only"] else ["focused-within-limits"] end),
      checks_out_of_scope: (if $d == "light" then ["A", "B", "D", "G-ladder"] else [] end),
      examples_selected: ["examples/one"], examples_out_of_scope: [], touched_types: ["aws_s3_bucket"],
      walk: {complete: true, unwalked: 0}, limits: {tf_files: 0, changed_lines: 2, changed_blocks: 0, selected_examples: 1}}' > "$out" ;;
  verify) [ -z "${DEPTH_VERIFY_FAIL:-}" ] || exit 1 ;;
  escalate) jq --arg r "$3" '.depth = "deep" | .reasons += [$r]' "$2" > "$2.t" && mv "$2.t" "$2" ;;
esac
EOF
cat > "$SK/schema-pass.sh" <<'EOF'
#!/bin/bash
echo "schema $SCHEMA_DEPTH $*" >> "${STUB_LOG:?}"
echo "schema pass: escalate overflow"; exit 3
EOF
cat > "$SK/ladder-pass.sh" <<'EOF'
#!/bin/bash
echo "ladder $*" >> "${STUB_LOG:?}"
[ "$1" = acquire ] && { echo "acquisition failed: stub"; exit 1; }
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
  repos/*/pulls/*) f=meta ;;
  repos/*/compare/*) f=compare ;;
  repos/*/git/trees/*) f="tree-${ep##*/}" ;;
  repos/*/issues/*/timeline) f=empty ;;
  repos/*/commits/*/check-runs) f=runs ;;
  repos/*/commits/*/status) f=status ;;
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
  validate) [ ! -f validate.fail ] || { echo "Error: stub failure"; exit 1; } ;;
esac
EOF
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/mtf-facts"
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/docker"
chmod +x "$TMP/bin/"*

# The remote: a bare repository the clone reaches through a url rewrite set in the environment.
mkrepo() { # name, extra files... -> bare repo with base and head commits; sets HEADC BASEC
  local w="$TMP/work-$1" b="$TMP/remote/example-org/$1.git"
  rm -rf "$w" "$b"; mkdir -p "$w"; git init -q "$w"
  (cd "$w" && mkdir -p examples/one && printf 'resource "x" "y" {}\n' > main.tf &&
    : > variables.tf && printf 'terraform {}\n' > versions.tf && printf 'module "m" { source = "../.." }\n' > examples/one/main.tf &&
    printf '# w\n' > README.md && git add -A && git -c user.name=t -c user.email=t@t commit -q -m base)
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
  echo '{"total_count": 1, "state": "success"}' > "$GHD/status"
}

RR="$SK/review-run.sh"
export PATH="$TMP/bin:$PATH" TMPDIR="$TMP/root" HOST_PASS_WAIT=0 XDG_CACHE_HOME="$TMP/cache"
mkdir -p "$TMPDIR"
unset CI GITHUB_ACTIONS GITHUB_RUN_ID
run_rr() { (cd "$TMP/cwd" && bash "$RR" "$@"); } # every run from a scratch cwd, to catch a stray file
mkdir -p "$TMP/cwd"
no_stray() { [ -z "$(find "$TMP/cwd" "$TMP/root" -maxdepth 4 \( -name x -o -name y -o -name b \) -print 2> /dev/null | grep -v '/clone/\|/base/')" ]; echo $?; }

# --- 1. Acceptance from the synthetic fixture ---------------------------------------------------
ROOTD="$(cd "$TMPDIR" && pwd -P)"
FR="$(mktemp -d "$ROOTD/pr-review.XXXXXX")"
cp -R "$FX/." "$FR/"; rm -rf "$FR/expected" "$FR/reviewer"; mkdir "$FR/clone"
run_rr handover "$FR" > "$TMP/h.out"
sed "s#^Workspace: $FR/clone\$#Workspace: RUN/clone#" "$FR/handover/task.md" > "$TMP/task.norm"
check "acceptance: handover reproduces the hand-assembled task byte for byte" "$(cmp -s "$TMP/task.norm" "$FX/expected/task.md"; echo $?)"
check "acceptance: handover reproduces the hand-assembled verification record" "$(cmp -s "$FR/handover/record.txt" "$FX/expected/record.txt"; echo $?)"
check "acceptance: handover prints at most 30 lines" "$(lines_ok "$TMP/h.out")"
run_rr render "$FR" --findings "$FX/reviewer/findings.json" --assessment "$FX/reviewer/assessment.txt" \
  --summary "$FX/reviewer/summary.txt" --out "$TMP/render1" > "$TMP/r.out"
check "acceptance: render reproduces the current renderer's comment byte for byte" "$(cmp -s "$TMP/render1/comment.md" "$FX/expected/comment.md"; echo $?)"
check "acceptance: render prints the render line" "$(grep -q '^rendered approve with nits (ladder rule 7), proposed event COMMENT, tier COMPACT$' "$TMP/r.out"; echo $?)"
check "acceptance: the run file carries the counts of the summary line" \
  "$(q "$FR/render/run-file.json" '.counts == {"instruction-like-text-from-others": 0, "conversation-claims-unread": 0, "review.quoted-claim-unverifiable": 1} and (has("depth") | not)')"
check "acceptance: render refuses an output directory inside the run" \
  "$(run_rr render "$FR" --findings "$FX/reviewer/findings.json" --assessment "$FX/reviewer/assessment.txt" --out "$FR/o" > /dev/null 2>&1; [ $? != 0 ]; echo $?)"
echo 'not json' > "$TMP/bad.json"
check "acceptance: render refuses findings that are not a list" \
  "$(run_rr render "$FR" --findings "$TMP/bad.json" --assessment "$FX/reviewer/assessment.txt" --out "$TMP/render2" > /dev/null 2>&1; [ $? = 1 ]; echo $?)"

# --- 2. prepare to render on a light change with hostile names -------------------------------------
mkrepo widget; ghfiles open false CHANGES_REQUESTED
run_rr prepare --repo example-org/widget --pr 7 --render-only > "$TMP/p.out" 2> "$TMP/p.err"
RUN="$(sed -n 's/^RUN=//p' "$TMP/p.out")"
check "prepare: prints the run directory and exits 0" "$([ -d "$RUN" ] && grep -q '^next: ' "$TMP/p.out"; echo $?)"
check "prepare: prints at most 30 lines" "$(lines_ok "$TMP/p.out")"
check "prepare: the clone holds the head and the base worktree the merge base" \
  "$([ "$(git -C "$RUN/clone" rev-parse HEAD)" = "$HEADC" ] && [ "$(git -C "$RUN/base" rev-parse HEAD)" = "$BASEC" ]; echo $?)"
check "prepare: git merge-base --all of the base and the head is the merge base alone" \
  "$([ "$(git -C "$RUN/clone" merge-base --all "$BASEC" HEAD)" = "$BASEC" ]; echo $?)"
check "prepare: index.json holds the enumerated fields" \
  "$(jq -e --arg h "$HEADC" '.status == "ok" and .head == $h and .depth == "light"
    and .reasons == ["light-docs-only"] and .checks_out_of_scope == ["A", "B", "D", "G-ladder"]
    and .signals.checks == "accepted" and .counts.files == 3 and .counts.changed_files == 3 and .plan == "no-profile"' "$RUN/index.json" > /dev/null; echo $?)"
check "prepare: index.json carries no title, body or branch text" "$(! grep -q 'touch\|author1\|feat' "$RUN/index.json"; echo $?)"
check "prepare: nothing in a title, branch or file name ran" "$(no_stray)"
check "prepare: depth.sh got the base SHA, the merge base worktree and the affected file" \
  "$(grep -q "^compute --clone $RUN/clone --base-tree $RUN/base --base $BASEC --files $RUN/host/files.json --classify $RUN/behaviour/behaviour.json --affected $RUN/affected.json --out $RUN/depth.json\$" "$STUB_LOG"; echo $?)"
check "prepare: a failed mtf-facts affected leaves {} for depth.sh" "$(q "$RUN/affected.json" '. == {}')"
check "defect: task.md carries the Write short line word for word" \
  "$(grep -qxF 'Write short: a `summary` of at most 200 characters and a `suggested_fix` of at most 250, or at most 600 for a `needs decision:` fix, one clause per option. The hard caps stay 500 and 600. A finding over the short targets is valid; the COMPACT render refuses it, and the comment renders in STANDARD only with `--standard`.' "$RUN/host/task.md"; echo $?)"
check "defect: the posting login's own CHANGES_REQUESTED is left out of a render-only run" \
  "$(q "$RUN/host/host.json" '.signals.review_decision == "none" and .own_review.state == "CHANGES_REQUESTED"')"
check "records files.json keeps additions and deletions" "$(q "$RUN/host/files.json" 'all(.[]; .additions == 1 and .deletions == 0)')"

touch "$RUN/clone/examples/one/validate.fail"
run_rr verify "$RUN" > "$TMP/v.out"
check "verify: a failed validate at light escalates to deep" \
  "$(grep -q '^depth: escalated to deep (deep-validate-failed)$' "$TMP/v.out" && q "$RUN/depth.json" '.depth == "deep"' | grep -qx 0; echo $?)"
check "verify: prints at most 30 lines" "$(lines_ok "$TMP/v.out")"
run_rr plan "$RUN" > "$TMP/pl.out"
check "plan: with no profile the coverage is --no-plan" \
  "$(q "$RUN/coverage.json" '.class == "none" and .unplanned == [{"dir": "examples/one", "reason": "no AWS profile named"}]')"
EVAL=1 run_rr ladder "$RUN" > "$TMP/l.out"
check "ladder: the claims evaluation ran" "$([ -f "$RUN/behaviour/run-behaviour.json" ]; echo $?)"
run_rr handover "$RUN" > "$TMP/ho.out"
T="$RUN/handover/task.md"
check "handover: Workspace first, Depth line before the block, record inside it" \
  "$([ "$(head -n 1 "$T")" = "Workspace: $RUN/clone" ] && grep -qx "Depth: $RUN/depth.json" "$T" &&
     awk '/^Depth: /{d=NR} /^UNTRUSTED-[0-9a-f]{12} BEGIN$/{b=NR} /^RECORD-[0-9a-f]{12}$/{r=NR} END{exit !(d < b && b < r)}' "$T"; echo $?)"
check "handover: the failed validate crosses with its decisive line" \
  "$(grep -q '^examples/one (all): terraform init -backend=false exit 0, terraform validate exit 1: Error: stub failure; at the merge base: ' "$RUN/handover/record.txt"; echo $?)"
check "handover: the title's text stays inside the block" \
  "$(awk '/^UNTRUSTED-[0-9a-f]{12} BEGIN$/{exit} /title|body/{f=1} END{exit f}' "$T"; echo $?)"
echo '[]' > "$TMP/f0.json"; echo 'Docs only.' > "$TMP/a0.txt"
run_rr render "$RUN" --findings "$TMP/f0.json" --assessment "$TMP/a0.txt" --out "$TMP/render3" > "$TMP/re.out" 2>&1
check "render: the run file carries depth and the verify gaps" \
  "$(q "$RUN/render/run-file.json" '.depth.depth == "deep" and .counts == null and .verify_gaps == [] and .examples == {count: 1, validated: 0}')"
check "render: prints at most 30 lines" "$(lines_ok "$TMP/re.out")"
DEPTH_VERIFY_FAIL=1 run_rr render "$RUN" --findings "$TMP/f0.json" --assessment "$TMP/a0.txt" --out "$TMP/render4" > "$TMP/re2.out" 2>&1
check "render: a depth binding that does not verify renders nothing" "$([ $? = 1 ] && [ ! -e "$TMP/render4/comment.md" ]; echo $?)"
check "after every subcommand nothing in a host string ran" "$(no_stray)"
run_rr cleanup "$RUN" > /dev/null
check "cleanup: the run directory is gone" "$([ ! -e "$RUN" ]; echo $?)"

# --- 3. focused: a schema escalation goes to deep --------------------------------------------------
DEPTH_STUB=focused run_rr prepare --repo example-org/widget --pr 7 > "$TMP/p2.out" 2>&1
RUN="$(sed -n 's/^RUN=//p' "$TMP/p2.out")"
run_rr schema "$RUN" > "$TMP/s.out"
check "schema: an escalation at focused sets depth deep with its reason" \
  "$(grep -q '^depth: escalated to deep (deep-schema-overflow)$' "$TMP/s.out" && grep -q "^schema $RUN/depth.json $RUN/facts $RUN/schema-work\$" "$STUB_LOG"; echo $?)"
run_rr cleanup "$RUN" > /dev/null

# --- 4. merged pull request, several module roots ----------------------------------------------------
ghfiles closed true APPROVED
run_rr prepare --repo example-org/widget --pr 7 > "$TMP/p3.out" 2>&1
RUN="$(sed -n 's/^RUN=//p' "$TMP/p3.out")"
check "defect: a merged pull request has mergeability not-applicable" "$(q "$RUN/host/host.json" '.signals.mergeability == "not-applicable" and .state.merged')"
run_rr cleanup "$RUN" > /dev/null
HT="$GHD/tree-$HEADC"
jq '.tree |= map(select(.path | IN("main.tf", "variables.tf", "versions.tf") | not))
  + [{path: "modules/a/main.tf"}, {path: "modules/a/variables.tf"}, {path: "modules/a/versions.tf"},
     {path: "modules/b/main.tf"}, {path: "modules/b/variables.tf"}, {path: "modules/b/versions.tf"}]
  | .tree |= map(. + {mode: (.mode // "100644"), type: (.type // "blob"), sha: (.sha // "0000000000000000000000000000000000000000"), size: (.size // 1)})' \
  "$HT" > "$HT.t" && mv "$HT.t" "$HT"
ghfiles open false APPROVED
run_rr prepare --repo example-org/widget --pr 7 > "$TMP/p4.out" 2>&1
RUN="$(sed -n 's/^RUN=//p' "$TMP/p4.out")"
check "defect: several module roots and changed paths in none of them is refused with a fixed reason" \
  "$([ "$(q "$RUN/index.json" '. == {format: 1, status: "refused", reason: "several-module-roots"}')" = 0 ] && grep -q 'the run is inconclusive' "$TMP/p4.out"; echo $?)"
check "a refused run takes no later subcommand" "$(run_rr handover "$RUN" > /dev/null 2>&1; [ $? = 1 ]; echo $?)"
jq '[{filename: "modules/a/main.tf", status: "modified", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-a\n+b"}]' -n > "$GHD/files"
HP="$SK/host-pass.sh"
GH_TOKEN=x bash "$HP" run --repo example-org/widget --pr 7 --login octo-reviewer --out "$TMP/hp1" > /dev/null 2>&1
check "defect: several module roots resolve to the one holding every changed path" "$(q "$TMP/hp1/host.json" '.prefix == "modules/a"')"
check "host-pass: an empty login is refused without --render-only" \
  "$(GH_TOKEN=x bash "$HP" run --repo example-org/widget --pr 7 --login "" --out "$TMP/hp2" > /dev/null 2>&1; [ $? = 2 ]; echo $?)"

# --- 5. usage and run directory refusals --------------------------------------------------------------
check "usage: a run directory outside the pattern is refused" "$(run_rr verify /tmp > /dev/null 2>&1; [ $? = 2 ]; echo $?)"
check "usage: a repository with a shell word is refused" "$(run_rr prepare --repo 'a/$(touch x)' --pr 1 > /dev/null 2>&1; [ $? = 2 ]; echo $?)"
check "usage: --owner-depth takes only deep" "$(run_rr prepare --repo a/b --pr 1 --owner-depth light > /dev/null 2>&1; [ $? = 2 ]; echo $?)"
check "the script has no eval and no bash -c" "$(! grep -nE '(^|[;&|(])[[:space:]]*eval[[:space:]]|bash -c' "$SKILL/references/review-run.sh"; echo $?)"
check "nothing in a host string ran, end of run" "$(no_stray)"

# --- 6. The workflow move: SKILL.md + references/workflow.md hold the pinned sentence multiset --------
# Sentences: the text of both files with fenced blocks, headings, table rows and block quotes
# removed (the navigation the move added is only those), link targets dropped (the move changes
# relative paths, never link text), list markers and emphasis stripped, split after ". ",
# trimmed, empty ones dropped, sorted. The pin is SKILL.md's multiset at the commit before the
# move, 224 sentences, with the one deliberate rule change of that commit applied (Step 9: the
# posting login's own reviews are left out of a render-only run too; review-run.md, Workflow
# move). A later edit of a step's text updates the pin on purpose; on a mismatch, set
# REVIEW_RUN_SENTENCES=<file> to write the list and compare it with the previous one.
sentences() {
  cat "$@" | awk '/^```/{f=!f; next} f{next} /^#/{next} /^\|/{next} /^>/{next} {print}' |
    perl -pe 's/\]\([^)]*\)/]/g; s/^\s*-\s+//; s/\*\*//g; s/\. (?=[A-Z`\[*(])/.\n/g' |
    sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$' | LC_ALL=C sort
}
sentences "$SKILL/SKILL.md" "$SKILL/references/workflow.md" > "$TMP/sentences"
[ -z "${REVIEW_RUN_SENTENCES:-}" ] || cp "$TMP/sentences" "$REVIEW_RUN_SENTENCES"
got="$(git hash-object "$TMP/sentences" | cut -c1-12)"
want=e874ff98c3b6
check "the workflow move keeps the sentence multiset ($got)" "$([ "$got" = "$want" ]; echo $?)"

echo
[ "$fails" -eq 0 ] && echo "all checks passed" || echo "$fails check(s) failed"
[ "$fails" -eq 0 ]
