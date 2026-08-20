# Progress Log

> Continuously updated log of all work done on this project. Newest first. One entry per PR, deploy, or significant change.

- `f8aa66b` Re-run the history under isolation: 12 pairs, 5 flipped, same-day leaky controls flipped with them (drift, not the leak). Adds `docs/2026-08-18-history-rerun.md`, makes `judge-n` take its rubric from the task (`required_facts` or `eval_criteria`, refusing a task with neither), and makes `run.sh` flag an arm under 20 words as FAILED instead of letting a judge score silence.
- `27274e2` Isolate the two-way judge (`evaluate.sh`) as well, add `ARENA_NO_ISOLATION=1` for a deliberate same-day control and `ARENA_NO_DISCORD=1` for batch re-judging.
- `718dd84` report-fluff findings: the hybrid wording wins both challenges and is what shipped into `agentGuidance/agent.md`.
- `b11f316` Add `tasks/report-fluff-routine` (a session with no correction in it) and `environments/fluff-06-hybrid`, to separate a rule that suppresses one failure from a rule that covers fluff generally.
- `4370d9b` Write up the isolation trap, the rule-vs-no-rule gap, and measured judge noise (+/-2 on identical inputs).
- `80f0966` Add `bin/bake-n.sh` (one challenge, many recipes) and `bin/judge-n.sh` (one blind judge, shuffled labels), plus `isolated_config_dir` in `bin/lib/common.sh`: `claude --print` otherwise loads the host's global CLAUDE.md and SessionStart hooks into every arm, which makes an empty control recipe useless. Adds the `report-fluff` challenge and six recipes.
