#!/usr/bin/env bash
# Platform runner: ADVERSARIAL — complementary-search review.
# Pass 1 reviews normally. Pass 2 (fresh context) is told to ASSUME pass 1
# missed at least one real bug and to hunt ONLY for defects not already listed.
# A final merge integrates verified pass-2 finds into pass 1's report.
# Differs from the retired `panel` (parallel duplicates + merge): this searches
# the complement space instead of sampling the same distribution twice.
set -euo pipefail

WORKSPACE_DIR="${1:?Usage: adversarial.sh <workspace_dir>}"
PROMPT="${BAKE_PROMPT:?BAKE_PROMPT is required}"
MODEL="${BAKE_MODEL:-claude-opus-4-8}"
MAX_TURNS="${BAKE_MAX_TURNS:-45}"
EFFORT_ARGS=()
[ -n "${BAKE_EFFORT:-}" ] && EFFORT_ARGS=(--effort "$BAKE_EFFORT")
RUN_ROOT="$(mktemp -d /tmp/adv.XXXXXX)"

run_pass() {  # dir prompt outfile
    local d="$1" pr="$2" out="$3"
    mkdir -p "$d"; cp -r "$WORKSPACE_DIR/." "$d/"
    ( cd "$d" && printf '%s' "$pr" | claude --print --max-turns "$MAX_TURNS" --output-format json \
        --dangerously-skip-permissions --model "$MODEL" "${EFFORT_ARGS[@]}" > "$out" 2>/dev/null ) || true
}

run_pass "$RUN_ROOT/p1" "$PROMPT" "$RUN_ROOT/p1.json"
R1="$(jq -r '.result // empty' "$RUN_ROOT/p1.json" 2>/dev/null || true)"
[ -n "$R1" ] || { jq -n '{result: "ADVERSARIAL FAILED: pass 1 empty", is_error: true}'; exit 0; }

P2="A reviewer already produced the review below for this task. Statistically, reviews at this depth miss at least one real defect. Your ONLY job: find real defects that are NOT in the existing review. Ignore everything already covered. Hunt specifically in the blind-spot classes: cross-request/state interactions, key/name collisions, error paths after partial success, concurrency and re-entrancy, resource lifecycle, and semantic drift between doc/claims and code. Verify each candidate against the actual code before reporting; report NOTHING you cannot point to a concrete failing scenario for. If you genuinely find nothing new after a thorough hunt, say exactly: NO ADDITIONAL DEFECTS FOUND.

ORIGINAL TASK:
$PROMPT

EXISTING REVIEW:
$R1"
run_pass "$RUN_ROOT/p2" "$P2" "$RUN_ROOT/p2.json"
R2="$(jq -r '.result // empty' "$RUN_ROOT/p2.json" 2>/dev/null || true)"

if [ -z "$R2" ] || printf '%s' "$R2" | grep -q "NO ADDITIONAL DEFECTS FOUND"; then
    jq -n --arg r "$R1" '{result: $r, subtype: "success", platform: "adversarial"}'
    exit 0
fi

MERGE="Integrate the additional verified findings below into the existing review: insert each at the right severity position, dedupe if anything overlaps, keep the original review's format and strengths section, and do not mention that multiple passes existed. Verify the additional findings against the code once more; drop any that don't hold.

ORIGINAL TASK:
$PROMPT

EXISTING REVIEW:
$R1

ADDITIONAL FINDINGS:
$R2"
run_pass "$RUN_ROOT/m" "$MERGE" "$RUN_ROOT/m.json"
RM="$(jq -r '.result // empty' "$RUN_ROOT/m.json" 2>/dev/null || true)"
[ -n "$RM" ] || RM="$R1"
jq -n --arg r "$RM" '{result: $r, subtype: "success", platform: "adversarial"}'
