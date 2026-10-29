# Check B: Coverage Gaps Against the Provider Schema

> **Part of:** [terraform-module-reviewer](../SKILL.md)
> **Purpose:** The operative fails-when and severity rules of Check B. Rule numbers refer to the [Mandatory Rules](../SKILL.md#mandatory-rules) in SKILL.md.
> **Engine text:** the text of the rules [rule-facts.md](rule-facts.md) marks `tool` or `candidate` is in [engine/check-b-coverage.md](engine/check-b-coverage.md), one section per rule. It is part of this check: read it with this file.

**Reads:** every `resource` and `data` block the change adds or edits in `main.tf` and sibling `.tf` files, as [Which blocks](#which-blocks) scopes them, the literals the change sets in `examples/`, the current `variables.tf` and `outputs.tf`, and the provider schema fetched per Rule 2. Also `versions.tf` for the declared minimum provider version, plus a second schema fetch pinned to that version: two fetches, one per version, the pattern the maintainer's [Step 2: Schema Diff](../../terraform-module-maintainer/SKILL.md#step-2-schema-diff) already sets out.

In this file the schema is what Rule 2's tools return: the provider's documentation page for one type at one version. Check B takes from it the argument and block names, the Required and Optional markers, the names the prose calls a block (a "configuration block", or a section headed as a `Block`), the exported attributes, whether the type is documented at that version, and whatever the prose states: value sets, deprecations, conflicts between arguments. It never takes an argument type or a nesting mode from it, because the page has neither unless its prose says so. A section of its own does not make a name a block: the same nested name is headed ``### `posix_user` Block`` on one version's page and `### posix_user` on another's, and a nested object attribute gets a section too. A name the prose does not call a block is unknown, block or attribute. A rule below that would need one does not fire, and a quoted claim that needs one, such as an ARN where an ID is expected, stays `review.quoted-claim-unverifiable` under [quoted-claims.md](quoted-claims.md), never a finding.

When the host gives a [host fact sheet](large-changes.md#budget) for a type, Check B takes the argument and block names, the required, optional, computed and deprecated flags and the exported attributes from it; a name it lists as a block is a block, and its minimum and maximum items are stated limits. Value sets, conflicts, validator limits, documented defaults and the other page facts come only from the page, which the run reads where [rule-facts.md](rule-facts.md) says a rule needs one. Its argument types and nesting modes enter no rule.

**Provider facts:** every rule below rests on the page, or on the host fact sheet where [rule-facts.md](rule-facts.md) says the sheet serves it. Without it, for any reason - the tools unreachable, the type not resolvable, the entry past the [budget](large-changes.md#budget) - none of them runs on that type, and the `review.check-not-run` of [Rule 4](../SKILL.md#rule-4-a-check-that-cannot-run-is-a-finding) names each `coverage.*` rule that had a block, output or literal to decide there, with the type and version.

## Which blocks

A `data` block is configuration the provider validates like a `resource` block, and a defect in it fails the plan the same way. So the rules that judge whether a block is valid read both kinds: an unknown argument or a block repeated past a stated limit, attribute syntax for a block, a Required argument nothing can set, a newly used deprecated argument, an argument above the declared minimum, an unguarded mutually exclusive pair, a default for a Required argument, and a literal outside the documented value set. A `dynamic` block counts as the block it generates, so a pair that one `dynamic "statement"` fills from the same input object is a pair in one block.

The two rules that judge what a caller can reach read `resource` blocks only: an optional argument left unexposed and a computed attribute with no output. A data source's optional arguments are query filters the module chooses, and its attributes feed the module, not its callers.

A block the change adds has no base, and every rule above applies to it. In a block the change edits, a rule fires only when the defect holds for the block at the head and does not hold for the same block at the base, so a change that narrows a defect it did not create is not charged with it. Read the base as [Check F reads it](check-f-scope.md#the-base-revision): the base reference, or the diff's hunks for that file read in reverse. When the block has no readable base, because the task gives no base reference and no hunks for its file, it is judged as an added block: a base that cannot be read cannot show the defect was already there. This is the scope sentence below, applied to `resource` and `data` blocks alike.

## Documented omissions

An optional argument or block is an omission documented with a reason when the module says why, in a comment beside the resource block or in the directory's `README.md`. One reason needs no text from the module: the provider page at the latest version states that the argument or block must not be used together with a separate resource type, and the module manages that type for the same object. It does when a `resource` block of the separate type sits in the same directory and an expression in its arguments names the resource that omits the argument, directly or through locals, never through a variable, as [Reference edges](../../terraform-module-maintainer/references/module-scope.md#reference-edges) traces a path. `aws_security_group.this` with no inline `ingress` or `egress`, in a directory whose `aws_vpc_security_group_ingress_rule` sets `security_group_id = aws_security_group.this[0].id`, is that case. The warning alone is no reason: when no block of the separate type names the resource, the omission needs its own.

## Rules

The coverage rules are the maintainer's, not this skill's: [Coverage Checklist](../../terraform-module-maintainer/references/coverage-checklist.md) and [Schema Validation Guide](../../terraform-module-maintainer/references/schema-validation.md).

**Fails when:**
- `coverage.unknown-argument`: moved to [engine/check-b-coverage.md](engine/check-b-coverage.md#coverageunknown-argument).
- `coverage.block-attribute-mismatch`: moved to [engine/check-b-coverage.md](engine/check-b-coverage.md#coverageblock-attribute-mismatch).
- `coverage.required-argument-unreachable`: moved to [engine/check-b-coverage.md](engine/check-b-coverage.md#coveragerequired-argument-unreachable).
- `coverage.optional-argument-unexposed`: moved to [engine/check-b-coverage.md](engine/check-b-coverage.md#coverageoptional-argument-unexposed).
- `coverage.attribute-not-output`: moved to [engine/check-b-coverage.md](engine/check-b-coverage.md#coverageattribute-not-output).
- `coverage.deprecated-argument`: moved to [engine/check-b-coverage.md](engine/check-b-coverage.md#coveragedeprecated-argument).
- `coverage.argument-above-min-version`: moved to [engine/check-b-coverage.md](engine/check-b-coverage.md#coverageargument-above-min-version).
- A mutually exclusive pair from the schema can both be set at once with no validation or precondition preventing it.
- The change defaults an input backing an argument the schema marks Required, `optional(type, value)` included, and that default is the more permissive documented value or contradicts the one the provider documents.
- A literal in the module or an example sits outside the value set the schema documents for that argument.

Scope is the change. Pre-existing gaps in resources the change does not touch are out of scope unless the task asks for a full coverage pass.

**Severity:**
- CRITICAL for a block no allowed version accepts: moved to `coverage.unknown-argument` and `coverage.block-attribute-mismatch` in [engine/check-b-coverage.md](engine/check-b-coverage.md).
- HIGH when a required argument is unreachable, a deprecated argument is newly used, or mutually exclusive arguments are unguarded. HIGH too when the module defaults an argument the schema marks Required (`coverage.default-for-required-argument`).
- HIGH for an argument above the declared minimum: moved to `coverage.argument-above-min-version` in [engine/check-b-coverage.md](engine/check-b-coverage.md#coverageargument-above-min-version).
- HIGH for an output wrong in a supported mode: moved to `coverage.attribute-not-output` in [engine/check-b-coverage.md](engine/check-b-coverage.md#coverageattribute-not-output).
- MEDIUM for an unexposed optional argument or computed attribute: moved to `coverage.optional-argument-unexposed` and `coverage.attribute-not-output` in [engine/check-b-coverage.md](engine/check-b-coverage.md).
- LOW when a literal sits outside the documented value set (`coverage.enum-value-unknown`). Name the value and the set and ask which is stale; never assert the code is wrong.
- MEDIUM when the schema could not be fetched, via `review.check-not-run` under Rule 4, or fell past the cap, as the [budget](large-changes.md#budget) sets out. That includes fetching the latest schema but not the one at the declared minimum: the version comparison then did not run. The finding names the rules it leaves unevaluated, as **Provider facts** above says, never only the check.
- No finding, at any severity, on an argument type or a nesting mode the page does not state.

`rule_id` prefix: `coverage.`, for example `coverage.unknown-argument`, `coverage.block-attribute-mismatch`, `coverage.required-argument-unreachable`, `coverage.deprecated-argument`, `coverage.optional-argument-unexposed`, `coverage.attribute-not-output`, `coverage.mutual-exclusion-unguarded`, `coverage.argument-above-min-version`, `coverage.default-for-required-argument`, `coverage.enum-value-unknown`.

## Suggested Fixes

Each row gives the fix a finding of that rule carries, in the forms of the [Suggested Fix Contract](findings-schema.md#suggested-fix-contract). `<...>` is what the finding fills in from its own evidence. A rule marked `needs decision` opens its fix with that prefix and lists the options; the maintainer skill applies none of them until a person chooses. A fix that adds an input names its type when the page or the code determines it, and otherwise leaves it to the maintainer, as the contract's [What](findings-schema.md#suggested-fix-contract) item says. A fix that adds or changes an input or an output also names the generated content it makes stale, as the contract's Generated content item says.

| `rule_id` | Form | The fix |
|-----------|------|---------|
| `coverage.unknown-argument` | code change | Remove the argument from `resource "<type>" "<name>"`. When the page has an argument the author evidently meant, rename it to that name instead, and say which. For a block repeated past a stated limit, remove the extra blocks or the input that generates them. |
| `coverage.block-attribute-mismatch` | code change | Rewrite `<name> = ...` as a `<name> { }` block, or as a `dynamic "<name>"` block over the input that fed it, per [Dynamic Block Patterns](../../terraform-module-maintainer/references/module-structure.md#dynamic-block-patterns). |
| `coverage.required-argument-unreachable` | code change | Add an input for the argument, named, per [Variables Patterns](../../terraform-module-maintainer/references/module-structure.md#variables-patterns), and set the argument from it. When the module always wants one value the page documents, set that literal instead. |
| `coverage.optional-argument-unexposed` | code change | Add an input for the argument with a `null` default, or an `optional()` attribute on the object input that feeds the block, and set the argument from it. When exposing it is out of the module's scope under the maintainer's scope rules, a comment beside the block giving that reason instead. |
| `coverage.attribute-not-output` | code change | MEDIUM: add `output "<name>"` reading the attribute, per [Expose Stable, User-Useful Computed Attributes](../../terraform-module-maintainer/references/module-structure.md#expose-stable-user-useful-computed-attributes). HIGH: change the named output's expression so every mode the module supports yields a value or null, per [Conditional Outputs with try()](../../terraform-module-maintainer/references/module-structure.md#conditional-outputs-with-try). |
| `coverage.deprecated-argument` | code change | Replace the argument with the one the page names as its replacement, or remove it when the page names none. |
| `coverage.argument-above-min-version` | code change or needs decision | Raise the provider floor in `versions.tf` to the first version whose page lists the argument, named. That raise is a `compat.provider-floor-raised` LOW. When that version is in a later major than the floor, `needs decision:` (a) raise the floor, a breaking change; (b) remove the argument. |
| `coverage.mutual-exclusion-unguarded` | code change | Add a `validation` block when both arguments come from one input, otherwise a `precondition` in the resource's `lifecycle`, rejecting both set at once, per [Preconditions for Cross-Field Invariants](../../terraform-module-maintainer/references/module-structure.md#preconditions-for-cross-field-invariants), with an `error_message` naming both. |
| `coverage.default-for-required-argument` | code change | Set the default to the value the page documents, named, or remove the default when the page documents none, so the caller has to choose. |
| `coverage.enum-value-unknown` | needs decision | Whether the literal or the page is stale: (a) change the literal to one of the documented values, listed; (b) keep it, with a comment giving the source that shows the value is accepted and the date it was read. |
| `review.check-not-run` | `no code change:` | The schema the check needed, by type and version, and the rules it left unevaluated. |
