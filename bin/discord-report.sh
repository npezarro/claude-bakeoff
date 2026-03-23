#!/usr/bin/env bash
# discord-report.sh — Post claude-bakeoff evaluation results to #claude-bakeoff in Discord.
#
# Usage:
#   arena discord-report <run-id>              # post evaluation results
#   ./bin/discord-report.sh <run-id>           # direct invocation
#
# Requires: bot token cached at ~/.cache/discord-bot-token (or SSH to VM)

set -euo pipefail

ARENA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ARENA_ROOT/bin/lib/common.sh"

CLAUDE_ARENA_CHANNEL_ID="${CLAUDE_ARENA_CHANNEL_ID:-1485414189127303259}"
BOT_TOKEN_CACHE="$HOME/.cache/discord-bot-token"

# --- Bot token resolution ---
_get_bot_token() {
  if [ -f "$BOT_TOKEN_CACHE" ]; then
    cat "$BOT_TOKEN_CACHE"
    return
  fi
  local token
  token=$(REDACTED_SSH_COMMAND 2>/dev/null)
  if [ -n "$token" ]; then
    mkdir -p "$(dirname "$BOT_TOKEN_CACHE")"
    echo "$token" > "$BOT_TOKEN_CACHE"
    chmod 600 "$BOT_TOKEN_CACHE"
    echo "$token"
  fi
}

# --- Post to Discord channel via bot API ---
bot_post() {
  local channel="$1"
  local content="$2"
  local token
  token=$(_get_bot_token)
  [ -z "$token" ] && { log_error "No bot token available"; return 1; }

  content="${content:0:1990}"

  curl -s -X POST "https://discord.com/api/v10/channels/${channel}/messages" \
    -H "Authorization: Bot ${token}" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c "import json,sys; print(json.dumps({'content': sys.argv[1]}))" "$content")"
}

# --- Post embed to Discord channel ---
bot_post_embed() {
  local channel="$1"
  local title="$2"
  local description="$3"
  local color="$4"
  local token
  token=$(_get_bot_token)
  [ -z "$token" ] && { log_error "No bot token available"; return 1; }

  description="${description:0:3900}"

  curl -s -X POST "https://discord.com/api/v10/channels/${channel}/messages" \
    -H "Authorization: Bot ${token}" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c "
import json, sys
print(json.dumps({
    'embeds': [{
        'title': sys.argv[1],
        'description': sys.argv[2],
        'color': int(sys.argv[3]),
        'footer': {'text': 'claude-bakeoff'},
        'timestamp': '$(date -u '+%Y-%m-%dT%H:%M:%SZ')'
    }]
}))
" "$title" "$description" "$color")"
}

# --- Main ---
RUN_ID="${1:-}"
if [ -z "$RUN_ID" ]; then
  log_error "Usage: arena discord-report <run-id>"
  exit 1
fi

EVAL_DIR="$ARENA_ROOT/$(config_get evaluations_dir evaluations)"
EVAL_FILE="$EVAL_DIR/${RUN_ID}.yaml"

if [ ! -f "$EVAL_FILE" ]; then
  log_error "No evaluation found for run '$RUN_ID'. Run 'arena eval $RUN_ID' first."
  exit 1
fi

# Parse evaluation results
TASK=$(grep '^task:' "$EVAL_FILE" | head -1 | sed 's/^task: *//')
ENV_A=$(grep '^env_a:' "$EVAL_FILE" | head -1 | sed 's/^env_a: *//')
ENV_B=$(grep '^env_b:' "$EVAL_FILE" | head -1 | sed 's/^env_b: *//')
WINNER=$(grep '^winner:' "$EVAL_FILE" | head -1 | sed 's/^winner: *//')

# Extract scores
SCORE_A=$(grep -A20 'env_a:' "$EVAL_FILE" | grep 'overall:' | head -1 | sed 's/.*overall: *//')
SCORE_B=$(grep -A20 'env_b:' "$EVAL_FILE" | grep 'overall:' | head -1 | sed 's/.*overall: *//')

# Extract summary and winner_reason
SUMMARY=$(sed -n '/^summary:/,/^[a-z_]*:/{ /^summary:/d; /^[a-z_]*:/d; s/^  //; p; }' "$EVAL_FILE" | head -5)
WINNER_REASON=$(sed -n '/^winner_reason:/,/^[a-z_]*:/{ /^winner_reason:/d; /^[a-z_]*:/d; s/^  //; p; }' "$EVAL_FILE" | head -5)

# Pick embed color based on winner
# Green for env_a, Blue for env_b, Gray for tie
case "$WINNER" in
  env_a) COLOR=3066993 ;;   # green
  env_b) COLOR=3447003 ;;   # blue
  tie)   COLOR=9807270 ;;   # gray
  *)     COLOR=15105570 ;;  # orange (unknown)
esac

# Build the embed description
EMBED_DESC="**Task:** \`$TASK\`
**Env A** (\`$ENV_A\`): **${SCORE_A:-?}/10**
**Env B** (\`$ENV_B\`): **${SCORE_B:-?}/10**
**Winner:** \`$WINNER\`

${SUMMARY}

**Reason:** ${WINNER_REASON}"

TITLE="Arena: ${TASK} — ${ENV_A} vs ${ENV_B}"

log_info "Posting results to #claude-bakeoff..."

RESPONSE=$(bot_post_embed "$CLAUDE_ARENA_CHANNEL_ID" "$TITLE" "$EMBED_DESC" "$COLOR")
MSG_ID=$(echo "$RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)

if [ -n "$MSG_ID" ]; then
  log_ok "Posted to #claude-bakeoff (message $MSG_ID)"

  # Post full evaluation as a thread reply if the raw judge output exists
  RAW_FILE="$EVAL_DIR/${RUN_ID}_raw.txt"
  if [ -f "$RAW_FILE" ]; then
    # Create thread from the message
    TOKEN=$(_get_bot_token)
    THREAD_RESPONSE=$(curl -s -X POST "https://discord.com/api/v10/channels/${CLAUDE_ARENA_CHANNEL_ID}/messages/${MSG_ID}/threads" \
      -H "Authorization: Bot ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$(python3 -c "import json; print(json.dumps({'name': 'Full Judge Reasoning', 'auto_archive_duration': 1440}))")")

    THREAD_ID=$(echo "$THREAD_RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)

    if [ -n "$THREAD_ID" ]; then
      RAW_CONTENT=$(cat "$RAW_FILE")
      while [ -n "$RAW_CONTENT" ]; do
        CHUNK="${RAW_CONTENT:0:1990}"
        RAW_CONTENT="${RAW_CONTENT:1990}"
        bot_post "$THREAD_ID" "$CHUNK" > /dev/null
        [ -n "$RAW_CONTENT" ] && sleep 1
      done
      log_ok "Full reasoning posted in thread"
    fi
  fi
else
  log_error "Failed to post to Discord"
  exit 1
fi
