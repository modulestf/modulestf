#!/usr/bin/env bash
# Local stubs exercise the production capture and record assembly functions.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
from pathlib import Path
import subprocess
import tempfile

source = Path('.agents/skills/terraform-module-pr-review/references/plan-runner/run-pass.sh').read_text()
helpers = source[source.index('check_record_size() {'):source.index('# The pre-session')]
cleanup = source[source.index('save_proxy_log() {'):source.index('trap cleanup EXIT')]
assembly = source[source.index('n=0\nfor ex in "$@"; do\n  n=$((n + 1))\n  check_record_size'):source.index('\n{\n  grep -o', source.index('assemble_record() {'))]
with tempfile.TemporaryDirectory(prefix='plan-record-cap.', dir='/tmp') as directory:
    script = Path(directory) / 'probe.sh'
    script.write_text('''#!/usr/bin/env bash
set -euo pipefail
record="$1/record"; TMPRUN="$1/tmp"; runner=stub; max_bytes=1024
mkdir -p "$record" "$TMPRUN"
die() { echo "run-pass: $*" >&2; exit 2; }
docker() {
  [ "$1" = run ] || return 0
  printf '%2048s' x
  printf '%2048s' y >&2
  return "${stub_status:-0}"
}
''' + cleanup + helpers + '''
case "$2" in
  cleanup-oversized|cleanup-symlink)
    tmp_parent="$1"; TMPRUN="$1/plan-runner.abcdef"
    mkdir -p "$TMPRUN"; echo synthetic > "$TMPRUN/pass.env"
    proxy_init=owned-init; proxy_plan=owned-plan
    volume=owned-volume; net_int=owned-int; net_ext=owned-ext
    # Record Docker calls outside the directory cleanup removes.
    calls="$1/calls"
    docker() { printf '%s\n' "$*" >> "$calls"; return 0; }
    if [ "$2" = cleanup-oversized ]; then
      printf '%1025s' x > "$record/proxy-init.log"
    else
      ln -s "$TMPRUN/other" "$record/proxy-init.log"
    fi
    cleanup
    test ! -e "$TMPRUN"
    rg -Fq 'rm -f owned-init' "$calls"
    rg -Fq 'rm -f owned-plan' "$calls"
    rg -Fq 'volume rm owned-volume' "$calls"
    rg -Fq 'network rm owned-int owned-ext' "$calls" ;;
  repeated)
    in_runner "$record/output.txt"
    in_runner "$record/output.txt"
    test "$(wc -c < "$record/output.txt")" -eq 1024
    test "$(wc -c < "$record/runner.log")" -eq 1024 ;;
  shared)
    in_runner "$record/runner.log"
    in_runner "$record/runner.log"
    test "$(wc -c < "$record/runner.log")" -eq 1024 ;;
  full)
    printf '%1024s' x > "$record/output.txt"
    in_runner "$record/output.txt"
    test "$(wc -c < "$record/output.txt")" -eq 1024
    test "$(wc -c < "$record/runner.log")" -eq 1024 ;;
  remaining)
    printf '%1000s' x > "$record/output.txt"
    in_runner "$record/output.txt"
    test "$(wc -c < "$record/output.txt")" -eq 1024 ;;
  oversized)
    printf '%1025s' x > "$record/output.txt"
    in_runner "$record/output.txt" ;;
  symlink)
    ln -s "$TMPRUN/other" "$record/output.txt"
    in_runner "$record/output.txt" ;;
  status)
    docker() { printf 'ok'; printf 'err' >&2; return 17; }
    capture_runner "$record/output.txt" && exit 1
    test "$?" -eq 17
    test "$(cat "$record/output.txt")" = ok
    test "$(cat "$record/runner.log")" = err ;;
  assembly-small|assembly-large)
    budget_min=120; planned=2; exc=0
    printf 'example: examples/a\nplan: planned\nbase: deferred\n' > "$TMPRUN/block.1"
    echo 'base: not available' > "$TMPRUN/base.1"
    printf 'example: examples/b\nplan: planned\n' > "$TMPRUN/block.2"
    if [ "$2" = assembly-large ]; then
      printf '%700s\n' x >> "$TMPRUN/block.1"
      printf '%700s\n' y >> "$TMPRUN/block.2"
    fi
    set -- examples/a examples/b
''' + assembly + '''
    test "$(tail -n 1 "$out")" = 'plan summary: 2 examples, 2 planned, 0 exceptions, 0 other'
    test "$(wc -c < "$out")" -le 1024 ;;
esac
''')
    for case in ('cleanup-oversized', 'cleanup-symlink', 'repeated', 'shared', 'full', 'remaining', 'status', 'assembly-small',
                 'oversized', 'symlink', 'assembly-large'):
        # Each case has its own private record, matching the production ownership model.
        case_dir = Path(directory) / case
        case_dir.mkdir()
        result = subprocess.run(['bash', str(script), str(case_dir), case], capture_output=True, timeout=10)
        expected = 2 if case in ('oversized', 'symlink', 'assembly-large') else 0
        assert result.returncode == expected, (case, result.returncode, result.stderr.decode())
        if case == 'assembly-large':
            assert not (case_dir / 'record/plan-pass.txt').exists()
        print('PASS', case)
print('PASS production capture and assembly boundaries (11 cases)')
PY
