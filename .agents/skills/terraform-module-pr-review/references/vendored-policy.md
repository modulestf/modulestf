# Vendored Policy

> **Part of:** [terraform-module-pr-review](../SKILL.md)
> **Purpose:** The host's comparison of a policy document a module copies from a workload's published IAM policy with that policy at a release tag, which `review-run.sh handover` hands the reviewer as `Vendored policy:` lines.

## What It Answers

Some modules ship an IAM policy document copied from a workload's own published policy, such as a Kubernetes controller's or a storage driver's. Pull requests sync the copy to a new upstream release and say it "matches upstream". The reviewer cannot read the upstream file: it either takes the claim unchecked or refuses to judge a narrowing and ends inconclusive. [vendored-policy.sh](vendored-policy.sh) reads the upstream file on the host instead, at a commit it resolves and records, and states the differences as facts.

## Profile Entries

The module profile's `vendored-policies.txt` lists the sources. The file is read from the skill's own checkout, never from the change, so a pull request that edits the list gets no evidence from its edit. A file that is a link, over 64 KiB or with any line outside this grammar gives no evidence at all.

- `entry <module repository> <file> <data block name> <upstream repository> <upstream file>`: the `data "aws_iam_policy_document"` block of that name in that repository-relative `.tf` file is a copy of the upstream file, a JSON policy document.
- `subst <expression> <value>`: an expression the documents use, read as the value the upstream file writes, such as `local.partition` as `aws`.
- A blank line or a line that starts with `#` is a comment.

Add an entry only for a file path confirmed in both repositories.

## Steps

For each entry of the base repository whose file the change touches:

1. Read the file at the head and at the merge base from the clone's git objects, in the form of the reviewer's [git-safety.md](../../terraform-module-reviewer/references/git-safety.md), with `ls-tree` and `cat-file` only. A partial clone, a link, a file over 1 MiB or a read that fails gives no evidence.
2. Read the block statically with [policy-hcl.pl](policy-hcl.pl). It evaluates nothing: a string, a list of strings, `true`, `false` and the profile's expressions are read; any other expression, a function, a template directive, a heredoc, or a `dynamic` block inside a statement gives no evidence for the whole document. A block the change leaves as it was gets no line.
3. Take the release tag: the one `v<x.y.z>` the pull request body or the head file names in a GitHub address of the upstream repository (`/releases/tag/`, `/blob/` or `/tree/`). No tag, two tags, or a tag older than the newest one the base file names gives no evidence. There is no latest fallback.
4. Resolve the tag to its commit with `gh api repos/<upstream>/git/ref/tags/<tag>`, and an annotated tag through `git/tags/<sha>`, then read the upstream file at that commit with `gh api repos/<upstream>/contents/<file>?ref=<commit>`, each with the time limit of [Allowed Commands](github-io.md#allowed-commands). A tag not found or a failed read gives no evidence.
5. Normalize each statement of the head, the base and the upstream file into one tuple per action and resource: effect, action or `NotAction`, resource or `NotResource`, then the principals and the conditions (operator, key and values), each sorted. Action names and condition keys compare in lower case. Compute the head against upstream and the head against the base.

Nothing fetched or read runs. A statement in a `dynamic` block that the change leaves as it was, and the documents the block merges through `source_policy_documents` or `override_policy_documents`, are left out of the comparison and named on a `not compared` line; a change to either gives no evidence.

## Output

One line per fact, `<file> <document> <fact>`, `<file>` module-relative, in profile order:

| Fact | Meaning |
|------|---------|
| `source <upstream> <tag> <commit> <file>` | The reference: the upstream file at the commit the tag resolved to |
| `lines <first> <last>` | The block's lines in the head file |
| `upstream equal` | Every head tuple is upstream and every upstream tuple is in the head |
| `upstream differs <n> extra <m> missing` | Then one `extra <tuple>` line per head tuple upstream lacks, and one `missing <tuple>` line per upstream tuple the head lacks, at most 40 each and an `and <n> more` line |
| `base equal`, `base absent`, `base differs <n> added <m> removed` | The same against the base, with `added` and `removed` lines |
| `not compared <n> dynamic statements`, `not compared merged documents` | What the comparison left out |
| `unknown <reason>` | No evidence for the document, and its only line |

`review-run.sh handover` states each line as `Vendored policy: <line>` in the skill's own task text, outside a triage run and for a change with a base, only when every line is in that grammar and there are at most 400; otherwise it states none. The reviewer's [Host Vendored Policy Evidence](../../terraform-module-reviewer/references/check-a-compatibility.md#host-vendored-policy-evidence) says what each fact means for Check A. A failed step is no evidence, and the run goes on as before.

## The LOW Band

`handover` records the documents it found equal to upstream in `state/vendored-equal.json`. `render` raises a LOW `compat.generated-policy-narrowed` finding to HIGH unless its `line` falls inside such a document's lines in its `file`, as the rule's LOW band says. The reviewer's judgment variant leaves the evidence section out of its prefix for its size cap, so such a run keeps the rules it had: at worst it ends inconclusive.
