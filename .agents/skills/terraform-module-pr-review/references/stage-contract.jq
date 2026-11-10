# stage-contract.jq: the pin and the stage file shapes shared by the pull request skills, as
# stage-contract.md states them. Each function is pure: it reads only the JSON it is given.
# Include it with `jq -L <this directory> 'include "stage-contract"; ...'`.

# --- Grammar ---------------------------------------------------------------------------------

def sha_ok: type == "string" and test("^[0-9a-f]{40}$");
def repo_ok: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$");
def ref_ok: type == "string" and test("^[A-Za-z0-9_][A-Za-z0-9._/-]{0,199}$")
  and (test("\\.\\.|//|/\\.|\\.lock$|/$|\\.$") | not);

# --- The pin ---------------------------------------------------------------------------------

# The nine gated pin keys, in the order pin_diff names a difference.
def pin_keys: ["target", "number", "base_repo", "head_repo", "base_ref", "head_ref", "head_sha", "base_sha", "merge_base"];
# Recorded as information, never compared.
def pin_info_keys: ["run_id", "skill_version", "diff_hash"];

def info_ok: type == "string" and length <= 200 and test("^[ -~]*$");

# Input: a pin. Exactly the nine keys plus any of the information keys, each in its grammar.
# head_repo is null when the fork behind the pull request is gone.
def pin_ok:
  type == "object"
  and (keys - pin_keys - pin_info_keys | length) == 0
  and (pin_keys - keys | length) == 0
  and (.target | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}#[1-9][0-9]{0,8}$"))
  and (.number | type == "number" and . == floor and . >= 1 and . <= 999999999)
  and (.target | sub("^.*#"; "") | tonumber) == .number
  and (.base_repo | repo_ok)
  and (.head_repo == null or (.head_repo | repo_ok))
  and (.base_ref | ref_ok)
  and (.head_ref | ref_ok)
  and (.head_sha | sha_ok)
  and (.base_sha | sha_ok)
  and (.merge_base | sha_ok)
  and all(pin_info_keys[] as $k | select(has($k)) | .[$k]; info_ok);

# Input: a pin. The first gated key whose value differs from the live pin's, or null.
def pin_diff($live): (first(pin_keys[] as $k | select(.[$k] != $live[$k]) | $k) // null);

# Input: {pr, merge_base}, pr a GET repos/{owner}/{repo}/pulls/{number} object. The live pin.
def live_pin:
  .pr as $p
  | {target: "\($p.base.repo.full_name)#\($p.number)",
     number: $p.number,
     base_repo: $p.base.repo.full_name,
     head_repo: ($p.head.repo.full_name // null),
     base_ref: $p.base.ref,
     head_ref: $p.head.ref,
     head_sha: $p.head.sha,
     base_sha: $p.base.sha,
     merge_base: .merge_base};

# --- The stage files -------------------------------------------------------------------------

# The exact top-level key set of each kind.
def stage_keys:
  {"review-plan": ["kind", "schema", "pin", "verdict", "proposed_event", "findings", "read_at",
                   "handover_block", "module_prefix", "module_profile", "reviewer_id"],
   "applied": ["kind", "schema", "pin", "new_sha", "plan_head_sha", "round_verdict"]};

# Input: a stage file. Its kind is $kind, its schema is 1, its pin is valid and its keys are
# exactly the kind's set. Field values beyond the pin are the reader's to validate.
def stage_ok($kind):
  type == "object"
  and (stage_keys | has($kind))
  and .kind == $kind
  and .schema == 1
  and (.pin | pin_ok)
  and ((keys | sort) == (stage_keys[$kind] | sort));

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

# --- Merge commit title ----------------------------------------------------------------------

# Input: the pull request title. Control characters removed, whitespace runs collapsed to one
# space, cut to 72 characters, then " (#N)" appended; cut is true when the cut removed text.
def commit_title($n):
  (explode | map(select(. > 31 and (. < 127 or . > 159))) | implode | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "")) as $t
  | {title: ($t[0:72] + " (#\($n))"), cut: (($t | length) > 72)};
