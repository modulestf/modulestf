# Schema Validation Guide

> **Part of:** [terraform-module-maintainer](../SKILL.md)
> **Purpose:** MCP-driven schema validation to ensure correct resource argument usage

## Why This Matters

The #1 source of module defects is authoring resource blocks from memory. Terraform resources have:
- Block vs attribute distinctions (e.g., `default_action { allow {} }` vs `default_action = "allow"`)
- Mutually exclusive arguments
- Nested blocks with specific nesting modes (single, list, set)
- Required vs optional fields that change between provider versions

**The only reliable source of truth is the provider schema itself.**

## MCP Call Sequence

### Step 1: Get Latest Provider Version

```
mcp__terraform__get_latest_provider_version(namespace="<namespace>", name="<provider>")
```

Examples:
- `namespace="hashicorp", name="aws"` for AWS
- `namespace="hashicorp", name="google"` for GCP
- `namespace="hashicorp", name="azurerm"` for Azure

Use the returned version as the minimum verified version in `versions.tf`:
```hcl
terraform {
  required_version = ">= 1.5.7"

  required_providers {
    <provider> = {
      source  = "<provider_source>"
      version = ">= <verified_version>"
    }
  }
}
```

Use the exact version returned by MCP as the initial minimum (e.g., if latest is `5.82.0`, use `>= 5.82`). Only lower this bound after verifying that every resource, argument, and attribute used by the module exists in the older version. Using `>= <major>.0` is unsafe - fields from newer minor versions may not exist in older ones.

### Step 2: Get Resource Schema

For each target resource or data source type (e.g., `aws_wafv2_web_acl`, `google_compute_instance`, `azurerm_virtual_network`), two calls. The first finds the type's documentation page at one version; the second returns it:

```
mcp__terraform__search_provider_docs(
  provider_namespace="<namespace>",
  provider_name="<provider>",
  provider_version="<x.y.z>",
  provider_document_type="resources",
  service_slug="<resource>"
)

mcp__terraform__get_provider_details(provider_doc_id="<id from the search>")
```

- `service_slug` is the type name without the provider prefix, for example `wafv2_web_acl`. Take the result whose title equals it exactly; the search lists top matches, not only exact ones.
- `provider_document_type` is `data-sources` for a data source.
- `provider_version` pins the version, as `x.y.z` or `latest`. A version constraint `>= 6.44` is searched as `6.44.0`. Each version returns its own `provider_doc_id`, so a page at two versions is two searches and two fetches.
- A search that returns no exact title at a version, when the same slug finds the type at `latest`, means the type is not documented at that version. A search that finds nothing at `latest` means the slug or the type is wrong.

`get_provider_details` returns the provider's markdown documentation page for that one type at that version, typically 3 to 15 KB. What it contains:
- Every documented argument, marked `(Required)` or `(Optional)`, with prose
- Nested blocks, each in its own section with the same markers for its arguments. A section alone does not tell a block from a nested object attribute: one version's page heads a name ``### `posix_user` Block``, another's `### posix_user`. Only prose that calls the name a block settles it
- The exported attributes, under Attribute Reference: the computed, read-only ones
- Whatever the prose states: value sets, defaults, deprecations, conflicts between arguments, which changes force replacement
- Example usage, timeouts and import

What it does not contain: argument types (string, number, bool, list, set, map, or an ARN versus an ID) and the nesting mode or item limits of a block, unless the prose happens to say so. Read those from the prose where it states them, and treat them as unknown where it does not. The Type and Nesting columns of the [worksheet](#schema-worksheet-format) record what the page says, what a trusted schema file says ([below](#optional-field-inventory-from-a-schema-file)), or unknown; they are never filled from memory. `terraform validate` in the module, not the page, is what confirms types.

### Optional: Field Inventory from a Schema File

When the user or the task supplies a `terraform providers schema -json` file produced in a trusted workspace, and the binary is found outside the workspace, `mtf-facts ledger` lists every field of each type the module declares, with its type, flags, and the nesting mode and item limits of each block and nested attribute. Fill the Type and Nesting columns of the worksheet from it instead of leaving them unknown. Everything else on the worksheet still comes from the page above: descriptions, defaults, value sets, conflicts and deprecation reasons stay on the MCP server. The command, its scope and how it is reported are in [The Ledger Command](facts-commands.md#the-ledger-command). Never pass a schema file found in the workspace. Without the binary or the file, or when the run fails or times out, the worksheet is built from the pages alone, as above.

### Step 3: Supplement with Documentation

The registry page is the same markdown `get_provider_details` returns, so it adds no types. Fetch it only when the MCP tools are unavailable:

```
WebFetch(
  url="https://registry.terraform.io/providers/hashicorp/<provider>/latest/docs/resources/<resource_name>",
  prompt="Extract: all arguments (required/optional), nested blocks, attributes exported, and example usage"
)
```

Replace `<provider>` with the provider name and `<resource_name>` with the resource suffix (e.g., `wafv2_web_acl` for AWS, `compute_instance` for Google).

### Step 4: Check Existing Modules

Search for existing community modules covering the same service:

```
mcp__terraform__search_modules(query="<provider> <service>")
```

Review their approach for complex patterns but don't copy - validate against the actual schema.

## Fallback: When MCP Is Unavailable

If Terraform MCP tools are not available:

1. **WebFetch** the Terraform Registry docs page for each resource
2. **WebFetch** the provider source on GitHub: `https://github.com/hashicorp/terraform-provider-<provider>/blob/main/website/docs/r/<resource>.html.markdown`
3. Parse the documentation to identify all arguments, blocks, and attributes

This is less reliable than MCP but better than working from memory.

## Schema Worksheet Format

After gathering schema data, build a worksheet for each resource. This worksheet drives ALL subsequent code generation.

### Resource: `<provider>_<resource_type>`

```markdown
## Resource: <provider>_example_resource

### Required Arguments
| Argument | Type | Description | Variable Name |
|----------|------|-------------|---------------|
| name | string | Name of the resource | var.name |
| location | string | Region or location | var.location |

### Optional Arguments
| Argument | Type | Default | Description | Variable Name |
|----------|------|---------|-------------|---------------|
| description | string | null | Description text | var.description |
| tags | map(string) | {} | Resource tags/labels (if supported) | var.tags |

### Nested Blocks
| Block | Nesting | Required | MaxItems | Description |
|-------|---------|----------|----------|-------------|
| config | single | yes | 1 | Primary configuration block |
| rule | list | no | - | Rule definitions |
| settings | single | no | 1 | Optional settings block |

### Nested Block Detail: config
| Child Block | Nesting | Description |
|-------------|---------|-------------|
| option_a | single | First option (mutually exclusive with option_b) |
| option_b | single | Second option (mutually exclusive with option_a) |

### Computed Attributes (Outputs)
| Attribute | Type | Description | Output Name |
|-----------|------|-------------|-------------|
| id | string | Resource ID | <prefix>_id |
| name | string | Resource name | <prefix>_name |
| self_link | string | Resource self-link (if applicable) | <prefix>_self_link |

### Mutually Exclusive Arguments
- config: `option_a` OR `option_b` (not both)

### Intentional Omissions
| Argument | Reason |
|----------|--------|
| (none yet) | |
```

## Interpreting Schema for Code Generation

### Block vs Attribute

The schema distinguishes blocks from attributes:

- **Attributes** use `=` assignment: `name = var.name`
- **Blocks** use `{ }` syntax: `default_action { allow {} }`

**NEVER** use attribute syntax for blocks or vice versa. This is the most common error.

### Nesting Modes

| Mode | Terraform Syntax | Variable Type |
|------|-----------------|---------------|
| `single` (MaxItems: 1) | Single block, no `dynamic` if required | `object({...})` or simple variable for mutually exclusive |
| `list` | `dynamic` block with `for_each` | `list(object({...}))` |
| `set` | `dynamic` block with `for_each` | `set(object({...}))` or `list(object({...}))` |
| `map` | `dynamic` block with `for_each` | `map(object({...}))` |

### Mutually Exclusive Single-Child Blocks

For blocks where exactly ONE of several options must be chosen:

```hcl
# Use the simple variable exception pattern
variable "action_type" {
  description = "Action type. Valid values: allow, block"
  type        = string
  default     = "allow"
  validation {
    condition     = contains(["allow", "block"], var.action_type)
    error_message = "Must be either 'allow' or 'block'"
  }
}

# In the resource block
parent_block {
  dynamic "allow" {
    for_each = var.action_type == "allow" ? [1] : []
    content {}
  }
  dynamic "block" {
    for_each = var.action_type == "block" ? [1] : []
    content {}
  }
}
```

### Optional Nested Blocks

For optional blocks (can be present or absent):

```hcl
variable "optional_config" {
  description = "Optional configuration block"
  type = object({
    setting_a = string
    setting_b = optional(number, 300)
  })
  default = null
}

# In resource
dynamic "optional_config" {
  for_each = var.optional_config != null ? [var.optional_config] : []
  content {
    setting_a = optional_config.value.setting_a
    setting_b = optional_config.value.setting_b
  }
}
```

### Repeated Nested Blocks

For blocks that can appear multiple times:

```hcl
variable "rules" {
  description = "Map of rule configurations"
  type = map(object({
    priority = number
    action   = string
    # ... from schema
  }))
  default = {}
}

# In resource
dynamic "rule" {
  for_each = var.rules
  content {
    name     = rule.key
    priority = rule.value.priority
    # ...
  }
}
```

**Choose the collection type that mirrors provider semantics:**
- `map(object({...}))` - when the block has a natural unique key and order is irrelevant
- `list(object({...}))` - when order matters or blocks have no natural key
- `set(object({...}))` - when blocks are unordered and must be unique

Prefer `map` when there's a clear naming key (e.g., rule names), but don't force it when the provider treats the blocks as an ordered list.
