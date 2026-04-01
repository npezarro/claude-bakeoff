#!/usr/bin/env bash
set -euo pipefail

ARENA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ARENA_ROOT/bin/lib/common.sh"

# Parse args
DESCRIPTION=""
NO_JUDGE=false
DRY_RUN=false
PLATFORM_A=""
PLATFORM_B=""
export NO_OUTPUT_FOLDER=false

while [ $# -gt 0 ]; do
    case "$1" in
        --no-judge)    NO_JUDGE=true; shift ;;
        --dry-run)     DRY_RUN=true; shift ;;
        --no-output-folder) NO_OUTPUT_FOLDER=true; shift ;;
        --platform-a)  PLATFORM_A="$2"; shift 2 ;;
        --platform-b)  PLATFORM_B="$2"; shift 2 ;;
        --platforms)   PLATFORM_A="$2"; PLATFORM_B="$3"; shift 3 ;;
        -h|--help)
            echo "Usage: arena auto \"<description>\" [--no-judge] [--dry-run] [--no-output-folder] [--platform-a NAME] [--platform-b NAME]"
            echo ""
            echo "Describe what you want to test. Claude designs the experiment and runs it."
            echo ""
            echo "Options:"
            echo "  --no-judge          Skip auto-judging after bake"
            echo "  --dry-run           Show experiment design without running"
            echo "  --no-output-folder  Skip creating bakeoff-<task>/ output folder"
            echo "  --platform-a        Override platform A (default: cli)"
            echo "  --platform-b        Override platform B (default: cli)"
            exit 0
            ;;
        -*)            log_error "Unknown option: $1"; exit 1 ;;
        *)             DESCRIPTION="$1"; shift ;;
    esac
done

if [ -z "$DESCRIPTION" ]; then
    log_error "Usage: arena auto \"<description>\" [--no-judge] [--dry-run]"
    log_error "Describe what you want to test in natural language."
    exit 1
fi

CLAUDE_BIN="$(config_get claude_bin claude)"
RUN_ID="$(generate_run_id)"

log_info "Designing experiment for: $DESCRIPTION"

# Build catalogs
TASK_CATALOG="$(build_task_catalog)"
ENV_CATALOG="$(build_env_catalog)"

# Build the planner prompt
PLANNER_PROMPT="$(cat <<PLANNER_EOF
You are designing an A/B test experiment for comparing Claude instruction environments.

## Available Tasks
$TASK_CATALOG

## Available Environments
$ENV_CATALOG

## User's Request
$DESCRIPTION

## Instructions

Select the best existing task and two environments to compare for this experiment. Consider:
- Which task type best exercises what the user wants to test
- Which two environments create the most meaningful comparison
- The environments should differ in a way that's relevant to the user's question

If NO existing task is a good fit, set task to GENERATE and provide a full task.yaml under generated_task.

Output ONLY this YAML block (no markdown fences, no extra text):

task: <existing task name OR "GENERATE">
env_a: <environment name>
env_b: <environment name>
rationale: <one sentence explaining the experiment design>
generated_task: |
  <full task.yaml content, only if task is GENERATE; omit this field entirely otherwise>
PLANNER_EOF
)"

# Ask Claude to design the experiment
log_info "Consulting Claude on experiment design..."
PLAN_OUTPUT="$($CLAUDE_BIN --print -p "$PLANNER_PROMPT" 2>/dev/null)" || {
    log_error "Failed to get experiment design from Claude"
    exit 1
}

# Parse the structured output
TASK="$(echo "$PLAN_OUTPUT" | grep '^task:' | head -1 | sed 's/^task: *//' | sed 's/ *$//')"
ENV_A="$(echo "$PLAN_OUTPUT" | grep '^env_a:' | head -1 | sed 's/^env_a: *//' | sed 's/ *$//')"
ENV_B="$(echo "$PLAN_OUTPUT" | grep '^env_b:' | head -1 | sed 's/^env_b: *//' | sed 's/ *$//')"
RATIONALE="$(echo "$PLAN_OUTPUT" | grep '^rationale:' | head -1 | sed 's/^rationale: *//')"

if [ -z "$TASK" ] || [ -z "$ENV_A" ] || [ -z "$ENV_B" ]; then
    log_error "Could not parse experiment design from Claude's response"
    log_error "Raw output:"
    echo "$PLAN_OUTPUT" >&2
    exit 1
fi

# Display the experiment design
echo ""
log_info "=== Experiment Design ==="
log_info "Task:        $TASK"
log_info "Environment A: $ENV_A"
log_info "Environment B: $ENV_B"
log_info "Rationale:   $RATIONALE"
echo ""

# Handle generated tasks
if [ "$TASK" = "GENERATE" ]; then
    TASK_NAME="auto-$RUN_ID"
    TASK_DIR="$ARENA_ROOT/tasks/$TASK_NAME"
    mkdir -p "$TASK_DIR"

    # Extract the generated task.yaml content (everything after generated_task: |)
    GENERATED="$(echo "$PLAN_OUTPUT" | awk '
        /^generated_task:/ { capture = 1; next }
        capture {
            if (/^[a-z_]+:/ && !/^  /) exit
            sub(/^  /, "")
            print
        }
    ')"

    if [ -z "$GENERATED" ]; then
        log_error "Claude indicated GENERATE but provided no task.yaml content"
        exit 1
    fi

    echo "$GENERATED" > "$TASK_DIR/task.yaml"
    TASK="$TASK_NAME"
    log_ok "Generated task: $TASK_DIR/task.yaml"
fi

# Dry run — stop here
if [ "$DRY_RUN" = true ]; then
    log_info "(dry run — not executing)"
    if [ -f "$ARENA_ROOT/tasks/$TASK/task.yaml" ]; then
        echo ""
        log_info "Task prompt preview:"
        get_task_prompt "$ARENA_ROOT/tasks/$TASK/task.yaml" | head -10
        echo "..."
    fi
    exit 0
fi

# Build bake args
BAKE_ARGS=("$TASK" "--env-a" "$ENV_A" "--env-b" "$ENV_B" "--id" "$RUN_ID")
[ -n "$PLATFORM_A" ] && BAKE_ARGS+=("--platform-a" "$PLATFORM_A")
[ -n "$PLATFORM_B" ] && BAKE_ARGS+=("--platform-b" "$PLATFORM_B")

# Run the bake
log_info "Firing up the oven..."
"$ARENA_ROOT/bin/run.sh" "${BAKE_ARGS[@]}"

# Auto-judge unless skipped
if [ "$NO_JUDGE" = false ]; then
    echo ""
    log_info "Sending to the judges..."
    "$ARENA_ROOT/bin/evaluate.sh" "$RUN_ID"
fi

log_ok "Auto bakeoff complete: $RUN_ID"
