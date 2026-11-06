# Test Pass

> **Part of:** [terraform-module-pr-review](../SKILL.md)
> **Purpose:** The second exception of Rule 3: the repository's own Python unit tests, run inside the isolated runner for a change to a module's embedded code, and the one fixed result line they leave.

A change to a file outside HCL that HCL reads, such as a Lambda function's source, is a `non-hcl-dependency` trigger ([behaviour-pass.md](behaviour-pass.md)). No level of the ladder can verify it. Its evidence is the repository's own tests. The Checks signal reads them when the head has check runs ([verdict.md](verdict.md#the-ladder)); this pass runs them itself, in the runner, so the review has test evidence of its own.

## When It Runs

- **Only with a `non-hcl-dependency` trigger** in `behaviour/behaviour.json`, at light, focused and deep, outside a triage run. `evidence` adds the `tests` step then, beside the other passes at deep and after them at light and focused, and `handover` and `render` refuse until it ran ([review-run.md](review-run.md)).
- **Only in the isolated runner.** When `docker info` does not answer within 30 seconds, the result is `not run: no runner`. Nothing runs on the reviewer's machine: there is no laptop mode for tests.
- **Not opt-in.** No credential of any kind is involved, the container's only way out is a proxy that passes the Python package index, and nothing the head holds reaches the host but one line. So the pass runs whenever the runner is available, without asking, unlike the plan pass, which needs a profile and a role named for the run. A run with no runner loses only this evidence.

## What Runs

What to run is read from the merge base, which is trusted, and never from the head. The head gives only the files the tests run on.

1. The Python files among the trigger files must sit in one directory, a plain path. Another file type only, or more than one directory, is `not run: unsupported`.
2. In that directory at the merge base, read with `git show` and never executed:
   - a `Pipfile` whose `[scripts]` `test` entry is a plain pytest run, `pytest` or `python -m pytest` or `python3 -m pytest` with flag-like arguments only, and whose `[requires]` `python_version` is absent, `3.11` or `3.12`: kind `pipenv`, with `python3` (3.11) or `python3.12`;
   - otherwise a `requirements-dev.txt` with a line naming `pytest`: kind `requirements`, with `python3`;
   - anything else, a `pyproject.toml` alone included: `not run: unsupported`.
3. The head's files of that directory, as a tar that `git archive` makes from the clone's objects, at most 64 MiB, go to the container on standard input. No host path of the head is mounted.
4. In the container ([plan-runner/test-entry.sh](plan-runner/test-entry.sh)): `pipenv install --dev`, or a virtual environment and `pip install -r requirements-dev.txt`, then `python -m pytest -p no:cacheprovider -q` with a JUnit report, from the directory. The command is fixed in the image. The base's script is read only to decide that the repository runs pytest; its arguments, and every command string of the head, `pipenv run` included, are never run.

## Isolation

[plan-runner/run-tests.sh](plan-runner/run-tests.sh) runs the pass on the runner images of the plan pass ([plan-runner/README.md](plan-runner/README.md)):

- an internal network whose only way out is the egress proxy with `allowlist-test`: `pypi.org` and `files.pythonhosted.org` on port 443, and nothing else, so GitHub, AWS and every other host are refused;
- before the archive reaches a container, the network check of the plan pass behind that proxy: IPv6 off, every direct path closed, both positive controls holding, with `pypi.org` as the allowed host and `github.com` and `sts.us-east-1.amazonaws.com` refused. A failure is `error network`;
- no credential: no environment variable, no file and no mount carries one;
- a read-only root, all capabilities dropped, `no-new-privileges`, uid 10001, 4 GiB of memory, 512 processes, a fresh work volume;
- every Docker object named with the run's id in `tests-record/run-id.txt`, removed when the script ends, and by `cleanup` after a SIGKILL.

## Limits

| Limit | Value |
|-------|-------|
| Time | 10 minutes for the install and the tests together, inside the container; the host stops the container a minute later |
| Output | 64 KiB of the container's output is read, and only its last result line is kept; the install and test output never leave the container |
| Archive | 64 MiB |
| Proxy log | 5 MiB, kept in the record for the operator, never read into the review |

## Result

One line, of exactly this grammar, in `<run>/tests.json` with the tested directory, in the handover record as `tests: <dir>: <result>`, and in the run file's `tests` key for the render:

| Result | Meaning |
|--------|---------|
| `passed <n>` | pytest exited 0; `<n>`, at least 1, tests passed |
| `failed <n>` | pytest exited 1; `<n>` tests failed or errored |
| `error <class>` | The pass ran and gave no test result: `install`, `timeout`, `no-tests`, `pytest`, `report`, `archive`, `network`, `runner`, `output`, `python`, `usage` |
| `not run: <reason>` | The pass did not start: `no trigger`, `unsupported`, `no merge base`, `no runner` |

No test name, message or other output prose crosses into the record, the reviewer's task or the comment.

## Verdict

[verdict.md](verdict.md#behaviour-evidence): `passed <n>` marks the Python `non-hcl-dependency` triggers of the tested directory `tested`, no gap of rule 4; `failed <n>` marks them `refuted`, a block at rule 2; `error` and `not run` change nothing, so the Checks signal stays their evidence as before. The comment gives one fixed line, `tests-passed` or `tests-failed` ([comment-format.md](comment-format.md#host-render-strings)).

## Limits of the Evidence

- **The head chooses its tests.** A change can weaken or delete its own tests, and a passing run then proves nothing about the change. The reviewer reads the test files in the diff; this pass adds a run, never a judgement of the tests.
- **The result line is untrusted.** The head's code runs in the container as the same user as the entry script, so it can print a forged line. That gives it no power the first point does not already give it, and the line is held to its grammar on the host.
- **The package index can carry data out.** The container holds only the head's public files, so there is nothing of the reviewer's to carry.
- **Python only**, one directory, pipenv from Debian (2022.12.19) and Python 3.11 or 3.12. A `Pipfile` asking for another Python ends in `error install`; a `Pipfile.lock` at the head is used as pipenv uses it.
- **The work volume has no size limit**, as in the plan pass; the run removes it.
