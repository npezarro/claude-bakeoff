# Engine parity on LIVE research tasks

Companion to `engine-parity.md`, which covered closed-book prose. These two tasks require
real retrieval: current prices, per-retailer, with URLs. This is the shape the public apps
actually serve, and the results are materially different from the closed-book ones.

Blind-judged (Fable, arms renamed ARM-A/B/C). First run 2026-08-31, re-measured
2026-09-03 after the retrieval fix.

## Result

Re-measured 2026-09-03 after the retrieval fix (Tavily/Brave ahead of SearXNG, bing and the
permanently-CAPTCHA'd engines dropped). **The first run's local numbers were invalid**: they
were produced while the search backend was returning dictionary definitions, so they measured
a broken pipeline rather than the engine.

| task | Claude | Codex | local (Qwen 30B + retrieval) |
|---|---|---|---|
| sander-buying-guide (2026-08-31) | **93** (8/8) | 76 (6/8) | 2 (0/8) *retrieval broken* |
| live-price-verify (2026-08-31) | 62 (4/6) | **91** (6/6) | 8 (3/6) *retrieval broken* |
| live-price-verify (2026-09-03, retrieval fixed) | **88** (6/6) | 78 (5/6) | 25 (3/6) |

Three things changed with the fix, and two of them are corrections to what I reported before.

**The "Codex beats Claude" result did not replicate.** On the re-run Claude won 88 to 78,
reversing the 62-to-91 of six days earlier. That earlier reversal was one observation at
n=1, flagged as such at the time, and it should now be treated as noise rather than a
finding. Claude has won five of six live and closed-book task-runs.

**Local improved but is still unsafe.** 8 -> 25 confirms the retrieval fix helped, and it is
still the worst arm by a wide margin.

**The failure mode changed, and the new one is more interesting.**

## Retrieval was necessary but not sufficient

With the fix, the local arm's sources are genuinely good: the Amazon product page,
camelcamelcamel, a woodworknation review, a redflagdeals thread. No dictionaries.

It still reported the Bosch ROS20VSC at **$199.99 at Amazon, $229.99 at Lowe's, $249.99 at
Home Depot** (real price ~$99), citing all three to source [4], `camelcamelcamel.com`.

That is a **price-history page for Amazon**. It contains many numbers, including historical
highs, and it has no Lowe's or Home Depot data at all. So the model:

1. read historical prices as current ones, and
2. invented the per-retailer attribution, citing a source that cannot support it.

Numeric provenance alone would NOT catch this, because those numbers really do appear on
the cited page. What catches it is a **claim-source consistency check**: a claim of the form
"$X at Lowe's" requires the cited page to mention Lowe's. That check is cheap, mechanical,
and is now the highest-value remaining item.

Note the judge flagged the same class of problem in Codex, more mildly: "key figures point
at price trackers, category listings, or nothing at all." Price-tracker pages mislead more
than one engine, so this is not purely a small-model failing.

## Caveats

- Two tasks, one or two runs each. Everything here is a small-n observation; the durable
  parts are the failure CLASSES, not the point scores.
- The Codex-beats-Claude result from 2026-08-31 did NOT replicate on 2026-09-03. Treat it
  as noise. This is the concrete cost of reporting an n=1 ordering.
- Live prices move, so these runs are not reproducible byte-for-byte.
- sander-buying-guide was not re-judged after the fix: the local arm returned zero words on
  that re-run, from a transient ollama connection failure during an 18GB model swap (the
  client now retries transport errors). Only live-price-verify has post-fix numbers.
- More research rounds do not fix either failure. Round count changes how much is
  retrieved, not whether the model reads a price-history page as current prices.
