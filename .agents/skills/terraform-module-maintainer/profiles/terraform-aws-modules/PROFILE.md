# Profile: terraform-aws-modules

> **Part of:** [terraform-module-maintainer](../../SKILL.md)
> **Status:** Holds the files that were previously at the skill root, plus the layout, quality gate and release rules extracted from `SKILL.md` and `references/quality-gates.md`.

Conventions used by modules in [github.com/terraform-aws-modules](https://github.com/terraform-aws-modules).

## What this profile defines

| Area | Where |
|------|-------|
| Static files copied into modules (editorconfig, gitignore, pre-commit, release config, GitHub workflows) | [templates/](templates/) |
| Template-to-destination mapping and placeholders | [templates-map.md](templates-map.md) |
| Code conventions: regions, configuration file formats, version floors, comment and copied-value evidence, validation scope, ARN partitions, example sizing | [code-conventions.md](code-conventions.md) |
| Scope for this family: AWS adjunct and ambient lists, repository file and tooling rules, worked cases. The Terraform rules are [module-scope.md](../../references/module-scope.md) | [scope.md](scope.md) |
| Module layout: required files and directories, `examples/basic`, `examples/complete`, `modules/`, `wrappers/` | [Module layout](#module-layout) |
| Quality gate: pre-commit-terraform hooks, what each owns, which artifacts are generated | [Quality gate](#quality-gate) |
| Release, pull request titles, changelog | [Release and commit conventions](#release-and-commit-conventions) and [templates/](templates/) |
| Pull request descriptions: the required sections and what each has to contain | [pr-description.md](pr-description.md) |
| Where migration notes live | [Migration notes](#migration-notes) |
| The values a tool reads, restated from the rules above in fenced blocks | [Profile constants](#profile-constants) |
| The rules above that a generic code reviewer can judge from a change alone, restated for a caller to hand over pinned by commit: advice, never a verdict | [review-guide.md](review-guide.md) |

## Module layout

This section states the file set a module created under this profile starts with. A file
it requires that is absent is a defect, and so is one that is present under another name
or in another place.

Modules in the family predate parts of this set, and several name their examples
differently. Against an existing module, a divergence here is a finding only when the
change under review is to the module's own file set. A change that adds a feature is not
asked to rename an example.

**Repository name.** `terraform-<provider>-<NAME>`, for example `terraform-aws-wafv2`.
This one is not a convention of the family: the Terraform Registry requires the pattern,
and a repository named anything else cannot be published there. The registry reads the
third segment as the module name and allows hyphens in it. This family narrows it to the
service, so `terraform-aws-security-group` is a family name for one service, not two
segments.

**Root.** `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, `README.md` and
`LICENSE`. Further resource files (`iam.tf`, `locals.tf`, a `<feature>.tf`) belong to the
archetype rather than to this profile: see
[service-archetypes.md](../../references/service-archetypes.md#module-shape-quick-reference).
The absence of one of those is not a defect.

**`LICENSE` is Apache 2.0.** Every module in this family carries the same license, so a
module carrying another one has diverged from the family, whatever the other license says.

**`var.putin_khuylo` is declared and gates creation at the root.** The root module of every
module in this family carries the political statement variable, and its `local.create` is
`var.create && var.putin_khuylo`. A root whose `create` local reads `var.create` alone is
missing it. Submodules under `modules/<name>/` are not required to carry it, and in this
family none does. A repository with no root module, one that ships only submodules, needs
it nowhere. It is declared second
in the Core Configuration group, directly after `create` and before `name` and `tags`. The
declaration is in
[templates/variables.tf.template](templates/variables.tf.template), the local in
[templates/main.tf.template](templates/main.tf.template).

**`versions.tf` declares the AWS provider's user agent.** The root `versions.tf`, and the
`versions.tf` of every `modules/<name>/` whose `required_providers` requires
`hashicorp/aws`, carry this block inside the `terraform` block, with `<name>` the repository
name after `terraform-aws-`:

```hcl
provider_meta "aws" {
  user_agent = [
    "github.com/terraform-aws-modules/terraform-aws-<name>"
  ]
}
```

A submodule names the repository, not itself. The reference is
[the terraform-aws-eks versions.tf](https://github.com/terraform-aws-modules/terraform-aws-eks/blob/master/versions.tf).
A submodule that requires no `hashicorp/aws` has no block, and neither do `examples/` and
`tests/`: they are callers, not the module. Each `wrappers/**/versions.tf` carries an empty
`provider_meta "aws" {}` with no `user_agent`, as the wrapper generator writes it: that file is
generated content, never authored, and this paragraph does not apply to it. Read on
2026-09-24 from terraform-aws-eks, terraform-aws-s3-bucket, terraform-aws-vpc,
terraform-aws-lambda, terraform-aws-rds and terraform-aws-iam: every root and submodule that
requires `hashicorp/aws` carries the block, all 28 wrapper `versions.tf` files carry the empty
one, and no example does. The template is
[templates/versions.tf.template](templates/versions.tf.template).

**Dotfiles and workflows.** Four dotfiles at the root and five files under
`.github/workflows/` are the profile's. Their names and sources are the destination column
of [templates-map.md](templates-map.md); a module missing one of those destinations is
missing a required file. Eight of the nine are copied verbatim and are expected to match
their template byte for byte except version pins: [Quality gate](#quality-gate).
`.pre-commit-config.yaml` is the exception: see [Quality gate](#quality-gate).

**A module starts with `examples/basic/` and `examples/complete/`.** Each holds `main.tf`,
`outputs.tf`, `versions.tf` and `README.md` of its own. `basic` is the smallest
configuration that works: required arguments only. `complete` demonstrates every major
feature and also carries a `module "disabled"` call with `create = false`, so the
create-nothing path is exercised. Older modules name the minimal example otherwise, most
often `simple`, or carry a set of feature-named examples and no minimal one at all; that
is the scope rule above, not a missing file. What every module does carry is a complete
example with the disabled call in it. A third example is warranted by the module's complexity,
not by this profile: see
[service-archetypes.md](../../references/service-archetypes.md#examples-pattern-by-complexity).

**`modules/<name>/` for a submodule.** A submodule is a complete module in the same shape
as the root: its own `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf` and
`README.md`, and an example of its own under `examples/`. A submodule that borrows the root
module's files is not one. When a submodule is warranted is again an archetype question:
see [service-archetypes.md](../../references/service-archetypes.md).

**Tests are native Terraform tests, allowed and not required.** A module may carry `tests/`
with Terraform native test files, `tests/*.tftest.hcl`. A module without them is not
incomplete, and a change is never asked to add one. Terratest, and any other Go test suite,
is never used in this family: no `go.mod`, `go.sum` or `*_test.go` file anywhere in the
repository. A helper module a native test loads sits in a directory under `tests/`, such as
`tests/setup/`, and belongs there only while a `module` block inside a `run` block of a
`tests/*.tftest.hcl` file names that directory as its `source`. The template is
[templates/test-basic.tftest.hcl.template](templates/test-basic.tftest.hcl.template).

**`wrappers/` is generated, never authored.** A hand-written file under `wrappers/` is a
defect: see [Quality gate](#quality-gate).

## Quality gate

The gate is pre-commit-terraform, configured by the `.pre-commit-config.yaml` that
[templates-map.md](templates-map.md) maps into the module. Eight hooks run, and between them
they own the following:

| Hook | What it owns |
|------|--------------|
| `terraform_fmt` | Canonical formatting of every `.tf` file |
| `terraform_docs` | The documentation region of `README.md`, at the root and in each example |
| `terraform_tflint` | The thirteen lint rules [templates/.pre-commit-config.yaml.template](templates/.pre-commit-config.yaml.template) enables, among them `terraform_documented_variables`, `terraform_documented_outputs`, `terraform_typed_variables`, `terraform_naming_convention`, `terraform_required_version`, `terraform_required_providers`, `terraform_unused_declarations` and `terraform_standard_module_structure`, which is the second check that a module's required files are present |
| `terraform_validate` | Terraform's own validity check, in each directory |
| `terraform_wrapper_module_for_each` | The whole `wrappers/` directory |
| `check-merge-conflict` | The absence of conflict markers |
| `end-of-file-fixer` | A final newline on every file |
| `trailing-whitespace` | The absence of trailing whitespace |

Several artifacts in a module are generated and never authored. Text a person wrote in any
of them is a defect, because the tool that owns it overwrites the file on its next run:

- The documentation region of a `README.md`, owned by `terraform_docs`. Read its marker
  pair out of the file rather than assuming one. The markers are HTML comments on lines of
  their own, a `BEGIN`/`END` pair naming the region, and the family uses two spellings.
  `<!-- BEGIN_TF_DOCS -->` and `<!-- END_TF_DOCS -->` is terraform-docs' own default, and
  it is what `terraform-aws-s3-bucket` carries in every `README.md` at the root, in each
  submodule and in each example. `<!-- BEGINNING OF PRE-COMMIT-TERRAFORM DOCS HOOK -->` and
  `<!-- END OF PRE-COMMIT-TERRAFORM DOCS HOOK -->` is the older pre-commit-terraform
  spelling, and it is what [templates/README.md.template](templates/README.md.template)
  and [templates/example-README.md.template](templates/example-README.md.template) ship, so
  a module created from the templates starts with it. Neither spelling is the profile's:
  whichever pair the file already carries is the one that file uses. That is why migration
  notes live in their own file: [Migration notes](#migration-notes).
- Any further region a generator writes. A module may give a hook its own marker pair, and
  that region is governed by the same rule as the documentation one. Find the pairs by
  scanning the file for `BEGIN`/`END` comment pairs. A further pair counts as generated only
  when its marker text appears literally in the arguments of a hook in the module's
  `.pre-commit-config.yaml`, or in a configuration file those arguments name, such as the
  `output.template` of a `.terraform-docs.yml`. Every other pair is a layout convention: the
  text between its markers is written by hand and edited like any other README prose, with
  the markers left in place. `terraform-aws-s3-bucket` has one,
  `<!-- BEGIN_KNOWN_LIMITATIONS -->` and `<!-- END_KNOWN_LIMITATIONS -->` in its root
  `README.md` above the documentation region: no hook argument in its quality gate names it.
- Every file under `wrappers/`, owned by `terraform_wrapper_module_for_each`.
- `CHANGELOG.md`, owned by semantic-release:
  [Release and commit conventions](#release-and-commit-conventions).

`.pre-commit-config.yaml` is the one profile-owned file whose content is expected to move
ahead of its template. [templates-map.md](templates-map.md) maps it in a copy-then-update
table for that reason: the `rev:` pins are refreshed in the module after the copy, so a
module whose pins sit above the template's is current, not drifted. Its hook list is the
profile's; its pins are not.

For running the gate - the order of the steps, what each hook's failure means, and how to
read its output - see [quality-gates.md](../../references/quality-gates.md).

## Documentation regeneration in an untrusted workspace

The maintainer's
[The Documentation Region](../../references/quality-gates.md#the-documentation-region)
takes these constants from this file, and nothing from the workspace.

- **Version.** terraform-docs `v0.24.0`: the version this family's pre-commit workflow
  installs (`TERRAFORM_DOCS_VERSION` in `terraform-aws-s3-bucket` at commit
  `5dc2f1f89743ab935114b0b039bc88044a672ca2`, the source of the pre-commit templates in
  [templates-map.md](templates-map.md#pre-commit-config-copy-then-update)).
- **Address.**
  `https://github.com/terraform-docs/terraform-docs/releases/download/v0.24.0/terraform-docs-v0.24.0-<platform>.tar.gz`
- **Archive SHA-256, per platform:**

  | `<platform>` | SHA-256 |
  |--------------|---------|
  | `darwin-amd64` | `3c3f7f18f908457fd1209cbe341418f7f6bae78c08126cfbe8de0d1b06aa8781` |
  | `darwin-arm64` | `f6b114f4b032f3f9202ab6c23bfd28c3c8e68aeeb8a8f12fc118bf2073081d71` |
  | `linux-amd64` | `9005daf969de0b50134493a2c00078b49f5f5b39d021cda7c89bf4d4f3d776d3` |
  | `linux-arm64` | `d12bd7b73c1fc9c64efc79f8157dd713dabd559f1ecf3cfc0f42e32279a155fd` |

  These are the values of the release's own checksums file,
  `https://github.com/terraform-docs/terraform-docs/releases/download/v0.24.0/terraform-docs-v0.24.0.sha256sum`,
  read on 2026-09-25 and again on 2026-10-01 with the same values. The darwin-arm64 archive
  was downloaded and matched on 2026-09-25. Any other platform has no
  recorded hash, so it takes the fallback.
- **Recognised marker pairs.** The template pair `<!-- BEGIN_TF_DOCS -->` and
  `<!-- END_TF_DOCS -->`, and the older hook pair
  `<!-- BEGINNING OF PRE-COMMIT-TERRAFORM DOCS HOOK -->` and
  `<!-- END OF PRE-COMMIT-TERRAFORM DOCS HOOK -->`. A `README.md` carries one pair or the other,
  and the configuration below takes that pair in its template. The older hook pair takes the
  fallback, with the reason "no parity fixture for this marker pair", until a parity fixture
  for it is recorded below; only the template pair is regenerated.
- **Configuration text,** the gate's effective settings, written to `tfdocs-config-<n>.yml`
  with the directory's marker pair in the template:

  ```yaml
  formatter: "markdown table"
  header-from: main.tf
  footer-from: ""
  recursive:
    enabled: false
  output:
    file: README.md
    mode: inject
    template: |-
      <!-- BEGIN_TF_DOCS -->
      {{ .Content }}
      <!-- END_TF_DOCS -->
  sort:
    enabled: true
    by: name
  settings:
    lockfile: false
  ```

  This reproduces the `terraform_docs` hook with `--args=--lockfile=false`. `header-from`
  names `main.tf`, the gate's own default, because terraform-docs `v0.24.0` refuses an empty
  value (`value of '--header-from' can't be empty`). It reads the copy of `main.tf` in the run
  directory, never the workspace.

Parity is a trusted-fixture check. Measured on 2026-09-25 on a copy of `terraform-aws-s3-bucket`
pull request 410's unmodified head, which commits no terraform-docs configuration: all 19
documentation regions, at the root and in every `modules/*` and `examples/*` directory, came
out byte for byte unchanged. Measured again on 2026-10-01 at that head
(`30cd3728d16cc5a1e1fa25d0d891015b6e4a0ada`) with the maintainer's
`references/terraform-docs-pass.sh` and the pinned darwin-arm64 binary: the same 19 regions
unchanged, and a changed variable description reached its row. Every one of them carries the
template pair, so the measurement covered that pair alone; the older hook pair has no
measured fixture yet.

`wrappers/` is never regenerated in an untrusted workspace. A fix that makes a wrapper file
stale leaves it reported stale, for the owner's checkout or CI.

## Release and commit conventions

Modules under this profile release with semantic-release, configured by
[templates/.releaserc.json.template](templates/.releaserc.json.template), and validate
pull request titles with
[templates/github-workflows-pr-title.yml.template](templates/github-workflows-pr-title.yml.template).

Three consequences for any change made under this profile:

- **The pull request title is what the release tooling reads.** It is validated on every
  push to the pull request, and on a squash merge it becomes the commit message that
  decides the next version. Write it as a Conventional Commit:
  `<type>: <Description>`. The types the workflow template accepts are `fix`, `feat`,
  `docs`, `ci` and `chore`. `feat` cuts a minor release, `fix` cuts a patch, the rest cut
  nothing. A `!` after the type, or a `BREAKING CHANGE:` trailer in the body, cuts a
  major release. The template also requires the description to start with an uppercase
  letter. The shape is not the whole requirement. The description names the capability or
  the fix, and the surface it lands on when the change is not to the root module, because
  on a squash merge this line becomes the commit message and from there an entry in the
  generated `CHANGELOG.md` that someone reads two years later.
  `feat: Add support for S3 bucket ABAC via new bucket_abac input` says what happened;
  `feat: Update module` does not.
- **`CHANGELOG.md` is generated.** semantic-release writes it from the released commits
  and commits it itself. Never hand-edit it, and never add an entry as part of a change.
- **The pull request body is what the maintainer merges on.** The title is read by the
  tooling; the body is read by a person deciding whether the change is correct, and by
  everyone who later asks why the module changed. What it has to contain, and what fails,
  is [pr-description.md](pr-description.md).

Conventional Commits is a public specification. Read it at
[conventionalcommits.org](https://www.conventionalcommits.org/en/v1.0.0/) rather than
looking for a restatement here.

A pull request that adds a feature carries an example that demonstrates it: an existing
example extended, or a new one when the feature is a use case of its own, which
[service-archetypes.md](../../references/service-archetypes.md#new-example-or-updated-example)
decides. It also carries the documentation that the feature changes, regenerated by the hook that owns it
rather than written by hand: the input and output tables, at the root and in every example
the feature touches.

## Migration notes

A change that forces consumers to act keeps its migration notes in the module, at
`docs/MIGRATION_<from>_to_<to>.md` - for example `docs/MIGRATION_v2_to_v3.md`.

Not in `README.md`. The terraform-docs region there is generated and overwrites anything
written inside it, and notes placed outside that region push the generated documentation
down the page. The pull request that makes the change links to the file, under
Motivation and Context: [pr-description.md](pr-description.md).

For what goes in the notes and the shape they take, see the upgrade workflow's
[Step 6: Migration Notes and Report](../../SKILL.md#step-6-migration-notes-and-report).

## Profile constants

A tool that applies this profile's rules reads its parameters from the blocks below, never
from prose. Each block restates rule text that lives in a section it links to, and that text
stays the rule. `tests/skills-test.sh` parses every block and fails when a value and the text
it restates disagree.

The format is the same for every block:

- The block is fenced code whose info string is `profile-constants`. No other block in the
  profile uses that info string.
- The first line is `name: <block name>`. Each later line is `<key>: <value>`: the key, a
  colon, one space, and the value to the end of the line.
- A list value is its items separated by single spaces. No item contains a space.
- A block name appears once in this file, and a key once in its block. Each block has a fixed
  set of keys. A block with a missing or an unknown key is invalid.

### Required files

Restates [Module layout](#module-layout): the files each area kind starts with, as paths
relative to the area, and the two examples a module starts with. The files the module root
must hold are `root` plus every value of [Template destinations](#template-destinations): the
four dotfiles and five workflows are required there too.

```profile-constants
name: required-files
root: main.tf variables.tf outputs.tf versions.tf README.md LICENSE
submodule: main.tf variables.tf outputs.tf versions.tf README.md
example: main.tf outputs.tf versions.tf README.md
example-dirs: examples/basic examples/complete
```

### Allowed regions

Restates [Regions](code-conventions.md#regions).

```profile-constants
name: regions
primary: eu-west-1
secondary: us-east-1
```

### Argument order

Restates the first and last positions of
[Argument Order in a Resource Block](../../references/module-structure.md#argument-order-in-a-resource-block).
Either argument of a list may hold the position.

```profile-constants
name: argument-order
first: count for_each
last: tags labels
```

### Template destinations

Restates the [Static Files](templates-map.md#static-files-copy-verbatim) and
[Pre-Commit Config](templates-map.md#pre-commit-config-copy-then-update) tables: the key is
the file under `templates/`, the value its destination relative to the module root.

```profile-constants
name: template-destinations
.editorconfig.template: .editorconfig
.gitignore.template: .gitignore
.releaserc.json.template: .releaserc.json
github-workflows-pre-commit.yml.template: .github/workflows/pre-commit.yml
github-workflows-release.yml.template: .github/workflows/release.yml
github-workflows-lock.yml.template: .github/workflows/lock.yml
github-workflows-pr-title.yml.template: .github/workflows/pr-title.yml
github-workflows-stale-actions.yaml.template: .github/workflows/stale-actions.yaml
.pre-commit-config.yaml.template: .pre-commit-config.yaml
```

### Profile-owned files

Restates [Profile-owned files](scope.md#profile-owned-files): the verbatim class, and the
directory whose file set is exactly its workflows.

```profile-constants
name: profile-owned-files
verbatim: .editorconfig .gitignore .releaserc.json .github/workflows/pre-commit.yml .github/workflows/release.yml .github/workflows/lock.yml .github/workflows/pr-title.yml .github/workflows/stale-actions.yaml
workflow-dir: .github/workflows
```

### Tooling list

Restates the closed list of [No new scanners or linters](scope.md#no-new-scanners-or-linters):
file names, and directory names without the trailing slash.

```profile-constants
name: tooling
files: .checkov.yaml .checkov.yml trivy.yaml .trivyignore kics.config infracost.yml
dirs: .tfsec
```

### Banner line

Restates [The Stand With Ukraine banner](scope.md#the-stand-with-ukraine-banner): the
`SWUbanner` line of [templates/README.md.template](templates/README.md.template), byte for
byte.

```profile-constants
name: banner
line: [![SWUbanner](https://raw.githubusercontent.com/vshymanskyy/StandWithUkraine/main/banner2-direct.svg)](https://github.com/vshymanskyy/StandWithUkraine/blob/main/docs/README.md)
```

### Adjunct types

Restates the closed list of [Adjunct types](scope.md#adjunct-types).

```profile-constants
name: adjunct-types
types: aws_iam_role aws_iam_role_policy aws_iam_role_policy_attachment aws_iam_policy aws_iam_instance_profile aws_cloudwatch_log_group aws_cloudwatch_log_resource_policy aws_security_group aws_vpc_security_group_ingress_rule aws_vpc_security_group_egress_rule aws_security_group_rule
```

## What stays out of a profile

- Provider-neutral workflow: schema gathering, coverage ledger, service archetypes, module structure patterns. These live in `../../references/`.
- General Terraform guidance. That belongs to `antonbabenko/terraform-skill`.

## Adding another profile

Not designed yet. When a second module family appears, copy this directory to `profiles/<name>/`, replace the templates, and add it to the list in `../../SKILL.md`. Define a profile format only once two profiles exist and differ.
