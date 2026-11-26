# Skip Coverage

> **Part of:** [terraform-module-pr-review](../SKILL.md)
> **Purpose:** Which examples a plan gate, a recorded exception or their design kept from planning are covered by the plans of other examples: the script, its inputs, the allow-list of changes, the base and head gate records, the witnesses, the reasons, the output and its limits.

A laptop plan pass skips an example whose files hit gate G1, G2 or G3 ([plan-pass.md](plan-pass.md#gates)), and [plan coverage](verify-pass.md#plan-coverage) lists it as not planned, an unknown at [verdict.md](verdict.md#the-ladder) rule 4. Such a skip says nothing about the change when the change cannot reach the gated code and the code it does change was planned elsewhere. This file decides that for conditions 1 and 2 of the rule; the render checks the rest ([render-comment.sh](render-comment.sh)). Any doubt leaves the skip an unknown, as it is today.

The script is [skip-coverage.sh](skip-coverage.sh), with the decision in [skip-coverage.jq](skip-coverage.jq). It runs the same under bash and zsh, reads only files, never runs terraform and never reads the network. It reads the changed attributes from the facts engine ([The facts engine](#the-facts-engine)). Like its siblings it is invoked by an absolute path in the skill as installed, never from the head or the workspace.

## Commands

```
<bash|zsh> /abs/path/skip-coverage.sh gates <run-dir> --tree <dir> --base <sha> \
    --coverage <coverage.json> --out <file> [--mode laptop|runner]
<bash|zsh> /abs/path/skip-coverage.sh check <run-dir> --files <files.json> \
    --coverage <coverage.json> --plan <record> --head <sha> --base <sha|unresolved> \
    --changed-files <n> [--addresses <dir>] [--base-gates <file>] [--prefix <module-root>] \
    [--mode laptop|runner]
```

`--mode` is `laptop` by default, the gate skips of a laptop pass. `runner` covers the recorded exceptions of a runner-mode pass instead ([Recorded exceptions](#recorded-exceptions)); any other value is a usage error. Both modes decide [design skips](#design-skips).

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
| `--mode` | `laptop`, the default, or `runner`: the plan pass mode whose skips are checked, and the mode of the gates both records run |

### The base tree

The base gate record needs a tree at the merge base. The run already has one when the merge base re-run added it: the worktree at `<run-dir>/base`. Otherwise the caller first fetches the merge base into the clone, as [Workspace](github-io.md#workspace) does for that re-run with `clone_git fetch --depth=1 origin "$BASE"`, since in an interactive run nothing else may have fetched it, and then adds the worktree the same way, through `clone_git` of [Workspace](github-io.md#workspace), which carries the hook and filter options: `GIT_LFS_SKIP_SMUDGE=1 git -C <run-dir>/clone -c core.hooksPath=/dev/null -c filter.lfs.smudge=cat -c filter.lfs.process= -c filter.lfs.required=false worktree add --detach -- <run-dir>/base <base>`. Then `gates --tree <run-dir>/base --base <base>` writes the record; the worktree may go after that. A worktree added only for this needs no clone-wide G0 run, `plan-pass.sh g0 <run-dir> base`: only `gates` reads the worktree and runs no terraform there, the per-file G0 still enters the record through `gates`, and only a directory skipped for G1, G2 or G3 alone can be covered, with its G0 state judged at head (condition 9).

With no base tree, or no record, every candidate directory is `base-record-missing`: the skips stay unknowns. When the clone does not hold the base commit, `gates` writes nothing and exits 3 with `the base commit is not in the clone; fetch it first`, and `check` reads such a `--base` as `unresolved`: every candidate directory is `merge-base-unresolved`.

## Conditions

A directory is covered only when every check below holds, in this order; the first that fails gives its reason.

1. It appears once in `unplanned` (else `not-sole-reason`), with the reason `plan gate G1`, `plan gate G2` or `plan gate G3` (else `wrong-gate-class`: G0, a failed plan, no profile, anything else). A reason of [Design skips](#design-skips) is decided there.
2. The clone is at `--head` (else `head-mismatch`), and the files list holds `--changed-files` entries and every entry was classified (else `files-incomplete`): a list cut short by paging could hide a change.
3. The plan record is a laptop record with a block for the directory whose `plan:` line names the same gate and a first hit (else `plan-record-unusable`). The hit is read as `<path>` with an optional `:<suffix>`: a clone hit is then matched by its path alone, and a downloaded hit needs a numeric line ([Downloaded hits](#downloaded-hits)). A runner record never covers a skip.
4. The whole change passes [The allow-list](#the-allow-list) and changes at least one attribute (else `change-not-allowed`).
5. No changed file, by its name or its previous name, lies under the directory or under its real directory, which the gate records give for a directory that is a link (else `dir-changed`).
6. `--base` is a SHA (else `merge-base-unresolved`).
7. The base gate record names `--base`, ends with its `end` line and holds the directory with its `done` line (else `base-record-missing`: missing, stale or partial).
8. Exact base hit: the head gate record, which `check` computes over the clone with the same function, holds the same lines for the directory as the base record, its real directory, its scope files and its hits as a multiset of gate and path (else `hit-set-differs`). When the record's first hit is in the clone scope, it must be among the head record's hits (else `hit-set-differs`); when it is in a downloaded module, [Downloaded hits](#downloaded-hits) applies instead.
9. No head hit is G0, and no recorded hit either when the first hit is downloaded (else `wrong-gate-class`).
10. Every changed attribute has a witness, [Witnesses](#witnesses) (else `witness-sensitive` when every attribute without one had a candidate that failed only on its sensitive bit, otherwise `no-witness`).

Checks 2, 4, 6 and 10 and the files count are about the whole change, so they give every gate skip the same reason; a design skip reads conditions 3, 4 and 6 its own way ([Design skips](#design-skips)).

## Gate records

`gates` and `check` build a gate record with one function. For each directory, in the tree at hand: `plan-pass.sh scope` lists the clone scope the plan pass gated, the example's `.tf` files and those of every local module directory it reaches, and `plan-pass.sh gates <run-dir> laptop clone <dir>` runs the per-file gates G0 to G3 over that list, with the directory as the example root, as the pass gives it, since the event bus rule of [plan-pass.md](plan-pass.md#data-sources-and-provider-flags) checks the module calls of the example root. Both are the plan pass's own functions, so the record holds the same scope and the same per-file hits the pass computed. The pass's gates before `init` also read the lock files the head committed in the scope (`committed_locks`); the record leaves them out, since that function runs only inside the pass. A lock file hit therefore never matches the record: as a first hit it gives `hit-set-differs`, and a lock file cannot differ between head and base without a changed file the allow-list refuses. plan-pass.sh reads the tree through a run directory of its own under the script's temporary directory, whose `clone` is a link to the tree, so a local module source in the base tree resolves inside the base tree.

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

For a `.tf` file the facts engine's `changes` report decides, read with the HCL parser from the head file in the clone and the base it rebuilds from the files list ([The facts engine](#the-facts-engine)):

1. The report lists the file as modified and parsed. A `.tf.json`, override or linked file, a file that does not parse or is over a parser limit, one with two top-level blocks of one address, and one the files list gives no patch for are not parsed; a patch that does not apply to the head file gives no report at all.
2. Nothing changed outside the values of direct attributes of blocks present at both sides (`outside` false): no block added, removed, renamed or moved, and no comment or blank line between blocks changed.
3. At least one block changed, and each one is an edited `resource` or `data` block with two plain-name labels and no structural edit: its header, a comment or blank line inside it, a trailing comment, an attribute added, removed or moved, and every nested block, `lifecycle`, `connection`, `provisioner` and `dynamic` among them, fail.
4. Each changed attribute is not `count`, `for_each`, `provider` or `depends_on`.
5. Its value, at head and at base, is plain: numbers, strings whose interpolations are plain and with no template directive, `true`, `false`, `null`, references with attribute, index and splat steps, tuples, objects with name or string keys, a negative number, and calls of only `concat`, `compact`, `flatten`, `distinct`, `join`, `format`, `length`, `toset`, `tolist`, `tomap`, `element`, `keys` and `values`. Any operator, `?:`, `for`, `...`, parentheses, a heredoc, a reference rooted at `each`, `count` or `self`, and every other function, `try`, `can`, `lookup`, `coalesce`, `merge`, `file`, `templatefile` and `jsondecode` among them, fail.

Two changed attributes on adjacent lines are two changed attributes, each needing its own witness. Bytes are compared as read, so a carriage return or a re-indented line outside a value is a structural edit, while a non-ASCII character inside a value is a change of that value.

The changed attribute is then `{dir, address, attribute}`: the file's directory, `.` for the root; the block's address, `<type>.<name>` or `data.<type>.<name>`; and the attribute's name.

## The facts engine

The script runs `mtf-facts changes <clone> --diff <files.json> --json` ([the facts engine's README](https://github.com/modulestf/facts#changes)), which rebuilds the base from the files list and reads both sides with the HCL parser. It takes the first `mtf-facts` on `PATH` from an absolute entry, every link resolved, and refuses one inside the run directory or the clone. It runs it only when `version --json` lists the feature `cmd:changes` and changes report version 1, with a deadline of `SKIP_COVERAGE_FACTS_TIMEOUT` seconds, 120 unless set, and an output cap of 16 MiB. A missing or older binary, a failure, a late or oversized answer, or a report of another shape leaves no report: then no `.tf` file is allowed, so every skip is `change-not-allowed`, and no directory declares a data source type. The engine's own fixtures hold the parsing cases.

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

Every directory of `unplanned` appears once, in its order, in `covered` or in `uncovered`. `gate` is `G1`, `G2` or `G3` in laptop mode and `role` or `docker` in runner mode, or `design` in either mode for a [design skip](#design-skips), which carries `reason` in place of `path`. `path` is the file of the record's first hit, without its line, or in runner mode the first exception hit of the head gate record. `downloaded` is present, and true, only when that hit is in a downloaded module ([Downloaded hits](#downloaded-hits)); a consumer that does not show it may ignore it. `witnesses` holds one entry per changed attribute, the same for every covered directory. `base_sha` is null only for `--base unresolved` or a base commit the clone does not hold, and `covered` is then empty.

The reasons, a closed list: `not-sole-reason`, `wrong-gate-class`, `head-mismatch`, `files-incomplete`, `plan-record-unusable`, `denial-unproven`, `not-validated`, `change-not-allowed`, `attribute-referenced`, `dir-changed`, `merge-base-unresolved`, `base-not-denied`, `base-record-missing`, `hit-set-differs`, `witness-sensitive`, `no-witness`.

## Design skips

Some examples can never plan under a plan-only review role, whatever the change: a data source whose read the [session policy](plan-pass.md#credentials) denies by name, for one, or a data source whose host the runner's plan proxy refuses on purpose. `check` decides an example whose coverage reason is one of these classes, the closed list:

| Class | Reason token | Mode |
|-------|--------------|------|
| `environment (access-denied)` | `access-denied` | either |
| `environment (refused-host)` | `refused-host` | runner |

Every other class stays an unknown, `wrong-gate-class`, the transient ones above all: `timeout`, `output-cap`, `network` and `throttling` say something about this run, and `credentials`, `sandbox`, `registry` and `plugin` about the machine. `network` is not on the list, since the token also stands for a stalled connection; the runner writes `refused-host` in its place only when the hosts it refused are all on the closed list below. A laptop pass has no plan proxy, so `check --mode laptop` takes `refused-host` as `wrong-gate-class`. The needs of a Docker daemon and of a role in another account are [Recorded exceptions](#recorded-exceptions) already.

The class alone proves nothing: it is a substring match on the first diagnostic, and a value the head chose can hold the word. The plan pass therefore records its own evidence ([plan-pass.md](plan-pass.md#per-example)): a `denied: <address> ...` line, only when every diagnostic block from the first `Error:` line on has exactly the shape of an AWS SDK access denial (`api error AccessDenied:`, `AccessDeniedException:` or `UnauthorizedOperation:` in the SDK's response error form) on a data source read: its summary line, blank lines, one `with data....` line, one `on ... in data "<type>" "<name>":` line naming the same data source, and numbered snippet lines, nothing else. A `Warning:` header after the first error, crash text or any other line refuses, so a value whose line breaks a provider prints into a summary cannot close the real block or add a `with` line to it. The plan pass reads the text output, not `terraform plan -json`, whose structured diagnostics no value could shape: switching the pass to JSON would change how it reads every class, kept line and `Plan:` line. Then a merge base re-run of the example, as for a `code-error`, which prints `base: <class>` and, for such a denial at the base, `base-denied: <address> ...`. The runner drops a `base-denied` line from the head's own output; only its base re-run writes one.

For `refused-host` the evidence is the runner's own, never the head's output. The runner ends a plan whose provider keeps retrying a host its plan proxy refused ([Refused hosts](plan-runner/README.md#refused-hosts)). It writes `plan: environment (refused-host)` only when every host the proxy refused that plan, 1 to 20 of them, is on this closed list, each a whole name on port 443 in a region of a known AWS partition: `sso.<region>.<suffix>`, `identitystore.<region>.<suffix>` and `api.ecr-public.<region>.<suffix>`, the suffix `amazonaws.com`, `amazonaws.com.cn`, `c2s.ic.gov`, `sc2s.sgov.gov`, `cloud.adc-e.uk`, `csp.hci.ic.gov` or `amazonaws.eu`. Any other refused host, or a proxy log it cannot read, keeps `environment (network)`. Beside the class it writes `refused: <host> ...`, the hosts sorted in codepoint order, and the `validate:` line of the plan pass's `validate` phase, `terraform validate` of the head's example in a container with no network and no credentials, so the early end hides no type error: `validate: passed` or `validate: failed` when that container printed exactly one `validate:` line and it is one of the two, else `validate: not run`, as with no budget left. The merge base re-run writes `base: environment (refused-host)` and `base-refused: <host> ...` under the same rule. The runner drops each of these lines, and a `plan:` or `base:` line with that class, from a container's output; only the runner writes them.

A design skip is covered under the conditions of a gate skip with these differences, all or nothing:

- Condition 1: the reason is on the list, and the directory appears once in `unplanned` (else `not-sole-reason`).
- Condition 3: the directory's block of the plan record, laptop or runner as `--mode` says, has that class as its `plan:` class (else `plan-record-unusable`), and exactly one `denied:` line of one to 50 distinct data addresses (else `denial-unproven`). For `refused-host`: exactly one `refused:` line of one to 20 distinct hosts of the closed list, and each host read by a data block of its mapped type that a `.tf` file directly in the example directory declares, `aws_ssoadmin_instances` for `sso`, an `aws_identitystore_*` type for `identitystore` and `aws_ecrpublic_authorization_token` for `api.ecr-public` (else `denial-unproven`). The types are the report's `data_sources` for the directory, from parsed blocks, so a type named only in a comment or a heredoc is not declared; a directory the report does not give as `complete`, with a `.tf.json`, linked or unparsed file, declares none, and neither does a directory reached through a link. Then exactly one `validate:` line, `validate: passed` (else `not-validated`).
- Condition 4: the change passes the allow-list, and no changed attribute belongs to a `data` block (else `change-not-allowed`): a changed data source argument can change what the plan reads, and so what the role is denied. No expression of the module reads a changed attribute (else `attribute-referenced`): the report's `read` is `unread` for each. It reads the configuration files directly in the block's directory, since an address resolves only inside its module. A reference reads the attribute it names after the address, past one index or splat that selects instances of a block with `count` or `for_each`; an index with a literal string key names an attribute; the whole object, a `for` expression over it, and any other index or splat read every attribute. `tags_all` reads a changed `tags`, and `self.<name>` inside the block reads `<name>`. A `.tf.json`, override, linked or unparsed file in that directory makes the state `unknown`, which counts as a read. Comments and string text are no reads. A value that reaches no expression reaches no local, `count`, `for_each` or data source.
- Condition 5: no changed file lies under the directory or under its real directory, which the head gate record gives (else `dir-changed`).
- Condition 6: `--base` is a SHA (else `merge-base-unresolved`), and the block holds exactly one `base:` line, `base: environment (access-denied)`, and one `base-denied:` line equal to the `denied:` line (else `base-not-denied`): the example, planned at the merge base the same way, was denied the same reads. For `refused-host`: one `base: environment (refused-host)` line and one `base-refused:` line equal to the `refused:` line, the same hosts refused at the merge base (else `base-not-denied`). A base that planned, failed another way or was not available, and a second `base:` line, leave the skip an unknown.
- Conditions 7 to 9: there is no gate hit to compare at the base, so the base gate record is not read. The head gate record must hold the directory with its `done` line and no hit at all (else `hit-set-differs`): a gate or exception hit there means the pass would have recorded a gate or an exception, so the record does not match the clone.
- Condition 10: the witnesses are the same as for a gate skip, from planned examples only.

Conditions 4 and 5 keep the mapped data blocks and the example's provider block as they were: a data block or provider block outside the example directory is not an attribute the allow-list takes (`change-not-allowed`), and any change under the example directory is `dir-changed`, or `change-not-allowed` for a `.tf` file there. Conditions 3, 4 and 6 differ by directory here, unlike a gate skip's: a changed `data` attribute gives a design skip `change-not-allowed` beside a covered gate skip. The covered element is `{"dir": "...", "gate": "design", "reason": "<token>", "witnesses": [...]}`, with no `path`. A design skip may stand beside the gate skips of a laptop pass or the exceptions of a runner pass. Residue: the `denied:` line is evidence code running in the head's plan could still print, as any line of the plan record is ([plan-pass.md](plan-pass.md#saved-plans-and-addresses)). The base lines only show that the base was denied the same reads, never that the head had no other error. A `refused-host` plan was ended early, so it shows no error behind the refused hosts; `validate` stands in for the type errors, and a provider error the plan would have met later stays unseen at both sides. A change that only the refused example exercises has no witness and stays an unknown. A witness shows that each changed attribute was planned elsewhere, never the refused example's own plan-time checks, such as its preconditions or the values of its `count` and `for_each`; the cap at approve with nits is what stands for that gap.

## Recorded exceptions

A runner-mode plan pass does not plan an example whose provider block assumes a fixed role in another account, or that needs a Docker daemon, and records `exception: example assumes a role in another account` or `exception: needs a Docker daemon` instead of a gate hit ([plan-pass.md](plan-pass.md)). `check --mode runner` decides such an exception under the same conditions as a gate skip, all or nothing, with these differences:

- Condition 1: the reason is one of the two exceptions, kind `role` or `docker` (else `wrong-gate-class`, a gate skip included: runner mode covers no gate skip).
- Condition 3: the record is a runner record (`plan pass mode: runner`), read by the host's own `host example <n>:` lines as plan coverage reads it, and the directory's block has the exception as its `plan:` class (else `plan-record-unusable`). The runner record carries no hit lines for an exception, so the hits come from the gate records alone.
- Conditions 7 and 8: both gate records are built in runner mode, `plan-pass.sh gates <run-dir> runner clone <dir>`, which adds the exception hits `Xrole` and `Xdocker` to the gate hits, and the header is `skip-gates 1 <sha> runner`; a record of the other mode is `base-record-missing`.
- Condition 9: the head gate record has no gate hit at all, since any gate hit makes the pass record a gate, not an exception (else `wrong-gate-class`), and at least one exception hit, every one of the recorded kind (else `hit-set-differs`). An exception that only a committed lock file or a downloaded module gives is not in the gate records, so it is never covered.
- Witnesses: the addresses files are the runner's, `addresses-<n>.json` beside its record, `<n>` the host's own example index.

The covered element's `gate` is the kind, `role` or `docker`, and its `path` is the file of the first exception hit of the head gate record.

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
| A head file missing from the clone, a patch that does not apply to it, a file the engine does not parse, no usable facts engine | `change-not-allowed` |
| An addresses file missing, oversized, a link, not JSON, or without the matching `head_sha` or `example` | that example gives no witness |

## Limits

- The downloaded scope is never gated at the base; a downloaded hit is taken from the head record on the argument in [Downloaded hits](#downloaded-hits), and only for an unchanged directory with a clean clone scope.
- A hit keeps no line, so a second hit of the same gate in the same file that replaces one removed elsewhere in it would compare equal; the allow-list keeps such text out of an allowed change.
- The engine reads HCL syntax, not Terraform's semantics: a reference is matched by its address in the module's own files, never evaluated.
- Addresses and the sensitive bit come from the head's own plan, read back with `terraform show`: evidence the head could shape, as [plan-pass.md](plan-pass.md#saved-plans-and-addresses) says.
