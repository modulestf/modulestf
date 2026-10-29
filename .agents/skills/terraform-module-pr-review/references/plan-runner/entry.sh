#!/bin/bash
# Entry point of the runner container: one phase of one example.
# Usage: plan-entry init|plan <example path relative to the clone root>
# The clone is mounted read-only at /src; /work is the only writable directory and is
# kept between the two phases, which run in two separate containers.
set -euo pipefail

phase="${1:?usage: plan-entry init|plan <example path>}"
example="${2:?usage: plan-entry init|plan <example path>}"
case "$example" in
  /* | *..* ) echo "refusing example path: $example" >&2; exit 2 ;;
esac

out=/work/out
mkdir -p "$out" /work/home /work/cache /work/tmp
export HOME=/work/home TMPDIR=/work/tmp
export TF_PLUGIN_CACHE_DIR=/work/cache TF_IN_AUTOMATION=1 TF_INPUT=0 CHECKPOINT_DISABLE=1

status() { printf '%s %s\n' "$1" "$2" >> "$out/status"; }

case "$phase" in
  init)
    # Terraform writes into the example directory, so it runs in a copy of the clone.
    cp -a /src /work/src
    cd "/work/src/$example"
    # init never sees credentials.
    set +e
    env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
      timeout 180 terraform init -backend=false -input=false -no-color > "$out/init.log" 2>&1
    rc=$?
    set -e
    status init "$rc"
    ;;
  plan)
    cd "/work/src/$example"
    set +e
    timeout 300 terraform plan -input=false -lock=false -refresh=true -no-color > "$out/plan.log" 2>&1
    rc=$?
    set -e
    status plan "$rc"
    ;;
  *) echo "unknown phase: $phase" >&2; exit 2 ;;
esac
exit 0
