# Rule to Provider Fact

> **Part of:** [terraform-module-reviewer](../SKILL.md)
> **Purpose:** For every `rule_id`, which provider facts it needs and whether a type read from [host fact sheets](large-changes.md#budget) also needs its page. Step 1 reads this table to fix the need list. It is static: a rule's need never depends on what a sheet or a page says.

Columns:

- **Provider facts:** `none`, the rule reads no provider schema; `schema`, it needs facts a host fact sheet carries (names, required, optional and computed flags, deprecation, block names, nesting modes, item limits, exported attributes), and a page serves too; `page`, it needs a page fact.
- **Page facts:** the facts only the page has that the rule may need: allowed values, conflicts, validator limits, documented defaults and omissions, data source behaviour, prose-only notes and import.
- **Page entry when:** for a type read from host fact sheets, the condition, taken from the need list, under which the type also takes a page entry at the latest version for this rule. `-` means never.
- **Carry:** whether a finding of this rule may be carried unchanged from an earlier review of the same change, as [Incremental task lines](findings-schema.md#incremental-task-lines) describes. `file` only when the audit below shows the rule's evidence is the target file's own bytes, at the base and the head, and nothing else: no other file, no provider fact, no title or body, no verification result, no example, no documentation, no generated content, and no scope, compatibility or `review.*` judgement. Every other rule is `never`, and so is a rule added without an audit.

The registry columns are for the deterministic facts engine designed in [the facts engine spec](../../../../docs/facts-engine-design.md#rule-registry). Nothing in this skill reads them yet. Each value was derived from the rule's **Fails when** and **Severity** text in its check file; [rule-audit.md](rule-audit.md) records the conventions, every value changed from the spec's initial classification and the rules whose text left a value open. A list is comma separated.

- **`engine`:** `tool`, the engine decides the rule; `candidate`, the engine detects with evidence and a model confirms; `llm`, the model owns the rule.
- **`class`:** `path`, the rule still runs when the configuration cannot be parsed; `config-semantic`, it needs the parse.
- **`scope`:** what the rule judges, from its check file: `touched-block`, a block, or for a non-HCL file the unit the rule compares, that the change adds, edits or removes; `touched-expression`, a value or literal the change sets; `newly-introduced`, only what the change adds; `any-file-in-area`, anything in the area, whether the change touched it or not.
- **`cross_area`:** `yes` when the rule has a `.` manifest entry because the [cross-area pass](large-changes.md#cross-area-pass) owns it, or its finding can carry `file` `.`; otherwise `no`.
- **`area_kinds`:** the area kinds where the rule can fire, from `root`, `submodule` and `example`; anywhere else it is `not_applicable`. Files under `tests/`, `.github/` and the root profile-owned files count as `root`.
- **`bundle_sections`:** the facts bundle sections the rule relies on, or `none`. The names stand for the spec's [Facts bundle](../../../../docs/facts-engine-design.md#facts-bundle) list in order: `tool-findings`, `candidates`, `area-rules`, `interface-diff`, `schema-coverage`, `file-index`. The names say which sections a rule reads; shedding one changes no status (see the spec's Facts bundle).
- **`severities`:** the severities the check file allows the rule, or `none` for a registry name that is never emitted as a finding.
- **`confirm_class`:** on a `candidate` rule, the model class that confirms its candidates: `small`, `mid` or `lead`. Every rule is `lead` until it passes its own evaluation. `-` on every other rule.
- **`proposed_confirm_class`:** the target class this audit proposes for a `candidate` rule, `-` on every other rule. It takes effect only when a rule passes its evaluation and `confirm_class` is changed to match.

`tests/skills-test.sh` checks that every `rule_id` the skill names has exactly one row here, and no other row, that each row's carry value is `file` or `never`, and that every `file` row has one line in [Carry audit](#carry-audit) and no other rule does. It also checks the registry columns: each value from its column's list, `confirm_class` and `proposed_confirm_class` set on `candidate` rules and only there, `confirm_class` `lead` on every `candidate` rule, and `small` in neither column on a rule whose `severities` include CRITICAL.

| `rule_id` | Provider facts | Page facts | Page entry when | Carry | `engine` | `class` | `scope` | `cross_area` | `area_kinds` | `bundle_sections` | `severities` | `confirm_class` | `proposed_confirm_class` |
|-----------|----------------|------------|-----------------|-------|----------|---------|---------|--------------|--------------|-------------------|--------------|-----------------|--------------------------|
| `claim.fix-not-effective` | none | - | - | never | llm | config-semantic | touched-expression | no | root, submodule | none | HIGH | - | - |
| `claim.refuted` | none | - | - | never | llm | config-semantic | touched-expression | yes | root, submodule | none | HIGH | - | - |
| `compat.break-unexplained` | none | - | - | never | llm | config-semantic | any-file-in-area | yes | root | tool-findings, candidates, interface-diff | MEDIUM | - | - |
| `compat.claim-contradicts-analysis` | none | - | - | never | llm | config-semantic | any-file-in-area | yes | root | tool-findings, candidates, interface-diff | HIGH, MEDIUM, LOW | - | - |
| `compat.default-changed` | none | - | - | never | candidate | config-semantic | touched-expression | no | root, submodule | candidates, interface-diff | CRITICAL, HIGH, MEDIUM | lead | mid |
| `compat.expression-behaviour-changed` | none | - | - | never | llm | config-semantic | touched-expression | no | root, submodule | interface-diff | CRITICAL, HIGH, LOW | - | - |
| `compat.generated-policy-narrowed` | none | - | - | never | candidate | config-semantic | touched-block | no | root, submodule | candidates | CRITICAL, HIGH | lead | mid |
| `compat.provider-floor-raised` | schema | - | - | never | candidate | config-semantic | touched-expression | no | root, submodule | candidates, interface-diff, schema-coverage | LOW | lead | mid |
| `compat.resource-address-changed` | none | - | - | never | candidate | config-semantic | touched-block | yes | root, submodule | candidates, interface-diff | CRITICAL, HIGH | lead | mid |
| `compat.type-narrowed` | none | - | - | never | candidate | config-semantic | touched-block | no | root, submodule | candidates, interface-diff | CRITICAL, HIGH | lead | mid |
| `compat.variable-now-required` | none | - | - | never | candidate | config-semantic | touched-block | no | root, submodule | candidates, interface-diff | CRITICAL, HIGH | lead | mid |
| `compat.variable-removed` | none | - | - | never | candidate | config-semantic | touched-block | no | root, submodule | candidates, interface-diff | CRITICAL, HIGH | lead | mid |
| `compat.version-constraint-raised` | none | - | - | never | candidate | config-semantic | touched-expression | no | root, submodule | candidates, interface-diff | CRITICAL, HIGH | lead | mid |
| `coverage.argument-above-min-version` | schema | - | - | never | candidate | config-semantic | touched-expression | no | root, submodule | candidates, schema-coverage | HIGH | lead | mid |
| `coverage.attribute-not-output` | schema | prose-only notes: an attribute set on one branch only | The change adds or edits an output that reads an attribute of the type. | never | candidate | config-semantic | touched-block | no | root, submodule | candidates, schema-coverage, interface-diff | HIGH, MEDIUM | lead | mid |
| `coverage.block-attribute-mismatch` | schema | - | - | never | candidate | config-semantic | touched-block | no | root, submodule | candidates, schema-coverage | CRITICAL | lead | mid |
| `coverage.default-for-required-argument` | page | documented defaults | The change adds or changes a default of an input that backs an argument of the type. | never | llm | config-semantic | touched-expression | no | root, submodule | schema-coverage, interface-diff | HIGH | - | - |
| `coverage.deprecated-argument` | schema | - | - | never | candidate | config-semantic | touched-expression | no | root, submodule | candidates, schema-coverage | HIGH | lead | mid |
| `coverage.enum-value-unknown` | page | allowed values | The change sets a literal on an argument of the type, in the module or an example. | never | llm | config-semantic | touched-expression | no | root, submodule, example | schema-coverage | LOW | - | - |
| `coverage.mutual-exclusion-unguarded` | page | conflicts | The change adds or edits a block of the type. | never | llm | config-semantic | touched-block | no | root, submodule | schema-coverage | HIGH | - | - |
| `coverage.optional-argument-unexposed` | schema | documented omissions | The change adds a `resource` block of the type. | never | candidate | config-semantic | newly-introduced | no | root, submodule | candidates, schema-coverage, interface-diff | MEDIUM | lead | lead |
| `coverage.required-argument-unreachable` | schema | - | - | never | candidate | config-semantic | touched-block | no | root, submodule | candidates, schema-coverage, interface-diff | HIGH | lead | mid |
| `coverage.unknown-argument` | schema | validator limits | The change adds or edits a block of the type that repeats a nested block. | never | candidate | config-semantic | touched-block | no | root, submodule | candidates, schema-coverage | CRITICAL | lead | mid |
| `examples.argument-undemonstrated` | none | - | - | never | llm | config-semantic | newly-introduced | yes | root, submodule | interface-diff | LOW | - | - |
| `examples.custom-input-required` | none | - | - | never | llm | config-semantic | any-file-in-area | yes | example | interface-diff | HIGH | - | - |
| `examples.disabled-call-missing` | none | - | - | never | candidate | config-semantic | any-file-in-area | no | example | candidates | MEDIUM | lead | lead |
| `examples.docs-incomplete` | none | - | - | never | llm | path | any-file-in-area | no | example | file-index | LOW | - | - |
| `examples.example-broken` | schema | allowed values, one-ofs | An example the change adds or edits, or one of the version bump only examples, has a block of the type. | never | llm | config-semantic | any-file-in-area | yes | example | schema-coverage, interface-diff | HIGH | - | - |
| `examples.example-broken-at-base` | none | - | - | never | llm | config-semantic | any-file-in-area | no | example | none | LOW | - | - |
| `examples.feature-undemonstrated` | none | - | - | never | llm | config-semantic | newly-introduced | yes | root, submodule | interface-diff | MEDIUM | - | - |
| `examples.real-domain-zone` | none | - | - | never | llm | config-semantic | touched-expression | no | example | none | LOW | - | - |
| `examples.stale-reference` | none | - | - | never | candidate | config-semantic | any-file-in-area | yes | example | candidates, interface-diff | HIGH | lead | small |
| `examples.submodule-missing` | none | - | - | never | candidate | path | newly-introduced | yes | submodule | candidates, file-index | HIGH | lead | lead |
| `examples.versions-missing` | none | - | - | never | tool | path | any-file-in-area | no | example | tool-findings, file-index | MEDIUM | - | - |
| `profile.changelog-handwritten` | none | - | - | never | llm | path | touched-block | no | root | file-index | HIGH | - | - |
| `profile.commit-type-mismatch` | none | - | - | never | llm | config-semantic | any-file-in-area | yes | root | tool-findings, candidates, interface-diff | MEDIUM, LOW | - | - |
| `profile.generated-content-handwritten` | none | - | - | never | llm | config-semantic | touched-block | no | root, submodule, example | interface-diff | HIGH | - | - |
| `profile.layout-divergence` | none | - | - | never | llm | path | newly-introduced | no | root, submodule, example | file-index | MEDIUM, LOW | - | - |
| `profile.migration-notes-misplaced` | none | - | - | never | llm | path | touched-block | no | root | file-index | MEDIUM | - | - |
| `profile.nonstandard-config-file` | none | - | - | never | tool | path | touched-block | no | root, submodule, example | tool-findings, file-index | HIGH | - | - |
| `profile.owner-identifier` | none | - | - | never | llm | config-semantic | any-file-in-area | no | root, submodule, example | none | MEDIUM | - | - |
| `profile.provider-meta-missing` | none | - | - | never | llm | config-semantic | touched-block | no | root, submodule | none | MEDIUM | - | - |
| `profile.putin-khuylo-missing` | none | - | - | never | tool | config-semantic | touched-block | no | root | tool-findings | MEDIUM | - | - |
| `profile.region-not-allowed` | none | - | - | file | candidate | config-semantic | touched-expression | no | root, submodule, example | candidates | HIGH | lead | lead |
| `profile.release-config-changed` | none | - | - | never | llm | path | touched-block | no | root | file-index | HIGH | - | - |
| `profile.required-file-missing` | none | - | - | never | tool | path | newly-introduced | no | root, submodule, example | tool-findings, file-index | MEDIUM | - | - |
| `profile.template-drift` | none | - | - | never | candidate | path | touched-block | no | root | candidates, file-index | MEDIUM, LOW | lead | lead |
| `profile.title-misspelling` | none | - | - | never | llm | path | any-file-in-area | yes | root | none | MEDIUM | - | - |
| `profile.title-uninformative` | none | - | - | never | llm | path | any-file-in-area | yes | root | none | MEDIUM | - | - |
| `profile.unrelated-change-bundled` | none | - | - | never | llm | config-semantic | touched-block | yes | root, submodule | interface-diff | LOW | - | - |
| `review.check-not-run` | none | - | - | never | llm | path | any-file-in-area | yes | root, submodule, example | area-rules | MEDIUM | - | - |
| `review.no-change-identified` | none | - | - | never | llm | path | any-file-in-area | yes | root | none | MEDIUM | - | - |
| `review.path-missing` | none | - | - | never | llm | path | any-file-in-area | yes | root | file-index | MEDIUM | - | - |
| `review.quoted-claim-unverifiable` | none | - | - | never | llm | config-semantic | any-file-in-area | yes | root | none | none | - | - |
| `review.tool-disputed` | none | - | - | never | llm | path | any-file-in-area | no | root, submodule, example | tool-findings | LOW | - | - |
| `review.untrusted-instruction` | none | - | - | never | llm | path | any-file-in-area | yes | root, submodule, example | none | HIGH | - | - |
| `review.verification-incomplete` | none | - | - | never | llm | path | any-file-in-area | yes | root | none | MEDIUM | - | - |
| `scope.boundary` | none | - | - | never | llm | config-semantic | newly-introduced | no | root, submodule | interface-diff | HIGH | - | - |
| `scope.composition` | none | - | - | never | llm | config-semantic | newly-introduced | no | root, submodule | interface-diff | MEDIUM | - | - |
| `scope.layout` | none | - | - | never | llm | path | newly-introduced | no | root, submodule | file-index | HIGH | - | - |
| `scope.module-call` | none | - | - | never | candidate | config-semantic | touched-block | no | root, submodule | candidates, interface-diff | HIGH | lead | lead |
| `scope.new-module` | none | - | - | never | llm | config-semantic | newly-introduced | yes | root | interface-diff | MEDIUM | - | - |
| `scope.new-submodule` | none | - | - | never | candidate | config-semantic | newly-introduced | no | submodule | candidates, interface-diff | MEDIUM | lead | lead |
| `scope.pre-commit-hook` | none | - | - | never | candidate | path | touched-block | no | root | candidates, file-index | HIGH | lead | small |
| `scope.profile-file` | none | - | - | never | candidate | path | touched-block | no | root | candidates, file-index | HIGH | lead | lead |
| `scope.provider` | none | - | - | never | candidate | config-semantic | touched-expression | yes | root, submodule | candidates, interface-diff | HIGH | lead | lead |
| `scope.readme-banner` | none | - | - | never | candidate | path | touched-block | no | root | candidates, file-index | HIGH | lead | small |
| `scope.tests` | none | - | - | never | llm | path | newly-introduced | no | root, submodule, example | file-index | HIGH | - | - |
| `scope.tooling` | none | - | - | never | candidate | path | newly-introduced | no | root, submodule, example | candidates, file-index | HIGH | lead | lead |
| `structure.argument-order` | none | - | - | file | candidate | config-semantic | touched-block | no | root, submodule | candidates | LOW | lead | small |
| `structure.arn-partition-hardcoded` | none | - | - | file | candidate | config-semantic | newly-introduced | no | root, submodule | candidates | HIGH | lead | small |
| `structure.comment-redundant` | none | - | - | file | llm | config-semantic | newly-introduced | no | root, submodule | none | MEDIUM | - | - |
| `structure.comment-unsourced` | none | - | - | file | llm | config-semantic | newly-introduced | no | root, submodule | none | MEDIUM | - | - |
| `structure.copied-content-unattributed` | none | - | - | never | llm | config-semantic | newly-introduced | no | root, submodule | none | MEDIUM | - | - |
| `structure.create-flag-ignored` | none | - | - | never | llm | config-semantic | newly-introduced | no | root, submodule | interface-diff | HIGH | - | - |
| `structure.docs-contradict-code` | page | data source behaviour | A changed block, output, local or documentation line depends on what a data source of the type does with its inputs. | never | llm | config-semantic | touched-block | no | root, submodule, example | interface-diff | HIGH | - | - |
| `structure.feature-above-version-floor` | none | - | - | never | candidate | config-semantic | touched-expression | no | root, submodule | candidates | HIGH | lead | lead |
| `structure.flag-polarity` | none | - | - | file | llm | config-semantic | newly-introduced | no | root, submodule | interface-diff | MEDIUM | - | - |
| `structure.grouping` | none | - | - | never | llm | config-semantic | touched-block | no | root, submodule | none | LOW | - | - |
| `structure.input-ignored-in-branch` | none | - | - | never | llm | config-semantic | touched-block | yes | root, submodule | interface-diff | CRITICAL, HIGH, MEDIUM | - | - |
| `structure.insecure-default` | none | - | - | never | llm | config-semantic | touched-expression | no | root, submodule | interface-diff | CRITICAL | - | - |
| `structure.missing-description` | none | - | - | file | tool | config-semantic | newly-introduced | no | root, submodule | tool-findings | MEDIUM | - | - |
| `structure.multi-provider` | none | - | - | file | candidate | config-semantic | newly-introduced | no | root, submodule | candidates | MEDIUM | lead | small |
| `structure.output-no-try` | none | - | - | never | candidate | config-semantic | newly-introduced | no | root, submodule | candidates, interface-diff | HIGH | lead | small |
| `structure.passthrough-default-drift` | none | - | - | never | candidate | config-semantic | touched-block | yes | root, submodule | candidates, interface-diff | HIGH, MEDIUM, LOW | lead | lead |
| `structure.passthrough-field-drift` | none | - | - | never | candidate | config-semantic | touched-block | yes | root, submodule | candidates, interface-diff | HIGH, MEDIUM | lead | lead |
| `structure.schema-shape-flattened` | schema | - | - | never | llm | config-semantic | touched-block | no | root, submodule | schema-coverage, interface-diff | HIGH | - | - |
| `structure.sibling-argument-omitted` | schema | - | - | never | llm | config-semantic | newly-introduced | no | root, submodule | schema-coverage | HIGH | - | - |
| `structure.sibling-block-asymmetry` | schema | - | - | never | llm | config-semantic | newly-introduced | no | root, submodule | schema-coverage | HIGH, MEDIUM | - | - |
| `structure.suppression-unexplained` | none | - | - | file | llm | config-semantic | newly-introduced | no | root, submodule | none | MEDIUM | - | - |
| `structure.validation-message-uninformative` | none | - | - | never | llm | config-semantic | newly-introduced | no | root, submodule | none | LOW | - | - |
| `structure.validation-missing` | none | - | - | never | llm | config-semantic | touched-block | no | root, submodule | interface-diff | MEDIUM | - | - |
| `structure.validation-overreaching` | none | - | - | never | llm | config-semantic | newly-introduced | no | root, submodule | none | MEDIUM | - | - |
| `structure.variable-untyped` | none | - | - | file | candidate | config-semantic | newly-introduced | no | root, submodule | candidates, interface-diff | MEDIUM | lead | lead |
| `structure.version-floor-understated` | none | - | - | never | candidate | config-semantic | touched-block | yes | root, submodule, example | candidates, interface-diff | CRITICAL, MEDIUM | lead | lead |
| `structure.wrong-file` | none | - | - | never | candidate | config-semantic | newly-introduced | no | root, submodule | candidates, file-index | MEDIUM | lead | small |

## Dedup Overlap

Step 2 of the merge in [the facts engine spec](../../../../docs/facts-engine-design.md#model-output-and-merge) deduplicates across rules only by this table. Pair 1 is derived from the pair the [Final Step](../SKILL.md#final-step-assemble-the-findings) names; pair 2 and the unmerged list below are the owner's decisions of 2026-10-21. Nothing in this skill reads the table yet. A row applies only when its "Same defect when" condition holds. The kept finding takes the higher severity of the two, and keeps its own text.

| Pair | Kept | Dropped | Same defect when | From |
|------|------|---------|------------------|------|
| 1 | `compat.default-changed` | `structure.flag-polarity` | Both are about one new `enable_*` or `attach_*` input that defaults to `true`, on the same subject: Check A's behaviour change for every existing caller and Check C's polarity defect. | Final Step, the polarity pair |
| 2 | The `compat.*` finding for the break | `profile.commit-type-mismatch` | The title's type or its missing `!` misreports that same break, the case [Check E](check-e-profile.md) gives for a breaking change released under a title with no `!` and no `BREAKING CHANGE:` trailer. | Final Step, the code over the description; owner decision |

The host merge does not apply pair 2: it keeps both findings. This is the owner's decision of 2026-10-22. The row stays in the table.

Not deduplicated, so both findings are kept:

- A `compat.*` code finding and `compat.claim-contradicts-analysis` about the claim it refutes: the Final Step carve-out, and [quoted-claims.md](quoted-claims.md#compatclaim-contradicts-analysis) says both are emitted, the description finding one band below the code finding.
- A break in the code and `compat.break-unexplained` about that break: Check A says it never replaces the finding for the break.
- A `scope.*` file rule and a `profile.*` rule on the same path for the same edit. [Check F](check-f-scope.md) calls them one defect and lists its pairs as examples, "not a closed list". The owner decided they stay unmerged in step 2, so both are kept.

The Final Step's general clause, "where two rules describe the same break, the rule naming the code wins over the rule naming the author's description", is the source of pair 2. Check A carves out its two rules that judge the description of the break, `compat.claim-contradicts-analysis` and `compat.break-unexplained`. `profile.commit-type-mismatch` judges the title, not Check A's description rules, so the clause still covers it.

## Carry Audit

The evidence each `file` rule reads, all of it in the target file:

- `profile.region-not-allowed`: A region literal the change touches in the target, against the two the profile allows.
- `structure.argument-order`: `count`, `for_each`, `tags` and `labels` positions inside a resource block of the target, and whether the change touched that block, read from the target at the base and the head.
- `structure.arn-partition-hardcoded`: An ARN literal the change adds in the target; `local.partition` can always be added, so no other file decides it.
- `structure.comment-redundant`: A comment the change adds in the target, read against the code beside it in the same file.
- `structure.comment-unsourced`: A comment the change adds in the target and whether it carries a source link and a date.
- `structure.flag-polarity`: A new flag variable's name and default, both in its own block of the target.
- `structure.missing-description`: A new variable or output block of the target without a `description`.
- `structure.multi-provider`: A `provider` block with an `alias`, or a `provider` or `providers` argument, in the target, and whether the target's path is under `examples/`.
- `structure.suppression-unexplained`: A suppression comment the change adds in the target, and the comment lines next to it.
- `structure.variable-untyped`: A new variable block of the target without a `type`, or with `any` and no comment giving the reason.
