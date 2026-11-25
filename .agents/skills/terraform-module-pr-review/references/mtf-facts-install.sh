#!/bin/bash
# Installs the mtf-facts release that mtf-facts-pin.json pins: downloads the asset for this
# machine's platform, checks its SHA-256 against the pin (the pin is the trust root, taken
# from the release's SHA256SUMS when the pin was raised), and moves it to <dir>/mtf-facts
# only after the check and a matching --version. Nothing is left behind on failure, and an
# existing <dir>/mtf-facts stays as it was.
# Usage: bash mtf-facts-install.sh <dir> [--pin FILE]
# Exits 0 when installed, 1 when the download, the hash or the version check fails, 2 on
# bad usage or a pin it refuses.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
PIN="$HERE/mtf-facts-pin.json"
DIR=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pin) PIN="${2-}"; shift 2 || { echo "mtf-facts-install: --pin needs a file" >&2; exit 2; } ;;
    -*) echo "mtf-facts-install: unknown option $1" >&2; exit 2 ;;
    *) [ -z "$DIR" ] || { echo "mtf-facts-install: one directory only" >&2; exit 2; }; DIR="$1"; shift ;;
  esac
done
[ -n "$DIR" ] || { echo "usage: mtf-facts-install.sh <dir> [--pin FILE]" >&2; exit 2; }
[ -d "$DIR" ] || { echo "mtf-facts-install: no directory $DIR" >&2; exit 2; }
command -v jq > /dev/null || { echo "mtf-facts-install: needs jq" >&2; exit 2; }

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) echo "mtf-facts-install: no release for $(uname -s)" >&2; exit 2 ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) echo "mtf-facts-install: no release for $(uname -m)" >&2; exit 2 ;;
esac
plat="${os}_$arch"

jq -e '.schema_version == 1' "$PIN" > /dev/null 2>&1 || { echo "mtf-facts-install: $PIN is not a pin file of schema 1" >&2; exit 2; }
version="$(jq -r '.version | strings' "$PIN")"
url="$(jq -r --arg p "$plat" '.platforms[$p].url | strings' "$PIN")"
want="$(jq -r --arg p "$plat" '.platforms[$p].sha256 | strings' "$PIN")"
printf '%s' "$version" | grep -Eqx 'v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?' ||
  { echo "mtf-facts-install: the pin's version '$version' is not a release tag" >&2; exit 2; }
printf '%s' "$want" | grep -Eqx '[0-9a-f]{64}' ||
  { echo "mtf-facts-install: the pin has no sha256 for $plat" >&2; exit 2; }
case "$url" in
  "https://github.com/modulestf/facts/releases/download/$version/mtf-facts_${version}_$plat") ;;
  *) echo "mtf-facts-install: the pin's URL for $plat is not the $version release asset: '$url'" >&2; exit 2 ;;
esac

tmp="$(mktemp -d "${TMPDIR:-/tmp}/mtf-facts-install.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --max-time 300 -o "$tmp/mtf-facts" "$url" ||
  { echo "mtf-facts-install: download of $url failed" >&2; exit 1; }
if command -v sha256sum > /dev/null; then got="$(sha256sum "$tmp/mtf-facts" | cut -d ' ' -f 1)"
else got="$(shasum -a 256 "$tmp/mtf-facts" | cut -d ' ' -f 1)"; fi
[ "$got" = "$want" ] ||
  { echo "mtf-facts-install: sha256 mismatch for $url: got $got, the pin says $want" >&2; exit 1; }
chmod 755 "$tmp/mtf-facts"
v="$("$tmp/mtf-facts" --version 2> /dev/null | head -n 1)" || v=""
[ "$v" = "$version" ] || { echo "mtf-facts-install: the binary reports '$v', the pin says $version" >&2; exit 1; }
mv -f "$tmp/mtf-facts" "$DIR/mtf-facts"
echo "mtf-facts $version ($plat) installed to $DIR/mtf-facts"
