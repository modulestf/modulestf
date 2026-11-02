# Run Summary: Check D

> **Part of:** [terraform-module-reviewer](../../SKILL.md), [Check D](../check-d-examples.md)
> **Purpose:** The index a run reads for Check D, as [Reading by Depth](../../SKILL.md#reading-by-depth) says: each `rule_id`, when it applies, the provider facts it needs as [rule-facts.md](../rule-facts.md) gives them, and the sections that hold its text. It holds no rule text; the sections are operative.

When unsure whether a row's **Applies when** holds, it holds.

An example `depth.json` puts out of scope, honoured at `focused` only, is read by no row.

## Read First

When any row below applies: [Reads, Fails When and Severity](../check-d-examples.md#reads-fails-when-and-severity).

## Rules

| `rule_id` | Applies when | Provider facts | Sections |
|-----------|--------------|----------------|----------|
| `examples.argument-undemonstrated` | The change adds an argument, or an input that feeds one. | none | [Check D](../check-d-examples.md#reads-fails-when-and-severity) |
| `examples.custom-input-required` | An example is in scope and the change touches it or anything it calls. | none | [Check D](../check-d-examples.md#reads-fails-when-and-severity) |
| `examples.disabled-call-missing` | The change adds or edits an example, or the task is a new module. | none | [engine](../engine/check-d-examples.md#examplesdisabled-call-missing) |
| `examples.docs-incomplete` | The change adds or edits an example, or the task is a new module. | none | [Check D](../check-d-examples.md#reads-fails-when-and-severity) |
| `examples.example-broken` | An example is in scope and the change touches it or anything it calls, or the record shows a failed run. | schema; page entry when: An example the change adds or edits, or one of the version bump only examples, has a block of the type. | [Check D](../check-d-examples.md#reads-fails-when-and-severity) |
| `examples.example-broken-at-base` | The record marks a failure, or a plan `code-error`, as reproducing at the base. | none | [Check D](../check-d-examples.md#reads-fails-when-and-severity) |
| `examples.feature-undemonstrated` | The change adds a resource, a nested or dynamic block, a submodule feature, an argument or an input. | none | [Check D](../check-d-examples.md#reads-fails-when-and-severity) |
| `examples.real-domain-zone` | The change adds or edits an example `.tf` file. | none | [Check D](../check-d-examples.md#reads-fails-when-and-severity) |
| `examples.stale-reference` | The change removes or renames a module input or output, or adds or edits an example's `module` block. | none | [engine](../engine/check-d-examples.md#examplesstale-reference) |
| `examples.submodule-missing` | The change adds a directory under `modules/`. | none | [engine](../engine/check-d-examples.md#examplessubmodule-missing) |
| `examples.versions-missing` | The change adds or edits an example, or the task is a new module. | none | [engine](../engine/check-d-examples.md#examplesversions-missing) |

## Other Sections

| Section | Open when |
|---------|-----------|
| [Plan evidence](../check-d-examples.md#plan-evidence) | The verification record carries plan evidence, an `example selection:`, `plan coverage:` or `not planned:` line, or a `plan pass mode:` line. |
| [Suggested Fixes](../check-d-examples.md#suggested-fixes) | Check D reports a finding. |
