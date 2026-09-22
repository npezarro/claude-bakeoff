# claude-bakeoff

A/B testing framework for comparing Claude CLI instruction environments. Tests different CLAUDE.md configurations against the same task to measure instruction quality.

## Architecture

- **CLI:** `arena` (symlinked to `bin/arena`, delegates to `bin/*.sh`)
- **Environments:** `environments/<name>/CLAUDE.md` — each is an isolated instruction set
- **Tasks:** `tasks/<name>/task.yaml` — prompt, eval criteria, expected behavior
- **Runs:** `runs/<timestamp>/` — captured outputs (gitignored)
- **Evaluations:** `evaluations/<timestamp>.yaml` — LLM judge verdicts (gitignored)
- **Platforms:** `platforms/<name>.sh` — pluggable execution backends selected via `platform_a`/`platform_b` in `config.yaml`. Interface: `BAKE_PROMPT`/`BAKE_MODEL`/`BAKE_MAX_TURNS`/`BAKE_EFFORT` env in, JSON with a `.result` field out. Available: `cli` (local `claude` CLI), `discord` (routes through #bakeoff-arena), `bestof` (runs `agentGuidance/scripts/bestof-claude.sh` with 2 parallel instances and keeps the judged winner).
- **Per-environment model:** `environments/<name>/model` — optional file holding a model ID (e.g. `claude-fable-5`) that overrides the global `claude_model` config for that environment only.
- **Per-environment platform:** `environments/<name>/platform` — optional file naming a platform (e.g. `codex`, `local`) that overrides the default `cli` platform for that environment only, read by `arena bake-n` so a single N-way bake can put different engines head to head.
- **Additional platforms:** `codex` (OpenAI Codex CLI via `codex exec --sandbox read-only`, runs under an isolated `CODEX_HOME`) and `local` (on-device Ollama model via `LLMG_OLLAMA_HOST`; text-only reply, no tool or file access, so only meaningful on tasks graded on reply text).

## Key Rules

1. **Output goes to private repos, not here.** Bakeoff results often contain proprietary content (resume text, strategy docs). Final synthesized outputs belong in privateContext or the relevant project repo, not in claude-bakeoff.
2. **Tasks are private by default.** The task library lives in `privateContext/bakeoff/tasks/` and is symlinked into `tasks/`; `.gitignore` default-denies `tasks/*` with an allowlist for the public examples (`.example`, `code-review`, `verify-claims`). To create a task: make the directory in `privateContext/bakeoff/tasks/` and symlink it into `tasks/` (see `privateContext/bakeoff/README.md`). Making a task public is a deliberate act: it must contain zero personal or attributed material, and it gets an explicit `!tasks/<name>` allowlist entry. The same applies to personal environments (voice/profile recipes), which live in `privateContext/bakeoff/environments/`.
3. **Environment CLAUDE.md files are the experiment.** Don't add general agent instructions — each environment should test a specific instruction hypothesis.
4. **Baseline must stay minimal.** `environments/baseline/CLAUDE.md` is the control. Don't add rules to it.
5. **Task eval criteria drive the judge.** Write specific, measurable criteria in `task.yaml`. Vague criteria ("good quality") produce unreliable judge scores.
6. **Runs and evaluations are gitignored.** Don't force-add them. Results that matter get distilled into the environment or agentGuidance.
7. **`cli` platform runs with `--dangerously-skip-permissions`.** Bakes execute headless in isolated throwaway workspaces with nobody present to approve tool permissions, so this is required for a valid comparison (otherwise agents can't write files or run code).
8. **Bakes are isolated from host guidance.** Before any arm runs, `isolated_config_dir` (`bin/lib/common.sh`) points `CLAUDE_CONFIG_DIR` at a throwaway dir holding only credentials, so arms load the workspace `CLAUDE.md` and not `~/.claude/CLAUDE.md` or the host's SessionStart hooks. Without a credentials file to copy, the run logs a loud warning and results are host-guidance-plus-recipe, not the recipe alone. See README's Isolation section for detail.
9. **`codex` platform runs under an isolated `CODEX_HOME`.** Defaults to `~/.codex-alt` (override via `BAKE_CODEX_HOME`), so a bake never runs against the personal ChatGPT/Codex session — same isolation intent as rule 8, applied to the Codex account boundary.

## Workflow

```bash
arena new env <name>        # Create environment
arena new task <name>       # Create task
arena run <task> --env-a X --env-b Y   # Execute A/B test
arena eval <run-id>         # LLM judge comparison
arena report <run-id>       # View results
arena merge <run-id>        # Synthesize best-of-both
arena auto "<prompt>"       # Quick single-prompt bakeoff
arena eval <run-id> --judge-model <model>  # Override config.yaml judge_model for this eval
arena eval <run-id> --suffix <suffix>      # Write eval output as <run-id><suffix>.yaml instead of overwriting; skips Discord auto-post
arena bake-n <task> --envs A B C [--jobs N]   # Same challenge, every recipe at once, one ranking
arena judge-n <run-id>      # Rank every arm of an N-way bake, blind, in one call
```

`config.yaml` settings relevant to a run: `claude_max_turns` (default 45), `claude_effort` (passed through as `BAKE_EFFORT`), `judge_model` (default `claude-fable-5`, pinned for a consistent discriminating judge). A `task.yaml`'s own `max_turns:` field overrides `claude_max_turns` for that task.

## Patterns Learned

- Instruction length is not monotonically better — minimal beats detailed on simple tasks
- Behavioral constraints cascade unpredictably (e.g., "always test" + flaky tests = lower completion)
- LLM judge correlates ~80% with human preference; diverges on subjective "code quality" dimension
- The 4-path bakeoff pattern (structured, adversarial, deep-dive, minimal) is effective for complex tasks like buying guides

## Objective & Capability Judging

- **`bin/grade-hidden.sh <run-id> [grader-cmd]`** — judge-free grading for a task that ships a hidden `tasks/<task>/grader/` dir (default `grader-cmd`: `python3 grade.py`). Copies each arm's workspace plus the whole grader dir (not just `*.py`, so answer-key/data files come along) into a throwaway dir, runs the grader, and parses its `GRADE: <passed>/<total>` line. Writes `evaluations/<run-id>.grade.json`. Not wired into the `arena` dispatcher; run directly.
- **`bin/judge-cap.sh <run-id> [judge-model] [--tag TAG]`** — blind N-way capability judge (default judge `claude-sonnet-5`), distinct from `judge-n.sh` (report-fluff rubric) and `evaluate.sh` (pairwise, non-blind). Scores every arm on the task's own `eval_criteria` plus correctness/completeness/evidence-fidelity in one shuffled-label call. Writes `evaluations/<run-id>.cap-<TAG>.json` (TAG defaults to the judge model ID minus `claude-`, version kept, e.g. `fable-5-1`; before 2026-09-22 the version was stripped, so `claude-fable-5` and `claude-fable-5-1` collided on `fable`), so one bake can be judged by multiple judges without clobbering. Never auto-posts to Discord. Not wired into the `arena` dispatcher; run directly.
- `grade-hidden.sh` runs the grader unconditionally, not only when the copied grader dir contains `*.py` — so a custom `grader-cmd` pointed at a node or bash grader is graded too, not just the `python3 grade.py` default.

## Discord Reporting (`bin/discord-report.sh`)

`arena discord-report <run-id>` posts evaluation results to a Discord channel. When changing this path, follow the cross-cutting Discord rules:

- **2000-character message limit.** Discord rejects messages longer than 2000 chars. `discord-report.sh` already truncates/splits content at 1990 chars and posts overflow as thread replies — keep that splitting in place; never assume a single message is enough for a long report.
- **Don't block on webhook failure.** A non-200 response or a missing bot token must log and continue, not abort the run or eval. Bakeoff execution must never be coupled to Discord availability.
- **No external posting without explicit instruction.** Discord reporting is an explicit, opt-in command (`arena discord-report`). Do not add automatic Discord posts to `run`, `eval`, or other commands, or to library code paths that run during normal A/B testing — the user retains control over when results are shared.
- **No tokens or secrets in commits.** The bot token is resolved at runtime from an env var or a local cache file; never hardcode it (this is a public repo).
- **Embed limits are separate from the message limit: an embed `description` caps at 4096 chars, and one message carries at most 10 embeds.** The 2000-char rule above governs plain `content` messages and does not protect the embed path. `bot_post_embed` in `discord-report.sh` truncates its description at 3900 — keep it under 4096, and if a report ever needs more than one embed, cap the array at 10 per send and split the rest across further sends. Discord rejects an over-long or over-full embed payload with a 400 and the eval report is lost with no visible error.
- **Every Discord API call needs a `User-Agent: DiscordBot (<url>, <version>)` header.** `discord-report.sh` and `platforms/discord.sh` hit `discord.com/api/v10/channels/{id}/messages` (post, thread-create, and message-poll) with bare `curl` that sets only `Authorization` + `Content-Type`. Discord sits behind Cloudflare bot-protection, which rejects a plain HTTP client sending no proper User-Agent with **HTTP 403 and body `{"code": 1010}`** — the request never reaches Discord, so the bot token and channel are both fine and retrying unchanged never succeeds; the eval report is silently lost. Diagnostic tell: a 403 whose body is `{"code": 1010}` with no `message` field, versus Discord's own permission failures (403 with code 50001/50013 and a human-readable message). Fix is a single header — add `-H "User-Agent: DiscordBot (https://github.com/npezarro/claude-bakeoff, 1.0)"` to every `curl` that calls the Discord API. The same header is required on any `DELETE /webhooks/{id}/{token}/messages/{id}` call.

## A per-call blind-map file clobbers the previous judge's arm mapping, silently inverting multi-judge results
claude-bakeoff bin/judge-cap.sh:70-78 truncates (: > $MAP) and RESHUFFLES runs/<id>/blind-map-cap.tsv on every invocation. The JSON output is already per-judge (.cap-<TAG>.json) but the map that DECODES it is not, so judging one run with two judges (the 2026-09-09 sonnet-5 + fable-5-1 methodology) destroys the first judge's mapping and leaves only the last call's. On 2026-09-17 run 20260917_142448 the two calls drew OPPOSITE shuffles: reading the surviving map against the first judge's scores would have reported the parity layer LOSING code-review by 5 when it actually WON by 5. Nothing errors and nothing looks wrong; the file exists and parses. Rule: any blind/randomised label map must be keyed by the same identifier as the output it decodes. Fix here: write blind-map-cap-<TAG>.tsv. Recovery for an already-clobbered map: match each verdict's distinguishing claims back to ground-truth features in the arm artifacts (e.g. which arm actually built a repro harness, which used a locale-independent month table), and seal each mapping with two independent features before trusting any score.

## A single-run judged ranking is not a decision basis; re-running the 2026-08-18 5-way with two judges inverted every position
The 2026-08-18 decision to retire parity layer v4 on Opus 5 (and to prefer the lightweight craft-v1 instead) rested on ONE isolated 5-way bakeoff on code-review, scored by a single judge: base 92 > craft 88 > review-closer 82 > v4 72. Re-run on 2026-09-17 as two independent bakeoffs, each judged blind by claude-sonnet-5 AND claude-fable-5-1, the ordering came out exactly inverted: v4 93.0 > review-closer 84.5 > craft-v1 79.5 > base 78.0, with v4 first under BOTH judges and beating base in 4 of 4 judge-cells on code-review. The layer built specifically for Opus 5 (craft-v1) scored +1.5 over no layer at all, inside noise. Judge disagreement on subjective code-review is a known ~20-point band, which is wider than every gap the 08-18 ranking was read as establishing, so that run could not support the conclusion drawn from it and a month of configuration followed from it anyway. Rules: (1) never retire or adopt on a single judged run, and never on a single judge; require at least two judges and read the SIGN agreement, not the means. (2) Prefer a judge-free objective grader where one can exist, and treat judged scores as a tiebreak. (3) Look for an objectively visible mechanism before believing a judged delta: here the winning arm demonstrably executed repros and tagged verified-vs-documented claims, which is checkable in the artifacts without any judge. (4) When a prior decision is contradicted, suspect the UNDERPOWERED prior first rather than assuming the substrate changed.
