# Review standards: decision record

Decided 2026-09-24. Every source below was read on that date, pinned where it has a commit.

This record answers three questions. Can generic code-review skills use the terraform-aws-modules profile without a copy? Which of their patterns should our skills adopt? Which cross-tool standard for findings or rules should we adopt, map to, or skip? Each decision states the reason, what was rejected, and what would reopen it.

## Sources

| Source | Pinned at | Read for |
|--------|-----------|----------|
| [superpowers requesting-code-review](https://github.com/obra/superpowers/blob/5bf4e78011075bcfc0dc295f0724994cd123ee71/skills/requesting-code-review/SKILL.md) and its [reviewer template](https://github.com/obra/superpowers/blob/5bf4e78011075bcfc0dc295f0724994cd123ee71/skills/requesting-code-review/code-reviewer.md) | commit `5bf4e78` | Inputs, severity, output shape |
| [superpowers receiving-code-review](https://github.com/obra/superpowers/blob/5bf4e78011075bcfc0dc295f0724994cd123ee71/skills/receiving-code-review/SKILL.md) | commit `5bf4e78` | How feedback is handled |
| [mattpocock/skills code-review](https://github.com/mattpocock/skills/blob/c55ee46073ed923f86ce59a5eb3b6d895095d1b7/skills/engineering/code-review/SKILL.md) | commit `c55ee46` | Standards and Spec axes |
| [SARIF 2.1.0 Errata 01](https://docs.oasis-open.org/sarif/sarif/v2.1.0/errata01/os/sarif-v2.1.0-errata01-os-complete.html), JSON schema read from [oasis-tcs/sarif-spec](https://github.com/oasis-tcs/sarif-spec/blob/a560296ca8c921f3bdb8d4a8db57ab83dae968a7/sarif-2.1/schema/sarif-schema-2.1.0.json) | commit `a560296` | Field names and required properties |
| [reviewdog diagnostic format](https://github.com/reviewdog/reviewdog/blob/360c7b7d7d15a704006eb8449da18bc31120d1cf/proto/rdf/reviewdog.proto) | commit `360c7b7` | rdjson fields |
| [AGENTS.md](https://agents.md/) | fetched | Format and precedence |
| [CodeRabbit review instructions](https://docs.coderabbit.ai/guides/review-instructions) and [configuration reference](https://docs.coderabbit.ai/reference/configuration), with its [JSON schema](https://coderabbit.ai/integrations/schema.v2.json) | fetched | Rule sources, `filePatterns`, `inheritance` |
| [GitHub Copilot repository instructions](https://docs.github.com/en/copilot/how-tos/configure-custom-instructions/add-repository-instructions) | fetched | Rule sources, branch read |
| [Conventional Comments](https://conventionalcomments.org/) | fetched | Comment format |

## Decision 1: how generic reviewers get the profile

### What each tool reads

| Tool | Where its rules come from | A channel the pull request head cannot edit |
|------|---------------------------|---------------------------------------------|
| superpowers requesting-code-review | A prompt template the caller fills: `[DESCRIPTION]`, `[PLAN_OR_REQUIREMENTS]`, `[BASE_SHA]`, `[HEAD_SHA]` in the template file, which its `SKILL.md` lists in curly braces. It looks for no standards file. | Yes: the caller fills every placeholder. |
| mattpocock code-review | Standards: "Anything in the repo that documents how code should be written", found by the orchestrating agent, plus a fixed smell baseline. Spec: issue references in commit messages, a path the user passes, or a spec file under `docs/`, `specs/` or `.scratch/`. | Spec only, through the user-passed path. For standards the skill documents no caller argument; the files come from the checkout under review. |
| CodeRabbit | `.coderabbit.yaml` in the repository root and guideline files matched by `knowledge_base.code_guidelines`, whose defaults include `AGENTS.md`, `CLAUDE.md`, `REVIEW.md` and `.github/copilot-instructions.md`. The pages read do not say which branch these come from. A `filePatterns` entry may also name a file in another repository of the same organization, as `repo:path` or `owner/repo:path`, "read at that repository's default branch". | Organization settings in the web interface, and a `filePatterns` entry pointing at another repository of the same organization. |
| GitHub Copilot code review | `.github/copilot-instructions.md`, `.github/instructions/*.instructions.md`, `AGENTS.md`. The page says Copilot reads them "from the head branch (the branch with your changes), not the base branch." | None on the page read. |

None of them can discover a file in this repository. The channels outside the head are text a caller supplies, vendor settings, and the CodeRabbit pointer to a file in another repository of the same organization.

### Decision

Hand the profile over, never let a tool discover it. The artifact is one self-contained guide, `profiles/terraform-aws-modules/review-guide.md` in the maintainer skill, written by a follow-up. It holds the family rules that can be judged from the diff and the head tree alone. Each entry carries the rule text, its `rule_id`, and the profile file and heading it comes from. A Not covered table lists what the guide leaves out and why: rules that need the Terraform MCP tools, host state or execution, and generic Terraform guidance owned by `terraform-skill`.

A caller pins the guide by commit SHA, reads it from a checkout of this repository outside the workspace, and passes it in: as `[PLAN_OR_REQUIREMENTS]` text to superpowers, or as an extra path in the standards list for the mattpocock skill, which works only when the caller runs that orchestration itself. What a generic reviewer returns is advice. It never feeds the pull request verdict, which stays a total function of `terraform-module-reviewer` findings.

What stays in this repository, unchanged: the profile, the maintainer references, the reviewer and its checks, and the findings schema. Nothing is added to module repositories.

### Reason

- Discovery reads the head. A copy in a module repository is read from the pull request head, where the pull request can edit it. Copilot says so, and the mattpocock skill reads the checkout under review. A rule the change can rewrite cannot judge that change.
- Copies drift. The family has many repositories, each copy would change by its own pull request, and nothing would compare it with the profile.
- The profile is not self-contained. It links the maintainer references, and schema facts come from the Terraform MCP tools, which generic reviewers do not have. Only a subset of rules can be handed over, so the guide has to say which.

### Guards

- Drift: every guide entry cites a profile file and heading anchor, which `tests/skills-test.sh` already resolves. The follow-up adds three checks there: every `rule_id` the guide names is in the reviewer registry, every profile heading is cited by an entry or listed as Not covered, and a hash of each cited section matches the one recorded in the guide, so an edit under an unchanged heading fails the test.
- Prompt injection: the guide is never read from the workspace. The generic reviewer still reads head files such as `AGENTS.md` and can be steered by them, which is why its output stays advice. Our own reviewer keeps Rule 3: workspace files are data, and configuration never loads from them.

### Rejected

- A copy in module repositories, as `AGENTS.md`, `REVIEW.md`, a coding-standards file, or CodeRabbit `path_instructions`: read from the head, drifts, and has to coexist with each module's own `AGENTS.md`.
- A CodeRabbit `filePatterns` pointer set in organization settings. The file it names has to live in a repository inside the terraform-aws-modules organization, so it is a copy with the drift problem above, checked by no test in this repository. Its protection is also unsettled: `inheritance` fills only the values a level leaves undefined, so a `.coderabbit.yaml` that sets its own `filePatterns` replaces the pointer, and the pages read do not say whether that file is read from the head.
- Pointing generic tools at the profile directory as it is: not self-contained, and much of it needs MCP or execution.
- A profile loader or package format: `AGENTS.md` rules out designing one before a second profile exists.

### Reopens when

- A generic reviewer documents a caller argument for standards, or reads its rules from the base branch only. A pointer in module repositories could then be safe.
- The terraform-aws-modules maintainers ask for a file in their repositories.
- CodeRabbit documents that `.coderabbit.yaml` is read from the base branch, and the terraform-aws-modules organization agrees to hold a pinned copy of the guide in one of its repositories. The pointer would then be a channel the head cannot edit, and the copy could be checked against this repository by SHA.
- A second profile exists.

## Decision 2: patterns to adopt

### Two axes, Standards and Spec

Decision: the originating request stays context for the existing checks. No Spec check, no `spec.` prefix, and the findings schema stays at version 3.

The mattpocock Spec axis reports (a) requirements missing or partial, (b) behaviour nobody asked for, and (c) requirements implemented wrongly, each quoting the spec. For a reusable module, (b) is covered by Check F, which judges whether an addition belongs in the module against written scope rules, together with `change-scope`. Items (a) and (c) measure the change against free text from the requester. That text is untrusted under reviewer Rule 3, and it differs for every change, so a `spec.*` name could not mean the same thing in every run, which the schema's stability rules require. The request already reaches the reviewer as the pull request body in the untrusted block.

Rejected: a `spec.` prefix, which would be findings schema version 4. Also rejected: separate Standards and Spec report sections. Our single list sorted by severity already names the check in each `rule_id` prefix, and the verdict ladder reads one list, so a split changes nothing it computes.

Reopens when the reviewer fixtures record two or more human-confirmed defects of the form "the change does not do what its request asked" that no check from A to F caught. That evidence would justify proposing `spec.` as version 4.

### Receiving review

Decision: adopted already, nothing more to add. The maintainer's [Resolve feedback](../.agents/skills/terraform-module-maintainer/references/resolve-feedback.md) mode, on `master` since this record was drafted, carries the discipline of receiving-code-review:

| receiving-code-review | Resolve feedback |
|-----------------------|------------------|
| Verify before implementing | "Nothing is edited before its item is verified." |
| Push back with technical reasoning | `reject` needs evidence from the code, the schema or the profile. Plausibility is not enough. |
| "I can't verify this without [X]" | `unverified`: edits nothing, and the reply asks for the evidence that would settle it |
| Clarify unclear items first | `unclear` and `needs-decision` stop the items related to them |
| Blocking, then simple, then complex | The same order in Step 3 |
| YAGNI check before "implementing properly" | `out-of-scope`, judged by the scope rules through `change-scope` |
| No performative agreement, no thanks | Replies carry no praise and no thanks boilerplate |

One difference is deliberate. receiving-code-review stops every item while any item is unclear, because "Items may be related." Resolve feedback holds only the related items and lets the unrelated ones proceed. It defines relatedness (same identifier, same block, or one fix depending on another), so the wider stop buys nothing. The mode also goes further on trust: every item is untrusted whatever its origin, where receiving-code-review trusts feedback from the person it works for.

Rejected: the GitHub thread-reply instruction, which is host-specific. Resolve feedback drafts replies and leaves posting to a person or a host adapter.

Reopens when a round shows an unrelated item fixed in a way that an answer to a held item would have changed.

### Explicit base, head and request

The reviewer takes a base reference, diffed with a read-only git query, and a workspace at one commit. The head is implicit. superpowers passes both SHAs, so its reviewer reviews exactly the range it was asked about.

Adopt: an optional head revision in the task. When given, the reviewer compares it with `git rev-parse HEAD`, which Rule 1 would list beside the read-only queries it already allows, and on a mismatch returns `review.no-change-identified` and stops, since the workspace is not the change the task names. No new `rule_id` and no schema change. The pull request skill pins the head itself; a local caller today has no guard against a stale checkout.

Rejected: a separate request input (see the Spec decision). Also rejected: the superpowers "Declined to judge" list of behaviours set aside as outside the spec. Our checks are closed lists, so a run has no open-ended set of things it chose not to judge, and a check that could not run is already a `review.check-not-run` finding.

### Severity

Keep the four-level enum. The mapping below is for rendering or exporting to a three-level consumer only.

| Ours | superpowers | SARIF `level` |
|------|-------------|---------------|
| CRITICAL | Critical | `error` |
| HIGH | Critical | `error` |
| MEDIUM | Important | `warning` |
| LOW | Minor | `note` |

superpowers defines Critical as "Bugs, security issues, data loss risks, broken functionality": our CRITICAL, and our HIGH, which fails at plan or apply. Important covers "missing features, poor error handling, test gaps", and "Proceed with unfixed Important issues" is one of its red flags. That matches MEDIUM, which the pull request verdict ladder also blocks on. Minor is LOW.

Severities from other reviewers are never translated into ours. The maintainer treats every incoming item as a claim, and the reviewer imports no findings.

Rejected: moving to three levels. It loses the CRITICAL and HIGH split that rule 0 of the verdict ladder reads.

## Decision 3: cross-tool standards

| Standard | Decision | Reason | Reopens when |
|----------|----------|--------|--------------|
| SARIF 2.1.0 | Map to, as an export. No exporter until a consumer exists. | An OASIS standard with a published JSON schema, read by code scanning services. Every one of our seven fields has a place (table below). | A consumer appears, such as uploading findings to a code scanning service. |
| reviewdog rdjson | Skip | A linter diagnostic format with three severities. Its `Suggestion` is replacement text over a range, so a prose `suggested_fix` has no field. reviewdog's value is inline comments, and the pull request skill posts one body with no inline comments. | Findings have to flow through a reviewdog pipeline. |
| AGENTS.md | Skip as a rules channel and as an output | Plain Markdown with "no mandatory structure", read by each tool from the workspace, that is the head. Our reviewer treats a workspace `AGENTS.md` as data. This repository's own `AGENTS.md` stays guidance for its authors. | Decision 1 reopens. |
| CodeRabbit `.coderabbit.yaml` | Skip | Configuration inside each module repository, or a pointer to a file in another repository of the organization, so a copy either way, with the problems of Decision 1. It defines no findings format to map to. | Decision 1 reopens. |
| GitHub Copilot instructions | Skip | Read from the head branch, per the page read. No findings format. | Copilot documents reading instructions from the base branch. |
| Conventional Comments | Skip | Formats one comment as `<label> [decorations]: <subject>`. The pull request skill posts one body grouped by severity. Labels such as `praise`, `thought` and `question` have no place in a defects-only schema, and the `blocking` decoration would repeat the verdict. | The pull request skill starts posting line comments. |
| A standard of our own | No | The seven-field schema is an internal contract between our skills. Nobody else would read a published version. | Another tool asks to consume the schema. |

### SARIF mapping

Verified against the schema pinned above, and for property bags against section 3.8.1 of the specification document. A run also needs `tool.driver.name`, the only required property of the driver.

| Our field | SARIF 2.1.0 | Why |
|-----------|-------------|-----|
| `id` | `result.properties.id` | `result.guid` must be a GUID, and our `id` is not stable across runs. Section 3.8.1 defines a property bag as holding properties "with arbitrary names". |
| `rule_id` | `result.ruleId`, and `run.tool.driver.rules[].id` for each distinct value | `ruleId` is "The stable, unique identifier of the rule", the meaning our stability rules give `rule_id`. A `reportingDescriptor` requires `id`. |
| `severity` | `result.level` per the severity table, plus `result.properties.severity` holding our value | `level` allows `none`, `note`, `warning`, `error`, with default `warning`. The property keeps all four levels, so the field survives the rendering, as the findings schema requires. |
| `file` | `result.locations[0].physicalLocation.artifactLocation.uri`, relative, with `uriBaseId` naming the module root | A `physicalLocation` requires `artifactLocation` or `address`. A module-level finding (`.`) points at the module root. |
| `line` | `...physicalLocation.region.startLine`, with `region` omitted when `line` is null | `startLine` has minimum 1, the same 1-based count we use. |
| `summary` | `result.message.text` | `message` is the only required property of a result. |
| `suggested_fix` | `result.properties.suggested_fix` | A SARIF `fix` requires `artifactChanges` with at least one item, which means concrete replacements. Our fix is prose and never applies, so it goes into the property bag, never `result.fixes`. |

## Pilot: the review guide in a generic reviewer

Run on 2026-09-24. One run per case, so the results below are observations, not a rate.

**Setup.**

- Guide: [review-guide.md](../.agents/skills/terraform-module-maintainer/profiles/terraform-aws-modules/review-guide.md) at blob `5a5ae5ff337e0834ae1985f61849d7c983362f98`, handed over as a file outside the workspace.
- Reviewer: a fresh general-purpose agent per case, with no skill from this repository loaded. It received the guide, the diff between the pinned base and head (REST `compare`, fetched by SHA), and the release title. It could fetch files of that one module repository by SHA with read-only GET requests. It was told to read no other local file and to return an access log. No log shows a read of this repository; the Case 9 log also names a copy of part of that case's own diff, saved by the agent host.
- Outputs: each reviewer's final message, with its self-reported access log, is kept in the maintainers' pilot outputs (not published), with local paths removed. The full transcripts were not kept, so the isolation claim rests on those self-reported logs. The Generic reviewer columns below are my reading of those outputs.
- Baseline: the latest measured list for the case in the reviewer's measured fixtures (not published). A baseline row is "in the guide" when its `rule_id` is one the guide names. The other rows are listed apart, because the guide never claims them.
- Matching: a generic finding matches a baseline row on `{rule_id, file}`. A finding on a directory, such as a new submodule, matches when the reviewer anchored it to a file inside that directory. Severity is compared separately, because the guide tells the reviewer to use its own scale. The totals also give the count under the fixtures' own comparison rule, exact `{rule_id, file, severity}` triples.

### Case 5: terraform-aws-s3-bucket pull request 411

Docs only, one new README region. Baseline: fixture Case 5, re-measured on 2026-09-24 after the generated-content rule change, an empty list.

| Triple | Baseline | Generic reviewer | Result |
|--------|----------|------------------|--------|
| `profile.commit-type-mismatch`, `.` | none | MEDIUM | Extra. `fix` on a docs-only change is not in the guide's list of wrong types. The fixture's notes record the same reading as one the rule text does not reach. |
| `structure.comment-unsourced`, `README.md` | none | LOW | Extra. The rule covers comments in `.tf` code. The reviewer applied it to README prose and said so. |
| `profile.generated-content-handwritten`, `README.md` | none | none | Agreed. The reviewer read the base `.pre-commit-config.yaml`, found no hook naming the new marker pair, and left the region alone, which is what this case pins. |

### Case 8: terraform-aws-eks pull request 3668

A revert that removes one managed policy from a role the module creates. Baseline: fixture Case 8, one triple, outside the guide.

| Triple | Baseline | Generic reviewer | Result |
|--------|----------|------------------|--------|
| `compat.generated-policy-narrowed`, `main.tf` | CRITICAL | none | Outside the guide, missed. The reviewer saw that the attachment would be destroyed, noted it for a person, and judged the revert not breaking. |
| `profile.commit-type-mismatch`, `.` | none, folded into the Check A finding | none | Agreed. The guide's "breaking change with no `!`" item fires only for a reader that rates the revert breaking. |

### Case 9: terraform-aws-s3-bucket pull request 410 at `30cd372`

A new submodule across 61 files. Baseline: fixture Case 9, 25 rows, 7 of them under rules the guide names.

| Triple | Baseline | Generic reviewer | Result |
|--------|----------|------------------|--------|
| `scope.new-submodule`, `modules/file-system` | MEDIUM | MEDIUM, on `modules/file-system/main.tf` | Matched on `{rule_id, file}` through the directory rule; not an exact triple, because the file differs |
| `structure.comment-unsourced`, `modules/file-system/main.tf` | MEDIUM | MEDIUM | Matched, exact triple |
| `structure.comment-unsourced`, `main.tf` | MEDIUM | LOW | Matched on `{rule_id, file}`, lower severity |
| `structure.comment-unsourced`, `examples/file-system/main.tf` | MEDIUM | LOW | Matched on `{rule_id, file}`, lower severity |
| `structure.copied-content-unattributed`, `modules/file-system/main.tf` | MEDIUM | MEDIUM | Matched, exact triple |
| `structure.copied-content-unattributed`, `examples/file-system/main.tf` | MEDIUM | none | Missed |
| `examples.feature-undemonstrated`, `examples/file-system/main.tf` | MEDIUM | none | Missed |
| `structure.comment-unsourced`, `modules/file-system/variables.tf` | none | LOW | Extra |
| `structure.comment-unsourced`, `variables.tf` | none | LOW | Extra |
| `structure.comment-unsourced`, `README.md` | none | LOW | Extra, README prose again |

The other 18 baseline rows are under rules the guide does not name: example, coverage, compatibility and structure checks that need the provider schema or the module's own logic. Three of them are HIGH. The reviewer described two of those three in substance, both `structure.docs-contradict-code`, as notes outside the guide with no ID. It did not reach the third, an example that cannot plan because a required block is missing.

### Totals and conclusion

| Case | Baseline rows in the guide | Matched on `{rule_id, file}` | Of those, exact triples | Missed | Extra |
|------|----------------------------|------------------------------|-------------------------|--------|-------|
| 5 | 0 | 0 | 0 | 0 | 2 |
| 8 | 0 | 0 | 0 | 0 | 0 |
| 9 | 7 | 5 | 2 | 2 | 3 |

- On the rules it carries, the guide mostly worked: the reviewer matched 5 of 7 baseline rows on `{rule_id, file}`, and 2 of 7 as exact triples. Two of the other three differ only in severity, rated LOW against MEDIUM, and one only in anchoring a directory finding to a file inside it. It also stayed silent where Case 5 needs silence. Of its five extras, two come from applying the evidence rules to README prose and one from extending the title-type list past the cases it names. The other two are unsourced comments in `.tf` files that the baseline did not list, and a second look could go either way.
- The guide does not carry the findings that matter most here. None of the four HIGH or CRITICAL baseline triples across the three cases is under a rule the guide names. Case 8's break and Case 9's example that cannot plan need compatibility and provider schema reasoning that the guide leaves to `terraform-module-reviewer`. That confirms Decision 1: a generic reviewer's output is advice and never a verdict input.
- Three single runs are too few for a public claim about a generic reviewer's recall, so no README note follows. Two guide changes would remove three of the five extras: say that the evidence rules cover comments and constants in `.tf` files, not README prose, and say that the title rule's list of wrong types is complete.

## Recommended follow-ups

1. Reviewer: optional head revision in the task, checked against the workspace `HEAD`. It closes the stale-checkout gap for local callers with no schema change.
2. Profile: self-contained review guide for generic reviewers, with the drift checks in `tests/skills-test.sh`. This is the hand-over artifact from Decision 1.
3. Pilot: measure generic reviewers given the guide on pinned terraform-aws-modules changes before any public claim about them. Depends on 2.

No follow-up for the receiving discipline, which Resolve feedback already carries. None for a SARIF exporter, a `spec.` prefix, or vendor configuration files: each waits for its reopen trigger.

## Related

- The toolset research (not published): rules defined in a project's repository, and the trust table.
- [findings-schema.md](../.agents/skills/terraform-module-reviewer/references/findings-schema.md): the seven-field contract the mappings above export.
