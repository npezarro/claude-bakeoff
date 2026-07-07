#!/usr/bin/env bash
# Platform runner: HARDENED — verified pipeline + test-suite hardening pass.
# After the worker finishes, a fresh-context agent audits the delivered test
# suite for uncovered risk areas (the recurring 9-9 tiebreak currency), adds
# the missing tests, re-runs everything, and reports; then the verify pass
# generates the evidence block. Attacks the native-depth residual on build
# tasks by making suite depth a pipeline stage instead of a model trait.
set -euo pipefail

WORKSPACE_DIR="${1:?Usage: hardened.sh <workspace_dir>}"
PROMPT="${BAKE_PROMPT:?BAKE_PROMPT is required}"
MODEL="${BAKE_MODEL:-claude-opus-4-8}"
MAX_TURNS="${BAKE_MAX_TURNS:-45}"
VERIFIER="$HOME/repos/agentGuidance/scripts/verify-report.sh"
EFFORT_ARGS=()
[ -n "${BAKE_EFFORT:-}" ] && EFFORT_ARGS=(--effort "$BAKE_EFFORT")

cd "$WORKSPACE_DIR"
OUT="$(mktemp)"
claude --print --max-turns "$MAX_TURNS" --output-format json \
    --dangerously-skip-permissions --model "$MODEL" "${EFFORT_ARGS[@]}" \
    -p "$PROMPT" > "$OUT" 2>/dev/null || true
REPORT="$(jq -r '.result // empty' "$OUT" 2>/dev/null || true)"
rm -f "$OUT"
[ -n "$REPORT" ] || { jq -n '{result: "HARDENED FAILED: worker empty", is_error: true}'; exit 0; }

HARDEN="A previous engineer just delivered the work in this directory for the task below, including a test suite. Your job is ONLY to harden the test suite: audit it against the task's risk areas (boundary semantics, error paths after partial success, cross-component contracts, ordering/pagination composition, lifecycle/cleanup, subprocess-level behavior like real exit codes), add the highest-value missing tests (aim for the 5-15 that most reduce risk, not bulk), run the full expanded suite, and fix nothing in the implementation unless a new test exposes a real bug (then fix minimally and note it). Output: a short list of what coverage you added and why, any real bug found, and the verbatim final suite output.

ORIGINAL TASK:
$PROMPT"
H_OUT="$(mktemp)"
claude --print --max-turns 30 --output-format json \
    --dangerously-skip-permissions --model "$MODEL" "${EFFORT_ARGS[@]}" \
    -p "$HARDEN" > "$H_OUT" 2>/dev/null || true
HARDEN_REPORT="$(jq -r '.result // empty' "$H_OUT" 2>/dev/null || true)"
rm -f "$H_OUT"

EVIDENCE="$("$VERIFIER" "$WORKSPACE_DIR" "$PROMPT" 2>/dev/null || echo "VERIFIER FAILED")"

FINAL="$REPORT

---
## Suite hardening pass (fresh-context)

${HARDEN_REPORT:-hardening pass failed}

---
## Independent verification (fresh-context agent, read+execute only)

$EVIDENCE"
jq -n --arg r "$FINAL" '{result: $r, subtype: "success", platform: "hardened"}'
