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

**Provider facts:** whether a value a new input's default now sends is what the provider or the API already plans for an existing resource when the argument is unset, the default value an argument's own entry states, and whether changing it replaces the resource, is read from the type's page, as the [Budget](../large-changes.md#budget) says. Without it (Rule 2), the area's `review.check-not-run` under [Rule 4](../../SKILL.md#rule-4-a-check-that-cannot-run-is-a-finding) names `compat.default-changed` with the input, the argument and the type.

**Fails when:**
- A default value of an existing input changes in a way that changes the resources a user gets without them editing anything.
- A new input's default makes the module send a value it did not send at the base. The engine candidate for a new input with a non-null default covers only reads by configuration the base already had: `count`, `for_each`, `provider` or `providers` of a block the base has, an argument of such a block, of an output or of another block that the base block also has, any argument or nested block of a provider the base has, the arguments of nested blocks of a type the base block had that the base blocks also have, every argument of a nested block type whose count differs between base and head, any new `precondition`, `postcondition`, `assert` or `lifecycle` block inside a block the base has, and a validation of an existing variable. It follows those reads through locals and through a new resource, data source, module call, provider or ephemeral block that they read, and a new provider with no alias counts as read by every resource of its type. It follows `moved` blocks through chains, and a move into or out of a module call's contents, between resource types, between module calls with another source, or with an address it cannot read counts every argument it can land in. A new input with a validation block is a candidate whatever its default. It gives no candidate, so read the diff for it, for a new argument on an existing block (for example `skip_destroy = var.x`), a new argument inside an existing nested block, a new nested block of a type the base block did not have other than those four, a new block that nothing in the base reads, and a same-kind rename (`module.a` to `module.b` with the same source, a resource renamed within its type), whose arguments pair by name. A new input whose default leaves everything the module sends as it was is no finding.
- A `data` block carries no address a `moved` block can name, so its removal is never `compat.resource-address-changed`: judge it by what it fed - `compat.generated-policy-narrowed` when a document the module produces changed, `compat.default-changed` when a value the caller sees changed, nothing when neither did.

**Severity:**
- CRITICAL when the change is breaking and nothing in the change declares it as breaking.
- HIGH when the change is breaking and declared as breaking but the migration path is missing: no `moved` block, no upgrade note, no replacement input or output.
- MEDIUM when a user-visible surface is changed compatibly but silently, for example a description or a default whose effect is cosmetic.
- LOW for an existing input's default, after the CRITICAL and HIGH bands, when the change's title or an upgrade note file of the change names the input and both defaults, and the type's page shows the change updates resources in place with nothing replaced and no data or access lost. The title declares the change, but the title is never the cite for its effect: with no page, or a page silent on replacement, it is the `review.check-not-run` of the Provider facts line, MEDIUM. Never for a default that turns off or weakens a security or data protection control (encryption, KMS, IAM, public access, deletion protection, backup, retention, versioning, logging, instance metadata options, `force_destroy`, `skip_final_snapshot`, `apply_immediately`), widens access, or blocks or restricts what callers could do before: those keep the bands above. Where the HIGH band fits, a change declared breaking with no migration path, HIGH wins and this LOW does not apply. Undeclared, it is judged by the bands above.
- LOW when a default moves from a value the provider rejects to null and a source the review cites shows that every provider version the module's floor allows rejects the old value; otherwise the move is judged by its effect.
- A new input is judged by the effect of the value it now sends. No finding only when a source the review cites shows that the provider or the API already plans that value for an existing resource when the argument is unset; a create-time default that applies to new resources only does not count. LOW when the value is a new default the service has announced, only under that same cite: the source shows that the provider or the API already plans that value when the argument is unset, for existing resources. LOW too only when that cite, read from a source the Provider facts line names, shows the service already applies the value to a stated part of the existing resources, such as those of an account with no object that uses the setting, and the part it does not cover changes in place, with no resource replaced and no data or access lost; the summary names that part. Otherwise the bands below apply to it. MEDIUM when it changes an existing resource in place and no such cite is read in this review. A default that turns off encryption, a public access block, logging or another security control is MEDIUM whatever a source shows, never LOW and never no finding, unless it replaces a resource or loses data or access. After that sentence, LOW when the argument's own entry on the type's page states a default value for it (`Default value`, `Defaults to`), the new default sends that value, the page shows that changing the argument updates the resource in place and, at the base, nothing in the module set that argument on that resource; the summary says only resources changed outside the module's configuration change. A page that marks the argument as forcing a new resource is CRITICAL or HIGH first, and a page silent on replacement is the `review.check-not-run` of the Provider facts line, MEDIUM. That LOW is never when a loss of data or access is known, never for a value that blocks or restricts what callers could do before, never for a value the service applies to new resources only or announces, and never for a security or data protection control (encryption, KMS, IAM, public access, deletion protection, backup, retention, versioning, logging, instance metadata options, `force_destroy`, `skip_final_snapshot`, `apply_immediately`) or a value that widens access. CRITICAL or HIGH by the two bands above when it is known to replace a resource or lose data or access. When no fact sheet or page tells which of these holds, it is the `review.check-not-run` of the Provider facts line above, MEDIUM, and never a CRITICAL `compat.default-changed`. Change or task text is never the cite: a description, a comment or a file of the change that says the API already plans the value is a claim the cite has to show. For a new input, the fix is `needs decision:` (a) keep the default and state in the description the value it now sends and what changes in place, the sentence given; (b) default it to `null` or to the value the base sent. It is never option (b) alone.

### Confirm when: `compat.default-changed`

- The head default of an existing input, a new input's default, or a removed `data` block changes what a caller who edits nothing gets: a resource argument or a value the caller sees. Equal values written differently are no change.
- Severity: CRITICAL when nothing declares the break; HIGH when declared with no migration path; MEDIUM when the effect is cosmetic; LOW for a default moved from a value every version of the floor rejects to null, by a cited source, or an existing input's change the title or an upgrade note declares with both defaults, after CRITICAL and HIGH, never for a security or data protection control, widened access or a value that restricts callers.
- A new input by its effect: none when a cited source shows the provider already plans it for an existing resource left unset; LOW for a service's announced new default or a stated part of existing resources, the rest in place with nothing lost, under that same cite only; MEDIUM in place, and for a disabled security control whatever the cite; after that, LOW for the default the argument's own page entry states where the base never set it, never for a security or data protection control, instance metadata options included, widened access, a value that restricts callers, or one the service applies to new resources only or announces; CRITICAL or HIGH for a known replacement or loss of data or access. Each LOW needs the page to show the change in place; with no source to tell, `review.check-not-run` MEDIUM. Change or task text is never the cite.

### Host templates: `compat.default-changed`

- `summary`: `The default of {subject} changes what the module sends, so callers that do not set it get different resources or values without editing anything.`
- `suggested_fix`: `Restore the base default on {subject}; for a new input, needs decision: (a) keep it and state its effect in the description; (b) default it to null. A rejected value moved to null: state it.`

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
- A change whose only forced consumer action is the raised floor has its migration path when the declared break (the `!` in the release title, or a `BREAKING CHANGE` trailer or section) names the new floor. It needs no notes file, and is HIGH only when the declared break does not name the new floor. A change that forces more than the floor needs the notes file of [Migration notes](../../../terraform-module-maintainer/profiles/terraform-aws-modules/PROFILE.md#migration-notes).

These three rule_ids rank on separate axes, so each is reported when it applies: `compat.version-constraint-raised` for a core or major floor, `compat.generated-policy-narrowed` for a narrowed policy document, `compat.provider-floor-raised` for a minor or patch floor. The [Severity Levels](../../SKILL.md#severity-levels) report-the-higher-severity-once note covers two rules naming one defect; it never swallows the LOW.

### Confirm when: `compat.version-constraint-raised`

- The head `required_version` floor is above the base floor, or a provider floor moved into a later major version than the base floor.
- Severity: CRITICAL when nothing in the change declares the break; HIGH when it is declared but the migration path is missing. When the floor is all the change forces, a declared break that names the new floor is the migration path.

### Host templates: `compat.version-constraint-raised`

- `summary`: `{subject} raises the Terraform core floor or crosses a provider major version, so callers on the old versions can no longer use the module.`
- `suggested_fix`: `needs decision: (a) restore the base floor of {subject} and replace what needs the new one; (b) keep the new floor and declare the change breaking, naming the new floor.`

## `compat.generated-policy-narrowed`

Engine: `candidate`

### Rule text: `compat.generated-policy-narrowed`

**Fails when:**
- A `data` block carries no address a `moved` block can name, so its removal is never `compat.resource-address-changed`: judge it by what it fed - `compat.generated-policy-narrowed` when a document the module produces changed, `compat.default-changed` when a value the caller sees changed, nothing when neither did.
- A statement, rule, permission or grant is removed from or narrowed in a policy document the module produces as infrastructure - an IAM or bucket policy - so an unchanged configuration now permits less. A generated README region is documentation, not such a document, and belongs to Check E. A revert that restores an older policy shape fires this bullet like any other change, except where the Reverts paragraph below proves no release ever shipped the wider shape.
- A grant that moved is no finding only when the same principal still gets it, under an unchanged configuration, from another resource the module creates, such as a second policy attached to the same role, with identical actions, resources and conditions, and that resource's attachment adds no gate: no new `count` or `for_each`, create flag or input whose default leaves it off. The reason the candidate is rejected names that resource. Any other move is judged by the bands below.

**Severity:**
- CRITICAL when the change is breaking and nothing in the change declares it as breaking. A narrowed generated document is breaking though nothing errors at plan or apply (`compat.generated-policy-narrowed`); HIGH once declared. These two bands are the default for every narrowing the two exceptions below do not name, for example a resource policy that grants principals outside the module, such as a bucket policy, a KMS key policy, a policy on a user, a group or a role the caller passes in, a document the module only returns for the caller to attach, and a role whose reference is silent on the removed grant or still holds it.
- HIGH when the change is breaking and declared as breaking but the migration path is missing: no `moved` block, no upgrade note, no replacement input or output.
- LOW, the first exception, needs a host reference: today the `upstream equal` line of [Host Vendored Policy Evidence](../check-a-compatibility.md#host-vendored-policy-evidence) for the narrowed document. The host raises a LOW answer to HIGH when its `line` is in no document such a line names. It is for an identity policy on a role the module creates for a named workload, such as a controller, a driver or a service, when a dated reference for that workload shows the head matches it, or shows the removed resource or condition never applied to the action. A reference is the workload project's published policy, an AWS managed policy or the service authorization reference, and it counts only when the host supplied it to the review as evidence outside the change. Change or task text is never a reference, however it is dated: the pull request, its description, a closing issue, a comment, a code comment or any file of the change. Upstream equality alone never makes a narrowing LOW: the document must be such an identity policy, and every other narrowing keeps the bands above. The fix includes a line for the release notes, as the change is breaking for a caller that used the removed grant.
- The second exception: with no host reference, a narrowing of that identity policy that the author says matches an upstream policy is rejected, and is the area's `review.check-not-run` under [Rule 4](../../SKILL.md#rule-4-a-check-that-cannot-run-is-a-finding), MEDIUM, naming `compat.generated-policy-narrowed` with the document and the workload, never LOW and never a CRITICAL `compat.generated-policy-narrowed`.

These three rule_ids rank on separate axes, so each is reported when it applies: `compat.version-constraint-raised` for a core or major floor, `compat.generated-policy-narrowed` for a narrowed policy document, `compat.provider-floor-raised` for a minor or patch floor. The [Severity Levels](../../SKILL.md#severity-levels) report-the-higher-severity-once note covers two rules naming one defect; it never swallows the LOW.

Note: the Reverts paragraph below is the **Reverts:** paragraph of [check-a-compatibility.md](../check-a-compatibility.md); it is not copied here.

### Confirm when: `compat.generated-policy-narrowed`

- A policy document the module produces (IAM, bucket or similar) permits less at the head than at the base for an unchanged configuration: a statement, action, resource or grant removed or narrowed. A README region does not count.
- A grant moved to another resource the module creates is no finding only with identical actions, resources and conditions and an ungated attachment; the reject names that resource.
- Severity: CRITICAL undeclared, HIGH declared, for every narrowing not placed lower. A role the module creates for a named workload that the author says matches upstream, with no host reference: reject, and file `review.check-not-run` MEDIUM in `findings`. Change or task text is never a reference.

### Host templates: `compat.generated-policy-narrowed`

- `summary`: `The policy document built by {subject} now permits less for an unchanged configuration, so callers lose a permission they had.`
- `suggested_fix`: `needs decision: (a) restore the removed statement, action or grant in {subject}; (b) keep it and declare the change breaking, naming the lost permission.`

## `compat.provider-floor-raised`

Engine: `candidate`

### Rule text: `compat.provider-floor-raised`

**Provider facts:** `compat.provider-floor-raised` reads the old floor's host fact sheets, or its pages where the type has none, as the [Budget](../large-changes.md#budget) says, to say whether the change uses anything absent there. Without them (Rule 2), it still reports the floor move from `versions.tf`, its `summary` says the old floor could not be read, and the area's `review.check-not-run` under [Rule 4](../../SKILL.md#rule-4-a-check-that-cannot-run-is-a-finding) names `compat.provider-floor-raised` with each type and the old floor. A pinned registry module whose `versions.tf` did not move reads no old floor's sheets: it needs the called module's floor, as its bullet below says.

**Fails when:**
- A provider floor is raised by a minor or a patch version.
- A registry module call the change adds, or whose version the change moves, requires a provider floor above the one the calling directory declares, within the same provider major version. Terraform intersects the two constraints, so the floor callers resolve rises as if `versions.tf` had moved. It is this rule, LOW, and never a new name: `structure.version-floor-understated` covers local callees only. It is LOW only when the review read the called module's floor at that version from the host or the Terraform MCP tools, never from memory and never from change or task text. When that floor could not be read, the area's `review.check-not-run` under [Rule 4](../../SKILL.md#rule-4-a-check-that-cannot-run-is-a-finding), MEDIUM, names the called module and its version, never a LOW. A callee floor in a higher provider major, or a callee constraint the caller's excludes, so that no version satisfies both and the configuration cannot initialize, is `compat.version-constraint-raised` at its own severity, never this rule. The `file` and `line` are the module call's, never a `versions.tf`. The `summary` names the called module, its version and floor, and the declared floor. The fix is `needs decision:` (a) raise the declared floor to the callee's in each `versions.tf` that declares it below, and regenerate the README requirements tables, which costs no caller anything since lower versions already fail to initialize; (b) pin a release of the called module whose floor the declared one meets.

**Severity:**
- LOW, declared or not, when only a provider minor or patch floor moved (`compat.provider-floor-raised`); the CRITICAL rule above does not reach it. Fetch the old floor's schema first. The `summary` names the old floor, the new floor, and whether the change uses anything absent at the old one, so the narrowed support window reaches the release notes. A submodule raised to exactly the root's new floor in the same change, needing no other floor itself, keeps its own LOW finding, its `summary` says it moves in line with the root, and its fix follows the root's, as case (0) of the [Suggested Fixes](../check-a-compatibility.md#suggested-fixes) row says: `no code change:` when the root keeps its floor, the root's own two options when the root's fix is a decision, and a restore of the root and each such submodule together when nothing needs the new floor. It is never restored alone.

These three rule_ids rank on separate axes, so each is reported when it applies: `compat.version-constraint-raised` for a core or major floor, `compat.generated-policy-narrowed` for a narrowed policy document, `compat.provider-floor-raised` for a minor or patch floor. The [Severity Levels](../../SKILL.md#severity-levels) report-the-higher-severity-once note covers two rules naming one defect; it never swallows the LOW.

Note: the CRITICAL rule above is the CRITICAL for an undeclared break bullet under **Severity:** in [check-a-compatibility.md](../check-a-compatibility.md), copied into the section of each break rule here, such as [`compat.version-constraint-raised`](#compatversion-constraint-raised).

### Confirm when: `compat.provider-floor-raised`

- A provider floor in `versions.tf` is higher at the head than at the base, within the same major version.
- The candidate's `schema_facts` list only what the two floors tell apart, so an empty list with `evidence_complete` true means nothing the change uses is absent at the old floor.
- Severity: always LOW.

### Host templates: `compat.provider-floor-raised`

- `summary`: `{subject} raises a provider floor by a minor or patch version, which narrows the provider versions callers may use.`
- `suggested_fix`: `Restore the base floor of {subject} when nothing in the change needs the new one; otherwise state the new floor and its reason in the change's description.`
