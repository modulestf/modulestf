# shellcheck shell=sh
# facts-resolve.sh: the one way the pull request review scripts find mtf-facts and read what it
# can do. Sourced, never run, by review-run.sh (bash) and verify-pass.sh (bash or zsh), so it
# keeps to shell both read the same way. Rules: review-run-details.md, section "The mtf-facts line".
#
#   facts_resolve [<refused dir>...]
#       Finds mtf-facts from /, canonical, a regular executable file outside every refused
#       directory, and runs "mtf-facts version --json" once under a 10 second limit and a 64 KiB
#       output cap. Sets:
#         FACTS_BIN       the binary, or empty when there is none
#         FACTS_STATE     absent, ok, old (no version report), timeout or refused
#         FACTS_VERSION   the version as the binary reports it (vX.Y.Z, a pseudo-version of a
#                         build from a commit, or "(devel)") when it is plain text, else empty.
#                         Only printed: the feature list, never the version, says what it can do.
#         FACTS_FEATURES  the report's feature names, one per line, only when FACTS_STATE is ok
#         FACTS_REPORT    the report as it came, only when FACTS_STATE is ok
#   facts_has <feature>    exit 0 when the version report lists the feature
#   facts_line             one line for the run's summary and the reviewer's task
#   facts_run <seconds> <bytes> <command>...
#       Runs a command in its own process group with standard error on standard output (dropped
#       when FACTS_RUN_NOERR is set), under a time limit and an output cap. Exit 124 past the
#       limit, 125 past the cap, both after the group is killed; else the command's own status.

# The features the scripts read, each with the first release that reports it. A step whose
# feature is missing takes its older path, so a binary without one still gives a review.
FACTS_NEEDS='flag:affected:module-root v0.12.0
flag:profile-check:profile-dir v0.9.0'

# shellcheck disable=SC2016 # a perl program
FACTS_RUN_PL='
my ($lim, $cap) = splice(@ARGV, 0, 2);
pipe(my $r, my $w) or exit 126;
my $pid = fork; exit 126 unless defined $pid;
if (!$pid) {
  close $r; setpgrp(0, 0);
  open(STDOUT, ">&", $w); open(STDIN, "<", "/dev/null");
  if ($ENV{FACTS_RUN_NOERR}) { open(STDERR, ">", "/dev/null") } else { open(STDERR, ">&", $w) }
  exec @ARGV; exit 127;
}
close $w;
my $stop = sub { kill "KILL", -$pid; kill "KILL", $pid; waitpid($pid, 0); exit shift };
$SIG{ALRM} = sub { $stop->(124) }; alarm($lim > 0 ? $lim : 1);
my ($n, $b) = (0, "");
while (my $k = sysread($r, $b, 65536)) {
  $n += $k; $stop->(125) if $n > $cap;
  syswrite(STDOUT, $b);
}
waitpid($pid, 0); exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
'
facts_run() {
  perl -e "$FACTS_RUN_PL" "$@" < /dev/null
}

facts_resolve() {
  FACTS_BIN='' FACTS_STATE=absent FACTS_VERSION='' FACTS_FEATURES='' FACTS_REPORT=''
  _fr_bin="$(cd / && command -v mtf-facts 2> /dev/null)" || return 0
  case "$_fr_bin" in /*) ;; *) return 0 ;; esac
  _fr_bin="$(cd / && perl -MCwd=realpath -e 'my $r = realpath($ARGV[0]); print $r if defined $r' "$_fr_bin")"
  [ -n "$_fr_bin" ] && [ -f "$_fr_bin" ] && [ -x "$_fr_bin" ] || return 0
  for _fr_d in "$@"; do
    [ -n "$_fr_d" ] || continue
    _fr_d="$(CDPATH= cd -- "$_fr_d" 2> /dev/null && pwd -P)" || continue
    case "$_fr_bin/" in "$_fr_d"/*) return 0 ;; esac
  done
  FACTS_BIN=$_fr_bin
  _fr_out="$(cd / && facts_run 10 65536 "$FACTS_BIN" version --json)"
  case $? in
    0)
      if printf '%s\n' "$_fr_out" | jq -e -s 'length == 1 and (.[0] | type == "object" and .schema_version == 1
          and (.version | type == "string") and (.features | type == "array" and length <= 4096
          and all(.[]; type == "string" and test("^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$"))))' > /dev/null 2>&1; then
        # shellcheck disable=SC2034 # read by the scripts that source this file
        FACTS_STATE=ok FACTS_REPORT=$_fr_out
        FACTS_FEATURES="$(printf '%s\n' "$_fr_out" | jq -r '.features[]')"
        FACTS_VERSION="$(printf '%s\n' "$_fr_out" | jq -r '.version | select(test("^[A-Za-z0-9(][A-Za-z0-9.+_()-]{0,127}$"))')"
      else
        FACTS_STATE=refused
      fi ;;
    124) FACTS_STATE=timeout ;;
    125) FACTS_STATE=refused ;;
    *)
      # No version report: a release before it. Its plain version line names the release.
      FACTS_STATE=old
      # Taken only when the output is exactly one line.
      _fr_out="$(cd / && facts_run 10 4096 "$FACTS_BIN" version)" &&
        case "$_fr_out" in
          *"
"*) ;;
          *) printf '%s\n' "$_fr_out" | grep -Eqx '[A-Za-z0-9(][A-Za-z0-9.+_()-]{0,127}' && FACTS_VERSION=$_fr_out ;;
        esac ;;
  esac
  return 0
}

facts_has() {
  # Only a name the version report may hold: an empty one or one with a line break matches nothing.
  case "$1" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9:._-]*) return 1 ;; esac
  [ "${#1}" -le 128 ] || return 1
  case "
$FACTS_FEATURES
" in *"
$1
"*) return 0 ;; esac
  return 1
}

facts_line() {
  _fl_v="${FACTS_VERSION:-version unknown}"
  _fl_min="$(printf '%s\n' "$FACTS_NEEDS" | awk '{ split(substr($2, 2), p, "."); k = p[1] * 1000000 + p[2] * 1000 + p[3]
    if (k > m) { m = k; v = $2 } } END { print v }')"
  case "$FACTS_STATE" in
    absent) echo "mtf-facts: not installed" ;;
    timeout) echo "mtf-facts: $_fl_v, its version report timed out; every step uses its older path" ;;
    refused) echo "mtf-facts: $_fl_v, its version report was refused; every step uses its older path" ;;
    old) echo "mtf-facts: $_fl_v, no feature report ($_fl_min or later reports every feature this skill reads); every step uses its older path" ;;
    *)
      _fl_miss='' _fl_need=''
      while read -r _fl_f _fl_r; do
        facts_has "$_fl_f" && continue
        _fl_miss="${_fl_miss:+$_fl_miss, }$_fl_f"
        _fl_need="${_fl_need}$_fl_r
"
      done <<EOF
$FACTS_NEEDS
EOF
      if [ -z "$_fl_miss" ]; then echo "mtf-facts: $_fl_v"
      else
        _fl_min="$(printf '%s' "$_fl_need" | awk '{ split(substr($1, 2), p, "."); k = p[1] * 1000000 + p[2] * 1000 + p[3]
          if (k > m) { m = k; v = $1 } } END { print v }')"
        case "$_fl_miss" in *,*) _fl_it=them ;; *) _fl_it=it ;; esac
        echo "mtf-facts: $_fl_v, missing $_fl_miss ($_fl_min or later reports $_fl_it); the steps that need it use their older path"
      fi ;;
  esac
}
