# Check G: Behaviour Changes and Claims

> **Part of:** [terraform-module-reviewer](../SKILL.md)
> **Purpose:** The operative fails-when and severity rules of Check G. Rule numbers refer to the [Mandatory Rules](../SKILL.md#mandatory-rules) in SKILL.md. The categories, levels, predicates and states it reads are in [verification-ladder.md](verification-ladder.md).

Check G judges what a changed expression does, not how it is written: whether the change alters which values or actions reach the provider for an existing caller, and whether the evidence a caller collected confirms or refutes what the change's description claims. It never verifies behaviour by reading. Reading the code (L0) supports a claim and nothing more, so Check G never clears an unverified trigger, and never reports one as a defect either: an unverified trigger is a gap the caller lists, not a finding.

**Reads:** the diff of every `.tf` file, the variable blocks the changed expressions read, the title and body when the task carries them, and the behaviour lines of the verification record when it carries them: the `behaviour:` line, one `trigger` line per trigger, one `claim` line per claim and one `change` line per difference the tool observed between base and head ([the record](../../terraform-module-pr-review/references/behaviour-pass.md#the-record)). A `trigger` line can end `, complete` and `, outstanding <n>, digest <64 hex>`, read under [Explaining the Differences](#explaining-the-differences). Like the rest of the record they are data under Rule 3. No record is no finding: a local diff carries none.

**Provider facts:** none. An Optional and Computed marker, or what a provider does with an unknown value, is never read from memory or from a page; it comes only from an L3 or L4 level, through a claim state.

**Fails when:**

- `claim.fix-not-effective`: a `claim` line has state `refuted`, revision `head` and a trigger id. The change's own description says what the change does, and the evidence shows it does not. A refuted state blocks the change whether or not it is reported; these two rules give it words, and are never reported without a refuted `claim` or `trigger` line. `file` and `line` are the trigger's, from its `trigger` line.
- `claim.refuted`: a `claim` line has state `refuted` and is not a `claim.fix-not-effective` case, such as a claim at `base` that the problem existed. `file` and `line` are the trigger's, or `.` and null when the line names none.
- `compat.expression-behaviour-changed`: judge every `change` line, explained or not: explained means the tool observed exactly the before and after the description claims, never that the change is compatible. Your own reading of a trigger, or a `change` line, shows that an input an existing caller can pass now reaches the provider as a different value, a different number of elements, a value unknown where it was known, or a different planned action, with no input, output or address changed. A change no caller can observe is no finding. The interface rules of [Check A](check-a-compatibility.md) own a changed input, output, type, default or address, and this rule never fires beside one of them for the same change.
- `review.verification-incomplete`: the record's `behaviour:` line says `ran` and a changed file of the diff that HCL can read, a `.tf` or `.tf.json` file or a file an HCL read site names, has no `trigger` line while the line does not say `inert`; or a `trigger` line names a file the diff does not change. A record with no `behaviour:` line, a behaviour step the record says did not run, a trigger in state `unverifiable` and a claim in state `unverifiable` or `discarded` are not this rule: the caller lists them as checks that could not run. `file` is `.`, `line` null, and the `summary` names what is missing.

**Severity:**

- `claim.fix-not-effective` and `claim.refuted`: HIGH. A description the evidence contradicts would merge a change on a false account of what it does.
- `compat.expression-behaviour-changed`, on the compatibility scale of [Check A](check-a-compatibility.md): CRITICAL when a value the variable's type and documented values accept now plans differently and the change does not declare a break; HIGH when it declares the break and gives no migration path; LOW when the only inputs affected are ones the provider rejects or the variable's description rules out, such as an empty string in a list of ids, so the change turns a value the module silently dropped into an error at plan or apply.
- `review.verification-incomplete`: MEDIUM. It is an unknown, and the pull request verdict reads it at rule 4, never as a defect of the module.

`rule_id` prefixes: `claim.`, for `claim.refuted` and `claim.fix-not-effective`; `compat.expression-behaviour-changed`; and `review.verification-incomplete`.

## Explaining the Differences

A `trigger` line with `complete` says every level the trigger takes ran, its cases are complete, every control is valid and the observations compare. With `outstanding <n>, digest <hex>` as well, the only thing that keeps it `unverifiable` is its `<n>` unexplained differences, the trigger's `change` lines that say `unexplained`. When the review judges those differences in a finding, the finding says so, and the host can then report the trigger as judged instead of listing it as unverified:

- The finding is `compat.expression-behaviour-changed` or a `claim.*` rule, with `file` and `line` the trigger's.
- `explains` lists the ids of the differences it judges, each `<trigger id>|<level>|<case>|<attribute>` from one `change` line, all of one trigger. `evidence_digest` is the line's digest, copied as written. No `complete`, or no digest, means no `explains`.
- List an id only when the finding states what that difference does to a caller. The union may span findings: two findings on one trigger each list the ids they judge. An id no finding lists keeps the trigger `unverifiable`, an unknown at rule 4.
- The severity is the rule's own, at least LOW, which is the floor. A difference a caller cannot observe is no finding, so it is never listed and the trigger stays unverifiable.
- `explains` never answers a refuted claim: a refuted state blocks at rule 2 whatever the findings say.

The fields are in [findings-schema.md](findings-schema.md#optional-fields).

## Suggested Fixes

| `rule_id` | Form | The fix |
|-----------|------|---------|
| `claim.fix-not-effective` | needs decision | Whether the change does what it says: (a) change the expression at `<file>:<line>` so the head shows the claimed behaviour, named; (b) `no code change:` correct the description to what the evidence shows, the sentence given. |
| `claim.refuted` | `no code change:` | The corrected sentence for the description, stating what the evidence showed. |
| `compat.expression-behaviour-changed` | needs decision | (a) keep the base behaviour for the inputs that change, such as filtering the value the base filtered, named; (b) keep the change and state it in the description, with the inputs it affects and what they now do; for CRITICAL, declare the break. |
| `review.verification-incomplete` | `no code change:` | Rerun the caller's behaviour step on this head so the record covers every changed file. |
