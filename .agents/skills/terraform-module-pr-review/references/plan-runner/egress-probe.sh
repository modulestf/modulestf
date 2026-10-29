#!/bin/bash
# Egress probe, run inside the runner container on the internal network. Two modes:
#
#   egress-probe init|plan
#       For the smoke test, after a phase: records whether each path out is open or closed
#       in /work/out/probe-<phase>.log, and always exits 0.
#   egress-probe check --gateway <address> [--host <address>]... --allowed <host> [--refused <host>]...
#       For run-pass.sh, before its first session, once behind each proxy: fails closed.
#       Prints one line per check, "closed <check>" for a closed path, "ok <check>" for a
#       positive control that held, and anything else for a fault, then the line
#       "end network check". Exits 0 only when every line is closed or ok. The container cannot
#       know the host's addresses, so the caller passes them: the internal network's gateway,
#       and with --host the docker0 address and the host's IPv6 addresses. Two positive
#       controls must hold, or every closed line could be a tool that did not run: a TCP
#       connection to the proxy on 8888, and a CONNECT through the proxy to --allowed, a host
#       its allowlist names. An IP-literal CONNECT and a CONNECT to each --refused host must
#       be refused by the proxy itself: curl exit 56 with a 4xx or 5xx CONNECT answer. A tool
#       that is missing or exits 126 or 127 is a fault, never a closed path.
set -uo pipefail

mode="${1:?usage: egress-probe init|plan | egress-probe check --gateway <address> [--host <address>]... --allowed <host> [--refused <host>]...}"

tcp() { timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2> /dev/null; } # host, port: 0 when it connects

if [ "$mode" = check ]; then
  shift
  targets=() gw="" allowed="" refused=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --gateway) gw="${2:-}"; targets+=("$gw"); shift 2 ;;
      --host) targets+=("${2:-}"); shift 2 ;;
      --allowed) allowed="${2:-}"; shift 2 ;;
      --refused) refused+=("${2:-}"); shift 2 ;;
      *) echo "fail check: unknown argument"; echo "end network check"; exit 1 ;;
    esac
  done
  targets+=(169.254.169.254 fd00:ec2::254)
  # A path: "closed <what>" when the connection fails or times out, "open <what>" when it
  # connects, "fail <what>: exit <n>" for anything else, such as a missing tool.
  path() { # label, host, port
    tcp "$2" "$3"; local rc=$?
    case "$rc" in 0) echo "open $1" ;; 1 | 124) echo "closed $1" ;; *) echo "fail $1: exit $rc" ;; esac
  }
  # A CONNECT through the proxy: "passed" when the proxy answered 200, "refused" when the
  # proxy itself refused it (curl exit 56 with a 4xx or 5xx answer), "fault" otherwise.
  connect() { # url
    local out rc
    out="$(curl -s -o /dev/null --max-time 15 -w '%{http_connect}' -x "$HTTPS_PROXY" "$1" 2> /dev/null)"; rc=$?
    if [ "$out" = 200 ]; then echo passed
    elif [ "$rc" -eq 56 ] && [[ "$out" =~ ^[45][0-9][0-9]$ ]]; then echo refused
    else echo "fault (exit $rc, answer ${out:-none})"; fi
  }
  {
    for t in timeout bash getent curl awk sort cat grep; do
      command -v "$t" > /dev/null 2>&1 || echo "fail tool missing: $t"
    done
    [ -n "$gw" ] || echo "fail check: no gateway address"
    [ -n "$allowed" ] || echo "fail check: no allowed host"
    [ -n "${HTTPS_PROXY:-}" ] || echo "fail check: no proxy variable"
    # Positive controls: the proxy is reachable, and passes a host its allowlist names.
    tcp proxy 8888; rc=$?
    if [ "$rc" -eq 0 ]; then echo "ok control direct proxy:8888"; else echo "fail control direct proxy:8888: exit $rc"; fi
    c="$(connect "https://$allowed/")"
    if [ "$c" = passed ]; then echo "ok control proxy CONNECT $allowed:443"; else echo "fail control proxy CONNECT $allowed:443: $c"; fi
    # The container's only network is the internal one: one interface up besides lo, and no
    # default route in either family. A kernel may add tunnel devices to every namespace;
    # they are down. An interface whose flags cannot be read counts as up.
    n=0
    for d in /sys/class/net/*/; do
      i="${d%/}"; i="${i##*/}"
      [ "$i" != lo ] || continue
      f="$(cat "$d/flags" 2> /dev/null)" || f=1
      [[ "$f" =~ ^(0x[0-9a-fA-F]+|[0-9]+)$ ]] || f=1
      [ $((f & 1)) -eq 0 ] || n=$((n + 1))
    done
    if [ "$n" = 1 ]; then echo "closed interfaces: one up"; else echo "open interfaces: $n up"; fi
    if [ ! -r /proc/net/route ]; then echo "fail route ipv4: unreadable"
    else
      awk 'NR > 1 && $2 == "00000000" { f = 1 } END { exit !f }' /proc/net/route; rc=$?
      case "$rc" in 0) echo "open route ipv4: default" ;; 1) echo "closed route ipv4: no default" ;; *) echo "fail route ipv4: exit $rc" ;; esac
    fi
    if [ -r /proc/net/ipv6_route ]; then
      awk '$1 == "00000000000000000000000000000000" && $2 == "00" && $10 != "lo" { f = 1 } END { exit !f }' /proc/net/ipv6_route; rc=$?
      case "$rc" in 0) echo "open route ipv6: default" ;; 1) echo "closed route ipv6: no default" ;; *) echo "fail route ipv6: exit $rc" ;; esac
    else
      echo "closed route ipv6: no default"
    fi
    # External names must not resolve. getent exits 2 for a name it cannot find.
    timeout 5 getent hosts example.com > /dev/null 2>&1; rc=$?
    case "$rc" in 0) echo "open dns example.com" ;; 2 | 124) echo "closed dns example.com" ;; *) echo "fail dns example.com: exit $rc" ;; esac
    # An IP-literal CONNECT, and each host outside this proxy's allowlist, must be refused.
    for h in 1.1.1.1 "${refused[@]+"${refused[@]}"}"; do
      c="$(connect "https://$h/")"
      if [ "$c" = refused ]; then echo "closed proxy CONNECT $h:443"; else echo "open proxy CONNECT $h:443: $c"; fi
    done
    # Direct TCP, bypassing the proxy: outside, and to every host address, on common ports.
    # In parallel, since a dropped packet costs the whole timeout.
    for t in 1.1.1.1:443 registry.terraform.io:443; do
      path "direct $t" "${t%:*}" "${t##*:}" &
    done
    for h in "${targets[@]}"; do
      for p in 22 80 443 2375 2376 8888; do
        path "direct $h:$p" "$h" "$p" &
      done
    done
    wait
  } | sort > /tmp/probe-check.txt
  echo "end network check" >> /tmp/probe-check.txt
  cat /tmp/probe-check.txt
  # Fail closed: both controls held, and every line but the last is a closed path or a control.
  [ "$(grep -c '^ok control ' /tmp/probe-check.txt)" = 2 ] && [ "$(grep -vcE '^(closed|ok) ' /tmp/probe-check.txt)" = 1 ]
  exit $?
fi

phase="$mode"
out=/work/out/probe-$phase.log
mkdir -p /work/out
: > "$out"
line() { printf '%s\n' "$*" >> "$out"; }

# A direct TCP connection, bypassing the proxy, to an address and to an allowed host.
for target in 1.1.1.1:443 registry.terraform.io:443; do
  if tcp "${target%:*}" "${target##*:}"; then
    line "direct $target: OPEN"
  else
    line "direct $target: closed"
  fi
done

# Name resolution of an outside host, which would be a DNS side channel.
if timeout 5 getent hosts example.com > /dev/null 2>&1; then
  line "dns example.com: resolves"
else
  line "dns example.com: does not resolve"
fi

# A plain HTTP request through the proxy, to an allowed host.
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -x "$HTTP_PROXY" http://registry.terraform.io/ 2>/dev/null)
line "proxy plain-http registry.terraform.io: exit $? http ${code:-none}"

# CONNECT through the proxy, one line per host.
for host in example.com registry.terraform.io github.com sts.us-east-1.amazonaws.com \
            ec2-192-0-2-1.compute-1.amazonaws.com probe-bucket.s3.amazonaws.com \
            probe-bucket.s3.us-east-1.amazonaws.com; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -x "$HTTPS_PROXY" "https://$host/" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 56 ] || [ "$rc" -eq 5 ]; then
    line "proxy $host: refused"
  else
    line "proxy $host: passed (exit $rc http ${code:-none})"
  fi
done

# CONNECT to an allowed host on a port other than 443.
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -x "$HTTPS_PROXY" https://sts.us-east-1.amazonaws.com:8443/ 2>/dev/null)
rc=$?
if [ "$rc" -eq 56 ] || [ "$rc" -eq 5 ]; then
  line "proxy sts.us-east-1.amazonaws.com:8443: refused"
else
  line "proxy sts.us-east-1.amazonaws.com:8443: passed (exit $rc http ${code:-none})"
fi
exit 0
