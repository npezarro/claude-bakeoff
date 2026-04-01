# claude-bakeoff

A/B testing framework for comparing Claude CLI results across different instruction environments.

Run the same task under two different sets of instructions (CLAUDE.md files), capture the outputs, and use an LLM-as-judge to evaluate which environment produced the better result.

## Why

Different prompting strategies, system instructions, and context configurations can dramatically affect Claude's output quality. This framework lets you test that systematically instead of guessing.

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

## Output Folder

By default, after judging (`arena judge`) or merging (`arena merge`), results are collected into a `bakeoff-<taskname>/` folder in the repo root. This folder contains:

- **`track-1-<env-a-name>.md`** — Full chain of thought + output from environment A
- **`track-2-<env-b-name>.md`** — Full chain of thought + output from environment B
- **`judging-results.yaml`** — Structured evaluation scores and verdict
- **`judging-notes.md`** — Raw judge reasoning (full deliberation)
- **`merged-recommended.md`** — Synthesized best-of-both output (created after `arena merge`)

To disable this behavior:

```bash
# Per-invocation: skip the output folder
arena bake my-task --no-output-folder
arena judge 20260319_143022 --no-output-folder
arena auto "test something" --no-output-folder

# Permanently: set in config.yaml
output_folder: false
```

## How It Works

1. Creates isolated workspaces for each environment
2. Copies the environment's CLAUDE.md into each workspace
3. Runs `claude --print` with the task prompt in each workspace
4. Captures full output and any files created
5. Sends both results to an LLM judge with scoring rubric
6. Judge scores on correctness, completeness, code quality, and instruction adherence (1-10)
7. Produces a structured verdict with winner, scores, and reasoning

## Requirements

- [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- `jq` (optional, for JSON parsing)
- Bash 4+
