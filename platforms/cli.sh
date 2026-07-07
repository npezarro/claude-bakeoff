#!/usr/bin/env bash
# Platform runner: CLI
# Runs the prompt via `claude --print` locally.
#
# Interface:
#   stdin:  (unused)
#   args:   <workspace_dir>
#   env:    BAKE_PROMPT, BAKE_ENV_NAME, BAKE_CLAUDE_BIN, BAKE_MAX_TURNS, BAKE_MODEL
#   stdout: JSON output from claude CLI
#   exit:   0 on success

set -euo pipefail

WORKSPACE_DIR="${1:?Usage: cli.sh <workspace_dir>}"
CLAUDE_BIN="${BAKE_CLAUDE_BIN:-claude}"
MAX_TURNS="${BAKE_MAX_TURNS:-10}"
PROMPT="${BAKE_PROMPT:?BAKE_PROMPT is required}"
MODEL="${BAKE_MODEL:-}"
EFFORT="${BAKE_EFFORT:-}"

MODEL_ARGS=()
if [ -n "$MODEL" ]; then
    MODEL_ARGS=(--model "$MODEL")
fi
if [ -n "$EFFORT" ]; then
    MODEL_ARGS+=(--effort "$EFFORT")
fi

cd "$WORKSPACE_DIR"
# Bakes run headless in isolated throwaway workspaces: nobody is present to
# approve tool permissions, so a run without bypass gets crippled (agents can't
# write files or execute code) and the comparison is invalid.
exec $CLAUDE_BIN --print \
    --max-turns "$MAX_TURNS" \
    --output-format json \
    --dangerously-skip-permissions \
    "${MODEL_ARGS[@]}" \
    -p "$PROMPT"
