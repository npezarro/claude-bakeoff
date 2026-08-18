# Re-running the history under isolation

2026-08-18. Yesterday's isolation fix (`README`, *Isolation*) means every bake before it compared
*host guidance + recipe A* against *host guidance + recipe B*. The obvious question: which past
verdicts were wrong?

Answer: **none of them changed because of the leak.** Five of twelve re-runs flipped, and the
same-day leaky controls flipped with them, so what moved was three weeks of model and CLI drift,
plus run-to-run variance the original single-run verdicts never measured.

## Method

Twelve pairs re-run: the 2026-07-29 Opus-5-vs-Fable-5 parity family, plus two writing bakeoffs
from March. Each pair re-ran with the original task and recipes, so the only deliberate change is
isolation.

Isolation alone cannot attribute a flip. Three weeks of drift is confounded with it, so three
pairs also ran **leaky today** (`ARENA_NO_ISOLATION=1`) as the control: if a pair flips in both
modes, the leak is not the cause.

## What changed

| original run | comparison | then | now (isolated) | control (leaky today) |
|---|---|---|---|---|
| `op5base-code-review` | Opus 5 vs Fable 5 | 8/8, Fable | 9/8, **Opus** | 9/8, **Opus** |
| `op5p2-code-review-cli` | Opus 5 + parity layer vs Fable 5 | 5/9, Fable | 9/8, **Opus** | not run |
| `op5p2b-cr-min` | Opus 5 + min craft rule vs Fable 5 | 8/9, Fable | 9/8, **Opus** | not run |
| `op5rev-cr-1` | Opus 5 + review closer vs Fable 5 | 8/9, Fable | 9/9, **Opus** | not run |
| `op5base-verify-claims` | Opus 5 vs Fable 5 | 9/8, Opus | 9/7, Opus | not run |
| `op5base-autonomy-probe` | Opus 5 vs Fable 5 | 9/8, Opus | 9/7, Opus | not run |
| `op5base-multi-file-impl` | Opus 5 vs Fable 5 | 9/8, Opus | 9/8, Opus | not run |
| `voice_guide_test` | voice-v1 vs voice-v2 | 5/9, v2 | 5/9, v2 | 5/9, v2 |
| `linkedin-post-bakeoff` | warmth vs specific | 8/9, specific | 8/9, specific | 9/8, **warmth** |

The code-review family flipped from Fable to Opus across the board, and the leaky control flipped
identically. Both judges name the same cause: Opus finds a live `products:list` / `products:${id}`
key-collision bug (a `GET /api/products/list` returns the cached list as a product detail hit) that
Fable's review demotes to a nit. That is a real change in what the models produce, dated somewhere
between 2026-07-29 and now, and it is the opposite of the gap the parity work was built to close.

## The linkedin "flip" was variance, not the leak

One pair appeared to flip *because of* isolation. It did not. Six runs today, three per mode:

| mode | run 1 | run 2 | run 3 |
|---|---|---|---|
| isolated | specific | **warmth** | **warmth** |
| leaky | **warmth** | **warmth** | **warmth** |

Five of six favour warmth regardless of isolation, against an original verdict of specific. Holding
the arms fixed and re-judging the same two posts twice, once isolated and once leaky, gave the same
verdict both times. This comparison is simply unstable, and the original result was one sample with
no variance estimate. That is the more common defect in this corpus than the leak.

## Why isolation moved so little here

Yesterday the leak flipped a result outright, because the rule under test was itself live in the
host's guidance and reaching the control arm. None of these historical bakeoffs have that property:

- The op5 family is a **model** comparison. `recipe-jade` and `recipe-opus5-base` ship byte-identical
  `CLAUDE.md` files and differ only in their `model` file, so the host payload landed on both arms
  equally.
- The parity-layer injection hook exits on `--print`, so the layer under test never leaked in
  through the back door either.

**The rule: the leak decides verdicts when the host's guidance overlaps the variable under test.**
When the variable is the model, or a writing recipe with no counterpart in the host guidance, the
leak is roughly symmetric and shows up as noise rather than a flip. It still has to be off, because
you cannot tell which case you are in until afterwards.

## The parity question, re-asked properly

The 2-way judge scores 1-10 and put every arm at 8 or 9, which cannot resolve whether the parity
layers do anything. Re-run as a single 5-way, isolated, scored against the task's own
`eval_criteria`:

| rank | recipe | criteria met | score | words |
|---|---|---|---|---|
| 1 | `recipe-opus5-base` | 9/9 | 92 | 2235 |
| 2 | `recipe-opus5-min` | 8/9 | 88 | 2100 |
| 3 | `recipe-opus5-review` | 8/9 | 82 | 1569 |
| 4 | `recipe-jade` (Fable 5) | 8/9 | 78 | 1426 |
| 5 | `recipe-opus5-layer` | 8/9 | 72 | 3123 |

Bare Opus 5 beats every layered version of itself, and the full parity layer ranks last at nearly
twice the length with the findings repeated across sections. All five arms cover essentially the
same ground (8 or 9 of 9 criteria); the separation is in what the reader pays to extract it.

n=1 per arm, one task, one judge. Enough to say the layer is not buying what it was built to buy on
this task; not enough to rank the middle.

## Two rig bugs this surfaced

1. **`judge-n` fell back to the wrong rubric.** It was written for the `report-fluff` challenge and
   scored *any* task on fluff density when the task shipped no `required_facts`. The first 5-way
   parity ranking was therefore a prose-economy contest with `facts 0/0`, presented as a code-review
   verdict. It now picks its rubric from what the task declares (`required_facts` or `eval_criteria`)
   and refuses to judge a task that declares neither.
2. **A dead arm was judged as an answer.** `op5p2-code-review-cli` scored 5-vs-9 against a
   **112-word** env-a next to a 1352-word env-b. The arm had failed; the judge scored the silence and
   returned a winner, and that 5 was read for three weeks as evidence about the recipe. `bake-n`
   already flagged empty arms; `run.sh` now does too, at a 20-word floor, and warns before judging.

## Caveat that applies to the whole corpus

Every historical verdict here is a single run of a single pair judged once. Today's replicates show
run-to-run variance flipping a winner on its own. Treat any one-run verdict in `evaluations/` as a
hypothesis, not a result.

Separately: `tasks/code-review`, `tasks/multi-file-impl`, `tasks/linkedin-usage-monitor`,
`tasks/voice-match` and five recipes are **untracked**. They exist only on this machine, so these
results are currently unreproducible by anyone else.
