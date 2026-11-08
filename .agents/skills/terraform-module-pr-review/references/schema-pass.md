# Schema Pass

> **Part of:** [terraform-module-pr-review](../SKILL.md)
> **Purpose:** The host step that resolves provider versions per module directory and renders host fact sheets from a schema mirror: its inputs, the version rules, the downloads, the fact sheet format, the output layout and the reason codes. The reviewer reads the output as its [Budget](../../terraform-module-reviewer/references/large-changes.md#budget) says.

The pass is one script, [schema-pass.sh](schema-pass.sh), with its renderer in [schema-facts.jq](schema-facts.jq). A host runs it from its own checkout of this repository pinned by commit, never from the head, with no credential of any kind, and hands the reviewer the output directory and the versions line. Nothing it downloads is run: the schema is data for `jq`, and a fact sheet is data for the reviewer under Rule 3. `tests/schema-pass-test.sh` checks the script and the renderer with the network stubbed.

```sh
SCHEMA_PROVIDERS="<tokens>" SCHEMA_TYPES="<tokens>" MODULESTF_SCHEMA_MIRROR="<owner>/<name>" \
  SCHEMA_HEAD="<sha>" SCHEMA_MERGE_BASE="<sha>" SCHEMA_INPUTS="<tokens>" [SCHEMA_ROOT="<module root>"] \
  bash schema-pass.sh <facts output directory> <work directory> [<handoff directory>]
```

With a handoff directory, the same run also writes the [schema handoff](#schema-handoff) for the facts engine. With `SCHEMA_DEPTH` set, the run is in a [depth mode](#depth-modes).

## Inputs

Tokens read from the `.tf` text of the head and of its merge base with the base branch (the `base` revision), never by running anything. Every token is checked again against these patterns before use, and a token that fails is dropped.

- Provider, per revision and module directory: `<rev>:<dir>:<local>=<namespace>/<name>:<constraint>`, the constraints of that local name joined by commas, spaces removed; `<rev>:<dir>:!constraint_unparsable` for a directory whose `required_providers` could not be read or gives a local name two sources; `<rev>:<dir>:<local>=!registry_host` for a source on another registry host.
- Type, per head directory: `<dir>:<resource|data>:<type>:<namespace>/<name>`, bound by the block's `provider` argument, else the type's prefix, then that local name's source, else `hashicorp/<local>`. The builtin `terraform` provider's types get no token.
- Patterns: `rev` `head` or `base`; namespace and name `^[a-z0-9][a-z0-9-]{0,63}$`; local name `^[A-Za-z][A-Za-z0-9_-]{0,63}$`; version `^[0-9]{1,5}\.[0-9]{1,5}\.[0-9]{1,5}$`; type `^[a-z][a-z0-9_]{0,127}$`; directory `.` or up to 8 segments of `^[A-Za-z0-9._-]{1,64}$`, none `.` or `..`; constraint `^[0-9A-Za-z.,<>=~! -]{0,64}$`, anything else resolved as unparsable.

## Versions

One fetch per provider of `https://registry.terraform.io/v1/providers/<namespace>/<name>/versions`. The candidates are the stable `x.y.z` versions only: a pre-release, build metadata, a `v` prefix or a segment of more than 5 digits is skipped, and segments compare as integers.

Constraints follow Terraform: `=`, `!=`, `>`, `>=`, `<`, `<=`, `~>`, a bare version meaning `=`, a comma meaning AND, and a partial version padded with zeros. `~> 1.2` is `>= 1.2.0, < 2.0.0`; `~> 1.2.0` is `>= 1.2.0, < 1.3.0`; `~> 1` is `>= 1.0.0, < 2.0.0`. Any other operator, such as `*` or `||`, is `constraint_unparsable`.

Per head directory and provider, with the directory's constraints:

- **Latest:** the highest candidate that satisfies them.
- **Minimum:** the lowest candidate that satisfies them, only when they have a lower bound (`=`, a bare version, `>=`, `>` or `~>`).
- **Old floor:** the lowest candidate that satisfies the base's constraints for the same directory and provider, when those have a lower bound, given only when it differs from the minimum or there is no minimum. A base constraint that is unparsable, a base directory that is unresolved, or a base constraint no candidate satisfies gives `old_floor_unresolved` with `constraint_unparsable` or `constraint_unsatisfiable`, never a silent gap.
- A provider a head type is bound to with no `required_providers` entry is unconstrained: latest only.
- No candidate satisfies them: `constraint_unsatisfiable`. The version list could not be read: its reason. Either way the pair is unresolved.

## Downloads

Fixed URL templates only: the registry list above, and `https://github.com/<mirror>/releases/download/<namespace>_<name>-v<version>/<file>`. The only URL taken from a response is a `Location` header, and each is checked before the next request:

- No `-L`: `curl --max-redirs 0`, one hop at a time, at most 3 hops (`redirect_limit`). A hop needs status 301, 302, 303, 307 or 308, and its body is not read.
- A relative `Location` is resolved against the request URL. The result must be `https`, with no user information and no port, on a host that is exactly one of `github.com`, `objects.githubusercontent.com`, `release-assets.githubusercontent.com` for the mirror, or `registry.terraform.io` for the version list, compared in lower case (`host_rejected`).
- TLS is always verified. No request carries a credential header, and the step holds no token.
- `--connect-timeout 10` and `--max-time 120` per request, three tries with a pause. 403 and 429 are `rate_limited`, other failures `http_error` or `network`; a 404 from the mirror is `not_in_mirror`.
- Every body goes to a file with `-o`, capped with `--max-filesize` and checked in bytes before any parser reads it: `SHA256SUMS` 4 KiB, `manifest.json` 16 KiB, the version list 2 MiB, the gzipped schema 8 MiB, the decompressed schema 128 MiB (`cap_exceeded`, or `schema_too_large` for the schema).

Per provider version:

- **Assets:** `<namespace>_<name>-<version>.schema.json.gz`, `manifest.json` and `SHA256SUMS`.
- **Checksums (`checksum`):** from `SHA256SUMS`, the exact lines for the schema and `manifest.json`, each once, checked with `sha256sum --strict -c`.
- **Manifest (`manifest`):** must name this provider, version and schema file, with a `format_version` matching `^([0-9]+)\.[0-9]+$` of major 1.
- **Schema (`json_shape`):** the same `format_version` rule, and `provider_schemas` holding exactly one key, `registry.terraform.io/<namespace>/<name>`.

## Caps

Per run: 32 providers, 96 provider versions, taken in provider order (by count of needed types, most first, then by name) and within a provider latest, minimum, then old floor, and 1000 types in name order. Past a cap: `overflow`. The bisect downloads of [Introduced Versions](#introduced-versions) count toward the 96 too, after every other version.

## Fact Sheets

One `jq` pass per provider version, the needed types given with `--argjson`, never as program text. A resource type is read from `resource_schemas`, a data source from `data_source_schemas`. The collection missing is a miss; the type missing from a present collection is `absent`.

The walk reads `.block.attributes`, `.block.block_types.<name>.block` recursively, and each attribute's `nested_type.attributes` recursively. Allowlisted fields only:

- An attribute's `type`, `nested_type`, `required`, `optional`, `computed`, `sensitive`, `write_only` and `deprecated`.
- A `nested_type`'s `nesting_mode`, `attributes`, `min_items` and `max_items`.
- A block type's `nesting_mode`, `min_items`, `max_items` and `block`, and that block's `deprecated`.
- The type's own `block.deprecated`, as the header line `deprecated: true`.

Any other key is ignored, and a missing flag is false. Descriptions and every other free text are dropped. A cty type decodes into `string`, `number`, `bool`, `dynamic`, `list(T)`, `set(T)`, `map(T)`, `object({n=T})` or `tuple([T])`. A type outside that grammar, a flag that is not a boolean, a name outside `^[a-z_][a-z0-9_]{0,127}$`, or a sheet over 256 KiB makes the type a miss.

The layout is fixed and sorted:

```text
provider: <namespace>/<name>
version: <x.y.z>
category: resource | data source
type: <type>
source: mirror schema
schema_sha256: <SHA-256 of the gzipped schema>
deprecated: true   (only when the resource or data source type itself is deprecated)

<name>: <type>; required|optional; computed; sensitive; write_only; deprecated
attr <name> (<mode>, min N, max M|unlimited); <flags>
  <nested attributes, indented>
block <name> (<mode>, min N, max M|unlimited); deprecated
  <the block's attributes and blocks, indented>

introduced:   (only at a latest version, as in Introduced Versions)
since: <path> <x.y.z>
since: <path> unresolved <reason>
since: <n> more paths unresolved overflow
```

- **Flags:** only the ones that are true; `optional` and `computed` can both appear. A block line carries `deprecated` only.
- **Order:** attributes first, then blocks, each by name.
- **Limits:** `single` is `max 1`, an omitted `min_items` is 0, an omitted or 0 `max_items` on `list`, `set` or `map` is `unlimited`, and `group` shows no limits: `block <name> (group)`.

A type is read from sheets only when every version it is needed at is `sheet` or `absent`. A type that is a miss, unresolved or over a cap at any of them is `page` at every one, and its sheets are removed.

## Introduced Versions

The first version that has an argument or block, for `coverage.argument-above-min-version`, found from the mirror with no model and no page.

- **Paths:** per directory and type with a sheet at both the latest version and the declared minimum, every attribute and block path of the latest sheet that the minimum sheet lacks. A path is the names from the top of the sheet down, joined with `.`, such as `gamma.x`. A path under a new block is listed too, since it can be newer than the block.
- **Search:** presence is assumed monotone from the introducing version up to the latest. The candidates are the stable versions of [Versions](#versions) from the minimum to the latest. Every version the run already read is an observation, from its sheet or its `absent` entry. While the lowest version observed with the path and the highest version below it observed without the path have candidates between them, the candidate halfway between is read, as in [Downloads](#downloads) with every check, for every open path of the provider at once. Paths are taken by type and path name. A bisect version is never published.
- **Result:** the lowest version with the path, when the candidate below it was observed without it: `since: <path> <x.y.z>`. Both ends are read, never inferred. Otherwise `since: <path> unresolved <reason>`:
  - `non_monotone`: a version above the lowest one with the path was observed without it.
  - A reason of [Reason Codes](#reason-codes) for a version the search needed that could not be read, such as `not_in_mirror` for a version the mirror lacks. Every path that needs that version takes the same reason.
  - `overflow`: a bisected path still open when the downloads or the deadline below run out.
- **Count line:** `since: <n> more paths unresolved overflow`, at most one per sheet and last in its section, counts the paths of that sheet with no line of their own: those past the paths cap and those past the section bytes. It names no path. Every new argument with no line of its own goes to the fetch helper.
- **Caps:** at most 16 paths per type and 12 bisect downloads per provider (`MAX_SINCE_PATHS`, `MAX_SINCE_DOWNLOADS`), within the 96 provider versions of [Caps](#caps). A failed download counts. Paths past 16, in name order, are not searched and are only counted in the count line. A bisected path still open when the downloads run out is `unresolved overflow`. Bisection needs about log2 of the candidates per introducing version, so 12 downloads cover a few distinct introducing versions over a hundred candidates.
- **Deadline:** the whole search stops starting downloads after 120 seconds of wall clock (`MAX_SINCE_SECONDS`; the host may set another whole number of seconds in `SCHEMA_SINCE_SECONDS`). Every path still open then is `unresolved overflow`, and the pass prints `schema pass: introduced deadline of <n> s passed, open paths unresolved overflow`. A download that started before the deadline is not cut short, so the search can end up to one download's time limits after it.
- **Section bytes:** at most 8192 bytes of path lines per run (`MAX_SINCE_BYTES`), taken in sheet path and then path order, plus the count lines. A path keeps its line while the lines so far, itself included, fit. The first path that does not fit, and every path after it in the run, gets no line and is counted in its sheet's count line instead. This cap is the section's own.
- **Layout:** the lines are sorted by path, after a blank line and the line `introduced:`, at the end of the sheet that holds the latest version's sheet, after any [deduplication](#depth-modes). The section is written after every sheet cap is checked and is outside them: the focused and deep caps, and the byte counts of the run's lines, take each sheet without its introduced section.
- **Failures:** no result here is a failure of the run. It adds no reason, never escalates a focused run and never makes a deep run partial; an `unresolved` line sends the reviewer to its fetch helper for that path only, and a count line for the new arguments of that type with no line of their own.
- **Output:** `schema pass: introduced <n> paths, <u> unresolved, <d> bisect downloads` when there is a path, and in a depth mode a source line per bisect version that no other step read.
- **Limits:** a path removed and added again between two versions the search reads is not seen; only the found version and the one below it are read for certain. Presence is taken from the sheet layout, so a path is present when its name is, whatever its type or flags.

## Output

- `versions.json`: `{"format": 1, "directories": {"<dir>": {"<namespace>/<name>": {"latest", "minimum", "old_floor", "old_floor_unresolved"} or {"unresolved": "<reason>"}}}}`, with `!<local>` in place of the provider for a `registry_host` source.
- `<namespace>/<name>/<version>/index.json`: `{"provider", "version", "schema_sha256", "types": {"<resource|data>:<type>": "sheet" | "absent" | "page"}}` for every type needed at that version, and in a [depth mode](#depth-modes) `same_as` for a sheet kept at another version.
- `<namespace>/<name>/<version>/<resources|data-sources>/<type>.facts`: one sheet per `sheet` entry, the full type name.
- `missing.json`: in deep mode only, every type without a sheet, as in [Depth Modes](#depth-modes).
- `files.sha256`: the SHA-256 of every other file, written last.

Each provider version is built in its own staging directory and moved into the output only after every check passed, so a step killed part-way publishes whole versions or none of them. The work directory also gets `wanted-pages`: for a host page cache, each needed version of a `page` type and the latest version of every other type. A type whose name does not start with `<name>_`, such as a `google-beta` type, has no page cache path and is left out; the reviewer fetches its page itself, which changes cost only.

A host checks the output again before a reviewer sees it: `files.sha256` must name every other file exactly once with a matching hash, every file must be a regular file under a size cap at an output path, and `versions.json` must have the shape above. Any mismatch discards the whole output; the page cache is separate and stays.

## Depth Modes

`SCHEMA_DEPTH=<run>/depth.json` selects the mode of that file's `depth`, `focused` or `deep`; the run script runs it before the reviewer starts. Focused needs whole provider facts or none, so any gap escalates the run to deep. Deep is already the widest depth, so a gap only means fewer sheets.

```sh
SCHEMA_DEPTH="<run>/depth.json" bash schema-pass.sh <facts output directory> <work directory>
```

- **Inputs:** the tokens come from `depth.json`, never from `SCHEMA_PROVIDERS` or `SCHEMA_TYPES`: `schema_providers` as given, `schema_types`, and `schema_locks`, one `<dir>:<namespace>/<name>=<x.y.z>` per provider of a head lock file. Focused takes only the `schema_types` of a type named in `touched_types`, and reads a base token only for the old floor of a [schema handoff](#schema-handoff), never for a sheet; deep takes every `schema_types` token and the base tokens. The file must be a regular file of at most 1 MiB, an object whose `depth` is `focused` or `deep` and whose four token keys are arrays of strings of 1 to 300 printable characters with no space; anything else escalates with `depth-input`, at either depth.
- **Versions:** per type, the latest allowed and the declared minimum of its directory, as in [Versions](#versions), and every head lock file version of its provider, deduplicated. Deep also reads the old floor; focused reads no old floor sheet, since a change to the constraints is deep by itself, and reads the old floor only for a handoff.
- **Trust anchor:** the mirror is `TRUSTED_MIRROR` in `schema-pass.sh`, `modulestf/terraform-schema-mirror`, a file of the reviewer's own skills checkout at the commit the run records. `MODULESTF_SCHEMA_MIRROR` may be unset or that value; any other value is `mirror-untrusted`, and nothing is downloaded from it. Nothing of the reviewed repository names a mirror or a host. The mirror publishes only the providers it lists, so a provider source outside that list is `not_in_mirror`. Each asset is checked as in [Downloads](#downloads), against the `SHA256SUMS` of the same immutable release.
- **Same sheet at several versions:** when a type's sheets at two or more versions are byte for byte the same below the six header lines that end with `schema_sha256`, one sheet stands for all of them. It is kept at the highest of those versions, with the line `versions: <every version it covers, ascending>` after its `version:` line; its file is removed at the other versions, whose `index.json` still says `sheet` for the type and names the version holding it in `"same_as": {"<resource|data>:<type>": "<version>"}`. The caps count the kept sheets only. A type is `sheet` or `absent` at every version it is needed at, the lock versions included, or `page` at all of them, as in [Fact Sheets](#fact-sheets).
- **Focused caps:** at most 16 sheets and 49152 bytes of sheets in total (`MAX_SHEETS`, `MAX_SHEET_BYTES`), after the sheets are deduplicated; the byte total is the bound on the reviewer's context. An introduced section is outside both caps and is bounded by its own, as [Introduced Versions](#introduced-versions) says. Measured on hashicorp/aws from the mirror, versions 6.71.0, 6.61.0 and 6.28.0: `aws_rds_cluster` 4467 to 4561 bytes, the `aws_cloudwatch_event_bus` data source 505, `aws_ecs_service` 5288 to 5609, `aws_ecs_task_definition` 2294 to 2512, `aws_ecs_cluster` 1135, `aws_security_group` 1122, `aws_vpc_security_group_egress_rule` and `_ingress_rule` 668 and 669; at 6.71.0 `aws_instance` 5920, `aws_db_instance` 4480. So about 8 sheets of the larger types fit in the byte cap; `aws_wafv2_web_acl` has no sheet at all (`page`). The five touched types of one eventbridge change, at 6.71.0 and 6.28.0, are the same at both versions: 5 sheets, 2581 bytes, where 10 sheets would have been read without the deduplication.
- **Deep caps:** at most 64 sheets and 1048576 bytes in total (`MAX_DEEP_SHEETS`, `MAX_DEEP_BYTES`), after the deduplication. The reviewer reads from disk only the sheets its rules need, so these bound the disk, not the context. Types are taken in provider, type and kind order, each with all its sheets or none; a type that does not fit is `page` at every version and `overflow` is noted, and a later, smaller type may still fit. Nothing is truncated.
- **Provenance:** the mirror is pinned by repository name only, so a run also prints one line per provider version read, `schema pass: source <owner>/<name> <namespace>_<name>-v<version> <sha256>`: the mirror, the release tag and the SHA-256 of the gzipped schema file, the same value as `schema_sha256` in that version's `index.json`. The run script copies these lines into the run record, so drift between runs shows. A schema file whose SHA-256 disagrees with its release's `SHA256SUMS` is `checksum`.
- **Focused result:** exit 0 and the line `schema pass: focused, mirror <owner>/<name>, <n> sheets, <bytes> bytes` only when every touched type is `sheet` or `absent` at every version and nothing failed. Otherwise the run prints `schema pass: escalate <reason>`, removes the output directory, publishes nothing, never truncates, and exits 3; the run script then sets depth `deep` with that reason. Any other non-zero exit escalates the same way, and a focused run prints no source line when it escalates.
- **Deep result:** a failure never escalates. The run exits 0, publishes every provider version it completed, and writes `missing.json`: `{"format": 1, "reasons": ["<reason>", ...], "missing": [{"provider": "<namespace>/<name>", "type": "<resource|data>:<type>", "versions": ["<x.y.z>", ...]}]}`, every type that has no sheet with the versions it was needed at, empty when none. The reviewer reads sheets for every other type and takes only the listed ones through its fetch helper. The line is `schema pass: deep, mirror <owner>/<name>, <n> sheets, <bytes> bytes` when nothing failed, else `schema pass: deep partial <reason>, <n> sheets, <bytes> bytes, <m> types without a sheet`, with the first reason met. A refused token or lock token is noted as `inputs` and left out; an untrusted mirror leaves every type without a sheet.

The reasons of both modes are the [reason codes](#reason-codes) with `_` written `-`, and these:

| Reason | When |
|---|---|
| `depth-input` | `depth.json` is missing, a link, over 1 MiB or outside its shape, at either depth |
| `inputs` | a token or a touched type outside its pattern |
| `type-unbound` | focused: a touched type with no `schema_types` token |
| `mirror-untrusted` | `MODULESTF_SCHEMA_MIRROR` names another mirror |
| `page` | a needed type is a miss at a version, so it would be read from pages |
| `overflow` | over the focused or deep caps, or over a cap of [Caps](#caps) |

When a run escalates or is partial for several reasons, the line gives the first one met; `missing.json` lists them all.

## Schema Handoff

The input of the facts engine: `<handoff directory>/schema-handoff.json.gz`, one gzipped JSON document in the shape of `schema/schema-handoff.schema.json` in the `modulestf/facts` repository. The reviewer never reads it.

- **Commits:** `head_sha` and `merge_base_sha`, from `SCHEMA_HEAD` and `SCHEMA_MERGE_BASE`, each 40 lowercase hex.
- **Inputs:** `SCHEMA_INPUTS` holds one token per `.tf` file the needs were read from, `<commit>:<SHA-256>:<path>`, the path relative to the module root `SCHEMA_ROOT` when it is set, otherwise to the repository root, up to 9 segments of `^[A-Za-z0-9._-]{1,64}$`, none `.` or `..`, ending in `.tf`. Per revision, `inputs.head` and `inputs.merge_base` list each path once with its SHA-256, sorted by the bytes of the path, and `tree_hash` is the SHA-256 of the lines `<sha256>  <path>` in that order, the layout of `sha256sum` output. A token for the same file in both revisions, as when the merge base is the head, counts once in each.
- **Directories:** per head directory and `required_providers` local name, or the provider's name when it has no entry there, with the source as `registry.terraform.io/<namespace>/<name>`: `latest`, `declared_minimum` and `old_floor` as in [Versions](#versions), except that the old floor is given even when it equals the minimum, and is `null` when the merge base has no `required_providers` entry for that provider in that directory. Otherwise one `unresolved_reason`: the pair's reason; `no_lower_bound` when the head constraints have no lower bound; or `old_floor_` and the reason when the old floor is unresolved, `old_floor_no_lower_bound` when the merge base constraints have no lower bound. A local name outside `^[a-z][a-z0-9_-]{0,63}$` and a source on another registry host are left out. With `SCHEMA_ROOT`, the module root of a repository whose module is below its root, each directory path is relative to it, the module root itself is `.`, and a directory outside it is left out, as the facts engine names the areas of the module root it lints; the fact sheets and `versions.json` keep the repository-relative directories.
- **Provider schemas:** for each provider version read from the mirror, every resource and data source type, filtered by [schema-handoff.jq](schema-handoff.jq): attribute names with `required`, `optional`, `computed` and `deprecated` when true, nested attribute types, nested block names, nesting modes and item limits, and the type's own deprecation. Every other field is dropped, descriptions and cty types included. A name outside the fact sheet name pattern, a flag that is not a boolean, an unknown nesting mode or a `group` nested attribute type fails the whole version, which is then left out: a type left out alone would read as absent from the schema. The fact sheets do not depend on it.
- **Caps:** at most 128 MiB uncompressed and 16 MiB gzipped, both recorded in `caps`.

There is no handoff, and the step output says `schema pass: no handoff, <code>`, when: a commit is missing or not 40 hex (`no_commits`); a token is outside its pattern, or `SCHEMA_ROOT` is `.` or not a directory of the directory pattern above (`inputs`); a token names a commit other than the head or the merge base (`sha_mismatch`); one path has two hashes in a revision (`duplicate_path`); the document cannot be built (`json_shape`); it is over a cap (`cap_exceeded`); or it cannot be moved into the handoff directory (`write_failed`). The document is built in the work directory and moved into place whole, so a run publishes all of it or nothing. The fact sheets and `versions.json` are written either way, and no handoff refusal fails the run.

What the gate reads as the inputs, which a consumer that compares tree hashes must match: every git tree entry of type blob whose path ends in `.tf`, at the head and at the merge base, except a blob over 1 MiB and a symbolic link (mode `120000`), which are left out. With a module root, the caller passes only the blobs under it, each path relative to it, and sets `SCHEMA_ROOT` to it; the gate does not check that the tokens are relative to `SCHEMA_ROOT`, and tokens that are not give tree hashes no consumer matches. A consumer whose own file set differs in either case gets another tree hash and treats the handoff as not covering that revision. When the merge base cannot be read, the gate reads the base branch for the needs and gives no inputs and no merge base, so there is no handoff.

## Reason Codes

The step's own output and a job summary carry these codes only, never a URL, a response body or `curl` output: `not_in_mirror`, `network`, `http_error`, `rate_limited`, `host_rejected`, `redirect_limit`, `cap_exceeded`, `schema_too_large`, `checksum`, `manifest`, `json_shape`, `constraint_unparsable`, `constraint_unsatisfiable`, `registry_host`, `overflow`.

## Limits

- Each directory is resolved as its own root, so its versions can differ from those of a whole configuration that combines several directories' constraints.
- The checksums prove an intact download from the same origin, not an honest publisher. The mirror's releases are immutable and its tags protected, and each sheet's `schema_sha256` shows any drift between runs.
- Out of scope: caching schemas across runs, an alert on the rate of misses, a provider allowlist for MCP and page fetches, an automated check of the mirror's immutability, and ephemeral resources and provider functions.
