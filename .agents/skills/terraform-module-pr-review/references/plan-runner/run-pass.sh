#!/bin/bash
# The plan pass, plan-pass.sh --mode runner, inside the isolated runner: one host command for
# a list of examples. See README.md in this directory.
#
# Usage:
#   run-pass.sh --clone DIR --record DIR (--profile NAME --role-arn ARN | --credentials-env-file FILE)
#               [--base SHA] [--diff-dir DIR]... [--budget-minutes N] [--jobs N] [--tmp DIR] [--build] <example-dir>...
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
# --jobs N, 1 to 8, or PLAN_JOBS, default 3: the head's plan containers that run side by side.
# Each slot has its own internal network and its own plan proxy, so a plan container reaches
# only its own proxy and the refused-host watcher of each container reads only its own
# refusals. Each example's block is written under its own index and the record is assembled
# in example order, whatever order the plans end in. What a verdict reads is the same as with
# --jobs 1: plan-pass.txt, addresses-<n>.json and plan-diff-<n>.json come from the blocks and
# saved plans of each example alone, and plan-refused-hosts.txt from the whole log of every plan
# proxy, before any cap, though an example that ran beside one that ended at credentials, and
# whose block is dropped, still adds its refusals there. The evidence files are not: proxy-plan.log holds each slot's log one
# after another, so its line order differs and its 5 MiB cap may keep other lines; runner.log
# takes each plan job's standard error in example order; and each slot from 2 on adds its own
# network-check-plan-<slot>.txt. An example's validate container runs in its slot after its
# plan container; the init, show, merge base and plan diff phases run one container at a time,
# in slot 1.
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
# plan proxy; so is an example this script ended because the plan proxy refused it only hosts
# refused by design, which first gets terraform validate in a container with no network and no
# credentials (README.md, Refused hosts). Examples that planned never touch the base. Every plan is saved with -out into a
# volume of its own, and the saved plan of an example that planned is then read with terraform
# show -json in one more container per example, with no network, no credentials and that
# volume read-only, after the plan container has ended; this script checks the addresses it
# prints and writes them to the record as addresses-<n>.json. This script owns the credentials:
# for each plan container it issues a session on the review role --role-arn names, with the
# profile, for 900 seconds, downscoped by the pinned session policy (../plan-session.sh), and
# mounts it read-only into that container as a file, never as --env or --env-file, so Docker
# keeps no copy in the container's configuration. The profile's own credentials never leave
# the host. A session that cannot be issued gives the container no credentials, and the plan
# pass ends at credentials there: there is no fallback to the profile's own. The container
# reads the file into the plan pass's environment, and plan-pass.sh reads them there.
#
# --diff-dir names a directory, repository-relative, that a change the host can clear by a plan
# diff sits in (../plan-pass.md, Plan diff). With --base, each example whose head planned and
# that is such a directory or calls one through a local module source gets its merge base
# example planned against the base module and against the head module, in two more containers
# behind the init and plan proxies, and compared in a container with no network and no
# credentials. Its block gets one plan-diff line, and an equal one the head module plan's
# addresses as plan-diff-<n>.json.
# --credentials-env-file is for the smoke test: a fixed file of made-up session credentials.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
pass="$(cd "$here/.." && pwd)/plan-pass.sh"
# The image tag: PLAN_RUNNER_TAG, or one derived from the files the images are built from
tag="$("$here/image-tag.sh")"
runner_image="plan-runner:$tag"
proxy_image="plan-egress-proxy:$tag"
clone="" record="" profile="" role_arn="" cred_file="" base="" build=0 budget_min=120 tmp_parent="" diffdirs=()
jobs="${PLAN_JOBS:-3}"

die() { echo "run-pass: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --clone) clone="${2:-}"; shift 2 ;;
    --record) record="${2:-}"; shift 2 ;;
    --profile) profile="${2:-}"; shift 2 ;;
    --role-arn) role_arn="${2:-}"; shift 2 ;;
    --credentials-env-file) cred_file="${2:-}"; shift 2 ;;
    --base) base="${2:-}"; shift 2 ;;
    --diff-dir) diffdirs+=("${2:-}"); shift 2 ;;
    --budget-minutes) budget_min="${2:-}"; shift 2 ;;
    --jobs) jobs="${2:-}"; shift 2 ;;
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
# A plan diff directory outside the pattern loses only its own plan diff
kept=()
for d in ${diffdirs[@]+"${diffdirs[@]}"}; do
  [[ "$d" =~ ^(\.|[A-Za-z0-9_][A-Za-z0-9._-]*(/[A-Za-z0-9_][A-Za-z0-9._-]*)*)$ ]] && kept+=("$d")
done
diffdirs=(${kept[@]+"${kept[@]}"})
[[ "$budget_min" =~ ^[1-9][0-9]{0,3}$ ]] || die "--budget-minutes must be a whole number of minutes, 1 to 9999"
budget=$((budget_min * 60))
[[ "$jobs" =~ ^[1-8]$ ]] || die "--jobs must be a whole number, 1 to 8"
slots=$jobs # no more slots than examples
[ "$slots" -le "$#" ] || slots=$#
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
: > "$TMPRUN/plan-refused"
id="$(basename "$TMPRUN" | tr -dc '[:alnum:]' | tr '[:upper:]' '[:lower:]')"
sfx="$(printf '%s' "$id" | tail -c 6)"
RUN="/work/pr-review.$sfx" # the plan pass's run directory, inside the work volume
net_int="plan-int-$id" net_ext="plan-ext-$id" volume="plan-work-$id" saved="plan-saved-$id"
runner="plan-runner-$id" proxy_init="plan-proxy-init-$id" proxy_plan="plan-proxy-plan-$id"
# Every name carries this run's id, and cleanup removes exactly these names, never by prefix.
# Slot k of the plan phase, from 2 on, adds -k to the runner, the internal network and the
# plan proxy.
echo "$id" > "$record/run-id.txt"
slot_names=()
for ((k = 2; k <= slots; k++)); do slot_names+=("$k"); done
use_slot() { # slot: this subshell's container, network, plan proxy, credentials file and stall flag
  [ "$1" -eq 1 ] && return 0
  runner="$runner-$1" net_int="$net_int-$1" proxy_plan="$proxy_plan-$1" pass_env="$TMPRUN/pass.env.$1" stalled="$TMPRUN/stalled.$1"
}

save_proxy_log() { # container, record file; a proxy may run twice, so the log is appended
  local have=0
  check_record_size "$record/$2"
  [ ! -f "$record/$2" ] || have=$(wc -c < "$record/$2")
  docker logs "$1" 2>&1 | head -c $((max_bytes - have)) >> "$record/$2" || true
  docker rm -f "$1" > /dev/null 2>&1 || true
}
# A plan job's process tree, read before the kill, so a process its end leaves behind, a docker
# client or a watcher, goes with it.
kill_tree() { # pid
  local all
  all="$(ps -A -o pid= -o ppid= | awk -v r="$1" '{ ch[$2] = ch[$2] " " $1 }
    END { q[1] = r; h = 1; t = 1; while (h <= t) { p = q[h++]; printf "%s ", p; m = split(ch[p], c, " "); for (i = 1; i <= m; i++) q[++t] = c[i] } }')" || all="$1"
  # shellcheck disable=SC2086 # a list of pids
  kill $all 2> /dev/null || true
}
job_pid=() job_ex=() job_poll=1
# A stored pid is ours only while it is a running job of this shell: once a job ends, its pid
# may be reused, so neither the poll nor the kill trusts the number alone.
job_running() { jobs -pr | grep -qx "$1"; }
stop_jobs() {
  local p
  for p in ${job_pid[@]+"${job_pid[@]}"}; do [ -n "$p" ] && job_running "$p" && kill_tree "$p"; done
  return 0
}
cleanup() {
  [ -z "${wpid:-}" ] || kill "$wpid" 2> /dev/null || true
  stop_jobs
  docker rm -f "$runner" > /dev/null 2>&1 || true
  for k in ${slot_names[@]+"${slot_names[@]}"}; do docker rm -f "$runner-$k" > /dev/null 2>&1 || true; done
  for p in "$proxy_init:proxy-init.log" "$proxy_plan:proxy-plan.log" ${slot_names[@]+$(printf "$proxy_plan-%s:proxy-plan.log " "${slot_names[@]}")}; do
    if docker container inspect "${p%%:*}" > /dev/null 2>&1; then
      # Refused evidence must not stop teardown or retain the session file. Normal
      # log collection still refuses the run; cleanup isolates that exit and continues.
      (save_proxy_log "${p%%:*}" "${p##*:}") || true
      docker rm -f "${p%%:*}" > /dev/null 2>&1 || true
    fi
  done
  docker volume rm "$volume" "$saved" > /dev/null 2>&1 || true
  for k in ${slot_names[@]+"${slot_names[@]}"}; do docker network rm "$net_int-$k" > /dev/null 2>&1 || true; done
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
values="$TMPRUN/values" pass_env="$TMPRUN/pass.env" stalled="$TMPRUN/stalled" runner_log="$record/runner.log"
printf '%s\n' "$role_arn" "$(printf '%s\n' "$role_arn" | sed -nE 's/^arn:[^:]*:iam::([0-9]{12}):.*/\1/p')" > "$values"
write_pass_env() { # AWS_* lines on stdin -> pass.env with PLAN_PASS_ names, values kept
  grep -E '^AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN)=' | sed 's/^/PLAN_PASS_/' > "$pass_env" || true
  # 0644, not 0600: the container runs as uid 10001, not the file's owner, and on a native
  # Linux daemon it could not read a 0600 file. The 0700 directory keeps other host users out.
  chmod 0644 "$pass_env"
  sed -nE 's/^PLAN_PASS_AWS_[A-Z_]+=//p' "$pass_env" >> "$values"
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
  for k in ${slot_names[@]+"${slot_names[@]}"}; do cp -p "$pass_env" "$TMPRUN/pass.env.$k"; done
fi
# Run in the plan container: exports the three names from the mounted file and no other
# line. Each line splits at its first '=', so a value keeps every '=' it has, a trailing
# base64 pad included. smoke.sh runs this exact line, found by its marker.
load_creds='while IFS= read -r l; do k=${l%%=*}; v=${l#*=}; case $k in PLAN_PASS_AWS_ACCESS_KEY_ID|PLAN_PASS_AWS_SECRET_ACCESS_KEY|PLAN_PASS_AWS_SESSION_TOKEN) export "$k=$v" ;; esac; done < /opt/plan-pass/creds.env' # creds-loader

docker volume create "$volume" > /dev/null
docker volume create "$saved" > /dev/null
docker network create --internal --ipv6=false "$net_int" > /dev/null
docker network create --ipv6=false "$net_ext" > /dev/null
for k in ${slot_names[@]+"${slot_names[@]}"}; do docker network create --internal --ipv6=false "$net_int-$k" > /dev/null; done

hardening=(--read-only --cap-drop ALL --security-opt no-new-privileges --pids-limit 512)
proxy_env=(-e HTTPS_PROXY=http://proxy:8888 -e HTTP_PROXY=http://proxy:8888
  -e https_proxy=http://proxy:8888 -e http_proxy=http://proxy:8888 -e NO_PROXY= -e no_proxy=)
common=("${hardening[@]}" --user 10001:10001 --memory 4g --tmpfs "/tmp:rw,size=64m"
  -v "$pass":/opt/plan-pass/plan-pass.sh:ro)
# The profile's extra plan providers, read by plan-pass.sh in runner mode; absent, the default eight
providers="$(cd "$here/../../.." && pwd)/terraform-module-maintainer/profiles/terraform-aws-modules/plan-providers.txt"
[ ! -f "$providers" ] || common+=(-v "$providers":/opt/plan-pass/plan-providers.txt:ro)

start_proxy() { # name, config; on this slot's internal network
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
  check_record_size "$runner_log"
  # Serialize the two streams: setup writes both to runner.log. The FIFO keeps stderr
  # bounded while Docker runs, and waiting closes it before another container starts. A plan
  # job's runner_log is its own, appended to runner.log in example order.
  local pipe="$TMPRUN/$runner.stderr.pipe" errf="$TMPRUN/$runner.stderr.txt"
  rm -f "$pipe" "$errf"
  mkfifo "$pipe"
  head -c "$max_bytes" < "$pipe" > "$errf" &
  err_pid=$!
  docker run "$@" 2> "$pipe" |
    bounded_append "$outf" || command_status=$?
  wait "$err_pid" || true
  bounded_append "$runner_log" < "$errf" || true
  rm -f "$pipe" "$errf"
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
[ "$(docker network inspect -f '{{.EnableIPv6}}' "$net_int" "$net_ext" ${slot_names[@]+$(printf "$net_int-%s " "${slot_names[@]}")} | tr '\n' ' ')" = "$(printf 'false %.0s' "$net_int" "$net_ext" ${slot_names[@]+"${slot_names[@]}"})" ] ||
  die "refusing to plan: IPv6 is on for a run network"
v4_re='^[0-9]{1,3}([.][0-9]{1,3}){3}$'
set_probe_args() { # the host addresses of this slot's internal network -> probe_args
  local gw d0 br v6 a
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
}
set_probe_args
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
# The saved plans' volume, writable by the plan containers' user: a new volume is root's, and
# its owner may change its mode with no capability.
docker run --rm --network none "${hardening[@]}" --user 0:0 -v "$saved":/saved \
  --entrypoint /bin/chmod "$runner_image" 1777 /saved

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
# Refused hosts (README.md, Refused hosts). tinyproxy logs a filter refusal on a NOTICE line of
# its own, but refuses a CONNECT to a port other than 443 with no refusal line, so those come
# from the request lines. Only whole lines in tinyproxy's own format count: a request line holds
# what the client sent, so text inside it never reads as a refusal.
refused_targets() { # tinyproxy log on stdin -> one line per refused CONNECT target
  awk 'BEGIN { p = "^[A-Z]+ +[A-Z][a-z][a-z] +[0-9]+ [0-9:.]+ \\[[0-9]+\\]: " }
    $0 ~ (p "Proxying refused on filtered url \"[^\" ]+\"$") { t = $0; sub(/^[^"]*"/, "", t); sub(/"$/, "", t); print t; next }
    $0 ~ (p "Request \\(file descriptor [0-9]+\\): CONNECT [^ ]+:[0-9]+ HTTP/1\\.[01]$") {
      t = $0; sub(/.*: CONNECT /, "", t); sub(/ HTTP\/1\.[01]$/, "", t); if (t !~ /:443$/) print t }'
}
# The refused targets of a plan proxy, read from its whole log before save_proxy_log caps it
# into proxy-plan.log, so plan-refused-hosts.txt is every plan proxy's refusals however many
# slots ran and however long the logs are. Each proxy's targets are deduplicated first and then
# cut at whole lines to max_bytes; only a proxy with over 5 MiB of distinct targets loses any.
uniq_capped() { awk -v m="$max_bytes" '!s[$0]++ { n += length($0) + 1; if (n > m) exit; print }'; }
plan_refusals() { # container
  docker logs "$1" 2>&1 | refused_targets | uniq_capped >> "$TMPRUN/plan-refused" || true
}
# A host the plan proxy refuses by design (README.md, Refused hosts): the Identity Center and
# public registry token endpoints, each a whole AWS name in a region of a known partition, on
# port 443, a closed list. ../skip-coverage.jq holds the same pattern as design_host.
design_host_re='(sso|identitystore|api\.ecr-public)\.[a-z]{2,4}(-[a-z]+){1,2}-[0-9]{1,2}\.(amazonaws\.com|amazonaws\.com\.cn|c2s\.ic\.gov|sc2s\.sgov\.gov|cloud\.adc-e\.uk|csp\.hci\.ic\.gov|amazonaws\.eu):443'
# The refused targets of the plan container that started at proxy log line $1, on one line and
# sorted in codepoint order, as skip-coverage.jq compares them, when there are 1 to 20 and every
# one is a host refused by design; nothing otherwise, a log that cannot be read included
# (../skip-coverage.md, Design skips).
design_refusals() { # proxy log lines before the container
  local t
  t="$(docker logs "$proxy_plan" 2>&1 | tail -n +"$(($1 + 1))" | refused_targets | LC_ALL=C sort -u)" || return 0
  [ -n "$t" ] && [ "$(printf '%s\n' "$t" | wc -l)" -le 20 ] || return 0
  [ -z "$(printf '%s\n' "$t" | grep -Evx "$design_host_re")" ] || return 0
  printf '%s\n' "$t" | paste -sd ' ' -
}
# The head's own terraform validate of one example, in a container with no network and no
# credentials, as the show phase reads a saved plan: the evidence that a plan the runner ended
# early hid no type error (../skip-coverage.md, Design skips). One fixed line: the container's
# one validate line when it printed exactly one and it is passed or failed, else not run.
validate_example() { # index, example
  local rem v; rem=$(left)
  [ "$rem" -gt 0 ] || { echo 'validate: not run'; return 0; }
  : > "$TMPRUN/validate.out.$1"
  in_runner "$TMPRUN/validate.out.$1" --network none "${common[@]}" -v "$volume":/work:ro \
    --tmpfs "$RUN/plan/out:rw,size=256m,mode=1777" --tmpfs "$RUN/plan/tmp:rw,size=64m,mode=1777" \
    --tmpfs "$RUN/plan/home:rw,size=64m,mode=1777" --entrypoint /bin/bash "$runner_image" -c \
    "exec bash /opt/plan-pass/plan-pass.sh plan '$RUN' '$pname' --mode runner --budget '$rem' --phase validate --index '$1' \"\$@\"" \
    plan-pass "$2"
  v="$(grep -E '^validate: ' "$TMPRUN/validate.out.$1")" || v=
  case "$v" in 'validate: passed'|'validate: failed') printf '%s\n' "$v" ;; *) echo 'validate: not run' ;; esac
}
# A plan whose provider keeps retrying a host the plan proxy refuses would wait for the plan's
# time limit. While a plan container runs, stall_watch reads the plan proxy's log from the line
# the container started at: once one host has been refused stall_tries times and the container
# is still running stall_grace seconds later, it kills the container and writes that host to the
# flag file. The flag is written only when the kill found the container running, so a plan that
# ended on its own keeps its result. The kill and the flag ignore TERM, so the parent's kill
# and wait after the container ends cannot cut them apart; the watcher ends when its parent is
# gone.
stall_tries=3 stall_grace=60 stall_poll=5 wpid= plan_since=
stall_watch() { # proxy log lines before this container, flag file
  local since="" h
  while sleep "$stall_poll"; do
    kill -0 "$$" 2> /dev/null || return 0
    h="$(docker logs "$proxy_plan" 2>&1 | tail -n +"$(($1 + 1))" | refused_targets | sort | uniq -c |
      awk -v n="$stall_tries" '$1 >= n { print $2; exit }')" || h=""
    [ -n "$h" ] || continue
    [ -n "$since" ] || since=$SECONDS
    [ $((SECONDS - since)) -ge "$stall_grace" ] || continue
    trap '' TERM
    if docker kill "$runner" > /dev/null 2>&1; then printf '%s\n' "$h" > "$2"; fi
    return 0
  done
}
plan_container() { # output file, phase, index, example, budget left: the work volume read-only, the credentials in
  # The volume stays read-only; the example's own plan may write into its directory, as the
  # lambda module's packaging does, so the clone (and the base worktree) are private
  # writable copies on tmpfs, seeded from the volume at start and gone with the container.
  local base_tmpfs=() seed_base=: lines
  if [ "$2" = base-plan ] || [ "$2" = diff-plan ]; then
    base_tmpfs=(--tmpfs "$RUN/base:rw,size=1g,mode=1777")
    seed_base="{ [ ! -d '$SEED/base' ] || cp -dR '$SEED/base/.' '$RUN/base/'; }"
  fi
  # The plan diff's head tree with the merge base example (../plan-pass.md, Plan diff)
  if [ "$2" = diff-plan ]; then
    base_tmpfs+=(--tmpfs "$RUN/mixed:rw,size=1g,mode=1777")
    seed_base="$seed_base && { [ ! -d '$SEED/mixed' ] || cp -dR '$SEED/mixed/.' '$RUN/mixed/'; }"
  fi
  issue_session
  rm -f "$stalled"
  plan_since=
  # No watcher when the log cannot be read: a baseline of 0 would count earlier refusals
  if lines="$(docker logs "$proxy_plan" 2>&1 | wc -l | tr -d ' ')" && [[ "$lines" =~ ^[0-9]+$ ]]; then
    stall_watch "$lines" "$stalled" &
    wpid=$!
    plan_since=$lines
  fi
  in_runner "$1" --network "$net_int" "${common[@]}" "${proxy_env[@]}" \
    -v "$volume":/work:ro -v "$volume":/seed:ro \
    --tmpfs "$RUN/clone:rw,size=1g,mode=1777" ${base_tmpfs[@]+"${base_tmpfs[@]}"} -v "$saved":"$RUN/plan/saved" \
    --tmpfs "$RUN/plan/out:rw,size=256m,mode=1777" --tmpfs "$RUN/plan/tmp:rw,size=256m,mode=1777" \
    --tmpfs "$RUN/plan/home:rw,size=64m,mode=1777" -v "$pass_env":/opt/plan-pass/creds.env:ro \
    --entrypoint /bin/bash "$runner_image" -c \
    "$load_creds && cp -dR '$SEED/clone/.' '$RUN/clone/' && $seed_base && exec bash /opt/plan-pass/plan-pass.sh plan '$RUN' '$pname' --mode runner --budget '$5' --phase '$2' --index '$3' \"\$@\"" \
    plan-pass ${base_args[@]+"${base_args[@]}"} "$4"
  if [ -n "$wpid" ]; then
    kill "$wpid" 2> /dev/null || true
    wait "$wpid" 2> /dev/null || true
  fi
  wpid=
}
# Lines only the host may write; the container's output is untrusted and may not forge them. A
# base-denied line comes only from a merge base re-run's own container, and the refused-host
# class with its refused, validate and base-refused lines only from this script (skip-coverage.md,
# Design skips).
host_only='^(plan summary:|plan pass mode:|plan pass budget:|host example |not reached:|plan-diff: |base-denied: |refused: |base-refused: |validate: |(plan|base): environment \(refused-host\))'
# The one credentials line a container may write, from plan-pass.sh's fixed list: the first
# such line is kept, any other credentials line is dropped
cred_re='^credentials: (session: not issued|write probe: write allowed|(identity check|write probe): (timed out|expired token|invalid token|access denied|throttled|network|other answer))$'
untrusted() { grep -Ev "$host_only" "$1" | awk -v re="$cred_re" '!/^credentials: / || ($0 ~ re && !c++)' || true; }

# Plan phase: one container per example, up to $slots side by side. Each block is kept apart
# until the end, because a deferred merge base re-run fills in its base line later. Slot 1 is
# the run's own network and plan proxy; every further slot gets its own, checked as slot 1's
# is before its first plan container.
start_proxy "$proxy_plan" plan.conf
network_check plan --allowed sts.us-east-1.amazonaws.com --refused registry.terraform.io
for k in ${slot_names[@]+"${slot_names[@]}"}; do
  (use_slot "$k"; start_proxy "$proxy_plan" plan.conf; set_probe_args
    network_check "plan-$k" --allowed sts.us-east-1.amazonaws.com --refused registry.terraform.io) || exit 2
done
# One example in one slot, in a subshell that took the slot's names: its plan container, then
# its block, written whole under its own index.
plan_example() { # index, example, budget left
  local n=$1 ex=$2 blk="$TMPRUN/block.$1.part" hosts vline
  : > "$TMPRUN/example.out.$n"
  plan_container "$TMPRUN/example.out.$n" plan "$n" "$ex" "$3"
  untrusted "$TMPRUN/example.out.$n" > "$blk"
  # Ended by stall_watch: the plan did not finish, whatever the container printed. When every
  # refusal was of a host refused by design, environment (refused-host) with those hosts, the
  # head's validate and a merge base re-run (skip-coverage.md, Design skips); otherwise
  # environment (network).
  if [ -s "$stalled" ]; then
    hosts="$(design_refusals "$plan_since")"
    if [ -n "$hosts" ]; then
      vline="$(validate_example "$n" "$ex")"
      { printf 'example: %s\nplan: environment (refused-host)\nrefused: %s\n%s\n' "$ex" "$hosts" "$vline"
        if [ -n "$base" ]; then echo 'base: deferred'; else echo 'base: not available'; fi; } > "$blk"
    else
      printf 'example: %s\nplan: environment (network)\n' "$ex" > "$blk"
    fi
  fi
  mv "$blk" "$TMPRUN/block.$n"
}
# Each example in turn into the first free slot, until the list ends, or an example ends at
# credentials: then no example starts after it. The budget is read once per example as it
# starts; an example it does not reach is plan: budget. Each session is issued here, one at a
# time, just before its container starts.
plan_jobs() {
  local next=1 k busy rem stop=0
  while :; do
    busy=0
    for ((k = 1; k <= slots; k++)); do
      [ -n "${job_pid[k]:-}" ] || continue
      if job_running "${job_pid[k]}"; then busy=$((busy + 1)); continue; fi
      wait "${job_pid[k]}" 2> /dev/null || true
      # The first plan line decides, as in the loop below; a job that left no block stops
      # the run there too, so no example starts after it
      if [ -f "$TMPRUN/block.${job_ex[k]}" ]; then
        case "$(grep -m 1 '^plan: ' "$TMPRUN/block.${job_ex[k]}" || true)" in 'plan: plan pass ended: credentials'*) stop=1 ;; esac
      else
        stop=1
      fi
      job_pid[k]=
    done
    k=1
    while [ "$k" -le "$slots" ] && [ "$next" -le "${#examples[@]}" ] && [ "$stop" -eq 0 ]; do
      if [ -n "${job_pid[k]:-}" ]; then k=$((k + 1)); continue; fi
      rem=$(left)
      if [ "$rem" -le 0 ]; then
        printf 'example: %s\nplan: budget\n' "${examples[next - 1]}" > "$TMPRUN/block.$next"; next=$((next + 1)); continue
      fi
      (use_slot "$k"; issue_session)
      (use_slot "$k"; issue_session() { :; }; runner_log="$TMPRUN/runner-log.$next"
        plan_example "$next" "${examples[next - 1]}" "$rem") &
      job_pid[k]=$! job_ex[k]=$next
      busy=$((busy + 1)) next=$((next + 1)) k=$((k + 1))
    done
    if [ "$busy" -eq 0 ] && { [ "$next" -gt "${#examples[@]}" ] || [ "$stop" -eq 1 ]; }; then break; fi
    sleep "$job_poll"
  done
}
n=0 planned=0 exc=0 deferred=() examples=("$@") cut=0
plan_jobs
# In example order: the counts, the merge base re-runs, each job's stderr into runner.log, and
# no block after the first example that ended at credentials, as a run of one slot stops there.
for ex in "$@"; do
  n=$((n + 1)); blk="$TMPRUN/block.$n"
  if [ "$cut" -eq 1 ]; then rm -f "$blk"; continue; fi
  # A job that ended with no block failed where a run of one slot would have stopped
  [ -f "$blk" ] || die "the plan of example $n ended with no record block"
  [ ! -f "$TMPRUN/runner-log.$n" ] || bounded_append "$record/runner.log" < "$TMPRUN/runner-log.$n"
  line="$(grep -m 1 '^plan: ' "$blk" || true)"
  case "$line" in
    'plan: planned'*) planned=$((planned + 1)) ;; # planned and planned-no-changes
    'plan: exception:'*) exc=$((exc + 1)) ;;
    # a code-error, an access denial on data source reads alone, and hosts refused by design
    # (skip-coverage.md, Design skips)
    'plan: code-error'*|'plan: environment (access-denied)'*|'plan: environment (refused-host)'*) [ -z "$base" ] || ! grep -qx 'base: deferred' "$blk" || deferred+=("$n") ;;
    'plan: plan pass ended: credentials'*) cut=1 ;;
  esac
done
plan_refusals "$proxy_plan"; save_proxy_log "$proxy_plan" proxy-plan.log
for k in ${slot_names[@]+"${slot_names[@]}"}; do plan_refusals "$proxy_plan-$k"; save_proxy_log "$proxy_plan-$k" proxy-plan.log; done

# The saved plan of each example that planned, read outside the container that ran the head's
# code: no network, no credentials, both volumes read-only. Only an addresses-json line the
# host's own checks accept reaches the record, reduced to the patterns below. A sensitive entry
# outside its shape is dropped, never emptied: a missing one reads as unknown, an empty one as
# none sensitive.
# shellcheck disable=SC2016 # a jq program
clean_addresses='. as $x
  | [($x.addresses? | if type == "array" then .[] else empty end)
     | select(type == "string" and length <= 300
       and test("^(module\\.[A-Za-z0-9_-]+\\.)*(data\\.)?(?!data\\.|module\\.)[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\z"))] | unique | .[:1000]
  | . as $s
  | {addresses: $s,
     attributes: (($x.attributes? | if type == "object" then . else {} end)
       | with_entries(select(.key as $k | ($s | index($k)) != null)
           | .value |= ([(if type == "array" then .[] else empty end)
                         | select(type == "string" and test("^[a-z0-9_]{1,128}$"))] | unique | .[:500]))),
     module_calls: ($x.module_calls? | if type == "object" then with_entries(select((.key | test("^[A-Za-z0-9_-]{1,64}$"))
                  and (.value | type == "string" and test("^[.][.]?(/[A-Za-z0-9_.-]+)*/?$")))) else {} end)}
  + (if ($x.sensitive? | type) == "object" then {sensitive: ($x.sensitive
       | with_entries(select((.key as $k | ($s | index($k)) != null)
           and (.value | type == "array" and length <= 500
                and all(.[]; type == "string" and test("^[a-z0-9_]{1,128}$"))))
           | .value |= unique))} else {} end)'
n=0
for ex in "$@"; do
  n=$((n + 1))
  [ -f "$TMPRUN/block.$n" ] && grep -Eq '^plan: planned' "$TMPRUN/block.$n" || continue
  rem=$(left)
  [ "$rem" -gt 0 ] || break
  : > "$TMPRUN/show.out"
  in_runner "$TMPRUN/show.out" --network none "${common[@]}" \
    -v "$volume":/work:ro -v "$saved":"$RUN/plan/saved":ro \
    --tmpfs "$RUN/plan/out:rw,size=256m,mode=1777" --tmpfs "$RUN/plan/tmp:rw,size=64m,mode=1777" \
    --tmpfs "$RUN/plan/home:rw,size=64m,mode=1777" --entrypoint /bin/bash "$runner_image" -c \
    "exec bash /opt/plan-pass/plan-pass.sh plan '$RUN' '$pname' --mode runner --budget '$rem' --phase show --index '$n' \"\$@\"" \
    plan-pass "$ex"
  sed -n 's/^addresses-json: //p' "$TMPRUN/show.out" | head -n 1 | jq -c "$clean_addresses" > "$TMPRUN/addresses.$n" 2> /dev/null || true
  [ -s "$TMPRUN/addresses.$n" ] && mv "$TMPRUN/addresses.$n" "$record/addresses-$n.json"
  rm -f "$TMPRUN/addresses.$n"
done

# The plan diff (../plan-pass.md, Plan diff): each example whose head planned, with the
# addresses this script accepted, that calls a plan diff directory through a local module source
# of its root module, resolved against the example directory, outside the example's own directory.
# shellcheck disable=SC2016 # a jq program
reaches_jq='def resolve($d): ($d + "/" + .) | split("/")
    | reduce .[] as $p ([]; if . == null then null elif $p == "" or $p == "." then .
        elif $p == ".." then (if length == 0 then null else .[:-1] end) else . + [$p] end)
    | if . == null then null elif length == 0 then "." else join("/") end;
  any((.module_calls // {}) | to_entries[] | .value | strings | resolve($d)
    | select(. != $d and (startswith($d + "/") | not)); IN($dd[]))'
diffs=()
if [ -n "$base" ] && [ "${#diffdirs[@]}" -gt 0 ]; then
  dd="$(printf '%s\n' "${diffdirs[@]}" | jq -R . | jq -s -c .)"
  n=0
  for ex in "$@"; do
    n=$((n + 1))
    [ -f "$record/addresses-$n.json" ] && grep -Eq '^plan: planned' "$TMPRUN/block.$n" || continue
    jq -e --arg d "$ex" --argjson dd "$dd" "$reaches_jq" "$record/addresses-$n.json" > /dev/null 2>&1 && diffs+=("$n")
  done
fi

# Merge base re-run, only for the code-errors, and the plan diffs: the base worktree and its init
# behind the init proxy with no credentials, then its plan behind the plan proxy. One proxy runs
# at a time, since both answer to the same name on the internal network.
if [ "${#deferred[@]}" -gt 0 ] || [ "${#diffs[@]}" -gt 0 ]; then
  start_proxy "$proxy_init" init.conf
  for n in ${deferred[@]+"${deferred[@]}"}; do
    rem=$(left)
    [ "$rem" -gt 0 ] || break # base-plan then records the budget
    ex="${examples[n - 1]}"
    in_runner "$record/plan-pass-init.txt" --network "$net_int" "${common[@]}" "${proxy_env[@]}" \
      -v "$volume":/work --entrypoint /bin/bash "$runner_image" -c \
      "exec bash /opt/plan-pass/plan-pass.sh plan '$RUN' '$pname' --mode runner --budget '$rem' --phase base-init --index '$n' \"\$@\"" \
      plan-pass --base "$base" "$ex"
  done
  for n in ${diffs[@]+"${diffs[@]}"}; do
    rem=$(left)
    [ "$rem" -gt 0 ] || break
    ex="${examples[n - 1]}"
    in_runner "$record/plan-pass-init.txt" --network "$net_int" "${common[@]}" "${proxy_env[@]}" \
      -v "$volume":/work --entrypoint /bin/bash "$runner_image" -c \
      "exec bash /opt/plan-pass/plan-pass.sh plan '$RUN' '$pname' --mode runner --budget '$rem' --phase diff-init --index '$n' \"\$@\"" \
      plan-pass --base "$base" "$ex"
  done
  save_proxy_log "$proxy_init" proxy-init.log
  start_proxy "$proxy_plan" plan.conf
  for n in ${deferred[@]+"${deferred[@]}"}; do
    rem=$(left)
    if [ "$rem" -le 0 ]; then echo 'base: budget' > "$TMPRUN/base.$n"; continue; fi
    ex="${examples[n - 1]}"
    : > "$TMPRUN/example.out"
    plan_container "$TMPRUN/example.out" base-plan "$n" "$ex" "$rem"
    { grep -E '^base: ' "$TMPRUN/example.out" | grep -Ev '^base: environment \(refused-host\)' | head -n 1
      grep -E '^base-denied: ' "$TMPRUN/example.out" | head -n 1
      untrusted "$TMPRUN/example.out" | grep '^credentials: ' | head -n 1; } > "$TMPRUN/base.$n" || true
    if [ -s "$stalled" ]; then
      hosts="$(design_refusals "$plan_since")"
      if [ -n "$hosts" ]; then printf 'base: environment (refused-host)\nbase-refused: %s\n' "$hosts" > "$TMPRUN/base.$n"
      else echo 'base: environment (network)' > "$TMPRUN/base.$n"; fi
    fi
    [ -s "$TMPRUN/base.$n" ] || echo 'base: not available' > "$TMPRUN/base.$n"
  done
  for n in ${diffs[@]+"${diffs[@]}"}; do
    rem=$(left)
    [ "$rem" -gt 0 ] || break
    : > "$TMPRUN/example.out"
    plan_container "$TMPRUN/example.out" diff-plan "$n" "${examples[n - 1]}" "$rem"
  done
  plan_refusals "$proxy_plan"; save_proxy_log "$proxy_plan" proxy-plan.log
fi
# The comparison of each plan diff, read outside the containers that ran the head's code, as
# the show phase is. Only a plan-diff line in its grammar reaches the record, and only an equal
# one's addresses and local module calls, reduced by clean_addresses; anything else is not-run show.
pdiff_re='^plan-diff: (equal|unknown|differs( [A-Za-z0-9_.-]+){0,50}|not-run (no-base|absent-at-base|base-plan|head-module-plan|show|budget))$'
for n in ${diffs[@]+"${diffs[@]}"}; do
  rem=$(left)
  if [ "$rem" -le 0 ]; then echo 'plan-diff: not-run budget' > "$TMPRUN/pdiff.$n"; continue; fi
  : > "$TMPRUN/diff.out"
  in_runner "$TMPRUN/diff.out" --network none "${common[@]}" \
    -v "$volume":/work:ro -v "$saved":"$RUN/plan/saved":ro \
    --tmpfs "$RUN/plan/out:rw,size=256m,mode=1777" --tmpfs "$RUN/plan/tmp:rw,size=64m,mode=1777" \
    --tmpfs "$RUN/plan/home:rw,size=64m,mode=1777" --entrypoint /bin/bash "$runner_image" -c \
    "exec bash /opt/plan-pass/plan-pass.sh plan '$RUN' '$pname' --mode runner --budget '$rem' --phase diff --index '$n' \"\$@\"" \
    plan-pass "${examples[n - 1]}"
  line="$(grep -E -m 1 '^plan-diff: ' "$TMPRUN/diff.out" || true)"
  [[ "$line" =~ $pdiff_re ]] || line='plan-diff: not-run show'
  if [ "$line" = 'plan-diff: equal' ]; then
    sed -n 's/^plan-diff-json: //p' "$TMPRUN/diff.out" | head -n 1 | jq -c "$clean_addresses"' | {addresses, module_calls}' \
      > "$TMPRUN/pdaddr.$n" 2> /dev/null || true
    if [ -s "$TMPRUN/pdaddr.$n" ]; then mv "$TMPRUN/pdaddr.$n" "$record/plan-diff-$n.json"; else line='plan-diff: not-run show'; fi
    rm -f "$TMPRUN/pdaddr.$n"
  fi
  printf '%s\n' "$line" > "$TMPRUN/pdiff.$n"
done
rm -f "$TMPRUN"/pass.env* # no plan container runs after this

# The record: each block headed by the host with its own index, so a forged block cannot claim
# another example, and a deferred base line replaced by its re-run's result.
n=0
for ex in "$@"; do
  n=$((n + 1))
  check_record_size "$TMPRUN/block.$n"
  check_record_size "$TMPRUN/base.$n"
  check_record_size "$TMPRUN/pdiff.$n"
done
assemble_record() {
printf 'plan pass mode: runner\nplan pass budget: %s minutes\n' "$budget_min"
n=0
for ex in "$@"; do
  n=$((n + 1))
  # No block: the plan loop ended at credentials before this example, which never started
  [ -f "$TMPRUN/block.$n" ] || { printf 'not reached: %s\n' "$ex"; continue; }
  check_record_size "$TMPRUN/block.$n"
  check_record_size "$TMPRUN/base.$n"
  printf 'host example %s: %s\n' "$n" "$ex"
  if [ -f "$TMPRUN/base.$n" ]; then
    awk -v f="$TMPRUN/base.$n" '$0 == "base: deferred" { while ((getline l < f) > 0) print l; next } { print }' \
      "$TMPRUN/block.$n"
  else
    sed 's/^base: deferred$/base: not available/' "$TMPRUN/block.$n"
  fi
  [ ! -f "$TMPRUN/pdiff.$n" ] || cat "$TMPRUN/pdiff.$n"
done
echo "plan summary: $# examples, $planned planned, $exc exceptions, $(($# - planned - exc)) other"
}
# Keep one byte beyond the allowance so an oversized assembly is refused, rather than
# publishing a truncated record that might retain a forged summary from an earlier block.
assemble_record "$@" | head -c "$((max_bytes + 1))" > "$TMPRUN/assembled.txt" || true
check_record_size "$TMPRUN/assembled.txt"
out="$record/plan-pass.txt"
mv "$TMPRUN/assembled.txt" "$out"

sort -u "$TMPRUN/plan-refused" | uniq_capped > "$record/plan-refused-hosts.txt" || true

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
