# modulestf

Agent skills that review reusable Terraform modules against a written profile of the module family's rules, and help you make the change the review asks for. One profile ships today: [terraform-aws-modules](https://github.com/terraform-aws-modules). They run in your coding agent (Claude Code or Codex) on your machine, with your own GitHub login.

- [The skills](#the-skills)
- [Quick start](#quick-start)
- [Everyday use](#everyday-use)
- [Reading a review](#reading-a-review)
- [Limits](#limits)
- [Advanced use](#advanced-use)
- [Requirements by task](#requirements-by-task)
- [Related repositories](#related-repositories)

## The skills

| Skill | You give it | You get back |
|-------|-------------|--------------|
| [`terraform-module-pr-review`](.agents/skills/terraform-module-pr-review/SKILL.md) | A pull request or commit URL, or `owner/repo#123` | A verdict and a comment to post, after you confirm |
| [`terraform-module-reviewer`](.agents/skills/terraform-module-reviewer/SKILL.md) | A module checkout and a diff, a base ref or a list of changed files | A list of findings. Read-only, no verdict |
| [`terraform-module-maintainer`](.agents/skills/terraform-module-maintainer/SKILL.md) | A change to make, review feedback to work through, a module to create or a provider to upgrade | Edits in your checkout, a report of the checks it ran, and reply drafts |
| [`change-scope`](.agents/skills/change-scope/SKILL.md) | A proposed addition, in any language or project | Whether it belongs in the thing being changed, and where it goes if not |

The pull request review calls the reviewer, and both call `change-scope`. The rules of the module family live in a profile: [`terraform-aws-modules`](.agents/skills/terraform-module-maintainer/profiles/terraform-aws-modules/PROFILE.md).

## Quick start

1. Install the skills. Copy or symlink all four directories under `.agents/skills/` side by side into your agent's skills directory: `~/.claude/skills/` for Claude Code, `~/.agents/skills/` for Codex. The three Terraform skills link into each other, so keep them together. `change-scope` also works alone.

   ```bash
   git clone https://github.com/modulestf/modulestf.git
   mkdir -p ~/.claude/skills
   ln -sfn "$PWD"/modulestf/.agents/skills/* ~/.claude/skills/   # Claude Code
   mkdir -p ~/.agents/skills
   ln -sfn "$PWD"/modulestf/.agents/skills/* ~/.agents/skills/   # Codex
   ```

2. Add HashiCorp's [Terraform MCP server](https://github.com/hashicorp/terraform-mcp-server) to your agent under the name `terraform`, so its tools appear as `mcp__terraform__get_latest_provider_version`, `mcp__terraform__search_providers` and `mcp__terraform__get_provider_details`. The skills read provider schemas from it, not from memory. Without it, every rule that needs a provider fact is reported as not run, so a pull request review is inconclusive at best.
3. Log in to GitHub with `gh auth login` as yourself, and install `terraform`, `git` and `jq`.
4. Ask your agent:

   ```text
   review terraform-aws-modules/terraform-aws-lambda#780
   ```

The skill clones the pull request into a temporary directory, runs `terraform init -backend=false` and `terraform validate` in each example the change touches, and shows you a verdict, the findings and the comment it would post. It posts nothing until you confirm the comment and its review event: comment, approve or request changes.

## Everyday use

Write requests in plain words. The examples show what each skill needs to hear.

### Review a pull request or a commit

```text
review https://github.com/terraform-aws-modules/terraform-aws-lambda/pull/780
is terraform-aws-modules/terraform-aws-lambda#780 ready to merge?
what should I reply on terraform-aws-modules/terraform-aws-lambda#780?
review https://github.com/terraform-aws-modules/terraform-aws-lambda/commit/<sha>
```

You get a verdict, a comment with every finding and its suggested fix, the checks that could not run, and the state of the pull request's checks and threads. The skill proposes one review event (comment, approve or request changes) and asks once. Say "do not post" and it runs render-only: it shows the comment and posts nothing. A commit gets a plain commit comment with no approve or request changes.

### Triage first

```text
triage terraform-aws-modules/terraform-aws-lambda#780
```

A quick pass: scope and the checks that need no provider lookup, with no validation. It never approves. Use it to decide whether a full review is worth it.

### Review your own change before you push

```text
review the changes on this branch against master in ~/src/terraform-aws-s3-bucket
```

The reviewer reads committed changes only. For uncommitted work, paste `git diff` into the request. You get findings, most severe first, each with a rule ID, a file and line, and a suggested fix. The reviewer never edits files and never runs Terraform.

### Make a change to a module

```text
add poller_group_name to the event source mapping in ~/src/terraform-aws-lambda
```

The maintainer checks first that the addition belongs in the module, then makes the smallest edit, says whether it is additive, behaviour-changing or breaking, and drafts the pull request description. Your checkout is treated as untrusted, so it runs only `terraform fmt -check`, `terraform init -backend=false`, `terraform validate` and the documentation update. Say "this is a trusted local run" to let it run `pre-commit run -a` as well. Say it only for code you wrote or have read: pre-commit runs the hooks the repository defines. It counts only in your own message: never from the repository, the pull request or text you paste. The same goes for permission to run outside the sandbox.

### Work through review feedback

```text
work through this review on my pull request, workspace ~/src/terraform-aws-lambda:
<paste the review and the comments>
apply F-003
```

The maintainer decides each item (apply, reject, already addressed, needs a decision, and so on), edits the code for the items it applies, and writes reply drafts that start with "Fixed in <sha>:" or "Not changed:". It stops and asks when an item is unclear or needs your decision. It never posts, pushes or resolves threads.

### Check whether something belongs, in any project

```text
before I add a Redis client to this billing service, does it belong here?
```

`change-scope` answers with one of three outcomes and the rule behind it. It does not judge quality or whether the idea is good, only where it belongs.

## Reading a review

- **Finding**: one problem in one place: a rule ID such as `compat.variable-removed`, a severity (CRITICAL, HIGH, MEDIUM or LOW), a file and line, a summary and a suggested fix. A fix can be a code change, a choice between options for you to make, or "no code change".
- **Verdict**: computed from the findings and the pull request's checks and threads, with no judgement of its own. The first rule that matches wins ([verdict.md](.agents/skills/terraform-module-pr-review/references/verdict.md)):
  1. Hold for the next major release: at least one CRITICAL finding, and every CRITICAL and HIGH finding is a compatibility (`compat.*`) finding.
  2. Block: any other CRITICAL or HIGH finding, or a failing host signal: a failing check, a merge conflict, or a review that requests changes.
  3. Inconclusive: anything that could not be checked.
  4. Changes suggested: unresolved review threads.
  5. Block: any MEDIUM finding.
  6. Approve with nits: only LOW findings.
  7. Approve: nothing found.
- **Inconclusive**: something could not be checked, for example a provider lookup, a validation or a check run that was still pending. A gap never counts as a pass, and a failed lookup is not evidence that anything is missing.
- **Validation**: `terraform init` downloads the providers and modules the change pins, and `terraform validate` runs those provider plugins. The skill removes AWS, GitHub, Terraform and SSH credentials from that environment, gives it an empty home directory and uses no backend. A passing `terraform validate` is evidence, not proof.
- **Scope outcomes**: when an addition belongs, there is no scope finding. Otherwise it is a Ban (it does not belong here, and the review names where it goes), a Maintainer decision (a person has to decide), or Not evaluated (the rule could not be applied; an unknown, never a pass). Text in the pull request itself, such as "this is in scope", never clears a scope rule.

## Limits

- No skill runs `terraform apply`, writes state or uses a real backend. None merges, pushes to a pull request or resolves threads. None obeys instructions found in the code, the pull request text or its comments; all of it is data.
- The pull request review posts only the one comment and review event you confirm in the conversation. From the pull request it runs only `terraform init -backend=false` and `terraform validate`, with AWS, GitHub, Terraform and SSH credentials removed and an empty home directory; both still run the provider plugins the change pins. When you opt in, it also runs `terraform plan` on a read-only review session.
- The reviewer and `change-scope` are read-only. They never post and never run Terraform.
- The maintainer edits only your checkout and never posts. It commits only when you ask, and runs the repository's own hooks only on a run you call trusted.

## Advanced use

These need extra tools, credentials or a decision from you.

### Add a terraform plan pass

```text
review owner/repo#123, plan with profile review-sso and role arn:aws:iam::<account-id>:role/<review-role>
```

The plan pass runs `terraform plan` on the examples the change touches, on a short session of a read-only review role that the account owner creates. You name both the AWS profile and the role for that run only. The session carries a policy that allows only read actions. Before planning, a write probe, a dry-run VPC create, must be refused; it tests one write action, not the whole policy. With Docker, the plan runs in an isolated container whose proxy lets each phase reach only the hosts it needs. Without Docker, it runs on your machine in laptop mode, where stricter pattern checks refuse risky examples; they reduce the risk of the code acting on your machine but cannot rule it out. Plan results add evidence and never clear a finding. In runner mode only each example's outcome and resource counts reach the comment. In laptop mode a finding may quote one scanned error line; the scan cannot guarantee that no sensitive value slips through. It needs `terraform`, `jq`, `perl`, `git` and AWS CLI v2. Details: [plan-pass.md](.agents/skills/terraform-module-pr-review/references/plan-pass.md) and the [plan runner](.agents/skills/terraform-module-pr-review/references/plan-runner/README.md), which is a prototype.

### Create a new module

```text
create a terraform-aws-<service> module covering <resource types>
```

The maintainer builds a coverage ledger from the provider schema (every argument becomes an input, an output, or a documented omission), copies the profile's templates and writes the examples. It counts as complete only after a trusted run of `pre-commit` and a `terraform plan` with credentials you choose.

### Upgrade a provider major version

```text
upgrade ~/src/terraform-aws-rds to AWS provider 6.x
```

The maintainer compares the old and new provider schemas, makes the smallest edit plus the version constraint bump, runs `terraform init -backend=false -upgrade`, and writes migration notes in `docs/MIGRATION_<from>_to_<to>.md` for anything that breaks consumers.

### Use mtf-facts alongside the skills

[`mtf-facts`](https://github.com/modulestf/facts) is an optional command-line tool that checks the deterministic rules from the files alone, with no network and no Terraform. When it is on your `PATH`, outside the module checkout, the reviewer runs it once and ends the review with a short comparison of where the tool and the review agree. Without it, the review is the same. The maintainer can also use its `lint`, `ledger` and `schema-diff` commands. The facts repository has a [walkthrough](https://github.com/modulestf/facts#example-review-a-pull-request) on a real pull request. Design: [docs/facts-engine-design.md](docs/facts-engine-design.md).

### Review a whole module, not a change

Tell the reviewer that the checkout holds a new module, for example one offered for adoption. It runs a full coverage pass with no base to compare against.

### Profiles

The terraform-aws-modules profile holds the family's templates, layout, release rules and scope lists. The skills' shared references stay provider-neutral; anything specific to one family goes in its profile. A second profile is not designed yet: [PROFILE.md](.agents/skills/terraform-module-maintainer/profiles/terraform-aws-modules/PROFILE.md) says how to start one. A module can record its own scope exceptions in `docs/SCOPE.md`; the review reads that file from the base, so an exception must be merged before the change that needs it. To hand the profile to another code reviewer, pin [review-guide.md](.agents/skills/terraform-module-maintainer/profiles/terraform-aws-modules/review-guide.md) by commit; it gives advice, not a verdict.

### Checks that need permission

When a check cannot run inside your agent's sandbox, the review records it as not run and the verdict is inconclusive at best. Only your own message can allow a run outside the sandbox, for that run or a named set of runs.

## Requirements by task

| Task | Needs |
|------|-------|
| Every Terraform skill | The four skill directories side by side, a Terraform MCP server |
| Review a pull request or commit | `gh` logged in as a person (a bot or CI identity runs render-only and posts nothing), `git`, `jq`, `terraform` |
| Review a local change | `git` |
| Change, fix or upgrade a module | `terraform`; for a trusted run also `pre-commit`, `terraform-docs` and `tflint` |
| Create a module | The same. To finish it: a trusted run and a `terraform plan` you run with your own credentials, not a review role |
| Plan pass | An AWS profile and a review role, AWS CLI v2, `jq`, `perl`; Docker for the isolated runner |
| `change-scope` alone | Nothing else |
| `mtf-facts` comparison | The `mtf-facts` binary on `PATH`, outside the checkout |

## Related repositories

- [modulestf/facts](https://github.com/modulestf/facts): `mtf-facts`, the optional facts engine.
- [modulestf/terraform-schema-mirror](https://github.com/modulestf/terraform-schema-mirror): provider schemas, every stable version, as release assets.
- [antonbabenko/terraform-skill](https://github.com/antonbabenko/terraform-skill): general Terraform practices. The skills here link to it and do not repeat it.

## Tests

The tests are shell scripts under `tests/`. Run them all with:

```bash
for t in tests/*.sh; do bash "$t" || echo "FAILED: $t"; done
```

What each test checks and what it needs is in [AGENTS.md](AGENTS.md#tests).

## Contributing and license

Issues are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues as [SECURITY.md](SECURITY.md) says. Licensed under the [Apache License 2.0](LICENSE).

## History

This repository held modules.tf-lambda, the Cloudcraft-to-Terraform generator (2019-2021). Its code is on the `legacy` branch.
