#!/bin/bash
# Entry point of the runner container for the test pass: one directory's Python unit tests.
# Usage: test-entry pipenv|requirements python3|python3.12 <budget seconds>
# The directory's files arrive on standard input as a tar archive. No credential is in this
# container and its proxy passes the Python package index only. The last line it prints is the
# result, one of: "tests: passed <n>", "tests: failed <n>", "tests: error <class>". The head's
# code runs here as the same user, so that line is untrusted data (test-pass.md, Limits).
# What it installs and runs is fixed here; no command string is read from the archive.
set -uo pipefail

result() { echo "tests: $1"; exit 0; }
kind="${1-}" py="${2-}" budget="${3-}"
case "$kind" in pipenv | requirements) ;; *) result "error usage" ;; esac
case "$py" in python3 | python3.12) ;; *) result "error usage" ;; esac
[[ "$budget" =~ ^[1-9][0-9]{0,4}$ ]] || result "error usage"
py="$(command -v "$py")" || result "error python"

export HOME=/work/home TMPDIR=/work/tmp PIP_NO_INPUT=1 PIP_DISABLE_PIP_VERSION_CHECK=1 \
  PIPENV_VENV_IN_PROJECT=1 PIPENV_YES=1 PIPENV_NOSPIN=1 PIPENV_IGNORE_VIRTUALENVS=1 \
  PYTHONDONTWRITEBYTECODE=1
mkdir -p /work/src /work/home /work/tmp /work/out
tar -xf - -C /work/src --no-same-owner --no-same-permissions 2> /dev/null || result "error archive"
cd /work/src || result "error archive"

t0=$SECONDS
# A command with what is left of the budget; 124 when nothing is left.
in_budget() { local s=$((budget - (SECONDS - t0))); [ "$s" -gt 0 ] || return 124; timeout -k 10 "$s" "$@"; }
# The output of the install and of the tests stays in the container: only the result leaves.
if [ "$kind" = pipenv ]; then
  [ -f Pipfile ] && [ ! -L Pipfile ] || result "error install"
  in_budget pipenv install --dev --python "$py" > /dev/null 2>&1
  rc=$?; venv=/work/src/.venv
else
  [ -f requirements-dev.txt ] && [ ! -L requirements-dev.txt ] || result "error install"
  in_budget python3 -m virtualenv -q -p "$py" /work/venv > /dev/null 2>&1 &&
    in_budget /work/venv/bin/python -m pip install -q -r requirements-dev.txt > /dev/null 2>&1
  rc=$?; venv=/work/venv
fi
case "$rc" in 0) ;; 124 | 137) result "error timeout" ;; *) result "error install" ;; esac

rm -f /work/out/junit.xml
in_budget "$venv/bin/python" -m pytest -p no:cacheprovider -q \
  --junitxml=/work/out/junit.xml > /dev/null 2>&1 < /dev/null
rc=$?
case "$rc" in 0 | 1) ;; 5) result "error no-tests" ;; 124 | 137) result "error timeout" ;; *) result "error pytest" ;; esac
# The counts from the JUnit report, read by the image's Python in isolated mode from /, so
# nothing in the test directory is imported.
counts="$(cd / && python3 -I -c '
import sys, xml.etree.ElementTree as E
r = E.parse("/work/out/junit.xml").getroot()
s = [r] if r.tag == "testsuite" else list(r)
n = lambda k: sum(int(x.get(k, 0)) for x in s)
print(n("tests") - n("failures") - n("errors") - n("skipped"), n("failures") + n("errors"))
' 2> /dev/null)" || result "error report"
read -r passed failed <<< "$counts"
[[ "$passed" =~ ^[0-9]{1,6}$ && "$failed" =~ ^[0-9]{1,6}$ ]] || result "error report"
if [ "$rc" = 1 ]; then
  [ "$failed" -gt 0 ] || result "error report"
  result "failed $failed"
fi
[ "$passed" -gt 0 ] || result "error no-tests"
result "passed $passed"
