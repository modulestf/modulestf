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
cat > "$SK/schema-pass.sh" <<'EOF'
#!/bin/bash
echo "schema $SCHEMA_DEPTH $*" >> "${STUB_LOG:?}"
echo "schema-env $SCHEMA_HEAD $SCHEMA_MERGE_BASE $(tr "\n" " " <<< "$SCHEMA_INPUTS")" >> "$STUB_LOG"
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
  *) exit 1 ;;
esac
EOF
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/docker"
chmod +x "$TMP/bin/"*

# The remote: a bare repository the clone reaches through a url rewrite set in the environment.
mkrepo() { # name, extra files... -> bare repo with base and head commits; sets HEADC BASEC
  local w="$TMP/work-$1" b="$TMP/remote/example-org/$1.git"
  rm -rf "$w" "$b"; mkdir -p "$w"; git init -q "$w"
  (cd "$w" && mkdir -p examples/one examples/two && printf 'resource "x" "y" {}\n' > main.tf &&
    printf 'module "m" { source = "../.." }\n' > examples/two/main.tf &&
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
     grep -qx "Output: write the findings list as JSON to $RUN/review/findings.json, the summary line to $RUN/review/summary.txt and the facts comparison note to $RUN/review/facts-comparison.txt, and nothing else." "$T" &&
     [ -d "$RUN/review" ]; echo $?)"
check "handover: the title's text stays inside the block" \
  "$(awk '/^UNTRUSTED-[0-9a-f]{12} BEGIN$/{exit} /title|body/{f=1} END{exit f}' "$T"; echo $?)"
render_to "$TMP/render-light"
check "render light: the real render-comment.sh states the depth, its reasons and what is out of scope" \
  "$(grep -qF 'Review depth: light. Reasons: `light-docs-only`.' "$TMP/render-light/comment.md" &&
     grep -qF 'Out of scope at this depth, so not unknowns: Check A, Check B, Check D, Check G beyond its claim reading, the plan pass' "$TMP/render-light/comment.md"; echo $?)"
check "render light: the run file carries depth, no gaps and the example counts" \
  "$(q "$RUN/render/run-file.json" '.depth.depth == "light" and .counts == null and .verify_gaps == [] and .examples == {count: 2, validated: 2}')"
check "render: prints at most 30 lines" "$(lines_ok "$TMP/re.out")"
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
run_rr schema "$RUN" > "$TMP/s.out"
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
SCHEMA_STUB=ok run_rr schema "$RUN" > "$TMP/s.out"
run_rr handover "$RUN" > /dev/null
check "handover at focused after schema names the fact sheets" "$(grep -qx "Provider fact sheets: $RUN/facts" "$RUN/handover/task.md"; echo $?)"
check "handover at focused after schema names the schema handoff" \
  "$(grep -qx "Schema handoff: $RUN/schema-handoff/schema-handoff.json.gz" "$RUN/handover/task.md" && grep -qx 'schema: handoff written, 1 directories, 1 provider schemas' "$TMP/s.out"; echo $?)"
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
SCHEMA_STUB=overflow run_rr schema "$RUN" > "$TMP/s.out" 2>&1
check "an escalation after the handover is refused and stops the run" \
  "$([ $? = 1 ] && grep -q 'escalation after the handover' "$RUN/state/stop" && [ "$(jq -r .depth "$RUN/depth.json")" = focused ]; echo $?)"
run_rr cleanup "$RUN" > /dev/null

DEPTH_STUB=focused prep
run_rr schema "$RUN" > "$TMP/s.out"
check "schema: an escalation at focused sets depth deep with its reason" \
  "$(grep -q '^depth: escalated to deep (deep-schema-overflow)$' "$TMP/s.out" && grep -q '^schema: escalated to deep (reason overflow)$' "$TMP/s.out" && grep -q "^schema $RUN/depth.json $RUN/facts $RUN/schema-work $RUN/schema-handoff\$" "$STUB_LOG"; echo $?)"
check "schema: an escalation removes the handoff with the fact sheets" "$([ ! -e "$RUN/schema-handoff" ] && [ ! -e "$RUN/facts" ]; echo $?)"
run_rr cleanup "$RUN" > /dev/null

DEPTH_STUB=focused prep
SCHEMA_STUB=ok run_rr schema "$RUN" > /dev/null
touch "$RUN/clone/examples/two/validate.fail"
run_rr verify "$RUN" > "$TMP/v.out"
check "verify: a new validate failure in an out-of-scope example escalates a focused run" \
  "$(grep -q '^depth: escalated to deep (deep-validate-failed)$' "$TMP/v.out" && [ "$(q "$RUN/depth.json" '.examples_out_of_scope == []')" = 0 ]; echo $?)"
run_rr cleanup "$RUN" > /dev/null

DEPTH_STUB=deep prep
SCHEMA_STUB=deeppartial run_rr schema "$RUN" > "$TMP/s.out"
check "schema at deep: a deep partial line is a success, its source lines recorded" \
  "$(grep -q '^schema: schema pass: deep partial page' "$TMP/s.out" && [ "$(cat "$RUN/state/schema")" = ok ] && [ -f "$RUN/facts/missing.json" ] &&
     [ "$(grep -c . "$RUN/state/schema-sources.txt")" = 1 ]; echo $?)"
full; run_rr handover "$RUN" > /dev/null
check "schema at deep: partial sheets are named in the handover" "$(grep -qx "Provider fact sheets: $RUN/facts" "$RUN/handover/task.md"; echo $?)"
run_rr cleanup "$RUN" > /dev/null

DEPTH_STUB=focused prep
SCHEMA_STUB=badsource run_rr schema "$RUN" > "$TMP/s.out"
check "schema: a source line outside its grammar escalates and nothing of it is recorded" \
  "$(grep -q '^depth: escalated to deep (deep-schema-source-line)$' "$TMP/s.out" && [ ! -e "$RUN/state/schema-sources.txt" ] && [ ! -e "$RUN/facts" ]; echo $?)"
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
# Negative self-check: each weakened copy must fail the case it weakens.
si_mut() { # name, perl expression, commits as one word, expected output of the original
  local m="$TMP/si-$1.sh"; perl -pe "$2" "$RR" > "$m"
  if cmp -s "$RR" "$m"; then check "self-check: schema_inputs mutation $1 changes the script" 1; return; fi
  check "self-check: schema_inputs mutation $1 is caught" "$([ "$(si "$m" $3)" != "$4" ]; echo $?)"
}
si_mut no-size 's/\]\] && \[ "\$s" -le 1048576 \] \|\| continue$/]] || continue/' "$SIC" "$(si "$SIC")"
si_mut no-mode 's/\^100\(644\|755\)\$/^[0-9]+\$/' "$SIC" "$(si "$SIC")"
si_mut no-charset 's/\[\[ "\$p" =~ \^\[A-Za-z0-9\._\/-\]\+\$ && /[[ /' "$SIN" 'status 1'
si_mut no-cap 's/\[ "\$n" -le 600 \] && //' "$SIM $SIC" 'status 1'

# The handover's depth.sh verify, and a mutation without it: a head moved after prepare is caught.
DEPTH_STUB=focused prep
SCHEMA_STUB=ok run_rr schema "$RUN" > /dev/null; full
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
    "$([ "$(jq -r '[.unplanned[].reason] | unique | join(",")' "$RUN/coverage.json")" = "$want" ] && grep -qx "plan: $want" "$TMP/pl.out"; echo $?)"
  run_rr cleanup "$RUN" > /dev/null
done

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

# --- 5. usage and run directory refusals --------------------------------------------------------------
check "usage: a run directory outside the pattern is refused" "$(run_rr verify /tmp > /dev/null 2>&1; [ $? = 2 ]; echo $?)"
check "usage: a repository with a shell word is refused" "$(run_rr prepare --repo 'a/$(touch x)' --pr 1 > /dev/null 2>&1; [ $? = 2 ]; echo $?)"
check "usage: a profile name that starts like an option is refused" \
  "$(run_rr prepare --repo a/b --pr 1 --profile -x --role-arn arn:aws:iam::000000000000:role/r > /dev/null 2>&1; [ $? = 2 ]; echo $?)"
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
sentences() {
  cat "$@" | awk '/^```/{f=!f; next} f{next} /^#/{next} /^\|/{next} /^>/{next} {print}' |
    perl -pe 's/\]\([^)]*\)/]/g; s/^\s*-\s+//; s/\*\*//g; s/\. (?=[A-Z`\[*(])/.\n/g' |
    sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$' | LC_ALL=C sort
}
sentences "$SKILL/SKILL.md" "$SKILL/references/workflow.md" "$SKILL/references/inputs.md" > "$TMP/sentences"
[ -z "${REVIEW_RUN_SENTENCES:-}" ] || cp "$TMP/sentences" "$REVIEW_RUN_SENTENCES"
got="$(git hash-object "$TMP/sentences" | cut -c1-12)"
want=e874ff98c3b6
check "SKILL.md is at most 16384 bytes, the run guide review-run.md at most 10240" \
  "$([ "$(wc -c < "$SKILL/SKILL.md")" -le 16384 ] && [ "$(wc -c < "$SKILL/references/review-run.md")" -le 10240 ]; echo $?)"
check "the workflow move keeps the sentence multiset ($got)" "$([ "$got" = "$want" ]; echo $?)"

echo
[ "$fails" -eq 0 ] && echo "all checks passed" || echo "$fails check(s) failed"
[ "$fails" -eq 0 ]
