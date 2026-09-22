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
