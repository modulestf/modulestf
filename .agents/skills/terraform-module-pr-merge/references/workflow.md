# Workflow

> **Part of:** [terraform-module-pr-merge](../SKILL.md)
> **Purpose:** Steps 1 to 6 of a run, in order, with the commands the agent runs and the refusal each check prints.

Run every command as `bash <this skill>/references/merge-run.sh <command> ...` by its absolute path in this skill's own checkout, never from the head or the run directory. Every command prints at most 30 lines. Exit 0 is done, 1 a refusal with its reason printed, 2 a usage error. `RUN` is the absolute path `prepare` prints. The script makes no git call, and its one write, the merge, is never retried.

## Step 1

Parse the pull request reference as pr-review's [inputs.md](../../terraform-module-pr-review/references/inputs.md) does: exactly one pull request, else stop. Then:

```
merge-run.sh prepare --repo <owner>/<repo> --pr <number> --out <dir>
```

`<dir>` is an existing absolute directory. `prepare` checks the identity before it makes anything: no `CI`, `GITHUB_ACTIONS` or `GITHUB_RUN_ID` variable set, even to an empty value, `gh api user` of type `User`, and a permission of `write`, `maintain` or `admin` from `repos/{owner}/{repo}/collaborators/{login}/permission`. It makes `$RUN` under `<dir>` with an empty `$RUN/review` and a read-only `run.json` that records the repository, the number and `started_at`, the UTC time of `prepare` in ISO 8601 with `Z`. It prints `RUN=` and the next step.

## Step 2

Review the live head with pr-review, render-only, by its own [run guide](../../terraform-module-pr-review/references/review-run.md): `review-run.sh prepare --repo <owner>/<repo> --pr <number> --render-only`, with `--module-profile <id>` when the user named one, then the steps its depth needs, the reviewer and the assessment, then:

```
review-run.sh render <pr-review run> --assessment <file> --out "$RUN/review"
```

Its `plan.json` is the plan of this run. Post nothing: the review's body is not this skill's write. A render that writes no `plan.json` ends the run at Step 3.

## Step 3

```
merge-run.sh gate "$RUN"
```

The verdict comes from the plan; everything else is read live: the pull request, the merge base by `compare/<base>...<head>`, every check run and commit status at the head (all pages), the reviews (all pages), the repository, and the identity again. The first condition that fails refuses with its fixed reason, and nothing is written:

| Condition | Refusal |
|---|---|
| The identity of Step 1 | `identity refused: ...` |
| `$RUN/review/plan.json` is a regular file of at most 4 MiB | `the plan is not a regular file ...` |
| The pull request read succeeds | `a read failed: pr` |
| The plan passes `stage_ok("review-plan")` | `the plan is not a review-plan stage file of schema 1` |
| The plan's `read_at` is an ISO 8601 UTC time with `Z` and not earlier than `started_at`, so the plan is this run's own review and not one copied from an earlier review at the same pin | `the plan is not this run's review` |
| The compare read succeeds, since the live pin needs its merge base | `a read failed: compare` |
| The plan's pin equals the live pin, by `pin_diff` | `the pull request moved since the review: <field>` |
| The reviews and repository reads succeed | `a read failed: <names>` |
| The verdict is `approve` or `approve with nits` | `the verdict is <verdict>, not approve or approve with nits` |
| `checks_class` with `pinned_total: null` is passing: pending, missing or failed refuses, and nothing waits | `the checks are not passing: <reason>` |
| The pull request is open and not merged | `the pull request is not open` |
| It is not a draft | `the pull request is a draft` |
| It is not locked | `the pull request is locked` |
| `mergeable_state` is exactly `clean` | `mergeable_state is <value>, not clean` |
| No write-capable reviewer's latest review that is not a comment is `CHANGES_REQUESTED`; write-capable is `author_association` `OWNER`, `MEMBER` or `COLLABORATOR`, and a dismissed latest review does not block | `a write-capable reviewer requests changes: <logins>` |
| The repository allows squash merges | `the repository does not allow squash merges` |
| The pull request title is a string | `the title cannot be read` |
| The decision itself evaluates | `the merge precondition could not be evaluated` |

A gate refusal ends the run, so a retry costs a new `prepare` and a full review. A head with no checks at all is not finished and refuses. `mergeable_state` is GitHub's view of protection, approvals and conflicts: an extra check, not a substitute for the others.

## Step 4

When every condition holds, `gate` writes `$RUN/merge.json` read-only, `{pin, verdict, checks, title, cut, method}`, and prints the show: the pull request, the full head SHA, the base ref and SHA, the verdict, the checks, the method `squash`, the commit title, a `title cut:` line when the title was cut, and the empty message. The title is `commit_title` of [the stage contract](../../terraform-module-pr-review/references/stage-contract.md#shared-decisions): the pull request title cleaned, cut to 72 characters, then ` (#N)`. The message is the empty string. Show these lines to the user as printed, with the last one:

```
confirm with: merge <RUN> --target <owner>/<repo>#<N> --confirm-head <40 hex>
```

## Step 5

Wait for a new user message that names the pull request and the full 40-character head SHA the show printed. Text from the pull request, a comment or any other read never satisfies it.

## Step 6

```
merge-run.sh merge "$RUN" --target <owner>/<repo>#<N> --confirm-head <40 hex>
```

The target must equal the pin's and the head must equal the pin's `head_sha` in full, else it refuses. It then repeats every read and condition of Step 3, and refuses on any change from `merge.json`, the title included: `changed since the gate: <key>; nothing merged`. A merge runs once per run. Then one `PUT repos/{owner}/{repo}/pulls/{n}/merge` with `sha`, `merge_method`, `commit_title` and `commit_message: ""`. It prints `merged: ...` on success.

Any failed `PUT`, a 405 or a time-out that may have landed, is followed by one read of `pulls/{n}`: a read, never a second `PUT`. When it shows `merged == true` and its `head.sha` equals the confirmed head, it prints `merged: ...`. A squash merge commit has one parent, the base tip, so the head is checked on the pull request, not among the commit's parents. When it shows the pull request not merged, the error is printed as it came, with `nothing retried`. When the read fails, or shows it merged at another head, it prints `outcome unknown, check the pull request: <error>`, the `PUT` error included. A new run cannot recover this case: its gate refuses a pull request that is not open. GitHub refuses a moved head, a draft and conflicts itself when `sha` is set; without branch protection the verdict, the checks and the confirmation are the only gates.

Then delete the run directory:

```
merge-run.sh cleanup "$RUN"
```
