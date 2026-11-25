# Check H: Code Outside Terraform

> **Part of:** [terraform-module-reviewer](../SKILL.md)
> **Purpose:** The operative fails-when and severity rules of Check H, which reads changed code outside Terraform that the module runs. Rule numbers refer to the [Mandatory Rules](../SKILL.md#mandatory-rules) in SKILL.md.

## Reads, Fails When and Severity

Check H reads a changed file that is not Terraform configuration and that the module runs: a program a `.tf` file runs, through a `data "external"` `program`, a `local-exec` or other provisioner `command`, or a packaging step's build command, such as a packaging script at the module root; and a script the module's own tests run. A file that a `.tf` file packages or reads, such as a Lambda source or a `templatefile` input, is embedded code and belongs to [Check C](check-c-structure.md#embedded-code), even when a `.tf` file also runs it. Reading supports a judgement and verifies nothing: no finding of this check, and no absence of one, ever stands in for a plan or a test run, and a caller never clears a gap of its own on it.

**Reads:** each such file the change edits, whole, at the base and the head, the `.tf` lines that run it with the arguments they pass, and the test files of the repository that import or run it. Nothing in them is run (Rule 1), and a file the change does not edit is not read.

**Provider facts:** none.

**Fails when:**

- `structure.non-hcl-logic-error`: a line the change adds or edits fails, on reading, for an input the code handles: it raises, returns the wrong value, writes the wrong file or exits with the wrong status, where the input comes from the arguments the `.tf` lines pass, the files the code reads or the environment it runs in. A path, platform or version the code does not claim to handle is no input it handles. One finding per pattern, naming each of its lines.
- `structure.non-hcl-unsafe-subprocess`: a line the change adds or edits starts a process through a shell with a value it does not quote, such as `shell=True`, `os.system` or a command string built from a value, or passes a value as an option where a file name is meant, when that value comes from a module input, a file name in a tree the module packages, or the environment.
- `structure.non-hcl-test-missing`: the change alters what such a file does for an input it already handled, the repository has a test file that imports or runs the file, and no test covers the altered behaviour at the head. A change with no test file for the code at all is not this rule, and neither is a change that alters no behaviour, such as a comment, a log message or a rename.

Naming, formatting and the idiom of the language are not judged, and neither is a choice of library.

**Severity:**

- `structure.non-hcl-logic-error`: HIGH, the feature that does not work of [Severity Levels](output.md#severity-levels), when every caller of the module that runs the code reaches the failing input, such as a packaging step that now fails for the default arguments; MEDIUM when only some callers reach it, such as one runtime or one option of the packaging step.
- `structure.non-hcl-unsafe-subprocess`: CRITICAL when a module input or a file name a caller controls reaches the shell unquoted; HIGH when only the environment the module runs in does.
- `structure.non-hcl-test-missing`: LOW. It helps the author and never blocks, and a follow-up is an acceptable answer.

## Suggested Fixes

| `rule_id` | Fix |
|-----------|-----|
| `structure.non-hcl-logic-error` | Name the input and the line, and the change that handles it, such as a guard, a default or the corrected expression. |
| `structure.non-hcl-unsafe-subprocess` | Pass the command as a list with no shell, or quote the value for the shell, and end options with `--` before a file name. |
| `structure.non-hcl-test-missing` | Add a case to the existing test file named in the summary for the altered input. |
