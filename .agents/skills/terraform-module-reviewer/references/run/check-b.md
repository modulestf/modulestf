# Run Summary: Check B

> **Part of:** [terraform-module-reviewer](../../SKILL.md), [Check B](../check-b-coverage.md)
> **Purpose:** The index a run reads for Check B, as [Reading by Depth](../../SKILL.md#reading-by-depth) says: each `rule_id`, when it applies, the provider facts it needs as [rule-facts.md](../rule-facts.md) gives them, and the sections that hold its text. It holds no rule text; the sections are operative.

When unsure whether a row's **Applies when** holds, it holds.

## Read First

When any row below applies: [Reads](../check-b-coverage.md#reads), [Which blocks](../check-b-coverage.md#which-blocks) and [Rules](../check-b-coverage.md#rules).

## Rules

| `rule_id` | Applies when | Provider facts | Sections |
|-----------|--------------|----------------|----------|
| `coverage.argument-above-min-version` | The change adds a resource or data block, or adds an argument or nested block to one. | schema | [engine](../engine/check-b-coverage.md#coverageargument-above-min-version) |
| `coverage.attribute-not-output` | The change adds a `resource` block, or adds or edits an output. | schema; page entry when: The change adds or edits an output that reads an attribute of the type. | [engine](../engine/check-b-coverage.md#coverageattribute-not-output) |
| `coverage.block-attribute-mismatch` | The change adds or edits a resource or data block. | schema | [engine](../engine/check-b-coverage.md#coverageblock-attribute-mismatch) |
| `coverage.default-for-required-argument` | The change adds or changes a default of an input, an `optional()` default or a literal fallback that reaches a resource or data argument. | page; page entry when: The change adds or changes a default of an input that backs an argument of the type. | [Rules](../check-b-coverage.md#rules) |
| `coverage.deprecated-argument` | The change adds a resource or data block, or adds an argument or nested block to one. | schema | [engine](../engine/check-b-coverage.md#coveragedeprecated-argument) |
| `coverage.enum-value-unknown` | The change sets a literal that reaches a resource or data argument, in the module or an example. | page; page entry when: The change sets a literal on an argument of the type, in the module or an example. | [Rules](../check-b-coverage.md#rules) |
| `coverage.mutual-exclusion-unguarded` | The change adds or edits a resource or data block, or an input, `validation` or `precondition` that feeds one. | page; page entry when: The change adds or edits a block of the type. | [Rules](../check-b-coverage.md#rules) |
| `coverage.optional-argument-unexposed` | The change adds a `resource` block. | schema; page entry when: The change adds a `resource` block of the type. | [engine](../engine/check-b-coverage.md#coverageoptional-argument-unexposed), [Documented omissions](../check-b-coverage.md#documented-omissions) |
| `coverage.required-argument-unreachable` | The change adds or edits a resource or data block, or an input that feeds one. | schema | [engine](../engine/check-b-coverage.md#coveragerequired-argument-unreachable) |
| `coverage.unknown-argument` | The change adds or edits a resource or data block. | schema; page entry when: The change adds or edits a block of the type that repeats a nested block. | [engine](../engine/check-b-coverage.md#coverageunknown-argument) |

## Other Sections

| Section | Open when |
|---------|-----------|
| [Suggested Fixes](../check-b-coverage.md#suggested-fixes) | Check B reports a finding. |
