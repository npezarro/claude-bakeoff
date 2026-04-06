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
