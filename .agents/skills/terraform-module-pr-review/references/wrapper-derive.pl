# wrapper-derive.pl: derive, the bytes terraform_wrapper_module_for_each writes to a wrapper
# versions.tf from its module's versions.tf, from pre-commit-terraform v1.106.0 on. Its text is
# the pull request fix skill's write-path.md, Wrapper Versions; both skills use this one copy.
#
#   perl wrapper-derive.pl derive <file>   prints derive(file) and exits 0, or exits 3 when
#                                          derive is undefined
#
# The pull request fix skill also prepends this file to its own perl, which calls derive.
use strict; use warnings;
sub closes { my $d = 0; for my $c (split //, shift) { $d++ if $c eq "["; return 0 if $c eq "]" && --$d < 0 } return $d == 0 }
sub derive {
  my $s = shift;
  return undef if length($s) > 65536 || $s !~ /\n\z/ || $s =~ /[^\x20-\x7e\t\n]/ || index($s, "<<") >= 0;
  my @l = split /\n/, $s, -1; pop @l;
  my ($o, $i) = ("", 0);
  while ($i < @l) {
    my $x = $l[$i++]; $o .= "$x\n";
    next unless $x =~ /^([ \t]*)provider_meta "[^"]*" \{$/;
    my ($ind, $closed) = ($1, 0);
    while ($i < @l) {
      my $y = $l[$i++];
      if ($y eq "$ind}") { $o .= "$y\n"; $closed = 1; last }
      return undef if $y =~ /[{}]/;
      if ($y =~ m{^[ \t]*(#|//|$)}) { $o .= "$y\n"; next }
      my ($t) = $y =~ /^[ \t]*([A-Za-z0-9_-]+)/;
      my $ua = defined $t && ($t eq "user_agent" || $t eq "module_name");
      if ($ua && $y =~ /^[ \t]*(user_agent|module_name) *= *\[[ \t]*$/) {
        while (1) { return undef if $i >= @l; my $z = $l[$i++]; return undef if $z =~ /[{}]/; last if $z =~ /^[ \t]*\]/ }
        next;
      }
      return undef unless $y =~ /^[ \t]*[A-Za-z_][A-Za-z0-9_-]* *= *(\S.*)$/;
      my $v = $1;
      return undef if index($v, "[") >= 0 && !($ua && closes($v));
      $o .= "$y\n" unless $ua;
    }
    return undef unless $closed;
  }
  return $o;
}
if (!caller && @ARGV && $ARGV[0] eq "derive") {
  my $s; if (open(my $h, "<:raw", $ARGV[1])) { local $/; $s = <$h>; $s = "" unless defined $s }
  my $d = defined $s ? derive($s) : undef; exit 3 unless defined $d; print $d; exit 0;
}
1;
