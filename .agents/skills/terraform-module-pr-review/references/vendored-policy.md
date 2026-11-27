# Vendored Policy

> **Part of:** [terraform-module-pr-review](../SKILL.md)
> **Purpose:** The host's comparison of a policy document a module copies from a workload's published IAM policy with that policy at a release tag, which `review-run.sh handover` hands the reviewer as `Vendored policy:` lines.

## What It Answers

Some modules ship an IAM policy document copied from a workload's own published policy, such as a Kubernetes controller's or a storage driver's. Pull requests sync the copy to a new upstream release and say it "matches upstream". The reviewer cannot read the upstream file: it either takes the claim unchecked or refuses to judge a narrowing and ends inconclusive. [vendored-policy.sh](vendored-policy.sh) reads the upstream file on the host instead, at a commit it resolves and records, reads the module's document and the policies that use it with the facts engine, and states the differences as facts.

## Profile Entries

The module profile's `vendored-policies.txt` lists the sources. The file is read from the skill's own checkout, never from the change, so a pull request that edits the list gets no evidence from its edit. A file that is a link, over 64 KiB or with any line outside this grammar gives no evidence at all.

- `entry <module repository> <file> <data block name> <upstream repository> <upstream file>`: the `data "aws_iam_policy_document"` block of that name in that repository-relative `.tf` file is a copy of the upstream file, a JSON policy document.
- `subst <expression> <value>`: an expression the documents use, read as the value the upstream file writes, such as `local.partition` as `aws`. The value is assumed, never read from the change.
- A blank line or a line that starts with `#` is a comment.

Add an entry only for a file path confirmed in both repositories.

## Steps

For each entry of the base repository whose file the change touches, every step with the 30 second limit of [Allowed Commands](github-io.md#allowed-commands):

1. Read the file at the head and at the merge base from the clone's git objects, in the form of the reviewer's [git-safety.md](../../terraform-module-reviewer/references/git-safety.md), with `ls-tree` and `cat-file` only. A partial clone, a link, a file over 1 MiB or a read that fails gives no evidence.
2. Read the block and its wiring with the facts engine: `mtf-facts iam-policy-docs` on the module root's files at the head, with `--base` on the same files at the merge base, under the 30 second limit and a 16 MiB output cap. The engine parses the files with the HCL parser Terraform uses and evaluates nothing ([its command reference](https://github.com/modulestf/facts/blob/master/docs/commands.md#iam-policy-docs)). The step runs only with an `mtf-facts` that [facts-resolve.sh](facts-resolve.sh) finds outside the clone and the run directory and whose version report lists `cmd:iam-policy-docs`; with none, every touched entry gets `unknown no facts engine`. The files come from the clone's git objects, never its work tree: every configuration, variables and lock file of the module root (`*.tf`, `*.tf.json`, `*.tofu`, `*.tofu.json`, `*.tfvars`, `*.tfvars.json`, `.terraform.lock.hcl`), at most 4 MiB each, 4000 and 64 MiB in all, each path plain ASCII with no `.` or `..` segment, and no two paths alike in letter case. A link is written as a link to nowhere and a submodule as an empty directory, so the engine refuses each as Terraform would not read it. The whole report must be one document of schema version 1. A directory the engine refuses (a parse error, an override, JSON or OpenTofu file, a link), a second block of the name, and content it cannot read as literal text (a `dynamic` block, `source_policy_documents` or `override_policy_documents`, a function, a variable, a conditional, a template directive) give no evidence for the whole document. A reference inside a string reads as the profile's value for it; any other reference gives `unknown unevaluated expression`. A block the engine reads at both sides with the same content and gate gets no line; a block it cannot read gets its `unknown` line whenever its file is touched.
3. Check the wiring from the same report, as the engine traces it through locals, merges and module calls: at least one `aws_iam_policy`, `aws_iam_role_policy`, `aws_iam_user_policy` or `aws_iam_group_policy` must take the document as its `policy` argument. A comment, a string, an output, a dot file Terraform ignores or any other place does not count, and uses the engine cannot trace (a conditional, an index, a function outside the ones it follows) give no evidence. Through a merge the document must have no `sid`, since a statement of the same `sid` in the merging document or its overrides would replace one of its own. With a base document, the engine's comparison precondition must hold (no variables file, no undecidable directory, the same provider blocks and lock files), the engine must find the uses equal at both sides, which takes in the text of every block on the way and every definition those blocks read, gates included, and the document's own `count` or `for_each` must read the same. A new document, or a run with no merge base, has nothing to compare: the document must have no `count` or `for_each`, and a policy must read it directly, with no gate, in every instance. Anything else gives no evidence.
4. Take the release tag: the one `v<x.y.z>` the pull request body or the head file names in a GitHub address of the upstream repository (`/releases/tag/`, `/blob/` or `/tree/`). The body is the pull request's own body item, never a comment. No tag, two tags, or a tag older than the newest one the base file names gives no evidence. A tag is evidence only when it is newer than the newest tag the base file names, or, failing that, when it is the upstream's latest release now (`gh api repos/<upstream>/releases/latest`). There is no latest fallback: the tag is always the one the change names. Two limits stay: `releases/latest` is whatever the upstream marks as latest, which can briefly be a patch release on an older line, and a stale tag in a base file comment sets the floor at that tag.
5. Resolve the tag to its commit with `gh api repos/<upstream>/git/ref/tags/<tag>`, and an annotated tag through `git/tags/<sha>`, then read the upstream file at that commit with `gh api repos/<upstream>/contents/<file>?ref=<commit>`. A tag not found or a failed read gives no evidence.
6. Normalize each statement of the head, the base and the upstream file into one tuple per action and resource: effect, action, resource, principals and conditions (operator, key and values). A tuple is a JSON array and is compared as one, never as joined text. A `NotAction`, `NotResource` or `NotPrincipal` list stays one sorted list, as it is one exclusion set. Action names compare in lower case; condition keys and values, resources and principals compare as written. Compute the head against upstream and the head against the base.

Nothing fetched or read runs. A host that selects the reviewer's judgment variant ([facts-variant.md](facts-variant.md)) gets no lines, since that variant's prefix leaves the reviewer's evidence section out for its size cap: such a run keeps the rules it had, and at worst ends inconclusive.

## Output

One line per fact, `<file> <document> <fact>`, `<file>` module-relative, in profile order:

| Fact | Meaning |
|------|---------|
| `source <upstream> <tag> <commit> <file>` | The reference: the upstream file at the commit the tag resolved to |
| `lines <first> <last>` | The block's lines in the head file |
| `upstream equal` | Every head tuple is upstream and every upstream tuple is in the head |
| `upstream differs <n> extra <m> missing` | Then one `extra <tuple>` line per head tuple upstream lacks, and one `missing <tuple>` line per upstream tuple the head lacks |
| `base equal`, `base absent`, `base differs <n> added <m> removed` | The same against the base, with `added` and `removed` lines; no `base` line when the run had no merge base |
| `widened <tuple>` | An `Allow` tuple the change adds that upstream lacks, or a `Deny` tuple the change removes that upstream keeps |
| `carried <tuple>` | An `Allow` tuple upstream lacks that the base already had |
| `unknown <reason>` | No evidence for the document, and its only line |

Each kind of tuple line takes at most 40 lines and an `and <n> more` line. A tuple's text is the effect, then `action:` or `notaction:`, `resource:` or `notresource:`, and `principal:`, `notprincipal:` and `condition:` when set, a list written as JSON.

`review-run.sh handover` states each line as `Vendored policy: <line>` in the skill's own task text, outside a triage run and for a change with a base, only when every line is in that grammar and there are at most 400; otherwise it states none. The reviewer's [Host Vendored Policy Evidence](../../terraform-module-reviewer/references/check-a-compatibility.md#host-vendored-policy-evidence) says what each fact means for Check A. A failed step is no evidence, and the run goes on as before.

## The LOW Band

`handover` records the documents it found equal to upstream in `state/vendored-equal.json`. `render` raises a LOW `compat.generated-policy-narrowed` finding to HIGH unless its `line` falls inside such a document's lines in its `file`, as the rule's LOW band says. The reviewer's own `findings-check.sh` refuses that LOW unless `--vendored-equal` counts an `upstream equal` line of the task, so a run with no host reference, such as a local review, never returns it.
