#!/usr/bin/env bash
# Platform runner: PANEL — coverage-first review sampling.
# Runs the prompt on 2 parallel instances, then a merge pass that unions their
# findings, dedupes, verifies each against the diff, and re-ranks by severity.
# Built to attack the one surviving Fable edge (review depth: "found one more
# real bug" tiebreaks) with architecture instead of a bigger model.
#
# Interface (same as cli.sh): args <workspace_dir>; env BAKE_PROMPT, BAKE_MODEL,
# BAKE_MAX_TURNS, BAKE_EFFORT; stdout JSON with .result.
set -euo pipefail

WORKSPACE_DIR="${1:?Usage: panel.sh <workspace_dir>}"
PROMPT="${BAKE_PROMPT:?BAKE_PROMPT is required}"
MODEL="${BAKE_MODEL:-claude-opus-4-8}"
MAX_TURNS="${BAKE_MAX_TURNS:-45}"

RUN_ROOT="$(mktemp -d /tmp/panel.XXXXXX)"
EFFORT_ARGS=()
[ -n "${BAKE_EFFORT:-}" ] && EFFORT_ARGS=(--effort "$BAKE_EFFORT")

# Finder passes: coverage-first framing per the documented Opus review guidance.
FINDER_SUFFIX="

FINDER MODE: Report every issue you find, including ones you are uncertain about or
consider low-severity. Do not filter for importance or confidence — a separate merge
step will do that. For each finding include your confidence and estimated severity."

PIDS=()
for i in 1 2; do
    D="$RUN_ROOT/arm$i"; mkdir -p "$D"; cp -r "$WORKSPACE_DIR/." "$D/"
    (
        cd "$D"
        claude --print --max-turns "$MAX_TURNS" --output-format json \
            --dangerously-skip-permissions --model "$MODEL" "${EFFORT_ARGS[@]}" \
            -p "${PROMPT}${FINDER_SUFFIX}" > "$RUN_ROOT/arm$i.json" 2>/dev/null || true
    ) &
    PIDS+=($!)
done
wait "${PIDS[@]}" 2>/dev/null || true

R1="$(jq -r '.result // empty' "$RUN_ROOT/arm1.json" 2>/dev/null || true)"
R2="$(jq -r '.result // empty' "$RUN_ROOT/arm2.json" 2>/dev/null || true)"
if [ -z "$R1" ] && [ -z "$R2" ]; then
    jq -n '{result: "PANEL FAILED: both finder arms empty", is_error: true}'; exit 0
fi

MERGE_PROMPT="Two independent reviewers produced the reports below for the same task.
Produce the single definitive review:
1. UNION their findings — include every real issue either found.
2. Dedupe overlapping findings (keep the better-explained version).
3. Drop findings that are factually wrong about the code (verify each claim against the code in this directory before keeping it).
4. Rank by severity (critical, warning, nit), keep the acknowledge-what's-done-well section.
5. Output a single polished review in the format the original task asked for. Do not mention that multiple reviewers or a merge existed.

ORIGINAL TASK:
$PROMPT

REVIEWER 1:
$R1

REVIEWER 2:
$R2"

MERGE_DIR="$RUN_ROOT/merge"; mkdir -p "$MERGE_DIR"; cp -r "$WORKSPACE_DIR/." "$MERGE_DIR/"
cd "$MERGE_DIR"
printf '%s' "$MERGE_PROMPT" | claude --print --max-turns 15 --output-format json \
    --dangerously-skip-permissions --model "$MODEL" "${EFFORT_ARGS[@]}" \
    > "$RUN_ROOT/merge.json" 2>/dev/null || true

MERGED="$(jq -r '.result // empty' "$RUN_ROOT/merge.json" 2>/dev/null || true)"
if [ -z "$MERGED" ]; then
    MERGED="${R1:-$R2}"   # merge failed → best single finder
fi
jq -n --arg r "$MERGED" '{result: $r, subtype: "success", platform: "panel"}'
