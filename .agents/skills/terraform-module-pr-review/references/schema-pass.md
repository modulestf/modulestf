# Schema Pass

> **Part of:** [terraform-module-pr-review](../SKILL.md)
> **Purpose:** The host step that resolves provider versions per module directory and renders host fact sheets from a schema mirror: its inputs, the version rules, the downloads, the fact sheet format, the output layout and the reason codes. The reviewer reads the output as its [Budget](../../terraform-module-reviewer/references/large-changes.md#budget) says.

The pass is one script, [schema-pass.sh](schema-pass.sh), with its renderer in [schema-facts.jq](schema-facts.jq). A host runs it from its own checkout of this repository pinned by commit, never from the head, with no credential of any kind, and hands the reviewer the output directory and the versions line. Nothing it downloads is run: the schema is data for `jq`, and a fact sheet is data for the reviewer under Rule 3. `tests/schema-pass-test.sh` checks the script and the renderer with the network stubbed.

```sh
SCHEMA_PROVIDERS="<tokens>" SCHEMA_TYPES="<tokens>" MODULESTF_SCHEMA_MIRROR="<owner>/<name>" \
  SCHEMA_HEAD="<sha>" SCHEMA_MERGE_BASE="<sha>" SCHEMA_INPUTS="<tokens>" \
  bash schema-pass.sh <facts output directory> <work directory> [<handoff directory>]
```

With a handoff directory, the same run also writes the [schema handoff](#schema-handoff) for the facts engine.

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

Per run: 32 providers, 96 provider versions, taken in provider order (by count of needed types, most first, then by name) and within a provider latest, minimum, then old floor, and 1000 types in name order. Past a cap: `overflow`.

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
```

- **Flags:** only the ones that are true; `optional` and `computed` can both appear. A block line carries `deprecated` only.
- **Order:** attributes first, then blocks, each by name.
- **Limits:** `single` is `max 1`, an omitted `min_items` is 0, an omitted or 0 `max_items` on `list`, `set` or `map` is `unlimited`, and `group` shows no limits: `block <name> (group)`.

A type is read from sheets only when every version it is needed at is `sheet` or `absent`. A type that is a miss, unresolved or over a cap at any of them is `page` at every one, and its sheets are removed.

## Output

- `versions.json`: `{"format": 1, "directories": {"<dir>": {"<namespace>/<name>": {"latest", "minimum", "old_floor", "old_floor_unresolved"} or {"unresolved": "<reason>"}}}}`, with `!<local>` in place of the provider for a `registry_host` source.
- `<namespace>/<name>/<version>/index.json`: `{"provider", "version", "schema_sha256", "types": {"<resource|data>:<type>": "sheet" | "absent" | "page"}}` for every type needed at that version.
- `<namespace>/<name>/<version>/<resources|data-sources>/<type>.facts`: one sheet per `sheet` entry, the full type name.
- `files.sha256`: the SHA-256 of every other file, written last.

Each provider version is built in its own staging directory and moved into the output only after every check passed, so a step killed part-way publishes whole versions or none of them. The work directory also gets `wanted-pages`: for a host page cache, each needed version of a `page` type and the latest version of every other type. A type whose name does not start with `<name>_`, such as a `google-beta` type, has no page cache path and is left out; the reviewer fetches its page itself, which changes cost only.

A host checks the output again before a reviewer sees it: `files.sha256` must name every other file exactly once with a matching hash, every file must be a regular file under a size cap at an output path, and `versions.json` must have the shape above. Any mismatch discards the whole output; the page cache is separate and stays.

## Schema Handoff

The input of the facts engine: `<handoff directory>/schema-handoff.json.gz`, one gzipped JSON document in the shape of `schema/schema-handoff.schema.json` in the `modulestf/facts` repository. The reviewer never reads it.

- **Commits:** `head_sha` and `merge_base_sha`, from `SCHEMA_HEAD` and `SCHEMA_MERGE_BASE`, each 40 lowercase hex.
- **Inputs:** `SCHEMA_INPUTS` holds one token per `.tf` file the needs were read from, `<commit>:<SHA-256>:<path>`, the path relative to the repository root, up to 9 segments of `^[A-Za-z0-9._-]{1,64}$`, none `.` or `..`, ending in `.tf`. Per revision, `inputs.head` and `inputs.merge_base` list each path once with its SHA-256, sorted by the bytes of the path, and `tree_hash` is the SHA-256 of the lines `<sha256>  <path>` in that order, the layout of `sha256sum` output. A token for the same file in both revisions, as when the merge base is the head, counts once in each.
- **Directories:** per head directory and `required_providers` local name, or the provider's name when it has no entry there, with the source as `registry.terraform.io/<namespace>/<name>`: `latest`, `declared_minimum` and `old_floor` as in [Versions](#versions), except that the old floor is given even when it equals the minimum, and is `null` when the merge base has no `required_providers` entry for that provider in that directory. Otherwise one `unresolved_reason`: the pair's reason; `no_lower_bound` when the head constraints have no lower bound; or `old_floor_` and the reason when the old floor is unresolved, `old_floor_no_lower_bound` when the merge base constraints have no lower bound. A local name outside `^[a-z][a-z0-9_-]{0,63}$` and a source on another registry host are left out.
- **Provider schemas:** for each provider version read from the mirror, every resource and data source type, filtered by [schema-handoff.jq](schema-handoff.jq): attribute names with `required`, `optional`, `computed` and `deprecated` when true, nested attribute types, nested block names, nesting modes and item limits, and the type's own deprecation. Every other field is dropped, descriptions and cty types included. A name outside the fact sheet name pattern, a flag that is not a boolean, an unknown nesting mode or a `group` nested attribute type fails the whole version, which is then left out: a type left out alone would read as absent from the schema. The fact sheets do not depend on it.
- **Caps:** at most 128 MiB uncompressed and 16 MiB gzipped, both recorded in `caps`.

There is no handoff, and the step output says `schema pass: no handoff, <code>`, when: a commit is missing or not 40 hex (`no_commits`); a token is outside its pattern (`inputs`); a token names a commit other than the head or the merge base (`sha_mismatch`); one path has two hashes in a revision (`duplicate_path`); the document cannot be built (`json_shape`); it is over a cap (`cap_exceeded`); or it cannot be moved into the handoff directory (`write_failed`). The document is built in the work directory and moved into place whole, so a run publishes all of it or nothing. The fact sheets and `versions.json` are written either way, and no handoff refusal fails the run.

What the gate reads as the inputs, which a consumer that compares tree hashes must match: every git tree entry of type blob whose path ends in `.tf`, at the head and at the merge base, except a blob over 1 MiB and a symbolic link (mode `120000`), which are left out. A consumer whose own file set differs in either case gets another tree hash and treats the handoff as not covering that revision. When the merge base cannot be read, the gate reads the base branch for the needs and gives no inputs and no merge base, so there is no handoff.

## Reason Codes

The step's own output and a job summary carry these codes only, never a URL, a response body or `curl` output: `not_in_mirror`, `network`, `http_error`, `rate_limited`, `host_rejected`, `redirect_limit`, `cap_exceeded`, `schema_too_large`, `checksum`, `manifest`, `json_shape`, `constraint_unparsable`, `constraint_unsatisfiable`, `registry_host`, `overflow`.

## Limits

- Each directory is resolved as its own root, so its versions can differ from those of a whole configuration that combines several directories' constraints.
- The checksums prove an intact download from the same origin, not an honest publisher. The mirror's releases are immutable and its tags protected, and each sheet's `schema_sha256` shows any drift between runs.
- Out of scope: caching schemas across runs, an alert on the rate of misses, a provider allowlist for MCP and page fetches, an automated check of the mirror's immutability, and ephemeral resources and provider functions.
