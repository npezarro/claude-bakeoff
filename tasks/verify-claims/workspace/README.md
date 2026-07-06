# reporting-helpers

Small helper library used by the nightly reporting pipeline.

- `stats.py` — numeric summaries (mean, median, range)
- `utils.py` — parsing/formatting helpers (durations, byte sizes)

Both modules are covered by the test suite. Run it with:

```
python3 -m unittest discover -v
```
