# AGENTS.md

Coding agents write the code and docs in this repository. Read this file before you change anything.

## Public repository: no sensitive details (READ FIRST)

- Everything committed here is public: files, code comments, commit messages, branch names, tags, pull request and issue text, review comments and release notes. Never add names of private repositories, tracker ids, local paths, customer names, account ids or internal planning notes. Describe the generic concept instead.
- Task tracking, research notes, plans and the measured review fixtures live in a private companion repository of the maintainers. If it is available in your session, follow its `AGENTS.md`. Never copy its content, names or ids here, and keep no issue-tracker state here.
- Never add that repository as a remote of a clone of this one, and never fetch from it or push to it.
- Changes land by pull request from maintainers only. Users open issues.

## What this repo is

modulestf reviews and maintains reusable Terraform modules. The first module family is terraform-aws-modules.

- `.agents/skills/`: the agent skills. `.claude/skills` is a symlink to it.
- `docs/`: design and decision records.
- `tests/`: the shell tests, listed below.

## Tests

The runner package test also needs ripgrep, and the record cap test needs Python 3 as well as Bash.
These tests make no network calls.

- `tests/plan-runner-packages-test.sh` checks that every direct Debian package
  install has an explicit version, no extra unpinned install is added and apt's
  authentication is retained. Negative mutations check each refusal. It does not
  establish archive availability; both architecture builds and native smoke do.

- `tests/plan-runner-record-cap-test.sh` executes the production capture and
  record assembly helpers with local Docker stubs: repeated and shared output,
  remaining and exhausted capacity, command failure status, non-regular or
  oversized destinations, and complete or oversized multi-example records.

The facts engine oracle and merge fixtures, and the checks that hold them to the facts
schemas, to this repository's `rule-facts.md` and to their own trees, are in the facts
repository's Go tests; its CI passes them the pinned `rule-facts.md` through
`MTF_FACTS_REGISTRY`. The layout is in [the oracle README](https://github.com/modulestf/facts/blob/master/testdata/oracle/README.md)
and [the merge README](https://github.com/modulestf/facts/blob/master/testdata/merge/README.md).

The suites below run with `bash` from a clean checkout, with no setup step and no network calls. They need the base toolchain: `bash`, `git`, `awk` and `grep`, plus `jq` for the plan pass, verify pass and render comment tests, `tar` and `gzip` for the terraform-docs pass test, `zsh` and `perl` for the plan pass and verify pass tests, and `perl` for the render comment test.

- `tests/behaviour-pass-test.sh` runs the pull request review skill's `references/behaviour-pass.sh` with `mtf-facts` stubbed: the classify and eval steps, the empty ladder record it hands `claims-eval` when no ladder ran, a ladder record and a claims file passed through, the head and base SHAs passed to `claims-eval` and its `capped` count held to the classifier's, the record lines with each `change` line and no input, and the run file object, an inert change and capped triggers, the module root prefix stripped from the files list and a rename covered at both paths, and each fail-closed refusal with its fixed reason: no tool, a tool that fails or passes its deadline, output over 1 MiB, not JSON or outside its contract, a trigger path with a space or a colon, a required case set that is not up to 32 cases with distinct ids, a path of the files list with no entry, a ladder record for another schema, head or base, and a claims file over its caps; then the usage errors, a unified diff among them. It ends with the replay of a pull request that drops `compact()` around a list, one wrapper change and one unknown propagation candidate with no ladder run, rendered by `render-comment.sh`: inconclusive at ladder rule 4, never approve with nits, with every unverified trigger and claim in section 5 and the evidence line. It needs `jq`.
- `tests/plan-pass-test.sh` runs the pull request review skill's `references/plan-pass.sh` under bash and under zsh, with `terraform` and `aws` stubbed: the opt-in and tool notes, the review role session, its write probe and the session policy, the gates, the record lines, the evidence redaction, the merge base re-run and the cleanup, no cap on the number of examples, the saved plan read back with `terraform show -json` and no credentials into an addresses file of configuration addresses and attribute names, runner mode (refused outside a container, the budget and phase arguments it alone takes, and the exceptions it records, such as the Docker provider, a fixed role and `build_in_docker = true`), and the plan runner's `hosted-record.sh` on fixture record directories: a record reduced to classes, `Plan:` counts, cleaned addresses and a refused host count, with no host name, kept line or file name in the output, and `host-pass.sh`'s rules for that file taken from the script, which refuse an address or attribute outside its pattern, and each refusal: a class or base result outside the list, a block with no plan line, a duplicate or unsafe path, an example under a module root prefix, lines out of order, no summary, a record not in runner mode, a symbolic link, an input or output over its size cap, and an `--out` that exists or whose directory does not.
- `tests/render-comment-test.sh` runs the pull request review skill's `references/render-comment.sh` and `render-comment.jq`, the host render of a review from merged findings with no model: the worked examples of `comment-format.md` byte for byte (the worked example, the Fix lines, and pull request 410 grouped and collapsed, with the Fix lines, Fix blocks and What to do section those two predate removed), the What to do section of every ladder rule and the four facts the ladder makes hold for it, the Fix block of a group of three or more entries and when a group stays unfolded, the verdict and proposed event of every ladder rule and the orderings and clamps `verdict.md` calls out, the disputed note, each collapse rule with a collapsed block and its Fix lines byte for byte, every fixed line of sections 5 and 6 in one whole body, the lines of sections 7 and 8 from `host.json`, the checks file and the run file, the plan coverage of the run file: an unplanned example is a rule 4 unknown listed after the verification gaps, golden, an inert change lists them as information and counts none as a gap, and a run file without coverage or with a class that does not match its list is refused, the module root prefix, that the script's fixed strings equal the Host Render Strings table of `comment-format.md`, the leak scan, the at-mention step, and each refused input: findings outside the merged findings schema, a host file for another head, a bad run file, an assessment with a line that starts like a heading, bold line, HTML or list item or with more than two paragraphs, and an output directory that is missing, holds a file or lies in the run directory; null counts render the one line `Counts: not reported by the review run.` and zero counts do not, and a run file with a count missing or empty counts is refused; more than 100 verification gaps all count for the verdict, while section 5 lists the first 100 and one line with the count of the rest. Behaviour evidence in the run file: verified, covered and inert pass with the evidence line under the rationale, each unverified trigger or claim, the capped count and a step that did not run are rule 4 unknowns listed in section 5 byte for byte, a `review.verification-incomplete` finding is a rule 4 unknown with its own rationale, a `claim.*` finding blocks, a run file with no behaviour object is a rule 4 unknown outside a triage run, a refuted state blocks at rule 2 by itself, with its own rationale and checklist item when no `claim.*` finding words it, and disarms rule 0, while a CRITICAL finding keeps rule 1 and its rationale with the refuted item added, byte for byte, a `claim.*` finding with no refuted state is refused, and a behaviour object outside its grammar is refused. A negative self-check mutates temp copies of the script and confirms each weakened copy is caught. It needs `jq`.
- `tests/reviewer-git-safety-test.sh` checks the reviewer's git safety form in `references/git-safety.md`, taking the functions and the table of queries from that file, and that every `diff`, `show` and `log` row carries both flags: for each setting a hostile workspace can put in `.git/config` or `.git/info/attributes` (external diff, diff driver command, textconv, smudge filter, fsmonitor, signature program, pager, lazy fetch over ssh and `ext::`), it shows the plain command runs a marker program and every query of the form's table runs none. It also shows that replace refs and grafts change what the plain queries read and not what the form reads, that `safe_git_refuse` refuses each partial clone key alone and a shallow clone but not a full clone, that `safe_git_partial` stops the head revision query for a partial clone but not for a shallow or full one, that `-c protocol.allow=never` alone does not stop an `ext::` lazy fetch, that `git status` still runs a clean filter in the form, and that a form without the lazy fetch, pager or replace overrides, or a refusal without the shallow test, is caught. It uses throwaway repositories only; the pager case needs `script(1)` and the lazy fetch case git 2.44 or newer, and each skips with a note without them.
- `tests/skills-test.sh` checks every markdown file and template git knows about, tracked or newly added but not yet committed, and the shell scripts under `.agents/skills/`, which get only the ASCII check: every relative link resolves to a path in the index, every anchor matches a real heading, no two headings in a file produce the same slug, headings are ATX, and the text is plain ASCII except where an exception records the character. A gitignored file is out of scope, and a link to one fails, because the forge cannot see it either. It also checks the terraform-aws-modules profile's `review-guide.md` against the profile: every level-2 profile section is cited or listed as Not covered, each cited or Not covered section still matches the hash the guide records, and every ID the guide lists exists in the reviewer skill. It checks that every profile constants block in the profile's `PROFILE.md` parses, that the blocks and their keys are exactly the expected ones, and that each value equals the rule text it restates, with a negative self-check that reports each mutation under the block it changed. It also checks that the reviewer's `references/rule-facts.md` has one row for every `rule_id` the skill names and no other row, that each row's carry value is `file` or `never`, that every `file` rule, and no other, has one line in its carry audit, and that the registry columns hold allowed values: engine, class, scope, cross_area, area_kinds, bundle_sections and severities, a confirm class only on a candidate rule, never small on a rule that can be CRITICAL, and every candidate at lead until its evaluation, each with a mutation that must be caught. It also checks the reviewer's `references/engine/` files against that table: every `tool` and `candidate` rule has exactly one level-2 section, every level-2 section is such a rule, no `llm` rule has one, each section's `Engine` line matches its row and it holds its own Rule text, Confirm when and Host templates headings once each, and its `summary` and `suggested_fix` templates sit under Host templates, outside fenced code, and are one code span each, hold `{subject}` and are at most 200 characters; a negative self-check mutates temp copies and confirms each of these fails. It also runs the reviewer's `references/judgment/assemble.sh` twice and checks that the runs agree, equal the committed `prefix.md`, which is at most 90 KB (92160 bytes), and change no file of the skill, with a negative self-check on temp copies for each of these.
- `tests/terraform-docs-pass-test.sh` runs the maintainer skill's `references/terraform-docs-pass.sh` with `curl` and terraform-docs stubbed: the profile constants it reads, a regenerated root and submodule in one run with the text outside the region and the file mode kept, the curl flags, a corrupt cache entry installed again once, and one negative fixture per check, each ending stale with the workspace unchanged: a wrapper or other entry, a path outside the shape or through a symbolic link, the eleventh directory, a terraform-docs configuration name in the directory or above it as a file, a dangling link or a fifo, an OpenTofu, JSON or override file, a symbolic link, hard link or fifo among the inputs, a name starting with a dash, a file over 1 MiB, 201 files, no `README.md`, each marker count failure including one in a code fence and the older pair, a hash mismatch, over 8 MiB, a time-out and the overall deadline, a failing tool, a file the run creates or deletes, a `README.md` the run turns into a directory, an empty region, marker text the run puts in the region, text before or after the region the run changes, and a workspace changed or added to during the run; an unreadable profile, a platform with no hash, a profile, download program or cache directory inside the workspace, a cache directory that is a link or has the wrong mode, and a second hash failure that ends the run's use of the tool; a run of 51 files that finishes fast, clean up on INT and TERM, a file not owned by the user when run as root; and that no run directory is left.
- `tests/verify-pass-test.sh` runs the pull request review skill's `references/verify-pass.sh` under bash and under zsh, with `terraform` and `mtf-facts` stubbed: each record, the version bump skip, a symbolic link example, the merge base re-run, an example the change adds, a merge base that cannot be fetched, a missing terraform, the environment it runs terraform in, the SHA inputs, the merge of a run outside the sandbox, the check of a host's results, the example selection (touched and caller first, an inert change that keeps every example, the tool's own fallback, an absent, failing or invalid tool and one inside the workspace, each selecting every example), the budget and the output cap with the stopped process group gone, a merge base fetch the budget stops, and the plan coverage from no plan, a laptop record, a runner record whose forged lines claim nothing, a hosted record, an inert change, and a module with no example directory.

## Skills

Each skill is a directory under `.agents/skills/<name>/`, where Codex and Antigravity load it. `.claude/skills` is a relative symlink to `../.agents/skills` so Claude Code loads the same files. Hooks and settings stay in `.claude/`: each tool has its own hook format.

- `SKILL.md`: entry point. Keep it short: triggers, modes, mandatory rules, workflow.
- `references/`: provider-neutral guidance that `SKILL.md` links to and loads on demand.
- `profiles/<profile>/`: conventions of one module family (templates, workflows, release config). Only in `terraform-module-maintainer`. Default profile: `terraform-aws-modules`.

Rules for editing skills:

- Keep `references/` provider-neutral. Anything specific to one module family goes into its profile.
- Do not design a profile format or loader until a second profile exists.
- Do not duplicate general Terraform guidance from `antonbabenko/terraform-skill`. Link to it instead.
- Provider schema facts (arguments, nested blocks, versions) come from the Terraform MCP tools, not from memory.
- Templates are copied into modules as-is. Keep them valid and consistent with the profile's `templates-map.md`.
- The reviewer links to the maintainer's `references/` and `profiles/` with relative paths. Do not copy them.
- The maintainer may link to the reviewer's `references/findings-schema.md` the same way, so the two skills agree on the shape of a finding. Both directions are relative paths between sibling skill directories, so the pair travels together: installing one without the other leaves a dead link.
- Skills must not assume GitHub, PRs, or comments. They work on a workspace and a task. That is the default, and it is required of every skill that makes a judgement. The one exception is a skill whose stated job is to adapt a single surface to the neutral ones, such as reviewing a GitHub pull request. Such a skill may know about its surface, but it keeps the host concerns to itself and hands a neutral skill only a workspace and a task. Finding a surface convenient is not the exception; adapting it is. Such a skill produces no finding of
  its own. It may compute a decision from a neutral skill's findings plus surface state, provided the
  computation is a documented total function of those inputs, stated in the skill, adding no judgement
  of the code. Anything beyond that is a judging skill, however its job is stated.
- Add new detail to `references/` or a profile, not to `SKILL.md`.

## Authoring and review

Content here is written by a team of agents with cross review. This is how the skills in this repo were written, and it caught defects, so it is the process, not a suggestion.

- One agent takes one issue and writes to its acceptance criteria.
- A different agent, which did not write the change, reviews it against those criteria one by one and
  returns a verdict: approve, or request changes with findings in the shape the reviewer skill's
  `references/findings-schema.md` defines.
- Findings go back to the original author to fix, and the same reviewer re-checks the ones it raised.
  The reviewer reviews; it does not edit.
- Mechanical checks are part of the review and are run, not asserted: every relative link resolves, every in-document anchor matches a real heading, no two headings in a file produce the same slug, cited tool names and parameters exist, and added lines are plain ASCII (the rules in [Writing style](#writing-style)). `bash tests/skills-test.sh` runs all of these but the tool names, which need the tool list and stay a manual step.
- A review of a skill also checks it against the rules in [Skills](#skills). A review of any text also runs the sensitivity scan in [Public repository](#public-repository-no-sensitive-details-read-first).
- Work that touches the same file is serialized. Only work on disjoint files runs in parallel.
- On a hard decision, such as a rule's severity or scope, a report or comment format, or a change to the findings schema, ask several independent models for a consensus review before you choose. Give them the options and the constraints, weigh their objections one by one, and record why you dismissed any. The owner does not always have the best idea, and a consensus review is how a weak one gets caught before it ships.

Why the second agent is worth its cost: a verification step listed existing tests as an unconditional check with the trust qualifier attached only to adding tests, and `terraform test` runs `apply` by default, so an untrusted workspace would have reached real credentials. The author did not see it; a reviewer reading the acceptance criteria did.

Content rules the review enforces:

- Write names out in full. `terraform-aws-modules` and `compliance.tf` are the two that come up. No internal shorthand and no initialism for either, anywhere a reader outside the project could see it, which per [Public repository](#public-repository-no-sensitive-details-read-first) is essentially everywhere: files, commit messages, branch names, tracker issues, and pull request text.
- Never write a bare at-mention of the assistant. Write it inside a code span if it has to appear at
  all, the way this file already writes `@modulestf`. On an issue, a pull request, a comment or a commit
  message a bare mention notifies the account or fires a trigger phrase. In a file it does not, but
  file text gets quoted into those surfaces, so keep it in a code span everywhere. In prose, name the
  assistant without the at-sign.
- No vendor or model attribution anywhere. The rule is in [Git](#git).

## Writing style

- Plain ASCII typography. No em or en dashes, no curly quotes, no ellipsis character, no
  arrows, no box-drawing characters. Write ` - ` for a dash, `->` for an arrow, and draw a
  directory tree with `|--`, `` `-- `` and `|`.
- The check is `LC_ALL=C grep -rnP '[^\x20-\x7e\t]' <path>`. It should return nothing. Do not write
  the class as `'[^ -~\t]'`: in a POSIX bracket expression that `\t` is a backslash and a `t`, both
  already in range, so the check flags every tab in any file that uses them. A file that
  has to keep a character records why, next to the file it applies to: today the only one is
  the lock workflow template, which is upstream text that generated modules must match byte
  for byte.
- The record is a line beginning with the words `Typography exception` and a colon, then the
  file in backticks and each kept codepoint written as `U+23F3`. `tests/skills-test.sh` reads
  it, so the name must match exactly one file in the directory holding the record or below it,
  and a codepoint the record does not name still fails, even in that same file.
- Short, direct sentences.

## Git

- Do not commit `.claude/settings.local.json` or `.history/` (gitignored).
- No vendor or model attribution in anything pushed to this repository. No `Co-authored-by` trailer
  naming an assistant, no "Generated with" line, no model name or identifier, no session URL.
  The carriers, in the order they are easiest to miss: the commit author and committer identity,
  branch names, commit
  messages, pull request titles and bodies, tracker issue text, review comments, and code comments.
  Naming a tool, action, SDK or directory the project depends on is not attribution
  (`anthropics/claude-code-action`, `.claude/`); attribution is a claim about who produced the change.
- Before committing, set `user.name` and `user.email` to a person. The author field is the most
  durable attribution a repository has, and no trailer is needed to carry it.
- Attribution already pushed is history. Flag it and ask before any rewrite, as
  [Public repository](#public-repository-no-sensitive-details-read-first) requires.
