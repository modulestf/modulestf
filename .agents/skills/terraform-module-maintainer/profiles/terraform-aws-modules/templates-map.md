# Templates Map

> **Part of:** [terraform-module-maintainer](../../SKILL.md)
> **Purpose:** Mapping of template files to module destinations, placeholder rules

## Template Location

All templates are at: `templates/`

## Static Files (Copy Verbatim)

These files are copied as-is with no modification. After copying, run `pre-commit autoupdate` to refresh pinned versions.

| Template Source | Destination | Notes |
|----------------|------------|-------|
| `.editorconfig.template` | `<module>/.editorconfig` | No changes needed |
| `.gitignore.template` | `<module>/.gitignore` | No changes needed |
| `.releaserc.json.template` | `<module>/.releaserc.json` | No changes needed |
| `github-workflows-pre-commit.yml.template` | `<module>/.github/workflows/pre-commit.yml` | No changes needed |
| `github-workflows-release.yml.template` | `<module>/.github/workflows/release.yml` | No changes needed |
| `github-workflows-lock.yml.template` | `<module>/.github/workflows/lock.yml` | No changes needed |
| `github-workflows-pr-title.yml.template` | `<module>/.github/workflows/pr-title.yml` | No changes needed |
| `github-workflows-stale-actions.yaml.template` | `<module>/.github/workflows/stale-actions.yaml` | No changes needed |

Typography exception: `templates/github-workflows-lock.yml.template` keeps two hourglass emoji (U+23F3). It is upstream terraform-aws-modules text copied verbatim, so removing them would make every generated module diverge from the family. Do not convert them to ASCII.

## Pre-Commit Config (Copy Then Update)

| Template Source | Destination | Post-Copy Action |
|----------------|------------|-----------------|
| `.pre-commit-config.yaml.template` | `<module>/.pre-commit-config.yaml` | Run `pre-commit autoupdate` to get latest versions |

The template has pinned versions that may be stale. `pre-commit autoupdate` fixes this automatically.

Source of the pins: `.pre-commit-config.yaml.template` and `github-workflows-pre-commit.yml.template` are the files of `terraform-aws-modules/terraform-aws-s3-bucket` at commit `5dc2f1f89743ab935114b0b039bc88044a672ca2` on `master`, read on 2026-10-01: pre-commit-terraform `v1.108.1`, pre-commit-hooks `v6.0.0`, terraform-docs `v0.24.0`, TFLint `v0.64.0`. The workflow template adds one thing upstream lacks: `HCLEDIT_VERSION: 0.2.17`, passed as `hcledit-version` to the pre-commit action, which pins the version that action installs by default at `v1.14.0`. To refresh, copy both files from a family repository's default branch, keep the hcledit pin, and record the repository and commit here.

## Skeletal Templates (Copy Then Customize)

These templates contain placeholders that must be replaced with service-specific content.

| Template Source | Destination | Customization |
|----------------|------------|---------------|
| `versions.tf.template` | `<module>/versions.tf`, and `<module>/modules/<name>/versions.tf` for a submodule that requires `hashicorp/aws` | Replace provider name, source, and version from MCP. `{{module_name}}` in the `provider_meta` user agent is the repository name after `terraform-aws-`, in a submodule too: [Module layout](PROFILE.md#module-layout) |
| `example-versions.tf.template` | `<module>/examples/*/versions.tf` | Replace provider name, source, and version from MCP. No `provider_meta`: an example is a caller |
| `README.md.template` | `<module>/README.md` | Replace placeholders, but DO NOT write content between terraform-docs markers |
| `example-README.md.template` | `<module>/examples/*/README.md` | Replace placeholders |

## Schema-Driven Files (Do NOT Copy Templates)

These template files exist as structural examples but must be **generated from the schema worksheet**, not copied:

| Template | Why Not Copy |
|----------|-------------|
| `main.tf.template` | Provider-specific data sources and resource blocks vary |
| `variables.tf.template` | Service-specific - only core variables are universal, and `putin_khuylo` at the root only: [Module layout](PROFILE.md#module-layout) |
| `outputs.tf.template` | Service-specific - outputs depend on provider schema |
| `iam.tf.template` | AWS-specific - other providers have different identity patterns |
| `example-complete-main.tf.template` | Placeholder features - must use real module variables |
| `example-complete-outputs.tf.template` | Output names depend on the module |
| `test-basic.tftest.hcl.template` | Output names depend on the module |

For these files, use the templates as **structural inspiration** for consistent formatting, but populate content from the schema worksheet.

## Wrappers

The `wrappers/` directory (main.tf, variables.tf, outputs.tf, versions.tf, README.md) is **auto-generated** by the `terraform_wrapper_module_for_each` pre-commit hook. Do NOT create wrapper files manually.

## Placeholder Reference

Templates use these placeholders:

| Placeholder | Description | Example Value |
|-------------|-------------|---------------|
| `{{provider}}` | Provider short name | `aws`, `google`, `azurerm` |
| `{{provider_source}}` | Provider source | `hashicorp/aws`, `hashicorp/google` |
| `{{provider_version}}` | Provider minimum version | `6.0`, `6.14`, `4.0` |
| `{{SERVICE_NAME}}` | Service display name | `WAF v2 Web ACL`, `Compute Instance` |
| `{{service}}` | Service identifier | `wafv2`, `compute` |
| `{{resource_type}}` | Terraform resource suffix | `wafv2_web_acl`, `compute_instance` |
| `{{MODULE_NAME}}` | Module display name | `WAF v2`, `Compute Instance` |
| `{{module_name}}` | Module identifier (kebab-case) | `wafv2`, `compute-instance` |
| `{{service_name}}` | Service name for examples | `wafv2`, `compute` |

## Copy Workflow

```bash
# 1. Create module directory
mkdir -p terraform-<provider>-<service>/{examples/{basic,complete},.github/workflows}

# 2. Copy static files (verbatim)
cp templates/.editorconfig.template terraform-<provider>-<service>/.editorconfig
cp templates/.gitignore.template terraform-<provider>-<service>/.gitignore
cp templates/.releaserc.json.template terraform-<provider>-<service>/.releaserc.json
cp templates/.pre-commit-config.yaml.template terraform-<provider>-<service>/.pre-commit-config.yaml
cp templates/github-workflows-pre-commit.yml.template terraform-<provider>-<service>/.github/workflows/pre-commit.yml
cp templates/github-workflows-release.yml.template terraform-<provider>-<service>/.github/workflows/release.yml
cp templates/github-workflows-lock.yml.template terraform-<provider>-<service>/.github/workflows/lock.yml
cp templates/github-workflows-pr-title.yml.template terraform-<provider>-<service>/.github/workflows/pr-title.yml
cp templates/github-workflows-stale-actions.yaml.template terraform-<provider>-<service>/.github/workflows/stale-actions.yaml

# 3. Copy versions.tf (will be updated with provider details from MCP)
cp templates/versions.tf.template terraform-<provider>-<service>/versions.tf
cp templates/example-versions.tf.template terraform-<provider>-<service>/examples/basic/versions.tf
cp templates/example-versions.tf.template terraform-<provider>-<service>/examples/complete/versions.tf

# 4. Generate Apache 2.0 LICENSE file

# 5. Update pre-commit hooks to latest
cd terraform-<provider>-<service> && pre-commit autoupdate
```

## What NOT to Copy

- Never copy `main.tf.template` verbatim - generate from schema
- Never copy `variables.tf.template` verbatim - generate from schema
- Never copy `outputs.tf.template` verbatim - generate from schema
- Never manually create files in `wrappers/` - auto-generated by pre-commit hook
- Never manually write content between a README's documentation markers - `terraform-docs` generates it. Read the marker pair out of the file rather than assuming one: `<!-- BEGIN_TF_DOCS -->` / `<!-- END_TF_DOCS -->` is terraform-docs' own default, `<!-- BEGINNING OF PRE-COMMIT-TERRAFORM DOCS HOOK -->` / `<!-- END OF PRE-COMMIT-TERRAFORM DOCS HOOK -->` is the older pre-commit-terraform spelling that `README.md.template` ships, and neither is the one true pair - whichever pair the file already carries is the one that file uses
