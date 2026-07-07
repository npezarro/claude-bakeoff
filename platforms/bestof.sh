#!/usr/bin/env bash
# Platform runner: BESTOF
# Runs the prompt on 2 parallel instances via agentGuidance/scripts/bestof-claude.sh,
# judges the reports with a cheap model, keeps the winner. The winner's workspace
# is copied back so the bake judge sees its artifacts.
#
# Interface (same as cli.sh):
#   args:   <workspace_dir>
#   env:    BAKE_PROMPT, BAKE_MODEL, BAKE_MAX_TURNS, BAKE_EFFORT
#   stdout: JSON with a .result field
set -euo pipefail

WORKSPACE_DIR="${1:?Usage: bestof.sh <workspace_dir>}"
PROMPT="${BAKE_PROMPT:?BAKE_PROMPT is required}"
MODEL="${BAKE_MODEL:-claude-opus-4-8}"
MAX_TURNS="${BAKE_MAX_TURNS:-45}"
BESTOF="$HOME/repos/agentGuidance/scripts/bestof-claude.sh"

ERRFILE="$(mktemp)"
REPORT="$("$BESTOF" -n 2 --model "$MODEL" --max-turns "$MAX_TURNS" \
            --workdir "$WORKSPACE_DIR" "$PROMPT" 2>"$ERRFILE")"
WINNER_DIR="$(tail -1 "$ERRFILE" | tr -d '[:space:]')"
rm -f "$ERRFILE"

if [ -d "$WINNER_DIR" ]; then
    cp -r "$WINNER_DIR/." "$WORKSPACE_DIR/"
fi

jq -n --arg r "$REPORT" '{result: $r, subtype: "success", platform: "bestof"}'
