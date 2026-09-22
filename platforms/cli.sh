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
set +e
$CLAUDE_BIN --print \
    --max-turns "$MAX_TURNS" \
    --output-format json \
    --dangerously-skip-permissions \
    "${MODEL_ARGS[@]}" \
    -p "$PROMPT"
rc=$?

# Keep the arm's session transcript next to its output (arms/<arm>/transcript/). The isolated
# CLAUDE_CONFIG_DIR is deleted when the bake ends, and `.result` holds only the FINAL assistant
# turn: an arm that wrote its deliverable and then took one more turn (e.g. after a background
# task notification) ends with a one-line "see the review above" and the deliverable is
# unrecoverable without this. The judge never sees the transcript; it grades what was delivered.
if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -d "$CLAUDE_CONFIG_DIR/projects" ]; then
    slug="$(pwd -P | sed 's/[^A-Za-z0-9]/-/g')"
    if [ -d "$CLAUDE_CONFIG_DIR/projects/$slug" ]; then
        mkdir -p ../transcript && cp "$CLAUDE_CONFIG_DIR/projects/$slug"/*.jsonl ../transcript/ 2>/dev/null
    fi
fi
exit $rc
