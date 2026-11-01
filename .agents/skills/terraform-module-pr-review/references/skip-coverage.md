# Skip Coverage

> **Part of:** [terraform-module-pr-review](../SKILL.md)
> **Purpose:** Which examples a plan gate kept from planning are covered by the plans of other examples: the script, its inputs, the allow-list of changes, the base and head gate records, the witnesses, the reasons, the output and its limits.

A laptop plan pass skips an example whose files hit gate G1, G2 or G3 ([plan-pass.md](plan-pass.md#gates)), and [plan coverage](verify-pass.md#plan-coverage) lists it as not planned, an unknown at [verdict.md](verdict.md#the-ladder) rule 4. Such a skip says nothing about the change when the change cannot reach the gated code and the code it does change was planned elsewhere. This file decides that for conditions 1 and 2 of the rule; the render checks the rest ([render-comment.sh](render-comment.sh)). Any doubt leaves the skip an unknown, as it is today.

The script is [skip-coverage.sh](skip-coverage.sh), with the decision in [skip-coverage.jq](skip-coverage.jq). It runs the same under bash and zsh, reads only files, never runs terraform and never reads the network. Like its siblings it is invoked by an absolute path in the skill as installed, never from the head or the workspace.

## Commands

```
<bash|zsh> /abs/path/skip-coverage.sh gates <run-dir> --tree <dir> --base <sha> \
    --coverage <coverage.json> --out <file>
<bash|zsh> /abs/path/skip-coverage.sh check <run-dir> --files <files.json> \
    --coverage <coverage.json> --plan <record> --head <sha> --base <sha|unresolved> \
    --changed-files <n> [--addresses <dir>] [--base-gates <file>] [--prefix <module-root>]
```

`gates` writes the base gate record, [Gate records](#gate-records), for every directory in the coverage's `unplanned` list. It refuses, exit 2 and nothing written, unless `--tree` is an absolute path to a git tree whose `HEAD` is the `--base` commit; a step that fails writes nothing either. `check` prints one JSON object, [Output](#output), on standard output.

Exit 0 means the evaluation ran: every directory uncovered is a valid result. `gates` exits 3, writing nothing, when the clone does not hold the `--base` commit ([The base tree](#the-base-tree)). Exit 2 is a usage error or a refused input, and nothing is printed: a run directory of another shape, a `--head` that is not a full lowercase SHA, a `--base` that is neither one nor the word `unresolved`, a missing or oversized `--files`, `--coverage` or `--plan`, a `--changed-files` that is not a count, a files list that is not an array of file objects, or a coverage that is not a plan coverage object.

## Inputs

| Input | What it is |
|-------|------------|
| `<run-dir>` | The run directory of [Workspace](github-io.md#workspace), with the clone at head in `<run-dir>/clone` |
| `--files` | The changed files list, `files.json` of [verify-pass.md](verify-pass.md#inputs): `filename`, `status`, `patch` and `previous_filename` are read |
| `--changed-files` | The pull request's `changed_files` count from its metadata ([github-io.md](github-io.md#metadata)); the files list must hold exactly that many entries |
| `--coverage` | The output of `verify-pass.sh coverage`; only `unplanned` is read |
| `--plan` | The plan pass's laptop record, the lines it printed: `plan pass mode:`, and per example `example:` and `plan:` |
| `--addresses` | The directory of `addresses-<n>.json` beside the record ([plan-pass.md](plan-pass.md#saved-plans-and-addresses)), `<n>` the example's place in the record; a file counts only for the example its `example` key names |
| `--base-gates` | The base gate record `gates` wrote |
| `--head` | The head commit, the full SHA; the clone must be at it |
| `--base` | The merge base, the full SHA from the compare read in Workspace, or `unresolved` when it could not be read |
| `--prefix` | The module root's repository-relative path, empty by default |

### The base tree

The base gate record needs a tree at the merge base. The run already has one when the merge base re-run added it: the worktree at `<run-dir>/base`. Otherwise the caller first fetches the merge base into the clone, as [Workspace](github-io.md#workspace) does for that re-run with `clone_git fetch --depth=1 origin "$BASE"`, since in an interactive run nothing else may have fetched it, and then adds the worktree the same way, through `clone_git` of [Workspace](github-io.md#workspace), which carries the hook and filter options: `GIT_LFS_SKIP_SMUDGE=1 git -C <run-dir>/clone -c core.hooksPath=/dev/null -c filter.lfs.smudge=cat -c filter.lfs.process= -c filter.lfs.required=false worktree add --detach -- <run-dir>/base <base>`. Then `gates --tree <run-dir>/base --base <base>` writes the record; the worktree may go after that. A worktree added only for this needs no clone-wide G0 run, `plan-pass.sh g0 <run-dir> base`: only `gates` reads the worktree and runs no terraform there, the per-file G0 still enters the record through `gates`, and only a directory skipped for G1, G2 or G3 alone can be covered, with its G0 state judged at head (condition 9).

With no base tree, or no record, every candidate directory is `base-record-missing`: the skips stay unknowns. When the clone does not hold the base commit, `gates` writes nothing and exits 3 with `the base commit is not in the clone; fetch it first`, and `check` reads such a `--base` as `unresolved`: every candidate directory is `merge-base-unresolved`.

## Conditions

A directory is covered only when every check below holds, in this order; the first that fails gives its reason.

1. It appears once in `unplanned` (else `not-sole-reason`), with the reason `plan gate G1`, `plan gate G2` or `plan gate G3` (else `wrong-gate-class`: G0, a failed plan, no profile, anything else).
2. The clone is at `--head` (else `head-mismatch`), and the files list holds `--changed-files` entries and every entry was classified (else `files-incomplete`): a list cut short by paging could hide a change.
3. The plan record is a laptop record with a block for the directory whose `plan:` line names the same gate and a first hit (else `plan-record-unusable`). The hit is read as `<path>` with an optional `:<suffix>`: a clone hit is then matched by its path alone, and a downloaded hit needs a numeric line ([Downloaded hits](#downloaded-hits)). A runner record never covers a skip.
4. The whole change passes [The allow-list](#the-allow-list) and changes at least one attribute (else `change-not-allowed`).
5. No changed file, by its name or its previous name, lies under the directory or under its real directory, which the gate records give for a directory that is a link (else `dir-changed`).
6. `--base` is a SHA (else `merge-base-unresolved`).
7. The base gate record names `--base`, ends with its `end` line and holds the directory with its `done` line (else `base-record-missing`: missing, stale or partial).
8. Exact base hit: the head gate record, which `check` computes over the clone with the same function, holds the same lines for the directory as the base record, its real directory, its scope files and its hits as a multiset of gate and path (else `hit-set-differs`). When the record's first hit is in the clone scope, it must be among the head record's hits (else `hit-set-differs`); when it is in a downloaded module, [Downloaded hits](#downloaded-hits) applies instead.
9. No head hit is G0, and no recorded hit either when the first hit is downloaded (else `wrong-gate-class`).
10. Every changed attribute has a witness, [Witnesses](#witnesses) (else `witness-sensitive` when every attribute without one had a candidate that failed only on its sensitive bit, otherwise `no-witness`).

Checks 2, 4, 6 and 10 and the files count are about the whole change, so they give every directory the same reason.

## Gate records

`gates` and `check` build a gate record with one function. For each directory, in the tree at hand: `plan-pass.sh scope` lists the clone scope the plan pass gated, the example's `.tf` files and those of every local module directory it reaches, and `plan-pass.sh gates <run-dir> laptop clone` runs the per-file gates G0 to G3 over that list. Both are the plan pass's own functions, so the record holds the same scope and the same per-file hits the pass computed. The pass's gates before `init` also read the lock files the head committed in the scope (`committed_locks`); the record leaves them out, since that function runs only inside the pass. A lock file hit therefore never matches the record: as a first hit it gives `hit-set-differs`, and a lock file cannot differ between head and base without a changed file the allow-list refuses. plan-pass.sh reads the tree through a run directory of its own under the script's temporary directory, whose `clone` is a link to the tree, so a local module source in the base tree resolves inside the base tree.

```
skip-gates 1 <sha>
dir <dir>
real <path>
file <path>
hit <gate> <path>
done <dir>
end
```

Paths are relative to the tree. `real` is the directory's real path, so a directory that is a link records its target. The per-file gates can print the same hit twice for one file, when two of its patterns match the same place; the record keeps every line, so the comparison counts such a hit the same way at head and base. The plan record's `(<n> hits)` counts distinct hits after the pass rewrites their paths, so it can be smaller than the number of `hit` lines. A hit keeps its gate and file and drops its line, since an allowed change elsewhere in a shared file moves lines; a directory absent from the tree records `file MISSING`. The pass's downloaded scope is not in the record: it exists only after `init`, which this script never runs. Its hits come from the plan record instead, [Downloaded hits](#downloaded-hits).

## Downloaded hits

The plan pass gates the modules `init` downloaded only when the clone scope had no hit, and records such a hit with a path under `downloaded/`: `gate-hit <G> downloaded/<module key>/<file>:<line>` per hit, and the first as `plan: plan gate <G> downloaded/<module key>/<file>:<line> (<n> hits)` ([plan-pass.md](plan-pass.md#gates)). This script never runs `init`, so no gate record holds those files at either side. A downloaded hit is taken from the head plan record and counts as equal at the base by construction, because the pull request cannot have put it there:

- G2, before and after `init`, admits only module sources that are local paths inside the clone or `terraform-aws-modules` registry sources, so a downloaded module's code comes from the registry and does not depend on the pull request.
- What `init` downloads is set by the module calls of the example and of the local modules it reaches. The example directory is unchanged (condition 5), the allow-list refuses every change to a module call's source or arguments, and the scope files are compared at both sides (condition 8).
- The resolved version of each registry module is recorded in the example's `modules:` line, and nothing here relies on it: a version constraint resolves the same way for the head and the base at the time of the run, and the base was never initialised.

Rules, each failing closed:

- The first hit is downloaded and every `gate-hit` line of the block is too, each with gate G1, G2 or G3, a path under `downloaded/` that does not climb out with `..`, and a numeric line. A block with no `gate-hit` lines is read by its `plan:` line alone.
- Any recorded hit with gate G0 gives `wrong-gate-class`. A hit line that does not parse, has no numeric line, such as a `modules.json` entry named by module key, or climbs out gives `hit-set-differs`.
- The head gate record of the directory has no hit: the pass gates the downloaded scope only when the clone scope is clean, so a clone hit beside a downloaded first hit means the record does not match the clone, `hit-set-differs`.
- The clone-scope comparison of condition 8 still applies.

The covered element then carries `"downloaded": true`. Such a hit was never gated at the base: a consumer must not describe it as found or measured at the base, only as a hit in a downloaded module the pull request cannot change.

## The allow-list

Every changed file of the pull request must be one of:

- a `*.md` file anywhere, with status `modified`, whose file name no `.tf` file in the head clone mentions;
- a `.tf` file with status `modified` and no `previous_filename`, at the module root or under `modules/`, never under an `examples/` or `wrappers/` directory, whose every change is a plain expression change to an attribute of a resource or data block.

A `.tf` file can read a document with `file`, `templatefile` or `fileset`, so a document that Terraform may read is code. The check is a fixed-string search for the document's file name over every `.tf` file of the clone, `.git` left out, and it is conservative both ways: a comment that merely names the file fails the change, and a path built from a variable or a glob such as `fileset(path.module, "*.md")` names no file and is not caught. The gates refuse those functions in every planned example's scope, so only a gated scope can read a document this way.

Anything else fails the whole change: any other file type, any status but `modified` (an added, removed, renamed or copied file), a `.tf` elsewhere, a file with no `patch`, and a change of only `*.md` files. A change with no Terraform change at all reaches no HCL read site and is inert; the render handles an inert change without this file, so the skips come back `change-not-allowed` and nothing is lost.

For a `.tf` file the parser in the script works on the head file in the clone and the patch:

1. It rebuilds the base text from the head text and the hunks. Every context and added line must equal the head file at its place and every hunk's line counts must match its header; otherwise the file fails. A file with a non-ASCII byte or a carriage return fails.
2. It parses both texts into blocks and attributes, with strings, interpolations, heredocs and comments read by a lexer; a `/*` comment, a template directive, a label that is not a plain name, a heredoc line whose template interpolation or directive does not close on that line, or anything it cannot place fails the file. HCL reads an open interpolation on as an expression, past a line that holds only the heredoc's marker, which a line-based heredoc reader would take as its end.
3. The skeletons of both texts, every block header and every attribute name in order, must be equal: no block or attribute added, removed, renamed or moved.
4. Each change group, a run of removed and added lines, must fall wholly inside one attribute, its removed lines in the base and its added lines in the head, and that attribute must be a direct argument of a top-level `resource` or `data` block with two labels. A changed comment or blank line between attributes fails; so does a group that spans two attributes.
5. The attribute is not `count`, `for_each`, `provider` or `depends_on`; `lifecycle`, `connection`, `provisioner`, `dynamic` and every other nested block fail at step 4.
6. Its expression, at head and at base, is plain: numbers, strings whose interpolations are plain, `true`, `false`, `null`, references with attribute, index and splat steps, tuples, objects with name or string keys, and calls of only `concat`, `compact`, `flatten`, `distinct`, `join`, `format`, `length`, `toset`, `tolist`, `tomap`, `element`, `keys` and `values`. Any operator, `?:`, `for`, `...`, a heredoc, a reference rooted at `each`, `count` or `self`, and every other function, `try`, `can`, `lookup`, `coalesce`, `merge`, `file`, `templatefile` and `jsondecode` among them, fail.

The changed attribute is then `{dir, address, attribute}`: the file's directory, `.` for the root; the block's address, `<type>.<name>` or `data.<type>.<name>`; and the attribute's name.

## Witnesses

Condition 2 of the rule: a plan of another example planned the changed code. For each changed attribute the examples of the record whose class is `planned` are tried in path order, and the first that qualifies is the witness:

- its `addresses-<n>.json` names `head_sha` equal to `--head` and `example` equal to the example directory of record block `<n>`, so a file from another run or another example never counts;
- a module call in its `module_calls`, tried by name, has a local source that resolves from the example directory, as plan coverage resolves it, to exactly the changed file's directory;
- `module.<call>.<address>` is in its `addresses`, and the attribute is in that address's `attributes`;
- its `sensitive` map holds that address with an array of names that does not contain the attribute.

These follow from it: count 0 or an empty `for_each` plans no instance, so no address; a registry or git source is not in `module_calls`; the same address under a call whose source resolves elsewhere is not a witness; a missing `sensitive` key, an address missing from it or a value of another shape gives no witness. `planned-no-changes` is not a witness here, since the rule counts it only for a change the ladder classed inert, and the render takes no covered skip for an inert change.

The v1 limit: the address's module path is exactly one `module.<call>` level, called directly by the example, whose source is the module root or the `modules/<sub>` directory of the changed file. A change reached only through a deeper chain, such as the root module calling `modules/<sub>`, has no witness, and the skips stay unknowns.

## Output

```
{"format": 1, "head_sha": "<40 hex>", "base_sha": "<40 hex>" or null,
 "covered": [{"dir": "...", "gate": "G3", "path": "...", "downloaded": true, "witnesses":
               [{"attribute": "...", "example": "...", "address": "..."}]}],
 "uncovered": [{"dir": "...", "why": "<reason>"}]}
```

Every directory of `unplanned` appears once, in its order, in `covered` or in `uncovered`. `path` is the file of the record's first hit, without its line. `downloaded` is present, and true, only when that hit is in a downloaded module ([Downloaded hits](#downloaded-hits)); a consumer that does not show it may ignore it. `witnesses` holds one entry per changed attribute, the same for every covered directory. `base_sha` is null only for `--base unresolved` or a base commit the clone does not hold, and `covered` is then empty.

The reasons, a closed list: `not-sole-reason`, `wrong-gate-class`, `head-mismatch`, `files-incomplete`, `plan-record-unusable`, `change-not-allowed`, `dir-changed`, `merge-base-unresolved`, `base-record-missing`, `hit-set-differs`, `witness-sensitive`, `no-witness`.

## What crosses to the reviewer

Nothing from this script crosses to the reviewer. The host puts `covered` into the run file's `coverage` as `covered_skips`, with `head_sha` and `base_sha` as `skip_head_sha` and `skip_base_sha` ([render-comment.sh](render-comment.sh)), and only when `covered` is not empty; the render applies it only when conditions 3 to 5 also hold, all skips or none. The `uncovered` list and its reasons stay in the run's own log. Directory, path, example and address are names only, and the render checks each against its pattern before it shows one.

## Failure modes

Each fails closed, the skips stay unknowns:

| Failure | Result |
|---------|--------|
| No base worktree, or `gates` refused or failed | no record, `base-record-missing` |
| The record names another SHA, lacks `end`, or a directory lacks `done` | `base-record-missing` |
| `plan-pass.sh scope` or `gates` failed at head | `hit-set-differs` |
| The clone moved off `--head` | `head-mismatch` |
| The files list shorter or longer than `--changed-files`, or an entry left unclassified | `files-incomplete` |
| A head file missing from the clone, a patch that does not apply to it, a file the parser cannot read | `change-not-allowed` |
| An addresses file missing, oversized, a link, not JSON, or without the matching `head_sha` or `example` | that example gives no witness |

## Limits

- The downloaded scope is never gated at the base; a downloaded hit is taken from the head record on the argument in [Downloaded hits](#downloaded-hits), and only for an unchanged directory with a clean clone scope.
- A hit keeps no line, so a second hit of the same gate in the same file that replaces one removed elsewhere in it would compare equal; the allow-list keeps such text out of an allowed change.
- The parser reads the subset of HCL the allow-list needs and fails on the rest; it is no Terraform parser.
- A change group spanning two attributes fails, though each half might be allowed alone.
- Addresses and the sensitive bit come from the head's own plan, read back with `terraform show`: evidence the head could shape, as [plan-pass.md](plan-pass.md#saved-plans-and-addresses) says.
