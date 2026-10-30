# Behaviour Pass

> **Part of:** [terraform-module-pr-review](../SKILL.md)
> **Purpose:** Steps 5.4 and 5.5's behaviour part as one script, [behaviour-pass.sh](behaviour-pass.sh): the classifier, the claims step and the claims evaluation, what each writes, and the record and run object they hand on.

The categories, levels, claim predicates and states are in the reviewer's [verification-ladder.md](../../terraform-module-reviewer/references/verification-ladder.md). This file covers only the host side: what runs, in what order, and what crosses.

## Order

1. **Classify, Step 5.4.** `behaviour-pass.sh classify --facts <mtf-facts> --dir <module root> --diff <files.json> --prefix <module root prefix> --out <dir>` runs `mtf-facts behaviour` on the module root of the Step 3 clone with the Step 4 files list, made module-relative: the prefix is stripped and paths outside it are left out. With a merge base tree checked out, `--base <dir>` replaces `--diff` and `--prefix`. A `--diff` that is not a GitHub files list, a JSON array of objects with a `filename`, is a usage error. It runs before any terraform command and needs none. It writes `behaviour.json` or `status` in `<dir>`, a directory under the run directory and outside the clone.
2. **Claims, Step 5.4.** The model reads `behaviour.json` and the pull request title and body, and writes `claims.json` in the same directory, as [the claims file](../../terraform-module-reviewer/references/verification-ladder.md#the-claims-file) says. No claim, no file. When classify wrote `status`, there is nothing to map a claim to, and no file is written.
3. **The passes, Step 5.5.** The default pass, the plan pass and, from a later release, the ladder runs.
4. **Evaluate, end of Step 5.5.** `behaviour-pass.sh eval --facts <mtf-facts> --out <dir> --head <headRefOid> --base-sha <merge base> [--claims <dir>/claims.json] [--ladder <ladder record>]` runs `mtf-facts claims-eval` with `--head-sha` and `--base-sha`. A ladder record whose `schema_version` is not 1, or whose `head_sha` or `base_sha` is not the one given, is refused before the tool runs. With no ladder record it hands the tool the empty one, so every trigger is unverifiable unless it is inert, and every claim is unverifiable. It writes `run-behaviour.json` and `record.txt`, and prints the record.

`--facts` is the installed `mtf-facts`, by an absolute path outside the clone, as the reviewer's [facts-engine.md](../../terraform-module-reviewer/references/facts-engine.md) runs it. The tool reads files and runs nothing from the clone; it runs with the out directory as its working directory, and each run has a deadline, 120 seconds unless `BEHAVIOUR_PASS_TIMEOUT` sets 1 to 9999. A triage run skips all four.

## Fail Closed

Every failure ends in `not-run` with one fixed reason, and the script still exits 0, so the step never stops the run. Leaving the object out of the run file does not help a host: outside a triage run, the render reads it as a step that did not run.

The reasons:

| Reason | When |
|--------|------|
| `mtf-facts not installed` | `--facts` is not an executable file |
| `mtf-facts failed` | `behaviour` or `claims-eval` exited non-zero |
| `mtf-facts timed out` | A run passed its deadline |
| `output refused` | Output over 1 MiB, not JSON, or outside its contract: a trigger id not `T-` and three digits, a duplicate id, a file that is not a clean module-relative path, a line below 1, a category outside the list, over 40 triggers, no `capped` count, an entry naming a trigger that does not exist, a trigger path with a space or a colon, a required case set (`triggers[].cases`) that is not up to 32 objects, each with an `inputs` object and a distinct `id`, a path of the files list with no entry, a rename checked at its old path too, while an `unchanged` status and paths under `.git` or `.terraform` need none; or a `claims-eval` reply that does not give every trigger and every claim of the files exactly one state from its list, or whose `changes` items are not a level, a case id of letters, digits, `_`, `.`, `:` or `-`, an attribute from the list and an `explained` flag |
| `ladder refused` | The ladder record is not JSON, not schema 1, or names another head or base. `claims-eval` does not run |
| `claims refused` | `claims.json` over 64 KiB, not a JSON object, over 20 claims, or a claim id that is not `C-` and digits or appears twice. `claims-eval` does not run |

A not-run behaviour step is an unknown at [verdict.md](verdict.md#behaviour-evidence) rule 4. Nothing is guessed in its place. Exit 2 is a usage error: a relative path, `eval` before `classify`, or an out directory that already holds the step's files.

## The Record

`record.txt` joins the verification record in the [handover](github-io.md#handover). Its lines, in order:

```text
behaviour: ran, <n> triggers, <c> over the cap[, inert]
trigger <id> `<file>` line <line> <category>: <state>
claim <claim_id> on <trigger id> at <base|head>, <predicate_type>: <state|discarded>
change <trigger id> <level> case <case> <attribute>: <explained|unexplained>
```

or the one line `behaviour: not run: <reason>`. File paths are relative to the module root, as the reviewer's diff is, in a code span; a trigger with no line has no `line` part. One `change` line per difference between base and head that `claims-eval` reports, never with the case's inputs. A claim's node, revision and predicate are printed only when each matches its closed pattern, since the model wrote the claims file; otherwise the line is `claim <claim_id>: <state>`. No reason text from the tool and no expression crosses: the reviewer reads the trigger's file and line itself.

## The Run Object

`run-behaviour.json` is the run file's optional `behaviour` key for [render-comment.sh](render-comment.sh):

```json
{"status": "ran", "reason": null, "capped": 0,
 "triggers": [{"id": "T-001", "file": "main.tf", "line": 2, "category": "wrapper-change", "state": "unverifiable"}],
 "claims": [{"claim_id": "C-1", "state": "unverifiable"}]}
```

A trigger's `state` is `inert`, `verified`, `covered`, `refuted` or `unverifiable`; a claim's is `verified`, `refuted` or `unverifiable`, and a claim the tool discarded is `unverifiable`. A not-run object has its `reason`, no trigger, no claim and `capped` 0. A refuted trigger or claim blocks at ladder rule 2 by itself. The render lists every unverifiable trigger and claim, the capped count and a not-run step in section 5 of [comment-format.md](comment-format.md#section-order), counts each as a gap, and writes the evidence line under the rationale.

## Limits

- The claims are the model's reading of the description. A claim the model leaves out is not evaluated, and its trigger then has no claim, which keeps it unverifiable unless it is inert or covered.
