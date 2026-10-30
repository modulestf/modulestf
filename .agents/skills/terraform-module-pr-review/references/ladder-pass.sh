#!/usr/bin/env bash
# shellcheck disable=SC2016 # the perl and jq programs below are single-quoted on purpose
# The verification ladder's L1 pass of terraform-module-pr-review, as one file. Rules and
# reasons: ladder-pass.md. Run it with bash by an absolute path in the skill as installed,
# never from the head, the workspace or a copy the head could have written:
#
#   bash /abs/path/ladder-pass.sh probe <run-dir>
#       Proves the network-denied sandbox on this host and prints its canary lines, then
#       "sandbox proven <kind>" and exit 0, or "sandbox unproven: <reason>" and exit 1.
#   bash /abs/path/ladder-pass.sh acquire <run-dir> --pins <pins.json> --cache <dir> \
#       --schema-out <schema.json>
#       Acquisition: fetches each pinned provider zip from its pinned host, checks its
#       sha256, builds the run's read-only mirror, then runs terraform init and
#       providers schema -json in the sandbox with the network denied. Exit 0 with the
#       schema written, 1 with "acquisition failed: <reason>", 2 a usage error.
#   bash /abs/path/ladder-pass.sh run <run-dir> --behaviour <behaviour.json> --base <sha> \
#       --head <sha> --out <ladder.json> [--coverage <coverage.json>]
#       L1: one fixture pair per trigger that asks for L1, checked by mtf-facts
#       fixture-check, planned and shown in the sandbox, projected into the ladder record.
#       Writes the record and exits 0; exit 2 is a usage error or a refused input.
#
# <run-dir> is the absolute run directory "<root>/pr-review.XXXXXX". Everything this script
# writes lives in <run-dir>/ladder (mode 0700), outside the clone. Every command takes
# --owner-pid <pid>: the long-lived process that owns the review, named in the run's lease.

CMD=${1:-}
RUN=${2:-}
die() { echo "ladder-pass.sh: $1" >&2; exit 2; }
case "$CMD" in probe|acquire|run|_fetch) ;; *) die "usage: ladder-pass.sh probe|acquire|run <run-dir> ..." ;; esac
case "$RUN" in /?*) ;; *) die "the run directory must be absolute" ;; esac
[ -d "$RUN" ] && [ ! -L "$RUN" ] || die "no run directory: $RUN"
RUN="$(cd "$RUN" && pwd -P)"
ROOT="${RUN%/*}"
case "$RUN" in "$ROOT"/pr-review.??????) ;; *) die "not a run directory: $RUN" ;; esac
shift 2
HERE="$(cd "$(dirname "$0")" && pwd -P)"
SELF="$HERE/${0##*/}"
TPL="$HERE/ladder-templates"

PINS=; CACHE=; SCHEMA_OUT=; BEH=; BASESHA=; HEADSHA=; OUT=; COVER=; OWNER=0
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || die "$1 needs a value"
  case "$1" in
    --pins) PINS=$2 ;; --cache) CACHE=$2 ;; --schema-out) SCHEMA_OUT=$2 ;;
    --behaviour) BEH=$2 ;; --base) BASESHA=$2 ;; --head) HEADSHA=$2 ;;
    --out) OUT=$2 ;; --coverage) COVER=$2 ;; --owner-pid) OWNER=$2 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift 2
done
case "$OWNER" in ''|*[!0-9]*) die "--owner-pid must be a process id" ;; esac

PATH_RE='^/[A-Za-z0-9/._-]+$'        # every path written into a sandbox profile
L1_BUDGET=600                        # seconds for the whole L1 pass of one review
MAX_TRIGGERS=40
MIB=1048576
SCRATCH_CAP_KB=262144                # the scratch tree may not grow past 256 MiB
MEM_CAP_KB=2097152                   # 2 GiB resident for one command's process tree
L="$RUN/ladder"
S="$L/scratch"
pathok() { printf '%s\n' "$1" | grep -Eqx -- "$PATH_RE" && case "$1" in *..*) false ;; esac; }
realp() { perl -MCwd=realpath -e 'my $r = realpath(shift); print $r if defined $r' "$1"; }
owner_start() { # pid: its start time as one word, empty when it is not running
  ps -o lstart= -p "$1" 2> /dev/null | tr -s ' \t' '__' | sed 's/^_//; s/_$//'
}
sha256() { perl -MDigest::SHA -e 'print Digest::SHA->new(256)->addfile(shift)->hexdigest' "$1"; }
firstline() { # file: the decisive error line, plain and bounded
  perl -ne 's/\e\[[0-9;]*m//g; if (/\A\s*Error:/ || eof) { s/\A\s+|\s+\z//g; s/[^\x20-\x7e]/?/g; print substr($_, 0, 300); exit }' "$1" 2> /dev/null
}

# One command under the host's control: fds 3 and up closed, its own process group held
# by an anchor process (so the group id cannot be reused while it is killed), a file size
# limit, a wall timeout, caps on stdout and stderr, and a cap on the resident size of its
# process tree. Exit: the command's status, 124 timeout, 125 output cap, 126 memory cap,
# 128 + n for signal n, 70 the runner itself failed.
RUN_PL='
use strict; use warnings; no warnings "exec"; use POSIX qw(:sys_wait_h setpgid);
my ($dir, $t, $cap, $mem, $out, $blocks, @cmd) = @ARGV;
my $anchor = fork // exit 70;
if (!$anchor) { setpgid(0, 0); sleep 1 while 1; POSIX::_exit(0) }
setpgid($anchor, $anchor);
my $pid = fork // do { kill "KILL", -$anchor; exit 70 };
if (!$pid) {
  setpgid(0, $anchor) or POSIX::_exit(70);
  chdir $dir or POSIX::_exit(70);
  open STDIN, "<", "/dev/null" or POSIX::_exit(70);
  open STDOUT, ">", $out or POSIX::_exit(70);
  open STDERR, ">", "$out.err" or POSIX::_exit(70);
  my $fdd = -d "/proc/self/fd" ? "/proc/self/fd" : "/dev/fd";
  opendir my $d, $fdd or POSIX::_exit(70);
  my @fds = grep { /\A[0-9]+\z/ && $_ > 2 } readdir $d;
  closedir $d;
  POSIX::close($_) for @fds;
  # bash, not sh: outside POSIX mode its ulimit -f counts 1024-byte blocks on every platform
  # (POSIX mode counts 512, which only makes the limit stricter).
  exec "/bin/bash", "-c", q{ulimit -f "$1" || exit 70; shift; exec "$@"}, "bash", $blocks, @cmd;
  POSIX::_exit(70);
}
sub tree_kb { # resident KiB of the process tree under $pid
  my (%kids, %rss);
  open my $ps, "-|", "ps", "-A", "-o", "pid=,ppid=,rss=" or return 0;
  while (<$ps>) { my ($p, $pp, $r) = split; next unless defined $r; push @{$kids{$pp}}, $p; $rss{$p} = $r }
  close $ps;
  my ($sum, @q) = (0, $pid);
  while (defined(my $p = shift @q)) { $sum += $rss{$p} // 0; push @q, @{$kids{$p} // []} }
  return $sum;
}
my ($end, $rc, $n) = (time + $t, undef, 0);
while (1) {
  my $w = waitpid($pid, WNOHANG);
  if ($w == $pid) { $rc = $? & 127 ? 128 + ($? & 127) : $? >> 8; last }
  if (time > $end) { $rc = 124; last }
  if ((-s $out // 0) > $cap || (-s "$out.err" // 0) > $cap) { $rc = 125; last }
  if (++$n % 5 == 0 && tree_kb() > $mem) { $rc = 126; last }
  select undef, undef, undef, 0.1;
}
if ($rc >= 124 && $rc <= 126) { kill "TERM", -$anchor; select undef, undef, undef, 0.5; }
kill "KILL", -$anchor;
waitpid($pid, 0) if $rc >= 124 && $rc <= 126;
waitpid($anchor, 0);
for my $f ($out, "$out.err") { truncate $f, $cap if (-s $f // 0) > $cap }
exit $rc;
'
run_cmd() { # dir timeout cap out cmd...: the command under the runner
  local dir=$1 t=$2 cap=$3 out=$4; shift 4
  perl -e "$RUN_PL" "$dir" "$t" "$cap" "${MEM_KB:-$MEM_CAP_KB}" "$out" $(( ${FSZ:-$((64 * MIB))} / 1024 )) "$@"
}

# The canary, run inside the sandbox under test, in the same profile and environment the
# commands get. One line per check: "denied <class> <target> <errno>" when the sandbox
# stopped it, "ok <check>", anything else a leak or a fault; the last line is "end canary".
CANARY_PL='# LADDER-CANARY
use strict; use warnings; no warnings "exec"; use Errno (); use POSIX ();
use Socket qw(AF_INET AF_INET6 AF_UNIX SOCK_STREAM SOCK_DGRAM inet_pton pack_sockaddr_in pack_sockaddr_in6 pack_sockaddr_un);
my ($os, $okf, $denyf, $home, $hostns, @ns) = @ARGV;
my @net_ok = $os eq "darwin" ? qw(EPERM) : qw(ENETUNREACH EPERM EACCES);
my @fs_ok = $os eq "darwin" ? qw(EPERM EACCES) : qw(EPERM EACCES ENOENT EROFS);
sub en { my $e = 0 + shift; for my $k (qw(EPERM EACCES ENETUNREACH ECONNREFUSED ENOENT EROFS EHOSTUNREACH)) { my $c = eval "Errno::$k()"; return $k if defined $c && $c == $e } "errno$e" }
sub line { print join(" ", @_), "\n" }
sub judge { my ($class, $what, $e, $ok) = @_; line((grep { $_ eq $e } @$ok) ? "denied" : "open", $class, $what, $e) }
sub net { my ($class, $fam, $addr, $port, $proto, $loop) = @_;
  my $what = "$proto:$addr:$port";
  my $packed = inet_pton($fam, $addr) or return line("fail", $class, $what, "address");
  my $sa = $fam == AF_INET ? pack_sockaddr_in($port, $packed) : pack_sockaddr_in6($port, $packed);
  my @ok = (@net_ok, ($loop && $os ne "darwin") ? "ECONNREFUSED" : ());
  my $s; socket($s, $fam, $proto eq "udp" ? SOCK_DGRAM : SOCK_STREAM, 0) or return judge($class, $what, en($!), \@ok);
  my $r = eval { local $SIG{ALRM} = sub { die "timeout\n" }; alarm 3;
    my $c = $proto eq "udp" ? defined(send($s, "x", 0, $sa)) : connect($s, $sa); my $e = $c ? "" : en($!); alarm 0; [$c, $e] };
  return line("open", $class, $what, "timeout") unless $r;
  return line("open", $class, $what, $proto eq "udp" ? "sent" : "connected") if $r->[0];
  judge($class, $what, $r->[1], \@ok);
}
sub fs { my ($class, $what, $code) = @_; return line("open", $class, $what, "succeeded") if $code->(); judge($class, $what, en($!), \@fs_ok) }
net("ipv4", AF_INET, "1.1.1.1", 443, "tcp");
net("ipv6", AF_INET6, "2606:4700:4700::1111", 443, "tcp");
net("link-local", AF_INET, "169.254.169.254", 80, "tcp");
net("loopback", AF_INET, "127.0.0.1", 9, "tcp", 1);
net("loopback", AF_INET6, "::1", 9, "tcp", 1);
for my $a ("1.1.1.1", @ns) {
  my $fam = $a =~ /:/ ? AF_INET6 : AF_INET;
  my $lo = $a =~ /\A(127\.|::1\z)/ ? 1 : 0;
  net("dns", $fam, $a, 53, "tcp", $lo);
  net("dns", $fam, $a, 53, "udp", 0) unless $lo;
}
if ($os eq "darwin") {
  my $s; socket($s, AF_UNIX, SOCK_STREAM, 0) or line("fail", "dns", "mdnsresponder", "socket");
  if ($s) { if (connect($s, pack_sockaddr_un("/var/run/mDNSResponder"))) { line("open", "dns", "mdnsresponder", "connected") } else { judge("dns", "mdnsresponder", en($!), \@net_ok) } }
}
if (open my $f, "<", $okf) { my $c = <$f> // ""; line($c eq "ok\n" ? "ok" : "fail", "scratch-read") } else { line("fail", "scratch-read", en($!)) }
fs("read", "run-sentinel", sub { open my $x, "<", $denyf });
fs("read", "home", sub { -d $home ? opendir(my $x, $home) : open(my $x, "<", $home) });
fs("write", "run-dir", sub { open my $x, ">", "$denyf.w" });
my $pid = fork;
if (defined $pid && $pid == 0) { exec { $denyf } $denyf; my $e = 0 + $!; POSIX::_exit($e > 0 && $e < 256 ? $e : 255) }
if (!defined $pid) { line("fail", "exec", "fork") }
else { waitpid($pid, 0); my $c = $? >> 8; if ($? == 0) { line("open", "exec", "run-sentinel", "ran") } else { judge("exec", "run-sentinel", en($c), \@fs_ok) } }
if ($os eq "linux") {
  my $me = readlink("/proc/self/ns/net") // "";
  line(($me ne "" && $me ne $hostns) ? "ok" : "fail", "netns", $me);
  my @if; if (open my $d, "<", "/proc/net/dev") { @if = map { /\A\s*([^:\s]+):/ ? $1 : () } <$d> }
  line(join(",", @if) eq "lo" ? "ok" : "fail", "interfaces", join(",", @if) || "none");
}
line("end", "canary");
'
# Accepts a canary output: the end line, nothing but denied/ok lines, every class denied
# at least once, the scratch read, and on Linux the namespace and interface checks.
canary_ok() { # file, os
  awk -v os="$2" '
    { last = $0 }
    $1 == "end" && $2 == "canary" { next }
    $1 == "denied" { d[$2] = 1; next }
    $1 == "ok" { k[$2] = 1; next }
    { bad = bad ? bad : $0 }
    END {
      if (bad != "") { print "leak or fault: " bad; exit 1 }
      if (last != "end canary") { print "canary did not finish"; exit 1 }
      n = split("ipv4 ipv6 link-local loopback dns read write exec", c, " ")
      for (i = 1; i <= n; i++) if (!(c[i] in d)) { print "no denied " c[i] " check"; exit 1 }
      if (!("scratch-read" in k)) { print "scratch not readable"; exit 1 }
      if (os == "linux" && !("netns" in k && "interfaces" in k)) { print "no network namespace"; exit 1 }
    }' "$1"
}

# --- run directory, lease and sweep -----------------------------------------------------
setup() {
  pathok "$L" || die "the run directory path has characters a sandbox profile cannot hold"
  if [ -e "$L" ] || [ -L "$L" ]; then
    [ -d "$L" ] && [ ! -L "$L" ] && [ -O "$L" ] || die "$L is not this user's directory"
  else
    mkdir -m 700 "$L" || die "cannot create $L"
  fi
  chmod 700 "$L"
  local now ostart=- pid start exp; now="$(date +%s)"
  if [ "$OWNER" != 0 ]; then
    ostart="$(owner_start "$OWNER")"
    [ -n "$ostart" ] || die "--owner-pid names no running process"
  fi
  # The sweep: a sibling run goes only when its owner is gone (the pid is not running, or
  # runs with another start time), or, for a lease with no owner, when its day has passed.
  for d in "$ROOT"/pr-review.??????/ladder; do
    [ "$d" != "$L" ] && [ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] && [ -f "$d/lease" ] || continue
    read -r pid start exp _ < "$d/lease" 2> /dev/null || continue
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    case "$exp" in ''|*[!0-9]*) continue ;; esac
    if [ "$pid" = 0 ]; then [ "$now" -gt "$exp" ] || continue
    else [ "$(owner_start "$pid")" != "$start" ] || continue; fi
    chmod -R u+w "$d" 2> /dev/null; rm -rf -- "$d"
  done
  # Renewed on every call: the owning review process, its start time, a day ahead.
  printf '%s %s %s %s\n' "$OWNER" "$ostart" "$((now + 86400))" "$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')" > "$L/lease"
  if [ -e "$S" ]; then chmod -R u+w "$S" 2> /dev/null; rm -rf -- "$S"; fi
  mkdir -m 700 -p "$S/home" "$S/tmp" "$S/plans" "$L/etc" "$L/out" "$L/plans" "$L/mirror" "$L/fixtures" || die "cannot create $L"
  chmod 700 "$S" "$L/plans"
  trap 'chmod -R u+w "$S" 2> /dev/null; rm -rf -- "$S"' EXIT
  printf 'ok\n' > "$S/sentinel"
  rm -f -- "$L/sentinel.w"; printf '#!/bin/sh\nexit 0\n' > "$L/sentinel"; chmod 700 "$L/sentinel"
  printf 'provider_installation {\n  filesystem_mirror {\n    path = "%s"\n  }\n}\n' "$L/mirror" > "$L/etc/cli.tfrc"
}

# --- the sandbox ---------------------------------------------------------------------------
OS=other
case "$(uname -s)" in Darwin) OS=darwin ;; Linux) OS=linux ;; esac
PERL=/usr/bin/perl
TF=; FACTS=; SBX_KIND=none; SBX_OK=0; SBX_WHY=; PROFILE_SHA=
tools() {
  local t
  t="$(command -v terraform 2> /dev/null)" && TF="$(realp "$t")"
  t="$(command -v mtf-facts 2> /dev/null)" && FACTS="$(realp "$t")"
  if [ "$OS" = darwin ]; then SBX="$(command -v sandbox-exec 2> /dev/null)" && SBX_KIND=sandbox-exec
  elif [ "$OS" = linux ]; then SBX="$(command -v bwrap 2> /dev/null)" && SBX_KIND=bwrap; fi
}
envset() { # tmpdir: the whole environment a sandboxed command gets
  ENVKV=(PATH=/usr/bin:/bin "HOME=$S/home" "TMPDIR=$1" "TF_CLI_CONFIG_FILE=$L/etc/cli.tfrc"
    CHECKPOINT_DISABLE=1 TF_IN_AUTOMATION=1 TF_INPUT=0 "GOMEMLIMIT=${2:-1GiB}")
}
profile() { # kind [provider dir] [plugin tmp]: writes $L/etc/<kind>.sb, later rules win
  local f="$L/etc/$1.sb" bin
  {
    printf '(version 1)\n(allow default)\n(deny network*)\n(deny mach-lookup)\n(deny ipc-posix*)\n(deny ipc-sysv*)\n'
    printf '(deny signal)\n(allow signal (target self))\n'
    printf '(deny file-write*)\n(allow file-write* (subpath "%s") (literal "/dev/null"))\n' "$S"
    printf '(deny file-read*)\n(allow file-read* (literal "/") (literal "/private") (literal "/usr") (literal "/etc") (literal "/tmp") (literal "/var") (literal "/private/var")'
    printf ' (subpath "/usr/lib") (subpath "/usr/share") (subpath "/usr/bin") (subpath "/System") (subpath "/Library/Perl")'
    printf ' (subpath "/private/etc") (subpath "/private/var/db/timezone") (subpath "/dev")'
    printf ' (subpath "%s") (subpath "%s") (subpath "%s") (subpath "%s")' "$S" "$L/etc" "$L/mirror" "$L/fixtures"
    for bin in "$TF" "$PERL" ${FACTS:+"$FACTS"}; do printf ' (literal "%s")' "$bin"; done
    printf ')\n(deny file-read* (subpath "/System/Volumes/Data"))\n(deny process-exec*)\n(allow process-exec'
    for bin in "$TF" "$PERL" ${FACTS:+"$FACTS"}; do printf ' (literal "%s")' "$bin"; done
    printf ')\n'
    if [ -n "${2:-}" ]; then # acquisition's schema step: the providers it unpacked, read-only, and go-plugin sockets
      printf '(deny file-write* (subpath "%s"))\n(allow process-exec (subpath "%s"))\n' "$2" "$2"
      printf '(allow file-read* file-write* (subpath "%s"))\n' "$3"
      printf '(allow network* (local unix-socket (subpath "%s")) (remote unix-socket (subpath "%s")))\n' "$3" "$3"
    fi
  } > "$f"
}
bw_args() { # [provider dir]: the bwrap arguments
  BW=(--unshare-all --die-with-parent --new-session --clearenv)
  local kv p
  for kv in "${ENVKV[@]}"; do BW+=(--setenv "${kv%%=*}" "${kv#*=}"); done
  for p in /usr /bin /sbin /lib /lib64; do BW+=(--ro-bind-try "$p" "$p"); done
  BW+=(--proc /proc --dev /dev --tmpfs /ladder-tmp --ro-bind "$TF" "$TF" --ro-bind "$L/etc" "$L/etc"
    --ro-bind "$L/mirror" "$L/mirror" --ro-bind "$L/fixtures" "$L/fixtures")
  [ -n "$FACTS" ] && BW+=(--ro-bind "$FACTS" "$FACTS")
  BW+=(--bind "$S" "$S")
  [ -n "${1:-}" ] && BW+=(--ro-bind "$1" "$1")
  # The tmpfs root holds the mount points bwrap made for the binds; read-only, so a write
  # outside scratch and /tmp fails instead of landing on it.
  BW+=(--remount-ro /)
  return 0
}
sbx() { # kind dir timeout cap out cmd...: the command in the sandbox, under the runner
  local kind=$1 dir=$2 t=$3 cap=$4 out=$5; shift 5
  if [ "$SBX_KIND" = sandbox-exec ]; then
    run_cmd "$dir" "$t" "$cap" "$out" /usr/bin/env -i "${ENVKV[@]}" "$SBX" -f "$L/etc/$kind.sb" "$@"
  else
    run_cmd "$dir" "$t" "$cap" "$out" "$SBX" "${BW[@]}" --chdir "$dir" -- "$@"
  fi
}
prove() { # sets SBX_OK, SBX_WHY, PROFILE_SHA; the canary lines land in $L/out/canary.txt
  local b ns hostns homet
  SBX_OK=0
  [ "$SBX_KIND" != none ] || { SBX_WHY="no sandbox tool for $OS (sandbox-exec on macOS, bwrap on Linux)"; return 1; }
  [ -n "$TF" ] || { SBX_WHY="terraform is not installed"; return 1; }
  [ -x "$PERL" ] || { SBX_WHY="$PERL is missing"; return 1; }
  for b in "$TF" "$PERL" ${FACTS:+"$FACTS"} "$S" "${HOME:-/nonexistent}"; do
    pathok "$b" || { SBX_WHY="a path a profile would hold has other characters: $b"; return 1; }
  done
  envset "$S/tmp"
  if [ "$SBX_KIND" = sandbox-exec ]; then profile exec; PROFILE_SHA="$(sha256 "$L/etc/exec.sb")"
  else bw_args; PROFILE_SHA="$(printf '%s\n' "${BW[@]}" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)')"; fi
  ns="$(sed -n 's/^nameserver[[:space:]]\{1,\}\([0-9A-Fa-f.:]\{1,\}\)[[:space:]]*$/\1/p' /etc/resolv.conf 2> /dev/null | head -8)"
  hostns="$(readlink /proc/self/ns/net 2> /dev/null || echo none)"
  # The home check: on macOS the home directory itself; on Linux a file in it, since the
  # run directory may lie under home and bwrap then makes empty mount point directories there.
  homet="${HOME:-/nonexistent}"
  if [ "$OS" = linux ]; then
    for b in "$homet"/.* "$homet"/*; do [ -f "$b" ] && [ ! -L "$b" ] && pathok "$b" && { homet=$b; break; }; done
  fi
  # shellcheck disable=SC2086 # one word per name server address
  sbx exec "$S" 60 "$MIB" "$L/out/canary.txt" "$PERL" -e "$CANARY_PL" "$OS" "$S/sentinel" "$L/sentinel" "$homet" "$hostns" $ns
  local rc=$?
  [ "$rc" -eq 0 ] || { SBX_WHY="the canary exited $rc"; return 1; }
  SBX_WHY="$(canary_ok "$L/out/canary.txt" "$OS")" || return 1
  SBX_OK=1; SBX_WHY=
}
why_code() { # SBX_WHY: the fixed code the record carries; the text itself stays on the host
  case "$SBX_WHY" in
    '') echo null ;; 'no sandbox tool'*) echo '"no-sandbox-tool"' ;; 'terraform is not'*) echo '"no-terraform"' ;;
    *'is missing') echo '"no-perl"' ;; 'a path a profile'*) echo '"path-characters"' ;; 'the canary exited'*) echo '"canary-failed"' ;;
    'leak or fault'*) echo '"canary-leak"' ;; 'canary did not'*) echo '"canary-incomplete"' ;; 'no denied'*) echo '"canary-class-missing"' ;;
    'scratch not'*) echo '"scratch-unreadable"' ;; 'no network namespace'*) echo '"no-network-namespace"' ;; *) echo '"other"' ;;
  esac
}

# --- probe -----------------------------------------------------------------------------------
if [ "$CMD" = probe ]; then
  setup; tools
  prove; ok=$SBX_OK
  [ -f "$L/out/canary.txt" ] && cat "$L/out/canary.txt"
  if [ "$ok" = 1 ]; then
    sbx exec "$S" 60 "$MIB" "$L/out/version.txt" "$TF" version -json \
      && printf 'terraform %s\n' "$(jq -r '.terraform_version // "unknown"' "$L/out/version.txt" 2> /dev/null)"
    echo "sandbox proven $SBX_KIND"; exit 0
  fi
  echo "sandbox unproven: $SBX_WHY"; exit 1
fi

# --- acquisition -------------------------------------------------------------------------------
platform() {
  local m; m="$(uname -m)"
  case "$m" in arm64|aarch64) m=arm64 ;; x86_64|amd64) m=amd64 ;; *) return 1 ;; esac
  printf '%s_%s\n' "$OS" "$m"
}
pins_ok() { # pins file: the shape, exact artifact hosts, https URLs with nothing but a path
  jq -e '
    def host: capture("^https://(?<h>[a-z0-9.-]+)/[A-Za-z0-9._/+-]+$").h;
    .schema_version == 1 and (.artifact_hosts | type == "array" and all(.[]; type == "string"))
    and (.providers | type == "array" and length <= 8)
    and (.artifact_hosts as $hosts | all(.providers[];
      (.source | type == "string" and test("^[a-z0-9.-]+/[a-z0-9-]+/[a-z0-9-]+$"))
      and (.version | type == "string" and test("^[0-9]+[.][0-9]+[.][0-9]+$"))
      and (.platforms | type == "object" and all(to_entries[];
        (.key | test("^(darwin|linux)_(amd64|arm64)$"))
        and (.value.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
        and (.value.url | type == "string" and test("^https://[a-z0-9.-]+/[A-Za-z0-9._/+-]+$"))
        and ((.value.url | host) as $h | $hosts | index([$h]) != null)))))
  ' "$1" > /dev/null 2>&1
}
if [ "$CMD" = _fetch ]; then # internal: runs under the cache lock that acquire holds
  CURL="$(command -v curl)" || { echo "curl is not installed"; exit 1; }
  mkdir -m 700 -p "$L/empty-home"
  jq -r --arg p "$(platform)" '.providers[] | [.platforms[$p].url, .platforms[$p].sha256] | @tsv' "$PINS" \
  | while IFS="$(printf '\t')" read -r url sum; do
    f="$CACHE/$sum.zip"
    [ -f "$f" ] && [ "$(sha256 "$f")" = "$sum" ] && continue
    rm -f -- "$f" "$f.part"
    FSZ=$((520 * MIB)) run_cmd "$CACHE" 900 "$MIB" "$L/out/curl.txt" /usr/bin/env -i PATH=/usr/bin:/bin "HOME=$L/empty-home" \
      "$CURL" -q --proto =https --max-redirs 0 --max-filesize $((512 * MIB)) --fail --silent --show-error \
      --output "$f.part" -- "$url" || { echo "download failed: $url"; rm -f -- "$f.part"; exit 1; }
    [ "$(sha256 "$f.part")" = "$sum" ] || { echo "sha256 mismatch: $url"; rm -f -- "$f.part"; exit 1; }
    mv -- "$f.part" "$f" || exit 1
  done
  exit $?
fi
if [ "$CMD" = acquire ]; then
  fail() { echo "acquisition failed: $1"; exit 1; }
  [ -f "$PINS" ] || die "--pins must name a readable file"
  case "$SCHEMA_OUT" in /?*) ;; *) die "--schema-out must be an absolute path" ;; esac
  case "$CACHE" in /?*) ;; *) die "--cache must be an absolute path" ;; esac
  pins_ok "$PINS" || die "--pins is not a valid pin file"
  setup; tools
  PLAT="$(platform)" || fail "unsupported platform"
  jq -e --arg p "$PLAT" 'all(.providers[]; .platforms[$p] != null)' "$PINS" > /dev/null || fail "no pin for $PLAT"
  [ -e "$CACHE" ] || mkdir -m 700 -p "$CACHE" || fail "cannot create the cache"
  CACHE="$(cd "$CACHE" && pwd -P)"
  [ -d "$CACHE" ] && [ -O "$CACHE" ] && [ "$(perl -e 'printf "%o", (stat shift)[2] & 07777' "$CACHE")" = 700 ] \
    || fail "the cache must be a directory of this user with mode 0700"
  case "$CACHE/" in "$RUN"/*) fail "the cache must lie outside the run directory" ;; esac
  # Serialized: one acquisition at a time per cache, a kernel lock released when its holder dies.
  perl -MFcntl=:flock -e 'open my $l, ">>", shift or exit 3; for (1 .. 600) { if (flock($l, LOCK_EX | LOCK_NB)) { system { $ARGV[0] } @ARGV; exit($? >> 8 || ($? & 127 ? 1 : 0)) } sleep 1 } print "the cache lock is held by another run\n"; exit 1' \
    "$CACHE/lock" bash "$SELF" _fetch "$RUN" --pins "$PINS" --cache "$CACHE" || fail "fetch"
  chmod -R u+w "$L/mirror"; rm -rf -- "${L:?}/mirror"; mkdir -m 700 "$L/mirror" || fail "mirror"
  : > "$L/pins.jsonl"
  jq -r --arg p "$PLAT" '.providers[] | [.source, .version, .platforms[$p].sha256] | @tsv' "$PINS" \
  | while IFS="$(printf '\t')" read -r src ver sum; do
    typ="${src##*/}"; d="$L/mirror/${src%/*}/$typ"
    mkdir -p "$d" && cp -- "$CACHE/$sum.zip" "$d/terraform-provider-${typ}_${ver}_$PLAT.zip" || exit 1
    [ "$(sha256 "$d/terraform-provider-${typ}_${ver}_$PLAT.zip")" = "$sum" ] || exit 1
    jq -cn --arg s "$src" --arg v "$ver" --arg h "$sum" '{source:$s, version:$v, sha256:$h}' >> "$L/pins.jsonl"
  done || fail "mirror copy"
  chmod -R a-w "$L/mirror"
  prove || fail "sandbox: $SBX_WHY"
  A="$S/acq"; mkdir -p "$A"
  jq -r '"terraform {\n  required_providers {\n" + ([.providers | to_entries[] | "    p\(.key) = { source = \"\(.value.source)\", version = \"= \(.value.version)\" }\n"] | add // "") + "  }\n}"' \
    "$PINS" > "$A/main.tf"
  # Provider binaries are large: a 2 GiB file size limit for init, 6 GiB resident for schema.
  FSZ=$((2048 * MIB)) sbx exec "$A" 300 "$MIB" "$L/out/init.txt" "$TF" init -backend=false -input=false -no-color \
    || fail "terraform init: $(firstline "$L/out/init.txt.err")"
  P="$A/.terraform/providers"; [ -d "$P" ] || fail "no providers installed"
  chmod -R a-w "$P"
  if [ "$SBX_KIND" = sandbox-exec ]; then
    PT="$(cd "$(mktemp -d /tmp/ladder.XXXXXX)" && pwd -P)" || fail "no plugin directory"
    pathok "$PT" || fail "plugin directory path"
    trap 'chmod -R u+w "$S" 2> /dev/null; rm -rf -- "$S" "$PT"' EXIT
    profile schema "$P" "$PT"; envset "$PT" 4GiB
  else
    envset /ladder-tmp 4GiB; bw_args "$P"
  fi
  MEM_KB=6291456 sbx schema "$A" 300 $((64 * MIB)) "$L/out/schema.json" "$TF" providers schema -json \
    || fail "providers schema: $(firstline "$L/out/schema.json.err")"
  jq -e --slurpfile p "$L/pins.jsonl" '.format_version != null and (.provider_schemas | keys) == ([$p[].source] | sort)' \
    "$L/out/schema.json" > /dev/null 2>&1 || fail "the schema does not name exactly the pinned providers"
  cp -- "$L/out/schema.json" "$SCHEMA_OUT.tmp" && mv -- "$SCHEMA_OUT.tmp" "$SCHEMA_OUT" || fail "cannot write $SCHEMA_OUT"
  exit 0
fi

# --- L1 ------------------------------------------------------------------------------------------
sha_ok() { [ "${#1}" -eq 40 ] && case "$1" in *[!0-9a-f]*) false ;; esac; }
sha_ok "$BASESHA" || die "--base must be a full commit SHA"
sha_ok "$HEADSHA" || die "--head must be a full commit SHA"
case "$OUT" in /?*) ;; *) die "--out must be an absolute path" ;; esac
[ -d "${OUT%/*}/" ] || die "the directory of --out must exist"
[ -f "$BEH" ] || die "--behaviour must name a readable file"
[ "$(wc -c < "$BEH")" -le $((4 * MIB)) ] || die "--behaviour is over 4 MiB"
jq -e '.schema_version == 1 and (.triggers | type == "array") and all(.triggers[]; type == "object"
  and (.id | type == "string" and test("^T-[0-9]{3,6}$")) and (.levels | type == "array"))' "$BEH" > /dev/null 2>&1 \
  || die "--behaviour is not a behaviour report"
if [ -n "$COVER" ]; then
  jq -e '(.class | IN("complete","partial","none")) and (.examples | type == "array")' "$COVER" > /dev/null 2>&1 \
    || die "--coverage is not a coverage object"
fi
setup; tools
chmod -R u+w "$L/fixtures"; rm -rf -- "${L:?}/fixtures" && mkdir -m 700 "$L/fixtures"
START="$(date +%s)"
prove
TFV=null
if [ "$SBX_OK" = 1 ] && sbx exec "$S" 60 "$MIB" "$L/out/version.txt" "$TF" version -json; then
  TFV="$(jq -c '.terraform_version | if type == "string" and test("^[0-9]+[.][0-9]+[.][0-9]+[0-9A-Za-z.+-]*$") then . else null end' "$L/out/version.txt" 2> /dev/null || echo null)"
fi
# The record names the sandbox by fixed words only; canary lines and paths stay in $L/out.
SBXJ="$(jq -cn --arg kind "$SBX_KIND" --argjson ok "$SBX_OK" --arg sha "$PROFILE_SHA" --argjson why "$(why_code)" \
  '{kind:$kind, proven:($ok == 1), profile_sha256:(if $sha == "" then null else $sha end), reason:$why}')"

# Builds the fixture pair of one trigger from the template and the classifier's cases: a
# local per input whose state a case var file picks, terraform_data stand-ins whose output is a
# typed unknown with a canary each, the subject in subject.tf, a manifest and a var file per
# case. Prints one JSON object: {"ok":true, ...} or {"ok":false,"reason":...}.
FIX_PL='
use strict; use warnings; use JSON::PP;
my ($tfile, $tmpl, $root) = @ARGV;
my $J = JSON::PP->new->canonical;
sub done { print $J->encode(shift), "\n"; exit 0 }
sub nope { done({ok => JSON::PP::false, reason => substr(shift, 0, 200)}) }
my $t = do { local $/; open my $fh, "<", $tfile or die; $J->decode(<$fh>) };
my %sec; { open my $fh, "<", $tmpl or die; my $cur; while (<$fh>) { if (/\A#-- (\S+)\n\z/) { $cur = $1; $sec{$cur} = ""; next } $sec{$cur} .= $_ if defined $cur } }
sub fill { my ($s, %v) = @_; my $x = $sec{$s} // die "no section $s"; $x =~ s/__([A-Z]+)__/exists $v{$1} ? $v{$1} : die "no value $1"/ge; $x }
sub toks { my $s = shift; my @t; while ($s =~ /\G\s*(?:([A-Za-z_][A-Za-z0-9_-]*)|([()\[\]{},=]))/gc) { push @t, defined $1 ? $1 : $2 } return undef unless $s =~ /\G\s*\z/gc && @t <= 400; \@t }
sub want { my ($t, $x) = @_; my $g = shift @$t; die "type\n" unless defined $g && $g eq $x }
sub ty { my ($t, $d) = @_; die "type\n" if $d > 20; my $k = shift @$t // die "type\n";
  return {k => $k} if $k =~ /\A(string|number|bool|any)\z/;
  if ($k =~ /\A(list|set|map)\z/) { want($t, "("); my $e = ty($t, $d + 1); want($t, ")"); return {k => $k, e => $e} }
  if ($k eq "tuple") { want($t, "("); want($t, "["); my @e; until (($t->[0] // "") eq "]") { push @e, ty($t, $d + 1); shift @$t if ($t->[0] // "") eq "," } want($t, "]"); want($t, ")"); return {k => "tuple", es => \@e} }
  if ($k eq "object") { want($t, "("); want($t, "{"); my @a;
    until (($t->[0] // "") eq "}") { my $n = shift @$t // die "type\n"; die "type\n" unless $n =~ /\A[A-Za-z_][A-Za-z0-9_-]*\z/; want($t, "=");
      if (($t->[0] // "") eq "optional") { shift @$t; want($t, "("); push @a, [$n, ty($t, $d + 1), 1]; want($t, ")") } else { push @a, [$n, ty($t, $d + 1), 0] }
      shift @$t if ($t->[0] // "") eq "," }
    want($t, "}"); want($t, ")"); return {k => "object", a => \@a} }
  die "type\n" }
sub ptype { my $s = shift; return undef unless defined $s && !ref $s; my $t = toks($s) or return undef; my $y = eval { ty($t, 0) }; return undef unless $y && !@$t; $y }
sub emit { my $y = shift;
  return "$y->{k}(" . emit($y->{e}) . ")" if $y->{e};
  return "tuple([" . join(", ", map { emit($_) } @{$y->{es}}) . "])" if $y->{es};
  return "object({" . join(", ", map { "$_->[0] = " . ($_->[2] ? "optional(" . emit($_->[1]) . ")" : emit($_->[1])) } @{$y->{a}}) . "})" if $y->{a};
  $y->{k} }
sub sample { my ($y, $c) = @_; my ($k, $one) = ($y->{k}, $c eq "one");
  return $one ? "a" : "" if $k eq "string" || $k eq "any";
  return $one ? 1 : 0 if $k eq "number";
  return $one ? JSON::PP::true : JSON::PP::false if $k eq "bool";
  return $one ? [sample($y->{e}, $c)] : [] if $k eq "list" || $k eq "set";
  return $one ? {k => sample($y->{e}, $c)} : {} if $k eq "map";
  return [map { sample($_, $c) } @{$y->{es}}] if $k eq "tuple";
  return {map { ($_->[0] => sample($_->[1], $c)) } @{$y->{a}}} }
my %ex = (base => $t->{base_expr}, head => $t->{head_expr});
for (values %ex) { nope("an expression is not a string") if defined && ref }
my @sides = grep { defined $ex{$_} && length $ex{$_} } qw(base head);
nope("the trigger has no expression") unless @sides;
for (@sides) { nope("an expression is over 16 KiB") if length $ex{$_} > 16384 }
# The inputs: the variables the expression reads, and the resource or data references,
# each with its type. A case gives every input a state; the fixture turns each input into
# a local whose value the case var file decides, and the expression reads that local.
my (@in, %seen);
sub input { my ($name, $y, $kind, $text) = @_; return if $seen{$name}++; push @in, {name => $name, y => $y, kind => $kind, text => $text} }
for my $r (@{ref $t->{referenced_inputs} eq "ARRAY" ? $t->{referenced_inputs} : []}) {
  nope("a referenced input has no name") unless ref $r eq "HASH" && defined $r->{name} && !ref $r->{name} && $r->{name} =~ /\A[A-Za-z_][A-Za-z0-9_-]{0,63}\z/;
  my $y = ptype($r->{type}) or nope("an input type is outside the L1 type grammar");
  input($r->{name}, $y, "var", "var.$r->{name}");
}
my $det = $t->{contextual_ref_details};
my @refs = ref $det eq "ARRAY" ? @$det : ();
nope("contextual references without details") if !@refs && ref $t->{contextual_refs} eq "ARRAY" && @{$t->{contextual_refs}};
my $wrap = "none";
for my $r (@refs) {
  nope("a contextual reference has no text and kind") unless ref $r eq "HASH" && defined $r->{text} && !ref $r->{text} && defined $r->{kind} && !ref $r->{kind} && length $r->{text} <= 256;
  my ($k, $x) = ($r->{kind}, $r->{text});
  if ($k eq "resource" || $k eq "data") {
    $x =~ /\A(?:data\.)?[a-z][a-z0-9_]*\.[A-Za-z_][A-Za-z0-9_-]*(\[\*\]|\[[0-9]+\]|\.\*)?\.([A-Za-z_][A-Za-z0-9_]*)\z/ or nope("a resource reference shape L1 cannot model");
    my ($ix, $attr) = ($1, $2);
    my $y = defined $r->{type} ? ptype($r->{type}) : $attr eq "id" ? {k => "string"} : undef;
    $y or nope("a resource reference with no attribute type");
    $y = {k => "list", e => $y} if defined $ix && $ix =~ /\*/;
    input($x, $y, "ref", $x);
  } elsif ($k eq "count") {
    nope("a count or each reference L1 cannot model") unless $x eq "count.index";
    nope("count and each in one expression") if $wrap eq "for_each"; $wrap = "count";
  } elsif ($k eq "each") {
    nope("an each.value reference is unverifiable at L1") unless $x eq "each.key";
    nope("count and each in one expression") if $wrap eq "count"; $wrap = "for_each";
  } elsif ($k eq "path" || $k eq "terraform") { nope("path and terraform references are unverifiable at L1")
  } else { nope("local, module, self and other references are unverifiable at L1") }
}
my $omit;   # a default-change trigger: the variable whose default the expression is
if (($t->{category} // "") eq "default-change" && defined $t->{address} && !ref $t->{address} && $t->{address} =~ /\Avar\.([A-Za-z_][A-Za-z0-9_-]{0,63})\z/) {
  $omit = $1;
  nope("the variable of a default change is not a referenced input") unless $seen{$omit};
}
# The cases, from the classifier: exactly the inputs above, each in one state.
my $cs = $t->{cases};
nope("no cases") unless ref $cs eq "ARRAY" && @$cs;
nope("over 32 cases") if @$cs > 32;
my (%ids, @cases);
# count.index and each.key are inputs too: the case picks the instance the subject is read at.
my $winput = $wrap eq "count" ? "count.index" : $wrap eq "for_each" ? "each.key" : undef;
my @names = ((map { $_->{name} } @in), defined $winput ? $winput : ());
for my $c (@$cs) {
  nope("a case has no id or inputs") unless ref $c eq "HASH" && defined $c->{id} && !ref $c->{id} && $c->{id} =~ /\A[A-Za-z0-9_.:-]{1,64}\z/ && ref $c->{inputs} eq "HASH";
  nope("two cases share an id") if $ids{$c->{id}}++;
  nope("a case does not name exactly the inputs") unless join("\n", sort keys %{$c->{inputs}}) eq join("\n", sort @names);
  my %v;
  for my $i (0 .. $#in) {
    my ($p, $s) = ($in[$i], $c->{inputs}{$in[$i]{name}});
    nope("a case input has another shape") unless ref $s eq "HASH";
    my @on = grep { $s->{$_} } qw(unknown null omitted);
    my $ue = ref $s->{unknown_elements} eq "ARRAY" ? $s->{unknown_elements} : [];
    nope("a case input has more than one state") if @on > 1 || (@on && @$ue);
    my $mode = @on ? $on[0] : "known";
    nope("an omitted input that is not the default being changed") if $mode eq "omitted" && !(defined $omit && $p->{name} eq $omit);
    nope("unknown elements of a type with no elements") if @$ue && !$p->{y}{e};
    for (@$ue) { nope("an unknown element is not an index or key") unless defined && !ref && /\A[A-Za-z0-9_.-]{1,64}\z/ }
    $v{"ladder_mode_$i"} = $mode;
    $v{"ladder_val_$i"} = $mode eq "known" ? $s->{value} : undef;
    $v{"ladder_sample_$i"} = sample($p->{y}, "one");
    if ($p->{y}{e}) { $v{"ladder_unk_$i"} = [map { "$_" } @$ue]; $v{"ladder_esample_$i"} = sample($p->{y}{e}, "one") }
    if (defined $omit && $p->{name} eq $omit) { $v{ladder_omit} = $mode eq "omitted" ? JSON::PP::true : JSON::PP::false }
  }
  my $addr = "";
  if (defined $winput) {
    my $s = $c->{inputs}{$winput};
    nope("a count.index or each.key input that is not a known value") unless ref $s eq "HASH" && !grep { $s->{$_} } qw(unknown null omitted);
    if ($wrap eq "count") {
      nope("a count.index input that is not a small index") unless defined $s->{value} && !ref $s->{value} && $s->{value} =~ /\A[0-9]\z/;
      $v{ladder_count_index} = 0 + $s->{value}; $addr = "terraform_data.subject[$s->{value}]";
    } else {
      nope("an each.key input outside the key characters") unless defined $s->{value} && !ref $s->{value} && $s->{value} =~ /\A[A-Za-z0-9_.-]{0,64}\z/;
      $v{ladder_each_key} = "$s->{value}"; $addr = "terraform_data.subject[\"$s->{value}\"]";
    }
  }
  push @cases, {id => $c->{id}, vars => \%v, inputs => $c->{inputs}, addr => $addr,
    unknown => [map { $in[$_]{name} } grep { my $s = $c->{inputs}{$in[$_]{name}}; $s->{unknown} || (ref $s->{unknown_elements} eq "ARRAY" && @{$s->{unknown_elements}}) } 0 .. $#in]};
}
# main.tf: the variables, the stand-ins whose output is a typed unknown, a canary each,
# the locals, the known canary.
my (%vars, @standins, @canaries, @locals, @blocks);
for my $i (0 .. $#in) {
  my $y = $in[$i]{y};
  my $set = $y->{k} eq "set";
  $vars{"ladder_val_$i"} = $set ? {k => "list", e => $y->{e}} : $y;   # a set with an unknown element is built from a list
  $vars{"ladder_mode_$i"} = {k => "string"};
  $vars{"ladder_sample_$i"} = $y;
  push @standins, fill("standin", NAME => "ladder_u_$i", COUNT => "", VAR => "ladder_sample_$i");
  push @canaries, ["canary_ladder_u_$i", "terraform_data.ladder_u_$i.output"];
  my $known = "var.ladder_val_$i";
  if ($y->{e}) {
    $vars{"ladder_unk_$i"} = {k => "list", e => {k => "string"}};
    $vars{"ladder_esample_$i"} = $y->{e};
    push @standins, fill("standin", NAME => "ladder_ue_$i", COUNT => "", VAR => "ladder_esample_$i");
    push @canaries, ["canary_ladder_ue_$i", "terraform_data.ladder_ue_$i.output"];
    my $pick = "contains(var.ladder_unk_$i, tostring(k)) ? terraform_data.ladder_ue_$i.output : v";
    $known = $y->{k} eq "map" ? "tomap({ for k, v in var.ladder_val_$i : k => $pick })"
      : ($set ? "toset" : "tolist") . "([for k, v in var.ladder_val_$i : $pick])";
  }
  push @locals, "  ladder_in_$i = var.ladder_mode_$i == \"unknown\" ? terraform_data.ladder_u_$i.output : var.ladder_mode_$i == \"known\" ? $known : null\n";
}
$vars{ladder_omit} = {k => "bool"} if defined $omit;
$vars{ladder_count_index} = {k => "number"} if $wrap eq "count";
$vars{ladder_each_key} = {k => "string"} if $wrap eq "for_each";
my $main = "";
$main .= fill("variable", NAME => $_, TYPE => emit($vars{$_})) for sort keys %vars;
$main .= $_ for @standins;
$main .= fill("locals", BODY => join("", @locals)) if @locals;
$main .= fill("canary", NAME => $_->[0], REF => $_->[1]) for @canaries;
$main .= fill("known");
@blocks = ((map { {type => "variable", labels => [$_]} } sort keys %vars),
  (map { {type => "resource", labels => ["terraform_data", $_]} } map { ("ladder_u_$_", $in[$_]{y}{e} ? "ladder_ue_$_" : ()) } 0 .. $#in),
  (@locals ? {type => "locals", labels => []} : ()),
  (map { {type => "output", labels => [$_->[0]]} } @canaries), {type => "output", labels => ["canary_known"]});
mkdir "$root/vars" or die;
for my $c (@cases) { open my $fh, ">", "$root/vars/$c->{id}.tfvars.json" or die; print $fh $J->encode($c->{vars}) }
# The expression reads the locals: each var.<name> and each reference text, as a whole name.
my @rw = sort { length($b->[0]) <=> length($a->[0]) || $a->[0] cmp $b->[0] } map { [$in[$_]{text}, "local.ladder_in_$_", $in[$_]{kind}] } 0 .. $#in;
my $subj = $wrap eq "none" ? {type => "output", labels => ["subject"]} : {type => "resource", labels => ["terraform_data", "subject"]};
my $sec = defined $omit ? "subject-default" : $wrap eq "none" ? "subject-output" : $wrap eq "count" ? "subject-count" : "subject-for-each";
nope("a default change in a counted or for_each context") if defined $omit && $wrap ne "none";
my ($oi) = grep { defined $omit && $in[$_]{name} eq $omit } 0 .. $#in;
mkdir "$root/expect" or die;
for my $s (@sides) {
  my $e = $ex{$s};
  for my $r (@rw) {
    my ($x, $to) = @$r;
    $e =~ s/(?<![A-Za-z0-9_.-])\Q$x\E(?![A-Za-z0-9_-])/$to/g;
  }
  mkdir "$root/$s" or die;
  open my $fh, ">", "$root/$s/main.tf" or die;
  print $fh $main;
  close $fh;
  open $fh, ">", "$root/$s/subject.tf" or die;
  print $fh fill($sec, EXPR => $e, LOCAL => defined $oi ? "local.ladder_in_$oi" : "");
  close $fh;
  open $fh, ">", "$root/expect/$s.json" or die;
  print $fh $J->encode({schema_version => 1, files => {"main.tf" => {blocks => \@blocks},
    "subject.tf" => {blocks => [$subj],
      single_expressions => [{block => $subj->{type}, labels => $subj->{labels}, attribute => $wrap eq "none" ? "value" : "input"}]}}});
}
done({ok => JSON::PP::true, wrap => $wrap, sides => \@sides, canaries => [map { $_->[0] } @canaries],
  cases => [map { {id => $_->{id}, inputs => $_->{inputs}, unknown_inputs => $_->{unknown}, addr => $_->{addr}} } @cases]});
'

# Projects one plan shown as JSON into an observation, and checks the canaries.
PROJ_JQ='
def anytrue: [.. | select(. == true)] | length > 0;
def subj: if $wrap == "none" then (.output_changes.subject // null)
  else (first(.resource_changes[]? | select(.address == $cs.addr) | .change) // null
    | if . == null then null else {after: .after.input, after_unknown: (.after_unknown.input // false),
        after_sensitive: (.after_sensitive.input // false)} end) end;
. as $p | ($p | subj) as $s
| { canaries: ([$canaries[] | $p.output_changes[.].after_unknown == true] | all),
    known: ($p.output_changes.canary_known.after == "known" and $p.output_changes.canary_known.after_unknown == false),
    obs: (if $s == null then null else
      ($s.after_unknown // false) as $u | (($s.after_sensitive // false) | anytrue) as $sens
      | ($u == true) as $whole | (($u | anytrue) | not) as $known
      | (($s.after | tojson | length) > 4096) as $big
      | {case: $cs.id, error: false, known: $known, wholly_unknown: $whole, unknown_inputs: $cs.unknown_inputs, inputs: $cs.inputs,
         length: (if $whole then null elif ($s.after | type) == "array" then ($s.after | length)
                  elif ($s.after | type) == "object" and $known then ($s.after | length) else null end),
         sensitive: $sens, redacted: (($whole | not) and ($sens | not) and $big),
         unknown_mask: (if $known then false elif ($u | tojson | length) > 4096 then null else $u end),
         action: null, unchanged_vs_prior: null}
      # A value whenever one is known, with null at the unknown parts of a partly unknown one.
      + (if ($whole | not) and ($sens | not) and ($big | not) then {value: $s.after} else {} end) end) }'

subject_error() { # plan error output: 0 when every error it holds is located in subject.tf
  perl -e 'my ($n, $s, $cur) = (0, 0, 0); while (<>) { if (/\A\s*Error:/) { $n++; $cur = 1; next }
    if ($cur && /\A\s*on (\S+) line [0-9]+/) { $s++ if $1 eq "subject.tf"; $cur = 0 } }
    exit($n > 0 && $s == $n ? 0 : 1)' "$1" 2> /dev/null
}
record() { # trigger state reason fixture_sha control observations
  jq -cn --arg id "$1" --arg st "$2" --arg why "$3" --arg fx "$4" --arg ctl "$5" --argjson obs "$6" \
    '{trigger_id:$id, level:"L1", state:$st, reason:(if $why == "" then null else $why end),
      fixture_sha256:(if $fx == "" then null else $fx end), control:(if $ctl == "" then null else $ctl end),
      observations:$obs}' >> "$L/runs.jsonl"
}
left() { # timeout: the timeout clipped to what the review's L1 budget has left; 1 when none
  local r=$((START + L1_BUDGET - $(date +%s)))
  [ "$r" -gt 0 ] || return 1
  [ "$1" -lt "$r" ] && r=$1
  echo "$r"
}
# Run reasons are fixed strings, or fixed words with a side, a case id, an exit status
# or rule ids of the trusted checker: nothing from the clone or a command's output.
l1() { # trigger file, id: one run record
  local tf=$1 id=$2 F="$L/fixtures/$2" meta wrap addr side c out rc why t fx="" base="" head="" obsb="[]" obsh="[]" o
  local fixj nob='{"base":[],"head":[]}'
  if [ "$SBX_OK" != 1 ]; then record "$id" unverifiable "sandbox unproven" "" "" "{\"base\":[],\"head\":[],\"sandbox\":$SBXJ}"; return; fi
  left 1 > /dev/null || { record "$id" unverifiable "budget" "" "" "$nob"; return; }
  mkdir -m 700 "$F" || { record "$id" unverifiable "fixture directory" "" "" "$nob"; return; }
  meta="$(perl -e "$FIX_PL" "$tf" "$TPL/l1.tf.tmpl" "$F" 2> /dev/null)" || meta='{"ok":false,"reason":"fixture builder failed"}'
  if [ "$(printf '%s' "$meta" | jq -r '.ok')" != true ]; then
    record "$id" unverifiable "$(printf '%s' "$meta" | jq -r '.reason // "fixture builder failed"')" "" "" "$nob"; return
  fi
  wrap="$(printf '%s' "$meta" | jq -r .wrap)"
  find "$F" -type f -exec chmod 444 {} + ; find "$F" -type d -exec chmod 555 {} +
  fixj='{}'
  for side in $(printf '%s' "$meta" | jq -r '.sides[]'); do
    [ -n "$FACTS" ] || { record "$id" unverifiable "mtf-facts is not installed" "" "" "$nob"; return; }
    t="$(left 60)" || { record "$id" unverifiable "budget" "" "" "$nob"; return; }
    sbx exec "$F/$side" "$t" "$MIB" "$L/out/fc.json" "$FACTS" fixture-check "$F/$side" --level L1 \
      --expect "$F/expect/$side.json" --json; rc=$?
    if [ "$rc" -eq 1 ]; then
      why="$(jq -r '[.violations[]? | .rule | select(type == "string" and test("^[a-z0-9._-]{1,64}$"))] | unique | .[:5] | join(", ")' "$L/out/fc.json" 2> /dev/null)"
      record "$id" unverifiable "fixture-check $side: ${why:-violations}" "" "" "$nob"; return
    fi
    o="$(jq -r 'select(.schema_version == 1 and .ok == true) | .tree_sha256 | select(type == "string" and test("^[0-9a-f]{64}$"))' "$L/out/fc.json" 2> /dev/null)"
    [ "$rc" -eq 0 ] && [ -n "$o" ] || { record "$id" unverifiable "fixture-check $side exited $rc" "" "" "$nob"; return; }
    fixj="$(printf '%s' "$fixj" | jq -c --arg s "$side" --arg h "$o" '. + {("\($s)_tree_sha256"): $h}')"
    if [ "$side" = base ]; then base=$o; else head=$o; fi
  done
  fixj="$(printf '%s' "$fixj" | jq -c --argjson v "$(for f in "$F"/vars/*.tfvars.json; do c="${f##*/}"; jq -cn --arg c "${c%.tfvars.json}" --arg h "$(sha256 "$f")" '{($c): $h}'; done | jq -cs 'add // {}')" \
    '. + {vars_sha256: $v}')"
  fx="$(printf 'base:%s\nhead:%s\n' "$base" "$head" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)')"
  local fob="{\"base\":[],\"head\":[],\"fixture\":$fixj}" ci n
  # A static check first, on every side: an undeclared name or a broken fixture fails here,
  # so a plan error of a case below is the expression's own error for those inputs.
  for side in $(printf '%s' "$meta" | jq -r '.sides[]'); do
    t="$(left 60)" || { record "$id" unverifiable "budget" "$fx" "" "$fob"; return; }
    sbx exec "$F/$side" "$t" "$MIB" "$L/out/validate.txt" "$TF" validate -no-color; rc=$?
    [ "$rc" -eq 0 ] || { record "$id" unverifiable "validate $side exited $rc" "$fx" "" "$fob"; return; }
  done
  n="$(printf '%s' "$meta" | jq '.cases | length')"
  for ((ci = 0; ci < n; ci++)); do
    c="$(printf '%s' "$meta" | jq -r --argjson i "$ci" '.cases[$i].id')"
    for side in $(printf '%s' "$meta" | jq -r '.sides[]'); do
      out="$S/plans/$side-$ci.tfplan"
      t="$(left 120)" || { record "$id" unverifiable "budget" "$fx" "" "$fob"; return; }
      sbx exec "$F/$side" "$t" $((8 * MIB)) "$L/out/plan.txt" "$TF" plan -input=false -no-color -refresh=false -lock=false \
        "-var-file=$F/vars/$c.tfvars.json" "-out=$out"; rc=$?
      # An error only in subject.tf is the expression failing for these inputs: an observation.
      if [ "$rc" -eq 1 ] && subject_error "$L/out/plan.txt.err"; then
        o="$(printf '%s' "$meta" | jq -c --argjson i "$ci" '.cases[$i] | {obs: {case: .id, error: true, known: false, wholly_unknown: false,
          length: null, sensitive: false, redacted: false, unknown_mask: null, unknown_inputs, inputs, action: null, unchanged_vs_prior: null}}')"
      else
        [ "$rc" -eq 0 ] || { record "$id" unverifiable "plan $side $c exited $rc" "$fx" "" "$fob"; return; }
        t="$(left 120)" || { record "$id" unverifiable "budget" "$fx" "" "$fob"; return; }
        sbx exec "$F/$side" "$t" $((8 * MIB)) "$L/out/show.json" "$TF" show -json "$out"; rc=$?
        mv -- "$out" "$L/plans/$id-$side-$ci.tfplan" 2> /dev/null
        [ "$rc" -eq 0 ] || { record "$id" unverifiable "show $side $c exited $rc" "$fx" "" "$fob"; return; }
        o="$(jq -c --arg wrap "$wrap" --argjson canaries "$(printf '%s' "$meta" | jq -c .canaries)" \
          --argjson cs "$(printf '%s' "$meta" | jq -c --argjson i "$ci" '.cases[$i]')" "$PROJ_JQ" "$L/out/show.json" 2> /dev/null)"
        if [ -z "$o" ] || [ "$(printf '%s' "$o" | jq -r '.canaries and .known')" != true ]; then
          record "$id" unverifiable "canary $side $c" "$fx" invalid "$fob"; return
        fi
        if [ "$(printf '%s' "$o" | jq -r '.obs == null')" = true ]; then
          record "$id" unverifiable "no subject $side $c" "$fx" invalid "$fob"; return
        fi
        if [ "$(printf '%s' "$o" | jq -r '.obs.sensitive')" = true ]; then
          record "$id" unverifiable "sensitive subject $side $c" "$fx" "" "$fob"; return
        fi
      fi
      if [ "$side" = base ]; then obsb="$(printf '%s' "$obsb" | jq -c --argjson o "$o" '. + [$o.obs]')"
      else obsh="$(printf '%s' "$obsh" | jq -c --argjson o "$o" '. + [$o.obs]')"; fi
    done
    [ "$(du -sk "$S" | cut -f1)" -le "$SCRATCH_CAP_KB" ] || { record "$id" unverifiable "scratch over its cap" "$fx" "" "$fob"; return; }
  done
  record "$id" ran "" "$fx" valid "$(jq -cn --argjson b "$obsb" --argjson h "$obsh" --argjson f "$fixj" --argjson s "$SBXJ" \
    '{base:$b, head:$h, fixture:$f, sandbox:($s | {kind, proven, profile_sha256})}')"
}

: > "$L/runs.jsonl"
jq -r '.l1[]' "$TPL/l1-categories.json" > "$L/etc/l1-categories.txt"
jq -c '.triggers[] | select(.levels | index("L1"))' "$BEH" | head -n "$MAX_TRIGGERS" > "$L/etc/l1-triggers.jsonl"
n=0
while IFS= read -r t; do
  n=$((n + 1))
  printf '%s\n' "$t" > "$L/etc/trigger.json"
  id="$(jq -r .id "$L/etc/trigger.json")"
  cat="$(jq -r '.category // ""' "$L/etc/trigger.json")"
  if ! grep -qxF -- "$cat" "$L/etc/l1-categories.txt"; then
    [[ "$cat" =~ ^[a-z0-9_-]{1,64}$ ]] || cat=other
    record "$id" unverifiable "no L1 template for category $cat" "" "" '{"base":[],"head":[]}'
    continue
  fi
  l1 "$L/etc/trigger.json" "$id"
done < "$L/etc/l1-triggers.jsonl"

PINSJ='[]'; [ -s "$L/pins.jsonl" ] && PINSJ="$(jq -cs . "$L/pins.jsonl")"
COVJ='{"class":"none","examples":[]}'; [ -n "$COVER" ] && COVJ="$(jq -c '{class, examples}' "$COVER")"
if ! { jq -n --arg head "$HEADSHA" --arg base "$BASESHA" --argjson tfv "$TFV" --argjson pins "$PINSJ" \
  --argjson cov "$COVJ" --slurpfile runs "$L/runs.jsonl" \
  '{schema_version:1, head_sha:$head, base_sha:$base, terraform_version:$tfv, pins:$pins, runs:$runs,
    coverage:$cov}' > "$OUT.tmp" && mv -- "$OUT.tmp" "$OUT"; }; then die "cannot write $OUT"; fi
exit 0
