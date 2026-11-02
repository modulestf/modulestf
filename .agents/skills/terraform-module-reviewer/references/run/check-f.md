# Run Summary: Check F

> **Part of:** [terraform-module-reviewer](../../SKILL.md), [Check F](../check-f-scope.md)
> **Purpose:** The index a run reads for Check F, as [Reading by Depth](../../SKILL.md#reading-by-depth) says: each `rule_id`, when it applies, the provider facts it needs as [rule-facts.md](../rule-facts.md) gives them, and the sections that hold its text. It holds no rule text; the sections are operative.

When unsure whether a row's **Applies when** holds, it holds.

## Read First

When any row below applies: [Reads, Fails When and Severity](../check-f-scope.md#reads-fails-when-and-severity) and [The base revision](../check-f-scope.md#the-base-revision).

## Rules

| `rule_id` | Applies when | Provider facts | Sections |
|-----------|--------------|----------------|----------|
| `scope.boundary` | The change adds a `resource` block, or a directory under `modules/` or a test helper directory. | none | [Check F](../check-f-scope.md#reads-fails-when-and-severity) |
| `scope.composition` | The change adds a `resource` or `moved` block. | none | [Check F](../check-f-scope.md#reads-fails-when-and-severity) |
| `scope.layout` | The change adds a path. | none | [Check F](../check-f-scope.md#reads-fails-when-and-severity) |
| `scope.module-call` | The change adds a `module` block or edits a `source`. | none | [engine](../engine/check-f-scope.md#scopemodule-call) |
| `scope.new-module` | The task is a new module. | none | [Check F](../check-f-scope.md#reads-fails-when-and-severity), [A new module](../check-f-scope.md#a-new-module) |
| `scope.new-submodule` | The change adds or renames a directory under `modules/`. | none | [engine](../engine/check-f-scope.md#scopenew-submodule) |
| `scope.pre-commit-hook` | The change adds, edits, deletes or renames `.pre-commit-config.yaml`. | none | [engine](../engine/check-f-scope.md#scopepre-commit-hook) |
| `scope.profile-file` | The change adds, edits, deletes or renames a profile-owned file or a file under `.github/`. | none | [engine](../engine/check-f-scope.md#scopeprofile-file) |
| `scope.provider` | The change adds a resource, data or provider block or changes its type, or adds or edits a `required_providers` entry or its source. | none | [engine](../engine/check-f-scope.md#scopeprovider) |
| `scope.readme-banner` | The change edits, adds, deletes or renames the root `README.md`. | none | [engine](../engine/check-f-scope.md#scopereadme-banner) |
| `scope.tests` | The change adds a path under `tests/`, a test file anywhere, or a `go.mod`, `go.sum` or `*_test.go` file anywhere. | none | [Check F](../check-f-scope.md#reads-fails-when-and-severity) |
| `scope.tooling` | The change adds a path. | none | [engine](../engine/check-f-scope.md#scopetooling) |

## Other Sections

| Section | Open when |
|---------|-----------|
| [The suggested fix](../check-f-scope.md#the-suggested-fix) | Check F reports a ban. |
| [Suggested Fixes](../check-f-scope.md#suggested-fixes) | Check F reports a finding. |
| [A new module](../check-f-scope.md#a-new-module) | The task is a new module. |
| [Renamed files](../check-f-scope.md#renamed-files) | The change renames a path. |
| [Not evaluated](../check-f-scope.md#not-evaluated) | A base fact a row reads is unavailable. |
| [Where Check F yields](../check-f-scope.md#where-check-f-yields) | A row applies to a path or block another check also judges. |
| [Decisions](../check-f-scope.md#decisions) | A row applies and the sections above leave its outcome open. |
| [Worked Cases](../check-f-scope.md#worked-cases) | A row applies and the sections above leave its outcome open. |
