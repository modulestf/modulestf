# Plan runner

A local prototype of an isolated runner for the plan pass:
`terraform init` and `terraform plan` run inside a container that has no route out except an
egress proxy with a host allowlist, a different one for each phase. It needs a local Docker
runtime and no AWS infrastructure. `run-pass.sh` runs the whole plan pass,
[plan-pass.sh](../plan-pass.sh) in runner mode, there for a list of examples; `run-plan.sh`
runs a bare `init` and `plan` for one example, for the smoke test. The pull request skill's
plan pass calls `run-pass.sh` when a container runtime is available, and runs the laptop pass
otherwise ([Runner or laptop](../plan-pass.md#runner-or-laptop)). The hosted review workflow's
plan job runs `run-pass.sh` on a GitHub-hosted runner for a maintainer's `@modulestf plan` request,
and `hosted-record.sh` reduces its record to `plan-hosted.json`, classes and counts only
([Hosted runner](../plan-pass.md#hosted-runner)). Nothing calls `run-plan.sh` but the smoke test.

## Stated limits

- **Head code sees the credentials and can use any allowed AWS service endpoint with
  them.** During `plan` the credentials are environment variables of the plan pass in the
  container, visible to anything running there. In `run-pass.sh` they are a session on the
  review role the user names, issued on the host for that one container, for 900 seconds,
  downscoped by the pinned session policy and checked there with a write probe
  ([plan-pass.md](../plan-pass.md#credentials)), never the profile's own credentials. The
  policy's allow list is provisional until a CloudTrail trial run measures it, and what it
  allows, configuration reads across the listed services, the head's code can use. `run-pass.sh` mounts them read-only as a
  file and never passes them with `--env` or `--env-file`, so `docker inspect` shows only
  the file's path. `run-plan.sh`, the bare runner for the smoke test, still passes the
  profile's own credentials with `--env-file`, where `docker inspect` shows them until its
  container is removed; use it only with made-up credentials or ones whose loss is
  acceptable.
- **A secret interleaved with other text passes every content scan.** The head's code in
  the plan container chooses what it prints. A credential split into fragments with other
  non-whitespace text between them matches none of the patterns and none of the values,
  in the plan pass's `kept`, in its whitespace-free copy or in the host's
  `record-scan.sh`. So no kept line of a runner-mode pass is ever quoted verbatim in a
  finding or a comment: a finding names the class, and a `planned` result may give its
  `Plan:` counts, which are numbers only. The line still reaches the reviewer's context.
  The structural answer is the downscoped short-lived review role above.
- **An allowed AWS service endpoint can still carry data out.** The plan allowlist admits
  service endpoints only, not hosts customers control, but a path-style S3 request
  (`s3.<region>.amazonaws.com/<bucket>`) can reach a bucket someone else owns, signed or,
  for a publicly writable bucket, unsigned.
- **The network check before the first session proves only the paths it probes.** It runs
  behind the init proxy before any head code, and behind the plan proxy before the first plan
  container. It refuses to plan when IPv6 is on for either run network, when more than 16
  host IPv6 addresses would need probing, and when a container on the internal network
  connects to the internal gateway, the `docker0` address, a host IPv6 address or a metadata
  address (`169.254.169.254`, `fd00:ec2::254`) on ports 22, 80, 443, 2375, 2376 or 8888,
  connects out directly, resolves an outside name, has a default route or a second interface
  up, or gets an IP-literal `CONNECT`, or one to a host outside that proxy's allowlist,
  through the proxy. Two positive controls must hold, or a closed result could be a tool that
  never ran: a direct connection to the proxy on 8888, and a `CONNECT` the proxy passes, to
  the registry behind the init proxy and to STS behind the plan proxy. So an offline host
  cannot plan. A missing tool, a tool exiting 126 or 127, and a `CONNECT` the proxy did not
  refuse itself (curl exit 56 with a 4xx or 5xx answer) are faults, never closed paths, and
  the probe's output must end with its `end network check` line. A service on another port of a host
  address is not probed; the host's INPUT drops on `br-+` and `docker0` are what close those.
  The probe runs on a laptop too: on a Linux host with a service listening on the bridge
  address on one of those ports, the runner refuses until such drops are in place. The host
  addresses come from `docker network inspect` and, where `ip` exists, from the host's own
  IPv6 addresses; on Docker Desktop the host's own interfaces are inside its VM and only the
  Docker addresses are probed.
- **Only the request target is filtered.** Traffic inside an allowed `CONNECT` tunnel is
  not inspected.
- **A `CONNECT` to a port other than 443 leaves no refusal line.** tinyproxy refuses it
  under `ConnectPort` and logs only the request. `run-plan.sh` lists it in
  `plan-refused-hosts.txt` from the request line, and anything else reading the proxy log
  has to do the same.
- **The plan pass's record lines are untrusted data** (Rule 2 of the pull request skill). In
  the plan phase the head's code runs as the same user as the plan pass in that container,
  so it can forge anything the container writes: the record lines, the kept lines and that
  example's part of the summary. A forged result can only add or remove plan evidence, and
  plan evidence never clears a finding on its own. Kept lines still pass the host's leak
  scan before any render. Each example plans in its own container with the work volume
  read-only, so it cannot change another example's state, sources or record, and the plan
  phase reads the init phase's saved state as data, never by sourcing a file.
- **Only `run-pass.sh` redacts.** The plan pass keeps only its redacted kept lines, and the
  host removes any record line holding a credential value. `run-plan.sh`, for the smoke
  test, copies its logs as they are.
- **The AWS CLI archives are pinned by the SHA-256 of a TLS download** from
  `awscli.amazonaws.com`. AWS signs them with PGP and publishes no checksum. PGP
  verification against the key in the AWS CLI install guide was not run for this pin, so
  that is a follow-up. The terraform archives are pinned from HashiCorp's published
  `SHA256SUMS`.
- **The image carries two Pythons**: Debian's `python3.11` as `python3`, and `python3.12`
  from a python-build-standalone release, pinned by version and by the SHA-256 in that
  release's `SHA256SUMS`. The lambda module's packaging script needs the Python version of
  the function's runtime on `PATH`, and `python3.12` is the only Python runtime the
  terraform-aws-lambda examples use. An example whose function runs another Python version
  fails at plan, as a `code-error` that reproduces at the base, until the image carries that
  version too. The pin rests on the checksum of a download over TLS; the release's
  signature was not verified.
- **No Docker daemon**, by design: no socket is mounted. An example that needs one is a
  recorded exception, `needs a Docker daemon`: the `kreuzwerker/docker` provider, and a
  module call with the literal `build_in_docker = true`, whose packaging calls Docker at
  plan. A `build_in_docker` set from a variable is not detected, so such an example ends in
  a `code-error`.
- **Direct Debian packages are version-pinned**. The eight direct apt install entries
  in `Dockerfile.runner` use explicit versions, checked against signed metadata from
  the digest-pinned base image's apt sources for amd64 and arm64 on 2026-10-04.
  Transitive dependencies still follow those sources at build time. This is not a
  frozen archive or a byte-reproducible image. Removed package versions fail the
  build; there is no unpinned fallback. To refresh, run `apt-get update` and
  `apt-cache policy` for each direct package in the pinned base on both
  architectures, keep apt's signature checks enabled, then update the verified
  versions and this date together. Run
  `bash tests/plan-runner-packages-test.sh` from the repository root, build the
  runner image for both architectures and run `smoke.sh` on the native one before
  accepting a refresh. Record both builds and the smoke result. Updating the base
  digest also requires this check; never assume its sources still have these pins.
- **Images are never removed by a run.** Each runner revision leaves its own
  `plan-runner:src-<hash>` and `plan-egress-proxy:src-<hash>`. Remove an old pair by its
  exact tag.
- **The saved plans' volume has no size limit.** It is an ordinary Docker volume, so a plan
  container can fill it; the run removes it when it ends, and Cleanup by its exact name.
- **A SIGKILL of `run-pass.sh` skips its cleanup.** Its containers, networks and volumes
  stay; the pull request skill's Cleanup removes them by the exact names in `run-id.txt`.
  A leftover plan container holds no credential in its configuration; it names only the
  mounted file.
  Its private temporary directory, mode 0700, which holds that credentials file, stays too,
  until Cleanup removes it or the credentials expire. A run that ends normally deletes the
  file after the last plan container. The skill passes `--tmp` with its run directory, so its
  Cleanup deletes that directory with the run. Run by hand without `--tmp`, the directory
  is under `TMPDIR` and stays until it is deleted by hand.
- **`run-plan.sh` gates nothing.** It is the bare runner for the smoke test. `run-pass.sh`
  applies the plan pass's runner-mode gates.

## Files

| File | What it is |
|------|------------|
| `Dockerfile.runner` | Runner image: Debian slim pinned by digest, terraform 1.16.4 and AWS CLI 2.37.1 pinned by version and SHA-256, plus git, jq, bash, perl, curl, python3 and python3.12, which the lambda module's packaging script needs at plan. Runs as uid 10001 |
| `Dockerfile.proxy` | Egress proxy image: Alpine pinned by digest, tinyproxy 1.11.2-r0, with one configuration per phase. Runs as `nobody` |
| `tinyproxy.conf` | Proxy configuration: default deny, filter on the whole request target, `CONNECT` to port 443 only, every connection and refusal logged |
| `allowlist-init` | Init phase: `registry.terraform.io`, `releases.hashicorp.com`, `github.com`, `codeload.github.com`, `objects.githubusercontent.com`. No AWS |
| `allowlist-plan` | Plan phase: named AWS service endpoints, in their global and regional forms, and nothing else. A host a legitimate example needs shows in `plan-refused-hosts.txt`, and its service is added here; `kinesis` came from the lambda event source mapping example. EC2 public DNS names, load balancer and API Gateway hosts, S3 website hosts and S3 bucket virtual hosts do not match |
| `entry.sh` | Runner entrypoint, one phase per container: `init` copies the read-only clone to `/work` and runs `init` with no credentials; `plan` runs `plan` in the same copy |
| `egress-probe.sh` | Probe run inside the runner on the internal network. `init` and `plan`, for the smoke test after a phase: direct connections, name resolution, plain HTTP, and one line per host through the proxy, always exiting 0. `check`, for `run-pass.sh` behind each proxy before its first session: fails closed, exiting 1 on any open path or fault, from two positive controls, the interfaces and routes, name resolution, refused `CONNECT`s and direct connections to the host addresses it is passed |
| `run-pass.sh` | Host side of the plan pass: checks the run networks with `egress-probe.sh check`, copies the clone into the work volume, runs the init phase in one container and the plan phase in one container per example, each behind its own proxy, issues each plan container its session, and writes the record |
| `hosted-record.sh` | Reduces a finished `run-pass.sh` record to `plan-hosted.json` for a hosted run: per example the class at the head and the base and the `Plan:` counts, and the number of refused hosts, refusing any record it cannot read that way ([Hosted runner](../plan-pass.md#hosted-runner)) |
| `record-scan.sh` | Host-side leak scan over a finished record: exact values and the plan pass's evidence patterns, each matching line replaced by a marker |
| `image-tag.sh` | Prints the image tag: `PLAN_RUNNER_TAG`, or one derived from the files the images are built from |
| `run-plan.sh` | Host side of the bare runner: builds or reuses the images, creates the networks and the work volume, runs the two phases each behind its own proxy, exports the record as regular files only and removes everything |
| `smoke.sh`, `smoke/example/`, `smoke/attack/` | Smoke test: a one-data-source example with made-up credentials, and an example whose code plants symlinks in the output directory |

## How a run is isolated

- Two Docker networks per run: an internal one with no route out, and an ordinary one. A
  proxy container is attached to both; the runner is on the internal one only, and reaches
  the proxy by the alias `proxy`. There is no name resolution for outside hosts on the
  internal network.
- **Two phases, two proxies.** The init-phase proxy allows only the registry and download
  hosts, and is removed before the plan phase starts. The plan-phase proxy allows only AWS
  service endpoints. So `init` cannot reach AWS, and `plan`, the only phase with
  credentials, cannot reach the registry, GitHub, or a host a customer controls under
  `amazonaws.com`.
- The filter matches the whole request target, `host:443` for `CONNECT`, so a plain HTTP
  request through the proxy is refused.
- Both containers run with a read-only root filesystem, all capabilities dropped,
  `no-new-privileges` and a process limit; the runner also has a memory limit and runs as a
  non-root user.
- The clone is mounted read-only. The only writable place is `/work`, a Docker volume
  created for the run and removed with the containers and the networks when the script
  exits. It is never a host directory, so nothing the runner writes there is resolved on
  the host.
- **The record takes regular files only.** `run-plan.sh` copies a fixed list of names out
  of the volume with `docker cp`, which streams a tar archive and never follows a link. The
  host reads the archive's listing, and extracts the content only when it is a single
  regular file, to standard output, so no link or device is ever created on the host. A
  refused name is listed in `export-refused.txt`. The record directory has to be new and is
  created with mode 0700, and the script fails if it ends up holding anything but regular
  files.
- **Each file is capped.** A record file, a container's output and a proxy log stop at
  5 MiB. `run-plan.sh` refuses to export a larger file, and lists it in
  `export-refused.txt`, so the head's code cannot fill the reviewer's disk through the
  record.
- **A run cleans up only what it created.** Every container, network and volume a run
  creates carries the run's id in its name, the id is written to `run-id.txt` in the
  record, and cleanup removes exactly those names. None of the scripts removes Docker
  objects by a name prefix, by a filter or with a prune, so runs on the same Docker daemon
  do not disturb each other.
- `init` never sees credentials. In `run-pass.sh`, `plan` gets a session on the review role
  `--role-arn` names, issued on the host with `--profile` for each plan container
  ([plan-pass.md](../plan-pass.md#credentials)). In `run-plan.sh`, the bare runner, it gets
  the profile's own credentials, exported on the host with `aws configure
  export-credentials`. `--credentials-env-file`, for the smoke test, is refused in both
  unless it carries a session token, so long-lived access keys are never used.

## The plan pass in the runner

```bash
./run-pass.sh --build --clone <clone> --record <dir> --profile <name> --role-arn <arn> [--base <sha>] [--tmp <dir>] \
  examples/complete examples/notification
```

`--clone` is a git checkout of the head, made the way the pull request skill's Workspace
makes one, with its `origin` remote so the base can be fetched for a re-run. The skill
passes a snapshot of its clone taken before its default pass writes `.terraform/` and lock
files, which G0 would refuse ([plan-pass.md](../plan-pass.md#runner-or-laptop)). This is
the skill's plan pass whenever a container runtime is available.

- **Network check:** before anything else runs in a container, IPv6 must be off on both run
  networks, and `egress-probe.sh check`, run in a container attached to the internal network
  as a plan container is, with no credentials and behind the init proxy, must find every path
  closed and both positive controls holding. The same check runs behind the plan proxy before
  the first plan container. The host passes it the internal network's gateway, the `docker0` address and the
  host's IPv6 addresses, which the container cannot know. A failure stops the run with a fixed
  reason on standard error, `refusing to plan: ...`, before any head code runs and before the
  first session, and the record holds no `plan-pass.txt`. The probe's lines are in
  `network-check-init.txt` and `network-check-plan.txt`. It runs on every run, on a laptop too.
- **Prepare:** a container with no network copies the read-only clone into the run
  directory, `/work/pr-review.XXXXXX`, inside the work volume.
- **Init phase:** one container behind the init proxy, with no credentials. It runs
  `plan-pass.sh g0` and then `plan-pass.sh plan --mode runner --phase init` for the whole
  list: the gates, `init` and the post-init checks. It saves each example's state in the
  volume. The merge base is not touched here.
- **Plan phase:** one container per example behind the plan proxy, with the work volume
  read-only and scratch directories on tmpfs. The clone, and the base worktree when there is
  one, are private writable copies on tmpfs, seeded from the volume when the container
  starts: a plan may write into its example directory, as the lambda module's packaging
  does, and a copy no other example sees keeps that write to itself. The copy lives only in
  that container's tmpfs and goes with it; nothing written there reaches the record, which
  is the container's output, capped and scanned on the host. Each runs
  `plan-pass.sh plan --mode runner --phase plan --index <n> <example>`, which prints that
  example's record lines. A `code-error` with `--base` given ends in `base: deferred`. The
  phase stops at a credentials failure, as the plan pass does, and at the budget.
- **Show phase:** every plan is saved with `-out` into a second volume, the saved plans'
  volume, made writable for the containers' user by a capability-free root container that
  only changes its mode. After the plan phase, one more container per example whose plan
  block holds `plan: planned` runs `--phase show`: no network, no credentials, the work
  volume and the saved plans read-only. It reads the saved plan with
  `terraform show -json` and prints one `addresses-json:` line. The host keeps only the
  configuration addresses, attribute names, sensitive names and local module calls that
  match their patterns, drops a malformed sensitive entry whole, and writes them to
  the record as `addresses-<n>.json` ([plan-pass.md](../plan-pass.md#saved-plans-and-addresses)).
  It counts against the same budget.
- **Merge base re-run:** only for the examples whose plan block holds `plan: code-error` and
  `base: deferred`, after the last head plan, so an example that planned costs the budget
  nothing at the base. The plan proxy is removed and the init proxy started again, since
  both answer to the name `proxy`. One container per such example, with no credentials and
  the volume writable, runs `--phase base-init`: the first adds the base worktree, fetching
  `--base` from `origin`, and each runs the gates and `init` of its example there. Then the
  plan proxy is started again, and one container per example runs `--phase base-plan`, set
  up as a plan container with the base worktree also copied to tmpfs, and prints the one
  `base:` line. The host takes the first `base:` line of that output, or `base: not
  available` when there is none, and puts it in place of `base: deferred`. The base re-runs
  count against the same budget; one the budget does not reach is `base: budget`.
- **Budget:** one wall-clock budget for the whole pass, from the init phase to the last base
  re-run: 120 minutes, or `--budget-minutes <n>`. It is recorded in `plan-pass.txt` as
  `plan pass budget: <n> minutes`. There is no cap on the number of examples. Each container
  gets what is left of the budget as the plan pass's `--budget`, and an example the budget
  does not reach is `plan: budget`. Each command keeps its own timeout.
- **Credentials:** `run-pass.sh` owns them. `--profile` needs `--role-arn`, the review role
  the user named; without it the script stops before anything runs, so the plan pass does
  not run. Before each plan container it calls [plan-session.sh](../plan-session.sh) on the
  host: a session on that role, issued with the profile, for 900 seconds, downscoped by the
  pinned session policy. A session that cannot be issued gives that container no
  credentials, and its plan pass ends at credentials; there is no fallback to the profile's
  own credentials, which never leave the host. The container's plan pass checks the session
  with `sts get-caller-identity` and an `ec2 create-vpc --dry-run` write probe that must be
  refused, a canary that the session policy applied. `--credentials-env-file`, for the smoke test, takes a fixed file of made-up
  session credentials instead and refuses one without a session token. The session goes
  only to the plan containers, as a
  file of `PLAN_PASS_AWS_*` lines in its private temporary directory, mounted read-only.
  The container exports those three names, and no other line, before it starts the plan
  pass. The Docker daemon, not the CLI, resolves that mount, so the temporary directory
  (under `--tmp` or `TMPDIR`) must be a path the daemon sees: a shared path on Docker
  Desktop, and not a remote `DOCKER_HOST` or a VM context without that mount, where Docker
  creates an empty root-owned directory in place of the file, the credentials check fails
  closed, and the directory may block cleanup. `plan-pass.sh` reads those in runner mode, and checks them
  with `sts get-caller-identity` and the write probe. A session `plan-session.sh` could not
  issue is reported to the operator on `run-pass.sh`'s standard error, with its fixed
  reason, never in the record.
- **Redaction:** the plan pass's evidence contract applies inside the runner, and its kept
  lines leave redacted. The head's code can still write to the container's output, so the
  host then runs `record-scan.sh` over every record file. It replaces each line that holds
  one of the run's credential values, or matches the evidence contract's patterns (an
  access key id, a JWT, a PEM header, `X-Amz-Signature`, `Authorization:`, a base64 run of
  40 or more characters), with a marker line. The base64 rule also drops a line holding a
  40-character commit SHA, which the record never needs. The values and every pattern but
  the base64 run are also matched in a copy of the file with all whitespace and newlines
  removed, and every line such a match spans is replaced, so a secret split across lines
  is caught too.
- **Blocks:** each plan container writes to a file of its own. The host drops any
  `plan summary:`, `plan pass mode:` or `host example` line from it, and heads the block with
  `host example <n>: <example>`, its own index, so a forged block cannot claim another
  example or the summary.

The record directory must not exist yet, and receives regular files only:

- `plan-pass.txt`: the mode and budget lines, then per example the host's `host example <n>:` line and
  the example's `example:`, `gate-hit`, `exception-hit`,
  `plan:`, `scope:`, `modules:` and `base:` lines, and the `plan summary:` line, which
  `run-pass.sh` writes from the examples' `plan:` lines;
- `plan-pass-init.txt`: the G0 count, one `init:` line per example, and one per merge base
  re-run;
- `proxy-init.log`, `proxy-plan.log` and `plan-refused-hosts.txt`, as for `run-plan.sh`;
- `network-check-init.txt` and `network-check-plan.txt`: the network check's lines behind
  each proxy, `closed <check>` and `ok <check>` for a pass, anything else for a fault, and the
  `end network check` line. They name the host's gateway, `docker0` and IPv6 addresses, so
  they stay in the record on the runner: `hosted-record.sh` never reads them, and nothing
  uploads them;
- `runner.log`: the containers' error output;
- `run-id.txt`: the id every Docker object of the run carries.

## Extending the plan allowlist

`allowlist-plan` names the AWS services a plan may reach, and it grows only from evidence.
When a legitimate example fails with an environment class and `plan-refused-hosts.txt`
names a service endpoint, `<service>.<region>.amazonaws.com:443`, add that service name to
the alternation in `allowlist-plan`, rebuild the proxy image with `--build`, and plan the
example again. Add a service only when an example needed it, and only its service name:
the region form stays the fixed pattern, so no host a customer controls under
`amazonaws.com` becomes reachable.

## The bare runner

```bash
./run-plan.sh --build --clone <clone> --example examples/complete --record <dir> --profile <name>
```

`--build` builds both images first. The images are `plan-runner:<tag>` and
`plan-egress-proxy:<tag>`. `image-tag.sh` gives the tag: `PLAN_RUNNER_TAG` when set,
otherwise `src-` and the first 12 hex digits of a SHA-256 over every file the two images are
built from. `run-pass.sh`, `run-plan.sh` and `smoke.sh` all use it. Two checkouts with the
same runner files share a tag and an identical image; a branch that changes any of those
files gets its own, so runs of different revisions on one Docker daemon never share an
image, and a build of an unchanged revision is cached. `--probe` also runs `egress-probe.sh` after each
phase. The record directory must not exist yet. It receives:

- `status`: `init <exit>` and `plan <exit>` lines;
- `init.log` and `plan.log`: the command output;
- `proxy-init.log` and `proxy-plan.log`: every host each phase connected to or was
  refused, from its proxy;
- `plan-refused-hosts.txt`: the hosts the plan phase was refused. A host a legitimate
  example needed names an AWS service to add to `allowlist-plan`;
- `probe-init.log` and `probe-plan.log`, with `--probe`;
- `runner.log`: the runner containers' own output;
- `run-id.txt`: the id every Docker object of the run carries;
- `export-refused.txt`, only when a listed name in the work volume was not a regular file.

## Smoke test

`./smoke.sh` builds the images and plans `smoke/example` with made-up session credentials.
STS rejects the made-up key with `InvalidClientTokenId`, which proves that `plan` reached
AWS through the plan-phase proxy with no real credential. It then plans `smoke/attack`,
whose `external` data source replaces `status` and `plan.log` in the output directory with
symlinks to `/etc/passwd` and `/etc/hostname`, plants one more, and writes a 6 MB file.
Last, it runs `run-pass.sh` with `--base` on a git fixture holding both examples and a
third whose `init` fails the same way at the head and at the base, a `code-error` that
needs no credentials; the fixture is its own `origin`. Ten more copies of that example make
thirteen, one past the laptop's cap. The made-up credentials fail the plan pass's `sts`
check, so that pass ends at credentials after the init phase. It also runs
`record-scan.sh` on a crafted record, and `run-pass.sh` three more times with a Docker wrapper
that fakes a fault for the network check: IPv6 on, the probe's gateway pointed at the proxy,
which listens, and a plan-phase positive control its proxy refuses. Its checks cover:

- each phase reaches only its own hosts;
- during plan, the registry, GitHub, an EC2 public DNS name and S3 bucket hosts are refused;
- direct connections are closed and outside names do not resolve in both phases;
- plain HTTP is refused, and so is a `CONNECT` to port 8443, which the refused-hosts list
  still names;
- credentials without a session token are refused before anything starts;
- the planted links are refused, the extra name is not exported, the oversized file is
  refused, and no record holds a link or any password-file content;
- `run-pass.sh`: the init phase readies both examples and reaches no AWS endpoint, the plan
  phase checks the credentials through the plan proxy, the host heads each block, the
  summary line is written, and no credential value and nothing but regular files is in the
  record;
- `run-pass.sh`'s network check behind each proxy: every line closed or a control that held,
  one interface up, no default route, the IP-literal `CONNECT` and the other phase's host
  refused, this phase's host passed, outside names unresolved, the gateway, `docker0` and
  metadata addresses closed on six ports each; IPv6 on stops the run before the probe, an open
  path stops it with the path named before any head code, and a failed plan-phase control
  stops it after init, before any plan container or plan record;
- the runner's budget line is recorded, and all thirteen examples are initialised, with no
  cap;
- the merge base: only the `code-error` is initialised there, and its `base: deferred` line
  becomes `base: reproduces at base`;
- `record-scan.sh` removes every crafted leak line, one per pattern, an exact value, and a
  value and a key id each split across two lines, and keeps the ordinary lines around them;
- `run-pass.sh --tmp`: nothing is left under it after a run, and one that cannot be
  written to stops the run before any Docker object is made;
- `image-tag.sh` gives `src-` and 12 hex digits, the same on every call, takes
  `PLAN_RUNNER_TAG` over it, and refuses an invalid one;
- no container, network or volume of the smoke test's own runs is left behind, checked by
  their exact names.

It creates no AWS resource and needs no AWS account.
