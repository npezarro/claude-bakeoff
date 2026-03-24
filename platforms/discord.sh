#!/usr/bin/env bash
# Platform runner: Discord
# Sends the prompt to #bakeoff-arena via webhook, waits for the bot's reply,
# and outputs the response text.
#
# Interface:
#   args:   <workspace_dir>  (unused for Discord, kept for interface parity)
#   env:    BAKE_PROMPT, BAKE_DISCORD_CHANNEL, BAKE_DISCORD_BOT_ID,
#           BAKE_DISCORD_WEBHOOK_URL, BAKE_DISCORD_TIMEOUT (seconds, default 300)
#   stdout: JSON with "result" field containing the response text
#   exit:   0 on success

set -euo pipefail

WORKSPACE_DIR="${1:?Usage: discord.sh <workspace_dir>}"
PROMPT="${BAKE_PROMPT:?BAKE_PROMPT is required}"

# --- Config ---
CHANNEL_ID="${BAKE_DISCORD_CHANNEL:?BAKE_DISCORD_CHANNEL is required}"
BOT_USER_ID="${BAKE_DISCORD_BOT_ID:?BAKE_DISCORD_BOT_ID is required}"
WEBHOOK_URL="${BAKE_DISCORD_WEBHOOK_URL:?BAKE_DISCORD_WEBHOOK_URL is required}"
TIMEOUT="${BAKE_DISCORD_TIMEOUT:-300}"
BOT_TOKEN_CACHE="$HOME/.cache/discord-bot-token"

# --- Resolve bot token (for reading messages) ---
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

# --- Send prompt via webhook (appears as "Bakeoff Runner", not the bot itself) ---
TAGGED_PROMPT="[bakeoff] ${PROMPT}"

SEND_RESP="$(curl -s -X POST "${WEBHOOK_URL}?wait=true" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c "import json,sys; print(json.dumps({'content': sys.argv[1], 'username': 'Bakeoff Runner'}))" "$TAGGED_PROMPT")")"

SENT_MSG_ID="$(echo "$SEND_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null)"

if [ -z "$SENT_MSG_ID" ]; then
    echo "ERROR: Failed to send prompt via webhook" >&2
    echo "$SEND_RESP" >&2
    exit 1
fi

echo "Sent prompt via webhook (msg $SENT_MSG_ID), waiting for bot response..." >&2

# --- Poll for the bot's reply ---
ELAPSED=0
POLL_INTERVAL=5
BOT_RESPONSE=""

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))

    # Fetch messages after our sent message
    MESSAGES="$(curl -s "https://discord.com/api/v10/channels/${CHANNEL_ID}/messages?after=${SENT_MSG_ID}&limit=20" \
        -H "Authorization: Bot ${TOKEN}")"

    # Find the bot's response — look for messages from the bot user ID
    BOT_RESPONSE="$(echo "$MESSAGES" | python3 -c "
import json, sys
try:
    msgs = json.load(sys.stdin)
except:
    sys.exit(1)
if not isinstance(msgs, list):
    sys.exit(1)

bot_id = '${BOT_USER_ID}'
# Collect all messages from the bot (may be chunked across multiple messages)
bot_msgs = []
for msg in msgs:
    author = msg.get('author', {})
    if author.get('id') == bot_id:
        bot_msgs.append(msg)

if not bot_msgs:
    sys.exit(1)

# Sort by timestamp ascending
bot_msgs.sort(key=lambda m: m.get('timestamp', ''))

# Concatenate all bot message content (handles chunked responses)
parts = []
for msg in bot_msgs:
    content = msg.get('content', '')
    if content.strip():
        parts.append(content)
    for embed in msg.get('embeds', []):
        desc = embed.get('description', '')
        if desc.strip():
            parts.append(desc)

if parts:
    print('\n'.join(parts))
    sys.exit(0)
sys.exit(1)
" 2>/dev/null)" && {
        # Check if the response looks complete (bot sends a final message with certain patterns)
        # Give it a couple more polls to collect all chunks
        sleep 3
        # Re-fetch to get any trailing chunks
        MESSAGES_FINAL="$(curl -s "https://discord.com/api/v10/channels/${CHANNEL_ID}/messages?after=${SENT_MSG_ID}&limit=50" \
            -H "Authorization: Bot ${TOKEN}")"
        BOT_RESPONSE="$(echo "$MESSAGES_FINAL" | python3 -c "
import json, sys
try:
    msgs = json.load(sys.stdin)
except:
    sys.exit(1)
if not isinstance(msgs, list):
    sys.exit(1)
bot_id = '${BOT_USER_ID}'
bot_msgs = [m for m in msgs if m.get('author', {}).get('id') == bot_id]
bot_msgs.sort(key=lambda m: m.get('timestamp', ''))
parts = []
for msg in bot_msgs:
    content = msg.get('content', '')
    if content.strip():
        parts.append(content)
    for embed in msg.get('embeds', []):
        desc = embed.get('description', '')
        if desc.strip():
            parts.append(desc)
if parts:
    print('\n'.join(parts))
    sys.exit(0)
sys.exit(1)
" 2>/dev/null)" && break || true
    } || true

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

# Output as JSON to match CLI platform output shape
python3 -c "
import json, sys
print(json.dumps({'result': sys.argv[1], 'platform': 'discord'}))
" "$BOT_RESPONSE"
