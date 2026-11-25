#!/bin/bash
# Self-check for references/vendored-policy.sh, policy-hcl.pl and vendored-policy.jq of
# terraform-module-pr-review: a vendored policy document compared with its upstream file at a
# release tag resolved to a commit, and with the base. gh is a stub that serves fixture files and
# logs each request. The handover grammar, the equal documents and the LOW raise are taken from
# review-run.sh. A negative self-check mutates temp copies and confirms each one is caught.
# No network. Needs bash, git, jq and perl.
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
REF="$SRC/.agents/skills/terraform-module-pr-review/references"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/vendored-policy-test.XXXXXX")" && pwd -P)" && [ -n "$TMP" ] || { echo "FAIL no temporary directory"; exit 1; }
[ -n "${KEEP:-}" ] || trap 'rm -rf "$TMP"' EXIT
fails=0
VP="$REF/vendored-policy.sh" # the script under test; the self-check swaps in mutated copies
RR="$REF/review-run.sh"
check() { if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
export GIT_CONFIG_NOSYSTEM=1 HOME="$TMP/home"; mkdir -p "$HOME"
G() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main -c commit.gpgsign=false "$@"; }
UP=example-org/widget-controller
REPO=example-org/terraform-aws-widget
C1=1111111111111111111111111111111111111111
C2=2222222222222222222222222222222222222222
C0=0000000000000000000000000000000000000000
AT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

# --- The gh stub: each endpoint is a file of $FIX, named by the endpoint with / and ? as _.
mkdir -p "$TMP/bin" "$TMP/fix"
FIX="$TMP/fix"; export FIX GHLOG="$TMP/gh.log"
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/bash
[ "$1" = api ] || exit 9
printf '%s\n' "$2" >> "$GHLOG"
f="$FIX/$(printf '%s' "$2" | tr '/?=' '___')"
[ -f "$f" ] || { echo '{"message": "Not Found"}'; exit 1; }
cat "$f"
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
serve() { printf '%s' "$2" > "$FIX/$(printf '%s' "$1" | tr '/?=' '___')"; }
# up_file <commit> <json>: the upstream file at that commit.
up_file() {
  serve "repos/$UP/contents/docs/iam_policy.json?ref=$1" \
    "$(jq -n --arg c "$(printf '%s' "$2" | base64 | tr -d '\n')" '{type: "file", path: "docs/iam_policy.json", encoding: "base64", size: 100, content: $c}')"
}
serve "repos/$UP/git/ref/tags/v2.0.0" "{\"ref\": \"refs/tags/v2.0.0\", \"object\": {\"type\": \"commit\", \"sha\": \"$C2\"}}"
serve "repos/$UP/git/ref/tags/v1.0.0" "{\"ref\": \"refs/tags/v1.0.0\", \"object\": {\"type\": \"commit\", \"sha\": \"$C1\"}}"
# An annotated tag: the ref names a tag object, which names the commit.
serve "repos/$UP/git/ref/tags/v3.0.0" "{\"ref\": \"refs/tags/v3.0.0\", \"object\": {\"type\": \"tag\", \"sha\": \"$AT\"}}"
serve "repos/$UP/git/tags/$AT" "{\"object\": {\"type\": \"commit\", \"sha\": \"$C0\"}}"
UPJ='{"Version": "2012-10-17", "Statement": [
  {"Effect": "Allow", "Action": ["ec2:DescribeVolumes", "ec2:ValidateThing"], "Resource": "*"},
  {"Effect": "Allow", "Action": "ec2:AttachVolume", "Resource": ["arn:aws:ec2:*:*:volume/*", "arn:aws:ec2:*:*:instance/*"]},
  {"Effect": "Allow", "Action": "ec2:CreateTags", "Resource": "arn:aws:ec2:*:*:volume/*",
   "Condition": {"StringEquals": {"ec2:CreateAction": ["CreateVolume", "CreateSnapshot"]}, "Null": {"aws:RequestTag/x": "false"}}}]}'
up_file "$C2" "$UPJ"
up_file "$C0" "$UPJ"
up_file "$C1" '{"Statement": [{"Effect": "Allow", "Action": ["ec2:DescribeVolumes"], "Resource": "*"}]}'

# --- The profile.
P="$TMP/profile"; mkdir "$P"
cat > "$P/vendored-policies.txt" <<EOF
# a comment
entry $REPO policies.tf widget $UP docs/iam_policy.json
entry $REPO policies.tf other $UP docs/iam_policy.json
entry example-org/terraform-aws-elsewhere policies.tf widget $UP docs/iam_policy.json

subst local.partition aws
subst data.aws_service_principal.ec2[0].name ec2.amazonaws.com
EOF

# The head block, as the upstream file at v2.0.0, written the way a module writes it.
HEAD_TF='# https://github.com/example-org/widget-controller/blob/main/docs/iam_policy.json
data "aws_iam_policy_document" "widget" {
  count = var.create ? 1 : 0

  source_policy_documents = [data.aws_iam_policy_document.base[0].json] # merged: not compared

  statement {
    # a comment with "quotes" and a brace }
    actions = [
      "ec2:DescribeVolumes",
      "ec2:ValidateThing", /* a block comment } */
    ]
    resources = ["*"]
  }

  statement {
    sid     = "Attach"
    actions = ["EC2:AttachVolume"]
    resources = [
      "arn:${local.partition}:ec2:*:*:instance/*",
      "arn:${local.partition}:ec2:*:*:volume/*",
    ]
  }

  statement {
    actions   = ["ec2:CreateTags"]
    resources = ["arn:${local.partition}:ec2:*:*:volume/*"]

    condition {
      test     = "Null"
      variable = "aws:RequestTag/x"
      values   = [false]
    }
    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["CreateSnapshot", "CreateVolume"]
    }
  }

  dynamic "statement" {
    for_each = var.kms_arns
    content {
      actions   = ["kms:Decrypt"]
      resources = [statement.value]
    }
  }
}

data "aws_iam_policy_document" "other" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["*"]
  }
}
'
# The base: the action ValidateThing missing, AttachVolume on "*".
BASE_TF="$(printf '%s' "$HEAD_TF" | perl -0pe 's/      "ec2:ValidateThing", \/\* a block comment \} \*\/\n//; s/resources = \[\n      "arn:\$\{local.partition\}:ec2:\*:\*:instance\/\*",\n      "arn:\$\{local.partition\}:ec2:\*:\*:volume\/\*",\n    \]/resources = ["*"]/')"

# repo <name> <base text or -> <head text>: a clone with a base commit and a head commit; prints
# "<clone> <base sha> <head sha>".
repo() {
  local c="$TMP/$1"; G init -q "$c"
  if [ "$2" != - ]; then printf '%s\n' "$2" > "$c/policies.tf"; else printf 'x\n' > "$c/other.tf"; fi
  G -C "$c" add -A; G -C "$c" commit -qm base; local b; b="$(git -C "$c" rev-parse HEAD)"
  printf '%s\n' "$3" > "$c/policies.tf"; G -C "$c" add -A; G -C "$c" commit -qm head
  echo "$c $b $(git -C "$c" rev-parse HEAD)"
}
FILES="$TMP/files.json"; echo '[{"filename": "policies.tf", "status": "modified"}]' > "$FILES"
BODY="$TMP/body.txt"; printf 'Syncs with https://github.com/%s/releases/tag/v2.0.0 $(touch %s/pwned)\n' "$UP" "$TMP" > "$BODY"
# vp <clone> <base> <head> [args...]: run the script, print its output file.
vp() {
  local c="$1" b="$2" h="$3" o; shift 3; o="$(mktemp -d "$TMP/out.XXXXXX")"
  local ba=(); [ -z "$b" ] || ba=(--base "$b")
  bash "$VP" --clone "$c" --head "$h" ${ba[@]+"${ba[@]}"} --diff "$FILES" --repo "$REPO" --body "$BODY" \
    --profile-dir "$P" --out "$o" "$@" > /dev/null 2>&1 || { echo "exit $?"; return; }
  cat "$o/vendored.txt"
}
read -r MAIN MB MH <<< "$(repo main "$BASE_TF" "$HEAD_TF")"
# The second document changes too in some cases; here only widget changed, so other gets no line.

t_equal() {
  : > "$GHLOG"; local o; o="$(vp "$MAIN" "$MB" "$MH")"
  [ "$o" = "policies.tf widget source $UP v2.0.0 $C2 docs/iam_policy.json
policies.tf widget lines 2 48
policies.tf widget upstream equal
policies.tf widget base differs 3 added 1 removed
policies.tf widget added Allow action:ec2:attachvolume resource:arn:aws:ec2:*:*:instance/*
policies.tf widget added Allow action:ec2:attachvolume resource:arn:aws:ec2:*:*:volume/*
policies.tf widget added Allow action:ec2:validatething resource:*
policies.tf widget removed Allow action:ec2:attachvolume resource:*
policies.tf widget not compared 1 dynamic statements
policies.tf widget not compared merged documents" ] &&
  # the file is read at the commit the tag resolved to, never at the tag
  [ "$(cat "$GHLOG")" = "repos/$UP/git/ref/tags/v2.0.0
repos/$UP/contents/docs/iam_policy.json?ref=$C2" ] && [ ! -e "$TMP/pwned" ]
}
t_equal; check "equal: case, order, comments, conditions and substitutions normalize; two diffs; fetched by commit SHA" $?

t_grammar() { # every line the script writes is in the handover's grammar, taken from review-run.sh
  local re; re="$(sed -n "s/^VP_LINE_RE='\(.*\)'$/\1/p" "$RR")"
  [ -n "$re" ] && vp "$MAIN" "$MB" "$MH" | grep -qvE "$re" && return 1
  [ -n "$re" ] && printf 'policies.tf widget extra Allow action:x:y resource:* condition:Bool:a=b\n' | grep -qE "$re" &&
    ! printf 'policies.tf widget upstream equal; rm -rf x\n' | grep -qE "$re"
}
t_grammar; check "grammar: review-run.sh's VP_LINE_RE takes every line and no other" $?

t_extra() {
  local h; h="$(printf '%s' "$HEAD_TF" | sed 's/"ec2:DescribeVolumes",/"ec2:DescribeVolumes", "ec2:DeleteEverything",/')"
  read -r c b hh <<< "$(repo extra "$BASE_TF" "$h")"
  vp "$c" "$b" "$hh" | grep -qxF 'policies.tf widget upstream differs 1 extra 0 missing' &&
    vp "$c" "$b" "$hh" | grep -qxF 'policies.tf widget extra Allow action:ec2:deleteeverything resource:*'
}
t_extra; check "extra: an action upstream lacks is named" $?

t_missing_cond() { # a condition the head drops: a tuple widened, missing from upstream's view
  local h; h="$(printf '%s' "$HEAD_TF" | perl -0pe 's/    condition \{\n      test     = "Null"\n      variable = "aws:RequestTag\/x"\n      values   = \[false\]\n    \}\n//')"
  read -r c b hh <<< "$(repo cond "$BASE_TF" "$h")"
  local o; o="$(vp "$c" "$b" "$hh")"
  grep -qxF 'policies.tf widget upstream differs 1 extra 1 missing' <<< "$o" &&
    grep -qxF 'policies.tf widget extra Allow action:ec2:createtags resource:arn:aws:ec2:*:*:volume/* condition:StringEquals:ec2:createaction=CreateSnapshot,CreateVolume' <<< "$o"
}
t_missing_cond; check "condition: a dropped condition is a differing tuple" $?

t_annotated() {
  printf 'See https://github.com/%s/tree/v3.0.0/docs\n' "$UP" > "$BODY"; : > "$GHLOG"
  local o; o="$(vp "$MAIN" "$MB" "$MH")"
  printf 'Syncs with https://github.com/%s/releases/tag/v2.0.0\n' "$UP" > "$BODY"
  grep -qxF "policies.tf widget source $UP v3.0.0 $C0 docs/iam_policy.json" <<< "$o" &&
    grep -qxF "repos/$UP/contents/docs/iam_policy.json?ref=$C0" "$GHLOG"
}
t_annotated; check "annotated tag: resolved through its tag object to the commit" $?

t_tags() {
  local ok=0
  printf 'no tag here, only https://github.com/%s/blob/main/x and https://github.com/other/repo/releases/tag/v9.0.0\n' "$UP" > "$BODY"
  [ "$(vp "$MAIN" "$MB" "$MH")" = "policies.tf widget unknown no tag" ] || ok=1
  printf 'https://github.com/%s/releases/tag/v2.0.0 and https://github.com/%s/releases/tag/v1.0.0\n' "$UP" "$UP" > "$BODY"
  [ "$(vp "$MAIN" "$MB" "$MH")" = "policies.tf widget unknown tag ambiguous" ] || ok=1
  printf 'https://github.com/%s/releases/tag/v4.0.0\n' "$UP" > "$BODY"
  [ "$(vp "$MAIN" "$MB" "$MH")" = "policies.tf widget unknown tag not found" ] || ok=1
  printf 'Syncs with https://github.com/%s/releases/tag/v2.0.0\n' "$UP" > "$BODY"
  return "$ok"
}
t_tags; check "tags: none, two, or one not found give no evidence, and no latest" $?

t_older() { # the base names v2.0.0; a change to v1.0.0 goes back
  local b h; b="$(printf '%s' "$BASE_TF" | sed "s#blob/main#blob/v2.0.0#")"; h="$(printf '%s' "$HEAD_TF" | sed "s#blob/main#blob/v1.0.0#")"
  read -r c bb hh <<< "$(repo older "$b" "$h")"
  printf 'nothing\n' > "$BODY"; local o; o="$(vp "$c" "$bb" "$hh")"
  printf 'Syncs with https://github.com/%s/releases/tag/v2.0.0\n' "$UP" > "$BODY"
  [ "$o" = "policies.tf widget unknown tag older" ]
}
t_older; check "older: a tag older than the base's is refused" $?

t_static() { # each shape the reader cannot evaluate: no evidence for the whole document
  local ok=0 h x k=0
  for x in 's/resources = \["\*"\]/resources = var.arns/:unevaluated expression' \
           's/"ec2:DescribeVolumes",/"ec2:DescribeVolumes", lower("X"),/:unevaluated expression' \
           's/resources = \["\*"\]/resources = ["\${var.x}"]/:unevaluated expression' \
           's/    condition \{\n      test     = "Null"/    dynamic "condition" {\n      test     = "Null"/:dynamic block' \
           's/resources = \["\*"\]/resources = [<<EOT\nx\nEOT\n]/:heredoc' \
           's/sid     = "Attach"/sid = "%{ if true }a%{ endif }"/:template directive'; do
    h="$(printf '%s' "$HEAD_TF" | perl -0pe "${x%:*}")"
    k=$((k + 1)); read -r c b hh <<< "$(repo "static$k" "$BASE_TF" "$h")"
    [ "$(vp "$c" "$b" "$hh")" = "policies.tf widget unknown ${x##*:}" ] || { echo "  static: ${x%:*} gave $(vp "$c" "$b" "$hh")" >&2; ok=1; }
  done
  return "$ok"
}
t_static; check "static: a variable, a function, an interpolation, a dynamic condition, a heredoc, a directive" $?

t_dynamic_changed() {
  local h; h="$(printf '%s' "$HEAD_TF" | sed 's/kms:Decrypt/kms:Encrypt/')"
  read -r c b hh <<< "$(repo dyn "$BASE_TF" "$h")"
  [ "$(vp "$c" "$b" "$hh")" = "policies.tf widget unknown dynamic statements changed" ]
}
t_dynamic_changed; check "dynamic: a changed dynamic statement gives no evidence" $?

t_scope() {
  local ok=0 o
  # a block the change leaves as it was gets no line: only other changes
  read -r c b hh <<< "$(repo same "$HEAD_TF" "$(printf '%s\n# trailing' "$HEAD_TF")")"
  [ -z "$(vp "$c" "$b" "$hh")" ] || ok=1
  # a file the change does not touch gets no line
  echo '[{"filename": "main.tf", "status": "modified"}]' > "$FILES"
  [ -z "$(vp "$MAIN" "$MB" "$MH")" ] || ok=1
  echo '[{"filename": "policies.tf", "status": "added"}]' > "$FILES"
  # a new file: base absent
  read -r c b hh <<< "$(repo new - "$HEAD_TF")"
  o="$(vp "$c" "$b" "$hh")"; grep -qxF 'policies.tf widget base absent' <<< "$o" || ok=1
  echo '[{"filename": "policies.tf", "status": "modified"}]' > "$FILES"
  return "$ok"
}
t_scope; check "scope: an unchanged block, an untouched file, a new file" $?

t_profile() {
  local ok=0 o
  cp "$P/vendored-policies.txt" "$TMP/vp.keep"
  printf 'entry %s policies.tf widget %s docs/iam_policy.json extra\n' "$REPO" "$UP" >> "$P/vendored-policies.txt"
  [ -z "$(vp "$MAIN" "$MB" "$MH")" ] || ok=1
  cp "$TMP/vp.keep" "$P/vendored-policies.txt"; printf 'subst var.x $(touch pwned)\n' >> "$P/vendored-policies.txt"
  [ -z "$(vp "$MAIN" "$MB" "$MH")" ] || ok=1
  mv "$P/vendored-policies.txt" "$TMP/real.txt"; ln -s "$TMP/real.txt" "$P/vendored-policies.txt"
  [ -z "$(vp "$MAIN" "$MB" "$MH")" ] || ok=1
  rm "$P/vendored-policies.txt"; cp "$TMP/vp.keep" "$P/vendored-policies.txt"
  # an entry of another repository only
  sed -i.bak "/^entry $(printf '%s' "$REPO" | sed 's#/#\\/#') /d" "$P/vendored-policies.txt"
  [ -z "$(vp "$MAIN" "$MB" "$MH")" ] || ok=1
  cp "$TMP/vp.keep" "$P/vendored-policies.txt"
  return "$ok"
}
t_profile; check "profile: a line outside the grammar, a link, another repository's entry give nothing" $?

t_fetch() {
  local ok=0
  up_file "$C2" 'not json'
  [ "$(vp "$MAIN" "$MB" "$MH")" = "policies.tf widget unknown upstream unreadable" ] || ok=1
  up_file "$C2" '{"Statement": [{"Effect": "Allow", "Action": "a:b", "Resource": "*", "Extra": 1}]}'
  [ "$(vp "$MAIN" "$MB" "$MH")" = "policies.tf widget unknown unsupported attribute" ] || ok=1
  serve "repos/$UP/contents/docs/iam_policy.json?ref=$C2" '{"type": "dir", "path": "docs/iam_policy.json"}'
  [ "$(vp "$MAIN" "$MB" "$MH")" = "policies.tf widget unknown fetch failed" ] || ok=1
  up_file "$C2" "$UPJ"
  return "$ok"
}
t_fetch; check "fetch: an unreadable or unexpected upstream file gives no evidence" $?

t_partial() {
  G -C "$MAIN" config extensions.partialClone origin
  local o; o="$(vp "$MAIN" "$MB" "$MH")"; G -C "$MAIN" config --unset extensions.partialClone
  # every listed document of a touched file: the clone cannot tell which one changed
  [ "$o" = "policies.tf widget unknown partial clone
policies.tf other unknown partial clone" ]
}
t_partial; check "partial clone: no evidence" $?

t_prefix() {
  local c="$TMP/pfx"; G init -q "$c"; mkdir -p "$c/modules/w"
  printf '%s\n' "$BASE_TF" > "$c/modules/w/policies.tf"; G -C "$c" add -A; G -C "$c" commit -qm b; local b; b="$(git -C "$c" rev-parse HEAD)"
  printf '%s\n' "$HEAD_TF" > "$c/modules/w/policies.tf"; G -C "$c" commit -qam h
  sed -i.bak "s# policies.tf widget # modules/w/policies.tf widget #" "$P/vendored-policies.txt"
  echo '[{"filename": "modules/w/policies.tf", "status": "modified"}]' > "$FILES"
  local o; o="$(vp "$c" "$b" "$(git -C "$c" rev-parse HEAD)" --prefix modules/w)"
  cp "$TMP/vp.keep" "$P/vendored-policies.txt"; echo '[{"filename": "policies.tf", "status": "modified"}]' > "$FILES"
  grep -qxF 'policies.tf widget upstream equal' <<< "$o"
}
t_prefix; check "prefix: the entry is repository-relative, the line module-relative" $?

# --- review-run.sh: the equal documents and the LOW raise, taken from the script.
fn() { awk -v f="$1() {" '$0 == f { p = 1 } p { print } p && $0 == "}" { exit }' "$RR"; }
t_raise() {
  local d; d="$(mktemp -d "$TMP/rr.XXXXXX")"; mkdir -p "$d/vendored" "$d/state"
  { sed -n "/^VP_LINE_RE=/p" "$RR"; fn vendored_ok; fn vendored_equal; fn vendored_raise; } > "$d/lib.sh"
  vp "$MAIN" "$MB" "$MH" > "$d/vendored/vendored.txt"
  RUN="$d" TRIAGE=false bash -c '. "$RUN/lib.sh"; vendored_equal' > "$d/eq.json"
  local f='[{"rule_id": "compat.generated-policy-narrowed", "severity": "LOW", "file": "policies.tf", "line": 20},
    {"rule_id": "compat.generated-policy-narrowed", "severity": "LOW", "file": "policies.tf", "line": 52},
    {"rule_id": "compat.generated-policy-narrowed", "severity": "LOW", "file": "main.tf", "line": 20},
    {"rule_id": "compat.generated-policy-narrowed", "severity": "LOW", "file": "policies.tf", "line": null},
    {"rule_id": "compat.generated-policy-narrowed", "severity": "MEDIUM", "file": "x.tf", "line": 1},
    {"rule_id": "compat.default-changed", "severity": "LOW", "file": "x.tf", "line": 1}]'
  local got; got="$(RUN="$d" bash -c '. "$RUN/lib.sh"; vendored_raise "$RUN/eq.json"' <<< "$f" | jq -c 'map(.severity)')"
  [ "$(jq -c . "$d/eq.json")" = '[{"file":"policies.tf","first":2,"last":48}]' ] &&
    [ "$got" = '["LOW","HIGH","HIGH","HIGH","MEDIUM","LOW"]' ] || return 1
  # a line outside the grammar: no line stated, nothing equal, every LOW raised
  printf 'policies.tf widget upstream equal; x\n' >> "$d/vendored/vendored.txt"
  [ "$(RUN="$d" TRIAGE=false bash -c '. "$RUN/lib.sh"; vendored_equal' | jq -c .)" = '[]' ] || return 1
  # a document that differs from upstream is never equal
  vp "$MAIN" "$MB" "$MH" | sed 's/upstream equal/upstream differs 1 extra 0 missing/' > "$d/vendored/vendored.txt"
  [ "$(RUN="$d" TRIAGE=false bash -c '. "$RUN/lib.sh"; vendored_equal' | jq -c .)" = '[]' ]
}
t_raise; check "render: LOW stands only inside an equal document's lines, any other LOW is HIGH" $?

t_handover() { # handover runs the step and states the lines before the untrusted block
  grep -qF 'rm -rf "$RUN/vendored"; [ "$TRIAGE" = true ] || [ "$nm" = true ] || vendored_policy "$t" "$s" "$mbl"' "$RR" &&
    grep -qF "! vendored_ok || sed 's/^/Vendored policy: /' \"\$RUN/vendored/vendored.txt\"" "$RR" &&
    grep -qF 'vendored_raise "$RUN/state/vendored-equal.json" < "$findings"' "$RR" &&
    [ "$(grep -n 'Vendored policy: ' "$RR" | cut -d: -f1)" -lt "$(grep -n 'sed -n "$n,\\$p" "$t"' "$RR" | cut -d: -f1)" ]
}
t_handover; check "handover: the step runs outside a triage run and its lines precede the block" $?

# --- Negative self-check: each mutation of a temp copy must make its named case fail.
oc=0
mutate() { # name, perl substitution, file, case function
  local d="$TMP/mut-$oc"; oc=$((oc + 1)); mkdir -p "$d"
  cp "$REF/vendored-policy.sh" "$REF/policy-hcl.pl" "$REF/vendored-policy.jq" "$RR" "$d/"
  perl -0pi -e "$2" "$d/$3"
  if cmp -s "$d/$3" "$REF/$3"; then check "self-check: $1 (the mutation changed nothing)" 1; return; fi
  local kv="$VP" kr="$RR" before="$fails"; VP="$d/vendored-policy.sh"; RR="$d/review-run.sh"
  "$4" > /dev/null 2>&1; local s=$?
  VP="$kv"; RR="$kr"; fails="$before"
  check "self-check: $1 is caught" "$([ "$s" != 0 ]; echo $?)"
}
mutate "the file fetched at the tag" 's/\?ref=\$sha"/?ref=\$t"/' vendored-policy.sh t_equal
mutate "action names compared as written" 's/map\(ascii_downcase\)/map(.)/g' vendored-policy.jq t_equal
mutate "a dynamic condition read as static" 's/unknown\(\$k eq .block. && \$id eq .dynamic. \? "dynamic block" : "unsupported attribute"\);/1;/; s/unknown\(\$cid eq .dynamic. \? "dynamic block" : "unsupported attribute"\)/1/; s/unknown\("dynamic block"\) if \$id eq .dynamic.;//' policy-hcl.pl t_static
mutate "a function read as a literal" 's/  unknown\("unevaluated expression"\);\n\}\nsub list/  return \$v;\n}\nsub list/' policy-hcl.pl t_static
mutate "the older tag accepted" 's/if \[ -n "\$bt" \] && older "\$t" "\$bt"; then/if false; then/' vendored-policy.sh t_older
mutate "two tags take the first" 's/\[ "\$\(wc -l <<< "\$t" \| tr -d . .\)" = 1 \] \|\|/t="\$(head -n 1 <<< "\$t")"; true ||/' vendored-policy.sh t_tags
mutate "a profile line outside the grammar skipped" 's/  else finish\n  fi\ndone < "\$SRC"/  fi\ndone < "\$SRC"/' vendored-policy.sh t_profile
mutate "a changed dynamic statement compared" 's/\.\[0\]\.dynamic == \.\[1\]\.dynamic/true/' vendored-policy.sh t_dynamic_changed
mutate "an unchanged block compared" 's/ > \/dev\/null 2>&1 && continue/ > \/dev\/null 2>\&1 \&\& true/' vendored-policy.sh t_scope
mutate "the partial clone read" 's/if \[ "\$partial" = true \]; then line "unknown partial clone"; continue; fi//' vendored-policy.sh t_partial
mutate "the LOW raise dropped" 's/then \.severity = "HIGH" else \. end/then . else . end/' review-run.sh t_raise
mutate "equal at any line of the file" 's/ and \(\$l \| type == "number"\) and \.first <= \$l and \$l <= \.last//' review-run.sh t_raise
mutate "a differing document read as equal" 's/select\(any\(\.\[\]; \.fact == \["upstream", "equal"\]\)\)/select(true)/' review-run.sh t_raise
mutate "the grammar takes a line with a tail" "s/\\{1,60\\}\\)\\\$'\\n# The review budget/{1,60})'\\n# The review budget/" review-run.sh t_grammar

echo
if [ "$fails" -eq 0 ]; then echo "vendored-policy: all checks hold"; else echo "vendored-policy: $fails failed"; exit 1; fi
