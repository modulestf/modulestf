# Depth

> **Part of:** [terraform-module-pr-review](../SKILL.md)
> **Purpose:** How deep a review goes, light, focused or deep, which checks and examples each depth leaves out, and how the host binds that choice to the trees it was computed from.

The host decides the depth before the reviewer starts, from the git trees at the bound head and merge base, never from a pull request artifact. `mtf-facts depth` reads the two trees and decides; [depth.sh](depth.sh) runs it, binds the result and writes `depth.json` in the run directory. Every rule fails closed: anything not proven is deep, never an approval.

## The Depths

| Depth | When | Runs | Out of scope |
|-------|------|------|--------------|
| light | Every changed file is documentation (`*.md`, `CHANGELOG*`, a `docs/` directory, `LICENSE`, `.gitignore`, `.editorconfig`), none is read by Terraform, no string expression in the head resolves to a changed file, every string expression resolves, and the classifier calls the change inert | `validate` in every example, Checks C (on the changed files it covers), E and F, and Check G's claim reading without the ladder | Checks A, B and D, the rest of Check G, the plan pass, the ladder, provider facts |
| focused | A Terraform change within the limits below, with no deep class | Checks A, C, E, F and G; D when a selected example reaches the change or an example changes; B on touched types; every touched and caller example planned; provider facts from fact sheets | Check B with no touched type, an example `mtf-facts` proves does not reach the change; Check D stays in scope |
| deep | Everything else | The whole pipeline | Nothing |

Focused limits, over all changed files, examples included: at most 6 Terraform files, 200 changed lines, 4 changed resource, data and module blocks, and 12 selected examples. A change past one is deep.

Deep is forced by a classifier that is missing, failed or invalid; a parser failure; an unresolved or unmodelled consumer; `mtf-facts affected` with a fallback; more than 12 selected examples; at focused, a schema pass that fails or overflows; any change to CI, hook or release configuration or to a CLI configuration file; more than 50 changed files at light; and every deep class of `mtf-facts depth`.

Light rule 6, `validate` passing in every example, is the host's: a failure runs `depth.sh escalate` with `deep-validate-failed` before the reviewer starts. A schema pass failure at focused runs it with `deep-schema-<reason>`.

The owner raises the depth with the exact token `depth: deep` and nothing else; the host passes it as `--owner-depth deep`, and depth.sh adds `deep-owner-raise`. Nothing lowers a depth, and fetched content never sets one. `mode: triage` is unchanged by any depth: it never approves.

## depth.json

The `mtf-facts depth` object, every key required and no other:

| Key | Value |
|-----|-------|
| `format` | `1` |
| `depth` | `light`, `focused` or `deep` |
| `reasons` | The reason tokens below, at least one, each once; every one starts with the depth's own word (`light-`, `focused-` or `deep-`) |
| `checks_out_of_scope` | At light a subset of `A`, `B`, `D` and `G-ladder` (Check G without its claim reading), at focused empty or `B` alone, at deep empty |
| `examples_selected`, `examples_out_of_scope` | Example directories, repository-relative in one spelling; no directory in both; only focused puts one out of scope |
| `touched_types` | Resource and data source types, `^[a-z][a-z0-9_]{0,127}$` |
| `walk` | `{"complete": bool, "unwalked": n}`; a reduced depth needs a complete walk |
| `limits` | `tf_files`, `changed_lines`, `changed_blocks`, `selected_examples`; a reduced depth needs them within the focused limits, and light no Terraform file |
| `schema_providers`, `schema_types`, `schema_locks` | The tokens of [schema-pass.md](schema-pass.md#inputs); a lock is `<dir>:<namespace>/<name>=<x.y.z>` |

depth.sh adds one key, `binding`: `head_sha`, `base_sha` and `merge_base`, 40 lowercase hex, and `diff_sha256`, the SHA-256 of `git diff --no-ext-diff --no-textconv --binary <merge base> <head>`. The merge base is the only result of `git merge-base --all <base> <head>`; none or several abort the run.

## Reason Tokens

The tokens `mtf-facts depth` gives, in its order:

- `light-docs-only`
- `focused-within-limits`
- `focused-no-example`
- `deep-terraform-block`
- `deep-lock-file`
- `deep-cli-config`
- `deep-ci-config`
- `deep-provider-config`
- `deep-depends-on`
- `deep-new-type`
- `deep-block-removed-or-renamed`
- `deep-variable-contract`
- `deep-output-sensitive`
- `deep-lifecycle-moved-removed-import`
- `deep-count-for-each`
- `deep-provisioner`
- `deep-policy`
- `deep-module-source-version`
- `deep-dynamic-structure`
- `deep-wrappers`
- `deep-limits`
- `deep-classifier-category`
- `deep-classifier-unavailable`
- `deep-classifier-invalid`
- `deep-classifier-mismatch`
- `deep-affected-fallback`
- `deep-affected-invalid`
- `deep-parse-failure`
- `deep-unwalked`
- `deep-unresolved-consumer`
- `deep-unresolved-file-dependency`
- `deep-path-unsafe`
- `deep-too-many-examples`
- `deep-too-many-files`
- `deep-test-or-mock`
- `deep-files-list-mismatch`
- `deep-non-terraform-change`

The host's own raises, which `mtf-facts` never gives:

- `deep-owner-raise`
- `deep-validate-failed`

And `deep-schema-<reason>`, `<reason>` matching `^[a-z0-9-]{1,64}$`, the schema pass's escalation. [render-comment.jq](render-comment.jq) holds the same lists, and `tests/depth-test.sh` checks the two are equal.

## depth.sh

```
<bash|zsh> /abs/path/depth.sh compute --clone "$RUN/clone" --base-tree "$RUN/base" --base <base-sha> \
  --files <files.json> --classify <behaviour.json> --affected <affected.json> --out "$RUN/depth.json" [--owner-depth deep]
<bash|zsh> /abs/path/depth.sh verify "$RUN/depth.json" --clone "$RUN/clone"
<bash|zsh> /abs/path/depth.sh escalate "$RUN/depth.json" <reason>
```

`compute` checks that the clone holds `<base-sha>`, that the merge base is the one result of `git merge-base --all`, and that the base tree is at it, then runs `mtf-facts depth` and writes `depth.json` whole or not at all. The clone needs the history between the base and the head for that; a shallow clone that lacks it aborts. `mtf-facts` comes from the host's `PATH`, its first absolute entry, with every link resolved; one under the clone, the base tree or the run directory is never run. A missing, failing or late `mtf-facts` (`DEPTH_TIMEOUT`, 120 seconds) or an object that does not fit the grammar above gives deep with `deep-classifier-unavailable`; a classifier output that is missing or not an object adds `deep-classifier-unavailable`, and an affected output that is missing, not an object or empty adds `deep-affected-fallback`.

`verify` recomputes the head, the merge base and the diff hash from the clone; any difference, an unknown key or an unknown value is a non-zero exit and the run aborts. The host runs it before the reviewer starts and again before the render. `escalate` raises the depth to deep in place with one deep token: the reasons of a reduced depth go, nothing stays out of scope, and the examples out of scope join the selected ones.

Exit 1 aborts the run; exit 2 is a usage error or a refused input; neither writes anything. Paths are data: they reach git and `mtf-facts` as single arguments and jq as files, never as shell words.

## Rule 4 Per Depth

A check or an example out of scope by the table above is not an unknown at rule 4 of [verdict.md](verdict.md#rule-4-per-depth): the render drops an example out of scope from the verification gaps and the examples not planned, and at light, where the plan pass is out of scope, every example not planned, whose reason the host writes as `plan pass skipped at light depth`. That reason at any other depth, or with no depth, is a refused input. Anything in scope that did not run stays an unknown. Deep leaves nothing out of scope, so it renders as a run with no depth does.

## Comment Lines

The run file carries `depth.json` as its `depth` key, and [render-comment.sh](render-comment.sh) refuses it, exit 2 and nothing written, unless it fits the grammar above, its `head_sha` is the head rendered and its `merge_base` is host.json's. The body then states, in both tiers ([comment-format.md](comment-format.md#host-render-strings)):

- `depth-line`: the depth and its reasons;
- `depth-out-of-scope`: the checks out of scope, at light the plan pass, the ladder and the provider facts, then the examples out of scope, the first 20 and `depth-more` with the count of the rest; none when nothing is out of scope.

STANDARD puts them under `### Review depth` after the checks that could not run; COMPACT puts them in its details block. An example name is shown in a code span when every character is in `[A-Za-z0-9._/-]`, else as `name-withheld`. A run file without `depth` renders the body it rendered before the key existed.
