# Comment Format

> **Part of:** [terraform-module-pr-review](../SKILL.md)
> **Purpose:** What the rendered review comment contains, in what order, and the scan that runs before it is shown to anyone.

The body is destined for a public repository. Write it for the maintainer who will read it there, not for the person running the skill.

## Section Order

Fixed, so two runs are comparable and a reader knows where to look.

1. **Assessment.** One or two sentences addressed to the author: what the change does, whether it looks broadly right, and what class of thing is missing. Size it to the change. A one-line spelling fix gets one short sentence and no thanks for the effort. A large feature with real defects gets a sentence on whether the shape is right and one naming what is missing. Name the actual thing every time. Generic praise and boilerplate thanks tell the author nothing. The assessment may also say that `terraform validate` passed in the examples the change touches, but only with its provenance, in words such as "`terraform validate` passed with the providers this change declares", adding "in a separate job without credentials" when the results came from a host. A pass ran providers the head chose, so it is evidence, never proof ([verify-pass.md](verify-pass.md#limits)): never write an unqualified "verified", and never state a host's passing result as a fact about the code. Or the assessment may say that the examples were not verified and why, with the same reasons section 5 lists per directory: terraform was not installed, `init` failed, the environment stopped it (`not run: environment`: a plugin handshake, a sandbox or OS denial, or the network), `not run: command limit`, `not run: budget`, `not run: symbolic link`, `verification input refused`, `host results rejected: <reason>`, or `host verification did not run`. In a [triage](github-io.md#triage) run the assessment says nothing about verification: Step 5.5 did not run, and the triage line under the verdict covers it. When `validate` ran and only `plan` was skipped because no AWS profile was named, the assessment says so once for the whole run; section 5 lists the examples that were not planned. When a profile was named and the plan pass stopped at a gate, the assessment says once: ``a `plan` was not run: the plan pass stopped at a gate``, and names neither the gate nor the file. When it ended as another note, it says ``a `plan` was not run: the plan pass ended without a result``. Section 5 lists neither. No kept line from a runner-mode plan pass, one whose record says `plan pass mode: runner` or carries plan evidence with no `plan pass mode:` line, appears anywhere in the body, whole or in part: not in the assessment, not in a finding summary, not in a Fix line. Such a pass ran the head's code with credentials, and a secret interleaved with text of that code's choosing passes the [leak scan](#leak-scan). When the plan pass planned an example, the assessment may name the counts on its kept `Plan:` summary line, such as `12 to add, 0 to change, 0 to destroy`, with the example's directory, and nothing else from the plan. It may also say, as a class, that the other examples the plan pass ran planned too, in words such as "the other examples the plan pass ran also planned", when the record has a `plan:` line for each of them and each is `planned` or `planned-no-changes`. An example with no `plan:` line in the record is not one the plan pass ran, and the statement never covers it. That statement names the class from the record's fixed `plan:` line, never a kept line, a count or a directory of those examples, as [plan-pass.md](plan-pass.md#what-crosses-to-the-reviewer) has a finding name the class.
2. **Verdict line.** The verdict from [verdict.md](verdict.md), in bold, with no `Verdict:` prefix, and, if a comment-only clamp applies, what it reduced the action to. A render-only clamp is never named in the body. It describes this run, not the change, and a body this run does not post can still reach the forge later, posted by hand or by a hosted adapter, where a line saying no action was proposed would be false. Its reason is shown beside the body where the run presents it, with the target, which satisfies [verdict.md](verdict.md#clamps)'s "say so next to the verdict" for a render-only run. Block reads `Changes requested before merge.`, changes suggested reads `Changes suggested.`, inconclusive reads `Inconclusive.`, approve reads `Good to merge.`, approve with nits reads `Good to merge, with nits.`, and hold for the next major reads `Breaking. Hold for the next major release.` The findings are still listed below it. In a [triage](github-io.md#triage) run a second line follows the verdict line, in plain text: `Triage only: the full review of this change has not run yet.` It is part of the body, since it describes what the review covered, and it appears only in a triage run.
3. **Rationale.** Two short sentences: the fact the verdict rests on, then the ladder rule that produced the verdict, in plain words and with its number. Nothing more: no new judgement, no praise, no summary of the change. When the behaviour step of [behaviour-pass.md](behaviour-pass.md) ran and classified at least one change or claim, one more paragraph follows: the fixed `behaviour-evidence` line of [Host Render Strings](#host-render-strings), with the count of each trigger and claim state. Over-cap triggers count as classified and not verified.
4. **Findings.** Grouped by severity, CRITICAL first, then by rule as [Grouping Findings](#grouping-findings) defines, which keeps the order the reviewer returned them in. When the list holds more than 10 findings, some groups render collapsed, as [Collapsing Findings](#collapsing-findings) defines. A finding that shares its rule with no other finding of its severity is one line: `rule_id`, repository-relative path and line, then the summary. Under it, a nested `Fix:` line carries its `suggested_fix`, so a person or the maintainer skill can make the change from the comment alone. A finding with a null line shows the path alone. Findings are rendered whole here; a `review.check-not-run` finding is a finding and belongs in this section, not in the next one. The optional `source` and `confirmed_by` fields of [findings-schema.md](../../terraform-module-reviewer/references/findings-schema.md#optional-fields) are not rendered and do not split a group. A `review.tool-disputed` finding is the disputed note: it renders after every severity, under the bold label `Disputed tool findings`, in the forms [Grouping Findings](#grouping-findings) defines, and never under LOW, since the ladder does not read it ([verdict.md](verdict.md)). It is not counted toward the threshold of [Collapsing Findings](#collapsing-findings) and never collapses. The rationale never names it.
5. **Checks that could not run.** This skill's own degraded reads: thread resolution unknown, a file whose patch was unavailable, quoted prose truncated, and every example directory whose verification did not run, one line each with its reason: terraform was not installed, `init` failed, `not run: environment`, `not run: command limit`, `not run: budget`, `not run: symbolic link`, `verification input refused`, `host results rejected: <reason>` with `<reason>` one of the fixed words in [verify-pass.md](verify-pass.md#results-from-a-host), or `host verification did not run`. It also lists every example whose `validate` failed at the head and whose merge base re-run did not run, with `merge base not available`, `merge base not run: environment`, `merge base not run: command limit` or `merge base not run: budget`; that line names only the re-run, and the head's failure stays a result. After those, when the change is not inert, it lists every selected example the plan pass did not cover, one `unplanned` line each with its fixed reason from [verify-pass.md](verify-pass.md#plan-coverage), `no AWS profile named` among them; a module with no example directory has the one `unplanned-no-examples` line instead, an unknown at rule 4 as well. One directory is enough; a run where the others verified still lists it. It also lists the behaviour evidence that did not verify ([behaviour-pass.md](behaviour-pass.md#the-run-object)): one line per trigger in state `unverifiable`, one line for the triggers over the classifier cap, one line per claim in state `unverifiable`, or the one line saying the behaviour step did not run and why. A trigger that is verified, covered by a plan or inert is not listed, and a refuted trigger or claim is not a gap: it blocks at rule 2. Each directory listed for one of these reasons is an unknown at [verdict.md](verdict.md#the-ladder) rule 4, so the verdict is inconclusive unless a rule above rule 4 fired, and so is each behaviour line. A plan pass note - a gate, the environment, needs input, the budget, output unrecognised, a plan pass that did not run or ended - is not a gap of its own and is never quoted ([plan-pass.md](plan-pass.md#what-crosses-to-the-reviewer)); the example it ended is listed once, as not planned, with the class as its reason. An inert change lists its examples that were not planned too, after the one `unplanned-inert` line, as information and not as gaps. An example directory recorded as `not run: version bump only` is not a gap and is not listed here, and neither is anything about conversation comments: those go in section 8. Each says what could not be read and why. A `terraform plan` or `terraform validate` that ran and failed is a result, not a gap: it produced a finding, and it belongs in the findings section above. Only a check that never ran may be mentioned here. In a triage run Step 5.5 does not run, and nothing is listed for it: the triage line under the verdict covers it.
6. **Pull request state.** The four host signals, one line, only when one of them is failing or unknown. Also, whenever the review decision left out an earlier review by the posting login, one line naming it even when every signal passes. Use the review's own state and commit, and pick the tail by the proposed event, which is known at this step. For `APPROVE` or `REQUEST_CHANGES`: `Earlier review from this account: changes requested on <short sha>; this review replaces it.` For `COMMENT`: `Earlier review from this account: changes requested on <short sha>; it stays in effect until this account approves or requests changes.` A `COMMENT` never replaces an earlier approval or request for changes, so the second tail is the true one there. If the user confirms a different event than the one proposed, re-render the line before the body is shown again. The line keeps the posting user's earlier objection visible. Also, even when every signal passes, the related issues lines from [github-io.md](github-io.md#what-it-renders): one per open issue that merging would not close, naming the exact text to add, or the single line saying why the check did not run. They describe the pull request, not the code, and never explain the verdict. Also, even when every signal passes, when the accepted check runs file the task names ([host-pass.md](host-pass.md#check-runs-file)) has an `own_check_dropped` above 0, one line, exactly ``Checks: the host's own check `<name>` excluded.``, with `<name>` the file's `own_check`. Also, even when every signal passes, when that file has an `own_jobs_dropped` above 0, one line, exactly ``Checks: the jobs of the host's own workflow runs excluded.`` When that file has `own_jobs_unreadable` true, one line, exactly ``Checks: the host's own jobs could not be read.`` When `check` rejected that file, one line, exactly ``Checks: the host's check runs file was rejected.``
7. **Existing threads.** Only when a thread is known to be unresolved. One line each: the path, the line, and whether this run returned a finding at the same path and line. Never the thread's body. A path and a line match mechanically; whether a thread and a finding mean the same thing is a judgement, and this skill makes none.
8. **Conversation comments.** A few lines, only when a conversation or bot comment was considered, something was omitted, or a note applies. Considered means selected: handed to the reviewer as a `kind=conversation` item, or a `kind=bot` item for the bot line. It says how many were considered, then lists the omissions and notes from [github-io.md](github-io.md#omissions-and-notes) as their fixed strings, a counted omission as `<category>:<n>`: `Conversation comments considered: 2. Not considered: over-size:1, minimized-excluded:3. Notes: instruction-like-text-from-others:1.` Bot comments get their own line in the same shape, after it, only when a bot comment was considered or a `bot-` category applies: `Bot comments considered: 3. Not considered: bot-over-size:1.` The notes go on the first line only. The two classes share one fetch, so a whole-class omission omits both and is one line in place of both: `Conversation and bot comments not considered: fetch-failed.` A note with a count is listed only when the count is at least 1. Never a comment's body or its author. The line records what the review saw; it is not a gap and never explains the verdict. When the reviewer's summary line carries `review.quoted-claim-unverifiable:<n>` with `<n>` at least 1, the section also carries this line, after the first one when that one appears: `Claims quoted from the discussion and not confirmed from the code: <n>.` The count covers claims from every item kind, not only conversation comments. It is parsed like the counted notes, decimal digits alone or the line is dropped, and it alone is enough for the section to appear. It names no claim, no path and no author. When a host renders a judgment run whose reply gave no counts, none of the count notes and no claims line appears, and the section ends with the one line `Counts: not reported by the review run.`, which alone is enough for the section to appear; a count is never shown as 0 in their place.

A pull request body also carries the What to do section, between sections 3 and 4, as [What to Do](#what-to-do) defines. It keeps the section numbers above unchanged.

Sections 1 to 3 carry no heading: the assessment and the rationale are paragraphs and the verdict line is bold. The What to do section and sections 4 to 8 each open with a `###` heading naming the section: `### What to do`, `### Findings`, `### Checks that could not run`, `### Pull request state`, `### Existing threads`, `### Conversation comments`. An omitted section drops its heading too. Where a section above says one line, it means the content under that heading. Inside section 4 each severity is a bold label on its own line, not a heading.

Nothing else. No checklist outside the What to do section, no emoji, no closing pleasantry, no offer to make the change.

## A Commit Target

A commit target, from [github-io.md](github-io.md#commit-target), renders the same order with three sections gone and two changed. Sections 6, 7 and 8 do not render, headings included: a commit has no pull request state, no review threads, and no conversation comments read as input. Section 2 uses the commit verdict lines in [verdict.md](verdict.md#absent-host-signals), which say nothing about merging, and names no clamp: every clamp that reaches a commit is render-only, and a render-only clamp is shown beside the body, never in it. Section 5 can never carry a thread resolution line, since no thread is read. No What to do section renders, heading included: it is for a pull request only. The assessment is addressed to the commit's author. The leak scan below runs before the body is shown, exactly as for a pull request.

## A Repository Target

A repository target, defined in [verdict.md](verdict.md#absent-host-signals), renders as a commit target does, with one difference: section 6 renders as one line under the heading `### Repository state`, in place of the pull request state:

`No host signals: this reviews a whole repository at <short sha>, with no pull request or commit, so the verdict comes from the findings alone (ladder rules 0 to 2, 4 and 6 to 8).`

A commit comment sits on its commit, so where it appears says what it reviewed. A repository review has no such place, so the line says it instead, and says why no check result, thread or review decision appears. Sections 7 and 8 do not render. No What to do section renders either, as for a commit. Section 5 carries no thread resolution line. The assessment is addressed to the module's author. The run is render-only, so no clamp appears in the body. The leak scan and the at-mention step run as for a pull request.

## What to Do

A pull request body carries `### What to do` after the rationale and before `### Findings`. It lists what would change the verdict. It is a total function of the ladder rule that fired, the host signals, the number of unresolved threads, and each finding's severity, `rule_id`, count and location. It reads no summary and no fix, except that item 5 below searches each fix for one fixed phrase. It never rewords a finding or a fix. It does not render for approve, ladder rule 8, and never for a commit or a repository target. It never collapses, and [Collapsing Findings](#collapsing-findings) does not count it.

A blocking group is a group of [Grouping Findings](#grouping-findings) whose severity is CRITICAL, HIGH or MEDIUM, whatever ladder rule fired. The disputed note forms no group here, and neither does a `review.*` rule, at any severity: those findings say how far the review reached, which the author cannot act on. They stay in section 4, and rule 4 counts them in item 6.

The section opens with one lead sentence chosen by the ladder rule, then one list. The leads are rows of [Host Render Strings](#host-render-strings): `todo-lead-block` for rules 1, 2, 3, 5 and 6, `todo-lead-4` for rule 4, `todo-lead-7` for rule 7, and `todo-lead-0` for rule 0. The items follow in this order, each from its row of that table:

1. The host signals: `todo-checks` when the Checks signal fails, `todo-mergeability` when Mergeability fails, and `todo-review-decision` when the Review decision fails.
2. The open threads, when at least one is unresolved: `todo-threads-one` for one, `todo-threads-many` for more.
3. The blocking groups, in the order of the findings: `todo-fix-one` for a group of one finding, `todo-fix-many` for more. Under rule 0 a group whose `rule_id` starts with `compat.` takes `todo-compat-one` or `todo-compat-many` instead. Then, when no `claim.*` finding at HIGH or above words it, one `todo-refuted` item per trigger the behaviour evidence refutes, with `{location}` and `{category}` as in section 5.
4. The LOW groups, in the order of the findings, in every verdict with a LOW finding: `todo-optional-one` and `todo-optional-many`.
5. Generated documentation: `todo-generated`, once, when a fix names generated content, as below.
6. Rule 4 only: `todo-triage` in a triage run. Then `todo-checks-unknown`, `todo-threads-unknown`, `todo-review-decision-unknown` and `todo-mergeability-unknown`, each when its signal is unknown. Then `todo-gaps-one` or `todo-gaps-many` when its `{count}` is above 0. It counts every `review.*` finding but the disputed note, every `could_not_run` entry but `thread-resolution-unknown`, which `todo-threads-unknown` covers, every example directory that did not verify and, for a change that is not inert, every example not planned, those past the first 100 included, and each unverified trigger and claim, each trigger over the cap, and a behaviour step that did not run, once.

An item opens with `- [ ] ` on items 1 and 2, on item 3 except a `todo-compat-*` one, and on item 5 when items 1 to 3 hold at least one `- [ ] ` item. Every other item opens with `- `.

In items 3 and 4, `{rule_id}` is the group's rule and `{count}` the number of its findings. `{locations}` lists every location of the group, its entries expanded in order, each in its own code span as section 4 writes it, separated by a comma and a space. A null line shows the path alone. Past eight locations, the first eight are listed and `todo-more` follows with the count of the rest.

Item 5 searches the `suggested_fix` of every finding for the fixed phrase `Generated content made stale:` of the [Suggested Fix Contract](../../terraform-module-reviewer/references/findings-schema.md#suggested-fix-contract). An occurrence is suppressed when the text after its colon is one space and a lowercase `none`, then a period, a comma or the end of the fix. The item renders when at least one occurrence is not suppressed. So `none`, `none.` and `none, the directory has no README.md.` add nothing, while `None`, `none of` and `nonempty` add the item.

The ladder makes four things hold, which the renderer does not check and `tests/render-comment-test.sh` does: every block verdict and rule 5 have a `- [ ] ` item, rule 7 has only LOW findings, rule 8 has no finding open, and rule 0 has a `compat.*` group. The first has one exception: a block whose only CRITICAL, HIGH or MEDIUM findings carry a `review.*` rule, such as `review.untrusted-instruction` or `review.path-missing`, has no item, and the section is its lead alone.

## Grouping Findings

A large change returns one rule many times, once per file or per line. One line per finding repeats the `rule_id` and buries the findings that differ. Grouping folds the repeats. It is a total function of the reviewer's findings list: the same list always renders the same lines, and nothing outside the list is read.

It runs after the verdict is computed and changes neither the verdict nor the finding set. The verdict is computed from the list, never from the render, and every finding appears in the render exactly once, at its own location.

Within one severity:

1. Findings with the same `rule_id` form one group. Groups are ordered by the position of their first finding in the reviewer's order.
2. Inside a group, findings whose summaries are identical byte for byte, and whose `suggested_fix` values are too, form one entry. An entry lists the location of each of its findings, `path:line` or the path alone for a null line, each in its own code span, separated by a comma and a space, in the reviewer's order. Entries are ordered by their first finding.
3. A group of one finding renders as one line: ``- `rule_id` - <location> - <summary>``.
4. A group of several findings and one entry renders as one line: ``- `rule_id` (<n>) - <locations> - <summary>``, where `<n>` is the number of findings in the group.
5. A group with several entries renders as ``- `rule_id` (<n>):``, then one nested line per entry, indented two spaces: `  - <locations> - <summary>`.
6. Every entry's line is followed by its Fix line, one level deeper: `  - Fix: <suggested_fix>` under a line of rule 3 or 4, and `    - Fix: <suggested_fix>` under a nested entry of rule 5. It is a list item of its own so that it renders on its own line; an indented line of plain text would join the summary's paragraph. Rule 7 is the one exception.
7. A group of rule 5 with three or more entries keeps its entry lines and moves their Fix lines into one block under the group: a blank line, `<details><summary>Fix for each location (<n>)</summary>`, a blank line, one line per entry in entry order, `- <locations> - Fix: <suggested_fix>`, a blank line, then `</details>`. `<n>` is the number of findings in the group, and the summary text is the `fix-fold` row of [Host Render Strings](#host-render-strings). A blank line separates the block from what follows. A group of one or two entries keeps its nested Fix lines. So does any group where a summary, a `suggested_fix` or a location contains `<details` or `</details` in any case, or a newline, since that text could close the block early or open another.

In these forms the separators are a space, a hyphen and a space, `<locations>` is the entry's list from rule 2, `<summary>` is the reviewer's summary, unchanged, and `<suggested_fix>` is the reviewer's `suggested_fix`, unchanged, a `needs decision:` or `no code change:` prefix included. The prefix is what tells a reader, and the maintainer skill, that a person has to choose or that no file changes.

Nothing else merges. Findings of different severities never share a line. Summaries that differ in any character stay apart, and so do identical summaries whose fixes differ, and each is shown in full: none is shortened, reworded, or picked over another. Deciding that two summaries mean the same thing would be a judgement, and this skill makes none. A summary that names its own path therefore never merges with its siblings. That costs length and keeps every rendered word the reviewer's.

Grouping removes repetition, not words. Most of the length of a large review is in the summaries, which are the reviewer's and stay verbatim.

### Example: pull request 410

The first render of terraform-aws-modules/terraform-aws-s3-bucket pull request 410 listed 30 findings (3 HIGH, 16 MEDIUM, 11 LOW), one line each, in a body of about 8 KB. The verdict was block at ladder rule 2 and stays block: grouping reads the same 30 findings and the verdict never reads the render. Counts for the list lines of each section, severity label excluded:

| Section | Findings | Lines before | Lines after, top level / total | Bytes before | Bytes after |
|---|---|---|---|---|---|
| HIGH | 3 | 3 | 2 / 4 | 1239 | 1213 |
| MEDIUM | 16 | 16 | 8 / 19 | 4196 | 3988 |
| LOW | 11 | 11 | 5 / 9 | 2080 | 1544 |

This example and the collapsed one below record run 1's render as measured, before the Fix line existed. That run kept no `suggested_fix`, so their Fix lines are left out rather than written after the fact, and so are the Fix blocks of grouping rule 7, which hold only Fix lines. Run 1 also predates the [What to Do](#what-to-do) section, so the collapsed body has none, and the counts are that render's. [Example: Fix lines](#example-fix-lines) shows the line itself.

`compat.provider-floor-raised` shows both forms of merge. Five of its six findings carry the same summary and become one entry with five locations. The sixth, at `versions.tf:7`, words its summary differently and stays a separate entry. `structure.comment-unsourced` has five findings and five different summaries, so it gains one line and loses four repeated `rule_id` values, and every summary stays.

Before, MEDIUM and LOW as rendered:

```markdown
**MEDIUM**

- `review.check-not-run` - `.` - Check B, and Check A's comparison at the old floor 6.42, did not run on `aws_s3_bucket`, `aws_s3_directory_bucket`, `aws_s3_bucket_analytics_configuration` and the root's `aws_caller_identity`, `aws_partition` and `aws_region` data sources, because their schemas were not fetched in this run.
- `review.check-not-run` - `examples/file-system` - Check B did not run on the `aws_availability_zones` data source, because its schema was not fetched in this run.
- `structure.comment-unsourced` - `examples/file-system/main.tf:125` - The comment that file data is always served from S3 asserts service behaviour with no link to an official source and no date.
- `structure.copied-content-unattributed` - `examples/file-system/main.tf:260` - The literal service principal `lambda.amazonaws.com` at line 260 and the `s3files:ClientRootAccess` statement at line 289 carry no comment naming a source URL and a date.
- `examples.feature-undemonstrated` - `examples/file-system/main.tf` - `aws_iam_role_policy_attachment` and `aws_vpc_security_group_egress_rule` in `modules/file-system` are created by no example, because no example sets `iam_role_policies` or any egress rule.
- `structure.comment-unsourced` - `main.tf:1579` - The comment that S3 Files supports general purpose buckets only asserts a service limitation with no link to an official source and no date.
- `review.check-not-run` - `modules/file-system` - Check B, and Check A's comparison at the old floor 6.42, did not run on `aws_iam_role`, `aws_iam_role_policy`, `aws_iam_role_policy_attachment`, `aws_security_group`, `aws_vpc_security_group_ingress_rule`, `aws_vpc_security_group_egress_rule`, the `aws_service_principal`, `aws_caller_identity`, `aws_partition` and `aws_region` data sources, or on four `aws_s3files_*` types at 6.42, because those schemas were not fetched in this run.
- `scope.new-submodule` - `modules/file-system` - The new directory `modules/file-system` manages `aws_s3files_file_system`, `aws_s3files_mount_target`, `aws_s3files_access_point`, `aws_s3files_file_system_policy` and `aws_s3files_synchronization_configuration`, which are neither adjunct types nor allowed by a `docs/SCOPE.md`, since the base has none.
- `structure.comment-unsourced` - `modules/file-system/main.tf:59` - New comments at lines 59, 78, 91, 219, 302, 346, 551 and 590 assert service behaviour, such as directory buckets being unsupported, the default VPC fallback and AWS rejecting an empty policy, with no link to an official source and no date.
- `structure.copied-content-unattributed` - `modules/file-system/main.tf:153` - The role's permissions document reproduces AWS's published inline policy, including the `DO-NOT-DELETE-S3-Files*` rule name, and the comment at line 258 names the source URL but no date.
- `coverage.attribute-not-output` - `modules/file-system/outputs.tf` - No output exposes `aws_s3files_synchronization_configuration`, so its computed `latest_version_number` is unreachable to callers.
- `structure.comment-unsourced` - `modules/file-system/variables.tf:80` - Comments at lines 80 and 379 assert service behaviour, that S3 Files checks role permissions at creation and that the API takes exactly one expiration rule, with no source and no date; the provider documents `expiration_data_rule` as Optional at 6.44.0 and 6.66.0.
- `structure.flag-polarity` - `modules/file-system/variables.tf:334` - `create_policy` is a new `create_*` boolean that defaults to `false`.
- `review.check-not-run` - `modules/table-bucket` - Check A's reading of the changed default `resources` in the table bucket policy did not use the `aws_s3tables_table_bucket` schema, because it was not fetched in this run.
- `structure.comment-unsourced` - `variables.tf:799` - Comments in the `file_systems` type at lines 799 and 924 assert service behaviour with no link to an official source and no date.
- `structure.passthrough-field-drift` - `variables.tf:850` - The `mount_targets` object in `file_systems` has no `security_groups` attribute, while `modules/file-system/variables.tf:183` declares `security_groups` on each mount target, so no root caller can set security groups per mount target.

**LOW**

- `coverage.enum-value-unknown` - `examples/file-system/main.tf:76` - `trigger = "ON_DIRECTORY_FIRST_ACCESS"` at lines 76 and 129 is outside the documented value set `ON_FILE_ACCESS` at 6.44.0 and 6.66.0; either the example or the provider documentation is stale.
- `examples.argument-undemonstrated` - `examples/file-system/main.tf` - No example sets several new `file_systems` attributes, for example `kms_key_id`, `accept_bucket_warning`, `iam_role_kms_key_arns` and `create_iam_role = false`.
- `compat.provider-floor-raised` - `modules/account-public-access/versions.tf:7` - The AWS provider floor moves from 6.42 to 6.44, and this directory uses nothing new.
- `structure.argument-order` - `modules/file-system/main.tf:37` - `tags` precedes the `dynamic "timeouts"` block in `aws_s3files_file_system.this` and, at line 437, in `aws_s3files_access_point.this`.
- `profile.unrelated-change-bundled` - `modules/notification/main.tf:1` - Under a `feat` title, `data "aws_partition" "this"` gains a `count` in a directory that takes no part in the file system feature.
- `compat.provider-floor-raised` - `modules/notification/versions.tf:7` - The AWS provider floor moves from 6.42 to 6.44, and this directory uses nothing new.
- `compat.provider-floor-raised` - `modules/object/versions.tf:7` - The AWS provider floor moves from 6.42 to 6.44, and this directory uses nothing new.
- `profile.unrelated-change-bundled` - `modules/table-bucket/main.tf:32` - Under a `feat` title, the default `resources` of the table bucket policy changes in a directory that takes no part in the file system feature.
- `compat.provider-floor-raised` - `modules/table-bucket/versions.tf:7` - The AWS provider floor moves from 6.42 to 6.44, and this directory uses nothing new.
- `compat.provider-floor-raised` - `modules/vectors/versions.tf:7` - The AWS provider floor moves from 6.42 to 6.44, and this directory uses nothing new.
- `compat.provider-floor-raised` - `versions.tf:7` - The AWS provider floor moves from 6.42 to 6.44; every `aws_s3files_*` type the change uses already exists at 6.42.
```

After, the same findings grouped:

```markdown
**MEDIUM**

- `review.check-not-run` (4):
  - `.` - Check B, and Check A's comparison at the old floor 6.42, did not run on `aws_s3_bucket`, `aws_s3_directory_bucket`, `aws_s3_bucket_analytics_configuration` and the root's `aws_caller_identity`, `aws_partition` and `aws_region` data sources, because their schemas were not fetched in this run.
  - `examples/file-system` - Check B did not run on the `aws_availability_zones` data source, because its schema was not fetched in this run.
  - `modules/file-system` - Check B, and Check A's comparison at the old floor 6.42, did not run on `aws_iam_role`, `aws_iam_role_policy`, `aws_iam_role_policy_attachment`, `aws_security_group`, `aws_vpc_security_group_ingress_rule`, `aws_vpc_security_group_egress_rule`, the `aws_service_principal`, `aws_caller_identity`, `aws_partition` and `aws_region` data sources, or on four `aws_s3files_*` types at 6.42, because those schemas were not fetched in this run.
  - `modules/table-bucket` - Check A's reading of the changed default `resources` in the table bucket policy did not use the `aws_s3tables_table_bucket` schema, because it was not fetched in this run.
- `structure.comment-unsourced` (5):
  - `examples/file-system/main.tf:125` - The comment that file data is always served from S3 asserts service behaviour with no link to an official source and no date.
  - `main.tf:1579` - The comment that S3 Files supports general purpose buckets only asserts a service limitation with no link to an official source and no date.
  - `modules/file-system/main.tf:59` - New comments at lines 59, 78, 91, 219, 302, 346, 551 and 590 assert service behaviour, such as directory buckets being unsupported, the default VPC fallback and AWS rejecting an empty policy, with no link to an official source and no date.
  - `modules/file-system/variables.tf:80` - Comments at lines 80 and 379 assert service behaviour, that S3 Files checks role permissions at creation and that the API takes exactly one expiration rule, with no source and no date; the provider documents `expiration_data_rule` as Optional at 6.44.0 and 6.66.0.
  - `variables.tf:799` - Comments in the `file_systems` type at lines 799 and 924 assert service behaviour with no link to an official source and no date.
- `structure.copied-content-unattributed` (2):
  - `examples/file-system/main.tf:260` - The literal service principal `lambda.amazonaws.com` at line 260 and the `s3files:ClientRootAccess` statement at line 289 carry no comment naming a source URL and a date.
  - `modules/file-system/main.tf:153` - The role's permissions document reproduces AWS's published inline policy, including the `DO-NOT-DELETE-S3-Files*` rule name, and the comment at line 258 names the source URL but no date.
- `examples.feature-undemonstrated` - `examples/file-system/main.tf` - `aws_iam_role_policy_attachment` and `aws_vpc_security_group_egress_rule` in `modules/file-system` are created by no example, because no example sets `iam_role_policies` or any egress rule.
- `scope.new-submodule` - `modules/file-system` - The new directory `modules/file-system` manages `aws_s3files_file_system`, `aws_s3files_mount_target`, `aws_s3files_access_point`, `aws_s3files_file_system_policy` and `aws_s3files_synchronization_configuration`, which are neither adjunct types nor allowed by a `docs/SCOPE.md`, since the base has none.
- `coverage.attribute-not-output` - `modules/file-system/outputs.tf` - No output exposes `aws_s3files_synchronization_configuration`, so its computed `latest_version_number` is unreachable to callers.
- `structure.flag-polarity` - `modules/file-system/variables.tf:334` - `create_policy` is a new `create_*` boolean that defaults to `false`.
- `structure.passthrough-field-drift` - `variables.tf:850` - The `mount_targets` object in `file_systems` has no `security_groups` attribute, while `modules/file-system/variables.tf:183` declares `security_groups` on each mount target, so no root caller can set security groups per mount target.

**LOW**

- `coverage.enum-value-unknown` - `examples/file-system/main.tf:76` - `trigger = "ON_DIRECTORY_FIRST_ACCESS"` at lines 76 and 129 is outside the documented value set `ON_FILE_ACCESS` at 6.44.0 and 6.66.0; either the example or the provider documentation is stale.
- `examples.argument-undemonstrated` - `examples/file-system/main.tf` - No example sets several new `file_systems` attributes, for example `kms_key_id`, `accept_bucket_warning`, `iam_role_kms_key_arns` and `create_iam_role = false`.
- `compat.provider-floor-raised` (6):
  - `modules/account-public-access/versions.tf:7`, `modules/notification/versions.tf:7`, `modules/object/versions.tf:7`, `modules/table-bucket/versions.tf:7`, `modules/vectors/versions.tf:7` - The AWS provider floor moves from 6.42 to 6.44, and this directory uses nothing new.
  - `versions.tf:7` - The AWS provider floor moves from 6.42 to 6.44; every `aws_s3files_*` type the change uses already exists at 6.42.
- `structure.argument-order` - `modules/file-system/main.tf:37` - `tags` precedes the `dynamic "timeouts"` block in `aws_s3files_file_system.this` and, at line 437, in `aws_s3files_access_point.this`.
- `profile.unrelated-change-bundled` (2):
  - `modules/notification/main.tf:1` - Under a `feat` title, `data "aws_partition" "this"` gains a `count` in a directory that takes no part in the file system feature.
  - `modules/table-bucket/main.tf:32` - Under a `feat` title, the default `resources` of the table bucket policy changes in a directory that takes no part in the file system feature.
```

### Example: Fix lines

From a review of a new module contribution, five of its findings, rendered with their Fix lines. The two `scope.profile-file` findings share a fix and not a summary, so they stay two entries of one group, each with its own Fix line. Every fix is the reviewer's text as returned, from before the [Suggested Fix Contract](../../terraform-module-reviewer/references/findings-schema.md#suggested-fix-contract), so the flag-polarity fix offers two changes without the `needs decision:` prefix the contract now asks for. The render shows a fix as it is and never rewrites it.

```markdown
**HIGH**

- `scope.profile-file` (2):
  - `.github/workflows/security.yml` - New workflow file running Trivy, Checkov and Gitleaks; the profile's workflow set is exactly the five templates.
    - Fix: Remove the workflow.
  - `.github/workflows/test.yml` - New workflow file running Terraform native tests; the profile's workflow set is exactly the five templates.
    - Fix: Remove the workflow.

**MEDIUM**

- `structure.comment-redundant` - `main.tf:7` - The comment at line 7 restates the conditional on the next line.
  - Fix: Remove the comment.
- `coverage.attribute-not-output` - `outputs.tf` - No output exposes the created role's `unique_id`, a stable computed attribute of `aws_iam_role`.
  - Fix: Add an `iam_role_unique_id` output with a `try()` fallback.
- `structure.flag-polarity` - `variables.tf:200` - `create_air_gapped_vault` is a `create_*` boolean that defaults to `false`.
  - Fix: Rename it to `enable_air_gapped_vault`, since the air-gapped vault is opt in, or default it to `true`.
```

## Collapsing Findings

Grouping still leaves a large review long, because the length is in the summaries. Collapsing keeps every CRITICAL and HIGH finding on screen and folds the rest under one line per rule that a reader can open. It is a total function of the reviewer's findings list and of the ladder rule that produced the verdict, which it reads and never changes. It runs after grouping and changes neither the verdict nor the finding set: every finding is still in the body, and the verdict is computed from the list, never from the render.

It applies only when the list holds more than 10 findings. A `review.tool-disputed` finding is not counted, and no rule below applies to it: it always renders in full under its own label, as [Section Order](#section-order) section 4 says. At 10 or fewer, every group renders in full as [Grouping Findings](#grouping-findings) defines.

Above 10, the first of these rules that matches decides how a group renders:

1. In full, when its severity is CRITICAL or HIGH.
2. When its `rule_id` is `review.check-not-run`: in full if the verdict came from ladder rule 4, collapsed otherwise. Under rule 4 these findings may be why the review is inconclusive, and the reader needs them on screen. Otherwise they describe how far the review could reach, which the change's author cannot act on.
3. In full, when its severity is the highest present in the list. Those findings produced the verdict.
4. Collapsed.

A group in full keeps the Fix block of [Grouping Findings](#grouping-findings) rule 7. A collapsed group renders as a block:

```markdown
<details><summary><code>rule_id</code> (<n>)</summary>

- <locations> - <summary>
  - Fix: <suggested_fix>

</details>
```

The block holds one `- <locations> - <summary>` line per entry of the group, built as grouping rule 2 builds entries, each followed by its Fix line, so collapsing hides a fix only until the block is opened, and `<n>` is the number of findings in the group, 1 included. The summary element uses a `<code>` element, not backticks, because the host does not render Markdown inside it. The blank line after the `<summary>` line and the one before `</details>` are required for the lines between them to render as a list. Groups in one severity are separated by one blank line. The severity label stays visible above its groups, collapsed or not.

Collapsed means hidden until opened, not removed. The leak scan and the at-mention step run over the whole body, collapsed blocks and Fix lines included.

### Example: pull request 410 collapsed

Run 1 listed 30 findings, so collapsing applies. HIGH is the highest severity present, so the three HIGH findings stay in full, the four `review.check-not-run` findings fold under one line, and every other MEDIUM and LOW group folds under its own line. The verdict is still block at ladder rule 2.

Counts for the whole body. Visible lines are the non-blank Markdown lines outside a `<details>` block, each `<summary>` line counted once. Visible bytes are the bytes of the body less the lines a `<details>` block hides.

| Render | Bytes | Visible lines | Visible bytes |
|---|---|---|---|
| Run 1 as rendered | 8251 | 39 | 8251 |
| Grouped | 7481 | 41 | 7481 |
| Grouped and collapsed | 8139 | 26 | 2918 |

Run 1's MEDIUM and LOW sections as rendered are in the grouping example above. Its HIGH section is the same three findings one line each, and every other part of its body is the same text as below. After, the whole body:

```markdown
The change adds Amazon S3 Files support through a new `modules/file-system` submodule and the root `file_systems` input, and the overall shape looks right. What is missing: the new example cannot plan because one access point has no POSIX user, and two documented behaviours have no code behind them. A file system policy built only from source documents is rejected, and setting `security_groups` does not stop a security group being created. `examples/file-system` passed `terraform init` and `terraform validate`; no `plan` was run.

**Changes requested before merge.**

Three HIGH findings are open. Any HIGH finding blocks merge (ladder rule 2).

### Findings

**HIGH**

- `examples.example-broken` - `examples/file-system/main.tf:111` - Access point `reports` in the `agents` file system sets no `posix_user`, which `aws_s3files_access_point` marks Required at 6.44.0 and 6.66.0, so the module renders no `posix_user` block and the example cannot plan. `terraform validate` passed because it does not expand the `dynamic` block; this conclusion is read from the files and the provider documentation, not verified by a plan.
- `structure.docs-contradict-code` (2):
  - `modules/file-system/main.tf:593` - `source_policy_documents` and `override_policy_documents` are documented as merged into the file system policy, but the precondition counts only the `statement` blocks of `data.aws_iam_policy_document.policy`, which never include merged documents, so `create_policy = true` with only those inputs fails at plan.
  - `variables.tf:939` - The `create_file_system_security_group` description says a file system that sets its own `security_groups` never creates a group, but `create_security_group` is forwarded without reading `security_groups`, so a group is still created, and the `security_group_vpc_id` precondition at `modules/file-system/main.tf:348` fails when no VPC is set.

**MEDIUM**

<details><summary><code>review.check-not-run</code> (4)</summary>

- `.` - Check B, and Check A's comparison at the old floor 6.42, did not run on `aws_s3_bucket`, `aws_s3_directory_bucket`, `aws_s3_bucket_analytics_configuration` and the root's `aws_caller_identity`, `aws_partition` and `aws_region` data sources, because their schemas were not fetched in this run.
- `examples/file-system` - Check B did not run on the `aws_availability_zones` data source, because its schema was not fetched in this run.
- `modules/file-system` - Check B, and Check A's comparison at the old floor 6.42, did not run on `aws_iam_role`, `aws_iam_role_policy`, `aws_iam_role_policy_attachment`, `aws_security_group`, `aws_vpc_security_group_ingress_rule`, `aws_vpc_security_group_egress_rule`, the `aws_service_principal`, `aws_caller_identity`, `aws_partition` and `aws_region` data sources, or on four `aws_s3files_*` types at 6.42, because those schemas were not fetched in this run.
- `modules/table-bucket` - Check A's reading of the changed default `resources` in the table bucket policy did not use the `aws_s3tables_table_bucket` schema, because it was not fetched in this run.

</details>

<details><summary><code>structure.comment-unsourced</code> (5)</summary>

- `examples/file-system/main.tf:125` - The comment that file data is always served from S3 asserts service behaviour with no link to an official source and no date.
- `main.tf:1579` - The comment that S3 Files supports general purpose buckets only asserts a service limitation with no link to an official source and no date.
- `modules/file-system/main.tf:59` - New comments at lines 59, 78, 91, 219, 302, 346, 551 and 590 assert service behaviour, such as directory buckets being unsupported, the default VPC fallback and AWS rejecting an empty policy, with no link to an official source and no date.
- `modules/file-system/variables.tf:80` - Comments at lines 80 and 379 assert service behaviour, that S3 Files checks role permissions at creation and that the API takes exactly one expiration rule, with no source and no date; the provider documents `expiration_data_rule` as Optional at 6.44.0 and 6.66.0.
- `variables.tf:799` - Comments in the `file_systems` type at lines 799 and 924 assert service behaviour with no link to an official source and no date.

</details>

<details><summary><code>structure.copied-content-unattributed</code> (2)</summary>

- `examples/file-system/main.tf:260` - The literal service principal `lambda.amazonaws.com` at line 260 and the `s3files:ClientRootAccess` statement at line 289 carry no comment naming a source URL and a date.
- `modules/file-system/main.tf:153` - The role's permissions document reproduces AWS's published inline policy, including the `DO-NOT-DELETE-S3-Files*` rule name, and the comment at line 258 names the source URL but no date.

</details>

<details><summary><code>examples.feature-undemonstrated</code> (1)</summary>

- `examples/file-system/main.tf` - `aws_iam_role_policy_attachment` and `aws_vpc_security_group_egress_rule` in `modules/file-system` are created by no example, because no example sets `iam_role_policies` or any egress rule.

</details>

<details><summary><code>scope.new-submodule</code> (1)</summary>

- `modules/file-system` - The new directory `modules/file-system` manages `aws_s3files_file_system`, `aws_s3files_mount_target`, `aws_s3files_access_point`, `aws_s3files_file_system_policy` and `aws_s3files_synchronization_configuration`, which are neither adjunct types nor allowed by a `docs/SCOPE.md`, since the base has none.

</details>

<details><summary><code>coverage.attribute-not-output</code> (1)</summary>

- `modules/file-system/outputs.tf` - No output exposes `aws_s3files_synchronization_configuration`, so its computed `latest_version_number` is unreachable to callers.

</details>

<details><summary><code>structure.flag-polarity</code> (1)</summary>

- `modules/file-system/variables.tf:334` - `create_policy` is a new `create_*` boolean that defaults to `false`.

</details>

<details><summary><code>structure.passthrough-field-drift</code> (1)</summary>

- `variables.tf:850` - The `mount_targets` object in `file_systems` has no `security_groups` attribute, while `modules/file-system/variables.tf:183` declares `security_groups` on each mount target, so no root caller can set security groups per mount target.

</details>

**LOW**

<details><summary><code>coverage.enum-value-unknown</code> (1)</summary>

- `examples/file-system/main.tf:76` - `trigger = "ON_DIRECTORY_FIRST_ACCESS"` at lines 76 and 129 is outside the documented value set `ON_FILE_ACCESS` at 6.44.0 and 6.66.0; either the example or the provider documentation is stale.

</details>

<details><summary><code>examples.argument-undemonstrated</code> (1)</summary>

- `examples/file-system/main.tf` - No example sets several new `file_systems` attributes, for example `kms_key_id`, `accept_bucket_warning`, `iam_role_kms_key_arns` and `create_iam_role = false`.

</details>

<details><summary><code>compat.provider-floor-raised</code> (6)</summary>

- `modules/account-public-access/versions.tf:7`, `modules/notification/versions.tf:7`, `modules/object/versions.tf:7`, `modules/table-bucket/versions.tf:7`, `modules/vectors/versions.tf:7` - The AWS provider floor moves from 6.42 to 6.44, and this directory uses nothing new.
- `versions.tf:7` - The AWS provider floor moves from 6.42 to 6.44; every `aws_s3files_*` type the change uses already exists at 6.42.

</details>

<details><summary><code>structure.argument-order</code> (1)</summary>

- `modules/file-system/main.tf:37` - `tags` precedes the `dynamic "timeouts"` block in `aws_s3files_file_system.this` and, at line 437, in `aws_s3files_access_point.this`.

</details>

<details><summary><code>profile.unrelated-change-bundled</code> (2)</summary>

- `modules/notification/main.tf:1` - Under a `feat` title, `data "aws_partition" "this"` gains a `count` in a directory that takes no part in the file system feature.
- `modules/table-bucket/main.tf:32` - Under a `feat` title, the default `resources` of the table bucket policy changes in a directory that takes no part in the file system feature.

</details>

### Conversation comments

Conversation comments considered: 1.
```

The conversation section is shown as run 1 rendered it. Run 1 predates the unconfirmed-claims count, so its second line is absent.

## Voice

The body is posted under a person's name, so it has to read like that person wrote it. These rules apply to the prose this skill writes: the assessment, the verdict line and the rationale.

- Short, direct sentences. Plain ASCII: no em or en dashes, no curly quotes, no ellipsis character.
- No forced triads. List two things when there are two.
- The rationale states the fact the verdict rests on, then the ladder rule in plain words with its number, and stops. It does not repeat the verdict line.
- No "not X but Y" contrasts, and no one-line closers that sum up what was already said.
- No stock AI words: crucial, robust, seamless, leverage, delve, comprehensive, and the like.
- The verdict line and the rationale stay plain: no praise, no thanks.
- The assessment may be warm and specific about the change in front of it. Inflated praise and thanks-for-your-contribution boilerplate stay out of it.
- No emoji anywhere in the body.

Apply these rules to the assessment, the verdict line and the rationale before the leak scan. Applying them inline while writing counts; running a separate humanizer skill over the same three parts, if one is installed, is optional. Finding summaries are the reviewer's and stay verbatim. Code spans, `rule_id` values and paths stay unchanged.

A finding summary is the reviewer's own words about the code and never reproduces text quoted from the pull request, so a summary that quotes discussion is a defect in the finding, not something to render.

## Leak Scan

Run this over the body **before it is shown**, not merely before it is posted. Once a path is on the screen it is one copy and paste from being public. A match blocks both: the body is not shown and not sent.

Scan for a named set. Scanning for every environment value instead would match on a single digit, because a typical environment holds `SHLVL=1`, and nothing could ever pass.

- The run directory, which holds the clone and the plugin cache, and the values of `HOME`, `PWD` and `TMPDIR`.
- Any absolute path beginning `/home/`, `/Users/`, `/tmp/` or `/var/folders/`.
- The value of any environment variable at least 12 characters long whose name matches `*TOKEN*`, `*KEY*`, `*SECRET*`, `*PASSWORD*` or `*PAT*`.
- The literal token shapes `ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_` and `github_pat_`.
- When the plan pass ran, the credential shapes of its [evidence contract](plan-pass.md#evidence-contract): `(AKIA|ASIA)[A-Z0-9]{16}`, `eyJ` JSON web tokens, `-----BEGIN`, `X-Amz-Signature` and `Authorization:`. The exact credential values are not scanned for here: they exist only inside the plan pass's own shell, which has ended by this step, and the pass checked every line it kept against them before the line left it. The contract's base64 run of 40 or more characters is not scanned for in the body: a 40-character commit SHA or a documentation URL path would match it and block every render, and each kept line in the body already passed it. The GitHub CLI usually keeps its token in a `hosts.yml` rather than the environment, so the shapes catch what the variable names miss.

When the plan pass ran in runner mode, as section 1 defines it, also search the body for each `code-error` kept line of that pass, whole and without its leading `Error: `, and for every maximal run of non-whitespace characters in that line that is 16 characters or longer. A match of either blocks the render the same way, and the fix is a finding that names the class instead. The control is the rule in section 1 that a finding names the class; this search is only the backstop for a quote that slipped through, and a fragment shorter than 16 characters passes it.

A match is reported as a bug in the render: say which pattern matched and where the text came from. Do not quietly strip the string and continue - a path in the body means something upstream is putting local state into findings, and that is worth knowing.

## At-mentions

Finding summaries are rendered verbatim, and an at-sign can still reach the body through one, through a path, or through a code span. A quoted `@org/team` notifies a whole team that never asked.

Before the body is shown, wrap every at-mention that is not already inside a code span in backticks: an at-sign followed by a name character, anywhere in the body. This neutralizes rather than blocks, because a path or a code span can legitimately contain one, and a blocked render would help nobody.

## Host Render Strings

A host may render the body with no model, from the merged findings and its own records: [render-comment.sh](render-comment.sh). Its fixed sentences are these, exactly, and `tests/render-comment-test.sh` checks that the script's strings equal this table. A word in braces is filled in: `{severity}` and `{rule}` from the verdict, `{count}` a number, spelled `Two` to `Ten` in a rationale and in digits elsewhere, `{signals}` the failing signal names joined with `, ` and a final ` and `, `{path}` and `{dir}` repository-relative, `{reason}` the verification reason of section 5 with `init` in a code span, `{location}` a thread's path, with `:` and its line when it has one, `{rule_id}` a group's `rule_id`, and `{locations}` a group's locations as [What to Do](#what-to-do) lists them. The `todo-*` rows are the What to do section, each item without its `- [ ] ` or `- ` opener, and `fix-fold` is the summary of the Fix block of [Grouping Findings](#grouping-findings) rule 7.

The rationale of section 3 takes one row per ladder rule. Rule 4 takes the row of the first unknown in this order: a triage run, the Checks, Threads, Review decision and Mergeability signals, a `review.no-change-identified` finding, a `review.check-not-run` finding, a `review.verification-incomplete` finding, then the lines of section 5. Rule 2 takes `rationale-2-refuted` when a refuted behaviour state alone fired it. Rule 3 names every failing signal. The signal line of section 6 joins the Checks, Mergeability, Review decision and Threads phrases with a space, in that order. Section 5 takes one row per `could_not_run` kind of [host-pass.md](host-pass.md#host-facts) and one `verification` row per example directory that did not verify, for the first 100 of them, then one `verification-more` row with the count of the rest, then, when the change is inert and an example was not planned, the `unplanned-inert` row, then one `unplanned` row per example of the run file's `coverage.unplanned`, or the `unplanned-no-examples` row for its one entry when the module has no example directory, for the first 100, then one `unplanned-more` row with the count of the rest, so the section stays bounded. The behaviour rows follow: `behaviour-not-run`, or `behaviour-trigger` per unverified trigger, then `behaviour-capped` when triggers were over the cap, then `behaviour-claim` per unverified claim, at most 40 and 20 of them by the run object's grammar. A run file with no behaviour object, outside a triage run, is a step the host did not run: `behaviour-not-run` with `{reason}` `not run by the host`. In `behaviour-trigger`, `{location}` is the trigger's file, repository-relative, with `:` and its line when it has one, and `{category}` its classifier category; in `behaviour-not-run`, `{reason}` is the run object's reason. `behaviour-evidence` is the paragraph section 3 adds. Section 7 takes one row per unresolved thread.

| Key | Text |
|-----|------|
| `rationale-0` | The only CRITICAL and HIGH findings carry a `compat.*` rule_id. When only breaking-change findings block, the change waits for the next major release (ladder rule 0). |
| `rationale-open-one` | A {severity} finding is open. Any {severity} finding blocks merge (ladder rule {rule}). |
| `rationale-open-many` | {count} {severity} findings are open. Any {severity} finding blocks merge (ladder rule {rule}). |
| `rationale-2-refuted` | The behaviour evidence refutes a change or a claim of the description. Refuted behaviour blocks merge (ladder rule 2). |
| `rationale-3-one` | Failing host signal: {signals}. A failing host signal blocks merge (ladder rule 3). |
| `rationale-3-many` | Failing host signals: {signals}. A failing host signal blocks merge (ladder rule 3). |
| `rationale-4-triage` | A triage run leaves its deferred checks unknown. Any unknown makes the review inconclusive (ladder rule 4). |
| `rationale-4-checks` | The check results could not be read, so a failing check may exist. Any unknown makes the review inconclusive (ladder rule 4). |
| `rationale-4-threads` | Review thread resolution could not be read, so an open objection may exist. Any unknown makes the review inconclusive (ladder rule 4). |
| `rationale-4-review-decision` | The reviews could not be read, so a request for changes may exist. Any unknown makes the review inconclusive (ladder rule 4). |
| `rationale-4-mergeability` | Mergeability could not be read, so a merge conflict may exist. Any unknown makes the review inconclusive (ladder rule 4). |
| `rationale-4-no-change` | The workspace did not hold the change. Any unknown makes the review inconclusive (ladder rule 4). |
| `rationale-4-check-not-run` | A check did not run, so a defect it covers may be open. Any unknown makes the review inconclusive (ladder rule 4). |
| `rationale-4-verification-incomplete` | The behaviour evidence handed to the review was incomplete, so a behaviour change may be unchecked. Any unknown makes the review inconclusive (ladder rule 4). |
| `rationale-4-listed` | A check this review needs could not run, as listed below. Any unknown makes the review inconclusive (ladder rule 4). |
| `rationale-5` | Review threads are still unresolved. Unresolved threads mean changes are suggested (ladder rule 5). |
| `rationale-7` | Only LOW findings remain. LOW findings alone mean approve with nits (ladder rule 7). |
| `rationale-8` | No finding is open. With nothing open, the change is approved (ladder rule 8). |
| `signal-name-checks` | checks |
| `signal-name-review-decision` | review decision |
| `signal-name-mergeability` | mergeability |
| `checks-pass` | Checks pass. |
| `checks-fail` | Checks fail. |
| `checks-unknown` | Checks: unknown. |
| `mergeability-pass` | Mergeable. |
| `mergeability-fail` | Not mergeable. |
| `mergeability-unknown` | Mergeability: unknown. |
| `review-decision-pass` | Approved. |
| `review-decision-fail` | Changes requested. |
| `review-decision-none` | No review yet. |
| `review-decision-unknown` | Review decision: unknown. |
| `threads-pass` | Threads resolved. |
| `threads-unresolved` | Unresolved threads: {count}. |
| `threads-unknown` | Thread resolution: unknown. |
| `patch-unavailable` | - The patch of `{path}` was unavailable, so its changes could not be read. |
| `thread-resolution-unknown` | - Review thread resolution: the thread query was unavailable, so review comments were grouped by reply instead. Whether the open threads are resolved is unknown. |
| `prose-truncated` | - Quoted prose was truncated, so part of the discussion was not read. |
| `threads-over-count` | - {count} review thread comments over the count did not reach the review. |
| `verification` | - Verification of `{dir}`: {reason}. |
| `verification-more` | - {count} more example directories with a check that could not run are not listed. |
| `unplanned` | - `{dir}` was not planned: {reason}. |
| `unplanned-more` | - {count} more examples that were not planned are not listed. |
| `unplanned-no-examples` | - The module has no example directory, so no example could be planned. |
| `unplanned-inert` | - The change reaches no Terraform configuration, so the examples below that were not planned leave nothing unknown. |
| `behaviour-not-run` | - Behaviour check: {reason}, so no change was classified or verified. |
| `behaviour-trigger` | - Behaviour change at `{location}` ({category}): not verified. |
| `behaviour-capped` | - {count} more behaviour changes over the classifier cap: not verified. |
| `behaviour-claim` | - Claim {claim_id} from the description: not verified. |
| `behaviour-evidence` | Behaviour evidence: {count} changes classified: {verified} verified, {covered} covered by a plan, {inert} inert, {refuted} refuted, {unverifiable} not verified; {claims} claims: {claims_verified} verified, {claims_refuted} refuted, {claims_unverifiable} not verified. |
| `thread-match` | - `{location}`: this review has a finding at the same path and line. |
| `thread-no-match` | - `{location}`: this review has no finding at the same path and line. |
| `todo-lead-block` | To make this mergeable, resolve each checklist item below and push. |
| `todo-lead-4` | This review is incomplete, so a later run may add items. The items below are known. |
| `todo-lead-7` | Nothing blocks merge. The items below are optional. |
| `todo-lead-0` | This change is breaking. Merge it in the next major release. To merge it sooner, restore compatibility with the fixes named below. Any checklist items below also block merge. |
| `todo-checks` | Fix the failing checks. |
| `todo-mergeability` | Resolve the merge conflict. |
| `todo-review-decision` | Address the requested changes. |
| `todo-threads-one` | Resolve the open review thread. |
| `todo-threads-many` | Resolve the {count} open review threads. |
| `todo-fix-one` | `{rule_id}`: apply the Fix at {locations}. |
| `todo-fix-many` | `{rule_id}` ({count}): apply the Fix at {locations}. |
| `todo-compat-one` | `{rule_id}`: the Fix at {locations} restores compatibility. |
| `todo-compat-many` | `{rule_id}` ({count}): the Fix at {locations} restores compatibility. |
| `todo-optional-one` | Optional: `{rule_id}` at {locations}. |
| `todo-optional-many` | Optional: `{rule_id}` ({count}) at {locations}. |
| `todo-more` | , and {count} more |
| `todo-refuted` | Behaviour change at `{location}` ({category}): the evidence refutes it. Fix the change or correct the description. |
| `todo-generated` | Documentation tables are generated. After the edits above, run `pre-commit run -a` and commit the result. Do not edit them by hand. |
| `todo-triage` | This was a triage run. The full review has not run. |
| `todo-checks-unknown` | Check results could not be read or are still running. |
| `todo-threads-unknown` | Review thread resolution could not be read. |
| `todo-review-decision-unknown` | The reviews could not be read. |
| `todo-mergeability-unknown` | Mergeability could not be read. |
| `todo-gaps-one` | 1 check could not run; see Checks that could not run. |
| `todo-gaps-many` | {count} checks could not run; see Checks that could not run. |
| `fix-fold` | Fix for each location ({count}) |

The lines of sections 6 and 8 that [host-pass.md](host-pass.md#host-facts) and [Section Order](#section-order) already give word for word are rendered as written there. Each line of sections 6 and 8 is its own paragraph, and the triage line is its own paragraph under the verdict line.

## Worked Example

A change that adds log delivery to a module. Every host signal reads clean, no thread is
unresolved and nobody commented on the conversation, so the last four sections are omitted and
the MEDIUM finding lands the verdict at rule 6. The repository, the findings and their fixes below are illustrative. The fence is only for this
document; the preview at the confirmation gate is rendered, never fenced.

```markdown
The change adds CloudWatch log delivery to the module, and the resource wiring looks right.
What is missing is caller control: the retention window is fixed in code, so nobody using the
module can change it.

**Changes requested before merge.**

A MEDIUM finding is open. Any MEDIUM finding blocks merge (ladder rule 6).

### What to do

To make this mergeable, resolve each checklist item below and push.

- [ ] `coverage.optional-argument-unexposed`: apply the Fix at `modules/logging/main.tf:31`.
- Optional: `structure.grouping` at `variables.tf:88`.

### Findings

**MEDIUM**

- `coverage.optional-argument-unexposed` - `modules/logging/main.tf:31` - The log group's retention argument is set to a literal, so callers cannot change how long logs are kept.
  - Fix: In `modules/logging/main.tf`, set `retention_in_days` on the log group from a new `variable "log_retention_in_days"` in `modules/logging/variables.tf`, with the current literal as its default so existing callers keep it.

**LOW**

- `structure.grouping` - `variables.tf:88` - The new variable sits between two unrelated groups instead of with the other logging inputs.
  - Fix: Move the new variable in `variables.tf` into the logging inputs' group.
```

Had thread resolution been unreadable on the same run, rule 4 would fire before the MEDIUM at
rule 6. The assessment does not move, because it describes the code and the code did not
change. The verdict and the rationale do, and two more sections appear:

```markdown
The change adds CloudWatch log delivery to the module, and the resource wiring looks right.
What is missing is caller control: the retention window is fixed in code, so nobody using the
module can change it.

**Inconclusive.**

Review thread resolution could not be read, so an open objection may exist. Any unknown makes the review inconclusive (ladder rule 4).

### What to do

This review is incomplete, so a later run may add items. The items below are known.

- [ ] `coverage.optional-argument-unexposed`: apply the Fix at `modules/logging/main.tf:31`.
- Optional: `structure.grouping` at `variables.tf:88`.
- Review thread resolution could not be read.

### Findings

**MEDIUM**

- `coverage.optional-argument-unexposed` - `modules/logging/main.tf:31` - The log group's retention argument is set to a literal, so callers cannot change how long logs are kept.
  - Fix: In `modules/logging/main.tf`, set `retention_in_days` on the log group from a new `variable "log_retention_in_days"` in `modules/logging/variables.tf`, with the current literal as its default so existing callers keep it.

**LOW**

- `structure.grouping` - `variables.tf:88` - The new variable sits between two unrelated groups instead of with the other logging inputs.
  - Fix: Move the new variable in `variables.tf` into the logging inputs' group.

### Checks that could not run

- Review thread resolution: the thread query was unavailable, so review comments were grouped by reply instead. Whether the open threads are resolved is unknown.

### Pull request state

Checks pass. Mergeable. No review yet. Thread resolution: unknown.
```

With the MEDIUM fixed, only the LOW one is left, the verdict moves to rule 7, and the
assessment shrinks with the work left to do:

```markdown
The change adds CloudWatch log delivery to the module. The wiring is right and callers can set
the retention window.

**Good to merge, with nits.**

Only LOW findings remain. LOW findings alone mean approve with nits (ladder rule 7).

### What to do

Nothing blocks merge. The items below are optional.

- Optional: `structure.grouping` at `variables.tf:88`.
```

Size the assessment to the change. A one-line spelling fix gets one sentence and stops:
`Spelling fix in the README, correct as written.`

The fields in the findings lines are the reviewer's, unchanged except for the path, which Step 8 rewrote from module-root-relative to repository-relative. Severity, `rule_id`, summary and `suggested_fix` are reproduced as returned: see [findings-schema.md](../../terraform-module-reviewer/references/findings-schema.md).
