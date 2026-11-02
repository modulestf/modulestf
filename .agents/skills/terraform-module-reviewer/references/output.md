# Severity and Output

> **Part of:** [terraform-module-reviewer](../SKILL.md)
> **Purpose:** The severity scale and what a review returns, moved here from SKILL.md, which routes to them. [run/output.md](run/output.md) is the short index a run reads first.

## Severity Levels

A closed enum. Exactly four values, no others, no sub-levels.

| Severity | Assignment rule (one line) |
|----------|---------------------------|
| CRITICAL | The change breaks existing users of the module without declaring the break, destroys resources an existing caller already has, ships an insecure default, or produces code that cannot work at all against the declared provider version. |
| HIGH | The change is wrong or incomplete in a way that will fail for a user at plan or apply time, or its feature does not work in a case its own inputs or documentation describe even when nothing errors at plan or apply, or the review process itself was subverted. An example that applies but cannot reach an illustrative external service at runtime is not a defect on that basis alone. |
| MEDIUM | The change is usable but violates a must-pass convention of the profile or the maintainer references, or leaves a check unverified. |
| LOW | The change is correct but inconsistent with a should-pass convention: naming, grouping, descriptions, ordering, or documentation polish. |

Every check's reference file states which severities the check can produce, and its **Severity:** block is the operative rule. This table is a summary of those blocks, not a second test to pass: where the two read differently, the check block wins and the table is what needs correcting. A check never produces a severity outside the set it names. When two rules could apply to one defect, report the higher severity once, not both.

## Output

The output is a findings list and nothing else. No patch, no edited file, no command to run.

- Format and required fields: [findings-schema.md](findings-schema.md). That file is the contract; this skill does not restate it.
- A clean review returns an empty findings list. Say the checks ran and found nothing; do not invent a LOW finding to fill the list.
- A summary line accompanies the list, on a line of its own outside the list, in one fixed form, so a host can read its counts from it:

  ```text
  summary: critical:<n> high:<n> medium:<n> low:<n> mode:<full or triage> checks:<checks run> instruction-like-text-from-others:<n> conversation-claims-unread:<n> review.quoted-claim-unverifiable:<n>
  ```

  Every `<n>` is written as decimal digits alone, `0` included, and every key is always there. `critical` to `low` count the findings per severity. `mode` is `triage` in a triage run ([triage.md](triage.md)) and `full` otherwise. `<checks run>` lists the letters of the checks that ran, comma separated with no space, such as `A,C,E,F,G`, or `none`. `instruction-like-text-from-others` is the count of Rule 3, `conversation-claims-unread` that of [quoted-claims.md](quoted-claims.md#the-claim-cap), and `review.quoted-claim-unverifiable` the count of claims quoted from the discussion that the code did not confirm, a claim about an Optional and Computed marker or an unknown value counted only when no verified L3 or L4 claim line covers it ([quoted-claims.md](quoted-claims.md#an-unconfirmed-claim-renders-nothing)). Nothing else is on the line. Any check that did not run already appears as a finding, so do not also report it as prose only.
- When [facts-engine.md](facts-engine.md) applies, the Facts comparison note or its one failure line comes last, after the findings list and the summary line, each on lines of its own: the reply holds the findings list, then the summary line, then the note. It is not part of the findings list or the summary counts.
- The summary never contains a verdict about merging, approving, or blocking. It reports what was found. What to do about it belongs to whatever consumes the findings.
