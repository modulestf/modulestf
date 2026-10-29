# Git Safety

> **Part of:** [terraform-module-reviewer](../SKILL.md), [Rule 1](../SKILL.md#rule-1-read-only-always)

The workspace is untrusted, and so is its `.git/` directory. Git reads `.git/config` and `.git/info/attributes` on every command, and several settings there name a program for git to run. A plain `git diff`, `git show` or `git log` in a hostile workspace can run any program the workspace chooses. This file gives the one form in which Rule 1 allows a version control query, and the reasons for each part of it.

## The form

Define these two functions once, in the shell that runs the queries. They run the same under bash and under zsh.

```sh
safe_git() {
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_LAZY_FETCH=1 \
  GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null \
  GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat \
  git --no-pager -c core.fsmonitor=false -c core.hooksPath=/dev/null \
    -c protocol.allow=never -c diff.external= -c log.showSignature=false \
    -c advice.graftFileDeprecated=false "$@"
}
safe_git_refuse() { # true for a partial or shallow clone: query nothing
  [ -n "$(safe_git config --get extensions.partialClone)" ] ||
    [ -n "$(safe_git config --get-regexp '^remote\..*\.promisor$')" ] ||
    [ -e "$(safe_git rev-parse --git-path shallow)" ]
}
```

Run `safe_git_refuse` first, from the workspace. It is true for a partial clone, whose missing objects git would fetch, and for a shallow clone, whose history the workspace cuts. When it is true, run no query: the query has failed, and Rule 1 and Step 1 say what follows. Otherwise run each query as `safe_git` followed by one row of this table, and nothing else.

| Query | Exact form after `safe_git` |
|-------|-----------------------------|
| The head revision | `rev-parse HEAD` |
| The diff of the change | `diff --no-ext-diff --no-textconv <base>...HEAD` |
| A commit | `show --no-ext-diff --no-textconv <rev>` |
| A file at a revision | `show --no-ext-diff --no-textconv <rev>:<path>` |
| Commit messages | `log --no-ext-diff --no-textconv --format=%B <base>..HEAD` |
| Ancestry | `merge-base --is-ancestor <sha> <base>` |
| The last release tag | `describe --tags --abbrev=0 <base>` |
| Tags holding a commit | `tag --contains <sha>` |

Further rules:

- `diff`, `show` and `log` always carry `--no-ext-diff --no-textconv`, also where the table's query prints no patch, so a `-p` added later is still covered.
- `diff` always takes two revisions. It never compares against the worktree or the index: no single revision, no `--cached`, no bare `git diff`.
- `log` never uses a `%G` placeholder or `--show-signature`. Both run the signature program.
- `git status` is not allowed. See [Why git status is banned](#why-git-status-is-banned).
- Every other git subcommand stays banned, as Rule 1 says. The one other use is the base extraction in [facts-engine.md](facts-engine.md), which reads git objects only and carries its own guards.

`GIT_NO_LAZY_FETCH` needs git 2.44 or newer. `safe_git_refuse` closes the same gap on older git, so the form holds on any git with `GIT_CONFIG_GLOBAL`, which is 2.32 or newer.

## What each part stops

Command-line `-c` settings and the environment beat the workspace's `.git/config`. Attributes are different: `.git/info/attributes` names a driver, and git then reads that driver's program from `.git/config` under a name the workspace chooses, so no fixed `-c` setting can blank it. The flags below switch off the use of drivers instead.

| Setting in the workspace | What runs it | What stops it |
|--------------------------|--------------|---------------|
| `diff.external` | `diff`, `show` and `log -p` | `--no-ext-diff`, and `-c diff.external=` |
| `diff.<driver>.command` named by an attribute | `diff`, `show` and `log -p` | `--no-ext-diff` |
| `diff.<driver>.textconv` named by an attribute | `diff`, `show` and `log -p` | `--no-textconv` |
| `filter.<driver>.smudge` named by an attribute | a diff that hands a file to an external diff or a textconv program | `--no-ext-diff --no-textconv`: no file is handed over |
| `filter.<driver>.clean` named by an attribute | `git status` and any diff against the worktree | nothing in the form: those commands are banned |
| `core.fsmonitor` | `git status` | `git status` is banned; `-c core.fsmonitor=false` as a second layer |
| `core.pager`, `pager.<command>` | any command whose output is a terminal | `--no-pager` and `GIT_PAGER=cat` |
| `extensions.partialClone` or `remote.<name>.promisor`, with a remote URL or `core.sshCommand` the workspace picks | any query that needs an object the clone lacks (lazy fetch) | `GIT_NO_LAZY_FETCH=1`, and `safe_git_refuse` |
| `log.showSignature` with `gpg.program` | `log` and `show` on a signed commit | `-c log.showSignature=false` |
| Replace refs (`refs/replace/`) | every query: a commit or tree is read as another one, so the diff hides lines while `rev-parse HEAD` still prints the stated head | `GIT_NO_REPLACE_OBJECTS=1` |
| `.git/info/grafts` | ancestry, `log` and `describe`: a commit gets parents it does not have | `GIT_GRAFT_FILE=/dev/null` |
| `.git/shallow` | ancestry and `describe`: history is cut where the workspace chooses | `safe_git_refuse` |

`-c protocol.allow=never` stops a lazy fetch over `ssh`, but not over a protocol the workspace allows by name: `protocol.ext.allow=always` in `.git/config` overrides `protocol.allow`, and an `ext::` remote URL then runs a command. It stays in the form as a second layer; `GIT_NO_LAZY_FETCH=1` and the refusal are what close the lazy fetch.

`GIT_CONFIG_NOSYSTEM=1` and `GIT_CONFIG_GLOBAL=/dev/null` keep the host's own configuration out, so the result does not depend on the machine. `core.fsmonitor=false`, `diff.external=`, `protocol.allow=never`, `core.hooksPath=/dev/null` and `GIT_TERMINAL_PROMPT=0` are second layers: no query in the table reaches the setting they blank, and they cost nothing and keep a fsmonitor, hook or password prompt from ever starting.

## Why git status is banned

`git status` compares the worktree with the index. When a file's stat data does not match the index, which the workspace can arrange, git hashes the file again and runs the clean filter that `.git/info/attributes` and `.git/config` name. Neither `--attr-source` nor `GIT_ATTR_SOURCE` stops it, because both replace only the `.gitattributes` files of the tree and `.git/info/attributes` still applies. No option turns off a filter whose name the workspace chooses, so `git status` cannot be made safe. The review needs nothing from it: the workspace holds one commit, and `rev-parse HEAD` checks which.

## Evidence

[tests/reviewer-git-safety-test.sh](../../../../tests/reviewer-git-safety-test.sh) takes the two functions from the block above and builds one hostile repository per vector in this file's table, each pointing the setting at a program that writes a marker file. For each vector it shows that the plain command writes the marker, so the vector is live, and that every query in the table, run in this form, writes none. It also shows that `-c protocol.allow=never` alone does not stop an `ext::` lazy fetch and that `git status` still runs a clean filter in this form.
