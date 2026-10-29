#!/bin/bash
# Smoke test of the isolated plan runner. Needs a local Docker runtime and network access
# for the image builds; uses no AWS account and no real credentials.
#
# It plans smoke/example with made-up session credentials and probes the network after
# each phase. Success means:
# - init reaches the registry and download hosts, and not AWS;
# - plan reaches STS through the plan-phase proxy and STS rejects the made-up key
#   (InvalidClientTokenId), which proves the path to AWS without any real credential;
# - during plan the registry, GitHub, EC2 public DNS names and S3 bucket hosts are refused;
# - a direct connection that bypasses the proxy fails, and outside names do not resolve;
# - plain HTTP through the proxy is refused;
# - credentials without a session token are refused before anything starts;
# - an oversized file in the output directory is refused;
# - with --base, only the example whose plan is a code-error is re-run at the merge base;
# - run-pass.sh's network check, behind each proxy, finds every path closed and both positive
#   controls held, and stops the run before any session when IPv6 is on, a path is open or a
#   control fails;
# - no credential value is in the configuration of a plan container (docker inspect);
# - the image tag is derived from the image files unless PLAN_RUNNER_TAG sets it;
# - no container, network or volume of these runs is left behind.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
rec="$(mktemp -d "${TMPDIR:-/tmp}/plan-runner-smoke.XXXXXX")"
creds="$rec/fake-credentials.env"
printf '%s\n' AWS_ACCESS_KEY_ID=smoke-test-not-a-key AWS_SECRET_ACCESS_KEY=smoke-test-not-a-secret \
  AWS_SESSION_TOKEN=smoke-test-not-a-token > "$creds"
static="$rec/static-credentials.env"
printf '%s\n' AWS_ACCESS_KEY_ID=smoke-test-not-a-key AWS_SECRET_ACCESS_KEY=smoke-test-not-a-secret > "$static"

"$here/run-plan.sh" --build --probe --clone "$here/smoke" --example example \
  --record "$rec/record" --credentials-env-file "$creds" > /dev/null
"$here/run-plan.sh" --clone "$here/smoke" --example example \
  --record "$rec/static" --credentials-env-file "$static" > "$rec/static.out" 2>&1
static_rc=$?
"$here/run-plan.sh" --clone "$here/smoke" --example attack --record "$rec/attack" \
  > "$rec/attack.out" 2>&1
attack_rc=$?

fails=0
check() { # description, command...
  local d="$1"; shift
  if "$@" > /dev/null 2>&1; then echo "ok   $d"; else echo "FAIL $d"; fails=$((fails + 1)); fi
}
r="$rec/record"
check "init succeeded" grep -qx 'init 0' "$r/status"
check "init downloaded the provider through the proxy" grep -q 'CONNECT releases.hashicorp.com:443' "$r/proxy-init.log"
check "init phase refuses AWS" grep -qx 'proxy sts.us-east-1.amazonaws.com: refused' "$r/probe-init.log"
check "init phase passes GitHub" grep -q '^proxy github.com: passed' "$r/probe-init.log"
check "plan reached STS through the plan proxy" grep -q 'CONNECT sts\.[a-z0-9-]*\.amazonaws\.com:443' "$r/proxy-plan.log"
check "STS rejected the made-up key" grep -q 'InvalidClientTokenId' "$r/plan.log"
check "plan phase refuses the registry" grep -qx 'proxy registry.terraform.io: refused' "$r/probe-plan.log"
check "plan phase refuses GitHub" grep -qx 'proxy github.com: refused' "$r/probe-plan.log"
check "plan phase refuses an EC2 public DNS name" grep -qx 'proxy ec2-192-0-2-1.compute-1.amazonaws.com: refused' "$r/probe-plan.log"
check "plan phase refuses an S3 bucket host" grep -qx 'proxy probe-bucket.s3.amazonaws.com: refused' "$r/probe-plan.log"
check "plan phase refuses a regional S3 bucket host" grep -qx 'proxy probe-bucket.s3.us-east-1.amazonaws.com: refused' "$r/probe-plan.log"
check "plan phase refuses a host outside AWS" grep -qx 'proxy example.com: refused' "$r/probe-plan.log"
check "refused plan hosts are listed" grep -qx 'github.com:443' "$r/plan-refused-hosts.txt"
check "plan phase refuses a CONNECT to port 8443" grep -qx 'proxy sts.us-east-1.amazonaws.com:8443: refused' "$r/probe-plan.log"
check "the port 8443 attempt is listed" grep -qx 'sts.us-east-1.amazonaws.com:8443' "$r/plan-refused-hosts.txt"
for phase in init plan; do
  check "$phase: direct connection to an address fails" grep -qx 'direct 1.1.1.1:443: closed' "$r/probe-$phase.log"
  check "$phase: direct connection to an allowed host fails" grep -qx 'direct registry.terraform.io:443: closed' "$r/probe-$phase.log"
  check "$phase: outside names do not resolve" grep -qx 'dns example.com: does not resolve' "$r/probe-$phase.log"
  check "$phase: plain HTTP through the proxy is refused" grep -qx 'proxy plain-http registry.terraform.io: exit 0 http 403' "$r/probe-$phase.log"
done
check "credentials without a session token are refused" test "$static_rc" -eq 2
check "the refusal says why" grep -q 'no session token' "$rec/static.out"
a="$rec/attack"
check "attack: the run completed" test "$attack_rc" -eq 0
check "attack: the planted status link was refused" grep -qx 'not a regular file in the work volume, not exported: out/status' "$a/export-refused.txt"
check "attack: the planted plan.log link was refused" grep -qx 'not a regular file in the work volume, not exported: out/plan.log' "$a/export-refused.txt"
check "attack: the record holds no link" test -z "$(find "$a" "$r" -type l -print -quit)"
check "attack: the record holds no password-file content" test -z "$(grep -rl -e 'root:' -e 'User Database' "$a" 2>/dev/null)"
check "attack: the unlisted planted name was not exported" test ! -e "$a/extra"
check "attack: an oversized file was refused" grep -qx 'larger than 5242880 bytes, not exported: out/probe-init.log' "$a/export-refused.txt"
check "attack: the oversized file is not in the record" test ! -e "$a/probe-init.log"
# The plan pass in the runner, on a git fixture holding both smoke examples and one whose init
# fails the same way at the head and at the merge base: a code-error that needs no credentials.
# The fixture is its own origin, so the base fetch stays inside the work volume. The made-up
# credentials fail the pass's sts check, so the pass ends at credentials after init. Ten more
# copies of the failing example make thirteen, past the laptop's cap of twelve, which the
# runner does not have.
repo="$rec/pass-repo"
mkdir -p "$repo/examples/broken"
printf 'terraform {\n  required_version = "= 0.0.1"\n}\n' > "$repo/examples/broken/main.tf"
git -C "$repo" init -q
git -C "$repo" remote add origin .
git -C "$repo" add -A
git -C "$repo" -c user.name=smoke -c user.email=smoke@example.com commit -q -m base
basesha="$(git -C "$repo" rev-parse HEAD)"
cp -R "$here/smoke/example" "$repo/examples/sts"
cp -R "$here/smoke/attack" "$repo/examples/attack"
git -C "$repo" add -A
git -C "$repo" -c user.name=smoke -c user.email=smoke@example.com commit -q -m head
mkdir -m 0700 "$rec/pass-tmp"
# A docker wrapper for these runs only: before run-pass.sh removes a runner container, it saves
# that container's docker inspect output, so the check below sees every plan container. With
# $rec/shim-mode it also fakes a fault for the network check: "ipv6" answers that IPv6 is on
# for the run networks, "open-path" points the probe's gateway at the proxy, which listens,
# and "plan-control" gives the plan-phase probe a positive control its proxy refuses.
mkdir "$rec/shim"
cat > "$rec/shim/docker" <<'SHIM'
#!/bin/bash
mode="$(cat "$SMOKE_REC/shim-mode" 2> /dev/null)"
if [ "$1 $2" = "rm -f" ]; then
  case "$3" in plan-runner-*) "$SMOKE_DOCKER" container inspect "$3" >> "$SMOKE_REC/inspect.json" 2> /dev/null || true ;; esac
fi
if [ "$mode" = ipv6 ] && [ "$1 $2 $3 $4" = "network inspect -f {{.EnableIPv6}}" ]; then
  echo true; echo true; exit 0
fi
if [ "$mode" = open-path ] && [ "$1" = run ]; then
  args=() prev=""
  for a in "$@"; do
    if [ "$prev" = --gateway ]; then args+=(proxy); else args+=("$a"); fi
    prev="$a"
  done
  exec "$SMOKE_DOCKER" "${args[@]}"
fi
if [ "$mode" = plan-control ] && [ "$1" = run ]; then
  args=() prev=""
  for a in "$@"; do
    if [ "$prev" = --allowed ] && [ "$a" = sts.us-east-1.amazonaws.com ]; then args+=(example.com); else args+=("$a"); fi
    prev="$a"
  done
  exec "$SMOKE_DOCKER" "${args[@]}"
fi
exec "$SMOKE_DOCKER" "$@"
SHIM
chmod +x "$rec/shim/docker"
export SMOKE_REC="$rec" SMOKE_DOCKER="$(command -v docker)"
PATH="$rec/shim:$PATH" "$here/run-pass.sh" --clone "$repo" --record "$rec/pass" --tmp "$rec/pass-tmp" --credentials-env-file "$creds" \
  --base "$basesha" examples/broken examples/sts examples/attack examples/broken examples/broken \
  examples/broken examples/broken examples/broken examples/broken examples/broken examples/broken \
  examples/broken examples/broken > /dev/null 2> "$rec/pass.err"
p="$rec/pass"
for ph in init plan; do
  nc="$p/network-check-$ph.txt"
  check "pass: $ph: the network check found every path closed and both controls held" \
    test "$(tail -n 1 "$nc")" = "end network check" -a "$(grep -vcE '^(closed|ok) ' "$nc")" -eq 1 -a "$(grep -c '^ok control ' "$nc")" -eq 2
  check "pass: $ph: the proxy was reached directly" grep -qx 'ok control direct proxy:8888' "$nc"
  check "pass: $ph: the probe saw one network interface" grep -qx 'closed interfaces: one up' "$nc"
  check "pass: $ph: the probe saw no IPv4 default route" grep -qx 'closed route ipv4: no default' "$nc"
  check "pass: $ph: an IP-literal CONNECT through the proxy is refused" grep -qx 'closed proxy CONNECT 1.1.1.1:443' "$nc"
  check "pass: $ph: external names do not resolve" grep -qx 'closed dns example.com' "$nc"
  check "pass: $ph: the gateway, docker0 and the IPv4 metadata address are closed on six ports each" \
    test "$(grep -cE '^closed direct [0-9.]+:(22|80|443|2375|2376|8888)$' "$nc")" -ge 19
  check "pass: $ph: the IPv6 metadata address is closed" grep -qx 'closed direct fd00:ec2::254:80' "$nc"
done
check "pass: init: the init proxy passes the registry" grep -qx 'ok control proxy CONNECT registry.terraform.io:443' "$p/network-check-init.txt"
check "pass: init: the init proxy refuses AWS" grep -qx 'closed proxy CONNECT sts.us-east-1.amazonaws.com:443' "$p/network-check-init.txt"
check "pass: plan: the plan proxy passes an AWS endpoint" grep -qx 'ok control proxy CONNECT sts.us-east-1.amazonaws.com:443' "$p/network-check-plan.txt"
check "pass: plan: the plan proxy refuses the registry" grep -qx 'closed proxy CONNECT registry.terraform.io:443' "$p/network-check-plan.txt"
check "pass: init phase readied both examples" grep -qx 'init: examples/attack: ready' "$p/plan-pass-init.txt"
check "pass: plan phase checked the credentials through the plan proxy" grep -q 'CONNECT sts\.[a-z0-9-]*\.amazonaws\.com:443' "$p/proxy-plan.log"
check "pass: made-up credentials end the pass" grep -qx 'plan: plan pass ended: credentials' "$p/plan-pass.txt"
check "pass: the host heads each example's block" grep -qx 'host example 2: examples/sts' "$p/plan-pass.txt"
check "pass: the summary line is written" grep -qx 'plan summary: 13 examples, 0 planned, 0 exceptions, 13 other' "$p/plan-pass.txt"
check "pass: the budget is recorded" grep -qx 'plan pass budget: 120 minutes' "$p/plan-pass.txt"
check "pass: no example cap in the runner" test "$(grep -c '^init: examples/broken: code-error$' "$p/plan-pass-init.txt")" -eq 11
check "pass: only the code-error was prepared at the base" test "$(grep -c ' at base: ' "$p/plan-pass-init.txt")" -eq 1
check "pass: the code-error was initialised at the base" grep -qx 'init: examples/broken at base: code-error' "$p/plan-pass-init.txt"
check "pass: the deferred base line was filled in" grep -qx 'base: reproduces at base' "$p/plan-pass.txt"
check "pass: no deferred base line is left" test -z "$(grep -x 'base: deferred' "$p/plan-pass.txt")"
# The init-phase network check asks the init proxy for STS on purpose, to see it refused. So
# what must hold is that no AWS endpoint was reached: tinyproxy wrote no "Established
# connection" line for an amazonaws host, and every request for one has its own "Proxying
# refused on filtered url" line, the same targets the same number of times.
no_aws_reached() { # proxy log
  local log
  log="$(tr 'A-Z' 'a-z' < "$1")" || return 1
  ! printf '%s\n' "$log" | grep 'established connection to host "[^"]*amazonaws' > /dev/null || return 1
  [ "$(printf '%s\n' "$log" | sed -nE 's/.*request \(file descriptor [0-9]+\): [a-z]+ ([^ ]*amazonaws[^ ]*) http.*/\1/p' | sort)" = \
    "$(printf '%s\n' "$log" | sed -nE 's/.*proxying refused on filtered url "([^"]*amazonaws[^"]*)".*/\1/p' | sort)" ]
}
check "pass: init reached no AWS endpoint" no_aws_reached "$p/proxy-init.log"
check "pass: the init proxy refused the network check's STS request" grep -q 'Proxying refused on filtered url "sts.us-east-1.amazonaws.com:443"' "$p/proxy-init.log"
check "pass: no credential value in the record" test -z "$(grep -rl 'smoke-test-not-a-' "$p")"
check "pass: a plan container was inspected with the credentials file mounted" grep -q '/opt/plan-pass/creds.env' "$rec/inspect.json"
check "pass: no credential value in a plan container's configuration" test -z "$(grep 'smoke-test-not-a-' "$rec/inspect.json")"
# The plan container's credentials loader, the exact line from run-pass.sh, run in the
# runner image on values with a trailing '=' pad and an internal '='.
loader="$(sed -n "s/^load_creds='\(.*\)' # creds-loader$/\1/p" "$here/run-pass.sh")"
printf '%s\n' PLAN_PASS_AWS_ACCESS_KEY_ID=smoke-key PLAN_PASS_AWS_SECRET_ACCESS_KEY=smoke=sec=ret \
  PLAN_PASS_AWS_SESSION_TOKEN=smoke-token= OTHER=x > "$rec/loader.env"
chmod 0644 "$rec/loader.env"
loaded="$(docker run --rm --network none --read-only --cap-drop ALL --user 10001:10001 \
  -v "$rec/loader.env":/opt/plan-pass/creds.env:ro --entrypoint /bin/bash \
  "plan-runner:$("$here/image-tag.sh")" -c "$loader && env | grep -E '^(PLAN_PASS_|OTHER=)' | sort" 2>&1)"
check "loader: the line is found in run-pass.sh" test -n "$loader"
check "loader: a value keeps its trailing pad and internal '='" test "$loaded" = "$(printf '%s\n' \
  PLAN_PASS_AWS_ACCESS_KEY_ID=smoke-key PLAN_PASS_AWS_SECRET_ACCESS_KEY=smoke=sec=ret PLAN_PASS_AWS_SESSION_TOKEN=smoke-token=)"
check "pass: the record holds regular files only" test -z "$(find "$p" -mindepth 1 ! -type f -print -quit)"
check "pass: nothing is left under --tmp" test -z "$(find "$rec/pass-tmp" -mindepth 1 -print -quit)"
# The network check fails closed: IPv6 on for a run network, or an open path, stops the run
# before any head code runs and before the first session, with no plan recorded; a plan-phase
# control that fails stops it after init, before the first plan container.
for m in ipv6 open-path plan-control; do
  echo "$m" > "$rec/shim-mode"
  PATH="$rec/shim:$PATH" "$here/run-pass.sh" --clone "$repo" --record "$rec/net-$m" --tmp "$rec/pass-tmp" \
    --credentials-env-file "$creds" examples/sts > /dev/null 2> "$rec/net-$m.err"
  echo $? > "$rec/net-$m.rc"
done
rm -f "$rec/shim-mode"
check "network: IPv6 on stops the run" test "$(cat "$rec/net-ipv6.rc")" -eq 2
check "network: the IPv6 refusal says why" grep -qx 'run-pass: refusing to plan: IPv6 is on for a run network' "$rec/net-ipv6.err"
check "network: IPv6 on runs no probe and no plan" test ! -e "$rec/net-ipv6/network-check-init.txt" -a ! -e "$rec/net-ipv6/plan-pass.txt"
check "network: an open path stops the run" test "$(cat "$rec/net-open-path.rc")" -eq 2
check "network: the refusal says why" grep -qx 'run-pass: refusing to plan: the network check found an open path, or could not run' "$rec/net-open-path.err"
check "network: the probe names the open path" grep -qx 'open direct proxy:8888' "$rec/net-open-path/network-check-init.txt"
check "network: an open path runs no head code" test ! -e "$rec/net-open-path/plan-pass-init.txt"
check "network: an open path runs no plan container and records no plan" test ! -e "$rec/net-open-path/proxy-plan.log" -a ! -e "$rec/net-open-path/plan-pass.txt"
q="$rec/net-plan-control"
check "network: a failed plan-phase control stops the run" test "$(cat "$q.rc")" -eq 2
check "network: the plan-phase refusal says why" grep -qx 'run-pass: refusing to plan: the network check found an open path, or could not run' "$q.err"
check "network: the plan-phase probe names the failed control" grep -qx 'fail control proxy CONNECT example.com:443: refused' "$q/network-check-plan.txt"
check "network: the init phase ran before it" grep -qx 'init: examples/sts: ready' "$q/plan-pass-init.txt"
check "network: a failed plan-phase control records no plan" test ! -e "$q/plan-pass.txt"

# --tmp is where the private temporary directory goes: one that cannot be written to stops
# the run before any credential is read or any Docker object is made.
mkdir -m 0500 "$rec/ro-tmp"
"$here/run-pass.sh" --clone "$repo" --record "$rec/ro-pass" --tmp "$rec/ro-tmp" --credentials-env-file "$creds" \
  examples/sts > /dev/null 2>&1
ro_rc=$?
check "pass: an unwritable --tmp stops the run" test "$ro_rc" -ne 0
check "pass: an unwritable --tmp made no Docker object" test ! -e "$rec/ro-pass/run-id.txt"

# A profile with no review role stops the run before any credential is read or any Docker
# object is made: there is no plan pass on the profile's own credentials.
"$here/run-pass.sh" --clone "$repo" --record "$rec/norole" --tmp "$rec/pass-tmp" --profile smoke \
  examples/sts > "$rec/norole.out" 2>&1
norole_rc=$?
check "pass: a profile with no review role stops the run" test "$norole_rc" -eq 2
check "pass: the refusal names the review role" grep -q 'needs --role-arn' "$rec/norole.out"
check "pass: a profile with no review role made no Docker object" test ! -e "$rec/norole/run-id.txt"

# The host leak scan, on a crafted record: exact values and every evidence pattern go, an
# ordinary line stays.
s="$rec/scan"
mkdir -p "$s"
{
  echo 'plan: planned | Plan: 1 to add, 0 to change, 0 to destroy.'
  echo 'key AKIAABCDEFGHIJKLMNOP'
  echo 'jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0'
  echo '-----BEGIN PRIVATE KEY-----'
  echo 'url ?X-Amz-Signature=abc'
  echo 'Authorization: AWS4-HMAC-SHA256'
  echo 'encoded c21va2UtdGVzdC1ub3QtYS1zZWNyZXQtdmFsdWUtZW5jb2RlZA=='
  echo 'value smoke-test-exact-value'
  echo 'split smoke-test-exa'
  echo 'ct-value across two lines'
  echo 'id AKIAABCDEF'
  echo '  GHIJKLMNOP split too'
  echo 'scope: examples/sts'
} > "$s/plan-pass.txt"
echo 'smoke-test-exact-value' > "$rec/scan-values"
scanned="$("$here/record-scan.sh" "$s" "$rec/scan-values")"
check "scan: every crafted leak line is removed, split ones included" test "$scanned" -eq 11
check "scan: the line after a split secret stays" grep -qx 'scope: examples/sts' "$s/plan-pass.txt"
check "scan: the ordinary line stays" grep -qx 'plan: planned | Plan: 1 to add, 0 to change, 0 to destroy.' "$s/plan-pass.txt"
check "scan: no crafted secret is left" test -z "$(grep -E 'AKIA|GHIJKLMNOP|eyJ|BEGIN|Signature|Authorization|c21va2|exact-value|smoke-test-exa|ct-value' "$s/plan-pass.txt")"

# The image tag: derived from the image files unless PLAN_RUNNER_TAG is set, and refused
# when it is not a valid tag.
tag1="$(env -u PLAN_RUNNER_TAG "$here/image-tag.sh")"
tag2="$(env -u PLAN_RUNNER_TAG "$here/image-tag.sh")"
check "image tag: the default is src- and 12 hex digits" test -n "$(printf '%s\n' "$tag1" | grep -Ex 'src-[0-9a-f]{12}')"
check "image tag: the default is the same on every call" test "$tag1" = "$tag2"
check "image tag: PLAN_RUNNER_TAG overrides it" test "$(PLAN_RUNNER_TAG=smoke-x "$here/image-tag.sh")" = smoke-x
check "image tag: an invalid PLAN_RUNNER_TAG is refused" test "$(PLAN_RUNNER_TAG='a b' "$here/image-tag.sh" > /dev/null 2>&1; echo $?)" -eq 2

# Leftovers: each run names everything it creates with its own id, recorded in run-id.txt.
# Only those exact names are inspected here; nothing is removed, and no prefix is matched, so
# another run on the same Docker daemon is neither touched nor counted.
leftover() { # ids...: prints each of those runs' containers, networks and volumes still present
  local id n
  for id in "$@"; do
    for n in "plan-runner-$id" "plan-proxy-$id" "plan-proxy-init-$id" "plan-proxy-plan-$id" "plan-export-$id"; do
      docker container inspect "$n" > /dev/null 2>&1 && echo "container $n"
    done
    for n in "plan-int-$id" "plan-ext-$id"; do
      docker network inspect "$n" > /dev/null 2>&1 && echo "network $n"
    done
    docker volume inspect "plan-work-$id" > /dev/null 2>&1 && echo "volume plan-work-$id"
  done
  return 0
}
ids="$(cat "$r/run-id.txt" "$a/run-id.txt" "$rec/static/run-id.txt" "$p/run-id.txt" \
  "$rec/net-ipv6/run-id.txt" "$rec/net-open-path/run-id.txt" "$rec/net-plan-control/run-id.txt" 2>/dev/null)"
check "every run recorded its id" test "$(printf '%s\n' "$ids" | grep -c .)" -eq 7
# shellcheck disable=SC2086 # one id per word
check "no container, network or volume of these runs left behind" test -z "$(leftover $ids)"

echo "record: $r"
[ "$fails" -eq 0 ] && echo "smoke passed" || echo "smoke failed: $fails"
exit "$fails"
