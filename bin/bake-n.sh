#!/usr/bin/env bash
# N-way bake: one challenge, many recipes, one ranking.
#
# `arena bake` compares exactly two recipes, which is the right shape when the
# question is "did this change help". It is the wrong shape when the question is
# "which of these six wordings should I ship": three pairwise bakes cannot be
# stacked into one ranking, because each bake gets its own judge and judges do
# not share a scale. This runs every arm against the same challenge and hands
# all of them to one judge, once.
#
# Usage:
#   arena bake-n <task> --envs a b c d [--jobs N] [--id RUN_ID]
set -euo pipefail

ARENA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ARENA_ROOT/bin/lib/common.sh"

TASK=""
ENVS=()
RUN_ID=""
JOBS=3

while [ $# -gt 0 ]; do
    case "$1" in
        --envs)
            shift
            while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do ENVS+=("$1"); shift; done ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --id)   RUN_ID="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)     log_error "Unknown option: $1"; exit 1 ;;
        *)      TASK="$1"; shift ;;
    esac
done

[ -n "$TASK" ] || { log_error "Usage: arena bake-n <task> --envs a b c [--jobs N]"; exit 1; }
[ "${#ENVS[@]}" -ge 2 ] || { log_error "--envs needs at least two recipes"; exit 1; }

validate_task "$TASK"
for e in "${ENVS[@]}"; do validate_env "$e"; done

RUN_ID="${RUN_ID:-$(generate_run_id)}"
RUN_DIR="$ARENA_ROOT/$(config_get runs_dir runs)/$RUN_ID"
TASK_DIR="$ARENA_ROOT/tasks/$TASK"
TASK_FILE="$TASK_DIR/task.yaml"

CLAUDE_BIN="$(config_get claude_bin claude)"
MAX_TURNS="$(config_get claude_max_turns 10)"
TASK_MAX_TURNS="$(grep -E '^max_turns:' "$TASK_FILE" 2>/dev/null | head -1 | awk '{print $2}' || true)"
[ -n "${TASK_MAX_TURNS:-}" ] && MAX_TURNS="$TASK_MAX_TURNS"
export BAKE_EFFORT="${BAKE_EFFORT:-$(config_get claude_effort '')}"

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

mkdir -p "$RUN_DIR/arms"
PROMPT="$(get_task_prompt "$TASK_FILE")"

{
    echo "run_id: $RUN_ID"
    echo "task: $TASK"
    echo "arms: ${ENVS[*]}"
    echo "n_arms: ${#ENVS[@]}"
    echo "started_at: $(date -Iseconds)"
    echo "status: running"
} > "$RUN_DIR/meta.yaml"

log_info "Bake #$RUN_ID  ($TASK, ${#ENVS[@]} arms, $JOBS at a time)"

run_arm() {
    local env_name="$1"
    local arm_dir="$RUN_DIR/arms/$env_name"
    local work_dir="$arm_dir/workspace"
    local env_dir="$ARENA_ROOT/environments/$env_name"

    mkdir -p "$work_dir"
    [ -d "$TASK_DIR/workspace" ] && cp -r "$TASK_DIR/workspace/." "$work_dir/"
    [ -f "$env_dir/CLAUDE.md" ] && cp "$env_dir/CLAUDE.md" "$work_dir/CLAUDE.md"

    local env_model
    env_model="$(config_get claude_model "")"
    [ -f "$env_dir/model" ] && env_model="$(head -1 "$env_dir/model" | tr -d '[:space:]')"

    BAKE_PROMPT="$PROMPT" \
    BAKE_ENV_NAME="$env_name" \
    BAKE_CLAUDE_BIN="$CLAUDE_BIN" \
    BAKE_MAX_TURNS="$MAX_TURNS" \
    BAKE_MODEL="$env_model" \
        "$ARENA_ROOT/platforms/cli.sh" "$work_dir" \
        > "$arm_dir/output.json" 2>"$arm_dir/stderr.log" || true

    if command -v jq >/dev/null 2>&1 && [ -s "$arm_dir/output.json" ]; then
        jq -r '.result // .text // .content // .' "$arm_dir/output.json" \
            > "$arm_dir/response.txt" 2>/dev/null || cp "$arm_dir/output.json" "$arm_dir/response.txt"
    else
        cp "$arm_dir/output.json" "$arm_dir/response.txt"
    fi

    # An arm that returned nothing is not a short answer, it is a failed run.
    if [ ! -s "$arm_dir/response.txt" ]; then
        log_error "[$env_name] empty response — see $arm_dir/stderr.log"
        echo "EMPTY" > "$arm_dir/FAILED"
    else
        log_ok "[$env_name] $(wc -w < "$arm_dir/response.txt" | tr -d ' ') words"
    fi
}

running=0
for env_name in "${ENVS[@]}"; do
    run_arm "$env_name" &
    running=$((running + 1))
    if [ "$running" -ge "$JOBS" ]; then wait -n; running=$((running - 1)); fi
done
wait

sed -i "s/^status:.*/status: completed/" "$RUN_DIR/meta.yaml"
echo "completed_at: $(date -Iseconds)" >> "$RUN_DIR/meta.yaml"

FAILED="$(find "$RUN_DIR/arms" -name FAILED | wc -l | tr -d ' ')"
[ "$FAILED" = "0" ] || log_error "$FAILED arm(s) produced nothing; the ranking would be a lie. Re-run them."

log_ok "Bake $RUN_ID complete"
log_info "Results at: $RUN_DIR"
log_info "Run 'arena judge-n $RUN_ID' to rank the arms"
