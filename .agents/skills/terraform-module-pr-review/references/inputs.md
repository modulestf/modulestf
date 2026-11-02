# Inputs

> **Part of:** [terraform-module-pr-review](../SKILL.md)
> **Purpose:** What this skill is for and how Step 0 parses the reference, moved here whole from SKILL.md.

## The Host and the Verdict

Adapting a code host to the neutral skills is this skill's whole job, so it may know about that host, and it keeps the host to itself: the reviewer gets a workspace and a task, nothing else. It produces no finding of its own. The verdict is a documented total function of the reviewer's findings, the pull request state, the checks this skill could not run itself, the Step 1 identity result, whether the run is render-only, and whether it is a triage run, defined in [verdict.md](verdict.md), adding no judgement of the code.

## Parsing the Reference

The reference is parsed, never searched for. Split the request on whitespace, strip surrounding punctuation from each token - leading `<`, `(`, `"`, `'`, and trailing `.`, `,`, `;`, `:`, `)`, `>`, `"`, `'` - then match each token, anchored, host exactly `github.com`:

```
^https://github\.com/(?!\.\.?[/#])([A-Za-z0-9._-]+)/(?!\.\.?[/#])([A-Za-z0-9._-]+)/pull/([1-9][0-9]*)(/(files|commits))?/?([?#].*)?$
^(?!\.\.?[/#])([A-Za-z0-9._-]+)/(?!\.\.?[/#])([A-Za-z0-9._-]+)#([1-9][0-9]*)$
^https://github\.com/(?!\.\.?[/#])([A-Za-z0-9._-]+)/(?!\.\.?[/#])([A-Za-z0-9._-]+)/commit/([0-9a-f]{7,40})/?([?#].*)?$
```

Exactly one token may match. Zero, or two or more, stops the run and says what was given. Matching token by token is what lets the patterns stay anchored: anchored patterns never match a whole sentence, and unanchored ones would find a pull request URL sitting inside another URL's query string.

Both ends are anchored, so a lookalike host does not match. `http://` and `www.github.com` are rejected on purpose, not by oversight: neither is the canonical host, and accepting either widens what counts as GitHub. A trailing `/files` or `/commits`, a query string, and a fragment are tolerated. `.` and `..` are rejected as an owner or a repository name, and a number starts at 1, so `pull/0` does not parse. An issue URL, a compare URL, a branch or tree URL, prose naming no pull request or commit, or two references in one request: stop and say what was given. A branch is not accepted because a branch name moves: ask for the commit it points at, and review that. A commit URL reviews that one commit against its parent and posts a plain commit comment with no decision; the steps it changes are in [github-io.md](github-io.md#commit-target). Never search for a pull request matching prose, and never take the most recent open one.
