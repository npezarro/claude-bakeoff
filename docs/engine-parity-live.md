# Engine parity on LIVE research tasks

Companion to `engine-parity.md`, which covered closed-book prose. These two tasks require
real retrieval: current prices, per-retailer, with URLs. This is the shape the public apps
actually serve, and the results are materially different from the closed-book ones.

Blind-judged (Fable, arms renamed ARM-A/B/C). Run 2026-08-31.

## Result

| task | Claude | Codex | local (Qwen 30B + retrieval) |
|---|---|---|---|
| sander-buying-guide | **93** (8/8 criteria) | 76 (6/8) | 2 (0/8) |
| live-price-verify | 62 (4/6) | **91** (6/6) | 8 (3/6) |

**Codex beat Claude on live-price-verify**, which did not happen once across the three
closed-book tasks. Claude was scrupulously honest about what it could not verify but left
the two central questions (price difference, stock status) unanswered and spent sentences
narrating its own epistemics. Codex answered all six criteria with a per-retailer URL each
and flagged the unverifiable cells explicitly. On a task that rewards *getting the numbers*,
Claude's caution cost it and Codex's directness won.

That is a real reversal, not noise in the same direction: the closed-book tasks rewarded
completeness of reasoning, and these reward verified specifics.

## The local arm did not lose. It produced dangerous output.

Its two answers, verbatim in substance:

1. sander-buying-guide: "The evidence provided contains no information about power
   sanders... The evidence is entirely unrelated to the query." Sources: Wikipedia's *Best
   Buy* article, `dictionary.cambridge.org/dictionary/english/best`, Merriam-Webster.
2. live-price-verify: "Bosch ROS20VSC costs **$299.99** at Amazon, **$349.99** at Lowe's
   and **$349.99** at Home Depot." The real price is about **$99**. The citation was a
   TV-series Wikipedia page.

The second is the serious one. It is fluent, cited, internally consistent, and would send
a reader to a checkout expecting roughly triple the real price. Nothing about its shape
signals that it is wrong.

### Root cause: the search backend, not the model

SearXNG reported `unresponsive_engines: brave "Suspended: too many requests",
duckduckgo "CAPTCHA", startpage "Suspended: CAPTCHA"`. Three of five engines are blocked,
leaving bing and google cse, and bing keyword-matches: for "best power sander for stripping
thick dark wood finish under $150" its top hits were bestbuy.com and two dictionary
definitions of "best".

Note what this means. The first answer is the pipeline working correctly: given dictionary
pages, it refused to invent a buying guide. **Grounding discipline held.** The second is
the same pipeline given evidence that merely *looked* like prices, and grounding does not
help when the ground is wrong.

### Two bugs this exposed, both fixed

**The degradation signal was being thrown away.** `search()` attached
`unresponsiveEngines` to its result array, then returned `dedupe(results)`, which builds a
NEW array. The property was silently dropped, so every caller saw `searchDegraded: null`
while three engines were down. The one signal meaning "do not trust these results" was
being discarded by a dedup step.

**A 120s client timeout killed the 30B mid-answer.** That default was calibrated on 4B
models at ~33 tok/s; the 30B generates at ~8.5 and reasons first, so a synthesis over a
full buying guide's evidence exceeded it. The first run of this bake recorded the local arm
at 0 words, which a judge would have scored as a terrible answer rather than a failed run.
Timeout is now a per-model property.

**And a guard was added, because a fix to retrieval quality is not available.** The
gateway now returns `untrustworthyRetrieval: true` when two or more engines are down, and
the bridge refuses that answer and falls through to Codex. Two is the threshold: one dead
engine is routine flakiness, two means the result set is only whatever survived.

## What to conclude

- **Claude stays the default.** It won the buying guide outright and is the only arm that
  never produced a fabricated figure.
- **Codex earns its place above local, more strongly than the closed-book tests showed.**
  It won a live task outright, and it retrieves reliably.
- **The local engine is not currently viable for live research**, and the blocker is
  retrieval, not the model. Fixing it means a search backend that is not three-fifths
  CAPTCHA'd: a paid API key (Brave's free tier is 2k/month) would likely resolve it, and
  that is the single highest-value change available to this pipeline.
- The earlier roadmap claim that "the residual gap is retrieval quality, not the model" is
  now measured rather than asserted.

## Caveats

- Two tasks, one run each. The Codex-beats-Claude reversal is one observation, not a trend.
- Live prices move, so these runs are not reproducible byte-for-byte; the failure classes
  are the durable part.
- The local arm ran with `maxRounds` 3 and 2 respectively; more rounds would not fix
  retrieval that returns dictionary pages.
