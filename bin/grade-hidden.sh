#!/usr/bin/env bash
# Objective, judge-free grading for a bake whose task ships a hidden grader.
#
# For each arm of <run-id>, copy the arm's workspace into a throwaway dir, drop the task's
# grader/ files in (which the arm never saw, so they cannot be gamed), run the grader, and
# parse its `GRADE: <passed>/<total>` line. Prints a table and writes a JSON summary. This
# is the answer to LLM-judge noise: a pass rate needs no judge's taste.
#
# Usage: grade-hidden.sh <run-id> [grader-cmd]
#   grader-cmd defaults to "python3 grade.py". The task must have tasks/<task>/grader/.
set -euo pipefail

ARENA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ARENA_ROOT/bin/lib/common.sh"

RUN_ID="${1:?Usage: grade-hidden.sh <run-id> [grader-cmd]}"
GRADER_CMD="${2:-python3 grade.py}"
RUN_DIR="$ARENA_ROOT/$(config_get runs_dir runs)/$RUN_ID"
[ -d "$RUN_DIR" ] || { log_error "No such bake: $RUN_ID"; exit 1; }
TASK="$(grep '^task:' "$RUN_DIR/meta.yaml" | sed 's/^task: *//')"
GRADER_DIR="$ARENA_ROOT/tasks/$TASK/grader"
[ -d "$GRADER_DIR" ] || { log_error "Task '$TASK' has no grader/ dir at $GRADER_DIR"; exit 1; }
EVAL_DIR="$ARENA_ROOT/$(config_get evaluations_dir evaluations)"; mkdir -p "$EVAL_DIR"
OUT_JSON="$EVAL_DIR/$RUN_ID.grade.json"

log_info "Objective grading $RUN_ID (task=$TASK, grader='$GRADER_CMD')"
echo
printf '%-22s %8s %7s   %s\n' RECIPE GRADE PCT NOTE
echo '{' > "$OUT_JSON"; first=1
for arm_dir in "$RUN_DIR"/arms/*/; do
    arm="$(basename "$arm_dir")"
    ws="$arm_dir/workspace"
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/grade-XXXXXX")"
    [ -d "$ws" ] && cp -r "$ws/." "$tmp/" 2>/dev/null || true
    # Copy the WHOLE grader dir (grade.py plus any answer-key/data files like expected.json),
    # not just *.py, or graders that read a key file silently score everything 0.
    cp -r "$GRADER_DIR"/. "$tmp/" 2>/dev/null || true
    note=""; grade="0/0"; pct=0
    if ls "$tmp"/*.py >/dev/null 2>&1; then
        raw="$(cd "$tmp" && timeout 120 bash -c "$GRADER_CMD" 2>&1 || true)"
        # `|| true` so a grader that crashes (no GRADE line) records a note instead of
        # aborting the whole run under `set -e`.
        line="$(printf '%s\n' "$raw" | grep -oE 'GRADE: [0-9]+/[0-9]+' | tail -1 | sed 's/GRADE: //' || true)"
        if [ -n "$line" ]; then
            grade="$line"; p="${line%%/*}"; t="${line##*/}"
            [ "$t" -gt 0 ] && pct=$(( 100 * p / t ))
        else
            note="no GRADE line ($(printf '%s' "$raw" | tail -1 | head -c 60))"
        fi
    else
        note="no python files in workspace"
    fi
    printf '%-22s %8s %6s%%   %s\n' "$arm" "$grade" "$pct" "$note"
    [ $first -eq 0 ] && echo ',' >> "$OUT_JSON"; first=0
    printf '  "%s": {"grade": "%s", "pct": %s}' "$arm" "$grade" "$pct" >> "$OUT_JSON"
    rm -rf "$tmp"
done
echo >> "$OUT_JSON"; echo '}' >> "$OUT_JSON"
echo
log_info "Objective grades: $OUT_JSON"
