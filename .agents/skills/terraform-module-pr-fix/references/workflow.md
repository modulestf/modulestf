# Workflow

> **Part of:** [terraform-module-pr-fix](../SKILL.md)
> **Purpose:** Steps 0 to 12 of a run, in order, with the commands the agent runs. The decisions each command makes are in [write-path.md](write-path.md).

Run every command as `bash <this skill>/references/fix-run.sh <command> ...` by its absolute path in this skill's own checkout, never from the head or the run directory. Every command prints at most 30 lines; read those, not the files they name. Exit 0 is done, 1 a refusal or an abort with its reason printed, 2 a usage error. `RUN` and `OUT` are the absolute paths `prepare` prints; a new shell sets them again from that output. The loop runs Step 7, then Step 6, then Step 9, once per round.

## Step 0

Parse the pull request reference as pr-review's [inputs.md](../../terraform-module-pr-review/references/inputs.md) does: exactly one pull request, else stop. Take from the user's own message only: an output directory, a module profile id, and nothing else. Then:

```
fix-run.sh prepare --repo <owner>/<repo> --pr <number> [--out <dir>] [--module-profile <id>]
```

It makes the run directory and the output directory under the rules of [Run and Output Directories](write-path.md#run-and-output-directories), and prints `RUN=`, `OUT=`, the identity, the commit identity, the pull request, for a locked one the lock line, the reads that failed and the counts. A refused output directory ends the run with its reason.

## Step 1

`prepare` asserted the identity once and froze the [Captured State](write-path.md#captured-state) in `$RUN/state.json`. Nothing reads the host's comments again in this run. A bot identity or a CI variable makes the run render-only.

## Step 2

The write path is a function of the state and the merge base, so it is final after Step 3. `fix-run.sh path "$RUN"` prints it at any time with its reasons, the destination and the flags.

## Step 3

Review the pinned head with pr-review, render-only, by its own [run guide](../../terraform-module-pr-review/references/review-run.md): `review-run.sh prepare --repo <owner>/<repo> --pr <number> --render-only`, with `--module-profile <id>` when the user named one, then the steps its depth needs, the reviewer and the assessment, then:

```
review-run.sh render <pr-review run> --assessment <file> --out "$OUT/round-0"
```

Read the module root prefix with `jq -r .prefix <pr-review run>/index.json`. Then the fix clone and the merge base check, which freeze the prefix and the merge base for the [Allowed Paths](write-path.md#allowed-paths) rule, and the frozen item set, which also keeps the prose of pr-review's handover for the round reviews:

```
fix-run.sh clone "$RUN" --prefix <prefix>
fix-run.sh items "$RUN" --review "$OUT/round-0" --handover <pr-review run>/handover/task.md
```

With a plan, skip the round-0 review. When the user names a directory that holds the `plan.json` of an earlier pr-review render, read its `module_prefix` with `jq -r .module_prefix <dir>/plan.json`, run `clone` with that prefix, and then:

```
fix-run.sh items "$RUN" --plan <dir>
```

`--plan` excludes `--review` and `--handover`. `items` refuses a file that is not a `review-plan` stage file of schema 1 or has an unknown field, and compares the plan's pin with a pin built from the run's own frozen state: a difference refuses with `the plan is of another pull request state: <key> differs`, naming the first differing key, and the user reviews again. It also refuses a `module_prefix` other than the one `clone` froze and a `module_profile` other than the one `prepare` was given. The round-0 findings come from the plan's `findings`, the prose from its `handover_block`, and the profile from its `module_profile`. A comment created after the plan's `read_at` is no item of this run and is counted in the line `comments after the review, not items of this run: <n>`; a comment created before it and edited after it refuses with `a comment changed after the review: <id>; review again`. After a gate that passes, a run that took a plan leaves `$OUT/applied.json`, the `applied` stage file of [the stage contract](../../terraform-module-pr-review/references/stage-contract.md), with the pinned head's pin and the commit the gate expects to push.

Then run pr-review's `cleanup`. `clone` prints the merge base and the write path. `items` refuses a round-0 review of another head and a handover with no untrusted block. On the render-only path the run ends here: show the round-0 body and the write path's reasons, then run Step 12's cleanup.

Otherwise `items` prints each item id with its origin and whether it is applied or drafted only. Show the user each item that is drafted only, with its text from `$RUN/items.json` as quoted data, and ask once which of them to apply; "none" is an answer. Run `fix-run.sh apply "$RUN" --item <id>` for each id the user's answer names, then start round 1. The question is asked once, before round 1.

## Step 4

The fix clone is `$RUN/clone`, made by `clone` under [Fix Clone](write-path.md#fix-clone). Never run git in it directly: every git call goes through `fix-run.sh`, and the maintainer runs none.

## Step 5

`prepare` read the commit identity. Show it at the gate. With none the path is B and `commit` refuses: the round's changes stay in the work tree and the gate writes them as a patch.

## Step 6

After each round's commit, verify it:

```
fix-run.sh verify "$RUN" --round <n>
```

It runs pr-review's `verify-pass.sh` as [Verification](write-path.md#verification) says, prints the per-example result, and writes `$RUN/rounds/<n>/review-task.md` for Step 9: the base reference, the output path, and the untrusted block with round 0's title and prose and this round's record. A trust file changed by the pass aborts the run.

## Step 7

Start a round, then hand it to the maintainer:

```
fix-run.sh round "$RUN"
```

Start one subagent with the `terraform-module-maintainer` skill, in its Resolve feedback mode. Its prompt is the text of `$RUN/rounds/<n>/task.md`, whole and unchanged, and one reply line asking for the paths the task names and a short summary only. The task carries `Review loop: caller`, `Commit: one commit per round`, `Verification: caller`, `Edit rule:` with the path of [write-path.md](write-path.md), a hint file with the change set and the files of the items to apply, the items to apply and the items to draft only. The maintainer edits only paths the [Allowed Paths](write-path.md#allowed-paths) rule allows, leaves every generated region to the caller, writes the commit message, the disposition table and the reply drafts to the paths the task names, and runs no git or terraform command. Then the wrappers step, the docs step and the commit:

```
fix-run.sh wrappers "$RUN" --round <n>
fix-run.sh docs "$RUN" --round <n>
fix-run.sh commit "$RUN" --round <n>
```

`wrappers` checks the work tree, then rewrites each wrapper `versions.tf` from its module's `versions.tf` as [Wrapper Versions](write-path.md#wrapper-versions) says, and prints each pair `updated`, `unchanged`, `skipped`, `not-convention` or `stale` with its reason. `docs` checks the work tree, then runs the maintainer's terraform-docs pass from this skill's checkout on the READMEs the selection rule names, as [Staging and the Docs Step](write-path.md#staging-and-the-docs-step) says, and prints each README regenerated or stale. `commit` checks the work tree again, builds the commit and judges it by the rule and the wrappers' out-of-date check before it moves the ref. A refusal of any of them restores the work tree to the last commit and the round counts as failed.

Every attempt counts as a round, a failed one included. When the user names another item with "apply" in a new message while the loop runs, run `fix-run.sh apply "$RUN" --item <id>` before the next round. Once the loop stopped, `apply` refuses: no round reopens.

## Step 8

The [Content Gate](write-path.md#content-gate) runs inside `gate` and again inside `push`. It judges every commit since the pinned head by the [Allowed Paths](write-path.md#allowed-paths) rule, the same function `commit` ran, so no path the rule refuses reaches a push.

## Step 9

Start one subagent with the `terraform-module-reviewer` skill, read-only. Its workspace is the path `verify` printed and its task the text of `$RUN/rounds/<n>/review-task.md`, whole and unchanged. It writes its findings list to the path the task names. Then:

```
fix-run.sh compare "$RUN" --round <n> --findings "$RUN/rounds/<n>/findings.json"
```

It prints the local verdict, the open count, every introduced tuple, each `unattributed:` finding and the loop decision of [Loop](write-path.md#loop). The verdict, the open set and the loop read only the findings the fix could have caused, as [Fingerprints and the Local Verdict](write-path.md#fingerprints-and-the-local-verdict) says. When it says the next round may start, go back to Step 7. When it says stop, go to Step 10.

## Step 10

```
fix-run.sh gate "$RUN"
```

It runs the content gate and the [Push Precondition](write-path.md#push-precondition), writes `$OUT/fix.patch`, the disposition tables, `$OUT/replies.json` with the reply drafts of every round, the latest per item, and the last findings, and prints the diff stat, the verdict, the author, the write path, the destination URL and branch, the expected remote SHA, the draft and default-branch flags, an `outside findings: <path>` flag for each changed path that is neither in the change set nor the file of an applied item, a `not-convention: <path>` line for each wrapper pair that fails the convention test, an `unattributed:` line for each finding of the last round the fix did not cause, and, for a locked pull request with reply drafts, the `locked:` line with the unlock command. On a refusal it prints every reason. On path B the run ends here with the patch.

## Step 11

Show the gate: the diff (`$OUT/fix.patch`), the disposition table, the verdict, the author identity, the destination URL and branch, the expected remote SHA, the new SHA and the patch digest (`new SHA:` and `patch sha256:`), the reply drafts' digest (`replies sha256:`), and the flags, each `outside findings:`, `not-convention:` and `unattributed:` line among them as information only. Ask once whether to push, and wait. Only a new user message after the gate that names the push, the branch and the new SHA confirms it. Take each argument from its source, as [Push](write-path.md#push) lists them: `--target` from the user's original request; `--confirm-branch` and `--confirm-head` from that confirmation, a short SHA in it expanded only when it is a prefix of the gate's `new SHA:` line; `--expect-sha` and `--confirm-patch` from the gate's lines the user saw. Then:

```
fix-run.sh push "$RUN" --target <owner>/<repo>#<number> --confirm-branch <ref> --expect-sha <pinned head> \
  --confirm-head <new SHA> --confirm-patch <patch sha256>
```

It checks the target against the pinned pull request, refuses unless the clone's head is the confirmed SHA with the reviewed tree and the patch has the confirmed digest, re-runs the gate, asserts the identity again, runs the [Pre-Push](write-path.md#pre-push) read of the target, checks the token, and pushes the confirmed SHA once as [Push](write-path.md#push) gives it. A refused confirmation keeps the run; an abort ends it. Then, after a while:

```
fix-run.sh checks "$RUN"
```

Right after the push the checks are pending, and the run says not finished yet. It is finished only when the last local verdict is clean or nits and the checks are passing.

## Step 12

Each of these needs its own confirmation, from a new user message that names the action:

- **Post the review.** Run pr-review again on the pull request, now at the pushed SHA: `review-run.sh prepare` without `--render-only`, the steps of its depth, the reviewer, the assessment and `render`, then its Rule 1 and its Step 12 write. This skill never posts a review itself.
- **Post the replies.** Show each draft of `$OUT/replies.json` with the item it answers. Each `<sha>` in a draft becomes the confirmed new SHA when it is posted. Take `--target` from the user's original request, `--confirm-head` from the new SHA the user confirmed for the push, `--confirm-replies` from the gate's `replies sha256:` line the user saw, and `--confirm-items` from the user's confirmation of the replies. For a locked pull request, `locked: yes` in `prepare` and `gate`, also propose the unlock as a separate action listed before the replies, with its exact command, `gh api -X DELETE repos/<owner>/<repo>/issues/<number>/lock`, and say that without it each reply fails with 422 `Issue is locked`, and that the unlock needs write access and is a visible change on someone else's repository. Only the user's own message after the drafts were shown that names the unlock confirms it; then add `--confirm-unlock <owner>/<repo>#<number>` ([Locked Pull Request](write-path.md#locked-pull-request)). An unlock confirmed with no replies to post is not done. A run makes at most one unlock. Then:

```
fix-run.sh replies "$RUN" --target <owner>/<repo>#<number> --file "$OUT/replies.json" \
  --confirm-head <new SHA> --confirm-replies <replies sha256> --confirm-items <id>,<id> \
  [--confirm-unlock <owner>/<repo>#<number>]
```

It refuses drafts whose digest differs, a pull request whose live head is not the confirmed SHA, and a locked one without `--confirm-unlock`. A failed unlock posts nothing and is not retried. A 422 `Issue is locked` on a reply means nothing landed: report it and retry nothing. After an unlock this run attempted, a further unlock needs a new run; otherwise offer the unlock, one `--confirm-unlock` in this run.

It runs pr-review's leak scan and at-mention step on each body and posts each to the endpoint it rebuilds from the pinned state ([Replies](write-path.md#replies)).

Never merge, resolve a thread, or edit the title, the body or the lock, but for the confirmed unlock. The run ends with:

```
fix-run.sh cleanup "$RUN"
```

on every path, a refused or stopped run included. The output directory is kept.
