#!/usr/bin/env bash
# Blind N-way CAPABILITY judge: rank every arm of an N-way bake on one scale.
#
# Why this exists alongside judge-n.sh and evaluate.sh:
#   - judge-n.sh   ranks N arms blind, but its rubric is FLUFF/report-craft (tuned for the
#                  report-fluff experiment). Wrong instrument for "which model/layer is more
#                  CAPABLE at the engineering task".
#   - evaluate.sh  uses a capability rubric (correctness/completeness/adherence) but is pairwise
#                  AND names the recipes to the judge, so "the one with the longest instructions"
#                  can become a prior, and two pairwise bakes cannot be stacked onto one scale.
# This script is the missing instrument: blind (shuffled ARM-A.. labels, map written first),
# N-way (one judge call, one scale), and scored against the TASK's own eval_criteria plus the
# standard capability dimensions. It reads each arm's final response AND the files it produced.
#
# Usage: judge-cap.sh <run-id> [judge-model] [--tag TAG]
#   judge-model defaults to claude-sonnet-5 (neutral to the Opus-vs-Fable comparison).
#   --tag TAG writes evaluations/<run-id>.cap-<TAG>.json (default TAG = judge model minus
#   the claude- prefix, version kept, e.g. fable-5-1),
#   so the same bake can be judged by several judges without clobbering.
# Never auto-posts to Discord.
set -euo pipefail

ARENA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ARENA_ROOT/bin/lib/common.sh"

RUN_ID="${1:?Usage: judge-cap.sh <run-id> [judge-model] [--tag TAG]}"; shift || true
JUDGE_MODEL="claude-sonnet-5"
TAG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --tag) TAG="$2"; shift 2 ;;
        -*)    log_error "Unknown option: $1"; exit 1 ;;
        *)     JUDGE_MODEL="$1"; shift ;;
    esac
done
# Default TAG keeps the version: stripping it made claude-fable-5 and claude-fable-5-1 both
# "fable", so judging one run with both silently overwrote the first verdict AND its map.
[ -n "$TAG" ] || TAG="$(echo "$JUDGE_MODEL" | sed -E 's/^claude-//; s/[^a-z0-9]+/-/g; s/-+$//')"

RUN_DIR="$ARENA_ROOT/$(config_get runs_dir runs)/$RUN_ID"
[ -d "$RUN_DIR" ] || { log_error "No such bake: $RUN_ID"; exit 1; }

TASK="$(grep '^task:' "$RUN_DIR/meta.yaml" | sed 's/^task: *//')"
TASK_FILE="$ARENA_ROOT/tasks/$TASK/task.yaml"
EVAL_DIR="$ARENA_ROOT/$(config_get evaluations_dir evaluations)"
mkdir -p "$EVAL_DIR"

TASK_PROMPT="$(get_task_prompt "$TASK_FILE")"
EXPECTED="$(get_task_block "$TASK_FILE" expected_behavior)"
CRITERIA="$(awk '/^eval_criteria:/{f=1;next} f&&/^[a-z_]+:/{exit} f&&/^[[:space:]]*-/{sub(/^[[:space:]]*-[[:space:]]*/,""); print}' "$TASK_FILE")"
N_CRITERIA="$(printf '%s\n' "$CRITERIA" | grep -c '[^[:space:]]' || true)"
[ "$N_CRITERIA" -gt 0 ] || { log_error "Task '$TASK' has no eval_criteria; nothing to judge against."; exit 1; }

# Dump the files an arm produced, capped and junk-excluded (same shape as evaluate.sh).
dump_workspace() {
    local dir="$1"
    [ -d "$dir" ] || { echo "(no workspace)"; return; }
    local out
    out="$(find "$dir" -type f ! -name 'CLAUDE.md' \
        ! -path '*node_modules*' ! -path '*/.git/*' ! -path '*__pycache__*' \
        ! -name '*.db' ! -name '*.sqlite*' ! -name '*.lock' ! -name 'package-lock.json' \
        ! -name '*.png' ! -name '*.jpg' ! -name '*.gif' \
        -size -200k -print0 2>/dev/null | sort -z | while IFS= read -r -d '' f; do
            echo "--- ${f#"$dir"/} ---"
            head -c 5000 "$f"
            if [ "$(wc -c < "$f")" -gt 5000 ]; then echo; echo "... [truncated at 5KB]"; fi
            echo
    done | head -c 150000)"
    [ -n "$out" ] && printf '%s' "$out" || echo "(no files produced)"
}

# Blind labels, shuffled, recorded before the judge is asked anything.
# Per-TAG, like the JSON verdict this map DECODES. A shared map was truncated and
# reshuffled on every invocation, so judging one run with two judges destroyed the
# first judge's mapping and left only the last call's. Seen 2026-09-17: two judges on
# run 20260917_142448 drew OPPOSITE shuffles, so reading the surviving map against the
# first judge's scores inverted that task's result (reported the arm LOSING by 5 when
# it won by 5). Nothing errored; the file existed and parsed.
MAP="$RUN_DIR/blind-map-cap-$TAG.tsv"
: > "$MAP"
i=0
LABELS=(A B C D E F G H I J K L)
while read -r arm; do
    [ -n "$arm" ] || continue
    printf '%s\t%s\n' "ARM-${LABELS[$i]}" "$arm" >> "$MAP"
    i=$((i + 1))
done < <(find "$RUN_DIR/arms" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | shuf)

cp "$MAP" "$RUN_DIR/blind-map-cap.tsv"   # legacy filename: last judge wins, as before

PROMPT_FILE="$RUN_DIR/judge-cap-prompt.txt"
{
    cat <<EOF
You are an impartial, expert software-engineering judge ranking $i AI-agent responses to the
SAME task. Each arm ran under a different (hidden) model + instruction configuration; you are
told neither. Judge purely on the engineering merit of what each arm actually did and delivered.

## The task the arms were given
$TASK_PROMPT

## Expected behavior
$EXPECTED

## The scoring checklist ($N_CRITERIA criteria — this is what "capable" means for THIS task)
$CRITERIA

For each arm, decide how many of the $N_CRITERIA checklist items it genuinely satisfies (judge by
evidence in the response and in the files it produced, not by claims it makes about itself). Then
give an overall 0-100 capability score. The overall MUST be driven primarily by checklist coverage
and correctness; writing quality and concision only break ties between arms with equal coverage.
Penalize: unsupported claims (asserting tests pass / code works without evidence), dangling or
missing files, ending with clarifying questions instead of doing the work, and over-long output
that buries the result. A short, correct, evidence-backed answer beats a long one that claims more.

The arms (blind, shuffled order):
EOF
    while IFS=$'\t' read -r label arm; do
        printf '\n=================== %s ===================\n' "$label"
        printf '### %s final response:\n' "$label"
        cat "$RUN_DIR/arms/$arm/response.txt" 2>/dev/null || echo "(no response)"
        printf '\n### %s files produced:\n' "$label"
        dump_workspace "$RUN_DIR/arms/$arm/workspace"
        printf '\n'
    done < "$MAP"

    cat <<EOF

Return ONLY a JSON object (no prose, no code fence):

{
  "arms": [
    {
      "label": "ARM-A",
      "criteria_met": 0,
      "criteria_total": $N_CRITERIA,
      "criteria_missing": ["short name of each checklist item missed"],
      "correctness": 0,
      "completeness": 0,
      "evidence_fidelity": 0,
      "overall": 0,
      "rank": 1,
      "verdict": "one sentence: what this arm did well or badly"
    }
  ],
  "winner": "ARM-?",
  "summary": "two sentences: what separated the top arm from the bottom"
}

correctness / completeness / evidence_fidelity are 0-10. overall is 0-100. rank 1 is best and
every arm gets a DISTINCT rank. Reward the arm that actually did the job with evidence.
EOF
} > "$PROMPT_FILE"

# Isolate the judge from the host guidance (it contains the parity layer being tested).
JUDGE_CFG=""
if [ -n "${ARENA_NO_ISOLATION:-}" ]; then
    log_error "ISOLATION OFF (ARENA_NO_ISOLATION set): the judge also reads the host's guidance."
elif JUDGE_CFG="$(isolated_config_dir)"; then
    export CLAUDE_CONFIG_DIR="$JUDGE_CFG"
    trap 'rm -rf "$JUDGE_CFG"' EXIT
else
    log_error "NOT ISOLATED: the judge will also read the host's guidance."
fi

log_info "Capability-judging $RUN_ID with $JUDGE_MODEL ($i arms, blind, tag=$TAG)"

RAW="$EVAL_DIR/$RUN_ID.cap-$TAG.raw.txt"
# Pipe the prompt on stdin, not via -p "$(...)": a prompt over ~128KB (Linux MAX_ARG_STRLEN)
# passed as a single argv string dies with "Argument list too long". Tasks that produce
# workspaces (multi-file-impl) blow past that. stdin has no such limit. (evaluate.sh does this.)
claude --print --model "$JUDGE_MODEL" --max-turns 3 --dangerously-skip-permissions \
    < "$PROMPT_FILE" > "$RAW" 2>"$EVAL_DIR/$RUN_ID.cap-$TAG.stderr.log" || true

JSON="$EVAL_DIR/$RUN_ID.cap-$TAG.json"
sed -e 's/^```json$//' -e 's/^```$//' "$RAW" | sed -n '/^{/,$p' > "$JSON"
if ! jq -e . "$JSON" >/dev/null 2>&1; then
    log_error "Judge did not return usable JSON. Raw: $RAW"
    exit 1
fi

# Reveal: join blind labels back to recipe names.
echo
printf 'TASK: %s   JUDGE: %s\n' "$TASK" "$JUDGE_MODEL"
printf '%-6s %-22s %5s %8s %8s %6s  %s\n' RANK RECIPE CRIT CORR/COMP EVID OVERALL VERDICT
while IFS=$'\t' read -r label arm; do
    jq -r --arg l "$label" --arg a "$arm" '
        .arms[] | select(.label == $l) |
        [ .rank, $a, "\(.criteria_met)/\(.criteria_total)",
          "\(.correctness)/\(.completeness)", .evidence_fidelity, .overall, .verdict ] | @tsv' "$JSON"
done < "$MAP" | sort -n | awk -F'\t' '{printf "%-6s %-22s %5s %8s %8s %6s  %s\n", $1, $2, $3, $4, $5, $6, $7}'

echo
# Blind winner -> real recipe name.
WINNER_LABEL="$(jq -r '.winner' "$JSON")"
WINNER_ARM="$(awk -F'\t' -v l="$WINNER_LABEL" '$1==l{print $2}' "$MAP")"
printf 'WINNER: %s (%s)\n' "$WINNER_ARM" "$WINNER_LABEL"
jq -r '.summary' "$JSON"
echo
log_info "Blind map: $MAP"
log_info "Verdict:   $JSON"
