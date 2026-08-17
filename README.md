# claude-bakeoff

A/B testing framework for comparing Claude CLI results across different instruction environments.

Run the same task under two different sets of instructions (CLAUDE.md files), capture the outputs, and use an LLM-as-judge to evaluate which environment produced the better result.

## Why

Different prompting strategies, system instructions, and context configurations can dramatically affect Claude's output quality. But the effects are often unpredictable: a change that improves code review quality might degrade debugging output. A more detailed instruction set might produce better results on complex tasks but worse results on simple ones.

This framework exists because I needed to make evidence-based decisions about instruction design before deploying changes across 27+ repositories via [agentGuidance](https://github.com/npezarro/agentGuidance). Without systematic testing, every instruction change was a gamble.

## What I've Learned

A few findings from running bakeoff tests:

- **Instruction length is not monotonically better.** Highly detailed instruction sets outperform minimal ones on complex multi-step tasks, but minimal instructions sometimes win on simple single-file edits where the extra context adds noise.
- **Behavioral constraints cascade unpredictably.** Adding a rule like "always run tests before committing" improved code quality scores but reduced task completion rates when the test suite had flaky tests. The interaction between rules matters more than any single rule.
- **LLM-as-judge scoring correlates with human preference ~80% of the time** on the rubrics I've tested (correctness, completeness, code quality, instruction adherence). The remaining 20% divergence is concentrated in subjective dimensions like "code quality" where the judge tends to prefer verbose, well-commented code over concise solutions.

## Quick Start

```bash
# Add to PATH
ln -s /path/to/claude-bakeoff/bin/arena ~/bin/arena

# Create two instruction environments
arena new env minimal
arena new env detailed
# Edit environments/minimal/CLAUDE.md and environments/detailed/CLAUDE.md

# Create a task
arena new task my-task
# Edit tasks/my-task/task.yaml with your prompt and eval criteria

# Run the A/B test
arena run my-task --env-a minimal --env-b detailed

# Evaluate with LLM-as-judge
arena eval <run-id>

# View results
arena report <run-id>
```

## How It Works

1. Creates isolated workspaces for each environment
2. Copies the environment's CLAUDE.md into each workspace
3. Points `CLAUDE_CONFIG_DIR` at a throwaway dir holding credentials and nothing else, so the arms
   read their own CLAUDE.md and not the host's global one (see **Isolation** below)
4. Runs `claude --print` with the task prompt in each workspace
5. Captures full output and any files created
6. Sends both results to an LLM judge with scoring rubric
7. Judge scores on correctness, completeness, code quality, and instruction adherence (1-10)
8. Produces a structured verdict with winner, scores, and reasoning

## Isolation

`claude --print` loads the HOST's `~/.claude/CLAUDE.md` and fires the host's SessionStart hooks in
addition to the workspace `CLAUDE.md` an arm was given. Left alone, that makes every bake a
comparison of *host guidance + recipe A* against *host guidance + recipe B*, and a deliberately
empty control recipe is not a control at all: it inherits whatever the host says.

This is not theoretical. On 2026-08-17 a six-arm bake on report writing produced a control arm that
was already clean, because the rule being tested was live in the host's own guidance and reached
every arm. Re-run with isolation, the same control arm opened with the exact failure the rule
exists to prevent. The finding flipped.

Both runners now call `isolated_config_dir` (in `bin/lib/common.sh`) before any arm starts. It
returns a `mktemp` dir containing a copy of `.credentials.json` and nothing else, exports it as
`CLAUDE_CONFIG_DIR`, and removes it on exit. The workspace `CLAUDE.md` still loads; the host's
does not. If no credentials file exists (API-key or keychain auth), the runner says loudly that
results are host-guidance-plus-recipe rather than silently measuring the wrong thing.

To verify isolation on your own machine, from an empty directory:

```bash
claude --print -p 'Answer YES or NO only. Does your context contain "<string only in your global CLAUDE.md>"?'
CLAUDE_CONFIG_DIR=$(mktemp -d) claude --print -p '...same question...'
```

Judges are isolated for a different reason: a judge that has read the host's guidance is grading
against the rule's author rather than against the rubric.

## Output Folder

By default, after judging (`arena judge`) or merging (`arena merge`), results are collected into a `bakeoff-<taskname>/` folder in the repo root. This folder contains:

- **`track-1-<env-a-name>.md`** -- Full chain of thought + output from environment A
- **`track-2-<env-b-name>.md`** -- Full chain of thought + output from environment B
- **`judging-results.yaml`** -- Structured evaluation scores and verdict
- **`judging-notes.md`** -- Raw judge reasoning (full deliberation)
- **`merged-recommended.md`** -- Synthesized best-of-both output (created after `arena merge`)

To disable this behavior:

```bash
# Per-invocation: skip the output folder
arena bake my-task --no-output-folder
arena judge 20260319_143022 --no-output-folder
arena auto "test something" --no-output-folder

# Permanently: set in config.yaml
output_folder: false
```

## Structure

```
environments/       # Named instruction sets (each contains a CLAUDE.md)
tasks/              # Task definitions (prompt, seed files, eval criteria)
runs/               # Captured outputs per run (gitignored)
evaluations/        # Judge verdicts per run (gitignored)
bin/arena           # CLI entrypoint
config.yaml         # Default settings
```

## Commands

| Command | Description |
|---------|-------------|
| `arena run <task>` | Execute a task in both environments |
| `arena eval <run-id>` | Run LLM-as-judge comparison |
| `arena report <run-id>` | Display evaluation results |
| `arena list tasks\|runs\|envs` | List available items |
| `arena new task\|env <name>` | Scaffold a new task or environment |

## Task Definition

Tasks are defined in `task.yaml`:

```yaml
name: my-task
description: What this task tests
prompt: |
  The prompt sent to Claude CLI
eval_criteria:
  - criterion one
  - criterion two
expected_behavior: |
  Description of what good output looks like
tags:
  - python
```

## Related Projects

- **[agentGuidance](https://github.com/npezarro/agentGuidance)**: The behavioral governance system whose rules this framework tests. Bakeoff results feed back into agentGuidance improvements.
- **[autonomousDev](https://github.com/npezarro/autonomousDev)**: Autonomous development agent. Runs under agentGuidance rules that were validated through bakeoff testing.

## Requirements

- [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- `jq` (optional, for JSON parsing)
- Bash 4+
