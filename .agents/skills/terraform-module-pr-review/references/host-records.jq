# host-records.jq: the pure parts of host-pass.sh run, as jq functions. Every rule here is
# stated in github-io.md (Metadata, Workspace, Changed Files, Discussion, Conversation
# Comments, Related Issues, Handover) and verdict.md (Host Signals). The shell reads; these
# functions decide. Loaded with: jq -L <references dir> 'include "host-records"; ...'

def crlf: gsub("\r\n"; "\n");

# --- Workspace: the module root prefix, from the head tree.

def module_files: ["main.tf", "variables.tf", "versions.tf"];

# A tree as {tree: [{path, mode, type, sha, size}], truncated} -> "" or "<dir>", or null
# when no single shallowest directory holds all three files.
def prefix:
  [.tree[] | select(.type == "blob") | .path] as $blobs
  | ($blobs | map(select(test("/") | not))) as $root
  | if (module_files - $root) == [] then ""
    else
      [$blobs[] | select(test("/")) | capture("^(?<d>.*)/(?<f>[^/]+)$")]
      | group_by(.d) | map(select((module_files - map(.f)) == []) | .[0].d)
      | (map(split("/") | length) | min) as $depth
      | map(select(split("/") | length == $depth))
      | if length == 1 then .[0] else null end
    end;

# --- Changed files: diff, renames, empty files and the patch-unavailable list.

# Files from the files list, the head and merge base trees as path -> entry maps, and the
# prefix. Paths are module-root-relative. A path outside the prefix gives null.
def rel($prefix):
  if $prefix == "" then . elif startswith($prefix + "/") then .[($prefix | length) + 1:] else null end;

def tree_map: reduce .tree[] as $e ({}; .[$e.path] = $e);

def entry_id: if . == null then null else "\(.mode) \(.type) \(.sha)" end;

def classify($head; $base; $prefix):
  map(
    . as $f
    | {status, filename, previous_filename, additions, deletions, patch,
       path: (.filename | rel($prefix)),
       old: (if .previous_filename then (.previous_filename | rel($prefix)) else null end)}
    | if .patch != null then .class = "diff"
      elif .additions == 0 and .deletions == 0 and .status == "renamed" and .previous_filename != null
           and ($base[.previous_filename] | entry_id) != null
           and ($base[.previous_filename] | entry_id) == ($head[.filename] | entry_id)
        then .class = "pure-rename"
      elif .additions == 0 and .deletions == 0 and .status != "renamed"
           and ((if .status == "removed" then $base[.filename] else $head[.filename] end) as $e
                | $e != null and $e.type == "blob" and $e.size == 0)
        then .class = "empty"
      else .class = "unavailable" end);

# --- Discussion: the review decision, from the reviews list.

# Reviews in list order, the resolved login, and whether the run is render-only.
def decision($login; $render_only):
  [.[] | select(.state != "COMMENTED" and .state != "PENDING")] as $nc
  | ($nc | map(select(.user.login == $login)) | last
     | if . == null then null else {state, commit_id} end) as $own
  | [$nc[] | select($render_only or .user.login != $login)]
  | group_by(.user.id) | map(last.state) as $latest
  | {review_decision: (if any($latest[]; . == "CHANGES_REQUESTED") then "fail"
                       elif any($latest[]; . == "APPROVED") then "pass" else "none" end),
     own_review: $own};

# --- Origin: numeric ids, never logins; ghost and non-User authors never match.

def author_id:
  if (.typename // "User") == "User" and (.id | type) == "number" and .login != "ghost" then .id else null end;

def origin($pr_author):
  ($pr_author | author_id) as $a
  | (author_id) as $c
  | if $a != null and $c != null and $a == $c then "change-author" else "other" end;

# --- Conversation comments: filter, select, bots.

def norm_bot_login: ascii_downcase | sub("\\[bot\\]$"; "");

# Comments as {typename, login, id, association, created, updated, minimized, body}, the
# path ("graphql" or "rest"), the pull request author, the resolved login.
def conversation($path; $pr_author; $login):
  map(.body |= crlf | .bytes = (.body | utf8bytelength)) as $all
  | ($all | map(select(.typename == "Bot"))) as $bots
  | ($all | map(select(.typename != "Bot"))) as $people
  # People: minimized out on GraphQL; classes; oldest first; walk once.
  | [$people[] | select($path == "graphql" and .minimized)] as $min
  | [$people[] | select(($path == "graphql" and .minimized) | not)
     | .class = (if .association | IN("OWNER", "MEMBER", "COLLABORATOR") then 0
                 elif origin($pr_author) == "change-author" then 1 else 2 end)]
  | sort_by(.class, .created)
  | reduce .[] as $c ({sel: [], bytes: 0, counts: {}};
      if (.sel | length) >= 10 then .counts["over-quota"] += 1
      elif $c.bytes > 4000 then .counts["over-size"] += 1
      elif .bytes + $c.bytes > 8000 then .counts["over-budget"] += 1
      else .sel += [$c] | .bytes += $c.bytes end)
  | . as $p
  # Bots: excluded logins, minimized, newest first by updated, walk once.
  | (["dependabot", "renovate", (($login // "") | norm_bot_login)] | map(select(. != ""))) as $excluded
  | [$bots[] | select((.login // "" | norm_bot_login) | IN($excluded[]) | not)] as $kept
  | [$kept[] | select($path == "graphql" and .minimized)] as $bmin
  | [$kept[] | select(($path == "graphql" and .minimized) | not)]
  | sort_by(.updated) | reverse
  | reduce .[] as $c ({sel: [], bytes: 0, counts: {}};
      if (.sel | length) >= 5 then .counts["bot-over-quota"] += 1
      elif $c.bytes > 6000 then .counts["bot-over-size"] += 1
      elif .bytes + $c.bytes > 12000 then .counts["bot-over-budget"] += 1
      else .sel += [$c] | .bytes += $c.bytes end)
  | . as $b
  | {items: ([$p.sel[] | {kind: "conversation", origin: origin($pr_author), text: .body}]
            + [$b.sel[] | {kind: "bot", origin: "other", text: .body}]),
     considered: ($p.sel | length), bot_considered: ($b.sel | length),
     counts: ($p.counts + $b.counts
              + (if ($min | length) > 0 then {"minimized-excluded": ($min | length)} else {} end)
              + (if ($bmin | length) > 0 then {"bot-minimized-excluded": ($bmin | length)} else {} end)),
     notes: (if $path == "rest" then ["minimized-status-not-checked"] else [] end)};

# --- Related issues.

def keywords: ["close", "closes", "closed", "fix", "fixes", "fixed", "resolve", "resolves", "resolved"];

def strip_token: sub("^[<(\"']+"; "") | sub("[.,;:)>\"']+$"; "");

# A token -> {repo, number} or null, the base repository given.
def ref($base):
  if test("^#[1-9][0-9]*$") then {repo: $base, number: (.[1:] | tonumber)}
  else (capture("^(?!\\.\\.?[/#])(?<o>[A-Za-z0-9._-]+)/(?!\\.\\.?[/#])(?<r>[A-Za-z0-9._-]+)#(?<n>[1-9][0-9]*)$")
        // null)
       | if . == null then null else {repo: "\(.o)/\(.r)", number: (.n | tonumber)} end
  end;

def key: "\(.repo | ascii_downcase)#\(.number)";

# The body -> candidate refs in order, and the refs a closing keyword precedes.
def body_refs($base; $self):
  (crlf | [splits("\\s+")] | map(select(. != "") | strip_token)) as $t
  | [range(0; $t | length) as $i
     | ($t[$i] | ref($base)) as $r | select($r != null)
     | select(($r | key) != ({repo: $base, number: $self} | key))
     | {ref: $r, linked: ($i > 0 and ($t[$i - 1] | ascii_downcase | IN(keywords[])))}];

def dedupe: reduce .[] as $r ([]; if any(.[]; key == ($r | key)) then . else . + [$r] end);

def show($base): if (.repo | ascii_downcase) == ($base | ascii_downcase) then "#\(.number)" else "\(.repo)#\(.number)" end;

# Timeline events -> candidate refs, the pull request author and the base repository.
def timeline_refs($pr_author; $base):
  [.[] | select(.event == "cross-referenced" and .source.issue != null
                and (.source.issue | has("pull_request") | not))
   | .source.issue
   | select(
       ({typename: "User", id: .user.id, login: .user.login} | origin($pr_author)) == "change-author"
       or ((.author_association | IN("OWNER", "MEMBER", "COLLABORATOR"))
           and ((.repository.full_name // "") | ascii_downcase) == ($base | ascii_downcase)))
   | {repo: .repository.full_name, number}];

# --- The untrusted block.

def bytecut($n):
  reduce explode[] as $c ({o: [], b: 0, stop: false};
    if .stop then . else ([$c] | implode | utf8bytelength) as $l
      | if .b + $l <= $n then .o += [$c] | .b += $l else .stop = true end end)
  | .o | implode;

def linecut($n):
  split("\n") as $ls
  | reduce range(0; $ls | length) as $i ({k: null, b: 0, stop: false};
      if .stop then . else (.b + ($ls[$i] | utf8bytelength) + (if $i > 0 then 1 else 0 end)) as $nb
        | if $nb <= $n then .k = ($ls[0:$i + 1] | join("\n")) | .b = $nb else .stop = true end end)
  | .k;

def cut($n):
  if utf8bytelength <= $n then . elif $n <= 0 then "" else (linecut($n) // bytecut($n)) end;

# Items [{kind, origin, text}] in block order -> items with text cut and omitted bytes, under
# the per-item 4000 and the total 16000 for title, body and thread items.
def capped:
  reduce .[] as $i ({out: [], left: 16000};
    ($i.text | crlf) as $t
    | if $i.kind | IN("title", "body", "thread") then
        ([4000, .left] | min) as $lim
        | ($t | cut($lim)) as $k
        | .out += [$i + {text: $k, omitted: (($t | utf8bytelength) - ($k | utf8bytelength))}]
        | .left -= ($k | utf8bytelength)
      else .out += [$i + {text: $t, omitted: 0}] end)
  | .out;

def block($s; $record):
  "UNTRUSTED-\($s) BEGIN\n"
  + ([.[] | "ITEM-\($s) kind=\(.kind) origin=\(.origin)\n"
           + (if .text == "" then "" else .text + (if .text | endswith("\n") then "" else "\n" end) end)
           + (if .omitted > 0 then "[truncated-\($s): \(.omitted) bytes omitted]\n" else "" end)] | join(""))
  + (if $record == null then "" else "RECORD-\($s)\n" + $record + (if $record | endswith("\n") then "" else "\n" end) end)
  + "UNTRUSTED-\($s) END\n";

# --- host.json grammar.

def nat: type == "number" and . >= 0 and . == floor;
def plain_path: type == "string" and length > 0 and length <= 1024 and (test("[\\x00-\\x1f\\x7f`]") | not);
def ref_text: type == "string" and test("^(#[1-9][0-9]*|[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[1-9][0-9]*)$");
def sha: type == "string" and test("^[0-9a-f]{40}$");

def omission_keys: ["over-size", "over-budget", "over-quota", "minimized-excluded", "bot-over-size",
  "bot-over-budget", "bot-over-quota", "bot-minimized-excluded"];

def valid_host($head):
  type == "object"
  and keys == (["format", "repo", "number", "head_sha", "base_sha", "merge_base", "prefix", "state",
                "signals", "own_review", "could_not_run", "unresolved_threads", "conversation",
                "related"] | sort)
  and .format == 1
  and (.repo | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$"))
  and (.number | nat and . > 0)
  and (.head_sha | sha) and .head_sha == $head and (.base_sha | sha)
  and (.merge_base == null or (.merge_base | sha))
  and (.prefix == "" or (.prefix | plain_path))
  and (.state | type == "object" and keys == ["base_is_default", "draft", "merged", "self_authored", "state"]
       and (.state | IN("open", "closed")) and (.merged | type == "boolean") and (.draft | type == "boolean")
       and (.base_is_default | type == "boolean") and (.self_authored | type == "boolean"))
  and (.signals | type == "object" and keys == ["mergeability", "review_decision", "threads"]
       and (.threads | IN("pass", "unknown"))
       and (.review_decision | IN("pass", "fail", "unknown", "none"))
       and (.mergeability | IN("pass", "fail", "unknown")))
  and (.own_review == null or (.own_review | type == "object" and keys == ["commit_id", "state"]
       and (.state | IN("APPROVED", "CHANGES_REQUESTED", "DISMISSED")) and (.commit_id | sha)))
  and (.could_not_run | type == "array" and all(.[]; type == "object" and (
        (keys == ["kind", "path"] and .kind == "patch-unavailable" and (.path | plain_path))
        or (keys == ["kind"] and (.kind | IN("thread-resolution-unknown", "prose-truncated")))
        or (keys == ["count", "kind"] and .kind == "threads-over-count" and (.count | nat and . > 0)))))
  and (.unresolved_threads | type == "array" and all(.[]; type == "object" and keys == ["line", "path"]
        and (.path | plain_path) and (.line == null or (.line | nat and . > 0))))
  and (.conversation | type == "object" and keys == ["bot_considered", "considered", "counts", "notes", "omitted", "path"]
       and (.path | IN("graphql", "rest"))
       and (.omitted == null or (.omitted | IN("fetch-failed", "fetch-budget-exhausted", "fetch-size-exhausted")))
       and (.considered | nat) and (.bot_considered | nat)
       and (.counts | type == "object" and all(to_entries[]; (.key | IN(omission_keys[])) and (.value | nat and . > 0)))
       and (.notes == [] or .notes == ["minimized-status-not-checked"]))
  and (.related | type == "object" and keys == ["open_unlinked", "sidebar_not_read", "status"]
       and (.status | IN("ok", "not-applicable", "too-many", "failed"))
       and (.sidebar_not_read | type == "boolean")
       and (.open_unlinked | type == "array" and all(.[]; ref_text))
       and (.status == "ok" or .open_unlinked == []));
