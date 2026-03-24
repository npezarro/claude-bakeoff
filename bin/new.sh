#!/usr/bin/env bash
set -euo pipefail

ARENA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ARENA_ROOT/bin/lib/common.sh"

TYPE="${1:-}"
NAME="${2:-}"

if [ -z "$TYPE" ] || [ -z "$NAME" ]; then
    echo "Usage: arena new <challenge|recipe> <name>"
    exit 1
fi

case "$TYPE" in
    task|challenge)
        DEST="$ARENA_ROOT/tasks/$NAME"
        if [ -d "$DEST" ]; then
            log_error "Challenge '$NAME' already exists"
            exit 1
        fi
        cp -r "$ARENA_ROOT/tasks/.example" "$DEST"
        sed -i "s/^name:.*/name: $NAME/" "$DEST/task.yaml"
        sed -i "s/^description:.*/description: TODO - describe this challenge/" "$DEST/task.yaml"
        log_ok "New challenge prepared: $DEST/task.yaml"
        log_info "Edit the task.yaml to set your prompt and judging criteria"
        ;;
    env|environment|recipe)
        DEST="$ARENA_ROOT/environments/$NAME"
        if [ -d "$DEST" ]; then
            log_error "Recipe '$NAME' already exists"
            exit 1
        fi
        mkdir -p "$DEST"
        cat > "$DEST/CLAUDE.md" <<EOF
# $NAME Recipe
# Add your instructions for this recipe here.
EOF
        log_ok "New recipe written: $DEST/"
        log_info "Edit the CLAUDE.md to define your instructions"
        ;;
    platform)
        DEST="$ARENA_ROOT/platforms/${NAME}.sh"
        if [ -f "$DEST" ]; then
            log_error "Platform '$NAME' already exists"
            exit 1
        fi
        cat > "$DEST" <<'PLATFORM_EOF'
#!/usr/bin/env bash
# Platform runner: NAME_PLACEHOLDER
#
# Interface:
#   args:   <workspace_dir>
#   env:    BAKE_PROMPT, BAKE_ENV_NAME
#   stdout: JSON with at least a "result" field containing the response text
#   exit:   0 on success

set -euo pipefail

WORKSPACE_DIR="${1:?Usage: NAME_PLACEHOLDER.sh <workspace_dir>}"
PROMPT="${BAKE_PROMPT:?BAKE_PROMPT is required}"

# TODO: Implement your platform runner here
# Output must be JSON: {"result": "<response text>"}
echo '{"result": "TODO: implement platform runner"}'
PLATFORM_EOF
        sed -i "s/NAME_PLACEHOLDER/$NAME/g" "$DEST"
        chmod +x "$DEST"
        log_ok "New platform runner: $DEST"
        log_info "Edit the script to implement your platform's execution logic"
        ;;
    *)
        echo "Usage: arena new <challenge|recipe|platform> <name>"
        exit 1
        ;;
esac
