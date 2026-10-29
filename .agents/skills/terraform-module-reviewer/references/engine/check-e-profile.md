# Engine Text: Check E

> **Part of:** [terraform-module-reviewer](../../SKILL.md), through [Check E: Profile Conventions](../check-e-profile.md)
> **Purpose:** The operative text of the Check E rules whose `engine` in [rule-facts.md](../rule-facts.md) is `tool` or `candidate`, moved here verbatim from the check file. The full variant reads this file as part of Check E. Each rule also carries the short criteria a confirmer reads and the fixed host templates for a confirmed finding.

Each rule has three sections. **Rule text** holds the moved sentences under their **Fails when:** and **Severity:** labels; a sentence that also covers an `llm` rule stays in the check file and is copied here, and a sentence shared by several rules here is copied into each of them, so every section stands alone. **Confirm when** gives the short criteria. **Host templates** gives the `summary` and `suggested_fix` the host fills with the finding's subject: each template is one code span, at most 200 characters as written with `{subject}` unfilled. Links in the moved text point to the same targets as in the check file. The Suggested Fixes rows stay in [the check file](../check-e-profile.md#suggested-fixes).

## `profile.template-drift`

Engine: `candidate`

### Rule text: `profile.template-drift`

**Fails when:**
- A static file the profile owns is added or edited by hand in a way that diverges from the template, with no stated reason. The static files are the verbatim class of [Profile-owned files](../../../terraform-module-maintainer/profiles/terraform-aws-modules/scope.md#profile-owned-files); `.pre-commit-config.yaml` is not one of them and is not compared with its template, as [Quality gate](../../../terraform-module-maintainer/profiles/terraform-aws-modules/PROFILE.md#quality-gate) reads. Version pins are left out of the comparison, in either direction: the version after `@` in a `uses:`, and a tool version a workflow installs. A file that differs from its template only in pins is no `profile.template-drift`, the same reading as [Profile-owned files](../../../terraform-module-maintainer/profiles/terraform-aws-modules/scope.md#profile-owned-files) and [Quality gate](../../../terraform-module-maintainer/profiles/terraform-aws-modules/PROFILE.md#quality-gate). Everything else in the file is still compared with the template. A pin the change lowers against the base is not template drift either; whether it is a finding is an open question in [scope.md](../../../terraform-module-maintainer/profiles/terraform-aws-modules/scope.md#open-questions). A pin that moves the version of a generator is read by the generated-content bullet below.

Note: the generated-content bullet below is the **Fails when:** bullet in [check-e-profile.md](../check-e-profile.md) on a generated region or `wrappers/` file in a change that also moves the version of its generator; it is not copied here.

**Severity** (copied from the check file, shared with `llm` rules):
- MEDIUM when a profile-owned file drifts from its template with no stated reason, a required file is missing, or migration notes sit in `README.md` instead of their own file under `docs/`.
- LOW when the divergence is cosmetic.

### Confirm when: `profile.template-drift`

- The file is in the Static Files table of the templates map, and the change adds or edits it. `.pre-commit-config.yaml` is not.
- At least one line differs from the template after version pins are set aside.
- The change states no reason for the divergence. A stated reason is the lead's to read: escalate when any prose accompanies the change.
- Severity: MEDIUM when the divergence changes or adds behaviour; LOW when it is cosmetic, such as whitespace, order or comments.

### Host templates: `profile.template-drift`

- `summary`: `{subject} diverges from its profile template beyond version pins, with no stated reason.`
- `suggested_fix`: `needs decision: (a) restore the lines of {subject} that differ from its template, keeping the version pins; (b) keep them, with the reason stated in the change's description.`

## `profile.required-file-missing`

Engine: `tool`

### Rule text: `profile.required-file-missing`

**Fails when:**
- The change omits a file the profile requires for the kind of module being changed.
  - **A new module**, the task shape in [Inputs](../../SKILL.md#inputs): the whole create-time file set of [Module layout](../../../terraform-module-maintainer/profiles/terraform-aws-modules/PROFILE.md#module-layout) applies, and its allowance for older modules does not. That covers its paragraphs on the root, on the dotfiles and workflows, on `examples/basic/` and `examples/complete/`, and on each `modules/<name>/`. A required path that is absent, or present only under another name or in another place, is `profile.required-file-missing`: one finding per required path, `file` that path and `line` null. A missing example or submodule directory is one finding for the directory, not one per file in it. `tests/` and `wrappers/` are not required paths.
  - Four requirements of the same section are not missing files and take other rule_ids: a `LICENSE` that is present and not Apache 2.0 is `profile.layout-divergence`, at the severity of a missing required file; a complete example without its `module "disabled"` call is Check D's `examples.disabled-call-missing`; a submodule without an example of its own is Check D's `examples.submodule-missing`; and a root without the `putin_khuylo` creation gate is `profile.putin-khuylo-missing` below, under its branch for a root the change adds.

**Severity** (copied from the check file, shared with `llm` rules):
- MEDIUM when a profile-owned file drifts from its template with no stated reason, a required file is missing, or migration notes sit in `README.md` instead of their own file under `docs/`.

### Confirm when: `profile.required-file-missing`

- The path is in the create-time file set of Module layout for this module's kind, and is not `tests/` or `wrappers/`.
- The path is absent at the head, or present only under another name or in another place.
- A missing directory is one finding, not one per file in it.

### Host templates: `profile.required-file-missing`

- `summary`: `The profile requires {subject} for this module, and the change does not add it.`
- `suggested_fix`: `Add {subject} from the template the profile's templates-map.md names for it, per PROFILE.md Module layout.`

## `profile.putin-khuylo-missing`

Engine: `tool`

### Rule text: `profile.putin-khuylo-missing`

**Fails when:**
- The root module creates resources without the creation gate the profile requires, against [Module layout](../../../terraform-module-maintainer/profiles/terraform-aws-modules/PROFILE.md#module-layout) and its `putin_khuylo` paragraph (`profile.putin-khuylo-missing`). Scope is the root module only, the directory holding the module's root `variables.tf`, because that paragraph requires the gate there and nowhere else. Each root variable a local combines with `var.putin_khuylo` is a creation input - `var.create`, or a `create_<x>` input such as `create_bucket` - and a module may have several; `var.create` is the one creation input when no local combines any. A `resource` or `module` block is judged only when its `count` or `for_each` reads a creation input, directly or through the locals it reads, and it is gated when that same path also reads `var.putin_khuylo`. Which blocks are judged depends on whether the root exists at the base:
  - **A root the change adds**, as when the task reviews a whole module as new: it fails when its `variables.tf` declares no `putin_khuylo`, or when a judged block is not gated. One finding, `file` `variables.tf` and `line` the first creation input's declaration, or null when there is none.
  - **A root on the base:** only the judged blocks the change adds, those whose `count` or `for_each` it edits, and those whose path to a creation input runs through a local it edits. Each one that is not gated fails: it honours a creation input and skips the gate, by reading the input directly past the gated local, or because the root has no gate at all. One finding per block, at its `count` or `for_each` line, except that blocks whose gate is lost in a local the change edits share one finding at that local's line. A pre-existing block the change does not touch is not this change's finding.
  - Silent cases. A block whose `count` or `for_each` reads no creation input, or which has neither, is Check C's `structure.create-flag-ignored`. When the base declares `putin_khuylo` and the head does not, Check A owns it as `compat.variable-removed`.

**Severity:**
- MEDIUM when the root module creates resources without the profile's creation gate (`profile.putin-khuylo-missing`): the module plans and applies, and it breaks a must-pass convention of the family.

### Confirm when: `profile.putin-khuylo-missing`

- The block is in the root module, and its `count` or `for_each` reads a creation input, directly or through locals.
- That path does not also read `var.putin_khuylo`, or the root declares no `putin_khuylo`.
- On a root the base has, the change adds the block, edits its `count` or `for_each`, or edits a local on its path.

### Host templates: `profile.putin-khuylo-missing`

- `summary`: `{subject} reads a creation input in the root module without the var.putin_khuylo creation gate the profile requires.`
- `suggested_fix`: `Gate {subject} on var.create && var.putin_khuylo through the creation local of templates/main.tf.template, and declare variable "putin_khuylo" if the root lacks it.`

## `profile.region-not-allowed`

Engine: `candidate`

### Rule text: `profile.region-not-allowed`

**Fails when:**
- A region literal the change adds or edits is neither `eu-west-1` nor `us-east-1`, against [Regions](../../../terraform-module-maintainer/profiles/terraform-aws-modules/code-conventions.md#regions). Scope is the literals the diff touches, and only where the literal chooses a region: a provider `region`, a `region` argument, a module input, an example's locals. A region appearing as a key in a lookup map, inside an ARN, or inside a hostname is not a choice and never fires this. A pre-existing literal the diff does not touch is not reported.

**Severity:**
- HIGH when a region literal the change touches is neither of the two the profile allows (`profile.region-not-allowed`), or the change carries a file format the profile's quality gate cannot read (`profile.nonstandard-config-file`).

### Confirm when: `profile.region-not-allowed`

- The change adds or edits the literal, and the literal is neither `eu-west-1` nor `us-east-1`.
- The literal chooses a region: a provider `region`, a `region` argument, a module input or an example's locals.
- It is not a lookup map key, part of an ARN or part of a hostname.

### Host templates: `profile.region-not-allowed`

- `summary`: `{subject} sets a region literal other than eu-west-1 or us-east-1, the two regions the profile allows.`
- `suggested_fix`: `Set the region literal at {subject} to eu-west-1, or to us-east-1 where a second region is needed, per the profile's Regions convention.`

## `profile.nonstandard-config-file`

Engine: `tool`

### Rule text: `profile.nonstandard-config-file`

**Fails when:**
- A file the change adds or edits is `*.tf.json`, `override.tf`, `override.tf.json` or `*_override.tf[.json]`, or is a `.tofu` file or an OpenTofu-only block in a module whose `required_version` admits Terraform, against [Configuration file formats](../../../terraform-module-maintainer/profiles/terraform-aws-modules/code-conventions.md#configuration-file-formats).

**Severity:**
- HIGH when a region literal the change touches is neither of the two the profile allows (`profile.region-not-allowed`), or the change carries a file format the profile's quality gate cannot read (`profile.nonstandard-config-file`).

### Confirm when: `profile.nonstandard-config-file`

- The change adds or edits the file.
- Its name matches `*.tf.json`, `override.tf`, `override.tf.json` or `*_override.tf[.json]`, or it is a `.tofu` file or holds an OpenTofu-only block in a module whose `required_version` admits Terraform.

### Host templates: `profile.nonstandard-config-file`

- `summary`: `{subject} is a file format the profile's quality gate cannot read: JSON configuration, an override file, or OpenTofu-only syntax.`
- `suggested_fix`: `Rewrite {subject} as a .tf file in Terraform's language, or fold the override into the file it overrides, per the profile's Configuration file formats.`
