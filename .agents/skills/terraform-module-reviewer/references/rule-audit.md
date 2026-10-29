# Rule Registry Audit

> **Part of:** [terraform-module-reviewer](../SKILL.md)
> **Purpose:** How the registry columns of [rule-facts.md](rule-facts.md) were filled, which values differ from the initial classification in [the facts engine spec](../../../../docs/facts-engine-design.md#initial-classification), and which rules left a value open. The table is the registry; this file is its record and changes nothing in it.

Every value comes from the rule's own **Fails when** and **Severity** text in its check file: [Check A](check-a-compatibility.md), [Check B](check-b-coverage.md), [Check C](check-c-structure.md), [Check D](check-d-examples.md), [Check E](check-e-profile.md) and [Check F](check-f-scope.md). The `review.*` rules come from [SKILL.md](../SKILL.md) Inputs and Rules 3 and 4, and from [quoted-claims.md](quoted-claims.md). Cross-area ownership comes from [Cross-Area Pass](large-changes.md#cross-area-pass) and, for Check F, from its own placement note.

## Conventions

- **`engine`.** The spec's tier is kept unless the check text gives a reason against it. A rule whose severity depends on the title, the body or a claim is never `tool`. A rule whose **Fails when** accepts a stated reason, a comment or prose is never `tool`, because the engine reads no prose; this is the reason the spec gives for `profile.template-drift`.
- **`class`.** `path` when the rule judges file names, file presence, or the content of a non-HCL file (workflow, `.pre-commit-config.yaml`, `CHANGELOG.md`, `README.md` prose, the title), so it can still run when the `.tf` files do not parse. Everything that reads blocks, expressions or comments of a `.tf` file is `config-semantic`.
- **`scope`.** "added by the change", "the change adds", "a new variable" and "introduced by the change" give `newly-introduced`. "adds or edits", "the diff adds or modifies", "the change touches" and every Check A comparison of base and head give `touched-block`, or `touched-expression` when the subject is one value: a default, a literal, a constraint, a function call. A rule that reads a whole example directory or the whole change, whether the change touched the file or not, is `any-file-in-area`. The title, body and `review.*` rules take `any-file-in-area`, the nearest of the four values for a subject that is no file. An argument the change adds inside a block is one value the change sets: `touched-expression`, with the rule dropping a defect the base already had.
- **`cross_area`.** `yes` for every rule the cross-area pass owns under its three tests, for `scope.provider` and `scope.new-module` (Check F places both there), and for the `review.*` rules whose finding carries `file` `.`.
- **`area_kinds`.** Check A, B and C rules judge module code and take `root, submodule`, with `example` added only where the check text names examples. Check D rules take `example`, except the three that ask whether a module feature or submodule is demonstrated, which anchor at the module. Profile files, workflows, `CHANGELOG.md` and the title take `root`.
- **`bundle_sections`.** A `tool` rule names `tool-findings` and a `candidate` rule `candidates`, both never shed. Beyond that a rule names `interface-diff` when it reads variables, outputs, providers, resources, `moved` blocks or module calls at base and head, `schema-coverage` when it reads provider schema facts for changed blocks, and `file-index` when it reads which paths exist. Only `review.check-not-run` names `area-rules`. A rule that reads only comments, literals or prose names `none` beyond its own channel.
- **`severities`.** Every level the **Severity** block can give the rule, including a band named only by example. Where the block names no `rule_id` for a level, the level goes to the rule whose **Fails when** bullet it restates.
- **`proposed_confirm_class`.** `small` only for a single-severity or low-stakes rule whose candidate is decided by syntax the evidence carries in full; never on a rule whose `severities` include CRITICAL. `mid` for the `compat.*` and `coverage.*` candidates, as the spec expects. `lead` where confirming needs a stated reason, a documentation citation, a list judgement or a severity band read from documentation.

## Changes from the initial classification

Two rows change tier, which leaves 5 `tool` rules. Every other rule keeps the spec's tier, including every rule the spec groups by pattern under `llm`.

| `rule_id` | Spec | Audit | Reason |
|-----------|------|-------|--------|
| `structure.variable-untyped` | `tool` | `candidate` | The rule also fires on `any` "without a stated reason", and its fix accepts "a comment with the reason instead"; whether a comment states a reason is prose the engine does not read. |
| `profile.region-not-allowed` | `tool` | `candidate` | Check E's suggested fix (a) keeps the literal with a comment giving the reason, which a tool that reads no comments would keep reporting at HIGH. |

Confirm-class proposals that the spec's likely lists do not name:

| `rule_id` | Proposed | Reason |
|-----------|----------|--------|
| `structure.multi-provider` | `small` | Pure syntax (an aliased `provider` block, a `provider =` or `providers =` argument, outside `examples/`), one severity, MEDIUM. |
| `structure.variable-untyped` | `lead` | Its `any` case needs a stated reason, which the convention above sends to the lead. |
| `coverage.optional-argument-unexposed` | `lead` | The spec's `coverage.*` group would make it `mid`, but it accepts an omission documented in a comment or the directory's `README.md`, a stated reason the convention sends to the lead. |
| `profile.region-not-allowed` | `lead` | Confirming needs the reason a comment gives for keeping the literal. |
| `compat.provider-floor-raised` | `mid` | The spec's `compat.*` group. It has one severity, LOW, so `small` is open to it later; it stays `mid` because its `summary` must say whether the change uses anything absent at the old floor, which rests on schema evidence. |
| `examples.disabled-call-missing`, `examples.submodule-missing`, `profile.template-drift`, `scope.module-call`, `scope.new-submodule`, `scope.profile-file`, `scope.provider`, `scope.tooling`, `structure.feature-above-version-floor`, `structure.passthrough-default-drift`, `structure.passthrough-field-drift`, `structure.version-floor-understated` | `lead` | The spec's "the rest stay `lead`". `structure.feature-above-version-floor` also needs a documentation quote and date in its `summary`, and `structure.version-floor-understated` can be CRITICAL. |

Every rule on the spec's likely `small` list kept `small`: none of `structure.argument-order` (LOW), `structure.wrong-file` (MEDIUM), `structure.output-no-try`, `structure.arn-partition-hardcoded`, `examples.stale-reference`, `scope.readme-banner` and `scope.pre-commit-hook` (all HIGH) has CRITICAL among its severities.

For two of them the spec's list takes precedence over the convention. `structure.arn-partition-hardcoded` is silent when a comment names the partitions the literal is right for, with its source and date, and `structure.wrong-file` rests on the archetype's file for a group of blocks. Both stay `small`, and the confirmer escalates to the lead whenever the evidence shows a comment next to the ARN, or a directory whose archetype is not one of the standard ones.

Three rows change `scope` after the facts engine review found them:

| `rule_id` | Audit | Now | Reason |
|-----------|-------|-----|--------|
| `coverage.deprecated-argument` | `newly-introduced` | `touched-expression` | An argument the change adds inside an existing block is a value the change sets, not a block the change adds. The rule itself drops a defect the base already had, as Check B [Which blocks](check-b-coverage.md#which-blocks) states. |
| `coverage.argument-above-min-version` | `newly-introduced` | `touched-expression` | The same reading: the argument is a value set in a block the change may only edit, and Which blocks drops a defect the base already had. |
| `scope.provider` | `newly-introduced` | `touched-expression` | A provider entry the change adds to an existing `required_providers` is a value the change sets, not a block the change adds. The rule itself drops a provider the base already had, as [Providers](../../terraform-module-maintainer/references/module-scope.md#providers) defines base providers. |

## Rows added after the audit

- `review.tool-disputed`: the spec's [Model output and merge](../../../../docs/facts-engine-design.md#model-output-and-merge) adds it, and [findings-schema.md](findings-schema.md#optional-fields) defines it. It comes from no check file, so the values follow the spec and the conventions above: `llm`, since only the model reports it; LOW, as the spec sets; `path`, so a dispute of a path rule's tool finding still runs when the configuration does not parse; `any-file-in-area`, as for the other `review.*` rules; `cross_area` `no`, since it takes the `file` of the tool finding it disputes; every area kind, since the tool rules span all three; `tool-findings`, the only section it reads.

## Severities that needed a reading

- `compat.variable-removed`, `compat.variable-now-required`, `compat.type-narrowed`, `compat.resource-address-changed`, `compat.version-constraint-raised`, `compat.generated-policy-narrowed`: CRITICAL undeclared, HIGH declared with no migration path. Check A gives the declared break with a migration path no level, so it is not a finding of these rules.
- `compat.default-changed` adds MEDIUM: the Check A band "a default whose effect is cosmetic".
- `coverage.attribute-not-output`: HIGH for an output wrong in a supported mode, MEDIUM for a computed attribute with no output.
- `structure.input-ignored-in-branch`: CRITICAL, HIGH and MEDIUM, all three named in its Check C bullet.
- `structure.passthrough-default-drift`: HIGH, MEDIUM and LOW; its CRITICAL case is reported as `structure.insecure-default`, so CRITICAL is not in its set.
- `structure.passthrough-field-drift`: HIGH and MEDIUM.
- `structure.insecure-default`: CRITICAL, the only level Check C gives a weakened secure default.
- `examples.stale-reference`: HIGH. The Check D block names no level for it; an example that "can no longer initialize" is broken by the change before apply, the HIGH bullet.
- `profile.layout-divergence`: MEDIUM for a `LICENSE` that is not Apache 2.0 ("at the severity of a missing required file") and LOW when cosmetic.
- `profile.commit-type-mismatch`: MEDIUM for a type that releases the change wrongly, LOW for `feat` on a fix only.
- `profile.template-drift`: MEDIUM, and LOW when the divergence is cosmetic.
- `review.quoted-claim-unverifiable`: `none`. An unconfirmed claim "produces no finding" and is only counted in the summary line, so the registry name never carries a severity.

## Open values

These rules left a value open. Each value in the table is the reading above; a reviewer of the audit may decide otherwise.

- `structure.sibling-block-asymmetry`: Check C's **Severity** block names no level for it. The table allows HIGH (the nearest band, "a nested input does not match the schema shape") and MEDIUM (the band of an optional argument left unexposed), so the host does not cap a severity the check might mean.
- Check C's MEDIUM for "missing tag propagation" and its **Fails when** bullet on tags have no `rule_id` in the registry. No row takes them; a finding of that kind is minted under [findings-schema.md](findings-schema.md).
- Check D's bullet on invented input names has no `rule_id` of its own. It is left with the per-example rules, without a row change.
- Check C does not say whether its rules run in example areas. `area_kinds` adds `example` only where a rule names examples: `structure.docs-contradict-code` ("an example comment") and `structure.version-floor-understated` ("an example against the module it calls"). `structure.multi-provider` excludes examples in its own text.
- `examples.example-broken-at-base` is `cross_area` `no`: the cross-area pass names `examples.example-broken` for untouched examples, not its base variant.
- `examples.feature-undemonstrated`, `examples.argument-undemonstrated` and `examples.submodule-missing` take the module's area kinds, because the cross-area pass anchors where the rule's text puts the finding and otherwise at the caller, and these rules judge a module feature.
- `profile.region-not-allowed` fires only "where the literal chooses a region", which includes "an example's locals". Its detector has to decide which locals choose a region from syntax; the confirmer settles the rest.
- `profile.nonstandard-config-file` is `path` for its file-name cases, which must run when the files do not parse. Its OpenTofu-only block case needs the parse and the `required_version` constraint; under a parse failure only that case is `not_evaluated`.
- `profile.putin-khuylo-missing` names a creation input only when it is a variable called `create` or `create_<x>` that a local reads together with the gate, where the gate is `var.putin_khuylo` or a local that reads it at any depth, and it takes those locals from the base and the head together. So `length(var.subnets)` is never a creation input, and a change that drops the gate from a `create_<x>` local still names that input. A path is gated only when the gate, or a local gated the same way, is an operand of the `&&` chain that decides creation, or the condition of a conditional whose false branch creates nothing (`0`, `null`, `[]`, `{}`, or `toset`, `tolist` or `tomap` of one of those), or the whole of a branch that is itself gated this way while the other branch creates nothing, or a `for` filter condition gated this way. A gate under `||` or `!`, in a conditional branch, or only in a function argument does not gate.
- `profile.provider-meta-missing`, `profile.changelog-handwritten`, `scope.tests` and `review.path-missing` read as mechanical but stay `llm`, as the spec has them. They are the next rules to consider for `candidate`; `review.path-missing` reads its paths from the task text, which the engine does not see.
- Every `compat.*` candidate is open to Check A's Reverts exemption, which needs read-only `git` queries a tool-less confirmer cannot make. The proposals stay `mid` on the condition that candidate evidence carries the revert facts, or that a change with a revert line escalates to the lead.
