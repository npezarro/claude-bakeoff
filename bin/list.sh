#!/usr/bin/env bash
set -euo pipefail

ARENA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ARENA_ROOT/bin/lib/common.sh"

TARGET="${1:-}"

case "$TARGET" in
    tasks)
        echo "Available tasks:"
        for d in "$ARENA_ROOT/tasks"/*/; do
            [ -f "$d/task.yaml" ] || continue
            name="$(basename "$d")"
            desc="$(get_task_field "$d/task.yaml" "description")"
            printf "  %-25s %s\n" "$name" "$desc"
        done
        ;;
    runs)
        RUNS_DIR="$ARENA_ROOT/$(config_get runs_dir runs)"
        if [ ! -d "$RUNS_DIR" ] || [ -z "$(ls -A "$RUNS_DIR" 2>/dev/null)" ]; then
            echo "No runs yet."
            exit 0
        fi
        echo "Runs:"
        for d in "$RUNS_DIR"/*/; do
            [ -f "$d/meta.yaml" ] || continue
            id="$(basename "$d")"
            task="$(grep '^task:' "$d/meta.yaml" | sed 's/^task: *//')"
            status="$(grep '^status:' "$d/meta.yaml" | sed 's/^status: *//')"
            env_a="$(grep '^env_a:' "$d/meta.yaml" | sed 's/^env_a: *//')"
            env_b="$(grep '^env_b:' "$d/meta.yaml" | sed 's/^env_b: *//')"
            printf "  %-20s %-20s %-10s %s vs %s\n" "$id" "$task" "[$status]" "$env_a" "$env_b"
        done
        ;;
    envs|environments)
        echo "Available environments:"
        for d in "$ARENA_ROOT/environments"/*/; do
            name="$(basename "$d")"
            files="$(ls "$d" | tr '\n' ', ' | sed 's/,$//')"
            printf "  %-25s (%s)\n" "$name" "$files"
        done
        ;;
    *)
        echo "Usage: arena list <tasks|runs|envs>"
        exit 1
        ;;
esac
