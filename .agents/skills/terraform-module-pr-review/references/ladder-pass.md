# Ladder pass

The L1 level of the verification ladder as one script, [ladder-pass.sh](ladder-pass.sh). It takes the triggers of the classifier report (`mtf-facts behaviour --json`), evaluates each trigger's base and head expression offline in a network-denied sandbox, and writes the ladder record that `mtf-facts claims-eval` reads. It never reads a file of the clone: a fixture holds only the trigger's own expression text, spliced into the skill's template. The script runs with bash and needs `perl`, `jq`, `terraform`, `mtf-facts` and, for acquisition, `curl`.

## Commands

Run each by the absolute path of the installed skill, never from the head or the workspace. `<run-dir>` is the run directory Workspace printed, `<root>/pr-review.XXXXXX`.

| Command | What it does | Exit |
|---|---|---|
| `bash ladder-pass.sh probe <run-dir>` | Builds the sandbox, runs the canary in it, prints the canary lines, then `terraform` with its version and `sandbox proven <kind>`, or `sandbox unproven: <reason>` | 0 proven, 1 not |
| `bash ladder-pass.sh acquire <run-dir> --pins <pins.json> --cache <dir> --schema-out <schema.json>` | Acquisition: the pinned providers into the run's read-only mirror, and `terraform providers schema -json` for `mtf-facts behaviour --schema` | 0 done, 1 `acquisition failed: <reason>`, 2 usage |
| `bash ladder-pass.sh run <run-dir> --behaviour <b.json> --base <sha> --head <sha> --out <ladder.json> [--coverage <coverage.json>]` | L1 for every trigger whose `levels` holds `L1`, at most 40 and 10 minutes, then the ladder record | 0 record written, 2 usage or refused input |

Every command also takes `--owner-pid <pid>`: the long-lived process that owns the review, such as the agent or the runner, named in the run's lease. Pass the same process on every call.

Acquisition is optional. L1 uses only Terraform's built-in provider, so a review without a schema still runs L1; the classifier then fails closed on Optional and Computed attributes. `--coverage` passes the example coverage object of the plan pass into the record; without it the record says class `none`.

## Run layout

Everything lives in `<run-dir>/ladder`, mode 0700, outside the clone.

| Path | Holds |
|---|---|
| `lease` | `<owner pid> <owner start time> <expiry> <token>`, rewritten on every call; owner `0` and start `-` without `--owner-pid`, expiry a day ahead |
| `scratch/` | The only path the sandbox may write: an empty `home/` and `tmp/`, the plans while they are written. Removed when the script exits |
| `fixtures/<trigger>/base`, `head` | `main.tf` and `subject.tf` per side, read-only, checked by fixture-check; `vars/` holds one var file per case, `expect/` the block manifest of each side |
| `plans/` | The raw saved plans, mode 0700, kept for the host |
| `mirror/` | The providers acquisition verified, packed layout, read-only |
| `etc/` | The sandbox profile, the CLI configuration (filesystem mirror only, no direct installation) |
| `out/` | Captured output of each command, under its cap |

At each start the script sweeps sibling runs, `<root>/pr-review.*/ladder`. It removes one only when the owner its lease names is gone: the process id is not running, or runs with another start time, which is a reused id. A lease with no owner goes only once its expiry has passed, a day after its last call. A run directory without a lease is never touched.

## Sandbox

Every command that reads a fixture runs in the sandbox, and the sandbox is proven first. The design was settled by a multi-model consensus review, measured on macOS; see [Decisions](#decisions).

- macOS: `sandbox-exec` with a profile written per run. Later rules win, so it reads as deny, then allow: no network of any kind, no `mach-lookup`, no POSIX or System V IPC, no signal to another process; writes only under `scratch/`; reads only system paths, `scratch/`, `fixtures/`, `etc/`, `mirror/` and the three binaries, and never under `/System/Volumes/Data`; exec only of `terraform`, `/usr/bin/perl` and `mtf-facts` by their real paths. Every path in the profile must match `^/[A-Za-z0-9/._-]+$`, or the run directory is refused.
- Linux: `bwrap --unshare-all --die-with-parent --new-session --clearenv`, read-only binds of `/usr`, `/bin`, `/sbin`, `/lib`, `/lib64`, the tools, `fixtures/`, `etc/` and `mirror/`, a fresh `/proc` and `/dev`, a tmpfs at `/ladder-tmp` for the plugin sockets (not on `/tmp`, which may hold the run directory and would then expose it writable), `scratch/` as the only writable bind, and the tmpfs root remounted read-only, since bwrap makes the mount point directories of the binds on it. Bare `unshare -n` is never used: it isolates the network only, and leaves the host's files and sockets open. On Ubuntu, AppArmor restricts unprivileged user namespaces by default, and bwrap then fails: the host must allow them (`kernel.apparmor_restrict_unprivileged_userns=0`, or an AppArmor profile for `bwrap`), or L1 stays unverifiable there.
- System V and POSIX IPC: macOS denies both in the profile, and bwrap gives the command its own IPC namespace, so a run leaves no IPC object on the host and there is nothing to remove with `ipcrm`.
- Both: the environment is exactly `PATH`, `HOME` and `TMPDIR` in scratch, the CLI configuration, `CHECKPOINT_DISABLE`, `TF_IN_AUTOMATION`, `TF_INPUT=0` and `GOMEMLIMIT`. No credential and no `AWS_*` variable reaches a command.

The canary runs in the same profile and environment, before any other command. Each class must be stopped by the sandbox, not merely unanswered:

| Class | Targets | Accepted on macOS | Accepted on Linux |
|---|---|---|---|
| ipv4 | TCP `1.1.1.1:443` | `EPERM` | `ENETUNREACH`, `EPERM`, `EACCES` |
| ipv6 | TCP `[2606:4700:4700::1111]:443` | `EPERM` | same |
| link-local | TCP `169.254.169.254:80` | `EPERM` | same |
| loopback | TCP `127.0.0.1:9`, `[::1]:9` | `EPERM` | same, or `ECONNREFUSED` from the namespace's own loopback |
| dns | TCP and UDP 53 to every name server in `/etc/resolv.conf` and `1.1.1.1`; on macOS also the `mDNSResponder` socket | `EPERM` | as ipv4; `ECONNREFUSED` only for a loopback name server |
| read, write, exec | A sentinel in `ladder/` outside scratch; the home directory on macOS, a file in it on Linux | `EPERM`, `EACCES` | also `ENOENT`, `EROFS` |

A scratch sentinel must be readable, and on Linux the network namespace must differ from the host's and hold only `lo`. Anything else, such as a connection, a sent datagram, a timeout, another errno, a missing line or a missing tool, leaves the sandbox unproven, and every L1 run of the review is `unverifiable` with the reason `sandbox unproven`. Terraform never runs outside the sandbox. ICMP and raw sockets have no canary: `deny network*` and the namespace cover every socket family, and a raw socket needs root. Run `probe` to see a host's decision with the canary lines; the live CI job holds a Linux runner to `sandbox proven bwrap`.

## Acquisition

- The pin file is the skill's [ladder-pins.json](ladder-pins.json), or one the host passes: per provider the source, the exact version, and per platform an `https` URL and the zip's sha256; and the list of artifact hosts. A URL must be `https://<host>/<path>` with its host on that list exactly. The sha256 is the trust root: the maintainer takes it from the release's `SHA256SUMS` when pinning.
- `curl -q --proto =https --max-redirs 0 --max-filesize 512M` fetches each zip into the cache, with an empty environment and home; the zip is checked before it is renamed into place, and again when it is copied into the run's mirror. A mismatch deletes it and fails. The cache must be a 0700 directory of the user, outside the run directory, and one acquisition at a time holds its kernel lock.
- `terraform init -backend=false` then runs in the sandbox with the network denied and the mirror as the only source. The providers it unpacked are made read-only, and `terraform providers schema -json` runs in a profile that adds only exec of that tree and Unix sockets in its own temporary directory, which the plugin protocol needs. The schema must name exactly the pinned providers. The record's `pins` list each provider's source, version and sha256.

## L1

For each trigger the [template](ladder-templates/l1.tf.tmpl) is filled when the trigger's category is in [l1-categories.json](ladder-templates/l1-categories.json). The inputs and their values come from the classifier, never from the script:

- The inputs are each `referenced_inputs` variable and each `contextual_ref_details` entry of kind `resource` or `data`. A variable's type is parsed and written back by the script; a type outside the grammar (`string`, `number`, `bool`, `any`, `list`, `set`, `map`, `tuple`, `object` with `optional`, no defaults) is unverifiable. A reference's type comes from the entry, or is `string` for `id`; a splat `x.y[*].a` is a list of that type.
- `triggers[].cases` are the required cases, at most 32: each gives every input exactly one state, a known value, a known list or map with some elements unknown, wholly unknown, null, or omitted. A trigger without cases, a case that names other inputs, or an omitted input other than the variable a default change is about is unverifiable.
- Each input becomes a local, `local.ladder_in_<n>`, and the expression reads it: every `var.<name>` and every reference text is renamed as a whole name. The local takes its state from the case's var file: the known value, the value with the listed elements replaced by a `terraform_data` stand-in's output, a stand-in's output for a wholly unknown value, or null. A stand-in's output is a typed unknown, and each stand-in has a canary output that must plan unknown; a `canary_known` output must plan known. Case values only ever reach a var file, never HCL text.
- A default change: the subject is `var.ladder_omit ? (<expression>) : local.ladder_in_<n>`, so an omitted case evaluates the default of each revision and any other case the value the caller passes.
- `count.index` wraps the subject in a counted `terraform_data`, `each.key` and `each.value` in one with `for_each`. `path`, `terraform`, `local`, `module`, `self` or any other kind is always unverifiable at L1: fixture-check refuses every root but `var`, `local`, `each`, `count` and `terraform_data`.

Each side directory holds `main.tf` (variables, stand-ins, locals, canaries) and `subject.tf` (the subject alone, no comment); the var files, one per case, and a manifest per side lie outside them. The manifest lists the exact top-level blocks of each file, type and labels, and the subject's `value` (or `input` when wrapped) as one expression, the last argument of the last block. `mtf-facts fixture-check <side> --level L1 --expect <manifest> --json` checks both sides before any terraform command, so an expression that closes its block and opens another fails with `manifest.block-set`. The side directories are read-only to the sandbox, so the tree fixture-check hashed is the tree that is planned.

Then `terraform validate` on each side: an undeclared name or a broken fixture fails here, and the run is unverifiable. Then, per case and side, `terraform plan -refresh=false -lock=false -out` and `terraform show -json` of the saved plan. A plan that fails with errors located only in `subject.tf` is the expression failing for those inputs, such as `concat(null)`: an observation with `error` true. Any other plan failure makes the run unverifiable.

## Record

The record follows the team contract: `schema_version`, `head_sha`, `base_sha`, `terraform_version`, `pins`, `runs`, `coverage`. A run is `{trigger_id, level: "L1", state, reason, fixture_sha256, control, observations}`:

- `state` is `ran` with `control` `valid` only when the sandbox was proven, fixture-check and validate passed both sides, every plan and show succeeded or failed in `subject.tf` alone, every canary held and no subject is sensitive. Anything else is `unverifiable` with the reason, never a result of "no difference"; a canary that failed sets `control` to `invalid`.
- `reason` is a fixed string: one of the builder's sentences, or fixed words with a side, a case id, an exit status, a category word or rule ids of fixture-check (`fixture-check head: manifest.block-set`). No text of the clone, of a terraform error or of the canary reaches it, so a reason is safe to quote in a comment.
- `fixture_sha256` is the sha256 of `base:<tree>\nhead:<tree>\n`, from the two tree hashes of fixture-check.
- `observations` is `{base: [obs], head: [obs], fixture, sandbox}`, one obs per case id in the classifier's order, an empty list for a side without an expression. An obs is the allowlisted projection of the plan: `case` (the case id), `error`, `known` (wholly known), `wholly_unknown`, `length` (known length of a list, or of a wholly known object), `unknown_mask`, `value` (only when wholly known, not sensitive and at most 4 KiB), `sensitive`, `redacted`, `unknown_inputs` (the inputs unknown in that case), `inputs` (the case as the classifier gave it), and `action` and `unchanged_vs_prior`, null at L1. `sandbox` is the kind, whether it was proven, the profile sha256 and a reason code: `no-sandbox-tool`, `no-terraform`, `no-perl`, `path-characters`, `canary-failed`, `canary-leak`, `canary-incomplete`, `canary-class-missing`, `scratch-unreadable`, `no-network-namespace` or `other`. Canary lines, paths and command output stay in `ladder/out` on the host.

## Limits

| Limit | Value |
|---|---|
| Triggers, time | 40 triggers, 10 minutes per review; every L1 command's timeout is clipped to the time left, and a trigger with none left is `unverifiable` with reason `budget` |
| Per command | plan and show 120 s and 8 MiB output, fixture-check and the canary 60 s, init and schema 300 s, a download 900 s; the schema's output cap is 64 MiB |
| Resources | a file size limit per command (`ulimit -f` in bash, 1024-byte blocks), 2 GiB resident for the command's process tree (6 GiB for the schema), the scratch tree at most 256 MiB |
| Cleanup | each command runs in its own process group, held by an anchor process until the group is killed; inherited descriptors are closed |

Memory is enforced by polling the resident size, not by an address-space limit, which Go programs do not survive. A descendant that starts its own session leaves the process group, so the group kill misses it; no L1 fixture can fork or exec, and bwrap's `--die-with-parent` and its pid namespace cover Linux. L3 runs provider plugins, so the L3 runner must kill the whole process tree or run in a pid namespace on macOS as well.

## Decisions

A multi-model consensus review, three rounds with a security analyst role, settled the sandbox; the engine ended at the round cap with the last revision above. Dismissed: removing perl from the exec list (one profile is what makes the canary binding, and a built-in only fixture has no exec path); an ICMP canary (covered by the network deny); process id reuse in the sweep (a reused id keeps the directory); cleanup of descendants that start a new session (no fixture byte can fork or exec); an exec allowlist inside bwrap (no exec path at L1). Deferred: a provider-backed execution profile, which L3 needs; a cgroup memory limit, which needs a delegated cgroup a laptop lacks. The Linux matrix is measured by the live CI job.
