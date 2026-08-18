#!/usr/bin/env bash
set -euo pipefail

ARENA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ARENA_ROOT/bin/lib/common.sh"

# Parse args
TASK=""
ENV_A="$(config_get env_a baseline)"
ENV_B="$(config_get env_b experimental)"
PLATFORM_A="$(config_get platform_a cli)"
PLATFORM_B="$(config_get platform_b cli)"
RUN_ID=""
export NO_OUTPUT_FOLDER=false

while [ $# -gt 0 ]; do
    case "$1" in
        --env-a)      ENV_A="$2"; shift 2 ;;
        --env-b)      ENV_B="$2"; shift 2 ;;
        --platform-a) PLATFORM_A="$2"; shift 2 ;;
        --platform-b) PLATFORM_B="$2"; shift 2 ;;
        --platforms)  PLATFORM_A="$2"; PLATFORM_B="$3"; shift 3 ;;
        --id)         RUN_ID="$2"; shift 2 ;;
        --no-output-folder) NO_OUTPUT_FOLDER=true; shift ;;
        -*)           log_error "Unknown option: $1"; exit 1 ;;
        *)            TASK="$1"; shift ;;
    esac
done

if [ -z "$TASK" ]; then
    log_error "Usage: arena bake <task> [--env-a NAME] [--env-b NAME] [--platform-a NAME] [--platform-b NAME]"
    exit 1
fi

validate_task "$TASK"
validate_env "$ENV_A"
validate_env "$ENV_B"
validate_platform "$PLATFORM_A"
validate_platform "$PLATFORM_B"

RUN_ID="${RUN_ID:-$(generate_run_id)}"
RUN_DIR="$ARENA_ROOT/$(config_get runs_dir runs)/$RUN_ID"
TASK_DIR="$ARENA_ROOT/tasks/$TASK"
TASK_FILE="$TASK_DIR/task.yaml"

CLAUDE_BIN="$(config_get claude_bin claude)"
MAX_TURNS="$(config_get claude_max_turns 10)"

# Per-task turn override: tasks/<name>/task.yaml `max_turns: N` beats config.
TASK_MAX_TURNS="$(grep -E '^max_turns:' "$TASK_FILE" 2>/dev/null | head -1 | awk '{print $2}' || true)"
if [ -n "${TASK_MAX_TURNS:-}" ]; then
    MAX_TURNS="$TASK_MAX_TURNS"
fi

# Effort passthrough: pre-set BAKE_EFFORT env wins, else config claude_effort.
export BAKE_EFFORT="${BAKE_EFFORT:-$(config_get claude_effort '')}"

# Discord platform config — secrets sourced from external .env, not committed
BAKEOFF_ENV_FILE="${BAKEOFF_ENV_FILE:-$HOME/.config/claude-bakeoff/.env}"
if [ -f "$BAKEOFF_ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$BAKEOFF_ENV_FILE"
fi
DISCORD_CHANNEL="${BAKEOFF_DISCORD_CHANNEL:-}"
DISCORD_BOT_ID="${BAKEOFF_DISCORD_BOT_ID:-}"
DISCORD_WEBHOOK_URL="${BAKEOFF_DISCORD_WEBHOOK_URL:-}"
DISCORD_TIMEOUT="$(config_get discord_timeout 300)"

log_info "Bake #$RUN_ID"
log_info "Challenge:  $TASK"
log_info "Recipe A:   $ENV_A (platform: $PLATFORM_A)"
log_info "Recipe B:   $ENV_B (platform: $PLATFORM_B)"

# Isolate the arms from the host's own instruction set before anything runs.
# Without this the comparison is between (host guidance + recipe A) and
# (host guidance + recipe B), which is not what the recipe names claim.
# ARENA_NO_ISOLATION=1 deliberately reproduces the old, leaky behaviour. The only
# honest use is as a same-day control: re-running history isolated tells you what
# changed, but model and CLI drift since the original run is confounded with the
# isolation unless you also run the leaky arm today.
ISO_CFG=""
if [ -n "${ARENA_NO_ISOLATION:-}" ]; then
    log_error "ISOLATION OFF (ARENA_NO_ISOLATION set): arms also load the host's guidance."
elif ISO_CFG="$(isolated_config_dir)"; then
    export CLAUDE_CONFIG_DIR="$ISO_CFG"
    trap 'rm -rf "$ISO_CFG"' EXIT
    log_info "Config isolated: arms see their own CLAUDE.md and no host guidance"
else
    log_error "NOT ISOLATED: no credentials file to copy. Every arm will also load"
    log_error "the host's ~/.claude/CLAUDE.md and SessionStart hooks. Results are"
    log_error "a comparison of host-guidance-plus-recipe, so say so when reporting."
fi

# Create run directory structure
mkdir -p "$RUN_DIR/env-a/workspace" "$RUN_DIR/env-b/workspace"

# Save run metadata
cat > "$RUN_DIR/meta.yaml" <<EOF
run_id: $RUN_ID
task: $TASK
env_a: $ENV_A
env_b: $ENV_B
platform_a: $PLATFORM_A
platform_b: $PLATFORM_B
started_at: $(date -Iseconds)
status: running
EOF

# Get the task prompt
PROMPT="$(get_task_prompt "$TASK_FILE")"

# Run a single environment via its platform runner
run_env() {
    local label="$1"      # env-a or env-b
    local env_name="$2"   # environment name
    local platform="$3"   # platform name
    local work_dir="$RUN_DIR/$label/workspace"
    local env_dir="$ARENA_ROOT/environments/$env_name"
    local runner="$ARENA_ROOT/platforms/${platform}.sh"

    log_info "[$label/$env_name via $platform] Prepping the station..."

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
        [ "$fname" = "model" ] && continue
        cp "$f" "$work_dir/$fname"
    done

    # Per-environment model override: environments/<name>/model holds a model ID
    # (e.g. claude-fable-5). Falls back to global claude_model from config.yaml.
    local env_model
    env_model="$(config_get claude_model "")"
    if [ -f "$env_dir/model" ]; then
        env_model="$(head -1 "$env_dir/model" | tr -d '[:space:]')"
    fi
    export BAKE_MODEL="$env_model"
    echo "model_${label//-/_}: ${env_model:-default}" >> "$RUN_DIR/meta.yaml"

    log_info "[$label/$env_name via $platform] Into the oven..."

    # Export environment for the platform runner
    export BAKE_PROMPT="$PROMPT"
    export BAKE_ENV_NAME="$env_name"
    export BAKE_CLAUDE_BIN="$CLAUDE_BIN"
    export BAKE_MAX_TURNS="$MAX_TURNS"
    export BAKE_DISCORD_CHANNEL="$DISCORD_CHANNEL"
    export BAKE_DISCORD_BOT_ID="$DISCORD_BOT_ID"
    export BAKE_DISCORD_WEBHOOK_URL="$DISCORD_WEBHOOK_URL"
    export BAKE_DISCORD_TIMEOUT="$DISCORD_TIMEOUT"

    # Run the platform runner
    "$runner" "$work_dir" \
        > "$RUN_DIR/$label/output.json" 2>"$RUN_DIR/$label/stderr.log" || true

    # Also save just the text response
    if command -v jq &>/dev/null && [ -s "$RUN_DIR/$label/output.json" ]; then
        jq -r '.result // .text // .content // .' "$RUN_DIR/$label/output.json" \
            > "$RUN_DIR/$label/response.txt" 2>/dev/null || \
            cp "$RUN_DIR/$label/output.json" "$RUN_DIR/$label/response.txt"
    else
        cp "$RUN_DIR/$label/output.json" "$RUN_DIR/$label/response.txt"
    fi

    # An arm that returned (almost) nothing is a failed run, not a terse answer, and
    # the judge cannot tell the difference: it scores the silence and reports a
    # winner. op5p2-code-review-cli shipped a verdict built on a 112-word env-a
    # against a 1352-word env-b, and the 5-vs-9 that came back was read for three
    # weeks as evidence about the recipe.
    local arm_words
    arm_words="$(wc -w < "$RUN_DIR/$label/response.txt" 2>/dev/null | tr -d ' ')"
    if [ "${arm_words:-0}" -lt 20 ]; then
        log_error "[$label/$env_name] returned $arm_words words -- treating as FAILED, not as an answer"
        log_error "[$label/$env_name] see $RUN_DIR/$label/stderr.log; judging this run compares a real answer against silence"
        echo "$arm_words words" > "$RUN_DIR/$label/FAILED"
    fi

    # Snapshot the workspace state after run (capture any files claude created/modified)
    find "$work_dir" -type f ! -name "CLAUDE.md" -newer "$RUN_DIR/meta.yaml" \
        > "$RUN_DIR/$label/changed_files.txt" 2>/dev/null || true

    log_ok "[$label/$env_name via $platform] Out of the oven"
    cd "$ARENA_ROOT"
}

# Run both environments sequentially
# (sequential to avoid Claude CLI conflicts; can parallelize later)
run_env "env-a" "$ENV_A" "$PLATFORM_A"
run_env "env-b" "$ENV_B" "$PLATFORM_B"

# Update metadata
sed -i "s/^status:.*/status: completed/" "$RUN_DIR/meta.yaml"
echo "completed_at: $(date -Iseconds)" >> "$RUN_DIR/meta.yaml"

if [ -e "$RUN_DIR/env-a/FAILED" ] || [ -e "$RUN_DIR/env-b/FAILED" ]; then
    log_error "At least one arm FAILED. Re-run it before judging; a verdict over a dead arm is not a result."
fi

log_ok "Bake $RUN_ID complete — ready for judging"
log_info "Results at: $RUN_DIR"
log_info "Run 'arena judge $RUN_ID' to send it to the judges"
