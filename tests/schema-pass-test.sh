#!/bin/bash
# Self-check for the schema pass of terraform-module-pr-review (references/schema-pass.sh
# and schema-facts.jq), focused mode first: the tokens from depth.json, the versions per
# touched type (latest, declared minimum, head lock file) deduplicated, the caps and the
# overflow code, the trusted mirror, each escalate reason, nothing downloaded run, and a
# negative self-check that mutates temp copies of the script. curl is stubbed: no network.
# Needs bash, jq, gzip, awk and GNU coreutils and findutils (g-prefixed on macOS).
# Run: tests/schema-pass-test.sh
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
REF="$SRC/.agents/skills/terraform-module-pr-review/references"
SP="$REF/schema-pass.sh" # the script under test; the self-check swaps in mutated copies
DOC="$REF/schema-pass.md"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/schema-pass-test.XXXXXX")" && pwd -P)" && [ -n "$TMP" ] || { echo "FAIL no temporary directory"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
fails=0

check() { # name, command status (0 = holds)
  if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

# GNU tools first where the host has them under a g prefix (macOS with coreutils).
mkdir -p "$TMP/bin"
for t in find sha256sum sort head base64 wc cut uniq sed awk; do
  g="$(command -v "g$t" 2> /dev/null)" && ln -sf "$g" "$TMP/bin/$t"
done
# A terraform that marks any call: the pass must never run it, nor anything downloaded.
printf '#!/bin/sh\ntouch "%s/ran-terraform"\n' "$TMP" > "$TMP/bin/terraform"
chmod +x "$TMP/bin/terraform"

# The curl stub: the registry answers from $SITE/registry; a download from the trusted
# mirror redirects once to the asset host, which answers from $SITE/mirror. A file named
# REDIRECT beside an asset makes the asset host redirect to the URL it holds instead.
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/bash
out="" hdr="" cap="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -D) hdr="$2"; shift 2 ;;
    --max-filesize) cap="$2"; shift 2 ;;
    -w | --proto | --connect-timeout | --max-time | --max-redirs) shift 2 ;;
    -s | --tlsv1.2) shift ;;
    --) url="$2"; shift 2 ;;
    *) echo "OPTION $1" >> "$STUB_LOG"; shift ;;
  esac
done
echo "URL $url" >> "$STUB_LOG"
reply() { # code, body file or -, location
  printf 'HTTP/1.1 %s X\r\n' "$1" > "$hdr"
  [ -z "${3:-}" ] || printf 'Location: %s\r\n' "$3" >> "$hdr"
  if [ "$2" != - ]; then
    if [ -n "$cap" ] && [ "$(wc -c < "$2")" -gt "$cap" ]; then exit 63; fi
    cp "$2" "$out"
  else
    echo "redirect body" > "$out"
  fi
  printf '%s' "$1"
}
M=https://github.com/modulestf/terraform-schema-mirror/releases/download/
case "$url" in
  https://registry.terraform.io/v1/providers/*/*/versions)
    p="${url#https://registry.terraform.io/v1/providers/}"; p="${p%/versions}"; f="$SITE/registry/${p/\//_}.json"
    if [ -f "$f" ]; then reply 200 "$f"; else reply 404 /dev/null; fi ;;
  "$M"*) reply 302 - "https://release-assets.githubusercontent.com/a/${url#"$M"}?sig=1" ;;
  https://release-assets.githubusercontent.com/a/*)
    p="${url#https://release-assets.githubusercontent.com/a/}"; p="${p%%\?*}"
    if [ -f "$SITE/mirror/${p%/*}/REDIRECT" ]; then reply 302 - "$(cat "$SITE/mirror/${p%/*}/REDIRECT")"
    elif [ -f "$SITE/mirror/$p" ]; then reply 200 "$SITE/mirror/$p"
    else reply 404 /dev/null; fi ;;
  *) reply 404 /dev/null ;;
esac
EOF
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"
export SITE="$TMP/site" STUB_LOG=/dev/null
mkdir -p "$SITE/registry" "$SITE/mirror"

# A schema of the provider example/demo: small types, one malformed, one large, a data
# source, and a description that would run a command if anything ever evaluated it.
small='{"block": {"attributes": {"id": {"type": "string", "computed": true}, "name": {"type": "string", "required": true}},
  "block_types": {"rule": {"nesting_mode": "list", "max_items": 2, "block": {"attributes": {"x": {"type": "number", "optional": true}}}}}}}'
jq -n --argjson s "$small" --arg mark "$TMP/ran-description" '{format_version: "1.0", provider_schemas: {"registry.terraform.io/example/demo": {
  resource_schemas: {
    demo_thing: ($s | .block.attributes.name.description = "$(touch \($mark)) `touch \($mark)`"),
    demo_a: $s, demo_b: $s, demo_c: $s,
    demo_broken: {block: {attributes: {x: {type: "string", optional: "yes"}}}},
    demo_big: {block: {attributes: ([range(1100)] | map({key: "attribute_number_\(.)", value: {type: "string", optional: true}}) | from_entries)}}},
  data_source_schemas: {demo_lookup: $s}}}}' > "$TMP/demo.schema.json"
release() { # version
  local d="$SITE/mirror/example_demo-v$1" f="example_demo-$1.schema.json.gz"
  mkdir -p "$d"
  jq -c . "$TMP/demo.schema.json" | gzip -n > "$d/$f"
  jq -n -c --arg v "$1" --arg f "$f" '{provider: "example/demo", version: $v, file: $f, format_version: "1.0"}' > "$d/manifest.json"
  (cd "$d" && sha256sum "$f" manifest.json > SHA256SUMS)
}
jq -n -c '{versions: [$ARGS.positional[] | {version: .}]}' --args 1.0.0 1.2.0 1.2.5 1.3.0 2.0.0-beta > "$SITE/registry/example_demo.json"
for v in 1.0.0 1.2.0 1.2.5 1.3.0; do release "$v"; done

mk() { # touched types, provider tokens, type tokens, lock tokens -> depth.json text
  jq -n -c --arg x "$1" --arg p "$2" --arg t "$3" --arg l "$4" 'def w($s): $s | split(" ") | map(select(. != ""));
    {format: 1, depth: "focused", touched_types: w($x), schema_providers: w($p), schema_types: w($t), schema_locks: w($l)}'
}
PROV="head:.:demo=example/demo:>=1.2"
TOK=".:resource:demo_thing:example/demo .:resource:demo_a:example/demo .:data:demo_lookup:example/demo"
run() { # name; env D (depth.json text), DP (its path instead), MIRROR, SPX (another script)
  R="$TMP/run-$1"
  mkdir -p "$R.d" && printf '%s\n' "${D:-}" > "$R.d/depth.json"
  if [ -n "${MIRROR+x}" ]; then export MODULESTF_SCHEMA_MIRROR="$MIRROR"; else unset MODULESTF_SCHEMA_MIRROR; fi
  STUB_LOG="$R.log" SCHEMA_DEPTH="${DP:-$R.d/depth.json}" SCHEMA_PROVIDERS="head:.:demo=example/demo:>=1.0" \
    SCHEMA_TYPES=".:resource:demo_b:example/demo" bash "${SPX:-$SP}" "$R/facts" "$R/work" > "$R.out" 2>&1
  RC=$?
  : >> "$R.log"
}
fetched() { grep -c "^URL https://github.com/modulestf/terraform-schema-mirror/releases/download/example_demo-v$1/SHA256SUMS$" "$R.log"; } # version
sheets() { (cd "$R/facts" 2> /dev/null && find . -name '*.facts' | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' '); }
esc() { # name, reason: exit 3, the one fixed line, nothing published
  [ "$RC" = 3 ] && [ "$(grep -c '^schema pass: escalate ' "$R.out")" = 1 ] && grep -qx "schema pass: escalate $2" "$R.out" && [ ! -e "$R/facts" ]
  check "escalates: $1 is $2, exit 3, nothing published" "$?"
}

# --- Versions: the latest allowed, the declared minimum and the lock version, deduplicated;
# only touched types; no old floor; the env tokens ignored.
D="$(mk demo_thing "$PROV base:.:demo=example/demo:>=1.0" "$TOK" ".:example/demo=1.2.5")" run versions
[ "$RC" = 0 ] && grep -qx 'schema pass: focused, mirror modulestf/terraform-schema-mirror, 3 sheets, [0-9]* bytes' "$R.out"
check "versions: exit 0 and the focused line" "$?"
[ "$(sheets)" = "example/demo/1.2.0/resources/demo_thing.facts example/demo/1.2.5/resources/demo_thing.facts example/demo/1.3.0/resources/demo_thing.facts " ]
check "versions: one whole sheet per touched type at the latest 1.3.0, the minimum 1.2.0 and the lock 1.2.5" "$?"
[ "$(fetched 1.0.0)" = 0 ] && ! grep -q 'example_demo-v2' "$R.log"
check "versions: no old floor from a base token, no pre-release" "$?"
[ "$(jq -c .types "$R/facts/example/demo/1.3.0/index.json")" = '{"resource:demo_thing":"sheet"}' ]
check "versions: an untouched type token and the SCHEMA_TYPES env are not rendered" "$?"
[ "$(jq -c '.directories["."]["example/demo"]' "$R/facts/versions.json")" = '{"latest":"1.3.0","minimum":"1.2.0"}' ] &&
  (cd "$R/facts" && sha256sum --strict --quiet -c files.sha256)
check "versions: versions.json and files.sha256 as in normal mode" "$?"
ver_bytes="$(sed -n 's/^schema pass: focused, .*, 3 sheets, \([0-9]*\) bytes$/\1/p' "$R.out")"
[ "$ver_bytes" = "$(cat "$R"/facts/example/demo/*/resources/*.facts | wc -c | tr -d ' ')" ]
check "versions: the byte count is the sheets' total" "$?"
src="$(sed -n 's/^schema pass: source //p' "$R.out" | LC_ALL=C sort)"
want="$(for v in 1.2.0 1.2.5 1.3.0; do printf 'modulestf/terraform-schema-mirror example_demo-v%s %s\n' "$v" \
  "$(sha256sum < "$SITE/mirror/example_demo-v$v/example_demo-$v.schema.json.gz" | cut -d ' ' -f 1)"; done)"
idx="$(for v in 1.2.0 1.2.5 1.3.0; do printf 'modulestf/terraform-schema-mirror example_demo-v%s %s\n' "$v" \
  "$(jq -r .schema_sha256 "$R/facts/example/demo/$v/index.json")"; done)"
[ -n "$src" ] && [ "$src" = "$want" ] && [ "$src" = "$idx" ]
check "provenance: one source line per version read, the mirror, the release tag and the schema file's SHA-256, as in index.json" "$?"
[ ! -e "$TMP/ran-terraform" ] && [ ! -e "$TMP/ran-description" ] && ! grep -rq 'touch' "$R/facts"
check "nothing downloaded or named in a schema is run, no description reaches a sheet" "$?"
grep -E '^OPTION' "$R.log"; [ $? = 1 ]
check "no unexpected curl option" "$?"

D="$(mk demo_thing "$PROV" "$TOK" ".:example/demo=1.3.0 examples/x:example/demo=1.3.0")" run dedupe
[ "$RC" = 0 ] && [ "$(fetched 1.3.0)" = 1 ] && [ "$(fetched 1.2.0)" = 1 ] && [ "$(grep -c "^URL https://github.com/.*/SHA256SUMS$" "$R.log")" = 2 ]
check "versions: a lock version equal to the latest is read once" "$?"
D="$(mk "demo_lookup demo_nope" "$PROV" "$TOK .:resource:demo_nope:example/demo" "")" run data-absent
[ "$RC" = 0 ] && [ "$(sheets)" = "example/demo/1.2.0/data-sources/demo_lookup.facts example/demo/1.3.0/data-sources/demo_lookup.facts " ] &&
  [ "$(jq -r '.types["resource:demo_nope"]' "$R/facts/example/demo/1.3.0/index.json")" = absent ]
check "a data source sheet; a type absent from the schema is absent, no sheet, no escalation" "$?"
D="$(mk "" "$PROV" "$TOK" "")" run none
[ "$RC" = 0 ] && grep -q ', 0 sheets, 0 bytes$' "$R.out" && [ "$(grep -c '^URL' "$R.log")" = 0 ]
check "no touched type: no download, 0 sheets, exit 0" "$?"
MIRROR=modulestf/terraform-schema-mirror D="$(mk demo_thing "$PROV" "$TOK" "")" run trusted-env
[ "$RC" = 0 ]
check "trust: MODULESTF_SCHEMA_MIRROR equal to the trusted mirror is accepted" "$?"

# --- Caps: 6 sheets and 49152 bytes; overflow never truncates.
D="$(mk "demo_thing demo_a demo_b" "$PROV" "$TOK .:resource:demo_b:example/demo" "")" run six
[ "$RC" = 0 ] && grep -q ', 6 sheets, ' "$R.out"
check "caps: 6 sheets pass" "$?"
D="$(mk "demo_thing demo_a demo_b demo_c" "$PROV" "$TOK .:resource:demo_b:example/demo .:resource:demo_c:example/demo" "")" run seven
esc "a seventh sheet" overflow
D="$(mk demo_big "head:.:demo=example/demo:=1.3.0" ".:resource:demo_big:example/demo" "")" run big-one
big="$(sed -n 's/^schema pass: focused, .*, 1 sheets, \([0-9]*\) bytes$/\1/p' "$R.out")"
[ "$RC" = 0 ] && [ -n "$big" ] && [ "$big" -le 49152 ] && [ $((big * 2)) -gt 49152 ]
check "caps: one large sheet under the byte cap passes" "$?"
D="$(mk demo_big "$PROV" ".:resource:demo_big:example/demo" "")" run big-two
esc "two large sheets over 49152 bytes" overflow

# --- Escalate reasons: each failure exits 3 with one fixed reason and publishes nothing.
D="$(mk demo_x "$PROV" "$TOK" "")" run unbound; esc "a touched type with no token" type-unbound
D="$(mk demo_thing "$PROV" "$TOK" ".:example/demo=v1.2")" run bad-lock; esc "a lock version outside x.y.z" inputs
D="$(mk demo_thing "$PROV" "$TOK" "../x:example/demo=1.2.0")" run bad-lock-dir; esc "a lock directory with .." inputs
D="$(mk demo_thing "$PROV" "../x:resource:demo_thing:example/demo" "")" run bad-type; esc "a touched type token outside its pattern" inputs
D="$(mk demo_thing "head:.:demo=Example/demo:>=1.2" "$TOK" "")" run bad-prov; esc "a provider token outside its pattern" inputs
D="$(mk 'Demo-x' "$PROV" "$TOK" "")" run bad-touched; esc "a touched type outside the type pattern" inputs
DP="$TMP/nowhere.json" run no-depth; esc "a missing depth.json" depth-input
D='not json' run not-json; esc "depth.json not JSON" depth-input
D='{"touched_types": [], "schema_providers": [], "schema_types": []}' run no-locks; esc "depth.json without schema_locks" depth-input
D='{"touched_types": ["a b"], "schema_providers": [], "schema_types": [], "schema_locks": []}' run space; esc "a token with a space" depth-input
ln -s "$TMP/run-versions.d/depth.json" "$TMP/link.json"; DP="$TMP/link.json" run link; esc "depth.json a symbolic link" depth-input
MIRROR=example/mirror D="$(mk demo_thing "$PROV" "$TOK" "")" run untrusted; esc "another mirror" mirror-untrusted
[ "$(grep -c '^URL' "$R.log")" = 0 ]
check "trust: an untrusted mirror is refused before any request" "$?"
D="$(mk demo_thing "$PROV" "$TOK" ".:example/demo=1.1.0")" run lock-missing; esc "a lock version the mirror lacks" not-in-mirror
D="$(mk demo_thing "head:.:demo=example/demo:>=9" "$TOK" "")" run unsat; esc "constraints no version satisfies" constraint-unsatisfiable
D="$(mk demo_thing "head:.:demo=example/demo:>=1||<2" "$TOK" "")" run unparsable; esc "an operator Terraform lacks" constraint-unparsable
D="$(mk demo_thing "head:.:!constraint_unparsable" "$TOK" "")" run dir-unparsable; esc "a directory whose required_providers could not be read" constraint-unparsable
D="$(mk other_x "head:.:other=example/other:>=1" ".:resource:other_x:example/other" "")" run no-registry; esc "a provider the registry lacks" http-error
D="$(mk demo_broken "$PROV" ".:resource:demo_broken:example/demo" "")" run miss; esc "a type that is a miss" page
DEMO="$SITE/mirror/example_demo-v1.3.0"
cp -R "$DEMO" "$TMP/keep"
reset() { rm -rf "$DEMO" && cp -R "$TMP/keep" "$DEMO"; }
D="$(mk demo_thing "$PROV" "$TOK" "")"
sed 's/^[0-9a-f]/0/' "$TMP/keep/SHA256SUMS" > "$DEMO/SHA256SUMS"; run bad-hash; esc "a checksum mismatch" checksum; reset
printf 'x' >> "$DEMO/example_demo-1.3.0.schema.json.gz"; run tampered-schema; esc "a schema file whose hash disagrees with SHA256SUMS" checksum
! grep -q '^schema pass: source ' "$R.out"
check "provenance: no source line when the run escalates" "$?"
reset
jq -c '.version = "1.2.0"' "$TMP/keep/manifest.json" > "$DEMO/manifest.json"
(cd "$DEMO" && sha256sum example_demo-1.3.0.schema.json.gz manifest.json > SHA256SUMS); run bad-manifest; esc "a manifest for another version" manifest; reset
echo "https://evil.example.com/x" > "$DEMO/REDIRECT"; run evil; esc "a redirect off the host list" host-rejected; reset
printf '#!/bin/sh\ntouch "%s/ran-asset"\n' "$TMP" | gzip -n > "$DEMO/example_demo-1.3.0.schema.json.gz"
chmod +x "$DEMO/example_demo-1.3.0.schema.json.gz"
(cd "$DEMO" && sha256sum example_demo-1.3.0.schema.json.gz manifest.json > SHA256SUMS); run script-asset; esc "an asset that is a script" json-shape
[ ! -e "$TMP/ran-asset" ]
check "a downloaded script is never run" "$?"
reset
bad=""
for f in "$TMP"/run-*.out; do
  l="$(sed -n 's/^schema pass: escalate //p' "$f")"
  [ -z "$l" ] || [[ "$l" =~ ^[a-z0-9-]{1,64}$ ]] || bad="$bad $l"
done
[ -z "$bad" ]
check "every escalate reason matches ^[a-z0-9-]{1,64}\$" "$?"

# --- Normal mode is unchanged: the same lock-free failure is a page type, exit 0.
R="$TMP/run-normal"
STUB_LOG="$R.log" SCHEMA_PROVIDERS="$PROV" SCHEMA_TYPES=".:resource:demo_broken:example/demo .:resource:demo_thing:example/demo" \
  MODULESTF_SCHEMA_MIRROR=example/mirror bash "$SP" "$R/facts" "$R/work" > "$R.out" 2>&1
a=$?
[ "$a" = 0 ] && ! grep -q 'escalate' "$R.out" && [ "$(jq -c '.directories["."]["example/demo"]' "$R/facts/versions.json")" = '{"latest":"1.3.0","minimum":"1.2.0"}' ]
check "normal mode: no SCHEMA_DEPTH, no escalation, any owner/name mirror as before" "$?"

# --- The script and its document.
code="$(grep -vE '^[[:space:]]*#' "$SP")"
! grep -qE '(^|[;&|(`]|then|do|\$\()[[:space:]]*(eval|source|terraform|sh -c|bash -c|exec)([[:space:]]|$)' <<< "$code" &&
  ! grep -qE '(^|[;&|]|then|do)[[:space:]]*\.[[:space:]]+["$]' <<< "$code"
check "script: no eval, source, exec, shell -c or terraform call" "$?"
grep -qxF 'TRUSTED_MIRROR="modulestf/terraform-schema-mirror"' "$SP" && grep -qxF 'MAX_SHEETS=6' "$SP" && grep -qxF 'MAX_SHEET_BYTES=49152' "$SP" &&
  grep -qF '`modulestf/terraform-schema-mirror`' "$DOC" && grep -qF 'at most 6 sheets and 49152 bytes' "$DOC"
check "doc: the trust anchor and the caps match the script" "$?"
codes="$(sed -nE "s/^reason_re='\^\((.*)\)\\$'$/\1/p" "$SP" | tr '|' '\n'; grep -oE 'escalate [a-z_]+' "$SP" | cut -d ' ' -f 2)"
miss=""
for c in $codes; do grep -qF "\`${c//_/-}\`" "$DOC" || grep -qF "\`$c\`" "$DOC" || miss="$miss $c"; done
[ -n "$codes" ] && [ -z "$miss" ]
check "doc: every reason the script can escalate with is listed" "$?"
[ -z "$miss" ] || echo "       not listed:$miss"

# --- Negative self-check: each weakened copy of the script must fail the case it weakens.
mutant() { # name, sed expression, case runner (a function), case check (a function)
  local d="$TMP/mut-$1"
  mkdir -p "$d" && cp "$REF/schema-facts.jq" "$REF/schema-handoff.jq" "$d/" && sed "$2" "$SP" > "$d/schema-pass.sh"
  if cmp -s "$SP" "$d/schema-pass.sh"; then check "self-check: mutation $1 changes the script" 1; return; fi
  SPX="$d/schema-pass.sh" "$3"
  "$4"; [ $? != 0 ]
  check "self-check: mutation $1 is caught" "$?"
}
c_seven() { D="$(mk "demo_thing demo_a demo_b demo_c" "$PROV" "$TOK .:resource:demo_b:example/demo .:resource:demo_c:example/demo" "")" run m-seven; }
k_seven() { [ "$RC" = 3 ] && grep -qx 'schema pass: escalate overflow' "$R.out" && [ ! -e "$R/facts" ]; }
c_big() { D="$(mk demo_big "$PROV" ".:resource:demo_big:example/demo" "")" run m-big; }
k_big() { [ "$RC" = 3 ] && grep -qx 'schema pass: escalate overflow' "$R.out"; }
c_trust() { MIRROR=example/mirror D="$(mk demo_thing "$PROV" "$TOK" "")" run m-trust; }
k_trust() { [ "$RC" = 3 ] && grep -qx 'schema pass: escalate mirror-untrusted' "$R.out"; }
c_lock() { D="$(mk demo_thing "$PROV" "$TOK" ".:example/demo=1.2.5")" run m-lock; }
k_lock() { [ "$RC" = 0 ] && [ -f "$R/facts/example/demo/1.2.5/resources/demo_thing.facts" ]; }
c_filter() { D="$(mk demo_thing "$PROV" "$TOK" "")" run m-filter; }
k_filter() { [ "$RC" = 0 ] && [ "$(jq -c .types "$R/facts/example/demo/1.3.0/index.json")" = '{"resource:demo_thing":"sheet"}' ]; }
c_unbound() { D="$(mk demo_x "$PROV" "$TOK" "")" run m-unbound; }
k_unbound() { [ "$RC" = 3 ] && grep -qx 'schema pass: escalate type-unbound' "$R.out"; }
c_miss() { D="$(mk demo_broken "$PROV" ".:resource:demo_broken:example/demo" "")" run m-miss; }
k_miss() { [ "$RC" = 3 ] && grep -qx 'schema pass: escalate page' "$R.out"; }
c_fail() { D="$(mk demo_thing "$PROV" "$TOK" ".:example/demo=1.1.0")" run m-fail; }
k_fail() { [ "$RC" = 3 ] && grep -qx 'schema pass: escalate not-in-mirror' "$R.out" && [ ! -e "$R/facts" ]; }
c_tok() { D="$(mk demo_thing "head:.:demo=Example/demo:>=1.2" "$TOK" "")" run m-tok; }
k_tok() { [ "$RC" = 3 ] && grep -qx 'schema pass: escalate inputs' "$R.out"; }
c_src() { D="$(mk demo_thing "$PROV" "$TOK" "")" run m-src; }
k_src() { [ "$RC" = 0 ] && [ "$(grep -c '^schema pass: source modulestf/terraform-schema-mirror example_demo-v1\.[23]\.0 [0-9a-f]\{64\}$' "$R.out")" = 2 ]; }
mutant sheet-cap 's/^MAX_SHEETS=6$/MAX_SHEETS=60/' c_seven k_seven
mutant byte-cap 's/^MAX_SHEET_BYTES=49152$/MAX_SHEET_BYTES=491520/' c_big k_big
mutant any-mirror 's/|| escalate mirror_untrusted$/|| :/' c_trust k_trust
mutant no-lock 's/^  awk -v p="\$prov" .\$1 == p { print p, \$2 }. "\$WORK\/locks"$/  :/' c_lock k_lock
mutant all-types 's/ \&\& (\$4 in x)//' c_filter k_filter
mutant unbound-ok 's/|| escalate type_unbound$/|| :/' c_unbound k_unbound
mutant page-ok 's/|| escalate page$/|| :/' c_miss k_miss
mutant exit-0 's/rm -rf "\$OUT"; exit 3; }/rm -rf "$OUT"; exit 0; }/' c_fail k_fail
mutant reasons-ok 's/^  \[ ! -s "\$WORK\/reasons" \] || escalate .*$/  :/' c_fail k_fail
mutant tokens-dropped 's/^refused_token() { .*$/refused_token() { :; }/' c_tok k_tok
mutant no-source 's/^    echo "schema pass: source .*$/    :/' c_src k_src

if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
