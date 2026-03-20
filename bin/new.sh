#!/usr/bin/env bash
set -euo pipefail

ARENA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ARENA_ROOT/bin/lib/common.sh"

TYPE="${1:-}"
NAME="${2:-}"

if [ -z "$TYPE" ] || [ -z "$NAME" ]; then
    echo "Usage: arena new <task|env> <name>"
    exit 1
fi

case "$TYPE" in
    task)
        DEST="$ARENA_ROOT/tasks/$NAME"
        if [ -d "$DEST" ]; then
            log_error "Task '$NAME' already exists"
            exit 1
        fi
        cp -r "$ARENA_ROOT/tasks/.example" "$DEST"
        sed -i "s/^name:.*/name: $NAME/" "$DEST/task.yaml"
        sed -i "s/^description:.*/description: TODO - describe this task/" "$DEST/task.yaml"
        log_ok "Created task: $DEST/task.yaml"
        log_info "Edit the task.yaml to define your prompt and criteria"
        ;;
    env|environment)
        DEST="$ARENA_ROOT/environments/$NAME"
        if [ -d "$DEST" ]; then
            log_error "Environment '$NAME' already exists"
            exit 1
        fi
        mkdir -p "$DEST"
        cat > "$DEST/CLAUDE.md" <<EOF
# $NAME Environment
# Add your instructions for this environment here.
EOF
        log_ok "Created environment: $DEST/"
        log_info "Edit the CLAUDE.md to define your instructions"
        ;;
    *)
        echo "Usage: arena new <task|env> <name>"
        exit 1
        ;;
esac
