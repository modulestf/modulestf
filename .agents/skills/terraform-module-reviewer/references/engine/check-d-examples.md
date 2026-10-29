# Engine Text: Check D

> **Part of:** [terraform-module-reviewer](../../SKILL.md), [Check D](../check-d-examples.md)
> **Purpose:** The operative fails-when and severity text of the Check D rules whose `engine` in [rule-facts.md](../rule-facts.md) is `tool` or `candidate`, moved here verbatim from the check file. The full variant reads this file as part of Check D.

Each rule has one section. **Rule text** is the moved text; a sentence that also covers an `llm` rule stays in the check file and is copied here, so each section stands alone. **Confirm when** is the short criteria a confirmer applies to one candidate. **Host templates** are the `summary` and `suggested_fix` the host writes for a confirmed candidate, with `{subject}` filled from the candidate. Each template is one code span of at most 200 characters as written, with `{subject}` unfilled.

## `examples.stale-reference`

Engine: `candidate`

### Rule text: `examples.stale-reference`

**Fails when:**
- An example references a variable or output that the change removed or renamed, so the example can no longer initialize.
- An example uses invented input names instead of real module variables.

**Severity:**
- HIGH when an example is broken by the change before or during apply (`examples.example-broken`), requires custom Terraform inputs or edits (`examples.custom-input-required`), or a submodule added by the change has no example. A verification record showing a failed plan is evidence for that HIGH, and its decisive error line is quoted in the `summary`. Only a failure new under this change reaches HIGH; one the record marks as reproducing at the base is the LOW above.

### Confirm when: `examples.stale-reference`

- An example reads a module input or output the change removed or renamed, or sets an input name the called module does not declare.
- The name is in the example's `.tf` code, not in a comment.

### Host templates: `examples.stale-reference`

- `summary`: `Example {subject} references a module input or output that does not exist at the head, so it can no longer initialize.`
- `suggested_fix`: `In {subject}, change the reference to the input or output that replaced it, or remove it when nothing replaced it.`

## `examples.submodule-missing`

Engine: `candidate`

### Rule text: `examples.submodule-missing`

**Fails when:**
- A submodule added by the change has no example of its own.

**Severity:**
- HIGH when an example is broken by the change before or during apply (`examples.example-broken`), requires custom Terraform inputs or edits (`examples.custom-input-required`), or a submodule added by the change has no example. A verification record showing a failed plan is evidence for that HIGH, and its decisive error line is quoted in the `summary`. Only a failure new under this change reaches HIGH; one the record marks as reproducing at the base is the LOW above.

### Confirm when: `examples.submodule-missing`

- The submodule directory is added by the change.
- No directory under `examples/` calls it.

### Host templates: `examples.submodule-missing`

- `summary`: `Submodule {subject} is added by the change and has no example of its own.`
- `suggested_fix`: `Add an example for {subject} with a main.tf calling it, a module "disabled" call with create = false, a versions.tf and a README.md.`

## `examples.disabled-call-missing`

Engine: `candidate`

### Rule text: `examples.disabled-call-missing`

**Fails when:**
- The complete example has no `module "disabled"` call with `create = false`.

**Severity:**
- MEDIUM when a feature added by the change is demonstrated nowhere (`examples.feature-undemonstrated`), or the disabled call is missing.

### Confirm when: `examples.disabled-call-missing`

- The example is the complete example.
- None of its `module` blocks is named `disabled` and sets `create = false`.

### Host templates: `examples.disabled-call-missing`

- `summary`: `The complete example {subject} has no module "disabled" call with create = false.`
- `suggested_fix`: `Add module "disabled" to the main.tf of {subject}, with the same source and create = false.`

## `examples.versions-missing`

Engine: `tool`

### Rule text: `examples.versions-missing`

**Fails when:**
- An example is missing its own `versions.tf`, its `README.md`, or the documentation markers in that README.

**Severity:**
- MEDIUM when an example has no `versions.tf`, or carries one under a name its sibling examples do not use (`examples.versions-missing`).

### Confirm when: `examples.versions-missing`

- The example directory has no `versions.tf`, or names it differently from its sibling examples.

### Host templates: `examples.versions-missing`

- `summary`: `Example {subject} has no versions.tf, or names it differently from its sibling examples.`
- `suggested_fix`: `Add versions.tf to {subject}, copied from a sibling example, or rename the file to the name its siblings use.`
