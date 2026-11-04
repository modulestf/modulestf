# Scope

> **Part of:** [terraform-module-maintainer](../../SKILL.md)
> **Status:** The terraform-aws-modules layer of scope. The concept is
> [change-scope](../../../change-scope/SKILL.md), and the Terraform rules - boundary, prefix
> rule, reference edges, providers, module sources, evaluation order, the `docs/SCOPE.md`
> record - are [module-scope.md](../../references/module-scope.md). This file supplies what
> those leave to a profile: the adjunct and ambient lists, the rules for repository files
> and tooling, and worked cases. [PROFILE.md](PROFILE.md) owns the file set and
> [code-conventions.md](code-conventions.md) owns what goes in the files. The reviewer's
> [Check F](../../../terraform-module-reviewer/references/check-f-scope.md) enforces this file.

Every rule below is adopted by this profile. None of it describes existing
terraform-aws-modules policy: the family has no written scope policy, and this file does not
claim one. The lists are closed until this file changes.

In this family a module manages one AWS service, and the repository name
`terraform-aws-<service>` names it: [Module layout](PROFILE.md#module-layout).

## Adjunct types

Any module may add these resource types in any boundary directory. The list is closed.

| Type | Carries |
|------|---------|
| `aws_iam_role` | Identity |
| `aws_iam_role_policy` | Identity |
| `aws_iam_role_policy_attachment` | Identity |
| `aws_iam_policy` | Identity |
| `aws_iam_instance_profile` | Identity, for a service that runs instances |
| `aws_cloudwatch_log_group` | Logs |
| `aws_cloudwatch_log_resource_policy` | Logs, for a service that writes to a log group through a resource policy |
| `aws_security_group` | Network access |
| `aws_vpc_security_group_ingress_rule` | Network access |
| `aws_vpc_security_group_egress_rule` | Network access |
| `aws_security_group_rule` | Network access, in the older single-rule form |

Most services need identity, logs and network access, and the family already creates them
beside its services: `terraform-aws-efs`, `terraform-aws-rds-aurora` and
`terraform-aws-elasticache` declare security groups of their own. An adjunct is exempt from
the boundary, not from the edge rule: an IAM role that nothing uses is a maintainer decision.

`aws_kms_key` is deliberately not an adjunct. A key is a service of its own, with its own
policy, rotation and deletion window, and a module takes its ARN as an input: composition
across services is the caller's job.

## Ambient data sources

Any module may read these, and none of them is a base identity for a reference edge. The list
is closed: `aws_caller_identity`, `aws_region`, `aws_partition`, `aws_availability_zones`,
`aws_service_principal`, `aws_iam_policy_document`.

The first five describe where the module runs, not another service. `aws_iam_policy_document`
is here for a different reason: a module writes one for almost every role and policy, so if
an existing one counted as a base identity, any new block could claim a connection by reading
it.

## Repository files and tooling

These rules run as step D of the
[evaluation order](../../references/module-scope.md#evaluation-order), after the type rules.

- **What they read.** [templates-map.md](templates-map.md), [PROFILE.md](PROFILE.md) and
  [templates/](templates/) are read from this skill as installed, never from the workspace
  under review.
- **What they judge.** The paths the diff touches - added, modified, deleted or renamed -
  and only what the change does to them: each rule compares the result with the base file,
  and reads the template only for what neither has. Drift the base already carries predates
  the change and is not its finding, whether or not the change touches the file. The banner
  rule states its own trigger.
- **Precedence.** A path takes its outcome from the first rule below that fires, in the order
  written, and yields one finding. The most specific rule comes first and the layout rule
  last.
- **Outcome.** Each rule is a ban.

### Profile-owned files

The verbatim class is the Static Files table of [templates-map.md](templates-map.md):
`.editorconfig`, `.gitignore`, `.releaserc.json` and the five workflows under
`.github/workflows/`. The files mapped in its other tables - `.pre-commit-config.yaml`,
`versions.tf`, `README.md`, examples - are customized after the copy and are not in this
class.

- The change deletes a verbatim-class file: it fails.
- A new file under `.github/workflows/` fails unless it is one of the five workflows. The
  workflow set is exactly the five templates: adding one of them, to a module that lacks it,
  is no ban, and its content is compared with its template like any other verbatim file.
- In a workflow the change touches, a job or a step that neither the base file nor the
  template has fails, and so does a `uses:` whose owner and repository appear in neither.
  Removing a job or a step the base has also fails. A job is matched by its id; a step by
  its `name`, or by its `uses:` or `run:` when it has no name.
  The version after `@`, and other version pins such as a tool version, are not read:
  templates lag the family, and a pin moved ahead of its template is current, not new.
- In `.releaserc.json`, a top-level key or a plugin that neither the base file nor the
  template has fails, and so does removing a top-level key or a plugin the base has. A
  plugin is identified by its name: the string, or the first element of a
  `[name, {options}]` array. Plugin options are not read.

The checks and the release flow are the profile's, so removing one is judged the same way as
a removed hook or a deleted verbatim file.

Byte-level drift from a template is not a scope question. The reviewer's Check E reports it
as template drift. When both fire on one file, the reviewer's deduplication keeps one finding
at the higher severity.

### Pre-commit hooks

The rule reads the set of repository URL and hook id pairs in `.pre-commit-config.yaml`.

- When the base has the file, a pair the result adds or removes relative to the base fails:
  a new repository, a changed repository URL, a new hook id, a removed hook. The template is
  not read here: several modules in the family run without a hook it lists, and that is the
  base's state, not this change's finding.
- When the change creates the file, a pair not in
  [templates/.pre-commit-config.yaml.template](templates/.pre-commit-config.yaml.template)
  fails.

`rev:` is not read. Refreshing pins is expected of this file:
[Quality gate](PROFILE.md#quality-gate). A change that only moves a `rev:` has no finding.

### No new scanners or linters

The tools this profile carries are the hooks above and the five workflows. A new path that
configures another scanner, linter or cost tool fails. The names this rule recognises are a
closed list: `.checkov.yaml`, `.checkov.yml`, `trivy.yaml`, `.trivyignore`, `.tfsec/`,
`kics.config` and `infracost.yml`. A new path matches when its basename is one of the file
names, or when any of its directory components is one of the directory names, such as
`.tfsec` in `examples/complete/.tfsec/config.yml`. Both match at any depth, `examples/`
included: an example is not a place to run a scanner. A tool configuration under any other
name still fails,
under [New files outside the layout](#new-files-outside-the-layout).

### Terraform tests

The decision is in [Module layout](PROFILE.md#module-layout): native tests are allowed and not
required, and Terratest is never used.

- **Go tests.** A new `go.mod`, `go.sum` or `*_test.go` file anywhere fails, whether or not the
  base already has Go tests.
- **Native tests.** A new `tests/*.tftest.hcl` file passes this rule. So does a new `*.tf` file
  in a [test helper directory](../../references/module-scope.md#test-helper-directories): a
  directory under `tests/` that a `run` block's `module` source names, matched as that
  section says. Passing here admits the file, not what it declares: the type rules read a
  helper against the module root, so it may use only base providers, local sources and the
  namespace below, and types inside the root's boundary. Any other new file under `tests/`
  goes on to [New files outside the layout](#new-files-outside-the-layout), and a
  `.tftest.hcl` file outside `tests/` does too.
- **Registry namespace for test helpers.** A helper may call a module of this family from the
  public Terraform Registry, such as `terraform-aws-modules/vpc/aws`, to build its fixtures.
  The whole `source` string must match
  `^(registry\.terraform\.io/)?terraform-aws-modules/[a-z0-9-]+/aws(//modules/[a-z0-9-]+)?$`:
  the host omitted or `registry.terraform.io`, the namespace `terraform-aws-modules`, and the
  provider segment `aws`, with an optional submodule path. Any other host, such as
  `app.terraform.io` or a private registry, and any other namespace fail.

### New files outside the layout

A new path passes only when it matches one of these. Everything else fails, including a new
top-level directory, a `Makefile` or a script.

| Path | Condition |
|------|-----------|
| `*.tf`, `*.tf.json` | At the root or in a directory under `modules/` |
| `README.md` | At the root or in a directory under `modules/` |
| `examples/**` | Any file: an example is a caller's configuration |
| `tests/*.tftest.hcl` | Native tests: [Terraform tests](#terraform-tests) |
| `tests/<dir>/*.tf` | A helper module a native test names as a `run` block's `module` source: [Terraform tests](#terraform-tests) |
| `wrappers/**` | Generated: [Quality gate](PROFILE.md#quality-gate) owns its content |
| `docs/SCOPE.md` | The exception record |
| `docs/MIGRATION_<from>_to_<to>.md` | [Migration notes](PROFILE.md#migration-notes) |
| `LICENSE`, `CHANGELOG.md` | [Module layout](PROFILE.md#module-layout) and [Release and commit conventions](PROFILE.md#release-and-commit-conventions) own their content |
| `.editorconfig`, `.gitignore`, `.releaserc.json`, `.pre-commit-config.yaml`, the five workflow paths | The destination column of [templates-map.md](templates-map.md) |

Files the base already has are not judged by this rule.

### The Stand With Ukraine banner

The root `README.md` of the result carries the `SWUbanner` line of
[templates/README.md.template](templates/README.md.template), byte for byte. It fails when the
line is missing and either the base root `README.md` had it or the change creates the root
`README.md`. A root `README.md` that lacked the line on the base and still lacks it is not
this change's finding.

## Not a ban here: a literal only one caller wants

A value written into the module that fits one caller - a name, a retention period, an account
ID - is not a scope question, and this file has no rule for it. The existing conventions
cover it:

- a configurable value that is not a variable: tier 5 of the
  [Coverage Checklist](../../references/coverage-checklist.md#tier-5-quality-should-pass),
  and an optional argument neither exposed nor documented is the reviewer's Check B;
- an account ID, a region or a partition inside an ARN:
  [ARNs and partitions](code-conventions.md#arns-and-partitions);
- a constant copied out of a document:
  [Copied values](code-conventions.md#evidence-comments-copied-values-and-availability).

## Worked cases

Each case names the rule and the outcome. Destinations are from
[Where a misfit goes](../../../change-scope/references/principles.md#where-a-misfit-goes).

| Case | Outcome |
|------|---------|
| `terraform-aws-lambda` pull request 770 adds `poller_group_name`, which hashicorp/aws 6.66.0 carries in the `provisioned_poller_config` block of `aws_lambda_event_source_mapping`, a type the base root manages, and passes it through from the module's inputs | No finding. A new argument on a managed type is coverage, not expansion, and no block is added |
| `terraform-aws-s3-bucket` pull request 410 creates `modules/file-system` | One maintainer decision (B) naming the directory and `aws_s3files_file_system`, `aws_s3files_file_system_policy`, `aws_s3files_access_point`, `aws_s3files_mount_target` and `aws_s3files_synchronization_configuration`. Its IAM role, role policy, policy attachment, security group and ingress and egress rules are adjuncts; `aws_caller_identity`, `aws_partition`, `aws_region`, `aws_service_principal` and `aws_iam_policy_document` are ambient; the root's call to `./modules/file-system` is a local source. Not five bans |
| An S3 bucket module adds `aws_s3_bucket_metadata_configuration` at the root, referencing `aws_s3_bucket.this` | No finding. The stem `aws_s3_bucket` admits it, and the reference is an edge. With no edge it is a maintainer decision |
| An S3 bucket module adds `aws_db_instance` | Ban (C1), outside the boundary. Destination: the caller, which composes the family's RDS module and passes the identifier in |
| A module whose base manages no `aws_s3_access_point` adds one at the root | Ban (C1). The stem `aws_s3_bucket` does not prefix it and it is not an adjunct. This is the stated cost of strict growth. Destination: the base first, with an `Allowed types` entry |
| The change adds `docs/SCOPE.md` allowing `aws_db_instance`, and adds an `aws_db_instance` | Ban (C1) still. The head's `docs/SCOPE.md` is never read. The new file itself passes the layout rule |
| `helm` is added to `required_providers` | Ban (A1): `hashicorp/helm` is not a base provider |
| A root `module` block with source `terraform-aws-modules/iam/aws` | Ban (A2): not a local source |
| The change adds `.checkov.yaml` and a checkov hook | Two bans: [No new scanners or linters](#no-new-scanners-or-linters) on `.checkov.yaml`, [Pre-commit hooks](#pre-commit-hooks) on `.pre-commit-config.yaml` |
| The change adds `examples/complete/.checkov.yaml` | Ban: [No new scanners or linters](#no-new-scanners-or-linters), matched by basename even under `examples/` |
| The change adds `examples/complete/.tfsec/config.yml` | Ban: [No new scanners or linters](#no-new-scanners-or-linters), matched by the directory component `.tfsec` |
| The change adds a step to `.github/workflows/pre-commit.yml` that neither the base file nor the template has | Ban: [Profile-owned files](#profile-owned-files) |
| The change moves `actions/checkout` in a workflow to a newer version than the template pins | No finding: version pins are not read |
| The change adds `.github/workflows/tfsec.yml` | Ban: [Profile-owned files](#profile-owned-files), a new workflow file |
| The change only moves `rev:` in `.pre-commit-config.yaml`, in a module whose base file lacks a hook the template lists | No finding: the rule compares with the base file |
| The change removes the `SWUbanner` line from the root `README.md` | Ban: [The Stand With Ukraine banner](#the-stand-with-ukraine-banner) |

## Open questions

- **Pre-commit hook arguments.** The hooks rule reads repository URLs and hook ids. An
  argument that names an owner, `--module-repo-org`, is decided for a new module: the
  reviewer's [Check E](../../../terraform-module-reviewer/references/check-e-profile.md)
  reports it as `profile.owner-identifier`. Whether any other changed `args` list, such as a
  newly enabled tflint rule, is a ban is not decided.
- **Submodule READMEs.** The banner rule reads the root `README.md` only. Whether a
  submodule's `README.md` carries the banner in this family has not been checked.
- **Support files.** A new file the module's own code reads - a `templatefile` input, a policy
  document, a packaging script - is outside the layout table and fails today. Whether to admit
  a fixed directory for them, or files referenced from `path.module`, is not decided.
- **Lowered pins.** Version pins are not read, so a change that moves a `rev:`, an action
  version or a tool version below what the base has passes every rule here. Whether a pin
  lowered against the base is a finding, and under which check, is not decided.
