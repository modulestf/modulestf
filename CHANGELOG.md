# [0.2.0](https://github.com/modulestf/modulestf/compare/v0.1.2...v0.2.0) (2026-11-06)


### Features

* **pr-review:** runner providers, CI job-less runs, embedded-code rule, test pass ([#110](https://github.com/modulestf/modulestf/issues/110)) ([a7f2368](https://github.com/modulestf/modulestf/commit/a7f23682bb60702b45bdbd976e62bd64a54468b7)), closes [terraform-aws-modules/terraform-aws-notify-slack#283](https://github.com/terraform-aws-modules/terraform-aws-notify-slack/issues/283)



## [0.1.2](https://github.com/modulestf/modulestf/compare/v0.1.1...v0.1.2) (2026-11-04)


### Bug Fixes

* **pr-review:** review an empty-base pull request as a new module; clamp own pull request to COMMENT ([#106](https://github.com/modulestf/modulestf/issues/106)) ([07037f8](https://github.com/modulestf/modulestf/commit/07037f85791d9b5aee9378686bb1562c484e3fc5))



## [0.1.1](https://github.com/modulestf/modulestf/compare/v0.1.0...v0.1.1) (2026-11-04)


### Bug Fixes

* **pr-review:** count many unverified behaviour changes per category in section 5 ([#104](https://github.com/modulestf/modulestf/issues/104)) ([a874f41](https://github.com/modulestf/modulestf/commit/a874f41434c409b31d52e264e8fd55792911ec59))



# [0.1.0](https://github.com/modulestf/modulestf/compare/v0.1.0-rc.5...v0.1.0) (2026-11-04)


### Bug Fixes

* **pr-review:** link behaviour change, refuted and thread locations to the repository ([#99](https://github.com/modulestf/modulestf/issues/99)) ([512917d](https://github.com/modulestf/modulestf/commit/512917dc0ec3b647a1a8ffdd295eb5493076bfee))
* **reviewer:** name the sibling count case under structure.input-ignored-in-branch ([#98](https://github.com/modulestf/modulestf/issues/98)) ([d095fc9](https://github.com/modulestf/modulestf/commit/d095fc966d9db3f85cb7cfb7ffe488d622d6629e))


### Features

* install the skills as a Claude Code or Codex plugin, `modulestf`, from the [antonbabenko/agent-plugins](https://github.com/antonbabenko/agent-plugins) marketplace
* install `mtf-facts` with Homebrew: `brew install modulestf/tap/mtf-facts`
* **review:** link locations to the reviewed repo, backtick code in findings, keep merge base ([#97](https://github.com/modulestf/modulestf/issues/97)) ([7433dac](https://github.com/modulestf/modulestf/commit/7433dacde89c63b8b34bdda10b753577cdaaf8dd))

# [0.1.0-rc.5](https://github.com/modulestf/modulestf/compare/v0.1.0-rc.4...v0.1.0-rc.5) (2026-11-03)


### Features

* **ladder:** null base for an added attribute; no data source at L3 ([#95](https://github.com/modulestf/modulestf/issues/95)) ([8a6f8eb](https://github.com/modulestf/modulestf/commit/8a6f8eb27cc948a96808b50100deb3281477cbf5))
* **plan-pass:** fixed-target data sources and provider flags in laptop G3; check data source regions ([#96](https://github.com/modulestf/modulestf/issues/96)) ([1ec765d](https://github.com/modulestf/modulestf/commit/1ec765d129e27081bd27a5ab332751f347a1a8ed))

# [0.1.0-rc.4](https://github.com/modulestf/modulestf/compare/v0.1.0-rc.3...v0.1.0-rc.4) (2026-11-03)


### Bug Fixes

* **plan-pass:** refuse a keyword written against its label and hidden heredoc ends in the gates ([#94](https://github.com/modulestf/modulestf/issues/94)) ([3d556ba](https://github.com/modulestf/modulestf/commit/3d556ba8dc8126bf4cec4466fc427e70b0aff10e))
* **review:** bind the schema handoff to a module root below the repository root ([#93](https://github.com/modulestf/modulestf/issues/93)) ([10c75b6](https://github.com/modulestf/modulestf/commit/10c75b6d23831602238f7fed5955590571e6f02c))

# [0.1.0-rc.3](https://github.com/modulestf/modulestf/compare/v0.1.0-rc.2...v0.1.0-rc.3) (2026-11-03)


### Bug Fixes

* rate dropped null and empty ids LOW, word compat items neutrally ([#87](https://github.com/modulestf/modulestf/issues/87)) ([7efea17](https://github.com/modulestf/modulestf/commit/7efea1775c9a8bc4676b2773993536c8e095aa2a))
* **review:** banded severity for claim-contradicts-analysis, short length targets for the reviewer, root-level checklist wording ([#85](https://github.com/modulestf/modulestf/issues/85)) ([3803922](https://github.com/modulestf/modulestf/commit/38039224c9a69ec93ff77f41abc9e31147ddebd1))
* **review:** hold the review comment to its size: assessment 700, summary 500, fix 600 characters ([#83](https://github.com/modulestf/modulestf/issues/83)) ([a408c26](https://github.com/modulestf/modulestf/commit/a408c26ff57b9260a2a76a93b43c04aee60c522f)), closes [terraform-aws-modules/terraform-aws-rds-aurora#556](https://github.com/terraform-aws-modules/terraform-aws-rds-aurora/issues/556) [terraform-aws-modules/terraform-aws-cloudwatch#88](https://github.com/terraform-aws-modules/terraform-aws-cloudwatch/issues/88)
* **review:** reachable COMPACT tier and a shorter STANDARD body ([#86](https://github.com/modulestf/modulestf/issues/86)) ([f0b7103](https://github.com/modulestf/modulestf/commit/f0b7103c7f5934b717d3c372578aab26ed1d5446))
* **review:** say in plain words why an example was not planned and who acts ([#88](https://github.com/modulestf/modulestf/issues/88)) ([b98d2d8](https://github.com/modulestf/modulestf/commit/b98d2d8275352eb01cfc0e92198338a4f0ffc1bd))


### Features

* depth-gated pull request review with one run script ([#90](https://github.com/modulestf/modulestf/issues/90)) ([8c97301](https://github.com/modulestf/modulestf/commit/8c97301917be1fb2b97a149b2a1f860537e52b2f))
* **review:** compact review comment for small changes, the reported trigger state, one-screen unknowns ([#84](https://github.com/modulestf/modulestf/issues/84)) ([09892ba](https://github.com/modulestf/modulestf/commit/09892ba47939ac01e0ffc6fcabc6372c6ad50793))
* **review:** count a safety-gate skip as covered when the changed code was planned elsewhere ([#89](https://github.com/modulestf/modulestf/issues/89)) ([b3f74cf](https://github.com/modulestf/modulestf/commit/b3f74cfa4a22d70c4f5e7fec4120ee8849488953))
* **review:** pass the schema handoff to the facts engine ([#92](https://github.com/modulestf/modulestf/issues/92)) ([0cb19ec](https://github.com/modulestf/modulestf/commit/0cb19eccddb5e9ae004ccd742e6015d02b342629))
* **review:** rate a fix that makes an ignored input take effect LOW ([#91](https://github.com/modulestf/modulestf/issues/91)) ([74c7f78](https://github.com/modulestf/modulestf/commit/74c7f78f53857d0385fd044d97309d9072562777))

# [0.1.0-rc.2](https://github.com/modulestf/modulestf/compare/v0.1.0-rc.1...v0.1.0-rc.2) (2026-10-31)


### Bug Fixes

* **review:** give L3 its own cases, pass the schema to the classifier, raise the claims cap ([#81](https://github.com/modulestf/modulestf/issues/81)) ([4ed569b](https://github.com/modulestf/modulestf/commit/4ed569b970d67996829f1082948458f96fa53f2d)), closes [terraform-aws-modules/terraform-aws-rds-aurora#556](https://github.com/terraform-aws-modules/terraform-aws-rds-aurora/issues/556)

# [0.1.0-rc.1](https://github.com/modulestf/modulestf/compare/fd8dfa469727b9137e757b84c3d28b6b87cf962d...v0.1.0-rc.1) (2026-10-31)


* feat!: select examples by what a change affects, bound verification, report plan coverage (#72) ([d220523](https://github.com/modulestf/modulestf/commit/d220523ca6f8702339e070c22391ef751272dfbb)), closes [#72](https://github.com/modulestf/modulestf/issues/72)


### Bug Fixes

* accept the claims-eval capped count and its three new change attributes ([#74](https://github.com/modulestf/modulestf/issues/74)) ([d00b318](https://github.com/modulestf/modulestf/commit/d00b318ae737ddd86460f50856ce0be1d1cc965f))
* reviewer rules and facts-engine docs after a pull request review ([#70](https://github.com/modulestf/modulestf/issues/70)) ([fd8dfa4](https://github.com/modulestf/modulestf/commit/fd8dfa469727b9137e757b84c3d28b6b87cf962d))


### Features

* add a What to do section to the review comment, read the AI facts report ([#71](https://github.com/modulestf/modulestf/issues/71)) ([2a7aa78](https://github.com/modulestf/modulestf/commit/2a7aa789c934b6860885fc16af2cb21f643a1781))
* ladder level L1 evaluates changed expressions in a sandbox ([#75](https://github.com/modulestf/modulestf/issues/75)) ([5751ad7](https://github.com/modulestf/modulestf/commit/5751ad7caf1b4821f7b80d8e334b3755ecf64f82))
* ladder level L2 checks count and for_each logic with plan-only tests ([#78](https://github.com/modulestf/modulestf/issues/78)) ([fff3aab](https://github.com/modulestf/modulestf/commit/fff3aabd776cc1d4a8b0b17e819b7412e4d05973))
* ladder level L3 plans a curated provider fixture with a prior state and a control ([#76](https://github.com/modulestf/modulestf/issues/76)) ([8bafb26](https://github.com/modulestf/modulestf/commit/8bafb26ec71ac7ac423b9a4ea16a328eb11b2f99))
* verify behaviour changes and claims before a review can approve ([#73](https://github.com/modulestf/modulestf/issues/73)) ([3bd9cf8](https://github.com/modulestf/modulestf/commit/3bd9cf8bb175f2db92f82409544b8fda9efa90bd))


### BREAKING CHANGES

* hosts must move their verify job, plan job, host
records and render to this commit together. verify.json (verify-pass.sh
run output) requires the top-level key selection and the per-directory
key affected, and selects every example rather than the touched ones.
plan-hosted.json examples require the keys addresses and attributes,
and check-plan no longer requires examples the change touches. The
render-comment.sh run file requires the key coverage
(class, inert, unplanned).

* fix: render the no example directory coverage reason with its own line

A non-inert change in a module with no example directory gave the coverage reason no example directory, which the render refused, so no comment was written. The reason is accepted, renders the fixed line unplanned-no-examples, and is an unknown at ladder rule 4.
