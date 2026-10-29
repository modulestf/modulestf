# Engine Text: Check F

> **Part of:** [terraform-module-reviewer](../../SKILL.md), through [Check F: Scope](../check-f-scope.md)
> **Purpose:** The operative text of the Check F rules whose `engine` in [rule-facts.md](../rule-facts.md) is `tool` or `candidate`, moved here verbatim from the check file. The full variant reads this file as part of Check F. Each rule also carries the short criteria a confirmer reads and the fixed host templates for a confirmed finding.

Each rule has three sections. **Rule text** holds the moved sentences under their **Fails when:** and **Severity:** labels; a sentence or table row that also covers an `llm` rule stays in the check file and is copied here, so every section stands alone. **Confirm when** gives the short criteria. **Host templates** gives the `summary` and `suggested_fix` the host fills with the finding's subject: each template is one code span, at most 200 characters as written with `{subject}` unfilled. Links in the moved text point to the same targets as in the check file. The context every Check F rule shares stays in the check file: [The base revision](../check-f-scope.md#the-base-revision), [A new module](../check-f-scope.md#a-new-module), [Renamed files](../check-f-scope.md#renamed-files), [Not evaluated](../check-f-scope.md#not-evaluated), [Where Check F yields](../check-f-scope.md#where-check-f-yields), [The suggested fix](../check-f-scope.md#the-suggested-fix) and the [Suggested Fixes](../check-f-scope.md#suggested-fixes) rows.

## `scope.provider`

Engine: `candidate`

### Rule text: `scope.provider`

**Fails when:**
- `scope.provider` (A1): a head provider, in canonical form, is not a base provider, under [Providers](../../../terraform-module-maintainer/references/module-scope.md#providers).

Copied from the check file, shared with `llm` rules, with the row of the check file's outcome table:
- A [test helper directory](../../../terraform-module-maintainer/references/module-scope.md#test-helper-directories) takes `scope.provider`, `scope.module-call` and `scope.boundary` against the module root, as that section reads A1, A2 and C1 for it, and never `scope.new-submodule` or `scope.composition`. Each finding's `file` and `line` are the helper's block or `required_providers` entry.

| `rule_id` | Outcome | One finding per | `file` and `line` | Destination in `suggested_fix` |
|-----------|---------|-----------------|-------------------|--------------------------------|
| `scope.provider` | Ban | Provider source | The first added block or `required_providers` entry that names it | The caller |

"First" means first in file order: path, then line.

**Severity** (copied from the check file, shared with `llm` rules):
- HIGH for every ban: `scope.provider`, `scope.module-call`, `scope.boundary`, `scope.profile-file`, `scope.pre-commit-hook`, `scope.tooling`, `scope.layout`, `scope.readme-banner` and `scope.tests`.
- Never CRITICAL and never LOW. A scope finding judges belonging, not whether the code works.

### Confirm when: `scope.provider`

- The base exists and is not empty: a new module takes `scope.new-module` instead.
- The provider source, in canonical form, is declared or used at the head and by no boundary directory at the base.
- One finding per provider source, at the first added block or `required_providers` entry that names it.

### Host templates: `scope.provider`

- `summary`: `{subject} adds a provider the base does not use, so the module would take on a new provider.`
- `suggested_fix`: `Remove from this change every block and the required_providers entry that use the provider at {subject}. Destination: the caller, which configures the provider.`

## `scope.module-call`

Engine: `candidate`

### Rule text: `scope.module-call`

**Fails when:**
- `scope.module-call` (A2): a `module` block the change adds, or whose `source` it edits, fails [Module sources](../../../terraform-module-maintainer/references/module-scope.md#module-sources).

Copied from the check file, shared with `llm` rules, with the row of the check file's outcome table:
- A [test helper directory](../../../terraform-module-maintainer/references/module-scope.md#test-helper-directories) takes `scope.provider`, `scope.module-call` and `scope.boundary` against the module root, as that section reads A1, A2 and C1 for it, and never `scope.new-submodule` or `scope.composition`. Each finding's `file` and `line` are the helper's block or `required_providers` entry.

| `rule_id` | Outcome | One finding per | `file` and `line` | Destination in `suggested_fix` |
|-----------|---------|-----------------|-------------------|--------------------------------|
| `scope.module-call` | Ban | `module` block | The block | The caller |

**Severity** (copied from the check file, shared with `llm` rules):
- HIGH for every ban: `scope.provider`, `scope.module-call`, `scope.boundary`, `scope.profile-file`, `scope.pre-commit-hook`, `scope.tooling`, `scope.layout`, `scope.readme-banner` and `scope.tests`.
- Never CRITICAL and never LOW. A scope finding judges belonging, not whether the code works.

### Confirm when: `scope.module-call`

- The change adds the `module` block or edits its `source`.
- The source is not one Module sources admits, read from the `source` string alone.
- In a test helper directory, the profile's test helper pattern is applied as the check file's worked cases show.

### Host templates: `scope.module-call`

- `summary`: `{subject} calls a module whose source the module-scope rules do not admit in this module.`
- `suggested_fix`: `Remove {subject} from this change, or, for an edited source, restore its base value. Destination: the caller.`

## `scope.new-submodule`

Engine: `candidate`

### Rule text: `scope.new-submodule`

**Fails when:**
- `scope.new-submodule` (B2): a directory under `modules/` that is absent from the base has at least one managed type that is neither an adjunct nor allowed.

Copied from the check file's outcome table, which also covers `llm` rules:

| `rule_id` | Outcome | One finding per | `file` and `line` | Destination in `suggested_fix` |
|-----------|---------|-----------------|-------------------|--------------------------------|
| `scope.new-submodule` | Maintainer decision | New directory | The directory, `line` null | None |

**Severity** (copied from the check file, shared with `llm` rules):
- MEDIUM for every maintainer decision: `scope.new-submodule`, `scope.composition` and `scope.new-module`.
- Never CRITICAL and never LOW. A scope finding judges belonging, not whether the code works.

### Confirm when: `scope.new-submodule`

- The directory is under `modules/`, absent from the base, and not a whole-directory rename of a base directory.
- At least one managed type in it is neither an adjunct nor allowed by an `Allowed types` entry of the base `docs/SCOPE.md`.
- One finding per directory, never one per type. A Denied type in it is `scope.boundary` instead.

### Host templates: `scope.new-submodule`

- `summary`: `{subject} is a new submodule that manages types outside the module's adjuncts and allowed types, a maintainer decision.`
- `suggested_fix`: `needs decision: whether the module takes on the types in {subject}. (a) keep the directory; (b) remove it and every module block that calls it from this change.`

## `scope.profile-file`

Engine: `candidate`

### Rule text: `scope.profile-file`

**Fails when:**
- `scope.profile-file`: [Profile-owned files](../../../terraform-module-maintainer/profiles/terraform-aws-modules/scope.md#profile-owned-files).

Copied from the check file's outcome table, which also covers `llm` rules:

| `rule_id` | Outcome | One finding per | `file` and `line` | Destination in `suggested_fix` |
|-----------|---------|-----------------|-------------------|--------------------------------|
| `scope.profile-file` | Ban | Path | The path, at the first offending line; `line` null for a new or deleted file | Nowhere |

**Severity** (copied from the check file, shared with `llm` rules):
- HIGH for every ban: `scope.provider`, `scope.module-call`, `scope.boundary`, `scope.profile-file`, `scope.pre-commit-hook`, `scope.tooling`, `scope.layout`, `scope.readme-banner` and `scope.tests`.
- Never CRITICAL and never LOW. A scope finding judges belonging, not whether the code works.

### Confirm when: `scope.profile-file`

- The path is profile-owned, as Profile-owned files lists, and no file rule earlier in the profile's precedence order fires on it.
- The change adds the path, or adds or removes a job, step, key or plugin in it, as that section reads.
- An added file under the workflow directory counts only when it is not one of the profile's workflows. Adding one of them is no `scope.profile-file`; `profile.template-drift` compares its content.
- A `rev:` or `@` version pin alone is not an addition.

### Host templates: `scope.profile-file`

- `summary`: `{subject} is a profile-owned file, and the change adds it or adds or removes content the profile owns.`
- `suggested_fix`: `Delete {subject} if the change adds it; otherwise restore its base content, removing what the change adds and putting back what it removes.`

## `scope.pre-commit-hook`

Engine: `candidate`

### Rule text: `scope.pre-commit-hook`

**Fails when:**
- `scope.pre-commit-hook`: [Pre-commit hooks](../../../terraform-module-maintainer/profiles/terraform-aws-modules/scope.md#pre-commit-hooks).

Copied from the check file's outcome table, which also covers `llm` rules:

| `rule_id` | Outcome | One finding per | `file` and `line` | Destination in `suggested_fix` |
|-----------|---------|-----------------|-------------------|--------------------------------|
| `scope.pre-commit-hook` | Ban | Path | `.pre-commit-config.yaml`, at the first pair added; `line` null when only removals fire | Nowhere |

**Severity** (copied from the check file, shared with `llm` rules):
- HIGH for every ban: `scope.provider`, `scope.module-call`, `scope.boundary`, `scope.profile-file`, `scope.pre-commit-hook`, `scope.tooling`, `scope.layout`, `scope.readme-banner` and `scope.tests`.
- Never CRITICAL and never LOW. A scope finding judges belonging, not whether the code works.

### Confirm when: `scope.pre-commit-hook`

- The change adds or removes a repository or hook id in `.pre-commit-config.yaml` against the base.
- A moved `rev:` alone is no finding.

### Host templates: `scope.pre-commit-hook`

- `summary`: `{subject} adds or removes a pre-commit repository or hook the profile does not allow to change.`
- `suggested_fix`: `In {subject}, remove the repository or hook the change adds, or restore the one it removes with its base rev and hook ids. A rev pin may stay ahead of the base.`

## `scope.tooling`

Engine: `candidate`

### Rule text: `scope.tooling`

**Fails when:**
- `scope.tooling`: [No new scanners or linters](../../../terraform-module-maintainer/profiles/terraform-aws-modules/scope.md#no-new-scanners-or-linters).

Copied from the check file's outcome table, which also covers `llm` rules:

| `rule_id` | Outcome | One finding per | `file` and `line` | Destination in `suggested_fix` |
|-----------|---------|-----------------|-------------------|--------------------------------|
| `scope.tooling` | Ban | Path | The path, `line` null | Nowhere |

**Severity** (copied from the check file, shared with `llm` rules):
- HIGH for every ban: `scope.provider`, `scope.module-call`, `scope.boundary`, `scope.profile-file`, `scope.pre-commit-hook`, `scope.tooling`, `scope.layout`, `scope.readme-banner` and `scope.tests`.
- Never CRITICAL and never LOW. A scope finding judges belonging, not whether the code works.

### Confirm when: `scope.tooling`

- The change adds the path, and its basename or a directory component is on the closed list of No new scanners or linters, under `examples/` too.
- No file rule earlier in the profile's precedence order fires on it.

### Host templates: `scope.tooling`

- `summary`: `{subject} adds configuration for a scanner or linter the profile does not use.`
- `suggested_fix`: `Delete {subject}.`

## `scope.readme-banner`

Engine: `candidate`

### Rule text: `scope.readme-banner`

**Fails when:**
- `scope.readme-banner`: [The Stand With Ukraine banner](../../../terraform-module-maintainer/profiles/terraform-aws-modules/scope.md#the-stand-with-ukraine-banner).

Copied from the check file's outcome table, which also covers `llm` rules:

| `rule_id` | Outcome | One finding per | `file` and `line` | Destination in `suggested_fix` |
|-----------|---------|-----------------|-------------------|--------------------------------|
| `scope.readme-banner` | Ban | Root `README.md` | `README.md`, `line` null | Nowhere |

**Severity** (copied from the check file, shared with `llm` rules):
- HIGH for every ban: `scope.provider`, `scope.module-call`, `scope.boundary`, `scope.profile-file`, `scope.pre-commit-hook`, `scope.tooling`, `scope.layout`, `scope.readme-banner` and `scope.tests`.
- Never CRITICAL and never LOW. A scope finding judges belonging, not whether the code works.

### Confirm when: `scope.readme-banner`

- The root `README.md` at the head lacks the `SWUbanner` line of the profile's `templates/README.md.template`, byte for byte.
- The change removes the line, or adds a root `README.md` without it.

### Host templates: `scope.readme-banner`

- `summary`: `{subject} lacks the Stand With Ukraine banner line the profile requires in the root README.md.`
- `suggested_fix`: `Add the SWUbanner line of the profile's templates/README.md.template to {subject}, byte for byte, where the template places it.`
