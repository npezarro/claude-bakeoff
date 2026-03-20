#!/usr/bin/env bash
set -euo pipefail

ARENA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ARENA_ROOT/bin/lib/common.sh"

# Parse args
TASK=""
ENV_A="$(config_get env_a baseline)"
ENV_B="$(config_get env_b experimental)"
RUN_ID=""

while [ $# -gt 0 ]; do
    case "$1" in
        --env-a) ENV_A="$2"; shift 2 ;;
        --env-b) ENV_B="$2"; shift 2 ;;
        --id)    RUN_ID="$2"; shift 2 ;;
        -*)      log_error "Unknown option: $1"; exit 1 ;;
        *)       TASK="$1"; shift ;;
    esac
done

if [ -z "$TASK" ]; then
    log_error "Usage: arena run <task> [--env-a NAME] [--env-b NAME]"
    exit 1
fi

validate_task "$TASK"
validate_env "$ENV_A"
validate_env "$ENV_B"

RUN_ID="${RUN_ID:-$(generate_run_id)}"
RUN_DIR="$ARENA_ROOT/$(config_get runs_dir runs)/$RUN_ID"
TASK_DIR="$ARENA_ROOT/tasks/$TASK"
TASK_FILE="$TASK_DIR/task.yaml"

CLAUDE_BIN="$(config_get claude_bin claude)"
MAX_TURNS="$(config_get claude_max_turns 10)"

log_info "Run ID:  $RUN_ID"
log_info "Task:    $TASK"
log_info "Env A:   $ENV_A"
log_info "Env B:   $ENV_B"

# Create run directory structure
mkdir -p "$RUN_DIR/env-a/workspace" "$RUN_DIR/env-b/workspace"

# Save run metadata
cat > "$RUN_DIR/meta.yaml" <<EOF
run_id: $RUN_ID
task: $TASK
env_a: $ENV_A
env_b: $ENV_B
started_at: $(date -Iseconds)
status: running
EOF

# Get the task prompt
PROMPT="$(get_task_prompt "$TASK_FILE")"

# Run a single environment
run_env() {
    local label="$1"      # env-a or env-b
    local env_name="$2"   # environment name
    local work_dir="$RUN_DIR/$label/workspace"
    local env_dir="$ARENA_ROOT/environments/$env_name"

    log_info "[$label/$env_name] Setting up workspace..."

    # Copy seed files if task has them
    if [ -d "$TASK_DIR/workspace" ]; then
        cp -r "$TASK_DIR/workspace/." "$work_dir/"
    fi

    # Copy environment's CLAUDE.md into workspace
    if [ -f "$env_dir/CLAUDE.md" ]; then
        cp "$env_dir/CLAUDE.md" "$work_dir/CLAUDE.md"
    fi

    # Copy any additional environment files (configs, templates, etc.)
    for f in "$env_dir"/*; do
        [ -f "$f" ] || continue
        local fname
        fname="$(basename "$f")"
        [ "$fname" = "CLAUDE.md" ] && continue
        cp "$f" "$work_dir/$fname"
    done

    log_info "[$label/$env_name] Running Claude CLI..."

    # Run claude in the workspace directory, capture output
    cd "$work_dir"
    $CLAUDE_BIN --print \
        --max-turns "$MAX_TURNS" \
        --output-format json \
        -p "$PROMPT" \
        > "$RUN_DIR/$label/output.json" 2>"$RUN_DIR/$label/stderr.log" || true

    # Also save just the text response
    if command -v jq &>/dev/null && [ -s "$RUN_DIR/$label/output.json" ]; then
        jq -r '.result // .text // .content // .' "$RUN_DIR/$label/output.json" \
            > "$RUN_DIR/$label/response.txt" 2>/dev/null || \
            cp "$RUN_DIR/$label/output.json" "$RUN_DIR/$label/response.txt"
    else
        cp "$RUN_DIR/$label/output.json" "$RUN_DIR/$label/response.txt"
    fi

    # Snapshot the workspace state after run (capture any files claude created/modified)
    find "$work_dir" -type f ! -name "CLAUDE.md" -newer "$RUN_DIR/meta.yaml" \
        > "$RUN_DIR/$label/changed_files.txt" 2>/dev/null || true

    log_ok "[$label/$env_name] Complete"
    cd "$ARENA_ROOT"
}

# Run both environments sequentially
# (sequential to avoid Claude CLI conflicts; can parallelize later)
run_env "env-a" "$ENV_A"
run_env "env-b" "$ENV_B"

# Update metadata
sed -i "s/^status:.*/status: completed/" "$RUN_DIR/meta.yaml"
echo "completed_at: $(date -Iseconds)" >> "$RUN_DIR/meta.yaml"

log_ok "Run $RUN_ID complete"
log_info "Results at: $RUN_DIR"
log_info "Run 'arena eval $RUN_ID' to evaluate"
