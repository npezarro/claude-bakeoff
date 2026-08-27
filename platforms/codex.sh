#!/usr/bin/env bash
# Platform runner: CODEX (OpenAI)
#
# Same contract as cli.sh and local.sh: BAKE_PROMPT in, {"result": "..."} out, so a bake
# can put Claude, Codex and a local model against each other under one blind judge.
#
# Uses an ISOLATED CODEX_HOME by default. The bakeoff must not run public-app comparisons
# against the personal ChatGPT session, and pointing it at ~/.codex would do exactly that.
set -euo pipefail

WORKSPACE_DIR="${1:?Usage: codex.sh <workspace_dir>}"
PROMPT="${BAKE_PROMPT:?BAKE_PROMPT is required}"
export CODEX_HOME="${BAKE_CODEX_HOME:-$HOME/.codex-alt}"
MODEL="${BAKE_MODEL:-}"

# The recipe's CLAUDE.md is the instruction set under test; hold it constant across arms
# so the bake measures the MODEL and not the prompt.
SYSTEM=""
[ -f "$WORKSPACE_DIR/CLAUDE.md" ] && SYSTEM="$(cat "$WORKSPACE_DIR/CLAUDE.md")"
FULL="${SYSTEM:+$SYSTEM

---

}$PROMPT"

cd "$WORKSPACE_DIR"
# stdin CLOSED: `codex exec` blocks on "Reading additional input from stdin..." when handed
# a pipe that never delivers, and the run hangs until the timeout with no output.
RAW="$(codex exec \
  --sandbox read-only \
  --skip-git-repo-check \
  --json \
  ${MODEL:+-c model="\"$MODEL\""} \
  "$FULL" < /dev/null 2>/dev/null)" || true

# The answer is the LAST agent_message. Reasoning and tool events share item.completed,
# so filtering on the item type matters.
echo "$RAW" | jq -s -c '
  [ .[] | select(.type=="item.completed") | select(.item.type=="agent_message") | .item.text ] as $msgs
  | [ .[] | select(.type=="turn.completed") | .usage ] as $usage
  | {
      type: "result",
      subtype: (if ($msgs|length)>0 then "success" else "error" end),
      result: ($msgs | last // ""),
      model: "codex",
      num_turns: 1,
      total_cost_usd: 0,
      prompt_tokens: ($usage | last | .input_tokens // 0),
      completion_tokens: ($usage | last | .output_tokens // 0)
    }'
