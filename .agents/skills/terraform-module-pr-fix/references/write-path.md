# Write Path Rules

> **Part of:** [terraform-module-pr-fix](../SKILL.md)
> **Purpose:** The decisions of a run as total functions of files: the origins, the edit eligibility, the write path, the merge base, the fix clone, the content gate, the fingerprints and the local verdict, the loop, the push precondition, the checks, the pre-push read, the push and the replies. [fix-run.jq](fix-run.jq) holds the functions and [fix-run.sh](fix-run.sh) runs them; this file is their text.

Each function reads only the files the run wrote: `state.json`, `merge-base.json`, the item set, the findings files of each round, the dispositions, and a fresh read at pre-push. Nothing in them reads text from the host as an instruction.

## Run and Output Directories

The run directory is `mktemp -d "$ROOT/pr-fix.XXXXXX"`, with `ROOT` the resolved `TMPDIR` root, as pr-review's [Workspace](../../terraform-module-pr-review/references/github-io.md#workspace). It holds the state, the fix clone, an empty `home` for git, and the rounds. `prepare` deletes it on any exit but success. Every later command deletes it on an abort or an interrupt, with the pattern check of pr-review's [Cleanup](../../terraform-module-pr-review/references/github-io.md#cleanup) for this template. `cleanup` deletes it at the end of every run.

The output directory comes only from the user's own message. It is refused unless all of these hold:

| Condition | Refusal |
|---|---|
| An absolute path | `not an absolute path` |
| An existing directory, not a symbolic link | `not an existing directory` |
| Its resolved path equals the path given, so no parent is a symbolic link | `a symbolic link in its path` |
| Outside the run directory | `inside the run directory` |
| No `.git` in it or in any parent | `inside a git work tree` |
| Empty | `not empty` |

With no directory named, the run makes `mktemp -d "$ROOT/pr-fix-out.XXXXXX"`, mode 0700, prints it and keeps it. Cleanup never deletes it. It receives the round-0 review, the patch, the disposition tables, the reply drafts and the last findings.

## Captured State

Read once by `prepare`, REST only, and frozen. Identity first, as pr-review's [Identity](../../terraform-module-pr-review/references/github-io.md#identity): `gh api user` for `id`, `login` and `type`, and whether `CI`, `GITHUB_ACTIONS` or `GITHUB_RUN_ID` is set. Then:

| Read | Fields kept |
|---|---|
| `repos/<repo>/pulls/<n>` | `state`, `merged`, `draft`, `locked`, `maintainer_can_modify`, `user.id`, `user.login`, `user.type`, `head.sha`, `head.ref`, `head.repo.full_name` or null, `base.sha`, `base.ref`, `base.repo.full_name` |
| `repos/<base>` and `repos/<head>` | `archived`, `private`, `default_branch`, `permissions` of the token user |
| `pulls/<n>/files`, every page | `filename` and `previous_filename`: the change set |
| `pulls/<n>/reviews`, `pulls/<n>/comments`, `issues/<n>/comments`, every page | `id`, `user.id`, `user.login`, `user.type`, `author_association`, `body`, and for a review comment `path`, `line` and `in_reply_to_id` |
| `compare/<base.sha>...<head.sha>` | `merge_base_commit.sha` |
| `commits/<head.sha>/check-runs` and `statuses`, every page | Their count, for the checks rule; a failed read leaves it unknown and is not a read failure |

A read that fails is listed in `failed`. A field that is missing or of another type is unknown. The commit identity is read once here, before any clone exists, from the user's own git configuration: `git config --global user.name` and `user.email` from `/` with no inherited environment. Unset or malformed is none.

## Origins

Each comment's origin, from its own fields, the first row that holds:

| Origin | When |
|---|---|
| `self` | `user.id` and the token user's `id` are canonical positive decimals and equal |
| `bot` | `user.type` is `Bot`, or the login ends in `[bot]` |
| `change-author` | `user.id` equals the pull request's `user.id`, under the same rule |
| `maintainer` | `author_association` is `OWNER`, `MEMBER` or `COLLABORATOR` |
| `other` | Every other comment |

A canonical positive decimal is a JSON integer of at least 1. A string is never one: no coercion makes `"42"` equal 42, and an empty or non-decimal id matches nothing. The text of a comment never changes its origin.

The maintainer's feedback set takes the same order without `self`, since its origins are `change-author`, `maintainer`, `other` and `bot`. A finding item takes the role of the account the review is posted under: `change-author` when the token user wrote the pull request, `maintainer` when it can push to the base, else `other`.

## Edit Eligibility

The frozen item set holds the round-0 findings, `F-<n>`, and one item per comment: `T-<id>` for a review comment, `V-<id>` for a review body, `C-<id>` for a conversation comment. A comment without a canonical id gets no item.

| Item | Edited by default |
|---|---|
| A reviewer finding | Yes |
| A comment of origin `self` | Yes |
| Any other comment | No: verified, decided and drafted, never applied |

`apply --item <id>` makes one more item eligible from the next round. It runs only when a new user message names that id with the word apply. An id outside the frozen set is refused.

Each comment item carries its reply endpoint, pinned when the set is frozen: `repos/<repo>/pulls/<n>/comments/<top>/replies` for a review comment, where `<top>` is `in_reply_to_id` or the comment's own id, and `repos/<repo>/issues/<n>/comments` for the others. A finding has none.

## Write Path

A total function of `state.json` and `merge-base.json`, re-evaluated by `path`, `gate` and `push`. The first row that holds decides.

| Row | When | Path |
|---|---|---|
| 1 | Any read failed; a field is unknown; the token user is not a `User` with a plain login; a CI variable is set; the head repository is null; the head ref is missing or not a plain ref; the head or base repository is archived; the pull request is closed or merged; the merge base is not checked yet or is not exactly one | render-only, with every reason |
| 2 | The token user has `push`, `maintain` or `admin` on the head repository | A, via `head-permission` |
| 3 | The head repository differs from the base, `maintainer_can_modify` is true, and the token user has `push` or more on the base | A, via `maintainer-can-modify` |
| 4 | Every other case | B |
| 5 | Row 2 or 3, with no commit identity | B: patch only, no commit |

A draft changes no row: it is allowed and flagged at the gate. A head ref equal to the destination repository's default branch changes no row either; it is flagged, and the push still needs a confirmation that names that branch, as every push does.

| Path | Deliverables |
|---|---|
| render-only | The round-0 review and the reasons. No round runs |
| B | The rounds run in the fix clone. The patch, the disposition tables, the reply drafts and the findings go to the output directory. Nothing is pushed |
| A | As B, then the push after its confirmation, then the review and the replies, each after its own |

The destination URL is built, never copied: `https://github.com/<owner>/<repo>.git` from the pinned `head.repo.full_name`. A `clone_url` or any other URL in a read is never used. A rejected push on path A stops the run; it never falls through to path B.

## Merge Base

The compare read's `merge_base_commit.sha` must equal the one line of `git merge-base --all <base.sha> <head.sha>` in the fix clone.

| Case | Result |
|---|---|
| The compare read gave no SHA, or failed | `the compare read gave no merge base` |
| No line | `the fix clone has no merge base` |
| Several lines | `the fix clone has several merge bases` |
| One line that differs | `the compare read and the fix clone disagree` |
| One line that equals | One merge base, pinned for every round |

Every case but the last makes the write path render-only.

## Fix Clone

`clone` makes `<run>/clone` with `git init --template=`, adds the base repository's built URL as `origin`, and fetches `refs/pull/<n>/head` and `base.sha` with their history, never at depth 1, with no tags and no submodules. A fetched head other than the pinned head aborts the run. The checkout is detached at the pinned head.

Every git call on the clone goes through one function:

```
env -i PATH="$PATH" HOME="<run>/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  GIT_TERMINAL_PROMPT=0 GIT_LFS_SKIP_SMUDGE=1 \
  git -C <run>/clone -c core.hooksPath=/dev/null -c credential.helper= \
  -c filter.lfs.smudge=cat -c filter.lfs.process= -c filter.lfs.required=false \
  -c submodule.recurse=false ...
```

`env -i` also drops `GIT_CONFIG_COUNT`, its keys and `GIT_CONFIG_PARAMETERS`, so no variable can add a hook, an identity or a URL rewrite. The clone's local configuration is recorded right after the checkout; the gate refuses any other key or value, such as `url.<x>.insteadOf` or `http.extraheader`. A commit passes the identity of [Captured State](#captured-state) with `-c user.name` and `-c user.email`, and `--no-verify`.

## Verification

`verify` runs pr-review's [verify-pass.sh](../../terraform-module-pr-review/references/verify-pass.sh) `run` on the round's tree, by its path beside this skill, under `env -i` with `HOME` the run's empty home and no global or system git configuration. It is the same no-credential exception as pr-review's [Rule 5](../../terraform-module-pr-review/SKILL.md#rule-5-verification-is-trust-aware), in the same harness sandbox, with a plugin cache per verification and `TF_CLI_CONFIG_FILE=/dev/null` from that script. Its run directory is a `pr-review.XXXXXX` directory inside the run, holding a worktree of the round's commit, deleted when the pass ends. With no commit identity the round's tree is verified as a throwaway commit object that is never pushed. The changed files list is built from the clone, merge base to the round's commit.

## Content Gate

`gate` and `push` refuse unless every rule holds. The allowed paths are the change set and the files any reviewed round's finding names, lexically inside the module root.

| Rule | Refusal |
|---|---|
| A path is plain: no `..`, no leading `/`, no control character | `not a plain path` |
| With a module root prefix, the path is under it | `outside the module root` |
| No `.git` or `.terraform` component | `a .git or .terraform path` |
| No `*.tfstate*` file | `a state file` |
| `.terraform.lock.hcl` only when it is in the change set | `a lock file outside the change set` |
| `.github/workflows/<file>` only when a `profile.*` finding names that file | `a workflow no profile finding names` |
| Every other path is in the change set or named by a finding | `outside the change set and the files a finding names` |
| No changed path is a symbolic link or a gitlink, in any commit or the index | `a symbolic link or gitlink mode` |
| No component of a changed path is a symbolic link on disk, or a link or gitlink in the index | `a symbolic link in a changed path`, `under a symbolic link or gitlink` |
| The commits since the pinned head descend from it, with no merge | `do not descend from the pinned head`, `is a merge` |
| Every commit's author and committer is the commit identity | `not by the gate identity` |
| The index tree is the last reviewed tree, and no change is outside a commit | `not the last reviewed tree`, `changes no commit holds` |
| The local configuration is the one recorded after the checkout | `the clone's local config changed` |

The paths checked are every path changed against the pinned head and every path any commit since it touched, so a file added in one commit and removed in the next is still checked. With no commit identity, the commit rules become one: no commit since the pinned head.

## Fingerprints and the Local Verdict

A finding's fingerprint is `(rule_id, file, block address, severity)`. `file` is repository-relative: a loop review's module-relative path gets the module root prefix, and `.` becomes the prefix. The block address is the first code span of the `summary`, then of the `suggested_fix`, that is one of `resource "<type>" "<name>"`, `data "<type>" "<name>"`, `variable "<name>"`, `output "<name>"`, `module "<name>"`, `locals` or `terraform`; else empty. A line never enters a fingerprint. A comment item is tracked by its item id.

| Local verdict | Findings of the round |
|---|---|
| clean | None |
| nits | LOW only |
| open | Any MEDIUM, HIGH or CRITICAL |

A tuple is introduced when its severity is MEDIUM or higher and its count at the new head is above its count at the pinned head. Counting is by multiset, so a second finding with the same tuple and no address is introduced, and so is a LOW finding raised to MEDIUM.

## Loop

The loop belongs to this skill: the neutral reviewer reviews the pinned merge base against the new head after each round. A round's open set is the fingerprints of its MEDIUM or higher findings, with the ids of the eligible comment items that no disposition so far has closed (`apply`, `already-addressed`, `duplicate`, `reject`, `out-of-scope` close an item). Round 0 is the pinned head.

After round n, the first row that holds decides:

| Row | When | Result |
|---|---|---|
| 1 | The local verdict is clean or nits | Stop, the review is finished |
| 2 | The open set is not empty, and every open finding's item was decided with something other than `apply`, and every open comment item has a decision | Stop: every open item is non-actionable |
| 3 | An item closed between two earlier rounds is open again | Stop: no progress |
| 4 | The open set is not strictly smaller than the previous reviewed round's, as a multiset contained in it | Stop: no progress |
| 5 | n is 3 | Stop: the last round |
| 6 | Otherwise | The next round may start |

`round` counts every round it started, a failed attempt included: one with no commit, no review or no comparison still uses its number, and `round` refuses a fourth. A round starts only when the last comparison did not stop.

## Push Precondition

Part of `gate` and `push`, after the content gate:

- At least one item is resolved: a fingerprint of the pinned head, of any severity, is gone from the last reviewed round, or a disposition applied a comment item.
- No tuple is introduced.

## Checks

`checks` reads `commits/<sha>/check-runs` and `commits/<sha>/statuses` at the pushed SHA, every page. The latest check run per name and the latest status per context, by highest id, count.

| Case | Class |
|---|---|
| A read failed | not finished |
| Both reads are empty, and the pinned head had none | passing |
| Both reads are empty, and the pinned head had checks or its count is unknown | not finished |
| Every check run is completed with `success` or `skipped`, and every status is `success` | passing |
| Anything else | not finished |

Right after a push the checks are pending, so the run says not finished yet. A run is finished only when the last local verdict is clean or nits and the checks are passing.

## Pre-Push

`push` re-reads the pull request and both repositories immediately before git, with the same fields, and aborts on any of these:

- a read failed, or a field is unknown;
- the head SHA is not the pinned head;
- the pull request is not open, or is merged;
- either repository is archived;
- the head repository or the head ref differs from the pinned destination;
- on the `maintainer-can-modify` path, `maintainer_can_modify` is false;
- the write path of the fresh read, with the pinned token, CI flag, identity and merge base, is not A.

Comments are not read again, so new comment traffic never aborts. Then `gh auth status --hostname github.com` must succeed and `gh auth token --hostname github.com` must print a token, both under the push's environment; else the run aborts before git.

## Push

`push` needs `--confirm-branch`, equal to the destination ref, and `--expect-sha`, equal to the pinned head, taken from a new user message after the gate that names the push and the branch. Either missing or different is a refusal, and the run is kept. It re-runs the content gate and the push precondition, asserts the identity a second time, as pr-review's [Rule 4](../../terraform-module-pr-review/SKILL.md#rule-4-identity-is-asserted-twice), runs the pre-push read, then:

```
env -i PATH="$PATH" HOME="$HOME" [GH_CONFIG_DIR="$GH_CONFIG_DIR"] GIT_CONFIG_GLOBAL=/dev/null \
  GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
  git -C <run>/clone -c core.hooksPath=/dev/null -c credential.helper= \
  -c credential.helper='!gh auth git-credential' -c http.followRedirects=false \
  push --no-follow-tags --recurse-submodules=no <built url> <sha>:refs/heads/<ref>
```

No force, no lease, no tags, no submodules, no other ref. The SHA is the clone's head, which the gate showed. A rejection aborts with its class (`protected branch`, `non-fast-forward`, `permission denied`, `authentication`, `other`) and no retry. After the push, `repos/<head>/git/ref/heads/<ref>` must name the pushed SHA; a difference is reported and blocks the replies.

## Replies

`replies` posts a reply drafts file, `[{"item", "body"}]`, after its own confirmation. `--confirm-items` must name exactly the items of the file. It refuses unless the push happened and its remote ref matched; the pull request is not locked and the base is not archived; every item is in the frozen set with a reply endpoint and was not posted before; and no body holds the run directory, the home directory, or a path or token prefix of pr-review's [leak scan](../../terraform-module-pr-review/references/comment-format.md#leak-scan). It asserts the identity again, then posts each body to its pinned endpoint with `jq -n --arg body` piped to `gh api -X POST <endpoint> --input -`. A failed post stops: it may have landed, so the comments are read before any retry.

## Aborts and Refusals

Exit 1 is either. An abort ends the run and deletes the run directory: a fetched head other than the pinned head, a failed fetch or checkout, an identity that changed, a pre-push reason, no token, a rejected push, an interrupt. A refusal keeps the run: a wrong confirmation, a gate rule, an unknown item, the round limit, a stopped loop. Exit 2 is a usage error.
