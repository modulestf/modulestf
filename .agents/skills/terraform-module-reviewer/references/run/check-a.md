# Run Summary: Check A

> **Part of:** [terraform-module-reviewer](../../SKILL.md), [Check A](../check-a-compatibility.md)
> **Purpose:** The index a run reads for Check A, as [Reading by Depth](../../SKILL.md#reading-by-depth) says: each `rule_id`, when it applies, the provider facts it needs as [rule-facts.md](../rule-facts.md) gives them, and the sections that hold its text. It holds no rule text; the sections are operative.

When unsure whether a row's **Applies when** holds, it holds.

## Read First

When any row below applies: [Reads, Fails When and Severity](../check-a-compatibility.md#reads-fails-when-and-severity).

## Rules

| `rule_id` | Applies when | Provider facts | Sections |
|-----------|--------------|----------------|----------|
| `compat.break-unexplained` | The title or the body declares the change breaking: a `!` type, a `BREAKING CHANGE` trailer or section, or words. | none | [Check A](../check-a-compatibility.md#reads-fails-when-and-severity) |
| `compat.claim-contradicts-analysis` | The title or the body makes a compatibility claim. | none | [Check A](../check-a-compatibility.md#reads-fails-when-and-severity), [quoted-claims.md](../quoted-claims.md#compatclaim-contradicts-analysis) |
| `compat.default-changed` | The change edits any default: a variable or `optional()` default, a fallback literal of `try`, `coalesce`, `lookup` or a conditional, a literal resource, data or module argument, or removes a `data` block; or edits a variable or output description; or adds an input with a default. | page; page entry when: The change adds an input whose default sets an argument of the type to a value the base did not send, or changes an existing input's default that the title or an upgrade note declares. The engine raises a candidate for an added input with a non-null default only when configuration the base already had reads it: `count`, `for_each`, `provider` or `providers` of a block the base has, an argument of such a block, of an output or of another block that the base block also has, any argument or nested block of a provider the base has, the arguments of nested blocks of a type the base block had that the base blocks also have, every argument of a nested block type whose count differs between base and head, any new `precondition`, `postcondition`, `assert` or `lifecycle` block inside a block the base has, and a validation of an existing variable. It follows those reads through locals and through a new resource, data source, module call, provider or ephemeral block that they read (a new provider with no alias counts as read by every resource of its type), and through `moved` blocks (chains; a move into or out of a module call's contents, between resource types, between module calls with another source, or with an address it cannot read counts every argument they can land in). It raises a candidate for a new input with a validation block whatever its default. It leaves to the review, from the diff, a new argument on an existing block (for example `skip_destroy = var.x`), a new argument inside an existing nested block, a new nested block of a type the base block did not have other than those four, a new block that nothing in the base reads, and a same-kind rename (`module.a` to `module.b` with the same source, a resource renamed within its type), whose arguments pair by name. | [engine](../engine/check-a-compatibility.md#compatdefault-changed) |
| `compat.generated-policy-narrowed` | The change edits or removes a policy document, statement, rule, permission or grant the module produces, anything that feeds one, or a `data` block. | none | [engine](../engine/check-a-compatibility.md#compatgenerated-policy-narrowed) |
| `compat.provider-floor-raised` | The change edits a provider version constraint, or adds a registry module call or moves its version. | schema | [engine](../engine/check-a-compatibility.md#compatprovider-floor-raised) |
| `compat.resource-address-changed` | The change removes, renames or moves a resource or module block (into or out of `count`, `for_each` or a submodule), edits its `count` or `for_each` or a value either reads, or edits or removes a `moved` block. | none | [engine](../engine/check-a-compatibility.md#compatresource-address-changed) |
| `compat.type-narrowed` | The change edits a variable's `type`, or adds or edits a `validation` block. | none | [engine](../engine/check-a-compatibility.md#compattype-narrowed) |
| `compat.variable-now-required` | The change adds a variable, or edits a variable's `default`, `nullable` or `type`. | none | [engine](../engine/check-a-compatibility.md#compatvariable-now-required) |
| `compat.variable-removed` | The change removes or renames a variable or output. | none | [engine](../engine/check-a-compatibility.md#compatvariable-removed) |
| `compat.vendored-policy-drift` | The task carries a `Vendored policy:` line. | none | [Check A](../check-a-compatibility.md#host-vendored-policy-evidence) |
| `compat.version-constraint-raised` | The change edits `required_version` or a provider version constraint. | none | [engine](../engine/check-a-compatibility.md#compatversion-constraint-raised) |

## Other Sections

| Section | Open when |
|---------|-----------|
| [Suggested Fixes](../check-a-compatibility.md#suggested-fixes) | Check A reports a finding. |
| [No base](../check-a-compatibility.md#no-base) | The task is a new module. |
| [Host Vendored Policy Evidence](../check-a-compatibility.md#host-vendored-policy-evidence) | The task carries a `Vendored policy:` line. |
