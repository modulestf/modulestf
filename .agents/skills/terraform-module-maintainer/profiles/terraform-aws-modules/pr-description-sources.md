# Pull Request Description: Source Material

> **Part of:** [terraform-module-maintainer](../../SKILL.md)
> **Purpose:** The material [pr-description.md](pr-description.md) was derived from, quoted
> with its provenance, so the derivation can be checked later without refetching anything
> from a code host.

Nothing here is a rule. The rules are in [pr-description.md](pr-description.md).

**Redaction.** Provenance is the repository, the pull request number, and the date
retrieved. Author handles are replaced by a role, because no rule in the standard depends
on who wrote a description. The one at-mention the source material carried was dropped
rather than reproduced, so a file in a repository cannot notify a person who never asked to
be part of this. No URL, email address or account identifier is copied.

## Item 1: the inherited pull request template

**Source:** the org `.github` repository, `PULL_REQUEST_TEMPLATE.md`. Retrieved
2026-09-22. Repositories in this family carry no template of their own and inherit this one,
which GitHub pre-fills into the body of every pull request.

```markdown
## Description
<!--- Describe your changes in detail -->

## Motivation and Context
<!--- Why is this change required? What problem does it solve? -->
<!--- If it fixes an open issue, please link to the issue here. -->

## Breaking Changes
<!-- Does this break backwards compatibility with the current major version? -->
<!-- If so, please provide an explanation why it is necessary. -->

## How Has This Been Tested?
- [ ] I have updated at least one of the `examples/*` to demonstrate and validate my change(s)
- [ ] I have tested and validated these changes using one or more of the provided `examples/*` projects
<!--- Users should start with an existing example as its written, deploy it, then check their changes against it -->
<!--- This will highlight breaking/disruptive changes. Once you have checked, deploy your changes to verify -->
<!--- Please describe how you tested your changes -->
- [ ] I have executed `pre-commit run -a` on my pull request
```

Two things the standard extends rather than restates. The four headings are the required
set. The comment under the checkboxes asks the author to describe how they tested, which is
why the standard treats a tick as a claim and the prose under it as the evidence.

## Item 2: the keep-it-focused rule

**Source:** the org `.github` repository, `CONTRIBUTING.md`, "Contributing via Pull
Requests". Retrieved 2026-09-22.

> Modify the source; please focus on the specific change you are contributing. If you also
> reformat all the code, it will be hard for us to focus on your change.

This is where the standard's `Also:` block comes from. A change that could not stay focused
stays reviewable by separating what is not the headline.

## Item 3: the reference description

**Source:** terraform-aws-modules/terraform-aws-s3-bucket, pull request 410. Written by the
maintainer. Retrieved 2026-09-22. Title `feat: Add Amazon S3 Files support`, 61 files
changed.

> Adds Amazon S3 Files support to the root module through a new `file_systems` map. Each
> file system can be scoped to a prefix and gets:
>
> - an IAM role scoped to its prefix, or your own via `iam_role_arn`
> - mount targets, on one shared security group by default or the file system's own
>   `security_groups`
> - access points, where `read_access_arns` / `read_write_access_arns` generate the allow
>   and deny statements AWS recommends
> - an optional file system policy and synchronization configuration
>
> File systems are not created on a directory bucket, which S3 Files does not support. New
> example: `examples/file-system`.
>
> Also:
> - README usage restructured: one log delivery snippet instead of three, and the feature
>   list split into capabilities and bucket types
> - `attach_elb_log_delivery_policy` and `attach_lb_log_delivery_policy` descriptions now
>   name the load balancers each one serves
> - Fixes an existing bug in `modules/table-bucket`, unrelated to S3 Files: a
>   `table_bucket_policy_statements` entry with `not_resources` also received the default
>   `resources`, and IAM rejects a statement with both
>
> ### Motivation and Context
> - Resolves "Proposal: add an Amazon S3 Files submodule when provider support is
>   available" #386
> - Closes "feat: Add Amazon S3 Files submodule" #388
>
> It lives in the root module so the file system is destroyed before bucket versioning is
> suspended, without callers adding `depends_on`.
>
> ### Breaking Changes
> None. The minimum AWS provider version moves from 6.42 to 6.44, which fixes deleting a
> synchronization configuration.
>
> ### Testing
> Against a live account: `examples/file-system` applied, re-planned with no changes and
> destroyed; a create, update, replace, bring-your-own and delete walk; a client mounting
> through an access point; and the upgrade test on `examples/complete` with `No changes`.

Every claim in it is falsifiable. It names the example by path, names the operations and
quotes their results, discloses the provider floor bump under Breaking Changes with its
reason even though the verdict is None, states in one sentence what the change deliberately
does not support and why, justifies the structural choice by naming the hazard it avoids,
references each issue as keyword plus quoted title plus number, and separates unrelated work
under a final `Also:` block.

The issue lines quoted above predate the rule in
[Closing keywords](pr-description.md#closing-keywords): the live body now writes them as
`<keyword> #<number>`, with the keyword directly before the number, and this item stays the
reference example for everything else.

Two divergences from the template, both of which the standard has to accept or the reference
becomes a finding: the Description content is an untitled lead paragraph with no
`## Description` heading, and the testing section is headed `### Testing` rather than
`## How Has This Been Tested?`.

## Item 4: the first contributor description

**Source:** terraform-aws-modules/terraform-aws-s3-bucket, pull request 393. Written by a
contributor. Retrieved 2026-09-22. Title `feat: Support S3 bucket ABAC`, 8 files changed.

It implements ABAC for general-purpose buckets via `aws_s3_bucket_abac`. Two issues are
named by bare number with a closing keyword and no title. Breaking Changes: `None`.

Testing, quoted in full:

> updated examples, tested with example projects, `pre-commit run -a`

## Item 5: the second contributor description

**Source:** terraform-aws-modules/terraform-aws-s3-bucket, pull request 406. Written by a
contributor. Retrieved 2026-09-22. Title
`feat(#405): Remove legacy ELB access log delivery policy from main.tf`, 2 files changed,
+1 -62.

It removes the legacy ELB access log delivery bucket policy statements, keeping only the
AWS-recommended service principal. Testing is the same shape as item 4: updated example
projects, verified the policy, plans succeed, legacy statements absent, logs still deliver,
`pre-commit run -a`, with no example path, no result quoted and no upgrade test.

Breaking Changes, quoted:

> No. The module interface remains unchanged

The maintainer contradicted that verdict in one line: it is a breaking change and will have
to be merged into the next breaking change.

## What was captured and what was not

Captured: the template, the contributing-guide sentence, one maintainer-written description
in full, and the two contributor descriptions summarised with their testing and breaking
change claims quoted verbatim, because those two claims are what the standard is derived
from.

Not captured: review threads, which belong to the reviewer skills and not to this standard;
any handle, URL, email address or account identifier.
