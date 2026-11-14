# Behaviour Pass

> **Part of:** [terraform-module-pr-review](../SKILL.md)
> **Purpose:** Steps 5.4 and 5.5's behaviour part as one script, [behaviour-pass.sh](behaviour-pass.sh): the classifier, the claims step and the claims evaluation, what each writes, and the record and run object they hand on.

The categories, levels, claim predicates and states are in the reviewer's [verification-ladder.md](../../terraform-module-reviewer/references/verification-ladder.md). This file covers only the host side: what runs, in what order, and what crosses.

## Order

1. **Classify, Step 5.4.** `behaviour-pass.sh classify --facts <mtf-facts> --dir <module root> --diff <files.json> --prefix <module root prefix> [--schema <schema.json>] --out <dir>` runs `mtf-facts behaviour` on the module root of the Step 3 clone with the Step 4 files list, made module-relative: the prefix is stripped and paths outside it are left out. With a merge base tree checked out, `--base <dir>` replaces `--diff` and `--prefix`. A `--diff` that is not a GitHub files list, a JSON array of objects with a `filename`, is a usage error. `--schema` is the provider schema `ladder-pass.sh acquire` wrote, which the classifier uses to decide Optional and Computed; acquisition needs only the pin file, so it runs first and the schema is passed when it succeeded. Classify itself runs before any terraform command on the head and needs none. It writes `behaviour.json` or `status` in `<dir>`, a directory under the run directory and outside the clone.
2. **Claims, Step 5.4.** The model reads `behaviour.json` and the pull request title and body, and writes `claims.json` in the same directory, as [the claims file](../../terraform-module-reviewer/references/verification-ladder.md#the-claims-file) says. No claim, no file. When classify wrote `status`, there is nothing to map a claim to, and no file is written.
3. **The passes, Step 5.5.** The default pass, the plan pass, then the ladder's L1, L2 and L3 levels: `ladder-pass.sh run <run-dir> --behaviour <dir>/behaviour.json --base <merge base> --head <headRefOid> --out <dir>/ladder.json --owner-pid <pid> [--schema <schema.json>]` evaluates each L1 trigger's required cases in its network-denied sandbox, runs each L2 trigger's cases as a plan-only `terraform test` there, and each L3 trigger in its curated provider fixture when `ladder-pass.sh acquire` ran in the run and wrote that schema, and writes the ladder record ([ladder-pass.md](ladder-pass.md)). When classify wrote `status`, there is no `behaviour.json` and the ladder does not run.
4. **Evaluate, end of Step 5.5.** First `behaviour-pass.sh wrappers` writes the wrapper evidence of [Wrapper Versions](#wrapper-versions). Then `behaviour-pass.sh eval --facts <mtf-facts> --out <dir> --head <headRefOid> --base-sha <merge base> [--claims <dir>/claims.json] [--ladder <ladder record>] [--wrappers <dir>/wrappers.txt]` runs `mtf-facts claims-eval` with `--head-sha` and `--base-sha`. A ladder record whose `schema_version` is not 1, or whose `head_sha` or `base_sha` is not the one given, is refused before the tool runs. With no ladder record it hands the tool the empty one, so every trigger is unverifiable unless it is inert, and every claim is unverifiable. It writes `run-behaviour.json` and `record.txt`, and prints the record.

`--facts` is the installed `mtf-facts`, by an absolute path outside the clone, as the reviewer's [facts-engine.md](../../terraform-module-reviewer/references/facts-engine.md) runs it. The tool reads files and runs nothing from the clone; it runs with the out directory as its working directory, and each run has a deadline, 120 seconds unless `BEHAVIOUR_PASS_TIMEOUT` sets 1 to 9999. A triage run skips all four.

## Fail Closed

Every failure ends in `not-run` with one fixed reason, and the script still exits 0, so the step never stops the run. Leaving the object out of the run file does not help a host: outside a triage run, the render reads it as a step that did not run.

The reasons:

| Reason | When |
|--------|------|
| `mtf-facts not installed` | `--facts` is not an executable file |
| `mtf-facts failed` | `behaviour` or `claims-eval` exited non-zero |
| `mtf-facts timed out` | A run passed its deadline |
| `output refused` | Output over 1 MiB, not JSON, or outside its contract: a trigger id not `T-` and three digits, a duplicate id, a file that is not a clean module-relative path, a line below 1, a category outside the list, over 40 triggers, no `capped` count, an entry naming a trigger that does not exist, a trigger path with a space or a colon, a required case set (`triggers[].cases`) that is not up to 32 objects, each with an `inputs` object and a distinct `id`, a path of the files list with no entry, a rename checked at its old path too, while an `unchanged` status and paths under `.git` or `.terraform` need none; or a `claims-eval` reply that does not give every trigger and every claim of the files exactly one state from its list, or whose `changes` items are not a level, a case id of letters, digits, `_`, `.`, `:` or `-`, one of the 11 attributes of [verification-ladder.md](../../terraform-module-reviewer/references/verification-ladder.md#states) an `explained` flag and, when given, `explained_by`, at most 20 claim ids of the claims file on an explained change only, or whose `capped` is not the classifier's |
| `ladder refused` | The ladder record is not JSON, not schema 1, or names another head or base. `claims-eval` does not run |
| `claims refused` | `claims.json` over 64 KiB, not a JSON object, over 48 claims, or a claim id that is not `C-` and digits or appears twice. `claims-eval` does not run |

A not-run behaviour step is an unknown at [verdict.md](verdict.md#behaviour-evidence) rule 4. Nothing is guessed in its place. Exit 2 is a usage error: a relative path, `eval` before `classify`, or an out directory that already holds the step's files.

## The Record

`record.txt` joins the verification record in the [handover](github-io.md#handover). Its lines, in order:

```text
behaviour: ran, <n> triggers, <c> over the cap[, inert]
trigger <id> `<file>` line <line> <category>: <state>[, wrapper <derived|copied>][, complete][, outstanding <n>, digest <64 hex>]
claim <claim_id> on <trigger id> at <base|head>, <predicate_type>: <state|discarded>
change <trigger id> <level> case <case> <attribute>: <explained[ by <claim ids>]|unexplained>
```

or the one line `behaviour: not run: <reason>`. File paths are relative to the module root, as the reviewer's diff is, in a code span; a trigger with no line has no `line` part. A trigger line says `complete` when `claims-eval` gives `complete` true, and the number of its outstanding differences with their `evidence_digest` when it gives both; the outstanding ids are `<trigger id>|<level>|<case>|<attribute>` of that trigger's `unexplained` `change` lines, which the reviewer names in a finding's `explains` with the digest ([verdict.md](verdict.md#behaviour-evidence)). One `change` line per difference between base and head that `claims-eval` reports, never with the case's inputs; an explained one names the claims `claims-eval` gives in `explained_by`, at most 20 ids of the claims file, so a pass can be traced to the claims behind it. A claim's node, revision and predicate are printed only when each matches its closed pattern, since the model wrote the claims file; otherwise the line is `claim <claim_id>: <state>`. No reason text from the tool and no expression crosses: the reviewer reads the trigger's file and line itself.

## The Run Object

`run-behaviour.json` is the run file's optional `behaviour` key for [render-comment.sh](render-comment.sh):

```json
{"status": "ran", "reason": null, "capped": 0,
 "triggers": [{"id": "T-001", "file": "main.tf", "line": 2, "category": "wrapper-change", "state": "unverifiable"}],
 "claims": [{"claim_id": "C-1", "state": "unverifiable"}]}
```

A trigger carries `complete`, `outstanding` and `evidence_digest` when `claims-eval` gives them, copied as they are and held to their grammar: `complete` a boolean, `outstanding` at most 256 ids of this trigger matching `^T-[0-9]{3}\|L[1-4]\|[A-Za-z0-9_.:-]{1,64}\|[a-z_]{1,32}$`, sorted and each once, and `evidence_digest` 64 lowercase hex characters, only with an outstanding id; a `verified`, `covered` or `inert` trigger carries neither. A trigger the classifier merged from others carries their categories as `also_categories`, copied from the classifier output, each a category of the list once. Output outside that grammar is `output refused`. A trigger's `state` is `inert`, `verified`, `covered`, `refuted` or `unverifiable`; a claim's is `verified`, `refuted` or `unverifiable`, and a claim the tool discarded is `unverifiable`. A not-run object has its `reason`, no trigger, no claim and `capped` 0. A refuted trigger or claim blocks at ladder rule 2 by itself. The render lists every unverifiable trigger and claim, the capped count and a not-run step in section 5 of [comment-format.md](comment-format.md#section-order), counts each as a gap, and writes the evidence line under the rationale.

## Wrapper Versions

The `terraform_wrapper_module_for_each` hook of `antonbabenko/pre-commit-terraform` writes each wrapper `versions.tf` from its module's `versions.tf`. Before v1.106.0 it copies the file unchanged. From v1.106.0 on it copies it and deletes the `user_agent` and `module_name` attributes of each `provider_meta` block. A maintenance pull request that moves the hook across that version regenerates the wrappers, and no level of the ladder can verify a `provider_meta` edit. The host computes the hook's output itself, runs nothing from the clone and trusts no check result.

`behaviour-pass.sh wrappers --clone <Step 3 clone> --head <headRefOid> --diff <files.json> --prefix <module root prefix> --out <dir>` writes `<dir>/wrappers.txt`, one line per wrapper `versions.tf` the files list names under the module root: its module-relative path, a space and its result. The pairs are the pull request fix skill's ([write-path.md](../../terraform-module-pr-fix/references/write-path.md#wrapper-versions)): `wrappers/versions.tf` comes from `versions.tf`, and `wrappers/<sub>/versions.tf` from `modules/<sub>/versions.tf`, where `<sub>` is one name of at most 64 characters of letters, digits, `.`, `_` and `-` that starts with a letter, a digit or `_`. Nothing else is read.

It reads three files at the head: the wrapper, its module file and the repository's `.pre-commit-config.yaml`, each with `ls-tree` and `cat-file blob` run under the environment and `-c` options of the form in the reviewer's [git-safety.md](../../terraform-module-reviewer/references/git-safety.md#the-form). The form's table of queries lists neither subcommand: like the base extraction of the reviewer's [facts-engine.md](../../terraform-module-reviewer/references/facts-engine.md), these two read objects only and run no driver, filter or textconv. A partial clone is refused, since git would fetch its missing objects. The depth-1 clone serves: a blob of the head needs no history. A file counts only when it is a `100644` blob of at most 64 KiB whose ancestors are tree entries.

The pin is the `rev` of the one `- repo:` entry of `https://github.com/antonbabenko/pre-commit-terraform` that lists the hook, read line by line as data. The reader fails closed rather than parse YAML: the file is no evidence when it holds a form a YAML loader could read another pin from. Those forms are a backslash anywhere, which covers an escape in a quoted scalar; a quote left open at the end of a line; a block scalar indicator (`|` or `>`); a flow mapping, or a flow sequence not closed on its own line; an anchor, alias, tag, merge key or complex key; a line that is not a comment, a blank, a list item or a key with a space after its colon, such as a plain scalar continued onto the next line or a `---` or `...` document marker; a second top-level `repos` key; a `repo` or `rev` key in any other spelling, such as a second `rev` key or a value on the next line; a `repo` URL outside a plain `https` form, such as one with a percent escape; and the repository name `pre-commit-terraform` or the hook id named a second time, in any letter case and under any owner or host. The `repo`, `rev` and hook `id` keys are read only with a space after the colon. A one-line flow sequence, such as `args: [--fix=lf]`, is read. A `--module-repo-provider` option anywhere moves the hook to another provider, and the file is no evidence. A `rev` of the form `v<x>.<y>.<z>` at v1.106.0 or later expects derive(module), the function in [wrapper-derive.pl](wrapper-derive.pl) both skills run. An earlier tag expects the module file byte for byte. The hook strips the attributes only in the `provider_meta` block of its provider, `aws` by default, while derive strips them in every block, so at v1.106.0 or later a module file with any other `provider_meta` line is no evidence.

| Result | When |
|--------|------|
| `derived` | The pin is v1.106.0 or later and the wrapper equals derive(module) |
| `copied` | The pin is earlier and the wrapper equals the module file |
| `differs` | The wrapper is not the expected file |
| `unknown <reason>` | No expected file: `no pin` (no file or no entry), `pin not a release tag` (a branch or a commit), `hook not listed`, `hook options`, `pin unreadable` (any of the forms above, two entries or `rev` lines, a byte outside printable ASCII), `provider_meta`, `derive undefined`, `wrapper <why>` or `module <why>`, where `<why>` is `link` (the file or an ancestor), `not a regular file`, `absent`, `over size` or `read failed`; `partial clone`; `read failed` |

`eval --wrappers <file>` reads the file only when it has at most 256 lines, each in that grammar; any other file is no evidence. A trigger whose file is a wrapper with `derived` or `copied`, and whose state is `unverifiable`, becomes `inert`, with no outstanding difference and no `change` line, and its record line says `, wrapper derived` or `, wrapper copied`. A `differs` or `unknown` wrapper and a `refuted` trigger keep their state. `review-run.sh handover` reads it the same way and states each line as `Wrapper versions: <path> <result>` in the task's own text, before the untrusted block, where the reviewer's [Check E](../../terraform-module-reviewer/references/check-e-profile.md#reads-fails-when-and-severity) reads it. The judgment variant's prefix ([facts-variant.md](facts-variant.md)) is at its size cap and carries only Check E's pointer line, so a judgment run takes `derived` and `copied` as no finding, and judges a `differs` or `unknown` wrapper by the generated content rules alone.

## Limits

- A trigger the classifier marks `base_absent` or `head_absent` has the expression `null` at that revision: the provider attribute is absent there, and Terraform reads it as null. The ladder evaluates it like any other expression, and a base claim on it is valid. The flags cross to no record line and no run object.
- A data source argument takes L1 only. A deferral of its read by `depends_on` or by a pending change of a dependency is not modelled, so no claim that a read is not deferred can verify.
- The claims are the model's reading of the description. A claim the model leaves out is not evaluated, and its trigger then has no claim, which keeps it unverifiable unless it is inert or covered.
