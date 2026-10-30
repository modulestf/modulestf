#!/usr/bin/env bash
# shellcheck disable=SC2016 # the perl programs below are single-quoted on purpose
# The default verification pass of terraform-module-pr-review, as one file. Rules and reasons:
# verify-pass.md. Runs the same under bash and zsh. Invoke it by an absolute path in the skill
# as installed, or in a host's own checkout pinned by commit; never from the head, the
# workspace or a copy the head could have written:
#
#   <bash|zsh> /abs/path/verify-pass.sh run <run-dir> --files <files.json> --base <sha> \
#       --out <out.json> [--prefix <module-root>] [--budget <seconds>] [--dir <example-dir>]...
#       terraform init -backend=false and terraform validate in each selected example
#       directory, the version bump skip, the records, the merge base re-run, each command
#       under its own time and output limit and the whole pass under one budget (1800
#       seconds unless --budget says otherwise). Writes the results as one JSON object to
#       <out.json>. --dir limits the pass to the named example directories, for a re-run
#       outside the sandbox (verify-pass.md, Commands).
#   <bash|zsh> /abs/path/verify-pass.sh select <run-dir> --files <files.json> [--prefix <module-root>]
#       Prints the example selection as one JSON object: how it was made, and the example
#       directories in order with their reasons (verify-pass.md, Example selection).
#   <bash|zsh> /abs/path/verify-pass.sh check <run-dir> --files <files.json> --base <sha> \
#       --head <sha> --results <results.json> [--prefix <module-root>]
#       Checks results a host produced: shape, the two SHAs, and the selection and example
#       directories against this run's own. Prints "results accepted" and exits 0, or prints
#       "results rejected: <reason>" and exits 1. Never runs terraform.
#   <bash|zsh> /abs/path/verify-pass.sh merge <run-dir> --results <inside.json> \
#       --outside <outside.json> --out <out.json>
#       Replaces each entry of the run inside the sandbox with the entry of the same
#       directory from the run outside it, marked "outside": true (verify-pass.md, Commands).
#   <bash|zsh> /abs/path/verify-pass.sh coverage <run-dir> --files <files.json> --out <out.json> \
#       [--prefix <module-root>] (--plan <record> [--addresses <dir>] | --hosted <plan-hosted.json> | --no-plan)
#       The plan coverage of the selection: per example the plan class, the base result and
#       the planned addresses, the class complete, partial or none, and the examples not
#       planned with a fixed reason (verify-pass.md, Plan coverage). Never runs terraform.
#
# <run-dir> is the absolute run directory Workspace printed, "<root>/pr-review.XXXXXX", holding
# the clone at <run-dir>/clone. Exit 2 is a usage error or a refused input; nothing is written.

CMD=${1:-}
RUN=${2:-}
die() { echo "verify-pass.sh: $1" >&2; exit 2; }
case "$CMD" in run|select|check|merge|coverage) ;; *) die "usage: verify-pass.sh run|select|check|merge|coverage <run-dir> ..." ;; esac
ROOT="${RUN%/*}"
case "$ROOT" in /?*) ;; *) die "the run directory must be absolute" ;; esac
case "$RUN" in "$ROOT"/pr-review.??????) ;; *) die "not a run directory: $RUN" ;; esac
DIR="$RUN/clone"
[ -d "$DIR" ] || die "no clone in $RUN"
CROOT="$(cd "$DIR" && pwd -P)"
shift 2

FILES=; BASESHA=; OUT=; PREFIX=; HEADSHA=; RESULTS=; ONLY=; OUTSIDE=; BUDGET=1800
PLANREC=; ADDRS=; HOSTED=; NOPLAN=
NL='
'
while [ $# -gt 0 ]; do
  if [ "$1" = --no-plan ]; then NOPLAN=1; shift; continue; fi
  case "$1" in
    --budget) BUDGET=${2:-} ;;
    --plan) PLANREC=${2:-} ;;
    --addresses) ADDRS=${2:-} ;;
    --hosted) HOSTED=${2:-} ;;
    --files) FILES=${2:-} ;;
    --base) BASESHA=${2:-} ;;
    --out) OUT=${2:-} ;;
    --prefix) PREFIX=${2:-} ;;
    --head) HEADSHA=${2:-} ;;
    --results) RESULTS=${2:-} ;;
    --dir) ONLY="$ONLY${2:-}$NL" ;;
    --outside) OUTSIDE=${2:-} ;;
    *) die "unknown argument: $1" ;;
  esac
  [ $# -ge 2 ] || die "$1 needs a value"
  shift 2
done

sha_ok() { # a full lowercase commit SHA, one line, nothing else
  [ "${#1}" -eq 40 ] || return 1
  case "$1" in *[!0-9a-f]*) return 1 ;; esac
  return 0
}

if [ "$CMD" = merge ]; then
  case "$OUT" in /?*) ;; *) die "--out must be an absolute path" ;; esac
  [ -f "$RESULTS" ] && [ -f "$OUTSIDE" ] || die "--results and --outside must name readable files"
  jq -e -n --slurpfile a "$RESULTS" --slurpfile b "$OUTSIDE" '
    ($a | length) == 1 and ($b | length) == 1 and ($a[0] | type) == "object" and ($b[0] | type) == "object"
    and $a[0].head_sha == $b[0].head_sha and $a[0].base_sha == $b[0].base_sha
    and ($b[0].dirs | type) == "array" and ($b[0].dirs | length) > 0
    and all($b[0].dirs[]; .dir as $d | .outside == false
      and any($a[0].dirs[]; .dir == $d and .outside == false
        and (.head.record == "not-run-environment" or .base.record == "not-run-environment")))
  ' > /dev/null 2>&1 || die "the two results do not pair: same head and base, and each outside entry one that ended not-run-environment inside"
  if ! { jq -n --slurpfile a "$RESULTS" --slurpfile b "$OUTSIDE" '
    $a[0] as $in | $b[0] as $out
    | $in + {terraform_version: ($in.terraform_version // $out.terraform_version),
             dirs: [$in.dirs[] | .dir as $d
                    | (first($out.dirs[] | select(.dir == $d) | . + {outside: true}) // .)]}
  ' > "$OUT.tmp" && mv -- "$OUT.tmp" "$OUT"; }; then die "cannot write $OUT"; fi
  exit 0
fi

case "$CMD" in run|check) sha_ok "$BASESHA" || die "--base must be a full commit SHA" ;; esac
[ -f "$FILES" ] || die "--files must name a readable file"
PREFIX="${PREFIX%/}"
case "$PREFIX" in /*|*..*|.) die "--prefix must be repository-relative" ;; esac
[ -n "$PREFIX" ] && PREFIX="$PREFIX/"
MROOT="$CROOT${PREFIX:+/${PREFIX%/}}"
printf '%s\n' "$BUDGET" | grep -Eqx '[1-9][0-9]{0,4}' || die "--budget must be a number of seconds, 1 to 99999"

# Work files: run uses $RUN/verify, the read-only commands a directory of their own, so a
# check or a coverage run never removes a pass's files.
case "$CMD" in run) W="$RUN/verify" ;; *) W="$RUN/verify-$CMD" ;; esac
if ! { rm -rf -- "$W" && mkdir -m 700 "$W"; }; then die "cannot create $W"; fi
PGIDS=""
stop_all() { # kill every process group this pass started, then remove the work files
  for g in $(printf '%s\n' "$PGIDS"); do kill -KILL -- "-$g" 2> /dev/null; done
  wait 2> /dev/null
  rm -rf -- "$W"
}
trap stop_all EXIT
trap 'stop_all; exit 130' INT TERM

# One command in its own process group, from a directory, under a time limit and a 1 MiB
# output cap: either kill takes the whole group and leaves <out>.cap, and run_capped then
# returns 124. With CAP_QUIET_ERR set, standard error is dropped instead of kept.
CAP_PL='
setpgrp(0, 0); my ($out, $dir, $lim) = splice(@ARGV, 0, 3);
my $stop = sub { open(my $m, ">", "$out.cap"); close $m; kill "KILL", -getpgrp() };
$SIG{ALRM} = $stop; alarm($lim > 0 ? $lim : 1);
chdir $dir or exit 125;
open(my $o, ">", $out) or exit 125;
my $pid = open(my $in, "-|"); exit 125 unless defined $pid;
if (!$pid) {
  if ($ENV{CAP_QUIET_ERR}) { open(STDERR, ">", "/dev/null") } else { open(STDERR, ">&", \*STDOUT) }
  open(STDIN, "<", "/dev/null"); exec @ARGV; exit 127;
}
my ($n, $buf) = (0, "");
while (my $r = sysread($in, $buf, 65536)) {
  if ($n + $r >= 1048576) { syswrite($o, $buf, 1048576 - $n); close $o; $stop->() }
  syswrite($o, $buf); $n += $r;
}
close $in; exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
'
run_capped() { # seconds, output file, directory, then the command
  rlim=$1; rout=$2; rdir=$3; shift 3
  rm -f -- "$rout.cap"
  perl -e "$CAP_PL" "$rout" "$rdir" "$rlim" "$@" < /dev/null &
  rpid=$!; PGIDS="$PGIDS $rpid"
  wait "$rpid"; rrc=$?
  [ -e "$rout.cap" ] && return 124
  return "$rrc"
}

# The selected example directories, one line each: "<reason><TAB><affected><TAB><dir>", in
# the order of the selection file, whose lines are "<affected><TAB><dir>". Exit 3: not an
# array of file objects. Exit 4: a path holds a control character.
DIRS_PL='
use strict; use warnings; use JSON::PP; use Cwd qw(realpath);
my ($files, $root, $pre, $sel) = @ARGV; $pre //= "";
my $d = do { local $/; open my $fh, "<", $files or exit 3; eval { decode_json(<$fh>) } };
exit 3 unless ref $d eq "ARRAY";
for my $f (@$d) {
  exit 3 unless ref $f eq "HASH";
  for my $k (qw(filename status)) { exit 3 unless defined $f->{$k} && !ref $f->{$k} }
  exit 3 if defined $f->{previous_filename} && ref $f->{previous_filename};
  exit 3 if defined $f->{patch} && ref $f->{patch};
  for my $k (qw(filename previous_filename)) { exit 4 if defined $f->{$k} && $f->{$k} =~ /[\x00-\x1f\x7f]/ }
}
sub lower { # the major of the highest lower bound of a constraint, or undef
  my @hi;
  for my $p (split /,/, shift, -1) {
    $p =~ s/\A\s+|\s+\z//g;
    return undef unless $p =~ /\A(>=|>|~>|=|<=|<|!=)?\s*v?([0-9]+(?:\.[0-9]+)*)(?:-[0-9A-Za-z.-]+)?\z/;
    my ($op, $v) = ($1 // "", $2);
    next if $op eq "<=" || $op eq "<" || $op eq "!=";
    my @v = split /\./, $v;
    my $gt = 0;
    for my $i (0 .. ($#v > $#hi ? $#v : $#hi)) {
      my ($a, $b) = ($v[$i] // 0, $hi[$i] // 0);
      if ($a != $b) { $gt = $a > $b; last }
    }
    @hi = @v if !@hi || $gt;
  }
  return @hi ? $hi[0] + 0 : undef;
}
sub lines { # the added and removed lines of a patch, per hunk: [[removed], [added]], ...
  my @h;
  for (split /\n/, shift) {
    if (/\A@@/) { push @h, [[], []]; next }
    return undef unless @h;
    if (/\A-(.*)\z/s) { push @{$h[-1][0]}, $1 } elsif (/\A\+(.*)\z/s) { push @{$h[-1][1]}, $1 }
  }
  return \@h;
}
sub trim { my $s = shift; $s =~ s/\A\s+|\s+\z//g; $s }
sub vpatch {
  my $h = lines(shift) or return 0;
  for my $k (@$h) {
    my ($r, $a) = @$k;
    return 0 unless @$r == @$a;
    for my $i (0 .. $#$r) {
      my ($o, $n) = map { trim($_) } $r->[$i], $a->[$i];
      return 0 unless $o =~ /\A(required_version|version)\s*=\s*"([^"]*)"\z/;
      my ($ko, $co) = ($1, $2);
      return 0 unless $n =~ /\A(required_version|version)\s*=\s*"([^"]*)"\z/;
      my ($kn, $cn) = ($1, $2);
      return 0 unless $ko eq $kn;
      my ($mo, $mn) = (lower($co), lower($cn));
      return 0 unless defined $mo && defined $mn && $mo == $mn;
    }
  }
  return 1;
}
sub rpatch {
  my $h = lines(shift) or return 0;
  for my $k (@$h) { for (@{$k->[0]}, @{$k->[1]}) { my $t = trim($_); return 0 unless $t =~ /\A\|.*\|\z/ || $t eq "|" } }
  return 1;
}
sub bump {
  my $dir = shift; my $n = 0;
  for my $f (@$d) {
    next unless grep { defined && index($_, "$dir/") == 0 } $f->{filename}, $f->{previous_filename};
    $n++;
    return 0 unless $f->{status} eq "modified" && defined $f->{patch};
    if ($f->{filename} eq "$dir/versions.tf") { return 0 unless vpatch($f->{patch}) }
    elsif ($f->{filename} eq "$dir/README.md") { return 0 unless rpatch($f->{patch}) }
    else { return 0 }
  }
  return $n > 0;
}
open my $sh, "<", $sel or exit 3;
while (my $l = <$sh>) {
  chomp $l; my ($aff, $dir) = split /\t/, $l, 2;
  my $abs = "$root/$dir";
  next unless -e $abs || -l $abs;
  my $r = realpath($abs);
  unless (defined $r && $r eq $abs) { print "skipped-symlink\t$aff\t$dir\n"; next }
  next unless -d $abs;
  opendir my $dh, $abs or next;
  my @tf = grep { /\.tf\z/ && -f "$abs/$_" } readdir $dh;
  next unless @tf;
  print bump($dir) ? "skipped-version-bump" : "verified", "\t$aff\t$dir\n";
}
'

# Every example directory of the module root, one line each: "real<TAB><dir>" for a directory
# holding a .tf file directly, "link<TAB><dir>" for a symbolic link to a directory, in byte
# order. Exit 4: a name outside [A-Za-z0-9._-].
ALL_PL='
use strict; use warnings;
my ($root, $pre) = @ARGV; my $ex = "$root/${pre}examples";
opendir my $dh, $ex or exit 0;
for my $n (sort grep { $_ ne "." && $_ ne ".." } readdir $dh) {
  my $p = "$ex/$n"; my $kind;
  if (-l $p) { next unless -d $p; $kind = "link" }
  else {
    next unless -d $p;
    opendir my $d2, $p or next;
    next unless grep { /\.tf\z/ && -f "$p/$_" } readdir $d2;
    $kind = "real";
  }
  exit 4 unless $n =~ /\A[A-Za-z0-9._-]+\z/;
  print "$kind\t${pre}examples/$n\n";
}
'

# The hosts named by a module or provider source on a line the change adds to a .tf file,
# lowercased, one per line.
HOSTS_PL='
use strict; use warnings; use JSON::PP;
my $d = do { local $/; open my $fh, "<", shift or exit 3; eval { decode_json(<$fh>) } };
exit 3 unless ref $d eq "ARRAY";
my %h;
for my $f (@$d) {
  next unless $f->{filename} =~ /\.tf\z/ && defined $f->{patch};
  for (split /\n/, $f->{patch}) {
    next unless /\A\+.*\bsource\s*=\s*"([^"]+)"/;
    my $s = lc $1;
    next if $s =~ m{\A\.\.?/};
    $s =~ s/\A[a-z0-9]+:://;
    my $host;
    if ($s =~ m{\A[a-z][a-z0-9+.-]*://(?:[^@/]*@)?([^/:?#]+)}) { $host = $1 }
    elsif ($s =~ m{\A[^@/]+@([^:/]+):}) { $host = $1 }
    else {
      my @seg = split m{/}, $s;
      $host = ($seg[0] =~ /\./) ? $seg[0] : "registry.terraform.io";
    }
    $h{$host} = 1 if defined $host && length $host;
  }
}
print "$_\n" for sort keys %h;
'

# Classifies the output of one failed command. Prints the class, "environment" or "code", on
# the first line and the decisive error line on the second. Arguments: the output file, the
# hosts file, and 1 when a marker appears in the tree'"'"'s own files, else 0.
CLASS_PL='
use strict; use warnings;
my ($outf, $hostf, $infiles) = @ARGV;
my $text = do { local $/; open my $fh, "<", $outf or die; <$fh> } // "";
my @hosts = do { open my $fh, "<", $hostf or die; map { chomp; $_ } grep { /\S/ } <$fh> };
my @markers = ("failed to instantiate provider", "unrecognized remote plugin message",
  "plugin exited before we could connect", "operation not permitted", "dial tcp", "no such host",
  "tls handshake timeout");
my %net = map { ($_ => 1) } ("dial tcp", "no such host", "tls handshake timeout");
my (@diag, $cur);
for my $l (split /\n/, $text) {
  $l =~ s/\r\z//;
  if ($l =~ /\A\s*(Error|Warning):/) { $cur = { kind => $1, lines => [$l] }; push @diag, $cur; next }
  push @{$cur->{lines}}, $l if $cur;
}
my $env = 0;
unless ($infiles) {
  for my $g (grep { $_->{kind} eq "Error" } @diag) {
    next if grep { /\A\s*on .+ line [0-9]+/ } @{$g->{lines}};
    my $t = lc join "\n", @{$g->{lines}};
    for my $m (@markers) {
      next unless index($t, $m) >= 0;
      next if $net{$m} && grep { index($t, $_) >= 0 } @hosts;
      $env = 1;
    }
  }
}
my ($line) = grep { /\A\s*Error:/ } split /\n/, $text;
($line) = reverse grep { /\S/ } split /\n/, $text unless defined $line;
$line //= "";
$line =~ s/\A\s+|\s+\z//g;
$line =~ s/[^\x20-\x7e]/?/g;
$line = substr($line, 0, 300);
print $env ? "environment" : "code", "\n", $line, "\n";
'

# The example selection (verify-pass.md, Example selection). mtf-facts is resolved from a
# working directory outside the workspace, as the reviewer's facts-engine.md resolves it, and
# a path inside the clone or the run directory counts as no binary. Writes $W/sel.tsv,
# "<affected><TAB><dir>" per selected example in order, and $W/selection.json.
facts_bin() {
  fb="$(cd / && command -v mtf-facts 2> /dev/null)" || return 1
  case "$fb" in /*) ;; *) return 1 ;; esac
  fb="$(cd / && perl -MCwd=realpath -e 'my $r = realpath($ARGV[0]); print $r if defined $r' "$fb")"
  [ -n "$fb" ] && [ -f "$fb" ] && [ -x "$fb" ] || return 1
  case "$fb/" in "$CROOT"/*|"$(cd "$RUN" && pwd -P)"/*) return 1 ;; esac
  printf '%s\n' "$fb"
}
# shellcheck disable=SC2016 # a jq program
AFFECTED_JQ='
def name_ok: type == "string" and test("^examples/[A-Za-z0-9._-]+$") and (test("^examples/[.][.]?$") | not);
($all | map(.dir)) as $dirs | ($all | map(select(.kind == "real") | .dir)) as $real
| type == "object" and .schema_version == 1 and (.inert | type == "boolean")
  and (.fallback == null or (.fallback | IN("unparsed", "dynamic-source", "no-change-input")))
  and (.inert == false or .fallback == null)
  and (.changed | type == "array" and all(.[]; type == "string"))
  and (.examples | type == "array" and all(.[]; type == "object" and (.dir | name_ok)
        and (.reason | IN("touched", "caller", "all"))))
  and (.fallback == null or all(.examples[]; .reason == "all"))
  and ([.examples[].dir] | length == (unique | length))
  and all(.examples[]; .dir as $d | $dirs | index([$pre + $d]) != null)
  and all($real[]; . as $d | any($in.examples[]; $pre + .dir == $d))
'
select_examples() {
  perl -e "$ALL_PL" "$CROOT" "$PREFIX" > "$W/all.tsv" || die "an example directory name outside [A-Za-z0-9._-]"
  TAB="$(printf '\t')"
  while IFS="$TAB" read -r kind rel; do jq -cn --arg k "$kind" --arg d "$rel" '{kind:$k, dir:$d}'; done < "$W/all.tsv" \
    | jq -s . > "$W/all.json"
  tool=absent
  if fb="$(facts_bin)"; then
    tool=failed
    if [ -n "$PREFIX" ]; then
      jq --arg p "$PREFIX" '[.[] | select((.filename | startswith($p)) or ((.previous_filename // "") | startswith($p)))
        | .filename |= ltrimstr($p) | if .previous_filename then .previous_filename |= ltrimstr($p) else . end]' \
        "$FILES" > "$W/affected-files.json" 2> /dev/null || die "--files is not a JSON array of file objects"
    else
      cp -- "$FILES" "$W/affected-files.json"
    fi
    if CAP_QUIET_ERR=1 run_capped 70 "$W/affected.json" / "$fb" affected "$MROOT" --diff "$W/affected-files.json" --json \
      && jq -e . "$W/affected.json" > /dev/null 2>&1; then
      tool=invalid
      jq -e --slurpfile all "$W/all.json" --arg pre "$PREFIX" '. as $in | $all[0] as $all | '"$AFFECTED_JQ" \
        "$W/affected.json" > /dev/null 2>&1 && tool=mtf-facts
    fi
  fi
  if [ "$tool" = mtf-facts ]; then
    # The tool's order, then any linked example it left out. An inert change keeps the whole
    # list: inert comes from the change, so it never empties what is verified and planned.
    jq -r --slurpfile all "$W/all.json" --arg pre "$PREFIX" '
      [.examples[] | $pre + .dir] as $t
      | (.examples[] | "\(.reason)\t\($pre)\(.dir)"),
        ($all[0][] | select(.kind == "link") | .dir as $d | select(($t | index($d)) == null) | "all\t\($d)")
      ' "$W/affected.json" > "$W/sel.tsv"
    jq -c '{tool: "mtf-facts", fallback, inert}' "$W/affected.json" > "$W/selection.json"
  else
    awk -F '\t' '{ print "all\t" $2 }' "$W/all.tsv" > "$W/sel.tsv"
    jq -cn --arg t "$tool" '{tool: $t, fallback: null, inert: false}' > "$W/selection.json"
  fi
}
dirs_list() { # the selected example directories, their reasons and affected reasons, into the named file
  select_examples
  perl -e "$DIRS_PL" "$FILES" "$CROOT" "$PREFIX" "$W/sel.tsv" > "$1"
  case $? in
    0) ;;
    4) die "a changed path holds a control character" ;;
    *) die "--files is not a JSON array of file objects" ;;
  esac
}
dirs_jsonl() { # list.tsv -> one {dir, reason, affected} per line
  TAB="$(printf '\t')"
  while IFS="$TAB" read -r reason aff rel; do
    jq -cn --arg dir "$rel" --arg reason "$reason" --arg aff "$aff" '{dir:$dir, reason:$reason, affected:$aff}'
  done < "$1"
}

if [ "$CMD" = select ]; then
  dirs_list "$W/list.tsv"
  dirs_jsonl "$W/list.tsv" | jq -s --slurpfile s "$W/selection.json" '{selection: $s[0], dirs: .}'
  exit 0
fi

if [ "$CMD" = check ]; then
  [ -f "$RESULTS" ] || die "--results must name a readable file"
  sha_ok "$HEADSHA" || die "--head must be a full commit SHA"
  dirs_list "$W/list.tsv"
  dirs_jsonl "$W/list.tsv" > "$W/list.jsonl"
  reject() { echo "results rejected: $1"; exit 1; }
  jq -e . "$RESULTS" > /dev/null 2>&1 || reject "not JSON"
  jq -e 'type == "object" and keys == ["base_sha","dirs","head_sha","selection","terraform_version"]' \
    "$RESULTS" > /dev/null 2>&1 || reject "shape"
  jq -e --arg h "$HEADSHA" '.head_sha == $h' "$RESULTS" > /dev/null 2>&1 || reject "head_sha"
  jq -e --arg b "$BASESHA" '.base_sha == $b' "$RESULTS" > /dev/null 2>&1 || reject "base_sha"
  jq -e '
    def num: . == null or (type == "number" and . == floor and . >= 0 and . <= 255);
    def line: . == null or (type == "string" and length <= 300 and test("^[ -~]*$"));
    def side($recs): type == "object" and keys == ["init","line","record","validate"]
      and (.init | num) and (.validate | num) and (.line | line)
      and (.record | type == "string") and (.record as $r | $recs | any(.[]; . == $r));
    def limited: (.record == "not-run-limit" or .record == "not-run-budget")
      and .line == null and (.validate == null or .init == 0);
    def head_ok: side(["code-result","init-failed","not-run-budget","not-run-environment","not-run-limit","terraform-absent"])
      and (if .record == "terraform-absent" then .init == null and .validate == null and .line == null
           elif .record == "init-failed" then .init != null and .init != 0 and .validate == null
           elif .record == "code-result" then .init == 0 and .validate != null
           elif .record == "not-run-environment" then .init != null
           else limited end);
    def base_ok: side(["absent-at-base","base-unavailable","code-result","init-failed","not-run-budget","not-run-environment","not-run-limit"])
      and (if (.record == "absent-at-base" or .record == "base-unavailable")
           then .init == null and .validate == null and .line == null
           elif .record == "not-run-limit" or .record == "not-run-budget" then limited
           else .init != null end);
    (.terraform_version == null or (.terraform_version | type == "string" and test("^[0-9]+[.][0-9]+[.][0-9]+[0-9A-Za-z.+-]*$")))
    and (.dirs | type == "array")
    and all(.dirs[]; type == "object" and keys == ["affected","base","dir","head","outside","reason"]
      and (.dir | type == "string") and .outside == false
      and (if .reason == "skipped-version-bump" or .reason == "skipped-symlink" then .head == null and .base == null
           elif .reason == "verified" then (.head | head_ok)
             and (if .head.record == "code-result" and .head.validate != 0
                  then (.base | base_ok) else .base == null end)
           else false end))
  ' "$RESULTS" > /dev/null 2>&1 || reject "shape"
  jq -e --slurpfile l "$W/list.jsonl" --slurpfile s "$W/selection.json" \
    '[.dirs[] | {dir, reason, affected}] == $l and .selection == $s[0]' "$RESULTS" > /dev/null 2>&1 \
    || reject "example directories"
  echo "results accepted"
  exit 0
fi

case "$OUT" in /?*) ;; *) die "--out must be an absolute path" ;; esac
[ -d "${OUT%/*}/" ] || die "the directory of --out must exist"

if [ "$CMD" = coverage ]; then
  n=0; [ -n "$PLANREC" ] && n=$((n + 1)); [ -n "$HOSTED" ] && n=$((n + 1)); [ -n "$NOPLAN" ] && n=$((n + 1))
  [ "$n" -eq 1 ] || die "coverage needs exactly one of --plan, --hosted and --no-plan"
  [ -z "$ADDRS" ] || [ -n "$PLANREC" ] || die "--addresses goes with --plan"
  dirs_list "$W/list.tsv"
  dirs_jsonl "$W/list.tsv" > "$W/list.jsonl"
  # The plan results as blocks {n, dir, plan, base}: a laptop record keyed by its example:
  # lines in order, a runner record by the host's own "host example <n>:" lines, so a block
  # the head's code printed cannot claim another example.
  # shellcheck disable=SC2016 # jq programs
  NORM='
def classes: ["planned", "planned-no-changes", "code-error", "environment", "needs input",
  "output unrecognised", "budget", "plan pass ended: credentials", "plan gate G0", "plan gate G1",
  "plan gate G2", "plan gate G3", "exception: example assumes a role in another account",
  "exception: needs a Docker daemon"];
def base_results: ["reproduces at base", "new under this change",
  "new under this change (absent at base)", "not available"];
def gate: if test("^plan gate G[0-3]( |$)") then .[0:12] else . end;
def norm: gate | if IN(classes[]) then . else "output unrecognised" end;
def bnorm: gate | if IN(classes[]) or IN(base_results[]) then . else "not available" end;
'
  if [ -n "$NOPLAN" ]; then
    echo '[]' > "$W/blocks.json"
  elif [ -n "$PLANREC" ]; then
    [ -f "$PLANREC" ] && [ ! -L "$PLANREC" ] && [ "$(wc -c < "$PLANREC")" -le 5242880 ] \
      || die "--plan must name a regular file of at most 5 MiB"
    jq -R -s "$NORM"'
      split("\n") as $l
      | any($l[]; startswith("host example ")) as $runner
      | reduce $l[] as $x ({b: [], n: 0};
          if $runner and ($x | startswith("host example ")) then
            (($x | capture("^host example (?<n>[1-9][0-9]{0,5}): (?<p>.*)$")) // null) as $h
            | if $h == null then . else .b += [{n: ($h.n | tonumber), dir: $h.p, plan: null, base: null}] end
          elif ($runner | not) and ($x | startswith("example: ")) then
            .n += 1 | .b += [{n: .n, dir: $x[9:], plan: null, base: null}]
          elif (.b | length) == 0 then .
          elif ($x | startswith("plan: ")) and .b[-1].plan == null then .b[-1].plan = ($x[6:] | split(" | ")[0] | norm)
          elif ($x | startswith("base: ")) and .b[-1].base == null then .b[-1].base = ($x[6:] | bnorm)
          else . end)
      | .b' "$PLANREC" > "$W/blocks.json" || die "--plan cannot be read"
  else
    [ -f "$HOSTED" ] && [ ! -L "$HOSTED" ] && [ "$(wc -c < "$HOSTED")" -le 1048576 ] \
      || die "--hosted must name a regular file of at most 1 MiB"
    jq "$NORM"'
      if type == "object" and (.examples | type == "array") then
        [.examples | to_entries[] | .key as $k | .value
         | select(type == "object" and (.path | type == "string"))
         | {n: ($k + 1), dir: .path, plan: (.head.class | if type == "string" then norm else "output unrecognised" end),
            base: (.base.class? // null | if type == "string" then bnorm else null end),
            addr: {addresses: .addresses, attributes: .attributes}}]
      else error("not a plan record") end' "$HOSTED" > "$W/blocks.json" 2> /dev/null || die "--hosted is not a plan record"
  fi
  # The planned addresses of each block, from addresses-<n>.json in --addresses: data only
  : > "$W/addr.jsonl"
  if [ -n "$ADDRS" ] && [ -d "$ADDRS" ] && [ ! -L "$ADDRS" ]; then
    for af in "$ADDRS"/addresses-*.json; do
      an="${af##*/addresses-}"; an="${an%.json}"
      printf '%s\n' "$an" | grep -Eqx '[1-9][0-9]{0,5}' || continue
      [ -f "$af" ] && [ ! -L "$af" ] && [ "$(wc -c < "$af")" -le 1048576 ] || continue
      jq -c --arg n "$an" '{($n): .}' "$af" >> "$W/addr.jsonl" 2> /dev/null || true
    done
  fi
  jq -n --slurpfile b "$W/blocks.json" --slurpfile l "$W/list.jsonl" --slurpfile s "$W/selection.json" \
    --slurpfile a "$W/addr.jsonl" --arg noplan "${NOPLAN:-}" --arg pre "$PREFIX" '
    ($a | add // {}) as $addr
    | def clean: . as $x
        | [($x.addresses | if type == "array" then .[] else empty end)
           | select(type == "string" and test("^[A-Za-z0-9_.-]{1,300}$"))] | unique | .[:1000]
        | . as $s
        | {addresses: $s,
           attributes: (($x.attributes | if type == "object" then . else {} end)
             | with_entries(select(.key as $k | ($s | index($k)) != null)
                 | .value |= ([(if type == "array" then .[] else empty end)
                               | select(type == "string" and test("^[a-z0-9_]{1,128}$"))] | unique | .[:500]))),
           module_calls: ($x.module_calls | if type == "object" then with_entries(select((.key | test("^[A-Za-z0-9_-]{1,64}$"))
                        and (.value | type == "string" and test("^[.][.]?(/[A-Za-z0-9_.-]+)*/?$")))) else {} end)};
    # A local module source resolved against the example directory, repository-relative, or
    # null when it climbs out of the repository
    def resolve($d): ($d + "/" + .) | split("/")
      | reduce .[] as $p ([]; if . == null then null elif $p == "" or $p == "." then .
          elif $p == ".." then (if length == 0 then null else .[:-1] end) else . + [$p] end)
      | if . == null then null elif length == 0 then "." else join("/") end;
    def planned: IN("planned", "planned-no-changes");
    [ $l[] | .dir as $d
      | (first($b[0][] | select(.dir == $d)) // null) as $k
      | (if $k == null or $k.plan == null then "not run" else $k.plan end) as $h
      | (if $k == null then null else $k.base end) as $bs
      | ((if $h | planned then ($k.addr // $addr[$k.n | tostring] // {}) | clean
          else {addresses: [], attributes: {}, module_calls: {}} end)) as $ad
      | {dir: $d, head: $h, base: $bs, addresses: $ad.addresses, attributes: $ad.attributes,
         module_calls: ($ad.module_calls | with_entries(.value |= resolve($d)) | with_entries(select(.value != null))),
         covered: (($h | planned) or ($h == "code-error"
           and ($bs | IN("reproduces at base", "new under this change", "new under this change (absent at base)")))),
         why: (if $noplan != "" then "no AWS profile named" elif $h == "not run" then "not reached by the plan pass"
               elif $h == "code-error" then "code-error, merge base not planned" else $h end)} ] as $e
    | ($e | map(select(.covered)) | length) as $c
    # No example at all is complete only for an inert change; otherwise nothing could be planned
    | (($e | length) == 0 and ($s[0].inert | not)) as $none
    | {schema_version: 1, selection: $s[0], inert: $s[0].inert,
       class: (if $none then "none" elif $c == ($e | length) then "complete" elif $c == 0 then "none" else "partial" end),
       examples: [$e[] | {dir, head, base, addresses, attributes, module_calls}],
       unplanned: (if $none then [{dir: ($pre + "examples"), reason: "no example directory"}]
                   else [$e[] | select(.covered | not) | {dir, reason: .why}] end)}
  ' > "$OUT.tmp" && mv -- "$OUT.tmp" "$OUT" || die "cannot write $OUT"
  exit 0
fi

HEAD="$(git -C "$DIR" rev-parse HEAD 2> /dev/null)"
sha_ok "$HEAD" || die "the clone has no head commit"
dirs_list "$W/list.tsv"
if [ -n "$ONLY" ]; then
  printf '%s' "$ONLY" | while IFS= read -r rel; do
    cut -f3 "$W/list.tsv" | grep -qxF -- "$rel" || { echo "verify-pass.sh: not an example directory of this change: $rel" >&2; exit 2; }
  done || exit 2
fi
perl -e "$HOSTS_PL" "$FILES" > "$W/hosts.txt" || die "--files is not a JSON array of file objects"
mkdir -p "$RUN/plugin-cache"

mkdir "$W/home"
env | sed -n 's/^\(TF_TOKEN_[A-Za-z0-9_]*\)=.*/\1/p' > "$W/tokens.txt"
# terraform with no credential and no inherited terraform settings
TFENV=(env)
while IFS= read -r v; do TFENV+=(-u "$v"); done < "$W/tokens.txt"
TFENV+=(-u AWS_PROFILE -u AWS_DEFAULT_PROFILE -u AWS_ACCESS_KEY_ID
  -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_SECURITY_TOKEN -u AWS_ROLE_ARN
  -u AWS_WEB_IDENTITY_TOKEN_FILE -u AWS_CONTAINER_CREDENTIALS_FULL_URI
  -u AWS_CONTAINER_CREDENTIALS_RELATIVE_URI -u AWS_CONTAINER_AUTHORIZATION_TOKEN
  -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN
  -u SSH_AUTH_SOCK -u SSH_ASKPASS -u GIT_ASKPASS -u GIT_SSH -u GIT_SSH_COMMAND
  -u TF_CLI_ARGS -u TF_CLI_ARGS_init -u TF_CLI_ARGS_validate -u TF_DATA_DIR -u TF_WORKSPACE
  -u CAP_QUIET_ERR
  HOME="$W/home" NETRC=/dev/null TF_CLI_CONFIG_FILE=/dev/null
  AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true
  TF_PLUGIN_CACHE_DIR="$RUN/plugin-cache" TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=true
  TF_IN_AUTOMATION=1 TF_INPUT=0 CHECKPOINT_DISABLE=1 GIT_TERMINAL_PROMPT=0
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_COUNT=2
  GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
  GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1=
  terraform)
T0=$SECONDS
left() { echo $((BUDGET - (SECONDS - T0))); }
LIMBUDGET=0
tf() { # seconds, directory, arguments: one terraform command into $W/out.txt, under the budget
  tl=$1; td=$2; shift 2
  bl=$(left); LIMBUDGET=0
  if [ "$bl" -lt "$tl" ]; then tl=$bl; LIMBUDGET=1; fi
  [ "$tl" -ge 1 ] || tl=1 # alarm 0 would mean no limit at all
  run_capped "$tl" "$W/out.txt" "$td" "${TFENV[@]}" "$@"
}
side() { # init validate record line: one JSON object
  jq -cn --argjson init "${1:-null}" --argjson validate "${2:-null}" --arg record "$3" --arg line "$4" \
    '{init:$init, validate:$validate, record:$record, line:(if $line == "" then null else $line end)}'
}
marked() { # tree root: true when a marker appears in its own files
  grep -rqiF --exclude-dir=.git --exclude-dir=.terraform \
    -e 'failed to instantiate provider' -e 'Unrecognized remote plugin message' \
    -e 'plugin exited before we could connect' -e 'operation not permitted' -e 'dial tcp' \
    -e 'no such host' -e 'TLS handshake timeout' -- "$1" 2> /dev/null
}
classify() { # output file, tree root: sets CLASS and LINE
  flag=0
  marked "$2" && flag=1
  perl -e "$CLASS_PL" "$1" "$W/hosts.txt" "$flag" > "$W/class.txt"
  CLASS="$(sed -n 1p "$W/class.txt")"; LINE="$(sed -n 2p "$W/class.txt")"
}
limited() { # a command the budget, its time limit or the output cap stopped: the record
  if [ "$LIMBUDGET" = 1 ] || [ "$(left)" -le 0 ]; then echo not-run-budget; else echo not-run-limit; fi
}
verify() { # tree root, module root, example directory: sets SIDEJ to one side object
  INIT=; VALID=; LINE=
  if [ "$(left)" -le 0 ]; then SIDEJ="$(side "" "" not-run-budget "")"; return; fi
  tf 180 "$1/$3" init -backend=false -input=false -no-color
  INIT=$?
  if [ "$INIT" -eq 124 ] && [ -e "$W/out.txt.cap" ]; then SIDEJ="$(side "$INIT" "" "$(limited)" "")"; return; fi
  if [ "$INIT" -ne 0 ]; then
    classify "$W/out.txt" "$2"
    if [ "$CLASS" = environment ]; then SIDEJ="$(side "$INIT" "" not-run-environment "$LINE")"
    else SIDEJ="$(side "$INIT" "" init-failed "$LINE")"; fi
    return
  fi
  if [ "$(left)" -le 0 ]; then SIDEJ="$(side 0 "" not-run-budget "")"; return; fi
  tf 60 "$1/$3" validate -no-color
  VALID=$?
  if [ "$VALID" -eq 124 ] && [ -e "$W/out.txt.cap" ]; then SIDEJ="$(side 0 "" "$(limited)" "")"; return; fi
  [ "$VALID" -eq 0 ] && { SIDEJ="$(side 0 0 code-result "")"; return; }
  classify "$W/out.txt" "$2"
  if [ "$CLASS" = environment ]; then SIDEJ="$(side 0 "$VALID" not-run-environment "$LINE")"
  else SIDEJ="$(side 0 "$VALID" code-result "$LINE")"; fi
}
BTREE="$RUN/verify-base"
BASEFAIL=
base_git() { # git arguments: one git command in the clone, with the Workspace options, under what is left of the budget
  bl=$(left); [ "$bl" -gt 0 ] || return 1
  run_capped "$bl" "$W/git.txt" / env GIT_LFS_SKIP_SMUDGE=1 git -C "$DIR" -c core.hooksPath=/dev/null \
    -c filter.lfs.smudge=cat -c filter.lfs.process= -c filter.lfs.required=false "$@"
}
base_ready() { # the merge base worktree for a re-run, added once; a fetch or add the budget stops fails
  [ -z "$BASEFAIL" ] || return 1
  [ -d "$BTREE" ] && return 0
  if ! git -C "$DIR" cat-file -e "${BASESHA}^{commit}" 2> /dev/null; then
    base_git fetch -q --depth=1 -- origin "$BASESHA" || { BASEFAIL=1; return 1; }
  fi
  base_git worktree add -q --detach -- "$BTREE" "$BASESHA" || { BASEFAIL=1; return 1; }
}

TFV=
if command -v terraform > /dev/null 2>&1; then
  mkdir "$W/empty"
  CAP_QUIET_ERR=1 tf 30 "$W/empty" version -json
  TFV="$(jq -r '.terraform_version // empty' "$W/out.txt" 2> /dev/null)"
  printf '%s\n' "$TFV" | grep -Eqx '[0-9]+[.][0-9]+[.][0-9]+[0-9A-Za-z.+-]*' || TFV=
  HAVE_TF=1
else
  HAVE_TF=0
fi

TAB="$(printf '\t')"
: > "$W/dirs.jsonl"
while IFS="$TAB" read -r reason aff rel; do
  if [ -n "$ONLY" ]; then printf '%s' "$ONLY" | grep -qxF -- "$rel" || continue; fi
  if [ "$reason" != verified ]; then
    jq -cn --arg dir "$rel" --arg reason "$reason" --arg aff "$aff" \
      '{dir:$dir, reason:$reason, affected:$aff, head:null, base:null, outside:false}' >> "$W/dirs.jsonl"
    continue
  fi
  BASEJ=null
  if [ "$HAVE_TF" = 0 ]; then
    HEADJ="$(side "" "" terraform-absent "")"
  else
    verify "$CROOT" "$MROOT" "$rel"; HEADJ=$SIDEJ
    if [ "$(printf '%s' "$HEADJ" | jq -r 'select(.record == "code-result" and .validate != 0) | "rerun"')" = rerun ]; then
      if ! base_ready; then
        BASEJ="$(side "" "" base-unavailable "")"
      elif ! git -C "$DIR" cat-file -e "${BASESHA}:$rel" 2> /dev/null; then
        BASEJ="$(side "" "" absent-at-base "")"
      else
        BROOT="$(cd "$BTREE" && pwd -P)"
        if [ "$(cd "$BROOT/$rel" 2> /dev/null && pwd -P)" = "$BROOT/$rel" ]; then
          verify "$BROOT" "$BROOT/${PREFIX%/}" "$rel"; BASEJ=$SIDEJ
        else # a symbolic link, or reached through one, at the base: never entered
          BASEJ="$(side "" "" base-unavailable "")"
        fi
      fi
    fi
  fi
  jq -cn --arg dir "$rel" --arg aff "$aff" --argjson head "$HEADJ" --argjson base "$BASEJ" \
    '{dir:$dir, reason:"verified", affected:$aff, head:$head, base:$base, outside:false}' >> "$W/dirs.jsonl"
done < "$W/list.tsv"

if ! { jq -n --arg head "$HEAD" --arg base "$BASESHA" --arg ver "$TFV" --slurpfile dirs "$W/dirs.jsonl" \
  --slurpfile sel "$W/selection.json" \
  '{head_sha:$head, base_sha:$base, terraform_version:(if $ver == "" then null else $ver end),
    selection:$sel[0], dirs:$dirs}' \
  > "$OUT.tmp" && mv -- "$OUT.tmp" "$OUT"; }; then die "cannot write $OUT"; fi
exit 0
