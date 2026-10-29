# Module Scope

> **Part of:** [terraform-module-maintainer](../SKILL.md)
> **Status:** Scope rules for a reusable Terraform module, for any provider. They apply the
> generic concept in [change-scope](../../change-scope/SKILL.md), whose
> [principles](../../change-scope/references/principles.md) this file does not repeat. A
> profile supplies the provider-specific lists and the repository-file rules: for the default
> profile, [terraform-aws-modules scope](../profiles/terraform-aws-modules/scope.md). The
> reviewer's [Check F](../../terraform-module-reviewer/references/check-f-scope.md) enforces
> these rules and gives each its rule_id.

Every rule here is adopted by this skill. None of it describes a written policy of any module
family.

## The module, for scope

A boundary directory is the module root, or a directory under the root's `modules/` at any
depth. The rules read `.tf` and `.tf.json` files in boundary directories, override files
included (`override.tf`, `*_override.tf` and their `.tf.json` forms).

Other directories are not boundary directories:

- `examples/` is a caller's configuration, which is where composition across services
  belongs. An example may declare providers and call remote modules, so no rule here reads it.
- `wrappers/` is generated from the root. Hand-written content there is a defect of its own
  under the profile, not a scope question.
- `tests/`, and any other directory, hold no module code. Whether a file may exist there at
  all is the profile's repository-file rules. The one exception is a
  [test helper directory](#test-helper-directories), which the type rules read.

A block the base revision already carries is not judged again. An addition is a block the
change adds, or a `module` block whose `source` the change edits. A renamed file or directory
is read as [Renamed files and directories](#renamed-files-and-directories) says.

Out of scope for these rules, because none of them adds a managed type or a dependency:
`removed` and `import` blocks, `check` blocks apart from a data block nested in one (its
provider counts, under [Providers](#providers)), `backend` and `cloud` blocks,
`required_version`, and variables, outputs and locals. Other checks own them.

## Outcomes

| Outcome | Severity | Resolved by |
|---------|----------|-------------|
| Ban | HIGH | Removing or moving the addition, or an allow entry on the base first |
| Maintainer decision | MEDIUM, one finding under one rule_id | A maintainer merging the change. A new-submodule decision (B) can also be resolved by allow entries in the base `docs/SCOPE.md`; a no-edge decision (C2) cannot, since no entry creates an edge, and neither can a new-module decision (N1), since its base has no `docs/SCOPE.md` |
| Not evaluated | none | Nothing: an unknown, never a pass |

These are severities on the reviewer's existing ladder. No new rung is added, and a consumer's
verdict ladder does not change.

The rules are strict on purpose. Growth within one service passes only through the prefix
rule, an adjunct, or an allow entry. The first block of a type that none of those admits is a
ban, even when the type plainly belongs to the same service. The cost is one allow entry,
landed on the base before the change.

## The boundary of a directory

For a boundary directory D that exists on the base revision:

- **Managed.** Every type declared in a `resource` block in D on the base.
- **Stems.** The managed types that are not adjuncts.
- **Prefix rule.** A type T is admitted when T begins with a stem followed by `_`. A stem of
  `example_bucket` admits `example_bucket_policy`. The `_` is required, so a stem of
  `example_route` admits `example_route_table` but not `example_route53_zone`.
- **Adjuncts.** The profile's adjunct list.
- **Allowed.** The base record's [Allowed types](#exceptions-docsscopemd).
- **Denied.** The base record's Denied types.

The boundary of D is the managed types, the types the prefix rule admits, the adjuncts and
the allowed types, minus the denied types. Denial applies last, after the prefix rule: a
denied type is outside even when D manages it, a stem admits it, or it is an adjunct.

The boundary is per directory. A type the root manages does not widen a submodule's boundary,
and the reverse holds too.

Every added block inside the boundary needs a [reference edge](#reference-edges) (C2), a
type the prefix rule admits included. So an unrelated type that shares a stem does not pass
silently: with no edge it becomes a maintainer decision.

Data blocks are never checked against the boundary. Reading is not managing. A data block
still counts for [Providers](#providers).

A service key read out of a type name is not part of the derivation. It would widen one
managed type to every type of its service, and it misparses names whose second segment is
not a service.

Without the base revision the boundary cannot be derived, and every rule that reads it
reports not-evaluated.

## Reference edges

A base identity is a block the base revision has in the same directory: `<type>.<name>` for a
resource, `data.<type>.<name>` for a data block, `module.<name>` for a module call. A data
block of a type on the profile's ambient list is not a base identity.

An added `resource` block has a reference edge when either holds:

- an expression in its arguments, its nested blocks, `count` or `for_each` names a base
  identity;
- a base `resource` or `module` block, as the change leaves it, names the added block in the
  same places.

The path may pass through locals and through other blocks the change adds. It may not pass
through a variable: two blocks that read the same `var.*` are not connected by it.
`depends_on` is not an edge, because it orders blocks without passing any value between them.

## Moved blocks

A `moved` block the change adds, from `from` to `to`, gives `to` the base identity of `from`
when all three hold: both addresses have the same type, both are in the same directory, and
the head no longer declares `from`. The block at `to` is then not an addition. Any other
`moved` block gives no identity, and the block at `to` is judged as an addition.

## Renamed files and directories

A rename moves a path. It never carries a block's identity from one directory to another.
What a renamed file adds is read against its old path's base content; how the reviewer
establishes that content, and when it cannot, is in its
[Renamed files](../../terraform-module-reviewer/references/check-f-scope.md#renamed-files).

- **Within one directory.** The blocks the old path had on the base are still base blocks of
  the directory. Only what the change adds to the file is an addition.
- **Into another directory.** Every block in the renamed file is an addition to the directory
  it arrives in, judged there as if written new. A directory's boundary is its own, so a type
  another directory manages does not come with the file.
- **A whole directory.** A directory under `modules/` that is absent from the base is the
  renamed directory O when all of these hold:
  - O is a directory under `modules/` with at least one `.tf` or `.tf.json` file directly in
    it on the base, and at least one such file is renamed into the new directory, so O is
    the one directory those renames come from;
  - every `.tf` and `.tf.json` file directly in O on the base is renamed to a path directly
    in the new directory;
  - every file renamed into the new directory comes from O;
  - the head has no `.tf` or `.tf.json` file directly in O.

  Each file renamed from O into the new directory is then read as a rename within one
  directory, not into another. The new directory's boundary and base identities are O's,
  derived from O's base. Step C of the
  [evaluation order](#evaluation-order) runs on it, not step B, so a directory renamed with
  no other change adds nothing. [Moved blocks](#moved-blocks) read O and the new directory
  as the same directory. A nested directory is tested on its own. When any condition fails,
  the directory is new, step B runs on it, and every block in a file renamed into it is an
  addition.
- **`docs/SCOPE.md`.** The record is the base's file at that exact path. A file renamed into
  it is read as added and supplies no entry. A record renamed away stays in force for the
  change that moves it.

## Providers

**Canonical form.** A provider source compares as `<host>/<namespace>/<type>`, lowercased.
The host defaults to `registry.terraform.io`. A `required_providers` entry with no `source`
means `hashicorp/<local name>`, as Terraform itself reads it.

**Provider of a block.** The local name is the part of the block's `provider` argument before
its first `.` when it has one - `aws` for `provider = aws.west` - otherwise the type name up to
its first `_`. That local name resolves through the
`required_providers` of the block's directory, and to `hashicorp/<local name>` when the
directory does not declare it. The built-in `terraform` provider, which `terraform_data`
belongs to, is never new.

**Base providers** are the union of:

- every source in a `required_providers` entry in any boundary directory on the base;
- the provider of every `resource` and `data` block in any boundary directory on the base;
- the base record's [Allowed providers](#exceptions-docsscopemd).

**Head providers** are the providers of what the change adds, in any boundary directory,
including one the change creates: `required_providers` entries, `provider` blocks, and every
`resource` and `data` block, nested data blocks in `check` blocks included.

## Module sources

A `module` block that is an addition passes when its `source` is a local path that stays
inside the module:

- it begins with `./` or `../`, and contains no `//`;
- normalized lexically against the calling directory, it resolves to a directory under the
  top-level `modules/`, other than the calling directory itself;
- no component of that path is a symbolic link on the head revision.

From the root that is `./modules/<name>`; from `modules/<a>` it is `../<b>`. A directory the
change itself creates satisfies it. A registry address, a Git or HTTP URL, an archive, and a
module of the same family published elsewhere all fail.

## Evaluation order

Rules run in this order, and each addition takes its outcome from the first rule that fires
on it. A base with no boundary directory at all - a whole module offered with no base - takes
[A new module](#a-new-module) in place of A1, B and C.

**A. Every boundary directory, on the base or new.**

1. A head provider that is not a base provider: a ban, one per provider source.
2. A `module` block whose source fails [Module sources](#module-sources): a ban.

**B. A directory under `modules/` that is absent from the base**, and is not a renamed
directory under [Renamed files and directories](#renamed-files-and-directories). It has no
base to derive a boundary from, so its types are read against the adjuncts and the allowed
types only.

1. A type in it that the base record denies: a ban, as anywhere else.
2. Otherwise, when at least one managed type in it is neither an adjunct nor allowed: one
   maintainer decision for the directory, naming the directory and each such type. Adding a
   sibling service in a submodule is growth only a maintainer can accept, so the type rules
   do not fire per type there.
3. A new directory whose types are all adjuncts or allowed is not a case for B.

No edge rule reads a new directory: it has no base block to connect to.

**C. A directory that exists on the base**, or a renamed directory, which takes its old
directory's base.

1. An added `resource` block whose type is outside [the boundary](#the-boundary-of-a-directory):
   a ban, one per type.
2. An added `resource` block whose type is inside the boundary, adjuncts included, with no
   [reference edge](#reference-edges): a maintainer decision, one per block.

A [test helper directory](#test-helper-directories) takes A1, A2 and C1 as that section
reads them, and no B or C2.

**D. Repository files and tooling.** The profile's rules, after C.

Folding into one decision is for the type rules in B and in [A new module](#a-new-module)
only. A profile's file rules are never folded into it, and each reports on its own.

## Test helper directories

A test helper directory is a directory under `tests/` that a native test loads: a `module`
block inside a `run` block of a `tests/*.tftest.hcl` file at the head names it as its
`source`. A source names a directory when it begins with `./` and, read from the module root
and normalized lexically, with `.` components and repeated or trailing `/` removed, it has no
`..` component and equals the directory's path from the module root. So `./tests/setup`,
`./tests/setup/` and `./tests//setup` all name `tests/setup`, and `../tests/setup` and
`./tests/other/../setup` name nothing. A directory under `tests/` that no native test names
is not a test helper directory, and the profile's repository-file rules decide its files.

`terraform test` applies every `run` block unless the block sets `command = plan`, so a helper
creates real resources wherever the tests run. The type rules therefore read a test helper
directory as a boundary directory with no base of its own, against the module root:

- **A1.** A provider of what the change adds in it that is not a [base provider](#providers)
  is a ban. A test helper directory adds nothing to the base providers.
- **A2.** A `module` block the change adds in it passes when its `source` is a local path
  that begins with `./` or `../`, contains no `//`, normalizes against the helper directory
  to the module root or to a directory under the top-level `modules/`, and has no symbolic
  link on the path; or when its whole `source` string matches the pattern the profile gives
  for test helper sources, which fixes the registry host, the namespace and the shape of the
  address. A profile that gives no pattern admits no registry source. Everything else is a
  ban, as under
  [Module sources](#module-sources).
- **C1.** An added `resource` block whose type is outside
  [the boundary](#the-boundary-of-a-directory) of the module root on the base is a ban, one
  per type. Data blocks are not checked against it, as anywhere else.
- No B rule and no edge rule reads it: a helper builds fixtures, which nothing on the base
  refers to.

In [a new module](#a-new-module) there is no base, so a test helper directory is one more
boundary directory in the N1 declaration, and A2 runs on it as above.

## A new module

When the base revision has no boundary directory, there is nothing to derive a boundary from
and no base provider. Read as a change, every provider would be new and every directory
unconnected, so A1, B and C would ban or flag the whole module one piece at a time, and the
root, which is neither on the base nor under `modules/`, would fall under none of them.

A new module is creating something new, so
[Creating something new](../../change-scope/references/activities.md#creating-something-new)
applies: the boundary is declared, not derived. The change is the declaration. It declares
the head providers, and, per boundary directory, the root and each directory under `modules/`,
its managed types. Whether a module with that declaration belongs in the family is one
question, so it is one outcome:

- **N1.** When at least one managed type in any boundary directory is not an adjunct: one
  maintainer decision for the whole module. It names each head provider in
  [canonical form](#providers), and each boundary directory with its managed types that are
  not adjuncts. It replaces A1, B and C: no provider ban, no decision per new submodule, and no
  edge rule, since there is no base block to connect to.
- **N2.** When every managed type is an adjunct, no decision is reported.

A2, [Module sources](#module-sources), still runs on every `module` block, and D, the
profile's repository-file rules, runs with every path new. No base `docs/SCOPE.md` exists, so
there are no allowed, denied or allowed-provider entries. A `docs/SCOPE.md` in the module is
the head's copy and is never read.

Once a maintainer adopts the module, its first commit is the base, and later changes are
judged against it under A to D, not against this declaration.

## Exceptions: docs/SCOPE.md

A module's exceptions live in an optional `docs/SCOPE.md` at the repository root. One file
serves every boundary directory. A file with one purpose, read by exact headings, parses the
same way on every run.

Without the file the module has no exceptions. The file is read from the base revision only.
The head's copy - added, edited or deleted by the change under review - is never read, so a
change cannot clear itself.

```markdown
## Allowed types

- `example_record` - the alias record for the module's own endpoint

## Denied types

- `example_log_group` - callers own log retention for this service

## Allowed providers

- `hashicorp/random` - generates the suffix of the default name
```

- The headings are exactly `## Allowed types`, `## Denied types` and `## Allowed providers`.
  Any other heading, and everything under it, is not read.
- A type entry is a list item whose first element is a code span holding a managed resource
  type. Data sources take no entry: no rule checks them against the boundary.
- A provider entry is a list item whose first element is a code span holding a provider
  source, compared in [canonical form](#providers). A bare name such as `random` reads as
  `hashicorp/random`.
- The text after the code span is the reason, for the people who read the file. No rule reads
  it.
- An allowed type joins every directory's boundary. A denied type leaves it, after the prefix
  rule. A type in both lists is denied.
- An allowed provider is a base provider.
- A remote module source and an addition with no edge take no entry. The first is a ban with
  no exception; the second is a maintainer decision already.

An allowance that repeats across modules moves into the profile's adjunct list.

## Evidence a finding cites

A finding under these rules cites, besides what
[change-scope](../../change-scope/references/principles.md#evidence-a-finding-cites) asks:

- the file and line of the added block;
- the rule, as a link to its heading in this file or the profile's scope file;
- the base fact: the directory's derived boundary and the stem or list entry that did or did
  not admit the type, the missing allow entry or present deny entry in the base
  `docs/SCOPE.md`, the base providers in canonical form, or the base identities the added
  block fails to reach.

The maintainer decision for a new submodule cites the new directory, each type in it that is
neither an adjunct nor allowed, and the fact that the directory is absent from the base. It
names no destination: choosing one is the decision. The maintainer decision for a new module
cites the same way: the head providers, each boundary directory with its managed types that
are not adjuncts, and the fact that the base has no boundary directory.

A claim that two types exclude each other quotes the Terraform MCP schema or the provider
documentation fetched in the same run. No quote, no finding.

## Open questions

- **Wiring through a submodule's inputs.** A new resource in `modules/<a>` whose only link to
  the rest of the module is a variable the root wires from a base block has no edge under
  [Reference edges](#reference-edges), since edges do not pass through variables. It becomes
  a maintainer decision. Whether an edge should cross the module call - from the root's
  argument, through the submodule's variable - is not decided.
