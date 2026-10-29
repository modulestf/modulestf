#!/bin/bash
# The plan pass, plan-pass.sh --mode runner, inside the isolated runner: one host command for
# a list of examples. See README.md in this directory.
#
# Usage:
#   run-pass.sh --clone DIR --record DIR (--profile NAME --role-arn ARN | --credentials-env-file FILE)
#               [--base SHA] [--budget-minutes N] [--tmp DIR] [--build] <example-dir>...
#
# --tmp names an existing directory, such as the pull request skill's run directory, to hold
# this script's private temporary directory, and with it the credentials file for the plan
# containers. The EXIT trap removes it; after a SIGKILL, whoever removes --tmp removes it
# too. Without --tmp it is made under TMPDIR.
#
# The runner has no cap on the number of examples. Its bound is a wall-clock budget for the
# whole pass, 120 minutes unless --budget-minutes says otherwise, recorded in plan-pass.txt.
# Every container gets what is left of it, and each command keeps its own timeout.
#
# --clone is a git checkout of the head, as the pull request skill's Workspace makes it, with
# its origin remote, so the plan pass can fetch --base for a re-run. The record directory must
# not exist yet; it is created 0700 and ends up holding regular files only.
#
# Before anything else runs in a container, a network check: IPv6 must be off on both run
# networks, and egress-probe.sh check, in a container on the internal network with no
# credentials, must find every path out closed behind the init proxy; and before the first
# plan container, behind the plan proxy too. Any failure stops the run with a fixed reason,
# before the first session and with no plan recorded.
#
# Phases: the init phase runs in one container behind the init proxy (registry and download
# hosts), with no credentials. The plan phase runs one container per example behind the plan
# proxy (AWS service endpoints), with the work volume read-only, and is the only place the
# credentials go. With --base, an example whose plan is a code-error is then re-run at the
# merge base in two more containers: base-init behind the init proxy, base-plan behind the
# plan proxy. Examples that planned never touch the base. This script owns the credentials:
# for each plan container it issues a session on the review role --role-arn names, with the
# profile, for 900 seconds, downscoped by the pinned session policy (../plan-session.sh), and
# mounts it read-only into that container as a file, never as --env or --env-file, so Docker
# keeps no copy in the container's configuration. The profile's own credentials never leave
# the host. A session that cannot be issued gives the container no credentials, and the plan
# pass ends at credentials there: there is no fallback to the profile's own. The container
# reads the file into the plan pass's environment, and plan-pass.sh reads them there.
# --credentials-env-file is for the smoke test: a fixed file of made-up session credentials.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
pass="$(cd "$here/.." && pwd)/plan-pass.sh"
# The image tag: PLAN_RUNNER_TAG, or one derived from the files the images are built from
tag="$("$here/image-tag.sh")"
runner_image="plan-runner:$tag"
proxy_image="plan-egress-proxy:$tag"
clone="" record="" profile="" role_arn="" cred_file="" base="" build=0 budget_min=120 tmp_parent=""

die() { echo "run-pass: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --clone) clone="${2:-}"; shift 2 ;;
    --record) record="${2:-}"; shift 2 ;;
    --profile) profile="${2:-}"; shift 2 ;;
    --role-arn) role_arn="${2:-}"; shift 2 ;;
    --credentials-env-file) cred_file="${2:-}"; shift 2 ;;
    --base) base="${2:-}"; shift 2 ;;
    --budget-minutes) budget_min="${2:-}"; shift 2 ;;
    --tmp) tmp_parent="${2:-}"; shift 2 ;;
    --build) build=1; shift ;;
    --) shift; break ;;
    -*) die "unknown argument: $1" ;;
    *) break ;;
  esac
done
[ "$#" -ge 1 ] || die "name at least one example directory"
[ -n "$clone" ] && [ -d "$clone/.git" ] || die "--clone must name a git checkout"
[ -n "$record" ] || die "--record is required"
[ ! -e "$record" ] && [ ! -L "$record" ] || die "--record must not exist yet: $record"
[ -n "$profile" ] || [ -n "$cred_file" ] || die "--profile or --credentials-env-file is required"
[ -z "$profile" ] || [ -z "$cred_file" ] || die "--profile and --credentials-env-file exclude each other"
[ -z "$profile" ] || [[ "$role_arn" =~ ^arn:aws(-[a-z]+)*:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$ ]] ||
  die "--profile needs --role-arn naming the review role; the plan pass does not run without it"
[ -n "$profile" ] || [ -z "$role_arn" ] || die "--role-arn goes with --profile"
# The profile name also goes to the plan pass, which redacts it from kept lines
pname="${profile:-smoke}"
[[ "$pname" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]{0,63}$ ]] || die "invalid profile name"
[ -z "$base" ] || [[ "$base" =~ ^[0-9a-f]{40}$ ]] || die "--base must be a full commit SHA"
[[ "$budget_min" =~ ^[1-9][0-9]{0,3}$ ]] || die "--budget-minutes must be a whole number of minutes, 1 to 9999"
budget=$((budget_min * 60))
if [ -n "$tmp_parent" ]; then
  [ -d "$tmp_parent" ] && [ ! -L "$tmp_parent" ] || die "--tmp must name an existing directory"
  tmp_parent="$(cd "$tmp_parent" && pwd -P)"
else
  tmp_parent="${TMPDIR:-/tmp}"
fi
[ -z "$cred_file" ] || [ -f "$cred_file" ] || die "no such credentials file: $cred_file"
for ex in "$@"; do
  case "$ex" in /* | *..* | -*) die "refusing example path: $ex" ;; esac
done
clone="$(cd "$clone" && pwd)"
mkdir -m 0700 "$record"
record="$(cd "$record" && pwd)"
max_bytes=5242880 # a record file, a log or a container's output stops at 5 MiB

if [ "$build" -eq 1 ]; then
  docker build -q -f "$here/Dockerfile.proxy" -t "$proxy_image" "$here" > /dev/null
  docker build -q -f "$here/Dockerfile.runner" -t "$runner_image" "$here" > /dev/null
fi

TMPRUN="$(mktemp -d "$tmp_parent/plan-runner.XXXXXX")"
chmod 0700 "$TMPRUN"
id="$(basename "$TMPRUN" | tr -dc '[:alnum:]' | tr '[:upper:]' '[:lower:]')"
sfx="$(printf '%s' "$id" | tail -c 6)"
RUN="/work/pr-review.$sfx" # the plan pass's run directory, inside the work volume
net_int="plan-int-$id" net_ext="plan-ext-$id" volume="plan-work-$id"
runner="plan-runner-$id" proxy_init="plan-proxy-init-$id" proxy_plan="plan-proxy-plan-$id"
# Every name carries this run's id, and cleanup removes exactly these names, never by prefix
echo "$id" > "$record/run-id.txt"

save_proxy_log() { # container, record file; a proxy may run twice, so the log is appended
  local have=0
  check_record_size "$record/$2"
  [ ! -f "$record/$2" ] || have=$(wc -c < "$record/$2")
  docker logs "$1" 2>&1 | head -c $((max_bytes - have)) >> "$record/$2" || true
  docker rm -f "$1" > /dev/null 2>&1 || true
}
cleanup() {
  docker rm -f "$runner" > /dev/null 2>&1 || true
  for p in "$proxy_init:proxy-init.log" "$proxy_plan:proxy-plan.log"; do
    if docker container inspect "${p%%:*}" > /dev/null 2>&1; then
      # Refused evidence must not stop teardown or retain the session file. Normal
      # log collection still refuses the run; cleanup isolates that exit and continues.
      (save_proxy_log "${p%%:*}" "${p##*:}") || true
      docker rm -f "${p%%:*}" > /dev/null 2>&1 || true
    fi
  done
  docker volume rm "$volume" > /dev/null 2>&1 || true
  docker network rm "$net_int" "$net_ext" > /dev/null 2>&1 || true
  case "$TMPRUN" in
    "$tmp_parent"/plan-runner.??????) rm -rf -- "$TMPRUN" ;;
    *) echo "refusing to delete: $TMPRUN" >&2 ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Credentials, for the plan containers only, renamed so that only the plan pass reads them.
# values collects every credential value and the role's ARN and account id, for the leak scan.
values="$TMPRUN/values"
printf '%s\n' "$role_arn" "$(printf '%s\n' "$role_arn" | sed -nE 's/^arn:[^:]*:iam::([0-9]{12}):.*/\1/p')" > "$values"
write_pass_env() { # AWS_* lines on stdin -> pass.env with PLAN_PASS_ names, values kept
  grep -E '^AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN)=' | sed 's/^/PLAN_PASS_/' > "$TMPRUN/pass.env" || true
  # 0644, not 0600: the container runs as uid 10001, not the file's owner, and on a native
  # Linux daemon it could not read a 0600 file. The 0700 directory keeps other host users out.
  chmod 0644 "$TMPRUN/pass.env"
  sed -nE 's/^PLAN_PASS_AWS_[A-Z_]+=//p' "$TMPRUN/pass.env" >> "$values"
}
# One session per plan container, issued just before it starts. A session that cannot be
# issued leaves pass.env empty: the container's plan pass ends at credentials.
session="$(cd "$here/.." && pwd)/plan-session.sh"
issue_session() {
  [ -n "$profile" ] || return 0
  local creds
  # plan-session.sh's fixed reason reaches the operator on this script's standard error,
  # never the record
  if creds="$(bash "$session" "$profile" "$role_arn" "modulestf-plan-$sfx")"; then
    jq -r '"AWS_ACCESS_KEY_ID=\(.AccessKeyId)", "AWS_SECRET_ACCESS_KEY=\(.SecretAccessKey)", "AWS_SESSION_TOKEN=\(.SessionToken)"' <<< "$creds" | write_pass_env
  else
    echo "run-pass: no session for this plan container; its plan pass ends at credentials" >&2
    : | write_pass_env
  fi
}
if [ -n "$cred_file" ]; then
  grep -Eq '^AWS_SESSION_TOKEN=.+' "$cred_file" ||
    die "the credentials carry no session token, so they are long-lived keys; use a role or SSO profile"
  write_pass_env < "$cred_file"
fi
# Run in the plan container: exports the three names from the mounted file and no other
# line. Each line splits at its first '=', so a value keeps every '=' it has, a trailing
# base64 pad included. smoke.sh runs this exact line, found by its marker.
load_creds='while IFS= read -r l; do k=${l%%=*}; v=${l#*=}; case $k in PLAN_PASS_AWS_ACCESS_KEY_ID|PLAN_PASS_AWS_SECRET_ACCESS_KEY|PLAN_PASS_AWS_SESSION_TOKEN) export "$k=$v" ;; esac; done < /opt/plan-pass/creds.env' # creds-loader

docker volume create "$volume" > /dev/null
docker network create --internal --ipv6=false "$net_int" > /dev/null
docker network create --ipv6=false "$net_ext" > /dev/null

hardening=(--read-only --cap-drop ALL --security-opt no-new-privileges --pids-limit 512)
proxy_env=(-e HTTPS_PROXY=http://proxy:8888 -e HTTP_PROXY=http://proxy:8888
  -e https_proxy=http://proxy:8888 -e http_proxy=http://proxy:8888 -e NO_PROXY= -e no_proxy=)
common=("${hardening[@]}" --user 10001:10001 --memory 4g --tmpfs "/tmp:rw,size=64m"
  -v "$pass":/opt/plan-pass/plan-pass.sh:ro)

start_proxy() { # name, config
  docker run -d --name "$1" --network "$net_ext" "${hardening[@]}" \
    --tmpfs /tmp:rw,size=16m "$proxy_image" "/etc/tinyproxy/$2" > /dev/null
  docker network connect --alias proxy "$net_int" "$1"
}
check_record_size() { # existing append destination
  [ ! -L "$1" ] && { [ ! -e "$1" ] || [ -f "$1" ]; } ||
    die "refusing a non-regular record file"
  [ ! -f "$1" ] || [ "$(wc -c < "$1")" -le "$max_bytes" ] ||
    die "refusing an oversized record file"
}
bounded_append() { # stdout stream -> remaining destination allowance
  local have=0
  check_record_size "$1"
  [ ! -f "$1" ] || have=$(wc -c < "$1")
  head -c "$((max_bytes - have))" >> "$1"
}
capture_runner() { # stdout destination, then docker arguments; stderr appended afterwards
  local outf="$1" err_pid command_status=0; shift
  check_record_size "$outf"
  check_record_size "$record/runner.log"
  # Serialize the two streams: setup writes both to runner.log. The FIFO keeps stderr
  # bounded while Docker runs, and waiting closes it before another container starts.
  rm -f "$TMPRUN/runner-stderr.pipe" "$TMPRUN/runner-stderr.txt"
  mkfifo "$TMPRUN/runner-stderr.pipe"
  head -c "$max_bytes" < "$TMPRUN/runner-stderr.pipe" > "$TMPRUN/runner-stderr.txt" &
  err_pid=$!
  docker run "$@" 2> "$TMPRUN/runner-stderr.pipe" |
    bounded_append "$outf" || command_status=$?
  wait "$err_pid" || true
  bounded_append "$record/runner.log" < "$TMPRUN/runner-stderr.txt" || true
  rm -f "$TMPRUN/runner-stderr.pipe" "$TMPRUN/runner-stderr.txt"
  return "$command_status"
}
in_runner() { # stdout file, then docker run arguments
  local outf="$1"; shift
  docker rm -f "$runner" > /dev/null 2>&1 || true
  capture_runner "$outf" --name "$runner" "$@" || true
}

# The pre-session network check, on a laptop too, before any head code runs and before the
# first session (docs/isolated-runner.md, Validation). It fails closed: IPv6 on for either run
# network, or any fault the probe finds, stops the run, with no session issued and no plan
# recorded. The probe runs in a runner container attached as a plan container is, with no
# credentials, once behind the init proxy here and once behind the plan proxy before the first
# plan container, and is passed the host addresses it cannot know: the internal network's
# gateway, the docker0 address, and the host's IPv6 addresses. Its lines, which name those
# addresses, stay in network-check-<phase>.txt in the record and are never reduced or uploaded.
[ "$(docker network inspect -f '{{.EnableIPv6}}' "$net_int" "$net_ext" | tr '\n' ' ')" = "false false " ] ||
  die "refusing to plan: IPv6 is on for a run network"
v4_re='^[0-9]{1,3}([.][0-9]{1,3}){3}$'
gw="$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' "$net_int")"
[[ "$gw" =~ $v4_re ]] || die "refusing to plan: the internal network has no IPv4 gateway address"
probe_args=(--gateway "$gw")
d0="$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' bridge 2> /dev/null || true)"
[[ ! "$d0" =~ $v4_re ]] || probe_args+=(--host "$d0")
if command -v ip > /dev/null 2>&1; then
  br="br-$(docker network inspect -f '{{.Id}}' "$net_int" | cut -c1-12)"
  # Global addresses on any interface, and the internal bridge's link-local one, which is on
  # the container's own link. More than 16, or one in another form, stops the run: none is
  # dropped unprobed.
  v6="$({ ip -6 -o addr show scope global 2> /dev/null | awk '{ split($4, a, "/"); print a[1] }'
    ip -6 -o addr show dev "$br" scope link 2> /dev/null | awk '{ split($4, a, "/"); print a[1] "%eth0" }'; } || true)"
  [ "$(printf '%s\n' "$v6" | grep -c .)" -le 16 ] || die "refusing to plan: more than 16 host IPv6 addresses to probe"
  for a in $v6; do
    [[ "$a" =~ ^[0-9a-f:]+(%eth0)?$ ]] || die "refusing to plan: a host IPv6 address the probe cannot take"
    probe_args+=(--host "$a")
  done
fi
network_check() { # phase, then egress-probe.sh check arguments beyond the host addresses
  local f="$record/network-check-$1.txt"; shift
  docker rm -f "$runner" > /dev/null 2>&1 || true
  capture_runner "$f" --rm --name "$runner" --network "$net_int" "${common[@]}" "${proxy_env[@]}" \
    --entrypoint /usr/local/bin/egress-probe "$runner_image" check "${probe_args[@]}" "$@" \
    &&
    [ -s "$f" ] && [ "$(tail -n 1 "$f")" = "end network check" ] ||
    die "refusing to plan: the network check found an open path, or could not run"
}
start_proxy "$proxy_init" init.conf
network_check init --allowed registry.terraform.io --refused sts.us-east-1.amazonaws.com

# Prepare: copy the read-only clone into the run directory. No network.
in_runner "$record/runner.log" --network none "${common[@]}" -v "$clone":/src:ro -v "$volume":/work \
  --entrypoint /bin/bash "$runner_image" -c "mkdir -m 700 '$RUN' && cp -a /src '$RUN/clone'"

# The budget runs from here: init, the plans and the merge base re-runs.
t0=$SECONDS
# Read once per container: the value checked is the value passed, so a container never
# starts with a budget of 0 or less
left() { echo $((budget - (SECONDS - t0))); }

# Init phase: G0, gates and init for every example. No credentials. The init proxy is the
# one the network check started.
in_runner "$record/plan-pass-init.txt" --network "$net_int" "${common[@]}" "${proxy_env[@]}" \
  -v "$volume":/work --entrypoint /bin/bash "$runner_image" -c \
  "bash /opt/plan-pass/plan-pass.sh g0 '$RUN' && exec bash /opt/plan-pass/plan-pass.sh plan '$RUN' '$pname' --mode runner --budget '$budget' --phase init \"\$@\"" \
  plan-pass "$@"
save_proxy_log "$proxy_init" proxy-init.log

SEED="/seed/pr-review.$sfx"
base_args=()
[ -z "$base" ] || base_args=(--base "$base")
plan_container() { # output file, phase, index, example, budget left: the work volume read-only, the credentials in
  # The volume stays read-only; the example's own plan may write into its directory, as the
  # lambda module's packaging does, so the clone (and the base worktree) are private
  # writable copies on tmpfs, seeded from the volume at start and gone with the container.
  local base_tmpfs=() seed_base=:
  if [ "$2" = base-plan ]; then
    base_tmpfs=(--tmpfs "$RUN/base:rw,size=1g,mode=1777")
    seed_base="{ [ ! -d '$SEED/base' ] || cp -dR '$SEED/base/.' '$RUN/base/'; }"
  fi
  issue_session
  in_runner "$1" --network "$net_int" "${common[@]}" "${proxy_env[@]}" \
    -v "$volume":/work:ro -v "$volume":/seed:ro \
    --tmpfs "$RUN/clone:rw,size=1g,mode=1777" ${base_tmpfs[@]+"${base_tmpfs[@]}"} \
    --tmpfs "$RUN/plan/out:rw,size=256m,mode=1777" --tmpfs "$RUN/plan/tmp:rw,size=256m,mode=1777" \
    --tmpfs "$RUN/plan/home:rw,size=64m,mode=1777" -v "$TMPRUN/pass.env":/opt/plan-pass/creds.env:ro \
    --entrypoint /bin/bash "$runner_image" -c \
    "$load_creds && cp -dR '$SEED/clone/.' '$RUN/clone/' && $seed_base && exec bash /opt/plan-pass/plan-pass.sh plan '$RUN' '$pname' --mode runner --budget '$5' --phase '$2' --index '$3' \"\$@\"" \
    plan-pass ${base_args[@]+"${base_args[@]}"} "$4"
}
# Lines only the host may write; the container's output is untrusted and may not forge them
host_only='^(plan summary:|plan pass mode:|plan pass budget:|host example )'

# Plan phase: one container per example. Each block is kept apart until the end, because a
# deferred merge base re-run fills in its base line later.
start_proxy "$proxy_plan" plan.conf
network_check plan --allowed sts.us-east-1.amazonaws.com --refused registry.terraform.io
n=0 planned=0 exc=0 deferred=() examples=("$@")
for ex in "$@"; do
  n=$((n + 1)); blk="$TMPRUN/block.$n"
  rem=$(left)
  if [ "$rem" -le 0 ]; then
    printf 'example: %s\nplan: budget\n' "$ex" > "$blk"; continue
  fi
  : > "$TMPRUN/example.out"
  plan_container "$TMPRUN/example.out" plan "$n" "$ex" "$rem"
  grep -Ev "$host_only" "$TMPRUN/example.out" > "$blk" || true
  line="$(grep -m 1 '^plan: ' "$blk" || true)"
  case "$line" in
    'plan: planned'*) planned=$((planned + 1)) ;; # planned and planned-no-changes
    'plan: exception:'*) exc=$((exc + 1)) ;;
    'plan: code-error'*) [ -z "$base" ] || ! grep -qx 'base: deferred' "$blk" || deferred+=("$n") ;;
    'plan: plan pass ended: credentials'*) break ;;
  esac
done
save_proxy_log "$proxy_plan" proxy-plan.log

# Merge base re-run, only for the code-errors: the base worktree and its init behind the init
# proxy with no credentials, then its plan behind the plan proxy. One proxy runs at a time,
# since both answer to the same name on the internal network.
if [ "${#deferred[@]}" -gt 0 ]; then
  start_proxy "$proxy_init" init.conf
  for n in "${deferred[@]}"; do
    rem=$(left)
    [ "$rem" -gt 0 ] || break # base-plan then records the budget
    ex="${examples[n - 1]}"
    in_runner "$record/plan-pass-init.txt" --network "$net_int" "${common[@]}" "${proxy_env[@]}" \
      -v "$volume":/work --entrypoint /bin/bash "$runner_image" -c \
      "exec bash /opt/plan-pass/plan-pass.sh plan '$RUN' '$pname' --mode runner --budget '$rem' --phase base-init --index '$n' \"\$@\"" \
      plan-pass --base "$base" "$ex"
  done
  save_proxy_log "$proxy_init" proxy-init.log
  start_proxy "$proxy_plan" plan.conf
  for n in "${deferred[@]}"; do
    rem=$(left)
    if [ "$rem" -le 0 ]; then echo 'base: budget' > "$TMPRUN/base.$n"; continue; fi
    ex="${examples[n - 1]}"
    : > "$TMPRUN/example.out"
    plan_container "$TMPRUN/example.out" base-plan "$n" "$ex" "$rem"
    grep -E '^base: ' "$TMPRUN/example.out" | head -n 1 > "$TMPRUN/base.$n" || true
    [ -s "$TMPRUN/base.$n" ] || echo 'base: not available' > "$TMPRUN/base.$n"
  done
  save_proxy_log "$proxy_plan" proxy-plan.log
fi
rm -f "$TMPRUN/pass.env" # no plan container runs after this

# The record: each block headed by the host with its own index, so a forged block cannot claim
# another example, and a deferred base line replaced by its re-run's result.
n=0
for ex in "$@"; do
  n=$((n + 1))
  check_record_size "$TMPRUN/block.$n"
  check_record_size "$TMPRUN/base.$n"
done
assemble_record() {
printf 'plan pass mode: runner\nplan pass budget: %s minutes\n' "$budget_min"
n=0
for ex in "$@"; do
  n=$((n + 1))
  [ -f "$TMPRUN/block.$n" ] || continue
  check_record_size "$TMPRUN/block.$n"
  check_record_size "$TMPRUN/base.$n"
  printf 'host example %s: %s\n' "$n" "$ex"
  if [ -f "$TMPRUN/base.$n" ]; then
    awk -v f="$TMPRUN/base.$n" '$0 == "base: deferred" { while ((getline l < f) > 0) print l; next } { print }' \
      "$TMPRUN/block.$n"
  else
    sed 's/^base: deferred$/base: not available/' "$TMPRUN/block.$n"
  fi
done
echo "plan summary: $# examples, $planned planned, $exc exceptions, $(($# - planned - exc)) other"
}
# Keep one byte beyond the allowance so an oversized assembly is refused, rather than
# publishing a truncated record that might retain a forged summary from an earlier block.
assemble_record "$@" | head -c "$((max_bytes + 1))" > "$TMPRUN/assembled.txt" || true
check_record_size "$TMPRUN/assembled.txt"
out="$record/plan-pass.txt"
mv "$TMPRUN/assembled.txt" "$out"

{
  grep -o 'refused on filtered url "[^"]*"' "$record/proxy-plan.log" | sed -E 's/.*"([^"]*)"/\1/'
  grep -o 'Request ([^)]*): CONNECT [^ ]*' "$record/proxy-plan.log" | sed -E 's/.*CONNECT //' | grep -v ':443$'
} | sort -u > "$record/plan-refused-hosts.txt" || true

for record_file in "$record"/*; do
  check_record_size "$record_file"
done

# Leak scan over the whole record: exact credential values and the plan pass's evidence
# patterns (record-scan.sh).
grep . "$values" > "$values.scan" || true
"$here/record-scan.sh" "$record" "$values.scan" > /dev/null
rm -f "$values" "$values.scan"

if [ -n "$(find "$record" -mindepth 1 ! -type f -print -quit)" ]; then
  die "the record holds something other than a regular file: $record"
fi
tail -n 1 "$out"
