# Workflow

> **Part of:** [terraform-module-pr-fix](../SKILL.md)
> **Purpose:** Steps 0 to 12 of a run, in order, with the commands the agent runs. The decisions each command makes are in [write-path.md](write-path.md).

Run every command as `bash <this skill>/references/fix-run.sh <command> ...` by its absolute path in this skill's own checkout, never from the head or the run directory. Every command prints at most 30 lines; read those, not the files they name. Exit 0 is done, 1 a refusal or an abort with its reason printed, 2 a usage error. `RUN` and `OUT` are the absolute paths `prepare` prints; a new shell sets them again from that output. The loop runs Step 7, then Step 6, then Step 9, once per round.

## Step 0

Parse the pull request reference as pr-review's [inputs.md](../../terraform-module-pr-review/references/inputs.md) does: exactly one pull request, else stop. Take from the user's own message only: an output directory, a module profile id, and nothing else. Then:

```
fix-run.sh prepare --repo <owner>/<repo> --pr <number> [--out <dir>] [--module-profile <id>]
```

It makes the run directory and the output directory under the rules of [Run and Output Directories](write-path.md#run-and-output-directories), and prints `RUN=`, `OUT=`, the identity, the commit identity, the pull request, the reads that failed and the counts. A refused output directory ends the run with its reason.

## Step 1

`prepare` asserted the identity once and froze the [Captured State](write-path.md#captured-state) in `$RUN/state.json`. Nothing reads the host's comments again in this run. A bot identity or a CI variable makes the run render-only.

## Step 2

The write path is a function of the state and the merge base, so it is final after Step 3. `fix-run.sh path "$RUN"` prints it at any time with its reasons, the destination and the flags.

## Step 3

Review the pinned head with pr-review, render-only, by its own [run guide](../../terraform-module-pr-review/references/review-run.md): `review-run.sh prepare --repo <owner>/<repo> --pr <number> --render-only`, with `--module-profile <id>` when the user named one, then the steps its depth needs, the reviewer and the assessment, then:

```
review-run.sh render <pr-review run> --assessment <file> --out "$OUT/round-0"
```

Read the module root prefix with `jq -r .prefix <pr-review run>/index.json`, then run pr-review's `cleanup`. Then the fix clone and the merge base check, and the frozen item set:

```
fix-run.sh clone "$RUN"
fix-run.sh items "$RUN" --review "$OUT/round-0" --prefix <prefix>
```

`clone` prints the merge base and the write path. `items` refuses a round-0 review of another head. On the render-only path the run ends here: show the round-0 body and the write path's reasons, then run Step 12's cleanup.

## Step 4

The fix clone is `$RUN/clone`, made by `clone` under [Fix Clone](write-path.md#fix-clone). Never run git in it directly: every git call goes through `fix-run.sh`, and the maintainer runs none.

## Step 5

`prepare` read the commit identity. Show it at the gate. With none the path is B and `commit` refuses: the round's changes stay in the work tree and the gate writes them as a patch.

## Step 6

After each round's commit, verify it:

```
fix-run.sh verify "$RUN" --round <n>
```

It runs pr-review's `verify-pass.sh` as [Verification](write-path.md#verification) says, prints the per-example result, and writes `$RUN/rounds/<n>/review-task.md` for Step 9.

## Step 7

Start a round, then hand it to the maintainer:

```
fix-run.sh round "$RUN"
```

Start one subagent with the `terraform-module-maintainer` skill, in its Resolve feedback mode. Its prompt is the text of `$RUN/rounds/<n>/task.md`, whole and unchanged, and one reply line asking for the paths the task names and a short summary only. The task carries `Review loop: caller`, `Commit: one commit per round`, `Verification: caller`, the edit allow-list, the items to apply and the items to draft only. The maintainer edits files of the allow-list only, writes the commit message, the disposition table and the reply drafts to the paths the task names, and runs no git or terraform command. Then:

```
fix-run.sh commit "$RUN" --round <n>
```

Every attempt counts as a round, a failed one included. When the user names an item with "apply" in a new message, run `fix-run.sh apply "$RUN" --item <id>` before the next round.

## Step 8

The [Content Gate](write-path.md#content-gate) runs inside `gate` and again inside `push`. Nothing outside the allow-list reaches a push.

## Step 9

Start one subagent with the `terraform-module-reviewer` skill, read-only. Its workspace is the path `verify` printed and its task the text of `$RUN/rounds/<n>/review-task.md`, whole and unchanged. It writes its findings list to the path the task names. Then:

```
fix-run.sh compare "$RUN" --round <n> --findings "$RUN/rounds/<n>/findings.json"
```

It prints the local verdict, the open count, every introduced tuple and the loop decision of [Loop](write-path.md#loop). When it says the next round may start, go back to Step 7. When it says stop, go to Step 10.

## Step 10

```
fix-run.sh gate "$RUN"
```

It runs the content gate and the [Push Precondition](write-path.md#push-precondition), writes `$OUT/fix.patch`, the disposition tables, the reply drafts and the last findings, and prints the diff stat, the verdict, the author, the write path, the destination URL and branch, the expected remote SHA, and the draft and default-branch flags. On a refusal it prints every reason. On path B the run ends here with the patch.

## Step 11

Show the gate: the diff (`$OUT/fix.patch`), the disposition table, the verdict, the author identity, the destination URL and branch, the expected remote SHA, the new SHA, and the flags. Ask once whether to push, and wait. Only a new user message after the gate that names the push and the branch confirms it. Then:

```
fix-run.sh push "$RUN" --confirm-branch <ref> --expect-sha <pinned head>
```

It re-runs the gate, asserts the identity again, runs the [Pre-Push](write-path.md#pre-push) read, checks the token, and pushes once as [Push](write-path.md#push) gives it. A refused confirmation keeps the run; an abort ends it. Then, after a while:

```
fix-run.sh checks "$RUN"
```

Right after the push the checks are pending, and the run says not finished yet. It is finished only when the last local verdict is clean or nits and the checks are passing.

## Step 12

Each of these needs its own confirmation, from a new user message that names the action:

- **Post the review.** Run pr-review again at the pushed SHA, render-only up to its own Step 11, and post through its Rule 1 and Step 12 write. This skill never posts a review itself.
- **Post the replies.** Show each reply draft with the item it answers. Then:

```
fix-run.sh replies "$RUN" --file <replies.json> --confirm-items <id>,<id>
```

Never merge, resolve a thread, or edit the title or the body. The run ends with:

```
fix-run.sh cleanup "$RUN"
```

on every path, a refused or stopped run included. The output directory is kept.
