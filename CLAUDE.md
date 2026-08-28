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

## Discord Reporting (`bin/discord-report.sh`)

`arena discord-report <run-id>` posts evaluation results to a Discord channel. When changing this path, follow the cross-cutting Discord rules:

- **2000-character message limit.** Discord rejects messages longer than 2000 chars. `discord-report.sh` already truncates/splits content at 1990 chars and posts overflow as thread replies — keep that splitting in place; never assume a single message is enough for a long report.
- **Don't block on webhook failure.** A non-200 response or a missing bot token must log and continue, not abort the run or eval. Bakeoff execution must never be coupled to Discord availability.
- **No external posting without explicit instruction.** Discord reporting is an explicit, opt-in command (`arena discord-report`). Do not add automatic Discord posts to `run`, `eval`, or other commands, or to library code paths that run during normal A/B testing — the user retains control over when results are shared.
- **No tokens or secrets in commits.** The bot token is resolved at runtime from an env var or a local cache file; never hardcode it (this is a public repo).
- **Embed limits are separate from the message limit: an embed `description` caps at 4096 chars, and one message carries at most 10 embeds.** The 2000-char rule above governs plain `content` messages and does not protect the embed path. `bot_post_embed` in `discord-report.sh` truncates its description at 3900 — keep it under 4096, and if a report ever needs more than one embed, cap the array at 10 per send and split the rest across further sends. Discord rejects an over-long or over-full embed payload with a 400 and the eval report is lost with no visible error.
