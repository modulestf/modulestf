#!/bin/bash
# Host side of the test pass (../test-pass.md): one directory's Python unit tests in the runner
# image, on an internal network whose only way out is an egress proxy that passes the Python
# package index alone, with no credentials, then the result line, then everything removed.
#
# Usage:
#   run-tests.sh --archive FILE --kind pipenv|requirements --python python3|python3.12
#                --record DIR [--budget-minutes N] [--tmp DIR] [--build]
#
# --archive is a tar of the test directory, made by the caller from the head with git archive;
# no host path of the head is mounted. --kind and --python come from the caller's reading of the
# merge base, never from the archive. The record directory must not exist yet; it is created 0700
# and ends up holding regular files only: run-id.txt, network-check-test.txt, proxy-test.log
# and tests.txt, whose one line is the result: passed <n>, failed <n> or error <class>.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tag="$("$here/image-tag.sh")"
runner_image="plan-runner:$tag"
proxy_image="plan-egress-proxy:$tag"
archive="" kind="" py="" record="" budget_min=10 tmp_parent="" build=0

die() { echo "run-tests: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --archive) archive="${2:-}"; shift 2 ;;
    --kind) kind="${2:-}"; shift 2 ;;
    --python) py="${2:-}"; shift 2 ;;
    --record) record="${2:-}"; shift 2 ;;
    --budget-minutes) budget_min="${2:-}"; shift 2 ;;
    --tmp) tmp_parent="${2:-}"; shift 2 ;;
    --build) build=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -f "$archive" ] && [ ! -L "$archive" ] || die "--archive must name a regular file"
case "$kind" in pipenv | requirements) ;; *) die "--kind must be pipenv or requirements" ;; esac
case "$py" in python3 | python3.12) ;; *) die "--python must be python3 or python3.12" ;; esac
[[ "$budget_min" =~ ^[1-9][0-9]?$ ]] || die "--budget-minutes must be 1 to 99"
[ -n "$record" ] && [ ! -e "$record" ] && [ ! -L "$record" ] || die "--record must not exist yet"
if [ -n "$tmp_parent" ]; then
  [ -d "$tmp_parent" ] && [ ! -L "$tmp_parent" ] || die "--tmp must name an existing directory"
  tmp_parent="$(cd "$tmp_parent" && pwd -P)"
else
  tmp_parent="${TMPDIR:-/tmp}"
fi
budget=$((budget_min * 60))
out_cap=65536 # the test container's output, of which only the result line is read
log_cap=5242880
mkdir -m 0700 "$record"
record="$(cd "$record" && pwd)"

if [ "$build" -eq 1 ]; then
  docker build -q -f "$here/Dockerfile.proxy" -t "$proxy_image" "$here" > /dev/null
  docker build -q -f "$here/Dockerfile.runner" -t "$runner_image" "$here" > /dev/null
fi

TMPRUN="$(mktemp -d "$tmp_parent/test-runner.XXXXXX")"
chmod 0700 "$TMPRUN"
id="$(basename "$TMPRUN" | tr -dc '[:alnum:]' | tr '[:upper:]' '[:lower:]')"
net_int="test-int-$id" net_ext="test-ext-$id" volume="test-work-$id"
runner="test-runner-$id" proxy="test-proxy-$id"
# Every name carries this run's id, and cleanup removes exactly these names, never by prefix
echo "$id" > "$record/run-id.txt"

cleanup() {
  docker rm -f "$runner" > /dev/null 2>&1 || true
  if docker container inspect "$proxy" > /dev/null 2>&1; then
    docker logs "$proxy" 2>&1 | head -c "$log_cap" > "$record/proxy-test.log" || true
    docker rm -f "$proxy" > /dev/null 2>&1 || true
  fi
  docker volume rm "$volume" > /dev/null 2>&1 || true
  docker network rm "$net_int" "$net_ext" > /dev/null 2>&1 || true
  case "$TMPRUN" in
    "$tmp_parent"/test-runner.??????) rm -rf -- "$TMPRUN" ;;
    *) echo "refusing to delete: $TMPRUN" >&2 ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM
finish() { # result: the record's one line and standard output
  printf '%s\n' "$1" > "$record/tests.txt"
  echo "$1"
  exit 0
}

docker volume create "$volume" > /dev/null
docker network create --internal --ipv6=false "$net_int" > /dev/null
docker network create --ipv6=false "$net_ext" > /dev/null

hardening=(--read-only --cap-drop ALL --security-opt no-new-privileges --pids-limit 512)
proxy_env=(-e HTTPS_PROXY=http://proxy:8888 -e HTTP_PROXY=http://proxy:8888
  -e https_proxy=http://proxy:8888 -e http_proxy=http://proxy:8888 -e NO_PROXY= -e no_proxy=)
common=(--network "$net_int" "${hardening[@]}" --user 10001:10001 --memory 4g
  --tmpfs "/tmp:rw,size=64m" "${proxy_env[@]}")

docker run -d --name "$proxy" --network "$net_ext" "${hardening[@]}" \
  --tmpfs /tmp:rw,size=16m "$proxy_image" /etc/tinyproxy/test.conf > /dev/null
docker network connect --alias proxy "$net_int" "$proxy"

# The network check of run-pass.sh, behind the test proxy, before the archive reaches a
# container: IPv6 off on both run networks, and egress-probe.sh check with the internal gateway,
# the docker0 address and the host's IPv6 addresses. Any failure ends the run as error network.
# shortcut: this copies run-pass.sh's address gathering; move both into one file when a third caller appears.
[ "$(docker network inspect -f '{{.EnableIPv6}}' "$net_int" "$net_ext" | tr '\n' ' ')" = "false false " ] ||
  finish "error network"
v4_re='^[0-9]{1,3}([.][0-9]{1,3}){3}$'
gw="$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' "$net_int")"
[[ "$gw" =~ $v4_re ]] || finish "error network"
probe_args=(--gateway "$gw")
d0="$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' bridge 2> /dev/null || true)"
[[ ! "$d0" =~ $v4_re ]] || probe_args+=(--host "$d0")
if command -v ip > /dev/null 2>&1; then
  br="br-$(docker network inspect -f '{{.Id}}' "$net_int" | cut -c1-12)"
  v6="$({ ip -6 -o addr show scope global 2> /dev/null | awk '{ split($4, a, "/"); print a[1] }'
    ip -6 -o addr show dev "$br" scope link 2> /dev/null | awk '{ split($4, a, "/"); print a[1] "%eth0" }'; } || true)"
  [ "$(printf '%s\n' "$v6" | grep -c .)" -le 16 ] || finish "error network"
  for a in $v6; do
    [[ "$a" =~ ^[0-9a-f:]+(%eth0)?$ ]] || finish "error network"
    probe_args+=(--host "$a")
  done
fi
nc="$record/network-check-test.txt"
docker run --rm --name "$runner" "${common[@]}" --entrypoint /usr/local/bin/egress-probe "$runner_image" \
  check "${probe_args[@]}" --allowed pypi.org --refused github.com --refused sts.us-east-1.amazonaws.com \
  2> /dev/null | head -c "$log_cap" > "$nc" || finish "error network"
[ "$(tail -n 1 "$nc")" = "end network check" ] || finish "error network"

# The tests: the archive on standard input, a fresh work volume, no credential. The container
# keeps its own budget; the host stops it a minute later whatever happens inside.
limit() { if command -v timeout > /dev/null; then timeout "$@"; else perl -e 'alarm shift; exec @ARGV' "$@"; fi; }
rc=0
limit $((budget + 60)) docker run -i --rm --name "$runner" "${common[@]}" -v "$volume":/work \
  --entrypoint /usr/local/bin/test-entry "$runner_image" "$kind" "$py" "$budget" < "$archive" 2> /dev/null |
  head -c "$out_cap" > "$TMPRUN/out" || rc=$?
docker rm -f "$runner" > /dev/null 2>&1 || true
line="$(grep -E '^tests: ' "$TMPRUN/out" | tail -n 1 | sed 's/^tests: //')"
if [[ "$line" =~ ^(passed|failed)\ [0-9]{1,6}$|^error\ [a-z-]{1,32}$ ]]; then finish "$line"; fi
case "$rc" in 0) finish "error output" ;; 124) finish "error timeout" ;; *) finish "error runner" ;; esac
