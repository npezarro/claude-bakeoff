#!/usr/bin/env bash
# Platform runner: CLI
# Runs the prompt via `claude --print` locally.
#
# Interface:
#   stdin:  (unused)
#   args:   <workspace_dir>
#   env:    BAKE_PROMPT, BAKE_ENV_NAME, BAKE_CLAUDE_BIN, BAKE_MAX_TURNS
#   stdout: JSON output from claude CLI
#   exit:   0 on success

set -euo pipefail

WORKSPACE_DIR="${1:?Usage: cli.sh <workspace_dir>}"
CLAUDE_BIN="${BAKE_CLAUDE_BIN:-claude}"
MAX_TURNS="${BAKE_MAX_TURNS:-10}"
PROMPT="${BAKE_PROMPT:?BAKE_PROMPT is required}"

cd "$WORKSPACE_DIR"
exec $CLAUDE_BIN --print \
    --max-turns "$MAX_TURNS" \
    --output-format json \
    -p "$PROMPT"
