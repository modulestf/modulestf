# Deterministic facts engine for the module reviewer

Status: design, not implemented.

## Problem

The reviewer is a model following about 400 KB of instructions. It decides every rule itself, including rules that are a pure function of parsed Terraform: a variable with no type, a missing `versions.tf`, a removed output. The baseline small pull request costs USD 1.20. 55 percent of that is cache writes, mostly the instruction prefix, and most of the cache reads come from turns spent reading files and fetching schema facts. A large change projects about 185,000 tokens in one pass.

## Goal

- Cut the baseline pull request to USD 0.60 or less on the current lead model, and wall time by 40 percent.
- Keep findings quality: no missed `{rule_id, file, severity}` triple against the curated oracle, and no new HIGH or CRITICAL false positive.
- Keep the reviewer host neutral. It must still review a workspace and a task with no host and no tool output.
- Keep the security posture: pull request content is untrusted, the model runs no Terraform and no repository script, and no credential reaches the analysis.
- Run each model role on the cheapest model class that matches the lead on the fixtures, and no cheaper.
- Make the same engine and rule registry usable when writing modules, so the maintainer skill and the reviewer apply one set of deterministic checks.

## Decision summary

1. Add `mtf-facts`, an offline Go CLI in its own public repository, `modulestf/facts` (Apache-2.0). It parses head and merge-base trees with `hashicorp/hcl/v2` `hclsyntax`, reads provider schemas through `hashicorp/terraform-json`, and compares constraints with `hashicorp/go-version`.
2. Each rule gets exactly one owner: `tool`, `candidate` or `llm`. The tool decides `tool` rules. It detects `candidate` rules with evidence, and the model confirms or rejects each candidate. The model owns `llm` rules.
3. The model gets a compact facts bundle and a fixed, smaller judgment-only instruction set. With no valid bundle it runs today's full instruction set. Until the A/B meets the P2 exit, `MODULESTF_FACTS_VARIANT` stays `full` by default, so the full set runs even with a valid bundle (owner decision 3, 2026-10-22).
4. A host-side merge applies fixed authority, validation and dedup rules.
5. Model roles are split by class. Candidates are confirmed in a tool-less call on a small or mid class model where the rule allows it. A cheaper class may only confirm or escalate, and sets no severity on a multi-severity rule. The lead keeps judgment, escalations and the verdict. Every class starts at the lead's model and moves only after the fixture match. See [Model classes per role](#model-classes-per-role).
6. The same binary serves the maintainer skill: `lint` on a workspace, a coverage `ledger` check and a provider `schema-diff`. See [Use when writing modules](#use-when-writing-modules).

## Tool choice

| Option | Decision | Why |
|--------|----------|-----|
| `hashicorp/hcl/v2` `hclsyntax` | Parser | Gives full resource bodies, nested and `dynamic` blocks, `moved` and `removed` blocks, and expression source ranges. The coverage rules need these. |
| `hashicorp/terraform-json` | Schema types | Go types for `terraform providers schema -json`, which the existing schema job already produces from its mirror. |
| `hashicorp/go-version` | Constraints | Version floors and constraint comparison. |
| `hashicorp/terraform-config-inspect` | Test cross-check only | Reads the module interface but drops resource bodies. |
| `matt-FFFFFF/tfmoduleschema` | Not a runtime dependency | Wraps terraform-config-inspect, so it also has no bodies. It also fetches through go-getter and registries, which the offline sandbox forbids. Could be used later to read published module interfaces outside the review path. |
| `matt-FFFFFF/tfpluginschema` | Not a runtime dependency | Gets provider schemas by running provider plugins. Schema acquisition stays in the existing trusted schema job. |
| tflint plugin ruleset | Out of scope | Evaluates expressions, loads plugins and brings its own rule semantics that we would have to suppress. Revisit if `mtf-facts` needs expression evaluation. |
| Extending the bash and jq passes | Rejected | A parser with body walking, base and head comparison and a manifest does not fit in jq. |

## Rule registry

[rule-facts.md](../.agents/skills/terraform-module-reviewer/references/rule-facts.md) remains the single source. It gains these columns, filled by the P0 audit against each check file's **Fails when** and **Severity** blocks:

| Column | Values | Use |
|--------|--------|-----|
| `engine` | `tool`, `candidate`, `llm` | Fixed per `rule_id`. It never changes from run to run. |
| `class` | `config-semantic`, `path` | A path rule still runs when the configuration cannot be parsed. |
| `scope` | from the check file: touched block, touched expression, newly introduced, any file in area | Each rule keeps its own scope. Pre-existing defects are not subtracted across the board. |
| `cross_area` | `yes`, `no` | Whether the rule has a `.` manifest entry. |
| `area_kinds` | `root`, `submodule`, `example` | Defines `not_applicable`. |
| `bundle_sections` | bundle section names | The bundle sections a rule reads. Shedding one changes no status; see [Facts bundle](#facts-bundle). |
| `severities` | subset of the four levels | The host enforces it on every model-set severity. |
| `confirm_class` | `small`, `mid`, `lead` | Candidate rules only. Which model class confirms the candidate. Starts at `lead` for every rule; see [Model classes per role](#model-classes-per-role). |

`tests/skills-test.sh` checks the columns and needs no new toolchain. A Go test in `modulestf/facts` checks that `mtf-facts rules` lists exactly the `tool` and `candidate` ids, each with at least one positive and one negative golden case.

The operative text for `tool` and `candidate` rules moves to `references/engine/<check>.md`. The full variant loads it. The judgment variant loads only the short candidate-confirmation criteria.

## Initial classification

P0 confirms every row. A rule whose severity depends on the title, the body or a claim cannot be `tool`.

| Tier | Rules |
|------|-------|
| `tool` | `structure.missing-description`, `examples.versions-missing`, `profile.required-file-missing`, `profile.putin-khuylo-missing`, `profile.nonstandard-config-file` |
| `candidate` | `structure.variable-untyped`, `profile.region-not-allowed`, `compat.variable-removed`, `compat.variable-now-required`, `compat.default-changed`, `compat.type-narrowed`, `compat.resource-address-changed`, `compat.generated-policy-narrowed`, `compat.version-constraint-raised`, `compat.provider-floor-raised`, `coverage.unknown-argument`, `coverage.deprecated-argument`, `coverage.argument-above-min-version`, `coverage.required-argument-unreachable`, `coverage.block-attribute-mismatch`, `coverage.optional-argument-unexposed`, `coverage.attribute-not-output`, `structure.output-no-try`, `structure.arn-partition-hardcoded`, `structure.multi-provider`, `structure.wrong-file`, `structure.passthrough-default-drift`, `structure.passthrough-field-drift`, `structure.argument-order`, `structure.feature-above-version-floor`, `structure.version-floor-understated`, `examples.submodule-missing`, `examples.disabled-call-missing`, `examples.stale-reference`, `profile.template-drift`, `scope.provider`, `scope.module-call`, `scope.new-submodule`, `scope.tooling`, `scope.pre-commit-hook`, `scope.profile-file`, `scope.readme-banner` |
| `llm` | Every other rule, including `compat.break-unexplained`, `compat.claim-contradicts-analysis`, `structure.docs-contradict-code`, `structure.flag-polarity`, `structure.comment-*`, `structure.insecure-default`, `structure.validation-*`, `examples.feature-undemonstrated`, `examples.example-broken`, `profile.title-*`, `profile.commit-type-mismatch`, `scope.boundary`, `scope.composition`, `scope.new-module` and all `review.*` |

Rules that need careful handling:

- `compat.resource-address-changed`, `compat.type-narrowed` and `compat.default-changed` are candidates because of `count` to `for_each` changes, `moved` blocks with expression keys, `any`, `optional()` with defaults, and expressions that are equal but written differently.
- `profile.template-drift` is a candidate because its rule allows a stated reason, and the tool reads no prose.
- A new variable without a default counts under `compat.variable-now-required`: every existing caller now has to set it.
- `coverage.argument-above-min-version` returns `clean` when the argument exists in the declared-minimum schema. It returns a candidate when the argument is absent at the minimum and present at the latest. An argument absent at both is a `coverage.unknown-argument` candidate. If the introducing version cannot be read through the Rule 2 path, the candidate becomes `review.check-not-run`. The model never rejects it from memory.
- `structure.feature-above-version-floor` concerns Terraform core features, not provider schemas. It uses a pinned table of language features with their introducing versions. A feature the table does not list is a candidate, not `not_evaluated`: the confirmer reads its introducing version.
- `structure.version-floor-understated` compares caller and callee constraints. Disjoint sets keep the check file's CRITICAL. It does not depend on provider documentation.
- `compat.provider-floor-raised` with no schema is `not_evaluated(schema_unavailable)`.
- Every schema outcome this spec does not name is `not_evaluated`, never `clean`.
- A candidate rule is `clean` only when its detector is exhaustive for that area. A case the detector cannot decide becomes a candidate for the confirmer, never `clean` and never a new reason code. A rule is `not_evaluated` only for a reason in the manifest's closed list, and the model then evaluates the rule itself.

Promotion from candidate to tool requires human-adjudicated outcomes, at least 5 true positives and 5 hard negatives observed (`dynamic`, `count` to `for_each`, `moved`, `optional()`, `any`), and zero false positives and zero misses. One confirmed false positive demotes the rule.

## mtf-facts

### Placement in the workflow

```
gate -> schema -> verify job [ mtf-facts step, then verify pass ] -> triage / review
```

- `mtf-facts` runs as its own step in the verify job, before the verify pass. The verify job is the only non-plan job that holds the head, and it has no credentials.
- The step is allowlisted for `continue-on-error`. It has its own timeout and an outcome output. Its failure never changes verify results, verify outputs or the plan job's conditions.
- The schema dependency is soft. If the schema job failed or was skipped, `mtf-facts` does not run, the review uses the full variant, and verify still runs.
- The step runs under bubblewrap with `env -i` and a fixed `PATH`, and no token is in scope. If bubblewrap cannot start, the step is skipped and the run uses the full variant. The tool never runs unsandboxed.

### Inputs

- Pristine head and merge-base trees, extracted by the host from commit objects without honoring `.gitattributes`: `git ls-tree` plus `git cat-file` per blob, with entry counts and blob hashes verified. Plain `git archive` is not used because `export-ignore` and `export-subst` would change the bytes. The merge-base commit is fetched explicitly. Symlinks are recorded as entries and never materialized. The trees sit outside the verify run directory and are mounted read-only. The verify sandbox never sees them.
- The schema handoff from the schema job. For each directory and provider it holds the versions the host pass resolves: latest, declared minimum and old floor, or the unresolved reason. For each version it holds a filtered `providers schema -json`: block schemas only, meaning attribute names, required, optional and computed flags, deprecation, nested block names, nesting mode and item limits. It records the head and merge-base SHAs and the tree hashes of the `.tf` inputs it was derived from, a SHA-256 per file, and both a compressed and an uncompressed cap. `mtf-facts` filters to the types its own parse references. A referenced type the handoff does not cover, or covers for other SHAs or tree hashes, is `not_evaluated` with the outcome `present`, `absent_from_schema` or `schema_unavailable`.
- Profile data from the pinned skills checkout.

### Terraform semantics

- One module per directory: the root, each `modules/*` and each `examples/*`. Directories are never merged.
- The tool reads `*.tf`. In a directory with `*.tf.json`, `override.tf` or `*_override.tf`, config-semantic rules are `not_evaluated`, and path rules still run.
- Meta-arguments (`count`, `for_each`, `depends_on`, `provider`, `lifecycle`, `provisioner`, `connection`, `dynamic`) are kept apart from provider attributes. Providers are resolved by the `required_providers` local name and alias. A provider that cannot be resolved makes the schema rules on that block `not_evaluated`.
- A parse error makes the config-semantic rules of that area `not_evaluated`, never `clean`. A symlink, a special file or an unreadable file makes the rules that would read it `not_evaluated`, and path rules report it where it is their subject. Every path rule runs on a subject that is a symlink: the link counts as present and is never followed. An example whose `versions.tf` is a link therefore has no `examples.versions-missing` finding.

### Areas and the manifest

- The in-scope areas are the directories with a changed, added or removed file, plus `.` for cross-area rules. Paths under `.github/` and the root profile files count as the root. The root `.` is in scope for its own rules only when the change touches it; it is always in scope as the home of the cross-area entries. Area kinds come from the exact path patterns in [large-changes.md](../.agents/skills/terraform-module-reviewer/references/large-changes.md#classify-every-changed-path). An unknown or mixed directory is `not_evaluated`.
- An area absent at base has known-empty base facts. An area absent at head has known-empty head facts, so removals are still evaluated.
- The manifest has one entry per in-scope `(rule, area)`: `clean`, `finding`, `candidate`, `not_evaluated(reason)` or `not_applicable`. A missing entry for a `tool` or `candidate` rule is an integrity failure.
- A rule whose `cross_area` is `yes` has exactly one entry, under `.`, for the cross-area pass, and no per-area entry. The pass reads every area of the module, in scope or not. Its findings and candidates land only on lines in the change, and keep their own `file`. The engine enforces this line-level scoping through the change map. When any area it reads is unreadable or does not parse, the entry is `not_evaluated`, with no findings and no candidates.
- With no base, as in `lint` without `--base`, every area is in scope and every block counts as added. A rule that needs the base is `not_evaluated(no_base)`. The `scope.*` rules follow [check-f-scope.md](../.agents/skills/terraform-module-reviewer/references/check-f-scope.md#not-evaluated): with no base revision every one of them is `not_evaluated(no_base)` too.
- A subject is area-scoped: `<area>:<address>`, such as `.:var.retention_days` or `modules/worker:aws_sqs_queue.this.redrive.max_count`. The same address in two areas is two subjects. The address need not name an attribute: a `coverage.attribute-not-output` subject is a block, such as `.:aws_s3_bucket.this`, with one candidate per resource block for its computed attributes, or an output, such as `.:output.bucket_arn`, with one candidate per output that can fail in a mode the module supports. A path rule's subject is the file or directory path itself, with no area prefix; a directory is a valid subject.
- The manifest stays a host artifact and is never put in the prompt.

### Confinement and limits

Every read must be a regular file whose path is under its root. The tool never emits a resolved symlink target. It sets limits on file count, bytes per file, total bytes, HCL nesting depth, memory (sandbox cgroup), wall time and output size. Per-file panic recovery makes that file's area `not_evaluated`. Outputs are written outside the verify write set, hashed, and hashed again before the prompt is built.

### Output envelope and validity

The output binds the head SHA, the merge-base SHA, the binary digest, the rule-registry hash, the schema handoff hashes and `profile_sha256`. The host and the skill use one predicate: the head equals the workspace HEAD (a detached checkout of that SHA), the merge base equals the recorded one, the binary digest and registry hash equal the workflow pins, the schema hashes and SHAs match, and `profile_sha256` matches. If any check fails, the bundle is invalid and the run uses the full variant.

### Build and supply chain

- Repository: `modulestf/facts`, public, Apache-2.0. It holds the Go code, the golden fixtures and the releases. The rule registry stays in the skills.
- Registry pin: facts CI reads `rule-facts.md` from this repository at a pinned commit, with no token, and fails if `mtf-facts rules` does not match the registry's `tool` and `candidate` ids. The pin can lag master; that drift is accepted, and a registry change is followed by a pin bump in facts.
- Registry hash: SHA-256 of the `rule-facts.md` content only. Changes to rule prose in `references/engine/` do not need a new release. The workflow compares the hash in the envelope with the hash of `rule-facts.md` at its own pinned skills commit.
- Build: reproducible CI build with pinned Go, `-trimpath` and vendored modules. A release asset is built per tag, with a GitHub artifact attestation (`actions/attest-build-provenance`). The workflow template pins the version and SHA-256, and runs `gh attestation verify` on the asset before running it. To update, cut a new tag and a new pin, with the golden tests passing.

## Facts bundle

- The bundle and the merge are `mtf-facts` Go subcommands. They run in the review job under bubblewrap with `env -i` and no network.
- Host-built JSON, embedded as one JSON string value inside a fixed untrusted region. The byte-length header counts the region's payload bytes only, excluding the header line, and sits outside the region. Strings from the pull request are length-capped. Rule 3 applies to the bundle.
- Sections, in priority order:
  1. tool findings
  2. candidates with evidence
  3. per area, the rules that are not `clean` or `not_applicable`
  4. interface diff delta (variables, outputs, providers, resources, `moved` blocks and module calls, with base and head values; JSON schema defined in P0)
  5. schema coverage delta for changed blocks
  6. file index
- Cap of 48 KB, a starting value to be measured in P1. The cap measures the payload bytes the byte-length header counts, so the header line and the region markers are not counted. Sections are shed lowest priority first: file index, schema coverage, interface diff, then area rules. Sections 1 and 2 are never shed; if they alone are over the cap, the run uses the full variant.
- Shedding a section changes no manifest status. A `tool` or `candidate` rule keeps its outcome, because its findings and candidates carry their own evidence and its `clean` is the engine's exhaustive answer. An `llm` rule that reads a shed section is judged from the files, as it is in any case. The bundle adds no reason code; the manifest's closed list of reason codes is unchanged.
- The schema coverage section lists each `resource` and `data` block the change adds or edits, with the lookup outcome of its type at the latest version and the argument and nested block paths the change adds or removes, each with its state at the latest and declared minimum versions. A removed block is left out: the rules that read the section judge blocks the change adds or edits. An area whose revisions do not both parse in full is left out, as in the interface diff. The section is absent unless a schema handoff binds to the run's commits and trees, also in a run that reads raw schema files with `--schema-files`. When a handoff binds and the change adds or edits no such block, the section is an empty list. The four flag entries of `coverage.unknown-argument` (`max_items_exceeded`, `dynamic_count_unknown`, `block_syntax_for_attribute` and `computed_key`) are candidate evidence only and never appear in it.

## Judgment variant and not_evaluated

- The judgment variant is a fixed static prefix, the same bytes on every run, with a target of 90 KB or less. It holds the SKILL.md judgment edition, the `llm` check text, the candidate criteria, the merge contract and the output envelope. Per-PR content comes after it: the bundle, the diff and the task. Instructions are never pruned per pull request, because pruning would break the prompt cache.
- The prefix is one assembled file in `references/judgment/`, and the model reads it first.
- `MODULESTF_FACTS_VARIANT` defaults to `full`. Workflow tasks may merge. It switches to the judgment variant only after the A/B meets the P2 exit.
- Judgment mode runs only after the registry equality gate passes: every `tool` and `candidate` rule is implemented.
- For each `not_evaluated` `(rule, area)`, the host injects that rule's operative text, read from the pinned skills checkout, after the prefix. The model then evaluates the rule from the files. If that cannot finish, the result is `review.check-not-run`. A schema-unavailable injection carries its reason and forbids an invented schema.
- The hosted run gets the injection as a file, as it gets the bundle. `mtf-facts bundle --injection` writes it; the host checks that it is one regular file with one link within the budget and copies it read-only beside the bundle. Only when it is not empty does the task carry a third line, `Facts injection: <path>`, after `Facts variant: judgment` and `Facts bundle: <path>`; the repair turn carries the same lines. The model reads the file only from that task line, after the prefix. Its rule text binds as the prefix's check text does, for the bundle's `not_evaluated` rules and areas only, and the area names in it are data from the change. A bundle with injected text is no fallback: it runs the judgment variant. A missing line or file makes each `not_evaluated` rule `review.check-not-run`.
- Injection budget: 24 KB of injected rule text per run, a starting value. Over the budget, the whole run uses the full variant. Each run uses one mode.
- The full variant is today's text. It covers local use, other hosts and every fallback. Both variants are tested.

## Model output and merge

Model output envelope, validated by the host:

```json
{
  "candidate_decisions": [
    {"candidate_id": "...", "decision": "confirm|reject", "reason": "1-200 chars",
     "severity": "confirm only, within the rule's severities", "summary": "confirm only", "suggested_fix": "confirm only"}
  ],
  "findings": [],
  "counts": {"instruction-like-text-from-others": 0, "conversation-claims-unread": 0, "review.quoted-claim-unverifiable": 0}
}
```

- `counts` is optional and carries the three counts the full variant's summary line carries, which the host renders and cannot derive from the merged findings (owner decision 2026-10-23). When present it has exactly those three keys, each a natural number, 0 included; anything else makes the reply invalid. `schema/model-output.schema.json` in `modulestf/facts` holds the shape, and `mtf-facts merge counts` prints the counts of the reply the final merge reads, or null. The host reads them as it reads the summary line and never defaults a missing count to 0: a reply without `counts` renders no count line and one line in their place, `Counts: not reported by the review run.` (owner decision 2026-10-24).

- `findings` may use only `llm` rule ids, plus rules injected as `not_evaluated` for that finding's area. The host drops a finding with any other `rule_id`, and only that finding: the reply stays valid and no repair turn starts. A rejected candidate therefore cannot come back under its own rule.
- An entry from the confirmer's `severity_needed` list is answered in `candidate_decisions` with `decision: confirm` only, plus its severity and optional text. A `reject` there is invalid. An entry still unanswered or invalid after the repair turn is materialized by the host at the rule's highest permitted severity with template text, never as `review.check-not-run`. The final merge checks that each `severity_needed` id is materialized exactly once.
- Every candidate id must be answered exactly once, with no unknown ids. An invalid reply gets one repair turn. The repair reply replaces the first reply whole, findings included; nothing from the first reply is kept. If the repair reply is still invalid, the host keeps its valid entries: its valid findings and its valid answers. Only a candidate whose answer is invalid or missing becomes `review.check-not-run`, and only such a `severity_needed` entry gets the fallback above.
- A `review.check-not-run` for a candidate takes the candidate's `file` and `line`, and the subject `<candidate rule_id>@<area>:<address>`, the address being the candidate's own (a block or an output for `coverage.attribute-not-output`), or `<candidate rule_id>@<file>` for a path rule candidate, so two candidates of different rules on one address stay two findings under dedup step 1.
- The host materializes confirmed candidates. It takes `rule_id`, `file`, `line` and the subject from the candidate, and `severity`, `summary` and `suggested_fix` from the model.
- The host enforces each rule's `severities` on every model-set severity, on a confirmed candidate and on a lead finding alike. A severity above the highest permitted one is capped down to it; a severity below the lowest permitted one is raised to the lowest. Neither makes the reply invalid.
- The host assigns `source` from the channel each finding arrived on, and never reads it from model text. `tool`: a tool finding, a candidate the confirmer confirmed, and a `severity_needed` entry the lead answered. `llm`: a finding from the lead's `findings`, and a candidate the lead confirmed, which keeps its `candidate_id` and has `confirmed_by: lead`. `host`: a finding the host builds with no model answer, which is a `review.check-not-run` for a candidate and the `severity_needed` fallback.
- The merged findings follow `schema/merged-findings.schema.json` in `modulestf/facts`, which owns it.
- Tool findings are final. A model finding with the same `(rule_id, subject)` is dropped. The model may add `review.tool-disputed` (LOW, no effect on the verdict ladder) for a human.
- The lead's `findings` carry no subject. The host derives the subject of a lead finding from its `file` and `line` through the facts index: the address of the block or argument at that line, scoped to the area that holds the file. A path rule's subject is the `file` itself. The derived subject is used only to dedup: the merged finding does not carry it. A finding whose subject cannot be derived dedups only by `(rule_id, file, line)`.
- Dedup step 1 is exact `(rule_id, subject)`, where the subject is the full area-scoped address: an argument path or attribute name where the rule has one, a block address or an output for `coverage.attribute-not-output`. File-level subjects are used only for path rules. `llm` findings dedup by `(rule_id, file, line)`. When duplicates differ, the merged finding takes the highest severity, as SKILL.md's Final Step says, and the `summary` and `suggested_fix` of the duplicate that comes first in the Final Step sort order (severity, then `file`, then `line`); on a full tie, the first in arrival order: tool findings, then candidate answers, then the lead's `findings`. The owner did not decide the sort-order tie-break; it is the default. The arrival order on a full tie is decided.
- Step 2 is an explicit cross-rule overlap table, derived from the SKILL.md Final Step pairs: [Dedup overlap](../.agents/skills/terraform-module-reviewer/references/rule-facts.md#dedup-overlap) in rule-facts.md. The host merge applies overlap pair 1 only: it keeps `compat.default-changed` over `structure.flag-polarity` for the polarity pair. It does not apply pair 2: a `compat.*` break and a `profile.commit-type-mismatch` on that same break are both kept (owner decision 2026-10-22). Nothing else is deduplicated across rules. The `scope.*` and `profile.*` pairs that check-f-scope.md calls one defect stay unmerged.
- [findings-schema.md](../.agents/skills/terraform-module-reviewer/references/findings-schema.md), [verdict.md](../.agents/skills/terraform-module-pr-review/references/verdict.md) and [comment-format.md](../.agents/skills/terraform-module-pr-review/references/comment-format.md) gain `source` and the disputed note. The verdict ladder is unchanged.
- A host script renders the comment and the verdict from the merged findings.

## Model classes per role

Three classes: `small` (Haiku class), `mid` (Sonnet class) and `lead` (the Opus-class lead). A role or a rule moves to a cheaper class only under the maintainers' evaluation rule for moving a role. Until then every class variable is unset and resolves to the lead's model, so the split changes cost only after an owner sets it.

| Role | Judges | Default | Target | Notes |
|------|--------|---------|--------|-------|
| `mtf-facts` | nothing | no model | no model | Deterministic. |
| Triage | blocks or not | `MODULESTF_BEDROCK_TRIAGE_MODEL` | `small` | Exists today. The variable gets the same pattern check as the helper; today it is passed unchecked. |
| Schema page helper | nothing | `inherit` | `small` | Exists today. With schema facts from the tool it fetches only page facts. |
| Candidate confirmer | confirm or escalate, one candidate at a time | `lead` | `small` or `mid` per rule | New. Below. |
| Judgment lead | `llm` rules, escalated candidates, merge text, verdict | `lead` | `mid` after evaluation | The P3 evaluation of the judgment variant. |

### Candidate confirmer

- A `confirm` step runs in the review job, after the bundle has passed the validity predicate and before the model step, only when the bundle has candidates whose `confirm_class` is not `lead`. It uses the review job's Bedrock role and holds no other credential. There is no separate job and no extra artifact.
- It makes one Bedrock Converse call per candidate, with no agent harness and no tools, a forced output schema and bounded concurrency. Every call of a class shares that class's static prefix, so the prefix is cached once. Candidates are sorted by candidate id, and a per-step cap limits the number of calls; candidates over the cap escalate. The cap starts at 10 calls per review, a value to be measured in P1. Only calls made count: a candidate that gets no call, because its class is `lead` or its evidence is not complete, does not count toward it. One call per candidate means an injection in one candidate's evidence cannot decide another's.
- The static prefix per class is the confirmation criteria of every rule in that class, taken from the pinned registry, so it is the same bytes on every run.
- The confirmer reads no files. Each candidate carries its evidence (source lines, base and head values, the schema facts it relied on) and an `evidence_complete` flag set by `mtf-facts`. Caps apply only where `mtf-facts` writes pull request strings, and set `evidence_complete` to false when they bite. The host never slices evidence or a bundle: a candidate whose evidence is not complete escalates without a call. The evidence sits in the fixed untrusted region of [Facts bundle](#facts-bundle).
- The output schema is exactly `{"decision": "confirm" | "escalate"}` for the one candidate id the host sent. Every other field is host-owned. A cheaper class can add a finding but can never hide one, set a severity or write text:
  - A rule whose `severities` has one value: `confirm` makes it a finding at that severity.
  - A rule with several severities: `confirm` marks the defect as real, and the lead sets its severity within `severities`. The lead may rewrite the text in its own output envelope, merged like any `llm` finding text, but cannot reject it. Lead text never enters the bundle. A compat break's severity, for example, depends on whether the break is declared, which only the lead sees.
  - A rule whose `severities` include CRITICAL is never `small`.
  - `summary` and `suggested_fix` come from fixed per-rule host templates filled with the candidate's subject. The host bounds the template text so that a confirmed entry is never larger, in payload bytes, than the candidate it replaces.
- Any other output, a timeout, or a failed step leaves the candidate unchanged in the candidates section, and the lead answers it as in [Model output and merge](#model-output-and-merge). The job does not fail, and this step never forces the full variant.
- The host then rebuilds the bundle: confirmed single-severity candidates move to tool findings with `source: tool` and `confirmed_by: <class>`, and confirmed multi-severity candidates move to a `severity_needed` list with the same `confirmed_by`. The tag is host-owned and survives dedup. `confirmed_by` is a single value: when dedup merges findings with different tags, the cheapest confirmer wins, `small` over `mid` over `lead`, so a strike reaches the cheapest class that confirmed the defect. It checks that every candidate id appears exactly once across candidates, tool findings and `severity_needed`. It checks the cap, measured as in [Facts bundle](#facts-bundle), and hashes the bundle again before the prompt is built. If the rebuilt bundle fails the cap or any check, the confirmations revert to candidates. With bounded templates the rebuild cannot outgrow the bundle it replaces; the revert stays as a safeguard.
- Residual risk: an injection in the evidence can make a cheaper class confirm a false positive. It cannot suppress a finding, and on a multi-severity rule it cannot set the severity.
- A strike is a false positive from a `confirmed_by` finding that a human adjudicates, including an upheld `review.tool-disputed`. One strike moves the rule back to `lead`. Strikes and moves are recorded in the maintainers' evaluation results.
- Models come from repository variables `MODULESTF_BEDROCK_CONFIRM_SMALL_MODEL` and `MODULESTF_BEDROCK_CONFIRM_MID_MODEL`, checked like the helper's: a full model name, an inference profile id or an ARN, never a family alias. Unset means the lead's model. The Bedrock role must allow each one.
- `tests/skills-test.sh` checks that `confirm_class` appears only on `candidate` rules and that no rule whose `severities` include CRITICAL is `small`.
- The job summary records, per rule and class, the confirmed and escalated counts. In P3 a maintainer reviews these summaries offline: a rule that escalates more than half its candidates over 20 runs moves back to `lead`, because the call then costs more than it saves. Nothing moves a class at runtime.
- P0 proposes a target class per candidate rule. Likely `small`: `structure.argument-order`, `structure.wrong-file`, `structure.output-no-try`, `structure.arn-partition-hardcoded`, `examples.stale-reference`, `scope.readme-banner`, `scope.pre-commit-hook`, if their `severities` allow it. Likely `mid`: the `compat.*` and `coverage.*` candidates. The rest stay `lead`.
- A rule moves to a cheaper class only after its own match on the fixtures and the promotion corpus, recorded in the maintainers' evaluation results.

## Use when writing modules

The maintainer skill makes the same decisions in the other direction: Rule 4's coverage ledger, the Targeted change backwards-compatibility check, and the Provider upgrade schema diff. The engine already computes the facts for all three, so it also ships three local commands. They run offline on a workspace the user trusts, use the same rule registry and binary, and never fetch.

| Command | Input | Output | Maintainer step |
|---------|-------|--------|-----------------|
| `mtf-facts lint <dir> [--base <dir>] [--schema-files <file>]...` | The workspace; optionally the tree the change started from; optional schema files | Tool findings and candidates in the findings schema, plus the manifest | Quality gate in all modes. With `--base`, the `compat.*` candidates feed Targeted change Step 4. |
| `mtf-facts ledger <dir> --schema-files <file> [--check <ledger>]` | The workspace and the schema | A field inventory per resource and data source type the module uses: name, type, required, optional, computed, deprecated, sensitive, nesting mode. With `--check`, every field has exactly one disposition, and every exposed input and output exists in the code. | Full create Steps 2, 3 and 8 |
| `mtf-facts schema-diff --from <file> --to <file> --types-from <dir>` | Two provider schemas | One row per change, for the types the module uses. On an argument, attribute or block: `added`, `removed`, `deprecated`, `newly_required`, `type_changed`, `no_longer_settable`, `nesting_changed`, `sensitive_changed` or `write_only_changed`. On a type: `added`, `removed`, `deprecated`, or `absent` when neither file has it though both have its provider. No row for a changed default: that is a page fact | Provider upgrade Step 2 |

- The schema file is `terraform providers schema -json`, produced by the user in a trusted workspace. Without one, the schema rules are `not_evaluated`, and the maintainer follows Rule 1 through the MCP tools as it does today. Page facts such as introducing versions stay on the MCP path.
- `ledger --check` reads a new JSON ledger file with its own schema.
- The author chooses each ledger disposition and answers each candidate in its report. The tool checks only that the ledger is complete. The reviewer still decides independently.
- `lint` and the reviewer's facts step are one code path. A parity test runs both on every fixture and requires identical tool findings and candidates.
- `lint` labels candidates as unconfirmed and never reports them as findings. Every command's output records the binary version, the registry hash and the schema file hashes, so a local result can be compared with the review's.
- The maintainer skill must still work without the binary. Each step names the command as optional and keeps its current manual checklist as the fallback, reported as skipped under Rule 3.
- Profile parameters (required files, allowed regions, argument order, template paths) are read from fenced constants blocks in the existing profile files, the way `terraform-docs-pass.sh` reads its profile constants. The rule logic in Go stays generic. Per AGENTS.md, no profile format or loader is designed until a second profile exists.
- No Terraform code generation in v1. A skeleton generator would encode the profile's code conventions in Go and duplicate the templates. Revisit only if ledger runs show that typing variables from the inventory is where the author's turns go.
- Model classes apply here too: the tool replaces the reading turns, and the author's model choice is the user's.
- The reviewer's Rule 1 bullet for `mtf-facts` was approved.

## Staging and incremental review

- No check-run writes from the facts step. Its results are posted only with the final review.
- Triage keeps its meaning.
- The judgment pass stays on the Opus-class lead until the maintainers' cost evaluation shows a Sonnet-class model matching on the judgment variant. Confirmer classes follow [Model classes per role](#model-classes-per-role).
- Incremental review: the tool reruns every time. Candidates are always answered again; there is no reuse in v1. `llm` findings carry only under the existing carry column.

## Failure contract

Any of these sends the run to the full variant, with a metric and a job summary line and no finding:

- `mtf-facts` crash, timeout or OOM
- schema job failure or skip
- an integrity failure
- the validity predicate is false
- the injection budget is exceeded (injected text within the budget is passed to the judgment run, never a fallback)
- bubblewrap is unavailable

Metrics are split into engine and integrity failures versus designed fallbacks. The denominator is runs that reach the verify job. Only engine and integrity failures above 5 percent over 20 runs pause promotion work.

## Tests and oracles

- Synthetic fixtures only, in `modulestf/facts` under `testdata/`, with generic names. P0 wrote them in this repository, and they moved at P1 to `testdata/oracle/`, where the facts Go tests check them against the schemas, the registry and their own trees. Each fixture carries a human-curated expected manifest and findings. Adversarial cases include `.gitattributes` `export-ignore` and `export-subst`, symlinks, deep nesting, `.tf.json` and override files.
- Go unit tests per rule, covering positive, negative and edge cases (`dynamic`, `count` to `for_each`, `moved`, `optional()`, `any`).
- Merge fixtures for authority, validation and dedup, written in this repository during P0 and now in `modulestf/facts` under `testdata/merge/`.
- A real pull request corpus for promotion evidence, kept outside the published tree.
- Model reference runs measure parity only, with the match rule of the maintainers' evaluation plan. They are never the oracle.

## Acceptance criteria

Measured with paired runs on the baseline pull request and the fixtures, using the four token classes from the usage line. The A/B budget is approved: the baseline pull request plus the fixture pull requests, both variants, two repeats each. The cost estimate is reported before the runs start.

- Baseline pull request USD 0.60 or less on the current lead model.
- Wall time down 40 percent.
- Zero missed triples against the curated oracle, and no new HIGH or CRITICAL false positive.
- `mtf-facts` under 10 seconds and under 512 MB on a 2,500-line change.
- Shedding and injection sizes measured on small, medium and large changes.
- Engine and integrity failure rate under 5 percent.
- No decision below `lead` is a `reject`, sets a severity or adds text, and every class move has its recorded match.
- `lint` and the facts step give identical tool findings and candidates on every fixture. `ledger --check` fails on a fixture with one unmapped field, and `schema-diff` matches a hand-made expected diff.

Expected levers, largest first: a smaller static prefix (cache writes); fewer turns, because the bundle replaces reading files and fetching schema (cache reads); schema facts from the tool, with the fetch helper only for page facts; candidates confirmed on small and mid class models in a tool-less call; a cheaper judgment model after evaluation; incremental reruns.

## Phases

| Phase | Scope | Exit |
|-------|-------|------|
| P0 | Rule audit (all registry columns), synthetic oracles, merge fixtures, handoff and interface-diff JSON schemas, core-feature table. Docs and fixtures only. | Every rule classified, and the audit reviewed by a second agent |
| P1 | `mtf-facts` step, pristine extraction, manifest, envelope, `tool` tier, schema handoff. Shadow mode: output logged, not merged. `lint` ships for local use on the same code path. | Golden tests green; runtime and memory targets met; failure rate measured |
| P2 | Candidates, output envelope, merge, judgment variant. A/B test against the full variant. | Acceptance criteria met on the baseline PR and the fixtures |
| P3 | Candidate promotions; `confirm` step; per-rule `confirm_class` moves; Sonnet-class evaluation of the judgment pass; checked triage model variable. | Per-rule promotion gate; match rule per rule and class |
| P4 | Incremental reuse with a dependency contract; large-change split threshold tuned again with the new projected context. | Cost and time measured again |
| P5 | `ledger` and `schema-diff`; profile constants blocks; maintainer skill steps name the commands with their fallbacks. Can start after P1, independent of P2 to P4. | Parity and maintainer acceptance criteria met; maintainer skill change reviewed by a second agent |

Leftover P1 items move to P2.

## Out of scope

- Module writing, and modules for any service and any provider.
- Terraform code generation from the ledger.
- Routing triage or the lead through a direct model call instead of the agent harness.
- Non-AWS profiles.
- A tflint ruleset.

## Design record

This design comes from an arbiter-mediated consensus run with four external reviewers over 5 rounds, on 2026-10-19. The run ended UNRESOLVED at the round cap. Every issue raised in the last round was accepted and is folded into this spec. The two dismissed claims were factually wrong: the schema job does render from the provider schema JSON, and the gate reads `.tf` text through the API without checking out the head. [Model classes per role](#model-classes-per-role) and [Use when writing modules](#use-when-writing-modules) were added on 2026-10-20 and went through a separate 3-round consensus on 2026-10-20 with the same reviewers. It ended at the user's 3-round limit with every round-3 issue folded in. That run made the confirmer an enum-only step in the review job: a cheaper class can confirm or escalate, but never reject, set a severity or write text.

On 2026-10-21 the owner answered the merge questions the P0 merge fixtures raised and the open points of the oracle fixtures' review. The answers are folded into [Terraform semantics](#terraform-semantics), [Areas and the manifest](#areas-and-the-manifest), [Facts bundle](#facts-bundle), [Model output and merge](#model-output-and-merge) and [Candidate confirmer](#candidate-confirmer). The owner did not decide two points, which stand as defaults: the text tie-break between duplicates by the Final Step sort order, and the derivation of the step 2 overlap table from the SKILL.md pairs, which goes to a second-agent review. The owner did decide the overlap table's added `profile.commit-type-mismatch` row and that the Check F `scope.*` and `profile.*` pairs stay unmerged. Later that day the owner settled two more points, folded into [Areas and the manifest](#areas-and-the-manifest) and [Model output and merge](#model-output-and-merge): a lead finding's derived subject serves only to dedup and is not carried by the merged finding, and a cross-area pass reads every area of the module, in scope or not, while its findings land only on lines in the change.

On 2026-10-22 the owner decided twelve points for the P2 and P5 plan. Each is folded into its section:

1. A host script renders the comment and the verdict from the merged findings: [Model output and merge](#model-output-and-merge).
2. The judgment prefix is one assembled file in `references/judgment/`, read first: [Judgment variant and not_evaluated](#judgment-variant-and-not_evaluated).
3. `MODULESTF_FACTS_VARIANT` defaults to `full`, workflow tasks may merge, and the switch to the judgment variant comes only after the A/B meets the P2 exit: [Judgment variant and not_evaluated](#judgment-variant-and-not_evaluated).
4. The bundle and the merge are Go subcommands run in the review job under bubblewrap with `env -i` and no network: [Facts bundle](#facts-bundle).
5. Judgment mode runs only after the registry equality gate, with every `tool` and `candidate` rule implemented: [Judgment variant and not_evaluated](#judgment-variant-and-not_evaluated).
6. The engine enforces line-level scoping of cross-area findings through the change map: [Areas and the manifest](#areas-and-the-manifest).
7. `compat.provider-floor-raised` with no schema is `not_evaluated(schema_unavailable)`: [Initial classification](#initial-classification).
8. `profile_sha256` is bound into the envelope and the validity predicate: [Output envelope and validity](#output-envelope-and-validity).
9. The A/B budget is approved: baseline plus fixture pull requests, both variants, two repeats, with the cost estimate reported before starting: [Acceptance criteria](#acceptance-criteria).
10. `ledger --check` reads a new JSON ledger file with its own schema: [Use when writing modules](#use-when-writing-modules).
11. The reviewer's Rule 1 bullet for `mtf-facts` was approved: [Use when writing modules](#use-when-writing-modules).
12. Leftover P1 items move to P2: [Phases](#phases).
