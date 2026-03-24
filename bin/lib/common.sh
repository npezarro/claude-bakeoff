#!/usr/bin/env bash
# Shared utilities for claude-bakeoff

ARENA_ROOT="${ARENA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Parse config.yaml (simple key: value parser, no yq dependency)
config_get() {
    local key="$1"
    local default="${2:-}"
    local val
    val=$(grep "^${key}:" "$ARENA_ROOT/config.yaml" 2>/dev/null | head -1 | sed 's/^[^:]*: *//' | sed 's/ *#.*//' | sed 's/^"//' | sed 's/"$//')
    if [ -z "$val" ] || [ "$val" = '""' ]; then
        echo "$default"
    else
        echo "$val"
    fi
}

# Generate a run ID
generate_run_id() {
    date +%Y%m%d_%H%M%S
}

# Logging
log_info()  { echo "[tent] $*"; }
log_error() { echo "[tent] ERROR: $*" >&2; }
log_ok()    { echo "[tent] ✓ $*"; }

# Validate a task exists
validate_task() {
    local task="$1"
    local task_dir="$ARENA_ROOT/tasks/$task"
    if [ ! -f "$task_dir/task.yaml" ]; then
        log_error "Task '$task' not found at $task_dir/task.yaml"
        exit 1
    fi
}

# Validate an environment exists
validate_env() {
    local env="$1"
    local env_dir="$ARENA_ROOT/environments/$env"
    if [ ! -d "$env_dir" ]; then
        log_error "Recipe '$env' not found at $env_dir"
        exit 1
    fi
}

# Validate a platform runner exists
validate_platform() {
    local platform="$1"
    local runner="$ARENA_ROOT/platforms/${platform}.sh"
    if [ ! -f "$runner" ]; then
        log_error "Platform '$platform' not found at $runner"
        log_info "Available platforms: $(ls "$ARENA_ROOT/platforms/"*.sh 2>/dev/null | xargs -I{} basename {} .sh | tr '\n' ' ')"
        exit 1
    fi
}

# Extract prompt from task.yaml
# Handles multi-line YAML scalar (prompt: |)
get_task_prompt() {
    local task_file="$1"
    awk '
        /^prompt:/ {
            # Check for inline value
            sub(/^prompt: */, "")
            if ($0 == "|" || $0 == ">") {
                capture = 1
                next
            }
            if ($0 != "") { print $0; exit }
            next
        }
        capture {
            if (/^[a-z_]+:/ && !/^  /) exit
            sub(/^  /, "")
            print
        }
    ' "$task_file"
}

# Extract a simple field from task.yaml
get_task_field() {
    local task_file="$1"
    local field="$2"
    grep "^${field}:" "$task_file" | head -1 | sed "s/^${field}: *//"
}

# Get multi-line block field (like eval_criteria or expected_behavior)
get_task_block() {
    local task_file="$1"
    local field="$2"
    awk -v f="$field" '
        $0 ~ "^"f":" {
            sub(/^[^:]*: */, "")
            if ($0 == "|" || $0 == ">") { capture = 1; next }
            if ($0 != "") { print $0; exit }
            next
        }
        capture {
            if (/^[a-z_]+:/ && !/^  /) exit
            sub(/^  /, "")
            print
        }
    ' "$task_file"
}
