# Run Summary: Check E

> **Part of:** [terraform-module-reviewer](../../SKILL.md), [Check E](../check-e-profile.md)
> **Purpose:** The index a run reads for Check E, as [Reading by Depth](../../SKILL.md#reading-by-depth) says: each `rule_id`, when it applies, the provider facts it needs as [rule-facts.md](../rule-facts.md) gives them, and the sections that hold its text. It holds no rule text; the sections are operative.

When unsure whether a row's **Applies when** holds, it holds.

## Read First

When any row below applies: [Reads, Fails When and Severity](../check-e-profile.md#reads-fails-when-and-severity).

## Rules

| `rule_id` | Applies when | Provider facts | Sections |
|-----------|--------------|----------------|----------|
| `profile.changelog-handwritten` | The change edits `CHANGELOG.md`. | none | [Check E](../check-e-profile.md#reads-fails-when-and-severity) |
| `profile.commit-type-mismatch` | The task carries the title the change will be released under. | none | [Check E](../check-e-profile.md#reads-fails-when-and-severity) |
| `profile.generated-content-handwritten` | The change adds, removes or edits an input or output, adds, removes or retypes a resource, or edits a generated region of a `README.md`, a file under `wrappers/`, a generator version or a terraform-docs configuration. | none | [Check E](../check-e-profile.md#reads-fails-when-and-severity) |
| `profile.layout-divergence` | The change adds a file, a directory or a `LICENSE`, or the task is a new module. | none | [Check E](../check-e-profile.md#reads-fails-when-and-severity) |
| `profile.migration-notes-misplaced` | The change edits a `README.md`, adds migration notes, or is breaking. | none | [Check E](../check-e-profile.md#reads-fails-when-and-severity) |
| `profile.nonstandard-config-file` | The change adds or edits a `.tf.json`, override or `.tofu` file, or an OpenTofu-only block. | none | [engine](../engine/check-e-profile.md#profilenonstandard-config-file) |
| `profile.owner-identifier` | The task is a new module. | none | [Check E](../check-e-profile.md#reads-fails-when-and-severity) |
| `profile.provider-meta-missing` | The change adds, removes or edits a `versions.tf`, or the task is a new module. | none | [Check E](../check-e-profile.md#reads-fails-when-and-severity) |
| `profile.putin-khuylo-missing` | The change adds a root block, edits a root `count`, `for_each` or a local either reads, or edits `putin_khuylo`, or the task is a new module. | none | [engine](../engine/check-e-profile.md#profileputin-khuylo-missing) |
| `profile.region-not-allowed` | The change adds or edits a literal that names a region. | none | [engine](../engine/check-e-profile.md#profileregion-not-allowed) |
| `profile.release-config-changed` | The change edits release or automation configuration the profile owns, or a file under `.github/`. | none | [Check E](../check-e-profile.md#reads-fails-when-and-severity) |
| `profile.required-file-missing` | The task is a new module, or the change adds a submodule or example, or deletes or renames a file. | none | [engine](../engine/check-e-profile.md#profilerequired-file-missing) |
| `profile.template-drift` | The change adds or edits a file the templates map lists. | none | [engine](../engine/check-e-profile.md#profiletemplate-drift) |
| `profile.title-misspelling` | The task carries the title the change will be released under. | none | [Check E](../check-e-profile.md#reads-fails-when-and-severity) |
| `profile.title-uninformative` | The task carries the title the change will be released under. | none | [Check E](../check-e-profile.md#reads-fails-when-and-severity) |
| `profile.unrelated-change-bundled` | The title's type is `feat` and the change edits a `.tf` file. | none | [Check E](../check-e-profile.md#reads-fails-when-and-severity) |

## Other Sections

| Section | Open when |
|---------|-----------|
| [Suggested Fixes](../check-e-profile.md#suggested-fixes) | Check E reports a finding. |
