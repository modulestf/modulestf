# Service Archetypes

> **Part of:** [terraform-module-maintainer](../SKILL.md)
> **Purpose:** Classify provider services by complexity to determine module architecture

## Complexity Classification

Before writing code, classify the target service:

| Complexity | Characteristics | Examples | Module Shape |
|------------|----------------|----------|--------------|
| **Simple** | Single primary resource, few config resources | AWS: S3, SNS; GCP: Cloud Storage, Pub/Sub; Azure: Storage Account | `main.tf` only |
| **Medium** | Primary resource + identity/IAM + logging | AWS: Lambda, WAF; GCP: Cloud Functions, Cloud Run; Azure: Function App | `main.tf` + `iam.tf` |
| **Complex** | Multiple interdependent resources, deployment patterns | AWS: EKS, VPC; GCP: GKE, VPC Network; Azure: AKS, Virtual Network | `main.tf` + `locals.tf` + `iam.tf` + submodules |

## Decision: When to Add Each File

### iam.tf (Identity / Access Management)

Add `iam.tf` when the service requires identity or access management resources:

- **AWS:** IAM roles, policies, assume role policies (`aws_iam_role`, `aws_iam_policy_document`)
- **GCP:** Service accounts, IAM bindings (`google_service_account`, `google_project_iam_member`)
- **Azure:** Role assignments, managed identities (`azurerm_role_assignment`, `azurerm_user_assigned_identity`)

Common triggers:
- Service requires an identity/role to function (compute, serverless, orchestration services)
- Service needs cross-service access permissions
- Service uses trust policies, bindings, or role assignments

For AWS, use `../profiles/terraform-aws-modules/templates/iam.tf.template` as structural inspiration. For other providers, build from the provider schema.

If the provider/service has no identity management concept, skip this file.

### locals.tf

Add `locals.tf` when:
- The module has more than 5-6 local values
- Complex data transformations are needed (flattening, merging)
- Multiple derived conditions exist
- Policy placeholder substitution is used

### Separate feature files (e.g., logging.tf, encryption.tf)

Add separate files when:
- A logical group of resources exceeds ~100 lines
- The feature is independently toggleable
- The resources have their own conditional creation flag

### Submodules (modules/<name>/)

Create a submodule when:
- Functionality is optional and specialized
- The component can be used independently of the root module
- Different deployment patterns exist
- The component has distinct identity/IAM requirements
- Specialized tooling integration is needed

**Each submodule is a complete, standalone module** with its own main.tf, variables.tf, outputs.tf, versions.tf, and README.md.

**Submodule parity rule:** Each submodule needs its own schema worksheet and coverage ledger for every resource it manages. Match the full provider schema for that submodule's scope, not just the subset exercised by root-module examples. Never treat helper submodules (e.g., logging) as "partial by default". If a submodule intentionally omits fields, record the omission explicitly.

## One Provider Configuration per Module

**A reusable module does not declare multiple aliased providers.** It uses the one
provider configuration its caller passes in, and nothing else.

Multiple regions, accounts, subscriptions or projects are the caller's composition
problem, not the module's. The caller instantiates the module once per provider
configuration:

```hcl
module "primary" {
  source = "..."
  providers = { <provider> = <provider>.primary }
}

module "secondary" {
  source = "..."
  providers = { <provider> = <provider>.secondary }
}
```

A module that carries its own aliased providers decides for every consumer which regions
and accounts exist, cannot be instantiated for a region it did not anticipate, and makes
every plan need credentials for all of them.

**Rare exceptions exist.** Some resources are inherently cross-region or cross-account -
cross-region replication, where one resource must reference a peer that only exists under
another provider configuration. When a module genuinely needs a second provider,
document in the module why it is there and what each alias is for, so the next maintainer
does not read it as a pattern to copy. Saving the caller a second `module` block is not a
reason.

## Service Category Guidance

### Compute Services

Services that run code or containers.

**Examples:** AWS Lambda/ECS/EC2, GCP Cloud Functions/Cloud Run/Compute Engine, Azure Functions/Container Apps/Virtual Machines

**Typically need:**
- `iam.tf` - Execution role, service account, or managed identity
- Logging configuration - For execution logs

**Variable sections:**
```
Core -> Service Config -> Identity/IAM -> Monitoring -> Networking (if VPC-attached)
```

**Common patterns:**
- `create_role`/`create_service_account` toggle with fallback to existing identity
- `attach_<policy>_policy` flags for managed policies
- Log retention configuration

### Storage Services

Services for object storage, file systems, block storage, NoSQL databases.

**Examples:** AWS S3/EFS/DynamoDB, GCP Cloud Storage/Filestore/Firestore, Azure Blob Storage/Files/Cosmos DB

**Typically need:**
- Encryption configuration with secure defaults
- Policy/ACL attachment patterns
- Lifecycle rules or TTL configuration

**Variable sections:**
```
Core -> Service Config -> Encryption -> Access Policies -> Lifecycle
```

**Common patterns:**
- Public access denied by default (if provider supports it)
- Encryption configuration as object variable
- Lifecycle rules as list/map of objects

### Network Services

Services for virtual networks, load balancers, API gateways, CDN.

**Examples:** AWS VPC/ALB/API Gateway, GCP VPC Network/Load Balancer/Cloud Endpoints, Azure VNet/Application Gateway/API Management

**Typically need:**
- Multiple related resources (subnets, route tables, listeners)
- Zone/AZ distribution patterns
- Security groups, firewall rules, or NSG rules

**Variable sections:**
```
Core -> Network Config -> Subnets/Ranges -> Security -> DNS -> Logging
```

**Common patterns:**
- Zone-based `count` or `for_each` for subnets
- Named listener/forwarding rules
- Multiple related output groups (public IDs, private IDs)

### Security Services

Services for WAF, threat detection, key management, security monitoring.

**Examples:** AWS WAF/KMS/GuardDuty, GCP Cloud Armor/Cloud KMS/Security Command Center, Azure WAF/Key Vault/Defender

**Typically need:**
- Rule/policy configuration as complex nested structures
- Association resources (WAF -> LB, KMS -> resource)

**Variable sections:**
```
Core -> Service Config -> Rules/Policies -> Associations -> Logging
```

**Common patterns:**
- `rules` as `map(object({...}))` for named rules
- `association_resource_id` for connecting to other resources
- Deeply nested dynamic blocks for rule statements

### Database Services

Services for relational databases, caches, data warehouses.

**Examples:** AWS RDS/ElastiCache/Redshift, GCP Cloud SQL/Memorystore/BigQuery, Azure SQL/Redis Cache/Synapse

**Typically need:**
- Network group (subnet group, private endpoint)
- Parameter/configuration group
- Security groups or firewall rules
- Backup and maintenance configurations

**Variable sections:**
```
Core -> Instance Config -> Network -> Parameters -> Backup -> Monitoring
```

**Common patterns:**
- `create_network_group` toggle for subnet/endpoint configuration
- `create_security_rule` with ingress/egress or firewall rules
- `backup_retention` and `maintenance_window`

## Module Shape Quick Reference

| If your module has... | Then add... |
|----------------------|-------------|
| Identity/IAM resources | `iam.tf` |
| >5 locals | `locals.tf` |
| >100 lines for a feature group | `<feature>.tf` |
| Optional specialized functionality | `modules/<name>/` submodule |
| Logging/monitoring resources | Logging section in `main.tf` or `logging.tf` |

## Examples Pattern by Complexity

### Simple Module
```
examples/
|-- basic/        # Minimal: just name + required config
`-- complete/     # All options enabled + disabled module call
```

### Medium Module
```
examples/
|-- basic/        # Minimal: name + required config
|-- complete/     # All features + IAM + logging + disabled module call
`-- <feature>/    # Feature-specific (e.g., with-existing-role/)
```

### Complex Module
```
examples/
|-- basic/        # Minimal: core resource only
|-- complete/     # Everything enabled + disabled module call
|-- <pattern-a>/  # Deployment pattern A
`-- <pattern-b>/  # Deployment pattern B
```

## New Example or Updated Example

When a change adds a feature, decide where it gets demonstrated before writing anything.

Add a **new** example when:

- The feature is a different use case from anything the existing examples show
- The feature needs a different architecture around it
- The feature is a pattern worth teaching on its own, typically several inputs that only
  make sense together

Update an **existing** example when:

- The feature enhances something an example already demonstrates
- The feature is one or two simple inputs
- The feature is commonly used together with what an example already shows

Default to updating. Every example is a directory that has to keep validating, so a new
one earns its place by teaching something the existing ones cannot. The `complete`
example is the usual home for a feature that has no better place.
