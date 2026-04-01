#!/usr/bin/env bash
set -euo pipefail

ARENA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ARENA_ROOT/bin/lib/common.sh"

# Parse args
RUN_ID=""
export NO_OUTPUT_FOLDER="${NO_OUTPUT_FOLDER:-false}"

while [ $# -gt 0 ]; do
    case "$1" in
        --no-output-folder) NO_OUTPUT_FOLDER=true; shift ;;
        -*)                 log_error "Unknown option: $1"; exit 1 ;;
        *)                  RUN_ID="$1"; shift ;;
    esac
done

if [ -z "$RUN_ID" ]; then
    log_error "Usage: arena merge <run-id> [--no-output-folder]"
    exit 1
fi

RUNS_DIR="$ARENA_ROOT/$(config_get runs_dir runs)"
RUN_DIR="$RUNS_DIR/$RUN_ID"
EVAL_DIR="$ARENA_ROOT/$(config_get evaluations_dir evaluations)"
EVAL_FILE="$EVAL_DIR/${RUN_ID}.yaml"

if [ ! -d "$RUN_DIR" ]; then
    log_error "Run '$RUN_ID' not found at $RUN_DIR"
    exit 1
fi

if [ ! -f "$EVAL_FILE" ]; then
    log_error "Evaluation not found at $EVAL_FILE — run 'arena judge $RUN_ID' first"
    exit 1
fi

# Read run metadata
TASK="$(grep '^task:' "$RUN_DIR/meta.yaml" | sed 's/^task: *//')"
ENV_A="$(grep '^env_a:' "$RUN_DIR/meta.yaml" | sed 's/^env_a: *//')"
ENV_B="$(grep '^env_b:' "$RUN_DIR/meta.yaml" | sed 's/^env_b: *//')"
TASK_FILE="$ARENA_ROOT/tasks/$TASK/task.yaml"

CLAUDE_BIN="$(config_get claude_bin claude)"

log_info "Merging bake $RUN_ID"
log_info "Challenge: $TASK | Recipe A: $ENV_A | Recipe B: $ENV_B"

# Gather responses
RESPONSE_A="$(cat "$RUN_DIR/env-a/response.txt" 2>/dev/null || echo "(no response captured)")"
RESPONSE_B="$(cat "$RUN_DIR/env-b/response.txt" 2>/dev/null || echo "(no response captured)")"

# Read the evaluation
EVALUATION="$(cat "$EVAL_FILE")"

# Get task context
TASK_PROMPT="$(get_task_prompt "$TASK_FILE")"

# Build the merge prompt
MERGE_PROMPT="$(cat <<MERGE_EOF
You are synthesizing the best elements from two AI responses that were evaluated in a bakeoff.
Your goal is to produce a single merged response that combines the strongest elements from each.

## Original Task
$TASK_PROMPT

## Judge's Evaluation
<evaluation>
$EVALUATION
</evaluation>

## Response A ("$ENV_A")
<response_a>
$RESPONSE_A
</response_a>

## Response B ("$ENV_B")
<response_b>
$RESPONSE_B
</response_b>

## Instructions

1. Review both responses and the judge's evaluation carefully.
2. Identify the strongest elements from each response — unique insights, better explanations, stronger recommendations, more thorough coverage.
3. Produce a single merged response that combines the best of both.
4. For each major section or point in your merged response, tag its source using inline markers:
   - [from-a] — taken primarily from Response A
   - [from-b] — taken primarily from Response B
   - [synthesized] — a new insight that emerged from combining both perspectives
5. At the end, include a brief "## Merge Notes" section listing what was taken from each source and why.

Write the merged response now.
MERGE_EOF
)"

log_info "Synthesizing the best of both recipes..."

# Run the merge
MERGE_OUTPUT="$($CLAUDE_BIN --print -p "$MERGE_PROMPT" 2>/dev/null)" || {
    log_error "Merge failed"
    exit 1
}

# Save the merged result
MERGE_FILE="$EVAL_DIR/${RUN_ID}_merged.txt"
cat > "$MERGE_FILE" <<EOF
# Merged Response: $RUN_ID
# Task: $TASK
# Sources: $ENV_A (env-a) + $ENV_B (env-b)
# Merged at: $(date -Iseconds)

$MERGE_OUTPUT
EOF

log_ok "Merge complete: $MERGE_FILE"

# Post to Discord if the discord-report script exists
if [ -f "$ARENA_ROOT/bin/discord-report.sh" ]; then
    log_info "Posting merge results to Discord..."
    "$ARENA_ROOT/bin/discord-report.sh" "$RUN_ID" || log_error "Discord report failed (non-fatal)"
fi

# Update the output folder with the merged file
collect_output_folder "$RUN_ID"
