#!/bin/bash
# Prints the image tag for the runner and proxy images: PLAN_RUNNER_TAG when set, otherwise
# src- and the first 12 hex digits of a SHA-256 over every file the two images are built
# from. Two checkouts with the same runner files share a tag; any change to those files
# gives a new one, so runs of different revisions on one Docker daemon never share an image.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
if [ -n "${PLAN_RUNNER_TAG:-}" ]; then
  tag="$PLAN_RUNNER_TAG"
else
  sum() { if command -v sha256sum > /dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }
  tag="src-$(
    for f in Dockerfile.runner Dockerfile.proxy entry.sh egress-probe.sh tinyproxy.conf \
      allowlist-init allowlist-plan; do
      printf '%s %s\n' "$f" "$(wc -c < "$here/$f" | tr -d ' ')"
      cat "$here/$f"
    done | sum | cut -c1-12
  )"
fi
[[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || { echo "invalid PLAN_RUNNER_TAG" >&2; exit 2; }
echo "$tag"
