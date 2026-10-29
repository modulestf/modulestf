# Quality Gates

> **Part of:** [terraform-module-maintainer](../SKILL.md)
> **Purpose:** Which checks run at which trust level, pre-commit workflow, terraform validation, error triage

## Trust Level Decides Which Checks Run

Rule 3 in `SKILL.md` is the contract. This file does not override it.

- **Untrusted workspace:** run only the safe-deterministic checks - read-only inspection, `terraform fmt -check`, `terraform validate` after `terraform init -backend=false`, and the pinned terraform-docs as [The Documentation Region](#the-documentation-region) sets out, plus tests from an explicit allowlist. Do not run `pre-commit`, Makefile targets, git hooks or any other workspace-supplied code, and do not load hook or agent configuration from the workspace. Report every check that did not run as skipped, with its reason.
- **Trusted local run or CI:** everything below applies.
- **Both:** the optional [Facts Lint Gate](#facts-lint-gate) runs when its binary is found outside the workspace.

Generated content a fix makes stale is handled at each trust level under [Generated Content a Fix Makes Stale](#generated-content-a-fix-makes-stale). The rest of this file describes the trusted path.

## Step 1: Pre-Commit Autoupdate

```bash
cd terraform-<provider>-<service>
pre-commit autoupdate
```

This updates all hook versions in `.pre-commit-config.yaml` to their latest releases. The template ships with pinned versions that go stale - this fixes that.

**Expected output:** Lines showing updated `rev:` values. Commit the updated `.pre-commit-config.yaml`.

## Step 2: Pre-Commit Run

```bash
pre-commit run -a
```

This runs ALL configured hooks on ALL files. Which hooks a module configures, and what each one owns, belongs to the profile: for the default profile, [Quality gate](../profiles/terraform-aws-modules/PROFILE.md#quality-gate). What each one fails on:

| Hook | Common Failures |
|------|----------------|
| `terraform_fmt` | Indentation, alignment |
| `terraform_docs` | Missing descriptions, malformed markers |
| `terraform_tflint` | Unused variables, naming violations |
| `terraform_validate` | Syntax errors, invalid references |
| `terraform_wrapper_module_for_each` | No manual action needed |
| `check-merge-conflict` | Leftover `<<<<<<<` |
| `end-of-file-fixer` | Missing final newline |
| `trailing-whitespace` | Whitespace at end of lines |
| `mixed-line-ending` | CRLF line endings, where a profile configures it (the default profile does not) |

## Step 3: Fix and Re-Run

**First run almost always fails.** This is expected - the hooks fix things automatically. Re-run:

```bash
pre-commit run -a
```

Repeat until all hooks pass. If a hook keeps failing, diagnose using the triage guide below.

## Error Triage Guide

### terraform_fmt failures

**Symptom:** Hook modifies files automatically.
**Fix:** Re-run pre-commit. The first run applies fixes, second run should pass.

### terraform_docs failures

**Symptom:** `README.md` is modified or hook errors out.

**Common causes:**
1. Missing terraform-docs markers in README.md. Read the marker pair out of the file
   rather than assuming one. The markers are HTML comments on lines of their own, a
   `BEGIN`/`END` pair naming the region, and the family uses two spellings:
   `<!-- BEGIN_TF_DOCS -->` / `<!-- END_TF_DOCS -->`, which is terraform-docs' own
   default, and `<!-- BEGINNING OF PRE-COMMIT-TERRAFORM DOCS HOOK -->` /
   `<!-- END OF PRE-COMMIT-TERRAFORM DOCS HOOK -->`, the older pre-commit-terraform
   spelling that the profile's README templates ship. Neither spelling is the one true
   pair: whichever pair the file already carries is the one that file uses, and a
   README that carries none gets the pair its sibling READMEs carry.
2. Variable or output missing `description` field
3. Malformed HCL that terraform-docs can't parse

**Fix:** Ensure markers exist, add descriptions to all variables and outputs, fix HCL syntax.

### terraform_tflint failures

**Symptom:** Linting errors reported.

**Common rules and fixes:**

| Rule | Meaning | Fix |
|------|---------|-----|
| `terraform_unused_declarations` | Variable/output declared but unused | Remove or wire up the variable |
| `terraform_documented_variables` | Missing `description` on variable | Add description |
| `terraform_documented_outputs` | Missing `description` on output | Add description |
| `terraform_naming_convention` | Name doesn't follow snake_case | Rename to snake_case |
| `terraform_typed_variables` | Missing `type` on variable | Add type constraint |
| `terraform_standard_module_structure` | Missing required files | Add missing main.tf/variables.tf/outputs.tf |
| `terraform_required_version` | Missing `required_version` | Add to versions.tf |
| `terraform_required_providers` | Missing `required_providers` | Add to versions.tf |

### terraform_validate failures

**Symptom:** `Error: <something> is not a valid attribute` or similar.

**Common causes:**
1. Block used as attribute or vice versa (the #1 schema error)
2. Reference to resource that doesn't exist (count = 0 but referenced without [0])
3. Missing required argument
4. Invalid argument name (typo or wrong provider version)

**Fix:** Cross-reference against the schema worksheet. Every argument must match the provider schema exactly.

### terraform_wrapper_module_for_each failures

**Symptom:** `wrappers/` directory files are created or modified.

This hook **auto-generates the entire `wrappers/` directory** (main.tf, variables.tf, outputs.tf, versions.tf, README.md) from the root module's variables. You do not need to manually create any wrapper files.

**Fix:** Re-run pre-commit. The hook applies changes automatically.

## Step 4: Validate Examples

After pre-commit passes, validate each example:

```bash
# Basic example
cd examples/basic
terraform init
terraform validate

# Complete example
cd ../complete
terraform init
terraform validate
```

If `terraform init` fails, check `versions.tf` provider constraints.
If `terraform validate` fails, the example references module inputs/outputs that don't exist.

## Step 5: Final Checks

After all hooks pass and examples validate:

- [ ] `README.md` has auto-generated content between the terraform-docs markers
- [ ] `wrappers/` directory is auto-generated by hook (do not manually edit)
- [ ] No `Passed` hooks still show as `Modified` (re-run needed)
- [ ] No hardcoded versions left in generated code (should be from MCP or templates)

## Facts Lint Gate

`mtf-facts lint` is an optional gate at every trust level. It reads files only and runs no program, so it stays in the safe-deterministic set even in an untrusted workspace. Run it after the checks above, or in an untrusted workspace after `terraform validate`, as [facts-commands.md](facts-commands.md) sets out:

- The binary is resolved outside the workspace, never from the module being changed. Without it, report `mtf-facts lint: skipped: binary not installed` and go on.
- `--registry` and `--profile-dir` come from the skills, never from the workspace.
- Fix or explain each tool finding. Each candidate is unconfirmed: answer it, confirmed or rejected with a reason, and never report it as a finding.
- A run that exits 2, times out or gives an invalid report is reported as skipped with that reason, never as a pass, and changes no other check.

## Generated Content a Fix Makes Stale

A fix that changes a variable, an output, a default, a description or a floor, or adds or removes a resource, data source or module block in a module directory or an example, makes generated content stale: the documentation region of a `README.md` and the files a wrapper generator writes. The fix names them, as the reviewer's [Suggested Fix Contract](../../terraform-module-reviewer/references/findings-schema.md#suggested-fix-contract) requires.

- **Trusted local run or CI:** the gate regenerates them. Run it as the steps below say, and the named files change with the rest.
- **Untrusted workspace:** `pre-commit` does not run, because its hooks, their arguments and their configuration come from the workspace. The documentation region of a `README.md` is regenerated under [The Documentation Region](#the-documentation-region) below when every one of its checks passes. Everything else, and a region whose checks do not all pass, takes [The Fallback](#the-fallback).

A generated region is never edited by hand to match: that is a defect of its own.

### The Documentation Region

The documentation generator is one trusted program, at the profile's pinned and hash-verified release. It parses a directory's Terraform files statically and writes one region of one file. Nothing from the workspace runs during regeneration. The only process started is that tool, on a copy outside the workspace. That is less than Rule 3's accepted `terraform init -backend=false` with `validate`, which runs provider plugins and module sources the workspace chose, with no jail either.

[terraform-docs-pass.sh](terraform-docs-pass.sh) carries out the steps below, marked by step number; `tests/terraform-docs-pass-test.sh` holds a negative fixture for each check. Run it with the workspace and the entries the fix names:

```bash
references/terraform-docs-pass.sh --workspace <workspace> "the terraform-docs region of modules/<name>/README.md" ...
```

It prints one line per entry, `regenerated <dir>` or `stale <dir> <check>`, then `complete` or `incomplete`, which the report takes as step 12 says.

The invoker may set a few inputs, read before the environment is cleared and never from the workspace: `--profile`, the profile file; `TFDOCS_PASS_CACHE_DIR`, the cache directory; `TFDOCS_PASS_CURL`, the download program, for tests; and `TFDOCS_PASS_DEADLINE_SECONDS` and `TFDOCS_PASS_TOOL_SECONDS`, which can only lower the two time limits. A profile, cache directory or download program whose real path is the workspace, inside it or above it is refused, since the workspace could otherwise name the release, its hash or the program that fetches it.

What the workspace controls is the tool's input text and, through that, the text of the region. It must not reach the tool's configuration, its arguments, the rest of the file system or the file's other text. Each step below closes one way it could. Any failure, missing facility, time-out or mismatch sends that directory to [The Fallback](#the-fallback). The checks are made against a tree nothing else is changing: a concurrent swap of a path would need a process the workspace does not have, and is out of scope.

0. **Trusted inputs and shell.**
   - Every constant comes from the profile the skill loaded, never from the workspace, and the workspace is never searched for any of them:
     - the tool's version, its HTTPS address per platform, and the SHA-256 of its release archive per platform;
     - the recognised marker pairs;
     - the configuration text, which is the gate's effective settings.
   - The procedure runs in a shell started as `env -i PATH=/usr/bin:/bin LC_ALL=C bash --noprofile --norc`, and every helper is found through that `PATH` only. It turns on job control (`set -m`), so each child it starts gets a process group of its own.
   - The helpers differ by platform, and each is picked by the platform, never by what happens to be installed: on Linux `sha256sum`, `stat -c`, `getent passwd` and `/proc/<pid>/stat` for a process's parent and group; on macOS `shasum -a 256`, `stat -f`, `perl` with `getpwuid` and `ps`. Neither platform's `PATH` is assumed to hold `timeout`: the deadlines below are kept by the shell itself, with `SECONDS` and a background watchdog.
   - The invoking user and the home directory come from the password entry of `id -u`, never from `HOME`, which `env -i` removes.
   - One deadline of 120 seconds starts before the first check and covers every external step: each helper, the download, the copies and every run.
1. **Scope.** Only the directories the fix's "Generated content made stale" sentence names, in the fix's order, each named once: a repeat is dropped before the cap. The sentence names regions as files, such as `the terraform-docs region of modules/file-system/README.md`; such a region names the directory that holds that `README.md`, and the root `README.md` names `.`. An entry of any other form, a wrapper file aside, is reported stale with the reason "not a documentation region".
   - The first 10 are processed. The rest are reported stale, with the reason "over the cap".
   - Each is exactly `.`, `modules/<name>` or `examples/<name>`, with `<name>` matching `^[a-z0-9-]+$`: no `..`, no absolute path.
   - The directory's real path equals the workspace's real path or begins with it and a separator, and no component of the path is a symbolic link.
2. **Gates by name and `lstat`, before any file is opened.** Any of these sends the whole directory to the fallback; no file is skipped.
   - A terraform-docs configuration name in the directory or in any directory above it up to the workspace root, as any file type: `.terraform-docs.yml`, `.terraform-docs.yaml`, either one under `.config/`, or `.tfdocs.d`. The workspace's own gate reads those files, so a run without them cannot reproduce its output, and they are never opened.
   - Any `*.tf.json`, `*.tofu`, `*.tofu.json`, `override.tf` or `*_override.tf` in the directory: an input the pinned release could read, or a file that changes how the others read, that the copy of `*.tf` alone would leave out.
   - No `README.md` in the directory.
   - A `*.tf` file or the `README.md` that is not a regular file, has a link count other than 1, is not owned by the invoking user, is larger than 1 MiB, or is not named with `^[A-Za-z0-9][A-Za-z0-9._-]*$`.
   - More than 200 such files, or more than 8 MiB of them.

   Record the directory's full name listing, and the inode, mode, size and SHA-256 of each file to be copied. This record is what step 10 compares against.
3. **Markers.** Only after `README.md` has passed its gate is it read, up to its size cap. Each marker is counted as a substring anywhere in the file, in a code fence or not. The file holds exactly one begin marker and one end marker of one recognised pair, begin first, and no marker of the other pair. That pair is the one the tool is configured with for this directory. A pair the profile marks as taking the fallback, such as one with no parity fixture yet, takes it here.
4. **Run directory.** Created with `mktemp -d` under the system's temporary directory, mode 0700. Its real path is neither inside the workspace nor above it. It holds:
   - `home/`, empty;
   - `tmp/`;
   - one `tfdocs-config-<n>.yml` per directory, a name terraform-docs never discovers on its own;
   - one `work/<n>/` per directory;
   - one `orig-<n>.md` per directory, a copy of the checked `README.md` that nothing runs on, kept for the comparison in step 9.
5. **Tool.** A per-user cache under the user's cache directory, found from the password entry as step 0 says. The cache directory passes the run directory's checks: not a symbolic link, mode 0700, owned by the invoking user, and its real path neither inside the workspace nor above it; otherwise the whole run takes the fallback. Each entry is keyed by the archive's SHA-256 and holds the binary and the binary's SHA-256, recorded at install.
   - **Install.**
     - Download with `curl -q -L --proto =https --proto-redir =https --fail --max-filesize <bytes> --max-time <seconds>` into a temporary file. `-q`, first, skips the user's `.curlrc`. The release address answers with a redirect, so `-L` follows it, and `--proto-redir` keeps every hop on HTTPS.
     - Verify the archive's SHA-256.
     - Extract only the named member, `tar -xOf <archive> terraform-docs > <temporary name in the cache entry>`, then set mode 0700.
     - Record the binary's SHA-256 and rename the binary into place.
   - **Before each use**, re-hash the binary against the recorded value. An entry that fails is removed and installed again once; a second failure sends the whole run to the fallback.
   - Every exit status is checked. The host's HTTPS proxy variables are the only additions to the fixed environment of the download, since a host that needs a proxy cannot reach the address without them.
6. **Configuration.** `tfdocs-config-<n>.yml` is the profile's constant text with this directory's marker pair. It sets:
   - the formatter;
   - the output file `README.md` and the inject mode;
   - recursion off and the lock file off;
   - the header and footer sources as the gate's effective settings;
   - no content template;
   - the sort order the gate uses.

   Nothing is passed through from hook arguments, and no string from the workspace goes in.
7. **Copy.** Copy the checked `*.tf` files and `README.md` into `work/<n>/`, and record a manifest of the copy.
8. **Run.**
   - Change into `work/<n>/`; a failure is a fallback.
   - In a child shell only, set `ulimit -t 30` and `ulimit -f 4096` (bash counts 1024-byte blocks), then `exec` the tool under `env -i PATH=/usr/bin:/bin HOME=<run>/home TMPDIR=<run>/tmp LC_ALL=C` in its own process group: `<cache>/terraform-docs --config <run>/tfdocs-config-<n>.yml .`
   - Record the child's process id, which is also its group id. A watchdog sends `TERM` to that group at 60 seconds and `KILL` 5 seconds later, and is disarmed when the tool exits. Before any signal, it checks that the recorded process is still the group's leader and still this run's child, so a reused id is never signalled.
   - Reaching the overall deadline kills the recorded group the same way and sends every directory not yet copied back to the fallback.
   - No process-count limit is set: `ulimit -u` counts every process the user owns, so no value bounds this run alone, and the tool starts no process of its own.
   - No `git` command runs anywhere in this procedure.
9. **After the run.** The copy's manifest differs only in `README.md`, which is still a regular file: nothing created, nothing deleted. `README.md` is byte for byte the same as `orig-<n>.md` outside the marker region, and the region is not empty and under 1 MiB. The marker test of step 3 holds again on the new file, counted the same way: exactly one begin and one end marker of the configured pair, begin first, and no marker of the other pair. A variable description that carries marker text into the region fails it.
10. **Copy back.**
    - Re-check the directory's full name listing and every source's inode, mode, size and SHA-256 against the record step 2 made, not against the copy.
    - Then create a temporary file in the same directory with `mktemp`, write the new text, give it the original mode, and rename it over `README.md`.

    Any mismatch is a fallback. Before this step nothing in the workspace changed. The mode is kept; access control lists and extended attributes are not, and the forge tracks neither.
11. **Clean up.** A trap on `EXIT`, `INT` and `TERM`:
    - stops the watchdog;
    - signals the recorded group only while its recorded leader is still alive and still this run's child;
    - removes a temporary file this run created in the workspace, if one is pending;
    - removes the run directory, guarded to the exact path this run created.

    A `SIGKILL` of the procedure itself leaves the 0700 run directory behind in the system's temporary directory, with no credential in it: a stated limit.
12. **Report.** Each named directory is reported regenerated, or stale with the name of the check that failed, never bytes or link targets from the workspace. Wrapper files are always reported stale. While any named generated content is stale, the report says the fix is not complete.

The version, the addresses, the hashes, the marker pairs and the configuration text for the default profile are in its [Documentation regeneration in an untrusted workspace](../profiles/terraform-aws-modules/PROFILE.md#documentation-regeneration-in-an-untrusted-workspace) section.

### The Fallback

Edit no generated file. The report lists each generated file or region the fix named that was not regenerated as stale, a skipped check with its reason, and says the fix is not complete. The reason is the check that failed, or, for wrapper files, "outside the safe set in an untrusted workspace". It is regenerated before merge in a trusted context: the owner's own checkout running the profile's pinned hooks, or the project's CI. Never ask anyone to run the workspace's own `pre-commit` configuration locally: that runs the workspace's hooks.

The files a wrapper generator writes always take this fallback in an untrusted workspace. The wrapper generator is outside the safe set: no set of checks run before it makes running it over an untrusted workspace acceptable.

Stated limits of the documentation step:

- The tool parses hostile input, and an exploit of its parser is not excluded.
- There is no memory limit.
- There is no file-system or network jail. It is not needed to stay below what Rule 3 already accepts, and this step does not claim more.
- The regenerated region still carries text the workspace wrote, such as a variable's description, as every regeneration does.
- The script bounds the hashing of each directory's files, the download, the extraction, the password lookup and the tool by the time left, with a watchdog that stops a command by process id after checking it is still the script's child. A metadata read, a marker count or a copy of the capped files is not bounded on its own; the deadline is checked between them.
- The cache's trust anchor is its file permissions plus the binary's SHA-256 recorded beside it. A process running as the same user could replace both.
- Moving the pinned version means reading the new release for the same routes before the profile records it.

## When Pre-Commit Tools Are Not Installed

If `pre-commit` is not available, install it:

```bash
pip install pre-commit
# or
brew install pre-commit
```

If `terraform-docs`, `tflint`, or `terraform` are not installed:

```bash
brew install terraform-docs tflint terraform
# or use the appropriate package manager
```

On the trusted path these tools are required: a module is not complete until they have run. If a tool cannot be installed, record the check as skipped with that reason. A skipped check is never a pass.

## Iteration Strategy

The typical flow is:

1. Write code -> run `pre-commit run -a` -> many failures (expected)
2. Fix auto-fixable issues (re-run)
3. Fix manual issues (descriptions, naming, unused vars)
4. Re-run -> fewer failures
5. Repeat until clean
6. Validate examples
7. Done

Do NOT try to get everything perfect before running pre-commit. Let the tools catch issues - that's what they're for.
