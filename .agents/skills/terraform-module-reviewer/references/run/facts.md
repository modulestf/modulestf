# Run Index: Facts

> **Part of:** [terraform-module-reviewer](../../SKILL.md), [facts-engine.md](../facts-engine.md)
> **Purpose:** What a run does with `mtf-facts` and with host fact sheets, each step linking the section that rules it. Open that section when a step is unclear; this file holds no rule of its own.

## mtf-facts

1. Find the binary outside the workspace, or do nothing and write nothing about it: [When to run](../facts-engine.md#when-to-run). Take the profile snapshot first, or refuse: [The snapshot](../profile-selection.md#the-snapshot).
2. Pick the base input, the first that applies ([The base tree](../facts-engine.md#the-base-tree)):
   - the task's `Diff: <path>` line: pass the path to `--diff` as given, read in place, never copied or written;
   - a merge base from the task's `Merge base: <sha>` line, or a base reference: extract it to a new temporary directory with the script of that section and pass `--base`;
   - neither: run with no `--base` and no `--diff`.
3. Run it once, after Step 1 and before Check A ([Command](../facts-engine.md#command)):

   ```sh
   mtf-facts lint <workspace> [--base <base-dir> | --diff <file>] --json --ai --timeout 60s \
     --registry <this skill>/references/rule-facts.md \
     --head-sha <git rev-parse HEAD> [--merge-base-sha <the task's Merge base>] \
     --profile-dir <profile snapshot> \
     [--schema-handoff <the task's Schema handoff>]
   ```

   Read the report from its standard output; it is never written to a file, so the run writes nothing beyond the `Output:` files.

   Pass `--schema-handoff` only with the path of the task's `Schema handoff: <path>` line, and on exit 2 run once more without it ([Command](../facts-engine.md#command)). The `Provider fact sheets:` directory is no input of `mtf-facts`: never pass it as `--schema-files` or `--schema-handoff`. Without a handoff, or with one that does not cover the run, the schema rules stay `not_evaluated(schema_unavailable)` and the checks read the sheets as the [Budget](../large-changes.md#budget) says.
4. Exit 0, 1 or 3 with a report that counts: read it ([Reading the report](../facts-engine.md#reading-the-report)). A finding or candidate makes its rule's run summary row hold ([Reading by Depth](../../SKILL.md#reading-by-depth)); decide each candidate as [Deciding candidates](../facts-engine.md#deciding-candidates) says. No rule is skipped for a `clean` entry.
5. Exit 2, a timeout or a report that does not count: one line, no finding ([Failure](../facts-engine.md#failure)).
6. After the findings: the note ([Facts comparison](../facts-engine.md#facts-comparison)), with the version and hash of what ran ([Pinning what ran](../facts-engine.md#pinning-what-ran)), written where [run/output.md](output.md) says.

## Fact Sheets

From the task's `Provider fact sheets: <dir>` line, for the types the need list fixes ([Host fact sheets](../large-changes.md#budget)):

- `<ns>/<name>/<version>/index.json` gives each `<resource|data>:<type>` as `sheet`, `absent` or `page`. A `sheet` with `same_as` naming a version is read from that version's sheet, whose `versions:` line lists every version it covers: never fetched.
- Deep: `missing.json` lists the types with no sheet and their versions. Only those go to the fetch helper.
- A type that is `page` at any version reads pages at all of them, through the fetch helper, never in the run's own context.
- A latest version's sheet may end with an `introduced:` section: the first version that has each path, from its `since` line. Only an `unresolved` line, or an argument with no line of its own (the section's `since: <n> more paths unresolved overflow` count line stands for it), goes to the fetch helper ([Introduced versions](../large-changes.md#budget)).
