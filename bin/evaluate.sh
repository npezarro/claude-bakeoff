#!/usr/bin/env bash
set -euo pipefail

ARENA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ARENA_ROOT/bin/lib/common.sh"

# Parse args
RUN_ID=""
export NO_OUTPUT_FOLDER="${NO_OUTPUT_FOLDER:-false}"

JUDGE_MODEL_OVERRIDE=""
EVAL_SUFFIX=""
while [ $# -gt 0 ]; do
    case "$1" in
        --no-output-folder) NO_OUTPUT_FOLDER=true; shift ;;
        --judge-model)      JUDGE_MODEL_OVERRIDE="$2"; shift 2 ;;
        --suffix)           EVAL_SUFFIX="$2"; shift 2 ;;
        -*)                 log_error "Unknown option: $1"; exit 1 ;;
        *)                  RUN_ID="$1"; shift ;;
    esac
done

if [ -z "$RUN_ID" ]; then
    log_error "Usage: arena eval <run-id> [--no-output-folder]"
    exit 1
fi

RUNS_DIR="$ARENA_ROOT/$(config_get runs_dir runs)"
RUN_DIR="$RUNS_DIR/$RUN_ID"
EVAL_DIR="$ARENA_ROOT/$(config_get evaluations_dir evaluations)"

if [ ! -d "$RUN_DIR" ]; then
    log_error "Run '$RUN_ID' not found at $RUN_DIR"
    exit 1
fi

# Read run metadata
TASK="$(grep '^task:' "$RUN_DIR/meta.yaml" | sed 's/^task: *//')"
ENV_A="$(grep '^env_a:' "$RUN_DIR/meta.yaml" | sed 's/^env_a: *//')"
ENV_B="$(grep '^env_b:' "$RUN_DIR/meta.yaml" | sed 's/^env_b: *//')"
PLATFORM_A="$(grep '^platform_a:' "$RUN_DIR/meta.yaml" | sed 's/^platform_a: *//' || echo "cli")"
PLATFORM_B="$(grep '^platform_b:' "$RUN_DIR/meta.yaml" | sed 's/^platform_b: *//' || echo "cli")"
TASK_FILE="$ARENA_ROOT/tasks/$TASK/task.yaml"

CLAUDE_BIN="$(config_get claude_bin claude)"

log_info "Judging bake $RUN_ID"
log_info "Challenge: $TASK | Recipe A: $ENV_A ($PLATFORM_A) | Recipe B: $ENV_B ($PLATFORM_B)"

# Gather responses
RESPONSE_A="$(cat "$RUN_DIR/env-a/response.txt" 2>/dev/null || echo "(no response captured)")"
RESPONSE_B="$(cat "$RUN_DIR/env-b/response.txt" 2>/dev/null || echo "(no response captured)")"

# Gather workspace diffs (files created/changed by each env).
# Capped and junk-excluded: a 14MB node_modules workspace once blew the argv
# limit and silently killed the judge (e1-multi/mh1, 2026-07-06).
dump_workspace() {
    local dir="$1"
    find "$dir" -type f ! -name 'CLAUDE.md' \
        ! -path '*node_modules*' ! -path '*/.git/*' ! -path '*__pycache__*' \
        ! -name '*.db' ! -name '*.sqlite*' ! -name '*.lock' ! -name 'package-lock.json' \
        ! -name '*.png' ! -name '*.jpg' ! -name '*.gif' \
        -size -200k -print0 2>/dev/null | sort -z | while IFS= read -r -d '' f; do
            echo "--- $f ---"
            head -c 6000 "$f"
            if [ "$(wc -c < "$f")" -gt 6000 ]; then echo; echo "... [truncated at 6KB]"; fi
            echo
    done | head -c 300000
}
WORKSPACE_A=""
WORKSPACE_B=""
if [ -d "$RUN_DIR/env-a/workspace" ]; then
    WORKSPACE_A="$(dump_workspace "$RUN_DIR/env-a/workspace")"
    [ -n "$WORKSPACE_A" ] || WORKSPACE_A="(empty)"
fi
if [ -d "$RUN_DIR/env-b/workspace" ]; then
    WORKSPACE_B="$(dump_workspace "$RUN_DIR/env-b/workspace")"
    [ -n "$WORKSPACE_B" ] || WORKSPACE_B="(empty)"
fi

# Get task context
TASK_PROMPT="$(get_task_prompt "$TASK_FILE")"
EXPECTED="$(get_task_block "$TASK_FILE" "expected_behavior")"
EVAL_CRITERIA="$(get_task_block "$TASK_FILE" "eval_criteria")"

# Global criteria from config
GLOBAL_CRITERIA="$(config_get judge_criteria '')"

# Build the judge prompt
JUDGE_PROMPT="$(cat <<JUDGE_EOF
You are an impartial judge evaluating two AI assistant responses to the same task.
The responses were generated under different configurations. Evaluate purely on merit.

## Configuration
- Environment A: "$ENV_A" instruction set, running on **$PLATFORM_A** platform
- Environment B: "$ENV_B" instruction set, running on **$PLATFORM_B** platform

Note: If the platforms differ (e.g., CLI vs Discord), consider that platform differences may
affect response format, length, and tool availability. Judge the quality of the answer itself,
not limitations imposed by the platform.

## Task Given
$TASK_PROMPT

## Expected Behavior
$EXPECTED

## Evaluation Criteria
Global: $GLOBAL_CRITERIA
Task-specific:
$EVAL_CRITERIA

## Environment A Response ("$ENV_A" via $PLATFORM_A)
<response_a>
$RESPONSE_A
</response_a>

### Files produced by Environment A:
<workspace_a>
$WORKSPACE_A
</workspace_a>

## Environment B Response ("$ENV_B" via $PLATFORM_B)
<response_b>
$RESPONSE_B
</response_b>

### Files produced by Environment B:
<workspace_b>
$WORKSPACE_B
</workspace_b>

## Your Evaluation

Provide your evaluation in EXACTLY this YAML format:

\`\`\`yaml
summary: |
  <2-3 sentence overall comparison>

scores:
  env_a:
    correctness: <1-10>
    completeness: <1-10>
    code_quality: <1-10>
    adherence_to_instructions: <1-10>
    overall: <1-10>
    strengths: |
      <bullet points>
    weaknesses: |
      <bullet points>
  env_b:
    correctness: <1-10>
    completeness: <1-10>
    code_quality: <1-10>
    adherence_to_instructions: <1-10>
    overall: <1-10>
    strengths: |
      <bullet points>
    weaknesses: |
      <bullet points>

winner: <env_a|env_b|tie>
winner_reason: |
  <1-2 sentences explaining the decision>
\`\`\`
JUDGE_EOF
)"

# A judge that has read the host's guidance grades against whatever the host
# believes instead of against the rubric. Same isolation the arms get.
JUDGE_CFG=""
if [ -n "${ARENA_NO_ISOLATION:-}" ]; then
    log_error "ISOLATION OFF (ARENA_NO_ISOLATION set): the judge also reads the host's guidance."
elif JUDGE_CFG="$(isolated_config_dir)"; then
    export CLAUDE_CONFIG_DIR="$JUDGE_CFG"
    trap 'rm -rf "$JUDGE_CFG"' EXIT
else
    log_error "NOT ISOLATED: the judge will also read the host's guidance."
fi

log_info "The judges are deliberating..."

mkdir -p "$EVAL_DIR"

# Run the judge
JUDGE_MODEL="${JUDGE_MODEL_OVERRIDE:-$(config_get judge_model "")}"
JUDGE_MODEL_ARGS=()
if [ -n "$JUDGE_MODEL" ]; then
    JUDGE_MODEL_ARGS=(--model "$JUDGE_MODEL")
fi
JUDGE_OUTPUT="$(printf '%s' "$JUDGE_PROMPT" | $CLAUDE_BIN --print "${JUDGE_MODEL_ARGS[@]}" 2>/dev/null)" || {
    log_error "The judges couldn't reach a verdict"
    exit 1
}

# Save raw judge output
echo "$JUDGE_OUTPUT" > "$EVAL_DIR/${RUN_ID}${EVAL_SUFFIX}_raw.txt"

# Extract YAML block from judge output
EVAL_YAML="$(echo "$JUDGE_OUTPUT" | sed -n '/^```yaml/,/^```/p' | sed '1d;$d')"

if [ -z "$EVAL_YAML" ]; then
    # Fallback: maybe the judge returned plain YAML without fences
    EVAL_YAML="$JUDGE_OUTPUT"
fi

# Save structured evaluation
cat > "$EVAL_DIR/${RUN_ID}${EVAL_SUFFIX}.yaml" <<EOF
run_id: $RUN_ID
judge_model: ${JUDGE_MODEL:-default}
task: $TASK
env_a: $ENV_A
env_b: $ENV_B
platform_a: $PLATFORM_A
platform_b: $PLATFORM_B
evaluated_at: $(date -Iseconds)

$EVAL_YAML
EOF

log_ok "Judging complete: $EVAL_DIR/${RUN_ID}${EVAL_SUFFIX}.yaml"
log_info "Run 'arena taste $RUN_ID' to see the results"

# Auto-post to Discord #claude-bakeoff
# ARENA_NO_DISCORD=1 for batch work: re-judging a backlog of old runs would
# otherwise post one report per run into a channel nobody asked to have filled.
if [ -f "$ARENA_ROOT/bin/discord-report.sh" ] && [ -z "$EVAL_SUFFIX" ] && [ -z "${ARENA_NO_DISCORD:-}" ]; then
    log_info "Posting results to Discord..."
    "$ARENA_ROOT/bin/discord-report.sh" "$RUN_ID" || log_error "Discord report failed (non-fatal)"
fi

# Collect results into bakeoff-<taskname>/ output folder
collect_output_folder "$RUN_ID"
