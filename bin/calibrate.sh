#!/usr/bin/env bash
# Calibrate the judge against human Pass/Fail labels. See bin/calibrate.py.
#
# Usage: arena calibrate extract|serve|judge|report [options]
#
# calibration/ holds real arm outputs and the human labels, so it is a symlink into the
# private repo, the same wiring as tasks/. This creates it on first use.
set -euo pipefail

ARENA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ARENA_ROOT/bin/lib/common.sh"
export ARENA_ROOT

PRIVATE="$ARENA_ROOT/../privateContext/bakeoff/calibration"
if [ ! -e "$ARENA_ROOT/calibration" ]; then
    [ -d "$ARENA_ROOT/../privateContext/bakeoff" ] || { log_error "privateContext/bakeoff not found next to this repo; calibration data has nowhere private to live."; exit 1; }
    mkdir -p "$PRIVATE"
    ln -s ../privateContext/bakeoff/calibration "$ARENA_ROOT/calibration"
    log_info "Linked calibration/ -> privateContext/bakeoff/calibration"
fi

# The judge gets the same isolation judge-n gives it: without it, the host's guidance
# (which contains several of the rules being graded) primes every verdict.
if [ "${1:-}" = "judge" ]; then
    if [ -n "${ARENA_NO_ISOLATION:-}" ]; then
        log_error "ISOLATION OFF (ARENA_NO_ISOLATION set): the judge also reads the host's guidance."
    elif JUDGE_CFG="$(isolated_config_dir)"; then
        export CLAUDE_CONFIG_DIR="$JUDGE_CFG"
        trap 'rm -rf "$JUDGE_CFG"' EXIT
    else
        log_error "NOT ISOLATED: the judge will also read the host's guidance."
    fi
fi

python3 "$ARENA_ROOT/bin/calibrate.py" "$@"
