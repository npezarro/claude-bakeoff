#!/usr/bin/env bash
# Platform runner: LOCAL
# Runs the prompt against an on-device model served by Ollama, so a bake can put a
# local model on one side and Claude on the other and let the blind judge score them.
#
# Interface (same contract as cli.sh):
#   args:   <workspace_dir>
#   env:    BAKE_PROMPT, BAKE_MODEL, BAKE_ENV_NAME
#           LLMG_OLLAMA_HOST  (default http://127.0.0.1:11434)
#           LLMG_NUM_CTX      (default 8192)
#   stdout: {"result": "..."} -- run.sh extracts .result, same as the claude CLI shape
#   exit:   0 on success
#
# The recipe's CLAUDE.md is passed as the system prompt. That is the point of running
# a local model through this harness at all: it holds the instruction set constant so
# the bake measures the MODEL, not the prompt.
#
# WHAT THIS PLATFORM CANNOT DO. A plain chat completion has no tools. It cannot read
# the workspace, run commands, search the web, or write files. Bake it only against
# tasks whose deliverable is the text of the reply. On a task that is graded by the
# files it produced (multi-file-impl, and anything in bakeoff-*-probe), this arm
# scores zero and the comparison is meaningless rather than merely unflattering.
# For grounded research, use local-llm-gateway's research pipeline instead, which
# does retrieval in code and passes the model text.

set -euo pipefail

WORKSPACE_DIR="${1:?Usage: local.sh <workspace_dir>}"
PROMPT="${BAKE_PROMPT:?BAKE_PROMPT is required}"
MODEL="${BAKE_MODEL:-}"
OLLAMA_HOST="${LLMG_OLLAMA_HOST:-http://127.0.0.1:11434}"
NUM_CTX="${LLMG_NUM_CTX:-8192}"

# A recipe pins its model with a `model` file (run.sh exports it as BAKE_MODEL).
# Without one there is no sensible default to guess, since which model is even
# pulled varies by host, so take the first non-embedding model Ollama reports.
if [ -z "$MODEL" ]; then
    AVAILABLE="$(curl -sf -m 10 "$OLLAMA_HOST/api/tags" \
        | jq -r '[.models[].name | select(test("embed") | not)] | join(" ")')"
    # Prefer the prose model (see the note below on Qwen3's reasoning tax), then fall
    # back to whatever is pulled.
    for candidate in gemma3:4b qwen3:4b; do
        if [[ " $AVAILABLE " == *" $candidate "* ]]; then MODEL="$candidate"; break; fi
    done
    [ -z "$MODEL" ] && MODEL="$(echo "$AVAILABLE" | awk '{print $1}')"
fi
if [ -z "$MODEL" ]; then
    echo '{"result":"","error":"no model available: set a `model` file in the recipe, or pull one with `ollama pull qwen3:4b`"}'
    exit 0
fi

SYSTEM=""
if [ -f "$WORKSPACE_DIR/CLAUDE.md" ]; then
    SYSTEM="$(cat "$WORKSPACE_DIR/CLAUDE.md")"
fi

# Pick a prose model for bakes, not a reasoning one. Qwen3's thinking cannot be
# disabled on this stack (think:false and /no_think were both measured and both fail),
# so it spends ~350 tokens and 10s reasoning before a two-sentence answer that then
# gets stripped. gemma3:4b does the same bake in 37 tokens and 1.1s. Bake output is
# always free prose, so a reasoning model is the wrong tool here by default.
# Override per recipe with a `model` file when that is the thing being tested.

# Build the request with jq so a prompt containing quotes, newlines or backslashes
# cannot break out of the JSON. `think:false` keeps Qwen3 reasoning out of the reply.
REQ="$(jq -nc \
    --arg model "$MODEL" \
    --arg system "$SYSTEM" \
    --arg prompt "$PROMPT" \
    --argjson ctx "$NUM_CTX" \
    '{
        model: $model,
        stream: false,
        think: false,
        options: { num_ctx: $ctx, temperature: 0.2 },
        messages: (
            (if $system == "" then [] else [{role:"system", content:$system}] end)
            + [{role:"user", content:$prompt}]
        )
    }')"

RESP="$(curl -sf -m 900 "$OLLAMA_HOST/api/chat" \
    -H 'Content-Type: application/json' \
    -d "$REQ" 2>/dev/null)" || {
    echo "{\"result\":\"\",\"error\":\"ollama request failed against $OLLAMA_HOST (model $MODEL)\"}"
    exit 0
}

# Strip any <think> block the flag failed to suppress, then emit the cli.sh-shaped
# envelope. Timing fields are carried through so a bake report can show that the
# local arm answered in 1s where the Claude arm took 30.
echo "$RESP" | jq -c '
    {
        type: "result",
        subtype: "success",
        result: (
            (.message.content // "")
            | gsub("(?s)<think>.*?</think>"; "")
            | sub("(?s)^.*</think>"; "")
            | sub("(?s)<think>.*$"; "")
            | gsub("^\\s+|\\s+$"; "")
        ),
        model: .model,
        num_turns: 1,
        total_cost_usd: 0,
        duration_ms: ((.total_duration // 0) / 1000000 | floor),
        prompt_tokens: (.prompt_eval_count // 0),
        completion_tokens: (.eval_count // 0)
    }'
