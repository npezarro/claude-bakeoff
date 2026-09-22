# context.md

## Last Updated

2026-09-22 -- **Two bake-offs reversed the Opus 5 parity verdict, and exposed a judging bug that had been silently inverting multi-judge results.** Round 1 (`20260917_141917`, `20260917_142448`): `recipe-opus5-base` vs `recipe-opus5-layer` on `autonomy-probe` + `code-review`, blind `claude-sonnet-5` + `claude-fable-5-1`. Layer took 3 of 4 cells but the judges disagreed in SIGN on autonomy, so a pre-registered decision rule (win both tasks, both judges) said no. Round 2 (`20260917_194247`), 4 arms: **v4 93.0 > review-closer 84.5 > craft-v1 79.5 > base 78.0**, v4 first under both judges. That inverts EVERY position of the 2026-08-18 single-run five-way (base 92 > craft 88 > review-closer 82 > v4 72) which drove a month of configuration. **Bug: `bin/judge-cap.sh:70-78` truncates and reshuffles `runs/<id>/blind-map-cap.tsv` on every invocation** while writing per-judge JSON (`.cap-<TAG>.json`), so judging one run with two judges destroys the first judge's mapping. Both multi-judge runs this session drew DIFFERENT shuffles; reading the surviving map against the first judge's scores would have reported the layer LOSING code-review by 5 when it won by 5. Worked around by snapshotting the map after each call; **the one-line fix (`blind-map-cap-<TAG>.tsv`) is NOT yet applied**. Objective correctness was a tie again (both `logstats` arms parse 18 / skip 2), confirming differences on this class of work are behavioral. Full closeout: `privateContext/deliverables/closeouts/2026-09-22-parity-layer-switch-and-opus5-remeasurement.md`.

2026-08-28 -- **Task library moved private.** The task library and the voice/profile environments now live in `privateContext/bakeoff/{tasks,environments}/` and are symlinked into this repo; `.gitignore` default-denies `tasks/*` with an allowlist for the tracked public examples (`.example`, `code-review`, `verify-claims`). Task prompts routinely carry personal or project-specific material, so private is the default and public is a deliberate allowlist decision (`privateContext/bakeoff/README.md` documents the wiring).

2026-08-19 -- **N-way bakeoffs, host isolation, and a re-run of the history.** Two capabilities and one serious measurement bug, all from a single question: which wording of an anti-fluff rule should ship into `agentGuidance/agent.md`.

**Host isolation (the important one).** `claude --print` loads the HOST's `~/.claude/CLAUDE.md` and fires the host's SessionStart hooks on top of the workspace `CLAUDE.md` an arm was given. Every bake this repo ran before 2026-08-18 was therefore *host guidance + recipe A* vs *host guidance + recipe B*, and a deliberately empty control recipe was not a control. It changed a result on the first run: the control arm came back clean because the rule under test was live in the host's guidance and reaching every arm; isolated, it opened by quoting the reader's own question back at them (78 -> 63). `isolated_config_dir` in `bin/lib/common.sh` returns a `mktemp` dir holding credentials and nothing else; `run.sh`, `bake-n.sh`, `evaluate.sh` and `judge-n.sh` all use it. `ARENA_NO_ISOLATION=1` reproduces the old behaviour deliberately, as a same-day control. Judges are isolated for a different reason: one that has read the host guidance grades against the rule's author instead of the rubric.

**N-way.** `arena bake-n <task> --envs A B C ...` runs every arm against one challenge with a concurrency cap; `arena judge-n <run-id>` hands all arms to one judge, blind and shuffled, with the label map written before the call. The rubric comes from the task: `required_facts` (did the facts survive the compression) or `eval_criteria` (did it do the job). It refuses a task that declares neither, after an early version silently scored a code review on prose economy and reported `facts 0/0` as if it were a verdict.

**Re-running the history under isolation** (`docs/2026-08-18-history-rerun.md`): 12 pairs, 5 flipped, and the same-day leaky controls flipped with them, so the cause was three weeks of model drift and not the leak. The leak decides verdicts only when the host guidance overlaps the variable under test; the July parity family varies the MODEL (`recipe-jade` and `recipe-opus5-base` ship byte-identical `CLAUDE.md` files), so the payload landed on both arms equally. The bigger defect in that corpus is n=1: every historical verdict is one run of one pair judged once, and this session's replicates flipped a winner on variance alone.

## Current State

- **Working.** `arena bake` / `bake-n` / `judge` / `judge-n` all run isolated by default. `tasks/report-fluff` and `tasks/report-fluff-routine` are the two report-writing challenges; findings in `tasks/report-fluff/FINDINGS.md`.
- The anti-fluff wording this repo selected is deployed in `agentGuidance/agent.md` under Communication.
- The parity family verdict as of 2026-08-18: bare Opus 5 first (92), craft rule 88, review closer 82, Fable 78, full layer v4 last (72), on `code-review` at n=1 per arm. That fed the retirement of the parity injection on Opus 5.

## Open Work

- **Private inputs.** Most tasks and the voice/linkedin environments live in `privateContext/bakeoff/` (symlinked in), so results that use them are reproducible on this machine but not by the public. Only `tasks/code-review` and `tasks/verify-claims` are public.
- **Treat any single-run verdict in `evaluations/` as a hypothesis.** Judge noise on identical inputs is about +/-2 and run-to-run variance is larger than that.
- `run.sh` flags an arm returning under 20 words as FAILED, added after `op5p2-code-review-cli` shipped a 5-vs-9 verdict built on a 112-word dead arm. Older verdicts predate that guard.

## Environment Notes

- **Deploy target:** local only; no service, no CI.
- **Runs:** `runs/` and `evaluations/` are gitignored. A worktree removal deletes them, so copy anything you need to keep before `git worktree remove`.
- **Judge model:** pinned in `config.yaml` (`claude-fable-5`) so arms are graded by a consistent, blind-named judge.
- **Default branch is `master`, not `main`.**

Full closeout: `privateContext/deliverables/closeouts/2026-08-19-anti-fluff-rule-bakeoff-isolation-and-parity-retirement.md`
