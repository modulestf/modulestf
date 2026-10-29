#!/usr/bin/env bash
# shellcheck disable=SC2016 # the perl programs below are single-quoted on purpose
# The default verification pass of terraform-module-pr-review, as one file. Rules and reasons:
# verify-pass.md. Runs the same under bash and zsh. Invoke it by an absolute path in the skill
# as installed, or in a host's own checkout pinned by commit; never from the head, the
# workspace or a copy the head could have written:
#
#   <bash|zsh> /abs/path/verify-pass.sh run <run-dir> --files <files.json> --base <sha> \
#       --out <out.json> [--prefix <module-root>] [--dir <example-dir>]...
#       terraform init -backend=false and terraform validate in each example directory the
#       change touches, the version bump skip, the records, the merge base re-run. Writes
#       the results as one JSON object to <out.json>. --dir limits the pass to the named
#       example directories, for a re-run outside the sandbox (verify-pass.md, Commands).
#   <bash|zsh> /abs/path/verify-pass.sh check <run-dir> --files <files.json> --base <sha> \
#       --head <sha> --results <results.json> [--prefix <module-root>]
#       Checks results a host produced: shape, the two SHAs, and the example directories
#       against this run's own list. Prints "results accepted" and exits 0, or prints
#       "results rejected: <reason>" and exits 1. Never runs terraform.
#   <bash|zsh> /abs/path/verify-pass.sh merge <run-dir> --results <inside.json> \
#       --outside <outside.json> --out <out.json>
#       Replaces each entry of the run inside the sandbox with the entry of the same
#       directory from the run outside it, marked "outside": true (verify-pass.md, Commands).
#
# <run-dir> is the absolute run directory Workspace printed, "<root>/pr-review.XXXXXX", holding
# the clone at <run-dir>/clone. Exit 2 is a usage error or a refused input; nothing is written.

CMD=${1:-}
RUN=${2:-}
die() { echo "verify-pass.sh: $1" >&2; exit 2; }
case "$CMD" in run|check|merge) ;; *) die "usage: verify-pass.sh run|check|merge <run-dir> ..." ;; esac
ROOT="${RUN%/*}"
case "$ROOT" in /?*) ;; *) die "the run directory must be absolute" ;; esac
case "$RUN" in "$ROOT"/pr-review.??????) ;; *) die "not a run directory: $RUN" ;; esac
DIR="$RUN/clone"
[ -d "$DIR" ] || die "no clone in $RUN"
CROOT="$(cd "$DIR" && pwd -P)"
shift 2

FILES=; BASESHA=; OUT=; PREFIX=; HEADSHA=; RESULTS=; ONLY=; OUTSIDE=
NL='
'
while [ $# -gt 0 ]; do
  case "$1" in
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

sha_ok "$BASESHA" || die "--base must be a full commit SHA"
[ -f "$FILES" ] || die "--files must name a readable file"
PREFIX="${PREFIX%/}"
case "$PREFIX" in /*|*..*|.) die "--prefix must be repository-relative" ;; esac
[ -n "$PREFIX" ] && PREFIX="$PREFIX/"
MROOT="$CROOT/${PREFIX%/}"

W="$RUN/verify"
if ! { rm -rf -- "$W" && mkdir -m 700 "$W"; }; then die "cannot create $W"; fi
trap 'rm -rf -- "$W"' EXIT

# The example directories the change touches, one line each: "<reason><TAB><dir>", in path
# order. Exit 3: not an array of file objects. Exit 4: a path holds a control character.
DIRS_PL='
use strict; use warnings; use JSON::PP; use Cwd qw(realpath);
my ($files, $root, $pre) = @ARGV; $pre //= "";
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
my %dirs; my $ex = "${pre}examples/";
for my $f (@$d) {
  for my $p (grep { defined } $f->{filename}, $f->{previous_filename}) {
    next unless index($p, $ex) == 0;
    my ($name, $more) = split m{/}, substr($p, length $ex), 2;
    next unless length $name && $name ne "." && $name ne "..";
    $dirs{"$ex$name"} = 1;
  }
}
for my $dir (sort keys %dirs) {
  my $abs = "$root/$dir";
  next unless -e $abs || -l $abs;
  my $r = realpath($abs);
  unless (defined $r && $r eq $abs) { print "skipped-symlink\t$dir\n"; next }
  next unless -d $abs;
  opendir my $dh, $abs or next;
  my @tf = grep { /\.tf\z/ && -f "$abs/$_" } readdir $dh;
  next unless @tf;
  print bump($dir) ? "skipped-version-bump" : "verified", "\t$dir\n";
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

dirs_list() { # the example directories and their reasons, into the named file
  perl -e "$DIRS_PL" "$FILES" "$CROOT" "$PREFIX" > "$1"
  case $? in
    0) ;;
    4) die "a changed path holds a control character" ;;
    *) die "--files is not a JSON array of file objects" ;;
  esac
}

if [ "$CMD" = check ]; then
  [ -f "$RESULTS" ] || die "--results must name a readable file"
  sha_ok "$HEADSHA" || die "--head must be a full commit SHA"
  dirs_list "$W/list.tsv"
  TAB="$(printf '\t')"
  while IFS="$TAB" read -r reason rel; do
    jq -cn --arg dir "$rel" --arg reason "$reason" '{dir:$dir, reason:$reason}'
  done < "$W/list.tsv" > "$W/list.jsonl"
  reject() { echo "results rejected: $1"; exit 1; }
  jq -e . "$RESULTS" > /dev/null 2>&1 || reject "not JSON"
  jq -e 'type == "object" and keys == ["base_sha","dirs","head_sha","terraform_version"]' \
    "$RESULTS" > /dev/null 2>&1 || reject "shape"
  jq -e --arg h "$HEADSHA" '.head_sha == $h' "$RESULTS" > /dev/null 2>&1 || reject "head_sha"
  jq -e --arg b "$BASESHA" '.base_sha == $b' "$RESULTS" > /dev/null 2>&1 || reject "base_sha"
  jq -e '
    def num: . == null or (type == "number" and . == floor and . >= 0 and . <= 255);
    def line: . == null or (type == "string" and length <= 300 and test("^[ -~]*$"));
    def side($recs): type == "object" and keys == ["init","line","record","validate"]
      and (.init | num) and (.validate | num) and (.line | line)
      and (.record | type == "string") and (.record as $r | $recs | any(.[]; . == $r));
    def head_ok: side(["code-result","init-failed","not-run-environment","terraform-absent"])
      and (if .record == "terraform-absent" then .init == null and .validate == null and .line == null
           elif .record == "init-failed" then .init != null and .init != 0 and .validate == null
           elif .record == "code-result" then .init == 0 and .validate != null
           else .init != null end);
    def base_ok: side(["absent-at-base","base-unavailable","code-result","init-failed","not-run-environment"])
      and (if (.record == "absent-at-base" or .record == "base-unavailable")
           then .init == null and .validate == null and .line == null else .init != null end);
    (.terraform_version == null or (.terraform_version | type == "string" and test("^[0-9]+[.][0-9]+[.][0-9]+[0-9A-Za-z.+-]*$")))
    and (.dirs | type == "array")
    and all(.dirs[]; type == "object" and keys == ["base","dir","head","outside","reason"]
      and (.dir | type == "string") and .outside == false
      and (if .reason == "skipped-version-bump" or .reason == "skipped-symlink" then .head == null and .base == null
           elif .reason == "verified" then (.head | head_ok)
             and (if .head.record == "code-result" and .head.validate != 0
                  then (.base | base_ok) else .base == null end)
           else false end))
  ' "$RESULTS" > /dev/null 2>&1 || reject "shape"
  jq -e --slurpfile l "$W/list.jsonl" '[.dirs[] | {dir, reason}] == $l' "$RESULTS" > /dev/null 2>&1 \
    || reject "example directories"
  echo "results accepted"
  exit 0
fi

case "$OUT" in /?*) ;; *) die "--out must be an absolute path" ;; esac
[ -d "${OUT%/*}/" ] || die "the directory of --out must exist"
HEAD="$(git -C "$DIR" rev-parse HEAD 2> /dev/null)"
sha_ok "$HEAD" || die "the clone has no head commit"
dirs_list "$W/list.tsv"
if [ -n "$ONLY" ]; then
  printf '%s' "$ONLY" | while IFS= read -r rel; do
    cut -f2 "$W/list.tsv" | grep -qxF -- "$rel" || { echo "verify-pass.sh: not an example directory of this change: $rel" >&2; exit 2; }
  done || exit 2
fi
perl -e "$HOSTS_PL" "$FILES" > "$W/hosts.txt" || die "--files is not a JSON array of file objects"
mkdir -p "$RUN/plugin-cache"

mkdir "$W/home"
env | sed -n 's/^\(TF_TOKEN_[A-Za-z0-9_]*\)=.*/\1/p' > "$W/tokens.txt"
tf() { # directory, arguments: terraform with no credential and no inherited terraform settings
  (cd -- "$1" && shift && while IFS= read -r v; do unset "$v"; done < "$W/tokens.txt" \
    && env -u AWS_PROFILE -u AWS_DEFAULT_PROFILE -u AWS_ACCESS_KEY_ID \
    -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_SECURITY_TOKEN -u AWS_ROLE_ARN \
    -u AWS_WEB_IDENTITY_TOKEN_FILE -u AWS_CONTAINER_CREDENTIALS_FULL_URI \
    -u AWS_CONTAINER_CREDENTIALS_RELATIVE_URI -u AWS_CONTAINER_AUTHORIZATION_TOKEN \
    -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN \
    -u SSH_AUTH_SOCK -u SSH_ASKPASS -u GIT_ASKPASS -u GIT_SSH -u GIT_SSH_COMMAND \
    -u TF_CLI_ARGS -u TF_CLI_ARGS_init -u TF_CLI_ARGS_validate -u TF_DATA_DIR -u TF_WORKSPACE \
    HOME="$W/home" NETRC=/dev/null TF_CLI_CONFIG_FILE=/dev/null \
    AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true \
    TF_PLUGIN_CACHE_DIR="$RUN/plugin-cache" TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=true \
    TF_IN_AUTOMATION=1 TF_INPUT=0 CHECKPOINT_DISABLE=1 GIT_TERMINAL_PROMPT=0 \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_COUNT=2 \
    GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null \
    GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1= \
    terraform "$@")
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
verify() { # tree root, module root, example directory: prints one side object
  INIT=; VALID=; LINE=
  tf "$1/$3" init -backend=false -input=false -no-color > "$W/out.txt" 2>&1
  INIT=$?
  if [ "$INIT" -ne 0 ]; then
    classify "$W/out.txt" "$2"
    if [ "$CLASS" = environment ]; then side "$INIT" "" not-run-environment "$LINE"
    else side "$INIT" "" init-failed "$LINE"; fi
    return
  fi
  tf "$1/$3" validate -no-color > "$W/out.txt" 2>&1
  VALID=$?
  [ "$VALID" -eq 0 ] && { side 0 0 code-result ""; return; }
  classify "$W/out.txt" "$2"
  if [ "$CLASS" = environment ]; then side 0 "$VALID" not-run-environment "$LINE"
  else side 0 "$VALID" code-result "$LINE"; fi
}
clone_git() {
  GIT_LFS_SKIP_SMUDGE=1 git -C "$DIR" -c core.hooksPath=/dev/null \
    -c filter.lfs.smudge=cat -c filter.lfs.process= \
    -c filter.lfs.required=false "$@"
}
BTREE="$RUN/verify-base"
base_ready() { # the merge base worktree for a re-run, added once
  [ -d "$BTREE" ] && return 0
  git -C "$DIR" cat-file -e "${BASESHA}^{commit}" 2> /dev/null \
    || clone_git fetch -q --depth=1 -- origin "$BASESHA" > /dev/null 2>&1 || return 1
  clone_git worktree add -q --detach -- "$BTREE" "$BASESHA" > /dev/null 2>&1
}

TFV=
if command -v terraform > /dev/null 2>&1; then
  mkdir "$W/empty"
  TFV="$(tf "$W/empty" version -json 2> /dev/null | jq -r '.terraform_version // empty' 2> /dev/null)"
  printf '%s\n' "$TFV" | grep -Eqx '[0-9]+[.][0-9]+[.][0-9]+[0-9A-Za-z.+-]*' || TFV=
  HAVE_TF=1
else
  HAVE_TF=0
fi

TAB="$(printf '\t')"
: > "$W/dirs.jsonl"
while IFS="$TAB" read -r reason rel; do
  if [ -n "$ONLY" ]; then printf '%s' "$ONLY" | grep -qxF -- "$rel" || continue; fi
  if [ "$reason" != verified ]; then
    jq -cn --arg dir "$rel" --arg reason "$reason" \
      '{dir:$dir, reason:$reason, head:null, base:null, outside:false}' >> "$W/dirs.jsonl"
    continue
  fi
  BASEJ=null
  if [ "$HAVE_TF" = 0 ]; then
    HEADJ="$(side "" "" terraform-absent "")"
  else
    HEADJ="$(verify "$CROOT" "$MROOT" "$rel")"
    if [ "$(printf '%s' "$HEADJ" | jq -r 'select(.record == "code-result" and .validate != 0) | "rerun"')" = rerun ]; then
      if ! base_ready; then
        BASEJ="$(side "" "" base-unavailable "")"
      elif ! git -C "$DIR" cat-file -e "${BASESHA}:$rel" 2> /dev/null; then
        BASEJ="$(side "" "" absent-at-base "")"
      else
        BROOT="$(cd "$BTREE" && pwd -P)"
        if [ "$(cd "$BROOT/$rel" 2> /dev/null && pwd -P)" = "$BROOT/$rel" ]; then
          BASEJ="$(verify "$BROOT" "$BROOT/${PREFIX%/}" "$rel")"
        else # a symbolic link, or reached through one, at the base: never entered
          BASEJ="$(side "" "" base-unavailable "")"
        fi
      fi
    fi
  fi
  jq -cn --arg dir "$rel" --argjson head "$HEADJ" --argjson base "$BASEJ" \
    '{dir:$dir, reason:"verified", head:$head, base:$base, outside:false}' >> "$W/dirs.jsonl"
done < "$W/list.tsv"

if ! { jq -n --arg head "$HEAD" --arg base "$BASESHA" --arg ver "$TFV" --slurpfile dirs "$W/dirs.jsonl" \
  '{head_sha:$head, base_sha:$base, terraform_version:(if $ver == "" then null else $ver end), dirs:$dirs}' \
  > "$OUT.tmp" && mv -- "$OUT.tmp" "$OUT"; }; then die "cannot write $OUT"; fi
exit 0
