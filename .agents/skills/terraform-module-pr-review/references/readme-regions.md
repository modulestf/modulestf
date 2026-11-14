# README Regions

> **Part of:** [terraform-module-pr-review](../SKILL.md)
> **Purpose:** The host's terraform-docs evidence for each `README.md` a change touches, which `review-run.sh handover` hands the reviewer as `README regions:` lines.

## What It Answers

A pull request that regenerates a README table, often after a terraform-docs version bump, leaves the reviewer unable to tell a regenerated region from a hand edit: the reviewer never runs the generator. [readme-regions.sh](readme-regions.sh) runs it on the host instead. It runs the maintainer's [terraform-docs-pass.sh](../../terraform-module-maintainer/references/terraform-docs-pass.sh), the procedure of [The Documentation Region](../../terraform-module-maintainer/references/quality-gates.md#the-documentation-region), with the version, address, hash and configuration the profile pins, and compares what it writes with the head's bytes.

## Steps

1. Take each path of the files list under the module root prefix that is a `README.md`, at most 256, in path order.
2. Read the head's entry of each from the clone's git objects, in the form of the reviewer's [git-safety.md](../../terraform-module-reviewer/references/git-safety.md), with `ls-tree` and `cat-file` only. A file the head deletes, or one with no marker of the profile's two terraform-docs pairs, gets no line.
3. Copy the head's entries of that directory into a work directory outside the clone: each regular `.tf` file and the `README.md` with their bytes, every other entry by name and type only, and the names of each directory above it up to the module root. The pass then refuses what it would refuse in a checkout, such as a link, an OpenTofu file or a terraform-docs configuration.
4. Run the pass once on the work directory, with every such `README.md` as an entry. The pass runs only its pinned, hash-checked binary. Nothing from the clone runs, and the clone is never written.
5. Give each `README.md` its result.

## Results

| Result | When |
|--------|------|
| `generated` | The pass regenerated the directory and the new `README.md` equals the head's byte for byte. |
| `differs` | The pass regenerated the directory, the bytes differ, and the head's `.github/workflows/pre-commit.yml` pins the profile's terraform-docs version. |
| `unknown version mismatch` | As `differs`, but that workflow pins another version: the difference may be that version's output, which the host does not run. |
| `unknown no version pin` | As `differs`, but the head has no such workflow or it pins no version: the host cannot tell which version wrote the region. |
| `unknown version unreadable` | As `differs`, but the workflow's pin is not a plain version. |
| `unknown <reason>` | Any other refusal: the pass's own stale reason in lower case, or the host's (`link`, `not a regular file`, `file over 1 mib`, `not a documentation region`, `partial clone`, `read failed`, `pass failed`). |

`review-run.sh handover` states each line as `README regions: <path> <result>` in the skill's own task text, outside a triage run, only when every line of the file is in that grammar; otherwise it states none. The reviewer's [Host README Evidence](../../terraform-module-reviewer/references/check-e-profile.md#host-readme-evidence) says what each result means for Check E. A failed step is no evidence, and the run goes on as before.
