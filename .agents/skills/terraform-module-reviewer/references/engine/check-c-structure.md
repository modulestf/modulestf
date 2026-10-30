# Engine Text: Check C

> **Part of:** [terraform-module-reviewer](../../SKILL.md), [Check C](../check-c-structure.md)
> **Purpose:** The operative fails-when and severity text of the Check C rules whose `engine` in [rule-facts.md](../rule-facts.md) is `tool` or `candidate`, moved here verbatim from the check file. The full variant reads this file as part of Check C.

Each rule has one section. **Rule text** is the moved text; a sentence that also covers an `llm` rule stays in the check file and is copied here, so each section stands alone. **Confirm when** is the short criteria a confirmer applies to one candidate. **Host templates** are the `summary` and `suggested_fix` the host writes for a confirmed candidate, with `{subject}` filled from the candidate. Each template is one code span of at most 200 characters as written, with `{subject}` unfilled.

## `structure.output-no-try`

Engine: `candidate`

### Rule text: `structure.output-no-try`

**Fails when:**
- An output added by the change has no `try()` fallback, or uses a fallback that changes the output type.

**Severity:**
- HIGH when conditional creation is broken, an output will error instead of returning null, or a nested input does not match the schema shape. HIGH too when documentation promises behaviour no code path implements (`structure.docs-contradict-code`); an input the code reads nowhere is the other rule, `structure.input-ignored-in-branch`.

### Confirm when: `structure.output-no-try`

- The output is added by the change.
- Its expression reads an attribute that can be absent and has no `try()` around it, or its `try()` fallback is of another type than the output's value.

### Host templates: `structure.output-no-try`

- `summary`: `Output {subject} has no try() fallback, or its fallback changes the output type, so it errors instead of returning null.`
- `suggested_fix`: `Wrap the expression of {subject} in try(<expression>, null), or use a fallback of the output's own type.`

## `structure.variable-untyped`

Engine: `candidate`

### Rule text: `structure.variable-untyped`

**Fails when:**
- A new variable has no explicit `type`, uses `any` without a stated reason, or has no `description`; a new output has no `description`.

**Severity:**
- MEDIUM when a must-pass structural convention is missed: missing `type`, missing `description`, wrong file, missing tag propagation, a scanner suppression with no reason for accepting the risk, a closed value set whose `validation` block is absent or commented out (`structure.validation-missing`; the wording of a message a present block does emit is `structure.validation-message-uninformative`).

### Confirm when: `structure.variable-untyped`

- The variable is new in the change.
- It has no `type`, or its type is `any` with no comment stating why.

### Host templates: `structure.variable-untyped`

- `summary`: `Variable {subject} has no explicit type, or uses any without a stated reason.`
- `suggested_fix`: `Add type = <type> to {subject}, named from how the module reads it, or keep any with a comment giving the reason.`

## `structure.missing-description`

Engine: `tool`

### Rule text: `structure.missing-description`

**Fails when:**
- A new variable has no explicit `type`, uses `any` without a stated reason, or has no `description`; a new output has no `description`.

**Severity:**
- MEDIUM when a must-pass structural convention is missed: missing `type`, missing `description`, wrong file, missing tag propagation, a scanner suppression with no reason for accepting the risk, a closed value set whose `validation` block is absent or commented out (`structure.validation-missing`; the wording of a message a present block does emit is `structure.validation-message-uninformative`).

### Confirm when: `structure.missing-description`

- The variable or output is new in the change.
- It has no `description` argument.

### Host templates: `structure.missing-description`

- `summary`: `Variable or output {subject} has no description.`
- `suggested_fix`: `Add a description to {subject}.`

## `structure.wrong-file`

Engine: `candidate`

### Rule text: `structure.wrong-file`

**Fails when:**
- Code lands in the wrong file for the module's archetype, for example identity resources inline in `main.tf` where the archetype calls for a separate file (`structure.wrong-file`). The archetype's extra files are optional in the profile, whose [Module layout](../../../terraform-module-maintainer/profiles/terraform-aws-modules/PROFILE.md#module-layout) says the absence of one is not a defect. So this fires only when the directory at the head already has the file the archetype names for that group, such as `iam.tf`, and the change adds blocks of that group to another file. A directory with no such file, new or existing, gets no finding for keeping the group in `main.tf`.

**Severity:**
- MEDIUM when a must-pass structural convention is missed: missing `type`, missing `description`, wrong file, missing tag propagation, a scanner suppression with no reason for accepting the risk, a closed value set whose `validation` block is absent or commented out (`structure.validation-missing`; the wording of a message a present block does emit is `structure.validation-message-uninformative`).

### Confirm when: `structure.wrong-file`

- The directory at the head already has the file the archetype names for the group, such as `iam.tf`.
- The change adds blocks of that group to another file.

### Host templates: `structure.wrong-file`

- `summary`: `Blocks in {subject} belong in the archetype file for their group, which this directory already has.`
- `suggested_fix`: `Move the blocks in {subject} to the archetype file the directory already has for their group.`

## `structure.argument-order`

Engine: `candidate`

### Rule text: `structure.argument-order`

**Fails when:**
- A resource block the diff adds or modifies puts `count` or `for_each` after another argument, or puts `tags` or `labels` anywhere but last, against [Argument Order in a Resource Block](../../../terraform-module-maintainer/references/module-structure.md#argument-order-in-a-resource-block). Only blocks the diff touches are in scope: ordering in untouched blocks of the same file is not this change's defect.

**Severity:**
- LOW when a should-pass convention is missed: grouping, section headers, argument order inside a touched resource block, naming consistency, an error message that tells the consumer neither the bound nor the value received.

### Confirm when: `structure.argument-order`

- The resource block is added or modified by the diff.
- `count` or `for_each` is not its first argument, or `tags` or `labels` is not its last.

### Host templates: `structure.argument-order`

- `summary`: `In {subject}, count or for_each is not first, or tags or labels is not last.`
- `suggested_fix`: `In {subject}, move count or for_each to the first line and tags or labels to the last.`

## `structure.multi-provider`

Engine: `candidate`

### Rule text: `structure.multi-provider`

**Fails when:**
- The change adds a `provider` block carrying an `alias`, adds a `provider = <provider>.<alias>` argument to a `resource` or `data` block, or adds a `providers = {}` argument to a `module` block, anywhere in the module under review. `examples/` is a root configuration, not the module: an example that demonstrates a cross-region or cross-account pattern declares aliases legitimately and is out of scope for this rule. Against [One Provider Configuration per Module](../../../terraform-module-maintainer/references/service-archetypes.md#one-provider-configuration-per-module). The caller composes regions and accounts; a module that carries its own aliases decides for every consumer which ones exist.

**Severity:**
- MEDIUM when a feature flag's prefix and its default disagree, or the module declares its own aliased provider configuration. Where a second provider configuration also changes what the caller has to pass in, Check A owns that part too.

### Confirm when: `structure.multi-provider`

- The change adds an aliased `provider` block, a `provider = <provider>.<alias>` argument, or a `providers = {}` argument.
- It is in the module under review, not under `examples/`.

### Host templates: `structure.multi-provider`

- `summary`: `{subject} gives the module its own aliased provider configuration, which the caller should compose.`
- `suggested_fix`: `Remove the aliased provider block, or the provider or providers argument, at {subject}; the caller passes a configured provider in.`

## `structure.passthrough-field-drift`

Engine: `candidate`

### Rule text: `structure.passthrough-field-drift`

**Fails when:**
- A `module` block calling a local submodule forwards a root input whose attribute set or unset value differs from the submodule variable it lands in. The procedure is in [Pass-through to a Local Submodule](#pass-through-procedure-structurepassthrough-field-drift).

**Severity:**
- MEDIUM when the submodule has an attribute the root cannot pass (`structure.passthrough-field-drift`): the submodule's capability is unreachable through the root, the band of an optional argument left unexposed. HIGH when that attribute is required in the submodule type, so every non-null value fails conversion at plan. For an attribute the root has and the submodule discards, the finding is `structure.passthrough-field-drift`, never `structure.input-ignored-in-branch`, at that rule's band: HIGH when it changes which resources are created or grants or restricts access, MEDIUM otherwise.

#### Pass-through procedure: `structure.passthrough-field-drift`

A root module that forwards its inputs to a submodule declares every field and default twice, once in its own type and once in the submodule's variables. The two copies drift with no error. This procedure compares them, and reads everything off the expression and type text so two runs list the same fields.

**Scope.** Every `module` block in the module root or in a submodule, with a `source` beginning `./` or `../`, that the diff adds or whose arguments it changes. Also every such block, touched or not, when the diff changes the called submodule's `variables.tf`, or changes the type or default of a root variable one of the block's arguments forwards. Calls under `examples/` are a root configuration (Check D), and calls under `wrappers/` are generated (Check E); both are out of scope.

**Forwarded.** An argument of that block is forwarded when its expression is one reference to a root input, or several joined only by `coalesce()`, `try()` or `<ref> != null ? <ref> : <other ref>`. A reference is `var.<name>`, an attribute path under it, or an attribute path under `each.value` where the `for_each` map's values are the elements of a root variable, unchanged, whether written in the `for_each` or in a local it reads: `{ for k, v in var.x : k => v if <condition> }` qualifies, `k => merge(v, {...})` does not. Any other expression - a literal, `each.key`, a resource attribute, `merge()` or any other function - is the author choosing a value, not forwarding one, and is not compared.

**Unset values.** The root side is what the expression yields when the caller sets none of the inputs it reads: `value` for an `optional(type, value)` attribute, null for an `optional(type)` attribute, the `default` for a variable. A required variable or attribute has no unset value and skips step 2. The submodule side is the variable's `default`. Terraform substitutes that default for a null argument when the variable has `nullable = false`, and substitutes an `optional(type, value)` default for a null attribute, so in those two cases a null on the root side is no difference.

1. **Attribute set** (`structure.passthrough-field-drift`). Walk the root-side type and the submodule variable's type together, at every depth under the forwarded argument; with several references, walk each one's type. An attribute the submodule type has and the root type lacks is a finding: no root caller can set it. An attribute the root type has and the submodule type lacks is a finding: conversion discards it, so what the caller sets there does nothing. When the call forwards any attribute of `each.value` or of one root object, a submodule variable the call does not set by any expression is the first case too.
2. **Unset value** (`structure.passthrough-default-drift`). For each forwarded argument, and each attribute both types carry, compare the two unset values after the substitution above. `null`, `[]` and `{}` are three different values.

The finding's `file` and `line` are where the root-side type declares the attribute, or the object type that lacks it, because that is where the fix goes. The `summary` names the submodule variable and its line.

### Confirm when: `structure.passthrough-field-drift`

- The `module` block is in the scope of [Pass-through to a Local Submodule](#pass-through-procedure-structurepassthrough-field-drift), and the argument is forwarded as that section defines.
- At some depth, an attribute is in the submodule type and not the root type, or in the root type and not the submodule type.
- The lead picks the severity from the Rule text: HIGH for a required submodule attribute, or a discarded one that changes which resources are created or grants or restricts access; MEDIUM otherwise.

### Host templates: `structure.passthrough-field-drift`

- `summary`: `The root type at {subject} and the submodule variable it is forwarded to do not carry the same attributes.`
- `suggested_fix`: `At {subject}, add the attribute the root type lacks, with the submodule's type and default, or remove the attribute the submodule lacks.`

## `structure.passthrough-default-drift`

Engine: `candidate`

### Rule text: `structure.passthrough-default-drift`

**Fails when:**
- A `module` block calling a local submodule forwards a root input whose attribute set or unset value differs from the submodule variable it lands in. The procedure is in [Pass-through to a Local Submodule](#pass-through-procedure-structurepassthrough-default-drift).

**Severity:**
- MEDIUM when a forwarded input's unset value differs between the root and the submodule (`structure.passthrough-default-drift`): a root caller who sets nothing gets a value the submodule does not declare, and nothing errors. HIGH when the root yields null into a submodule variable that has a non-null default and no `nullable = false`, so the submodule receives a value its own default excludes, or when the root's own documentation states the submodule's value. LOW when the input feeds only tags, a description or a name. Where the root's value weakens a secure default the submodule keeps, that is `structure.insecure-default` at CRITICAL, reported once.

#### Pass-through procedure: `structure.passthrough-default-drift`

A root module that forwards its inputs to a submodule declares every field and default twice, once in its own type and once in the submodule's variables. The two copies drift with no error. This procedure compares them, and reads everything off the expression and type text so two runs list the same fields.

**Scope.** Every `module` block in the module root or in a submodule, with a `source` beginning `./` or `../`, that the diff adds or whose arguments it changes. Also every such block, touched or not, when the diff changes the called submodule's `variables.tf`, or changes the type or default of a root variable one of the block's arguments forwards. Calls under `examples/` are a root configuration (Check D), and calls under `wrappers/` are generated (Check E); both are out of scope.

**Forwarded.** An argument of that block is forwarded when its expression is one reference to a root input, or several joined only by `coalesce()`, `try()` or `<ref> != null ? <ref> : <other ref>`. A reference is `var.<name>`, an attribute path under it, or an attribute path under `each.value` where the `for_each` map's values are the elements of a root variable, unchanged, whether written in the `for_each` or in a local it reads: `{ for k, v in var.x : k => v if <condition> }` qualifies, `k => merge(v, {...})` does not. Any other expression - a literal, `each.key`, a resource attribute, `merge()` or any other function - is the author choosing a value, not forwarding one, and is not compared.

**Unset values.** The root side is what the expression yields when the caller sets none of the inputs it reads: `value` for an `optional(type, value)` attribute, null for an `optional(type)` attribute, the `default` for a variable. A required variable or attribute has no unset value and skips step 2. The submodule side is the variable's `default`. Terraform substitutes that default for a null argument when the variable has `nullable = false`, and substitutes an `optional(type, value)` default for a null attribute, so in those two cases a null on the root side is no difference.

1. **Attribute set** (`structure.passthrough-field-drift`). Walk the root-side type and the submodule variable's type together, at every depth under the forwarded argument; with several references, walk each one's type. An attribute the submodule type has and the root type lacks is a finding: no root caller can set it. An attribute the root type has and the submodule type lacks is a finding: conversion discards it, so what the caller sets there does nothing. When the call forwards any attribute of `each.value` or of one root object, a submodule variable the call does not set by any expression is the first case too.
2. **Unset value** (`structure.passthrough-default-drift`). For each forwarded argument, and each attribute both types carry, compare the two unset values after the substitution above. `null`, `[]` and `{}` are three different values.

The finding's `file` and `line` are where the root-side type declares the attribute, or the object type that lacks it, because that is where the fix goes. The `summary` names the submodule variable and its line.

### Confirm when: `structure.passthrough-default-drift`

- The argument is forwarded as [Pass-through to a Local Submodule](#pass-through-procedure-structurepassthrough-default-drift) defines.
- After the substitution that section describes, the root's unset value and the submodule default differ; `null`, `[]` and `{}` are three values.
- The lead picks HIGH, MEDIUM or LOW as the Rule text says.

### Host templates: `structure.passthrough-default-drift`

- `summary`: `The unset value at {subject} differs from the default of the submodule variable it is forwarded to.`
- `suggested_fix`: `At {subject}, set the root side's unset value to the submodule's default.`

## `structure.feature-above-version-floor`

Engine: `candidate`

### Rule text: `structure.feature-above-version-floor`

**Fails when:**
- The change uses a core language function or block introduced after the declared `required_version`, calls a `provider::<name>::<fn>` function under a floor below 1.8, or uses a function or block only OpenTofu has in a module whose constraint admits Terraform, against [Version floors](../../../terraform-module-maintainer/profiles/terraform-aws-modules/code-conventions.md#version-floors).

**Severity:**
- HIGH when the change uses a core language feature the declared `required_version` does not reach (`structure.feature-above-version-floor`); the `summary` quotes the documentation page that gives the introducing version and the date it was read. This is the core language axis and `coverage.argument-above-min-version` in Check B is the provider-schema one, so they stay separate.

### Confirm when: `structure.feature-above-version-floor`

- The change adds the use of the function or block.
- Its introducing version is above the declared `required_version` floor; or it is a `provider::` function under a floor below 1.8; or it is OpenTofu only and the constraint admits Terraform.

### Host templates: `structure.feature-above-version-floor`

- `summary`: `{subject} uses a core language feature the declared required_version does not reach.`
- `suggested_fix`: `needs decision: (a) raise required_version for {subject} to the introducing version, a compat break for callers; (b) use a feature the floor has.`

## `structure.version-floor-understated`

Engine: `candidate`

### Rule text: `structure.version-floor-understated`

**Fails when:**
- A `versions.tf` the change touches declares a lower floor than the thing it calls - the root against a submodule under `modules/` it calls, or an example against the module it calls - against [Version floors](../../../terraform-module-maintainer/profiles/terraform-aws-modules/code-conventions.md#version-floors). Scope is those files and their counterparts; a caller declaring more than its callee is silent.

**Severity:**
- MEDIUM when a caller declares a lower floor than the thing it calls but the two constraint sets still intersect (`structure.version-floor-understated`): the configuration still initializes, and only a must-pass convention of the family is violated. CRITICAL when the two sets do not intersect at all - an upper bound excluding the callee's floor - because no version satisfies both and the configuration cannot initialize.

### Confirm when: `structure.version-floor-understated`

- The change touches the caller's or the callee's `versions.tf`.
- The caller's floor is below the callee's floor.
- The lead picks CRITICAL when the two constraint sets do not intersect, MEDIUM otherwise.

### Host templates: `structure.version-floor-understated`

- `summary`: `The caller at {subject} declares a lower version floor than the module it calls.`
- `suggested_fix`: `In the versions.tf of {subject}, raise the floor to the callee's, and remove an upper bound that excludes it.`

## `structure.arn-partition-hardcoded`

Engine: `candidate`

### Rule text: `structure.arn-partition-hardcoded`

**Fails when:**
- An ARN the change adds writes `arn:aws:` as a literal, or hard-codes an account ID or a region, where the module builds the ARN and `local.partition` is available or addable, against [ARNs and partitions](../../../terraform-module-maintainer/profiles/terraform-aws-modules/code-conventions.md#arns-and-partitions). A comment naming the partitions the literal is right for, carrying its source and date, is silent, and so is an ARN appearing inside a comment as an example of a format.

**Severity:**
- HIGH when an ARN the change adds hard-codes the partition, an account ID or a region the module could derive (`structure.arn-partition-hardcoded`).

### Confirm when: `structure.arn-partition-hardcoded`

- The ARN is added by the change, outside a comment.
- It writes `arn:aws:` as a literal, or a literal account ID or region, where the module builds the ARN.
- No comment names the partitions the literal is right for with a source and a date.

### Host templates: `structure.arn-partition-hardcoded`

- `summary`: `The ARN at {subject} hard-codes the partition, an account ID or a region the module could derive.`
- `suggested_fix`: `At {subject}, replace arn:aws: with arn:${local.partition}:, and a literal account or region with the module's local or input.`
