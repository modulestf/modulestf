# Review Run

> **Part of:** [terraform-module-pr-review](../SKILL.md)
> **Purpose:** The run guide: every command of [review-run.sh](review-run.sh) with its inputs and outputs, in the order a run uses them. With SKILL.md it is all a normal run reads; the edge cases are in [review-run-details.md](review-run-details.md) and the step text in [workflow.md](workflow.md).

Invoke `bash <this skill>/references/review-run.sh <command> ...` by its absolute path in this skill's own checkout, never from the head or the run directory. Every command prints at most 30 lines; read those, not the files they name. Exit 0 is done, 1 a refusal or a failed step with its reason printed, 2 a usage error. No command posts: the write stays Steps 11 and 12 under Rules 1 and 4.

## A Run, Step by Step

1. **Parse** the request (Step 0, [inputs.md](inputs.md)).
2. **`prepare --repo <owner>/<repo> --pr <number>`**, with flags from the user's own message only: `--render-only`; `--triage`; `--profile <name> --role-arn <arn>` when the user named both for this run; `--owner-depth deep` for the exact token `depth: deep`. `--owner-pid <pid>` is optional and the user need not give it: the long-lived process that owns the review, such as a runner, named in the ladder's lease ([ladder-pass.md](ladder-pass.md)); without it the lease has no owner and expires a day ahead, which is right for a run an agent drives. It prints `RUN=<directory>`, the identity, the depth with its reasons, the signals and the next commands, and writes `<run>/index.json`: the head, base and merge base, the depth, its reasons, the checks and examples out of scope, the signals, the state flags and counts. No host prose is in it. A refusal prints `prepare refused: <reason>`: say the review is inconclusive and why, and run `cleanup`.
3. **Claims** (Step 5.4), outside a triage run: read `<run>/behaviour/behaviour.json` and the title and body in `<run>/host/task.md`, and write `<run>/behaviour/claims.json` as [the claims file](../../terraform-module-reviewer/references/verification-ladder.md#the-claims-file) says; no claim, no file.
4. **The evidence commands of the depth**, in the order of the table below. Each prints a short status; one that prints `depth: escalated to deep` switches the rest of the run to the deep row.
5. **`handover <run>`**: writes `<run>/handover/task.md` and prints the workspace and the task path.
6. **The reviewer**, as [Starting the Reviewer](#starting-the-reviewer) says.
7. **The assessment**, as [The Assessment](#the-assessment) says.
8. **`render <run> --assessment <file> --out <dir>`**: prints the render line, the body path and the identity line.
9. **Show and confirm** under Rule 1: the body file rendered as markdown, the target, the login and the event; for a render-only run, the clamp's reason beside it.
10. **`cleanup <run>`** ends every run, a refused or stopped one included.

## Commands per Depth

| Depth | After `prepare` and the claims |
|---|---|
| light | `verify`, `plan`, `ladder`, `handover` |
| focused | `schema`, `verify`, `plan`, `skip-coverage`, `ladder`, `handover` |
| deep | `schema`, `verify`, `plan`, `skip-coverage`, `ladder`, `handover` |
| triage | `handover` only, with no claims |

`handover` and `render` refuse until every step of the depth has run; the message names the missing one.

## Commands

| Command | Reads | Writes and prints |
|---|---|---|
| `schema <run>` | `depth.json` | Fact sheets in `<run>/facts` from [schema-pass.sh](schema-pass.sh), whole at focused; at deep partial, with `missing.json` naming the types with no sheet, and `schema pass: deep ...` is a success; never run at light. The `schema pass: source` lines go into the record. At focused a failure escalates: `schema: escalated to deep (reason <r>)`. At deep a failure leaves no sheets, and the reviewer reads pages |
| `verify <run> [--outside]` | The clone, `files.json` | `<run>/verify.json`, the default pass ([verify-pass.md](verify-pass.md)) in every example. A failed `validate` at light, or one new under the change at focused in any example, escalates. `--outside` re-runs the examples that ended `not run: environment`, only under the user's authorization in [github-io.md](github-io.md#allowed-commands) |
| `plan <run>` | The profile and role from `prepare` | The plan pass ([plan-pass.md](plan-pass.md)), runner or laptop mode, at focused and deep with a profile; then `<run>/coverage.json` at every depth. At light the unplanned reason is `plan pass skipped at light depth`; with a profile and no plan record, `plan pass did not run: refused` or `...: failed` |
| `skip-coverage <run>` | `coverage.json`, the plan record | `<run>/skip-check.json` ([skip-coverage.md](skip-coverage.md)), only after a laptop pass with gate G1 to G3 skips |
| `ladder <run>` | `behaviour.json`, `claims.json` | The ladder record at focused and deep ([ladder-pass.md](ladder-pass.md)), then the claims evaluation at every depth: `behaviour/run-behaviour.json` and `behaviour/record.txt` |
| `handover <run>` | Every output above | `<run>/handover/task.md`, `record.txt` and `change.diff`; `<run>/review/` for the reviewer's output |
| `render <run> --assessment <file> --out <dir> [--findings <file>] [--summary <file>] [--standard]` | The reviewer's output, the run's files | The body, `findings.json` and `result.json` in `--out`, outside the run directory ([render-comment.sh](render-comment.sh)) |
| `cleanup <run>` | Nothing | Deletes the run directory |

## Starting the Reviewer

Start one subagent with the `terraform-module-reviewer` skill, read-only: it edits no file of the workspace and runs no command the reviewer skill does not allow. Its prompt is the workspace, the task and one reply line, `{workspace, task, reply}`: the workspace is the path `handover` prints; the task is the text of `<run>/handover/task.md`, whole and unchanged; the reply line asks for the paths the task's `Output:` line names and a short summary only. The skill is the one the host loads by name, or the `SKILL.md` path of the skills checkout the user named for this run. Add nothing else: the task's own lines already carry the head revision, `Write short:`, `Depth:`, `Provider fact sheets:` when the schema pass gave sheets, `Diff:`, `Merge base:` and `Output:`, then the untrusted block with the prose and the verification record.

The `Output:` line names where the reviewer writes, all under `<run>/review/`: `findings.json`, the findings list with paths relative to the module root; `summary.txt`, its summary line; and `facts-comparison.txt`, the note comparing its findings with the facts engine, which the render does not read. Read nothing of its reply but those paths and the summary. When a COMPACT cap refuses the render, send the finding back to the same reviewer once with the render's advice.

## The Assessment

The assessment is section 1 of the comment and the only text the model writes for it ([comment-format.md](comment-format.md#section-order)): what the change does and what matters in it, from the findings and the diff, never a finding of its own. Write it to a file outside the clone, such as `<run>/assessment.txt`. Printable ASCII, at most two short paragraphs and 700 characters, and no line that starts like a heading, a bold line, HTML, a list item, a quote or a table row. The COMPACT tier takes at most 350 characters in one paragraph; over a cap the render refuses and says which.

## Render and Confirm

`render` defaults `--findings` to `<run>/review/findings.json` and `--summary` to `<run>/review/summary.txt`, merges the run's evidence into the run file, checks the depth binding, and runs render-comment.sh. It prints `rendered <verdict> (ladder rule <n>), proposed event <EVENT>, tier <TIER>`, the body path and the identity. `--standard` renders the STANDARD tier when the reviewer kept a finding over a COMPACT cap. Then Step 11 of [workflow.md](workflow.md#step-11) and Rule 1: show the body file, ask once, and post only on a confirmation that names the event.
