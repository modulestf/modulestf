# fix-run.jq: the decision functions of terraform-module-pr-fix, as write-path.md states them.
# Each one is pure: it reads only the JSON it is given. fix-run.sh and tests/pr-fix-test.sh
# include this file with `jq -L <dir> 'include "fix-run"; ...'`.

# --- Identity --------------------------------------------------------------------------------

# A canonical positive decimal id: a JSON integer of at least 1. A string is never one, so no
# coercion can make "12" equal 12.
def canon: type == "number" and . == floor and . >= 1 and . <= 9007199254740991;
def same_id($a; $b): ($a | canon) and ($b | canon) and $a == $b;
def is_bot: (.user.type == "Bot") or ((.user.login | type) == "string" and (.user.login | endswith("[bot]")));

# Origins, in the order written: self, bot, change-author, maintainer, other.
def origin($tok; $author):
  if same_id(.user.id; $tok) then "self"
  elif is_bot then "bot"
  elif same_id(.user.id; $author) then "change-author"
  elif (.author_association | IN("OWNER", "MEMBER", "COLLABORATOR")) then "maintainer"
  else "other" end;
# The origin the maintainer's feedback set takes: the same order without self.
def role($author):
  if is_bot then "bot"
  elif same_id(.user.id; $author) then "change-author"
  elif (.author_association | IN("OWNER", "MEMBER", "COLLABORATOR")) then "maintainer"
  else "other" end;

# --- Write path ------------------------------------------------------------------------------

def sha_ok: type == "string" and test("^[0-9a-f]{40}$");
def repo_ok: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$");
def ref_ok: type == "string" and test("^[A-Za-z0-9_][A-Za-z0-9._/-]{0,199}$")
  and (test("\\.\\.|//|/\\.|\\.lock$|/$|\\.$") | not);
def bool_ok: type == "boolean";
def push_perm: type == "object" and (.push == true or .maintain == true or .admin == true);

# The merge base check: the compare read's sha against `git merge-base --all` in the fix clone.
def merge_base_check:
  if (.compare | sha_ok | not) then {ok: false, reason: "the compare read gave no merge base"}
  elif (.local | length) == 0 then {ok: false, reason: "the fix clone has no merge base"}
  elif (.local | length) > 1 then {ok: false, reason: "the fix clone has several merge bases"}
  elif .local[0] != .compare then {ok: false, reason: "the compare read and the fix clone disagree"}
  else {ok: true, reason: "one merge base", sha: .compare} end;

# The fields the write path reads, each of its type; a missing one is unknown.
def unknown_fields:
  .pr as $p | .base_repo as $b | .head_repo as $h |
  [ (if ($p.state | type) != "string" then "pr.state" else empty end),
    (if ($p.merged | bool_ok | not) then "pr.merged" else empty end),
    (if ($p.draft | bool_ok | not) then "pr.draft" else empty end),
    (if ($p.maintainer_can_modify | bool_ok | not) then "pr.maintainer_can_modify" else empty end),
    (if ($p.head.sha | sha_ok | not) then "pr.head.sha" else empty end),
    (if ($p.base.repo.full_name | repo_ok | not) then "pr.base.repo" else empty end),
    (if ($p.user.id | canon | not) then "pr.user.id" else empty end),
    (if ($b.archived | bool_ok | not) then "base.archived" else empty end),
    (if ($b.permissions | type) != "object" then "base.permissions" else empty end),
    (if $p.head.repo != null and (($p.head.repo.full_name | repo_ok | not)
       or ($h.archived | bool_ok | not) or ($h.permissions | type) != "object"
       or ($h.default_branch | type) != "string") then "head.repo" else empty end) ];

# Input {state, merge_base}: merge_base is merge_base_check's output, or null before the clone.
def write_path:
  .state as $s | .merge_base as $m | $s.pr as $p |
  [ (if ($s.failed | length) > 0 then "a read failed: " + ($s.failed | join(", ")) else empty end),
    (if ($s.token.id | canon) and $s.token.type == "User"
        and ($s.token.login | type) == "string" and ($s.token.login | test("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$"))
     then empty else "the token user is not a person" end),
    (if $s.ci != false then "a CI environment is set" else empty end),
    (($s | unknown_fields) as $u | if ($u | length) > 0 then "a field is unknown: " + ($u | join(", ")) else empty end),
    (if $p.head.repo == null then "the head repository is gone" else empty end),
    (if ($p.head.ref | ref_ok | not) then "the head ref is missing" else empty end),
    (if $s.base_repo.archived == true or $s.head_repo.archived == true then "a repository is archived" else empty end),
    (if $p.state != "open" or $p.merged != false then "the pull request is closed or merged" else empty end),
    (if $m == null then "the merge base is not checked yet"
     elif $m.ok != true then "the merge base is not exactly one: " + ($m.reason // "unknown") else empty end) ] as $why |
  if ($why | length) > 0 then {path: "render-only", reasons: $why}
  else
    $p.head.repo.full_name as $dest |
    { dest: {repo: $dest, url: "https://github.com/\($dest).git", ref: $p.head.ref, expected_sha: $p.head.sha},
      flags: {draft: $p.draft, default_branch: ($p.head.ref == $s.head_repo.default_branch)} } +
    if ($s.head_repo.permissions | push_perm) then {path: "A", via: "head-permission", reasons: []}
    elif $dest != $p.base.repo.full_name and $p.maintainer_can_modify == true and ($s.base_repo.permissions | push_perm)
    then {path: "A", via: "maintainer-can-modify", reasons: []}
    else {path: "B", reasons: ["the token user cannot push to the head ref"]} end
    | if .path == "A" and $s.commit_identity == null
      then .path = "B" | del(.via) | .reasons = ["no commit identity in the user's git config: patch only"] else . end
  end;

# The fresh read with the pinned run's own facts: token, CI, commit identity and merge base.
def write_path_input($pinned):
  {state: (. + {token: $pinned.state.token, ci: $pinned.state.ci, commit_identity: $pinned.state.commit_identity}),
   merge_base: $pinned.merge_base} | write_path;

# Pre-push: the pinned state against a fresh read. Every reason aborts; comments are not read.
def prepush_abort($pinned; $path):
  . as $f | ($f | write_path_input($pinned)) as $w |
  [ (if ($f.failed | length) > 0 then "a read failed: " + ($f.failed | join(", ")) else empty end),
    (($f | unknown_fields) as $u | if ($u | length) > 0 then "a field is unknown: " + ($u | join(", ")) else empty end),
    (if $f.pr.head.sha != $path.dest.expected_sha then "the head ref moved" else empty end),
    (if $f.pr.state != "open" then "the pull request is not open" else empty end),
    (if $f.pr.merged != false then "the pull request is merged" else empty end),
    (if $f.base_repo.archived != false or $f.head_repo.archived != false then "a repository is archived" else empty end),
    (if $f.pr.head.repo.full_name != $path.dest.repo or $f.pr.head.ref != $path.dest.ref then "the destination changed" else empty end),
    (if $path.via == "maintainer-can-modify" and $f.pr.maintainer_can_modify != true then "maintainer_can_modify is false" else empty end),
    (if $w.path != "A" then "the destination permission is lost" else empty end) ]
  | unique;

# --- Findings, fingerprints and the local verdict ---------------------------------------------

def findings_ok: type == "array" and all(.[]; type == "object"
  and (.id | type == "string" and test("^[A-Za-z0-9._-]{1,32}$"))
  and (.rule_id | type == "string" and test("^[a-z]+\\.[a-z0-9-]+$"))
  and (.severity | IN("CRITICAL", "HIGH", "MEDIUM", "LOW"))
  and (.file | type == "string" and length > 0 and (test("^/|(^|/)\\.\\.(/|$)") | not))
  and (.summary | type == "string") and (.suggested_fix | type == "string"));

# The block address of a finding: the first code span of its summary, then of its fix, that is one.
def addr:
  [(.summary // ""), (.suggested_fix // "") | [scan("`([^`]+)`")[0]] | .[]
   | select(test("^(resource|data) \"[^\"]+\" \"[^\"]+\"$|^(variable|output|module) \"[^\"]+\"$|^(locals|terraform)$"))]
  | .[0] // "";
# (rule_id, repository-relative file, block address or "", severity); never a line.
def fp($prefix):
  [.rule_id, (if $prefix == "" then .file elif .file == "." then $prefix else $prefix + "/" + .file end), addr, .severity];
def open_sev: IN("CRITICAL", "HIGH", "MEDIUM");
def verdict: if length == 0 then "clean" elif all(.[]; .severity == "LOW") then "nits" else "open" end;
def counts: group_by(.) | map({key: (.[0] | tojson), value: length}) | from_entries;
# The MEDIUM or higher tuples whose count at $now is above their count at $pin.
def introduced($pin; $now):
  ($pin | counts) as $a |
  [$now | counts | to_entries[] | select((.key | fromjson)[3] | open_sev) | select(.value > ($a[.key] // 0))
   | .key | fromjson];
# Multiset difference $a - $b of lists of strings.
def msub($a; $b): ($b | counts) as $c |
  [$a | counts | to_entries[] | .key as $k | (.value - ($c[$k] // 0)) as $n | select($n > 0) | range($n) | $k | fromjson];

# --- The loop --------------------------------------------------------------------------------

def closing: IN("apply", "already-addressed", "duplicate", "reject", "out-of-scope");
def decisions: IN("apply", "reject", "unverified", "already-addressed", "duplicate", "out-of-scope", "needs-decision", "unclear");

# Input {history, round, limit, verdict, nonactionable}: history is the open set of each reviewed
# round, round 0 first, each a list of strings (a fingerprint as JSON text, or "item:<id>").
def loop_decision:
  .history as $h | ($h | length - 1) as $n | $h[$n] as $now |
  ([range(0; [$n - 1, 0] | max) | . as $k | msub($h[$k]; $h[$k + 1])[]] | unique) as $closed |
  if .verdict == "clean" or .verdict == "nits" then {stop: true, finished_review: true,
    reason: "the local verdict is \(.verdict): finished among attributable findings, \(.unattributed // 0) unattributed"}
  elif .nonactionable then {stop: true, finished_review: false, reason: "every open item is non-actionable"}
  elif $n >= 1 and any($now[]; IN($closed[])) then {stop: true, finished_review: false, reason: "no progress: a closed item reappears"}
  elif $n >= 1 and ((($now | length) >= ($h[$n - 1] | length)) or (msub($now; $h[$n - 1]) | length) > 0)
  then {stop: true, finished_review: false, reason: "no progress: the open set did not shrink"}
  elif .round >= .limit then {stop: true, finished_review: false, reason: "round \(.round) is the last"}
  else {stop: false, finished_review: false, reason: "the next round may start"} end;

# --- Checks ----------------------------------------------------------------------------------

# Input {ok, runs, statuses, pinned_total}: pinned_total is null when the pinned head's reads failed.
def checks_class:
  if .ok != true then {class: "not finished", reason: "a checks read failed"}
  else
    (.runs | group_by(.name) | map(max_by(.id))) as $r |
    (.statuses | group_by(.context) | map(max_by(.id))) as $s |
    if ($r | length) + ($s | length) == 0 then
      if .pinned_total == 0 then {class: "passing", reason: "no checks, and the pinned head had none"}
      else {class: "not finished", reason: "no checks yet, the pinned head had \(.pinned_total // "unknown")"} end
    else
      ([$r[] | select((.status == "completed" and (.conclusion | IN("success", "skipped"))) | not) | .name]
       + [$s[] | select(.state != "success") | .context]) as $bad |
      if ($bad | length) == 0 then {class: "passing", reason: "\($r | length) check runs and \($s | length) statuses passed"}
      else {class: "not finished", reason: ("not passing: " + ($bad | sort | .[0:5] | join(", ")))} end
    end
  end;

# --- Allowed paths ---------------------------------------------------------------------------

def path_grammar: test("^[A-Za-z0-9_][A-Za-z0-9._-]*(/[A-Za-z0-9_][A-Za-z0-9._-]*)*$") and length <= 255;
# The module root prefix as clone froze it: the empty string, or the grammar's components.
def prefix_ok: type == "string" and (. == "" or path_grammar);
# Under the module root: the slash-boundary test.
def under($prefix): $prefix == "" or startswith($prefix + "/");

# The directory of a path: the bytes before its last slash, or "" when it has none.
def dir_of: rindex("/") as $i | if $i == null then "" else .[0:$i] end;
# The NUL-separated output of git diff-tree --name-only as module-relative paths.
def module_paths($x): [split("\u0000")[] | select(. != "" and under($x)) | if $x == "" then . else .[($x | length) + 1:] end];
# Attribution (write-path.md, Fingerprints and the Local Verdict). Input {findings, pinned, changed,
# prefix}: findings the round's list with module-relative files, pinned the pinned head's list,
# repository-relative, changed the round's changed paths, module-relative. Output {attributable,
# unattributed}, both repository-relative. A5 comes first, so a malformed file never reaches A2.
def attribution:
  .prefix as $x | .changed as $ch | [.pinned[] | [.rule_id, .file, addr]] as $pk |
  [.findings[] | .file as $f |
    ( ($f != "." and ($f | path_grammar | not))
      or ($f | IN($ch[]))
      or ($f != "" and $f != "." and (($f | dir_of) as $d | any($ch[]; endswith(".tf") and dir_of == $d)))
      or ([.rule_id, fp($x)[1], addr] | IN($pk[]))
      or (.severity | IN("HIGH", "CRITICAL")) ) as $a
    | {a: $a, f: (.file = fp($x)[1])}]
  | {attributable: map(select(.a) | .f), unattributed: map(select(.a | not) | .f)};

# Clauses 1 to 3 of write-path.md, Allowed Paths, on one path: "" when they hold, else the clause.
def path_clause($prefix):
  if (path_grammar | not) or (under($prefix) | not) then "grammar"
  elif (test("\\.(tf|tfvars|md)$|\\.tftest\\.hcl$") | not) then "suffix"
  elif (split("/") | any(.[]; ascii_downcase == "wrappers")) or (split("/") | .[-1] | ascii_downcase) == "changelog.md" then "reserved"
  else "" end;

# The entries of `git ls-tree -r -t -z --full-tree` as {path: mode}; null when a record does not parse.
def tree_modes:
  if . == "" then [] else split("\u0000") | if .[-1] != "" then null else .[:-1] end end
  | if . == null then null else
      [.[] | index("\t") as $i | select($i != null) | {m: .[0:$i], p: .[$i + 1:]}
       | select((.m | test("^[0-7]{6} (blob|tree|commit) [0-9a-f]{40,64}$")) and .p != "")] as $e
      | if ($e | length) != length then null else ($e | map({(.p): .m[0:6]}) | add // {}) end
    end;
# The records of `git diff-tree -r -z --raw --no-renames` as [{path, om, nm}]; null when one does not parse.
def raw_records:
  if . == "" then [] else split("\u0000") | if (length % 2) != 1 or .[-1] != "" then null else .[:-1] end end
  | if . == null then null else
      [range(0; length; 2) as $i | {meta: .[$i], path: .[$i + 1]}
       | (.meta | capture("^:(?<om>[0-7]{6}) (?<nm>[0-7]{6}) [0-9a-f]{40,64} [0-9a-f]{40,64} [ADMT]$")) as $c
       | select(.path != "") | {path, om: $c.om, nm: $c.nm}] as $r
      | if ($r | length) != (length / 2) then null else $r end
    end;

# Clauses 1 to 5 on records [{path, om, nm}] between the parent tree $a and the new tree $b, both
# {path: mode}. $e lists the mapped wrappers the caller found to meet clause 3's exception; only a
# modified record of one passes clause 3. Output {refused: [{path, clause}], md: [{path, om, nm}]}:
# md, the .md paths clause 6 judges, only when nothing is refused.
def clauses($a; $b; $x; $e):
  [.[] | .path as $p
   | ($p | path_clause($x)) as $c0
   | (if $c0 == "reserved" and ($p | IN($e[])) and .om != "000000" and .nm != "000000" then "" else $c0 end) as $c
   | (if $c != "" then $c
      elif any(.om, .nm; IN("000000", "100644") | not) then "mode"
      elif any($p | split("/") | range(1; length) as $i | .[0:$i] | join("/") | ($a[.], $b[.]); . != null and . != "040000") then "ancestors"
      else "" end) as $why
   | {path: $p, om, nm, clause: $why}]
  | {refused: map(select(.clause != "") | {path, clause}),
     md: (if all(.[]; .clause == "") then map(select(.path | endswith(".md")) | {path, om, nm}) else [] end)};

# Input {raw, par, new, prefix, except}: the git output of one commit against its parent, and the
# wrappers clause 3 excepts. null when an input does not parse or the prefix is malformed.
def path_rule:
  (.raw | raw_records) as $r | (.par | tree_modes) as $a | (.new | tree_modes) as $b | .prefix as $x | (.except // []) as $e |
  if $r == null or $a == null or $b == null or ($x | prefix_ok | not) then null else $r | clauses($a; $b; $x; $e) end;

# The staging invariants: input {paths, par, new, prefix}, paths the NUL-separated changed and
# untracked paths of the work tree, new the work tree as a listing in ls-tree form (the paths and
# their existing components, by lstat), except the wrappers clause 3 excepts. The same clauses 1 to 5.
def stage_rule:
  (.par | tree_modes) as $a | (.new | tree_modes) as $b | .prefix as $x | (.except // []) as $e |
  if $a == null or $b == null or ($x | prefix_ok | not) then null
  else [.paths | split("\u0000")[] | select(. != "")] | unique | map({path: ., om: ($a[.] // "000000"), nm: ($b[.] // "000000")})
    | clauses($a; $b; $x; $e) end;

# The selection rule, shared by the docs step and clause 6. Input {tf, readme, links, prefix}: tf
# the NUL-separated paths changed between the frozen merge base and the documented tree, readme the
# README.md paths that exist in that tree, links the directories that hold a .tf that is a link.
# Output [{readme, entry, dir, label, stale}]: entry is the README relative to the module root, dir
# its directory in the docs pass's form ("." for the module root). Wrapper paths are not selected.
def docs_selection:
  .prefix as $x | .readme as $r | .links as $l |
  [.tf | split("\u0000")[] | select(endswith(".tf") and (split("/") | any(.[]; ascii_downcase == "wrappers") | not))
   | (split("/") | .[:-1] | join("/")) as $d
   | (if $d == "" then "README.md" else $d + "/README.md" end) as $m
   | select(($m | under($x)) and ($m | IN($r[])))
   | {readme: $m, d: $d}] | unique_by(.readme)
  | map((if $x == "" then .readme else .readme[($x | length) + 1:] end) as $e
    | (if $e == "README.md" then "." else $e[0:-10] end) as $dir
    | {readme, entry: $e, dir: $dir, label: (if ($dir | test("^[ -~]{1,200}$")) then $dir else "an unprintable path" end),
       stale: (if (.d | IN($l[])) then "a .tf in its directory is a symbolic link" else null end)});

# --- Captured state --------------------------------------------------------------------------

def user_of: {id: .user.id, login: .user.login, type: .user.type};
def repo_of: if . == null then null else {full_name, archived, private, default_branch, permissions} end;
# Input: the raw reads of prepare (or of pre-push), as one object; output: the state file.
def state_of:
  {format: 1, repo, number, failed, token: (.token | if . == null then null else {id, login, type} end),
   ci, commit_identity: .commit,
   pr: (.pr | {state, merged, draft, locked, maintainer_can_modify, user: user_of,
     head: {sha: .head.sha, ref: .head.ref, repo: (if .head.repo == null then null else {full_name: .head.repo.full_name} end)},
     base: {sha: .base.sha, ref: .base.ref, repo: {full_name: .base.repo.full_name}}}),
   base_repo: (.base | repo_of), head_repo: (.head | repo_of),
   merge_base_compare: (.compare.merge_base_commit.sha // null),
   change_set: ([.files[]? | .filename, (.previous_filename // empty)] | unique),
   comments: [
     (.reviews[]? | select((.body // "") != "") | {kind: "review", id, user: user_of, author_association, body,
        path: null, line: null, reply_to: null}),
     (.rcomments[]? | {kind: "thread", id, user: user_of, author_association, body, path,
        line: (.line // .original_line), reply_to: (.in_reply_to_id // .id)}),
     (.icomments[]? | {kind: "conversation", id, user: user_of, author_association, body,
        path: null, line: null, reply_to: null})],
   checks_pinned: (if .pinned_ok then {total: ((.runs | length) + (.statuses | length))} else {total: null} end)};

# --- Feedback items --------------------------------------------------------------------------

# Input {state, findings}: the frozen item set. Findings are the round-0 review's, repository-relative.
# The role a finding item takes: that of the account the review is posted under.
def own_role:
  if same_id(.token.id; .pr.user.id) then "change-author" elif (.base_repo.permissions | push_perm) then "maintainer" else "other" end;
def items_of:
  .state as $s | $s.token.id as $tok | $s.pr.user.id as $au | ($s | own_role) as $own |
  [ (.findings[] | {id, source: "finding", origin: "reviewer", role: $own, eligible: true,
       file, line, text: (.summary + "\nFix: " + .suggested_fix), fingerprint: (fp("") | tojson), reply: null}),
    ($s.comments[] | select((.id | canon) and (.reply_to == null or (.reply_to | canon))) |
      (if .kind == "thread" then "T" elif .kind == "review" then "V" else "C" end) as $k |
      origin($tok; $au) as $o |
      {id: "\($k)-\(.id)", source: (if .kind == "review" then "conversation" else .kind end), origin: $o, role: role($au),
       eligible: ($o == "self"), file: .path, line, text: (.body // ""), fingerprint: null,
       reply: (if .kind == "thread" then "repos/\($s.repo)/pulls/\($s.number)/comments/\(.reply_to)/replies"
               else "repos/\($s.repo)/issues/\($s.number)/comments" end)}) ];

# The reply endpoint of a comment item, rebuilt from the pinned state and the item id alone.
def reply_endpoint($id):
  . as $s | ($id | capture("^(?<k>[TCV])-(?<n>[1-9][0-9]{0,18})$")? // null) as $m |
  if $m == null then null
  else ({"T": "thread", "V": "review", "C": "conversation"}[$m.k]) as $kind |
    [$s.comments[] | select(.kind == $kind and (.id | canon) and (.id | tostring) == $m.n)] as $c |
    if ($c | length) != 1 then null
    elif $kind == "thread" then ($c[0].reply_to | if canon then "repos/\($s.repo)/pulls/\($s.number)/comments/\(.)/replies" else null end)
    else "repos/\($s.repo)/issues/\($s.number)/comments" end
  end;

# The verification record in the line form of pr-review's verify-pass.md, Records, as review-run.sh
# writes it into the handover (its VERIFY_LINES_JQ); tests/pr-fix-test.sh holds the two equal.
def verify_lines:
  def side_base: if . == null then ""
    elif .record == "code-result" then (if .validate == 0 then "new under this change" else "already failing at the base" end)
    elif .record == "init-failed" then "already failing at the base"
    elif .record == "absent-at-base" then "absent at base"
    elif .record == "base-unavailable" then "merge base not available"
    elif .record == "not-run-environment" then "merge base not run: environment"
    elif .record == "not-run-limit" then "merge base not run: command limit"
    elif .record == "not-run-budget" then "merge base not run: budget"
    else "merge base not available" end;
  def ln: if .line then ": " + .line else "" end;
  "example selection: \(.selection.tool)" + (if .selection.fallback then ", fallback \(.selection.fallback)" else "" end)
    + (if .selection.inert then ", inert: nothing to verify" else "" end),
  (.dirs[] | "\(.dir) (\(.affected)): " + (
    if .reason == "skipped-version-bump" then "not run: version bump only"
    elif .reason == "skipped-symlink" then "not run: symbolic link"
    elif .head.record == "code-result" then "terraform init -backend=false exit \(.head.init), terraform validate exit \(.head.validate)"
      + (if .head.validate != 0 then (.head | ln) + "; at the merge base: " + (.base | side_base) else "" end)
    elif .head.record == "init-failed" then "terraform init -backend=false exit \(.head.init), init failed" + (.head | ln)
    elif .head.record == "not-run-environment" then "not run: environment" + (.head | ln)
    elif .head.record == "terraform-absent" then "terraform absent"
    elif .head.record == "not-run-limit" then "not run: command limit"
    elif .head.record == "not-run-budget" then "not run: budget"
    else "verification input refused" end)
    + (if .outside then ", outside the sandbox, by authorization" else "" end));
