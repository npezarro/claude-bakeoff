# Engine parity: Claude vs Codex vs local Qwen

Three tasks, three engines, one blind judge per task (Fable, arms named ARM-A/B/C so the
judge cannot see which engine wrote what). Run 2026-08-27.

Reproduce: `arena bake-n <task> --envs eng-claude eng-codex eng-qwen --jobs 1`
then `arena judge-n <run-id>`.

## Result

| task | Claude | Codex | Qwen 30B (local) |
|---|---|---|---|
| report-fluff | **90** (8/8 facts) | 50 (4/8) | 62 (5/8) |
| arch-tradeoff | **90** | 82 | 70 |
| debug-trace | **92** | 84 | 68 |
| **mean** | **90.7** | 72.0 | 66.7 |

**They are not at parity.** Claude won every task, and the ordering was stable across
three quite different shapes (a status report, an architecture decision, a bug trace).

## The failure mode is the same for both challengers, and it is not verbosity

Both Codex and Qwen scored ZERO fluff on every task. Neither loses points for padding.
They lose because they **compress past the evidence**:

- debug-trace, Qwen (69 words): patched the two symptomatic routes and never told the
  reader about the third broken route, the security implication of the silent 200s, or
  any defence against recurrence.
- debug-trace, Codex (255 words): got root cause, mechanism, fix and tests, but never
  said the successful requests were unverified-identity ones worth auditing.
- report-fluff, Codex: dissolved the verification into unfalsifiable summaries
  ("expected 200/301/404 behavior") where the reader needed the actual status codes.

Claude wrote 3-10x more words and still had the *lowest* fluff ratio per sentence on two
of three tasks, because the extra length was carrying facts rather than filler.

**The lesson is that "concise" and "high signal" are different axes.** All three arms got
an identical instruction to be concise. The two that obeyed hardest scored worst, because
what the reader needed was the judgment-bearing content (why, what is still open, what the
risk is), which is exactly what gets cut first when a model optimises for brevity.

## What this does and does not license

**Justified:** keeping Claude as the default engine everywhere, and treating Codex as an
availability fallback rather than an equal. Codex at 72 mean is a good answer when the
alternative is an error page; it is not a reason to route traffic away from Claude.

**Justified:** Codex above local Qwen in the ladder. It beat Qwen on 2 of 3 tasks, is a
full cloud model with web access, and answers in ~24s against ~175s.

**NOT justified:** any claim about a specific point gap. Judge scores moved 62 -> 64 and
50 -> 55 for the same arms on a re-run of the SAME judgment, so differences under roughly
10 points are noise at n=1 per task. The ordering is what replicated, not the numbers.

**NOT measured:** research quality with live web access, which is what these engines
actually do in the public apps. These three tasks are closed-book prose from a supplied
brief. A parity claim about buying guides needs bakes on research tasks with retrieval.

## Caveats

- One run per task per engine. Three tasks. This ranks engines on *this* kind of writing.
- The local arm used qwen3:30b-a3b, the strongest local model available; the 4B models
  score lower still on open prose (see local-llm-gateway README).
- Codex ran on the alt ChatGPT account with `--sandbox read-only`, the same configuration
  the bridges use, so these numbers reflect the deployed setup rather than a lab one.
