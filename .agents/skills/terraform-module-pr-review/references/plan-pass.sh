#!/usr/bin/env bash
# The plan pass of terraform-module-pr-review, as one file. Rules and reasons: plan-pass.md.
# Runs the same under bash and zsh. Invoke it by its literal absolute path, never through a
# variable or a copy in the workspace:
#
#   <bash|zsh> /abs/path/plan-pass.sh g0 <run-dir> [base]
#       G0 over the clone, or with "base" over the base worktree, into <run-dir>/g0.txt or
#       <run-dir>/g0-base.txt. Run it before any terraform command touches that tree.
#   <bash|zsh> /abs/path/plan-pass.sh plan <run-dir> <profile> [--role-arn <arn>] [--mode laptop|runner] [--base <sha>] <example-dir>...
#       The plan pass over the named example directories, repository-relative, in the order
#       given, until the budget runs out. Prints "plan pass mode:" once, then the record lines per example on
#       standard output: "example:", "plan:", "scope:", "modules:" and "base:", and a
#       "gate-hit" line per hit. --mode laptop is the default; --mode runner relaxes the
#       code-execution gates and is refused outside a container (plan-pass.md, Modes).
#       Runner mode only: --budget <seconds> replaces the pass's 60-minute budget, for a
#       runner that holds one budget across its containers, and there is no cap on the number
#       of examples. --phase init runs G0's saved result, the gates and init for every
#       example and saves each one's state under <run-dir>/plan, with no credential call;
#       --phase plan --index <n> <example-dir> then plans that one example from the saved
#       state and prints its record lines, with no summary. The runner runs each phase in its
#       own container behind its own egress proxy (plan-pass.md, Modes). --phase show --index
#       <n> <example-dir>, in a container with no network and no credentials, prints the saved
#       plan's addresses as one "addresses-json:" line for the host to check. --phase validate
#       --index <n> <example-dir>, in the same kind of container, runs terraform validate on
#       the example from the saved state and prints one "validate: passed|failed" line.
#       Every plan is saved with -out under <run-dir>/plan/saved. In laptop mode the saved head
#       plan of a planned example is read with terraform show -json after the plan has ended,
#       and its addresses, attribute and sensitive names, local module calls, the head
#       commit and the example directory are written to <run-dir>/plan-addresses/addresses-<n>.json, <n> the example's
#       place in the list (plan-pass.md, Saved plans and addresses).
#       Laptop mode needs --role-arn: the plan credentials are a session on that review role,
#       downscoped by plan-session-policy.json and issued by plan-session.sh, never the
#       profile's own (plan-pass.md, Credentials). Runner mode gets its session from the runner.
#       Laptop mode keeps each head plan's result in the plan cache across runs, PLAN_CACHE or
#       the user's cache directory, and reads it back on a later run with the same inputs
#       (plan-pass.md, Plan cache).
#   <bash|zsh> /abs/path/plan-pass.sh gates <run-dir> <laptop|runner> <clone|downloaded> [<example-dir>]
#       The per-file gates alone, over the absolute .tf paths on standard input. Read only,
#       for the fixtures and skip-coverage.sh. <example-dir>, absolute, is the example root
#       the event bus rule needs; without it that rule never passes.
#   <bash|zsh> /abs/path/plan-pass.sh scope <run-dir> <absolute directory>
#       The clone scope of one example directory under the clone: its .tf files and those of
#       the local module directories it reaches, one absolute path per line. Read only, for
#       skip-coverage.sh.
#
# <run-dir> is the absolute run directory Workspace printed, "<root>/pr-review.XXXXXX", holding
# the clone at <run-dir>/clone and, when it exists, the base worktree at <run-dir>/base.

RUN=${2:-}
ROOT="${RUN%/*}"
case "$ROOT" in /?*) ;; *) echo "plan-pass.sh: the run directory must be absolute" >&2; exit 2 ;; esac
case "$RUN" in "$ROOT"/pr-review.??????) ;; *) echo "plan-pass.sh: not a run directory: $RUN" >&2; exit 2 ;; esac
DIR="$RUN/clone"
[ -d "$DIR" ] || { echo "plan-pass.sh: no clone in $RUN" >&2; exit 2; }
CROOT="$(cd "$DIR" && pwd -P)"

names() { # directory
  find "$1" -path "$1/.git" -prune -o \( -name .terraform -o -name terraform.d \
    -o -name '*.tfstate*' -o -name terraform.rc -o -name .terraformrc -o -name crash.log \
    -o -name '*.tf.json' -o -name '*_override.tf' -o -name override.tf \
    -o -name '*.auto.tfvars' -o -name '*.auto.tfvars.json' -o -name terraform.tfvars \
    -o -name terraform.tfvars.json \) -print | sed 's/^/G0 /'
}
links() { # directory: links whose real path leaves it
  find "$1" -path "$1/.git" -prune -o -type l -print | perl -MCwd=realpath -e '
    my $root = shift;
    while (my $l = <STDIN>) { chomp $l; my $r = realpath($l); print "G0 $l\n" unless defined $r && index("$r/", "$root/") == 0 }
  ' "$1"
}
g0() { names "$1"; links "$1"; }

GATES_PL='
use strict; use warnings; use Cwd qw(realpath);
my ($mode, $root, $gm, $ex) = @ARGV; $root = realpath($root); my $run = ($gm // "") eq "runner";
$ex = defined $ex && length $ex ? realpath($ex) : undef;
my %pok = map { ("registry.terraform.io/hashicorp/$_" => 1) } qw(aws random time tls cloudinit);
my @pre = qw(aws_ random_ time_ tls_ cloudinit_);
my %dok = map { ($_ => 1) } qw(aws_caller_identity aws_canonical_user_id aws_partition aws_region aws_availability_zones aws_iam_policy_document aws_service_principal aws_default_tags tls_public_key cloudinit_config);
my %top = map { ($_ => 1) } qw(terraform provider variable locals output resource data module moved removed);
my $reg = qr{\A(?:registry\.terraform\.io/)?terraform-aws-modules/[a-z0-9-]+/aws(?://modules/[a-z0-9_-]+)?\z};
my $B = qr{(?<b>\{(?:[^{}]++|(?&b))*\})};
sub hit { my ($g, $f, $t, $p) = @_; my $l = defined $p ? 1 + (substr($t, 0, $p) =~ tr/\n//) : 0; print "$g $f:$l\n" }
sub canon { my $s = lc shift; $s = "registry.terraform.io/$s" if ($s =~ tr{/}{}) == 1; $s }
my $rre = qr{\A(?:${\ ($ENV{PLAN_PROV_RE} // "(?!)")})\z};
sub pok { my $c = canon(shift); $run ? $c =~ $rre : $pok{$c} }
sub blank { my $t = shift; $t =~ s{"((?:[^"\\\n]|\\.)*)"}{"\"" . ($1 =~ tr/\n/x/cr) . "\""}ge; $t }
# A keyword written right against its first label, `data"t""n"{`, is valid HCL that the label patterns below,
# which want a space, would not see. It is a hit, and so is a carriage return, form feed or vertical tab,
# which Terraform reads as line or space where the lexer and the patterns read text.
my $ADJ = qr{\b(?:resource|data|provider|module|variable|output|locals|terraform|moved|removed|ephemeral|check|import|action|backend|cloud|provisioner|connection|lifecycle|dynamic|required_providers)"};
my $KW = qr{\b(?:resource|data|provider|module|moved|removed|ephemeral|check|import|action|backend|cloud|provisioner|dynamic)\s+[A-Za-z_][\w-]*(?:\s*"[^"]*"|\s+[A-Za-z_][\w-]*)*\s*\{};
# Runner mode only (plan-pass.md, Modes). One lexer masks strings, comments and heredocs with
# spaces of the same length, newlines kept, so offsets in the mask are offsets in the raw text.
my $gh = qr{\A(?:github\.com/|git\@github\.com:|git::https://github\.com/|git::ssh://git\@github\.com/)};
my $CRED = qr{access_key|secret_key|token|profile|shared_credentials_files?|shared_config_files|assume_role(?:_with_web_identity)?|role_arn|endpoints|custom_ca_bundle|https?_proxy|no_proxy|insecure|ec2_metadata_service_endpoint(?:_mode)?};
sub fill { (my $x = shift) =~ s/[^\n]/ /g; $x }
sub skip_string { # at an opening quote; returns the offset after its closing quote, or -1
  my ($sr) = @_; $$sr =~ /\G"/gc; my @m = ("S");
  while (@m) {
    if ($m[-1] eq "S") {
      if ($$sr =~ /\G[\$%]\{/gc) { push @m, 0; next }
      if ($$sr =~ /\G(?:\\.|\$\$\{|%%\{|[^"\\\$%\n]+|[\$%])/gc) { next }
      if ($$sr =~ /\G"/gc) { pop @m; next }
      return -1;
    }
    if ($$sr =~ /\G"/gc) { push @m, "S"; next }
    if ($$sr =~ /\G\{/gc) { $m[-1]++; next }
    if ($$sr =~ /\G\}/gc) { if ($m[-1] > 0) { $m[-1]-- } else { pop @m } next }
    if ($$sr =~ /\G[^"{}]+/gc) { next }
    return -1;
  }
  return pos($$sr);
}
sub mask { # returns the mask, or undef when a string, comment or heredoc does not end
  my $s = shift; my $o = ""; pos($s) = 0;
  while (pos($s) < length $s) {
    my $p = pos($s);
    if ($s =~ /\G(?:#|\/\/)[^\n]*/gc) { $o .= fill($&); next }
    if ($s =~ /\G\/\*.*?\*\//gcs) { $o .= fill($&); next }
    return undef if $s =~ /\G\/\*/gc;
    if ($s =~ /\G<<-?([A-Za-z_][\w-]*)[ \t]*\n/gc) {
      my $id = $1;
      return undef unless $s =~ /\G(.*?)^[ \t]*\Q$id\E[ \t]*$/gcsm;
      # Terraform ends a heredoc at a line equal to the marker once trimmed of any Unicode space;
      # a body line that would be that, read with every space and non-ASCII byte dropped, fails.
      for (split /\n/, $1) { (my $t = $_) =~ s/[\s\x80-\xff]//g; return undef if $t eq $id }
      $o .= "<<" . fill(substr($s, $p + 2, pos($s) - $p - 2)); next;
    }
    if (substr($s, $p, 1) eq "\"") {
      my $e = skip_string(\$s); return undef if $e < 0;
      $o .= "\"" . fill(substr($s, $p + 1, $e - $p - 2)) . "\""; pos($s) = $e; next;
    }
    $s =~ /\G./gcs; $o .= $&;
  }
  return $o;
}
sub fixed_role { # masked and raw inner text of one assume_role block
  my ($m, $r) = @_; my $n = 0;
  (my $x = $m) =~ s/^[ \t]*(?:role_arn|session_name)[ \t]*=[ \t]*"[ ]*"[ \t]*$//mg;
  return 0 if $x =~ /\S/;
  while ($m =~ /^[ \t]*role_arn[ \t]*=[ \t]*"/mg) {
    my $v = substr($r, $+[0]) =~ /\A([^"]*)"/ ? $1 : "";
    return 0 unless $v =~ m{\Aarn:aws[a-z-]*:iam::[0-9]{12}:role/[\w+=,.\@/-]+\z};
    $n++;
  }
  return $n == 1;
}
sub runner_file {
  my ($f, $raw) = @_;
  my $m = mask($raw);
  unless (defined $m) { hit("G0", $f); return }
  hit("G3", $f, $m, $-[0]) if $m =~ $ADJ;
  hit("G0", $f, $m, $-[0]) if $m =~ /[^\x00-\x7f]/;
  while ($m =~ /^[ \t]*[A-Za-z_][\w-]*((?:[ \t]+"[^"\n]*")+)[ \t]*\{/mg) {
    hit("G0", $f, $m, $-[1]) if substr($raw, $-[1], $+[1] - $-[1]) =~ /[^\x00-\x7f]/;
  }
  while ($m =~ /$KW/g) { hit("G3", $f, $m, $-[0]) }
  for my $t ($raw, $m) { while ($t =~ /(?:\bcloud\s*\{|backend\s+")/g) { hit("G3", $f, $t, $-[0]) } }
  while ($m =~ /\bprovider\s+"[^"]*"\s*/g) {
    my ($at, $e) = ($-[0], $+[0]);
    my $name = substr($raw, $at, $e - $at) =~ /"([^"]*)"/ ? lc $1 : "";
    unless ($m =~ /\G$B/gc) { hit("G3", $f, $m, $at); next }
    next unless $name eq "aws" || $name eq "awscc";
    my ($b0, $b1) = ($-[0] + 1, $+[0] - 1);
    my $body = substr($m, $b0, $b1 - $b0);
    my ($rest, $exc) = ($body, 0);
    if ($body =~ /(?:\A|[\s{;,])assume_role\s*($B)/) {
      my ($s0, $i0, $i1) = ($-[0], $-[1], $+[1]);
      if (fixed_role(substr($body, $i0 + 1, $i1 - $i0 - 2), substr($raw, $b0 + $i0 + 1, $i1 - $i0 - 2))) {
        $exc = 1; substr($rest, $s0, $i1 - $s0) = fill(substr($rest, $s0, $i1 - $s0));
      }
    }
    my $bad = $rest =~ /<</ || $rest =~ /(?:\A|[\s{;,])(?:$CRED)\s*[={]/;
    while (!$bad && $rest =~ /\bdynamic\s+"([^"]*)"/g) {
      $bad = substr($raw, $b0 + $-[1], $+[1] - $-[1]) =~ /\A\s*(?:$CRED)\s*\z/;
    }
    if ($bad) { hit("G3", $f, $m, $at) } elsif ($exc) { hit("Xrole", $f, $m, $at) }
  }
  (my $dir = $f) =~ s{/[^/]*\z}{};
  while ($m =~ /\brequired_providers\s*/g) {
    my $at = $-[0];
    unless ($m =~ /\G$B/gc) { hit("G1", $f, $m, $at); next }
    my $b0 = $-[0] + 1; my $bb = substr($m, $b0, $+[0] - $b0 - 1);
    while ($bb =~ /^\s*([A-Za-z_][\w-]*)\s*=\s*($B|"[^"]*")/mg) {
      my ($n, $vs, $ve) = ($1, $-[2], $+[2]); my $src = "hashicorp/$n";
      if (substr($bb, $vs, $ve - $vs) =~ /\bsource\s*=\s*"/) {
        ($src) = substr($raw, $b0 + $vs + $+[0]) =~ /\A([^"]*)"/; $src //= "";
      }
      if (canon($src) eq "registry.terraform.io/kreuzwerker/docker") { hit("Xdocker", $f, $m, $at) }
      elsif ($mode eq "clone" && !pok($src)) { hit("G1", $f, $m, $at) }
      # a local name must be its source type, so the aws checks cannot be renamed away
      hit("G1", $f, $m, $at) if lc($n) ne (canon($src) =~ m{([^/]*)\z})[0];
    }
  }
  # A module call whose own argument is build_in_docker = true, the literal: its packaging
  # calls Docker at plan, and the runner has none. Nested maps and expressions do not count.
  while ($m =~ /\bmodule\s+"[^"]*"\s*/g) {
    my $at = $-[0];
    next unless $m =~ /\G$B/gc;
    (my $top = substr($+{b}, 1, -1)) =~ s/$B/fill($&)/ge;
    hit("Xdocker", $f, $m, $at) if $top =~ /^[ \t]*build_in_docker[ \t]*=[ \t]*true[ \t]*$/m;
  }
  return unless $mode eq "clone";
  while ($m =~ /\bmodule\s+"[^"]*"\s*/g) {
    my $at = $-[0];
    unless ($m =~ /\G$B/gc) { hit("G2", $f, $m, $at); next }
    my $b0 = $-[0];
    unless (substr($m, $b0, $+[0] - $b0) =~ /\bsource\s*=\s*"/) { hit("G2", $f, $m, $at); next }
    my ($s) = substr($raw, $b0 + $+[0]) =~ /\A([^"]*)"/; $s //= "";
    if ($s =~ m{\A\.\.?/}) {
      my $r = realpath("$dir/$s");
      hit("G2", $f, $m, $at) unless defined $r && index("$r/", "$root/") == 0;
    } else {
      hit("G2", $f, $m, $at) unless $s =~ $reg || $s =~ $gh;
    }
  }
}
# Laptop mode only (plan-pass.md, Data sources and provider flags): the relaxed data source
# rules and provider skip flags, all off when a file BAN names is anywhere in scope.
my %dfree = map { ($_ => 1) } qw(aws_arn aws_cloudwatch_log_data_protection_policy_document);
# Data sources whose read makes no API call, so their region goes nowhere (plan-pass.md, Data source regions)
my %rfree = map { ($_ => 1) } qw(aws_region aws_service_principal);
my $BAN = qr{\A(?:override\.tf|.*_override\.tf|.*\.tfvars|.*\.tfvars\.json|.*\.auto\.tfvars.*|.*\.tf\.json)\z}s;
my $ARNOK = qr{\Aarn:(?:aws(?:-[a-z]+)*|\$\{data\.aws_partition\.[A-Za-z_][\w-]*\.partition\}):iam::aws:policy/([A-Za-z0-9+=,.\@_-]+(?:/[A-Za-z0-9+=,.\@_-]+)*)\z};
my $NAMEOK = qr{\A[A-Za-z0-9._-]{1,256}\z};
my $REGIONOK = qr{\A[a-z]{2}(?:-[a-z]+)+-[0-9]{1,2}\z};
my $SKIPOK = qr{\A\s*(?:(?:#|//).*|(?:skip_metadata_api_check|skip_credentials_validation|skip_requesting_account_id)\s*=\s*(?:true|false)\s*|skip_region_validation\s*=\s*false\s*)\z};
sub blocks { # masked and raw text, keyword: [[labels], body start, body end, header start] per block
  my ($m, $r, $kw) = @_; my @b;
  # \s* as Terraform reads it, so a keyword against its label, which $ADJ also refuses, is still seen
  while ($m =~ /\b\Q$kw\E((?:\s*"[^"\n]*")+)\s*(?=\{)/g) {
    my $h = $-[0];
    my @l = substr($r, $-[1], $+[1] - $-[1]) =~ /"([^"\n]*)"/g;
    next unless $m =~ /\G$B/gc;
    push @b, [\@l, $-[0] + 1, $+[0] - 1, $h];
  }
  return @b;
}
sub tok { # masked and raw text, value start and end: [kind, value]
  my ($m, $r, $s, $e) = @_;
  return ["other"] unless substr($m, $s, $e - $s) =~ /\A[ \t]*(.*?)[ \t]*\z/;
  my ($t, $o) = ($1, $s + $-[1]);
  if ($t =~ /\A"( *)"\z/) { my $c = substr($r, $o + 1, length $1); return $c =~ /[\$%]\{/ ? ["other"] : ["str", $c] }
  return ["null"] if $t eq "null";
  return ["bool", $t] if $t eq "true" || $t eq "false";
  return ["var", $1] if $t =~ /\Avar\.([A-Za-z_][A-Za-z0-9_-]*)\z/;
  return ["local", $1] if $t =~ /\Alocal\.([A-Za-z_][A-Za-z0-9_-]*)\z/;
  return ["other"];
}
sub lit { $_[0][0] =~ /\A(?:str|null|bool)\z/ }
sub body_lines { # masked text, body start and end: [name, value start, value end] per line, or undef
  my ($m, $s, $e) = @_; my @a; my $p = $s;
  for my $l (split /\n/, substr($m, $s, $e - $s), -1) {
    if ($l =~ /\S/) {
      return undef unless $l =~ /\A[ \t]*([A-Za-z_][\w-]*)[ \t]*=[ \t]*(?=\S)/;
      push @a, [$1, $p + $+[0], $p + length $l];
    }
    $p += length($l) + 1;
  }
  return \@a;
}
sub top_attrs { # masked and raw text, body start and end: (name => token, ...) and the names seen twice
  my ($m, $r, $s, $e) = @_; my (%a, %dup);
  (my $x = substr($m, $s, $e - $s)) =~ s/$B/fill($&)/ge;
  my $p = $s;
  for my $l (split /\n/, $x, -1) {
    if ($l =~ /\A[ \t]*([A-Za-z_][\w-]*)[ \t]*=[ \t]*/) {
      $dup{$1} = 1 if exists $a{$1};
      $a{$1} = tok($m, $r, $p + $+[0], $p + length $l);
    }
    $p += length($l) + 1;
  }
  return (\%a, \%dup);
}
my @F; my %M; my (@calls, %vars, %dirs, %loc, %lbad); my ($ban, $a3, $lall) = (0, 0, 0);
while (my $f = <STDIN>) {
  chomp $f; my ($fh, $raw);
  if ($f ne "UNREADABLE" and open($fh, "<", $f)) { $raw = do { local $/; <$fh> }; close $fh }
  push @F, [$f, $raw];
}
unless ($run) {
  $a3 = $mode eq "clone" && defined $ex;
  for (@F) {
    my ($f, $raw) = @$_;
    (my $d = $f) =~ s{/[^/]*\z}{}; my $rd = realpath($d);
    unless (defined $raw) { $a3 = 0; if (defined $rd) { $lbad{$rd} = 1 } else { $lall = 1 } next }
    unless (defined $rd) { $ban = 1; next }
    $dirs{$rd} = 1;
    my $m = $M{$f} = mask($raw);
    unless (defined $m) { $a3 = 0; $lbad{$rd} = 1; next }
    # A dot file, which only the downloaded mode lists, is gated but never read for calls,
    # variables or locals: Terraform ignores it
    next if $f =~ m{(?:\A|/)\.[^/]*\z};
    # Locals: each name counted over every locals block of the directory
    while ($m =~ /\blocals\s*(?=\{)/g) {
      next unless $m =~ /\G$B/gc;
      my ($a, $dup) = top_attrs($m, $raw, $-[0] + 1, $+[0] - 1);
      for my $k (keys %$a) { $loc{$rd}{$k}{n} += $dup->{$k} ? 2 : 1; $loc{$rd}{$k}{t} = $a->{$k} }
    }
    for my $b (blocks($m, $raw, "module")) {
      my ($a, $dup) = top_attrs($m, $raw, $b->[1], $b->[2]);
      my $st = $a->{source} && !$dup->{source} ? $a->{source} : ["other"];
      unless ($st->[0] eq "str") { $a3 = 0; next }
      my $s = $st->[1];
      if ($s =~ m{\A\.\.?/}) {
        my $t = realpath("$rd/$s");
        unless (defined $t && -d $t) { $a3 = 0; next }
        $dirs{$t} = 1;
        $a3 = 0 unless index("$t/", "$root/") == 0;
        push @calls, [$rd, $t, $a, $dup];
      } elsif ($s !~ $reg) { $a3 = 0 }
    }
    for my $b (blocks($m, $raw, "variable")) {
      my ($a, $dup) = top_attrs($m, $raw, $b->[1], $b->[2]); my $n = $b->[0][0];
      my $dv = exists $vars{$rd}{$n} || @{ $b->[0] } != 1 || $dup->{default} || $dup->{nullable};
      $vars{$rd}{$n} = { default => $a->{default}, nullable => $a->{nullable}, dup => $dv };
    }
  }
  for my $d (sort keys %dirs) {
    my $h; unless (opendir($h, $d)) { $ban = 1; next }
    $ban = 1 if grep { $_ =~ $BAN } readdir $h;
    closedir $h;
  }
  $a3 = 0 if $ban;
}
sub policy_ok { # masked and raw text, body start and end
  my ($m, $r, $s, $e) = @_; my %n;
  my $al = body_lines($m, $s, $e) or return 0;
  for (@$al) {
    my ($k, $vs, $ve) = @$_; $n{$k}++; my $v = substr($m, $vs, $ve - $vs);
    if ($k eq "count") { return 0 if $v =~ /<</; next }
    return 0 unless $k eq "arn" && $v =~ /\A"( *)"[ \t]*\z/;
    return 0 unless substr($r, $vs + 1, length $1) =~ $ARNOK;
    my $p = $1;
    return 0 if length($p) > 512 || grep { $_ eq "." || $_ eq ".." } split m{/}, $p, -1;
  }
  return ($n{arn} // 0) == 1 && ($n{count} // 0) <= 1;
}
sub rl { # token, directory: local.NAME as the bare literal it is declared once as, or undef
  my ($t, $d) = @_;
  return $t unless $t->[0] eq "local";
  return undef if $ban || $lall || !defined $d || $lbad{$d};
  my $v = $loc{$d}{$t->[1]};
  return undef unless $v && $v->{n} == 1 && lit($v->{t});
  return $v->{t};
}
sub eff { # token, module call, module directory: the value Terraform takes, or undef when unknown
  my ($t, $c, $d) = @_;
  return $t unless $t->[0] eq "var";
  my $n = $t->[1]; my $v = $vars{$d}{$n};
  return undef unless $v && !$v->{dup} && !$c->[3]{$n};
  my ($nl, $df) = ($v->{nullable}, $v->{default});
  return undef if $nl && $nl->[0] ne "bool";
  my $dflt = $df && lit($df) ? $df : undef;
  return $dflt unless exists $c->[2]{$n};
  my $x = rl($c->[2]{$n}, $c->[0]);
  return undef unless defined $x;
  return $x if $x->[0] eq "str" || $x->[0] eq "bool";
  return $nl && $nl->[1] eq "false" ? $dflt : ["null"] if $x->[0] eq "null";
  return undef;
}
sub bus_pass { # effective name and region
  my ($nm, $rg) = @_;
  return defined $nm && defined $rg && $nm->[0] eq "str" && $nm->[1] =~ $NAMEOK
    && ($rg->[0] eq "null" || ($rg->[0] eq "str" && $rg->[1] =~ $REGIONOK));
}
sub region_val { my $t = shift; defined $t && ($t->[0] eq "null" || ($t->[0] eq "str" && $t->[1] =~ $REGIONOK)) }
sub region_ok { # file, masked and raw text, body start and end of a data block: its region argument
  my ($f, $m, $r, $s, $e) = @_;
  my ($a, $dup) = top_attrs($m, $r, $s, $e);
  return 0 if $dup->{region};
  return 1 unless exists $a->{region};
  (my $d = $f) =~ s{/[^/]*\z}{}; $d = realpath($d);
  my $t = rl($a->{region}, $d);
  return 0 unless defined $t;
  return region_val($t) if lit($t);
  # var.NAME only in a module directory of the clone scope, resolved per call as the event bus is
  return 0 unless $a3 && $t->[0] eq "var";
  return 0 unless defined $d && $d ne $ex;
  my @c = grep { $_->[1] eq $d } @calls;
  return 0 unless @c;
  for my $c (@c) { return 0 unless $c->[0] eq $ex && region_val(eff($t, $c, $d)) }
  return 1;
}
sub bus_ok { # file, masked and raw text, body start and end
  my ($f, $m, $r, $s, $e) = @_; my (%n, %t);
  return 0 unless $a3;
  my $al = body_lines($m, $s, $e) or return 0;
  for (@$al) {
    my ($k, $vs, $ve) = @$_; $n{$k}++;
    return 0 unless $k =~ /\A(?:count|name|region)\z/;
    if ($k eq "count") { return 0 if substr($m, $vs, $ve - $vs) =~ /<</; next }
    $t{$k} = tok($m, $r, $vs, $ve);
  }
  return 0 unless ($n{name} // 0) == 1 && ($n{count} // 0) <= 1 && ($n{region} // 0) <= 1;
  $t{region} //= ["null"];
  (my $d = $f) =~ s{/[^/]*\z}{}; $d = realpath($d); return 0 unless defined $d;
  for my $k (keys %t) { $t{$k} = rl($t{$k}, $d); return 0 unless defined $t{$k} }
  return lit($t{name}) && lit($t{region}) && bus_pass($t{name}, $t{region}) if $d eq $ex;
  for (values %t) { return 0 unless lit($_) || $_->[0] eq "var" }
  my @c = grep { $_->[1] eq $d } @calls;
  return 0 unless @c;
  for my $c (@c) { return 0 unless $c->[0] eq $ex && bus_pass(eff($t{name}, $c, $d), eff($t{region}, $c, $d)) }
  return 1;
}
for (@F) {
  my ($f, $raw) = @$_;
  unless (defined $raw) { hit("G0", $f); next }
  hit("G0", $f) if $f =~ m{(?:\A|/)(?:[^/]*_)?override\.tf\z};
  hit("G0", $f, $raw, $-[0]) if $raw =~ /[\r\f\x0b]/;
  if ($run) { runner_file($f, $raw); next }
  my %rel; # a relaxed type: [every block of it passed, how many blocks]
  if (!$ban && defined $M{$f}) {
    for my $b (blocks($M{$f}, $raw, "data")) {
      my $y = $b->[0][0] // ""; next unless @{ $b->[0] } == 2;
      next unless $y eq "aws_iam_policy" || $y eq "aws_cloudwatch_event_bus";
      my $ok = $y eq "aws_iam_policy" ? policy_ok($M{$f}, $raw, $b->[1], $b->[2]) : bus_ok($f, $M{$f}, $raw, $b->[1], $b->[2]);
      $rel{$y}[0] = ($rel{$y}[0] // 1) && $ok; $rel{$y}[1]++;
    }
  }
  # The region argument of every data block (plan-pass.md, Data source regions)
  if (defined $M{$f}) {
    for my $b (blocks($M{$f}, $raw, "data")) {
      next if @{ $b->[0] } == 2 && $rfree{$b->[0][0]};
      hit("G3", $f, $M{$f}, $b->[3]) unless region_ok($f, $M{$f}, $raw, $b->[1], $b->[2]);
    }
  } elsif ($raw =~ /\bdata\s+"/) { hit("G3", $f) }
  (my $code = blank($raw)) =~ s{(?:#|//)[^\n]*}{}g;
  hit("G0", $f, $code, $-[0]) if $code =~ /[^\x00-\x7f]/;
  (my $lb = $raw) =~ s{(?:#|//)[^\n]*}{}g;
  while ($lb =~ /^[ \t]*[A-Za-z_][\w-]*((?:[ \t]+"[^"\n]*")+)[ \t]*\{/mg) { my ($at, $l) = ($-[1], $1); hit("G0", $f, $lb, $at) if $l =~ /[^\x00-\x7f]/ }
  hit("G0", $f, $code, $-[0]) if $code =~ m{/\*};
  hit("G3", $f, $code, $-[0]) if $code =~ $ADJ;
  while ($code =~ /$KW/g) { hit("G3", $f, $code, $-[0]) }
  (my $nc = $raw) =~ s{(?:#|//)[^\n]*}{}g;
  for my $t ($raw, $nc) {
    my $bt = blank($t);
    while ($t =~ /(?:provisioner|\bfile\w*\s*\(|templatefile\s*\(|provider::|\bcloud\s*\{|backend\s+")/g) { hit("G3", $f, $t, $-[0]) }
    while ($t =~ /^([A-Za-z_][\w-]*)(?:\s+"[^"]*")*\s*\{/mg) { hit("G3", $f, $t, $-[0]) unless $top{$1} }
    while ($t =~ /^\s*(?:ephemeral|check|import|action)\b(?:\s+"[^"]*")*\s*\{/mg) { hit("G3", $f, $t, $-[0]) }
    my %seen; while ($t =~ /\b(resource|data)\s+"([^"]*)"/g) { $seen{$2}++ if $1 eq "data" }
    while ($t =~ /\b(resource|data)\s+"([^"]*)"/g) {
      my ($k, $y, $at) = ($1, $2, $-[0]);
      my $ok = grep { index($y, $_) == 0 } @pre;
      # A relaxed type passes only when every mention of it is a block that passed its rule
      my $rx = $rel{$y} && $rel{$y}[0] && $rel{$y}[1] == $seen{$y};
      $ok = 0 if $k eq "data" && !$dok{$y} && !(!$ban && defined $M{$f} && $dfree{$y}) && !$rx;
      hit("G3", $f, $t, $at) unless $ok;
    }
    while ($bt =~ /\bprovider\s+"[^"]*"\s*/g) {
      my $at = $-[0];
      if ($bt =~ /\G$B/gc) {
        my $b0 = $-[0] + 1;
        my $body = my $body0 = substr($+{b}, 1, -1);
        if ($body =~ /<</) { hit("G3", $f, $bt, $at); next }
        $body =~ s/\bdefault_tags\s*$B//g;
        # skip_region_validation = true only beside one region set to a bare literal region name;
        # the values are read from the text before strings were filled, at the same offsets
        (my $bf = $body0) =~ s/\bdefault_tags\s*$B/fill($&)/ge;
        my @rg; while ($bf =~ /^[ \t]*region[ \t]*=[ \t]*(.*?)[ \t]*$/mg) { push @rg, substr($t, $b0 + $-[1], $+[1] - $-[1]) }
        my $rlit = @rg == 1 && $rg[0] =~ /\A"([^"]*)"\z/ && $1 =~ $REGIONOK;
        for my $line (split /\n/, $body) {
          next unless $line =~ /\S/;
          next if !$ban && $line =~ $SKIPOK;
          next if !$ban && $rlit && $line =~ /\A\s*skip_region_validation\s*=\s*true\s*\z/;
          if ($line !~ /\A\s*(?:region|alias)\s*=/) { hit("G3", $f, $bt, $at); last }
        }
      } else { hit("G3", $f, $bt, $at) }
    }
  }
  next unless $mode eq "clone";
  (my $dir = $f) =~ s{/[^/]*\z}{};
  my $bl = blank($raw);
  while ($bl =~ /\brequired_providers\s*/g) {
    my $at = $-[0];
    if ($bl =~ /\G$B/gc) {
      my ($b0, $b1) = ($-[0] + 1, $+[0] - 1);
      my ($bb, $rb) = (substr($bl, $b0, $b1 - $b0), substr($raw, $b0, $b1 - $b0));
      while ($bb =~ /^\s*([A-Za-z_][\w-]*)\s*=\s*($B|"[^"]*")/mg) {
        my ($n, $v) = ($1, substr($rb, $-[2], $+[2] - $-[2])); my $src = "hashicorp/$n";
        if ($v =~ /\A\{/) { $src = $1 if $v =~ /\bsource\s*=\s*"([^"]*)"/ }
        hit("G1", $f, $raw, $at) unless $pok{canon($src)};
      }
    } else { hit("G1", $f, $raw, $at) }
  }
  while ($bl =~ /\bmodule\s+"[^"]*"\s*/g) {
    my $at = $-[0];
    unless ($bl =~ /\G$B/gc) { hit("G2", $f, $raw, $at); next }
    my $body = substr($raw, $-[0], $+[0] - $-[0]);
    unless ($body =~ /\bsource\s*=\s*"([^"]*)"/) { hit("G2", $f, $raw, $at); next }
    my $s = $1;
    if ($s =~ m{\A\.\.?/}) {
      my $r = realpath("$dir/$s");
      hit("G2", $f, $raw, $at) unless defined $r && index("$r/", "$root/") == 0;
    } else {
      hit("G2", $f, $raw, $at) unless $s =~ $reg;
    }
  }
}
'
scope() { # absolute example directory
  perl -MCwd=realpath -e '
    my ($root, @q) = (realpath($ARGV[0]), realpath($ARGV[1])); my (%seen, %f);
    while (defined(my $d = shift @q)) {
      next if $seen{$d}++;
      opendir(my $h, $d) or do { print "UNREADABLE\n"; next };
      # Terraform ignores a file whose name starts with a dot, so the scope does too
      for my $n (sort grep { /\.tf\z/ && !/\A\./ } readdir $h) {
        my $p = "$d/$n"; $f{$p} = 1;
        open(my $fh, "<", $p) or do { print "UNREADABLE\n"; next };
        local $/; my $t = <$fh>;
        while ($t =~ /\bsource\s*=\s*"(\.\.?\/[^"]*)"/g) {
          my $r = realpath("$d/$1");
          push @q, $r if defined $r && -d $r && index("$r/", "$root/") == 0;
        }
      }
    }
    print "$_\n" for sort keys %f;
  ' "$CROOT" "$1"
}
rel() { sed -e "s|^$CROOT\$|.|" -e "s|$CROOT/||g" -e "s|$PLAN/data/[^/]*/modules/|downloaded/|g"; }
gate_class() { # all hits as one argument: prints each, sets CLASS to the first and the count
  GH="$(printf '%s\n' "$1" | rel | awk '!seen[$0]++')"; n="$(printf '%s\n' "$GH" | grep -c .)"
  printf '%s\n' "$GH" | sed 's/^/gate-hit /'
  CLASS="plan gate $(printf '%s\n' "$GH" | head -n 1) ($n hits)"
}
exc_or_gate() { # all hits as one argument: a gate hit wins; exceptions alone are a recorded exception
  g="$(printf '%s\n' "$1" | grep -v '^X')"
  if [ -n "$g" ]; then gate_class "$g"; return; fi
  printf '%s\n' "$1" | rel | awk '!seen[$0]++' | sed 's/^X[a-z]* /exception-hit /'
  case "$1" in
    Xrole*) CLASS='exception: example assumes a role in another account' ;;
    *) CLASS='exception: needs a Docker daemon' ;;
  esac
}
PHERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
# Runner mode: the eight named providers, plus the profile's lines (plan-pass.md, Runner providers)
RPROV='hashicorp/(aws|random|time|tls|cloudinit|null|local|external)'
# The file is mounted beside this script in the runner, and read from the profile in a checkout
PFILE="$PHERE/plan-providers.txt"
[ -f "$PFILE" ] || PFILE="$PHERE/../../terraform-module-maintainer/profiles/terraform-aws-modules/plan-providers.txt"
if [ -f "$PFILE" ]; then
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in ''|'#'*) continue ;; esac
    printf '%s\n' "$l" | grep -Eqx '[a-z0-9-]+/(\*|[a-z0-9-]+)' ||
      { echo "plan pass not run: profile provider line refused"; exit 0; }
    RPROV="$RPROV|$(printf '%s' "$l" | sed 's/\*$/[a-z0-9-]+/')"
  done < "$PFILE"
fi
export PLAN_PROV_RE="registry\\.terraform\\.io/($RPROV)"
if [ "${1:-}" = gates ]; then
  case "${3:-}/${4:-}" in laptop/clone|laptop/downloaded|runner/clone|runner/downloaded) ;;
    *) echo "plan-pass.sh: gates <run-dir> <laptop|runner> <clone|downloaded> [<example-dir>]" >&2; exit 2 ;; esac
  h="$(perl -e "$GATES_PL" "$4" "$CROOT" "$3" "${5:-}")"
  [ -n "$h" ] && { printf '%s\n' "$h"; exc_or_gate "$h" > /dev/null; echo "class: $CLASS"; }
  exit 0
fi
if [ "${1:-}" = scope ]; then
  [ -d "${3:-}" ] || { echo "plan-pass.sh: scope <run-dir> <absolute directory>" >&2; exit 2; }
  scope "$3"
  exit 0
fi
if [ "${1:-}" = g0 ]; then
  if [ "${3:-}" = base ]; then
    [ -d "$RUN/base" ] || { echo "plan-pass.sh: no base worktree in $RUN" >&2; exit 2; }
    g0 "$(cd "$RUN/base" && pwd -P)" > "$RUN/g0-base.txt"
    echo "g0 base: $(grep -c . "$RUN/g0-base.txt") hits"
  else
    g0 "$CROOT" > "$RUN/g0.txt"
    echo "g0: $(grep -c . "$RUN/g0.txt") hits"
  fi
  exit 0
fi
[ "${1:-}" = plan ] || { echo "plan-pass.sh: first argument is g0, plan, gates or scope" >&2; exit 2; }

PROFILE=${3:-}
shift 3 2>/dev/null || { echo "plan pass not run: arguments missing"; exit 0; }
BASESHA=; GMODE=laptop; PHASE=; INDEX=; BUDGET=; ROLE_ARN=; DIFFDIRS=
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
while :; do
  case "${1:-}" in
    --base) BASESHA=${2:-}; shift 2 2>/dev/null || shift ;;
    --role-arn) ROLE_ARN=${2:-}; shift 2 2>/dev/null || shift ;;
    --mode) GMODE=${2:-}; shift 2 2>/dev/null || shift ;;
    --phase) PHASE=${2:-}; shift 2 2>/dev/null || shift ;;
    --index) INDEX=${2:-}; shift 2 2>/dev/null || shift ;;
    --budget) BUDGET=${2:-}; shift 2 2>/dev/null || shift ;;
    --diff-dir) DIFFDIRS="$DIFFDIRS${2:-}
"; shift 2 2>/dev/null || shift ;;
    *) break ;;
  esac
done

# Opt-in and tools: a failed check stops the pass here, with a note for the record
case "$GMODE" in laptop|runner) ;; *) echo "plan pass not run: mode unknown"; exit 0 ;; esac
# A plan diff directory is repository-relative: "." or plain segments, never "..". Any other
# loses only its own plan diff.
DIFFDIRS="$(printf '%s' "$DIFFDIRS" | grep -Ex '\.|[A-Za-z0-9_][A-Za-z0-9._-]*(/[A-Za-z0-9_][A-Za-z0-9._-]*)*')"
case "$PHASE" in
  '') ;;
  init) [ "$GMODE" = runner ] || { echo "plan pass not run: phase needs runner mode"; exit 0; } ;;
  plan|base-init|base-plan|show|validate|diff-init|diff-plan|diff) [ "$GMODE" = runner ] || { echo "plan pass not run: phase needs runner mode"; exit 0; }
    printf '%s\n' "$INDEX" | grep -Eqx '[1-9][0-9]{0,3}' && [ "$#" -eq 1 ] ||
      { echo "plan pass not run: phase $PHASE needs --index and one example"; exit 0; } ;;
  *) echo "plan pass not run: phase unknown"; exit 0 ;;
esac
if [ -n "$BUDGET" ]; then
  [ "$GMODE" = runner ] || { echo "plan pass not run: budget needs runner mode"; exit 0; }
  printf '%s\n' "$BUDGET" | grep -Eqx '[1-9][0-9]{0,6}' || { echo "plan pass not run: budget not a number of seconds"; exit 0; }
fi
# A guard against choosing runner mode by mistake on a workstation, not a proof of isolation
if [ "$GMODE" = runner ] && [ ! -e /.dockerenv ] && [ ! -e /run/.containerenv ]; then
  echo "plan pass not run: runner mode outside a container"; exit 0
fi
printf '%s\n' "$PROFILE" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9_-]{0,63}$' || { echo "plan pass not run: profile not opted in"; exit 0; }
# Laptop mode plans only with a session on a named review role; the runner issues its own
if [ "$GMODE" = laptop ]; then
  printf '%s\n' "$ROLE_ARN" | grep -Eqx 'arn:aws(-[a-z]+)*:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+' ||
    { echo "plan pass not run: no review role"; exit 0; }
  [ "${#ROLE_ARN}" -le 2048 ] || { echo "plan pass not run: no review role"; exit 0; }
  [ -f "$HERE/plan-session.sh" ] && [ -f "$HERE/plan-session-policy.json" ] ||
    { echo "plan pass not run: plan-session.sh missing"; exit 0; }
fi
for t in terraform jq aws perl git; do
  command -v "$t" > /dev/null 2>&1 || { echo "plan pass not run: $t missing"; exit 0; }
done
aws --version 2>&1 | grep -Eq '^aws-cli/2\.' || { echo "plan pass not run: AWS CLI version 2 missing"; exit 0; }
if [ -n "$PHASE" ] && [ "$PHASE" != init ]; then
  [ -d "$RUN/plan/state" ] || { echo "plan pass not run: no saved init phase"; exit 0; }
else
  [ -d "$RUN/plan" ] && { echo "plan pass not run: plan directory already exists"; exit 0; }
fi
# Runner mode: the runner's egress proxy, captured before env -i drops it, and the plan
# credentials the runner passed in, captured and removed from this process's environment
RPROXY=; RAK=; RSK=; RST=
if [ "$GMODE" = runner ]; then
  RPROXY=${HTTPS_PROXY:-}
  RAK=${PLAN_PASS_AWS_ACCESS_KEY_ID:-}; RSK=${PLAN_PASS_AWS_SECRET_ACCESS_KEY:-}; RST=${PLAN_PASS_AWS_SESSION_TOKEN:-}
  unset PLAN_PASS_AWS_ACCESS_KEY_ID PLAN_PASS_AWS_SECRET_ACCESS_KEY PLAN_PASS_AWS_SESSION_TOKEN
fi
case "$PHASE" in ''|init) echo "plan pass mode: $GMODE${PHASE:+, phase $PHASE}" ;; esac
if [ "$GMODE" = runner ]; then PROV_RE=$PLAN_PROV_RE
else PROV_RE='registry\.terraform\.io/hashicorp/(aws|random|time|tls|cloudinit)'; fi

PLAN="$RUN/plan"
if [ -z "$PHASE" ] || [ "$PHASE" = init ]; then
  mkdir -m 700 "$PLAN"
  mkdir "$PLAN/data" "$PLAN/cache" "$PLAN/home" "$PLAN/tmp" "$PLAN/out" "$PLAN/state" "$PLAN/saved"
  : > "$PLAN/cli.tfrc"; : > "$PLAN/aws-config"; : > "$PLAN/aws-credentials"
fi
# Laptop mode: the provider tree this run's acquisition unpacked, as verify takes it
# (verify-pass.md, The acquired provider tree): init links each pinned provider from it instead of unpacking it
# again. The runner has no such tree.
PTREE=
if [ "$GMODE" = laptop ] && [ -z "$PHASE" ] && bash "$HERE/ladder-pass.sh" tree "$RUN" --out "$PLAN/tree.tfrc" > /dev/null 2>&1; then
  PTREE="$PLAN/tree.tfrc"
fi
PGIDS=""
PTMP="$PLAN/tmp" # terraform's TMPDIR; in laptop mode a short directory made below
plan_stop() { # kill every process group this pass started, then remove the pass's own files
  for g in $(printf '%s\n' "$PGIDS"); do kill -KILL -- "-$g" 2>/dev/null; done
  wait 2>/dev/null
  case "$PTMP" in /tmp/pp.??????) rm -rf -- "$PTMP" ;; esac
  case "$ROOT" in /?*) ;; *) RUN= ;; esac
  case "$RUN" in
    "$ROOT"/pr-review.??????) rm -rf -- "$RUN/plan" ;;
    *) echo "refusing to delete: $RUN/plan" >&2 ;;
  esac
}
plan_abort() { # interrupted: remove the whole run, as Cleanup would
  plan_stop
  case "$RUN" in
    "$ROOT"/pr-review.??????) rm -rf -- "$RUN" ;;
    *) echo "refusing to delete: $RUN" >&2 ;;
  esac
}
plan_kill() { # a runner phase: kill this pass's process groups and keep the files for the next phase
  for g in $(printf '%s\n' "$PGIDS"); do kill -KILL -- "-$g" 2>/dev/null; done
  wait 2>/dev/null
}
if [ -n "$PHASE" ]; then
  trap 'plan_kill; exit 130' INT TERM
  trap plan_kill EXIT
else
  trap 'plan_abort; exit 130' INT TERM
  trap plan_stop EXIT
fi
# terraform starts each provider on a unix socket at $TMPDIR/plugin<digits>, and a socket
# path has at most 103 bytes on macOS and 107 on Linux. A laptop run directory sits under the
# caller's TMPDIR, which can be long, so terraform gets a short directory instead; the
# runner's /work/pr-review.XXXXXX/plan/tmp is short already.
if [ "$GMODE" = laptop ]; then
  PTMP="$(mktemp -d /tmp/pp.XXXXXX)" && chmod 700 "$PTMP" || { echo "plan pass not run: no short TMPDIR under /tmp"; exit 0; }
fi

TFDIR="$(dirname "$(command -v terraform)")"
AWSBIN="$(command -v aws)"
AK=; SK=; ST=
# The role ARN and its account id are never recorded: any line holding one is dropped
LEAKS="$ROLE_ARN $(printf '%s\n' "$ROLE_ARN" | sed -nE 's/^arn:[^:]*:iam::([0-9]{12}):.*/\1/p')"
set_env() { # example key
  TFENV=(env -i PATH="/usr/bin:/bin:$TFDIR" HOME="$PLAN/home" TMPDIR="$PTMP"
    TF_DATA_DIR="$PLAN/data/$1" TF_PLUGIN_CACHE_DIR="$PLAN/cache"
    TF_CLI_CONFIG_FILE="$PLAN/cli.tfrc" TF_IN_AUTOMATION=1 TF_INPUT=0
    CHECKPOINT_DISABLE=1 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
    GIT_TERMINAL_PROMPT=0 AWS_CONFIG_FILE="$PLAN/aws-config"
    AWS_SHARED_CREDENTIALS_FILE="$PLAN/aws-credentials"
    AWS_EC2_METADATA_DISABLED=true AWS_REGION=us-east-1 AWS_DEFAULT_REGION=us-east-1
    ${RPROXY:+HTTPS_PROXY=$RPROXY} ${RPROXY:+HTTP_PROXY=$RPROXY} ${RPROXY:+https_proxy=$RPROXY}
    ${RPROXY:+http_proxy=$RPROXY}
    ${AK:+AWS_ACCESS_KEY_ID=$AK} ${SK:+AWS_SECRET_ACCESS_KEY=$SK} ${ST:+AWS_SESSION_TOKEN=$ST})
}
CREDWHY= # the step that ended the pass at credentials and its reason, from a fixed list
cred_why() { # step, exit status, answer: sets CREDWHY to a fixed reason, never to the answer itself
  if [ "$2" -eq 142 ]; then CREDWHY="$1: timed out"; return; fi # perl's alarm: SIGALRM
  case "$3" in
    *ExpiredToken*) CREDWHY="$1: expired token" ;;
    *InvalidClientTokenId*|*SignatureDoesNotMatch*|*UnrecognizedClient*) CREDWHY="$1: invalid token" ;;
    *AccessDenied*) CREDWHY="$1: access denied" ;;
    *Throttling*|*RequestLimitExceeded*|*TooManyRequests*|*'Rate exceeded'*) CREDWHY="$1: throttled" ;;
    *'Could not connect'*|*'Connect timeout'*|*'Read timeout'*|*'Connection was closed'*|*ProxyConnect*|*'SSL validation failed'*)
      CREDWHY="$1: network" ;;
    *) CREDWHY="$1: other answer" ;;
  esac
}
get_creds() {
  CREDWHY='session: not issued'
  if [ "$GMODE" = runner ]; then
    # The runner exported them on its host and passed them to the plan phase only
    [ -n "$RAK" ] && [ -n "$RSK" ] && [ -n "$RST" ] || return 1
    AK=$RAK; SK=$RSK; ST=$RST
  else
    # A session on the review role, downscoped by the pinned policy; never the profile's own
    # Its reason on standard error is for the operator; this output is the record
    CREDS="$(bash "$HERE/plan-session.sh" "$PROFILE" "$ROLE_ARN" modulestf-plan-pass 2> /dev/null)" || return 1
    AK="$(printf '%s' "$CREDS" | jq -er .AccessKeyId)" || return 1
    SK="$(printf '%s' "$CREDS" | jq -er .SecretAccessKey)" || return 1
    ST="$(printf '%s' "$CREDS" | jq -er .SessionToken)" || return 1
  fi
  CREDS=; LEAKS="$LEAKS $AK $SK $ST"
  set_env none
  # Standard error only: standard output holds the account id, which is never kept
  PROBE="$("${TFENV[@]}" perl -e 'alarm 30; exec @ARGV' "$AWSBIN" sts get-caller-identity --no-cli-pager < /dev/null 2>&1 > /dev/null)"
  rc=$?; [ "$rc" -eq 0 ] || { cred_why 'identity check' "$rc" "$PROBE"; PROBE=; return 1; }
  # The write probe: a dry-run write the session must not be allowed. Only
  # UnauthorizedOperation goes on; DryRunOperation, any other answer or a timeout ends the pass.
  PROBE="$("${TFENV[@]}" perl -e 'alarm 30; exec @ARGV' "$AWSBIN" ec2 create-vpc --cidr-block 10.255.0.0/16 --dry-run --no-cli-pager < /dev/null 2>&1)"
  rc=$?
  case "$PROBE" in
    *'(UnauthorizedOperation)'*) PROBE=; CREDWHY= ;;
    *'(DryRunOperation)'*) PROBE=; CREDWHY='write probe: write allowed'; return 1 ;;
    *) cred_why 'write probe' "$rc" "$PROBE"; PROBE=; return 1 ;;
  esac
}

lock_hits() { # lock file: providers outside the mode's allowlist
  grep -Eo '^provider "[^"]*"' "$1" 2>/dev/null | sed 's/^provider "//; s/"$//' | grep -Evx "$PROV_RE" |
    while IFS= read -r p; do
      if [ "$GMODE" = runner ] && [ "$p" = registry.terraform.io/kreuzwerker/docker ]; then echo "Xdocker $1:0"
      else echo "G1 $1:$p"; fi
    done
}
committed_locks() { # example directory: providers in lock files the head committed
  for d in $(scope "$1" | grep '^/' | sed 's|/[^/]*$||' | sort -u); do
    (cd "$d" && git ls-files --error-unmatch .terraform.lock.hcl > /dev/null 2>&1) || continue
    lock_hits "$d/.terraform.lock.hcl"
  done
}
post_init() { # example key, absolute example directory
  M="$PLAN/data/$1/modules"
  [ -f "$2/.terraform.lock.hcl" ] || echo "G1 $2/.terraform.lock.hcl:0"
  lock_hits "$2/.terraform.lock.hcl"
  [ -d "$M" ] || return 0
  MR="$(cd "$M" && pwd -P)"
  perl -MJSON::PP -MCwd=realpath -e '
    my ($ex, $root, $j, $mr, $gm) = @ARGV;
    my $gh = qr{\A(?:github\.com/|git\@github\.com:|git::https://github\.com/|git::ssh://git\@github\.com/)};
    my $reg = qr{\A(?:registry\.terraform\.io/)?terraform-aws-modules/[a-z0-9-]+/aws(?://modules/[a-z0-9_-]+)?\z};
    (my $ml = $j) =~ s{/[^/]*\z}{};
    sub lex { my @p; for (split m{/}, $_[0]) { next if $_ eq "" || $_ eq "."; if ($_ eq "..") { pop @p } else { push @p, $_ } } "/" . join("/", @p) }
    open(my $fh, "<", $j) or do { print "G2 $j:0\n"; exit };
    my @m = @{ decode_json(do { local $/; <$fh> })->{Modules} }; my (%d, %l); $ml = lex($ml);
    for (@m) { my $p = $_->{Dir}; $p = "$ex/$p" unless $p =~ m{\A/}; $d{$_->{Key}} = realpath($p); $l{$_->{Key}} = lex($p) }
    for (@m) {
      next if $_->{Key} eq "";
      my ($k, $s, $r, $lp) = ($_->{Key}, $_->{Source}, $d{$_->{Key}}, $l{$_->{Key}});
      unless (defined $r && -d $r) { print "G2 $j:$k\n"; next }
      # Below the modules directory, written as given or as its real path, no path component may be a symbolic link.
      my $in; for my $pre ($ml, $mr) { if ($lp ne $pre && index("$lp/", "$pre/") == 0) { $in = $mr . substr($lp, length $pre); last } }
      if (defined $in && $r ne $in) { print "G2 $j:$k\n"; next }
      if (($s =~ $reg || ($gm eq "runner" && $s =~ $gh)) && !defined $in) { print "G2 $j:$k\n"; next }
      print "dir $r\n" if index("$r/", "$mr/") == 0;
      if ($s =~ $reg) { print "version $k $s $_->{Version}\n"; next }
      if ($gm eq "runner" && $s =~ $gh) { print "version $k $s -\n"; next }
      (my $pk = $k) =~ s/\.?[^.]*\z//;
      my $pd = $d{$pk}; my ($lim, $want);
      if (defined $pd && index("$pd/", "$mr/") == 0) {
        # A downloaded parent, even with the data directory in the clone: its whole package, reached with no symbolic link on the way.
        ($lim, $want) = ("$mr/$1", lex("$pd/$s")) if substr($pd, length($mr) + 1) =~ m{\A([^/]+)};
      } elsif (defined $pd && index("$pd/", "$root/") == 0) { $lim = $root }
      print "G2 $j:$k\n" unless $s =~ m{\A\.\.?/} && defined $lim && index("$r/", "$lim/") == 0 && (!defined $want || $r eq $want);
    }
  ' "$2" "$CROOT" "$M/modules.json" "$MR" "$GMODE" > "$PLAN/out/$1-modules.txt"
  grep -v '^dir ' "$PLAN/out/$1-modules.txt"
  sed -n 's/^dir //p' "$PLAN/out/$1-modules.txt" | sort -u | while IFS= read -r d; do
    pkg="$MR/$(printf '%s\n' "${d#"$MR"/}" | cut -d/ -f1)"
    find "$d" -maxdepth 1 \( -name .terraform -o -name terraform.d -o -name '*.tfstate*' \
      -o -name terraform.rc -o -name .terraformrc -o -name crash.log -o -name '*.tf.json' \
      -o -name '*_override.tf' -o -name override.tf -o -name '*.auto.tfvars' \
      -o -name '*.auto.tfvars.json' -o -name terraform.tfvars -o -name terraform.tfvars.json \) -print | sed 's/^/G0 /'
    find "$d" -maxdepth 1 -type l -print | perl -MCwd=realpath -e '
      my $root = shift;
      while (my $l = <STDIN>) { chomp $l; my $r = realpath($l); print "G0 $l\n" unless defined $r && index("$r/", "$root/") == 0 }
    ' "$pkg"
    find "$d" -maxdepth 1 \( -type f -o -type l \) -name '*.tf' | sort | perl -e "$GATES_PL" downloaded "$CROOT" "$GMODE"
  done
}
CAP_PL='
setpgrp(0, 0); my $out = shift; my $cap = $ENV{CAP_BYTES} || 1048576;
open(my $o, ">", $out) or exit 125;
my $pid = open(my $in, "-|"); exit 125 unless defined $pid;
if (!$pid) {
  if ($ENV{CAP_QUIET_ERR}) { open(STDERR, ">", "/dev/null") } else { open(STDERR, ">&", \*STDOUT) }
  open(STDIN, "<", "/dev/null"); exec @ARGV; exit 127;
}
my ($n, $buf) = (0, "");
while (my $r = sysread($in, $buf, 65536)) {
  if ($n + $r >= $cap) {
    syswrite($o, $buf, $cap - $n); close $o;
    open(my $m, ">", "$out.cap"); close $m;
    kill "KILL", -getpgrp();
  }
  syswrite($o, $buf); $n += $r;
}
close $in; exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
'
run_capped() { # seconds, output file, then the command
  lim=$1; out=$2; shift 2; rm -f "$out.cap"
  perl -e "$CAP_PL" "$out" "$@" < /dev/null &
  pid=$!; PGIDS="$PGIDS $pid"; n=0; killed=
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$n" -ge "$((lim * 10))" ]; then kill -KILL -- "-$pid" 2>/dev/null; killed=1; break; fi
    sleep 0.1; n=$((n + 1)) # tenths of a second, so a command that exits at once does not wait a whole second
  done
  wait "$pid"; rc=$?
  if [ -n "$killed" ] || [ -e "$out.cap" ]; then return 124; fi
  return "$rc"
}
PLAN_T0=$SECONDS
left() { r=$((${BUDGET:-3600} - (SECONDS - PLAN_T0))); if [ "$r" -lt "$1" ]; then echo "$r"; else echo "$1"; fi; }
DIAG_PL='
my @l = map { s/\A[^\x00-\x7f]+ ?//r } <STDIN>;
my ($i) = grep { $l[$_] =~ /Error: / } 0 .. $#l;
exit 4 unless defined $i;
for my $j ($i .. $#l) { last if $j > $i && $l[$j] !~ /\S/; print $l[$j] }
'
# The environment pattern by reason, one "<token> <phrases>" line each, the first match winning:
# the class is "environment (<token>)", a fixed token, never the matched text.
ENV_REASONS='credentials no valid credential sources|NoCredentialProviders|failed to (retrieve|refresh cached) credentials|InvalidClientTokenId|SignatureDoesNotMatch|ExpiredToken
access-denied AccessDenied|UnauthorizedOperation
throttling Throttling|RequestLimitExceeded
registry Error accessing remote module registry|Failed to query available provider packages|Failed to retrieve available versions
plugin failed to instantiate provider|Unrecognized remote plugin message|plugin exited before we could connect
sandbox operation not permitted
network dial tcp|no such host|connection refused|connection reset|TLS handshake
timeout i/o timeout|context deadline exceeded|timed out'
env_reason() { # diagnostic block file: the token of the first reason whose phrases it holds
  printf '%s\n' "$ENV_REASONS" | while read -r tok re; do
    grep -Eiq "$re" "$1" && { echo "$tok"; break; }
  done
}
class_of() { # exit status, output file, init or plan
  if [ "$1" -eq 124 ]; then
    if [ -e "$2.cap" ]; then echo 'environment (output-cap)'; else echo 'environment (timeout)'; fi
    return
  fi
  if [ "$1" -eq 0 ]; then
    [ "$3" = init ] && { echo ok; return; }
    grep -Eq '^Plan: .* to destroy\.$' "$2" && { echo planned; return; }
    grep -Eq '^No changes\.' "$2" && { echo planned-no-changes; return; }
    echo 'output unrecognised'; return
  fi
  perl -e "$DIAG_PL" < "$2" > "$2.block" || { echo 'output unrecognised'; return; }
  r="$(env_reason "$2.block")"; [ -n "$r" ] && { echo "environment ($r)"; return; }
  grep -q 'No value for required variable' "$2.block" && { echo 'needs input'; return; }
  echo code-error
}
# The denial evidence of a design skip (skip-coverage.md, Design skips): the data addresses of a
# plan output whose every Error: block has exactly the shape of an AWS SDK access denial on a data
# source read, sorted and once each; exit 1 for any other output. From the first "Error:" line on,
# every line must be one of: an "Error:" summary in the SDK's fixed form, a blank line, one
# "  with data....," line, one "  on <file> line <n>, in data "<type>" "<name>":" line naming the
# same data source, or a numbered snippet line. Anything else refuses: a "Warning:" header, text
# after a crash, a second "with" line, or a line a value put into a summary. The class alone is a
# substring of the first block, and Terraform prints a summary raw, line breaks included.
DENIED_PL='
my @l = map { s/\A[^\x00-\x7f]+ ?//r =~ s/\s+\z//r } <STDIN>;
my ($i) = grep { $l[$_] =~ /\AError:(?: |\z)/ } 0 .. $#l;
exit 1 unless defined $i;
my $ix = q{(?:\[(?:[0-9]+|"[A-Za-z0-9_.\/-]*")\])?};
my $mod = qr{(?:module\.[A-Za-z0-9_-]+$ix\.)*};
my (@b, %a);
for my $x (@l[$i .. $#l]) {
  if ($x =~ /\AError:(?: |\z)/) {
    $x =~ /\AError: [^\n]*: operation error [A-Za-z0-9 .-]+: [A-Za-z0-9]+, https response error StatusCode: 4[0-9][0-9], RequestID: [A-Za-z0-9-]+, (?:HostID: [A-Za-z0-9+\/=]+, )?api error (?:AccessDenied|AccessDeniedException|UnauthorizedOperation): / or exit 1;
    push @b, {w => [], o => []}; next;
  }
  next if $x eq "";
  if ($x =~ /\A  with ($mod)data\.([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)$ix,\z/) { push @{$b[-1]{w}}, [$1, $2, $3]; next }
  if ($x =~ /\A  on [^ ]+ line [0-9]+, in data "([A-Za-z0-9_-]+)" "([A-Za-z0-9_-]+)":\z/) { push @{$b[-1]{o}}, [$1, $2]; next }
  next if $x =~ /\A +[0-9]+: /;
  exit 1;
}
for my $k (@b) {
  exit 1 unless @{$k->{w}} == 1 && @{$k->{o}} == 1;
  my ($m, $t, $n) = @{$k->{w}[0]};
  exit 1 unless $k->{o}[0][0] eq $t && $k->{o}[0][1] eq $n;
  ($m = "${m}data.$t.$n") =~ s/\[[^\]]*\]//g;
  $a{$m} = 1;
}
exit 1 if keys(%a) > 50;
print join(" ", sort keys %a), "\n";
'
EVID_PL='
my $b = do { local $/; <STDIN> }; my $p = $ENV{PROFILE};
$b =~ s/arn:aws[a-z-]*:[^\s"\x27`]*/<arn>/g;
$b =~ s/(?<![0-9])[0-9]{12}(?![0-9])/<account>/g;
$b =~ s/(?<![A-Za-z0-9_-])\Q$p\E(?![A-Za-z0-9_-])/<profile>/g if length $p;
my $bad = grep { length && index($b, $_) >= 0 } split " ", ($ENV{LEAKS} // "");
$bad ||= $b =~ m{(?:AKIA|ASIA)[A-Z0-9]{16}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+|-----BEGIN|X-Amz-Signature|Authorization:|[A-Za-z0-9+/]{40,}};
# A value or shape split across lines: the same checks, bar the base64 run, with all whitespace removed
(my $j = $b) =~ s/\s+//g;
$bad ||= grep { length && index($j, $_) >= 0 } split " ", ($ENV{LEAKS} // "");
$bad ||= $j =~ m{(?:AKIA|ASIA)[A-Z0-9]{16}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+|-----BEGIN|X-Amz-Signature|Authorization:};
exit 3 if $bad;
my ($first) = split /\n/, $b; print substr($first // "", 0, 160), "\n";
'
kept() { PROFILE="$PROFILE" LEAKS="$LEAKS" perl -e "$EVID_PL"; }
# The addresses of a saved plan's resource changes, and of the data sources it read during the
# plan (prior_state and planned_values, each matched to a data block of the configuration at
# the same module path, only when the plan did not error), each index key removed, and per
# address the top-level attributes it plans or reads a value for: names only, never a value
# or a key, which can carry what the account returned. Per address too, those attributes the
# plan marks sensitive in any instance, the head commit given as $h when it is a full SHA, and
# the example directory given as $e when it is a plain repository-relative path.
# shellcheck disable=SC2016 # a jq program
ADDR_JQ='
def addr_ok: length <= 300
  and test("^(module\\.[A-Za-z0-9_-]+\\.)*(data\\.)?(?!data\\.|module\\.)[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\z");
def cfg_data: (.resources[]? | objects | select(.mode == "data") | .address | strings),
  (.module_calls? | objects | to_entries[] | .key as $k | .value.module? | objects | cfg_data | "module.\($k).\(.)");
def nokey: gsub("\\[(\"([^\"\\\\]|\\\\.)*\"|[0-9]+)\\]"; ""); # a whole quoted or numeric key, never cut at a ] inside it
. as $plan
| [$plan.configuration | objects | .root_module | objects | cfg_data] as $cfg
| [(.resource_changes[]? | select(type == "object" and (.address | type == "string"))
   | {a: (.address | nokey), c: (.change // {})}),
   (if $plan.errored == true then empty else
      (($plan.prior_state | objects | .values | objects | .root_module), ($plan.planned_values | objects | .root_module))
      | objects | recurse(.child_modules[]? | objects) | .resources[]? | objects
      | select(.mode == "data" and (.address | type == "string"))
      | {a: (.address | nokey), c: {after: .values, after_sensitive: .sensitive_values}}
      | select(.a | IN($cfg[])) end)
 | select(.a | addr_ok)]
| (group_by(.a) | map(.[0].a as $a | [.[].c] as $cs
   | ([$cs[] | ((.after | if type == "object" then to_entries[] | select(.value != null) | .key else empty end),
                (.after_unknown | if type == "object" then to_entries[] | select(.value == true) | .key else empty end))]
      | map(select(test("^[a-z0-9_]{1,128}$"))) | unique | .[:500]) as $at
   # An instance whose after_sensitive is not an object or false marks every attribute sensitive
   | {a: $a, at: $at,
      s: (if any($cs[]; .after_sensitive | type != "object" and . != false) then $at
          else [$cs[] | .after_sensitive | objects | to_entries[] | select([.value | .. | select(. == true)] != []) | .key]
            | unique | map(select(IN($at[]))) end)})) as $g
| {addresses: (map(.a) | unique | .[:1000]),
   attributes: ($g | map({key: .a, value: .at}) | from_entries),
   module_calls: ($plan.configuration.root_module.module_calls | if type == "object" then
     with_entries(.value |= (.source? // null)) | with_entries(select((.key | test("^[A-Za-z0-9_-]{1,64}$"))
                and (.value | type == "string" and test("^[.][.]?(/[A-Za-z0-9_.-]+)*/?$")))) else {} end),
   sensitive: ($g | map({key: .a, value: .s}) | from_entries)}
| if $h | test("^[0-9a-f]{40}$") then . + {head_sha: $h} else . end
| if ($e | test("^[A-Za-z0-9._/-]{1,300}$")) and (any($e | split("/")[]; . == "..") | not) then . + {example: $e} else . end
'
# The plan diff of one example (plan-pass.md, Plan diff): two saved plans of the merge base
# example's HCL, against the base module ($a) and against the head module ($b), compared here and
# nowhere else, with the provider schema of the head module plan ($s). Per address, index keys
# kept, the address sets and each change's actions, after, after_unknown, after_sensitive and
# replace_paths; then the root outputs whole. A value unknown on either side is equal only in an
# attribute the schema marks computed that neither plan's configuration sets on that resource,
# wholly unknown when it is optional (a computed-only attribute never is set), or in a nested block
# neither configuration writes, wholly unknown: an
# attribute the configuration sets, one the schema does not name, a resource whose configuration
# cannot be found and a type the schema lacks are unknown, and so are a plan that errored, one that
# deferred a change and a change whose markers are not objects. Prints {result, reason, differs}:
# reason is the token an unknown result names, null otherwise, and differs
# names the addresses, index keys removed, and outputs that differ: names only, no value leaves.
# shellcheck disable=SC2016 # a jq program
PDIFF_JQ='
def nokey: gsub("\\[(\"([^\"\\\\]|\\\\.)*\"|[0-9]+)\\]"; "");
def rc: [.resource_changes[] | select(type == "object" and (.address | type == "string"))];
def part: .change | {actions, after, after_unknown, after_sensitive, replace_paths};
def marker: . == null or . == false or type == "object";
def has_true: [.. | select(. == true)] != [];
# The instances of a block type in a value, $m its nesting mode: a list or set block is a list, a
# map block an object of labels, a single or group block an object; the joined configuration of
# several instances is a list of these.
def insts($m): if type == "array" then [.[] | if $m == "map" and type == "object" then .[] else . end]
  elif type == "object" then (if $m == "map" then [.[]] else [.] end) else [] end;
# The configuration of a list of block instances as one object: each key kept, the values of a key
# that several instances set joined into one list, so the next level reads what every instance
# sets; null for any other shape, which reads as no configuration.
def merge_cfg: if type == "array" and length > 0 and all(.[]; type == "object") then
    reduce .[] as $o ({}; reduce ($o | to_entries[]) as $e (.;
      .[$e.key] = if has($e.key) then [(.[$e.key], $e.value) | if type == "array" then .[] else . end] else $e.value end))
  else null end;
# Every true leaf of an after_unknown value at block level ($blk) is in an attribute the schema
# marks computed that the configuration at this level ($ex, null when not known) does not set, or
# in a nested block it does not write. $all holds every planned instance at this level that $ex
# describes. A nested block type is read with its configuration only when the configuration writes
# as many instances as are planned, counted over $all, and it is no set block written more than
# once; otherwise a dynamic block, which a plan'"'"'s configuration does not show, or a set that merged
# equal elements made some instances, and its contents read as not known.
def computed_only($blk; $ex; $all):
  if . == null or . == false then true
  elif type != "object" then false
  elif $blk == null then has_true | not
  else all(to_entries[]; .key as $k | .value as $v
    | ($ex != null and ($ex | has($k))) as $set
    | if ($blk.attributes[$k] | type) == "object" then
        ($v | has_true | not)
        or ($blk.attributes[$k] | .computed == true and (.required | not)
            and ((.optional | not) or ($ex != null and ($set | not) and $v == true)))
      elif ($blk.block_types[$k] | type) == "object" then
        $blk.block_types[$k] as $bt | $bt.block as $nb | $bt.nesting_mode as $m
        | [$all[] | objects | .[$k] | insts($m)[]] as $nall
        | (if $ex == null or ($set | not) then null
           else $ex[$k] | insts($m) | if length != ($nall | length) or ($m == "set" and length > 1) then null else merge_cfg end end) as $nex
        | if $v == null or $v == false then true
          elif $v == true then $ex != null and ($set | not)
          elif $m == "map" then ($v | type) == "object" and all($v[]; computed_only($nb; $nex; $nall))
          elif ($v | type) == "array" then all($v[]; computed_only($nb; $nex; $nall))
          elif ($v | type) == "object" then ($v | computed_only($nb; $nex; $nall))
          else false end
      else ($v | has_true | not) end)
  end;
def block_of($c): ($s[0].provider_schemas[$c.provider_name // ""]
    | if $c.mode == "data" then .data_source_schemas else .resource_schemas end | .[$c.type // ""].block) // null;
# The expressions of a change'"'"'s resource in a plan'"'"'s configuration, through its module calls; null
# when they cannot be found.
def cfg_of($P; $c): ($c.module_address // "" | nokey
    | if . == "" then [] else split(".") | [range(1; length; 2) as $i | .[$i]] end) as $mods
  | (reduce $mods[] as $m ($P.configuration.root_module; if type == "object" then .module_calls[$m].module else null end)) as $mod
  | if ($mod | type) != "object" then null
    else first($mod.resources[]? | select(.address == (if $c.mode == "data" then "data." else "" end) + "\($c.type).\($c.name)" and .mode == $c.mode) | (.expressions // {})) // null end;
# Why a plan diff is unknown, a token of a closed set: the plan errored or holds no change list,
# deferred a change, has a change whose markers are not objects, a type the schema lacks, a resource
# with an unknown whose configuration cannot be found, an unknown at the top of a resource the rule
# does not take, or one inside a nested block. The first, in that order, is the reason.
def reasons: ["errored", "deferred", "marker", "schema", "config", "configured", "block"];
def plan_reason: if type != "object" or .errored == true or (.resource_changes | type) != "array" then "errored"
  elif ((.deferred_changes // []) | length) > 0 then "deferred"
  elif any(.resource_changes[]; type != "object" or (.change | type) != "object"
           or (.change.after_unknown | marker | not) or (.change.after_sensitive | marker | not)) then "marker"
  else empty end;
# The first of a list of reasons in the order of the set.
def first_reason: [.[] | . as $r | reasons | index($r)] | min | reasons[.];
# The reasons of one change: schema, config, or for each top-level key the rule does not take,
# block when the key is a nested block type and configured otherwise; every such key counts, so the
# reason does not depend on the order of the keys.
def change_reasons($A; $B): . as $c | block_of($c) as $blk | $c.change.after_unknown as $u
  | if $blk == null then "schema"
    else (cfg_of($A; $c), cfg_of($B; $c)) as $ex
      | select($u | computed_only($blk; $ex; [$u]) | not)
      | if $ex == null then "config"
        else [($u | to_entries[]) as $e | select({($e.key): $e.value} | computed_only($blk; $ex; [$u]) | not)
            | if ($blk.block_types[$e.key] | type) == "object" then "block" else "configured" end]
          | if . == [] then "configured" else first_reason end end
    end;
$a[0] as $A | $b[0] as $B
| if any(($A, $B); plan_reason)
  then {result: "unknown", reason: ([($A, $B) | plan_reason] | first_reason), differs: []}
  elif any(($A, $B) | rc[]; change_reasons($A; $B))
  then {result: "unknown", reason: ([($A, $B) | rc[] | change_reasons($A; $B)] | first_reason), differs: []}
  else ($A | rc | map({key: .address, value: part}) | from_entries) as $x
    | ($B | rc | map({key: .address, value: part}) | from_entries) as $y
    | ($A.output_changes // {}) as $oa | ($B.output_changes // {}) as $ob
    | ([($x + $y | keys[]) | select($x[.] != $y[.]) | nokey]
       + [($oa + $ob | keys[]) | select($oa[.] != $ob[.]) | "output.\(.)"] | unique) as $d
    | {result: (if $d == [] then "equal" else "differs" end), reason: null,
       differs: ($d | map(select(length <= 300 and test("^[A-Za-z0-9_.-]+$"))) | .[:50])}
  end
'
# pd_show <key>: terraform show -json of the key's saved plan into out/<key>-show.json, in the
# example directory, with no credentials. Status 2 when there is no saved plan.
pd_show() {
  [ -f "$PLAN/saved/$1.tfplan" ] || return 2
  AK=; SK=; ST=; set_env "$1"
  CAP_BYTES=16777216 CAP_QUIET_ERR=1 run_capped "$(left 120)" "$PLAN/out/$1-show.json" "${TFENV[@]}" \
    terraform show -json -no-color "$PLAN/saved/$1.tfplan"
}
# pd_schema <key>: the provider schema of the key's example directory, read with no credentials
# and no network from the providers its init installed, into out/<key>-schema.json; a failure
# leaves the file empty, which the comparison reads as no schema.
pd_schema() {
  AK=; SK=; ST=; set_env "$1"
  CAP_BYTES=268435456 CAP_QUIET_ERR=1 run_capped "$(left 120)" "$PLAN/out/$1-schema.json" "${TFENV[@]}" \
    terraform providers schema -json -no-color || : > "$PLAN/out/$1-schema.json"
}
# pd_compare <base show> <head module show> <schema>: prints the plan-diff line and, for equal,
# sets PDADDR to the head module plan's addresses and local module calls, the merge base
# example's, as {"addresses": [...], "module_calls": {...}} (ADDR_JQ, names only).
pd_compare() {
  PDADDR=
  r="$(jq -n -c --slurpfile a "$1" --slurpfile b "$2" --slurpfile s "$3" "$PDIFF_JQ" 2> /dev/null)" || r='{"result":"unknown","reason":"compare","differs":[]}'
  case "$(printf '%s' "$r" | jq -r .result 2> /dev/null)" in
    equal) PDADDR="$(jq -c --arg h '' --arg e '' "$ADDR_JQ"' | {addresses, module_calls}' "$2" 2> /dev/null)"
      if [ -n "$PDADDR" ]; then echo "plan-diff: equal"; else echo "plan-diff: not-run show"; fi ;;
    differs) printf '%s' "$r" | jq -r '"plan-diff: differs" + (.differs | map(" " + .) | join(""))' ;;
    unknown) printf '%s' "$r" | jq -r '"plan-diff: unknown " + (.reason | if IN("errored", "deferred", "marker", "schema", "config", "configured", "block") then . else "compare" end)' 2> /dev/null \
      || echo "plan-diff: unknown compare" ;;
    *) echo "plan-diff: unknown compare" ;;
  esac
}
# mixed_ready <example>: the head tree with this example directory as at the merge base, in
# <run-dir>/mixed, a worktree of the clone, and its G0 result in g0-mixed.txt.
mixed_git() {
  GIT_LFS_SKIP_SMUDGE=1 git -C "$RUN/mixed" -c core.hooksPath=/dev/null -c filter.lfs.smudge=cat \
    -c filter.lfs.process= -c filter.lfs.required=false "$@"
}
mixed_ready() {
  [ -d "$RUN/mixed" ] || clone_git worktree add -q --detach -- "$RUN/mixed" HEAD > /dev/null 2>&1 || return 1
  mixed_git rm -r -q --ignore-unmatch -- "$1" > /dev/null 2>&1 &&
    mixed_git checkout -q "$BASESHA" -- "$1" > /dev/null 2>&1 || return 1
  g0 "$(cd "$RUN/mixed" && pwd -P)" > "$RUN/g0-mixed.txt"
}
# example_changed <example>: the change touches the example directory, or the question fails.
example_changed() {
  ! clone_git diff --quiet --no-ext-diff --no-textconv "$BASESHA" HEAD -- "$1" > /dev/null 2>&1
}
# The plan diff directories (--diff-dir), one per line; reaches <example> <addresses file>: a
# local module call of the example's root module resolves to one, outside the example's own
# directory, whose files the plan diff restores from the merge base.
reaches() {
  printf '%s\n' "$DIFFDIRS" | jq -R -s -e --arg d "$1" --slurpfile x "$2" '
    def resolve($d): ($d + "/" + .) | split("/")
      | reduce .[] as $p ([]; if . == null then null elif $p == "" or $p == "." then .
          elif $p == ".." then (if length == 0 then null else .[:-1] end) else . + [$p] end)
      | if . == null then null elif length == 0 then "." else join("/") end;
    (split("\n") | map(select(. != ""))) as $dd
    | any(($x[0].module_calls // {}) | to_entries[] | .value | strings | resolve($d)
        | select(. != $d and (startswith($d + "/") | not)); IN($dd[]))' \
    > /dev/null 2>&1
}
SHOWTO=
pe_show() { # key: the saved plan as JSON, reduced to its addresses on standard output
  pd_show "$1" || return 0
  : > "$PLAN/out/$1-show.ok"
  jq -c --arg h "$PHEAD" --arg e "$PEX" "$ADDR_JQ" "$PLAN/out/$1-show.json" 2> /dev/null
}
# The plan cache across runs (plan-pass.md, Plan cache), laptop mode only: a head plan's class,
# kept line and addresses file, under the hash of every input that can change them. Nothing in
# an entry is trusted: an entry that fails any check is a miss and is removed when it is ours.
PCACHE=; PCTF=; PCKEY=
PC_TTL_MIN=1440 # an entry older than a day is not used: the account the plan reads can change
PC_MAX_ENTRIES=256 # the least recently used removed first
PC_CAP_ADDR=4194304 # the largest addresses file stored or read
# A directory or file owned by the user, no symbolic link, writable by neither group nor others,
# read as a positive answer, so a find that fails refuses it.
private_dir() { [ -d "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] && [ -n "$(find -H "$1" -maxdepth 0 -type d ! -perm -0020 ! -perm -0002 2> /dev/null)" ]; }
private_file() { [ -f "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] && [ -n "$(find -H "$1" -maxdepth 0 -type f ! -perm -0020 ! -perm -0002 2> /dev/null)" ]; }
# A path that is its own physical path: no symbolic link in any component, no . or .., no
# trailing or doubled slash.
physical() { [ "$(CDPATH= cd -P -- "$1" 2> /dev/null && pwd -P)" = "$1" ]; }
fsize() { wc -c < "$1" | tr -d ' '; }
# The key: t: a text, f: a file's bytes, d: a tree, m: a tree less its top modules.json (Terraform
# writes local paths there). A tree is every name under it, sorted, with each file's bytes and
# each link's target, each file by its own digest so no file's bytes can read as the next name;
# .git and .terraform directories and lock files are left out, the lock file
# of the example being an input of its own.
PC_KEY_PL='
use strict; use warnings; use Digest::SHA; use File::Find;
my $d = Digest::SHA->new(256); $d->add("modulestf plan cache 1\0");
for my $arg (@ARGV) {
  my ($t, $v) = split /:/, $arg, 2;
  if ($t eq "t") { $d->add("t\0$v\0"); next }
  if ($t eq "f") { exit 1 unless -f $v && !-l $v; $d->add("f\0", Digest::SHA->new(256)->addfile($v, "b")->hexdigest, "\0"); next }
  exit 1 unless ($t eq "d" || $t eq "m") && -d $v && !-l $v;
  my @e;
  find({no_chdir => 1, wanted => sub {
    my $r = substr($File::Find::name, length $v);
    if (-d $_ && !-l $_) { if (m{/\.(?:git|terraform)\z}) { $File::Find::prune = 1; return } push @e, ["D", $r]; return }
    return if ($t eq "m" && $r eq "/modules.json") || $r =~ m{/\.terraform\.lock\.hcl\z};
    push @e, [(-l $_ ? "L" : -f _ ? "F" : "O"), $r];
  }}, $v);
  $d->add("$t\0");
  for my $x (sort { $a->[1] cmp $b->[1] } @e) {
    my ($k, $r) = @$x; $d->add("$k\0$r\0");
    if ($k eq "L") { $d->add(readlink("$v$r") // "", "\0") }
    elsif ($k eq "F") { open(my $h, "<", "$v$r") or exit 1; binmode $h; $d->add(Digest::SHA->new(256)->addfile($h)->hexdigest, "\0") }
  }
}
print $d->hexdigest, "\n";
'
pc_key() { # key: the hex key of the head plan of the example in the current directory
  [ -n "$PCACHE" ] && [ -n "$PCTF" ] || return 1
  printf '%s\n' "$PHEAD" | grep -Eqx '[0-9a-f]{40}' || return 1
  PCA=("t:mode $GMODE" "t:profile $PROFILE" "t:role $ROLE_ARN" "t:commit $PHEAD" "t:example $PEX"
    "t:terraform $PCTF" "t:modules $VERSIONS" "f:$HERE/plan-pass.sh" "f:$HERE/plan-session.sh"
    "f:$HERE/plan-session-policy.json" "f:$PWD/.terraform.lock.hcl")
  while IFS= read -r d; do PCA+=("d:$d"); done <<EOF
$(scope "$PWD" | grep '^/' | sed 's|/[^/]*$||' | sort -u)
EOF
  [ ! -d "$PLAN/data/$1/modules" ] || PCA+=("m:$PLAN/data/$1/modules")
  perl -e "$PC_KEY_PL" "${PCA[@]}" 2> /dev/null | grep -Ex '[0-9a-f]{64}'
}
pc_ok() { # entry: every check of a usable entry for PCKEY, PHEAD and PEX
  private_dir "$1" || return 1
  for f in key class kept; do private_file "$1/$f" || return 1; done
  [ "$(fsize "$1/key")" -le 65 ] && [ "$(fsize "$1/class")" -le 32 ] && [ "$(fsize "$1/kept")" -le 4096 ] || return 1
  [ -n "$(find "$1/key" -mmin -"$PC_TTL_MIN" 2> /dev/null)" ] || return 1
  [ "$(cat "$1/key")" = "$PCKEY" ] && [ "$(grep -c '' "$1/kept")" = 1 ] || return 1
  case "$(cat "$1/class")" in
    planned|planned-no-changes)
      private_file "$1/addresses.json" && [ "$(fsize "$1/addresses.json")" -le "$PC_CAP_ADDR" ] &&
        jq -s -e --arg h "$PHEAD" --arg x "$PEX" 'length == 1 and (.[0] | type == "object" and .head_sha == $h
          and .example == $x and (.addresses | type == "array"))' "$1/addresses.json" > /dev/null 2>&1 ;;
    code-error) [ ! -e "$1/addresses.json" ] && [ ! -L "$1/addresses.json" ] ;;
    *) return 1 ;;
  esac
}
pc_hit() { # key: true when a usable entry set CLASS, KEPT and the addresses file
  PCKEY="$(pc_key "$1")" || { PCKEY=; return 1; }
  pce="$PCACHE/$PCKEY"
  [ -e "$pce" ] || [ -L "$pce" ] || return 1
  if ! pc_ok "$pce"; then
    if [ -L "$pce" ]; then rm -f "$pce"; elif [ -d "$pce" ] && [ -O "$pce" ]; then rm -rf "$pce"; fi
    return 1
  fi
  # The entry checked, then copied into the pass's own directory and checked again there: what is
  # read is the copy, so a run trimming the cache meanwhile can only make this a miss.
  pce="$(mktemp -d "$PLAN/tmp/pc.XXXXXX" 2> /dev/null)" || return 1
  for f in key class kept addresses.json; do
    [ ! -e "$PCACHE/$PCKEY/$f" ] || cp -p "$PCACHE/$PCKEY/$f" "$pce/" 2> /dev/null || return 1
  done
  pc_ok "$pce" || return 1
  pcc="$(cat "$pce/class")"
  # A plan diff needs the plan itself, so an example that reaches a plan diff directory plans
  if [ "$pcc" != code-error ] && [ -n "$DIFFDIRS" ] && reaches "$PEX" "$pce/addresses.json"; then return 1; fi
  CLASS=$pcc; KEPT="$(cat "$pce/kept")"
  [ "$CLASS" = code-error ] || cat "$pce/addresses.json" > "$SHOWTO"
  touch -c "$PCACHE/$PCKEY" 2> /dev/null; PCKEY=
  echo "plan pass: plan cache hit $PEX" >&2
}
pc_put() { # key: the head plan just run, stored as an entry, whole or not at all
  [ -n "$PCKEY" ] || return 0
  case "$CLASS" in
    planned|planned-no-changes) [ -s "$SHOWTO" ] && [ "$(fsize "$SHOWTO")" -le "$PC_CAP_ADDR" ] || return 0 ;;
    code-error) ;;
    *) return 0 ;;
  esac
  t="$(mktemp -d "$PCACHE/.put.XXXXXX" 2> /dev/null)" || return 0
  # One rename of the whole entry, only when none exists: an entry another run stored meanwhile
  # is kept, and a rename that landed inside it is removed.
  if printf '%s\n' "$PCKEY" > "$t/key" && printf '%s\n' "$CLASS" > "$t/class" && printf '%s\n' "$KEPT" > "$t/kept" &&
      case "$CLASS" in planned|planned-no-changes) cp "$SHOWTO" "$t/addresses.json" ;; esac && chmod 600 "$t"/* &&
      [ ! -e "$PCACHE/$PCKEY" ] && mv "$t" "$PCACHE/$PCKEY" 2> /dev/null; then
    [ ! -e "$PCACHE/$PCKEY/${t##*/}" ] || rm -rf "$PCACHE/$PCKEY/${t##*/}"
    # At most PC_MAX_ENTRIES entries, and the temporary directory of a run killed part-way
    # removed after an hour
    find "$PCACHE" -mindepth 1 -maxdepth 1 -type d -name '.put.*' -mmin +60 -exec rm -rf {} + 2> /dev/null
    ls -1t "$PCACHE" 2> /dev/null | grep -Ex '[0-9a-f]{64}' | tail -n +$((PC_MAX_ENTRIES + 1)) |
      while IFS= read -r x; do rm -rf "$PCACHE/$x"; done
    return 0
  fi
  rm -rf "$t"
}
if [ "$GMODE" = laptop ] && [ -z "$PHASE" ]; then
  if [ -n "${PLAN_CACHE+x}" ]; then pcd=$PLAN_CACHE
  elif [ -n "${XDG_CACHE_HOME:-}" ]; then pcd="$XDG_CACHE_HOME/modulestf/plan-cache"
  elif [ -n "${HOME:-}" ]; then pcd="$HOME/.cache/modulestf/plan-cache"
  else pcd=; fi
  if [ -n "$pcd" ]; then
    case "$pcd" in /?*) (umask 077 && mkdir -p "$pcd") 2> /dev/null ;; esac
    PCTF="$(env -i PATH="/usr/bin:/bin:$TFDIR" HOME="$PLAN/home" TMPDIR="$PTMP" TF_CLI_CONFIG_FILE="$PLAN/cli.tfrc" \
      CHECKPOINT_DISABLE=1 terraform version -json < /dev/null 2> /dev/null | jq -r '"\(.terraform_version) \(.platform)"' 2> /dev/null |
      grep -Ex '[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9.+-]* [a-z0-9_]+')"
    # The parent the user owns, or one with the sticky bit, so no other user can rename the
    # directory away and put another in its place
    pcp="${pcd%/*}"; [ -n "$pcp" ] || pcp=/
    case "$pcd" in /?*) physical "$pcd" && private_dir "$pcd" && { [ -O "$pcp" ] || [ -k "$pcp" ]; } &&
      [ -n "$PCTF" ] && PCACHE=$pcd ;; esac
    [ -n "$PCACHE" ] || echo "plan pass: plan cache not used" >&2
  fi
fi
pe_init() { # absolute example directory, key, root (the clone or the base worktree), saved g0 file
  # Everything before the credentials: gates, init, post_init. CLASS "ready" means plan next.
  CROOT=$3; CLASS=; KEPT=; VERSIONS=; SCOPE=; out=; INCD=
  [ "$(left 1)" -gt 0 ] || { CLASS=budget; return; }
  [ -e "$4" ] || { CLASS='plan gate G0 not evaluated'; return; }
  [ -s "$4" ] && { gate_class "$(cat "$4")"; return; }
  SCOPE="$(scope "$1" | sed 's|/[^/]*$||' | sort -u | rel | tr '\n' ' ')"
  h="$(scope "$1" | perl -e "$GATES_PL" clone "$CROOT" "$GMODE" "$1"; committed_locks "$1")"
  [ -n "$h" ] && { exc_or_gate "$h"; return; }
  cd "$1" || { CLASS='plan gate G0 unreadable'; return; }
  INCD=1
  # A lock file the clone does not track, or a .terraform/, from an earlier run: the plan pass reads neither
  drop_lock
  rm -rf .terraform
  AK=; SK=; ST=; set_env "$2"
  # The acquired tree only for an example with no lock file of its own, which terraform could not
  # check against an unpacked tree; a failed init runs again as the pass always ran it.
  tcfg="$PLAN/cli.tfrc"; [ -z "$PTREE" ] || [ -e .terraform.lock.hcl ] || [ -L .terraform.lock.hcl ] || tcfg=$PTREE
  run_capped "$(left 180)" "$PLAN/out/$2-init.txt" "${TFENV[@]}" TF_CLI_CONFIG_FILE="$tcfg" terraform init -backend=false -input=false -no-color
  rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ "$tcfg" != "$PLAN/cli.tfrc" ] && [ "$(left 180)" -gt 0 ]; then
    run_capped "$(left 180)" "$PLAN/out/$2-init.txt" "${TFENV[@]}" terraform init -backend=false -input=false -no-color
    rc=$?
  fi
  CLASS="$(class_of "$rc" "$PLAN/out/$2-init.txt" init)"; out="$PLAN/out/$2-init.txt"
  if [ "$CLASS" = ok ]; then
    pi="$(post_init "$2" "$1")"
    SCOPE="$SCOPE$(sed -n 's/^dir //p' "$PLAN/out/$2-modules.txt" 2>/dev/null | sort -u | rel | tr '\n' ' ')"
    VERSIONS="$(printf '%s\n' "$pi" | sed -n 's/^version //p' | tr '\n' ';')"
    h="$(printf '%s\n' "$pi" | grep -v '^version ')"
    if [ -n "$h" ]; then exc_or_gate "$h"; else CLASS=ready; fi
  fi
}
pe_plan() { # key: the credentials and the plan, then the kept line and the denial evidence
  DENIED=; PCKEY=
  # Laptop mode, a head plan: a plan cache entry stands in for the credentials, the plan and the
  # show (plan-pass.md, Plan cache)
  [ "$CLASS" = ready ] && [ -n "$SHOWTO" ] && pc_hit "$1" && return 0
  if [ "$CLASS" = ready ]; then
    if ! get_creds; then CLASS='plan pass ended: credentials'
    else
      set_env "$1"
      run_capped "$(left 300)" "$PLAN/out/$1-plan.txt" "${TFENV[@]}" terraform plan -input=false -lock=false -refresh=true -no-color -compact-warnings "-out=$PLAN/saved/$1.tfplan"
      rc=$?; CLASS="$(class_of "$rc" "$PLAN/out/$1-plan.txt" plan)"; out="$PLAN/out/$1-plan.txt"
    fi
    AK=; SK=; ST=
  fi
  case "$CLASS" in
    planned) KEPT="$(grep -E -m 1 '^Plan: .* to destroy\.$' "$out" | kept)" ;;
    code-error) KEPT="$(kept < "$out.block")" ;;
    'environment (access-denied)') DENIED="$(perl -e "$DENIED_PL" < "$out")" || DENIED= ;;
  esac
  # Laptop mode: the head plan's addresses, read by a terraform process of its own after the
  # plan has ended, with no credentials (plan-pass.md, Saved plans and addresses). run_capped
  # sets out, so this comes after the kept line.
  if [ -n "$SHOWTO" ]; then
    case "$CLASS" in planned|planned-no-changes) pe_show "$1" > "$SHOWTO"; [ -z "$DIFFDIRS" ] || pd_schema "$1" ;; esac
    pc_put "$1"
  fi
}
drop_lock() { # the lock file of the working directory, removed only when git answers and does not track it
  dl="$(git ls-files -- .terraform.lock.hcl 2> /dev/null)" && [ -z "$dl" ] && rm -f .terraform.lock.hcl
  return 0
}
plan_example() { # absolute example directory, key, root (the clone or the base worktree), saved g0 file
  pe_init "$@"
  pe_plan "$2"
  [ -z "$INCD" ] || drop_lock
}
init_state() { # absolute example directory, key, root, saved g0 file: pe_init, saved for the plan phase
  pe_init "$@" > "$PLAN/state/$2.lines"
  [ "$CLASS" = ready ] || pe_plan "$2" # only the kept line of an init failure
  printf '%s\n' "$CLASS" "$SCOPE" "$VERSIONS" "$out" "$KEPT" > "$PLAN/state/$2.vars"
}
load_state() { # key; false when the init phase saved nothing for it
  [ -f "$PLAN/state/$1.vars" ] || return 1
  CLASS="$(sed -n 1p "$PLAN/state/$1.vars")"; SCOPE="$(sed -n 2p "$PLAN/state/$1.vars")"
  VERSIONS="$(sed -n 3p "$PLAN/state/$1.vars")"; out="$(sed -n 4p "$PLAN/state/$1.vars")"
  KEPT="$(sed -n 5p "$PLAN/state/$1.vars")"
  grep . "$PLAN/state/$1.lines" 2>/dev/null
  return 0
}

clone_git() {
  GIT_LFS_SKIP_SMUDGE=1 git -C "$DIR" -c core.hooksPath=/dev/null \
    -c filter.lfs.smudge=cat -c filter.lfs.process= \
    -c filter.lfs.required=false "$@"
}
base_ready() { # the base worktree for a re-run, added once with its G0 saved first
  [ -d "$RUN/base" ] && return 0
  printf '%s\n' "$BASESHA" | grep -Eqx '[0-9a-f]{40}' || return 1 # a full SHA only, never an option
  clone_git fetch -q --depth=1 -- origin "$BASESHA" > /dev/null 2>&1 || return 1
  clone_git worktree add -q --detach -- "$RUN/base" "$BASESHA" > /dev/null 2>&1 || return 1
  g0 "$(cd "$RUN/base" && pwd -P)" > "$RUN/g0-base.txt"
}

pd_side() { # absolute example directory, key, root, saved g0 file: one plan of the plan diff and
  # its show, before the lock file this pass wrote is removed. Status 2: no plan; 1: no show.
  pe_init "$@"; pe_plan "$2"; rc=2
  case "$CLASS" in planned|planned-no-changes) pd_show "$2" && rc=0 || rc=1; pd_schema "$2" ;; budget) rc=3 ;; esac
  [ -z "$INCD" ] || drop_lock
  return "$rc"
}
pd_laptop() { # repository-relative example, key, place: the plan diff of an example whose head planned
  printf '%s\n' "$BASESHA" | grep -Eqx '[0-9a-f]{40}' && base_ready || { echo "plan-diff: not-run no-base"; return; }
  B="$(cd "$RUN/base" && pwd -P)"
  [ -d "$B/$1" ] || { echo "plan-diff: not-run absent-at-base"; return; }
  [ "$(left 1)" -gt 0 ] || { echo "plan-diff: not-run budget"; return; }
  pd_side "$B/$1" "$2-base" "$B" "$RUN/g0-base.txt"; rc=$?
  [ "$rc" = 3 ] && { echo "plan-diff: not-run budget"; return; }
  [ "$rc" = 2 ] && { echo "plan-diff: not-run base-plan"; return; }
  [ "$rc" = 0 ] || { echo "plan-diff: not-run show"; return; }
  hk=$2
  [ -f "$PLAN/out/$2-show.ok" ] || { echo "plan-diff: not-run show"; return; }
  if example_changed "$1"; then
    mixed_ready "$1" || { echo "plan-diff: not-run head-module-plan"; return; }
    M="$(cd "$RUN/mixed" && pwd -P)"; hk=$2-mixed
    pd_side "$M/$1" "$hk" "$M" "$RUN/g0-mixed.txt"; rc=$?
    [ "$rc" = 3 ] && { echo "plan-diff: not-run budget"; return; }
    [ "$rc" = 2 ] && { echo "plan-diff: not-run head-module-plan"; return; }
    [ "$rc" = 0 ] || { echo "plan-diff: not-run show"; return; }
  fi
  pd_compare "$PLAN/out/$2-base-show.json" "$PLAN/out/$hk-show.json" "$PLAN/out/$hk-schema.json"
  [ -z "$PDADDR" ] || printf '%s\n' "$PDADDR" > "$RUN/plan-addresses/plan-diff-$3.json"
}
DENIED=; NPLAN=0; NEXC=0; EXN=0; HROOT=$CROOT # plan_example moves CROOT to the base worktree for a re-run
PHEAD=; PEX= # the head commit and the example directory for the addresses files, laptop mode only
if [ "$PHASE" = init ]; then
  # No credentials and no plan here. The merge base is prepared later, only for an example
  # whose plan is a code-error (phase base-init).
  for rel_ex in "$@"; do
    EXN=$((EXN + 1)); key="e$EXN"; : > "$PLAN/state/$key.lines"; CLASS=; SCOPE=; VERSIONS=; out=
    case "$rel_ex" in
      /*|*..*) CLASS='plan gate G0 not an example directory' ;;
      *) init_state "$HROOT/$rel_ex" "$key" "$HROOT" "$RUN/g0.txt" ;;
    esac
    [ -f "$PLAN/state/$key.vars" ] || printf '%s\n' "$CLASS" "" "" "" "" > "$PLAN/state/$key.vars"
    echo "init: $rel_ex: $CLASS"
  done
  exit 0
fi
if [ "$PHASE" = base-init ]; then
  # One example whose plan was a code-error: the base worktree, added once, and its init there.
  # No credentials.
  rel_ex=$1; key="e$INDEX"
  case "$rel_ex" in /*|*..*) exit 0 ;; esac
  if base_ready; then
    B="$(cd "$RUN/base" && pwd -P)"
    if [ -d "$B/$rel_ex" ]; then
      init_state "$B/$rel_ex" "$key-base" "$B" "$RUN/g0-base.txt"
      echo "init: $rel_ex at base: $CLASS"
    else
      : > "$PLAN/state/$key-base.absent"
    fi
  fi
  exit 0
fi
if [ "$PHASE" = plan ]; then
  rel_ex=$1; key="e$INDEX"
  echo "example: $rel_ex"
  load_state "$key" || { echo "plan: plan gate G0 not evaluated"; exit 0; }
  if [ "$CLASS" = ready ]; then cd "$HROOT/$rel_ex" || CLASS='plan gate G0 unreadable'; fi
  [ "$CLASS" = ready ] && pe_plan "$key"
  printf 'plan: %s\n' "$CLASS${KEPT:+ | $KEPT}" # never echo: zsh's echo turns a \n in the kept text into a line
  [ "$CLASS" = 'plan pass ended: credentials' ] && echo "credentials: $CREDWHY"
  [ -n "$SCOPE" ] && echo "scope: ${SCOPE% }"
  [ -n "$VERSIONS" ] && echo "modules: ${VERSIONS%;}"
  [ -n "$DENIED" ] && echo "denied: $DENIED"
  # The merge base re-run is a later phase, so only an example that needs it pays for it
  if [ "$CLASS" = code-error ] || [ -n "$DENIED" ]; then
    if [ -n "$BASESHA" ]; then echo "base: deferred"; else echo "base: not available"; fi
  fi
  exit 0
fi
if [ "$PHASE" = show ]; then
  # A container of its own, with no network and no credentials, after the plan container
  # ended: the saved plan's addresses, which the host checks before it records them
  rel_ex=$1; key="e$INDEX"
  case "$rel_ex" in /*|*..*) exit 0 ;; esac
  cd "$HROOT/$rel_ex" 2> /dev/null || exit 0
  a="$(pe_show "$key")"
  [ -z "$a" ] || echo "addresses-json: $a"
  exit 0
fi
if [ "$PHASE" = validate ]; then
  # A container of its own, with no network and no credentials, for an example the runner ended
  # because the plan proxy refused it hosts by design: the head's validate, the evidence that
  # the early end hid no type error (skip-coverage.md, Design skips). One fixed line.
  rel_ex=$1; key="e$INDEX"
  case "$rel_ex" in /*|*..*) exit 0 ;; esac
  { load_state "$key" > /dev/null && [ "$CLASS" = ready ] && cd "$HROOT/$rel_ex" 2> /dev/null; } || { echo "validate: failed"; exit 0; }
  AK=; SK=; ST=; set_env "$key"
  if run_capped "$(left 120)" "$PLAN/out/$key-validate.txt" "${TFENV[@]}" terraform validate -no-color; then
    echo "validate: passed"
  else
    echo "validate: failed"
  fi
  exit 0
fi
if [ "$PHASE" = diff-init ]; then
  # The plan diff of an example whose head planned (Plan diff): the merge base example at the
  # base, and, when the change touches the example, the merge base example in the head tree.
  # No credentials.
  # The decision is recorded before any init: diff reads a missing one as no evidence.
  rel_ex=$1; key="e$INDEX"
  case "$rel_ex" in /*|*..*) exit 0 ;; esac
  { printf '%s\n' "$BASESHA" | grep -Eqx '[0-9a-f]{40}' && base_ready; } || { : > "$PLAN/state/$key-diff.nobase"; exit 0; }
  B="$(cd "$RUN/base" && pwd -P)"
  [ -d "$B/$rel_ex" ] || { : > "$PLAN/state/$key-diff.absent"; exit 0; }
  if example_changed "$rel_ex"; then : > "$PLAN/state/$key-diff.mixed"; else : > "$PLAN/state/$key-diff.unchanged"; fi
  init_state "$B/$rel_ex" "$key-base" "$B" "$RUN/g0-base.txt"
  if [ -f "$PLAN/state/$key-diff.mixed" ]; then
    if mixed_ready "$rel_ex"; then
      M="$(cd "$RUN/mixed" && pwd -P)"; init_state "$M/$rel_ex" "$key-mixed" "$M" "$RUN/g0-mixed.txt"
    else printf '%s\n' 'plan gate G0 not evaluated' "" "" "" "" > "$PLAN/state/$key-mixed.vars"; fi
  fi
  exit 0
fi
if [ "$PHASE" = diff-plan ]; then
  # Both plans of the plan diff, saved; their classes stay in this container's log.
  rel_ex=$1; key="e$INDEX"
  for side in base mixed; do
    load_state "$key-$side" > /dev/null || continue
    if [ "$CLASS" = ready ]; then cd "$RUN/$side/$rel_ex" || CLASS='plan gate G0 unreadable'; fi
    [ "$CLASS" = ready ] && pe_plan "$key-$side"
    echo "diff plan $side: $CLASS"
  done
  exit 0
fi
if [ "$PHASE" = diff ]; then
  # A container with no network and no credentials, after the plans ended: the comparison, one
  # plan-diff line, and for equal the head module plan's addresses for the host to check.
  rel_ex=$1; key="e$INDEX"
  case "$rel_ex" in /*|*..*) exit 0 ;; esac
  if [ -f "$PLAN/state/$key-diff.nobase" ]; then echo "plan-diff: not-run no-base"; exit 0; fi
  if [ -f "$PLAN/state/$key-diff.absent" ]; then echo "plan-diff: not-run absent-at-base"; exit 0; fi
  if [ -f "$PLAN/state/$key-diff.mixed" ]; then hk=$key-mixed hd=$RUN/mixed/$rel_ex
  elif [ -f "$PLAN/state/$key-diff.unchanged" ]; then hk=$key hd=$HROOT/$rel_ex
  else echo "plan-diff: not-run head-module-plan"; exit 0; fi
  { cd "$RUN/base/$rel_ex" 2> /dev/null && [ -f "$PLAN/saved/$key-base.tfplan" ]; } || { echo "plan-diff: not-run base-plan"; exit 0; }
  pd_show "$key-base" || { echo "plan-diff: not-run show"; exit 0; }
  { cd "$hd" 2> /dev/null && [ -f "$PLAN/saved/$hk.tfplan" ]; } || { echo "plan-diff: not-run head-module-plan"; exit 0; }
  pd_show "$hk" || { echo "plan-diff: not-run show"; exit 0; }
  pd_schema "$hk"
  pd_compare "$PLAN/out/$key-base-show.json" "$PLAN/out/$hk-show.json" "$PLAN/out/$hk-schema.json"
  [ -z "$PDADDR" ] || echo "plan-diff-json: $PDADDR"
  exit 0
fi
if [ "$PHASE" = base-plan ]; then
  rel_ex=$1; key="e$INDEX"
  if [ -f "$PLAN/state/$key-base.absent" ]; then echo "base: new under this change (absent at base)"
  elif load_state "$key-base"; then
    if [ "$CLASS" = ready ]; then cd "$RUN/base/$rel_ex" || CLASS='plan gate G0 unreadable'; fi
    [ "$CLASS" = ready ] && pe_plan "$key-base"
    case "$CLASS" in
      code-error) echo "base: reproduces at base" ;;
      planned|planned-no-changes) echo "base: new under this change" ;;
      *) echo "base: $CLASS" ;;
    esac
    [ -n "$DENIED" ] && echo "base-denied: $DENIED"
    [ "$CLASS" = 'plan pass ended: credentials' ] && echo "credentials: $CREDWHY"
  else
    echo "base: not available"
  fi
  exit 0
fi
rm -rf -- "$RUN/plan-addresses" && mkdir -m 700 "$RUN/plan-addresses"
[ "$GMODE" = laptop ] && PHEAD="$(clone_git rev-parse --verify -q 'HEAD^{commit}' 2> /dev/null)"
NALL=$#
STOP=; : > "$PLAN/out/pdq"
# example_block <example>: one example's record lines, written to its block file so a plan diff,
# run after every head, joins its own block (Plan diff).
example_block() {
  rel_ex=$1
  echo "example: $rel_ex"
  case "$rel_ex" in /*|*..*) echo "plan: plan gate G0 not an example directory"; return ;; esac
  key="e$EXN" # unique per example: two directories may share a last name
  SHOWTO=; PEX=; [ "$GMODE" = laptop ] && SHOWTO="$RUN/plan-addresses/addresses-$EXN.json" && PEX=$rel_ex
  plan_example "$HROOT/$rel_ex" "$key" "$HROOT" "$RUN/g0.txt"
  SHOWTO=; PEX=
  printf 'plan: %s\n' "$CLASS${KEPT:+ | $KEPT}" # never echo: zsh's echo turns a \n in the kept text into a line
  case "$CLASS" in planned|planned-no-changes) NPLAN=$((NPLAN + 1)) ;; exception:*) NEXC=$((NEXC + 1)) ;; esac
  [ -n "$SCOPE" ] && echo "scope: ${SCOPE% }"
  [ -n "$VERSIONS" ] && echo "modules: ${VERSIONS%;}"
  # A denial on data source reads alone is re-run at the merge base too (Design skips)
  [ -n "$DENIED" ] && echo "denied: $DENIED"
  # The plan diff of a planned example that reaches a plan diff directory waits for every head
  case "$CLASS" in
    planned|planned-no-changes)
      if [ -n "$DIFFDIRS" ] && [ -f "$RUN/plan-addresses/addresses-$EXN.json" ] &&
          reaches "$rel_ex" "$RUN/plan-addresses/addresses-$EXN.json"; then
        printf '%s %s\n' "$EXN" "$rel_ex" >> "$PLAN/out/pdq"
      fi ;;
  esac
  if [ "$CLASS" = code-error ] || [ -n "$DENIED" ]; then
    if base_ready; then
      if [ -d "$RUN/base/$rel_ex" ]; then
        plan_example "$(cd "$RUN/base" && pwd -P)/$rel_ex" "$key-base" "$(cd "$RUN/base" && pwd -P)" "$RUN/g0-base.txt"
        case "$CLASS" in
          code-error) echo "base: reproduces at base" ;;
          planned|planned-no-changes) echo "base: new under this change" ;;
          *) echo "base: $CLASS" ;;
        esac
        [ -n "$DENIED" ] && echo "base-denied: $DENIED"
      else
        echo "base: new under this change (absent at base)"
      fi
    else
      echo "base: not available"
    fi
  fi
  if [ "$CLASS" = 'plan pass ended: credentials' ]; then echo "credentials: $CREDWHY"; STOP=1; fi
}
for rel_ex in "$@"; do
  EXN=$((EXN + 1))
  example_block "$rel_ex" > "$PLAN/out/block.$EXN"
  [ -z "$STOP" ] || break
done
# The plan diffs, each in its own example's block, once every head has planned
if [ -z "$STOP" ]; then
  while read -r n rel_ex <&3; do
    pd_laptop "$rel_ex" "e$n" "$n" >> "$PLAN/out/block.$n"
  done 3< "$PLAN/out/pdq"
fi
n=0
while [ "$n" -lt "$EXN" ]; do n=$((n + 1)); cat "$PLAN/out/block.$n"; done
# The examples after the one that ended the pass: never started, unlike one the caller left out
shift "$EXN"
for rel_ex in "$@"; do echo "not reached: $rel_ex"; done
echo "plan summary: $NALL examples, $NPLAN planned, $NEXC exceptions, $((NALL - NPLAN - NEXC)) other"
exit 0
