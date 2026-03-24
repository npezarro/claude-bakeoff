#!/usr/bin/env bash
# Platform runner: Discord
# Sends the prompt to a Discord channel via the bot, waits for the bot's reply,
# and outputs the response text.
#
# Interface:
#   args:   <workspace_dir>  (unused for Discord, kept for interface parity)
#   env:    BAKE_PROMPT, BAKE_DISCORD_CHANNEL, BAKE_DISCORD_BOT_ID,
#           BAKE_DISCORD_TIMEOUT (seconds, default 300)
#   stdout: bot's response text (plain text, not JSON)
#   exit:   0 on success

set -euo pipefail

WORKSPACE_DIR="${1:?Usage: discord.sh <workspace_dir>}"
PROMPT="${BAKE_PROMPT:?BAKE_PROMPT is required}"
BOT_TOKEN_CACHE="$HOME/.cache/discord-bot-token"

# --- Config ---
CHANNEL_ID="${BAKE_DISCORD_CHANNEL:?BAKE_DISCORD_CHANNEL is required}"
BOT_USER_ID="${BAKE_DISCORD_BOT_ID:?BAKE_DISCORD_BOT_ID is required}"
TIMEOUT="${BAKE_DISCORD_TIMEOUT:-300}"

# --- Resolve bot token ---
get_bot_token() {
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

TOKEN="$(get_bot_token)"
[ -z "$TOKEN" ] && { echo "ERROR: No bot token available" >&2; exit 1; }

discord_api() {
    local method="$1" endpoint="$2"
    shift 2
    curl -s -X "$method" "https://discord.com/api/v10${endpoint}" \
        -H "Authorization: Bot ${TOKEN}" \
        -H "Content-Type: application/json" \
        "$@"
}

# --- Tag the prompt so the bot knows it's a bakeoff run ---
TAGGED_PROMPT="[bakeoff] ${PROMPT}"

# --- Record timestamp before sending (for filtering) ---
BEFORE_TS="$(date +%s)"

# --- Send prompt to the channel ---
SEND_PAYLOAD="$(python3 -c "import json,sys; print(json.dumps({'content': sys.argv[1]}))" "$TAGGED_PROMPT")"
SEND_RESP="$(discord_api POST "/channels/${CHANNEL_ID}/messages" -d "$SEND_PAYLOAD")"
SENT_MSG_ID="$(echo "$SEND_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null)"

if [ -z "$SENT_MSG_ID" ]; then
    echo "ERROR: Failed to send prompt to Discord channel $CHANNEL_ID" >&2
    echo "$SEND_RESP" >&2
    exit 1
fi

echo "Sent prompt (msg $SENT_MSG_ID), waiting for bot response..." >&2

# --- Poll for the bot's reply ---
ELAPSED=0
POLL_INTERVAL=5

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))

    # Fetch messages after our sent message
    MESSAGES="$(discord_api GET "/channels/${CHANNEL_ID}/messages?after=${SENT_MSG_ID}&limit=10")"

    # Find a message from the bot that's a reply or just after ours
    BOT_RESPONSE="$(echo "$MESSAGES" | python3 -c "
import json, sys
msgs = json.load(sys.stdin)
bot_id = '${BOT_USER_ID}'
for msg in msgs:
    author = msg.get('author', {})
    if author.get('id') == bot_id or author.get('bot', False):
        # Check if it's a reply to our message or just the next bot message
        ref = msg.get('message_reference', {})
        if ref.get('message_id') == '${SENT_MSG_ID}' or author.get('id') == bot_id:
            content = msg.get('content', '')
            # Also check embeds
            for embed in msg.get('embeds', []):
                if embed.get('description'):
                    content += '\n' + embed['description']
            if content.strip():
                print(content)
                sys.exit(0)
sys.exit(1)
" 2>/dev/null)" && break || true

    # Adaptive polling: slow down after first minute
    if [ "$ELAPSED" -ge 60 ] && [ "$POLL_INTERVAL" -lt 10 ]; then
        POLL_INTERVAL=10
    fi

    echo "  ...waiting (${ELAPSED}s / ${TIMEOUT}s)" >&2
done

if [ -z "${BOT_RESPONSE:-}" ]; then
    echo "ERROR: Timed out waiting for bot response after ${TIMEOUT}s" >&2
    exit 1
fi

echo "Got bot response (${ELAPSED}s)" >&2

# Output the response — wrap in JSON to match CLI platform output shape
python3 -c "
import json, sys
print(json.dumps({'result': sys.argv[1], 'platform': 'discord'}))
" "$BOT_RESPONSE"
