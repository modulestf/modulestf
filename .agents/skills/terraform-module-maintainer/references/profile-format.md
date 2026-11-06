# Profile Format

> **Part of:** [terraform-module-maintainer](../SKILL.md)
> **Purpose:** What a profile is, format 1 of its constants, the options it can relax and the rules each option turns off, how a run selects a profile, and how to make, verify and update a custom one.

## The profile directory

A profile is one self-contained directory. It links to no other profile and holds no symbolic link.

| File | Required | What it holds |
|------|----------|---------------|
| `PROFILE.md` | yes | The rules of the module family and its [constants blocks](#format-1). Its first heading is `# Profile: <name>` |
| `code-conventions.md` | no | Code rules the reviewer's checks link to |
| `SCOPE.md` | no | What belongs in a module of the family |
| `templates/` | no | Files copied into a module as they are |
| `templates-map.md` | no | Where each template goes |
| `review-guide.md` | no | The profile restated for another code reviewer |
| `pr-description.md` | no | What a pull request body holds |

A file the profile omits means only the generic rules of the skills apply where a rule links to it. The reviewer's checks link to the files of the default profile, [terraform-aws-modules](../profiles/terraform-aws-modules/PROFILE.md); under another profile each link means the selected profile's file of the same name, and the same section in it.

A `based-on:` line in `PROFILE.md` is a note for the people who keep the profile, naming the shipped profile and the release it was copied from. No tool and no skill loads it.

## Format 1

The constants are fenced blocks with the info string `profile-constants`, in `PROFILE.md`, in the grammar its [Profile constants](../profiles/terraform-aws-modules/PROFILE.md#profile-constants) section gives. Format 1 is exactly these nine blocks and keys. An unknown block or key makes the profile invalid.

| Block | Keys |
|-------|------|
| `required-files` | `root`, `submodule`, `example`, `example-dirs` |
| `regions` | `primary`, `secondary` |
| `argument-order` | `first`, `last` |
| `template-destinations` | one key per file under `templates/`, the value its destination; no key when the profile ships no templates |
| `profile-owned-files` | `verbatim`, `workflow-dir` |
| `tooling` | `files`, `dirs` |
| `banner` | `line` |
| `adjunct-types` | `types` |
| `profile-options` | `format`, `consumers`, `partitions`, `examples`, `release` |

A key written `<key>:` with nothing after the colon has the empty value: an empty list, or no value for a key that holds one. A key written with a colon, a space and nothing else is invalid. Only these keys may be empty: `example` and `example-dirs` of `required-files`, `verbatim` and `workflow-dir` of `profile-owned-files`, `files` and `dirs` of `tooling`, and `line` of `banner`. An empty `workflow-dir` owns no workflow, and an empty banner `line` asks for no banner.

### Profile options

The `profile-options` block states which conventions of the default family the profile relaxes. Its keys and values are a closed set:

| Key | Values | Default |
|-----|--------|---------|
| `format` | `1` | `1` |
| `consumers` | `public`, `in-repo` | `public` |
| `partitions` | `portable`, `fixed` | `portable` |
| `examples` | `required`, `none` | `required` |
| `release` | `registry`, `none` | `registry` |

- A profile with no `profile-options` block has the defaults.
- A profile relaxes when any value differs from its default.
- An unknown format, key or value makes the profile invalid.
- `examples: none` with a non-empty `example` or `example-dirs` in `required-files` makes the profile invalid.

What each value means:

- `consumers: public`: the modules are published and called from repositories the review cannot see. `in-repo`: every caller is a root module in the same repository.
- `partitions: portable`: the modules run in every AWS partition. `fixed`: they run in one partition only.
- `examples: required`: each module ships examples under `examples/`. `none`: the callers in the repository are the examples.
- `release: registry`: releases are cut from commit titles and published. `none`: the repository has no release process of the family's kind.

## Gate table

A value in this table makes only the rules in its row not applicable. `mtf-facts` holds the same table and reports each of those rules `not_applicable` with the reason `profile_option`. The review never judges a gated rule, on any path: with the facts report, without it, or after a failed `mtf-facts` run.

| Option | Rules made not applicable |
|--------|---------------------------|
| `partitions: fixed` | `structure.arn-partition-hardcoded` |
| `examples: none` | `examples.disabled-call-missing`, `examples.submodule-missing`, `examples.versions-missing`, `examples.feature-undemonstrated`, `examples.argument-undemonstrated` |
| `release: none` | `profile.commit-type-mismatch`, `profile.title-uninformative`, `profile.title-misspelling`, `profile.unrelated-change-bundled`, `profile.changelog-handwritten`, `profile.release-config-changed`, `profile.owner-identifier`, `profile.provider-meta-missing`, `profile.migration-notes-misplaced`, `profile.template-drift` |

`profile.required-file-missing` is not gated by `examples: none`: such a profile empties its `example` and `example-dirs` instead. `consumers: in-repo` gates no rule. It only feeds the downgrade below.

## Downgrade

Under `consumers: in-repo`, `mtf-facts` lists in `in_repo_downgrade` each module area whose callers all live in the repository and all change in the same change: the change has a base or a diff and is no full-tree run, the caller scan is complete, the module has at least one caller, and every caller file changed. Its candidates of these five rules in those areas carry `downgrade: "in-repo"`:

- `compat.variable-removed`
- `compat.variable-now-required`
- `compat.type-narrowed`
- `compat.default-changed`
- `compat.generated-policy-narrowed`

A confirmed break of a marked candidate is MEDIUM, whether it was an undeclared CRITICAL or a declared HIGH, and its `summary` says: callers in this repository change in the same pull request; confirm each still works. The downgrade happens only through that marker, never from the profile, the prose or the review's own reading. The MEDIUM `compat.default-changed` already has for a cosmetic change is unchanged.

These two never downgrade:

- `compat.resource-address-changed`
- `compat.version-constraint-raised`

## Selection

A run selects the profile only from the user's own request, never from the workspace, the change or its discussion. The selection decides which profile files a run reads, and nothing else.

- `profile: <id>`: one path segment of `a` to `z`, `0` to `9` and `-`, naming a directory under this skill's `profiles/`.
- `profile-dir: <absolute path>`: a custom profile.
- Neither: `terraform-aws-modules`.

A run refuses, with a message that names no path:

- both lines given;
- an id that names no shipped profile, or a shipped profile whose `# Profile:` name is not its directory name;
- a `profile-dir` that is not absolute, or that lies inside the workspace or inside any git checkout;
- a profile that fails `mtf-facts profile-check`;
- a profile that relaxes, when the `mtf-facts` installed has no `profile-check`, or its report has no `in_repo_downgrade`.

Each run takes one snapshot, `mtf-facts profile-snapshot --profile-dir <dir>`, and every later step reads the profile from the snapshot's `dir` only. The command prints `{dir, tree_sha256, profile_sha256}`. `profile_tree_sha256` is that `tree_sha256`: the sha256 of the sorted lines `<sha256 hex>  <relative path>` with a line feed, one per file of the snapshot. Without an `mtf-facts` that has `profile-snapshot`, only a shipped profile that relaxes nothing runs, read in place, and `profile_tree_sha256` is `none`.

Public output names the profile as `shipped:<id>` or `custom`, with `profile_tree_sha256`. It never prints the path of a custom profile.

## Profile fit

The reviewer adds one profile fit line: whether the change's repository looks like the selected profile's declared options. Examples under `examples/` beside `examples: none`, a module no root in the repository calls beside `consumers: in-repo`, or release configuration beside `release: none` do not fit. The line is advice. It never selects a profile and never changes a severity.

## Make a custom profile

1. Copy a shipped profile to a directory outside any module repository and outside any git checkout: [in-repo-modules](../profiles/in-repo-modules/PROFILE.md) for in-house modules called by roots in the same repository, or [terraform-aws-modules](../profiles/terraform-aws-modules/PROFILE.md) for published modules. Copy files, not links.
2. Change the first heading to `# Profile: <your name>`, and add a `based-on:` line naming the profile and the skills release you copied.
3. Set the `profile-options` block to what your modules do. Relax only what is true: each relaxed value turns rules off, as the [Gate table](#gate-table) says.
4. Edit the other constants blocks, the rules in `PROFILE.md` and any optional file. Delete an optional file you do not want; its rules then fall back to the generic ones. Keep each template valid and named in `template-destinations`.
5. Name the directory with `profile-dir: <absolute path>` in your request to the reviewer, the pull request review or the maintainer.

## Verify a custom profile

1. Run `mtf-facts profile-check --profile-dir <dir>`. Exit 0 is a valid profile; exit 1 lists the problems; exit 2 is input it could not read. It prints one JSON object: `valid`, `problems`, the `options` and whether they are `relaxing`.
2. Run it with `--gates` to add the gate table and `gated_rules`, the rules your options turn off, and with `--downgrade-ids` to add `downgrade_ids`, the rules that may downgrade.
3. Review a change you know the answer to, naming the profile with `profile-dir:`, and check the findings and the profile fit line.
4. Compare the `profile_tree_sha256` the review prints with the one from `mtf-facts profile-snapshot --profile-dir <dir>`. Pin that value where you run reviews, so a changed profile shows.

## Update a custom profile

1. After upgrading the skills or `mtf-facts`, run `mtf-facts profile-check` on the profile again.
2. Diff the profile against the new release of the shipped profile its `based-on:` line names, and carry over the changes you want.
3. A new format is refused loudly by `profile-check`, never read half way. Every format change ships as a breaking change (`feat!`) of the skills, with the migration in its release notes.
4. Update `based-on:` and the pinned `profile_tree_sha256`.
