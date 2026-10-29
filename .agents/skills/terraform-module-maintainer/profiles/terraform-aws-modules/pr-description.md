# Pull Request Description

> **Part of:** [terraform-module-maintainer](../../SKILL.md)
> **Purpose:** What the body of a pull request in this family has to contain to be
> reviewable, and what fails. Extends the inherited org template; never replaces it.

The title is read by the release tooling, and
[Release and commit conventions](PROFILE.md#release-and-commit-conventions) covers it. The
body is read by the maintainer who decides whether to merge, and by everyone who later asks
why the module changed. The material this file is derived from is in
[pr-description-sources.md](pr-description-sources.md).

## The template comes first

Every repository in this family inherits `PULL_REQUEST_TEMPLATE.md` from the org's `.github`
repository, and GitHub pre-fills it into the body. Its four headings are the required set.

| Heading | Accepted variants |
|---------|-------------------|
| `## Description` | An untitled lead paragraph at the top of the body |
| `## Motivation and Context` | None |
| `## Breaking Changes` | None |
| `## How Has This Been Tested?` | `## Testing`, `### Testing` |

This file does not change those headings, does not remove one, and does not remove the three
checkboxes. It says what belongs inside each. Where the two disagree, the template wins and
this file is what needs correcting.

Never tick a checkbox on the author's behalf, and never read a tick as evidence. Checkbox
two, "I have tested and validated these changes using one or more of the provided
`examples/*` projects", is necessary and not sufficient: the template's own comment asks the
author to describe how they tested. The tick is the claim, the prose under it is the
evidence, and the prose is what this file governs.

## Required sections, in order

### 1. Description

- [ ] An opening sentence naming the feature, the surface it lands on (the root module, or
      `modules/<name>`), and the input that carries it, in backticks.
- [ ] For a map, list or object input, one sentence on the shape: what one entry is and what
      it is scoped to.
- [ ] A bullet per capability added, each naming its concrete input or output in backticks.
      One bullet, one capability, and none that restates the sentence above it.
- [ ] A sentence per thing the change deliberately does not support, with its reason. A
      limitation with no reason reads as an oversight and gets raised in review.
- [ ] The example directory by path, when the change adds one.
- [ ] Everything in the diff that is not the headline change, under a final `Also:` block,
      one bullet each. A bullet fixing an unrelated defect says it is unrelated, names the
      file or submodule, and states the defect and why it is one. The org `CONTRIBUTING.md`
      asks contributors to keep a pull request focused; this block is how a change that
      could not stay focused stays reviewable anyway.

### 2. Motivation and Context

- [ ] Every issue addressed, one per line, as `<keyword> #<number> "<issue title>"`. The
      keyword is `Closes` for an issue this completes and `Resolves` for one it answers.
      The keyword followed directly by the number makes GitHub link the issue and close it
      on merge; the quoted title after it makes the line readable without following the
      link. See [Closing keywords](#closing-keywords).
- [ ] Every open issue the pull request is related to gets such a line, including one opened
      after the pull request. An issue that does not exist is not opened just so it can be
      closed.
- [ ] A sentence of rationale for every structural choice a reviewer could reasonably have
      made differently: root module or submodule, one resource or many, a new input or a new
      example. State the mechanism, not the preference - what breaks under the alternative,
      or what the caller has to write to work around it.
- [ ] When the delivered shape differs from the shape the issue asked for, say so here.
- [ ] A link to `docs/MIGRATION_<from>_to_<to>.md` when the change forces consumers to act.
      See [Migration notes](PROFILE.md#migration-notes).

### 3. Breaking Changes

- [ ] A verdict on its own line: `None.` or a statement of what breaks.
- [ ] Every version constraint that moves in the diff, with its reason, even when the verdict
      is `None.`: the old minimum, the new minimum, and what the new minimum buys.
- [ ] For a break, what breaks in consumer terms and what the consumer does about it, one
      line each.
- [ ] For a break, why compatibility could not be held: what was tried, and what the
      compatible alternative would have cost the consumer or made impossible. "The provider
      removed the attribute" is a reason. "The new shape is cleaner" is not.
- [ ] The verdict is about the infrastructure a consumer gets, not the module's variable
      surface. An unchanged set of inputs whose defaults now produce a different resource,
      policy or permission is a break. "The module interface remains unchanged" is not a
      reason and does not belong here.
- [ ] The verdict has to be supported by the testing section below.

### 4. How Has This Been Tested?

Every line here is falsifiable: a reader can run it and check the answer.

- [ ] The environment, named: a live account, or `terraform validate` only.
- [ ] Per example exercised, the path, the operations run, and the result of each. The
      minimum on a live account is apply, re-plan, destroy, with the re-plan result stated.
- [ ] The lifecycle transitions beyond a first apply: update, replace and delete, plus any
      branch a plain apply never reaches, such as supplying an existing resource instead of
      creating one.
- [ ] Any check outside Terraform that confirms the resource works: a client that connected,
      a log that arrived, an object that was written.
- [ ] The upgrade test, whenever anything user-visible changed. The existing example is
      applied at the released version, the module source is swapped to this branch,
      `terraform plan` is run, and the result is quoted. `No changes` is what supports a
      `Breaking Changes: None.` verdict. A plan with a diff means the verdict is wrong, and
      that diff is what belongs under Breaking Changes instead.
- [ ] `pre-commit run -a`, run and stated.

## Closing keywords

GitHub's own rules, from "Linking a pull request to an issue",
<https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/linking-a-pull-request-to-an-issue>,
read on 2026-09-24.

- The keywords are `close`, `closes`, `closed`, `fix`, `fixes`, `fixed`, `resolve`,
  `resolves` and `resolved`, in any case, optionally followed by a colon: `Closes #10`,
  `CLOSES #10` and `Closes: #10` all link.
- The documented syntax is the keyword, then the reference, with nothing between them but
  the optional colon and a space: `#<number>` for an issue in the same repository, and
  `<owner>/<repo>#<number>` for one in another repository, as in
  `Fixes octo-org/octo-repo#100`.
- The keywords work only in a pull request that targets the default branch. On any other
  base they are ignored.
- A keyword naming another pull request links the two, and merging this one also closes
  that one. This convention is about issues; closing another pull request is a separate
  decision for the author and the maintainer.
- A maintainer can also link an issue from the pull request sidebar, which closes it on merge
  the same way.

## What fails

A description carrying any of these is not reviewable, and review says so rather than
guessing at the author's intent.

| Fails | Why |
|-------|-----|
| "Tested using the provided example projects", "tested locally", "works as expected" | No example, no operation, no result. Nothing in it can be reproduced. |
| `Breaking Changes: None` with no upgrade test, on a change touching defaults, policy documents, resource addresses or version constraints | An assertion with no evidence, and the assertion is what gets merged. |
| "The module interface remains unchanged" as the reason for no break | Reasons about the variable surface while the break is in the infrastructure produced. |
| A declared break whose only stated justification is that the new shape is better | The consumer cannot tell an unavoidable break from a preference, and has no basis to plan around it. |
| A version constraint moved in the diff and not mentioned under Breaking Changes | The fact a reader most needs in order to disagree with the verdict is missing. |
| Issues as bare numbers, or named in prose with no closing keyword | GitHub never links them, and the release notes say nothing. |
| Drive-by changes folded into the headline paragraph, or absent from the body | A reviewer cannot attribute a hunk, so the diff has to be re-derived by hand. |
| A new example directory in the diff and not named in the body | The reviewer looks for the demonstration in the wrong place. |
| A required heading left in place with nothing under it, or its HTML comment only | An unanswered section. |
| A checkbox ticked with no prose under it | The tick is the claim, not the evidence. |
| Migration notes required by the change and not linked | The consumer who needs them will not find them. |
| Praise, thanks, emoji, a closing pleasantry, or a restatement of the title | Noise in the artifact that explains the change from here on. |

## Worked example

The two sections the table above has the most rows about, written to this standard. The
module and the version numbers are invented.

````markdown
## Breaking Changes

None. The minimum AWS provider version moves from 5.70 to 5.72, which is where
`target_object_key_format` was added.

## How Has This Been Tested?

Against a live account: `examples/complete` applied, re-planned with no changes and
destroyed; logging added, switched between both key formats, and removed on an existing
bucket; an object written to the source bucket and the delivered log read back from the
target. The upgrade test on `examples/complete` at v4.11.0, with the module source swapped
to this branch, plans `No changes`.
````

## What this file is not

It is not a review rule, and no reviewer-side finding grades a description against it. A
description exists only on a code host, and the reviewer skill has to read correctly against
a local diff where there is none, so such a rule would have a code-host artifact as its
entire trigger. A rule failing every thin testing claim would also fire on nearly every
community pull request. This file is for the author; a maintainer reading a description that
fails it says so in their own words. The one reviewer-side finding that touches a
description is narrower than this file: it fires only when the review's own reading rates
the change breaking AND accompanying prose exists AND that prose declares the break without
saying why it was unavoidable. It grades nothing else here, and with no prose it does not
fire at all.

A missing closing keyword is not a finding either. Which issues a pull request is related
to, and which of them merging closes, is state only the code host holds. The pull request
review skill reads it and renders a line under pull request state, with no effect on the
verdict: [Related Issues](../../../terraform-module-pr-review/references/github-io.md#related-issues).

It also does not restate the title rules, which are enforced by
`.github/workflows/pr-title.yml` and documented at
[Release and commit conventions](PROFILE.md#release-and-commit-conventions).
