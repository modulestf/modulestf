#!/usr/bin/env bash
# shellcheck disable=SC2016 # the perl and jq programs below are single-quoted on purpose
# The covered skip of terraform-module-pr-review: which examples skipped by a plan gate are
# covered by the plan of other examples, as one file. Rules and reasons: skip-coverage.md.
# Runs the same under bash and zsh. Invoke it by an absolute path in the skill as installed,
# never from the head or the workspace:
#
#   <bash|zsh> /abs/path/skip-coverage.sh gates <run-dir> --tree <dir> --base <sha> \
#       --coverage <coverage.json> --out <file>
#       The base gate record: for every unplanned example directory in <coverage.json>, the
#       clone scope plan-pass.sh gives in <dir>, a worktree at <sha>, and the per-file gates
#       plan-pass.sh runs over it. Writes <file> complete or not at all.
#   <bash|zsh> /abs/path/skip-coverage.sh check <run-dir> --files <files.json> \
#       --coverage <coverage.json> --plan <record> --head <sha> --base <sha|unresolved> \
#       [--addresses <dir>] [--base-gates <file>] [--prefix <module-root>]
#       Prints one JSON object: the covered and the uncovered unplanned directories
#       (skip-coverage.md, Output). Never runs terraform and never reads the network.
#
# <run-dir> is the absolute run directory Workspace printed, "<root>/pr-review.XXXXXX", holding
# the clone at head at <run-dir>/clone. Exit 2 is a usage error or a refused input.

CMD=${1:-}
RUN=${2:-}
die() { echo "skip-coverage.sh: $1" >&2; exit 2; }
case "$CMD" in gates|check) ;; *) die "usage: skip-coverage.sh gates|check <run-dir> ..." ;; esac
ROOT="${RUN%/*}"
case "$ROOT" in /?*) ;; *) die "the run directory must be absolute" ;; esac
case "$RUN" in "$ROOT"/pr-review.??????) ;; *) die "not a run directory: $RUN" ;; esac
[ -d "$RUN/clone" ] || die "no clone in $RUN"
shift 2
HERE="$(cd "$(dirname "$0")" && pwd -P)"
PP="$HERE/plan-pass.sh"
[ -f "$PP" ] || die "no plan-pass.sh beside this script"

FILES=; COV=; PLANREC=; ADDRS=; BGATES=; HEADSHA=; BASESHA=; PREFIX=; TREE=; OUT=
while [ $# -gt 0 ]; do
  case "$1" in
    --files) FILES=${2:-} ;;
    --coverage) COV=${2:-} ;;
    --plan) PLANREC=${2:-} ;;
    --addresses) ADDRS=${2:-} ;;
    --base-gates) BGATES=${2:-} ;;
    --head) HEADSHA=${2:-} ;;
    --base) BASESHA=${2:-} ;;
    --prefix) PREFIX=${2:-} ;;
    --tree) TREE=${2:-} ;;
    --out) OUT=${2:-} ;;
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
regular() { # name, path: a regular file, not a link, at most 5 MiB
  [ -f "$2" ] && [ ! -L "$2" ] && [ "$(wc -c < "$2")" -le 5242880 ] || die "$1 must name a regular file of at most 5 MiB"
}

W="$(mktemp -d "${TMPDIR:-/tmp}/pr-review.XXXXXX")" || die "no temporary directory"
trap 'rm -rf -- "$W"' EXIT
trap 'rm -rf -- "$W"; exit 130' INT TERM

regular --coverage "$COV"
# The unplanned example directories, once each, in order: data only
jq -r 'if type == "object" and (.unplanned | type == "array") then
         [.unplanned[] | .dir | select(type == "string" and test("^[A-Za-z0-9._/-]{1,300}$"))] | unique[]
       else error("not a coverage object") end' "$COV" > "$W/dirs.txt" 2> /dev/null \
  || die "--coverage is not a plan coverage object"

# The gate record of one tree: per directory its clone scope and the per-file gate hits, both
# from plan-pass.sh, the same two functions the plan pass ran, paths relative to the tree and
# hits without their line, which a change elsewhere in a shared file moves. plan-pass.sh is
# pointed at the tree through a run directory of its own whose clone is a link to the tree.
record_gates() { # tree, sha: the record on standard output; non-zero when a step failed
  f="$(mktemp -d "$W/pr-review.XXXXXX")" || return 1
  ln -s "$1" "$f/clone" || return 1
  t="$(cd "$1" && pwd -P)" || return 1
  echo "skip-gates 1 $2"
  while IFS= read -r d; do
    echo "dir $d"
    if [ -d "$t/$d" ]; then
      s="$(bash "$PP" scope "$f" "$t/$d")" || return 1
      printf '%s\n' "$s" | awk -v r="$t/" 'NF { if (index($0, r) == 1) print "file " substr($0, length(r) + 1); else print "file " $0 }'
      printf '%s\n' "$s" | bash "$PP" gates "$f" laptop clone | awk -v r="$t/" '/^G[0-3] / {
          p = substr($0, 4); sub(/:[^:]*$/, "", p); if (index(p, r) == 1) p = substr(p, length(r) + 1)
          print "hit " substr($0, 1, 2) " " p }' | sort
    else
      echo "file MISSING"
    fi
    echo "done $d"
  done < "$W/dirs.txt"
  echo end
}

if [ "$CMD" = gates ]; then
  sha_ok "$BASESHA" || die "--base must be a full commit SHA"
  [ -d "$TREE" ] || die "--tree must name a directory"
  case "$OUT" in /?*) ;; *) die "--out must be an absolute path" ;; esac
  [ -d "${OUT%/*}/" ] || die "the directory of --out must exist"
  [ "$(git -C "$TREE" rev-parse --verify 'HEAD^{commit}' 2> /dev/null)" = "$BASESHA" ] || die "--tree is not at --base"
  record_gates "$TREE" "$BASESHA" > "$OUT.tmp" || { rm -f -- "$OUT.tmp"; die "the gates did not run"; }
  mv -- "$OUT.tmp" "$OUT" || die "cannot write $OUT"
  exit 0
fi

# --- check
sha_ok "$HEADSHA" || die "--head must be a full commit SHA"
[ "$BASESHA" = unresolved ] || sha_ok "$BASESHA" || die "--base must be a full commit SHA or unresolved"
regular --files "$FILES"
regular --plan "$PLANREC"
PREFIX="${PREFIX%/}"
case "$PREFIX" in /*|*..*|.) die "--prefix must be repository-relative" ;; esac
[ -n "$PREFIX" ] && PREFIX="$PREFIX/"
jq -e 'type == "array" and all(.[]; type == "object" and (.filename | type == "string") and (.status | type == "string")
  and ([.filename, .previous_filename // ""][] | test("[\\x00-\\x1f\\x7f]") | not))' "$FILES" > /dev/null 2>&1 \
  || die "--files is not a JSON array of file objects"

CLONE="$(cd "$RUN/clone" && pwd -P)"
HEADOK=false
[ "$(git -C "$CLONE" rev-parse --verify 'HEAD^{commit}' 2> /dev/null)" = "$HEADSHA" ] && HEADOK=true

# The allow-list, per changed .tf file a candidate: the patch, then the head file from the clone.
# CLASSIFY_PL rebuilds the base text from the head text and the patch, parses both, and prints
# one "attr <address> <name>" line per changed attribute and "ok", or one "reject <why>" line
# (skip-coverage.md, The allow-list).
CLASSIFY_PL='
use strict; use warnings;
my ($headf, $patchf) = @ARGV;
sub out { print "$_[0]\n"; exit 0 }
sub slurp { open(my $h, "<", $_[0]) or return undef; local $/; my $t = <$h>; close $h; $t }
my $ht = slurp($headf); my $pt = slurp($patchf);
out("reject unreadable") unless defined $ht && defined $pt;
out("reject non-ascii or carriage return") if "$ht$pt" =~ /[^\x09\x0a\x20-\x7e]/;
my @head = split /\n/, $ht, -1; pop @head if @head && $head[-1] eq "";
my @p = split /\n/, $pt, -1; pop @p if @p && $p[-1] eq "";
# Rebuild the base: hunks in order, every context and added line checked against the head.
# A change group is a run of removed and added lines; it records its base and head lines.
my (@base, @groups); my $hi = 0; my $i = 0;
out("reject no hunk") unless @p;
while ($i < @p) {
  $p[$i] =~ /\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/ or out("reject patch");
  my ($os, $oc, $ns, $nc) = ($1, $2 // 1, $3, $4 // 1);
  my $start = $nc == 0 ? $ns : $ns - 1;
  out("reject patch") if $start < $hi || $start > @head;
  push @base, $head[$hi++] while $hi < $start;
  out("reject patch") unless @base == ($oc == 0 ? $os : $os - 1);
  $i++; my ($co, $cn, $g) = (0, 0, undef);
  while ($i < @p && $p[$i] !~ /\A@@ /) {
    my $x = $p[$i++];
    next if $x =~ /\A\\/;
    my ($c, $t) = (substr($x, 0, 1), substr($x, 1));
    if ($c eq " ") { out("reject patch") unless $hi < @head && $head[$hi] eq $t; push @base, $t; $hi++; $co++; $cn++; $g = undef }
    elsif ($c eq "+") { out("reject patch") unless $hi < @head && $head[$hi] eq $t; $hi++; $cn++;
      push @groups, ($g = {b => [], h => []}) unless $g; push @{$g->{h}}, $hi }
    elsif ($c eq "-") { push @base, $t; $co++;
      push @groups, ($g = {b => [], h => []}) unless $g; push @{$g->{b}}, scalar @base }
    else { out("reject patch") }
  }
  out("reject patch") unless $co == $oc && $cn == $nc;
}
push @base, @head[$hi .. $#head];

# Lexer: tokens [type, value, line, end line, extra]. Strings keep their interpolations as
# token lists; a template directive, a block comment or anything unknown fails the file.
our ($T, $line);
sub fail { die "parse\n" }
sub lex_string {
  my ($l, $s0, @in) = ($line, pos($T)); my $dir = 0;
  pos($T)++;
  while (1) {
    if ($T =~ /\G\\[^\n]/gc) { next }
    if ($T =~ /\G(?:\$\$\{|%%\{)/gc) { next }
    if ($T =~ /\G\$\{/gc) { push @in, lex(1); next }
    if ($T =~ /\G%\{/gc) { $dir = 1; lex(1); next }
    if ($T =~ /\G"/gc) { return ["S", substr($T, $s0, pos($T) - $s0), $l, $l, {in => \@in, dir => $dir}] }
    if ($T =~ /\G[^"\\\$%\n]+/gc || $T =~ /\G[\$%]/gc) { next }
    fail();
  }
}
sub lex { # until the end, or with $interp until the "}" that closes the interpolation
  my ($interp) = @_; my (@t, $d); $d = 0;
  while (1) {
    if (pos($T) >= length $T) { fail() if $interp; return \@t }
    if ($T =~ /\G\n/gc) { push @t, ["NL", "", $line, $line]; $line++; next }
    if ($T =~ /\G[ \t]+/gc || $T =~ /\G(?:#|\/\/)[^\n]*/gc) { next }
    fail() if $T =~ /\G\/\*/gc;
    if ($T =~ /\G(?=")/gc) { push @t, lex_string(); next }
    if ($T =~ /\G<<-?([A-Za-z_][A-Za-z0-9_-]*)[ \t]*\n/gc) {
      my ($id, $l) = ($1, $line); $line++;
      while (1) { fail() unless $T =~ /\G([^\n]*)\n/gc; $line++; last if $1 =~ /\A\s*\Q$id\E\s*\z/ }
      push @t, ["HD", $id, $l, $line - 1]; $line--; pos($T)--; next;
    }
    if ($T =~ /\G([A-Za-z_][A-Za-z0-9_-]*)/gc) { push @t, ["ID", $1, $line, $line]; next }
    if ($T =~ /\G([0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)/gc) { push @t, ["NUM", $1, $line, $line]; next }
    if ($T =~ /\G(==|!=|<=|>=|&&|\|\||=>|\.\.\.|::|[{}\[\]()=,.:?!+\-*\/%<>])/gc) {
      my $q = $1;
      if ($interp && $q eq "{") { $d++ }
      if ($interp && $q eq "}") { return \@t if $d == 0; $d-- }
      push @t, ["P", $q, $line, $line]; next;
    }
    fail();
  }
}
# Parser: the body of a file, its blocks and attributes. Returns the skeleton, block headers and
# attribute names without any expression, and the attributes with their line spans.
our (@k, $j, @attrs);
sub isp { my $u = $k[$j]; defined $u && $u->[0] eq "P" && $u->[1] eq $_[0] }
sub body {
  my ($nested, $ctx, $addr) = @_; my @items;
  while (1) {
    $j++ while $j < @k && $k[$j][0] eq "NL";
    if ($j >= @k) { fail() if $nested; return join(";", @items) }
    if (isp("}")) { fail() unless $nested; $j++; return join(";", @items) }
    fail() unless $k[$j][0] eq "ID";
    my ($name, $sl) = ($k[$j][1], $k[$j][2]); $j++;
    if (isp("=")) {
      $j++; my ($s, $d, $el) = ($j, 0, $sl);
      while ($j < @k) {
        my $u = $k[$j];
        if ($u->[0] eq "NL") { last if $d == 0 }
        elsif ($u->[0] eq "P" && $u->[1] =~ /\A[(\[{]\z/) { $d++ }
        elsif ($u->[0] eq "P" && $u->[1] =~ /\A[)\]}]\z/) { last if $d == 0; $d-- }
        $el = $u->[3]; $j++;
      }
      my @e = grep { $_->[0] ne "NL" } @k[$s .. $j - 1];
      fail() unless @e;
      push @attrs, {name => $name, start => $sl, end => $el, toks => \@e, rd => $ctx eq "rd", addr => $addr};
      push @items, "A $name";
    } else {
      my @l;
      while ($j < @k && ($k[$j][0] eq "S" || $k[$j][0] eq "ID")) {
        my $v = $k[$j][1]; $v =~ s/\A"(.*)"\z/$1/s; fail() unless $v =~ /\A[A-Za-z0-9_-]+\z/; push @l, $v; $j++;
      }
      fail() unless isp("{");
      $j++;
      my $rd = !$nested && ($name eq "resource" || $name eq "data") && @l == 2;
      my $sub = body(1, $rd ? "rd" : "other", $rd ? ($name eq "data" ? "data." : "") . "$l[0].$l[1]" : "");
      push @items, "B $name @l {$sub}";
    }
  }
}
sub parse {
  local $T = join("\n", @{$_[0]}) . "\n"; local $line = 1; pos($T) = 0;
  local @k = @{lex(0)}; local $j = 0; local @attrs;
  my $sk = body(0, "top", "");
  return ($sk, [@attrs]);
}
my ($hs, $ha, $bs, $ba);
eval { ($hs, $ha) = parse(\@head); ($bs, $ba) = parse(\@base); 1 } or out("reject unparsed");
out("reject structure changed") unless $hs eq $bs && @$ha == @$ba;
sub at { my ($a, $n) = @_; for my $x (0 .. $#$a) { return $x if $a->[$x]{start} <= $n && $n <= $a->[$x]{end} } -1 }

# A plain expression: references, literals, splats, lists, objects and the allowed functions.
my %fn = map { ($_ => 1) } qw(concat compact flatten distinct join format length toset tolist tomap element keys values);
our @x; our $q;
sub xp { my $u = $x[$q]; defined $u && $u->[0] eq "P" && $u->[1] eq $_[0] }
sub want { fail() unless xp($_[0]); $q++ }
sub list { my ($close) = @_; until (xp($close)) { pexpr(); last unless xp(","); $q++ } want($close) }
sub pexpr {
  my $u = $x[$q] // fail();
  if ($u->[0] eq "NUM") { $q++ }
  elsif (xp("-") && ($x[$q + 1][0] // "") eq "NUM") { $q += 2 }
  elsif ($u->[0] eq "S") {
    fail() if $u->[4]{dir};
    for my $in (@{$u->[4]{in}}) { local @x = grep { $_->[0] ne "NL" } @$in; local $q = 0; pexpr(); fail() if $q < @x }
    $q++;
  } elsif ($u->[0] eq "ID" && defined $x[$q + 1] && $x[$q + 1][0] eq "P" && $x[$q + 1][1] eq "(") {
    fail() unless $fn{$u->[1]}; $q += 2; list(")");
  } elsif ($u->[0] eq "ID") {
    fail() if $u->[1] =~ /\A(?:each|count|self|for|if|in)\z/; $q++;
  } elsif (xp("[")) { $q++; list("]") }
  elsif (xp("{")) {
    $q++;
    until (xp("}")) {
      my $key = $x[$q] // fail();
      fail() unless $key->[0] eq "ID" || ($key->[0] eq "S" && !@{$key->[4]{in}} && !$key->[4]{dir});
      $q++; fail() unless xp("=") || xp(":"); $q++; pexpr(); $q++ if xp(",");
    }
    $q++;
  } else { fail() }
  while (1) {
    if (xp(".")) { $q++; my $v = $x[$q] // fail(); fail() unless $v->[0] eq "ID" || $v->[0] eq "NUM" || xp("*"); $q++ }
    elsif (xp("[")) { $q++; if (xp("*")) { $q++ } else { pexpr() } want("]") }
    else { last }
  }
}
sub plain { local @x = @{$_[0]}; local $q = 0; eval { pexpr(); fail() if $q < @x; 1 } }

my %meta = map { ($_ => 1) } qw(count for_each provider depends_on);
my %seen;
for my $g (@groups) {
  my %ids;
  for my $n (@{$g->{b}}) { $ids{at($ba, $n)}++ }
  for my $n (@{$g->{h}}) { $ids{at($ha, $n)}++ }
  my @ids = keys %ids;
  out("reject change outside one attribute") unless @ids == 1 && $ids[0] >= 0;
  my ($h, $b) = ($ha->[$ids[0]], $ba->[$ids[0]]);
  out("reject not a resource or data attribute") unless $h->{rd} && $b->{rd} && $h->{addr} eq $b->{addr} && $h->{name} eq $b->{name};
  out("reject meta-argument") if $meta{$h->{name}};
  out("reject expression not plain") unless plain($h->{toks}) && plain($b->{toks});
  print "attr $h->{addr} $h->{name}\n" unless $seen{"$h->{addr} $h->{name}"}++;
}
out("ok");
'

# Per changed file one JSON line {file, dir, ok, attrs}: a modified *.md is allowed with no
# attribute; a modified .tf at the module root or under modules/ goes through CLASSIFY_PL;
# anything else is not allowed.
: > "$W/classes.jsonl"
n=0
jq -c --arg pre "$PREFIX" '.[] | {f: .filename, s: .status, prev: (.previous_filename // null),
    patch: (.patch // null),
    kind: (if .filename | test("\\.md$") then "md"
           elif (.filename | startswith($pre)) and (.filename[($pre | length):] | test("^([^/]+|modules/.+)\\.tf$"))
             and (.filename[($pre | length):] | test("(^|/)(examples|wrappers)/") | not) then "tf"
           else "other" end)}' "$FILES" > "$W/files.jsonl" || die "--files cannot be read"
while IFS= read -r row; do
  n=$((n + 1))
  f="$(printf '%s\n' "$row" | jq -r .f)"
  kind="$(printf '%s\n' "$row" | jq -r 'if .s != "modified" or .prev != null then "other" else .kind end')"
  out=
  case "$kind" in
    md) out=ok ;;
    tf)
      if printf '%s\n' "$row" | jq -e '.patch | type == "string"' > /dev/null; then
        printf '%s\n' "$row" | jq -j .patch > "$W/patch-$n"
        hf="$CLONE/$f"
        if [ -f "$hf" ] && [ ! -L "$hf" ]; then out="$(perl -e "$CLASSIFY_PL" "$hf" "$W/patch-$n")"; fi
      fi ;;
  esac
  printf '%s\n' "$out" | jq -R -s -c --arg f "$f" '
    split("\n") | map(select(length > 0)) as $l
    | {file: $f, dir: ($f | if test("/") then sub("/[^/]*$"; "") else "." end),
       ok: ($l[-1:] == ["ok"]),
       attrs: [$l[] | select(startswith("attr ")) | split(" ") | {address: .[1], attribute: .[2]}]}' >> "$W/classes.jsonl"
done < "$W/files.jsonl"

# The witness records: addresses-<n>.json from --addresses, data only, as the plan coverage reads them
: > "$W/addr.jsonl"
if [ -n "$ADDRS" ] && [ -d "$ADDRS" ] && [ ! -L "$ADDRS" ]; then
  for af in "$ADDRS"/addresses-*.json; do
    an="${af##*/addresses-}"; an="${an%.json}"
    printf '%s\n' "$an" | grep -Eqx '[1-9][0-9]{0,5}' || continue
    [ -f "$af" ] && [ ! -L "$af" ] && [ "$(wc -c < "$af")" -le 1048576 ] || continue
    jq -c --arg n "$an" '{($n): .}' "$af" >> "$W/addr.jsonl" 2> /dev/null || true
  done
fi

# The gate records: the head computed now over the clone, the base read from --base-gates
HEADGATES=; BASEGATES=
if [ "$HEADOK" = true ]; then HEADGATES="$(record_gates "$CLONE" "$HEADSHA")" || HEADGATES=; fi
if [ -n "$BGATES" ] && [ -f "$BGATES" ] && [ ! -L "$BGATES" ] && [ "$(wc -c < "$BGATES")" -le 5242880 ]; then
  BASEGATES="$(cat "$BGATES")"
fi

jq -n -L "$HERE" --slurpfile cov "$COV" --slurpfile cls "$W/classes.jsonl" --slurpfile a "$W/addr.jsonl" \
  --rawfile rec "$PLANREC" --arg hg "$HEADGATES" --arg bg "$BASEGATES" \
  --arg head "$HEADSHA" --arg base "$BASESHA" --argjson headok "$HEADOK" \
  --slurpfile files "$FILES" '
  include "skip-coverage";
  skip_coverage($cov[0]; $files[0]; $cls; ($a | add // {}); $rec; $hg; $bg; $head; $base; $headok)
' || die "cannot evaluate"
exit 0
