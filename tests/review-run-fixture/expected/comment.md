This drops `compact()` around `vpc_security_group_ids` on `aws_rds_cluster.this`, so a security group id that is unknown at plan now shows as known after apply instead of hiding the change. Null and empty-string entries of `var.vpc_security_group_ids` now reach the provider too; the description names only the empty strings.

**Good to merge, with nits.** `validate` passed in all 9 examples; 6 were planned. 3 of 9 examples were not planned because of the review safety checks; the changed code was planned in `examples/alpha` (see notes).

- LOW `compat.claim-contradicts-analysis` `.` - The description says losing the filter of empty strings is the only behaviour removed; null elements of var.vpc_security_group_ids are no longer dropped either and now reach the provider.
  - Fix: no code change: in the Breaking Changes section, replace the sentence on the only behaviour removed with: Empty-string and null elements of `vpc_security_group_ids` are no longer dropped; both now reach the provider.
- LOW `structure.argument-order` [`main.tf:43`](https://github.com/example-org/terraform-aws-widget/blob/a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1/main.tf#L43) - In resource aws_rds_cluster.this, which the change edits, tags is not the last argument: vpc_security_group_ids and the dynamic timeouts block follow it.
  - Fix: In resource "aws_rds_cluster" "this", move `tags = merge(var.tags, var.cluster_tags)` below `vpc_security_group_ids` and the `dynamic "timeouts"` block, per Argument Order in a Resource Block in the maintainer's module-structure.md.
- LOW `compat.expression-behaviour-changed` [`main.tf:156`](https://github.com/example-org/terraform-aws-widget/blob/a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1/main.tf#L156) - Without compact(), null and empty-string elements of var.vpc_security_group_ids now reach the provider where the base dropped them; at L3, a null beside an unknown id changes whether the plan errors.
  - Fix: needs decision: whether null and empty-string elements of var.vpc_security_group_ids keep reaching the provider: (a) in resource "aws_rds_cluster" "this", filter only that input, as `concat(aws_security_group.this[*].id, [for id in var.vpc_security_group_ids : id if id != null && id != ""])`; a filter over an input that may be unknown makes the list unknown again at plan, the defect the change removed; (b) keep the change and state in the description that null and empty-string elements of `vpc_security_group_ids` now reach the provider instead of being dropped.

<details><summary>Evidence and notes</summary>

- Not planned: `examples/echo` (G3 hit in a downloaded module; the pull request cannot change it).
- Not planned: `examples/golf` (G3 hit in `examples/golf/main.tf`, same at base b2b2b2b).
- Not planned: `examples/hotel` (G3 hit in `examples/hotel/main.tf`, same at base b2b2b2b).
- Covered by: `vpc_security_group_ids` planned in `examples/alpha` as `module.widget.aws_rds_cluster.this` at a1a1a1a.
- Behaviour change at [`main.tf:156`](https://github.com/example-org/terraform-aws-widget/blob/a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1/main.tf#L156) reported: judged in F-003 (5 differences). 3 claims verified.
- Claims quoted from the discussion and not confirmed from the code: 1.
</details>
