# Run Summary: Check C

> **Part of:** [terraform-module-reviewer](../../SKILL.md), [Check C](../check-c-structure.md)
> **Purpose:** The index a run reads for Check C, as [Reading by Depth](../../SKILL.md#reading-by-depth) says: each `rule_id`, when it applies, the provider facts it needs as [rule-facts.md](../rule-facts.md) gives them, and the sections that hold its text. It holds no rule text; the sections are operative.

When unsure whether a row's **Applies when** holds, it holds.

## Read First

When any row below applies: [Reads, Fails When and Severity](../check-c-structure.md#reads-fails-when-and-severity).

## Rules

| `rule_id` | Applies when | Provider facts | Sections |
|-----------|--------------|----------------|----------|
| `structure.argument-order` | The change adds or edits a resource block. | none | [engine](../engine/check-c-structure.md#structureargument-order) |
| `structure.arn-partition-hardcoded` | The change adds or edits an ARN, an account ID or a region as a literal outside a comment. | none | [engine](../engine/check-c-structure.md#structurearn-partition-hardcoded) |
| `structure.comment-redundant` | The change adds a comment. | none | [Check C](../check-c-structure.md#reads-fails-when-and-severity) |
| `structure.comment-unsourced` | The change adds a comment. | none | [Check C](../check-c-structure.md#reads-fails-when-and-severity) |
| `structure.copied-content-unattributed` | The change adds a literal constant: a policy, an account number, an ARN, a principal, a condition key or a zone ID. | none | [Check C](../check-c-structure.md#reads-fails-when-and-severity) |
| `structure.create-flag-ignored` | The change adds a resource, data or module block, or edits a `count` or `for_each`. | none | [Check C](../check-c-structure.md#reads-fails-when-and-severity) |
| `structure.docs-contradict-code` | The change adds or edits documentation (a README section, a `description`, an example comment) or the code it describes. | page; page entry when: A changed block, output, local or documentation line depends on what a data source of the type does with its inputs. | [Check C](../check-c-structure.md#reads-fails-when-and-severity) |
| `structure.feature-above-version-floor` | The change adds a call of a function, a block type or another language feature, or edits `required_version`. | none | [engine](../engine/check-c-structure.md#structurefeature-above-version-floor) |
| `structure.flag-polarity` | The change adds a boolean input, or edits a boolean input's default. | none | [Check C](../check-c-structure.md#reads-fails-when-and-severity) |
| `structure.grouping` | The change adds or renames a block, variable or output, moves one between files, or edits a section header. | none | [Check C](../check-c-structure.md#reads-fails-when-and-severity) |
| `structure.input-ignored-in-branch` | The change adds or forwards an input, or edits an expression, `count`, `for_each`, conditional or flag that reads or switches one; or adds a mode input that changes how many instances a sibling resource needs, while that resource's `count` or `for_each` does not read it. | none | [Check C](../check-c-structure.md#reads-fails-when-and-severity) |
| `structure.insecure-default` | The change touches encryption, public access, logging, deletion protection or another security setting: an argument, a default or a flag it sets, edits or stops setting. | none | [Check C](../check-c-structure.md#reads-fails-when-and-severity) |
| `structure.missing-description` | The change adds a variable or output. | none | [engine](../engine/check-c-structure.md#structuremissing-description) |
| `structure.multi-provider` | The change adds or edits a `provider` block, a `provider` argument or a `providers` map. | none | [engine](../engine/check-c-structure.md#structuremulti-provider) |
| `structure.output-no-try` | The change adds an output. | none | [engine](../engine/check-c-structure.md#structureoutput-no-try) |
| `structure.passthrough-default-drift` | The change adds or edits a `module` block whose source is a local submodule, that submodule's variables, or the type or default of a root variable a module argument forwards. | none | [engine](../engine/check-c-structure.md#structurepassthrough-default-drift) |
| `structure.passthrough-field-drift` | The change adds or edits a `module` block whose source is a local submodule, that submodule's variables, or the type or default of a root variable a module argument forwards. | none | [engine](../engine/check-c-structure.md#structurepassthrough-field-drift) |
| `structure.schema-shape-flattened` | The change adds or edits an object- or `any`-typed input, or the nested block it feeds. | schema | [Check C](../check-c-structure.md#reads-fails-when-and-severity) |
| `structure.sibling-argument-omitted` | The change adds a resource block. | schema | [Check C](../check-c-structure.md#reads-fails-when-and-severity) |
| `structure.sibling-block-asymmetry` | The change adds or edits a `dynamic` block. | schema | [Check C](../check-c-structure.md#reads-fails-when-and-severity) |
| `structure.suppression-unexplained` | The change adds a comment that directs a scanner. | none | [Check C](../check-c-structure.md#reads-fails-when-and-severity) |
| `structure.validation-message-uninformative` | The change adds or edits a `validation` or `precondition` block. | none | [Check C](../check-c-structure.md#reads-fails-when-and-severity) |
| `structure.validation-missing` | The change adds or edits an input or a `validation` block, or comments one out. | none | [Check C](../check-c-structure.md#reads-fails-when-and-severity) |
| `structure.validation-overreaching` | The change adds or edits a `validation` block. | none | [Check C](../check-c-structure.md#reads-fails-when-and-severity) |
| `structure.variable-untyped` | The change adds a variable. | none | [engine](../engine/check-c-structure.md#structurevariable-untyped) |
| `structure.version-floor-understated` | The change edits a `versions.tf`, or adds or edits a `module` block whose source is local. | none | [engine](../engine/check-c-structure.md#structureversion-floor-understated) |
| `structure.wrong-file` | The change adds a block. | none | [engine](../engine/check-c-structure.md#structurewrong-file) |
| Tag propagation, no `rule_id` | The change adds a resource block. | none | [Check C](../check-c-structure.md#reads-fails-when-and-severity) |

## Other Sections

| Section | Open when |
|---------|-----------|
| [Suggested Fixes](../check-c-structure.md#suggested-fixes) | Check C reports a finding. |
