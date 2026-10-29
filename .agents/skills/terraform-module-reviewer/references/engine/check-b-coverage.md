# Engine Text: Check B

> **Part of:** [terraform-module-reviewer](../../SKILL.md), [Check B](../check-b-coverage.md)
> **Purpose:** The operative text of the Check B rules that [rule-facts.md](../rule-facts.md) marks `tool` or `candidate`, one section per rule. The full variant reads this file as part of Check B. A host injects one rule's section when that rule is `not_evaluated` for an area.

Everything else in [check-b-coverage.md](../check-b-coverage.md) still applies to these rules: what the check reads, what the schema is, Provider facts, [Which blocks](../check-b-coverage.md#which-blocks), [Documented omissions](../check-b-coverage.md#documented-omissions), the scope sentence and the Suggested Fixes rows. A sentence that covers several rules here is copied verbatim into each of their sections, so each section reads on its own. A sentence that also covers an `llm` rule stays in the check file as well.

Each section has three parts. **Rule text** is the check's text, moved here verbatim. **Confirm when** is the short criteria a confirmer applies to one candidate. **Host templates** are the `summary` and `suggested_fix` a host writes for a confirmed candidate, with `{subject}` filled from the candidate. Each template is one code span of at most 200 characters as written, `{subject}` included.

## `coverage.unknown-argument`

Engine: `candidate`

### Rule text: `coverage.unknown-argument`

**Fails when:**
- A `resource` or `data` block sets an argument that the schema does not have, or repeats a block past a limit the page's prose or a host fact sheet states.

**Severity:**
- CRITICAL when the `resource` or `data` block cannot be valid for ANY version the module allows: an argument absent from the latest schema, attribute syntax for a name the prose or a host fact sheet calls a block, or a block repeated past a stated limit. Nobody can apply it.

### Confirm when: `coverage.unknown-argument`

- The argument is absent from the latest schema of the type, or the block repeats past a limit the page or a host fact sheet states. Meta-arguments (`count`, `for_each`, `provider`, `depends_on`, `lifecycle`) do not count.
- A candidate can carry one more `schema_facts` entry at the latest version, whose `path` is the item's path, a colon and a flag. Such an entry is candidate evidence only: the bundle's `schema_coverage` section never lists it. It says why a name the schema has is a candidate:
  - `<path>:max_items_exceeded:<n>`, `present`: the block is written more than `n` times, the schema's `max_items`. Confirm.
  - `<path>:dynamic_count_unknown:<n>`, `unknown`: a `dynamic` block whose count is known only at plan, against `max_items` `n`. Confirm only when the page or the code shows it can pass `n`.
  - `<path>:block_syntax_for_attribute`, `present`: block syntax for a name the schema has as an attribute. Confirm unless it is a plain attribute the page types a list or set of object, which takes block syntax. A nested-type attribute never takes block syntax.
  - `<path>:computed_key`, `unknown`: an object key under the attribute known only at plan. Confirm only when the page or the code shows a key the attribute does not have.
- Severity: always CRITICAL.

### Host templates: `coverage.unknown-argument`

- `summary`: `{subject} is not in the provider schema at any version the module allows, or repeats a block past its limit, so no caller can apply it.`
- `suggested_fix`: `Remove {subject}, or rename it to the argument the page has when one was evidently meant; for a block past its limit remove the extra blocks.`

## `coverage.block-attribute-mismatch`

Engine: `candidate`

### Rule text: `coverage.block-attribute-mismatch`

**Fails when:**
- A `resource` or `data` block uses attribute syntax for a name the prose calls a block, or a host fact sheet lists as a block. Only then is it `coverage.block-attribute-mismatch`; for a name neither does, either syntax is no finding.

**Severity:**
- CRITICAL when the `resource` or `data` block cannot be valid for ANY version the module allows: an argument absent from the latest schema, attribute syntax for a name the prose or a host fact sheet calls a block, or a block repeated past a stated limit. Nobody can apply it.

### Confirm when: `coverage.block-attribute-mismatch`

- The code writes `<name> = ...` and the page prose or a host fact sheet calls `<name>` a block. A name neither calls a block is no finding.
- Severity: always CRITICAL.

### Host templates: `coverage.block-attribute-mismatch`

- `summary`: `{subject} is set with attribute syntax, but the provider documents it as a block, so the configuration is invalid.`
- `suggested_fix`: `Rewrite {subject} as a block, or as a dynamic block over the input that fed it.`

## `coverage.required-argument-unreachable`

Engine: `candidate`

### Rule text: `coverage.required-argument-unreachable`

**Fails when:**
- An argument or block the schema marks Required, on a `resource` or `data` block the change introduces or modifies, that no input the module exposes and no static value in the module can ever set. Where the caller supplies the value through an exposed input and the provider errors when they leave it out, that is the normal shape and not a finding. An `optional()` attribute or a `dynamic` block feeding a Required block is that shape too: the caller can set the value, and leaving it out fails at plan. An example that leaves the value out is `examples.example-broken` under Check D.

**Severity:**
- HIGH when a required argument is unreachable, a deprecated argument is newly used, or mutually exclusive arguments are unguarded.

### Confirm when: `coverage.required-argument-unreachable`

- The schema marks the argument or block Required, and no exposed input, `optional()` attribute, `dynamic` block or static value in the module can set it.
- Severity: always HIGH.

### Host templates: `coverage.required-argument-unreachable`

- `summary`: `{subject} is Required by the provider, but no module input or static value can set it, so the block fails at plan.`
- `suggested_fix`: `Add an input for {subject} and set the argument from it, or set the literal the page documents when the module always wants one value.`

## `coverage.optional-argument-unexposed`

Engine: `candidate`

### Rule text: `coverage.optional-argument-unexposed`

**Fails when:**
- An optional argument of a resource introduced by the change is neither an exposed input nor an omission documented with a reason, as [Documented omissions](../check-b-coverage.md#documented-omissions) reads one.

**Severity:**
- MEDIUM when an optional argument is neither exposed nor documented as an omission, or a stable computed attribute is simply not exposed by any output.

### Confirm when: `coverage.optional-argument-unexposed`

- The `resource` block is new in the change, the argument is Optional in the schema, nothing sets it from an input, and no documented omission covers it.
- Severity: always MEDIUM.

### Host templates: `coverage.optional-argument-unexposed`

- `summary`: `The optional argument {subject} is neither exposed as an input nor documented as an omission, so callers cannot set it.`
- `suggested_fix`: `Add an input for {subject} with a null default, or an optional() attribute on the object input, and set the argument from it; or document the omission.`

## `coverage.attribute-not-output`

Engine: `candidate`

### Rule text: `coverage.attribute-not-output`

**Fails when:**
- A stable, user-useful computed attribute of a resource introduced by the change has no output.

**Severity:**
- HIGH when an output the change adds or touches is wrong in a mode the module supports, for example reading an attribute the provider sets on only one branch, so a caller indexes an empty element (`coverage.attribute-not-output`).
- MEDIUM when an optional argument is neither exposed nor documented as an omission, or a stable computed attribute is simply not exposed by any output.

### Confirm when: `coverage.attribute-not-output`

- A stable, user-useful computed attribute of a `resource` new in the change has no output, or an output the change adds or touches yields no value in a mode the module supports.
- A block candidate's `schema_facts` are its computed attributes that no output reads; a second fact at the declared minimum shows a state there that differs from the latest. Confirm when any one is stable and user-useful, and name those attributes in the summary.
- Severity: HIGH for an output wrong in a supported mode; MEDIUM for an attribute with no output.

### Host templates: `coverage.attribute-not-output`

- `summary`: `{subject} has a stable computed attribute no output exposes, or is an output that yields no value in a mode the module supports.`
- `suggested_fix`: `If {subject} is a resource block, add an output for each stable computed attribute it lacks; if it is an output, change its expression so every supported mode yields a value or null.`

## `coverage.deprecated-argument`

Engine: `candidate`

### Rule text: `coverage.deprecated-argument`

**Fails when:**
- A deprecated argument is newly introduced by the change.

**Severity:**
- HIGH when a required argument is unreachable, a deprecated argument is newly used, or mutually exclusive arguments are unguarded.

### Confirm when: `coverage.deprecated-argument`

- The schema marks the argument deprecated, and the change adds it where the base did not set it.
- Severity: always HIGH.

### Host templates: `coverage.deprecated-argument`

- `summary`: `{subject} is deprecated in the provider schema and the change newly uses it.`
- `suggested_fix`: `Replace {subject} with the argument the page names as its replacement, or remove it when the page names none.`

## `coverage.argument-above-min-version`

Engine: `candidate`

### Rule text: `coverage.argument-above-min-version`

**Fails when:**
- An argument the change adds exists in the schema of the latest provider version but not in the schema at the module's declared minimum version, and the change does not raise that minimum.

**Severity:**
- HIGH when an added argument exists in the latest schema but is absent at the module's declared MINIMUM version.

### Confirm when: `coverage.argument-above-min-version`

- The argument is new in the change, present in the latest schema, absent in the schema at the declared minimum version, and the change leaves that minimum where it was.
- Severity: always HIGH.

### Host templates: `coverage.argument-above-min-version`

- `summary`: `{subject} exists in the latest provider schema but not at the module's declared minimum version, so callers on that minimum fail.`
- `suggested_fix`: `Raise the provider floor in versions.tf to the first version whose page lists {subject}, or remove the argument when that version is a later major.`
