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
#       given, at most 12 in laptop mode. Prints "plan pass mode:" once, then the record lines per example on
#       standard output: "example:", "plan:", "scope:", "modules:" and "base:", and a
#       "gate-hit" line per hit. --mode laptop is the default; --mode runner relaxes the
#       code-execution gates and is refused outside a container (plan-pass.md, Modes).
#       Runner mode only: --budget <seconds> replaces the pass's 60-minute budget, for a
#       runner that holds one budget across its containers, and there is no cap on the number
#       of examples. --phase init runs G0's saved result, the gates and init for every
#       example and saves each one's state under <run-dir>/plan, with no credential call;
#       --phase plan --index <n> <example-dir> then plans that one example from the saved
#       state and prints its record lines, with no summary. The runner runs each phase in its
#       own container behind its own egress proxy (plan-pass.md, Modes).
#       Laptop mode needs --role-arn: the plan credentials are a session on that review role,
#       downscoped by plan-session-policy.json and issued by plan-session.sh, never the
#       profile's own (plan-pass.md, Credentials). Runner mode gets its session from the runner.
#   <bash|zsh> /abs/path/plan-pass.sh gates <run-dir> <laptop|runner> <clone|downloaded>
#       The per-file gates alone, over the absolute .tf paths on standard input. Read only,
#       for the fixtures.
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
my ($mode, $root, $gm) = @ARGV; $root = realpath($root); my $run = ($gm // "") eq "runner";
my %pok = map { ("registry.terraform.io/hashicorp/$_" => 1) } qw(aws random time tls cloudinit);
my @pre = qw(aws_ random_ time_ tls_ cloudinit_);
my %dok = map { ($_ => 1) } qw(aws_caller_identity aws_canonical_user_id aws_partition aws_region aws_availability_zones aws_iam_policy_document aws_service_principal aws_default_tags tls_public_key cloudinit_config);
my %top = map { ($_ => 1) } qw(terraform provider variable locals output resource data module moved removed);
my $reg = qr{\A(?:registry\.terraform\.io/)?terraform-aws-modules/[a-z0-9-]+/aws(?://modules/[a-z0-9-]+)?\z};
my $B = qr{(?<b>\{(?:[^{}]++|(?&b))*\})};
sub hit { my ($g, $f, $t, $p) = @_; my $l = defined $p ? 1 + (substr($t, 0, $p) =~ tr/\n//) : 0; print "$g $f:$l\n" }
sub canon { my $s = lc shift; $s = "registry.terraform.io/$s" if ($s =~ tr{/}{}) == 1; $s }
sub pok { my $c = canon(shift); $run ? $c =~ m{\Aregistry\.terraform\.io/hashicorp/[a-z0-9-]+\z} : $pok{$c} }
sub blank { my $t = shift; $t =~ s{"((?:[^"\\\n]|\\.)*)"}{"\"" . ($1 =~ tr/\n/x/cr) . "\""}ge; $t }
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
      return undef unless $s =~ /\G.*?^[ \t]*\Q$id\E[ \t]*$/gcsm;
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
while (my $f = <STDIN>) {
  chomp $f; my $fh;
  if ($f eq "UNREADABLE" or !open($fh, "<", $f)) { hit("G0", $f); next }
  my $raw = do { local $/; <$fh> }; close $fh;
  hit("G0", $f) if $f =~ m{(?:\A|/)(?:[^/]*_)?override\.tf\z};
  if ($run) { runner_file($f, $raw); next }
  (my $code = blank($raw)) =~ s{(?:#|//)[^\n]*}{}g;
  hit("G0", $f, $code, $-[0]) if $code =~ /[^\x00-\x7f]/;
  (my $lb = $raw) =~ s{(?:#|//)[^\n]*}{}g;
  while ($lb =~ /^[ \t]*[A-Za-z_][\w-]*((?:[ \t]+"[^"\n]*")+)[ \t]*\{/mg) { my ($at, $l) = ($-[1], $1); hit("G0", $f, $lb, $at) if $l =~ /[^\x00-\x7f]/ }
  hit("G0", $f, $code, $-[0]) if $code =~ m{/\*};
  while ($code =~ /$KW/g) { hit("G3", $f, $code, $-[0]) }
  (my $nc = $raw) =~ s{(?:#|//)[^\n]*}{}g;
  for my $t ($raw, $nc) {
    my $bt = blank($t);
    while ($t =~ /(?:provisioner|\bfile\w*\s*\(|templatefile\s*\(|provider::|\bcloud\s*\{|backend\s+")/g) { hit("G3", $f, $t, $-[0]) }
    while ($t =~ /^([A-Za-z_][\w-]*)(?:\s+"[^"]*")*\s*\{/mg) { hit("G3", $f, $t, $-[0]) unless $top{$1} }
    while ($t =~ /^\s*(?:ephemeral|check|import|action)\b(?:\s+"[^"]*")*\s*\{/mg) { hit("G3", $f, $t, $-[0]) }
    while ($t =~ /\b(resource|data)\s+"([^"]*)"/g) {
      my ($k, $y, $at) = ($1, $2, $-[0]);
      my $ok = grep { index($y, $_) == 0 } @pre;
      $ok = 0 if $k eq "data" && !$dok{$y};
      hit("G3", $f, $t, $at) unless $ok;
    }
    while ($bt =~ /\bprovider\s+"[^"]*"\s*/g) {
      my $at = $-[0];
      if ($bt =~ /\G$B/gc) {
        my $body = substr($+{b}, 1, -1);
        if ($body =~ /<</) { hit("G3", $f, $bt, $at); next }
        $body =~ s/\bdefault_tags\s*$B//g;
        for my $line (split /\n/, $body) {
          next unless $line =~ /\S/;
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
if [ "${1:-}" = gates ]; then
  case "${3:-}/${4:-}" in laptop/clone|laptop/downloaded|runner/clone|runner/downloaded) ;;
    *) echo "plan-pass.sh: gates <run-dir> <laptop|runner> <clone|downloaded>" >&2; exit 2 ;; esac
  h="$(perl -e "$GATES_PL" "$4" "$CROOT" "$3")"
  [ -n "$h" ] && { printf '%s\n' "$h"; exc_or_gate "$h" > /dev/null; echo "class: $CLASS"; }
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
[ "${1:-}" = plan ] || { echo "plan-pass.sh: first argument is g0, plan or gates" >&2; exit 2; }

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
  plan|base-init|base-plan) [ "$GMODE" = runner ] || { echo "plan pass not run: phase needs runner mode"; exit 0; }
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
if [ "$GMODE" = runner ]; then PROV_RE='registry\.terraform\.io/hashicorp/[a-z0-9-]+'
else PROV_RE='registry\.terraform\.io/hashicorp/(aws|random|time|tls|cloudinit)'; fi

PLAN="$RUN/plan"
if [ -z "$PHASE" ] || [ "$PHASE" = init ]; then
  mkdir -m 700 "$PLAN"
  mkdir "$PLAN/data" "$PLAN/cache" "$PLAN/home" "$PLAN/tmp" "$PLAN/out" "$PLAN/state"
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
get_creds() {
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
  "${TFENV[@]}" perl -e 'alarm 30; exec @ARGV' "$AWSBIN" sts get-caller-identity --no-cli-pager < /dev/null > /dev/null 2>&1 || return 1
  # The write probe: a dry-run write the session must not be allowed. Only
  # UnauthorizedOperation goes on; DryRunOperation, any other answer or a timeout ends the pass.
  PROBE="$("${TFENV[@]}" perl -e 'alarm 30; exec @ARGV' "$AWSBIN" ec2 create-vpc --cidr-block 10.255.0.0/16 --dry-run --no-cli-pager < /dev/null 2>&1)"
  case "$PROBE" in *'(UnauthorizedOperation)'*) PROBE= ;; *) PROBE=; return 1 ;; esac
}

scope() { # absolute example directory
  perl -MCwd=realpath -e '
    my ($root, @q) = (realpath($ARGV[0]), realpath($ARGV[1])); my (%seen, %f);
    while (defined(my $d = shift @q)) {
      next if $seen{$d}++;
      opendir(my $h, $d) or do { print "UNREADABLE\n"; next };
      for my $n (sort grep { /\.tf\z/ } readdir $h) {
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
setpgrp(0, 0); my $out = shift;
open(my $o, ">", $out) or exit 125;
my $pid = open(my $in, "-|"); exit 125 unless defined $pid;
if (!$pid) { open(STDERR, ">&", \*STDOUT); open(STDIN, "<", "/dev/null"); exec @ARGV; exit 127 }
my ($n, $buf) = (0, "");
while (my $r = sysread($in, $buf, 65536)) {
  if ($n + $r >= 1048576) {
    syswrite($o, $buf, 1048576 - $n); close $o;
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
ENV_RE='no valid credential sources|NoCredentialProviders|failed to (retrieve|refresh cached) credentials|InvalidClientTokenId|SignatureDoesNotMatch|AccessDenied|UnauthorizedOperation|ExpiredToken|Throttling|RequestLimitExceeded|i/o timeout|context deadline exceeded|timed out|dial tcp|no such host|Error accessing remote module registry|Failed to query available provider packages|Failed to retrieve available versions|connection refused|connection reset|TLS handshake|failed to instantiate provider|Unrecognized remote plugin message|plugin exited before we could connect|operation not permitted'
class_of() { # exit status, output file, init or plan
  [ "$1" -eq 124 ] && { echo environment; return; }
  if [ "$1" -eq 0 ]; then
    [ "$3" = init ] && { echo ok; return; }
    grep -Eq '^Plan: .* to destroy\.$' "$2" && { echo planned; return; }
    grep -Eq '^No changes\.' "$2" && { echo planned-no-changes; return; }
    echo 'output unrecognised'; return
  fi
  perl -e "$DIAG_PL" < "$2" > "$2.block" || { echo 'output unrecognised'; return; }
  grep -Eiq "$ENV_RE" "$2.block" && { echo environment; return; }
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
pe_init() { # absolute example directory, key, root (the clone or the base worktree), saved g0 file
  # Everything before the credentials: gates, init, post_init. CLASS "ready" means plan next.
  CROOT=$3; CLASS=; KEPT=; VERSIONS=; SCOPE=; out=; INCD=
  [ "$(left 1)" -gt 0 ] || { CLASS=budget; return; }
  [ -e "$4" ] || { CLASS='plan gate G0 not evaluated'; return; }
  [ -s "$4" ] && { gate_class "$(cat "$4")"; return; }
  SCOPE="$(scope "$1" | sed 's|/[^/]*$||' | sort -u | rel | tr '\n' ' ')"
  h="$(scope "$1" | perl -e "$GATES_PL" clone "$CROOT" "$GMODE"; committed_locks "$1")"
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
      run_capped "$(left 300)" "$PLAN/out/$1-plan.txt" "${TFENV[@]}" terraform plan -input=false -lock=false -refresh=true -no-color -compact-warnings
      rc=$?; CLASS="$(class_of "$rc" "$PLAN/out/$1-plan.txt" plan)"; out="$PLAN/out/$1-plan.txt"
    fi
    AK=; SK=; ST=
  fi
  case "$CLASS" in
    planned) KEPT="$(grep -E -m 1 '^Plan: .* to destroy\.$' "$out" | kept)" ;;
    code-error) KEPT="$(kept < "$out.block")" ;;
  esac
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
  [ -n "$SCOPE" ] && echo "scope: ${SCOPE% }"
  [ -n "$VERSIONS" ] && echo "modules: ${VERSIONS%;}"
  # The merge base re-run is a later phase, so only an example that needs it pays for it
  if [ "$CLASS" = code-error ]; then
    if [ -n "$BASESHA" ]; then echo "base: deferred"; else echo "base: not available"; fi
  fi
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
  else
    echo "base: not available"
  fi
  exit 0
fi
for rel_ex in "$@"; do
  EXN=$((EXN + 1))
  echo "example: $rel_ex"
  if [ "$GMODE" = laptop ] && [ "$EXN" -gt 12 ]; then echo "plan: budget"; continue; fi
  case "$rel_ex" in /*|*..*) echo "plan: plan gate G0 not an example directory"; continue ;; esac
  key="e$EXN" # unique per example: two directories may share a last name
  plan_example "$HROOT/$rel_ex" "$key" "$HROOT" "$RUN/g0.txt"
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
  [ "$CLASS" = 'plan pass ended: credentials' ] && break
done
echo "plan summary: $# examples, $NPLAN planned, $NEXC exceptions, $(($# - NPLAN - NEXC)) other"
exit 0
