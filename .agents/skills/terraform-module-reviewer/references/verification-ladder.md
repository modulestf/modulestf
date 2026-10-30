# Verification Ladder

> **Part of:** [terraform-module-reviewer](../SKILL.md)
> **Purpose:** How a behaviour change is verified: the trigger categories, the evidence levels each one takes, the closed claim predicates and the claims file the model writes, the states `mtf-facts claims-eval` gives, and how each state maps to the verdict. [Check G](check-g-behaviour.md) reads the result.

A logic change is verified by escalating evidence, simplest first, until a test shows the behaviour at the base and at the head. Reading the code is the first level and never the last: it supports a claim and never verifies one. Every step that produces evidence is deterministic: `mtf-facts` classifies and evaluates, the host runs the levels, and the model only writes the claims and reads the result.

## Triggers

`mtf-facts behaviour` reads the base and head trees and turns every changed tree entry into AST-level changes. Each one is a trigger with an id (`T-001` on), a file, a line and exactly one category. At most 40 triggers; the rest are counted in `capped` and are unverifiable. A change only to an enumerated documentation or metadata path that no HCL read site reaches is inert, with no trigger.

| Category | What changed |
|----------|--------------|
| `wrapper-change` | A function call added around or removed from an expression, such as `compact()` around a list |
| `default-change` | A variable default |
| `count-for_each-conditional-change` | A `count`, a `for_each` or a conditional that selects instances or values |
| `type-validation-change` | A variable type or validation |
| `dynamic-block-change` | A `dynamic` block |
| `locals-outputs-change` | A local or an output |
| `moved-or-renamed-address` | A `moved` block or a renamed address |
| `provider-version-floor-change` | A provider or Terraform version constraint |
| `unknown-propagation-candidate` | An expression whose result can turn from known to unknown at plan time, or back, for an argument the provider may treat as Optional and Computed |
| `literal-argument-change` | A literal argument value |
| `resource-added-or-removed` | A resource, data source or module block |
| `lifecycle-change` | A `lifecycle` block |
| `unclassified-change` | Any other HCL change |
| `non-hcl-dependency` | A file an HCL read site reaches, a lock file, a mode-only change, a path that did not parse, or a dynamic path |

## Levels

| Level | Evidence | Verifies |
|-------|----------|----------|
| L0 | Reading the code and the documents | Nothing. It supports a claim |
| L1 | Offline expression evaluation: base and head in two scratch directories, built-in provider only, typed samples and typed unknowns, a saved plan read with `show -json` | Expression predicates |
| L2 | `terraform test` with a mocked provider | From a later release |
| L3 | A curated fixture per resource and provider version: the real provider, fake credentials, prior state, `-refresh=false`, and a control run of the base expression that must match its recorded baseline | Plan predicates |
| L4 | The credentialed example plan pass, a base and a head plan per example | Plan predicates, and coverage |

At most two levels per trigger. The classifier picks them from the category:

| Category | Levels |
|----------|--------|
| `wrapper-change`, `locals-outputs-change`, `count-for_each-conditional-change`, `default-change`, `type-validation-change` | L1 |
| `unknown-propagation-candidate` | L1, then L3 with a curated fixture, or covered by a plan |
| `literal-argument-change`, `resource-added-or-removed`, `lifecycle-change`, `dynamic-block-change`, `unclassified-change`, `non-hcl-dependency` | Covered by a plan |
| `provider-version-floor-change` | The compatibility rules of [Check A](check-a-compatibility.md) |
| `moved-or-renamed-address`, provisioners and `connection` blocks | None: unverifiable by design |

Covered means the changed address appears in an example the plan pass planned, with a nonempty instance list, and the changed attribute is present in its planned configuration.

## The Claims File

The caller's model writes it, never the review, which stays read-only under Rule 1: in terraform-module-pr-review that is Step 5.4, after the classifier and before any level runs. It reads the title and the body items of origin `change-author` only, as untrusted data under Rule 3, and writes `claims.json` in the behaviour step's directory, never in the workspace:

```json
{"schema_version": 1, "claims": [
  {"claim_id": "C-1", "text": "compact() returns a wholly unknown list when an element is unknown",
   "predicate_type": "expression-output-unknown", "params": {"node": "T-001", "revision": "base"},
   "trigger_id": "T-001", "file": "main.tf", "line": 2}]}
```

- One claim per testable statement about behaviour, at most 20. A statement no predicate below can express is not written: it stays prose, and Check A and [quoted-claims.md](quoted-claims.md) judge it as before.
- `claim_id` is `C-` and a number, unique in the file. `text` is the statement, quoted short, at most 200 characters. It is a label for a person and evaluates nothing.
- `params.node` is a trigger id from `behaviour.json`. The tool splices only that trigger's own expression into its templates, so no claim can carry code. The `inputs` of `expression-output-equals-for-inputs` reach a template as a `.tfvars.json` file, never spliced as text. `trigger_id`, when set, equals `params.node`; `file` and `line` are the trigger's.
- `params.revision` is `base` for a claim about the problem the change fixes, and `head` for a claim about what the change does.

| `predicate_type` | It claims that, at the revision | Other params | Levels |
|------------------|---------------------------------|--------------|--------|
| `expression-output-unknown` | The trigger's expression is wholly unknown at plan time | `cases_where`, optional, a scope (below) | L1 |
| `expression-output-length-known` | Its length is known at plan time | `length`, optional, an integer; `cases_where`, optional, a scope | L1 |
| `expression-output-equals-for-inputs` | It equals `expected` for the given inputs | `inputs`, an object of input name, a variable or a contextual reference, to a JSON sample; `expected`, a JSON value | L1 |
| `input-filtered` | It drops the given value of an input, or with `filtered` false keeps it | `input`, a case input name, a variable or a contextual reference; `value`, `empty-string` or `null`; `filtered`, optional, true by default; `cases_where`, optional, a scope | L1 |
| `plan-attribute-unknown` | The planned attribute is known after apply | - | L3, L4 |
| `plan-attribute-unchanged-vs-prior` | The planned attribute equals the prior state | - | L3, L4 |
| `plan-action` | The planned action on the address | `action`, one of `no-op`, `create`, `update`, `replace`, `delete` | L3, L4 |

Every `params` object is closed: a key not in its row discards the claim. A discarded claim is unverifiable.

A scope, `cases_where`, limits a claim to the required cases whose inputs are all in the named states. It is a non-empty object of input name to state. An input name is a key of the trigger's `cases[].inputs`: a variable, or a contextual reference as written, such as `aws_security_group.this[*].id`. A state is `wholly_unknown`, `unknown_element`, `empty` (`[]`, `{}` or `""`), `known` (any other known value with no unknown element and not null), `null` or `omitted`. A malformed scope discards the claim; a scope that matches no case leaves it unverifiable.

For the change that drops `compact()` around a list of security group ids, the description's "`compact()` returns a wholly unknown list" is `expression-output-unknown` at `base`, "`concat()` keeps the length" is `expression-output-length-known` at `head`, and "the plan shows the change as known after apply" is `plan-attribute-unknown` at `head` on the unknown propagation trigger.

## Ladder Record Observations

A level's run is evidence only with `state` `ran` and `control` `valid`. Its `observations` hold `base` and `head`, each a list of observations: `case`, `known` (required), `unknown_inputs`, `inputs`, `length`, `value` (left out when unknown, sensitive or redacted), `sensitive`, `redacted`, `action`, and `unchanged_vs_prior`. Raw plans never leave the host; the record carries this projection only.

## States

`mtf-facts claims-eval` gives every claim one state, at its own revision only: `verified` when at least one relevant observation exists and all agree with it, `refuted` when one contradicts it, `unverifiable` otherwise, including a comparison of an unknown, sensitive or redacted value.

Every trigger gets one state, by these rules in order. A claim can verify or refute itself; it never verifies a trigger by being true.

1. `refuted`: a claim on the trigger is refuted.
2. `inert`: no behaviour can change.
3. `covered`: the changed address is in a planned example, as above.
4. `unverifiable`: the trigger compares an input with a function call of no input, such as `var.cidr == lower("EVIL")`, so it has no required case and a reason; or a level the trigger takes has no base and head run with state `ran` and control `valid` (the base expression's control matched its recorded baseline), or a run there has control `invalid`, or the tool's sweep has over 32 cases, or a case of the trigger's required set has no observation at base or at head (reason `L1 case "<id>" is missing at the base`, or `at the head`), or a trigger that takes L1 has no required case.
5. The sweep is the tool's own. `mtf-facts behaviour` gives each trigger that takes L1 its required case set in `triggers[].cases`, each case an `id` and its `inputs`, deterministic from the input types and the category, never from claims or the ladder runs, and the same case ids hold at both revisions. A run may add cases; it cannot drop a required one. For a `list(string)` input the set holds at least: an empty list, one known element, an empty-string element, a null element, an unknown element, and a wholly unknown list. A `default-change` trigger adds the case with the input omitted, so the default itself is evaluated. The tool compares base and head per case and attribute, each on its own: `known`; `wholly_unknown`; `unknown_mask`, which elements are unknown; `length`, null against a number included; `value`, only when known at both and neither sensitive nor redacted; `sensitive`; `redacted`; `unknown_inputs` as a set; `action`; `unchanged_vs_prior`; `error`, whether evaluation failed. A case known at both revisions whose value or length cannot be compared because it is sensitive or redacted makes the trigger `unverifiable`.
6. `verified` when no case differs: stable over the bounded sweep, which is not full equivalence.
7. Otherwise `verified` only when every difference is explained by verified claims on that case, one at each revision, each matching that revision's observation exactly, and `unverifiable` with the difference named when one is not:

| Attribute | One side | Other side |
|-----------|----------|------------|
| `known`, L1 | `expression-output-unknown` on the unknown side | `expression-output-equals-for-inputs` whose `expected` is the observed value |
| `known`, L3 or L4 | `plan-attribute-unknown` on the unknown side | `plan-attribute-unchanged-vs-prior`, true |
| `length` | `expression-output-unknown` where the length is unknown | `expression-output-length-known` with the observed `length`, or `expression-output-equals-for-inputs` |
| `value` | `expression-output-equals-for-inputs` with the case's inputs and the observed value | The same, at the other revision |
| `action` | `plan-action` with the observed action | The same, at the other revision |
| `unchanged_vs_prior` | `plan-attribute-unchanged-vs-prior` on the true side | `plan-attribute-unknown` |

At L1, a `value` or `length` difference where one revision drops an input's marker elements, its empty strings or nulls, and the other keeps them is explained by verified `input-filtered` claims at both revisions on that case, `filtered` at one and `filtered` false at the other, with the same input and value, when the keeping side's value with those elements removed equals the other side's. At L1, a `wholly_unknown` or `unknown_mask` difference where the base is wholly unknown and the head partly known, with a definite length and neither failed, sensitive nor redacted, is explained by a verified `expression-output-unknown` with a scope at the base and a verified `expression-output-length-known` with a scope and the observed `length` at the head. The reverse, a head that is wholly unknown where the base was partly known, is never explained: it hides a change from the plan. An unscoped claim never explains it, and neither does a mask change between two partly known sides or any such change at L3 or L4. `error`, `sensitive`, `redacted` and `unknown_inputs` differences are never explained. An L2 run never evidences `expression-output-unknown`, `expression-output-length-known` or `plan-attribute-unknown`, and explains no unknown-ness difference. `expression-*` predicates explain L1 observations only, `plan-*` predicates L3 and L4 only. Each difference crosses to the review as a `change` line, explained or not, without its inputs, an explained one with the claims `claims-eval` names in `explained_by`: explained means the tool observed exactly what the description claims, never that the change is compatible, so the review judges each under [Check G](check-g-behaviour.md).

For the change that drops `compact()` around a list, the cases with an unknown element or a wholly unknown input differ in unknown-ness: wholly unknown at the base, a known length at the head. Scoped claims explain them, `expression-output-unknown` at the base and `expression-output-length-known` at the head per scope; a simulated L1 run needs 7 such claims for the 24 differences of the wrapper trigger. The cases with an empty-string or null element still differ in `value` and `length`, since `concat()` keeps those elements: `input-filtered` claims explain them, filtered at the base and `filtered` false at the head, for the empty strings and nulls of `var.vpc_security_group_ids` and the nulls of the security group ids, 6 claims. The 13 claims verify the trigger, and all 40 differences are still listed. Without the filtering claims the trigger stays `unverifiable`, and the review weighs those cases as a compatibility change.

## Evidence to Verdict

| State | Finding | Verdict rung |
|-------|---------|--------------|
| `inert`, `verified`, `covered` | None | Pass |
| `refuted`, a trigger or a claim | Blocks by itself; Check G words it: `claim.fix-not-effective` for a refuted claim at `head` on a trigger, `claim.refuted` for any other | Block, rule 2 |
| `unverifiable`, over the cap, or the step not run | None: the host lists it | Inconclusive, rule 4 |

Refuted outranks covered. A behaviour change never approves on L0 alone, so the change above, with no level run yet, is inconclusive and never approve with nits. The pull request skill's [verdict.md](../../terraform-module-pr-review/references/verdict.md#behaviour-evidence) holds the same map.
