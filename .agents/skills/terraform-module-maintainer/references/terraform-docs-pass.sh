#!/bin/bash
# terraform-docs-pass.sh - regenerate the terraform-docs region of README.md in an
# untrusted workspace, as quality-gates.md "The Documentation Region" sets out. Each
# numbered step there is marked "Step <n>" below. Any failed check reports that entry
# stale with the check's name; nothing is changed in the workspace before step 10.
#
# Usage:
#   terraform-docs-pass.sh [--profile FILE] --workspace DIR ENTRY...
#   terraform-docs-pass.sh [--profile FILE] --print-constants
#
# ENTRY is what the fix's "Generated content made stale" sentence names, one per
# argument: "the terraform-docs region of modules/x/README.md", "modules/x/README.md",
# "README.md", or a wrapper file such as "wrappers/x/main.tf".
# --profile defaults to the terraform-aws-modules profile beside this skill. It is read
# from the skill, never from the workspace.
#
# Output, one line per entry, then a closing line:
#   regenerated <dir>
#   stale <dir or entry N> <reason>
#   complete | incomplete
#
# Invoker-only settings, read before the environment is cleared, never from the
# workspace: TFDOCS_PASS_CACHE_DIR (the cache directory), TFDOCS_PASS_CURL (the curl
# program, for tests), TFDOCS_PASS_DEADLINE_SECONDS and TFDOCS_PASS_TOOL_SECONDS (may
# only lower the 120 and 60 second limits). HTTPS_PROXY or https_proxy is passed to the
# download only.

# Step 0: a clean shell. Re-run under env -i with the fixed PATH and no startup files.
if [ "${TFDOCS_PASS_CLEAN:-}" != 1 ]; then
  exec /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C TFDOCS_PASS_CLEAN=1 \
    TFDOCS_PASS_PROXY="${HTTPS_PROXY:-${https_proxy:-}}" \
    TFDOCS_PASS_CURL="${TFDOCS_PASS_CURL:-}" \
    TFDOCS_PASS_CACHE_DIR="${TFDOCS_PASS_CACHE_DIR:-}" \
    TFDOCS_PASS_DEADLINE_SECONDS="${TFDOCS_PASS_DEADLINE_SECONDS:-}" \
    TFDOCS_PASS_TOOL_SECONDS="${TFDOCS_PASS_TOOL_SECONDS:-}" \
    /bin/bash --noprofile --norc "$0" "$@"
fi

set -u
set -m
umask 077

CAP_DIRS=10
MAX_FILES=200
MAX_FILE_BYTES=1048576
MAX_DIR_BYTES=8388608
MAX_ARCHIVE_BYTES=67108864
DEADLINE=120
TOOL_SECONDS=60
KILL_GRACE=5
CPU_SECONDS=30
FSIZE_BLOCKS=4096
CONFIG_NAMES=".terraform-docs.yml .terraform-docs.yaml .config/.terraform-docs.yml .config/.terraform-docs.yaml .tfdocs.d"

lower() { # lower NAME VALUE: VALUE replaces NAME's limit only when it is digits and smaller
  case $2 in '' | *[!0-9]*) return ;; esac
  [ "$2" -gt 0 ] && [ "$2" -lt "${!1}" ] && printf -v "$1" '%s' "$2"
}
lower DEADLINE "$TFDOCS_PASS_DEADLINE_SECONDS"
lower TOOL_SECONDS "$TFDOCS_PASS_TOOL_SECONDS"
START=$SECONDS
left() { echo $((DEADLINE - (SECONDS - START))); }

# Step 0: helpers by platform, never by what is installed.
case $(uname -s) in Linux) OS=linux ;; Darwin) OS=darwin ;; *) OS= ;; esac
case $(uname -m) in x86_64 | amd64) ARCH=amd64 ;; aarch64 | arm64) ARCH=arm64 ;; *) ARCH= ;; esac
sha256() {
  if [ "$OS" = linux ]; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}
sha256_names() { # sha256_names DIR NAME...: "<hash> <name>" per file, in order
  local d=$1
  shift
  (cd -- "$d" && if [ "$OS" = linux ]; then sha256sum -- "$@"; else shasum -a 256 -- "$@"; fi) | awk '{print $1, $2}'
}
statf() { # inode mode size uid links
  if [ "$OS" = linux ]; then stat -c '%i %a %s %u %h' "$1"; else stat -f '%i %Lp %z %u %l' "$1"; fi
}
home_dir() {
  if [ "$OS" = linux ]; then getent passwd "$(id -u)" | awk -F: '{print $6}'; else perl -e 'print((getpwuid($<))[7])'; fi
}

MYPID=${BASHPID:-$$}
# ids PID: "<process group> <parent>" of a live process, or nothing.
ids() {
  if [ "$OS" = linux ]; then
    [ -r "/proc/$1/stat" ] && sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $3, $2}'
  else
    ps -o pgid= -o ppid= -p "$1" 2>/dev/null | awk '{print $1, $2}'
  fi
}
child_of() { [ "$(ids "$1" | awk '{print $2}')" = "$2" ]; } # child_of PID PARENT
running() { # running PID: the process exists and has not exited (a zombie has)
  local st
  if [ "$OS" = linux ]; then
    st=$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $1}')
  else
    st=$(ps -o stat= -p "$1" 2>/dev/null | awk '{print substr($1, 1, 1)}')
  fi
  [ -n "$st" ] && [ "$st" != Z ]
}
# bounded SECONDS OUT CMD...: run CMD with its output in OUT, and kill it when SECONDS pass.
# Called only from this shell, never inside a command substitution, and it relies on no
# process group: the watchdog's sleep is recorded and stopped by its process id, and every
# signal is sent only after the target is checked to be the expected child.
WD=0
bounded() {
  local secs=$1 out=$2 pid wpid spid wd rc
  shift 2
  [ "$secs" -gt 0 ] || return 124
  WD=$((WD + 1))
  wd=$RUN/tmp/wd-$WD
  mkdir "$wd" || return 1
  "$@" >"$out" 2>/dev/null &
  pid=$!
  (sleep "$secs" & echo $! >"$wd/sleep"; wait $!
    [ -e "$wd/disarm" ] || { child_of "$pid" "$MYPID" && kill -KILL "$pid"; }) >/dev/null 2>&1 &
  wpid=$!
  wait "$pid"
  rc=$?
  : >"$wd/disarm"
  local tries=0
  while [ ! -s "$wd/sleep" ] && [ "$tries" -lt 200 ]; do tries=$((tries + 1)); sleep 0.01; done
  spid=$(cat "$wd/sleep" 2>/dev/null)
  [ -n "$spid" ] && child_of "$spid" "$wpid" && kill -TERM "$spid" 2>/dev/null
  wait "$wpid" 2>/dev/null
  rm -rf -- "$wd"
  return "$rc"
}
# value VAR SECONDS CMD...: VAR becomes the bounded command's output.
value() {
  local var=$1 secs=$2
  shift 2
  bounded "$secs" "$RUN/tmp/value" "$@" || return 1
  printf -v "$var" '%s' "$(cat "$RUN/tmp/value")"
}

PROFILE=
WORKSPACE=
PRINT=0
while [ $# -gt 0 ]; do
  case $1 in
    --profile) PROFILE=${2:-}; shift 2 || exit 2 ;;
    --workspace) WORKSPACE=${2:-}; shift 2 || exit 2 ;;
    --print-constants) PRINT=1; shift ;;
    --) shift; break ;;
    -*) echo "unknown option" >&2; exit 2 ;;
    *) break ;;
  esac
done
SELF_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P) || exit 2
[ -n "$PROFILE" ] || PROFILE=$SELF_DIR/../profiles/terraform-aws-modules/PROFILE.md

# Step 0: constants from the profile's "Documentation regeneration in an untrusted
# workspace" section.
read_profile() {
  [ -f "$PROFILE" ] && [ ! -L "$PROFILE" ] || return 1
  VERSION=$(grep -E '^- \*\*Version\.\*\* terraform-docs `v[0-9]+\.[0-9]+\.[0-9]+`' "$PROFILE" |
    head -n 1 | sed -E 's/.*`(v[0-9]+\.[0-9]+\.[0-9]+)`.*/\1/')
  URL=$(awk '/^- \*\*Address\.\*\*/ {f = 1; next} f && /`https:\/\// {print; exit}' "$PROFILE" |
    sed -E 's/.*`(https:[^`]*)`.*/\1/')
  PLATFORM=$OS-$ARCH
  HASH=
  [ -n "$OS" ] && [ -n "$ARCH" ] &&
    HASH=$(grep -E "^ *\| \`$PLATFORM\` \| \`[0-9a-f]{64}\` \|" "$PROFILE" | head -n 1 |
      sed -E 's/.*`([0-9a-f]{64})`.*/\1/')
  MARKERS=$(awk '/^- \*\*Recognised marker pairs\.\*\*/ {f = 1} f && /^- \*\*/ && !/Recognised/ {exit} f' "$PROFILE" |
    grep -oE '`<!-- [A-Z_ -]+ -->`' | tr -d '`')
  CONFIG=$(awk '/^- \*\*Configuration text,\*\*/ {f = 1; next}
    f == 1 && /^ *```yaml$/ {f = 2; next}
    f == 2 && /^ *```$/ {exit}
    f == 2 {sub(/^  /, ""); print}' "$PROFILE")
  B1=$(sed -n 1p <<<"$MARKERS"); E1=$(sed -n 2p <<<"$MARKERS")
  B2=$(sed -n 3p <<<"$MARKERS"); E2=$(sed -n 4p <<<"$MARKERS")
  [[ $VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  [[ $URL == https://github.com/* && $URL == *'<platform>'* ]] || return 1
  [ "$(wc -l <<<"$MARKERS" | tr -d ' ')" = 4 ] && [ -n "$B2" ] && [ -n "$E2" ] || return 1
  [[ $CONFIG == *"$B1"* && $CONFIG == *"$E1"* ]] || return 1
  URL=${URL//<platform>/$PLATFORM}
  return 0
}
PROFILE_OK=1
read_profile || PROFILE_OK=0

if [ "$PRINT" = 1 ]; then
  [ "$PROFILE_OK" = 1 ] || { echo "profile constants unreadable" >&2; exit 1; }
  printf 'version %s\nplatform %s\nurl %s\nhash %s\nmarkers %s | %s | %s | %s\n' \
    "$VERSION" "$PLATFORM" "$URL" "${HASH:-none}" "$B1" "$E1" "$B2" "$E2"
  printf '%s\n' "$CONFIG"
  exit 0
fi

[ -n "$WORKSPACE" ] && [ $# -gt 0 ] || { echo "usage: --workspace DIR ENTRY..." >&2; exit 2; }
WS=$(cd -P -- "$WORKSPACE" 2>/dev/null && pwd -P) || { echo "workspace unreadable" >&2; exit 2; }

# Invoker-only inputs never come from the workspace: a profile, a curl program or a cache
# directory whose real path is the workspace, inside it or above it is refused.
real_of() { # real path of an existing file or directory
  if [ -d "$1" ]; then (cd -P -- "$1" && pwd -P); else
    local dir
    dir=$(cd -P -- "$(dirname -- "$1")" && pwd -P) && echo "$dir/${1##*/}"
  fi
}
refused() {
  local r
  r=$(real_of "$1") || return 0
  [ "$r" = "$WS" ] || [[ $WS == "$r"/* ]] || [[ $r == "$WS"/* ]]
}
if refused "$PROFILE"; then PROFILE_OK=0; fi
if [ -n "$TFDOCS_PASS_CURL" ]; then
  if [ -L "$TFDOCS_PASS_CURL" ] || [ ! -f "$TFDOCS_PASS_CURL" ] || refused "$TFDOCS_PASS_CURL"; then
    echo "TFDOCS_PASS_CURL refused" >&2; exit 2
  fi
fi

REPORT=()
INCOMPLETE=0
stale() { REPORT+=("stale $1 $2"); INCOMPLETE=1; }

# Step 1: scope. Map each entry to a directory, drop repeats, cap at CAP_DIRS.
DIRS=()
n=0
for raw in "$@"; do
  n=$((n + 1))
  e=${raw#the terraform-docs region of }
  if [[ $e == README.md ]]; then
    d=.
  elif [[ $e =~ ^(modules|examples)/[a-z0-9-]+/README\.md$ ]]; then
    d=${e%/README.md}
  elif [[ $e == wrappers/* ]]; then
    if [[ $e =~ ^wrappers/[A-Za-z0-9._/-]+$ && $e != *..* ]]; then label=$e; else label="entry $n"; fi
    stale "$label" "outside the safe set in an untrusted workspace"
    continue
  else
    stale "entry $n" "not a documentation region"
    continue
  fi
  seen=0
  for x in "${DIRS[@]+"${DIRS[@]}"}"; do [ "$x" = "$d" ] && seen=1; done
  [ "$seen" = 1 ] && continue
  if [ "${#DIRS[@]}" -ge "$CAP_DIRS" ]; then stale "$d" "over the cap"; continue; fi
  DIRS+=("$d")
done

RUN=
RUN_REAL=
TPID=
WPID=
PENDING=
TOOL=
TOOL_STATE=unknown

alive_child() { # the recorded pid still leads its own group and is still our child
  [ "$(ids "$1")" = "$1 $MYPID" ]
}
signal_group() { alive_child "$2" && kill "-$1" -- "-$2" 2>/dev/null; }

# Step 11: clean up on every exit.
cleanup() {
  [ -n "$TPID" ] && signal_group KILL "$TPID"
  [ -n "$WPID" ] && child_of "$WPID" "$MYPID" && kill -TERM "$WPID" 2>/dev/null
  [ -n "$PENDING" ] && rm -f -- "$PENDING"
  if [ -n "$RUN" ] && [[ $RUN == /tmp/tfdocs-pass.* ]] && [ -d "$RUN" ] && [ ! -L "$RUN" ]; then
    rm -rf -- "$RUN"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

inside_or_above() { # true when real path $1 is the workspace, inside it, or above it
  [ "$1" = "$WS" ] || [[ $WS == "$1"/* ]] || [[ $1 == "$WS"/* ]]
}

# Step 4: the run directory.
make_run() {
  RUN=$(mktemp -d /tmp/tfdocs-pass.XXXXXXXX) || { RUN=; return 1; }
  chmod 700 "$RUN" || return 1
  RUN_REAL=$(cd -P -- "$RUN" && pwd -P) || return 1
  inside_or_above "$RUN_REAL" && return 1
  mkdir "$RUN/home" "$RUN/tmp" "$RUN/work" || return 1
}

own_dir_ok() { # not a symbolic link, a directory, ours, mode 700, apart from the workspace
  local real
  [ ! -L "$1" ] && [ -d "$1" ] && [ -O "$1" ] || return 1
  [ "$(statf "$1" | awk '{print $2}')" = 700 ] || return 1
  real=$(cd -P -- "$1" && pwd -P) || return 1
  ! inside_or_above "$real"
}

# Step 5: the tool, from a per-user cache keyed by the archive's SHA-256.
install_tool() {
  local entry=$1 archive=$RUN/tmp/archive.tar.gz tmp curl=${TFDOCS_PASS_CURL:-/usr/bin/curl} t
  local proxy=()
  [ -n "$TFDOCS_PASS_PROXY" ] && proxy=(HTTPS_PROXY="$TFDOCS_PASS_PROXY" https_proxy="$TFDOCS_PASS_PROXY")
  local h
  t=$(left)
  [ "$t" -gt 0 ] || return 1
  bounded "$t" /dev/null /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C "${proxy[@]+"${proxy[@]}"}" \
    "$curl" -q -L --proto =https --proto-redir =https --fail --silent --show-error \
    --max-filesize "$MAX_ARCHIVE_BYTES" --max-time "$t" -o "$archive" "$URL" || return 1
  value h "$(left)" sha256 "$archive" && [ "$h" = "$HASH" ] || return 1
  tmp=$(mktemp "$entry/.terraform-docs.XXXXXXXX") || return 1
  bounded "$(left)" "$tmp" tar -xOf "$archive" terraform-docs && [ -s "$tmp" ] &&
    chmod 700 "$tmp" || { rm -f -- "$tmp"; return 1; }
  bounded "$(left)" "$entry/.sha.tmp" sha256 "$tmp" || { rm -f -- "$tmp" "$entry/.sha.tmp"; return 1; }
  mv -f -- "$entry/.sha.tmp" "$entry/terraform-docs.sha256" && mv -f -- "$tmp" "$entry/terraform-docs" || return 1
  rm -f -- "$archive"
}
tool_ok() {
  local entry=$1
  [ -f "$entry/terraform-docs" ] && [ ! -L "$entry/terraform-docs" ] && [ -f "$entry/terraform-docs.sha256" ] || return 1
  local h
  value h "$(left)" sha256 "$entry/terraform-docs" && [ "$h" = "$(cat "$entry/terraform-docs.sha256")" ]
}
REINSTALLED=0
ensure_tool() { # sets TOOL, or FAIL; a failure is the whole run's
  [ "$TOOL_STATE" = failed ] && { FAIL=$TOOL_FAIL; return 1; }
  if [ "$TOOL_STATE" = ok ]; then
    tool_ok "$(dirname "$TOOL")" && return 0
    TOOL_STATE=failed
    TOOL_FAIL="tool unavailable or hash mismatch"
    [ "$REINSTALLED" = 0 ] || { FAIL=$TOOL_FAIL; return 1; }
    REINSTALLED=1
    rm -f -- "$TOOL" "$TOOL.sha256"
    install_tool "$(dirname "$TOOL")" && tool_ok "$(dirname "$TOOL")" || { FAIL=$TOOL_FAIL; return 1; }
    TOOL_STATE=ok
    return 0
  fi
  TOOL_STATE=failed
  TOOL_FAIL="no hash for this platform"
  [ -n "$HASH" ] || { FAIL=$TOOL_FAIL; return 1; }
  TOOL_FAIL="tool unavailable or hash mismatch"
  local home cache entry
  cache=$TFDOCS_PASS_CACHE_DIR
  if [ -z "$cache" ]; then
    value home "$(left)" home_dir && [ -n "$home" ] && [ -d "$home" ] || { FAIL=$TOOL_FAIL; return 1; }
    if [ "$OS" = darwin ]; then cache=$home/Library/Caches/modulestf-terraform-docs; else cache=$home/.cache/modulestf-terraform-docs; fi
  fi
  [ -e "$cache" ] || [ -L "$cache" ] || { mkdir -p -- "$(dirname -- "$cache")" && mkdir -m 700 -- "$cache"; } ||
    { FAIL=$TOOL_FAIL; return 1; }
  own_dir_ok "$cache" || { FAIL="cache directory"; TOOL_FAIL=$FAIL; return 1; }
  entry=$cache/$HASH
  [ -e "$entry" ] || [ -L "$entry" ] || mkdir -m 700 -- "$entry" || { FAIL=$TOOL_FAIL; return 1; }
  own_dir_ok "$entry" || { FAIL="cache directory"; TOOL_FAIL=$FAIL; return 1; }
  if ! tool_ok "$entry"; then
    if [ -e "$entry/terraform-docs" ]; then REINSTALLED=1; fi
    rm -f -- "$entry/terraform-docs" "$entry/terraform-docs.sha256"
    install_tool "$entry" && tool_ok "$entry" || { FAIL=$TOOL_FAIL; return 1; }
  fi
  TOOL=$entry/terraform-docs
  TOOL_STATE=ok
}

# Step 2: gates by name and lstat, then the record of every file to copy.
FAIL=
gate_dir() { # gate_dir DIR: sets RECORD and LISTING, or FAIL
  local d=$1 p name c s count=0 total=0 have_readme=0 line
  local -a names files=()
  RECORD=
  LISTING=
  p=$d
  while :; do
    for c in $CONFIG_NAMES; do
      if [ -e "$p/$c" ] || [ -L "$p/$c" ]; then FAIL="terraform-docs configuration present"; return 1; fi
    done
    [ "$p" = "$WS" ] && break
    p=$(dirname -- "$p")
  done
  shopt -s nullglob dotglob
  names=("$d"/*)
  shopt -u nullglob dotglob
  for p in "${names[@]+"${names[@]}"}"; do
    name=${p##*/}
    LISTING+="$name"$'\n'
    case $name in
      *.tf.json | *.tofu | *.tofu.json | override.tf | *_override.tf)
        FAIL="input file the copy would leave out"; return 1 ;;
      *.tf | README.md) ;;
      *) continue ;;
    esac
    [ "$name" = README.md ] && have_readme=1
    [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { FAIL="file name"; return 1; }
    if [ -L "$p" ] || [ ! -f "$p" ]; then FAIL="not a regular file"; return 1; fi
    [ -O "$p" ] || { FAIL="not owned by the invoking user"; return 1; }
    s=$(statf "$p") || { FAIL="stat"; return 1; }
    set -- $s
    [ "$5" = 1 ] || { FAIL="link count"; return 1; }
    [ "$3" -le "$MAX_FILE_BYTES" ] || { FAIL="file over 1 MiB"; return 1; }
    count=$((count + 1))
    total=$((total + $3))
    [ "$count" -le "$MAX_FILES" ] || { FAIL="over 200 files"; return 1; }
    [ "$total" -le "$MAX_DIR_BYTES" ] || { FAIL="over 8 MiB"; return 1; }
    files+=("$name $1 $2 $3")
  done
  [ "$have_readme" = 1 ] || { FAIL="no README.md"; return 1; }
  local -a fnames=()
  for line in "${files[@]}"; do fnames+=("${line%% *}"); done
  bounded "$(left)" "$RUN/tmp/hashes" sha256_names "$d" "${fnames[@]}" || { FAIL="hash or deadline"; return 1; }
  local i=0 h hn
  while read -r h hn; do
    [ "$hn" = "${fnames[$i]}" ] || { FAIL="hash"; return 1; }
    RECORD+="${files[$i]} $h"$'\n'
    i=$((i + 1))
  done <"$RUN/tmp/hashes"
  [ "$i" = "${#files[@]}" ] || { FAIL="hash"; return 1; }
}

count_of() { grep -aoF -- "$2" "$1" | wc -l | tr -d ' '; }
offset_of() { grep -aboF -- "$2" "$1" | head -n 1 | cut -d: -f1; }
# marker_pair FILE: 1 for the template pair, 2 for the older pair, else fails
marker_pair() {
  local f=$1 b1 e1 b2 e2
  b1=$(count_of "$f" "$B1"); e1=$(count_of "$f" "$E1")
  b2=$(count_of "$f" "$B2"); e2=$(count_of "$f" "$E2")
  if [ "$b1$e1$b2$e2" = 1100 ] && [ "$(offset_of "$f" "$B1")" -lt "$(offset_of "$f" "$E1")" ]; then echo 1; return 0; fi
  if [ "$b1$e1$b2$e2" = 0011 ] && [ "$(offset_of "$f" "$B2")" -lt "$(offset_of "$f" "$E2")" ]; then echo 2; return 0; fi
  return 1
}

# Step 9: compare the new README.md with the pristine copy outside the region.
region_ok() {
  local old=$1 new=$2 ob oe nb ne rs
  [ "$(marker_pair "$new")" = 1 ] || { FAIL="marker test after the run"; return 1; }
  ob=$(offset_of "$old" "$B1"); oe=$(offset_of "$old" "$E1")
  nb=$(offset_of "$new" "$B1"); ne=$(offset_of "$new" "$E1")
  cmp -s <(head -c "$ob" "$old") <(head -c "$nb" "$new") || { FAIL="text before the region changed"; return 1; }
  cmp -s <(tail -c "+$((oe + 1))" "$old") <(tail -c "+$((ne + 1))" "$new") || { FAIL="text after the region changed"; return 1; }
  rs=$((ne - nb - ${#B1}))
  [ "$rs" -gt 0 ] && [ "$rs" -lt "$MAX_FILE_BYTES" ] || { FAIL="region size"; return 1; }
  head -c "$ne" "$new" | tail -c "$rs" | grep -q '[^[:space:]]' || { FAIL="region empty"; return 1; }
}

manifest() { # manifest DIR OUT: names, and hashes of every regular file but README.md
  local d=$1 out=$2 p
  local -a names=()
  shopt -s nullglob dotglob
  for p in "$d"/*; do names+=("${p##*/}"); done
  shopt -u nullglob dotglob
  {
    printf 'name %s\n' "${names[@]+"${names[@]}"}"
    for p in "${names[@]+"${names[@]}"}"; do
      if [ "$p" = README.md ] || [ -L "$d/$p" ] || [ ! -f "$d/$p" ]; then echo "kind $p"; fi
    done
  } >"$out"
  local -a hashed=()
  for p in "${names[@]+"${names[@]}"}"; do
    [ "$p" != README.md ] && [ ! -L "$d/$p" ] && [ -f "$d/$p" ] && hashed+=("$p")
  done
  [ "${#hashed[@]}" -gt 0 ] || return 0
  bounded "$(left)" "$out.h" sha256_names "$d" "${hashed[@]}" && cat "$out.h" >>"$out"
}

# Step 8: run the tool in its own process group under limits and a watchdog.
run_tool() {
  local w=$1 cfg=$2 out=$3 t rc
  t=$(left)
  [ "$t" -gt "$TOOL_SECONDS" ] && t=$TOOL_SECONDS
  [ "$t" -gt 0 ] || return 1
  (
    cd -- "$w" || exit 97
    ulimit -t "$CPU_SECONDS" && ulimit -f "$FSIZE_BLOCKS" || exit 98
    exec /usr/bin/env -i PATH=/usr/bin:/bin HOME="$RUN/home" TMPDIR="$RUN/tmp" LC_ALL=C \
      "$TOOL" --config "$cfg" .
  ) >"$out" 2>&1 &
  TPID=$!
  local wd=$RUN/tmp/tool-wd spid f
  mkdir "$wd" || return 1
  (trap ': >"$wd/done"' EXIT
    sleep "$t" & echo $! >"$wd/sleep"; wait $!
    [ -e "$wd/disarm" ] && exit 0
    signal_group TERM "$TPID"
    [ -e "$wd/disarm" ] && exit 0
    sleep "$KILL_GRACE" & echo $! >"$wd/sleep2"; wait $!
    [ -e "$wd/disarm" ] || signal_group KILL "$TPID") >/dev/null 2>&1 &
  WPID=$!
  wait "$TPID"
  rc=$?
  TPID=
  : >"$wd/disarm"
  # Stop the watchdog's sleeps by process id until it has exited. The loop also ends when
  # the watchdog is gone without writing its done file, as after a SIGKILL from outside,
  # and in any case past its own time plus the grace and 5 seconds.
  local cap=$((SECONDS + t + KILL_GRACE + 5))
  until [ -e "$wd/done" ] || ! running "$WPID" || [ "$SECONDS" -gt "$cap" ]; do
    for f in sleep sleep2; do
      spid=$(cat "$wd/$f" 2>/dev/null)
      [ -n "$spid" ] && child_of "$spid" "$WPID" && kill -TERM "$spid" 2>/dev/null
    done
    sleep 0.05
  done
  wait "$WPID" 2>/dev/null
  WPID=
  rm -rf -- "$wd"
  return "$rc"
}

process_dir() { # process_dir N DIR: regenerate one directory or set FAIL
  local i=$1 rel=$2 d w cfg orig new c mode tmp now
  FAIL=
  [ "$(left)" -gt 0 ] || { FAIL="deadline"; return 1; }
  # Step 1: path shape, real path and no symbolic link component.
  if [ "$rel" = . ]; then
    d=$WS
  else
    [ ! -L "$WS/${rel%%/*}" ] && [ ! -L "$WS/$rel" ] && [ -d "$WS/$rel" ] || { FAIL="directory path"; return 1; }
    d=$WS/$rel
    [ "$(cd -P -- "$d" && pwd -P)" = "$d" ] || { FAIL="directory path"; return 1; }
  fi
  gate_dir "$d" || return 1
  local record=$RECORD listing=$LISTING
  # Step 3: markers.
  case $(marker_pair "$d/README.md") in
    1) ;;
    2) FAIL="no parity fixture for this marker pair"; return 1 ;;
    *) FAIL="marker test"; return 1 ;;
  esac
  ensure_tool || return 1
  # Step 6: configuration.
  cfg=$RUN/tfdocs-config-$i.yml
  printf '%s\n' "$CONFIG" >"$cfg" || { FAIL="configuration"; return 1; }
  # Step 7: copy, checked against the record.
  w=$RUN/work/$i
  orig=$RUN/orig-$i.md
  mkdir "$w" || { FAIL="copy"; return 1; }
  local -a copied=()
  while read -r name _ _ _ c; do
    [ -n "$name" ] || continue
    cp -- "$d/$name" "$w/$name" || { FAIL="copy"; return 1; }
    copied+=("$c $name")
  done <<<"$record"
  bounded "$(left)" "$RUN/tmp/copied" sha256_names "$w" $(printf '%s\n' "${copied[@]}" | awk '{print $2}') &&
    [ "$(cat "$RUN/tmp/copied")" = "$(printf '%s\n' "${copied[@]}")" ] || { FAIL="changed during copy"; return 1; }
  cp -- "$w/README.md" "$orig" || { FAIL="copy"; return 1; }
  manifest "$w" "$RUN/tmp/before-$i" || { FAIL="manifest"; return 1; }
  # Step 8: run.
  run_tool "$w" "$cfg" "$RUN/tool-$i.log" || { FAIL="tool failed or timed out"; return 1; }
  [ "$(left)" -gt 0 ] || { FAIL="deadline"; return 1; }
  # Step 9: after the run.
  new=$w/README.md
  manifest "$w" "$RUN/tmp/after-$i" && cmp -s "$RUN/tmp/before-$i" "$RUN/tmp/after-$i" ||
    { FAIL="files created, deleted or changed by the run"; return 1; }
  if [ -L "$new" ] || [ ! -f "$new" ]; then FAIL="README.md no longer a regular file"; return 1; fi
  region_ok "$orig" "$new" || return 1
  # Step 10: copy back after re-checking the workspace against the step 2 record.
  mode=$(printf '%s\n' "$record" | awk '$1 == "README.md" {print $3}')
  gate_dir "$d" || { FAIL="workspace changed"; return 1; }
  [ "$RECORD" = "$record" ] && [ "$LISTING" = "$listing" ] || { FAIL="workspace changed"; return 1; }
  if cmp -s "$orig" "$new"; then return 0; fi
  tmp=$(mktemp "$d/.README.md.XXXXXXXX") || { FAIL="copy back"; return 1; }
  PENDING=$tmp
  cat -- "$new" >"$tmp" && chmod "$mode" "$tmp" && mv -f -- "$tmp" "$d/README.md" ||
    { rm -f -- "$tmp"; PENDING=; FAIL="copy back"; return 1; }
  PENDING=
}

if [ "${#DIRS[@]}" -gt 0 ]; then
  if [ "$PROFILE_OK" != 1 ]; then
    for d in "${DIRS[@]}"; do stale "$d" "profile constants unreadable"; done
  elif ! make_run; then
    for d in "${DIRS[@]}"; do stale "$d" "run directory"; done
  else
    i=0
    for d in "${DIRS[@]}"; do
      i=$((i + 1))
      if process_dir "$i" "$d"; then REPORT+=("regenerated $d"); else stale "$d" "$FAIL"; fi
    done
  fi
fi

printf '%s\n' "${REPORT[@]}"
if [ "$INCOMPLETE" = 1 ]; then echo incomplete; else echo complete; fi
exit 0
