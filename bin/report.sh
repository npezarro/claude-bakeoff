#!/usr/bin/env bash
set -euo pipefail

ARENA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ARENA_ROOT/bin/lib/common.sh"

RUN_ID="${1:-}"
if [ -z "$RUN_ID" ]; then
    log_error "Usage: arena report <run-id>"
    exit 1
fi

EVAL_DIR="$ARENA_ROOT/$(config_get evaluations_dir evaluations)"
EVAL_FILE="$EVAL_DIR/${RUN_ID}.yaml"

if [ ! -f "$EVAL_FILE" ]; then
    log_error "No evaluation found for run '$RUN_ID'"
    log_info "Run 'arena eval $RUN_ID' first"
    exit 1
fi

echo ""
echo "╔═══════════════════════════════════════════════════╗"
echo "║          THE JUDGING  —  Bake $RUN_ID"
echo "╚═══════════════════════════════════════════════════╝"
echo ""
cat "$EVAL_FILE"
echo ""
echo "─────────────────────────────────────────────────────"

# Show raw judge reasoning if available
RAW_FILE="$EVAL_DIR/${RUN_ID}_raw.txt"
if [ -f "$RAW_FILE" ]; then
    echo ""
    echo "Full judge notes: $RAW_FILE"
fi
