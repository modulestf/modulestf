#!/bin/bash
# Host side of the isolated plan runner: run one example's init and plan in a container
# on an internal network whose only way out is an egress proxy, with a different proxy
# allowlist per phase, export the record, remove everything. See README.md.
#
# Usage:
#   run-plan.sh --clone DIR --example REL --record DIR
#               [--profile NAME | --credentials-env-file FILE] [--probe] [--build]
#
# The record directory must not exist yet; it is created 0700 and receives regular files
# only.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# The image tag: PLAN_RUNNER_TAG, or one derived from the files the images are built from
tag="$("$here/image-tag.sh")"
runner_image="plan-runner:$tag"
proxy_image="plan-egress-proxy:$tag"
clone="" example="" record="" profile="" cred_file="" probe=0 build=0
# The only files the record takes from the runner's work volume.
record_files=(status init.log plan.log probe-init.log probe-plan.log)

die() { echo "run-plan: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --clone) clone="${2:-}"; shift 2 ;;
    --example) example="${2:-}"; shift 2 ;;
    --record) record="${2:-}"; shift 2 ;;
    --profile) profile="${2:-}"; shift 2 ;;
    --credentials-env-file) cred_file="${2:-}"; shift 2 ;;
    --probe) probe=1; shift ;;
    --build) build=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$clone" ] && [ -d "$clone" ] || die "--clone must name a directory"
[ -n "$example" ] || die "--example is required"
case "$example" in /* | *..*) die "refusing example path: $example" ;; esac
[ -d "$clone/$example" ] || die "no such example: $example"
[ -n "$record" ] || die "--record is required"
[ ! -e "$record" ] && [ ! -L "$record" ] || die "--record must not exist yet: $record"
[ -z "$profile" ] || [ -z "$cred_file" ] || die "--profile and --credentials-env-file exclude each other"
if [ -n "$profile" ]; then
  [[ "$profile" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]{0,63}$ ]] || die "invalid profile name"
fi
if [ -n "$cred_file" ]; then
  [ -f "$cred_file" ] || die "no such credentials file: $cred_file"
fi
clone="$(cd "$clone" && pwd)"
mkdir -m 0700 "$record"
record="$(cd "$record" && pwd)"
max_bytes=5242880 # a record file, a log or a container's output stops at 5 MiB

if [ "$build" -eq 1 ]; then
  docker build -q -f "$here/Dockerfile.proxy" -t "$proxy_image" "$here" > /dev/null
  docker build -q -f "$here/Dockerfile.runner" -t "$runner_image" "$here" > /dev/null
fi

RUN="$(mktemp -d "${TMPDIR:-/tmp}/plan-runner.XXXXXX")"
chmod 0700 "$RUN"
id="$(basename "$RUN" | tr -dc '[:alnum:]' | tr '[:upper:]' '[:lower:]')"
net_int="plan-int-$id" net_ext="plan-ext-$id" runner="plan-runner-$id"
proxy_init="plan-proxy-init-$id" proxy_plan="plan-proxy-plan-$id"
volume="plan-work-$id" exporter="plan-export-$id"
# Every name carries this run's id, and cleanup removes exactly these names, never by prefix
echo "$id" > "$record/run-id.txt"

save_proxy_log() { # container, record file
  docker logs "$1" 2>&1 | head -c "$max_bytes" > "$record/$2" || true
  docker rm -f "$1" > /dev/null 2>&1 || true
}
cleanup() {
  docker rm -f "$runner" "$exporter" > /dev/null 2>&1 || true
  for p in "$proxy_init:proxy-init.log" "$proxy_plan:proxy-plan.log"; do
    if docker container inspect "${p%%:*}" > /dev/null 2>&1; then
      save_proxy_log "${p%%:*}" "${p##*:}"
    fi
  done
  docker volume rm "$volume" > /dev/null 2>&1 || true
  docker network rm "$net_int" "$net_ext" > /dev/null 2>&1 || true
  case "$RUN" in
    "${TMPDIR:-/tmp}"/plan-runner.??????) rm -rf -- "$RUN" ;;
    *) echo "refusing to delete: $RUN" >&2 ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

creds=""
if [ -n "$profile" ]; then
  aws configure export-credentials --profile="$profile" --format env-no-export \
    --no-cli-pager < /dev/null > "$RUN/creds.env"
  creds="$RUN/creds.env"
elif [ -n "$cred_file" ]; then
  creds="$cred_file"
fi
if [ -n "$creds" ] && ! grep -Eq '^AWS_SESSION_TOKEN=.+' "$creds"; then
  die "the credentials carry no session token, so they are long-lived keys; use a role or SSO profile"
fi

# The work directory is a named volume, never a host directory, so nothing the runner
# writes there, a symlink included, is ever resolved on the host. Docker seeds an empty
# volume from the image's /work, which is owned by the runner's uid.
docker volume create "$volume" > /dev/null
docker network create --internal "$net_int" > /dev/null
docker network create "$net_ext" > /dev/null

hardening=(--read-only --cap-drop ALL --security-opt no-new-privileges --pids-limit 512)
proxy_env=(-e HTTPS_PROXY=http://proxy:8888 -e HTTP_PROXY=http://proxy:8888
  -e https_proxy=http://proxy:8888 -e http_proxy=http://proxy:8888 -e NO_PROXY= -e no_proxy=)
runner_opts=(--network "$net_int" "${hardening[@]}" --user 10001:10001
  --tmpfs "/tmp:rw,size=64m" -v "$clone":/src:ro -v "$volume":/work "${proxy_env[@]}")

start_proxy() { # name, config
  docker run -d --name "$1" --network "$net_ext" "${hardening[@]}" \
    --tmpfs /tmp:rw,size=16m "$proxy_image" "/etc/tinyproxy/$2" > /dev/null
  docker network connect --alias proxy "$net_int" "$1"
}
run_runner() { # args for the runner container, after the image
  docker rm -f "$runner" > /dev/null 2>&1 || true
  docker run --name "$runner" "${runner_opts[@]}" "$@" 2>&1 | head -c "$max_bytes" >> "$record/runner.log" || true
}
# Copy one file out of the work volume into the record, only if it is a regular file.
# docker cp streams a tar archive and never follows a link; the host reads the archive's
# listing first and extracts the content to standard output, so no link, device or other
# path is ever created on the host.
export_file() { # name
  local tarball="$RUN/export.tar" listing
  rm -f "$tarball"
  # The copy stops at the cap plus room for the tar headers, so a huge file never lands whole
  docker cp "$exporter:/work/out/$1" - 2>/dev/null | head -c $((max_bytes + 65536)) > "$tarball" || true
  [ -s "$tarball" ] || return 0
  if [ "$(wc -c < "$tarball" | tr -d ' ')" -ge $((max_bytes + 65536)) ]; then
    echo "larger than $max_bytes bytes, not exported: out/$1" >> "$record/export-refused.txt"
    return 0
  fi
  listing="$(tar -tvf "$tarball" 2>/dev/null)" || return 0
  if [ "$(printf '%s\n' "$listing" | wc -l | tr -d ' ')" != 1 ] || [ "${listing:0:1}" != "-" ]; then
    echo "not a regular file in the work volume, not exported: out/$1" >> "$record/export-refused.txt"
    return 0
  fi
  tar -xOf "$tarball" "$1" > "$record/$1"
}
export_record() {
  docker rm -f "$exporter" > /dev/null 2>&1 || true
  docker create --name "$exporter" --network none -v "$volume":/work "$runner_image" > /dev/null
  for f in "${record_files[@]}"; do export_file "$f"; done
  docker rm -f "$exporter" > /dev/null 2>&1 || true
}

# Phase 1: init, no credentials, registry and download hosts only.
start_proxy "$proxy_init" init.conf
run_runner --memory 4g "$runner_image" init "$example"
if [ "$probe" -eq 1 ]; then
  run_runner --entrypoint /usr/local/bin/egress-probe "$runner_image" init
fi
save_proxy_log "$proxy_init" proxy-init.log
export_record

# Phase 2: plan, with credentials, AWS service endpoints only.
if [ -f "$record/status" ] && [ ! -L "$record/status" ] && grep -qx 'init 0' "$record/status"; then
  start_proxy "$proxy_plan" plan.conf
  env_args=()
  [ -z "$creds" ] || env_args=(--env-file "$creds")
  # The ${a[@]+...} form keeps an empty array safe under set -u in bash 3.2.
  run_runner --memory 4g ${env_args[@]+"${env_args[@]}"} "$runner_image" plan "$example"
  if [ "$probe" -eq 1 ]; then
    run_runner --entrypoint /usr/local/bin/egress-probe "$runner_image" plan
  fi
  save_proxy_log "$proxy_plan" proxy-plan.log
  # Hosts the plan phase was refused: each one names an endpoint an example needed.
  # tinyproxy logs a filter refusal, but refuses a CONNECT to a port other than 443
  # with no refusal line, so those come from the CONNECT request lines.
  {
    grep -o 'refused on filtered url "[^"]*"' "$record/proxy-plan.log" \
      | sed -E 's/.*"([^"]*)"/\1/'
    grep -o 'Request ([^)]*): CONNECT [^ ]*' "$record/proxy-plan.log" \
      | sed -E 's/.*CONNECT //' | grep -v ':443$'
  } | sort -u > "$record/plan-refused-hosts.txt" || true
  export_record
fi

# The record holds regular files only.
if [ -n "$(find "$record" -mindepth 1 ! -type f -print -quit)" ]; then
  die "the record holds something other than a regular file: $record"
fi
if [ -f "$record/status" ]; then
  cat "$record/status"
else
  echo "no status recorded"
fi
