#!/usr/bin/env bash
# Platform runner: LOCAL-RESEARCH
#
# Routes the prompt through local-llm-gateway's /research endpoint, which does real
# retrieval (search, fetch, rank) and then synthesises a cited answer on an on-device
# model.
#
# THIS EXISTS BECAUSE local.sh IS THE WRONG ARM FOR A RESEARCH TASK. local.sh is a plain
# chat completion with no tools: on a buying-guide question it answers from weights alone,
# inventing prices and model numbers it cannot check. Putting that against two cloud
# models WITH web access does not measure the engines, it measures who was allowed to look
# things up, and the local arm would lose for a reason that says nothing about the model.
#
# Interface (same contract as cli.sh / codex.sh):
#   args:   <workspace_dir>
#   env:    BAKE_PROMPT, LLMG_URL, BAKE_RESEARCH_ROUNDS
#   stdout: {"result": "..."} in the claude-CLI shape
set -euo pipefail

WORKSPACE_DIR="${1:?Usage: local-research.sh <workspace_dir>}"
PROMPT="${BAKE_PROMPT:?BAKE_PROMPT is required}"
LLMG_URL="${LLMG_URL:-http://127.0.0.1:3120}"
ROUNDS="${BAKE_RESEARCH_ROUNDS:-3}"
# Deep research is slow on-device: ~40-70s per round plus a ~110s synthesis. A bake must
# not abandon the arm before it finishes or the comparison records an empty answer as a
# quality result.
TIMEOUT="${BAKE_RESEARCH_TIMEOUT:-900}"

REQ="$(jq -nc --arg q "$PROMPT" --argjson r "$ROUNDS" '{question: $q, maxRounds: $r}')"

RESP="$(curl -sf -m "$TIMEOUT" "$LLMG_URL/research" \
  -H 'Content-Type: application/json' -d "$REQ" 2>/dev/null)" || {
  echo '{"type":"result","subtype":"error","result":"","error":"local research gateway unreachable or failed"}'
  exit 0
}

# Append the sources. The bridge shows them to the reader, and a research answer judged
# without its citations is being judged on a different artifact than the one that ships.
echo "$RESP" | jq -c '
  {
    type: "result",
    subtype: (if (.answer // "") == "" then "error" else "success" end),
    result: (
      (.answer // "")
      + (if ((.sources // []) | length) > 0
         then "\n\n### Sources\n\n" + ((.sources | map("\(.n). [\(.domain)](\(.url))")) | join("\n"))
         else "" end)
    ),
    model: (.models.prose // "local"),
    num_turns: (.rounds // 1),
    total_cost_usd: 0,
    fact_count: (.factCount // 0),
    source_count: ((.sources // []) | length),
    search_degraded: (.searchDegraded // null)
  }'
