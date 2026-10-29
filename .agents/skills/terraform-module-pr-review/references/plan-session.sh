#!/usr/bin/env bash
# The plan pass's credentials: one session on the review role, issued with the named profile,
# for 900 seconds, downscoped by the pinned session policy in plan-session-policy.json. The
# session's permissions are the intersection of the role's policy and that policy. Rules and
# reasons: plan-pass.md, Credentials. Called by plan-pass.sh in laptop mode and by
# plan-runner/run-pass.sh on the host, once per example.
#
#   bash /abs/path/plan-session.sh <profile> <role-arn> <session-name>
#
# Prints one JSON object with AccessKeyId, SecretAccessKey and SessionToken on standard
# output. Any failure exits 1 with nothing on standard output and one fixed reason on
# standard error, for the operator, never for a record: there is no fallback to the
# profile's own credentials.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd -P)"
profile=${1:-} arn=${2:-} name=${3:-}
stop() { echo "plan-session: $1" >&2; exit 1; }
[[ "$profile" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]{0,63}$ ]] || stop "bad input: profile name"
[[ "$arn" =~ ^arn:aws(-[a-z]+)*:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$ ]] && [ "${#arn}" -le 2048 ] ||
  stop "bad input: review role ARN"
[[ "$name" =~ ^[A-Za-z0-9+=,.@_-]{2,64}$ ]] || stop "bad input: session name"
policy="$(jq -c . "$here/plan-session-policy.json" 2> /dev/null)" && [ "${#policy}" -le 2048 ] ||
  stop "bad input: session policy unreadable or over 2048 characters"
out="$(perl -e 'alarm 30; exec @ARGV' aws sts assume-role --profile="$profile" --role-arn "$arn" \
  --role-session-name "$name" --duration-seconds 900 --policy "$policy" \
  --output json --no-cli-pager < /dev/null 2> /dev/null)" || stop "assume-role failed or timed out"
jq -ce '.Credentials | {AccessKeyId, SecretAccessKey, SessionToken}
  | select(all(.[]; type == "string" and test("^[^[:space:]]+$")))' <<< "$out" 2> /dev/null ||
  stop "bad output: no session credentials in the assume-role answer"
