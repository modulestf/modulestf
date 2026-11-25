#!/usr/bin/perl
# policy-hcl.pl: the static reader of vendored-policy.md. It reads one
# data "aws_iam_policy_document" block from a Terraform file, evaluates nothing, and prints its
# statements as JSON for vendored-policy.sh, or one line "unknown <reason>" when the block holds
# anything it cannot read as literal text: a reference other than a profile substitution, a
# function, a conditional, a heredoc, a template directive or a dynamic block inside a statement.
#
#   perl policy-hcl.pl <file.tf> <block name> <substitutions file>
#
# The substitutions file holds "<expression> <value>" lines from the module profile: each
# expression, written alone as a list element or as ${<expression>} inside a string, reads as its
# value. Output: {"statements": [...], "dynamic": [<text>...], "merges": "<text>", "lines": [<first>,
# <last>]}, the block's lines in the file, with each
# statement {effect, action, not_action, resource, not_resource, principal, not_principal,
# condition}, the lists sorted and null when absent. Exit 0 with either output; 2 a usage error.
use strict;
use warnings;
use JSON::PP;

@ARGV == 3 or do { print STDERR "usage: policy-hcl.pl <file> <block> <substitutions>\n"; exit 2 };
my ($file, $name, $subfile) = @ARGV;
$name =~ /^[A-Za-z_][A-Za-z0-9_-]{0,63}$/ or do { print STDERR "policy-hcl.pl: bad block name\n"; exit 2 };

sub unknown { print "unknown $_[0]\n"; exit 0 }

my %sub;
open(my $sf, '<', $subfile) or do { print STDERR "policy-hcl.pl: no substitutions file\n"; exit 2 };
while (my $l = <$sf>) {
  chomp $l;
  next if $l eq '';
  $l =~ /^(\S+) (\S+)$/ or do { print STDERR "policy-hcl.pl: bad substitution line\n"; exit 2 };
  $sub{$1} = $2;
}
close $sf;

open(my $fh, '<', $file) or unknown("read failed");
binmode $fh;
local $/;
our $text = <$fh>;
close $fh;
defined $text or unknown("read failed");
length($text) <= 1048576 or unknown("file over 1 mib");
$text =~ /[^\x09\x0a\x0d\x20-\x7e]/ and unknown("unsafe text");
$text =~ s/\r\n/\n/g;

# Comments out, strings kept: a string runs to its closing quote, an interpolation ${...} inside it
# to its matching brace, with strings nested in the interpolation followed too.
my $clean = '';
our $i = 0;
our $n = length $text;
sub scan_string {    # from the opening quote at $i; returns the string's raw text, quotes included
  my $s = $i;
  $i++;
  while ($i < $n) {
    my $c = substr($text, $i, 1);
    if ($c eq '\\') { $i += 2; next }
    if ($c eq '"') { $i++; return substr($text, $s, $i - $s) }
    if ($c eq "\n") { unknown("unclosed string") }
    if (substr($text, $i, 2) eq '${' || substr($text, $i, 2) eq '%{') {
      $i += 2;
      my $d = 1;
      while ($i < $n && $d > 0) {
        my $e = substr($text, $i, 1);
        if ($e eq '"') { scan_string(); next }
        $d++ if $e eq '{';
        $d-- if $e eq '}';
        $i++;
      }
      $d == 0 or unknown("unclosed string");
      next;
    }
    $i++;
  }
  unknown("unclosed string");
}
while ($i < $n) {
  my $c = substr($text, $i, 1);
  if ($c eq '"') { $clean .= scan_string(); next }
  if ($c eq '#' || substr($text, $i, 2) eq '//') {
    $i++ while $i < $n && substr($text, $i, 1) ne "\n";
    next;
  }
  if (substr($text, $i, 2) eq '/*') {
    my $e = index($text, '*/', $i + 2);
    $e >= 0 or unknown("unclosed comment");
    my $body = substr($text, $i, $e + 2 - $i);
    $clean .= "\n" x ($body =~ tr/\n//);
    $i = $e + 2;
    next;
  }
  $clean .= $c;
  $i++;
}

# The block: exactly one at the top level, found by its header, with its body to the matching brace.
my @hits;
while ($clean =~ /^[ \t]*data[ \t]+"aws_iam_policy_document"[ \t]+"\Q$name\E"[ \t]*\{/mg) { push @hits, pos($clean) }
@hits or unknown("block missing");
@hits == 1 or unknown("block repeated");

# body($pos): the text from $pos to the brace that closes the block opened just before it.
sub close_of {
  my ($s, $pos) = @_;
  my $d = 1;
  my $len = length $s;
  while ($pos < $len) {
    my $c = substr($s, $pos, 1);
    if ($c eq '"') {
      local ($text, $n, $i) = ($s, $len, $pos);
      scan_string();
      $pos = $i;
      next;
    }
    $d++ if $c eq '{';
    $d-- if $c eq '}';
    return $pos if $d == 0;
    $pos++;
  }
  unknown("unclosed block");
}
my $start = $hits[0];
my $end = close_of($clean, $start);
my $first = 1 + (substr($clean, 0, $start) =~ tr/\n//);
my $last = 1 + (substr($clean, 0, $end) =~ tr/\n//);
my $block = substr($clean, $start, $end - $start);
$block =~ /<</ and unknown("heredoc");

# items($text): the attributes and blocks of a body, in order, as [kind, name, labels, text].
sub items {
  my ($s) = @_;
  my @out;
  my $p = 0;
  my $len = length $s;
  while (1) {
    $p++ while $p < $len && substr($s, $p, 1) =~ /\s/;
    last if $p >= $len;
    substr($s, $p) =~ /^([A-Za-z_][A-Za-z0-9_-]*)/ or unknown("unsupported syntax");
    my $id = $1;
    $p += length $id;
    $p++ while $p < $len && substr($s, $p, 1) =~ /[ \t]/;
    if (substr($s, $p, 1) eq '=') {
      $p++;
      my $q = $p;
      my $d = 0;
      while ($q < $len) {
        my $c = substr($s, $q, 1);
        if ($c eq '"') { local ($text, $n, $i) = ($s, $len, $q); scan_string(); $q = $i; next }
        $d++ if $c =~ /[\[({]/;
        $d-- if $c =~ /[\])}]/;
        last if $c eq "\n" && $d == 0;
        $q++;
      }
      my $v = substr($s, $p, $q - $p);
      $v =~ s/^\s+|\s+$//g;
      push @out, ['attr', $id, [], $v];
      $p = $q;
      next;
    }
    my @labels;
    while (substr($s, $p, 1) eq '"') {
      local ($text, $n, $i) = ($s, $len, $p);
      my $raw = scan_string();
      $p = $i;
      push @labels, substr($raw, 1, -1);
      $p++ while $p < $len && substr($s, $p, 1) =~ /[ \t]/;
    }
    substr($s, $p, 1) eq '{' or unknown("unsupported syntax");
    my $e = close_of($s, $p + 1);
    push @out, ['block', $id, \@labels, substr($s, $p + 1, $e - $p - 1)];
    $p = $e + 1;
  }
  return @out;
}

# A string literal, its interpolations replaced by their substitutions.
sub str {
  my ($v) = @_;
  $v =~ /^"(.*)"$/s or unknown("unevaluated expression");
  my $s = $1;
  $s =~ /%\{/ and unknown("template directive");
  $s =~ s/\$\$\{/\x00/g;
  $s =~ s/\$\{\s*([^{}"]*?)\s*\}/exists $sub{$1} ? $sub{$1} : unknown("unevaluated expression")/ge;
  $s =~ /\$\{/ and unknown("unevaluated expression");
  $s =~ s/\x00/\${/g;
  $s =~ /\\(?![\\"])/ and unknown("unsupported escape");
  $s =~ s/\\(["\\])/$1/g;
  return $s;
}
sub elem {
  my ($v) = @_;
  return str($v) if $v =~ /^"/;
  return $v if $v eq 'true' || $v eq 'false';
  return $sub{$v} if exists $sub{$v};
  unknown("unevaluated expression");
}
sub list {
  my ($v) = @_;
  $v =~ /^\[(.*)\]$/s or unknown("unevaluated expression");
  my $s = $1;
  my @e;
  my ($p, $q, $d, $len) = (0, 0, 0, length $s);
  while ($q <= $len) {
    my $c = $q < $len ? substr($s, $q, 1) : ',';
    if ($c eq '"') { local ($text, $n, $i) = ($s, $len, $q); scan_string(); $q = $i; next }
    $d++ if $c =~ /[\[({]/;
    $d-- if $c =~ /[\])}]/;
    if ($c eq ',' && $d == 0) {
      my $t = substr($s, $p, $q - $p);
      $t =~ s/^\s+|\s+$//g;
      push @e, elem($t) if $t ne '';
      $p = $q + 1;
    }
    $q++;
  }
  return [sort { $a cmp $b } @e];
}

sub principals {
  my ($body, $kind) = @_;
  my ($type, $ids);
  for my $it (items($body)) {
    my ($k, $id, undef, $v) = @$it;
    $k eq 'attr' or unknown($k eq 'block' && $id eq 'dynamic' ? "dynamic block" : "unsupported attribute");
    if ($id eq 'type') { $type = str($v) }
    elsif ($id eq 'identifiers') { $ids = list($v) }
    else { unknown("unsupported attribute") }
  }
  defined $type && defined $ids or unknown("unsupported attribute");
  return map { "$type=$_" } @$ids;
}

sub statement {
  my ($body) = @_;
  my %st = (effect => 'Allow');
  my %seen;
  for my $it (items($body)) {
    my ($k, $id, undef, $v) = @$it;
    if ($k eq 'block') {
      unknown("dynamic block") if $id eq 'dynamic';
      if ($id eq 'principals' || $id eq 'not_principals') {
        push @{$st{$id eq 'principals' ? 'principal' : 'not_principal'}}, principals($v);
      } elsif ($id eq 'condition') {
        my ($t, $var, $vals);
        for my $c (items($v)) {
          my ($ck, $cid, undef, $cv) = @$c;
          $ck eq 'attr' or unknown($cid eq 'dynamic' ? "dynamic block" : "unsupported attribute");
          if ($cid eq 'test') { $t = str($cv) }
          elsif ($cid eq 'variable') { $var = str($cv) }
          elsif ($cid eq 'values') { $vals = list($cv) }
          else { unknown("unsupported attribute") }
        }
        defined $t && defined $var && defined $vals or unknown("unsupported attribute");
        push @{$st{condition}}, { test => $t, variable => $var, values => $vals };
      } else {
        unknown("unsupported attribute");
      }
      next;
    }
    !$seen{$id}++ or unknown("unsupported attribute");
    if ($id eq 'sid') { str($v) }
    elsif ($id eq 'effect') { $st{effect} = str($v) }
    elsif ($id =~ /^(not_)?(actions|resources)$/) { $st{($1 // '') . substr($2, 0, -1)} = list($v) }
    else { unknown("unsupported attribute") }
  }
  $st{effect} =~ /^(Allow|Deny)$/ or unknown("unsupported effect");
  for my $k (qw(action not_action resource not_resource principal not_principal condition)) {
    $st{$k} = undef unless exists $st{$k};
  }
  for my $k (qw(principal not_principal)) { $st{$k} = [sort @{$st{$k}}] if defined $st{$k} }
  return \%st;
}

my (@statements, @dynamic, @merges);
for my $it (items($block)) {
  my ($k, $id, $labels, $v) = @$it;
  if ($k eq 'block') {
    if ($id eq 'statement' && !@$labels) { push @statements, statement($v) }
    elsif ($id eq 'dynamic' && @$labels == 1 && $labels->[0] eq 'statement') {
      (my $t = $v) =~ s/\s+/ /g;
      push @dynamic, $t;
    } else { unknown("unsupported attribute") }
    next;
  }
  if ($id eq 'count') { next }
  if ($id =~ /^(source_policy_documents|override_policy_documents|policy_id|version)$/) {
    (my $t = $v) =~ s/\s+/ /g;
    push @merges, "$id = $t";
    next;
  }
  unknown("unsupported attribute");
}
print JSON::PP->new->canonical->encode({ statements => \@statements, dynamic => \@dynamic, merges => join("\n", @merges), lines => [$first, $last] }), "\n";
