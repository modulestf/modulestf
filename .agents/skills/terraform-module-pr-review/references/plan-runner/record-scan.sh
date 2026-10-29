#!/bin/bash
# Leak scan over a finished record, on the host, before anything reads it.
# Usage: record-scan.sh <record-dir> [<values-file>]
#
# Every regular file directly in <record-dir> is rewritten with each line that matches
# replaced by a marker line. A line matches when it holds a value from <values-file> (one per
# line, such as the run's credentials), or matches the plan pass's evidence patterns
# (plan-pass.md, Evidence contract): an AWS access key id, a JWT, a PEM header, a signed-URL
# signature, an Authorization header, or a run of 40 or more base64 characters. The last
# pattern also drops a line holding a 40-character commit SHA; the record never needs one.
#
# A secret split across lines evades a line-by-line check, so the values and the distinctive
# patterns, every one but the base64 run, are also matched in a copy of the file with all
# whitespace and newlines removed, and every line such a match spans is replaced. The base64
# run is left out there, because joined ordinary text forms long runs of its own.
# Prints the number of lines it replaced.
set -euo pipefail

dir="${1:?usage: record-scan.sh <record-dir> [<values-file>]}"
values="${2:-/dev/null}"
[ -d "$dir" ] || { echo "record-scan: no such directory: $dir" >&2; exit 2; }

n=0
for f in "$dir"/*; do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  c="$(perl -e '
    my ($file, $vfile) = @ARGV;
    open(my $vh, "<", $vfile) or die; my @v = grep { length } map { chomp; s/\s+//gr } <$vh>;
    open(my $fh, "<", $file) or die; my @l = <$fh>; close $fh;
    my $shape = qr{(?:AKIA|ASIA)[A-Z0-9]{16}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+|-----BEGIN|X-Amz-Signature|Authorization:};
    my $re = qr{$shape|[A-Za-z0-9+/]{40,}};
    my %bad;
    for my $i (0 .. $#l) {
      my $x = $l[$i]; my $b = $x =~ $re;
      for my $s (@v) { $b ||= index($x, $s) >= 0 }
      $bad{$i} = 1 if $b;
    }
    # The joined copy: every non-whitespace character, with the line it came from.
    my ($j, @at) = ("");
    for my $i (0 .. $#l) { for my $ch (split //, $l[$i]) { next if $ch =~ /\s/; $j .= $ch; push @at, $i } }
    my @spans;
    while ($j =~ /$shape/g) { push @spans, [$-[0], $+[0] - 1] }
    for my $s (@v) { my $p = 0; while (($p = index($j, $s, $p)) >= 0) { push @spans, [$p, $p + length($s) - 1]; $p++ } }
    for my $sp (@spans) { $bad{$_} = 1 for $at[$sp->[0]] .. $at[$sp->[1]] }
    my $n = 0;
    for my $i (sort { $a <=> $b } keys %bad) { $l[$i] = "[a line was removed by the leak scan]\n"; $n++ }
    open($fh, ">", $file) or die; print $fh @l; close $fh;
    print $n;
  ' "$f" "$values")"
  n=$((n + c))
done
echo "$n"
