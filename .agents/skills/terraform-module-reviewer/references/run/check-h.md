# Run Summary: Check H

> **Part of:** [terraform-module-reviewer](../../SKILL.md), [Check H](../check-h-non-hcl.md)
> **Purpose:** The index a run reads for Check H, as [Reading by Depth](../../SKILL.md#reading-by-depth) says: each `rule_id`, when it applies, the provider facts it needs as [rule-facts.md](../rule-facts.md) gives them, and the sections that hold its text. It holds no rule text; the sections are operative.

When unsure whether a row's **Applies when** holds, it holds.

## Read First

When any row below applies: [Reads, Fails When and Severity](../check-h-non-hcl.md#reads-fails-when-and-severity).

## Rules

| `rule_id` | Applies when | Provider facts | Sections |
|-----------|--------------|----------------|----------|
| `structure.non-hcl-logic-error` | The change edits a file that is not Terraform configuration and that the module runs: a program a `.tf` file runs through `external`, a provisioner or a build command, or a script the module's tests run. | none | [Check H](../check-h-non-hcl.md#reads-fails-when-and-severity) |
| `structure.non-hcl-test-missing` | The change edits such a file and the repository has a test file that imports or runs it. | none | [Check H](../check-h-non-hcl.md#reads-fails-when-and-severity) |
| `structure.non-hcl-unsafe-subprocess` | The change edits such a file and an edited line starts a process. | none | [Check H](../check-h-non-hcl.md#reads-fails-when-and-severity) |

## Other Sections

| Section | Open when |
|---------|-----------|
| [Suggested Fixes](../check-h-non-hcl.md#suggested-fixes) | Check H reports a finding. |
