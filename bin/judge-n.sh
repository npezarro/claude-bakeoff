#!/usr/bin/env bash
# Rank every arm of an N-way bake with one judge, in one call.
#
# The arms are handed over blind and in shuffled order: the judge sees ARM-A..F
# and never the recipe names, so "the one with the longest instructions" cannot
# become a prior. The mapping is written to the run dir before the call, so the
# reveal is a lookup rather than a claim.
#
# Usage: arena judge-n <run-id>
set -euo pipefail

ARENA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ARENA_ROOT/bin/lib/common.sh"

RUN_ID="${1:?Usage: arena judge-n <run-id>}"
RUN_DIR="$ARENA_ROOT/$(config_get runs_dir runs)/$RUN_ID"
[ -d "$RUN_DIR" ] || { log_error "No such bake: $RUN_ID"; exit 1; }

TASK="$(grep '^task:' "$RUN_DIR/meta.yaml" | sed 's/^task: *//')"
TASK_FILE="$ARENA_ROOT/tasks/$TASK/task.yaml"
JUDGE_MODEL="$(config_get judge_model claude-fable-5)"
EVAL_DIR="$ARENA_ROOT/$(config_get evaluations_dir evaluations)"
mkdir -p "$EVAL_DIR"

# A task either ships a required_facts block (report-shaped: did the facts survive
# the compression) or an eval_criteria list (everything else: did the answer do the
# job). Falling back to the fluff rubric for a task that never asked for one ranks a
# code review on its prose economy and calls it a verdict, which is worse than
# refusing: it looks like an answer. Pick the rubric from what the task declares.
REQUIRED_FACTS="$(get_task_block "$TASK_FILE" required_facts)"
N_FACTS="$(printf '%s\n' "$REQUIRED_FACTS" | grep -c '[^[:space:]]' || true)"
CRITERIA="$(awk '/^eval_criteria:/{f=1;next} f&&/^[a-z_]+:/{exit} f&&/^[[:space:]]*-/{sub(/^[[:space:]]*-[[:space:]]*/,""); print}' "$TASK_FILE")"
N_CRITERIA="$(printf '%s\n' "$CRITERIA" | grep -c '[^[:space:]]' || true)"

if [ "$N_FACTS" -gt 0 ]; then
    RUBRIC_LABEL="facts"
    RUBRIC_HEAD="These $N_FACTS facts are what the reader actually needs. Score each report on how many survive, in any wording:"
    RUBRIC_BODY="$REQUIRED_FACTS"
    RUBRIC_N="$N_FACTS"
elif [ "$N_CRITERIA" -gt 0 ]; then
    RUBRIC_LABEL="criteria"
    RUBRIC_HEAD="These $N_CRITERIA criteria are what the task actually asked for. They decide the ranking; fluff density is secondary and breaks ties. Score each answer on how many it meets:"
    RUBRIC_BODY="$CRITERIA"
    RUBRIC_N="$N_CRITERIA"
else
    log_error "Task '$TASK' declares neither required_facts nor eval_criteria. There is nothing to judge against."
    exit 1
fi

# Blind labels, shuffled, recorded before the judge is asked anything.
MAP="$RUN_DIR/blind-map.tsv"
: > "$MAP"
i=0
LABELS=(A B C D E F G H I J K L)
while read -r arm; do
    [ -n "$arm" ] || continue
    printf '%s\t%s\n' "ARM-${LABELS[$i]}" "$arm" >> "$MAP"
    i=$((i + 1))
done < <(find "$RUN_DIR/arms" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | shuf)

PROMPT_FILE="$RUN_DIR/judge-prompt.txt"
{
    cat <<EOF
You are judging $i candidate reports. Every one of them reports the SAME finished piece of
work to the same reader: a senior engineer who owns the system, who was present for the work,
and who is the person whose question caused the design to change. They differ only in the
writing instructions their author was given, which you do not get to see.

The thing being measured is how much of each report is text the reader ALREADY HAD before
reading it. Count a sentence as FLUFF if it does any of these and nothing else:
  - restates the request, the task, or the reader's own words back to them
  - says the author was wrong, apologises, or explains why the author's earlier choice happened
  - announces what the report is about to say, or summarises what it just said
  - praises the reader, the question, or the idea
  - narrates effort or difficulty ("this was tricky", "after some digging")
  - hedges without adding a fact ("it seems", "hopefully")
  - repeats a fact already stated elsewhere in the same report
A sentence that carries a fact is NOT fluff even if it is long, and a heading is not a sentence.
Count sentences of prose only: skip code blocks, command output, and table rows.

$RUBRIC_HEAD
$RUBRIC_BODY

The reports:
EOF
    while IFS=$'\t' read -r label arm; do
        printf '\n===== %s =====\n' "$label"
        cat "$RUN_DIR/arms/$arm/response.txt"
        printf '\n'
    done < "$MAP"

    cat <<'EOF'

Return ONLY a JSON object, no prose around it, no code fence:

{
  "arms": [
    {
      "label": "ARM-A",
      "total_sentences": 0,
      "fluff_sentences": 0,
      "fluff_quotes": ["verbatim quote of the worst offender, or none"],
      "facts_present": 0,
      "facts_missing": ["short name of each one missed"],
      "opener": "outcome | restatement | apology | preamble | praise",
      "signal_score": 0,
      "rank": 1,
      "verdict": "one sentence, what this report does to the reader"
    }
  ],
  "winner": "ARM-?",
  "summary": "two sentences: what separated the top from the bottom"
}

facts_present / facts_missing are counted against the numbered list above, whichever kind it is.
signal_score is 0-100 and must punish BOTH failure modes: fluff kept, and list items lost.
A report that cut everything including the evidence is not a winner. Rank 1 is best. Every arm
gets a distinct rank.
EOF
} > "$PROMPT_FILE"

# The judge needs isolating for a different reason than the arms do: the host's
# guidance contains the very rule this bake is choosing the wording of, and a
# judge primed with it would be grading against the author's own phrasing.
JUDGE_CFG=""
if [ -n "${ARENA_NO_ISOLATION:-}" ]; then
    log_error "ISOLATION OFF (ARENA_NO_ISOLATION set): the judge also reads the host's guidance."
elif JUDGE_CFG="$(isolated_config_dir)"; then
    export CLAUDE_CONFIG_DIR="$JUDGE_CFG"
    trap 'rm -rf "$JUDGE_CFG"' EXIT
else
    log_error "NOT ISOLATED: the judge will also read the host's guidance."
fi

log_info "Judging $RUN_ID with $JUDGE_MODEL ($i arms, blind)"

RAW="$EVAL_DIR/$RUN_ID.raw.txt"
claude --print --model "$JUDGE_MODEL" --max-turns 3 --dangerously-skip-permissions \
    -p "$(cat "$PROMPT_FILE")" > "$RAW" 2>"$EVAL_DIR/$RUN_ID.stderr.log" || true

# The judge is asked for bare JSON; strip a fence anyway rather than fail on one.
JSON="$EVAL_DIR/$RUN_ID.json"
sed -e 's/^```json$//' -e 's/^```$//' "$RAW" | sed -n '/^{/,$p' > "$JSON"

if ! jq -e . "$JSON" >/dev/null 2>&1; then
    log_error "Judge did not return usable JSON. Raw output: $RAW"
    exit 1
fi

# Reveal: join the judge's blind labels back to recipe names, add the one number
# that never needed a judge.
echo
printf '%-8s %-20s %6s %6s %7s %8s %6s  %s\n' RANK RECIPE WORDS FLUFF/SENT "$(echo "$RUBRIC_LABEL" | tr '[:lower:]' '[:upper:]')" SCORE OPENER VERDICT
while IFS=$'\t' read -r label arm; do
    words="$(wc -w < "$RUN_DIR/arms/$arm/response.txt" | tr -d ' ')"
    jq -r --arg l "$label" --arg a "$arm" --arg w "$words" --arg nf "$RUBRIC_N" '
        .arms[] | select(.label == $l) |
        [ .rank, $a, $w, "\(.fluff_sentences)/\(.total_sentences)",
          "\(.facts_present)/\($nf)", .signal_score, .opener, .verdict ] | @tsv' "$JSON"
done < "$MAP" | sort -n | awk -F'\t' '{printf "%-8s %-20s %6s %10s %7s %8s %-10s %s\n", $1, $2, $3, $4, $5, $6, $7, $8}'

echo
jq -r '"WINNER (blind): \(.winner)\n\(.summary)"' "$JSON"
echo
log_info "Blind map: $MAP"
log_info "Full verdict: $JSON"
