# Run Summary: Check G

> **Part of:** [terraform-module-reviewer](../../SKILL.md), [Check G](../check-g-behaviour.md)
> **Purpose:** The index a run reads for Check G, as [Reading by Depth](../../SKILL.md#reading-by-depth) says: each `rule_id`, when it applies, the provider facts it needs as [rule-facts.md](../rule-facts.md) gives them, and the sections that hold its text. It holds no rule text; the sections are operative.

When unsure whether a row's **Applies when** holds, it holds.

With `G-ladder` out of scope in `depth.json`, only the claim reading [Reading by Depth](../../SKILL.md#reading-by-depth) describes runs, and no row below and no section of [verification-ladder.md](../verification-ladder.md) is read.

## Read First

When any row below applies: [Reads, Fails When and Severity](../check-g-behaviour.md#reads-fails-when-and-severity).

## Rules

| `rule_id` | Applies when | Provider facts | Sections |
|-----------|--------------|----------------|----------|
| `claim.fix-not-effective` | The verification record has a `claim` line. | none | [Check G](../check-g-behaviour.md#reads-fails-when-and-severity) |
| `claim.refuted` | The verification record has a `claim` line. | none | [Check G](../check-g-behaviour.md#reads-fails-when-and-severity) |
| `compat.expression-behaviour-changed` | The change edits an expression in a resource, data, module, local, variable, output or provider block, or a file an HCL read site names, or the record has a `trigger` or `change` line. | none | [Check G](../check-g-behaviour.md#reads-fails-when-and-severity) |
| `review.verification-incomplete` | The verification record has a `behaviour:` line. | none | [Check G](../check-g-behaviour.md#reads-fails-when-and-severity) |

## Other Sections

| Section | Open when |
|---------|-----------|
| [Explaining the Differences](../check-g-behaviour.md#explaining-the-differences) | A `trigger` line ends with `complete` or carries `outstanding`. |
| [Worked Example: A List of Subnet Ids](../check-g-behaviour.md#worked-example-a-list-of-subnet-ids) | The change edits a list or set of identifiers. |
| [Suggested Fixes](../check-g-behaviour.md#suggested-fixes) | Check G reports a finding. |
| [Triggers](../verification-ladder.md#triggers) | The record has a `behaviour:` or `trigger` line. |
| [Levels](../verification-ladder.md#levels) | The record has a `trigger` or `claim` line. |
| [The Claims File](../verification-ladder.md#the-claims-file) | The record has a `claim` line. |
| [Ladder Record Observations](../verification-ladder.md#ladder-record-observations) | The record has a `change` line. |
| [States](../verification-ladder.md#states) | The record has a `trigger` or `claim` line. |
| [Evidence to Verdict](../verification-ladder.md#evidence-to-verdict) | The record has a `trigger` or `claim` line. |
