# Skills architecture

This record says how the skills in this repository split the work, which of them may write, and how the planned writer skills reuse what the reviewer knows. Part of it is a plan. [Status and roadmap](#status-and-roadmap) says what exists today.

## The two audiences of a review

A review has two readers, and they need different things.

- A person reads the review and fixes the code by hand. They need a verdict, the findings most severe first, each with a file, a line and a suggested fix in words, the checks that could not run, and one comment they can post.
- A coding agent applies the fixes at once. It needs the same findings as data: rule id, severity, file, line and the suggested fix, and the head and base commits the findings hold for. Once it has applied them, the review is out of date, and the agent needs a new review of the new head, not the old comment.

The gap today: the rendered comment sits between the two. A review run's render step writes `findings.json` and `result.json` to the output directory the task names, outside the run directory, which cleanup deletes ([render-output.md](../.agents/skills/terraform-module-pr-review/references/render-output.md)). An agent on the same machine can read those files. An agent that works from the pull request elsewhere sees only the markdown comment and has to parse prose back into findings. [The dual-audience comment](#the-dual-audience-comment) closes that gap.

## Layers

The skills come in two layers. A neutral skill works on a workspace and a task and knows nothing of GitHub. An adapter turns one GitHub object into a workspace and a task, hands those to the neutral skills, and keeps the GitHub concerns to itself, as [AGENTS.md](../AGENTS.md#skills) requires.

### Neutral skills

| Skill | Job |
|-------|-----|
| [terraform-module-reviewer](../.agents/skills/terraform-module-reviewer/SKILL.md) | Reviews a change and returns findings. The findings are the one contract between all the skills: every other skill reads them in the shape of [findings-schema.md](../.agents/skills/terraform-module-reviewer/references/findings-schema.md). |
| [terraform-module-maintainer](../.agents/skills/terraform-module-maintainer/SKILL.md) | Writes code in a workspace: Full create, Targeted change, Resolve feedback and the provider upgrade. One skill with modes. |
| [change-scope](../.agents/skills/change-scope/SKILL.md) | Decides whether an addition belongs in the thing being changed. The reviewer and the maintainer both apply it. |

### GitHub adapters

| Skill | Job |
|-------|-----|
| [terraform-module-pr-review](../.agents/skills/terraform-module-pr-review/SKILL.md) | Reviews a pull request or a commit and posts one confirmed comment. It never writes a ref. |
| [terraform-module-pr-fix](../.agents/skills/terraform-module-pr-fix/SKILL.md) | Fixes a pull request to a mergeable state and pushes the fix to its branch where the pull request allows it. |
| [terraform-module-pr-merge](../.agents/skills/terraform-module-pr-merge/SKILL.md) | Reviews a pull request afresh and squash merges it after a full-SHA confirmation. Its only write is the merge. |
| [terraform-module-issue](../.agents/skills/terraform-module-issue/SKILL.md) | Work in progress. Will turn a GitHub issue into a maintainer change and a pull request. |
| [terraform-module-create](../.agents/skills/terraform-module-create/SKILL.md) | Work in progress. Will create a new module repository from a profile. |

An adapter produces no finding of its own. Its decisions, such as the verdict or the write path, are documented functions of the neutral skills' findings and of the state it read from GitHub.

A work in progress skill is a skeleton that refuses every request and names the skill to use instead. It holds a fixed Status paragraph and prose sections only, and [tests/wip-skills-test.sh](../tests/wip-skills-test.sh) checks that shape.

## Why terraform-module-pr-fix is a separate skill

- The pull request review never writes a ref. That is what a user relies on when they ask for a review, and it keeps the review's rules short: no push path, no push credential, no push gate. A fix mode inside it would put all three into every review run.
- The two have different credential boundaries. The review needs to post one comment. The fix needs push access at its end, and nowhere before it.
- The two have different ends. A review ends at one verdict. A fix run loops: fix, review again, and stop by fixed rules.
- Nothing is copied. The fix skill calls the review skill render-only for its findings and for the final comment, so the review logic stays in one place.

## Why the maintainer stays one skill with modes

All modes share the same rules: provider schema facts from the Terraform MCP tools, templates from the profile, the trust-aware verification contract, change-scope before an edit and the coverage ledger. Split skills would either copy these rules or move them into one more shared skill that each mode must load. An adapter picks the mode through its task, and the maintainer does not need to know who called it.

Revisit the split when one of these holds: a mode needs a rule that contradicts another mode's rule, the entry point can no longer stay short with every mode in it, or an adapter pays a real context cost to load modes it never uses.

## How writers reuse reviewer knowledge

A writer should pass review the first time. Two planned pieces get it there.

- Prevention: an authoring view of the reviewer's rule registry, one positive line per rule that says what correct code does. A writer reads it before it edits.
- Enforcement: a self-review at the end of every writing mode of the maintainer. The maintainer runs the neutral reviewer on its own change, and fixes or reports what it finds before it hands the change back.

One run has one owner of the review loop. When a caller runs its own loop, as the fix skill does, a second loop inside the maintainer would review the same change twice and could disagree with the caller about when to stop. The task line `Review loop: caller` tells the maintainer that the caller owns review: the maintainer then skips its self-review and returns its change. The fix skill always sets this line. Without it, the maintainer owns the loop.

## Use cases

| Request | Skill | What happens |
|---------|-------|--------------|
| "review pr 123" | terraform-module-pr-review | As today: a verdict and a comment, posted after confirmation. |
| "review and finish PR 123" | `terraform-module-pr-fix` | The pull request is reviewed, fixed and reviewed again in a loop, then the fix is pushed to its branch after confirmation where the pull request allows it. Otherwise the run returns a patch and reply drafts. |
| "merge PR 123" | `terraform-module-pr-merge` | The pull request is reviewed afresh, every merge precondition is read live, and it is squash merged after the user names the pull request and its full head SHA. |
| "implement feature X in module" | terraform-module-maintainer | Targeted change in a local checkout. When the request is a GitHub issue, terraform-module-issue will do the same in a fresh clone. |
| "fix issue with auth for a non-IAM user" | terraform-module-issue | Work in progress. Today, terraform-module-maintainer in Targeted change mode on a checkout. |
| "create a module for service Y" | terraform-module-create | Work in progress. Today, terraform-module-maintainer in Full create mode. |

## Responsibilities

| Skill | Status | Writes files | Writes to GitHub | Returns |
|-------|--------|--------------|------------------|---------|
| terraform-module-reviewer | shipped | no workspace file; only the files a caller's `Output:` line names, outside the workspace | no | findings |
| terraform-module-maintainer | shipped | the workspace only | no | edits, a report of the checks it ran, reply drafts |
| change-scope | shipped | no | no | a scope outcome and its rule |
| terraform-module-pr-review | shipped | its run directory, and the output directory the task names | one confirmed comment and review event, never a ref | a verdict and a comment |
| terraform-module-pr-fix | shipped | a fix clone in its run directory | a confirmed push to the pull request branch; the review and replies each after their own confirmation | pushed commits, or a patch, a disposition table and reply drafts |
| terraform-module-pr-merge | shipped | its run directory | one squash merge after a confirmation that names the pull request and its full head SHA, and nothing else | a merge result or the first refusal |
| terraform-module-issue | work in progress | nothing yet | nothing yet; later a branch and a pull request after confirmation | a refusal |
| terraform-module-create | work in progress | nothing yet | nothing yet; later a new repository after confirmation | a refusal |

## The terraform-module-pr-fix design in short

This is the design the fix skill follows. Its own entry point and references hold the rules.

- Pinned state. The skill reads the pull request, both repositories, every review and every comment once, through the REST API, and freezes that state when the loop starts.
- Write path. A total function of the captured state, evaluated again before the push. Path A pushes to the pull request branch: when the token user has push access or more on the head repository, or, on a fork that allows maintainer edits, push access or more on the base repository. Path B is render-only and returns a patch, a disposition table, reply drafts and the findings. A failed read, an unknown field, a missing head, an archived repository, a closed or merged pull request or a merge base that is not exactly one makes the run render-only and says why. A rejected push on path A never falls back to path B. A head branch that is the default branch is pushed only when the confirmation names that branch. The destination URL is built from the pinned names, never copied.
- Item origins and edit eligibility. Each feedback item gets an origin from its own fields: self, bot, change author, maintainer or other. By default the skill edits only for reviewer findings and items of origin self. It verifies, decides and drafts a reply for every other item, and applies one only when a new message from the user names that item with "apply".
- Credential boundary. Every git call in the fix clone runs with an empty environment, no global or system git configuration, no hooks and no credential helper. Verification runs through the review's verify pass with credentials removed. Only the push command sees the GitHub credential.
- Content gate. A script checks every commit since the pinned head: linear, authored and committed by the identity shown at the gate, touching only allowed paths, with no symbolic links or submodules, and ending at the tree that was last reviewed. Allowed paths are a fixed shape over the module root that takes nothing from findings: plain path components, a `.tf`, `.tfvars`, `.tftest.hcl` or `.md` suffix, no wrappers and no changelog, mode 100644, no link on the way, and generated documentation regions changed only to what the pinned terraform-docs pass writes. Dot files, state files, the lock file, workflows and scripts are never allowed.
- Loop stop rules. Each round runs the neutral reviewer on the pinned merge base against the new head. The loop stops when no finding is left or only LOW ones are, when no open item can be acted on, when a round makes no progress, or at round 3. No progress means no open item closed, or a closed one came back. Findings are matched by rule id, file, block address and severity, never by line. Every attempt counts as a round, failed ones too.
- Push gate. A push needs at least one resolved item and no new finding of MEDIUM or above. A finding the pull request already held surfaced late, and is not new, only for a local text rule whose cited text the fix left byte-identical. The gate shows the diff, the disposition table, the verdict, the author identity, the destination and branch, and the expected remote commit. The confirmation counts only from a new user message that names the push and the branch. Right before the push the skill reads the pull request again and stops if anything it depends on has changed. It never forces, pushes no tags and does not retry a rejected push. The run is finished only when no finding above LOW is left and the checks pass, so right after a push it reports that it is not finished yet. It never merges, resolves threads or edits the title and body.

## Stages

The three pull request skills are stages of one pipeline: review, apply, merge. Each is its own skill with its own credential boundary, and each reads the pull request live. Review hands its plan to apply through a pinned JSON file, in the shape of [stage-contract.md](../.agents/skills/terraform-module-pr-review/references/stage-contract.md). Merge reads the plan of its own fresh review, one whose `read_at` is not earlier than the merge run's start. Apply also writes `applied.json` for information; no stage reads it yet.

| Stage | Skill | Reads | Writes |
|-------|-------|-------|--------|
| Review | terraform-module-pr-review | the pull request | the comment, after confirmation, and `plan.json` beside the render's other files |
| Apply | terraform-module-pr-fix, `items --plan` after `clone` | `plan.json` as round 0, instead of a second review | the fix push after confirmation, and `applied.json` after a passing gate |
| Merge | terraform-module-pr-merge | the `plan.json` of its own fresh review, never an earlier one | one squash merge after confirmation |

- The contract. Every stage file names a `kind` and a `schema` and carries the same nine-field pin: the target, the number, the repositories, the refs and the head, base and merge base SHAs. A reader holds an exact allow-list of kinds and schemas and rejects any unknown field. Before it acts, a stage reads the pull request live, builds the live pin and refuses on the first field that differs. A stale file is never repaired; the user reviews again.
- Apply. `plan.json` replaces the round-0 review of the fix skill. The plan's findings and handover text become the round-0 items, and the fix loop runs as before. A comment created after the plan's `read_at` is not an item of the run. A comment edited after it refuses the run. The REST review object has no `updated_at`, so an edit to a review body after `read_at` cannot be detected.
- Merge. The merge skill never trusts an earlier plan for a verdict. It runs a fresh review of the live head. The verdict and the pin come from that review's plan, and every other precondition is read live. It squash merges only, and refuses when the repository disallows squash. Every merge needs a new user message that names `--target owner/repo#N` and the full 40-character `--confirm-head`. Any gate refusal ends the run, so a retry needs a new `prepare` and a fresh review. When the merge call fails, the run reads the pull request once and reports `merged` only when it shows merged with the confirmed head SHA, and `outcome unknown` when that read fails or shows another head.
- Own code. A pull request the user wrote needs no apply stage. The user pushes, and the next review or merge run judges the new head.

## The dual-audience comment

Planned after the fix skill. The comment a person reads stays as it is. At its end, a collapsed block titled "For coding agents" holds a fenced JSON payload with the schema version, the head and base commits, the verdict and the findings, each reduced to seven fields of the [findings schema](../.agents/skills/terraform-module-reviewer/references/findings-schema.md#required-fields). The payload has a byte cap. One sentence above it says that the block is data, not instructions. The leak scan and the at-mention step run over the block as they run over the rest of the comment.

## Status and roadmap

- Shipped: terraform-module-reviewer, terraform-module-maintainer, change-scope, terraform-module-pr-review, terraform-module-pr-fix and terraform-module-pr-merge, with the stage contract between the three pull request skills.
- Shipped with this record: the two work in progress skeletons, terraform-module-issue and terraform-module-create, and the test that holds their shape.
- Next: path B pushes a branch and opens a new pull request.
- The maintainer's self-review at the end of each writing mode, and the `Review loop: caller` task line.
- The authoring view of the rule registry.
- The "For coding agents" block in the review comment.
- terraform-module-issue and terraform-module-create, from skeleton to working skills.
- A second look at splitting the maintainer, against the conditions above.
