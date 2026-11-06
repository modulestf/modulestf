# Profile: in-repo-modules

> **Part of:** [terraform-module-maintainer](../../SKILL.md)
> **Status:** Shipped profile for in-house modules. It is a starting point to copy and edit, as [Profile Format](../../references/profile-format.md#make-a-custom-profile) says.

Conventions for a private repository that keeps its own reusable modules next to the live root configurations that call them, such as a monorepo with in-house modules. The modules are not published. Their only callers are roots in the same repository.

## What this profile defines

| Area | Where |
|------|-------|
| Module areas and their callers | [Module areas](#module-areas) |
| The files each module holds | [Module layout](#module-layout) |
| What this profile turns off | [Relaxed conventions](#relaxed-conventions) |
| The values a tool reads | [Profile constants](#profile-constants) |

This profile ships no `code-conventions.md`, `SCOPE.md`, templates, templates map, review guide or pull request description rules. Where a rule of the skills links to one of those files, only the generic rule applies.

## Module areas

Any directory holding `.tf` files outside `modules/` and `examples/` is its own module area for `mtf-facts`, so a module may live at any path, such as `infra/modules/network` or `platform/vpc`. A root configuration is an area too. A module's callers are the root configurations and other modules in the same repository whose `module` blocks name it with a local `./` or `../` source. Registry and git sources are not callers in the repository.

A change to a module is reviewed together with its callers. When every caller changes in the same change, `mtf-facts` marks the module for the downgrade of [Profile Format](../../references/profile-format.md#downgrade): a break is MEDIUM with the advice to confirm each caller still works, not CRITICAL.

## Module layout

**Root.** A module area holds `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf` and `README.md`.

**A submodule** under `modules/<name>/` of a module holds the same files: `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf` and `README.md`.

**Examples.** None. The callers in the repository show how each module is used.

No `LICENSE` is required: the repository is private. `README.md` is written by hand or by the repository's own tooling. This profile carries no terraform-docs constants, so the maintainer's documentation pass reports the region stale and never edits it.

## Relaxed conventions

- `consumers: in-repo`: callers live in the same repository, which feeds the downgrade.
- `examples: none`: the example rules are not applicable.
- `release: none`: the release title, changelog, release config, owner and template rules are not applicable.
- `partitions: portable`: an ARN still builds its partition from `local.partition` or the provider. Set `fixed` when every module runs in one partition only.

The [Gate table](../../references/profile-format.md#gate-table) lists each rule an option turns off.

## Profile constants

The blocks in format 1 of [Profile Format](../../references/profile-format.md#format-1). A key written `<key>:` with nothing after the colon has the empty value.

`required-files` restates [Module layout](#module-layout). `regions` are the only two regions a region literal the change adds or edits may name, in every module and root area of the repository: `profile.region-not-allowed` reads them. Edit them to the regions your repository deploys to. `argument-order` is the generic order of the maintainer's module structure reference. The repository owns its own files, so no template, owned file, tooling list or banner applies. `adjunct-types` is the list of supporting AWS types a module may create beside its main resource; edit it for another provider.

```profile-constants
name: required-files
root: main.tf variables.tf outputs.tf versions.tf README.md
submodule: main.tf variables.tf outputs.tf versions.tf README.md
example:
example-dirs:
```

```profile-constants
name: regions
primary: us-east-1
secondary: us-west-2
```

```profile-constants
name: argument-order
first: count for_each
last: tags labels
```

```profile-constants
name: template-destinations
```

```profile-constants
name: profile-owned-files
verbatim:
workflow-dir:
```

```profile-constants
name: tooling
files:
dirs:
```

```profile-constants
name: banner
line:
```

```profile-constants
name: adjunct-types
types: aws_iam_role aws_iam_role_policy aws_iam_role_policy_attachment aws_iam_policy aws_iam_instance_profile aws_cloudwatch_log_group aws_cloudwatch_log_resource_policy aws_security_group aws_vpc_security_group_ingress_rule aws_vpc_security_group_egress_rule aws_security_group_rule
```

```profile-constants
name: profile-options
format: 1
consumers: in-repo
partitions: portable
examples: none
release: none
```
