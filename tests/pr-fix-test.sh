#!/bin/bash
# Self-check for references/fix-run.sh and fix-run.jq of terraform-module-pr-fix: the write path
# rows, the origins, the item set, the fingerprints and the introduced rule, the loop stops, the
# checks classes, the content gate, the pre-push aborts, the push, the replies, the run and output
# directories, and that no credential reaches verification. No network: gh is a stub on PATH that
# answers from fixture JSON and records its argv, terraform is a stub that dumps its environment
# and tries to read canary credential files, and the remote is a local bare repository.
#
# The remote: a git shim on PATH execs the real git with one url.<file>.insteadOf for
# https://github.com/. fix-run.sh has no test-only branch, variable or override that a hostile
# environment could flip; every git flag it passes reaches the real git unchanged, and the shim
# records each call's argv for the push assertions.
#
# A negative self-check mutates temp copies of fix-run.sh and fix-run.jq and confirms each named
# case fails. Needs bash, git, jq and perl.
# Run: tests/pr-fix-test.sh (KEEP=1 keeps the temporary directory; PR_FIX_TEST_SHELL=/bin/bash
# runs the script under that shell)
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
SKILLS="$SRC/.agents/skills"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pr-fix-test.XXXXXX")" && pwd -P)" && [ -n "$TMP" ] || { echo "FAIL no temporary directory"; exit 1; }
[ -n "${KEEP:-}" ] || trap 'chmod -R u+w "$TMP" 2> /dev/null; rm -rf "$TMP"' EXIT
fails=0
FR="$SKILLS/terraform-module-pr-fix/references/fix-run.sh" # the script under test; the self-check swaps in mutated copies
check() { if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
SH="${PR_FIX_TEST_SHELL:-bash}" # bash, or /bin/bash for the 3.2 that macOS ships
fr() { "$SH" "$FR" "$@"; }
JL() { jq -L "$(dirname "$FR")" "$@"; } # the decision functions of the script under test
outof() { "$@" 2>&1; true; } # the output of a command expected to refuse, under pipefail

REALGIT="$(command -v git)"
FX="$TMP/fx"; REM="$TMP/remotes"; BIN="$TMP/bin"; WORK="$TMP/work"
mkdir -p "$FX/api" "$REM" "$BIN" "$WORK" "$TMP/home/.aws" "$TMP/home/.config/gh" "$TMP/tmp"
export HOME="$TMP/home" TMPDIR="$TMP/tmp"
unset CI GITHUB_ACTIONS GITHUB_RUN_ID GH_CONFIG_DIR
# Canary credentials: in the environment and in the files a provider or a git helper would read.
CANARY=canary-6f1d2c
export GH_TOKEN="gho_$CANARY" GITHUB_TOKEN="$CANARY-gh" AWS_ACCESS_KEY_ID="AKIA$CANARY" \
  AWS_SECRET_ACCESS_KEY="$CANARY-aws" TF_TOKEN_app_terraform_io="$CANARY-tf" AWS_SHARED_CREDENTIALS_FILE="$HOME/.aws/credentials" \
  VAULT_TOKEN="$CANARY-vault" ARM_CLIENT_SECRET="$CANARY-arm"
printf '[default]\naws_secret_access_key = %s-file\n' "$CANARY" > "$HOME/.aws/credentials"
printf 'github.com:\n    oauth_token: %s-hosts\n' "$CANARY" > "$HOME/.config/gh/hosts.yml"
printf '[user]\n\tname = Pat Owner\n\temail = pat@example.com\n' > "$HOME/.gitconfig"

# --- Stubs ------------------------------------------------------------------------------------

cat > "$BIN/git" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$TMP/git-argv.log"
env | grep -iE 'token|secret|canary' >> "$TMP/git-env.log"
exec "$REALGIT" -c "url.file://$REM/.insteadOf=https://github.com/" "\$@"
EOF
cat > "$BIN/terraform" <<EOF
#!/bin/bash
env >> "$TMP/tf-env.log"
for f in "\${AWS_SHARED_CREDENTIALS_FILE:-\$HOME/.aws/credentials}" "\$HOME/.aws/credentials" \
  "\${GH_CONFIG_DIR:-\$HOME/.config/gh}/hosts.yml" "\$HOME/.netrc" "\$HOME/.terraformrc"; do
  cat "\$f" >> "$TMP/tf-read.log" 2> /dev/null
done
case "\$1" in version) echo '{"terraform_version": "1.16.0"}' ;; esac
exit 0
EOF
cat > "$BIN/gh" <<EOF
#!/bin/bash
FX="$FX"; REM="$REM"; REALGIT="$REALGIT"
EOF
cat >> "$BIN/gh" <<'EOF'
printf '%s\n' "$*" >> "$FX/gh-argv.log"
env | grep -iE 'token|secret|canary' >> "$FX/gh-env.log"
case "$1" in
  auth)
    case "$2" in
      status) [ -f "$FX/auth-ok" ] && { echo "github.com: Logged in"; exit 0; }; exit 1 ;;
      token) cat "$FX/token" 2> /dev/null; exit 0 ;;
      *) exit 0 ;;
    esac ;;
  api) shift ;;
  *) exit 1 ;;
esac
ep=""; q=""; post=false; slurp=false
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) q="$2"; shift 2 ;;
    -X) [ "$2" = POST ] && post=true; shift 2 ;;
    --input) shift 2 ;;
    --paginate) shift ;;
    --slurp) slurp=true; shift ;;
    *) ep="$1"; shift ;;
  esac
done
ep="${ep%%\?*}"
if [ "$post" = true ]; then
  [ ! -f "$FX/post-fail" ] || exit 1
  { printf '%s ' "$ep"; jq -c .; } >> "$FX/posted.log"; echo '{}'; exit 0
fi
if [[ "$ep" =~ ^repos/([^/]+/[^/]+)/git/ref/heads/(.+)$ ]]; then
  s="$("$REALGIT" --git-dir="$REM/${BASH_REMATCH[1]}.git" rev-parse "refs/heads/${BASH_REMATCH[2]}" 2> /dev/null)" || exit 1
  out="{\"object\": {\"sha\": \"$s\"}}"
else
  f="$FX/api/$ep.json"; [ -f "$f" ] || exit 1
  out="$(cat "$f")"
  # A paginated fixture holds its pages; without --slurp gh prints them one after another.
  [ "$slurp" = true ] || [ ! -f "$f.pages" ] || out="$(jq -c '.[]' "$f")"
fi
if [ -n "$q" ]; then printf '%s\n' "$out" | jq -r "$q"; else printf '%s\n' "$out"; fi
EOF
chmod +x "$BIN/git" "$BIN/terraform" "$BIN/gh"
# The caller's PATH less every entry holding an mtf-facts, so verify-pass.sh selects every example.
PATH0="$(printf '%s\n' "$PATH" | tr ':' '\n' | while IFS= read -r d; do [ -x "$d/mtf-facts" ] || printf '%s:' "$d"; done)"
export PATH="$BIN:${PATH0%:}"

# --- The module repository, its bare remote and a fork ------------------------------------------

RG() { env -i PATH="$PATH" HOME="$HOME" GIT_CONFIG_NOSYSTEM=1 "$REALGIT" -c user.name=t -c user.email=t@example.com \
  -c init.defaultBranch=main -c commit.gpgsign=false "$@"; }
M="$WORK/module"
RG init -q "$M"
mkdir -p "$M/examples/complete"
printf 'resource "null_resource" "this" {}\n' > "$M/main.tf"
printf 'variable "name" {\n  type = string\n}\n' > "$M/variables.tf"
printf 'terraform {\n  required_version = ">= 1.5"\n}\n' > "$M/versions.tf"
printf 'module "this" {\n  source = "../.."\n  name   = "x"\n}\n' > "$M/examples/complete/main.tf"
printf '# module\n' > "$M/README.md"
RG -C "$M" add -A; RG -C "$M" commit -qm base
B="$(RG -C "$M" rev-parse HEAD)"
RG -C "$M" checkout -q -b feat
printf 'variable "name" {\n  type = string\n}\n\nvariable "size" {\n  type = number\n}\n' > "$M/variables.tf"
RG -C "$M" commit -qam head
H="$(RG -C "$M" rev-parse HEAD)"
mkbare() { # owner/repo: a bare copy with main, feat and refs/pull/7/head
  rm -rf "$REM/$1.git"; mkdir -p "$(dirname "$REM/$1.git")"
  RG clone -q --bare "$M" "$REM/$1.git"
  RG --git-dir="$REM/$1.git" update-ref refs/pull/7/head "$H"
  RG --git-dir="$REM/$1.git" config uploadpack.allowAnySHA1InWant true
}

# --- Fixtures -------------------------------------------------------------------------------

api() { mkdir -p "$(dirname "$FX/api/$1.json")"; printf '%s\n' "$2" > "$FX/api/$1.json"; rm -f "$FX/api/$1.json.pages"; }
pages() { api "$1" "$2"; touch "$FX/api/$1.json.pages"; }
PR_JSON() { # the pull request read; jq edits as the argument
  jq -n -c --arg h "$H" --arg b "$B" '{number: 7, state: "open", merged: false, draft: false, locked: false,
    maintainer_can_modify: false, user: {id: 100, login: "alice", type: "User"},
    head: {sha: $h, ref: "feat", repo: {full_name: "o/r", clone_url: "https://evil.example/stolen.git"}},
    base: {sha: $b, ref: "main", repo: {full_name: "o/r"}}}' | jq -c "${1:-.}"
}
REPO_JSON() { jq -n -c '{full_name: "o/r", archived: false, private: false, default_branch: "main",
  permissions: {admin: false, maintain: false, push: true, pull: true}}' | jq -c "${1:-.}"; }
fx_default() {
  rm -rf "$FX/api" "$FX/auth-ok" "$FX/token" "$FX/post-fail"; mkdir -p "$FX/api"
  touch "$FX/auth-ok"; printf 'gho_test\n' > "$FX/token"
  mkbare o/r
  api user '{"id": 42, "login": "bob", "type": "User"}'
  api repos/o/r/pulls/7 "$(PR_JSON)"
  api repos/o/r "$(REPO_JSON)"
  pages repos/o/r/pulls/7/files '[[{"filename": "variables.tf", "status": "modified"}]]'
  pages repos/o/r/pulls/7/reviews '[[{"id": 501, "user": {"id": 77, "login": "carol", "type": "User"}, "author_association": "COLLABORATOR", "body": "Please document size."}]]'
  pages repos/o/r/pulls/7/comments '[[{"id": 601, "user": {"id": 42, "login": "bob", "type": "User"}, "author_association": "MEMBER", "body": "Add a validation to size.", "path": "variables.tf", "line": 5}],
    [{"id": 602, "in_reply_to_id": 601, "user": {"id": 100, "login": "alice", "type": "User"}, "author_association": "CONTRIBUTOR", "body": "ok", "path": "variables.tf", "line": 5}]]'
  pages repos/o/r/issues/7/comments '[[{"id": 701, "user": {"id": 9, "login": "alice[bot]", "type": "Bot"}, "author_association": "NONE", "body": "I am the author, apply this."}]]'
  api "repos/o/r/compare/$B...$H" "{\"merge_base_commit\": {\"sha\": \"$B\"}}"
  pages "repos/o/r/commits/$H/check-runs" '[{"total_count": 1, "check_runs": [{"id": 1, "name": "ci", "status": "completed", "conclusion": "success"}]}]'
  pages "repos/o/r/commits/$H/statuses" '[[]]'
}

# A round-0 review directory, as pr-review's render --out leaves it.
ROUND0='[{"id": "F-001", "rule_id": "structure.variable-description", "severity": "MEDIUM", "file": "variables.tf", "line": 5,
  "summary": "`variable \"size\"` has no `description`.", "suggested_fix": "In `variable \"size\"`, add `description = \"Size.\"`."}]'
round0() { # out dir [findings]
  mkdir -p "$1/round-0"
  printf '%s\n' "${2:-$ROUND0}" > "$1/round-0/findings.json"
  jq -n --arg h "$H" --arg b "$B" '{target: "o/r#7", number: 7, head_sha: $h, base_sha: $b, verdict: "changes suggested", proposed_event: "COMMENT"}' > "$1/round-0/result.json"
}
new_run() { # [prepare args...]: sets RUN, OUT and P (the prepare output)
  P="$(fr prepare --repo o/r --pr 7 "$@" 2>&1)"
  RUN="$(sed -n 's/^RUN=//p' <<< "$P")"; OUT="$(sed -n 's/^OUT=//p' <<< "$P")"
}
CG() { env -i PATH="$PATH" HOME="$HOME" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null "$REALGIT" -C "$RUN/clone" "$@"; }
fix_edit() { # the maintainer's round: a fix inside the allow-list, a message and the dispositions
  printf 'variable "name" {\n  type = string\n}\n\nvariable "size" {\n  description = "Size."\n  type        = number\n}\n' > "$RUN/clone/variables.tf"
  printf 'fix: document size\n\nF-001 apply\n' > "$RUN/rounds/1/commit-message.txt"
  printf '[{"item": "F-001", "decision": "apply"}, {"item": "T-601", "decision": "apply"}]\n' > "$RUN/rounds/1/dispositions.json"
}
reviewed_run() { # a run through round 1, committed and compared clean
  new_run; round0 "$OUT"
  fr clone "$RUN" > "$TMP/clone.out" 2>&1 && fr items "$RUN" --review "$OUT/round-0" > /dev/null 2>&1 &&
    fr round "$RUN" > /dev/null 2>&1 && fix_edit && fr commit "$RUN" --round 1 > /dev/null 2>&1 &&
    echo '[]' > "$TMP/empty.json" && fr compare "$RUN" --round 1 --findings "$TMP/empty.json" > "$TMP/compare.out" 2>&1
}

# --- 1. Write path rows (write-path.md, Write path) --------------------------------------------

STATE0="$(jq -n -c --argjson pr "$(PR_JSON)" --argjson r "$(REPO_JSON)" '{failed: [], token: {id: 42, login: "bob", type: "User"},
  ci: false, commit_identity: {name: "Pat", email: "p@example.com"}, pr: ($pr | del(.head.repo.clone_url)),
  base_repo: $r, head_repo: $r}')"
MB_OK='{"ok": true, "reason": "one merge base"}'
wp() { # jq edit of the state, merge base JSON: prints path and the reasons
  JL -r -n --argjson s "$(jq -c "$1" <<< "$STATE0")" --argjson m "$2" 'include "fix-run";
    {state: $s, merge_base: $m} | write_path | "\(.path) \(.via // "") \(.flags.draft) \(.flags.default_branch) \(.reasons | join("; "))"'
}
t_rows() {
  wp . "$MB_OK" | grep -q '^A head-permission false false $' &&
  wp '.failed = ["pr"]' "$MB_OK" | grep -q '^render-only .*a read failed: pr' &&
  wp '.pr.merged = null' "$MB_OK" | grep -q '^render-only .*a field is unknown: pr.merged' &&
  wp '.pr.head.repo = null | .head_repo = null' "$MB_OK" | grep -q '^render-only .*the head repository is gone' &&
  wp '.pr.head.ref = ""' "$MB_OK" | grep -q '^render-only .*the head ref is missing' &&
  wp '.head_repo.archived = true' "$MB_OK" | grep -q '^render-only .*archived' &&
  wp '.base_repo.archived = true' "$MB_OK" | grep -q '^render-only .*archived' &&
  wp '.pr.state = "closed"' "$MB_OK" | grep -q '^render-only .*closed or merged' &&
  wp '.pr.merged = true' "$MB_OK" | grep -q '^render-only .*closed or merged' &&
  wp . '{"ok": false, "reason": "the fix clone has several merge bases"}' | grep -q '^render-only .*several merge bases' &&
  wp . null | grep -q '^render-only .*not checked yet' &&
  wp '.pr.draft = true' "$MB_OK" | grep -q '^A head-permission true false' &&
  wp '.pr.head.ref = "main"' "$MB_OK" | grep -q '^A head-permission false true' &&
  wp '.pr.head.repo.full_name = "fork/r" | .head_repo.full_name = "fork/r" | .head_repo.permissions.push = false | .pr.maintainer_can_modify = true' "$MB_OK" |
    grep -q '^A maintainer-can-modify ' &&
  wp '.pr.head.repo.full_name = "fork/r" | .head_repo.full_name = "fork/r" | .head_repo.permissions.push = false | .pr.maintainer_can_modify = false' "$MB_OK" |
    grep -q '^B .*cannot push' &&
  wp '.head_repo.permissions = {push: false, maintain: true}' "$MB_OK" | grep -q '^A head-permission' &&
  wp '.head_repo.permissions = {push: false, pull: true}' "$MB_OK" | grep -q '^B ' &&
  wp '.commit_identity = null' "$MB_OK" | grep -q '^B .*no commit identity' &&
  wp '.token.type = "Bot"' "$MB_OK" | grep -q '^render-only .*not a person' &&
  wp '.token.login = "bob[bot]"' "$MB_OK" | grep -q '^render-only .*not a person' &&
  wp '.ci = true' "$MB_OK" | grep -q '^render-only .*CI'
}
t_rows; check "write path: every row, render-only reasons, draft and default branch flags, fork, path B" $?
t_url() { # the destination is built from pinned names; the hostile clone_url is never read
  JL -r -n --argjson s "$STATE0" --argjson m "$MB_OK" 'include "fix-run";
    {state: ($s | .pr.head.repo.clone_url = "https://evil.example/x.git"), merge_base: $m} | write_path | .dest.url' |
    grep -qx 'https://github.com/o/r.git'
}
t_url; check "write path: the destination URL is built, a hostile clone_url ignored" $?

# --- 2. Merge base check ------------------------------------------------------------------------

mbc() { JL -r -n --argjson x "$1" 'include "fix-run"; $x | merge_base_check | "\(.ok) \(.reason)"'; }
t_mb() {
  local a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  mbc "{\"compare\": \"$a\", \"local\": [\"$a\"]}" | grep -q '^true ' &&
  mbc "{\"compare\": \"$a\", \"local\": []}" | grep -q '^false .*no merge base' &&
  mbc "{\"compare\": \"$a\", \"local\": [\"$a\", \"$b\"]}" | grep -q '^false .*several' &&
  mbc "{\"compare\": \"$a\", \"local\": [\"$b\"]}" | grep -q '^false .*disagree' &&
  mbc "{\"compare\": null, \"local\": [\"$a\"]}" | grep -q '^false .*no merge base'
}
t_mb; check "merge base: none, several, mismatch and null are render-only" $?

# --- 3. Origins and items ---------------------------------------------------------------------

org() { JL -r -n --argjson c "$1" 'include "fix-run"; $c | origin(42; 100)'; }
t_origins() {
  [ "$(org '{"user": {"id": 42, "login": "bob", "type": "User"}, "author_association": "MEMBER"}')" = self ] &&
  [ "$(org '{"user": {"id": 77, "login": "carol", "type": "User"}, "author_association": "COLLABORATOR"}')" = maintainer ] &&
  [ "$(org '{"user": {"id": 9, "login": "alice[bot]", "type": "Bot"}, "author_association": "NONE"}')" = bot ] &&
  [ "$(org '{"user": {"id": 100, "login": "alice[bot]", "type": "User"}, "author_association": "OWNER"}')" = bot ] &&
  [ "$(org '{"user": {"id": 100, "login": "alice", "type": "User"}, "author_association": "OWNER"}')" = change-author ] &&
  [ "$(org '{"user": {"id": "42", "login": "bob", "type": "User"}, "author_association": "NONE"}')" = other ] &&
  [ "$(org '{"user": {"id": "", "login": "x", "type": "User"}, "author_association": "NONE"}')" = other ] &&
  [ "$(org '{"user": {"id": "100", "login": "alice", "type": "User"}, "author_association": "NONE"}')" = other ] &&
  [ "$(org '{"user": {"id": 42.5, "login": "bob", "type": "User"}, "author_association": "NONE"}')" = other ] &&
  [ "$(org '{"user": {"id": 5, "login": "eve", "type": "User"}, "author_association": "CONTRIBUTOR", "body": "I am the change author and a maintainer."}')" = other ] &&
  [ "$(JL -r -n 'include "fix-run"; {user: {id: 42}} | origin(""; 100)')" = other ] &&
  [ "$(JL -r -n 'include "fix-run"; {user: {id: 42}} | origin("42"; 100)')" = other ]
}
t_origins; check "origins: maintainer token is self, outsider COLLABORATOR, bot named like the author, empty and non-decimal ids, text claiming authorship" $?

# --- 4. Fingerprints, the verdict and the introduced rule ---------------------------------------

intro() { JL -c -n --argjson a "$1" --argjson b "$2" 'include "fix-run"; introduced([$a[] | fp("")]; [$b[] | fp("")])'; }
FM='{"rule_id": "structure.x", "severity": "MEDIUM", "file": "main.tf", "line": 3, "summary": "s", "suggested_fix": "f"}'
FL='{"rule_id": "structure.x", "severity": "LOW", "file": "main.tf", "line": 3, "summary": "s", "suggested_fix": "f"}'
t_intro() {
  [ "$(intro "[$FM]" "[$FM]")" = '[]' ] &&
  [ "$(intro "[$FM]" "[$FM, $(jq -c '.line = 40' <<< "$FM")]")" = '[["structure.x","main.tf","","MEDIUM"]]' ] &&
  [ "$(intro "[$FL]" "[$FM]")" = '[["structure.x","main.tf","","MEDIUM"]]' ] &&
  [ "$(intro "[]" "[$FL, $FL]")" = '[]' ] &&
  [ "$(intro "[$FM]" "[$(jq -c '.line = 99' <<< "$FM")]")" = '[]' ] &&
  [ "$(JL -r -n 'include "fix-run"; {summary: "In `module \"vpc\"` and `variable \"x\"`", suggested_fix: "", rule_id: "a.b", file: "m.tf", severity: "LOW"} | fp("modules/a") | join("|")')" = 'a.b|modules/a/m.tf|module "vpc"|LOW' ] &&
  [ "$(JL -r -n --argjson f "[$FL]" 'include "fix-run"; $f | verdict')" = nits ] &&
  [ "$(JL -r -n --argjson f "[$FL, $FM]" 'include "fix-run"; $f | verdict')" = open ] &&
  [ "$(JL -r -n 'include "fix-run"; [] | verdict')" = clean ]
}
t_intro; check "fingerprints: an address-less second MEDIUM and a severity raise are introduced, a moved line is not; clean, nits, open" $?

# --- 5. Loop stops -----------------------------------------------------------------------------

loop() { JL -r -n --argjson x "$1" 'include "fix-run"; $x | loop_decision | "\(.stop) \(.reason)"'; }
t_loop() {
  loop '{"history": [["a","b"],["a"]], "round": 1, "limit": 3, "verdict": "open", "nonactionable": false}' | grep -q '^false ' &&
  loop '{"history": [["a","b"],["a","b"]], "round": 1, "limit": 3, "verdict": "open", "nonactionable": false}' | grep -q '^true no progress: the open set' &&
  loop '{"history": [["a","b"],["a","c"]], "round": 1, "limit": 3, "verdict": "open", "nonactionable": false}' | grep -q '^true no progress: the open set' &&
  loop '{"history": [["a","b"],["b"],["a"]], "round": 2, "limit": 3, "verdict": "open", "nonactionable": false}' | grep -q '^true no progress: a closed item reappears' &&
  loop '{"history": [["a","b","c"],["a","b"],["a"]], "round": 3, "limit": 3, "verdict": "open", "nonactionable": false}' | grep -q '^true round 3 is the last' &&
  loop '{"history": [["a"],[]], "round": 1, "limit": 3, "verdict": "nits", "nonactionable": false}' | grep -q '^true the local verdict is nits' &&
  loop '{"history": [["a"],["a"]], "round": 1, "limit": 3, "verdict": "open", "nonactionable": true}' | grep -q '^true every open item is non-actionable'
}
t_loop; check "loop: no progress, a reappearing fingerprint, round 3, nits and non-actionable stop" $?

# --- 6. Checks ---------------------------------------------------------------------------------

ck() { JL -r -n --argjson x "$1" 'include "fix-run"; $x | checks_class | .class'; }
t_checks() {
  local ok='{"id": 1, "name": "ci", "status": "completed", "conclusion": "success"}'
  [ "$(ck "{\"ok\": true, \"runs\": [$ok], \"statuses\": [], \"pinned_total\": 1}")" = passing ] &&
  [ "$(ck '{"ok": true, "runs": [{"id": 1, "name": "ci", "status": "in_progress", "conclusion": null}], "statuses": [], "pinned_total": 1}')" = "not finished" ] &&
  [ "$(ck '{"ok": true, "runs": [{"id": 1, "name": "ci", "status": "completed", "conclusion": "skipped"}], "statuses": [{"id": 3, "context": "x", "state": "success"}], "pinned_total": 1}')" = passing ] &&
  [ "$(ck '{"ok": true, "runs": [{"id": 1, "name": "ci", "status": "completed", "conclusion": "neutral"}], "statuses": [], "pinned_total": 1}')" = "not finished" ] &&
  [ "$(ck '{"ok": true, "runs": [], "statuses": [{"id": 3, "context": "x", "state": "pending"}], "pinned_total": 1}')" = "not finished" ] &&
  [ "$(ck '{"ok": true, "runs": [], "statuses": [{"id": 3, "context": "x", "state": "failure"}, {"id": 9, "context": "x", "state": "success"}], "pinned_total": 1}')" = passing ] &&
  [ "$(ck '{"ok": true, "runs": [{"id": 8, "name": "ci", "status": "completed", "conclusion": "failure"}, {"id": 2, "name": "ci", "status": "completed", "conclusion": "success"}], "statuses": [], "pinned_total": 1}')" = "not finished" ] &&
  [ "$(ck '{"ok": true, "runs": [], "statuses": [], "pinned_total": 0}')" = passing ] &&
  [ "$(ck '{"ok": true, "runs": [], "statuses": [], "pinned_total": 2}')" = "not finished" ] &&
  [ "$(ck '{"ok": true, "runs": [], "statuses": [], "pinned_total": null}')" = "not finished" ] &&
  [ "$(ck "{\"ok\": false, \"runs\": [$ok], \"statuses\": [], \"pinned_total\": 1}")" = "not finished" ]
}
t_checks; check "checks: success, skipped, pending, neutral, latest per context and name, none with and without pinned checks, a read error" $?

# --- 7. Pre-push aborts --------------------------------------------------------------------------

PIN="$(jq -n -c --argjson s "$STATE0" --argjson m "$MB_OK" '{state: $s, merge_base: $m}')"
PATHA="$(JL -c -n --argjson p "$PIN" 'include "fix-run"; $p | write_path')"
PATHF="$(JL -c -n --argjson p "$PIN" 'include "fix-run"; $p | .state |= (.pr.head.repo.full_name = "fork/r" | .head_repo.full_name = "fork/r"
  | .head_repo.permissions.push = false | .pr.maintainer_can_modify = true) | write_path')"
pp() { # jq edit of the fresh state, the pinned path: the abort reasons
  JL -r -n --argjson f "$(jq -c "$1" <<< "$STATE0" | jq -c 'del(.token, .ci, .commit_identity)')" --argjson p "$PIN" --argjson path "${2:-$PATHA}" \
    'include "fix-run"; $f | prepush_abort($p; $path) | join("; ")'
}
t_prepush() {
  [ -z "$(pp .)" ] &&
  pp ".pr.head.sha = \"$B\"" | grep -q 'the head ref moved' &&
  pp '.pr.state = "closed"' | grep -q 'not open' &&
  pp '.pr.merged = true' | grep -q 'merged' &&
  pp '.head_repo.archived = true' | grep -q 'archived' &&
  pp '.base_repo.archived = true' | grep -q 'archived' &&
  pp '.head_repo.permissions.push = false' | grep -q 'permission is lost' &&
  pp '.pr.head.ref = "other"' | grep -q 'destination changed' &&
  pp '.pr.head.repo.full_name = "x/y"' | grep -q 'destination changed' &&
  pp 'del(.pr.draft)' | grep -q 'unknown' &&
  pp '.failed = ["base"]' | grep -q 'a read failed' &&
  pp '.pr.head.repo.full_name = "fork/r" | .head_repo.full_name = "fork/r" | .head_repo.permissions.push = false | .pr.maintainer_can_modify = false' "$PATHF" |
    grep -q 'maintainer_can_modify is false' &&
  [ -z "$(pp '.pr.head.repo.full_name = "fork/r" | .head_repo.full_name = "fork/r" | .head_repo.permissions.push = false | .pr.maintainer_can_modify = true' "$PATHF")" ] &&
  [ -z "$(pp '.comments = [{"kind": "conversation", "id": 9}] | .pr.draft = true')" ]
}
t_prepush; check "pre-push: each abort field, the fork's maintainer_can_modify, and comment traffic or a draft change does not abort" $?

# --- 8. Path refusals of the content gate -------------------------------------------------------

pr_() { JL -r -n --arg p "$1" --arg x "${2:-}" 'include "fix-run";
  {path: $p, prefix: $x, change_set: ["variables.tf", "modules/a/main.tf"], finding_files: ["README.md", ".github/workflows/lock.yml"],
   profile_files: [".github/workflows/pr-title.yml"]} | path_refusal'; }
t_paths() {
  [ -z "$(pr_ variables.tf)" ] && [ -z "$(pr_ README.md)" ] && [ -z "$(pr_ .github/workflows/pr-title.yml)" ] &&
  pr_ main.tf | grep -q 'outside the change set' &&
  pr_ .terraform.lock.hcl | grep -q 'lock file' &&
  pr_ examples/x/.terraform/p | grep -q '.terraform path' &&
  pr_ .git/config | grep -q '.git' &&
  pr_ terraform.tfstate | grep -q 'state file' &&
  pr_ x.tfstate.backup | grep -q 'state file' &&
  pr_ .github/workflows/lock.yml | grep -q 'workflow' &&
  pr_ ../x | grep -q 'plain' &&
  pr_ variables.tf modules/a | grep -q 'module root' &&
  [ -z "$(pr_ modules/a/main.tf modules/a)" ]
}
t_paths; check "content gate paths: lock file, .terraform, .git, state, workflow without a profile finding, outside the change set or module root" $?

# --- 9. The run end to end: prepare, clone, items, round, commit, verify, compare, gate, push -----

fx_default
mkdir -p "$TMP/evilhooks"; printf '#!/bin/sh\ntouch "%s/hooked"\n' "$TMP" > "$TMP/evilhooks/pre-commit"
cp "$TMP/evilhooks/pre-commit" "$TMP/evilhooks/post-checkout"; chmod +x "$TMP/evilhooks/"*
t_e2e() {
  : > "$TMP/git-argv.log"; : > "$FX/gh-argv.log"; : > "$TMP/tf-env.log"; : > "$TMP/tf-read.log"; rm -f "$TMP/hooked"
  # A hostile GIT_CONFIG_COUNT: hooks and an identity the wrapper must not see.
  GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$TMP/evilhooks" \
    GIT_CONFIG_KEY_1=user.name GIT_CONFIG_VALUE_1=Injected reviewed_run || { echo "reviewed_run failed"; return 1; }
  [ ! -e "$TMP/hooked" ] || { echo "a hook ran"; return 1; }
  [ "$(CG log -1 --format=%an)" = "Pat Owner" ] || { echo "identity"; return 1; }
  grep -q '^write path: A (head-permission)' "$TMP/clone.out" || { echo "path"; return 1; }
  grep -q '^destination: https://github.com/o/r.git feat' "$TMP/clone.out" || return 1
  grep -q '^loop: stop, the local verdict is clean' "$TMP/compare.out" || { cat "$TMP/compare.out"; return 1; }
  fr verify "$RUN" --round 1 > "$TMP/verify.out" 2>&1 || { cat "$TMP/verify.out"; return 1; }
  grep -q '^verify: 1 validate passed' "$TMP/verify.out" || { cat "$TMP/verify.out"; return 1; }
  [ -s "$TMP/tf-env.log" ] || { echo "terraform never ran"; return 1; }
  ! grep -iE "token|secret|$CANARY" "$TMP/tf-env.log" > /dev/null || { echo "a credential reached terraform"; return 1; }
  ! grep -q "$CANARY" "$TMP/tf-read.log" || { echo "terraform read a canary"; return 1; }
  ! grep -rq "$CANARY" "$RUN" || { echo "a canary in the run directory"; return 1; }
  ! grep -q "$CANARY" "$TMP/git-env.log" "$TMP/git-argv.log" "$FX/gh-argv.log" 2> /dev/null || { echo "a canary in git or gh"; return 1; }
  [ "$(fr gate "$RUN" 2>&1 | tee "$TMP/gate.out" | grep -c '^push: https://github.com/o/r.git [0-9a-f]\{40\}:refs/heads/feat$')" = 1 ] || { cat "$TMP/gate.out"; return 1; }
  grep -q "^expected remote SHA: $H" "$TMP/gate.out" && [ -s "$OUT/fix.patch" ] || return 1
  fr push "$RUN" --confirm-branch main --expect-sha "$H" > "$TMP/push.out" 2>&1 && return 1
  grep -q 'another branch than feat' "$TMP/push.out" || return 1
  fr push "$RUN" --confirm-branch feat --expect-sha "$B" > /dev/null 2>&1 && return 1
  ! grep -q ' push ' "$TMP/git-argv.log" || { echo "pushed before a confirmation"; return 1; }
  # New comment traffic after the state was read does not abort.
  pages repos/o/r/issues/7/comments '[[{"id": 702, "user": {"id": 5, "login": "eve", "type": "User"}, "body": "new"}]]'
  fr push "$RUN" --confirm-branch feat --expect-sha "$H" > "$TMP/push.out" 2>&1 || { cat "$TMP/push.out"; return 1; }
  local new; new="$(CG rev-parse HEAD)"
  [ "$(RG --git-dir="$REM/o/r.git" rev-parse refs/heads/feat)" = "$new" ] && grep -q "^remote ref: $new" "$TMP/push.out" || return 1
  local pl; pl="$(grep ' push ' "$TMP/git-argv.log")"
  [ "$(printf '%s\n' "$pl" | wc -l | tr -d ' ')" = 1 ] &&
    printf '%s\n' "$pl" | grep -qF -- "-c core.hooksPath=/dev/null -c credential.helper= -c credential.helper=!gh auth git-credential -c http.followRedirects=false push --no-follow-tags --recurse-submodules=no https://github.com/o/r.git $new:refs/heads/feat" &&
    ! printf '%s\n' "$pl" | grep -qE -- '--force|--force-with-lease|--tags|--mirror|\+' || { echo "push argv: $pl"; return 1; }
  grep -q '^checks: pending' "$TMP/push.out" || return 1
  # Right after the push the new SHA has no checks, and the pinned head had one: not finished.
  pages "repos/o/r/commits/$new/check-runs" '[{"total_count": 0, "check_runs": []}]'; pages "repos/o/r/commits/$new/statuses" '[[]]'
  fr checks "$RUN" | grep -q '^checks: not finished, no checks yet' || return 1
  # Two pages: the newest run per name and the newest status per context decide.
  pages "repos/o/r/commits/$new/check-runs" '[{"total_count": 2, "check_runs": [{"id": 3, "name": "ci", "status": "completed", "conclusion": "failure"}]},
    {"total_count": 2, "check_runs": [{"id": 4, "name": "ci", "status": "completed", "conclusion": "success"}]}]'
  pages "repos/o/r/commits/$new/statuses" '[[{"id": 11, "context": "lint", "state": "pending"}], [{"id": 12, "context": "lint", "state": "success"}]]'
  fr checks "$RUN" > "$TMP/checks.out" && grep -q '^checks: passing' "$TMP/checks.out" && grep -q '^finished: clean, checks passing' "$TMP/checks.out" ||
    { cat "$TMP/checks.out"; return 1; }
  rm "$FX/api/repos/o/r/commits/$new/statuses.json"
  fr checks "$RUN" | grep -q '^checks: not finished, a checks read failed' || return 1
  # Replies: only ids of the frozen set with a pinned endpoint, each confirmed.
  printf '[{"item": "C-999", "body": "x"}]\n' > "$TMP/r1.json"
  fr replies "$RUN" --file "$TMP/r1.json" --confirm-items C-999 > "$TMP/r.out" 2>&1 && return 1
  grep -q 'not an open reply target' "$TMP/r.out" || return 1
  printf '[{"item": "F-001", "body": "x"}]\n' > "$TMP/r1.json"
  fr replies "$RUN" --file "$TMP/r1.json" --confirm-items F-001 > /dev/null 2>&1 && return 1
  jq -n '[{item: "T-602", body: "Fixed in `abc`: it\u0027s \"done\" $(x)."}]' > "$TMP/r2.json"
  fr replies "$RUN" --file "$TMP/r2.json" --confirm-items T-601 > /dev/null 2>&1 && return 1
  fr replies "$RUN" --file "$TMP/r2.json" --confirm-items T-602 > "$TMP/r.out" 2>&1 || { cat "$TMP/r.out"; return 1; }
  grep -qF 'repos/o/r/pulls/7/comments/601/replies {"body":"Fixed in `abc`: it'"'"'s \"done\" $(x)."}' "$FX/posted.log" || { cat "$FX/posted.log"; return 1; }
  fr replies "$RUN" --file "$TMP/r2.json" --confirm-items T-602 > /dev/null 2>&1 && { echo "posted twice"; return 1; }
  printf '[{"item": "C-701", "body": "see /Users/bob/x"}]\n' > "$TMP/r3.json"
  fr replies "$RUN" --file "$TMP/r3.json" --confirm-items C-701 > /dev/null 2>&1 && return 1
  fr cleanup "$RUN" > /dev/null && [ ! -e "$RUN" ] && [ -d "$OUT" ]
}
t_e2e; check "end to end: GIT_CONFIG_COUNT ignored, no credential in env, argv, run dir or clone, gate, confirm-branch, push argv, checks, replies" $?

t_items() { # the frozen set: origins, eligibility, endpoints
  fx_default; new_run; round0 "$OUT"; fr clone "$RUN" > /dev/null 2>&1 && fr items "$RUN" --review "$OUT/round-0" > /dev/null 2>&1 || return 1
  local x; x="$(jq -c 'map({id, origin, eligible, reply})' "$RUN/items.json")"
  [ "$x" = '[{"id":"F-001","origin":"reviewer","eligible":true,"reply":null},{"id":"V-501","origin":"maintainer","eligible":false,"reply":"repos/o/r/issues/7/comments"},{"id":"T-601","origin":"self","eligible":true,"reply":"repos/o/r/pulls/7/comments/601/replies"},{"id":"T-602","origin":"change-author","eligible":false,"reply":"repos/o/r/pulls/7/comments/601/replies"},{"id":"C-701","origin":"bot","eligible":false,"reply":"repos/o/r/issues/7/comments"}]' ] ||
    { echo "$x"; return 1; }
  fr items "$RUN" --review "$OUT/round-0" > /dev/null 2>&1 && return 1
  fr apply "$RUN" --item X-1 > /dev/null 2>&1 && return 1
  fr apply "$RUN" --item V-501 > /dev/null && fr round "$RUN" > /dev/null || return 1
  grep -q '^Apply: F-001, V-501, T-601$' "$RUN/rounds/1/task.md" && grep -q '^Review loop: caller$' "$RUN/rounds/1/task.md" &&
    grep -q '^Draft only: T-602, C-701$' "$RUN/rounds/1/task.md" && grep -qx 'variables.tf' "$RUN/rounds/1/allow.txt" || { cat "$RUN/rounds/1/task.md"; return 1; }
  fr cleanup "$RUN" > /dev/null
}
t_items; check "items: frozen once, origins and eligibility, apply only by id, thread replies to the top comment, the round task" $?

t_rounds() { # every attempt counts as a round, failed ones included
  fx_default; new_run; round0 "$OUT"; fr clone "$RUN" > /dev/null 2>&1 && fr items "$RUN" --review "$OUT/round-0" > /dev/null 2>&1 || return 1
  fr round "$RUN" > /dev/null && fr commit "$RUN" --round 1 > "$TMP/c.out" 2>&1 && return 1
  printf 'x\n' > "$RUN/rounds/1/commit-message.txt"
  fr commit "$RUN" --round 1 > "$TMP/c.out" 2>&1 && return 1
  grep -q 'changed nothing; the round still counts' "$TMP/c.out" || return 1
  fr round "$RUN" > /dev/null && fr round "$RUN" > /dev/null || return 1
  fr round "$RUN" > "$TMP/c.out" 2>&1 && return 1
  grep -q 'round 3 was the last' "$TMP/c.out" && fr cleanup "$RUN" > /dev/null
}
t_rounds; check "loop: a failed attempt counts, a fourth round is refused" $?

t_loop_e2e() { # round 1 leaves the finding open and adds one: no progress stops the loop, introduced blocks the gate
  fx_default; new_run; round0 "$OUT"; fr clone "$RUN" > /dev/null 2>&1 && fr items "$RUN" --review "$OUT/round-0" > /dev/null 2>&1 &&
    fr round "$RUN" > /dev/null || return 1
  printf '\n' >> "$RUN/clone/variables.tf"; printf 'try\n' > "$RUN/rounds/1/commit-message.txt"
  printf '[{"item": "F-001", "decision": "apply"}]\n' > "$RUN/rounds/1/dispositions.json"
  fr commit "$RUN" --round 1 > /dev/null || return 1
  jq --argjson f "$ROUND0" '$f + [$f[0] | .line = 9 | .summary = "Another." | .suggested_fix = "x"]' -n > "$TMP/f1.json"
  fr compare "$RUN" --round 1 --findings "$TMP/f1.json" > "$TMP/c.out" 2>&1 || return 1
  grep -q '^loop: stop, no progress: the open set did not shrink' "$TMP/c.out" && grep -q 'introduced: structure.variable-description variables.tf  MEDIUM' "$TMP/c.out" || { cat "$TMP/c.out"; return 1; }
  fr round "$RUN" > "$TMP/c.out" 2>&1 && return 1
  grep -q 'the loop stopped' "$TMP/c.out" || return 1
  fr gate "$RUN" > "$TMP/g.out" 2>&1 && return 1
  grep -q '^introduced: ' "$TMP/g.out" && grep -q '^no item is resolved' "$TMP/g.out" && fr cleanup "$RUN" > /dev/null
}
t_loop_e2e; check "loop end to end: no progress stops, an introduced MEDIUM and no resolved item block the gate" $?

# --- 10. The content gate negatives --------------------------------------------------------------

gate_neg() { # mutation (shell, run in the clone after a clean review), expected line
  fx_default; reviewed_run || { echo "setup failed"; return 1; }
  ( cd "$RUN/clone" && eval "$1" ) > /dev/null 2>&1
  fr gate "$RUN" > "$TMP/gn.out" 2>&1 && { echo "gate passed"; return 1; }
  grep -q -- "$2" "$TMP/gn.out" || { cat "$TMP/gn.out"; return 1; }
  fr cleanup "$RUN" > /dev/null
}
GC='env -i PATH="$PATH" HOME="$HOME" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$REALGIT" -c user.name="Pat Owner" -c user.email=pat@example.com'
t_gate_lock() { gate_neg "printf x > .terraform.lock.hcl; $GC add -A; $GC commit -qm l" 'path refused: a lock file outside the change set'; }
t_gate_tfdir() { gate_neg "mkdir -p .terraform; printf x > .terraform/p; $GC add -f -A; $GC commit -qm t" 'path refused: a .git or .terraform path'; }
t_gate_outside() { gate_neg "printf x >> main.tf; $GC commit -qam o" 'path refused: outside the change set'; }
t_gate_symlink() { gate_neg "rm variables.tf; ln -s main.tf variables.tf; $GC add -A; $GC commit -qm s" 'a symbolic link or gitlink mode'; }
t_gate_gitlink() { gate_neg "$GC update-index --add --cacheinfo 160000,$B,variables.tf.d; $GC commit -qm g" 'a symbolic link or gitlink mode'; }
t_gate_nondesc() { gate_neg "$GC checkout -q --detach $B; printf 'x' >> variables.tf; $GC commit -qam n" 'do not descend from the pinned head'; }
t_gate_tree() { gate_neg "printf '\n' >> variables.tf; $GC commit -qam t" 'not the last reviewed tree'; }
t_gate_ident() { gate_neg "$GC commit -q --amend --no-edit --author='Mallory <m@example.com>'" 'not by the gate identity'; }
t_gate_insteadof() { gate_neg "$GC config url.https://evil.example/.insteadOf https://github.com/" 'local config changed'; }
t_gate_header() { gate_neg "$GC config http.extraheader 'AUTHORIZATION: basic x'" 'local config changed'; }
t_gate_lock; check "content gate: a lock file outside the change set" $?
t_gate_tfdir; check "content gate: a .terraform path" $?
t_gate_outside; check "content gate: a path outside the allow-list" $?
t_gate_symlink; check "content gate: a symbolic link" $?
t_gate_gitlink; check "content gate: a gitlink" $?
t_gate_nondesc; check "content gate: a commit that does not descend from the pinned head" $?
t_gate_tree; check "content gate: a tree other than the last reviewed one" $?
t_gate_ident; check "content gate: a commit by another identity" $?
t_gate_insteadof; check "content gate: an unexpected local key url.*.insteadOf" $?
t_gate_header; check "content gate: an unexpected local key http.extraheader" $?

# --- 11. Aborts, the token and the render-only cases --------------------------------------------

t_token() { # an empty token aborts before git, and the abort leaves no run directory
  fx_default; reviewed_run && fr gate "$RUN" > /dev/null 2>&1 || return 1
  : > "$FX/token"; : > "$TMP/git-argv.log"
  fr push "$RUN" --confirm-branch feat --expect-sha "$H" > "$TMP/t.out" 2>&1 && return 1
  grep -q 'gh holds no github.com token' "$TMP/t.out" && ! grep -q ' push ' "$TMP/git-argv.log" && [ ! -e "$RUN" ]
}
t_token; check "push: an empty token aborts before git, and the abort deletes the run directory" $?
t_moved() { # a moved head at pre-push aborts
  fx_default; reviewed_run && fr gate "$RUN" > /dev/null 2>&1 || return 1
  api repos/o/r/pulls/7 "$(PR_JSON ".head.sha = \"$B\"")"; : > "$TMP/git-argv.log"
  fr push "$RUN" --confirm-branch feat --expect-sha "$H" > "$TMP/t.out" 2>&1 && return 1
  grep -q 'pre-push: .*the head ref moved' "$TMP/t.out" && ! grep -q ' push ' "$TMP/git-argv.log" && [ ! -e "$RUN" ]
}
t_moved; check "push: a moved head at the pre-push read aborts with no git push" $?
t_reject() { # a rejected push stops with its class and no retry
  fx_default; reviewed_run && fr gate "$RUN" > /dev/null 2>&1 || return 1
  # The remote branch gains a commit the push does not hold.
  RG -C "$M" push -q -f "$REM/o/r.git" "$(RG -C "$M" commit-tree "$H^{tree}" -p "$H" -m other):refs/heads/feat"; : > "$TMP/git-argv.log"
  fr push "$RUN" --confirm-branch feat --expect-sha "$H" > "$TMP/t.out" 2>&1 && return 1
  grep -q 'push rejected (non-fast-forward); no retry' "$TMP/t.out" && [ "$(grep -c ' push ' "$TMP/git-argv.log")" = 1 ]
}
t_reject; check "push: a rejection stops with its class, once, never with force" $?
t_clone_moved() { # the clone's head is not the pinned head: abort, no run directory left
  fx_default; new_run; RG --git-dir="$REM/o/r.git" update-ref refs/pull/7/head "$B"
  fr clone "$RUN" > "$TMP/t.out" 2>&1 && return 1
  grep -q 'head moved' "$TMP/t.out" && [ ! -e "$RUN" ]
}
t_clone_moved; check "clone: a moved head aborts and leaves no run directory" $?
t_mismatch() { # the compare read disagrees with the clone: render-only, no round
  fx_default; api "repos/o/r/compare/$B...$H" "{\"merge_base_commit\": {\"sha\": \"$H\"}}"; new_run
  fr clone "$RUN" > "$TMP/t.out" 2>&1 && grep -q '^write path: render-only' "$TMP/t.out" && grep -q 'disagree' "$TMP/t.out" || return 1
  round0 "$OUT"; fr items "$RUN" --review "$OUT/round-0" > /dev/null 2>&1 || return 1
  fr round "$RUN" > /dev/null 2>&1 && return 1
  fr cleanup "$RUN" > /dev/null
}
t_mismatch; check "merge base: a compare read that disagrees with the clone is render-only" $?
t_nullmb() {
  fx_default; api "repos/o/r/compare/$B...$H" '{"merge_base_commit": null}'; new_run
  fr clone "$RUN" > "$TMP/t.out" 2>&1; grep -q '^write path: render-only' "$TMP/t.out" && fr cleanup "$RUN" > /dev/null
}
t_nullmb; check "merge base: a null compare merge base is render-only" $?
t_readfail() {
  fx_default; rm "$FX/api/repos/o/r/pulls/7/reviews.json"; new_run
  grep -q '^reads failed: reviews' <<< "$P" && fr clone "$RUN" > "$TMP/t.out" 2>&1; grep -q 'a read failed: reviews' "$TMP/t.out" && fr cleanup "$RUN" > /dev/null
}
t_readfail; check "state: a failed read is render-only" $?
t_ci() {
  fx_default; P="$(CI=true fr prepare --repo o/r --pr 7 2>&1)"; RUN="$(sed -n 's/^RUN=//p' <<< "$P")"
  fr clone "$RUN" > "$TMP/t.out" 2>&1; grep -q 'a CI environment is set' "$TMP/t.out" && fr cleanup "$RUN" > /dev/null
}
t_ci; check "identity: a CI environment is render-only" $?
t_noident() {
  fx_default; mv "$HOME/.gitconfig" "$HOME/.gitconfig.off"; new_run; mv "$HOME/.gitconfig.off" "$HOME/.gitconfig"
  grep -q '^commit identity: none, patch only' <<< "$P" && fr clone "$RUN" > "$TMP/t.out" 2>&1 && grep -q '^write path: B' "$TMP/t.out" &&
    round0 "$OUT" && fr items "$RUN" --review "$OUT/round-0" > /dev/null && fr round "$RUN" > /dev/null || return 1
  fix_edit; fr commit "$RUN" --round 1 > /dev/null 2>&1 && return 1
  fr compare "$RUN" --round 1 --findings "$TMP/empty.json" > /dev/null && fr gate "$RUN" > "$TMP/t.out" 2>&1 || { cat "$TMP/t.out"; return 1; }
  grep -q '^write path: B' "$TMP/t.out" && grep -q 'size' "$OUT/fix.patch" && [ "$(CG rev-parse HEAD)" = "$H" ] &&
    fr push "$RUN" --confirm-branch feat --expect-sha "$H" > /dev/null 2>&1 && return 1
  fr cleanup "$RUN" > /dev/null
}
t_noident; check "commit identity unset: no commit, the patch only, no push" $?

# --- 12. The output and run directories ----------------------------------------------------------

t_out() {
  fx_default
  mkdir -p "$TMP/o-real" "$TMP/o-full"; ln -sfn "$TMP/o-real" "$TMP/o-link"; printf x > "$TMP/o-full/f"
  mkdir -p "$TMP/o-par/real"; ln -sfn "$TMP/o-par/real" "$TMP/o-par/l"; mkdir -p "$TMP/o-par/l/sub"
  local n0; n0="$(find "$TMPDIR" -maxdepth 1 -name 'pr-fix.*' | wc -l | tr -d ' ')"
  outof fr prepare --repo o/r --pr 7 --out "$TMP/o-link" | grep -qE 'refused: not an existing directory|symbolic link' &&
  outof fr prepare --repo o/r --pr 7 --out "$TMP/o-par/l/sub" | grep -q 'symbolic link in its path' &&
  outof fr prepare --repo o/r --pr 7 --out "$M/examples" | grep -q 'inside a git work tree' &&
  outof fr prepare --repo o/r --pr 7 --out "$TMP/o-full" | grep -q 'not empty' &&
  outof fr prepare --repo o/r --pr 7 --out o-real | grep -q 'not an absolute path' &&
  [ "$(find "$TMPDIR" -maxdepth 1 -name 'pr-fix.*' | wc -l | tr -d ' ')" = "$n0" ] || return 1
  new_run --out "$TMP/o-real"; [ "$OUT" = "$TMP/o-real" ] || return 1
  case "$RUN" in "$TMPDIR"/pr-fix.??????) ;; *) return 1 ;; esac
  fr cleanup "$RUN" > /dev/null
  new_run; case "$OUT" in "$TMPDIR"/pr-fix-out.??????) ;; *) return 1 ;; esac
  [ "$(stat -f %Lp "$OUT" 2> /dev/null || stat -c %a "$OUT")" = 700 ] && fr cleanup "$RUN" > /dev/null && [ -d "$OUT" ]
}
t_out; check "output directory: a symbolic link, a symlinked parent, inside a work tree, not empty, relative refused; the default is 0700 and kept" $?
t_cleanup() {
  fx_default; new_run
  fr cleanup "$TMP/pr-fix.abcdef" > /dev/null 2>&1; [ $? = 2 ] || return 1
  fr cleanup "$RUN/../$(basename "$RUN")" > /dev/null 2>&1; [ $? = 2 ] || return 1
  fr cleanup "$RUN" > /dev/null && [ ! -e "$RUN" ]
}
t_cleanup; check "cleanup: only a resolved run directory of the template is deleted" $?

# --- Negative self-check: each mutation of a temp copy must make its named case fail. ------------

oc=0
mutate() { # name, perl substitution, case function
  local d="$TMP/mut-$oc/skills"; oc=$((oc + 1)); mkdir -p "$d/terraform-module-pr-fix/references"
  ln -s "$SKILLS/terraform-module-pr-review" "$d/terraform-module-pr-review"
  local r="$SKILLS/terraform-module-pr-fix/references"
  cp "$r/fix-run.sh" "$r/fix-run.jq" "$d/terraform-module-pr-fix/references/"
  perl -0pi -e "$2" "$d/terraform-module-pr-fix/references/fix-run.sh" "$d/terraform-module-pr-fix/references/fix-run.jq"
  if cmp -s "$d/terraform-module-pr-fix/references/fix-run.sh" "$r/fix-run.sh" && cmp -s "$d/terraform-module-pr-fix/references/fix-run.jq" "$r/fix-run.jq"; then
    check "self-check: $1 (the mutation changed nothing)" 1; return
  fi
  local keep="$FR" before="$fails"; FR="$d/terraform-module-pr-fix/references/fix-run.sh"
  "$3" > /dev/null 2>&1; local s=$?
  FR="$keep"; fails="$before"
  check "self-check: $1 is caught" "$([ "$s" != 0 ]; echo $?)"
}
mutate "the git wrapper without env -i" 's/^  env -i PATH="\$PATH" HOME="\$RUN\/home" GIT_CONFIG_GLOBAL/  env PATH="\$PATH" HOME="\$RUN\/home" GIT_CONFIG_GLOBAL/m' t_e2e
mutate "verification without env -i" 's/  env -i PATH="\$PATH" HOME="\$RUN\/home" TMPDIR/  env PATH="\$PATH" HOME="\$RUN\/home" TMPDIR/' t_e2e
mutate "a push with force" 's/push --no-follow-tags/push --force --no-follow-tags/' t_e2e
mutate "the confirm-branch guard dropped" 's/\[ -n "\$cb" \] && \[ "\$cb" = "\$ref" \] \|\|/true ||/' t_e2e
mutate "the symbolic link check dropped" 's/\$2 ~ \/\^\(120000\|160000\)\$\//\$2 ~ \/^(160000)\$\//' t_gate_symlink
mutate "the config key check dropped" 's/|| echo "the clone.s local config changed"/|| true/' t_gate_insteadof
mutate "the tree check dropped" 's/\[ "\$\(G write-tree\)" = "\$\(jq -r .\.tree. "\$RUN\/reviewed\.json"\)" \] \|\|/true ||/' t_gate_tree
mutate "the identity check dropped" 's/grep -vxF -- "\$name"/grep -vxF -- "\$name\$name"/; s/ > \/dev\/null &&\n      echo "a commit is not by the gate identity"/ > \/dev\/null \&\& false \&\&\n      echo "a commit is not by the gate identity"/' t_gate_ident
mutate "a string id taken as canonical" 's/def canon: type == "number" and/def canon: (tonumber? \/\/ 0) as \$n | \$n >= 1 or/' t_origins
mutate "the hostile clone_url used" 's/url: "https:\/\/github\.com\/\\\(\$dest\)\.git"/url: (\$s.pr.head.repo.clone_url \/\/ "https:\/\/github.com\/\\(\$dest).git")/' t_url
mutate "a severity raise not introduced" 's/select\(\(\.key \| fromjson\)\[3\] \| open_sev\) \| select\(\.value > \(\$a\[\.key\] \/\/ 0\)\)/select((.key | fromjson)[3] | open_sev) | select(.value > (\$a[.key] \/\/ 0) and \$a[.key] != null)/' t_intro
mutate "comment traffic aborts" 's/\(if \$w\.path != "A" then "the destination permission is lost" else empty end\) \]/(if \$w.path != "A" then "the destination permission is lost" else empty end), (if \$f.comments != null and (\$f.comments | length) > 0 then "comments changed" else empty end) ]/' t_prepush
mutate "the token check dropped" 's/\[ -n "\$\("\$\{GHENV\[\@\]\}" gh auth token --hostname github\.com 2> \/dev\/null\)" \]/true/' t_token
mutate "a reply id outside the frozen set" 's/select\(\(\[\$it\[0\]\[\] \| select\(\.id == \$i and \.reply != null\)\] \| length\) == 0 or/select(false and/' t_e2e
mutate "the round limit dropped" 's/\[ "\$n" -le "\$LIMIT" \] \|\|/true ||/' t_rounds
mutate "the output directory symlink check dropped" 's/\[ "\$real" = "\$\{o%\/\}" \] \|\|/true ||/' t_out

echo
if [ "$fails" -eq 0 ]; then echo "pr-fix: all checks hold"; else echo "pr-fix: $fails failed"; exit 1; fi
