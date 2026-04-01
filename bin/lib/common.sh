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

# Collect bakeoff results into a bakeoff-<taskname>/ output folder.
# Creates individual track files, the judging results file, and (if present) the merged file.
#
# Usage: collect_output_folder <run_id>
collect_output_folder() {
    local run_id="$1"
    local runs_dir="$ARENA_ROOT/$(config_get runs_dir runs)"
    local run_dir="$runs_dir/$run_id"
    local eval_dir="$ARENA_ROOT/$(config_get evaluations_dir evaluations)"

    # Check if output folder is enabled
    local enabled
    enabled="$(config_get output_folder true)"
    if [ "$enabled" = "false" ] || [ "$enabled" = "no" ]; then
        return 0
    fi

    # Check for the NO_OUTPUT_FOLDER override (set by --no-output-folder flag)
    if [ "${NO_OUTPUT_FOLDER:-false}" = "true" ]; then
        return 0
    fi

    if [ ! -d "$run_dir" ]; then
        log_error "Run directory not found: $run_dir"
        return 1
    fi

    # Read run metadata
    local task env_a env_b
    task="$(grep '^task:' "$run_dir/meta.yaml" | sed 's/^task: *//')"
    env_a="$(grep '^env_a:' "$run_dir/meta.yaml" | sed 's/^env_a: *//')"
    env_b="$(grep '^env_b:' "$run_dir/meta.yaml" | sed 's/^env_b: *//')"

    local out_dir="$ARENA_ROOT/bakeoff-${task}"
    mkdir -p "$out_dir"

    # Track 1: env-a response (full chain of thought + output)
    if [ -f "$run_dir/env-a/response.txt" ]; then
        local track_a_file="$out_dir/track-1-${env_a}.md"
        {
            echo "# Track 1: ${env_a}"
            echo ""
            echo "**Run ID:** ${run_id}"
            echo "**Environment:** ${env_a}"
            echo ""
            echo "---"
            echo ""
            cat "$run_dir/env-a/response.txt"
        } > "$track_a_file"
    fi

    # Track 2: env-b response (full chain of thought + output)
    if [ -f "$run_dir/env-b/response.txt" ]; then
        local track_b_file="$out_dir/track-2-${env_b}.md"
        {
            echo "# Track 2: ${env_b}"
            echo ""
            echo "**Run ID:** ${run_id}"
            echo "**Environment:** ${env_b}"
            echo ""
            echo "---"
            echo ""
            cat "$run_dir/env-b/response.txt"
        } > "$track_b_file"
    fi

    # Judging results
    if [ -f "$eval_dir/${run_id}.yaml" ]; then
        cp "$eval_dir/${run_id}.yaml" "$out_dir/judging-results.yaml"
    fi
    if [ -f "$eval_dir/${run_id}_raw.txt" ]; then
        cp "$eval_dir/${run_id}_raw.txt" "$out_dir/judging-notes.md"
    fi

    # Merged / recommended materials (if merge has been run)
    if [ -f "$eval_dir/${run_id}_merged.txt" ]; then
        cp "$eval_dir/${run_id}_merged.txt" "$out_dir/merged-recommended.md"
    fi

    log_ok "Output folder: $out_dir/"
}

# Build a text catalog of all tasks (name, description, tags)
build_task_catalog() {
    local catalog=""
    for d in "$ARENA_ROOT/tasks"/*/; do
        [ -f "$d/task.yaml" ] || continue
        local name desc tags
        name="$(basename "$d")"
        desc="$(get_task_field "$d/task.yaml" "description")"
        tags="$(get_task_field "$d/task.yaml" "tags")"
        catalog+="- $name: $desc"
        [ -n "$tags" ] && catalog+=" [tags: $tags]"
        catalog+=$'\n'
    done
    printf '%s' "$catalog"
}

# Build a text catalog of all environments (name + CLAUDE.md summary)
build_env_catalog() {
    local catalog=""
    for d in "$ARENA_ROOT/environments"/*/; do
        [ -d "$d" ] || continue
        local name summary
        name="$(basename "$d")"
        if [ -f "$d/CLAUDE.md" ]; then
            summary="$(head -3 "$d/CLAUDE.md" | sed 's/^# *//' | tr '\n' ' ' | sed 's/  */ /g')"
        else
            summary="(no CLAUDE.md)"
        fi
        catalog+="- $name: $summary"
        catalog+=$'\n'
    done
    printf '%s' "$catalog"
}
