#!/bin/bash
# Self-check for the schema pass of terraform-module-pr-review (references/schema-pass.sh
# and schema-facts.jq) in its depth modes: the tokens from depth.json, the versions per
# type (latest, declared minimum, head lock file) deduplicated, one sheet for versions with
# the same body, the focused caps and overflow code, the trusted mirror, each escalate
# reason, deep's partial results and missing.json, nothing downloaded run, and a negative
# self-check that mutates temp copies of the script. curl is stubbed: no network.
# Needs jq; it runs the script with /bin/bash and the system tools only (BSD or GNU), so a
# GNU-only flag fails here as it would on a Mac.
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

mkdir -p "$TMP/bin"
# SHA-256 with GNU coreutils, macOS's sha256sum, or else shasum, as the script does.
if command -v sha256sum > /dev/null 2>&1; then sha256() { sha256sum "$@"; }; else sha256() { shasum -a 256 "$@"; }; fi
# The system PATH only: the stubs below, then the host's own tools, never a g-prefixed set.
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
# The system tools only, so a GNU-only flag in the script fails here as it would on a Mac;
# jq is linked in from wherever the host keeps it.
jq_bin="$(command -v jq)" && ln -s "$jq_bin" "$TMP/bin/jq" || { echo "FAIL no jq"; exit 1; }
export PATH="$TMP/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export SITE="$TMP/site" STUB_LOG=/dev/null
mkdir -p "$SITE/registry" "$SITE/mirror"

# A schema of the provider example/demo per version: small types that differ at every
# version, demo_part that differs only between minor versions, demo_lookup the same at
# every version, one malformed, one large, and a description that would run a command if
# anything ever evaluated it.
small='{"block": {"attributes": {"id": {"type": "string", "computed": true}, "name": {"type": "string", "required": true}},
  "block_types": {"rule": {"nesting_mode": "list", "max_items": 2, "block": {"attributes": {"x": {"type": "number", "optional": true}}}}}}}'
schema() { # version -> the schema JSON
  jq -n -c --argjson s "$small" --arg mark "$TMP/ran-description" --arg v "$1" '
    ($v | gsub("[.]"; "_")) as $vu | ($v | split(".")[0:2] | join("_")) as $mu
    | ($s | .block.attributes["since_\($vu)"] = {type: "bool", optional: true}) as $d
    | {format_version: "1.0", provider_schemas: {"registry.terraform.io/example/demo": {
    resource_schemas: {
      demo_thing: ($d | .block.attributes.name.description = "$(touch \($mark)) `touch \($mark)`"),
      demo_a: $d, demo_b: $d, demo_c: $d, demo_d: $d, demo_e: $d, demo_f: $d,
      demo_part: ($s | .block.attributes["since_\($mu)"] = {type: "bool", optional: true}),
      demo_broken: {block: {attributes: {x: {type: "string", optional: "yes"}}}},
      demo_big: {block: {attributes: ([range(1100)] | map({key: "attribute_number_\(.)", value: {type: "string", optional: true}}) | from_entries
        | .["since_\($vu)"] = {type: "bool", optional: true})}}},
    data_source_schemas: {demo_lookup: $s}}}}'
}
release() { # version
  local d="$SITE/mirror/example_demo-v$1" f="example_demo-$1.schema.json.gz"
  mkdir -p "$d"
  schema "$1" | gzip -n > "$d/$f"
  jq -n -c --arg v "$1" --arg f "$f" '{provider: "example/demo", version: $v, file: $f, format_version: "1.0"}' > "$d/manifest.json"
  (cd "$d" && sha256 "$f" manifest.json > SHA256SUMS)
}
jq -n -c '{versions: [$ARGS.positional[] | {version: .}]}' --args 1.0.0 1.2.0 1.2.5 1.3.0 2.0.0-beta > "$SITE/registry/example_demo.json"
for v in 1.0.0 1.2.0 1.2.5 1.3.0; do release "$v"; done

mk() { # touched types, provider tokens, type tokens, lock tokens -> depth.json text
  jq -n -c --arg x "$1" --arg p "$2" --arg t "$3" --arg l "$4" --arg d "${DEPTH:-focused}" 'def w($s): $s | split(" ") | map(select(. != ""));
    {format: 1, depth: $d, touched_types: w($x), schema_providers: w($p), schema_types: w($t), schema_locks: w($l)}'
}
PROV="head:.:demo=example/demo:>=1.2"
TOK=".:resource:demo_thing:example/demo .:resource:demo_a:example/demo .:data:demo_lookup:example/demo"
run() { # name; env D (depth.json text), DP (its path instead), MIRROR, SPX (another script)
  R="$TMP/run-$1"
  mkdir -p "$R.d" && printf '%s\n' "${D:-}" > "$R.d/depth.json"
  if [ -n "${MIRROR+x}" ]; then export MODULESTF_SCHEMA_MIRROR="$MIRROR"; else unset MODULESTF_SCHEMA_MIRROR; fi
  STUB_LOG="$R.log" SCHEMA_DEPTH="${DP:-$R.d/depth.json}" SCHEMA_PROVIDERS="head:.:demo=example/demo:>=1.0" \
    SCHEMA_TYPES=".:resource:demo_b:example/demo" /bin/bash "${SPX:-$SP}" "$R/facts" "$R/work" > "$R.out" 2>&1
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
  (cd "$R/facts" && sha256 --strict -c files.sha256 > /dev/null)
check "versions: versions.json and files.sha256 as in normal mode" "$?"
ver_bytes="$(sed -n 's/^schema pass: focused, .*, 3 sheets, \([0-9]*\) bytes$/\1/p' "$R.out")"
[ "$ver_bytes" = "$(cat "$R"/facts/example/demo/*/resources/*.facts | wc -c | tr -d ' ')" ]
check "versions: the byte count is the sheets' total" "$?"
src="$(sed -n 's/^schema pass: source //p' "$R.out" | LC_ALL=C sort)"
want="$(for v in 1.2.0 1.2.5 1.3.0; do printf 'modulestf/terraform-schema-mirror example_demo-v%s %s\n' "$v" \
  "$(sha256 < "$SITE/mirror/example_demo-v$v/example_demo-$v.schema.json.gz" | cut -d ' ' -f 1)"; done)"
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
D="$(mk "demo_lookup demo_nope" "$PROV" "$TOK .:resource:demo_nope:example/demo" ".:example/demo=1.2.5")" run data-absent
[ "$RC" = 0 ] && [ "$(sheets)" = "example/demo/1.3.0/data-sources/demo_lookup.facts " ] && grep -q ', 1 sheets, ' "$R.out" &&
  [ "$(jq -r '.types["resource:demo_nope"]' "$R/facts/example/demo/1.3.0/index.json")" = absent ]
check "a data source sheet; a type absent from the schema is absent, no sheet, no escalation" "$?"
f="$R/facts/example/demo/1.3.0/data-sources/demo_lookup.facts"
[ "$(sed -n 2,3p "$f")" = "$(printf 'version: 1.3.0\nversions: 1.2.0 1.2.5 1.3.0')" ] && [ "$(grep -c '^versions: ' "$f")" = 1 ] &&
  [ "$(jq -c .same_as "$R/facts/example/demo/1.2.0/index.json") $(jq -c .same_as "$R/facts/example/demo/1.2.5/index.json")" = \
    '{"data:demo_lookup":"1.3.0"} {"data:demo_lookup":"1.3.0"}' ] &&
  [ "$(jq -r '.types["data:demo_lookup"]' "$R/facts/example/demo/1.2.0/index.json")" = sheet ] &&
  [ "$(jq -c .same_as "$R/facts/example/demo/1.3.0/index.json")" = null ]
check "dedupe: one sheet for three versions with the same body, at the highest, a versions line, same_as at the others" "$?"
D="$(mk demo_part "$PROV" ".:resource:demo_part:example/demo" ".:example/demo=1.2.5")" run part
[ "$RC" = 0 ] && [ "$(sheets)" = "example/demo/1.2.5/resources/demo_part.facts example/demo/1.3.0/resources/demo_part.facts " ] &&
  grep -qx 'versions: 1.2.0 1.2.5' "$R/facts/example/demo/1.2.5/resources/demo_part.facts" &&
  ! grep -q '^versions:' "$R/facts/example/demo/1.3.0/resources/demo_part.facts" &&
  [ "$(jq -c .same_as "$R/facts/example/demo/1.2.0/index.json")" = '{"resource:demo_part":"1.2.5"}' ] &&
  (cd "$R/facts" && sha256 --strict -c files.sha256 > /dev/null)
check "dedupe: only versions with the same body share a sheet; files.sha256 still holds" "$?"
D="$(mk "" "$PROV" "$TOK" "")" run none
[ "$RC" = 0 ] && grep -q ', 0 sheets, 0 bytes$' "$R.out" && [ "$(grep -c '^URL' "$R.log")" = 0 ]
check "no touched type: no download, 0 sheets, exit 0" "$?"
MIRROR=modulestf/terraform-schema-mirror D="$(mk demo_thing "$PROV" "$TOK" "")" run trusted-env
[ "$RC" = 0 ]
check "trust: MODULESTF_SCHEMA_MIRROR equal to the trusted mirror is accepted" "$?"

# --- Caps: 16 sheets and 49152 bytes after the dedupe; overflow never truncates.
FOUR="demo_thing demo_a demo_b demo_c"
SIX="$FOUR demo_d demo_e"
toks() { for t in "$@"; do printf '.:resource:%s:example/demo ' "$t"; done; } # types -> type tokens
D="$(mk "$FOUR" "$PROV" "$(toks $FOUR)" ".:example/demo=1.2.5")" run twelve
[ "$RC" = 0 ] && grep -q ', 12 sheets, ' "$R.out"
check "caps: 4 types at 3 versions, 12 small sheets, pass" "$?"
D="$(mk "$SIX" "$PROV" "$(toks $SIX)" ".:example/demo=1.2.5")" run eighteen
esc "18 sheets" overflow
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
(cd "$DEMO" && sha256 example_demo-1.3.0.schema.json.gz manifest.json > SHA256SUMS); run bad-manifest; esc "a manifest for another version" manifest; reset
echo "https://evil.example.com/x" > "$DEMO/REDIRECT"; run evil; esc "a redirect off the host list" host-rejected; reset
printf '#!/bin/sh\ntouch "%s/ran-asset"\n' "$TMP" | gzip -n > "$DEMO/example_demo-1.3.0.schema.json.gz"
chmod +x "$DEMO/example_demo-1.3.0.schema.json.gz"
(cd "$DEMO" && sha256 example_demo-1.3.0.schema.json.gz manifest.json > SHA256SUMS); run script-asset; esc "an asset that is a script" json-shape
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
DEPTH=light D="$(DEPTH=light mk demo_thing "$PROV" "$TOK" "")" run light; esc "a depth other than focused or deep" depth-input

# --- Deep: every schema_types token, the old floor too, generous caps, and a failure never
# escalates: exit 0, the sheets it completed, and missing.json naming every type without one.
missing() { jq -c '[.missing[] | "\(.type)@\(.versions | join(","))"]' "$R/facts/missing.json"; }
DT=".:resource:demo_thing:example/demo .:resource:demo_a:example/demo .:data:demo_lookup:example/demo"
DEPTH=deep D="$(DEPTH=deep mk "" "$PROV base:.:demo=example/demo:>=1.0" "$DT" ".:example/demo=1.2.5")" run deep-full
[ "$RC" = 0 ] && grep -qx 'schema pass: deep, mirror modulestf/terraform-schema-mirror, 9 sheets, [0-9]* bytes' "$R.out" &&
  [ "$(jq -c . "$R/facts/missing.json")" = '{"format":1,"reasons":[],"missing":[]}' ] &&
  [ -f "$R/facts/example/demo/1.0.0/resources/demo_a.facts" ] && [ -f "$R/facts/example/demo/1.2.5/resources/demo_thing.facts" ] &&
  [ "$(sheets | tr ' ' '\n' | grep -c 'demo_lookup')" = 1 ] && [ "$(grep -c '^schema pass: source ' "$R.out")" = 4 ] &&
  (cd "$R/facts" && sha256 --strict -c files.sha256 > /dev/null)
check "deep full: every type token, not only touched, at latest, minimum, lock and old floor, deduplicated, missing.json empty" "$?"
DEPTH=deep D="$(DEPTH=deep mk "" "$PROV" "$DT .:resource:demo_broken:example/demo" "")" run deep-miss
[ "$RC" = 0 ] && grep -q '^schema pass: deep partial page, 5 sheets, [0-9]* bytes, 1 types without a sheet$' "$R.out" &&
  [ "$(missing)" = '["resource:demo_broken@1.2.0,1.3.0"]' ] && [ "$(jq -c .reasons "$R/facts/missing.json")" = '["page"]' ] &&
  [ "$(jq -r '.types["resource:demo_broken"]' "$R/facts/example/demo/1.3.0/index.json")" = page ] &&
  [ -f "$R/facts/example/demo/1.3.0/resources/demo_thing.facts" ] && [ ! -e "$R/facts/example/demo/1.3.0/resources/demo_broken.facts" ]
check "deep partial: a miss is page at every version and in missing.json, the other sheets published, exit 0" "$?"
DEPTH=deep D="$(DEPTH=deep mk "" "$PROV" "$DT" ".:example/demo=1.1.0 .:example/demo=v9")" run deep-fail
[ "$RC" = 0 ] && grep -q '^schema pass: deep partial inputs, 0 sheets, 0 bytes, 3 types without a sheet$' "$R.out" &&
  [ "$(jq -c .reasons "$R/facts/missing.json")" = '["inputs","not-in-mirror"]' ] &&
  [ "$(missing)" = '["data:demo_lookup@1.1.0,1.2.0,1.3.0","resource:demo_a@1.1.0,1.2.0,1.3.0","resource:demo_thing@1.1.0,1.2.0,1.3.0"]' ]
check "deep partial: a bad lock token is noted, a lock version the mirror lacks makes every type of the provider page, exit 0" "$?"
MIRROR=example/mirror DEPTH=deep D="$(DEPTH=deep mk "" "$PROV" "$DT" "")" run deep-untrusted
[ "$RC" = 0 ] && grep -q '^schema pass: deep partial mirror-untrusted, 0 sheets, 0 bytes, 3 types without a sheet$' "$R.out" &&
  [ "$(grep -c '^URL https://github' "$R.log")" = 0 ]
check "deep partial: an untrusted mirror is never read, every type is listed missing, exit 0" "$?"
mkdir -p "$TMP/deepcap" && cp "$REF/schema-facts.jq" "$REF/schema-handoff.jq" "$TMP/deepcap/" &&
  sed 's/^MAX_DEEP_SHEETS=64$/MAX_DEEP_SHEETS=3/' "$SP" > "$TMP/deepcap/schema-pass.sh"
SPX="$TMP/deepcap/schema-pass.sh" DEPTH=deep D="$(DEPTH=deep mk "" "$PROV" "$(toks demo_a demo_b demo_thing)" ".:example/demo=1.2.5")" run deep-cap
[ "$RC" = 0 ] && grep -q '^schema pass: deep partial overflow, 3 sheets, ' "$R.out" &&
  [ "$(sheets)" = "example/demo/1.2.0/resources/demo_a.facts example/demo/1.2.5/resources/demo_a.facts example/demo/1.3.0/resources/demo_a.facts " ] &&
  [ "$(missing)" = '["resource:demo_b@1.2.0,1.2.5,1.3.0","resource:demo_thing@1.2.0,1.2.5,1.3.0"]' ]
check "deep caps: types in name order with all their sheets or none, the rest page and missing, never truncated" "$?"
grep -qxF 'MAX_DEEP_SHEETS=64' "$SP" && grep -qxF 'MAX_DEEP_BYTES=1048576' "$SP" && grep -qF 'at most 64 sheets and 1048576 bytes' "$DOC"
check "doc: the deep caps match the script" "$?"

# --- Normal mode is unchanged: the same lock-free failure is a page type, exit 0.
R="$TMP/run-normal"
STUB_LOG="$R.log" SCHEMA_PROVIDERS="$PROV" SCHEMA_TYPES=".:resource:demo_broken:example/demo .:resource:demo_thing:example/demo" \
  MODULESTF_SCHEMA_MIRROR=example/mirror /bin/bash "$SP" "$R/facts" "$R/work" > "$R.out" 2>&1
a=$?
[ "$a" = 0 ] && ! grep -q 'escalate' "$R.out" && [ "$(jq -c '.directories["."]["example/demo"]' "$R/facts/versions.json")" = '{"latest":"1.3.0","minimum":"1.2.0"}' ]
check "normal mode: no SCHEMA_DEPTH, no escalation, any owner/name mirror as before" "$?"

# --- The script and its document.
code="$(grep -vE '^[[:space:]]*#' "$SP")"
! grep -qE '(^|[;&|(`]|then|do|\$\()[[:space:]]*(eval|source|terraform|sh -c|bash -c|exec)([[:space:]]|$)' <<< "$code" &&
  ! grep -qE '(^|[;&|]|then|do)[[:space:]]*\.[[:space:]]+["$]' <<< "$code"
check "script: no eval, source, exec, shell -c or terraform call" "$?"
grep -qxF 'TRUSTED_MIRROR="modulestf/terraform-schema-mirror"' "$SP" && grep -qxF 'MAX_SHEETS=16' "$SP" && grep -qxF 'MAX_SHEET_BYTES=49152' "$SP" &&
  grep -qF '`modulestf/terraform-schema-mirror`' "$DOC" && grep -qF 'at most 16 sheets and 49152 bytes' "$DOC"
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
  rm -rf "$TMP"/run-m-*
  mkdir -p "$d" && cp "$REF/schema-facts.jq" "$REF/schema-handoff.jq" "$d/" && sed "$2" "$SP" > "$d/schema-pass.sh"
  if cmp -s "$SP" "$d/schema-pass.sh"; then check "self-check: mutation $1 changes the script" 1; return; fi
  SPX="$d/schema-pass.sh" "$3"
  "$4"; [ $? != 0 ]
  check "self-check: mutation $1 is caught" "$?"
}
c_seven() { D="$(mk "$SIX" "$PROV" "$(toks $SIX)" ".:example/demo=1.2.5")" run m-seven; }
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
mutant sheet-cap 's/^MAX_SHEETS=16$/MAX_SHEETS=160/' c_seven k_seven
mutant byte-cap 's/^MAX_SHEET_BYTES=49152$/MAX_SHEET_BYTES=491520/' c_big k_big
mutant any-mirror 's/^    fail mirror_untrusted$/    :/' c_trust k_trust
mutant no-lock 's/^  awk -v p="\$prov" .\$1 == p { print p, \$2 }. "\$WORK\/locks"$/  :/' c_lock k_lock
mutant all-types 's/(m == "deep" || (\$4 in x))/1/' c_filter k_filter
mutant unbound-ok 's/|| escalate type_unbound$/|| :/' c_unbound k_unbound
mutant page-ok 's/|| escalate page$/|| :/' c_miss k_miss
mutant exit-0 's/rm -rf "\$OUT"; exit 3; }/rm -rf "$OUT"; exit 0; }/' c_fail k_fail
c_unp() { D="$(mk demo_thing "head:.:demo=example/demo:>=1||<2" "$TOK" "")" run m-unp; }
k_unp() { [ "$RC" = 3 ] && grep -qx 'schema pass: escalate constraint-unparsable' "$R.out"; }
mutant reasons-ok 's/^    \[ ! -s "\$WORK\/reasons" \] || escalate .*$/    :/' c_unp k_unp
mutant tokens-dropped 's/^refused_token() { .*$/refused_token() { :; }/' c_tok k_tok
mutant no-source 's/^    echo "schema pass: source .*$/    :/' c_src k_src
c_dup() { D="$(mk demo_lookup "$PROV" "$TOK" ".:example/demo=1.2.5")" run m-dup; }
k_dup() { [ "$RC" = 0 ] && [ "$(sheets)" = "example/demo/1.3.0/data-sources/demo_lookup.facts " ] &&
  grep -qx 'versions: 1.2.0 1.2.5 1.3.0' "$R/facts/example/demo/1.3.0/data-sources/demo_lookup.facts"; }
c_part() { D="$(mk demo_part "$PROV" ".:resource:demo_part:example/demo" ".:example/demo=1.2.5")" run m-part; }
k_part() { [ "$RC" = 0 ] && [ "$(sheets)" = "example/demo/1.2.5/resources/demo_part.facts example/demo/1.3.0/resources/demo_part.facts " ]; }
mutant no-dedupe 's/tail -n +7 /tail -n +1 /' c_dup k_dup
mutant keep-lowest 's/keep="\${vs##\* }"/keep="${vs%% *}"/' c_part k_part
c_deep() { DEPTH=deep D="$(DEPTH=deep mk "" "$PROV" "$DT .:resource:demo_broken:example/demo" ".:example/demo=v9")" run m-deep; }
k_deep() { [ "$RC" = 0 ] && grep -q '^schema pass: deep partial inputs, ' "$R.out" && [ -f "$R/facts/missing.json" ] &&
  [ "$(jq -c '[.missing[].type]' "$R/facts/missing.json")" = '["resource:demo_broken"]' ]; }
c_dlock() { DEPTH=deep D="$(DEPTH=deep mk "" "$PROV" "$DT" ".:example/demo=1.1.0")" run m-dlock; }
k_dlock() { [ "$RC" = 0 ] && [ "$(jq '.missing | length' "$R/facts/missing.json")" = 3 ]; }
mutant deep-escalates 's/elif \[ "\$MODE" = deep \]; then note "\$1"; fi; }/elif [ "$MODE" = deep ]; then escalate "$1"; fi; }/' c_deep k_deep
mutant no-missing 's/^\[ "\$MODE" != deep \] || cp "\$WORK\/missing.json" "\$OUT\/missing.json" || exit 1$/:/' c_deep k_deep
mutant lock-not-same-source 's/      if (s != "sheet" \&\& s != "absent") page = 1$/      s = s/' c_dlock k_dlock

if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
