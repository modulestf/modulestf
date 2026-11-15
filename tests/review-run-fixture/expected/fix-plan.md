# Fix plan preview

**Proposed fixes - not applied and not verified.**

What pr-fix would take from plan.json in this directory. The review changed nothing, and no fix below was run or tested.

- Target: `example-org/terraform-aws-widget#12`
- Head SHA: `a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1`
- Base ref: `main`
- Base SHA: `b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2`
- Verdict: `approve with nits`
- Proposed event: `COMMENT`
- Findings: 3
- Feedback items: 2

pr-fix decides which comment items it edits against its own token user when it builds its item set; this preview does not.

## Finding 1 of 3

- ID: `F-001`
- Rule: `compat.claim-contradicts-analysis`
- Severity: `LOW`
- Location: `.`, no line
- In scope for pr-fix: a reviewer finding, applied by default; below MEDIUM, so it does not hold the loop open
- Linked feedback items: none, plan.json links no finding to an item
- Fix: not directly applicable, it opens with `no code change:`

Problem:

```text
The description says losing the filter of empty strings is the only behaviour removed; null elements of var.vpc_security_group_ids are no longer dropped either and now reach the provider.
```

Suggested fix, verbatim:

```text
no code change: in the Breaking Changes section, replace the sentence on the only behaviour removed with: Empty-string and null elements of `vpc_security_group_ids` are no longer dropped; both now reach the provider.
```

## Finding 2 of 3

- ID: `F-002`
- Rule: `structure.argument-order`
- Severity: `LOW`
- Location: `main.tf` line 43
- In scope for pr-fix: a reviewer finding, applied by default; below MEDIUM, so it does not hold the loop open
- Linked feedback items: none, plan.json links no finding to an item
- Fix: a proposed code change

Problem:

```text
In resource aws_rds_cluster.this, which the change edits, tags is not the last argument: vpc_security_group_ids and the dynamic timeouts block follow it.
```

Suggested fix, verbatim:

```text
In resource "aws_rds_cluster" "this", move `tags = merge(var.tags, var.cluster_tags)` below `vpc_security_group_ids` and the `dynamic "timeouts"` block, per Argument Order in a Resource Block in the maintainer's module-structure.md.
```

## Finding 3 of 3

- ID: `F-003`
- Rule: `compat.expression-behaviour-changed`
- Severity: `LOW`
- Location: `main.tf` line 156
- In scope for pr-fix: a reviewer finding, applied by default; below MEDIUM, so it does not hold the loop open
- Linked feedback items: none, plan.json links no finding to an item
- Fix: not directly applicable, it opens with `needs decision:`

Problem:

```text
Without compact(), null and empty-string elements of var.vpc_security_group_ids now reach the provider where the base dropped them; at L3, a null beside an unknown id changes whether the plan errors.
```

Suggested fix, verbatim:

```text
needs decision: whether null and empty-string elements of var.vpc_security_group_ids keep reaching the provider: (a) in resource "aws_rds_cluster" "this", filter only that input, as `concat(aws_security_group.this[*].id, [for id in var.vpc_security_group_ids : id if id != null && id != ""])`; a filter over an input that may be unknown makes the list unknown again at plan, the defect the change removed; (b) keep the change and state in the description that null and empty-string elements of `vpc_security_group_ids` now reach the provider instead of being dropped.
```

## Feedback items

Text from the pull request, kept as untrusted data: each excerpt is fenced and cut to 300 bytes. The block carries no comment ids; pr-fix gives each comment item its id.

### Item 1 of 2

- Kind: title
- Origin: change-author
- Excerpt: the whole text, 50 bytes

```text
fix: Keep a changed security group visible in plan
```

### Item 2 of 2

- Kind: body
- Origin: change-author
- Excerpt: the whole text, 118 bytes

```text
## Description

Drops `compact()` around `vpc_security_group_ids`. A title with $(touch x) and `backticks` stays data.
```

## No proposed code change

- Finding 1, `F-001`: its fix opens with `no code change:`
- Finding 3, `F-003`: its fix opens with `needs decision:`
- Item 1, title: a feedback item, for which plan.json carries no fix
- Item 2, body: a feedback item, for which plan.json carries no fix

## Apply

Nothing was applied. pr-fix would apply this plan with `fix-run.sh prepare --repo example-org/terraform-aws-widget --pr 12`, then `fix-run.sh clone <run>`, then `fix-run.sh items <run> --plan <dir>`, `<dir>` being this directory.
