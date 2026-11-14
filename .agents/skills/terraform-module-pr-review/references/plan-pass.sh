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
#       plan's addresses as one "addresses-json:" line for the host to check.
#       Every plan is saved with -out under <run-dir>/plan/saved. In laptop mode the saved head
#       plan of a planned example is read with terraform show -json after the plan has ended,
#       and its addresses, attribute and sensitive names, local module calls, the head
#       commit and the example directory are written to <run-dir>/plan-addresses/addresses-<n>.json, <n> the example's
#       place in the list (plan-pass.md, Saved plans and addresses).
#       Laptop mode needs --role-arn: the plan credentials are a session on that review role,
#       downscoped by plan-session-policy.json and issued by plan-session.sh, never the
#       profile's own (plan-pass.md, Credentials). Runner mode gets its session from the runner.
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
my $reg = qr{\A(?:registry\.terraform\.io/)?terraform-aws-modules/[a-z0-9-]+/aws(?://modules/[a-z0-9-]+)?\z};
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
PHERE="$(cd "$(dirname "$0")" && pwd -P)"
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
BASESHA=; GMODE=laptop; PHASE=; INDEX=; BUDGET=; ROLE_ARN=
HERE="$(cd "$(dirname "$0")" && pwd -P)"
while :; do
  case "${1:-}" in
    --base) BASESHA=${2:-}; shift 2 2>/dev/null || shift ;;
    --role-arn) ROLE_ARN=${2:-}; shift 2 2>/dev/null || shift ;;
    --mode) GMODE=${2:-}; shift 2 2>/dev/null || shift ;;
    --phase) PHASE=${2:-}; shift 2 2>/dev/null || shift ;;
    --index) INDEX=${2:-}; shift 2 2>/dev/null || shift ;;
    --budget) BUDGET=${2:-}; shift 2 2>/dev/null || shift ;;
    *) break ;;
  esac
done

# Opt-in and tools: a failed check stops the pass here, with a note for the record
case "$GMODE" in laptop|runner) ;; *) echo "plan pass not run: mode unknown"; exit 0 ;; esac
case "$PHASE" in
  '') ;;
  init) [ "$GMODE" = runner ] || { echo "plan pass not run: phase needs runner mode"; exit 0; } ;;
  plan|base-init|base-plan|show) [ "$GMODE" = runner ] || { echo "plan pass not run: phase needs runner mode"; exit 0; }
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
PGIDS=""
plan_stop() { # kill every process group this pass started, then remove the pass's own files
  for g in $(printf '%s\n' "$PGIDS"); do kill -KILL -- "-$g" 2>/dev/null; done
  wait 2>/dev/null
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

TFDIR="$(dirname "$(command -v terraform)")"
AWSBIN="$(command -v aws)"
AK=; SK=; ST=
# The role ARN and its account id are never recorded: any line holding one is dropped
LEAKS="$ROLE_ARN $(printf '%s\n' "$ROLE_ARN" | sed -nE 's/^arn:[^:]*:iam::([0-9]{12}):.*/\1/p')"
set_env() { # example key
  TFENV=(env -i PATH="/usr/bin:/bin:$TFDIR" HOME="$PLAN/home" TMPDIR="$PLAN/tmp"
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
    my $reg = qr{\A(?:registry\.terraform\.io/)?terraform-aws-modules/[a-z0-9-]+/aws(?://modules/[a-z0-9-]+)?\z};
    open(my $fh, "<", $j) or do { print "G2 $j:0\n"; exit };
    my @m = @{ decode_json(do { local $/; <$fh> })->{Modules} }; my %d;
    for (@m) { my $p = $_->{Dir}; $p = "$ex/$p" unless $p =~ m{\A/}; $d{$_->{Key}} = realpath($p) }
    for (@m) {
      next if $_->{Key} eq "";
      my ($s, $r) = ($_->{Source}, $d{$_->{Key}});
      unless (defined $r && -d $r) { print "G2 $j:$_->{Key}\n"; next }
      print "dir $r\n" if index("$r/", "$mr/") == 0;
      if ($s =~ $reg) { print "version $_->{Key} $s $_->{Version}\n"; next }
      if ($gm eq "runner" && $s =~ $gh) { print "version $_->{Key} $s -\n"; next }
      (my $pk = $_->{Key}) =~ s/\.?[^.]*\z//;
      my $pd = $d{$pk};
      my $lim = defined $pd && index("$pd/", "$root/") == 0 ? $root : $pd;
      print "G2 $j:$_->{Key}\n" unless $s =~ m{\A\.\.?/} && defined $lim && index("$r/", "$lim/") == 0;
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
    if [ "$n" -ge "$lim" ]; then kill -KILL -- "-$pid" 2>/dev/null; killed=1; break; fi
    sleep 1; n=$((n + 1))
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
# The addresses of a saved plan's resource changes, each index key removed, and per address
# the top-level attributes it plans a value for: names only, never a value or a key, which can
# carry what the account returned. Per address too, those attributes the plan marks sensitive
# in any instance, the head commit given as $h when it is a full SHA, and the example directory
# given as $e when it is a plain repository-relative path.
# shellcheck disable=SC2016 # a jq program
ADDR_JQ='
. as $plan
| [.resource_changes[]? | select(type == "object" and (.address | type == "string"))
 | {a: (.address | gsub("\\[[^\\]]*\\]"; "")), c: (.change // {})}
 | select(.a | test("^[A-Za-z0-9_.-]{1,300}$"))]
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
SHOWTO=
pe_show() { # key: the saved plan as JSON, reduced to its addresses on standard output
  [ -f "$PLAN/saved/$1.tfplan" ] || return 0
  AK=; SK=; ST=; set_env "$1"
  CAP_BYTES=16777216 CAP_QUIET_ERR=1 run_capped "$(left 120)" "$PLAN/out/$1-show.json" "${TFENV[@]}" \
    terraform show -json -no-color "$PLAN/saved/$1.tfplan" || return 0
  jq -c --arg h "$PHEAD" --arg e "$PEX" "$ADDR_JQ" "$PLAN/out/$1-show.json" 2> /dev/null
}
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
  # The default pass's init left its own lock file and .terraform/ here; the plan pass reads neither
  git ls-files --error-unmatch .terraform.lock.hcl > /dev/null 2>&1 || rm -f .terraform.lock.hcl
  rm -rf .terraform
  AK=; SK=; ST=; set_env "$2"
  run_capped "$(left 180)" "$PLAN/out/$2-init.txt" "${TFENV[@]}" terraform init -backend=false -input=false -no-color
  rc=$?; CLASS="$(class_of "$rc" "$PLAN/out/$2-init.txt" init)"; out="$PLAN/out/$2-init.txt"
  if [ "$CLASS" = ok ]; then
    pi="$(post_init "$2" "$1")"
    SCOPE="$SCOPE$(sed -n 's/^dir //p' "$PLAN/out/$2-modules.txt" 2>/dev/null | sort -u | rel | tr '\n' ' ')"
    VERSIONS="$(printf '%s\n' "$pi" | sed -n 's/^version //p' | tr '\n' ';')"
    h="$(printf '%s\n' "$pi" | grep -v '^version ')"
    if [ -n "$h" ]; then exc_or_gate "$h"; else CLASS=ready; fi
  fi
}
pe_plan() { # key: the credentials and the plan, then the kept line
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
  esac
  # Laptop mode: the head plan's addresses, read by a terraform process of its own after the
  # plan has ended, with no credentials (plan-pass.md, Saved plans and addresses). run_capped
  # sets out, so this comes after the kept line.
  if [ -n "$SHOWTO" ]; then
    case "$CLASS" in planned|planned-no-changes) pe_show "$1" > "$SHOWTO" ;; esac
  fi
}
plan_example() { # absolute example directory, key, root (the clone or the base worktree), saved g0 file
  pe_init "$@"
  pe_plan "$2"
  [ -z "$INCD" ] || git ls-files --error-unmatch .terraform.lock.hcl > /dev/null 2>&1 || rm -f .terraform.lock.hcl
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

NPLAN=0; NEXC=0; EXN=0; HROOT=$CROOT # plan_example moves CROOT to the base worktree for a re-run
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
  echo "plan: $CLASS${KEPT:+ | $KEPT}"
  [ "$CLASS" = 'plan pass ended: credentials' ] && echo "credentials: $CREDWHY"
  [ -n "$SCOPE" ] && echo "scope: ${SCOPE% }"
  [ -n "$VERSIONS" ] && echo "modules: ${VERSIONS%;}"
  # The merge base re-run is a later phase, so only an example that needs it pays for it
  if [ "$CLASS" = code-error ]; then
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
    [ "$CLASS" = 'plan pass ended: credentials' ] && echo "credentials: $CREDWHY"
  else
    echo "base: not available"
  fi
  exit 0
fi
rm -rf -- "$RUN/plan-addresses" && mkdir -m 700 "$RUN/plan-addresses"
[ "$GMODE" = laptop ] && PHEAD="$(clone_git rev-parse --verify -q 'HEAD^{commit}' 2> /dev/null)"
NALL=$#
for rel_ex in "$@"; do
  EXN=$((EXN + 1))
  echo "example: $rel_ex"
  case "$rel_ex" in /*|*..*) echo "plan: plan gate G0 not an example directory"; continue ;; esac
  key="e$EXN" # unique per example: two directories may share a last name
  SHOWTO=; PEX=; [ "$GMODE" = laptop ] && SHOWTO="$RUN/plan-addresses/addresses-$EXN.json" && PEX=$rel_ex
  plan_example "$HROOT/$rel_ex" "$key" "$HROOT" "$RUN/g0.txt"
  SHOWTO=; PEX=
  echo "plan: $CLASS${KEPT:+ | $KEPT}"
  case "$CLASS" in planned|planned-no-changes) NPLAN=$((NPLAN + 1)) ;; exception:*) NEXC=$((NEXC + 1)) ;; esac
  [ -n "$SCOPE" ] && echo "scope: ${SCOPE% }"
  [ -n "$VERSIONS" ] && echo "modules: ${VERSIONS%;}"
  if [ "$CLASS" = code-error ]; then
    if base_ready; then
      if [ -d "$RUN/base/$rel_ex" ]; then
        plan_example "$(cd "$RUN/base" && pwd -P)/$rel_ex" "$key-base" "$(cd "$RUN/base" && pwd -P)" "$RUN/g0-base.txt"
        case "$CLASS" in
          code-error) echo "base: reproduces at base" ;;
          planned|planned-no-changes) echo "base: new under this change" ;;
          *) echo "base: $CLASS" ;;
        esac
      else
        echo "base: new under this change (absent at base)"
      fi
    else
      echo "base: not available"
    fi
  fi
  if [ "$CLASS" = 'plan pass ended: credentials' ]; then echo "credentials: $CREDWHY"; break; fi
done
# The examples after the one that ended the pass: never started, unlike one the caller left out
shift "$EXN"
for rel_ex in "$@"; do echo "not reached: $rel_ex"; done
echo "plan summary: $NALL examples, $NPLAN planned, $NEXC exceptions, $((NALL - NPLAN - NEXC)) other"
exit 0
