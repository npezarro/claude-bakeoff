# Study design: how close do cheaper tiers get to Opus 5.5 with layered scaffolding?

Status: PRE-REGISTERED 2026-09-22, before any baseline result was read. Sections 1-6 are
fixed; section 7 (layer candidates) has a gap-driven part that is filled in only after the
baseline, and every addition there is dated.

This mirrors the earlier Opus-to-Fable parity work (parity layer v4, the 2026-07 and 2026-09
audits): measure the raw gap first, then try instruction layers and pipeline stages per tier,
and adopt nothing on a single run or a single judge.

## 1. Question

Opus 5.5 (`claude-opus-5-5`) is the new top model. How closely can three cheaper models
approximate it, and does any instruction layer or pipeline stage close the gap?

| tier | model ID | recipe (bare) |
|---|---|---|
| reference | `claude-opus-5-5` | `recipe-opus55` |
| candidate | `claude-opus-5` | `recipe-opus5-base` |
| candidate | `claude-sonnet-5` | `recipe-sonnet5-base` |
| candidate | `claude-haiku-4-5-20251001` | `recipe-haiku45d-base` |

All bare arms share one byte-identical 122-byte preamble (md5 `4721e68f...`), so only the
model varies. `recipe-haiku45d-*` pins the dated Haiku ID; the older `recipe-haiku45-*`
recipes use the `claude-haiku-4-5` alias and are kept unchanged for comparability with past runs.

## 2. Prior art this design inherits (not re-derived)

- Objective hidden-test correctness is saturated family-wide on sub-hour work (Haiku 4.5
  through Fable 5.1 all 100% on kvstore-tx, algo-scale, long-context, instr-load, and on the
  300-turn mini-redis and pagewatch-engine builds). Expect ties there; the differences that
  exist are behavioral (evidence fidelity, autonomy, report craft, review depth).
- Known cheaper-tier gaps vs the previous top model: Sonnet 5 is roughly 85-97% on judged
  dimensions and over-claims on verify-claims under the sonnet-tuned layer; Haiku 4.5 has an
  evidence-fidelity gap (autonomy 55, verify 66 bare) and collapses on degraded vision (12/100).
- A single judged run is not a decision basis (a 2026-08-18 single-judge ranking was fully
  inverted by a two-judge replication). Judges from an arm's family may self-prefer.
- `bin/judge-cap.sh` used to share one blind map across judges; it is now per-TAG. Two judges
  whose model names shorten to the same default tag (`claude-fable-5` and `claude-fable-5-1`
  both become `fable`) would still collide, so every judge call here passes an explicit `--tag`.

## 3. Probe set and order (cheap first)

Phase 0 (baseline, bare arms only, n=2 per cell):

| group | probes | grading |
|---|---|---|
| objective | instr-load, kvstore-tx, long-context, algo-scale | `bin/grade-hidden.sh` (judge-free) |
| behavioral | code-review, verify-claims, fanout-probe, debug-trace, autonomy-probe, vision-probe | two blind judges + objective side-checks where one exists |
| costlier behavioral | multi-file-impl, long-horizon-probe (45 turns) | two blind judges |

Objective side-checks for judged probes (judge-free, run against each arm's workspace with the
task's pristine test files restored): fanout-probe (does `tests_all.py` pass, 14 tests),
verify-claims (does the pristine suite pass). These separate "fixed it" from "said it fixed it".

Skipped in this kickoff (cost/time): mini-redis and pagewatch-engine (300 turns),
multihour-probe (250), overnight-probe (500). They are candidates for a later phase only if a
gap shows up at 45 turns that looks horizon-dependent.

Settings for every arm: `--effort xhigh`, 45-turn budget (task overrides where the task sets one),
isolated `CLAUDE_CONFIG_DIR`, `--dangerously-skip-permissions`, 4 arms in parallel.

## 4. Judges

Arms are Opus 5.5, Opus 5, Sonnet 5 and Haiku 4.5. The judges must not be any of them:

- Primary: `claude-fable-5-1` (tag `fable51`).
- Secondary: `claude-fable-5` (tag `fable5`).

Both are outside the Opus/Sonnet/Haiku lines, so no arm is judged by itself. Known weakness:
the two judges are the same line and therefore correlated, so their agreement is weaker evidence
than agreement between unrelated judges. Where they disagree in sign on a cell, a third non-arm
judge (`claude-opus-4-8`, same line as two arms but a different model) is used only as a
tiebreak, and that is reported as such.

Judged scores are secondary to objective graders whenever both exist.

## 5. Metrics (pre-registered)

- Per cell: overall 0-100 from `judge-cap.sh` (task checklist plus correctness, completeness,
  evidence fidelity), or pass-rate for objective probes.
- Parity ratio for arm X on probe P = score(X) / score(Opus 5.5), computed within the same run
  and the same judge, then averaged over judges and replicates. Tier summary = mean over probes.
- Cost per task per arm: `total_cost_usd` from each arm's `output.json` (API-equivalent list
  price as reported by the CLI; on a subscription this is a relative cost, not a bill).
- Cost-adjusted: parity ratio divided by (arm cost / Opus 5.5 cost), reported alongside, never
  instead of, the parity ratio.

## 6. Decision rules (fixed before results)

**Gap identification (Phase 0).** Opus 5.5 "leads" tier T on probe P only if Opus 5.5 outscores
T in every judge x replicate cell (4 of 4), or, for objective probes, in both replicates. A 3-of-4
result is "possible lead, needs n=3". Mixed signs is "no detectable lead". Only probes with a
lead or possible lead get layer work in Phase 1.

**Tier parity verdict.** A tier (bare or layered) is at parity if its mean parity ratio is at
least 95% on judged probes AND 100% on objective probes AND no single probe is below 85%.
It is a usable fallback at 90% mean with no probe below 80%.

**Layer adoption for tier T.** A layer is recommended for T only if, against T bare on the same
runs, it (a) raises the gap probe(s) under both judges in both replicates, (b) drops no other
probe by more than 5 points (judge mean), and (c) leaves every objective score unchanged. Anything
short of that is reported as "not adopted" with the cell table, however good the mean looks.

**Replication.** n=2 per cell minimum before any claim. Adoption decisions need n=2 with full
sign agreement; if any cell disagrees, n=3 before deciding.

**Recommendations only.** No live injection config (`parity-layer.conf`, hooks, worker) is
changed by this study.

## 7. Layer candidates per tier (Phase 1)

Reused, already validated elsewhere:

| tier | candidates |
|---|---|
| Opus 5 | v4 (`recipe-opus5-layer`, verified byte-identical to the canonical block), craft-v1 (`recipe-opus5-min`), craft plus complement-search closer (`recipe-opus5-review`) |
| Sonnet 5 | sonnet-tuned v4 (`recipe-sonnet5-layer`, same text as `recipe-topaz2`), v4 verbatim (new arm) |
| Haiku 4.5 | sonnet-tuned v4 (`recipe-haiku45d-layer`) |

Pipeline stages (from the earlier parity work, apply per task type): verified pass
(`platforms/verified.sh`) for report-critical work, complement-search second pass
(`platforms/adversarial.sh`) for review, suite hardening (`platforms/hardened.sh`) for builds.

Gap-driven proposals: filled in after Phase 0 (see the dated addendum below).

## 8. Cost envelope

From earlier runs at xhigh / 45 turns, per task per arm: Opus-class $0.4-2.5, Sonnet 5 $0.13-0.6,
Haiku 4.5 $0.04-0.2. One four-arm replicate of the 12-probe baseline is therefore roughly
$20-35 API-equivalent, plus two judge calls per judged run. Every batch is gated by the usage
check; the kickoff stops launching new runs if 5-hour or 7-day usage exceeds 60%.

## 9. Reproduce

```
cd claude-bakeoff
export BAKE_EFFORT=xhigh
ARMS="recipe-opus55 recipe-opus5-base recipe-sonnet5-base recipe-haiku45d-base"
./bin/bake-n.sh <task> --envs $ARMS --jobs 4 --id o55-<task>-r1
./bin/grade-hidden.sh o55-<task>-r1                               # objective probes
./bin/judge-cap.sh o55-<task>-r1 claude-fable-5-1 --tag fable51   # judged probes
./bin/judge-cap.sh o55-<task>-r1 claude-fable-5   --tag fable5
```

## Addendum 2026-09-22 (after Phase 0, n=2): gap-driven layer candidates

Written after the baseline was read. Sections 1-6 above are unchanged.

**Correction to the premise, from the data.** The CLI's own list-price cost basis (fitted
exactly from `modelUsage`, zero residual) prices Opus 5.5 at $4 / $20 per million input /
output tokens and $0.20 per million cache reads, against Opus 5 at $5 / $25 / $0.50. Across the
12 baseline probes Opus 5.5 cost 100% and Opus 5 cost 120%. Opus 5 is therefore not a cheaper
substitute for Opus 5.5 on this cost basis, so it is kept as a comparison tier but deprioritized
for layer work. Sonnet 5 (39%) and Haiku 4.5 (12%) are the real cost-saving tiers.

**Gaps found (pre-registered 4-of-4 rule), with the objectively visible mechanism:**

| tier | probes where Opus 5.5 leads 4/4 | mechanism checked in the artifacts |
|---|---|---|
| Opus 5 | autonomy-probe, debug-trace | repro/audit scripts left in `/tmp` outside the workspace, so claimed verification is uncheckable; one "report above" with no report |
| Sonnet 5 | autonomy-probe, long-horizon-probe, debug-trace, verify-claims, fanout-probe, vision-probe | final message says the output was "pasted above" when no assistant message ever contained it (transcripts: the "above" was a tool result the reader never sees); summarized instead of quoted runner output; no before-state |
| Haiku 4.5 | every judged probe except code-review (2/4) | never rotates a degraded image, then asks the user (vision 5-8/100); coverage inventories that do not match the test file; reports on files it never opened; paraphrased "all tests pass" |

**New candidates (recipes committed, not yet run):**

| recipe | tier | what it adds | targets |
|---|---|---|---|
| `recipe-sonnet5-evid` | Sonnet 5 | sonnet-tuned v4 plus a 4-line evidence-depth addendum (quote before and after runner output, prove each fix is load-bearing, re-check every "I changed X" sentence against the file) | phantom "above", thin evidence, and the earlier sonnet-layer over-claim on verify-claims |
| `recipe-sonnet5-v4` | Sonnet 5 | canonical v4 verbatim (byte-identical to `recipe-opus5-layer`) | control for whether the sonnet-tuned autonomy rewording still matters on Sonnet 5 |
| `recipe-haiku45d-evid` | Haiku 4.5 | short standalone 8-rule evidence layer: read before reporting, every number copied from a tool result, before/after runner lines verbatim, root-cause fixes, verified-vs-believed split, rotate/crop/enlarge images with tools before reading them, outcome first, deliverable in the message | fabricated inventories, skipped files, the vision collapse |
| `recipe-haiku45d-layer` | Haiku 4.5 | sonnet-tuned v4 (reuse) | comparison against the short layer; the earlier run showed it destabilizing verify-claims |

Pipeline stages to try after the layers: the verified pass (`platforms/verified.sh`) on Haiku and
Sonnet for report-critical probes, because an evidence-fidelity failure is the one a
fresh-context verifier catches without relying on the worker's instruction-following.

**Phase 1 plan (queued):** one 7-arm bake per probe so every layer shares the Opus 5.5 reference
in the same judge call: `recipe-opus55`, `recipe-sonnet5-base`, `recipe-sonnet5-layer`,
`recipe-sonnet5-evid`, `recipe-haiku45d-base`, `recipe-haiku45d-layer`, `recipe-haiku45d-evid`.
Probes: autonomy-probe, long-horizon-probe, verify-claims, debug-trace, vision-probe, fanout-probe
(n=2 each), then `recipe-sonnet5-v4` and the verified pass on whichever probes remain open.
Decision rule: section 6 as registered.

**Framework fixes made during Phase 0** (behavior-neutral for the arms):
- `bin/judge-cap.sh`: the default-tag collision noted in section 2 is fixed; the default tag now
  keeps the version (`fable-5`, `fable-5-1`). In this study the two judges drew different
  shuffles on 14 of 16 runs, so per-judge maps were load-bearing.
- `platforms/cli.sh`: keeps each arm's session transcript at `arms/<arm>/transcript/` (from
  fanout-probe onward), because `.result` holds only the final assistant turn and an arm that
  ends on a trailing "see the review above" is otherwise unrecoverable.
- `bin/bake-n.sh`: an arm whose CLI result has `is_error: true` is now marked FAILED. One
  baseline arm (Opus 5, debug-trace r2) died after 24 turns with "OAuth session expired and could
  not be refreshed" when another process rotated the shared refresh token mid-bake; it was
  re-run in place and the run re-judged by both judges (pre-rerun verdicts kept).

## Phase 1 pre-registration (2026-09-25, before any Phase 1 run)

**Layer bakes.** One 8-arm bake per probe, so every layer shares the Opus 5.5 reference and its
own tier's bare arm inside the same judge call: `recipe-opus55`, `recipe-sonnet5-base`,
`recipe-sonnet5-layer` (sonnet-tuned v4), `recipe-sonnet5-v4` (v4 verbatim), `recipe-sonnet5-evid`,
`recipe-haiku45d-base`, `recipe-haiku45d-layer` (sonnet-tuned v4), `recipe-haiku45d-evid`.
Probes: autonomy-probe, long-horizon-probe, verify-claims, debug-trace, vision-probe,
fanout-probe; n=2 each; run IDs `o55p1-<probe>-r<n>`. Same judges (`claude-fable-5-1` tag
`fable51`, `claude-fable-5` tag `fable5`), each decoded with its own blind map.

Judge-free checks: fanout-probe and verify-claims (pristine suites plus hidden cases, as in
Phase 0) and, new, vision-probe (cell accuracy of `metrics.csv` against the 20-cell ground truth
in the task's eval criteria, plus the header).

**How section 6 is applied (clarified now, before results):**
- Ratios are computed within Phase 1 runs only (Opus 5.5 of the same run and judge).
- Section 6(a), "raises the gap probe(s) under both judges in both replicates", is read
  literally: a layer is ADOPTED for a tier only if it beats that tier's bare arm in all 4 cells
  on every gap probe of that tier that is in this probe set (Sonnet 5 and Haiku 4.5: all six),
  and (b) and (c) hold. As a separately labelled secondary result, a layer is "supported on
  probe P" if it beats bare in 4 of 4 cells on P with no other probe falling more than 5 points.
- (c) "objective unchanged": the four hidden-test probes are not re-run for layers in this
  phase (saturated for every bare tier); (c) is checked on the three judge-free side-checks only,
  and the readout says so.
- Tier parity verdict for a layered config uses the same thresholds as section 6 (95% mean,
  no probe under 85%; usable fallback 90% mean, none under 80%) over the six Phase 1 probes.

**Code-review replicate 3.** The four bare arms plus `recipe-opus55-final`, run ID
`o55-code-review-r3`, judged by both judges.

**Headless Opus 5.5 final-message rule** (`recipe-opus55-final`: the bare preamble plus three
rules: the final message carries the full deliverable, never point "above", stop background
work before the final message). Motivation: Phase 0 code-review r2, where a background watcher's
notification produced a 44-word final turn and lost the review. Design: `recipe-opus55` vs
`recipe-opus55-final` on code-review, run IDs `o55f-code-review-r1..r3`, plus the r3 bake above.
Primary metric, judge-free: delivery failures, defined as a final message under 300 words or one
whose only reference to the review is a pointer to earlier content. Rule: recommend the rule for
headless Opus 5.5 pipelines if the rule arm has 0 delivery failures in its 4 runs AND its judged
mean on runs where both arms delivered is not more than 5 points below the bare arm's. With a
bare failure rate near 1 in 2 this is directional evidence, not proof, and is reported as such.

**Budget.** `check-usage.sh --gate --force` before every batch; stop launching at 7-day >= 70%
or 5-hour >= 60%, and record where the stop happened.
