#!/usr/bin/env bash
# Platform runner: VERIFIED — worker + fresh-context evidence verifier.
# Runs the task normally, then verify-report.sh (read+execute-only agent)
# re-runs the project's checks in the finished workspace and its evidence
# block is appended to the final report. Attacks the long-horizon residual
# (evidence not surviving into the final message) with architecture.
#
# Interface (same as cli.sh): args <workspace_dir>; env BAKE_PROMPT, BAKE_MODEL,
# BAKE_MAX_TURNS, BAKE_EFFORT; stdout JSON with .result.
set -euo pipefail

WORKSPACE_DIR="${1:?Usage: verified.sh <workspace_dir>}"
PROMPT="${BAKE_PROMPT:?BAKE_PROMPT is required}"
MODEL="${BAKE_MODEL:-claude-opus-4-8}"
MAX_TURNS="${BAKE_MAX_TURNS:-45}"
VERIFIER="$HOME/repos/agentGuidance/scripts/verify-report.sh"

cd "$WORKSPACE_DIR"
EFFORT_ARGS=()
[ -n "${BAKE_EFFORT:-}" ] && EFFORT_ARGS=(--effort "$BAKE_EFFORT")

OUT="$(mktemp)"
claude --print --max-turns "$MAX_TURNS" --output-format json \
    --dangerously-skip-permissions --model "$MODEL" "${EFFORT_ARGS[@]}" \
    -p "$PROMPT" > "$OUT" 2>/dev/null || true
REPORT="$(jq -r '.result // empty' "$OUT" 2>/dev/null || true)"
rm -f "$OUT"
if [ -z "$REPORT" ]; then
    jq -n '{result: "VERIFIED PLATFORM FAILED: worker produced no result", is_error: true}'; exit 0
fi

EVIDENCE="$("$VERIFIER" "$WORKSPACE_DIR" "$PROMPT" 2>/dev/null || echo "VERIFIER FAILED")"

FINAL="$REPORT

---
## Independent verification (fresh-context agent, read+execute only)

$EVIDENCE"

jq -n --arg r "$FINAL" '{result: $r, subtype: "success", platform: "verified"}'
