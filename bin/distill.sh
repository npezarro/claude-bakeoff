#!/usr/bin/env bash
set -euo pipefail

ARENA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ARENA_ROOT/bin/lib/common.sh"

# Parse args
PROFILE_NAME=""

while [ $# -gt 0 ]; do
    case "$1" in
        --profile)    PROFILE_NAME="$2"; shift 2 ;;
        -*)           log_error "Unknown option: $1"; exit 1 ;;
        *)            log_error "Unexpected argument: $1"; exit 1 ;;
    esac
done

if [ -z "$PROFILE_NAME" ]; then
    log_error "Usage: arena distill --profile <name>"
    exit 1
fi

PROFILES_DIR="$HOME/repos/agentGuidance/profiles"
PROFILE_DIR="$PROFILES_DIR/$PROFILE_NAME"
EXPERIENCE_FILE="$PROFILE_DIR/experience.md"
PROFILE_FILE="$PROFILE_DIR/profile.md"

# Validate profile directory exists
if [ ! -d "$PROFILE_DIR" ]; then
    log_error "Profile directory not found: $PROFILE_DIR"
    exit 1
fi

# Validate experience.md exists and has content
if [ ! -f "$EXPERIENCE_FILE" ]; then
    log_error "No experience.md found at $EXPERIENCE_FILE"
    exit 1
fi

if [ ! -s "$EXPERIENCE_FILE" ]; then
    log_error "experience.md is empty — nothing to distill"
    exit 1
fi

# Read profile context (optional, may not exist)
PROFILE_CONTEXT=""
if [ -f "$PROFILE_FILE" ]; then
    PROFILE_CONTEXT="$(cat "$PROFILE_FILE")"
fi

EXPERIENCE_CONTENT="$(cat "$EXPERIENCE_FILE")"

CLAUDE_BIN="$(config_get claude_bin claude)"

log_info "Distilling experience log for profile: $PROFILE_NAME"

# Build the distill prompt
DISTILL_PROMPT="$(cat <<DISTILL_EOF
Here is an agent profile and its experience log. Distill the experience log into the top recurring patterns and lessons.

## Agent Profile
<profile>
$PROFILE_CONTEXT
</profile>

## Experience Log
<experience>
$EXPERIENCE_CONTENT
</experience>

## Instructions

Analyze the experience log and produce output in EXACTLY this format:

## Distilled Patterns
(condensed top patterns, organized by theme — keep entries that represent durable, cross-project patterns; drop one-off observations that aren't generalizable)

---

## Raw Log
(preserve ALL original entries below this marker so nothing is lost)

Write the distilled output now. Start with "## Distilled Patterns".
DISTILL_EOF
)"

log_info "Sending to Claude for distillation..."

DISTILL_OUTPUT="$($CLAUDE_BIN --print -p "$DISTILL_PROMPT" 2>/dev/null)" || {
    log_error "Distillation failed"
    exit 1
}

# Write the distilled output back to experience.md
echo "$DISTILL_OUTPUT" > "$EXPERIENCE_FILE"

# Count patterns extracted (lines starting with - or * under Distilled Patterns, before Raw Log)
PATTERN_COUNT="$(echo "$DISTILL_OUTPUT" | sed -n '/^## Distilled Patterns/,/^## Raw Log/p' | grep -cE '^\s*[-*] ' || echo "0")"

log_info "Committing distilled experience log..."

# Git add, commit, push
cd "$HOME/repos/agentGuidance"
git add "profiles/$PROFILE_NAME/experience.md"
git commit -m "Distill $PROFILE_NAME experience log" || {
    log_error "Git commit failed (no changes?)"
    exit 1
}
git push || {
    log_error "Git push failed"
    exit 1
}

log_ok "Distilled $PROFILE_NAME experience log ($PATTERN_COUNT patterns extracted)"
