#!/bin/bash
# shellcheck disable=SC2319 # "$(<test>; echo $?)" passes the test's own status to check
# Self-check for references/merge-run.sh of terraform-module-pr-merge: the identity, the plan and
# pin checks, every merge precondition with its reason, the show, the confirmation values, the
# re-read before the merge, the one PUT and its four fields, and the 405 answer. No git and no
# network: gh is a stub on PATH that answers from fixture JSON and records its argv and each PUT.
# A negative self-check runs mutated temp copies of the script and confirms each named case fails.
# Needs bash, jq and perl.
# Run: tests/pr-merge-test.sh (KEEP=1 keeps the temporary directory)
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
SKILLS="$SRC/.agents/skills"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pr-merge-test.XXXXXX")" && pwd -P)" && [ -n "$TMP" ] || { echo "FAIL no temporary directory"; exit 1; }
[ -n "${KEEP:-}" ] || trap 'chmod -R u+w "$TMP" 2> /dev/null; rm -rf "$TMP"' EXIT
fails=0
MR="$SKILLS/terraform-module-pr-merge/references/merge-run.sh" # the script under test; the self-check swaps in mutated copies
check() { if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
[ -f "$MR" ] || { echo "FAIL no $MR"; exit 1; }
mr() { bash "$MR" "$@"; }
outof() { "$@" 2>&1; true; }

FX="$TMP/fx"; BIN="$TMP/bin"; OUTD="$TMP/out"
mkdir -p "$BIN" "$OUTD"
export PATH="$BIN:$PATH"
GITLOG="$TMP/git.log"; : > "$GITLOG"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 1\n' "$GITLOG" > "$BIN/git"; chmod +x "$BIN/git" # logs any git call
unset CI GITHUB_ACTIONS GITHUB_RUN_ID

H=0123456789abcdef0123456789abcdef01234567
B=89abcdef0123456789abcdef0123456789abcdef
M=fedcba9876543210fedcba9876543210fedcba98
C=1111111111111111111111111111111111111111

cat > "$BIN/gh" <<EOF
#!/bin/bash
FX="$FX"
EOF
cat >> "$BIN/gh" <<'EOF'
printf '%s\n' "$*" >> "$FX/gh-argv.log"
[ "$1" = api ] || exit 1
shift
ep=""; put=false; slurp=false
while [ $# -gt 0 ]; do
  case "$1" in
    -X) [ "$2" = PUT ] && put=true; shift 2 ;;
    --input) shift 2 ;;
    --paginate) shift ;;
    --slurp) slurp=true; shift ;;
    *) ep="$1"; shift ;;
  esac
done
ep="${ep%%\?*}"
if [ "$put" = true ]; then
  { printf '%s ' "$ep"; jq -c .; } >> "$FX/put.log"
  [ ! -f "$FX/put-405" ] || { echo '{"message": "Pull Request is not mergeable"}'; echo "gh: Pull Request is not mergeable (HTTP 405)" >&2; exit 1; }
  # put-fail: a PUT that fails with the error line the file holds, such as a timeout
  [ ! -f "$FX/put-fail" ] || { cat "$FX/put-fail" >&2; exit 1; }
  echo "{\"sha\": \"$(cat "$FX/merge-sha")\", \"merged\": true, \"message\": \"Pull Request successfully merged\"}"; exit 0
fi
# read-fail-after-put: every read after a PUT fails
[ ! -f "$FX/read-fail-after-put" ] || [ ! -s "$FX/put.log" ] || exit 1
f="$FX/api/$ep.json"; [ -f "$f" ] || exit 1
# A fixture with a .second file answers its first read from the fixture and every later read from .second.
if [ -f "$f.second" ]; then [ ! -f "$f.seen" ] || f="$f.second"; touch "$FX/api/$ep.json.seen"; fi
# A list fixture holds its pages; without --slurp gh prints them one after another.
if [ "$slurp" = true ] || [ ! -f "$FX/api/$ep.json.pages" ]; then cat "$f"; else jq -c '.[]' "$f"; fi
EOF
chmod +x "$BIN/gh"

# fixtures: a clean, approved, open pull request o/r#7 with passing checks
fresh() {
  rm -rf "$FX"; mkdir -p "$FX/api/repos/o/r/pulls/7" "$FX/api/repos/o/r/commits/$H" "$FX/api/repos/o/r/compare" \
    "$FX/api/repos/o/r/collaborators/alice" "$FX/api/repos/o/r/commits"
  printf '%s\n' "$C" > "$FX/merge-sha"
  echo '{"login": "alice", "id": 1, "type": "User"}' > "$FX/api/user.json"
  echo '{"permission": "admin"}' > "$FX/api/repos/o/r/collaborators/alice/permission.json"
  echo '{"full_name": "o/r", "allow_squash_merge": true}' > "$FX/api/repos/o/r.json"
  jq -n --arg h "$H" --arg b "$B" '{number: 7, state: "open", merged: false, draft: false, locked: false,
    mergeable_state: "clean", title: "feat: Add the x input", merge_commit_sha: null,
    base: {ref: "main", sha: $b, repo: {full_name: "o/r"}}, head: {ref: "fix/x", sha: $h, repo: {full_name: "f/r"}}}' \
    > "$FX/api/repos/o/r/pulls/7.json"
  jq -n --arg m "$M" '{merge_base_commit: {sha: $m}}' > "$FX/api/repos/o/r/compare/$B...$H.json"
  echo '[{"total_count": 1, "check_runs": [{"id": 1, "name": "test", "status": "completed", "conclusion": "success"}]}]' \
    > "$FX/api/repos/o/r/commits/$H/check-runs.json"
  echo '[[{"id": 1, "context": "ci/lint", "state": "success"}]]' > "$FX/api/repos/o/r/commits/$H/statuses.json"
  echo '[[{"id": 1, "user": {"login": "bob", "id": 2}, "author_association": "MEMBER", "state": "CHANGES_REQUESTED"},
    {"id": 2, "user": {"login": "bob", "id": 2}, "author_association": "MEMBER", "state": "APPROVED"},
    {"id": 3, "user": {"login": "eve", "id": 3}, "author_association": "NONE", "state": "CHANGES_REQUESTED"}]]' \
    > "$FX/api/repos/o/r/pulls/7/reviews.json"
  touch "$FX/api/repos/o/r/commits/$H/check-runs.json.pages" "$FX/api/repos/o/r/commits/$H/statuses.json.pages" \
    "$FX/api/repos/o/r/pulls/7/reviews.json.pages"
  jq -n --arg b "$B" '{sha: "x", parents: [{sha: $b}]}' > "$FX/api/repos/o/r/commits/$C.json"
  : > "$FX/put.log"
}
fx() { local f="$FX/api/$1.json"; jq "$2" "$f" > "$f.tmp" && mv "$f.tmp" "$f"; } # edit a fixture with a jq filter
fx2() { local f="$FX/api/$1.json"; jq "$2" "$f" > "$f.second"; } # every read after the first answers the edited fixture
plan() { # writes the plan pr-review would leave in $RUN/review, edited by an optional jq filter
  jq -n --arg h "$H" --arg b "$B" --arg m "$M" '{kind: "review-plan", schema: 1,
    pin: {target: "o/r#7", number: 7, base_repo: "o/r", head_repo: "f/r", base_ref: "main", head_ref: "fix/x",
          head_sha: $h, base_sha: $b, merge_base: $m},
    verdict: "approve", proposed_event: "APPROVE", findings: [], read_at: (now | floor | todateiso8601),
    handover_block: "x", module_prefix: "", module_profile: null, reviewer_id: 1} | '"${1:-.}" > "$RUN/review/plan.json"
}
prep() { RUN="$(mr prepare --repo o/r --pr 7 --out "$OUTD" | sed -n 's/^RUN=//p')"; [ -d "$RUN" ]; }
puts() { wc -l < "$FX/put.log" | tr -d ' '; }
domerge() { mr merge "$RUN" --target o/r#7 --confirm-head "$H"; }

# --- happy path ----------------------------------------------------------------------------
fresh
o="$(mr prepare --repo o/r --pr 7 --out "$OUTD")"; s=$?
RUN="$(printf '%s\n' "$o" | sed -n 's/^RUN=//p')"
[ "$s" = 0 ] && [ -d "$RUN/review" ] && [ -z "$(ls -A "$RUN/review")" ]; check "prepare makes the run with an empty review directory" $?
printf '%s\n' "$o" | grep -qxF "next: review the head with pr-review render-only --out $RUN/review, then: gate $RUN"; check "prepare prints the next step" $?
[ "$(printf '%s\n' "$o" | wc -l)" -le 30 ]; check "prepare prints at most 30 lines" $?
plan
o="$(mr gate "$RUN")"; s=$?
[ "$s" = 0 ]; check "gate passes a clean approved pull request" $?
printf '%s\n' "$o" | grep -qxF "confirm with: merge $RUN --target o/r#7 --confirm-head $H"; check "gate prints the confirmation line with the full head" $?
printf '%s\n' "$o" | grep -qxF "head: $H" && printf '%s\n' "$o" | grep -qxF "base: main at $B"; check "gate shows the full head and the base ref and SHA" $?
printf '%s\n' "$o" | grep -qxF "title: feat: Add the x input (#7)" && printf '%s\n' "$o" | grep -qxF "method: squash"; check "gate shows the title and the method" $?
[ "$(printf '%s\n' "$o" | wc -l)" -le 30 ]; check "gate prints at most 30 lines" $?
[ -f "$RUN/merge.json" ] && [ ! -w "$RUN/merge.json" ] &&
  [ "$(jq -c 'keys' "$RUN/merge.json")" = '["checks","cut","method","pin","title","verdict"]' ]; check "gate writes merge.json read-only with its six keys" $?
[ "$(puts)" = 0 ]; check "gate sends no PUT" $?
o="$(domerge)"; s=$?
[ "$s" = 0 ] && printf '%s\n' "$o" | grep -q '^merged'; check "merge prints merged" $?
[ "$(puts)" = 1 ]; check "merge sends exactly one PUT" $?
[ "$(sed 's/^[^ ]* //' "$FX/put.log" | jq -c -S .)" = "$(jq -c -S -n --arg h "$H" '{sha: $h, merge_method: "squash", commit_title: "feat: Add the x input (#7)", commit_message: ""}')" ]
check "the PUT carries exactly sha, merge_method, commit_title and an empty commit_message" $?
[ "$(cut -d' ' -f1 "$FX/put.log")" = repos/o/r/pulls/7/merge ]; check "the PUT goes to the pull request's merge endpoint" $?
o="$(outof domerge)"
[ "$(puts)" = 1 ] && printf '%s\n' "$o" | grep -q 'ran already'; check "a second merge in the same run sends no PUT" $?
[ ! -s "$GITLOG" ]; check "the happy path makes no git call" $?
mr cleanup "$RUN" > /dev/null && [ ! -e "$RUN" ]; check "cleanup deletes the run directory" $?

# --- refusals: one precondition each, each with its reason and no PUT -----------------------
# refuse_gate <name> <reason substring> <setup command>: the setup runs after prepare and the plan
refuse_gate() {
  fresh; prep || { check "$1 (prepare failed)" 1; return; }
  plan; eval "$3"
  local o; o="$(outof mr gate "$RUN")"
  printf '%s\n' "$o" | grep -qF -- "$2" && [ ! -e "$RUN/merge.json" ] && [ "$(puts)" = 0 ]
  check "gate refuses $1: $2" $?
}
refuse_prepare() {
  fresh; eval "$3"
  local o s; o="$(mr prepare --repo o/r --pr 7 --out "$OUTD" 2>&1)"; s=$?
  [ "$s" != 0 ] && printf '%s\n' "$o" | grep -qF -- "$2" && ! printf '%s\n' "$o" | grep -q '^RUN='
  check "prepare refuses $1: $2" $?
}
refuse_prepare "a bot user" "the token user is not a person" "fx user '.type = \"Bot\" | .login = \"ci[bot]\"'"
refuse_prepare "CI=true" "a CI variable is set" "export CI=true"; unset CI
refuse_prepare "CI set but empty" "a CI variable is set" "export CI="; unset CI
refuse_prepare "GITHUB_ACTIONS set" "a CI variable is set" "export GITHUB_ACTIONS=true"; unset GITHUB_ACTIONS
refuse_prepare "GITHUB_RUN_ID set but empty" "a CI variable is set" "export GITHUB_RUN_ID="; unset GITHUB_RUN_ID
refuse_prepare "read permission" "has no write access" "fx repos/o/r/collaborators/alice/permission '.permission = \"read\"'"
refuse_prepare "a relative --out" "--out" "OUTD_SAVE=\$OUTD; OUTD=out"; OUTD="$OUTD_SAVE"
refuse_gate "plan kind applied" "the plan is not a review-plan stage file of schema 1" "plan '.kind = \"applied\"'"
refuse_gate "no plan" "the plan is not a regular file" "rm \"\$RUN/review/plan.json\""
refuse_gate "a plan read before this run started" "the plan is not this run's review" "plan '.read_at = \"2020-01-01T00:00:00Z\"'"
refuse_gate "a malformed read_at" "the plan is not this run's review" "plan '.read_at = \"2026-11-10 00:00:00\"'"
refuse_gate "a read_at that is not a time" "the plan is not this run's review" "plan '.read_at = \"2026-13-40T00:00:00Z\"'"
refuse_gate "the pin moved" "the pull request moved since the review: head_sha" "fx repos/o/r/pulls/7 '.head.sha = \"$B\"'; cp \"\$FX/api/repos/o/r/compare/$B...$H.json\" \"\$FX/api/repos/o/r/compare/$B...$B.json\""
refuse_gate "a retargeted base" "the pull request moved since the review: base_ref" "fx repos/o/r/pulls/7 '.base.ref = \"release\"'"
refuse_gate "verdict changes suggested" "the verdict is changes suggested, not approve or approve with nits" "plan '.verdict = \"changes suggested\"'"
refuse_gate "a pending check" "the checks are not passing: not passing: test" "fx repos/o/r/commits/$H/check-runs '.[0].check_runs[0].status = \"in_progress\" | .[0].check_runs[0].conclusion = null'"
refuse_gate "zero checks" "the checks are not passing: no checks yet" "echo '[{\"total_count\": 0, \"check_runs\": []}]' > \"\$FX/api/repos/o/r/commits/$H/check-runs.json\"; echo '[[]]' > \"\$FX/api/repos/o/r/commits/$H/statuses.json\""
refuse_gate "a failed status" "the checks are not passing: not passing: ci/lint" "fx repos/o/r/commits/$H/statuses '.[0][0].state = \"failure\"'"
refuse_gate "a failed checks read" "the checks are not passing: a checks read failed" "rm \"\$FX/api/repos/o/r/commits/$H/statuses.json\""
refuse_gate "mergeable_state unknown" "mergeable_state is unknown, not clean" "fx repos/o/r/pulls/7 '.mergeable_state = \"unknown\"'"
refuse_gate "a closed pull request" "the pull request is not open" "fx repos/o/r/pulls/7 '.state = \"closed\"'"
refuse_gate "a draft" "the pull request is a draft" "fx repos/o/r/pulls/7 '.draft = true'"
refuse_gate "a locked pull request" "the pull request is locked" "fx repos/o/r/pulls/7 '.locked = true'"
refuse_gate "a maintainer's latest review CHANGES_REQUESTED" "a write-capable reviewer requests changes: bob" \
  "fx repos/o/r/pulls/7/reviews '.[0] += [{id: 4, user: {login: \"bob\", id: 2}, author_association: \"MEMBER\", state: \"CHANGES_REQUESTED\"}]'"
refuse_gate "squash disallowed" "the repository does not allow squash merges" "fx repos/o/r '.allow_squash_merge = false'"
refuse_gate "a failed pull request read" "a read failed: pr" "rm \"\$FX/api/repos/o/r/pulls/7.json\""
refuse_gate "a failed compare read" "a read failed: compare" "rm \"\$FX/api/repos/o/r/compare/$B...$H.json\""
[ ! -s "$GITLOG" ]; check "the refusals make no git call" $?

# a dismissed latest review and a commenter's request do not block; approve with nits passes
fresh; prep; plan '.verdict = "approve with nits"'
fx repos/o/r/pulls/7/reviews '.[0] += [{id: 5, user: {login: "bob", id: 2}, author_association: "MEMBER", state: "DISMISSED"}]'
mr gate "$RUN" > /dev/null; check "gate passes approve with nits, a dismissed review and an outside request" $?

# a long title is cut and flagged
fresh; prep; plan
fx repos/o/r/pulls/7 ".title = \"$(printf 'a%.0s' $(seq 1 80))\""
o="$(mr gate "$RUN")"
printf '%s\n' "$o" | grep -qxF "title: $(printf 'a%.0s' $(seq 1 72)) (#7)" && printf '%s\n' "$o" | grep -q '^title cut: yes'; check "gate cuts a long title and flags it" $?

# --- the confirmation values ---------------------------------------------------------------
refuse_merge() { # name, reason substring, merge arguments, setup after the gate
  fresh; prep; plan; mr gate "$RUN" > /dev/null || { check "$1 (gate failed)" 1; return; }
  eval "${4-:}"
  local o; o="$(outof mr merge "$RUN" $3)"
  printf '%s\n' "$o" | grep -qF -- "$2" && [ "$(puts)" = 0 ]
  check "merge refuses $1: $2" $?
}
refuse_merge "a short --confirm-head" "--confirm-head must be the full 40-character head SHA" "--target o/r#7 --confirm-head ${H:0:12}"
refuse_merge "another head" "the head is not the one the gate showed" "--target o/r#7 --confirm-head $B"
refuse_merge "a --target of another pull request" "the target is not the pull request the gate showed" "--target o/r#8 --confirm-head $H"
refuse_merge "a --target of another repository" "the target is not the pull request the gate showed" "--target o/x#7 --confirm-head $H"
refuse_merge "no --target" "--target" "--confirm-head $H"
# Review Focus 4: a check turns failed between gate and merge
refuse_merge "a check failed after the gate" "the checks are not passing" "--target o/r#7 --confirm-head $H" \
  "fx repos/o/r/commits/$H/check-runs '.[0].check_runs[0].conclusion = \"failure\"'"
refuse_merge "a title edited after the gate" "changed since the gate: title" "--target o/r#7 --confirm-head $H" \
  "fx repos/o/r/pulls/7 '.title = \"feat: Something else\"'"
refuse_merge "a head pushed after the gate" "the pull request moved since the review: head_sha" "--target o/r#7 --confirm-head $H" \
  "fx repos/o/r/pulls/7 '.head.sha = \"$B\"'; cp \"\$FX/api/repos/o/r/compare/$B...$H.json\" \"\$FX/api/repos/o/r/compare/$B...$B.json\""
refuse_merge "a bot identity at merge" "the token user is not a person" "--target o/r#7 --confirm-head $H" "fx user '.type = \"Bot\"'"
refuse_merge "CI set at merge" "a CI variable is set" "--target o/r#7 --confirm-head $H" "export CI=1"; unset CI
refuse_merge "a merge before the gate" "run gate first" "--target o/r#7 --confirm-head $H" "chmod u+w \"\$RUN\"; chmod u+w \"\$RUN/merge.json\"; rm \"\$RUN/merge.json\""

# --- Review Focus 5: the 405 answer ----------------------------------------------------------
# The merge commit is a real squash: one parent, the base tip, never the head.
fresh; prep; plan; mr gate "$RUN" > /dev/null
touch "$FX/put-405"
fx2 repos/o/r/pulls/7 ".merged = true | .state = \"closed\" | .merge_commit_sha = \"$C\""
fx repos/o/r/commits/$C ".parents = [{sha: \"$B\"}]"
o="$(domerge)"; s=$?
[ "$s" = 0 ] && printf '%s\n' "$o" | grep -q '^merged' && [ "$(puts)" = 1 ]; check "a 405 with the pull request merged at the confirmed head reports merged, no second PUT" $?

fresh; prep; plan; mr gate "$RUN" > /dev/null
touch "$FX/put-405"
fx2 repos/o/r/pulls/7 ".merged = true | .state = \"closed\" | .merge_commit_sha = \"$C\" | .head.sha = \"$M\""
o="$(outof domerge)"
! printf '%s\n' "$o" | grep -q '^merged' && printf '%s\n' "$o" | grep -qxF 'merge-run.sh: outcome unknown, check the pull request: gh: Pull Request is not mergeable (HTTP 405)' && [ "$(puts)" = 1 ]
check "a 405 with the pull request merged at another head reports the outcome unknown with the error, no second PUT" $?

fresh; prep; plan; mr gate "$RUN" > /dev/null
touch "$FX/put-405"
o="$(outof domerge)"
! printf '%s\n' "$o" | grep -q '^merged' && printf '%s\n' "$o" | grep -qxF 'merge-run.sh: the merge failed: gh: Pull Request is not mergeable (HTTP 405); nothing retried' && [ "$(puts)" = 1 ]
check "a 405 with the pull request not merged reports the error as is, no second PUT" $?

# --- any other PUT failure is read once too: a timeout that landed, one that did not, a failed read
fresh; prep; plan; mr gate "$RUN" > /dev/null
echo "Post https://api.github.com/repos/o/r/pulls/7/merge: net/http: request canceled (Client.Timeout exceeded)" > "$FX/put-fail"
fx2 repos/o/r/pulls/7 ".merged = true | .state = \"closed\" | .merge_commit_sha = \"$C\""
o="$(domerge)"; s=$?
[ "$s" = 0 ] && printf '%s\n' "$o" | grep -qxF "merged: o/r#7, head $H, merge commit $C (the merge had already landed)" && [ "$(puts)" = 1 ]
check "a PUT that timed out but landed at the confirmed head reports merged, no second PUT" $?

fresh; prep; plan; mr gate "$RUN" > /dev/null
echo "gh: Server Error (HTTP 502)" > "$FX/put-fail"
o="$(outof domerge)"
! printf '%s\n' "$o" | grep -q '^merged' && printf '%s\n' "$o" | grep -qxF 'merge-run.sh: the merge failed: gh: Server Error (HTTP 502); nothing retried' && [ "$(puts)" = 1 ]
check "a PUT that failed and did not land reports the error as it came, nothing retried, no second PUT" $?

fresh; prep; plan; mr gate "$RUN" > /dev/null
echo "gh: Server Error (HTTP 502)" > "$FX/put-fail"; touch "$FX/read-fail-after-put"
o="$(outof domerge)"
! printf '%s\n' "$o" | grep -q '^merged' && printf '%s\n' "$o" | grep -qxF 'merge-run.sh: outcome unknown, check the pull request: gh: Server Error (HTTP 502)' && [ "$(puts)" = 1 ]
check "a PUT that failed with a failed read after it reports the outcome unknown with the error, no second PUT" $?

# --- Negative self-check ----------------------------------------------------------------------
oc=0
mutate() { # name, perl substitution, case command (run with MR at the copy)
  local d="$TMP/mut-$oc"; oc=$((oc + 1))
  mkdir -p "$d/terraform-module-pr-merge/references" "$d/terraform-module-pr-review/references"
  cp "$SKILLS/terraform-module-pr-review/references/stage-contract.jq" "$d/terraform-module-pr-review/references/"
  cp "$MR" "$d/terraform-module-pr-merge/references/merge-run.sh"
  perl -0pi -e "$2" "$d/terraform-module-pr-merge/references/merge-run.sh"
  if cmp -s "$d/terraform-module-pr-merge/references/merge-run.sh" "$MR"; then check "self-check: $1 (the mutation changed nothing)" 1; return; fi
  local keep="$MR" before="$fails"; MR="$d/terraform-module-pr-merge/references/merge-run.sh"
  ( eval "$3" ) > /dev/null 2>&1; local s=$?
  MR="$keep"; fails="$before"
  check "self-check: $1 is caught" "$([ "$s" != 0 ]; echo $?)"
}
mutate "the re-read before the merge skipped" 's/^  live raw-merge$/  RAW="\$RUN\/raw-merge"; mkdir "\$RAW"; jq "{merge: .}" "\$RUN\/merge.json" > "\$RAW\/decision.json"/m' \
  'fresh; prep; plan; mr gate "$RUN"; fx repos/o/r/commits/'"$H"'/check-runs ".[0].check_runs[0].conclusion = \"failure\""; mr merge "$RUN" --target o/r#7 --confirm-head '"$H"'; [ "$(puts)" = 0 ]'
mutate "approve with nits swapped for changes suggested" 's/"approve with nits"/"changes suggested"/g' \
  'fresh; prep; plan ".verdict = \"changes suggested\""; ! mr gate "$RUN"'
mutate "the fresh review check dropped" 's/^     elif \(\$pl\.read_at \| iso_time\)[^\n]*\n//m' \
  'fresh; prep; plan ".read_at = \"2020-01-01T00:00:00Z\""; ! mr gate "$RUN"'
mutate "the read after a failed PUT limited to a 405" 's/    get after "repos\/\$REPO\/pulls\/\$NUM" \|\| fail/    case "\$err" in *"HTTP 405"*) ;; *) fail "the merge failed: \$err; nothing retried" ;; esac\n    get after "repos\/\$REPO\/pulls\/\$NUM" || fail/' \
  'fresh; prep; plan; mr gate "$RUN"; echo "timeout" > "$FX/put-fail"; fx2 repos/o/r/pulls/7 ".merged = true"; domerge'

if [ "$fails" = 0 ]; then echo "all pr-merge checks passed"; else echo "$fails pr-merge check(s) FAILED"; exit 1; fi
