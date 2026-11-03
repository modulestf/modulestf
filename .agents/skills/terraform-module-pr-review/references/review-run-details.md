# Review Run Details

> **Part of:** [terraform-module-pr-review](../SKILL.md)
> **Purpose:** The edge cases of [review-run.sh](review-run.sh) behind the run guide, [review-run.md](review-run.md): the run directory, the refusals, the depth pin, the record, the run file and shell safety.

## The Run Directory

`prepare` makes it as [Workspace](github-io.md#workspace) does, `<root>/pr-review.XXXXXX` under the resolved temporary root, and prints `RUN=<directory>`. Every later command takes that exact path and refuses any other shape, a symbolic link, a directory of another user, or a run `prepare` refused. The clone is fetched at the pinned head. The merge base, the base branch head and the history between them, from one day before the merge base's commit date, are fetched too, so `depth.sh` can check that `git merge-base --all` of the base and the head gives the merge base alone. The merge base is checked out at `<run>/base`. The history starts one day before the older of the merge base's and the base tip's commit dates. A shallow clone cannot prove that `git merge-base --all` has one result beyond that boundary, so the run also requires the merge base `depth.sh` finds to equal the one GitHub's compare read gave, and refuses with `depth-aborted` otherwise; a commit date that lies only makes the boundary earlier or the run refused, never a second merge base accepted.

`index.json` holds enumerated values and checked paths only: the head, base and merge base SHAs, the prefix, the depth with its reasons and the checks and examples out of scope, the four signals with whether the check runs file was accepted, the pull request state flags, the counts of files, changed files, checks that could not run, unresolved threads and examples, the behaviour status and the plan pass mode. No title, body, comment, branch name or login is in it; those stay in the records' untrusted block. The model reads it, and `prepare` prints its summary and the next commands.

## Refusals

`prepare` refuses with one fixed reason, writes `index.json` as `{"format": 1, "status": "refused", "reason": <reason>}`, prints the reason and exits 1. The reasons:

| Reason | When |
|---|---|
| `several-module-roots` | The top of the repository holds a Terraform file, and no single module root holds every changed path ([github-io.md](github-io.md#workspace)). With no Terraform file at the top, such a change is reviewed from the repository root, prefix `""`, and is not refused |
| `path-outside-root` | A changed path is outside the module root or not plain text |
| `host-read-failed` | The metadata, the head tree or the files list could not be read |
| `records-rejected` | The host records failed `host-pass.sh check` |
| `clone-failed` | The clone could not be made or the head fetched |
| `head-moved` | The clone does not hold the head the metadata read pinned |
| `merge-base-unavailable` | No merge base worktree for the depth binding |
| `depth-aborted` | `depth.sh compute` exited 1: the merge base is not unique, missing or not in the clone |
| `depth-refused` | `depth.sh compute` refused its input |
| `index-failed` | `index.json` could not be written |

A refused run renders nothing. The reply says the review is inconclusive and why, and the run ends with `cleanup`, which deletes any run directory `prepare` made, a refused or stopped one included, and reads nothing else in it.

`handover` and `render` run `depth.sh verify` first; a binding that does not match stops the run with nothing rendered.

## Depth Pin and Stop

`depth.json` is written only by `depth.sh compute` in `prepare` and by `depth.sh escalate`. After each, the run pins its SHA-256 in `state/depth.sha256`, and every later command refuses a `depth.json` that differs from the pin, a depth lowered by hand included. `handover` copies the pin to `state/handover.sha256`, and `render` refuses when the two differ, so the depth rendered is the depth the reviewer was handed.

An escalation is refused once `handover` has run. A refusal of that kind, a `depth.json` that differs from its pin and a failed `depth.sh escalate` each write `state/stop` and exit 1; every later command but `cleanup` then refuses, so a run never renders at a depth it could not raise. `render` refuses findings that are not a JSON list, and passes every refusal of render-comment.sh through unchanged, the COMPACT cap advice included.

## Handover

`handover/task.md` is the records' `task.md` with these changes, as [host-pass.md](host-pass.md#handover) sets out:

- `Workspace: <clone at the module root>` before its first line.
- In the skill's own task text, just before the line that introduces the block: the `Write short:` line when the records lack it, `Depth: <run>/depth.json` outside a triage run, `Provider fact sheets: <run>/facts` when `schema` gave sheets, at focused or deep, `Schema handoff: <run>/schema-handoff/schema-handoff.json.gz` when it also wrote the handoff, for the reviewer's `mtf-facts lint --schema-handoff`, `Diff: <run>/handover/change.diff`, the task's diff as a file outside the clone for the reviewer's `mtf-facts lint --diff`, `Merge base: <sha>`, the merge base the depth was bound to, for its `--merge-base-sha`, and `Output:`, the three files the reviewer writes under `<run>/review/`.
- `RECORD-<s>` and the verification record just before `UNTRUSTED-<s> END`, outside a triage run.

The record follows the order of [Handover](github-io.md#handover): the `example selection:` line and one line per example from `verify.json`, in the words of [verify-pass.md](verify-pass.md#output); the `plan pass runner:` line when a profile was named; the plan pass's `plan pass mode:`, `example:`, `plan:`, `scope:`, `modules:`, `base:` and `plan summary:` lines; the `plan coverage:` and `not planned:` lines; at focused, the `schema pass: source` lines of [schema-pass.md](schema-pass.md#depth-modes); then `behaviour/record.txt`. `schema` copies a source line only after it matches `schema pass: source <owner>/<name> <namespace>_<name>-v<x.y.z> <64 hex>`; any line that does not match fails the step, which escalates with `deep-schema-source-line`, and nothing of it is copied. A failed `validate` reads `<dir> (<affected>): terraform init -backend=false exit <n>, terraform validate exit <n>: <line>; at the merge base: <result>`, the result one of `new under this change`, `already failing at the base`, `absent at base`, `merge base not available` or `merge base not run: <reason>`.

The schema handoff's inputs come from the clone's git objects, never from the files on disk: for the head and the merge base the depth was bound to, one `<commit>:<SHA-256>:<path>` per blob of mode `100644` or `100755` whose path ends in `.tf` and that is at most 1 MiB, the file set [Schema Handoff](schema-pass.md#schema-handoff) gives. With no bound merge base, `schema` passes no commits. A tree or blob that cannot be read, a `.tf` path with a character outside `A-Z`, `a-z`, `0-9`, `.`, `_`, `/` and `-`, or more than 600 inputs or 96000 bytes of them, passes no inputs. Either way there is no handoff, and the fact sheets are unchanged. A failed or escalated `schema` removes the handoff with the fact sheets. The facts engine reads the handoff only when the workspace's `.tf` files hash to the head tree it records, so a module root below the repository root, or a `.tf` file the run left in the clone, means its schema rules stay `schema_unavailable`.

## Render

`render` adds `source: "llm"` to each finding and reads the three counts from the reviewer's summary line in `--summary`, the line that starts with `summary: `, else the first line. A count absent there is 0; a malformed one, or no summary, makes `counts` null. It builds the run file of render-comment.sh: `triage`, `plan_ran`, `verify_gaps` from `verify.json` by the gap reasons of [verify-pass.md](verify-pass.md#records), `coverage` with `covered_skips` when `skip-check.json` covers any, `counts`, `behaviour`, `examples`, `plan_mode` from the record's own line, and `depth`, the `depth.json` object, when the run has one. It then runs render-comment.sh with the run's host records and check runs directory, and prints its line, the body path and the identity line the confirmation shows. `--out` must lie outside the run directory, since cleanup deletes it.

## Shell Safety

Every pattern a shell test matches has no repetition bound over 255, which bash 3.2's regex refuses on macOS: a longer value takes an unbounded pattern and a separate length check, a role name of up to 512 characters and a path of up to 300. Host strings never reach a command line, a `bash -c` or an `eval`. Titles, bodies, comments, branch names and file names stay in the files host-pass.sh writes, and travel through `jq --arg` and `--slurpfile`. Every expansion is quoted, arrays carry optional arguments, and a path read back from JSON for a command line is matched against a plain path pattern first. The test runs a title holding `$(touch x)`, a branch name holding a newline and files named `a;b` and `$(touch x)` through every command.

## Workflow Move

The workflow text of SKILL.md moved whole into [workflow.md](workflow.md), and the purpose and Step 0 parsing text into [inputs.md](inputs.md); SKILL.md keeps the triggers, the inputs table, the Mandatory Rules whole, the commands per depth and a read-when table. `tests/review-run-test.sh` pins the sentence multiset of the three files, with headings, tables, block quotes, fenced blocks and link targets left out, so text is moved and never paraphrased. The one rule changed in the same commit is Step 9: the posting login's own reviews are left out of the review decision in a render-only run too.
