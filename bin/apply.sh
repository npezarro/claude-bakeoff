#!/usr/bin/env bash
set -euo pipefail

ARENA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ARENA_ROOT/bin/lib/common.sh"

# Parse args
RUN_ID=""
PROFILE_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            PROFILE_NAME="${2:-}"
            if [ -z "$PROFILE_NAME" ]; then
                log_error "--profile requires a name"
                exit 1
            fi
            shift 2
            ;;
        -*)
            log_error "Unknown flag: $1"
            exit 1
            ;;
        *)
            RUN_ID="$1"
            shift
            ;;
    esac
done

if [ -z "$RUN_ID" ]; then
    log_error "Usage: arena apply <run-id> --profile <name>"
    exit 1
fi

if [ -z "$PROFILE_NAME" ]; then
    log_error "Usage: arena apply <run-id> --profile <name>"
    log_error "--profile is required"
    exit 1
fi

RUNS_DIR="$ARENA_ROOT/$(config_get runs_dir runs)"
RUN_DIR="$RUNS_DIR/$RUN_ID"
EVAL_DIR="$ARENA_ROOT/$(config_get evaluations_dir evaluations)"
GUIDANCE_DIR="$HOME/repos/agentGuidance"
PROFILE_DIR="$GUIDANCE_DIR/profiles/$PROFILE_NAME"

# Validate run exists
if [ ! -d "$RUN_DIR" ]; then
    log_error "Run '$RUN_ID' not found at $RUN_DIR"
    exit 1
fi

# Validate profile exists
if [ ! -d "$PROFILE_DIR" ]; then
    log_error "Profile '$PROFILE_NAME' not found at $PROFILE_DIR"
    exit 1
fi

# Find the best available evaluation source: merged > eval
MERGED_FILE="$EVAL_DIR/${RUN_ID}_merged.txt"
EVAL_FILE="$EVAL_DIR/${RUN_ID}.yaml"

if [ -f "$MERGED_FILE" ]; then
    log_info "Using merged evaluation: $MERGED_FILE"
    EVAL_CONTENT="$(cat "$MERGED_FILE")"
elif [ -f "$EVAL_FILE" ]; then
    log_info "Using evaluation: $EVAL_FILE"
    EVAL_CONTENT="$(cat "$EVAL_FILE")"
else
    log_error "No evaluation found for $RUN_ID"
    log_error "Expected: $MERGED_FILE or $EVAL_FILE"
    log_error "Run 'arena judge $RUN_ID' first"
    exit 1
fi

# Read run metadata
TASK="$(grep '^task:' "$RUN_DIR/meta.yaml" | sed 's/^task: *//')"
TASK_FILE="$ARENA_ROOT/tasks/$TASK/task.yaml"

# Get task prompt
TASK_PROMPT="$(get_task_prompt "$TASK_FILE")"

# Read current experience log
EXPERIENCE_FILE="$PROFILE_DIR/experience.md"
if [ -f "$EXPERIENCE_FILE" ]; then
    CURRENT_EXPERIENCE="$(cat "$EXPERIENCE_FILE")"
else
    CURRENT_EXPERIENCE="(no experience log yet)"
fi

CLAUDE_BIN="$(config_get claude_bin claude)"

log_info "Applying bakeoff learnings from $RUN_ID to profile $PROFILE_NAME"
log_info "Task: $TASK"

# Build the extraction prompt
EXTRACT_PROMPT="$(cat <<EXTRACT_EOF
Here is a bakeoff result (task + evaluation/merge). Extract 1-3 durable learnings that should be added to this agent profile's experience log.

## Task
$TASK_PROMPT

## Evaluation / Merge Result
<evaluation>
$EVAL_CONTENT
</evaluation>

## Current Experience Log
<experience>
$CURRENT_EXPERIENCE
</experience>

## Instructions

Format each learning as a single line in this pipe-delimited format:
$(date +%Y-%m-%d) | bakeoff/$TASK | What worked | What didn't | Learned

Rules:
- Only extract genuinely novel patterns not already captured in the experience log above.
- Each line must be self-contained and actionable.
- Output ONLY the formatted lines, nothing else. No headers, no explanations, no markdown fences.
- If there are no novel learnings, output exactly: (no new learnings)
EXTRACT_EOF
)"

log_info "Extracting learnings..."

LEARNINGS="$($CLAUDE_BIN --print -p "$EXTRACT_PROMPT" 2>/dev/null)" || {
    log_error "Failed to extract learnings"
    exit 1
}

# Check if there are actual learnings
if [ "$LEARNINGS" = "(no new learnings)" ]; then
    log_info "No novel learnings to apply — profile is already up to date"
    exit 0
fi

# Append to experience.md
echo "" >> "$EXPERIENCE_FILE"
echo "$LEARNINGS" >> "$EXPERIENCE_FILE"

log_ok "Appended learnings to $EXPERIENCE_FILE"

# Commit and push in agentGuidance
cd "$GUIDANCE_DIR"
git add "profiles/$PROFILE_NAME/experience.md"
git commit -m "Apply bakeoff learnings from $RUN_ID to $PROFILE_NAME"
git push

log_ok "Committed and pushed to agentGuidance"
log_ok "Applied bakeoff learnings from $RUN_ID to $PROFILE_NAME"
