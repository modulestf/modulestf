#!/usr/bin/perl
# policy-hcl.pl: the static reader of vendored-policy.md. It reads one
# data "aws_iam_policy_document" block from a Terraform file, evaluates nothing, and prints its
# statements as JSON for vendored-policy.sh, or one line "unknown <reason>" when the block holds
# anything it cannot read as literal text: a reference other than a profile substitution, a
# function, a conditional, a heredoc anywhere in the file, a template directive, a dynamic block, a
# merged document, a bare block label anywhere in the file, or more than 4000 action and resource pairs.
#
#   perl policy-hcl.pl <file.tf> <block name> <substitutions file>
#   perl policy-hcl.pl --scan <file.tf>                    "ok", or "unknown <reason>"
#   perl policy-hcl.pl --wiring <block name> <file.tf>...  the policies that read the block
#
# Every mode first holds the file to an allowlist of text, so the reader and Terraform cannot
# disagree on where a string or a comment ends: plain ASCII, no heredoc, no "$${" or "%%{", an even
# number of unescaped quotes on every line, and a "/*" only inside a quoted string of its line.
# --wiring prints one sorted line per policy that reads the block, its whole "policy" value:
#   direct <type>.<name> <gate>                              an aws_iam_policy or aws_iam_role_policy
#   via <document> <gate> <digest> <type>.<name> <gate>      an element of the source_policy_documents
#                                                           of a document such a policy reads
# each <gate> the resource's or document's count or for_each text, or "none", and <digest> the
# SHA-256 of the merging document's text and its source list; or "unknown <reason>".
#
# The substitutions file holds "<expression> <value>" lines from the module profile: each
# expression, written alone as a list element or as ${<expression>} inside a string, reads as its
# value. Output: {"statements": [...], "gate": "<count or for_each text>" or null, "lines": [<first>,
# <last>]}, the block's lines in the file, with each
# statement {effect, action, not_action, resource, not_resource, principal, not_principal,
# condition}, the lists sorted and null when absent. Exit 0 with either output; 2 a usage error.
use strict;
use warnings;
use JSON::PP;

sub unknown { print "unknown $_[0]\n"; exit 0 }
sub usage { print STDERR "usage: policy-hcl.pl <file> <block> <substitutions> | --scan <file> | --wiring <block> <file>...\n"; exit 2 }
my $NAME_RE = qr/^[A-Za-z_][A-Za-z0-9_-]{0,63}$/;
my $mode = @ARGV && $ARGV[0] =~ /^--(scan|wiring)$/ ? $1 : 'document';
shift @ARGV unless $mode eq 'document';
my ($file, $name, $subfile);
if ($mode eq 'scan') { @ARGV == 1 or usage(); $file = $ARGV[0] }
elsif ($mode eq 'wiring') { @ARGV >= 2 or usage(); $name = shift @ARGV }
else { @ARGV == 3 or usage(); ($file, $name, $subfile) = @ARGV }
!defined $name || $name =~ $NAME_RE or do { print STDERR "policy-hcl.pl: bad block name\n"; exit 2 };

my %sub;
if (defined $subfile) {
  open(my $sf, '<', $subfile) or do { print STDERR "policy-hcl.pl: no substitutions file\n"; exit 2 };
  while (my $l = <$sf>) {
    chomp $l;
    next if $l eq '';
    $l =~ /^(\S+) (\S+)$/ or do { print STDERR "policy-hcl.pl: bad substitution line\n"; exit 2 };
    $sub{$1} = $2;
  }
  close $sf;
}

our ($text, $i, $n);
# read_text <file>: the file's text, held to the allowlist above.
sub read_text {
  my ($f) = @_;
  open(my $fh, '<', $f) or unknown("read failed");
  binmode $fh;
  local $/;
  my $t = <$fh>;
  close $fh;
  defined $t or unknown("read failed");
  length($t) <= 1048576 or unknown("file over 1 mib");
  $t =~ /[^\x09\x0a\x0d\x20-\x7e]/ and unknown("unsafe text");
  $t =~ s/\r\n/\n/g;
  $t =~ /<<-?[A-Za-z_]/ and unknown("heredoc");
  $t =~ /\$\$\{|%%\{/ and unknown("escaped interpolation");
  for my $l (split /\n/, $t) {
    (my $q = $l) =~ s/\\["\\]//g;
    my $c = () = $q =~ /"/g;
    $c % 2 == 0 or unknown("unbalanced quotes");
    while ($q =~ m{/\*}g) {
      my $before = () = substr($q, 0, pos($q) - 2) =~ /"/g;
      $before % 2 == 1 or unknown("block comment");
    }
  }
  return $t;
}

# Comments out, strings kept: a string runs to its closing quote, an interpolation ${...} inside it
# to its matching brace on the same line, with strings nested in the interpolation followed too.
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
        $e ne "\n" or unknown("multi-line interpolation");
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
sub clean_of {
  local ($text, $n, $i) = ($_[0], length $_[0], 0);
  my $clean = '';
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
  return $clean;
}
if ($mode eq 'scan') { read_text($file); print "ok\n"; exit 0 }

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
    push @out, ['block', $id, \@labels, substr($s, $p + 1, $e - $p - 1), $p + 1, $e];
    $p = $e + 1;
  }
  return @out;
}

if ($mode eq 'wiring') {
  require Digest::SHA;
  my (%docs, %locals, @res);
  for my $f (@ARGV) {
    for my $it (items(clean_of(read_text($f)))) {
      my ($k, $id, $labels, $v) = @$it;
      next unless $k eq 'block';
      my %a;
      for my $x (items($v)) {
        next unless $x->[0] eq 'attr';
        (my $t = $x->[3]) =~ s/\s+//g;
        $a{$x->[1]} = $t;
      }
      if ($id eq 'locals' && !@$labels) {
        for my $l (keys %a) { !exists $locals{$l} or unknown("local repeated"); $locals{$l} = $a{$l} }
        next;
      }
      next unless @$labels == 2;
      if ($id eq 'data' && $labels->[0] eq 'aws_iam_policy_document') {
        !exists $docs{$labels->[1]} or unknown("block repeated");
        (my $b = $v) =~ s/\s+//g;
        $docs{$labels->[1]} = { a => \%a, body => $v, digest => Digest::SHA::sha256_hex($b) };
      } elsif ($id eq 'resource' && $labels->[0] =~ /^aws_iam_(policy|role_policy)$/) {
        push @res, { type => $labels->[0], label => $labels->[1], a => \%a };
      }
    }
  }
  exists $docs{$name} or unknown("block missing");
  my $gate = sub { my ($h) = @_; defined $h->{a}{count} ? "count=$h->{a}{count}" : defined $h->{a}{for_each} ? "for_each=$h->{a}{for_each}" : 'none' };
  # A policy reads a document only as the whole value of its "policy" argument.
  my $reads = sub { my ($v, $d) = @_; defined $v && $v =~ /^data\.aws_iam_policy_document\.\Q$d\E(\[0\])?\.json$/ };
  # A merging document names the block as one element of its source_policy_documents, written as a
  # list or as a local whose value holds the element.
  my $elem = qr/(?:^|[,(\[])data\.aws_iam_policy_document\.\Q$name\E(?:\[0\]|\[\*\])?\.json(?=[,)\]]|$)/;
  my @out;
  for my $r (@res) { push @out, "direct $r->{type}.$r->{label} " . $gate->($r) if $reads->($r->{a}{policy}, $name) }
  for my $d (sort keys %docs) {
    next if $d eq $name;
    my $src = $docs{$d}{a}{source_policy_documents} // next;
    my $val = $src =~ /^local\.([A-Za-z_][A-Za-z0-9_-]*)$/ ? ($locals{$1} // next) : $src;
    next unless $val =~ $elem;
    # A statement of the same sid in the merging document or its overrides would replace one of the
    # block's: a block with a sid is never read through a merge.
    $docs{$name}{body} !~ /(^|\n)\s*sid\s*=/ or unknown("sid in merged document");
    my $dig = Digest::SHA::sha256_hex("$docs{$d}{digest} $val");
    for my $r (@res) { push @out, "via $d " . $gate->($docs{$d}) . " $dig $r->{type}.$r->{label} " . $gate->($r) if $reads->($r->{a}{policy}, $d) }
  }
  print "$_\n" for sort @out;
  exit 0;
}

# The block: read the whole file as top-level blocks, so a block Terraform evaluates is never missed
# (a bare label is unsupported syntax) and text inside another block is never taken for it.
my $clean = clean_of(read_text($file));
my @hits = grep { $_->[0] eq 'block' && $_->[1] eq 'data' && @{$_->[2]} == 2
  && $_->[2][0] eq 'aws_iam_policy_document' && $_->[2][1] eq $name } items($clean);
@hits or unknown("block missing");
@hits == 1 or unknown("block repeated");
my $block = $hits[0][3];
my $first = 1 + (substr($clean, 0, $hits[0][4]) =~ tr/\n//);
my $last = 1 + (substr($clean, 0, $hits[0][5]) =~ tr/\n//);

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
    elsif ($id =~ /^(not_)?(actions|resources)$/) {
      my $l = list($v);
      @$l or unknown("empty list");
      $st{($1 // '') . substr($2, 0, -1)} = $l;
    }
    else { unknown("unsupported attribute") }
  }
  $st{effect} =~ /^(Allow|Deny)$/ or unknown("unsupported effect");
  for my $k (qw(action not_action resource not_resource principal not_principal condition)) {
    $st{$k} = undef unless exists $st{$k};
  }
  for my $k (qw(principal not_principal)) { $st{$k} = [sort @{$st{$k}}] if defined $st{$k} }
  return \%st;
}

my (@statements, $gate);
my $cells = 0;
for my $it (items($block)) {
  my ($k, $id, $labels, $v) = @$it;
  if ($k eq 'block') {
    unknown("dynamic statement") if $id eq 'dynamic';
    $id eq 'statement' && !@$labels or unknown("unsupported attribute");
    my $st = statement($v);
    # The tuple product, capped here before anything expands it.
    $cells += (defined $st->{action} ? scalar @{$st->{action}} : 1) * (defined $st->{resource} ? scalar @{$st->{resource}} : 1);
    $cells <= 4000 or unknown("too large");
    push @statements, $st;
    next;
  }
  unknown("merged documents") if $id eq 'source_policy_documents' || $id eq 'override_policy_documents';
  if ($id eq 'count' || $id eq 'for_each') {
    !defined $gate or unknown("unsupported attribute");
    (my $t = $v) =~ s/\s+/ /g;
    $gate = "$id = $t";
    next;
  }
  if ($id eq 'version') { str($v) eq '2012-10-17' or unknown("unsupported attribute"); next }
  unknown("unsupported attribute");
}
print JSON::PP->new->canonical->encode({ statements => \@statements, gate => $gate, lines => [$first, $last] }), "\n";
