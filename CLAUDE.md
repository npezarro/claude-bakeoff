# claude-bakeoff

A/B testing framework for comparing Claude CLI instruction environments. Tests different CLAUDE.md configurations against the same task to measure instruction quality.

## Architecture

- **CLI:** `arena` (symlinked to `bin/arena`, delegates to `bin/*.sh`)
- **Environments:** `environments/<name>/CLAUDE.md` — each is an isolated instruction set
- **Tasks:** `tasks/<name>/task.yaml` — prompt, eval criteria, expected behavior
- **Runs:** `runs/<timestamp>/` — captured outputs (gitignored)
- **Evaluations:** `evaluations/<timestamp>.yaml` — LLM judge verdicts (gitignored)

## Key Rules

1. **Output goes to private repos, not here.** Bakeoff results often contain proprietary content (resume text, strategy docs). Final synthesized outputs belong in privateContext or the relevant project repo, not in claude-bakeoff.
2. **Environment CLAUDE.md files are the experiment.** Don't add general agent instructions — each environment should test a specific instruction hypothesis.
3. **Baseline must stay minimal.** `environments/baseline/CLAUDE.md` is the control. Don't add rules to it.
4. **Task eval criteria drive the judge.** Write specific, measurable criteria in `task.yaml`. Vague criteria ("good quality") produce unreliable judge scores.
5. **Runs and evaluations are gitignored.** Don't force-add them. Results that matter get distilled into the environment or agentGuidance.

## Workflow

```bash
arena new env <name>        # Create environment
arena new task <name>       # Create task
arena run <task> --env-a X --env-b Y   # Execute A/B test
arena eval <run-id>         # LLM judge comparison
arena report <run-id>       # View results
arena merge <run-id>        # Synthesize best-of-both
arena auto "<prompt>"       # Quick single-prompt bakeoff
```

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
