# Engine Text: Check A

> **Part of:** [terraform-module-reviewer](../../SKILL.md), [Check A](../check-a-compatibility.md)
> **Purpose:** The operative text of the Check A rules that [rule-facts.md](../rule-facts.md) marks `tool` or `candidate`, one section per rule. The full variant reads this file as part of Check A. A host injects one rule's section when that rule is `not_evaluated` for an area.

Everything else in [check-a-compatibility.md](../check-a-compatibility.md) still applies to these rules: what the check reads, the Reverts exemption, No base and the Suggested Fixes rows. A sentence that covers several rules here is copied verbatim into each of their sections, so each section reads on its own.

Each section has three parts. **Rule text** is the check's text, moved here verbatim. **Confirm when** is the short criteria a confirmer applies to one candidate. **Host templates** are the `summary` and `suggested_fix` a host writes for a confirmed candidate, with `{subject}` filled from the candidate. Each template is one code span of at most 200 characters as written, `{subject}` included.

## `compat.variable-removed`

Engine: `candidate`

### Rule text: `compat.variable-removed`

**Fails when:**
- A variable or output is removed or renamed.

**Severity:**
- CRITICAL when the change is breaking and nothing in the change declares it as breaking.
- HIGH when the change is breaking and declared as breaking but the migration path is missing: no `moved` block, no upgrade note, no replacement input or output.

### Confirm when: `compat.variable-removed`

- A variable or output at the base has no variable or output of the same name at the head in the same area.
- Severity: CRITICAL when nothing in the change declares the break; HIGH when it is declared but the migration path is missing.

### Host templates: `compat.variable-removed`

- `summary`: `{subject} is removed or renamed, so every caller that sets or reads it fails at plan.`
- `suggested_fix`: `Restore {subject} with its base type, default and description; for a rename keep the old name, deprecated in its description, feeding the new one.`

## `compat.variable-now-required`

Engine: `candidate`

### Rule text: `compat.variable-now-required`

**Fails when:**
- A variable gains `nullable = false`, loses its `default`, or otherwise becomes required.

**Severity:**
- CRITICAL when the change is breaking and nothing in the change declares it as breaking.
- HIGH when the change is breaking and declared as breaking but the migration path is missing: no `moved` block, no upgrade note, no replacement input or output.

### Confirm when: `compat.variable-now-required`

- A caller that set nothing for the variable at the base must set it at the head: its `default` is gone, it gained `nullable = false`, or it is new with no `default`.
- Severity: CRITICAL when nothing in the change declares the break; HIGH when it is declared but the migration path is missing.

### Host templates: `compat.variable-now-required`

- `summary`: `{subject} is now required, so every caller that did not set it fails at plan.`
- `suggested_fix`: `Restore the base default, or remove the added nullable = false, on {subject}.`

## `compat.type-narrowed`

Engine: `candidate`

### Rule text: `compat.type-narrowed`

**Fails when:**
- A variable type is narrowed, or a `validation` block is added or tightened so that input that was valid before is now rejected.

**Severity:**
- CRITICAL when the change is breaking and nothing in the change declares it as breaking.
- HIGH when the change is breaking and declared as breaking but the migration path is missing: no `moved` block, no upgrade note, no replacement input or output.

### Confirm when: `compat.type-narrowed`

- Some value the base type and validation accepted is rejected at the head. An equal type written differently, or `optional()` with a default that keeps old input valid, is not a narrowing.
- Severity: CRITICAL when nothing in the change declares the break; HIGH when it is declared but the migration path is missing.

### Host templates: `compat.type-narrowed`

- `summary`: `{subject} now rejects input its base type or validation accepted, so existing callers can fail at plan.`
- `suggested_fix`: `Restore the base type, or the base validation condition, on {subject}.`

## `compat.default-changed`

Engine: `candidate`

### Rule text: `compat.default-changed`

**Fails when:**
- A default value changes in a way that changes the resources a user gets without them editing anything.
- A `data` block carries no address a `moved` block can name, so its removal is never `compat.resource-address-changed`: judge it by what it fed - `compat.generated-policy-narrowed` when a document the module produces changed, `compat.default-changed` when a value the caller sees changed, nothing when neither did.

**Severity:**
- CRITICAL when the change is breaking and nothing in the change declares it as breaking.
- HIGH when the change is breaking and declared as breaking but the migration path is missing: no `moved` block, no upgrade note, no replacement input or output.
- MEDIUM when a user-visible surface is changed compatibly but silently, for example a description or a default whose effect is cosmetic.

### Confirm when: `compat.default-changed`

- The head default, or a removed `data` block, changes what a caller who edits nothing gets: a resource argument or a value the caller sees. Equal values written differently are no change.
- Severity: CRITICAL when nothing declares the break; HIGH when declared with no migration path; MEDIUM when the effect is cosmetic.

### Host templates: `compat.default-changed`

- `summary`: `The default of {subject} changed, so callers that do not set it get different resources or values without editing anything.`
- `suggested_fix`: `Restore the base default on {subject} and make the new behaviour an opt-in value of it or of a new input.`

## `compat.resource-address-changed`

Engine: `candidate`

### Rule text: `compat.resource-address-changed`

**Fails when:**
- A resource is removed, renamed, or has its address changed (for example a move into or out of `for_each`, or between a root resource and a submodule) with no `moved` block. A `data` block carries no address a `moved` block can name, so its removal is never `compat.resource-address-changed`: judge it by what it fed - `compat.generated-policy-narrowed` when a document the module produces changed, `compat.default-changed` when a value the caller sees changed, nothing when neither did.

**Severity:**
- CRITICAL when the change is breaking and nothing in the change declares it as breaking.
- HIGH when the change is breaking and declared as breaking but the migration path is missing: no `moved` block, no upgrade note, no replacement input or output.

### Confirm when: `compat.resource-address-changed`

- A managed resource address present at the base is absent at the head, and no `moved` block maps it, per instance key when `count` or `for_each` changed. A `data` block never counts.
- Severity: CRITICAL when nothing in the change declares the break; HIGH when it is declared but the migration path is missing.

### Host templates: `compat.resource-address-changed`

- `summary`: `{subject} changed address with no moved block, so existing state plans a destroy and a create.`
- `suggested_fix`: `Add a moved block from the base address to the head address of {subject}, one per instance key when count or for_each changed.`

## `compat.version-constraint-raised`

Engine: `candidate`

### Rule text: `compat.version-constraint-raised`

**Fails when:**
- A Terraform core `required_version` floor is raised, or a provider floor crosses a major version.

**Severity:**
- CRITICAL when the change is breaking and nothing in the change declares it as breaking.
- HIGH when the change is breaking and declared as breaking but the migration path is missing: no `moved` block, no upgrade note, no replacement input or output.

These three rule_ids rank on separate axes, so each is reported when it applies: `compat.version-constraint-raised` for a core or major floor, `compat.generated-policy-narrowed` for a narrowed policy document, `compat.provider-floor-raised` for a minor or patch floor. The [Severity Levels](../../SKILL.md#severity-levels) report-the-higher-severity-once note covers two rules naming one defect; it never swallows the LOW.

### Confirm when: `compat.version-constraint-raised`

- The head `required_version` floor is above the base floor, or a provider floor moved into a later major version than the base floor.
- Severity: CRITICAL when nothing in the change declares the break; HIGH when it is declared but the migration path is missing.

### Host templates: `compat.version-constraint-raised`

- `summary`: `{subject} raises the Terraform core floor or crosses a provider major version, so callers on the old versions can no longer use the module.`
- `suggested_fix`: `needs decision: (a) restore the base floor of {subject} and replace what needs the new one; (b) keep the new floor and declare the change breaking.`

## `compat.generated-policy-narrowed`

Engine: `candidate`

### Rule text: `compat.generated-policy-narrowed`

**Fails when:**
- A `data` block carries no address a `moved` block can name, so its removal is never `compat.resource-address-changed`: judge it by what it fed - `compat.generated-policy-narrowed` when a document the module produces changed, `compat.default-changed` when a value the caller sees changed, nothing when neither did.
- A statement, rule, permission or grant is removed from or narrowed in a policy document the module produces as infrastructure - an IAM or bucket policy - so an unchanged configuration now permits less. A generated README region is documentation, not such a document, and belongs to Check E. A revert that restores an older policy shape fires this bullet like any other change, except where the Reverts paragraph below proves no release ever shipped the wider shape.

**Severity:**
- CRITICAL when the change is breaking and nothing in the change declares it as breaking. A narrowed generated document is breaking though nothing errors at plan or apply (`compat.generated-policy-narrowed`); HIGH once declared.
- HIGH when the change is breaking and declared as breaking but the migration path is missing: no `moved` block, no upgrade note, no replacement input or output.

These three rule_ids rank on separate axes, so each is reported when it applies: `compat.version-constraint-raised` for a core or major floor, `compat.generated-policy-narrowed` for a narrowed policy document, `compat.provider-floor-raised` for a minor or patch floor. The [Severity Levels](../../SKILL.md#severity-levels) report-the-higher-severity-once note covers two rules naming one defect; it never swallows the LOW.

Note: the Reverts paragraph below is the **Reverts:** paragraph of [check-a-compatibility.md](../check-a-compatibility.md); it is not copied here.

### Confirm when: `compat.generated-policy-narrowed`

- A policy document the module produces (IAM, bucket or similar) permits less at the head than at the base for an unchanged configuration: a statement, action, resource or grant removed or narrowed. A README region does not count.
- Severity: CRITICAL when nothing in the change declares the break; HIGH once declared.

### Host templates: `compat.generated-policy-narrowed`

- `summary`: `The policy document built by {subject} now permits less for an unchanged configuration, so callers lose a permission they had.`
- `suggested_fix`: `needs decision: (a) restore the removed statement, action or grant in {subject}; (b) keep it and declare the change breaking, naming the lost permission.`

## `compat.provider-floor-raised`

Engine: `candidate`

### Rule text: `compat.provider-floor-raised`

**Provider facts:** `compat.provider-floor-raised` reads the old floor's host fact sheets, or its pages where the type has none, as the [Budget](../large-changes.md#budget) says, to say whether the change uses anything absent there. Without them (Rule 2), it still reports the floor move from `versions.tf`, its `summary` says the old floor could not be read, and the area's `review.check-not-run` under [Rule 4](../../SKILL.md#rule-4-a-check-that-cannot-run-is-a-finding) names `compat.provider-floor-raised` with each type and the old floor.

**Fails when:**
- A provider floor is raised by a minor or a patch version.

**Severity:**
- LOW, declared or not, when only a provider minor or patch floor moved (`compat.provider-floor-raised`); the CRITICAL rule above does not reach it. Fetch the old floor's schema first. The `summary` names the old floor, the new floor, and whether the change uses anything absent at the old one, so the narrowed support window reaches the release notes.

These three rule_ids rank on separate axes, so each is reported when it applies: `compat.version-constraint-raised` for a core or major floor, `compat.generated-policy-narrowed` for a narrowed policy document, `compat.provider-floor-raised` for a minor or patch floor. The [Severity Levels](../../SKILL.md#severity-levels) report-the-higher-severity-once note covers two rules naming one defect; it never swallows the LOW.

Note: the CRITICAL rule above is the CRITICAL for an undeclared break bullet under **Severity:** in [check-a-compatibility.md](../check-a-compatibility.md), copied into the section of each break rule here, such as [`compat.version-constraint-raised`](#compatversion-constraint-raised).

### Confirm when: `compat.provider-floor-raised`

- A provider floor in `versions.tf` is higher at the head than at the base, within the same major version.
- The candidate's `schema_facts` list only what the two floors tell apart, so an empty list with `evidence_complete` true means nothing the change uses is absent at the old floor.
- Severity: always LOW.

### Host templates: `compat.provider-floor-raised`

- `summary`: `{subject} raises a provider floor by a minor or patch version, which narrows the provider versions callers may use.`
- `suggested_fix`: `Restore the base floor of {subject} when nothing in the change needs the new one; otherwise state the new floor and its reason in the change's description.`
