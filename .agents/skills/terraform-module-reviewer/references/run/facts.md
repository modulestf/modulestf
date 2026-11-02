# Run Index: mtf-facts

> **Part of:** [terraform-module-reviewer](../../SKILL.md), [facts-engine.md](../facts-engine.md)
> **Purpose:** What a run does with `mtf-facts`, in order, each step linking the section of [facts-engine.md](../facts-engine.md) that rules it. Open that section when a step is unclear; this file holds no rule of its own.

1. Find the binary outside the workspace, or do nothing and write nothing about it: [When to run](../facts-engine.md#when-to-run).
2. Pick the base input, the first that applies ([The base tree](../facts-engine.md#the-base-tree)):
   - the task's `Diff: <path>` line: pass the path to `--diff` as given, read in place, never copied or written;
   - a merge base from the task's `Merge base: <sha>` line, or a base reference: extract it to a new temporary directory with the script of that section and pass `--base`;
   - neither: run with no `--base` and no `--diff`.
3. Run it once, after Step 1 and before Check A ([Command](../facts-engine.md#command)):

   ```sh
   mtf-facts lint <workspace> [--base <base-dir> | --diff <file>] --json --ai --timeout 60s \
     --registry <this skill>/references/rule-facts.md \
     --head-sha <git rev-parse HEAD> [--merge-base-sha <the task's Merge base>] \
     --profile-dir <maintainer skill>/profiles/terraform-aws-modules
   ```

   The `Provider fact sheets:` directory is no input of `mtf-facts`: never pass it as `--schema-files` or `--schema-handoff`. The schema rules then stay `not_evaluated(schema_unavailable)` and the checks read the sheets as the [Budget](../large-changes.md#budget) says.
4. Exit 0, 1 or 3 with a report that counts: read it ([Reading the report](../facts-engine.md#reading-the-report)). A finding or candidate makes its rule's run summary row hold ([Reading by Depth](../../SKILL.md#reading-by-depth)); decide each candidate as [Deciding candidates](../facts-engine.md#deciding-candidates) says. No rule is skipped for a `clean` entry.
5. Exit 2, a timeout or a report that does not count: one line, no finding ([Failure](../facts-engine.md#failure)).
6. After the findings: the note ([Facts comparison](../facts-engine.md#facts-comparison)), with the version and hash of what ran ([Pinning what ran](../facts-engine.md#pinning-what-ran)), written where [run/output.md](output.md) says.
