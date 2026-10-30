#!/bin/bash
# Checks the reviewer's git safety form (terraform-module-reviewer references/git-safety.md).
# For each setting a hostile workspace can put in .git/config or .git/info/attributes,
# it builds a throwaway repository that points the setting at a program writing a
# marker file, shows the plain command writes the marker (the vector is live), and
# shows every query of the form's table, run through safe_git, writes none.
# All repositories live in a temporary directory; nothing touches the network.
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$SRC/.agents/skills/terraform-module-reviewer/references/git-safety.md"
TMP="$(mktemp -d)" || { echo "FAIL setup: mktemp"; exit 1; }
trap 'rm -rf -- "$TMP"' EXIT
fails=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails + 1)); }
skip() { echo "skip $1: $2"; }

# Keep the host's own configuration out of every run, plain or safe.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

# The form under test, taken from the document, not copied.
form="$(awk '/^## The form/{f=1} f&&/^```sh$/{c=1;next} c&&/^```$/{exit} c' "$DOC")"
if [ -z "$form" ]; then echo "FAIL setup: no sh block under 'The form' in $DOC"; exit 1; fi
eval "$form"
declare -F safe_git >/dev/null && declare -F safe_git_partial >/dev/null && declare -F safe_git_refuse >/dev/null ||
  { echo "FAIL setup: the form does not define safe_git, safe_git_partial and safe_git_refuse"; exit 1; }

MARK="$TMP/marker"
mkdir -p "$TMP/bin"
# A program that only writes the marker. -file prints its file argument (textconv),
# -stdin copies its input (filters, pager), -noop prints nothing.
printf '#!/bin/sh\n: > "%s"\ncat "$1" 2>/dev/null\nexit 0\n' "$MARK" > "$TMP/bin/evil-file"
printf '#!/bin/sh\n: > "%s"\ncat\n' "$MARK" > "$TMP/bin/evil-stdin"
printf '#!/bin/sh\n: > "%s"\nexit 1\n' "$MARK" > "$TMP/bin/evil-noop"
chmod +x "$TMP/bin/"*

# Base repository: two commits, a tag on the first.
BASE="$TMP/base"
git init -q -b main "$BASE"
printf 'one\n' > "$BASE/a.txt"
git -C "$BASE" add a.txt && git -C "$BASE" commit -qm base && git -C "$BASE" tag v1
printf 'one\ntwo\n' > "$BASE/a.txt"
git -C "$BASE" commit -qam head

fresh() { rm -rf "$TMP/r"; cp -R "$BASE" "$TMP/r"; rm -f "$MARK"; }
cfg() { git -C "$TMP/r" config "$@"; }
attr() { mkdir -p "$TMP/r/.git/info"; printf '%s\n' "$1" > "$TMP/r/.git/info/attributes"; }

# The queries of the form's table, read from the document: the second column of each
# row under the "Exact form" header, placeholders filled with this repository's names.
queries="$(awk -F'|' '/Exact form after/{t=1;next} t&&/^\|-/{next} t&&!/^\|/{exit} t{print $3}' "$DOC" |
  sed 's/^ *`//; s/` *$//; s/<base>/v1/g; s/<rev>/HEAD/g; s/<path>/a.txt/g; s/<sha>/v1/g')"
nq="$(printf '%s\n' "$queries" | grep -c .)"
[ "$nq" -ge 8 ] || { echo "FAIL setup: read $nq queries from the table, expected at least 8"; exit 1; }
ok "table: $nq queries read from the document"
# The document's own rule: diff, show and log always carry both flags.
while IFS= read -r q; do
  case "$q" in diff\ *|show\ *|log\ *)
    case "$q" in *--no-ext-diff*--no-textconv*|*--no-textconv*--no-ext-diff*) ;;
      *) fail table "row lacks --no-ext-diff --no-textconv: $q" ;; esac ;;
  esac
done <<<"$queries"
# A script that runs every query through a form ($active, the document's unless a
# self-check weakens it), so the same table can also run on a terminal.
active="$form"
write_table() {
  { printf '%s\n' "$active" 'cd "$1" || exit 1'
    printf '%s\n' "$queries" | sed 's/^/safe_git /'; } > "$TMP/table.sh"
}

# Every query of the form's table, through safe_git, in repository $1.
table() { write_table; bash "$TMP/table.sh" "$1" >/dev/null 2>&1 </dev/null; }

# live NAME CMD...: the plain command must write the marker.
live() {
  local name="$1"; shift
  rm -f "$MARK"
  ( cd "$TMP/r" && "$@" ) >/dev/null 2>&1 </dev/null
  if [ -e "$MARK" ]; then ok "$name: live with the plain command"
  else fail "$name" "the plain command did not run the program, so the vector is not shown live"; fi
}
# safe NAME: no query of the table may write the marker.
safe() {
  rm -f "$MARK"
  table "$TMP/r"
  if [ -e "$MARK" ]; then fail "$1" "a query in the safe form ran the program"
  else ok "$1: the table in the safe form runs nothing"; fi
}

# diff.external
fresh; cfg diff.external "$TMP/bin/evil-noop"
live diff.external git diff v1 HEAD; safe diff.external

# diff.<driver>.command named by an attribute
fresh; attr '* diff=x'; cfg diff.x.command "$TMP/bin/evil-noop"
live diff-driver-command git diff v1 HEAD; safe diff-driver-command

# diff.<driver>.textconv named by an attribute
fresh; attr '* diff=x'; cfg diff.x.textconv "$TMP/bin/evil-file"
live textconv git diff v1 HEAD; safe textconv

# filter.<driver>.smudge, reached through a harmless textconv
fresh; attr '* filter=f diff=x'; cfg filter.f.smudge "$TMP/bin/evil-stdin"; cfg diff.x.textconv cat
live smudge git diff v1 HEAD; safe smudge

# core.fsmonitor
fresh; cfg core.fsmonitor "$TMP/bin/evil-noop"
live fsmonitor git status; safe fsmonitor

# log.showSignature with gpg.program, on a commit that carries a signature header
fresh
tree="$(git -C "$TMP/r" rev-parse 'HEAD^{tree}')"; parent="$(git -C "$TMP/r" rev-parse HEAD)"
signed="$(printf 'tree %s\nparent %s\nauthor t <t@example.com> 1700000000 +0000\ncommitter t <t@example.com> 1700000000 +0000\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n AAAA\n -----END PGP SIGNATURE-----\n\nsigned\n' "$tree" "$parent" |
  git -C "$TMP/r" hash-object -t commit -w --stdin)"
git -C "$TMP/r" update-ref refs/heads/main "$signed"
cfg log.showSignature true; cfg gpg.program "$TMP/bin/evil-noop"
live show-signature git log -1; safe show-signature

# core.pager and pager.log: only reached when the output is a terminal
in_pty() {
  case "$(uname -s)" in
    Darwin) script -q /dev/null "$@" ;;
    *) script -qec "$(printf '%q ' "$@")" /dev/null ;;
  esac
}
if command -v script >/dev/null 2>&1; then
  fresh; cfg core.pager "$TMP/bin/evil-stdin"; cfg pager.log "$TMP/bin/evil-stdin"
  live pager in_pty git log -1
  rm -f "$MARK"; write_table
  ( cd "$TMP/r" && in_pty bash "$TMP/table.sh" "$TMP/r" ) >/dev/null 2>&1 </dev/null
  if [ -e "$MARK" ]; then fail pager "a query of the table on a terminal ran the pager"
  else ok "pager: the table on a terminal runs no pager"; fi
else
  skip pager "no script(1) to give git a terminal"
fi

# Version gate for GIT_NO_LAZY_FETCH (git 2.44). Decided once, with its own skip reason.
git_ver="$(git version | awk '{print $3}')"
lazy_env=no
if ! printf '1\n2\n' | sort -V -C 2>/dev/null; then
  skip lazy-fetch-version "sort -V is not available to compare git versions"
elif printf '2.44.0\n%s\n' "$git_ver" | sort -V -C; then
  lazy_env=yes
else
  skip lazy-fetch-version "git $git_ver has no GIT_NO_LAZY_FETCH; safe_git_refuse is the guard there"
fi

# Lazy fetch in a partial clone. The server allows filters; the clone lacks the blobs.
SERVER="$TMP/server"
git clone -q --bare "$BASE" "$SERVER" && git -C "$SERVER" config uploadpack.allowFilter true
lazy() {
  rm -rf "$TMP/r"; rm -f "$MARK"
  git clone -q --no-checkout --filter=blob:none "file://$SERVER" "$TMP/r" 2>/dev/null
}
lazy; cfg remote.origin.url "ssh://example.invalid/x"; cfg core.sshCommand "$TMP/bin/evil-noop"
live lazy-fetch-ssh git show v1:a.txt
lazy; cfg remote.origin.url "ext::$TMP/bin/evil-noop"; cfg protocol.ext.allow always
live lazy-fetch-ext git show v1:a.txt
rm -f "$MARK"
( cd "$TMP/r" && git -c protocol.allow=never show v1:a.txt ) >/dev/null 2>&1 </dev/null
if [ -e "$MARK" ]; then ok "lazy-fetch-ext: protocol.allow=never alone does not stop it, as the document says"
else fail lazy-fetch-ext "protocol.allow=never alone stopped the ext fetch; the document's claim is wrong"; fi
[ "$lazy_env" = yes ] && safe lazy-fetch-ext

# safe_git_refuse: each key of a partial clone alone, a shallow clone, and a full clone.
refused() { ( cd "$TMP/r" && safe_git_refuse ) >/dev/null 2>&1; }
fresh; cfg core.repositoryformatversion 1; cfg extensions.partialClone origin
if refused; then ok "refuse: extensions.partialClone alone"; else fail refuse "extensions.partialClone alone was not refused"; fi
fresh; cfg remote.origin.url "file://$SERVER"; cfg remote.origin.promisor true
if refused; then ok "refuse: remote promisor alone"; else fail refuse "a promisor remote alone was not refused"; fi
rm -rf "$TMP/r"; git clone -q --depth 1 "file://$SERVER" "$TMP/r" 2>/dev/null
if refused; then ok "refuse: a shallow clone"; else fail refuse "a shallow clone was not refused"; fi
fresh
if refused; then fail refuse "a full clone was refused"; else ok "refuse: a full clone is not refused"; fi

# safe_git_partial gates the head revision query: a partial clone stops it, a shallow
# clone does not, because rev-parse HEAD reads one ref and no history.
partial() { ( cd "$TMP/r" && safe_git_partial ) >/dev/null 2>&1; }
rm -rf "$TMP/r"; git clone -q --depth 1 "file://$SERVER" "$TMP/r" 2>/dev/null
if partial; then fail head "a shallow clone was taken for a partial one"
elif [ "$( cd "$TMP/r" && safe_git rev-parse HEAD )" = "$(git -C "$TMP/r" rev-parse HEAD)" ] &&
  [ -e "$TMP/r/.git/shallow" ]; then ok "head: rev-parse HEAD runs in a shallow clone"
else fail head "rev-parse HEAD did not print the head of a shallow clone"; fi
fresh; cfg core.repositoryformatversion 1; cfg extensions.partialClone origin
if partial; then ok "head: extensions.partialClone alone stops the head query"; else fail head "extensions.partialClone alone did not stop the head query"; fi
fresh; cfg remote.origin.url "file://$SERVER"; cfg remote.origin.promisor true
if partial; then ok "head: remote promisor alone stops the head query"; else fail head "a promisor remote alone did not stop the head query"; fi
fresh
if partial; then fail head "a full clone stopped the head query"; else ok "head: a full clone does not stop the head query"; fi

# Replace refs: the workspace makes HEAD read as a commit with the base tree.
fresh
fake="$(git -C "$TMP/r" commit-tree -p v1 -m fake "$(git -C "$TMP/r" rev-parse 'v1^{tree}')")"
git -C "$TMP/r" replace HEAD "$fake"
if [ -z "$(git -C "$TMP/r" diff v1...HEAD)" ]; then ok "replace refs: live, the plain diff hides the change"
else fail "replace refs" "the plain diff still showed the change, so the vector is not shown live"; fi
if ( cd "$TMP/r" && safe_git diff --no-ext-diff --no-textconv v1...HEAD ) 2>/dev/null | grep '^+two$' > /dev/null; then
  ok "replace refs: safe_git shows the real change"
else fail "replace refs" "safe_git diff did not show the real change"; fi

# Grafts: the workspace gives HEAD an unrelated parent.
fresh
orphan="$(git -C "$TMP/r" commit-tree -m orphan "$(git -C "$TMP/r" rev-parse 'v1^{tree}')")"
printf '%s %s\n' "$(git -C "$TMP/r" rev-parse HEAD)" "$orphan" > "$TMP/r/.git/info/grafts"
if git -C "$TMP/r" merge-base --is-ancestor "$orphan" HEAD 2>/dev/null; then ok "grafts: live, the plain query takes the graft"
else fail grafts "the plain query ignored the graft, so the vector is not shown live"; fi
if ( cd "$TMP/r" && safe_git merge-base --is-ancestor "$orphan" HEAD ) 2>/dev/null; then
  fail grafts "safe_git took the graft"
else ok "grafts: safe_git ignores the graft"; fi

# filter.<driver>.clean: why git status is banned. The form does not stop it.
fresh; attr '* filter=f'; cfg filter.f.clean "$TMP/bin/evil-stdin"
touch -t 200001010000 "$TMP/r/a.txt"
rm -f "$MARK"
( cd "$TMP/r" && safe_git status ) >/dev/null 2>&1 </dev/null
if [ -e "$MARK" ]; then ok "clean filter: git status runs it even through safe_git, so status stays banned"
else fail "clean filter" "safe_git status did not run the clean filter; the ban's reason no longer holds"; fi
safe clean-filter

# Self-check: a weakened form must be caught, so the checks above can fail.
mutant() { active="$(printf '%s\n' "$form" | sed "$1")"; eval "$active"; }
if [ "$lazy_env" = yes ]; then
  lazy; cfg remote.origin.url "ext::$TMP/bin/evil-noop"; cfg protocol.ext.allow always
  mutant 's/GIT_NO_LAZY_FETCH=1 //'
  rm -f "$MARK"; table "$TMP/r"
  if [ -e "$MARK" ]; then ok "self-check: the form without GIT_NO_LAZY_FETCH is caught"
  else fail self-check "the form without GIT_NO_LAZY_FETCH was not caught"; fi
else
  skip self-check-lazy "needs GIT_NO_LAZY_FETCH (git 2.44)"
fi
if command -v script >/dev/null 2>&1; then
  fresh; cfg core.pager "$TMP/bin/evil-stdin"; cfg pager.log "$TMP/bin/evil-stdin"
  mutant 's/GIT_PAGER=cat//; s/--no-pager //'
  rm -f "$MARK"; write_table
  ( cd "$TMP/r" && in_pty bash "$TMP/table.sh" "$TMP/r" ) >/dev/null 2>&1 </dev/null
  if [ -e "$MARK" ]; then ok "self-check: the form without the pager overrides is caught"
  else fail self-check "the form without the pager overrides was not caught"; fi
else
  skip self-check-pager "no script(1) to give git a terminal"
fi
fresh; mutant 's/GIT_NO_REPLACE_OBJECTS=1 //'
fake="$(git -C "$TMP/r" commit-tree -p v1 -m fake "$(git -C "$TMP/r" rev-parse 'v1^{tree}')")"
git -C "$TMP/r" replace HEAD "$fake"
if ( cd "$TMP/r" && safe_git diff --no-ext-diff --no-textconv v1...HEAD ) 2>/dev/null | grep '^+two$' > /dev/null; then
  fail self-check "the form without GIT_NO_REPLACE_OBJECTS was not caught"
else ok "self-check: the form without GIT_NO_REPLACE_OBJECTS is caught"; fi
fresh; mutant 's/ ||$//; /git-path shallow/d'
rm -rf "$TMP/r"; git clone -q --depth 1 "file://$SERVER" "$TMP/r" 2>/dev/null
if refused; then fail self-check "the refusal without the shallow test was not caught"
else ok "self-check: the refusal without the shallow test is caught"; fi
active="$form"; eval "$form"

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
