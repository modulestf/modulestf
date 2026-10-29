# Module Structure Patterns

> **Part of:** [terraform-module-maintainer](../SKILL.md)
> **Purpose:** Patterns for main.tf, variables.tf, outputs.tf, and supporting files

For general Terraform best practices (block ordering, naming conventions, count vs for_each), consult the `antonbabenko/terraform-skill` plugin. This file covers module-author-specific patterns.

## File Organization

### Which Files a Module Has

Four `.tf` files are universal, whatever the provider: `main.tf` holds the resources,
`variables.tf` the inputs, `outputs.tf` the outputs, and `versions.tf` the Terraform and
provider constraints. `README.md` sits beside them. Every other `.tf` file at the root is
an extraction from `main.tf` once it has grown, and which ones a module needs follows from
its archetype: [service-archetypes.md](service-archetypes.md#module-shape-quick-reference).

Each example under `examples/`, and each submodule under `modules/<name>/`, is itself a
root configuration or a module in that same shape, with its own copies of those files.

The rest of a module's file set - the license, the static dotfiles, the CI workflows, the
generated `wrappers/` directory, which examples are mandatory - belongs to the module
family, not to Terraform. The default profile states it in
[Module layout](../profiles/terraform-aws-modules/PROFILE.md#module-layout).

### Element Order in main.tf

1. **Data sources** (top - provider-specific context data)
2. **Locals** (computation layer)
3. **Primary resource** (core service resource)
4. **Configuration resources** (settings, policies attached to primary)
5. **Supporting resources** (identity/IAM, logging, etc. - in separate files if complex)

### Section Headers

Use consistent comment headers to separate sections:

```hcl
################################################################################
# Section Name
################################################################################
```

### Argument Order in a Resource Block

Inside a single resource block, keep this order:

1. `count` or `for_each`
2. Required arguments
3. Optional arguments
4. Nested blocks and `dynamic` blocks
5. `tags` (or `labels`) last

```hcl
resource "<provider>_<resource>" "this" {
  count = local.create ? 1 : 0

  name = var.name

  description = var.description
  setting_one = var.setting_one

  dynamic "nested_block" {
    for_each = var.nested_configs

    content {
      key   = nested_block.value.key
      value = nested_block.value.value
    }
  }

  tags = var.tags
}
```

The creation meta-argument reads first because it decides whether the rest of the block
happens at all, and tags read last because every module puts them there, so a reviewer
knows where to look without searching.

## Locals Pattern

Every module starts with a base `create` local:

```hcl
locals {
  create = var.create
}
```

A module family may add its own conjunct to this local. The default profile does:
[Module layout](../profiles/terraform-aws-modules/PROFILE.md#module-layout).

Add provider-specific data source locals as needed. Common patterns by provider:

```hcl
# AWS - account, partition, region context
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  create     = var.create
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
}

# GCP - project and region context
data "google_client_config" "current" {}

locals {
  create  = var.create
  project = data.google_client_config.current.project
  region  = data.google_client_config.current.region
}

# Azure - subscription and tenant context
data "azurerm_client_config" "current" {}

locals {
  create          = var.create
  subscription_id = data.azurerm_client_config.current.subscription_id
  tenant_id       = data.azurerm_client_config.current.tenant_id
}
```

The AWS block assumes provider major 6. There `data.aws_region.current.region` is the
region attribute and `name` is a deprecated argument kept for compatibility. On provider
major 5 there is no `region` attribute and `name` is the one to read, so a module still
pinned below 6 uses `data.aws_region.current.name` instead. Confirm the attribute for the
version the module targets with the Terraform MCP tools before writing it, the same way as
any other provider fact.

Add derived conditions as needed:

```hcl
locals {
  create      = var.create
  create_role = local.create && var.create_role
}
```

## Variables Patterns

### Grouping

Group variables with section headers in this order:

1. **Core Configuration** - `create`, `name`, `tags`, plus any core variable the profile requires
2. **Service Configuration** - All resource arguments from the schema worksheet
3. **Identity / IAM Configuration** - `create_role`, `role_name`, policy attachments (if applicable)
4. **Monitoring & Logging** - Logging configuration (if applicable)

### Core Variables (Every Module)

```hcl
variable "create" {
  description = "Controls if resources should be created (affects all resources)"
  type        = bool
  default     = true
}

variable "name" {
  description = "Name of the <service resource>"
  type        = string
  default     = ""
}

variable "tags" {
  description = "A map of tags to add to all resources"
  type        = map(string)
  default     = {}
}
```

**Important notes:**
- `create` is universal. `name` and `tags` are only included when the target schema supports them. A profile may require further core variables of its own.
- GCP uses `labels` instead of `tags`. Some providers have no tagging concept - omit accordingly.
- If the resource requires `name`, do NOT default to `""` - either make it required (no default) or use a sensible default.
- Check the provider schema before including `name` or `tags` - not all resources have them.

### Variable Types: Prefer Specific Over `any`

Map schema types to Terraform variable types:

| Schema Type | Variable Type |
|-------------|---------------|
| String argument | `string` with `default = null` |
| Number argument | `number` with `default = null` |
| Boolean argument | `bool` with appropriate default |
| Single nested block | `object({...})` with `default = null` |
| Repeated nested block (named) | `map(object({...}))` with `default = {}` |
| Repeated nested block (ordered) | `list(object({...}))` with `default = []` |
| Truly polymorphic | `any` (last resort, document why) |

Use `optional()` for nested object attributes (Terraform 1.3+):

```hcl
variable "config" {
  type = object({
    required_field = string
    optional_field = optional(string)
    with_default   = optional(number, 300)
  })
  default = null
}
```

### Default Value Strategy

| Category | Default | Reason |
|----------|---------|--------|
| Security-critical (encryption, public access) | Secure value (`true`/`false`) | Safe by default |
| Optional features | `false` or `null` | Opt-in |
| Optional arguments | `null` | Let the provider decide |
| Collections | `{}` or `[]` | Empty, no resources created |

### Feature Flag Naming and Default Polarity

Three prefixes carry three different promises. The prefix and the default go together:
picking one without the other is how a module changes behaviour behind its callers' backs.

| Prefix | What the flag means | Default | Polarity |
|--------|--------------------|---------|----------|
| `enable_<x>` | Turn on a feature the module does not provide by default | `false` | Opt in |
| `create_<x>` | Create a resource the module owns as part of its core job | `true` | Opt out |
| `attach_<x>` | Attach a policy, rule, or association to something else | `false` | Opt in |

Why the polarity matters: nobody sets a variable they have never heard of. A new
`enable_*` input that defaults to `true` ships the feature to every existing caller on
their next plan, as infrastructure they did not ask for - an additive-looking change that
is behaviour-changing in fact. A `create_*` input defaults to `true` for the mirror-image
reason: the resource is already there for every caller, so defaulting to `false` would
destroy it.

Pick the prefix from what the flag actually does, and match the prefixes the module
already uses. A feature that is new to the module is `enable_*` even when a sibling
resource is behind a `create_*` flag.

### Variable Descriptions

Always include:
- What the variable controls (action verb)
- Valid values if constrained
- Conflicts with other variables if applicable
- Reference to provider documentation for complex types

```hcl
variable "location" {
  description = "Specifies the region or location for the resource. Check provider documentation for valid values"
  type        = string
}
```

### Validation Rules

Use sparingly - the provider already validates most values. Add validation only for:
- Enum values that are easy to get wrong
- Values that would cause confusing downstream errors

What a validation must not do, and the reasoning for each case, is in
[code-conventions.md](../profiles/terraform-aws-modules/code-conventions.md#validation).

### Preconditions for Cross-Field Invariants

Use `validation` for single-variable checks. Use `lifecycle` `precondition` blocks when correctness depends on multiple inputs or feature toggles.

Add a precondition when:
- Enabling a feature requires companion inputs (e.g., logging enabled requires at least one destination)
- A "use existing" path requires an ID/ARN when creation is disabled
- Exactly one of several top-level inputs must be set (e.g., `rules` vs `rule_json`)

If the provider would only fail during plan/apply with a vague message, add the precondition in the module.

```hcl
variable "scope" {
  description = "Resource scope. Valid values: REGIONAL, GLOBAL"
  type        = string
  default     = "REGIONAL"

  validation {
    condition     = contains(["REGIONAL", "GLOBAL"], var.scope)
    error_message = "Scope must be either 'REGIONAL' or 'GLOBAL'. Got: ${var.scope}"
  }
}
```

### Error Messages Name the Offending Value

The `error_message` is the only part of a `validation` or `precondition` block the consumer
ever sees. State the accepted values or the bound, the value that was received, and what to
do about it.

```hcl
# DON'T: the consumer learns nothing
error_message = "Invalid"

# DO: the bound, the value received, and the fix
error_message = "Instance count must be between 1 and 100. Got: ${var.instance_count}. Set it within that range."
```

## Outputs Patterns

### Expose Stable, User-Useful Computed Attributes

Expose computed attributes that consumers would reference. Preserve correct types in fallbacks:

```hcl
output "<prefix>_id" {
  description = "The ID of the <resource>"
  value       = try(<provider>_<resource>.this[0].id, null)
}

output "<prefix>_name" {
  description = "The name of the <resource>"
  value       = try(<provider>_<resource>.this[0].name, null)
}
```

**Fallback type rules:**
- String attributes: use `null` (not `""` - empty string hides absence)
- Number attributes: use `null`
- List attributes: use `[]`
- Map attributes: use `{}`
- Sensitive attributes: set `sensitive = true` or document as intentional omission

**Omit** ephemeral/write-only attributes and internal-only computed fields that have no consumer value.

### Output Naming

- Prefix with resource type for clarity: `web_acl_id`, `instance_self_link`
- For provider-specific supporting resources, use descriptive prefixes (e.g., `role_arn`, `service_account_email`, `identity_principal_id`)

### Conditional Outputs with try()

Always use `try()` for resources that may not exist. Match the fallback type to the attribute type:

```hcl
output "id" {
  description = "The ID of the resource"
  value       = try(<provider>_<resource>.this[0].id, null)
}
```

For multiple possible sources:

```hcl
output "endpoint" {
  description = "The endpoint URL"
  value       = try(<provider>_<resource>.this[0].endpoint, <provider>_<resource>.alternative[0].endpoint, null)
}
```

## Dynamic Block Patterns

### Required Single Block

For required blocks that must always be present:

```hcl
config {
  setting_a = var.config.setting_a
  setting_b = var.config.setting_b
}
```

### Optional Single Block

For blocks that can be present or absent:

```hcl
dynamic "optional_block" {
  for_each = var.optional_config != null ? [var.optional_config] : []
  content {
    setting = optional_block.value.setting
  }
}
```

### Mutually Exclusive Blocks (Simple Variable Pattern)

For blocks where exactly one option must be chosen:

```hcl
variable "action_type" {
  description = "Action type. Valid values: allow, block, count, captcha"
  type        = string
  validation {
    condition     = contains(["allow", "block", "count", "captcha"], var.action_type)
    error_message = "Must be one of: allow, block, count, captcha. Got: ${var.action_type}"
  }
}

# In resource
dynamic "allow" {
  for_each = var.action_type == "allow" ? [1] : []
  content {}
}
dynamic "block" {
  for_each = var.action_type == "block" ? [1] : []
  content {}
}
```

### Repeated Blocks from Map

For blocks that appear zero or more times with unique keys:

```hcl
variable "custom_entries" {
  description = "Map of entry configurations"
  type = map(object({
    value = string
    type  = string
  }))
  default = {}
}

dynamic "entry" {
  for_each = var.custom_entries
  content {
    key   = entry.key
    value = entry.value.value
    type  = entry.value.type
  }
}
```

### Consistent Field Coverage in Nested Dynamic Blocks

If the provider reuses the same block shape at multiple nesting levels (e.g., `statement` blocks at level 0, 1, 2 in WAF), keep every level in sync unless the schema explicitly differs. After implementing level 0, compare level 1/2 renderers against the same child-block inventory before moving on. Common failure mode: level 0 supports all `field_to_match` variants but deeper branches expose only a subset.

### Sibling Block Symmetry Check

When a parent block has mutually exclusive siblings (e.g., `allow`, `block`, `count`, `challenge` actions), inspect each sibling's schema before assuming they all use the same empty `content {}` shape. If one sibling supports nested options (e.g., `custom_request_handling`), verify every other sibling for equivalent children and implement or document the differences explicitly. Do not stop after the first working branch.

### Deeply Nested Dynamic Blocks

For complex nested structures, nest `dynamic` blocks:

```hcl
dynamic "rule" {
  for_each = var.rules
  content {
    name     = rule.key
    priority = rule.value.priority

    dynamic "action" {
      for_each = rule.value.action != null ? [rule.value.action] : []
      content {
        dynamic "allow" {
          for_each = action.value.type == "allow" ? [1] : []
          content {}
        }
        dynamic "block" {
          for_each = action.value.type == "block" ? [1] : []
          content {}
        }
      }
    }
  }
}
```

## Dependency Management

### Implicit (Preferred)

```hcl
resource "<provider>_config" "this" {
  count = local.create ? 1 : 0

  resource_id = <provider>_primary.this[0].id  # Implicit dependency
}
```

### Explicit (When Needed)

Use `depends_on` only when there's a race condition with no direct reference:

```hcl
resource "<provider>_policy" "this" {
  count = local.create && local.attach_policy ? 1 : 0

  resource_id = <provider>_resource.this[0].id
  policy      = data.<provider>_policy_document.combined[0].json

  depends_on = [
    <provider>_access_control.this,
  ]
}
```

### Waiting Out Provider Eventual Consistency

Some provider APIs are eventually consistent: a resource is created, and for a few seconds
another API cannot see it yet. A consumer of that resource then fails on the same apply with
a not-found error. `depends_on` alone does not help, because the ordering is already correct
and the remote side is simply late.

The accepted remedy is a wait resource with a fixed duration placed between the two, ordered
by `depends_on` on both sides, carrying a comment that names the API whose consistency it is
working around:

```hcl
# The <provider> API is eventually consistent for this resource: it is not visible
# to <consuming API> for a few seconds after creation.
resource "time_sleep" "wait_for_identity" {
  count = local.create ? 1 : 0

  depends_on      = [<provider>_identity.this]
  create_duration = "10s"
}

resource "<provider>_consumer" "this" {
  count = local.create ? 1 : 0

  identity_id = <provider>_identity.this[0].id

  depends_on = [time_sleep.wait_for_identity]
}
```

`time_sleep` comes from the `time` provider, so `versions.tf` has to declare it.

A fixed wait is a workaround, not a guarantee. It pays a delay on every apply and can still
lose the race on a slow day. Use a direct reference whenever one exists, and drop the wait
when the provider gives you one.

## Scanner Suppressions

Which security scanners run, and whether any run at all, is the profile's business. The
convention that holds everywhere: a suppression is a decision to accept a risk, so it
carries the reason for accepting it. Put the reason in plain language on the directive
line itself or on a comment line next to it.

```hcl
# <scanner>:<ignore-directive>:<rule-id>
# Logging is optional and controlled by var.enable_logging, so the consumer opts in.
resource "<provider>_<resource>" "this" {
  # ...
}
```

A suppression with no reason is indistinguishable from a finding that someone silenced to
get a check passing, and the next maintainer has no way to tell whether it is still true.

## Keep Nested Objects Matching Provider Schema

Preserve the provider's nesting structure even when it seems unnecessary:

```hcl
# DO: Match provider schema
variable "nested_config" {
  type = object({
    inner_property = object({
      value = number
    })
  })
  default = null
}

# DON'T: Flatten the structure
variable "nested_value" {
  type    = number
  default = null
}
```

This ensures forward compatibility when providers add sibling fields.
