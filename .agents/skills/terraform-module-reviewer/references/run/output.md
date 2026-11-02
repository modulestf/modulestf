# Run Index: Output

> **Part of:** [terraform-module-reviewer](../../SKILL.md), [findings-schema.md](../findings-schema.md), [output.md](../output.md)
> **Purpose:** What a run writes, each item linking the section that rules it. Open a section when an item is unclear or a finding needs more; this file holds no rule of its own.

## Where It Goes

- With an `Output:` line in the caller's own task text, write exactly the files it names, outside the workspace, and nothing else: the findings list as JSON, the summary line, and the Facts comparison note or its failure line when [run/facts.md](facts.md) applies.
- Without one, the reply holds the findings list, then the summary line on a line of its own, then the note last ([Output](../output.md#output)).

## The Findings List

A JSON list of findings and nothing else; `[]` is a clean review ([Shape](../findings-schema.md#shape)). Each finding carries these seven fields ([Required Fields](../findings-schema.md#required-fields)):

| Field | Value |
|-------|-------|
| `id` | `F-001`, `F-002`, ... in output order |
| `rule_id` | A registry name ([`rule_id` Format](../findings-schema.md#rule_id-format)), from a check's run summary, its sections, Rules 3 and 4, or the Inputs rules |
| `severity` | `CRITICAL`, `HIGH`, `MEDIUM` or `LOW`, from the rule's own Severity text ([Severity Levels](../output.md#severity-levels)); a `review.*` finding is never `CRITICAL` |
| `file` | Path relative to the module root, `.` for no single file |
| `line` | 1-based line at the reviewed revision, or `null` |
| `summary` | One plain sentence, what is wrong and where it bites; aim for 200 characters, 500 is the cap |
| `suggested_fix` | One of the three forms of the [Suggested Fix Contract](../findings-schema.md#suggested-fix-contract); aim for 250 characters, 600 for `needs decision:`, 600 is the cap |

Write short: the targets are in [Length Targets](../findings-schema.md#length-targets). Order by severity, then `file`, then `line` with null last, and number after ordering ([Ordering](../findings-schema.md#ordering)). Deduplicate first, by the [Final Step](../workflow.md#final-step-assemble-the-findings). `explains` and `evidence_digest` are set only as Check G's summary says ([Optional Fields](../findings-schema.md#optional-fields)). A task with incremental lines: [Incremental Task Lines](../findings-schema.md#incremental-task-lines).

## The Summary Line

One line, every key always there, each `<n>` decimal digits, `0` included ([Output](../output.md#output)):

```text
summary: critical:<n> high:<n> medium:<n> low:<n> mode:<full or triage> checks:<checks run> instruction-like-text-from-others:<n> conversation-claims-unread:<n> review.quoted-claim-unverifiable:<n>
```

`<checks run>` is the letters of the checks that counted as run ([Reading by Depth](../../SKILL.md#reading-by-depth)), comma separated, or `none`.
